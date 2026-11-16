#Requires -Version 5.1
<#
    WinCare.Storage - fixed volumes and, when identifiable, the media type of the
    underlying physical disk (HDD/SSD/SCM) and NVMe bus. Read-only.

    Sources:
      Win32_LogicalDisk (DriveType=3)                       volumes, size, free space
      root/Microsoft/Windows/Storage MSFT_Partition          drive letter -> disk number
      root/Microsoft/Windows/Storage MSFT_PhysicalDisk       MediaType, BusType
    MSFT_PhysicalDisk.DeviceId usually equals the disk number; when no match is
    found, MediaType stays 'Unknown' instead of guessing.
#>

$script:MediaTypeMap = @{ 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
$script:BusTypeMap = @{ 1 = 'SCSI'; 3 = 'ATA'; 7 = 'USB'; 8 = 'RAID'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 15 = 'FileBackedVirtual'; 17 = 'NVMe' }

function ConvertTo-WcVolumeInfo {
    [CmdletBinding()]
    param(
        [object[]] $LogicalDisk,
        [object[]] $Partition,
        [object[]] $PhysicalDisk,
        [string] $SystemDrive = 'C:'
    )
    $diskByLetter = @{}
    foreach ($p in @($Partition)) {
        if ($null -eq $p) { continue }
        $letter = Get-WcObjectValue $p 'DriveLetter'
        if ($letter -and [string]$letter -match '^[A-Za-z]$') {
            $diskByLetter[([string]$letter).ToUpperInvariant() + ':'] = [string](Get-WcObjectValue $p 'DiskNumber')
        }
    }
    $physById = @{}
    foreach ($d in @($PhysicalDisk)) {
        if ($null -eq $d) { continue }
        $physById[[string](Get-WcObjectValue $d 'DeviceId')] = $d
    }
    $result = @()
    foreach ($ld in @($LogicalDisk)) {
        if ($null -eq $ld) { continue }
        $id = ([string](Get-WcObjectValue $ld 'DeviceID')).ToUpperInvariant()
        $size = Get-WcObjectValue $ld 'Size'
        $free = Get-WcObjectValue $ld 'FreeSpace'
        $freePct = $null
        if ($size -and [double]$size -gt 0 -and $null -ne $free) { $freePct = [math]::Round(([double]$free / [double]$size) * 100, 1) }
        $media = 'Unknown'; $bus = 'Unknown'; $model = $null
        if ($diskByLetter.ContainsKey($id) -and $physById.ContainsKey($diskByLetter[$id])) {
            $pd = $physById[$diskByLetter[$id]]
            $mt = Get-WcObjectValue $pd 'MediaType'
            if ($null -ne $mt -and $script:MediaTypeMap.ContainsKey([int]$mt)) { $media = $script:MediaTypeMap[[int]$mt] }
            $bt = Get-WcObjectValue $pd 'BusType'
            if ($null -ne $bt -and $script:BusTypeMap.ContainsKey([int]$bt)) { $bus = $script:BusTypeMap[[int]$bt] }
            $model = Get-WcObjectValue $pd 'FriendlyName'
        }
        $sizeOut = $null; if ($size) { $sizeOut = [double]$size }
        $freeOut = $null; if ($null -ne $free) { $freeOut = [double]$free }
        $result += [pscustomobject]@{
            Drive       = $id
            Label       = [string](Get-WcObjectValue $ld 'VolumeName')
            FileSystem  = [string](Get-WcObjectValue $ld 'FileSystem')
            SizeBytes   = $sizeOut
            FreeBytes   = $freeOut
            FreePercent = $freePct
            MediaType   = $media
            BusType     = $bus
            Model       = $model
            IsSystem    = ($id -eq $SystemDrive.ToUpperInvariant())
        }
    }
    return $result
}

function Get-WcVolumeInfo {
    [CmdletBinding()]
    param()
    $ld = Get-WcCimData -ClassName 'Win32_LogicalDisk' -Filter 'DriveType=3'
    $parts = Get-WcCimData -ClassName 'MSFT_Partition' -Namespace 'root/Microsoft/Windows/Storage'
    $phys = Get-WcCimData -ClassName 'MSFT_PhysicalDisk' -Namespace 'root/Microsoft/Windows/Storage'
    $sys = $env:SystemDrive
    if (-not $sys) { $sys = 'C:' }
    return (ConvertTo-WcVolumeInfo -LogicalDisk $ld -Partition $parts -PhysicalDisk $phys -SystemDrive $sys)
}

Export-ModuleMember -Function @('ConvertTo-WcVolumeInfo', 'Get-WcVolumeInfo')
