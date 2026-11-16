#Requires -Version 5.1
<#
    WinCare.Baseline - F5: before/after measurement and System Restore points.

    Provides the two Core plan hooks (Register-WcPlanHook), registered lazily by
    Register-WcBaselineHandler (called by Initialize-WcActionHandlers):
      Measure      free bytes of every fixed drive (CIM Win32_LogicalDisk DriveType=3)
      RestorePoint Checkpoint-Computer before High-risk items (policy in Invoke-WcPlan)

    Restore point rules (never relaxed):
      * WinCare NEVER enables System Protection and NEVER changes
        SystemRestorePointCreationFrequency or any other setting: it only reads them.
      * Checkpoint-Computer exists only in Windows PowerShell 5.1 (Desktop) and only on
        client SKUs; it needs an elevated session.
      * Windows creates at most one restore point per frequency window (default 1440 min).
        A recent point is reported as Skipped / created-recently (and referenced), not as a failure.
      * Protection detection reads the SPP\Clients registry value (list of protected volumes).
        This heuristic is documented in docs/CONTRATO-ACOES.md and must be confirmed on real
        client Windows (docs/VALIDACAO-WINDOWS.md); when in doubt the result is Unavailable.

    Pattern: Get-* thin I/O (mocked in tests), ConvertTo-* pure (fixtures on Linux).
#>

$script:WcSppClientsPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients'
$script:WcSppClientsValue = '{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
$script:WcSrPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore'
$script:WcSrConfigPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
$script:WcRestorePointDefaultFrequency = 1440
$script:WcRestorePointTypes = @{ 0 = 'APPLICATION_INSTALL'; 1 = 'APPLICATION_UNINSTALL'; 10 = 'DEVICE_DRIVER_INSTALL'; 12 = 'MODIFY_SETTINGS'; 13 = 'CANCELLED_OPERATION' }

# -------------------------------------------------------------- free space --

function Get-WcFixedDriveRaw {
    <# Thin I/O: fixed drives (DriveType=3). Throws on failure (recorded as a measurement error). #>
    [CmdletBinding()]
    param()
    return @(Get-CimInstance -ClassName 'Win32_LogicalDisk' -Filter 'DriveType=3' -ErrorAction Stop)
}

function ConvertTo-WcFreeSpaceMetric {
    <# Pure: Win32_LogicalDisk rows -> System metrics FreeBytes per drive (Value $null when unknown). #>
    [CmdletBinding()]
    param([object[]] $Disk)
    $out = @()
    foreach ($d in @($Disk)) {
        if ($null -eq $d) { continue }
        $id = [string](Get-WcObjectValue $d 'DeviceID')
        if (-not (Test-WcDriveLetter -Value $id)) { continue }
        $free = Get-WcObjectValue $d 'FreeSpace'
        $value = $null
        if ($null -ne $free) { $value = [long]$free }
        $out += New-WcMetric -Source System -Name 'FreeBytes' -Target $id.ToUpperInvariant() -Unit 'Bytes' -Value $value
    }
    return @($out | Sort-Object Target)
}

function Measure-WcSystemFreeSpace {
    <# Generic measurement used by the Measure hook. Empty on non-Windows hosts. #>
    [CmdletBinding()]
    param()
    if (-not (Test-WcIsWindows)) { return @() }
    return (ConvertTo-WcFreeSpaceMetric -Disk @(Get-WcFixedDriveRaw))
}

# ------------------------------------------------------ restore point data --

function ConvertFrom-WcDmtfDate {
    <# Pure: WMI DMTF datetime 'yyyyMMddHHmmss.ffffff+UUU' -> UTC DateTime, or $null. #>
    [CmdletBinding()]
    param([string] $Value)
    if (-not $Value -or $Value -notmatch '^(\d{14})\.(\d{6})([+-])(\d{3})$') { return $null }
    $local = [datetime]::ParseExact($Matches[1], 'yyyyMMddHHmmss', [System.Globalization.CultureInfo]::InvariantCulture)
    $local = $local.AddTicks([long]$Matches[2] * 10)
    $offset = [int]$Matches[4]
    if ($Matches[3] -eq '-') { $offset = -$offset }
    return [datetime]::SpecifyKind($local.AddMinutes(-$offset), [System.DateTimeKind]::Utc)
}

function ConvertTo-WcRestorePointRow {
    <# Pure: Get-ComputerRestorePoint objects -> rows (newest first) for the Reports page. #>
    [CmdletBinding()]
    param([object[]] $RestorePoint)
    $rows = @()
    foreach ($p in @($RestorePoint)) {
        if ($null -eq $p) { continue }
        $seq = Get-WcObjectValue $p 'SequenceNumber'
        if ($null -eq $seq) { continue }
        $created = ConvertFrom-WcDmtfDate -Value ([string](Get-WcObjectValue $p 'CreationTime'))
        $createdText = $null
        if ($null -ne $created) { $createdText = $created.ToString('o') }
        $typeId = Get-WcObjectValue $p 'RestorePointType'
        $type = [string]$typeId
        if ($null -ne $typeId -and $script:WcRestorePointTypes.ContainsKey([int]$typeId)) { $type = $script:WcRestorePointTypes[[int]$typeId] }
        $rows += [pscustomobject]@{ SequenceNumber = [long]$seq; Created = $createdText; Description = [string](Get-WcObjectValue $p 'Description'); Type = $type }
    }
    return @($rows | Sort-Object SequenceNumber -Descending)
}

function Select-WcRecentRestorePoint {
    <# Pure: newest restore point created within FrequencyMinutes before NowUtc, or $null. #>
    [CmdletBinding()]
    param(
        [object[]] $Row,
        [Parameter(Mandatory = $true)][datetime] $NowUtc,
        [int] $FrequencyMinutes = 1440
    )
    if ($FrequencyMinutes -le 0) { return $null }
    $cutoff = $NowUtc.AddMinutes(-$FrequencyMinutes)
    foreach ($r in @($Row | Sort-Object SequenceNumber -Descending)) {
        if ($null -eq $r -or -not $r.Created) { continue }
        $t = [datetime]::Parse($r.Created, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
        if ($t -gt $cutoff -and $t -le $NowUtc.AddMinutes(5)) { return $r }
    }
    return $null
}

function Test-WcVolumeProtected {
    <# Pure: does the SPP\Clients value list the drive (entries look like '\\?\Volume{...}\:(C%3A)')? #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([object[]] $ProtectedVolume, [string] $Drive)
    if (-not (Test-WcDriveLetter -Value $Drive)) { return $false }
    $needle = '(' + $Drive.Substring(0, 1) + '%3A)'
    foreach ($v in @($ProtectedVolume)) {
        if ($null -ne $v -and ([string]$v).IndexOf($needle, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

function ConvertTo-WcRestorePointAvailability {
    <#
        Pure decision from collected facts (Get-WcRestorePointFacts). Returns
        Available, Reason, ProtectionEnabled ($true/$false/$null = unknown), FrequencyMinutes, Drive.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable] $Facts)
    $freq = $script:WcRestorePointDefaultFrequency
    if ($Facts.ContainsKey('FrequencyMinutes') -and $null -ne $Facts.FrequencyMinutes) { $freq = [int]$Facts.FrequencyMinutes }
    $drive = [string]$Facts['SystemDrive']
    $protected = $null
    if ($Facts.ContainsKey('ProtectedVolumes') -and $Facts['IsWindows']) { $protected = (Test-WcVolumeProtected -ProtectedVolume @($Facts.ProtectedVolumes) -Drive $drive) }
    $reason = ''
    if (-not $Facts['IsWindows']) { $reason = 'not-windows' }
    # PowerShell 7 (Core): the restore point cmdlets exist only in Windows PowerShell 5.1,
    # so they run in a powershell.exe child (DesktopBridge) when it is present.
    elseif ([string]$Facts['PSEdition'] -ne 'Desktop' -and -not $Facts['DesktopBridge']) { $reason = 'powershell-edition' }
    elseif (-not $Facts['HasCheckpointCommand']) { $reason = 'cmdlet-missing' }
    elseif ($null -ne $Facts['ProductType'] -and [int]$Facts['ProductType'] -ne 1) { $reason = 'server-sku' }
    elseif ($null -ne $Facts['PolicyDisableSR'] -and [int]$Facts['PolicyDisableSR'] -eq 1) { $reason = 'disabled-by-policy' }
    elseif ($protected -ne $true) { $reason = 'protection-disabled' }
    elseif (-not $Facts['IsAdmin']) { $reason = 'requires-admin' }
    return [pscustomobject]@{ Available = ($reason -eq ''); Reason = $reason; ProtectionEnabled = $protected; FrequencyMinutes = $freq; Drive = $drive }
}

function Get-WcRestorePointFacts {
    <# Read-only I/O: everything ConvertTo-WcRestorePointAvailability needs. Never writes anything. #>
    [CmdletBinding()]
    param()
    $facts = @{ IsWindows = (Test-WcIsWindows); PSEdition = [string]$PSVersionTable['PSEdition']; HasCheckpointCommand = $false; DesktopBridge = $false
        IsAdmin = $false; ProductType = $null; PolicyDisableSR = $null; ProtectedVolumes = $null; FrequencyMinutes = $null; SystemDrive = $env:SystemDrive
    }
    if (-not $facts.IsWindows) { return $facts }
    if (-not $facts.SystemDrive) { $facts.SystemDrive = 'C:' }
    if ($facts.PSEdition -eq 'Desktop') {
        $facts.HasCheckpointCommand = [bool](Get-Command -Name 'Checkpoint-Computer' -CommandType Cmdlet -ErrorAction SilentlyContinue)
    }
    else {
        # Windows PowerShell 5.1 ships with every supported Windows; its cmdlet is used through the bridge.
        $facts.DesktopBridge = [bool](Test-Path -LiteralPath (Get-WcDesktopPowerShellPath))
        $facts.HasCheckpointCommand = $facts.DesktopBridge
    }
    $facts.IsAdmin = (Test-WcIsAdmin)
    $os = @(Get-WcCimData -ClassName 'Win32_OperatingSystem') | Select-Object -First 1
    if ($os) { $facts.ProductType = Get-WcObjectValue $os 'ProductType' }
    $facts.PolicyDisableSR = (Get-WcRegistryValues -Path $script:WcSrPolicyPath -Name @('DisableSR'))['DisableSR']
    $facts.FrequencyMinutes = (Get-WcRegistryValues -Path $script:WcSrConfigPath -Name @('SystemRestorePointCreationFrequency'))['SystemRestorePointCreationFrequency']
    $spp = Get-WcRegistryValues -Path $script:WcSppClientsPath -Name @($script:WcSppClientsValue)
    if ($spp.ContainsKey($script:WcSppClientsValue)) { $facts.ProtectedVolumes = @($spp[$script:WcSppClientsValue]) } else { $facts.ProtectedVolumes = @() }
    return $facts
}

function Get-WcRestorePointAvailability {
    [CmdletBinding()]
    param()
    return (ConvertTo-WcRestorePointAvailability -Facts (Get-WcRestorePointFacts))
}

function Get-WcDesktopPowerShellPath {
    $root = $env:SystemRoot
    if (-not $root) { $root = 'C:\Windows' }
    return ($root.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe')
}

function Invoke-WcDesktopPowerShell {
    <#
        Runs a FIXED script (built here from validated values only) in Windows PowerShell 5.1
        and returns its JSON output parsed. Used from PowerShell 7 for 5.1-only cmdlets.
        -EncodedCommand is a command, not a script file: execution policy is not involved.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Script)
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Script))
    $out = & (Get-WcDesktopPowerShellPath) -NoProfile -NonInteractive -EncodedCommand $b64 2>&1
    $code = $LASTEXITCODE
    $text = (@($out | ForEach-Object { [string]$_ }) -join "`n").Trim()
    if ($code -ne 0) { throw ('Windows PowerShell 5.1 bridge failed ({0}): {1}' -f $code, $text) }
    if (-not $text) { return @() }
    return @(ConvertFrom-Json -InputObject $text)
}

function Get-WcComputerRestorePointRaw {
    <# Thin I/O (read-only listing). Needs elevation. On PowerShell 7 it goes through the 5.1 bridge. #>
    [CmdletBinding()]
    param()
    if ([string]$PSVersionTable['PSEdition'] -eq 'Desktop') { return @(Get-ComputerRestorePoint -ErrorAction Stop) }
    $script = 'try { @(Get-ComputerRestorePoint -ErrorAction Stop | Select-Object SequenceNumber, CreationTime, Description, RestorePointType) | ConvertTo-Json -Compress -Depth 2 } catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }'
    return @(Invoke-WcDesktopPowerShell -Script $script | ForEach-Object { $_ })
}

function Get-WcRestorePoint {
    <#
        Read-only listing for the Reports page. Never throws.
        Status: Ok | Unavailable (Reason as in availability) | Error (Detail).
    #>
    [CmdletBinding()]
    param()
    $av = Get-WcRestorePointAvailability
    $result = [pscustomobject]@{ Status = 'Ok'; Reason = ''; Detail = $null; ProtectionEnabled = $av.ProtectionEnabled; FrequencyMinutes = $av.FrequencyMinutes; Points = @() }
    # Listing works whenever the cmdlet exists and the session is elevated, even if protection is now off.
    if (@('not-windows', 'powershell-edition', 'cmdlet-missing', 'server-sku', 'requires-admin') -contains $av.Reason) {
        $result.Status = 'Unavailable'; $result.Reason = $av.Reason
        return $result
    }
    if ($av.Reason -and -not (Test-WcIsAdmin)) { $result.Status = 'Unavailable'; $result.Reason = 'requires-admin'; return $result }
    try { $result.Points = @(ConvertTo-WcRestorePointRow -RestorePoint @(Get-WcComputerRestorePointRaw)) }
    catch { $result.Status = 'Error'; $result.Reason = 'error'; $result.Detail = $_.Exception.Message }
    return $result
}

# --------------------------------------------------- restore point creation --

function Get-WcRestorePointDescription {
    <# Pure: fixed ASCII description, no free text from outside. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $PlanId, [string] $ActionId)
    $p = ([string]$PlanId -replace '[^A-Za-z0-9\-]', '')
    if ($p.Length -gt 8) { $p = $p.Substring(0, 8) }
    $a = ([string]$ActionId -replace '[^a-z0-9\.\-]', '')
    if ($a.Length -gt 60) { $a = $a.Substring(0, 60) }
    return ('WinCare plan {0} before {1}' -f $p, $a)
}

function Invoke-WcCheckpointComputer {
    <# Thin I/O (mocked in tests). Returns the warning messages Checkpoint-Computer produced. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9 \.\-]{1,100}$')][string] $Description)
    $warnings = @()
    if ([string]$PSVersionTable['PSEdition'] -ne 'Desktop') {
        # PowerShell 7: run the 5.1-only cmdlet in powershell.exe. $Description is limited by
        # ValidatePattern to letters, digits, space, dot and dash, so it cannot break the quotes.
        $script = 'try {{ $w = @(); Checkpoint-Computer -Description ''{0}'' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable w; ConvertTo-Json -Compress -InputObject @($w | ForEach-Object {{ [string]$_ }}) }} catch {{ [Console]::Error.WriteLine($_.Exception.Message); exit 1 }}' -f $Description
        return @(Invoke-WcDesktopPowerShell -Script $script | ForEach-Object { [string]$_ })
    }
    Checkpoint-Computer -Description $Description -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue -WarningVariable warnings
    return @($warnings | ForEach-Object { [string]$_ })
}

function New-WcRestorePoint {
    <#
        Creates a restore point if, and only if, System Protection is already enabled on the
        system drive. Returns a Core restore point outcome (New-WcRestorePointOutcome); never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Description)
    try {
        $av = Get-WcRestorePointAvailability
        if (-not $av.Available) {
            return (New-WcRestorePointOutcome -Status Unavailable -Reason $av.Reason -Detail ('System Restore not usable ({0}). WinCare never enables System Protection.' -f $av.Reason))
        }
        $existing = @(ConvertTo-WcRestorePointRow -RestorePoint @(Get-WcComputerRestorePointRaw))
        $recent = Select-WcRecentRestorePoint -Row $existing -NowUtc (Get-Date).ToUniversalTime() -FrequencyMinutes $av.FrequencyMinutes
        if ($recent) {
            return (New-WcRestorePointOutcome -Status Skipped -Reason 'created-recently' -SequenceNumber $recent.SequenceNumber -CreationTime $recent.Created -Description $recent.Description -Detail ('Restore point #{0} was created within the last {1} minutes; Windows allows one per window and WinCare does not change that setting.' -f $recent.SequenceNumber, $av.FrequencyMinutes))
        }
        $maxBefore = 0L
        foreach ($e in $existing) { if ($e.SequenceNumber -gt $maxBefore) { $maxBefore = $e.SequenceNumber } }
        Write-WcLog -Level Audit -Category 'RestorePoint' -Message ('Creating restore point: ' + $Description) | Out-Null
        $warnings = @(Invoke-WcCheckpointComputer -Description $Description)
        $after = @(ConvertTo-WcRestorePointRow -RestorePoint @(Get-WcComputerRestorePointRaw))
        $new = @($after | Where-Object { $_.SequenceNumber -gt $maxBefore }) | Select-Object -First 1
        if ($new) {
            return (New-WcRestorePointOutcome -Status Created -SequenceNumber $new.SequenceNumber -CreationTime $new.Created -Description $new.Description -Detail 'Restore point created.')
        }
        $warnText = (@($warnings | ForEach-Object { @($_) -join ' ' }) -join ' ').Trim()
        if ($warnText -match '(?i)1440|already been created|within the past') {
            return (New-WcRestorePointOutcome -Status Skipped -Reason 'created-recently' -Detail $warnText)
        }
        $detail = 'Checkpoint-Computer returned but no new restore point was found.'
        if ($warnText) { $detail = $detail + ' ' + $warnText }
        return (New-WcRestorePointOutcome -Status Failed -Reason 'not-verified' -Detail $detail)
    }
    catch {
        return (New-WcRestorePointOutcome -Status Failed -Reason 'error' -Detail $_.Exception.Message)
    }
}

# ---------------------------------------------------------------- handlers --

function Register-WcBaselineHandler {
    <# Called lazily by Core (Initialize-WcActionHandlers). Registers the F5 plan hooks; no actions. #>
    [CmdletBinding()]
    param()
    Register-WcPlanHook -Name Measure -ScriptBlock { param($Context) Measure-WcSystemFreeSpace }
    Register-WcPlanHook -Name RestorePoint -ScriptBlock { param($Plan, $Item) New-WcRestorePoint -Description (Get-WcRestorePointDescription -PlanId $Plan.Id -ActionId $Item.ActionId) }
}

Export-ModuleMember -Function @('Register-WcBaselineHandler',
    'Get-WcFixedDriveRaw', 'ConvertTo-WcFreeSpaceMetric', 'Measure-WcSystemFreeSpace',
    'ConvertFrom-WcDmtfDate', 'ConvertTo-WcRestorePointRow', 'Select-WcRecentRestorePoint', 'Test-WcVolumeProtected',
    'ConvertTo-WcRestorePointAvailability', 'Get-WcRestorePointFacts', 'Get-WcRestorePointAvailability',
    'Get-WcDesktopPowerShellPath', 'Invoke-WcDesktopPowerShell', 'Get-WcComputerRestorePointRaw', 'Get-WcRestorePoint', 'Get-WcRestorePointDescription', 'Invoke-WcCheckpointComputer', 'New-WcRestorePoint'
)
