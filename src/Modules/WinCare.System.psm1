#Requires -Version 5.1
<#
    WinCare.System - Windows, CPU, memory, uptime and pending-reboot data.

    Pattern used by every collection module:
      Get-*        thin I/O wrapper (CIM, registry). Windows-only. Mocked in tests.
      ConvertTo-*  pure function that shapes raw data. Fully tested on Linux.
    Nothing here changes the system.
#>

function Get-WcCimData {
    <# Read-only CIM query that never throws: returns $null and logs on failure. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ClassName,
        [string] $Namespace = 'root/cimv2',
        [string] $Filter
    )
    $params = @{ ClassName = $ClassName; Namespace = $Namespace; ErrorAction = 'Stop' }
    if ($Filter) { $params['Filter'] = $Filter }
    try { return @(Get-CimInstance @params) }
    catch {
        Write-WcLog -Level Warning -Category 'CIM' -Message ("{0} unavailable: {1}" -f $ClassName, $_.Exception.Message) | Out-Null
        return $null
    }
}

function Get-WcRegistryValues {
    <# Reads selected values of a registry key. Missing key -> empty hashtable. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $Name
    )
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $result }
    foreach ($n in $Name) {
        $p = $item.PSObject.Properties[$n]
        if ($p) { $result[$n] = $p.Value }
    }
    return $result
}

function Get-WcObjectValue {
    <# Safe property read for CIM objects, hashtables and pscustomobjects. #>
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# ------------------------------------------------------------------ Windows --

function ConvertTo-WcWindowsInfo {
    <#
        Builds the Windows identity from Win32_OperatingSystem + the
        'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' values.
        Windows 11 still reports ProductName "Windows 10" in the registry, so the
        family is derived from the build number (>= 22000 = Windows 11).
    #>
    [CmdletBinding()]
    param(
        $OperatingSystem,
        [hashtable] $CurrentVersion = @{}
    )
    $build = 0
    $buildText = Get-WcObjectValue $OperatingSystem 'BuildNumber'
    if (-not $buildText) { $buildText = $CurrentVersion['CurrentBuildNumber'] }
    if ($buildText) { [void][int]::TryParse([string]$buildText, [ref]$build) }

    $productType = Get-WcObjectValue $OperatingSystem 'ProductType'
    $isServer = ($null -ne $productType -and [int]$productType -ne 1)

    $family = 'Unknown'
    if ($isServer) { $family = 'Windows Server' }
    elseif ($build -ge 22000) { $family = 'Windows 11' }
    elseif ($build -ge 10240) { $family = 'Windows 10' }
    elseif ($build -gt 0) { $family = 'Legacy' }

    $edition = [string]$CurrentVersion['EditionID']
    $isLtsc = ($edition -match 'S$' -and $edition -match '^(Enterprise|IoTEnterprise)')
    $isIoT = ($edition -like 'IoT*')

    $editionLabel = switch -Regex ($edition) {
        '^Professional$' { 'Pro'; break }
        '^ProfessionalWorkstation$' { 'Pro for Workstations'; break }
        '^ProfessionalEducation$' { 'Pro Education'; break }
        '^Enterprise$' { 'Enterprise'; break }
        '^EnterpriseS$' { 'Enterprise LTSC'; break }
        '^IoTEnterprise$' { 'IoT Enterprise'; break }
        '^IoTEnterpriseS$' { 'IoT Enterprise LTSC'; break }
        '^Education$' { 'Education'; break }
        '^Core' { 'Home'; break }
        default { if ($edition) { $edition } else { 'Unknown' } }
    }

    $supported = (-not $isServer) -and ($build -ge 10240) -and (@('Professional', 'Enterprise', 'EnterpriseS', 'IoTEnterprise', 'IoTEnterpriseS') -contains $edition)

    return [pscustomobject]@{
        Family          = $family
        Caption         = [string](Get-WcObjectValue $OperatingSystem 'Caption')
        EditionId       = $edition
        Edition         = $editionLabel
        DisplayVersion  = [string]$CurrentVersion['DisplayVersion']
        Build           = $build
        Ubr             = $CurrentVersion['UBR']
        Version         = [string](Get-WcObjectValue $OperatingSystem 'Version')
        Architecture    = [string](Get-WcObjectValue $OperatingSystem 'OSArchitecture')
        IsLtsc          = [bool]$isLtsc
        IsIoT           = [bool]$isIoT
        IsServer        = [bool]$isServer
        InSupportMatrix = [bool]$supported
    }
}

function Get-WcWindowsInfo {
    [CmdletBinding()]
    param()
    $os = Get-WcCimData -ClassName 'Win32_OperatingSystem' | Select-Object -First 1
    $cv = Get-WcRegistryValues -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name @('EditionID', 'DisplayVersion', 'ReleaseId', 'UBR', 'CurrentBuildNumber', 'ProductName')
    return (ConvertTo-WcWindowsInfo -OperatingSystem $os -CurrentVersion $cv)
}

# ---------------------------------------------------------------------- CPU --

function ConvertTo-WcCpuUsage {
    <#
        CPU utilisation from two raw samples of Win32_PerfRawData_PerfOS_Processor
        (Name='_Total'). PercentProcessorTime is a PERF_100NSEC_TIMER_INV counter:
            busy% = (1 - dIdle / dTime) * 100
        where dIdle = delta PercentProcessorTime and dTime = delta Timestamp_Sys100NS.
        Returns $null when the samples cannot produce a valid value.
    #>
    [CmdletBinding()]
    param($First, $Second)
    if ($null -eq $First -or $null -eq $Second) { return $null }
    $idle1 = Get-WcObjectValue $First 'PercentProcessorTime'
    $idle2 = Get-WcObjectValue $Second 'PercentProcessorTime'
    $t1 = Get-WcObjectValue $First 'Timestamp_Sys100NS'
    $t2 = Get-WcObjectValue $Second 'Timestamp_Sys100NS'
    if ($null -eq $idle1 -or $null -eq $idle2 -or $null -eq $t1 -or $null -eq $t2) { return $null }
    $dTime = [double]$t2 - [double]$t1
    $dIdle = [double]$idle2 - [double]$idle1
    if ($dTime -le 0 -or $dIdle -lt 0) { return $null }
    $busy = (1.0 - ($dIdle / $dTime)) * 100.0
    if ($busy -lt 0) { $busy = 0 }
    if ($busy -gt 100) { $busy = 100 }
    return [math]::Round($busy, 1)
}

function ConvertTo-WcCpuInfo {
    [CmdletBinding()]
    param($Processor, $UsagePercent, [int] $SampleMilliseconds = 1000)
    $list = @($Processor | Where-Object { $null -ne $_ })
    $first = $null
    if ($list.Count -gt 0) { $first = $list[0] }
    $cores = 0; $logical = 0
    foreach ($p in $list) {
        $c = Get-WcObjectValue $p 'NumberOfCores'; if ($c) { $cores += [int]$c }
        $l = Get-WcObjectValue $p 'NumberOfLogicalProcessors'; if ($l) { $logical += [int]$l }
    }
    $name = Get-WcObjectValue $first 'Name'
    if ($name) { $name = ([string]$name).Trim() }
    return [pscustomobject]@{
        Name              = $name
        Sockets           = $list.Count
        Cores             = $cores
        LogicalProcessors = $logical
        MaxClockMHz       = Get-WcObjectValue $first 'MaxClockSpeed'
        UsagePercent      = $UsagePercent
        UsageMethod       = ('Win32_PerfRawData_PerfOS_Processor _Total, 2 samples {0} ms apart' -f $SampleMilliseconds)
    }
}

function Get-WcCpuInfo {
    [CmdletBinding()]
    param([ValidateRange(250, 5000)][int] $SampleMilliseconds = 1000)
    $proc = Get-WcCimData -ClassName 'Win32_Processor'
    $filter = "Name='_Total'"
    $s1 = Get-WcCimData -ClassName 'Win32_PerfRawData_PerfOS_Processor' -Filter $filter | Select-Object -First 1
    Start-Sleep -Milliseconds $SampleMilliseconds
    $s2 = Get-WcCimData -ClassName 'Win32_PerfRawData_PerfOS_Processor' -Filter $filter | Select-Object -First 1
    $usage = ConvertTo-WcCpuUsage -First $s1 -Second $s2
    return (ConvertTo-WcCpuInfo -Processor $proc -UsagePercent $usage -SampleMilliseconds $SampleMilliseconds)
}

# ------------------------------------------------------------------- memory --

function ConvertTo-WcMemoryInfo {
    <# TotalPhysicalMemory (bytes, Win32_ComputerSystem); FreePhysicalMemory (KB, Win32_OperatingSystem). #>
    [CmdletBinding()]
    param($OperatingSystem, $ComputerSystem)
    $total = Get-WcObjectValue $ComputerSystem 'TotalPhysicalMemory'
    if (-not $total) {
        $kb = Get-WcObjectValue $OperatingSystem 'TotalVisibleMemorySize'
        if ($kb) { $total = [double]$kb * 1024 }
    }
    $freeKb = Get-WcObjectValue $OperatingSystem 'FreePhysicalMemory'
    $available = $null
    if ($null -ne $freeKb) { $available = [double]$freeKb * 1024 }
    $usedPct = $null
    if ($total -and $null -ne $available -and [double]$total -gt 0) {
        $usedPct = [math]::Round((1 - ($available / [double]$total)) * 100, 1)
    }
    $totalOut = $null
    if ($total) { $totalOut = [double]$total }
    return [pscustomobject]@{
        TotalBytes     = $totalOut
        AvailableBytes = $available
        UsedPercent    = $usedPct
    }
}

# ------------------------------------------------------------------- uptime --

function ConvertTo-WcUptime {
    [CmdletBinding()]
    param($LastBootUpTime, [datetime] $Now = (Get-Date))
    if ($null -eq $LastBootUpTime) { return $null }
    $boot = [datetime]$LastBootUpTime
    $span = $Now - $boot
    if ($span.TotalSeconds -lt 0) { return $null }
    return [pscustomobject]@{
        LastBoot   = $boot.ToString('o')
        TotalHours = [math]::Round($span.TotalHours, 1)
        Days       = $span.Days
        Hours      = $span.Hours
        Minutes    = $span.Minutes
    }
}

# ----------------------------------------------------------- pending reboot --

function ConvertTo-WcPendingReboot {
    <#
        Signals (all read-only):
          CbsRebootPending        HKLM\...\Component Based Servicing\RebootPending (key)
          WindowsUpdateRequired   HKLM\...\WindowsUpdate\Auto Update\RebootRequired (key)
          PendingFileRename       Session Manager\PendingFileRenameOperations (value)
        PendingFileRename alone is common and often benign, so it is reported as
        informational and does not set IsPending by itself.
    #>
    [CmdletBinding()]
    param([hashtable] $Signals = @{})
    $strong = @()
    foreach ($k in @('CbsRebootPending', 'WindowsUpdateRequired')) {
        if ($Signals[$k]) { $strong += $k }
    }
    return [pscustomobject]@{
        IsPending         = ($strong.Count -gt 0)
        Sources           = $strong
        PendingFileRename = [bool]$Signals['PendingFileRename']
    }
}

function Get-WcPendingReboot {
    [CmdletBinding()]
    param()
    $signals = @{
        CbsRebootPending      = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        WindowsUpdateRequired = Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
        PendingFileRename     = $false
    }
    $sm = Get-WcRegistryValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name @('PendingFileRenameOperations')
    if ($sm.ContainsKey('PendingFileRenameOperations') -and $sm['PendingFileRenameOperations']) { $signals.PendingFileRename = $true }
    return (ConvertTo-WcPendingReboot -Signals $signals)
}

# ----------------------------------------------------------------- snapshot --

function Get-WcSystemInfo {
    <# Windows + CPU + memory + uptime + pending reboot in one read-only call. #>
    [CmdletBinding()]
    param([int] $CpuSampleMilliseconds = 1000)
    $os = Get-WcCimData -ClassName 'Win32_OperatingSystem' | Select-Object -First 1
    $cs = Get-WcCimData -ClassName 'Win32_ComputerSystem' | Select-Object -First 1
    return [pscustomobject]@{
        Windows       = Get-WcWindowsInfo
        Cpu           = Get-WcCpuInfo -SampleMilliseconds $CpuSampleMilliseconds
        Memory        = ConvertTo-WcMemoryInfo -OperatingSystem $os -ComputerSystem $cs
        Uptime        = ConvertTo-WcUptime -LastBootUpTime (Get-WcObjectValue $os 'LastBootUpTime')
        PendingReboot = Get-WcPendingReboot
        ComputerName  = [System.Environment]::MachineName
        PowerShell    = $PSVersionTable.PSVersion.ToString()
        PSEdition     = [string]$PSVersionTable['PSEdition']
        IsAdmin       = Test-WcIsAdmin
    }
}

Export-ModuleMember -Function @(
    'Get-WcCimData', 'Get-WcRegistryValues', 'Get-WcObjectValue',
    'ConvertTo-WcWindowsInfo', 'Get-WcWindowsInfo',
    'ConvertTo-WcCpuUsage', 'ConvertTo-WcCpuInfo', 'Get-WcCpuInfo',
    'ConvertTo-WcMemoryInfo', 'ConvertTo-WcUptime',
    'ConvertTo-WcPendingReboot', 'Get-WcPendingReboot', 'Get-WcSystemInfo'
)
