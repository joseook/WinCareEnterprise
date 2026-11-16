#Requires -Version 5.1
<#
    WinCare.Health - "System health" analysis page (page id 'health', F6).
    Contract: docs/CONTRATO-ACOES.md section 6. Everything here is READ-ONLY.

    Sections (Get-WcHealthPageData):
      critical-events   Kernel-Power 41, EventLog 6008, BugCheck 1001, disk 7/11/51/153,
                        Ntfs 55/98 (Warning or worse), WHEA-Logger - grouped, never message text
      app-crashes       Application Error 1000 / Windows Error Reporting 1001, grouped by program
      devices           Win32_PnPEntity with ConfigManagerErrorCode <> 0 + documented meaning
      disks             Get-PhysicalDisk + Get-StorageReliabilityCounter (often needs admin)
      startup-tasks     non-Microsoft scheduled tasks with a logon/boot trigger (information only)
      startup-services  auto-start services whose binary is outside %windir% and not Microsoft-signed
      battery           design vs full-charge capacity (root\wmi, then Win32_Battery)
      updates           last install (WU history + Win32_QuickFixEngineering), restart required
      time-uptime       uptime, W32Time service and configured time source (registry)

    Windows Update is a protected feature: this module only READS its history and the
    restart-required flag. Nothing here clears event logs, disables tasks or services, or
    touches drivers. w32tm is not used (needs admin, localized output).

    Pattern: Get-* thin I/O (mocked in tests) + ConvertTo-*/Test-* pure (Linux unit tests).
    Row texts come from Localization/<lang>.d/f6-health.json when loaded, with an English
    fallback so the page data is still readable in a runspace without strings.
#>

$script:WcHealthSigCache = @{}
$script:WcHealthThreshold = @{
    StaleUpdateDays = 60; LongUptimeDays = 30; BatteryWearWarn = 40; SsdWearWarn = 80
    DiskTempWarnC = 70; MaxRowsPerSection = 200
}

# English fallback for ConfigManagerErrorCode (Microsoft "Device Manager error messages").
$script:WcPnpCodes = @{
    1 = 'Not configured correctly'; 3 = 'Driver may be corrupted or the system is low on memory'
    10 = 'Device cannot start'; 12 = 'Not enough free resources'; 14 = 'Restart required'
    16 = 'Windows cannot identify all resources'; 18 = 'Reinstall the drivers'
    19 = 'Configuration in the registry is incomplete or damaged'; 21 = 'Windows is removing the device'
    22 = 'Device is disabled'; 24 = 'Device not present, not working or missing drivers'
    28 = 'Drivers are not installed'; 29 = 'Disabled by the firmware'
    31 = 'Windows cannot load the drivers'; 32 = 'Driver (service) is disabled'
    33 = 'Cannot determine required resources'; 34 = 'Cannot determine device settings'
    35 = 'Firmware lacks required information'; 36 = 'IRQ translation failed'
    37 = 'Driver failed to initialize'; 38 = 'Previous driver instance still in memory'
    39 = 'Driver is corrupted or missing'; 40 = 'Driver service key is missing or incorrect'
    41 = 'Driver loaded but the hardware was not found'; 42 = 'Duplicate device'
    43 = 'Device reported problems and was stopped'; 44 = 'Shut down by an application or service'
    45 = 'Device is not connected'; 46 = 'Windows is shutting down'; 47 = 'Prepared for safe removal'
    48 = 'Driver blocked (known problems)'; 49 = 'Registry size limit exceeded'
    50 = 'Cannot apply all properties'; 51 = 'Waiting on another device'
    52 = 'Driver digital signature cannot be verified'; 53 = 'Reserved by the kernel debugger'
    54 = 'Failed and is being reset'; 56 = 'Still setting up the class configuration'
}
# Codes that describe a state the user chose or a transient condition, not a fault.
$script:WcPnpInfoCodes = @(14, 21, 22, 45, 46, 47, 53)

$script:WcHealthCategoryText = @{
    UnexpectedShutdown = 'Unexpected shutdown'; BugCheck = 'Blue screen (bugcheck)'
    Disk = 'Disk / file system error'; Whea = 'Hardware error (WHEA)'
}
$script:WcCrashEventNames = @('APPCRASH', 'BEX', 'BEX64', 'AppHangB1', 'AppHangXProcB1', 'MoAppCrash', 'MoAppHang')

# --------------------------------------------------------------- helpers --

function Get-WcHealthText {
    <# Localized text when strings are loaded; English fallback otherwise. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Key, [string] $Fallback = '', [object[]] $Arguments)
    $text = $null
    try { $text = Get-WcLocalizedValue -Key $Key } catch { $text = $null }
    if ($text -isnot [string] -or -not $text) { $text = $Fallback }
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) { return ($text -f $Arguments) }
    return $text
}

function Format-WcHealthDate {
    <# Short local date for display ('' when missing). Unspecified kind is shown as is. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return '' }
    $d = [datetime]$Value
    if ($d.Kind -eq [System.DateTimeKind]::Utc) { $d = $d.ToLocalTime() }
    return $d.ToString('yyyy-MM-dd HH:mm', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-WcHealthBytes {
    [CmdletBinding()]
    [OutputType([string])]
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    $b = [double]$Bytes
    foreach ($u in @(@('TB', 1TB), @('GB', 1GB), @('MB', 1MB), @('KB', 1KB))) {
        if ($b -ge $u[1]) { return ('{0} {1}' -f [math]::Round($b / $u[1], 1).ToString([System.Globalization.CultureInfo]::InvariantCulture), $u[0]) }
    }
    return ('{0} B' -f $b)
}

function New-WcHealthSection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [object[]] $Rows = @(),
        [ValidateSet('Info', 'Warning', 'Critical')][string] $Severity = 'Info',
        [string] $NoteKey
    )
    if (-not $NoteKey) { $NoteKey = 'section.health.' + $Id + '.note' }
    return [pscustomobject]@{ Id = $Id; TitleKey = 'section.health.' + $Id; NoteKey = $NoteKey; Rows = @($Rows); Severity = $Severity }
}

function New-WcHealthFinding {
    <# Same shape as WinCare.Diagnostics findings (keys finding.<id>.title/.recommendation). #>
    param([string] $Id, [ValidateSet('Info', 'Warning', 'Critical')][string] $Severity, [object[]] $Evidence)
    return [pscustomobject]@{
        Id = $Id; Severity = $Severity; TitleKey = "finding.$Id.title"; RecommendationKey = "finding.$Id.recommendation"; Evidence = $Evidence
    }
}

function Get-WcHealthReportDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-Path (Get-WcDataRoot) 'reports')
}

function Test-WcHealthPathUnder {
    <# Pure, Windows path semantics on any host: Path is Root or inside it (case-insensitive, no '..'). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Path, [string] $Root)
    if (-not $Path -or -not $Root) { return $false }
    $p = $Path.Replace('/', '\')
    $r = $Root.Replace('/', '\').TrimEnd('\')
    if (-not $r -or $p -match '(^|\\)\.\.(\\|$)') { return $false }
    if ($p.Equals($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $p.StartsWith($r + '\', [System.StringComparison]::OrdinalIgnoreCase)
}

# ---------------------------------------------------------------- events --

function Get-WcHealthEventQuery {
    <# Pure: one FilterHashtable per category, capped with MaxEvents. #>
    [CmdletBinding()]
    param([ValidateRange(1, 90)][int] $Days = 7, [datetime] $Now = (Get-Date))
    $start = $Now.AddDays(-$Days)
    return @(
        @{ Category = 'UnexpectedShutdown'; MaxEvents = 200; Filter = @{ LogName = 'System'; Id = @(41, 6008); StartTime = $start } }
        @{ Category = 'BugCheck'; MaxEvents = 100; Filter = @{ LogName = 'System'; Id = @(1001); StartTime = $start } }
        @{ Category = 'Disk'; MaxEvents = 300; Filter = @{ LogName = 'System'; Id = @(7, 11, 51, 153, 55, 98); Level = @(1, 2, 3); StartTime = $start } }
        @{ Category = 'Whea'; MaxEvents = 200; Filter = @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Level = @(1, 2, 3); StartTime = $start } }
        @{ Category = 'AppCrash'; MaxEvents = 500; Filter = @{ LogName = 'Application'; Id = @(1000, 1001); StartTime = $start } }
    )
}

function Get-WcHealthEventCategory {
    <#
        Pure classification by provider + id (+ level). Returns the category or $null.
        Data = first event properties as strings. ASSUMPTION (documented WER layout, not
        verified on every build): WER 1001 Data[2] = event name, Data[5] = P1 (program).
    #>
    [CmdletBinding()]
    param([string] $ProviderName, [int] $Id, $Level, [object[]] $Data = @())
    $p = [string]$ProviderName
    $lvl = 4
    if ($null -ne $Level -and [string]$Level -ne '') { $lvl = [int]$Level }
    if ($p -eq 'Microsoft-Windows-Kernel-Power' -and $Id -eq 41) { return 'UnexpectedShutdown' }
    if ($p -eq 'EventLog' -and $Id -eq 6008) { return 'UnexpectedShutdown' }
    if (@('Microsoft-Windows-WER-SystemErrorReporting', 'BugCheck') -contains $p -and $Id -eq 1001) { return 'BugCheck' }
    if ($p -eq 'disk' -and @(7, 11, 51, 153) -contains $Id) { return 'Disk' }
    if (@('Ntfs', 'Microsoft-Windows-Ntfs') -contains $p -and @(55, 98) -contains $Id -and $lvl -ge 1 -and $lvl -le 3) { return 'Disk' }
    if ($p -eq 'Microsoft-Windows-WHEA-Logger' -and $lvl -ge 1 -and $lvl -le 3) { return 'Whea' }
    if ($p -eq 'Application Error' -and $Id -eq 1000) { return 'AppCrash' }
    if ($p -eq 'Windows Error Reporting' -and $Id -eq 1001) {
        $name = ''
        if (@($Data).Count -gt 2) { $name = [string]@($Data)[2] }
        if ($script:WcCrashEventNames -contains $name) { return 'AppCrash' }
    }
    return $null
}

function ConvertTo-WcHealthProgramName {
    <# Pure: file name only (never a full path that could reveal a user folder), max 64 chars. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    $s = ([string]$Value).Trim()
    if ($s) { $s = @($s -split '[\\/]')[-1].Trim() }
    if (-not $s) { return '(unknown)' }
    if ($s.Length -gt 64) { $s = $s.Substring(0, 64) }
    return $s
}

function ConvertTo-WcHealthEventSummary {
    <#
        Pure: raw events (ProviderName, Id, Level, TimeCreated, Data[]) -> grouped rows.
        Critical rows: one per category + source + event id. Crash rows: one per program,
        with Application Error 1000 and WER 1001 counted separately (one crash usually
        produces both, so they are not added together).
    #>
    [CmdletBinding()]
    param([object[]] $Event = @(), [int] $Days = 7)
    $groups = @{}; $crash = @{}
    $totals = @{ UnexpectedShutdown = 0; BugCheck = 0; Disk = 0; Whea = 0; AppCrash = 0 }
    foreach ($e in @($Event)) {
        if ($null -eq $e) { continue }
        $prov = [string](Get-WcObjectValue $e 'ProviderName')
        $id = 0; [void][int]::TryParse([string](Get-WcObjectValue $e 'Id'), [ref]$id)
        $data = @(Get-WcObjectValue $e 'Data')
        $cat = Get-WcHealthEventCategory -ProviderName $prov -Id $id -Level (Get-WcObjectValue $e 'Level') -Data $data
        if (-not $cat) { continue }
        $totals[$cat]++
        $t = Get-WcObjectValue $e 'TimeCreated'
        $when = $null; if ($null -ne $t) { $when = [datetime]$t }
        if ($cat -eq 'AppCrash') {
            $prog = $null
            if ($prov -eq 'Application Error') { if ($data.Count -gt 0) { $prog = $data[0] } }
            elseif ($data.Count -gt 5) { $prog = $data[5] }
            $name = ConvertTo-WcHealthProgramName $prog
            $k = $name.ToLowerInvariant()
            if (-not $crash.ContainsKey($k)) { $crash[$k] = @{ Program = $name; Crashes = 0; WerReports = 0; Last = $null } }
            $g = $crash[$k]
            if ($prov -eq 'Application Error') { $g.Crashes++ } else { $g.WerReports++ }
            if ($null -ne $when -and ($null -eq $g.Last -or $when -gt $g.Last)) { $g.Last = $when }
            continue
        }
        $k = '{0}|{1}|{2}' -f $cat, $prov, $id
        if (-not $groups.ContainsKey($k)) { $groups[$k] = @{ Category = $cat; Source = $prov; EventId = $id; Count = 0; First = $null; Last = $null; Codes = @() } }
        $g = $groups[$k]
        $g.Count++
        if ($null -ne $when) {
            if ($null -eq $g.First -or $when -lt $g.First) { $g.First = $when }
            if ($null -eq $g.Last -or $when -gt $g.Last) { $g.Last = $when }
        }
        if ($cat -eq 'BugCheck' -and $data.Count -gt 0) {
            $m = [regex]::Match([string]$data[0], '^\s*(0x[0-9A-Fa-f]{1,16})')
            if ($m.Success -and $g.Codes -notcontains $m.Groups[1].Value -and $g.Codes.Count -lt 3) { $g.Codes += $m.Groups[1].Value }
        }
    }
    $rows = @(foreach ($g in $groups.Values) {
            $label = Get-WcHealthText -Key ('health.category.' + $g.Category) -Fallback $script:WcHealthCategoryText[$g.Category]
            $raw = ''; if ($null -ne $g.Last) { $raw = $g.Last.ToString('s') }
            [pscustomobject]@{
                EventCategory = $label; Source = $g.Source; EventId = $g.EventId; Events = $g.Count
                FirstSeen = Format-WcHealthDate $g.First; LastSeen = Format-WcHealthDate $g.Last
                Detail = ($g.Codes -join ', '); LastSeenRaw = $raw
            }
        })
    $crashRows = @(foreach ($g in $crash.Values) {
            $raw = ''; if ($null -ne $g.Last) { $raw = $g.Last.ToString('s') }
            [pscustomobject]@{ Program = $g.Program; Crashes = $g.Crashes; WerReports = $g.WerReports; LastSeen = Format-WcHealthDate $g.Last; LastSeenRaw = $raw }
        })
    return [pscustomobject]@{
        Days      = $Days
        Rows      = @($rows | Sort-Object -Property LastSeenRaw -Descending)
        CrashRows = @($crashRows | Sort-Object -Property @{ Expression = { $_.Crashes + $_.WerReports }; Descending = $true }, @{ Expression = 'LastSeenRaw'; Descending = $true })
        Totals    = $totals
    }
}

function Get-WcHealthEventRaw {
    <#
        Thin: runs one query. "No events" is not an error. Only provider, id, level, time and
        the first 6 property values leave this function (no rendered message text).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable] $Query)
    $events = @()
    try { $events = @(Get-WinEvent -FilterHashtable $Query.Filter -MaxEvents $Query.MaxEvents -ErrorAction Stop) }
    catch {
        if ([string]$_.FullyQualifiedErrorId -like 'NoMatching*') { return @() }
        throw
    }
    $out = @()
    foreach ($e in $events) {
        $data = @()
        $props = @($e.Properties)
        for ($i = 0; $i -lt [math]::Min(6, $props.Count); $i++) { $data += [string]$props[$i].Value }
        $out += [pscustomobject]@{ ProviderName = $e.ProviderName; Id = $e.Id; Level = $e.Level; TimeCreated = $e.TimeCreated; Data = $data }
    }
    return $out
}

function Get-WcHealthEventData {
    <# Runs every query (one failing query does not stop the others) and summarizes. #>
    [CmdletBinding()]
    param([ValidateRange(1, 90)][int] $Days = 7)
    $all = @(); $errors = @()
    foreach ($q in (Get-WcHealthEventQuery -Days $Days)) {
        try { $all += @(Get-WcHealthEventRaw -Query $q) }
        catch { $errors += ('{0}: {1}' -f $q.Category, $_.Exception.Message) }
    }
    $s = ConvertTo-WcHealthEventSummary -Event $all -Days $Days
    $s | Add-Member -NotePropertyName Errors -NotePropertyValue $errors
    return $s
}

# --------------------------------------------------------------- devices --

function Get-WcPnpErrorMeaning {
    <# Pure: ConfigManagerErrorCode -> Text + Severity (Info for user/transient states). #>
    [CmdletBinding()]
    param([int] $Code)
    $fallback = 'Unknown problem code'
    if ($script:WcPnpCodes.ContainsKey($Code)) { $fallback = $script:WcPnpCodes[$Code] }
    $sev = 'Warning'
    if ($script:WcPnpInfoCodes -contains $Code) { $sev = 'Info' }
    return [pscustomobject]@{ Code = $Code; Text = (Get-WcHealthText -Key ('health.pnp.' + $Code) -Fallback $fallback); Severity = $sev }
}

function ConvertTo-WcHealthDeviceRows {
    [CmdletBinding()]
    param([object[]] $Device = @())
    $rows = @()
    foreach ($d in @($Device)) {
        if ($null -eq $d) { continue }
        $code = 0; [void][int]::TryParse([string](Get-WcObjectValue $d 'ConfigManagerErrorCode'), [ref]$code)
        if ($code -eq 0) { continue }
        $m = Get-WcPnpErrorMeaning -Code $code
        $name = [string](Get-WcObjectValue $d 'Name')
        if (-not $name) { $name = [string](Get-WcObjectValue $d 'Description') }
        $rows += [pscustomobject]@{ Name = $name; DeviceClass = [string](Get-WcObjectValue $d 'PNPClass'); ErrorCode = $code; Meaning = $m.Text; SeverityRaw = $m.Severity }
    }
    return @($rows | Sort-Object -Property @{ Expression = { if ($_.SeverityRaw -eq 'Warning') { 0 } else { 1 } } }, Name)
}

function Get-WcHealthDevice {
    [CmdletBinding()]
    param()
    $raw = Get-WcCimData -ClassName 'Win32_PnPEntity' -Filter 'ConfigManagerErrorCode <> 0'
    return @(ConvertTo-WcHealthDeviceRows -Device $raw)
}

# ----------------------------------------------------------------- disks --

function ConvertTo-WcDiskHealthText {
    <# Pure: HealthStatus as string or MSFT_PhysicalDisk code (0 Healthy, 1 Warning, 2 Unhealthy, 5 Unknown). #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return 'Unknown' }
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n)) {
        $map = @{ 0 = 'Healthy'; 1 = 'Warning'; 2 = 'Unhealthy'; 5 = 'Unknown' }
        if ($map.ContainsKey($n)) { return $map[$n] }
        return [string]$n
    }
    return [string]$Value
}

function ConvertTo-WcDiskOperationalText {
    <# Pure: OperationalStatus (string(s) or CIM codes) -> 'OK' / 'Degraded, ...'. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    $map = @{ 1 = 'Other'; 2 = 'OK'; 3 = 'Degraded'; 4 = 'Stressed'; 5 = 'Predictive Failure'; 6 = 'Error'; 7 = 'Non-Recoverable Error'
        8 = 'Starting'; 9 = 'Stopping'; 10 = 'Stopped'; 11 = 'In Service'; 12 = 'No Contact'; 13 = 'Lost Communication'
    }
    $parts = @()
    foreach ($v in @($Value)) {
        if ($null -eq $v -or [string]$v -eq '') { continue }
        $n = 0
        if ([int]::TryParse([string]$v, [ref]$n) -and $map.ContainsKey($n)) { $parts += $map[$n] } else { $parts += [string]$v }
    }
    if ($parts.Count -eq 0) { return 'Unknown' }
    return ($parts -join ', ')
}

function ConvertTo-WcHealthDiskRows {
    <#
        Pure. Entry = @{ Disk; Counter; CounterStatus = Ok|RequiresAdmin|Unavailable }.
        Returns rows + the names of disks that need attention.
    #>
    [CmdletBinding()]
    param([object[]] $Entry = @(), [hashtable] $Threshold = $script:WcHealthThreshold)
    $mediaMap = @{ 0 = 'Unspecified'; 3 = 'HDD'; 4 = 'SSD'; 5 = 'SCM' }
    $busMap = @{ 1 = 'SCSI'; 3 = 'ATA'; 7 = 'USB'; 8 = 'RAID'; 10 = 'SAS'; 11 = 'SATA'; 12 = 'SD'; 15 = 'FileBackedVirtual'; 17 = 'NVMe' }
    $rows = @(); $bad = @(); $warn = @()
    foreach ($en in @($Entry)) {
        if ($null -eq $en) { continue }
        $d = Get-WcObjectValue $en 'Disk'
        if ($null -eq $d) { continue }
        $c = Get-WcObjectValue $en 'Counter'
        $status = [string](Get-WcObjectValue $en 'CounterStatus')
        $name = [string](Get-WcObjectValue $d 'FriendlyName')
        $media = Get-WcObjectValue $d 'MediaType'
        $n = 0
        if ($null -ne $media -and [int]::TryParse([string]$media, [ref]$n)) { if ($mediaMap.ContainsKey($n)) { $media = $mediaMap[$n] } else { $media = [string]$n } }
        $bus = Get-WcObjectValue $d 'BusType'
        if ($null -ne $bus -and [int]::TryParse([string]$bus, [ref]$n)) { if ($busMap.ContainsKey($n)) { $bus = $busMap[$n] } else { $bus = [string]$n } }
        $health = ConvertTo-WcDiskHealthText (Get-WcObjectValue $d 'HealthStatus')
        $oper = ConvertTo-WcDiskOperationalText (Get-WcObjectValue $d 'OperationalStatus')
        $size = Get-WcObjectValue $d 'Size'
        $wear = $null; $temp = $null; $tempMax = $null; $rErr = $null; $wErr = $null
        if ($status -eq 'Ok' -and $null -ne $c) {
            $wear = Get-WcObjectValue $c 'Wear'; $temp = Get-WcObjectValue $c 'Temperature'; $tempMax = Get-WcObjectValue $c 'TemperatureMax'
            $rErr = Get-WcObjectValue $c 'ReadErrorsUncorrected'; $wErr = Get-WcObjectValue $c 'WriteErrorsUncorrected'
        }
        $relText = switch ($status) {
            'Ok' { Get-WcHealthText -Key 'health.reliability.ok' -Fallback 'Read' }
            'RequiresAdmin' { Get-WcHealthText -Key 'health.reliability.requires-admin' -Fallback 'Requires admin' }
            default { Get-WcHealthText -Key 'health.reliability.unavailable' -Fallback 'Not available' }
        }
        $sev = 'Info'
        if (@('Warning', 'Unhealthy') -contains $health -or ($oper -ne 'OK' -and $oper -ne 'Unknown')) { $sev = 'Critical' }
        elseif (($null -ne $wear -and [double]$wear -ge $Threshold.SsdWearWarn) -or
            ($null -ne $rErr -and [double]$rErr -gt 0) -or ($null -ne $wErr -and [double]$wErr -gt 0) -or
            ($null -ne $temp -and [double]$temp -gt 0 -and (($null -ne $tempMax -and [double]$tempMax -gt 0 -and [double]$temp -ge [double]$tempMax) -or [double]$temp -ge $Threshold.DiskTempWarnC))) { $sev = 'Warning' }
        if ($sev -eq 'Critical') { $bad += $name } elseif ($sev -eq 'Warning') { $warn += $name }
        $sizeRaw = 0; if ($null -ne $size) { $sizeRaw = [double]$size }
        $rows += [pscustomobject]@{
            Name = $name; MediaType = [string]$media; BusType = [string]$bus; Size = Format-WcHealthBytes $size
            DiskHealth = $health; Operational = $oper; WearPercent = $wear; TemperatureC = $temp
            ReadErrors = $rErr; WriteErrors = $wErr; Reliability = $relText; SizeRaw = $sizeRaw; SeverityRaw = $sev
        }
    }
    return [pscustomobject]@{ Rows = $rows; Unhealthy = $bad; Attention = $warn }
}

function Get-WcHealthDiskRaw {
    <# Thin. Reliability counters often need admin: reported per disk, never thrown. #>
    [CmdletBinding()]
    param()
    $admin = Test-WcIsAdmin
    $out = @()
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $c = $null; $st = 'Unavailable'
        try {
            $c = Get-StorageReliabilityCounter -PhysicalDisk $d -ErrorAction Stop
            if ($null -ne $c) { $st = 'Ok' }
        }
        catch {
            if (-not $admin) { $st = 'RequiresAdmin' }
            Write-WcLog -Level Warning -Category 'Health' -Message ('Reliability counter unavailable: {0}' -f $_.Exception.Message) | Out-Null
        }
        if ($null -eq $c -and -not $admin) { $st = 'RequiresAdmin' }
        $out += [pscustomobject]@{ Disk = $d; Counter = $c; CounterStatus = $st }
    }
    return $out
}

# --------------------------------------------------------------- startup --

function Test-WcHealthMicrosoftTaskPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $TaskPath)
    return ([string]$TaskPath).StartsWith('\Microsoft\', [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-WcHealthStartupTrigger {
    <# Pure: trigger CIM class names -> 'Logon'/'Boot' (other triggers ignored). #>
    [CmdletBinding()]
    param([object[]] $TriggerType = @())
    $out = @()
    foreach ($t in @($TriggerType)) {
        switch -Regex ([string]$t) {
            'LogonTrigger$' { if ($out -notcontains 'Logon') { $out += 'Logon' } }
            'BootTrigger$' { if ($out -notcontains 'Boot') { $out += 'Boot' } }
        }
    }
    return $out
}

function Select-WcHealthStartupTask {
    <# Pure: tasks with a logon/boot trigger, excluding \Microsoft\ unless -IncludeMicrosoft. #>
    [CmdletBinding()]
    param([object[]] $Task = @(), [switch] $IncludeMicrosoft)
    $out = @()
    foreach ($t in @($Task)) {
        if ($null -eq $t) { continue }
        if (-not $IncludeMicrosoft -and (Test-WcHealthMicrosoftTaskPath ([string](Get-WcObjectValue $t 'TaskPath')))) { continue }
        if (@(Get-WcHealthStartupTrigger -TriggerType @(Get-WcObjectValue $t 'TriggerTypes')).Count -eq 0) { continue }
        $out += $t
    }
    return $out
}

function ConvertTo-WcTaskResultText {
    <# Pure: LastTaskResult -> readable text (documented SCHED_S_* codes; others as hex). #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($null -eq $Value -or [string]$Value -eq '') { return '' }
    $n = [int64]$Value
    $hex = '0x{0:X}' -f ($n -band 0xFFFFFFFFL)
    $known = @{ 0L = @('health.task.result.ok', 'Success'); 0x41300L = @('health.task.result.ready', 'Ready'); 0x41301L = @('health.task.result.running', 'Running')
        0x41303L = @('health.task.result.not-run', 'Has not run yet'); 0x41306L = @('health.task.result.terminated', 'Terminated by user')
    }
    $k = $n -band 0xFFFFFFFFL
    if ($known.ContainsKey($k)) { return ('{0} ({1})' -f (Get-WcHealthText -Key $known[$k][0] -Fallback $known[$k][1]), $hex) }
    return $hex
}

function ConvertTo-WcHealthTaskRows {
    <# Pure. Task: TaskPath, TaskName, Author, State, TriggerTypes, Actions; Info: hashtable 'path+name' -> LastRunTime/LastTaskResult. #>
    [CmdletBinding()]
    param([object[]] $Task = @(), [hashtable] $Info = @{})
    $rows = @()
    foreach ($t in @($Task)) {
        if ($null -eq $t) { continue }
        $path = [string](Get-WcObjectValue $t 'TaskPath'); $name = [string](Get-WcObjectValue $t 'TaskName')
        $trig = @(foreach ($tt in @(Get-WcHealthStartupTrigger -TriggerType @(Get-WcObjectValue $t 'TriggerTypes'))) { Get-WcHealthText -Key ('health.trigger.' + $tt.ToLowerInvariant()) -Fallback $tt })
        $i = $Info[$path + $name]
        $lastRun = ''; $lastResult = ''
        if ($null -ne $i) {
            $lr = Get-WcObjectValue $i 'LastRunTime'
            if ($null -ne $lr -and ([datetime]$lr).Year -ge 2000) { $lastRun = Format-WcHealthDate $lr }
            else { $lastRun = Get-WcHealthText -Key 'health.value.never' -Fallback 'Never' }
            $lastResult = ConvertTo-WcTaskResultText (Get-WcObjectValue $i 'LastTaskResult')
        }
        $rows += [pscustomobject]@{
            Name = $name; TaskPath = $path; Author = [string](Get-WcObjectValue $t 'Author'); Triggers = ($trig -join ', ')
            Path = (@(Get-WcObjectValue $t 'Actions') | Where-Object { $_ }) -join '; '; State = [string](Get-WcObjectValue $t 'State')
            LastRun = $lastRun; LastResult = $lastResult
        }
    }
    return @($rows | Sort-Object -Property TaskPath, Name)
}

function Get-WcHealthScheduledTaskRaw {
    <# Thin: Get-ScheduledTask simplified (executable only; arguments are not read). #>
    [CmdletBinding()]
    param()
    $out = @()
    foreach ($t in @(Get-ScheduledTask -ErrorAction Stop)) {
        $types = @(foreach ($tr in @($t.Triggers)) { if ($null -ne $tr) { $tr.CimClass.CimClassName } })
        $acts = @(foreach ($a in @($t.Actions)) {
                if ($null -eq $a) { continue }
                $exe = Get-WcObjectValue $a 'Execute'
                if ($exe) { [string]$exe } else { '(COM handler)' }
            })
        $out += [pscustomobject]@{ TaskPath = $t.TaskPath; TaskName = $t.TaskName; Author = $t.Author; State = [string]$t.State; TriggerTypes = $types; Actions = $acts }
    }
    return $out
}

function Get-WcHealthScheduledTaskInfo {
    <# Thin: last run/result for the selected tasks only. #>
    [CmdletBinding()]
    param([object[]] $Task = @())
    $info = @{}
    foreach ($t in @($Task)) {
        try {
            $i = Get-ScheduledTaskInfo -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop
            $info[[string]$t.TaskPath + [string]$t.TaskName] = [pscustomobject]@{ LastRunTime = $i.LastRunTime; LastTaskResult = $i.LastTaskResult }
        }
        catch { Write-WcLog -Level Warning -Category 'Health' -Message ('Task info unavailable: {0}' -f $_.Exception.Message) | Out-Null }
    }
    return $info
}

function ConvertTo-WcServiceBinaryPath {
    <#
        Pure: Win32_Service.PathName -> executable path. Handles quoted paths, unquoted
        paths with spaces (up to '.exe'), %VARS% (from -Environment), \SystemRoot\ and \??\.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $PathName, [string] $WindowsDir = 'C:\Windows', [hashtable] $Environment = @{})
    $s = ([string]$PathName).Trim()
    if (-not $s) { return '' }
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 1) { $s = $s.Substring(1, $end - 1) } else { $s = $s.Trim('"') }
    }
    else {
        $m = [regex]::Match($s, '^(.+?\.(exe|sys|dll))(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        if ($m.Success) { $s = $m.Groups[1].Value } else { $s = @($s -split '\s+')[0] }
    }
    $s = [regex]::Replace($s, '%([^%]+)%', {
            param($mm)
            $n = $mm.Groups[1].Value
            if ($n -ieq 'SystemRoot' -or $n -ieq 'windir') { return $WindowsDir }
            foreach ($k in $Environment.Keys) { if ($k -ieq $n) { return [string]$Environment[$k] } }
            return $mm.Value
        })
    if ($s.StartsWith('\??\')) { $s = $s.Substring(4) }
    if ($s -match '^\\SystemRoot\\') { $s = $WindowsDir.TrimEnd('\') + $s.Substring(11) }
    if ($s -imatch '^system32\\') { $s = $WindowsDir.TrimEnd('\') + '\' + $s }
    return $s
}

function ConvertTo-WcCertificateName {
    <# Pure: 'CN=Contoso Ltd, O=Contoso, ...' -> 'Contoso Ltd' (O= when no CN). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Subject)
    foreach ($attr in @('CN', 'O')) {
        $m = [regex]::Match([string]$Subject, '(?:^|,\s*)' + $attr + '=("[^"]*"|[^,]*)')
        if ($m.Success) { return $m.Groups[1].Value.Trim().Trim('"') }
    }
    return ''
}

function Test-WcMicrosoftSigner {
    <# Pure: valid signature whose subject organization is Microsoft Corporation. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Status, [string] $Subject)
    return ($Status -eq 'Valid' -and [string]$Subject -match '(^|,\s*)O="?Microsoft Corporation"?(,|$)')
}

function Get-WcHealthFileSignature {
    <# Thin, cached per path for the session. Status/Subject as strings. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    $key = $Path.ToLowerInvariant()
    if ($script:WcHealthSigCache.ContainsKey($key)) { return $script:WcHealthSigCache[$key] }
    $r = [pscustomobject]@{ Status = 'NotFound'; Subject = '' }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
            $subj = ''
            if ($null -ne $sig.SignerCertificate) { $subj = [string]$sig.SignerCertificate.Subject }
            $r = [pscustomobject]@{ Status = [string]$sig.Status; Subject = $subj }
        }
        catch { $r = [pscustomobject]@{ Status = 'Error'; Subject = '' } }
    }
    $script:WcHealthSigCache[$key] = $r
    return $r
}

function Clear-WcHealthSignatureCache { $script:WcHealthSigCache = @{} }

function Select-WcHealthThirdPartyService {
    <# Pure: auto-start services whose binary is outside the Windows folder. Adds BinaryPath. #>
    [CmdletBinding()]
    param([object[]] $Service = @(), [string] $WindowsDir = 'C:\Windows', [hashtable] $Environment = @{})
    $out = @()
    foreach ($s in @($Service)) {
        if ($null -eq $s) { continue }
        if ([string](Get-WcObjectValue $s 'StartMode') -ne 'Auto') { continue }
        $bin = ConvertTo-WcServiceBinaryPath -PathName ([string](Get-WcObjectValue $s 'PathName')) -WindowsDir $WindowsDir -Environment $Environment
        if (-not $bin -or (Test-WcHealthPathUnder -Path $bin -Root $WindowsDir)) { continue }
        $out += [pscustomobject]@{
            Name = [string](Get-WcObjectValue $s 'Name'); DisplayName = [string](Get-WcObjectValue $s 'DisplayName')
            State = [string](Get-WcObjectValue $s 'State'); BinaryPath = $bin
        }
    }
    return $out
}

function ConvertTo-WcHealthServiceRows {
    <# Pure. Signature: hashtable lower-case path -> Status/Subject. Microsoft-signed hidden unless -IncludeMicrosoft. #>
    [CmdletBinding()]
    param([object[]] $Service = @(), [hashtable] $Signature = @{}, [switch] $IncludeMicrosoft)
    $rows = @()
    foreach ($s in @($Service)) {
        if ($null -eq $s) { continue }
        $sig = $Signature[([string]$s.BinaryPath).ToLowerInvariant()]
        $st = 'Unknown'; $subj = ''
        if ($null -ne $sig) { $st = [string](Get-WcObjectValue $sig 'Status'); $subj = [string](Get-WcObjectValue $sig 'Subject') }
        if (-not $IncludeMicrosoft -and (Test-WcMicrosoftSigner -Status $st -Subject $subj)) { continue }
        $name = $s.DisplayName; if (-not $name) { $name = $s.Name }
        $rows += [pscustomobject]@{ Name = $name; ServiceName = $s.Name; Path = $s.BinaryPath; State = $s.State; SignedBy = (ConvertTo-WcCertificateName $subj); Signature = $st }
    }
    return @($rows | Sort-Object -Property Name)
}

function Get-WcHealthStartupService {
    [CmdletBinding()]
    param([switch] $IncludeMicrosoft)
    $win = $env:SystemRoot
    if (-not $win) { $win = 'C:\Windows' }
    $envMap = @{ ProgramFiles = $env:ProgramFiles; 'ProgramFiles(x86)' = ${env:ProgramFiles(x86)}; ProgramData = $env:ProgramData; SystemDrive = $env:SystemDrive }
    $svc = Get-WcCimData -ClassName 'Win32_Service' -Filter "StartMode='Auto'"
    if ($null -eq $svc) { throw 'Win32_Service query failed.' }
    $third = @(Select-WcHealthThirdPartyService -Service $svc -WindowsDir $win -Environment $envMap)
    $sigs = @{}
    foreach ($t in $third) { $sigs[$t.BinaryPath.ToLowerInvariant()] = Get-WcHealthFileSignature -Path $t.BinaryPath }
    return @(ConvertTo-WcHealthServiceRows -Service $third -Signature $sigs -IncludeMicrosoft:$IncludeMicrosoft)
}

# --------------------------------------------------------------- battery --

function Get-WcWearPercent {
    <# Pure: (1 - full/design) * 100, 1 decimal, never below 0; $null when unknown. #>
    [CmdletBinding()]
    param($DesignCapacity, $FullChargeCapacity)
    if ($null -eq $DesignCapacity -or $null -eq $FullChargeCapacity) { return $null }
    $d = [double]$DesignCapacity; $f = [double]$FullChargeCapacity
    if ($d -le 0 -or $f -le 0) { return $null }
    return [math]::Max(0, [math]::Round((1 - ($f / $d)) * 100, 1))
}

function ConvertTo-WcHealthBatteryRows {
    <#
        Pure. root\wmi BatteryStaticData (DesignedCapacity) + BatteryFullChargedCapacity
        (FullChargedCapacity) matched by InstanceName; Win32_Battery as fallback/presence.
    #>
    [CmdletBinding()]
    param([object[]] $StaticData = @(), [object[]] $FullCharge = @(), [object[]] $Win32Battery = @())
    $full = @{}
    foreach ($f in @($FullCharge)) { if ($null -ne $f) { $full[[string](Get-WcObjectValue $f 'InstanceName')] = Get-WcObjectValue $f 'FullChargedCapacity' } }
    $rows = @()
    foreach ($s in @($StaticData)) {
        if ($null -eq $s) { continue }
        $inst = [string](Get-WcObjectValue $s 'InstanceName')
        $design = Get-WcObjectValue $s 'DesignedCapacity'
        $fc = $full[$inst]
        $name = [string](Get-WcObjectValue $s 'DeviceName')
        if (-not $name) { $name = $inst }
        $rows += [pscustomobject]@{ Name = $name; DesignCapacity = $design; FullChargeCapacity = $fc; WearPercent = (Get-WcWearPercent $design $fc); Source = 'root\wmi' }
    }
    $w32 = @($Win32Battery | Where-Object { $null -ne $_ })
    if ($rows.Count -eq 0) {
        foreach ($b in $w32) {
            $design = Get-WcObjectValue $b 'DesignCapacity'; $fc = Get-WcObjectValue $b 'FullChargeCapacity'
            $name = [string](Get-WcObjectValue $b 'Name'); if (-not $name) { $name = [string](Get-WcObjectValue $b 'DeviceID') }
            $rows += [pscustomobject]@{ Name = $name; DesignCapacity = $design; FullChargeCapacity = $fc; WearPercent = (Get-WcWearPercent $design $fc); Source = 'Win32_Battery' }
        }
    }
    $max = $null
    foreach ($r in $rows) { if ($null -ne $r.WearPercent -and ($null -eq $max -or $r.WearPercent -gt $max)) { $max = $r.WearPercent } }
    return [pscustomobject]@{ HasBattery = ($rows.Count -gt 0); Rows = $rows; MaxWear = $max }
}

function Get-WcHealthBattery {
    [CmdletBinding()]
    param()
    $w32 = Get-WcCimData -ClassName 'Win32_Battery'
    $static = $null; $fc = $null
    if (@($w32 | Where-Object { $null -ne $_ }).Count -gt 0) {
        # root\wmi battery classes throw "not supported" on machines without a battery; only ask when one exists.
        $static = Get-WcCimData -ClassName 'BatteryStaticData' -Namespace 'root/wmi'
        $fc = Get-WcCimData -ClassName 'BatteryFullChargedCapacity' -Namespace 'root/wmi'
    }
    return (ConvertTo-WcHealthBatteryRows -StaticData $static -FullCharge $fc -Win32Battery $w32)
}

# --------------------------------------------------------- windows update --

function ConvertTo-WcHotFixDate {
    <# Pure: Win32_QuickFixEngineering.InstalledOn ('M/d/yyyy', yyyyMMdd or hex FILETIME) -> datetime/$null. #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    $s = ([string]$Value).Trim()
    if (-not $s) { return $null }
    if ($s -match '^[0-9A-Fa-f]{15,16}$') {
        try { return [datetime]::FromFileTimeUtc([Convert]::ToInt64($s, 16)) } catch { return $null }
    }
    $d = [datetime]::MinValue
    $fmts = [string[]]@('M/d/yyyy', 'MM/dd/yyyy', 'M/d/yyyy h:mm:ss tt', 'yyyyMMdd', 'yyyy-MM-dd')
    if ([datetime]::TryParseExact($s, $fmts, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    return $null
}

function ConvertTo-WcHealthUpdateRows {
    <#
        Pure. History: Date, Title, ResultCode (2 ok, 3 ok with errors, 4 failed), Operation (1 install).
        HotFix: HotFixID, InstalledOn. PendingReboot: IsPending, Sources (WinCare.System).
    #>
    [CmdletBinding()]
    param([object[]] $History = @(), [object[]] $HotFix = @(), $PendingReboot, [datetime] $Now = (Get-Date), [string] $HistoryError)
    $lastOk = $null; $lastTitle = ''; $failed = 0
    foreach ($h in @($History)) {
        if ($null -eq $h) { continue }
        $op = Get-WcObjectValue $h 'Operation'; $rc = [int](Get-WcObjectValue $h 'ResultCode'); $dt = Get-WcObjectValue $h 'Date'
        if ($null -ne $op -and [int]$op -ne 1) { continue }
        if ($rc -eq 4) { $failed++ }
        if (@(2, 3) -contains $rc -and $null -ne $dt -and ($null -eq $lastOk -or [datetime]$dt -gt $lastOk)) { $lastOk = [datetime]$dt; $lastTitle = [string](Get-WcObjectValue $h 'Title') }
    }
    $hfDate = $null; $hfId = ''
    foreach ($f in @($HotFix)) {
        if ($null -eq $f) { continue }
        $d = ConvertTo-WcHotFixDate (Get-WcObjectValue $f 'InstalledOn')
        if ($null -ne $d -and ($null -eq $hfDate -or $d -gt $hfDate)) { $hfDate = $d; $hfId = [string](Get-WcObjectValue $f 'HotFixID') }
    }
    $newest = $lastOk
    if ($null -ne $hfDate -and ($null -eq $newest -or $hfDate -gt $newest)) { $newest = $hfDate }
    $days = $null
    if ($null -ne $newest) { $days = [math]::Max(0, [int][math]::Floor(($Now - $newest).TotalDays)) }
    if ($lastTitle.Length -gt 120) { $lastTitle = $lastTitle.Substring(0, 120) }
    $none = Get-WcHealthText -Key 'health.value.unknown' -Fallback 'Unknown'
    $wuValue = $none
    if ($null -ne $lastOk) { $wuValue = ('{0} - {1}' -f (Format-WcHealthDate $lastOk), $lastTitle) }
    elseif ($HistoryError) { $wuValue = $none + ' (' + $HistoryError + ')' }
    $hfValue = $none; if ($null -ne $hfDate) { $hfValue = ('{0} - {1}' -f $hfDate.ToString('yyyy-MM-dd'), $hfId) }
    $daysValue = $none; if ($null -ne $days) { $daysValue = [string]$days }
    $yes = Get-WcHealthText -Key 'health.value.yes' -Fallback 'Yes'; $no = Get-WcHealthText -Key 'health.value.no' -Fallback 'No'
    $rebootValue = $none
    if ($null -ne $PendingReboot) {
        if ($PendingReboot.IsPending) { $rebootValue = $yes + ' (' + (@($PendingReboot.Sources) -join ', ') + ')' } else { $rebootValue = $no }
    }
    $rows = @(
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.update.last-success' -Fallback 'Last successful update'); Value = $wuValue; Source = 'Microsoft.Update.Session QueryHistory' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.update.newest-hotfix' -Fallback 'Newest installed hotfix'); Value = $hfValue; Source = 'Win32_QuickFixEngineering' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.update.days-since' -Fallback 'Days since last install'); Value = $daysValue; Source = 'WinCare' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.update.failed' -Fallback 'Failed installs in recent history'); Value = [string]$failed; Source = 'Microsoft.Update.Session QueryHistory' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.update.reboot' -Fallback 'Restart required'); Value = $rebootValue; Source = 'Registry (CBS, WindowsUpdate)' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.update.policy' -Fallback 'WinCare and Windows Update'); Value = (Get-WcHealthText -Key 'health.update.policy-value' -Fallback 'Read-only: WinCare never changes, pauses or resets Windows Update'); Source = 'WinCare' }
    )
    return [pscustomobject]@{ Rows = $rows; DaysSinceInstall = $days; Failed = $failed; RebootPending = ($null -ne $PendingReboot -and [bool]$PendingReboot.IsPending) }
}

function Get-WcHealthUpdateHistory {
    <# Thin, read-only: Windows Update Agent COM history (last -Count entries). #>
    [CmdletBinding()]
    param([ValidateRange(1, 200)][int] $Count = 30)
    $session = New-Object -ComObject 'Microsoft.Update.Session'
    $searcher = $session.CreateUpdateSearcher()
    $total = [int]$searcher.GetTotalHistoryCount()
    if ($total -le 0) { return @() }
    $out = @()
    foreach ($e in @($searcher.QueryHistory(0, [math]::Min($Count, $total)))) {
        if ($null -eq $e) { continue }
        $out += [pscustomobject]@{ Date = $e.Date; Title = [string]$e.Title; ResultCode = [int]$e.ResultCode; Operation = [int]$e.Operation }
    }
    return $out
}

function Get-WcHealthUpdate {
    [CmdletBinding()]
    param()
    $hist = @(); $histErr = $null
    try { $hist = @(Get-WcHealthUpdateHistory) } catch { $histErr = $_.Exception.Message }
    $hf = Get-WcCimData -ClassName 'Win32_QuickFixEngineering'
    $pr = $null
    try { $pr = Get-WcPendingReboot } catch { $pr = $null }
    return (ConvertTo-WcHealthUpdateRows -History $hist -HotFix $hf -PendingReboot $pr -HistoryError $histErr)
}

# ---------------------------------------------------------- time / uptime --

function ConvertTo-WcHealthTimeRows {
    <# Pure. TimeConfig: W32Time\Parameters Type/NtpServer. TimeService: Win32_Service W32Time. #>
    [CmdletBinding()]
    param($LastBootUpTime, [datetime] $Now = (Get-Date), [hashtable] $TimeConfig = @{}, $TimeService)
    $none = Get-WcHealthText -Key 'health.value.unknown' -Fallback 'Unknown'
    $uptimeDays = $null; $clockIssue = $false
    $upValue = $none; $bootValue = $none
    if ($null -ne $LastBootUpTime) {
        $boot = [datetime]$LastBootUpTime
        $bootValue = Format-WcHealthDate $boot
        $span = $Now - $boot
        if ($span.TotalSeconds -lt 0) { $clockIssue = $true; $upValue = Get-WcHealthText -Key 'health.time.boot-in-future' -Fallback 'Boot time is in the future: check the clock' }
        else { $uptimeDays = [math]::Round($span.TotalDays, 1); $upValue = ('{0}d {1}h {2}min' -f $span.Days, $span.Hours, $span.Minutes) }
    }
    $svcValue = $none
    if ($null -ne $TimeService) { $svcValue = ('{0} / {1}' -f [string](Get-WcObjectValue $TimeService 'State'), [string](Get-WcObjectValue $TimeService 'StartMode')) }
    $type = [string]$TimeConfig['Type']
    $typeText = switch ($type) {
        'NTP' { Get-WcHealthText -Key 'health.time.type.ntp' -Fallback 'NTP server' }
        'NT5DS' { Get-WcHealthText -Key 'health.time.type.nt5ds' -Fallback 'Domain hierarchy' }
        'AllSync' { Get-WcHealthText -Key 'health.time.type.allsync' -Fallback 'All available sources' }
        'NoSync' { Get-WcHealthText -Key 'health.time.type.nosync' -Fallback 'Not synchronized' }
        '' { $none }
        default { $type }
    }
    $server = [string]$TimeConfig['NtpServer']
    if (-not $server) { $server = $none }
    $rows = @(
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.time.uptime' -Fallback 'Uptime'); Value = $upValue; Source = 'Win32_OperatingSystem' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.time.last-boot' -Fallback 'Last boot'); Value = $bootValue; Source = 'Win32_OperatingSystem' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.time.service' -Fallback 'Windows Time service'); Value = $svcValue; Source = 'Win32_Service W32Time' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.time.sync-type' -Fallback 'Time synchronization'); Value = $typeText; Source = 'Registry W32Time\Parameters' }
        [pscustomobject]@{ Item = (Get-WcHealthText -Key 'health.time.ntp-server' -Fallback 'Time server'); Value = $server; Source = 'Registry W32Time\Parameters' }
    )
    return [pscustomobject]@{ Rows = $rows; UptimeDays = $uptimeDays; ClockIssue = $clockIssue; NoSync = ($type -eq 'NoSync') }
}

function Get-WcHealthTime {
    [CmdletBinding()]
    param()
    $os = Get-WcCimData -ClassName 'Win32_OperatingSystem' | Select-Object -First 1
    $svc = Get-WcCimData -ClassName 'Win32_Service' -Filter "Name='W32Time'" | Select-Object -First 1
    $cfg = Get-WcRegistryValues -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -Name @('Type', 'NtpServer')
    return (ConvertTo-WcHealthTimeRows -LastBootUpTime (Get-WcObjectValue $os 'LastBootUpTime') -TimeConfig $cfg -TimeService $svc)
}

# -------------------------------------------------------------- findings --

function Get-WcHealthFinding {
    <# Pure: metrics hashtable -> findings. Missing metrics produce nothing. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable] $Metric, [hashtable] $Threshold = $script:WcHealthThreshold)
    $out = @()
    $days = $Metric['Days']
    $t = $Metric['EventTotals']
    if ($null -ne $t) {
        if ($t['BugCheck'] -gt 0) { $out += New-WcHealthFinding -Id 'health-bugchecks' -Severity Critical -Evidence @($t['BugCheck'], $days) }
        if ($t['Disk'] -gt 0) { $out += New-WcHealthFinding -Id 'health-disk-errors' -Severity Critical -Evidence @($t['Disk'], $days) }
        if ($t['UnexpectedShutdown'] -gt 0) { $out += New-WcHealthFinding -Id 'health-unexpected-shutdowns' -Severity Warning -Evidence @($t['UnexpectedShutdown'], $days) }
        if ($t['Whea'] -gt 0) { $out += New-WcHealthFinding -Id 'health-whea-errors' -Severity Warning -Evidence @($t['Whea'], $days) }
    }
    foreach ($n in @($Metric['UnhealthyDisks'])) { if ($n) { $out += New-WcHealthFinding -Id 'health-disk-unhealthy' -Severity Critical -Evidence @($n) } }
    if ($null -ne $Metric['DeviceProblems'] -and $Metric['DeviceProblems'] -gt 0) { $out += New-WcHealthFinding -Id 'health-device-problems' -Severity Warning -Evidence @($Metric['DeviceProblems']) }
    if ($null -ne $Metric['BatteryWear'] -and $Metric['BatteryWear'] -ge $Threshold.BatteryWearWarn) { $out += New-WcHealthFinding -Id 'health-battery-worn' -Severity Warning -Evidence @($Metric['BatteryWear']) }
    if ($null -ne $Metric['DaysSinceUpdate'] -and $Metric['DaysSinceUpdate'] -ge $Threshold.StaleUpdateDays) { $out += New-WcHealthFinding -Id 'health-update-stale' -Severity Warning -Evidence @($Metric['DaysSinceUpdate']) }
    if ($null -ne $Metric['UptimeDays'] -and $Metric['UptimeDays'] -ge $Threshold.LongUptimeDays) { $out += New-WcHealthFinding -Id 'health-uptime-long' -Severity Info -Evidence @([int][math]::Floor($Metric['UptimeDays'])) }
    if ($Metric['ClockIssue']) { $out += New-WcHealthFinding -Id 'health-clock' -Severity Warning -Evidence @() }
    $rank = @{ Critical = 0; Warning = 1; Info = 2 }
    return @($out | Sort-Object -Property @{ Expression = { $rank[$_.Severity] } })
}

# ------------------------------------------------------------- page data --

function Get-WcHealthPageData {
    <#
        CONTRATO-ACOES.md section 6. Never throws: a failing section is listed in Errors and
        still appears (empty, note 'section.health.unavailable').
    #>
    [CmdletBinding()]
    param(
        $Context,
        [ValidateRange(1, 90)][int] $Days = 7,
        [switch] $IncludeMicrosoft
    )
    $sections = @(); $errors = @(); $metric = @{ Days = $Days }
    $max = $script:WcHealthThreshold.MaxRowsPerSection
    $fail = {
        param($Id, $Err)
        $script:WcHealthPageErrors += ('{0}: {1}' -f $Id, $Err.Exception.Message)
        New-WcHealthSection -Id $Id -Severity Warning -NoteKey 'section.health.unavailable'
    }
    $script:WcHealthPageErrors = @()

    try {
        $ev = Get-WcHealthEventData -Days $Days
        foreach ($e in @($ev.Errors)) { $script:WcHealthPageErrors += ('critical-events: ' + $e) }
        $metric['EventTotals'] = $ev.Totals
        $sev = 'Info'
        if ($ev.Totals['BugCheck'] -gt 0 -or $ev.Totals['Disk'] -gt 0) { $sev = 'Critical' }
        elseif ($ev.Totals['UnexpectedShutdown'] -gt 0 -or $ev.Totals['Whea'] -gt 0) { $sev = 'Warning' }
        $sections += New-WcHealthSection -Id 'critical-events' -Rows @($ev.Rows | Select-Object -First $max) -Severity $sev
        $cs = 'Info'; if ($ev.Totals['AppCrash'] -gt 0) { $cs = 'Warning' }
        $sections += New-WcHealthSection -Id 'app-crashes' -Rows @($ev.CrashRows | Select-Object -First $max) -Severity $cs
    }
    catch { $sections += & $fail 'critical-events' $_; $sections += & $fail 'app-crashes' $_ }

    try {
        $dev = @(Get-WcHealthDevice)
        $problems = @($dev | Where-Object { $_.SeverityRaw -eq 'Warning' }).Count
        $metric['DeviceProblems'] = $problems
        $s = 'Info'; if ($problems -gt 0) { $s = 'Warning' }
        $sections += New-WcHealthSection -Id 'devices' -Rows @($dev | Select-Object -First $max) -Severity $s
    }
    catch { $sections += & $fail 'devices' $_ }

    try {
        $dk = ConvertTo-WcHealthDiskRows -Entry @(Get-WcHealthDiskRaw)
        $metric['UnhealthyDisks'] = @($dk.Unhealthy)
        $s = 'Info'
        if (@($dk.Unhealthy).Count -gt 0) { $s = 'Critical' } elseif (@($dk.Attention).Count -gt 0) { $s = 'Warning' }
        $sections += New-WcHealthSection -Id 'disks' -Rows $dk.Rows -Severity $s
    }
    catch { $sections += & $fail 'disks' $_ }

    try {
        $sel = @(Select-WcHealthStartupTask -Task @(Get-WcHealthScheduledTaskRaw) -IncludeMicrosoft:$IncludeMicrosoft)
        $info = Get-WcHealthScheduledTaskInfo -Task $sel
        $sections += New-WcHealthSection -Id 'startup-tasks' -Rows @(ConvertTo-WcHealthTaskRows -Task $sel -Info $info | Select-Object -First $max)
    }
    catch { $sections += & $fail 'startup-tasks' $_ }

    try { $sections += New-WcHealthSection -Id 'startup-services' -Rows @(Get-WcHealthStartupService -IncludeMicrosoft:$IncludeMicrosoft | Select-Object -First $max) }
    catch { $sections += & $fail 'startup-services' $_ }

    try {
        $bat = Get-WcHealthBattery
        if (-not $bat.HasBattery) { $sections += New-WcHealthSection -Id 'battery' -NoteKey 'section.health.battery.none' }
        else {
            $metric['BatteryWear'] = $bat.MaxWear
            $s = 'Info'; if ($null -ne $bat.MaxWear -and $bat.MaxWear -ge $script:WcHealthThreshold.BatteryWearWarn) { $s = 'Warning' }
            $sections += New-WcHealthSection -Id 'battery' -Rows $bat.Rows -Severity $s
        }
    }
    catch { $sections += & $fail 'battery' $_ }

    try {
        $up = Get-WcHealthUpdate
        $metric['DaysSinceUpdate'] = $up.DaysSinceInstall
        $s = 'Info'; if ($null -ne $up.DaysSinceInstall -and $up.DaysSinceInstall -ge $script:WcHealthThreshold.StaleUpdateDays) { $s = 'Warning' }
        $sections += New-WcHealthSection -Id 'updates' -Rows $up.Rows -Severity $s
    }
    catch { $sections += & $fail 'updates' $_ }

    try {
        $tm = Get-WcHealthTime
        $metric['UptimeDays'] = $tm.UptimeDays; $metric['ClockIssue'] = $tm.ClockIssue
        $s = 'Info'; if ($tm.ClockIssue -or $tm.NoSync) { $s = 'Warning' }
        $sections += New-WcHealthSection -Id 'time-uptime' -Rows $tm.Rows -Severity $s
    }
    catch { $sections += & $fail 'time-uptime' $_ }

    $findings = @()
    try { $findings = @(Get-WcHealthFinding -Metric $metric) } catch { $script:WcHealthPageErrors += ('findings: ' + $_.Exception.Message) }
    $errors = @($script:WcHealthPageErrors)
    return [pscustomobject]@{ PageId = 'health'; Sections = $sections; Findings = $findings; Errors = $errors }
}

# ---------------------------------------------------------------- actions --

function Get-WcHealthToolPath {
    <# Absolute path of an in-box tool (Sysnative from a 32-bit host on 64-bit Windows). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][ValidateSet('powercfg.exe', 'perfmon.exe')][string] $Name)
    if (-not $env:SystemRoot) { throw 'SystemRoot is not defined.' }
    $dir = 'System32'
    if ([System.Environment]::Is64BitOperatingSystem -and -not [System.Environment]::Is64BitProcess) { $dir = 'Sysnative' }
    return ($env:SystemRoot.TrimEnd('\') + '\' + $dir + '\' + $Name)
}

function Test-WcHealthToolCommand {
    <#
        Pure. Returns $null when allowed, else the reason. Executable must be under
        <SystemRoot>\System32|Sysnative; each argument is a plain switch token or a path
        inside the reports folder (no quotes, no '..').
    #>
    [CmdletBinding()]
    param([string] $FilePath, [string[]] $ArgumentList = @(), [string] $SystemRoot, [string] $ReportsDir)
    if (-not $SystemRoot) { return 'SystemRoot is not defined.' }
    $ok = (Test-WcHealthPathUnder -Path $FilePath -Root ($SystemRoot.TrimEnd('\') + '\System32')) -or (Test-WcHealthPathUnder -Path $FilePath -Root ($SystemRoot.TrimEnd('\') + '\Sysnative'))
    if (-not $ok) { return "only absolute paths under %SystemRoot%\System32 are allowed: '$FilePath'" }
    foreach ($a in @($ArgumentList)) {
        if ($a -match '^[A-Za-z0-9:/\-\.]+$') { continue }
        if ($ReportsDir -and $a.IndexOf('"') -lt 0 -and (Test-WcHealthPathUnder -Path $a -Root $ReportsDir)) { continue }
        return "argument not allowed: '$a'"
    }
    return $null
}

function Invoke-WcHealthTool {
    <# Thin: runs powercfg (validated), captures output, enforces a timeout. Mocked in tests. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [ValidateRange(5, 600)][int] $TimeoutSeconds = 120
    )
    $why = Test-WcHealthToolCommand -FilePath $FilePath -ArgumentList $ArgumentList -SystemRoot $env:SystemRoot -ReportsDir (Get-WcHealthReportDir)
    if ($why) { throw "Refusing to run: $why" }
    if (-not [System.IO.File]::Exists($FilePath)) { throw "Executable not found: $FilePath" }
    $quoted = @(foreach ($a in $ArgumentList) { if ($a -match '\s') { '"' + $a + '"' } else { $a } })
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($quoted -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    Write-WcLog -Level Audit -Category 'Health' -Message ('Running: {0} {1}' -f $FilePath, $psi.Arguments) | Out-Null
    try {
        [void]$proc.Start()
        $outTask = $proc.StandardOutput.ReadToEndAsync()
        $errTask = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            try { $proc.Kill() } catch { Write-Verbose 'Process already exited.' }
            throw ('{0} did not finish in {1} s.' -f $FilePath, $TimeoutSeconds)
        }
        $proc.WaitForExit()
        Write-WcLog -Level Audit -Category 'Health' -Message ('Exit code {0}: {1}' -f $proc.ExitCode, $FilePath) | Out-Null
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = ([string]$outTask.Result).Trim(); StdErr = ([string]$errTask.Result).Trim() }
    }
    finally { $proc.Dispose() }
}

function Invoke-WcHealthPowerReport {
    <#
        Preview (default) or -Execute. Battery: powercfg /batteryreport /output <reports>\battery-report.html.
        Energy: powercfg /energy /output <reports>\energy-report.html /duration 60 (needs admin, ~60 s).
        Success = the report file was (re)written by this run; the exit code is reported as is
        (powercfg /energy may return non-zero when its analysis finds problems - unverified).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('Battery', 'Energy')][string] $Kind, [switch] $Execute)
    $dir = Get-WcHealthReportDir
    $exe = Get-WcHealthToolPath -Name 'powercfg.exe'
    if ($Kind -eq 'Battery') {
        $out = Join-Path $dir 'battery-report.html'
        $argList = @('/batteryreport', '/output', $out); $timeout = 60; $needsAdmin = $false; $dur = 'a few seconds'
    }
    else {
        $out = Join-Path $dir 'energy-report.html'
        $argList = @('/energy', '/output', $out, '/duration', '60'); $timeout = 180; $needsAdmin = $true; $dur = 'about 60 s'
    }
    $cmdText = ('{0} {1}' -f $exe, ($argList -join ' '))
    $item = [pscustomobject]@{ Command = $cmdText; Path = $out; RequiresAdmin = $needsAdmin; Duration = $dur }
    if (-not $Execute) {
        return (New-WcActionResult -Summary ('Would run: {0} (read-only; writes only the report file; {1}).' -f $cmdText, $dur) -Items @($item))
    }
    if ($needsAdmin -and -not (Test-WcIsAdmin)) { throw 'powercfg /energy requires an elevated (administrator) session.' }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $start = (Get-Date).AddSeconds(-2)
    $r = Invoke-WcHealthTool -FilePath $exe -ArgumentList $argList -TimeoutSeconds $timeout
    $fresh = (Test-Path -LiteralPath $out) -and ((Get-Item -LiteralPath $out).LastWriteTime -ge $start)
    $text = (@($r.StdOut, $r.StdErr) | Where-Object { $_ }) -join "`r`n"
    if (-not $fresh) {
        $first = @($text -split "`r?`n" | Where-Object { $_.Trim() })[0]
        throw ('powercfg did not write {0} (exit code {1}). {2}' -f $out, $r.ExitCode, $first)
    }
    return (New-WcActionResult -Summary ('Report saved: {0} (powercfg exit code {1}).' -f $out, $r.ExitCode) -Items @($item) -Output $text -ExitCode $r.ExitCode)
}

function Start-WcHealthReliabilityMonitor {
    <# Thin: opens Reliability Monitor for the user (perfmon /rel). Mocked in tests. #>
    [CmdletBinding()]
    param()
    $exe = Get-WcHealthToolPath -Name 'perfmon.exe'
    Write-WcLog -Level Audit -Category 'Health' -Message ('Opening Reliability Monitor: {0} /rel' -f $exe) | Out-Null
    Start-Process -FilePath $exe -ArgumentList @('/rel') | Out-Null
    return $exe
}

function Export-WcHealthEvent {
    <# Writes the summarized critical events + crashes (no message text) as JSON in the reports folder. #>
    [CmdletBinding()]
    param([ValidateRange(1, 90)][int] $Days = 7, [string] $Directory = (Get-WcHealthReportDir))
    $ev = Get-WcHealthEventData -Days $Days
    $path = Join-Path $Directory ('health-events-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
    $doc = [pscustomobject]@{
        Generated = (Get-Date).ToString('o'); Days = $Days; Totals = $ev.Totals
        CriticalEvents = @($ev.Rows); AppCrashes = @($ev.CrashRows); Errors = @($ev.Errors)
    }
    Write-WcTextFile -Path $path -Content ($doc | ConvertTo-Json -Depth 5)
    Write-WcLog -Level Audit -Category 'Health' -Message 'Health events exported.' -Data @{ path = $path } | Out-Null
    return [pscustomobject]@{ Path = $path; Events = @($ev.Rows).Count; Programs = @($ev.CrashRows).Count; Errors = @($ev.Errors) }
}

function Register-WcHealthHandler {
    <# Called lazily by Core (Initialize-WcActionHandlers). Every health action is read-only. #>
    [CmdletBinding()]
    param()
    Register-WcActionHandler -Name 'Health-BatteryReport' -Preview { param($Context) Invoke-WcHealthPowerReport -Kind Battery } -Execute { param($Context) Invoke-WcHealthPowerReport -Kind Battery -Execute }
    Register-WcActionHandler -Name 'Health-EnergyReport' -Preview { param($Context) Invoke-WcHealthPowerReport -Kind Energy } -Execute { param($Context) Invoke-WcHealthPowerReport -Kind Energy -Execute }
    Register-WcActionHandler -Name 'Health-ReliabilityOpen' -Preview {
        param($Context)
        New-WcActionResult -Summary 'Would open Reliability Monitor (perfmon /rel). Nothing is changed.'
    } -Execute {
        param($Context)
        $exe = Start-WcHealthReliabilityMonitor
        New-WcActionResult -Summary ('Opened Reliability Monitor ({0} /rel).' -f $exe)
    }
    Register-WcActionHandler -Name 'Health-ExportEvents' -Preview {
        param($Context)
        New-WcActionResult -Summary ('Would export the summarized critical events and application crashes of the last 7 days to JSON in {0} (no event message text).' -f (Get-WcHealthReportDir))
    } -Execute {
        param($Context)
        $r = Export-WcHealthEvent
        New-WcActionResult -Summary ('Exported {0} event group(s) and {1} crashing program(s) to {2}.' -f $r.Events, $r.Programs, $r.Path) -Items @([pscustomobject]@{ Path = $r.Path; Events = $r.Events })
    }
}

Export-ModuleMember -Function @(
    'Get-WcHealthPageData', 'Register-WcHealthHandler',
    'Get-WcHealthText', 'Format-WcHealthDate', 'Format-WcHealthBytes', 'New-WcHealthSection', 'Get-WcHealthReportDir', 'Test-WcHealthPathUnder',
    'Get-WcHealthEventQuery', 'Get-WcHealthEventCategory', 'ConvertTo-WcHealthProgramName', 'ConvertTo-WcHealthEventSummary', 'Get-WcHealthEventRaw', 'Get-WcHealthEventData',
    'Get-WcPnpErrorMeaning', 'ConvertTo-WcHealthDeviceRows', 'Get-WcHealthDevice',
    'ConvertTo-WcDiskHealthText', 'ConvertTo-WcDiskOperationalText', 'ConvertTo-WcHealthDiskRows', 'Get-WcHealthDiskRaw',
    'Test-WcHealthMicrosoftTaskPath', 'Get-WcHealthStartupTrigger', 'Select-WcHealthStartupTask', 'ConvertTo-WcTaskResultText', 'ConvertTo-WcHealthTaskRows',
    'Get-WcHealthScheduledTaskRaw', 'Get-WcHealthScheduledTaskInfo',
    'ConvertTo-WcServiceBinaryPath', 'ConvertTo-WcCertificateName', 'Test-WcMicrosoftSigner', 'Get-WcHealthFileSignature', 'Clear-WcHealthSignatureCache',
    'Select-WcHealthThirdPartyService', 'ConvertTo-WcHealthServiceRows', 'Get-WcHealthStartupService',
    'Get-WcWearPercent', 'ConvertTo-WcHealthBatteryRows', 'Get-WcHealthBattery',
    'ConvertTo-WcHotFixDate', 'ConvertTo-WcHealthUpdateRows', 'Get-WcHealthUpdateHistory', 'Get-WcHealthUpdate',
    'ConvertTo-WcHealthTimeRows', 'Get-WcHealthTime', 'Get-WcHealthFinding',
    'Get-WcHealthToolPath', 'Test-WcHealthToolCommand', 'Invoke-WcHealthTool', 'Invoke-WcHealthPowerReport', 'Start-WcHealthReliabilityMonitor', 'Export-WcHealthEvent'
)
