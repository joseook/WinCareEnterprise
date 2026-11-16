#Requires -Version 5.1
<#
    WinCare.Processes - page 'processes' (Processos e memoria) and its actions.

    Page data: Get-WcProcessesPageData (docs/CONTRATO-ACOES.md section 6). Sections:
      memory-overview  RAM total/available, commit charge vs limit, page file usage,
                       compressed memory ('Memory Compression' process), hard faults/s.
      top-memory       top processes by working set (+ private bytes, kind, hosted services).
      growth           private bytes sampled N times; steady growth = leak SUSPICION (heuristic).
      review           processes running from user-writable folders or with an
                       unsigned/invalid Authenticode signature (information, not a verdict).
      cpu-now          % CPU per process from two TotalProcessorTime snapshots.
      no-ram-cleaner   note-only section: why WinCare offers no "RAM cleaner".

    Actions (Core/actions.d/f6-processes.json):
      process.end                 ends ONE user-selected process (Medium, irreversible).
                                  Parameters: $Context.Parameters['process.end'] (see
                                  Set-WcProcessEndRequest). Graceful CloseMainWindow first;
                                  Stop-Process only when the request says Force.
      memory.schedule-diagnostic  opens the Windows Memory Diagnostic (MdSched.exe). There is
                                  no documented non-interactive switch: the user chooses
                                  "restart now" or "check next time". WinCare never reboots.

    Deliberately NOT offered: "RAM cleaners" (EmptyWorkingSet, standby-list purge).
    Windows already trims working sets and repurposes standby memory on demand; purging
    them only forces the data to be read again from disk (key processes.note.no-ram-cleaner).

    Command lines (Win32_Process.CommandLine) are never read into rows: they can carry secrets.

    Pattern: Get-* thin I/O (mocked in tests), ConvertTo-*/Test-* pure (Linux fixtures).
#>

# ------------------------------------------------------------- thresholds --

function Get-WcProcessesThreshold {
    <#
        Documented thresholds (plain-language status OK / pressure / critical):
          Available RAM    pressure below 15 % of total, critical below 5 %.
          Commit charge    pressure at or above 80 % of the commit limit, critical at 95 %
                           (at the limit Windows refuses allocations and warns "low memory").
          Page file        pressure at or above 80 % of its allocated size.
          Hard faults      pressure at or above 1000 pages read from disk per second
                           (counter Memory\Pages Input/sec over the sample window; short sample).
          Growth           private bytes rise at EVERY sample and by at least 10 MB and 5 %
                           over the window (heuristic, not proof of a leak).
    #>
    [CmdletBinding()]
    param()
    return @{
        AvailablePressurePercent = 15
        AvailableCriticalPercent = 5
        CommitPressurePercent    = 80
        CommitCriticalPercent    = 95
        PagefilePressurePercent  = 80
        HardFaultPressurePerSec  = 1000
        GrowthMinBytes           = 10MB
        GrowthMinPercent         = 5
    }
}

# Processes that make Windows work. Ending any of them crashes or destabilizes the session.
$script:WcProcessCriticalNames = @('System', 'Idle', 'Registry', 'Secure System', 'Memory Compression', 'smss', 'csrss',
    'wininit', 'winlogon', 'services', 'lsass', 'LsaIso', 'svchost', 'dwm', 'fontdrvhost', 'sihost', 'explorer',
    'spoolsv', 'audiodg', 'conhost', 'WUDFHost', 'dllhost', 'taskhostw', 'ctfmon', 'RuntimeBroker', 'StartMenuExperienceHost',
    'ShellExperienceHost', 'SearchHost', 'TextInputHost', 'LogonUI', 'userinit', 'WmiPrvSE')

# Security, EDR, VPN and device-management agents. The project never touches them
# (protected features: Defender, EDR, VPN, MDM). Names without '.exe', compared case-insensitively.
$script:WcProcessSecurityNames = @(
    # Microsoft Defender / Defender for Endpoint / Windows Security
    'MsMpEng', 'MsMpEngCP', 'MpDefenderCoreService', 'NisSrv', 'MpCmdRun', 'SecurityHealthService', 'SecurityHealthSystray',
    'SecurityHealthHost', 'smartscreen', 'MsSense', 'SenseCncProxy', 'SenseIR', 'SenseNdr', 'SenseTVM', 'SenseSampleUploader', 'SenseCE', 'MpSigStub',
    # Intune / ConfigMgr / device management
    'IntuneManagementExtension', 'AgentExecutor', 'Microsoft.Management.Services.IntuneWindowsAgent', 'omadmclient', 'DeviceEnroller', 'CcmExec', 'CmRcService',
    # CrowdStrike, SentinelOne, Carbon Black, Cylance, Cortex XDR, Elastic, Tanium, Qualys, Rapid7, Wazuh
    'CSFalconService', 'CSFalconContainer', 'SentinelAgent', 'SentinelServiceHost', 'SentinelStaticEngine', 'SentinelStaticEngineScanner',
    'SentinelUI', 'SentinelHelperService', 'RepMgr', 'RepUtils', 'RepUx', 'RepWSC', 'cb', 'CylanceSvc', 'CylanceUI', 'cyserver', 'cytool',
    'CyveraService', 'traps', 'tlaservice', 'cyrprtui', 'elastic-agent', 'elastic-endpoint', 'TaniumClient', 'QualysAgent', 'ir_agent', 'wazuh-agent',
    # Sophos, Symantec/Broadcom, Trend Micro, McAfee/Trellix, ESET, Kaspersky, Bitdefender
    'SophosHealth', 'SophosFileScanner', 'SophosNtpService', 'SophosUI', 'SAVService', 'SEDService', 'McsAgent', 'McsClient', 'SSPService', 'hmpalert',
    'ccSvcHst', 'SepMasterService', 'smc', 'Smcgui', 'PccNTMon', 'TmListen', 'NTRTScan', 'TmCCSF', 'Ds_Agent', 'coreServiceShell',
    'mfemms', 'mfefire', 'mfevtps', 'masvc', 'macmnsvc', 'mcshield', 'ekrn', 'egui', 'ERAAgent', 'avp', 'avpui', 'klnagent',
    'bdagent', 'vsserv', 'EPSecurityService', 'EPProtectedService', 'bdservicehost',
    # VPN / secure access clients
    'vpnagent', 'vpnui', 'csc_ui', 'acumbrellaagent', 'PanGPS', 'PanGPA', 'FortiClient', 'FortiTray', 'fortisslvpndaemon', 'FCDBLog', 'FortiESNAC',
    'openvpn', 'openvpnserv', 'openvpn-gui', 'OpenVPNConnect', 'wireguard', 'dsAccessService', 'Pulse', 'PulseSecureService', 'TracSrvWrapper', 'trac',
    'EPWD', 'f5fpclientW', 'warp-svc', 'Cloudflare WARP', 'tailscaled', 'tailscale-ipn', 'ZSATunnel', 'ZSATrayManager', 'ZSAService', 'ZSAUpm',
    'stAgentSvc', 'nsdiag', 'NordVPN', 'nordvpn-service', 'ExpressVPN', 'expressvpnd'
)
# File-version Company values of security vendors (substring match): a second net for renamed agents.
$script:WcProcessSecurityCompanies = @('CrowdStrike', 'SentinelOne', 'Sentinel Labs', 'Carbon Black', 'Cylance', 'Palo Alto Networks', 'Sophos',
    'Symantec', 'Broadcom', 'Trend Micro', 'McAfee', 'Trellix', 'ESET', 'Kaspersky', 'Bitdefender', 'Fortinet', 'Zscaler', 'Netskope', 'Tanium',
    'Qualys', 'Rapid7', 'Elastic', 'Cisco Systems', 'Check Point', 'Ivanti', 'Pulse Secure', 'Cloudflare', 'Tailscale', 'WireGuard', 'OpenVPN')
# Path fragments of Microsoft Defender components.
$script:WcProcessSecurityPaths = @('\Windows Defender\', '\Windows Defender Advanced Threat Protection\', '\Microsoft\Windows Defender\',
    '\Microsoft Intune Management Extension\', '\Microsoft Security Client\')
# Accounts that run Windows itself.
$script:WcProcessSystemAccounts = @('NT AUTHORITY\SYSTEM', 'NT AUTHORITY\LOCAL SERVICE', 'NT AUTHORITY\NETWORK SERVICE', 'SYSTEM', 'LOCAL SERVICE', 'NETWORK SERVICE')

$script:WcSignatureCache = @{}

# ------------------------------------------------------------- text helpers --

function Get-WcProcText {
    <# Localized text with an English fallback when the string table is not loaded. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Key, [string] $Fallback, [object[]] $Arguments)
    $t = $null
    if (Get-Command -Name 'Get-WcString' -ErrorAction SilentlyContinue) { $t = Get-WcString -Key $Key -Arguments $Arguments }
    if (-not $t -or $t -eq "[$Key]") {
        if (-not $Fallback) { $Fallback = $Key }
        if ($null -ne $Arguments -and $Arguments.Count -gt 0) { return ($Fallback -f $Arguments) }
        return $Fallback
    }
    return $t
}

function ConvertTo-WcProcBytesText {
    <# Pure: bytes -> short display text (KB/MB/GB/TB, current culture). #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Bytes)
    if ($null -eq $Bytes) { return '-' }
    $b = [double]$Bytes
    $sign = ''
    if ($b -lt 0) { $sign = '-'; $b = - $b }
    if ($b -ge 1TB) { return ('{0}{1:N1} TB' -f $sign, ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0}{1:N1} GB' -f $sign, ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0}{1:N0} MB' -f $sign, ($b / 1MB)) }
    return ('{0}{1:N0} KB' -f $sign, ($b / 1KB))
}

function ConvertTo-WcProcStatusText {
    <# Pure-ish: status code (Ok/Pressure/Critical/Info/Unknown) -> localized label. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Status)
    $fallback = @{ Ok = 'OK'; Pressure = 'Pressure'; Critical = 'Critical'; Info = 'Info'; Unknown = 'Unknown'; Growing = 'Growing'; Stable = 'Stable' }
    $fb = $Status
    if ($fallback.ContainsKey($Status)) { $fb = $fallback[$Status] }
    return (Get-WcProcText -Key ('processes.status.' + $Status.ToLowerInvariant()) -Fallback $fb)
}

function Get-WcProcSeverity {
    <# Pure: list of status codes -> section severity (Critical > Warning > Info). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]] $Status)
    $s = @($Status)
    if ($s -contains 'Critical') { return 'Critical' }
    if ($s -contains 'Pressure' -or $s -contains 'Growing') { return 'Warning' }
    return 'Info'
}

# ---------------------------------------------------------- memory overview --

function Get-WcLevelStatus {
    <# Pure: value vs pressure/critical thresholds. -LowerIsWorse for "available" style figures. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value, [double] $Pressure, [double] $Critical, [switch] $LowerIsWorse)
    if ($null -eq $Value) { return 'Unknown' }
    $v = [double]$Value
    if ($LowerIsWorse) {
        if ($v -lt $Critical) { return 'Critical' }
        if ($v -lt $Pressure) { return 'Pressure' }
        return 'Ok'
    }
    if ($v -ge $Critical) { return 'Critical' }
    if ($v -ge $Pressure) { return 'Pressure' }
    return 'Ok'
}

function ConvertTo-WcHardFaultRate {
    <#
        Pure: two raw samples of Win32_PerfRawData_PerfOS_Memory -> pages read from disk per
        second (Memory\Pages Input/sec). Elapsed time from Timestamp_Sys100NS, else -ElapsedSeconds.
    #>
    [CmdletBinding()]
    param($First, $Second, [double] $ElapsedSeconds = 0)
    $a = Get-WcProcValue $First 'PagesInputPersec'
    $b = Get-WcProcValue $Second 'PagesInputPersec'
    if ($null -eq $a -or $null -eq $b) { return $null }
    $secs = 0.0
    $ta = Get-WcProcValue $First 'Timestamp_Sys100NS'
    $tb = Get-WcProcValue $Second 'Timestamp_Sys100NS'
    if ($null -ne $ta -and $null -ne $tb -and [double]$tb -gt [double]$ta) { $secs = ([double]$tb - [double]$ta) / 1e7 }
    if ($secs -le 0) { $secs = $ElapsedSeconds }
    if ($secs -le 0) { return $null }
    $delta = [double]$b - [double]$a
    if ($delta -lt 0) { return $null }
    return [math]::Round($delta / $secs, 1)
}

function Get-WcProcValue {
    <# Safe property read (hashtable / pscustomobject / CIM). Local copy: no cross-module dependency in pure code. #>
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) { return $InputObject[$Name] }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-WcMemoryFacts {
    <#
        Pure: raw CIM data -> memory facts in bytes.
          OperatingSystem  Win32_OperatingSystem (TotalVisibleMemorySize, FreePhysicalMemory,
                           TotalVirtualMemorySize, FreeVirtualMemory: all in KB)
          PerfMemory       Win32_PerfFormattedData_PerfOS_Memory (AvailableBytes, CommittedBytes, CommitLimit)
          PageFile         Win32_PageFileUsage (AllocatedBaseSize, CurrentUsage, PeakUsage: MB)
          CompressedBytes  working set of the 'Memory Compression' process ($null = not present)
          HardFaultsPerSec from ConvertTo-WcHardFaultRate
    #>
    [CmdletBinding()]
    param($OperatingSystem, $PerfMemory, [object[]] $PageFile, $CompressedBytes = $null, $HardFaultsPerSec = $null, [double] $SampleSeconds = 0)
    $kb = 1024L
    $total = $null; $avail = $null; $committed = $null; $limit = $null
    $v = Get-WcProcValue $OperatingSystem 'TotalVisibleMemorySize'
    if ($null -ne $v) { $total = [long]$v * $kb }
    $v = Get-WcProcValue $PerfMemory 'AvailableBytes'
    if ($null -ne $v) { $avail = [long]$v }
    else {
        $v = Get-WcProcValue $OperatingSystem 'FreePhysicalMemory'
        if ($null -ne $v) { $avail = [long]$v * $kb }
    }
    $v = Get-WcProcValue $PerfMemory 'CommittedBytes'
    $l = Get-WcProcValue $PerfMemory 'CommitLimit'
    if ($null -ne $v -and $null -ne $l) { $committed = [long]$v; $limit = [long]$l }
    else {
        # Fallback: the OS "virtual memory" figures are the commit limit and its free part.
        $tv = Get-WcProcValue $OperatingSystem 'TotalVirtualMemorySize'
        $fv = Get-WcProcValue $OperatingSystem 'FreeVirtualMemory'
        if ($null -ne $tv -and $null -ne $fv) { $limit = [long]$tv * $kb; $committed = ([long]$tv - [long]$fv) * $kb }
    }
    $files = @()
    foreach ($p in @($PageFile)) {
        if ($null -eq $p) { continue }
        $alloc = Get-WcProcValue $p 'AllocatedBaseSize'
        $cur = Get-WcProcValue $p 'CurrentUsage'
        $peak = Get-WcProcValue $p 'PeakUsage'
        $files += [pscustomobject]@{
            Name           = [string](Get-WcProcValue $p 'Name')
            AllocatedBytes = $(if ($null -ne $alloc) { [long]$alloc * 1MB } else { $null })
            UsedBytes      = $(if ($null -ne $cur) { [long]$cur * 1MB } else { $null })
            PeakBytes      = $(if ($null -ne $peak) { [long]$peak * 1MB } else { $null })
        }
    }
    $cb = $null
    if ($null -ne $CompressedBytes) { $cb = [long]$CompressedBytes }
    return [pscustomobject]@{
        TotalBytes = $total; AvailableBytes = $avail; CommittedBytes = $committed; CommitLimitBytes = $limit
        PageFiles = $files; CompressedBytes = $cb; HardFaultsPerSec = $HardFaultsPerSec; SampleSeconds = $SampleSeconds
    }
}

function ConvertTo-WcPercent {
    param($Part, $Whole)
    if ($null -eq $Part -or $null -eq $Whole -or [double]$Whole -le 0) { return $null }
    return [math]::Round(([double]$Part / [double]$Whole) * 100, 1)
}

function ConvertTo-WcMemoryOverviewRows {
    <# Pure: memory facts + thresholds -> display rows (Metric, Value, Status, ProcThreshold, ProcStatusRaw). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Facts, [hashtable] $Threshold = (Get-WcProcessesThreshold))
    $rows = @()
    $mk = {
        param($key, $fb, $value, $status, $thrKey, $thrFb, $thrArgs)
        $thr = '-'
        if ($thrKey) { $thr = Get-WcProcText -Key $thrKey -Fallback $thrFb -Arguments $thrArgs }
        [pscustomobject]@{
            Metric = (Get-WcProcText -Key $key -Fallback $fb); Value = $value
            Status = (ConvertTo-WcProcStatusText -Status $status); ProcThreshold = $thr; ProcStatusRaw = $status
        }
    }
    $rows += & $mk 'processes.metric.total' 'Installed memory (usable)' (ConvertTo-WcProcBytesText $Facts.TotalBytes) 'Info' $null $null $null

    $availPct = ConvertTo-WcPercent $Facts.AvailableBytes $Facts.TotalBytes
    $st = Get-WcLevelStatus -Value $availPct -Pressure $Threshold.AvailablePressurePercent -Critical $Threshold.AvailableCriticalPercent -LowerIsWorse
    $val = '-'
    if ($null -ne $Facts.AvailableBytes) { $val = ('{0} ({1}%)' -f (ConvertTo-WcProcBytesText $Facts.AvailableBytes), $availPct) }
    $rows += & $mk 'processes.metric.available' 'Available memory' $val $st 'processes.threshold.available' 'Pressure below {0}%, critical below {1}%' @($Threshold.AvailablePressurePercent, $Threshold.AvailableCriticalPercent)

    $commitPct = ConvertTo-WcPercent $Facts.CommittedBytes $Facts.CommitLimitBytes
    $st = Get-WcLevelStatus -Value $commitPct -Pressure $Threshold.CommitPressurePercent -Critical $Threshold.CommitCriticalPercent
    $val = '-'
    if ($null -ne $commitPct) { $val = ('{0} / {1} ({2}%)' -f (ConvertTo-WcProcBytesText $Facts.CommittedBytes), (ConvertTo-WcProcBytesText $Facts.CommitLimitBytes), $commitPct) }
    $rows += & $mk 'processes.metric.commit' 'Commit charge / limit' $val $st 'processes.threshold.commit' 'Pressure from {0}%, critical from {1}% of the limit' @($Threshold.CommitPressurePercent, $Threshold.CommitCriticalPercent)

    $files = @($Facts.PageFiles)
    if ($files.Count -eq 0) {
        $rows += & $mk 'processes.metric.pagefile-none' 'Page file' (Get-WcProcText -Key 'processes.value.no-pagefile' -Fallback 'none configured') 'Info' $null $null $null
    }
    foreach ($f in $files) {
        $pct = ConvertTo-WcPercent $f.UsedBytes $f.AllocatedBytes
        $st = Get-WcLevelStatus -Value $pct -Pressure $Threshold.PagefilePressurePercent -Critical 101
        $val = ('{0}: {1} / {2} ({3}%), peak {4}' -f $f.Name, (ConvertTo-WcProcBytesText $f.UsedBytes), (ConvertTo-WcProcBytesText $f.AllocatedBytes), $pct, (ConvertTo-WcProcBytesText $f.PeakBytes))
        $rows += & $mk 'processes.metric.pagefile' 'Page file usage' $val $st 'processes.threshold.pagefile' 'Pressure from {0}% of its size' @($Threshold.PagefilePressurePercent)
    }

    $val = Get-WcProcText -Key 'processes.value.not-available' -Fallback 'not available'
    if ($null -ne $Facts.CompressedBytes) { $val = ConvertTo-WcProcBytesText $Facts.CompressedBytes }
    $rows += & $mk 'processes.metric.compressed' 'Compressed memory (Memory Compression)' $val 'Info' 'processes.threshold.compressed' 'Informative: compression is normal and cheaper than paging' $null

    $st = Get-WcLevelStatus -Value $Facts.HardFaultsPerSec -Pressure $Threshold.HardFaultPressurePerSec -Critical ([double]::MaxValue)
    $val = '-'
    if ($null -ne $Facts.HardFaultsPerSec) { $val = Get-WcProcText -Key 'processes.value.hard-faults' -Fallback '{0} pages/s (sample of {1} s)' -Arguments @($Facts.HardFaultsPerSec, [math]::Round([double]$Facts.SampleSeconds, 0)) }
    $rows += & $mk 'processes.metric.hard-faults' 'Hard faults (pages read from disk)' $val $st 'processes.threshold.hard-faults' 'Pressure from {0} pages/s (short sample)' @($Threshold.HardFaultPressurePerSec)
    return $rows
}

# -------------------------------------------------------- process inventory --

function ConvertTo-WcProcessKind {
    <#
        Pure classification:
          System      PID 0/4 or a core Windows process name
          Service     hosts one or more Win32 services (Win32_Service.ProcessId)
          Session0    runs in session 0 (services/background of the system) without a mapped service
          App         user session with a main window
          Background  user session, no main window
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int] $ProcessId, [string] $Name, $SessionId, [bool] $HasWindow, [int] $ServiceCount = 0)
    if ($ProcessId -eq 0 -or $ProcessId -eq 4) { return 'System' }
    $core = @('System', 'Idle', 'Registry', 'Secure System', 'Memory Compression', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'LsaIso')
    foreach ($c in $core) { if ($Name -eq $c) { return 'System' } }
    if ($ServiceCount -gt 0) { return 'Service' }
    if ($null -ne $SessionId -and [int]$SessionId -eq 0) { return 'Session0' }
    if ($HasWindow) { return 'App' }
    return 'Background'
}

function ConvertTo-WcProcessKindText {
    param([string] $Kind)
    $fb = @{ System = 'Windows (system)'; Service = 'Service host'; Session0 = 'Background (session 0)'; App = 'App (window)'; Background = 'Background' }
    $f = $Kind
    if ($fb.ContainsKey($Kind)) { $f = $fb[$Kind] }
    return (Get-WcProcText -Key ('processes.kind.' + $Kind.ToLowerInvariant()) -Fallback $f)
}

function ConvertTo-WcServiceMap {
    <# Pure: Win32_Service rows -> hashtable ProcessId(int) -> sorted service names (running ones, PID > 0). #>
    [CmdletBinding()]
    param([object[]] $Service)
    $map = @{}
    foreach ($s in @($Service)) {
        if ($null -eq $s) { continue }
        $procId = Get-WcProcValue $s 'ProcessId'
        if ($null -eq $procId -or [int]$procId -le 0) { continue }
        $k = [int]$procId
        if (-not $map.ContainsKey($k)) { $map[$k] = @() }
        $map[$k] += [string](Get-WcProcValue $s 'Name')
    }
    $out = @{}
    foreach ($k in @($map.Keys)) { $out[$k] = @($map[$k] | Sort-Object) }
    return $out
}

function ConvertTo-WcServiceListText {
    <# Pure: service names -> 'a, b, c (+N)' capped at Max names. #>
    param([string[]] $Name, [int] $Max = 6)
    $n = @($Name | Where-Object { $_ })
    if ($n.Count -eq 0) { return '' }
    if ($n.Count -le $Max) { return ($n -join ', ') }
    return ('{0} (+{1})' -f (($n | Select-Object -First $Max) -join ', '), ($n.Count - $Max))
}

function ConvertTo-WcProcessInventory {
    <#
        Pure merge: process snapshot (Get-WcProcessSnapshot -Detailed) + Win32_Process rows
        (ProcessId, ExecutablePath, SessionId only - CommandLine is ignored on purpose) +
        service map -> one object per process.
    #>
    [CmdletBinding()]
    param([object[]] $Snapshot, [object[]] $CimProcess, [hashtable] $ServiceMap = @{})
    $cim = @{}
    foreach ($c in @($CimProcess)) {
        if ($null -eq $c) { continue }
        $procId = Get-WcProcValue $c 'ProcessId'
        if ($null -ne $procId) { $cim[[int]$procId] = $c }
    }
    $out = @()
    foreach ($p in @($Snapshot)) {
        if ($null -eq $p) { continue }
        $procId = [int]$p.Id
        $c = $null
        if ($cim.ContainsKey($procId)) { $c = $cim[$procId] }
        $path = [string](Get-WcProcValue $p 'Path')
        if (-not $path) { $path = [string](Get-WcProcValue $c 'ExecutablePath') }
        $session = Get-WcProcValue $p 'SessionId'
        if ($null -eq $session) { $session = Get-WcProcValue $c 'SessionId' }
        $services = @()
        if ($ServiceMap.ContainsKey($procId)) { $services = @($ServiceMap[$procId]) }
        $hasWindow = [bool](Get-WcProcValue $p 'HasWindow')
        $out += [pscustomobject]@{
            Id = $procId; Name = [string]$p.Name; WorkingSet = (Get-WcProcValue $p 'WorkingSet'); PrivateBytes = (Get-WcProcValue $p 'PrivateBytes')
            SessionId = $session; HasWindow = $hasWindow; Path = $path; Services = $services
            Company = [string](Get-WcProcValue $p 'Company'); Description = [string](Get-WcProcValue $p 'Description')
            Kind = (ConvertTo-WcProcessKind -ProcessId $procId -Name ([string]$p.Name) -SessionId $session -HasWindow $hasWindow -ServiceCount $services.Count)
        }
    }
    return $out
}

function Select-WcTopProcess {
    <# Pure: top N by working set (Idle/PID 0 excluded). #>
    [CmdletBinding()]
    param([object[]] $Inventory, [int] $Top = 25)
    return @(@($Inventory) | Where-Object { $null -ne $_ -and $_.Id -ne 0 -and $null -ne $_.WorkingSet } |
            Sort-Object -Property @{ Expression = { [long]$_.WorkingSet }; Descending = $true } | Select-Object -First $Top)
}

function ConvertTo-WcTopMemoryRows {
    <# Pure: inventory objects (already the top N) -> display rows. #>
    [CmdletBinding()]
    param([object[]] $Process)
    $rows = @()
    foreach ($p in @($Process)) {
        if ($null -eq $p) { continue }
        $rows += [pscustomobject]@{
            Name = $p.Name; ProcPid = $p.Id
            ProcWorkingSet = (ConvertTo-WcProcBytesText $p.WorkingSet); ProcPrivate = (ConvertTo-WcProcBytesText $p.PrivateBytes)
            Description = $p.Description; Company = $p.Company; Path = $p.Path
            ProcKind = (ConvertTo-WcProcessKindText -Kind $p.Kind); ProcServices = (ConvertTo-WcServiceListText -Name $p.Services)
            ProcWorkingSetRaw = $p.WorkingSet; ProcPrivateRaw = $p.PrivateBytes
        }
    }
    return $rows
}

# ------------------------------------------------------------ growth check --

function Test-WcProcessGrowth {
    <#
        Pure heuristic: steady growth = every sample larger than the previous one AND total
        growth >= MinGrowthBytes AND >= MinGrowthPercent of the first sample. Not proof of a leak:
        caches, loading documents and warm-up also grow.
    #>
    [CmdletBinding()]
    param([object[]] $Sample, [long] $MinGrowthBytes = 10MB, [double] $MinGrowthPercent = 5)
    $s = @($Sample | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $res = [pscustomobject]@{ Growing = $false; DeltaBytes = $null; Percent = $null; Samples = $s.Count }
    if ($s.Count -lt 2) { return $res }
    $res.DeltaBytes = [long]($s[$s.Count - 1] - $s[0])
    if ($s[0] -gt 0) { $res.Percent = [math]::Round(($res.DeltaBytes / $s[0]) * 100, 1) }
    $steady = $true
    for ($i = 1; $i -lt $s.Count; $i++) { if ($s[$i] -le $s[$i - 1]) { $steady = $false; break } }
    $res.Growing = ($steady -and $res.DeltaBytes -ge $MinGrowthBytes -and $null -ne $res.Percent -and $res.Percent -ge $MinGrowthPercent)
    return $res
}

function ConvertTo-WcGrowthSeries {
    <#
        Pure: list of snapshots (each an array of {Id, Name, PrivateBytes}) -> series per process
        present in EVERY snapshot with the same name (PID reuse guard). Limited to the Top N
        processes by private bytes in the first snapshot.
    #>
    [CmdletBinding()]
    param([object[]] $Snapshots, [int] $Top = 15)
    $snaps = @($Snapshots)
    if ($snaps.Count -lt 2) { return @() }
    $first = @(@($snaps[0]) | Where-Object { $null -ne $_ -and $_.Id -ne 0 -and $null -ne $_.PrivateBytes } |
            Sort-Object -Property @{ Expression = { [long]$_.PrivateBytes }; Descending = $true } | Select-Object -First $Top)
    $index = @()
    foreach ($s in $snaps) {
        $h = @{}
        foreach ($p in @($s)) { if ($null -ne $p) { $h[[int]$p.Id] = $p } }
        $index += , $h
    }
    $out = @()
    foreach ($p in $first) {
        $vals = @()
        $ok = $true
        foreach ($h in $index) {
            if (-not $h.ContainsKey([int]$p.Id) -or $h[[int]$p.Id].Name -ne $p.Name -or $null -eq $h[[int]$p.Id].PrivateBytes) { $ok = $false; break }
            $vals += [long]$h[[int]$p.Id].PrivateBytes
        }
        if ($ok) { $out += [pscustomobject]@{ Id = [int]$p.Id; Name = [string]$p.Name; Samples = $vals } }
    }
    return $out
}

function ConvertTo-WcGrowthRows {
    <# Pure: series -> rows (growing first, then by growth). #>
    [CmdletBinding()]
    param([object[]] $Series, [hashtable] $Threshold = (Get-WcProcessesThreshold))
    $tmp = @()
    foreach ($s in @($Series)) {
        if ($null -eq $s) { continue }
        $g = Test-WcProcessGrowth -Sample $s.Samples -MinGrowthBytes $Threshold.GrowthMinBytes -MinGrowthPercent $Threshold.GrowthMinPercent
        $status = 'Stable'
        if ($g.Growing) { $status = 'Growing' }
        $pctText = '-'
        if ($null -ne $g.Percent) { $pctText = ('{0}%' -f $g.Percent) }
        $deltaText = ConvertTo-WcProcBytesText $g.DeltaBytes
        if ($null -ne $g.DeltaBytes -and $g.DeltaBytes -ge 0) { $deltaText = '+' + $deltaText }
        $tmp += [pscustomobject]@{
            Name = $s.Name; ProcPid = $s.Id
            ProcSamples = ((@($s.Samples) | ForEach-Object { ConvertTo-WcProcBytesText $_ }) -join ' -> ')
            ProcGrowth = ('{0} ({1})' -f $deltaText, $pctText)
            Status = (ConvertTo-WcProcStatusText -Status $status); ProcStatusRaw = $status; ProcGrowthRaw = $g.DeltaBytes
        }
    }
    return @($tmp | Sort-Object -Property @{ Expression = { if ($_.ProcStatusRaw -eq 'Growing') { 0 } else { 1 } } }, @{ Expression = { [double]$_.ProcGrowthRaw }; Descending = $true })
}

# ---------------------------------------------------------------- CPU now --

function ConvertTo-WcCpuRows {
    <#
        Pure: two snapshots ({Id, Name, CpuSeconds}) -> top N by % of total CPU capacity over the
        elapsed wall time (100% = all logical processors busy). PID 0 (Idle) excluded; processes
        without readable CPU time or not present in both snapshots are skipped.
    #>
    [CmdletBinding()]
    param([object[]] $First, [object[]] $Last, [double] $ElapsedSeconds, [int] $LogicalProcessors = 1, [int] $Top = 10)
    if ($ElapsedSeconds -le 0 -or $LogicalProcessors -lt 1) { return @() }
    $a = @{}
    foreach ($p in @($First)) { if ($null -ne $p -and $null -ne $p.CpuSeconds) { $a[[int]$p.Id] = $p } }
    $tmp = @()
    foreach ($p in @($Last)) {
        if ($null -eq $p -or $null -eq $p.CpuSeconds -or [int]$p.Id -eq 0) { continue }
        if (-not $a.ContainsKey([int]$p.Id) -or $a[[int]$p.Id].Name -ne $p.Name) { continue }
        $delta = [double]$p.CpuSeconds - [double]$a[[int]$p.Id].CpuSeconds
        if ($delta -le 0) { continue }
        $pct = [math]::Round(($delta / ($ElapsedSeconds * $LogicalProcessors)) * 100, 1, [System.MidpointRounding]::AwayFromZero)
        $tmp += [pscustomobject]@{
            Name = [string]$p.Name; ProcPid = [int]$p.Id; ProcCpuPercent = ('{0} %' -f $pct)
            CpuSecondsTotal = [math]::Round([double]$p.CpuSeconds, 1); ProcCpuPercentRaw = $pct
        }
    }
    return @($tmp | Sort-Object -Property @{ Expression = { [double]$_.ProcCpuPercentRaw }; Descending = $true } | Select-Object -First $Top)
}

# ------------------------------------------------- background worth review --

function ConvertTo-WcProcessLocationKind {
    <#
        Pure: executable path -> user-writable location kind or $null.
          Temp       ...\AppData\Local\Temp\..., ...\Windows\Temp\..., or under -TempRoot
          AppData    ...\AppData\Roaming\..., or under -AppDataRoot
          Downloads  ...\Users\<name>\Downloads\..., or under -DownloadsRoot
        Programs installed per user under AppData\Local\Programs are NOT flagged (normal for
        Teams, VS Code, browsers).
    #>
    [CmdletBinding()]
    param([string] $Path, [string] $TempRoot, [string] $AppDataRoot, [string] $DownloadsRoot)
    if (-not $Path) { return $null }
    $p = $Path -replace '/', '\'
    foreach ($pair in @(@('Temp', $TempRoot), @('AppData', $AppDataRoot), @('Downloads', $DownloadsRoot))) {
        $root = [string]$pair[1]
        if (-not $root) { continue }
        $r = ($root -replace '/', '\').TrimEnd('\') + '\'
        if ($p.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) { return $pair[0] }
    }
    if ($p -match '(?i)\\AppData\\Local\\Temp\\' -or $p -match '(?i)^[A-Z]:\\Windows\\Temp\\') { return 'Temp' }
    if ($p -match '(?i)\\AppData\\Roaming\\') { return 'AppData' }
    if ($p -match '(?i)\\Users\\[^\\]+\\Downloads\\') { return 'Downloads' }
    return $null
}

function Test-WcProcessWorthReview {
    <# Pure: user-writable location OR a signature status other than Valid / NotChecked. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $LocationKind, [string] $SignatureStatus)
    if ($LocationKind) { return $true }
    if ($SignatureStatus -and @('Valid', 'NotChecked') -notcontains $SignatureStatus) { return $true }
    return $false
}

function Select-WcSignatureCandidate {
    <#
        Pure: unique executable paths to check, at most -Max: every user-writable one first,
        then the rest by working set. Paths under -SystemRoot are skipped (in-box, catalog-signed;
        checking them would spend the budget on Windows itself).
    #>
    [CmdletBinding()]
    param([object[]] $Inventory, [int] $Max = 25, [string] $SystemRoot, [hashtable] $Roots = @{})
    $sys = $null
    if ($SystemRoot) { $sys = ($SystemRoot -replace '/', '\').TrimEnd('\') + '\' }
    $seen = @{}
    $first = @(); $rest = @()
    $sorted = @(@($Inventory) | Where-Object { $null -ne $_ -and $_.Path } | Sort-Object -Property @{ Expression = { [double]$_.WorkingSet }; Descending = $true })
    foreach ($p in $sorted) {
        $key = $p.Path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        if ($sys -and ($p.Path -replace '/', '\').StartsWith($sys, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $kind = ConvertTo-WcProcessLocationKind -Path $p.Path -TempRoot $Roots['Temp'] -AppDataRoot $Roots['AppData'] -DownloadsRoot $Roots['Downloads']
        if ($kind) { $first += $p.Path } else { $rest += $p.Path }
    }
    return @(@($first) + @($rest) | Select-Object -First $Max)
}

function ConvertTo-WcSignerName {
    <# Pure: certificate subject -> CN (or O) value. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Subject)
    if (-not $Subject) { return '' }
    $m = [regex]::Match($Subject, '(?:^|,\s*)CN=("([^"]+)"|[^,]+)')
    if ($m.Success) { if ($m.Groups[2].Success) { return $m.Groups[2].Value.Trim() } else { return $m.Groups[1].Value.Trim() } }
    $m = [regex]::Match($Subject, '(?:^|,\s*)O=("([^"]+)"|[^,]+)')
    if ($m.Success) { if ($m.Groups[2].Success) { return $m.Groups[2].Value.Trim() } else { return $m.Groups[1].Value.Trim() } }
    return $Subject
}

function ConvertTo-WcReviewRows {
    <#
        Pure: inventory + signature results (hashtable lower-case path -> {Status, Signer}) ->
        rows for executables worth reviewing, ONE row per executable path (ProcPid = first PID,
        ProcInstances = number of running processes). Status 'NotChecked' = outside the budget.
    #>
    [CmdletBinding()]
    param([object[]] $Inventory, [hashtable] $Signature = @{}, [hashtable] $Roots = @{})
    $rows = @()
    $byPath = @{}
    foreach ($p in @($Inventory)) {
        if ($null -eq $p -or -not $p.Path) { continue }
        $k = $p.Path.ToLowerInvariant()
        if ($byPath.ContainsKey($k)) { $byPath[$k].ProcInstances++; continue }
        $kind = ConvertTo-WcProcessLocationKind -Path $p.Path -TempRoot $Roots['Temp'] -AppDataRoot $Roots['AppData'] -DownloadsRoot $Roots['Downloads']
        $sig = $null
        if ($Signature.ContainsKey($k)) { $sig = $Signature[$k] }
        $status = 'NotChecked'; $signer = ''
        if ($null -ne $sig) { $status = [string]$sig.Status; $signer = [string]$sig.Signer }
        if (-not (Test-WcProcessWorthReview -LocationKind $kind -SignatureStatus $status)) { $byPath[$k] = [pscustomobject]@{ ProcInstances = 1 }; continue }
        $locText = '-'
        if ($kind) { $locText = Get-WcProcText -Key ('processes.location.' + $kind.ToLowerInvariant()) -Fallback $kind }
        $row = [pscustomobject]@{
            Name = $p.Name; ProcPid = $p.Id; ProcInstances = 1; Path = $p.Path; ProcLocation = $locText
            ProcSignature = (Get-WcProcText -Key ('processes.signature.' + $status.ToLowerInvariant()) -Fallback $status)
            ProcSigner = $signer; ProcKind = (ConvertTo-WcProcessKindText -Kind $p.Kind); ProcSignatureRaw = $status
        }
        $byPath[$k] = $row
        $rows += $row
    }
    return $rows
}

# ---------------------------------------------------------------- I/O --

function Get-WcProcessSnapshot {
    <#
        Thin I/O: Get-Process -> plain objects {Id, Name, WorkingSet, PrivateBytes, CpuSeconds,
        SessionId[, HasWindow, Path, StartTime]}. -Detailed adds window/path/start time (slower).
        Unreadable properties (protected processes) are $null; never throws.
    #>
    [CmdletBinding()]
    param([switch] $Detailed)
    $out = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        $o = [ordered]@{ Id = $p.Id; Name = $p.ProcessName; WorkingSet = $null; PrivateBytes = $null; CpuSeconds = $null; SessionId = $null }
        try { $o.WorkingSet = [long]$p.WorkingSet64 } catch { $o.WorkingSet = $null }
        try { $o.PrivateBytes = [long]$p.PrivateMemorySize64 } catch { $o.PrivateBytes = $null }
        try { $t = $p.TotalProcessorTime; if ($null -ne $t) { $o.CpuSeconds = [double]$t.TotalSeconds } } catch { $o.CpuSeconds = $null }
        try { $o.SessionId = [int]$p.SessionId } catch { $o.SessionId = $null }
        if ($Detailed) {
            $o.HasWindow = $false; $o.Path = $null; $o.StartTime = $null
            try { $o.HasWindow = ($p.MainWindowHandle -ne [IntPtr]::Zero) } catch { $o.HasWindow = $false }
            try { $o.Path = [string]$p.Path } catch { $o.Path = $null }
            try { $o.StartTime = $p.StartTime } catch { $o.StartTime = $null }
        }
        $out += [pscustomobject]$o
    }
    return $out
}

function Get-WcFileVersionText {
    <# Thin I/O: FileDescription/CompanyName of an executable. Never throws. #>
    [CmdletBinding()]
    param([string] $Path)
    $r = [pscustomobject]@{ Description = ''; Company = '' }
    if (-not $Path) { return $r }
    try {
        $vi = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        $r.Description = [string]$vi.FileDescription
        $r.Company = [string]$vi.CompanyName
    }
    catch { Write-Verbose ('Version info unavailable: ' + $Path) }
    return $r
}

function Get-WcFileSignature {
    <#
        Thin I/O: Authenticode status + signer of a file, cached by path, size and write time
        (Get-AuthenticodeSignature validates the catalog too). Never throws: errors -> 'UnknownError'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    $stamp = ''
    try { $fi = New-Object System.IO.FileInfo($Path); $stamp = ('{0}|{1}' -f $fi.Length, $fi.LastWriteTimeUtc.Ticks) } catch { $stamp = '?' }
    $key = $Path.ToLowerInvariant() + '|' + $stamp
    if ($script:WcSignatureCache.ContainsKey($key)) { return $script:WcSignatureCache[$key] }
    $res = [pscustomobject]@{ Status = 'UnknownError'; Signer = '' }
    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
        $res.Status = [string]$sig.Status
        if ($sig.SignerCertificate) { $res.Signer = ConvertTo-WcSignerName -Subject ([string]$sig.SignerCertificate.Subject) }
    }
    catch { $res.Status = 'UnknownError' }
    $script:WcSignatureCache[$key] = $res
    return $res
}

function Clear-WcSignatureCache { $script:WcSignatureCache = @{} }

function Get-WcUserWritableRoots {
    <# Thin: user-writable roots from the environment (TEMP, APPDATA, USERPROFILE\Downloads). #>
    $roots = @{ Temp = $env:TEMP; AppData = $env:APPDATA; Downloads = $null }
    if ($env:USERPROFILE) { $roots.Downloads = [System.IO.Path]::Combine($env:USERPROFILE, 'Downloads') }
    return $roots
}

function Get-WcMemoryPerfRaw {
    <# Thin I/O: one raw sample of Win32_PerfRawData_PerfOS_Memory (for the hard-fault rate). #>
    return (@(Get-WcCimData -ClassName 'Win32_PerfRawData_PerfOS_Memory') | Select-Object -First 1)
}

function Get-WcProcessCimLite {
    <# Thin I/O: Win32_Process reduced to ProcessId/Name/ExecutablePath/SessionId. CommandLine is dropped here. #>
    $rows = @()
    foreach ($c in @(Get-WcCimData -ClassName 'Win32_Process')) {
        if ($null -eq $c) { continue }
        $rows += [pscustomobject]@{
            ProcessId = (Get-WcProcValue $c 'ProcessId'); Name = (Get-WcProcValue $c 'Name')
            ExecutablePath = (Get-WcProcValue $c 'ExecutablePath'); SessionId = (Get-WcProcValue $c 'SessionId')
        }
    }
    return $rows
}

# ------------------------------------------------------------- page data --

function New-WcProcSection {
    param([string] $Id, [object[]] $Rows, [string] $Severity = 'Info', [string] $NoteKey)
    if (-not $NoteKey) { $NoteKey = ('section.processes.' + $Id + '.note') }
    $s = [ordered]@{ Id = $Id; TitleKey = ('section.processes.' + $Id); NoteKey = $NoteKey }
    $s.Rows = @($Rows)
    $s.Severity = $Severity
    $s.NoteOnly = ($Id -eq 'no-ram-cleaner')
    return [pscustomobject]$s
}

function New-WcProcFinding {
    <# Same shape as New-WcFinding (WinCare.Diagnostics) without the cross-module call. #>
    param([string] $Id, [string] $Severity, [object[]] $Evidence)
    return [pscustomobject]@{ Id = $Id; Severity = $Severity; TitleKey = "finding.$Id.title"; RecommendationKey = "finding.$Id.recommendation"; Evidence = $Evidence }
}

function Get-WcProcessesPageData {
    <#
        Page 'processes' (CONTRATO section 6). Read-only, never throws; a failed section goes to
        Errors. Takes about SampleCount x SampleIntervalSeconds seconds (default 3 x 3 s: the
        first and last snapshot also give the CPU and hard-fault samples).
    #>
    [CmdletBinding()]
    param(
        [hashtable] $Context,
        [ValidateRange(1, 200)][int] $TopCount = 25,
        [ValidateRange(2, 10)][int] $SampleCount = 3,
        [ValidateRange(0, 30)][double] $SampleIntervalSeconds = 3,
        [ValidateRange(1, 100)][int] $GrowthTopCount = 15,
        [ValidateRange(0, 200)][int] $SignatureCheckCount = 25,
        [ValidateRange(1, 100)][int] $CpuTopCount = 10
    )
    $thr = Get-WcProcessesThreshold
    $errors = @()
    $findings = @()
    $sections = @()

    # --- sampling (one pass feeds growth, CPU and hard faults) ---
    $snaps = @()
    $perfA = $null; $perfB = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tFirst = 0.0; $tLast = 0.0
    try { $perfA = Get-WcMemoryPerfRaw } catch { $errors += ('memory-overview: ' + $_.Exception.Message) }
    try {
        $snaps += , @(Get-WcProcessSnapshot -Detailed)
        $tFirst = $sw.Elapsed.TotalSeconds
        for ($i = 1; $i -lt $SampleCount; $i++) {
            if ($SampleIntervalSeconds -gt 0) { Start-Sleep -Milliseconds ([int]($SampleIntervalSeconds * 1000)) }
            $snaps += , @(Get-WcProcessSnapshot)
            $tLast = $sw.Elapsed.TotalSeconds
        }
    }
    catch { $errors += ('top-memory: ' + $_.Exception.Message) }
    try { $perfB = Get-WcMemoryPerfRaw } catch { $errors += ('memory-overview: ' + $_.Exception.Message) }
    $elapsed = $sw.Elapsed.TotalSeconds

    $inventory = @()
    try {
        $svcMap = ConvertTo-WcServiceMap -Service @(Get-WcCimData -ClassName 'Win32_Service')
        $first = @()
        if ($snaps.Count -gt 0) { $first = @($snaps[0]) }
        $inventory = @(ConvertTo-WcProcessInventory -Snapshot $first -CimProcess @(Get-WcProcessCimLite) -ServiceMap $svcMap)
    }
    catch { $errors += ('top-memory: ' + $_.Exception.Message) }

    # --- 1. memory overview ---
    try {
        $os = @(Get-WcCimData -ClassName 'Win32_OperatingSystem') | Select-Object -First 1
        $perf = @(Get-WcCimData -ClassName 'Win32_PerfFormattedData_PerfOS_Memory') | Select-Object -First 1
        $pf = @(Get-WcCimData -ClassName 'Win32_PageFileUsage')
        $comp = $null
        $mc = @($inventory | Where-Object { $_.Name -eq 'Memory Compression' }) | Select-Object -First 1
        if ($mc) { $comp = $mc.WorkingSet }
        $hf = ConvertTo-WcHardFaultRate -First $perfA -Second $perfB -ElapsedSeconds $elapsed
        $facts = ConvertTo-WcMemoryFacts -OperatingSystem $os -PerfMemory $perf -PageFile $pf -CompressedBytes $comp -HardFaultsPerSec $hf -SampleSeconds $elapsed
        $rows = @(ConvertTo-WcMemoryOverviewRows -Facts $facts -Threshold $thr)
        $sev = Get-WcProcSeverity -Status @($rows | ForEach-Object { $_.ProcStatusRaw })
        $sections += New-WcProcSection -Id 'memory-overview' -Rows $rows -Severity $sev
        foreach ($r in $rows) {
            if (@('Pressure', 'Critical') -notcontains $r.ProcStatusRaw) { continue }
            $sevF = 'Warning'
            if ($r.ProcStatusRaw -eq 'Critical') { $sevF = 'Critical' }
            $findings += New-WcProcFinding -Id 'processes-memory-pressure' -Severity $sevF -Evidence @($r.Metric, $r.Value)
        }
    }
    catch { $errors += ('memory-overview: ' + $_.Exception.Message) }

    # --- 2. top processes by memory ---
    try {
        $top = @(Select-WcTopProcess -Inventory $inventory -Top $TopCount)
        foreach ($p in $top) {
            if ($p.Path -and (-not $p.Description -or -not $p.Company)) {
                $vi = Get-WcFileVersionText -Path $p.Path
                if (-not $p.Description) { $p.Description = $vi.Description }
                if (-not $p.Company) { $p.Company = $vi.Company }
            }
        }
        $sections += New-WcProcSection -Id 'top-memory' -Rows @(ConvertTo-WcTopMemoryRows -Process $top)
    }
    catch { $errors += ('top-memory: ' + $_.Exception.Message) }

    # --- 3. growth (heuristic) ---
    try {
        $series = @(ConvertTo-WcGrowthSeries -Snapshots $snaps -Top $GrowthTopCount)
        $rows = @(ConvertTo-WcGrowthRows -Series $series -Threshold $thr)
        $growing = @($rows | Where-Object { $_.ProcStatusRaw -eq 'Growing' })
        $sev = 'Info'
        if ($growing.Count -gt 0) { $sev = 'Warning' }
        $sections += New-WcProcSection -Id 'growth' -Rows $rows -Severity $sev
        foreach ($g in $growing) { $findings += New-WcProcFinding -Id 'processes-growth-suspect' -Severity 'Info' -Evidence @($g.Name, $g.ProcPid, $g.ProcGrowth) }
    }
    catch { $errors += ('growth: ' + $_.Exception.Message) }

    # --- 4. background programs worth reviewing ---
    try {
        $roots = Get-WcUserWritableRoots
        $sigs = @{}
        if ($SignatureCheckCount -gt 0) {
            foreach ($path in @(Select-WcSignatureCandidate -Inventory $inventory -Max $SignatureCheckCount -SystemRoot $env:SystemRoot -Roots $roots)) {
                $sigs[$path.ToLowerInvariant()] = Get-WcFileSignature -Path $path
            }
        }
        $rows = @(ConvertTo-WcReviewRows -Inventory $inventory -Signature $sigs -Roots $roots)
        $sev = 'Info'
        if ($rows.Count -gt 0) { $sev = 'Warning' }
        $sections += New-WcProcSection -Id 'review' -Rows $rows -Severity $sev
    }
    catch { $errors += ('review: ' + $_.Exception.Message) }

    # --- 5. CPU now ---
    try {
        $rows = @()
        if ($snaps.Count -ge 2) {
            $rows = @(ConvertTo-WcCpuRows -First @($snaps[0]) -Last @($snaps[$snaps.Count - 1]) -ElapsedSeconds ($tLast - $tFirst) -LogicalProcessors ([System.Environment]::ProcessorCount) -Top $CpuTopCount)
        }
        $sections += New-WcProcSection -Id 'cpu-now' -Rows $rows
    }
    catch { $errors += ('cpu-now: ' + $_.Exception.Message) }

    # --- 6. why there is no RAM cleaner (note only) ---
    $sections += New-WcProcSection -Id 'no-ram-cleaner' -Rows @() -NoteKey 'processes.note.no-ram-cleaner'

    return [pscustomobject]@{ PageId = 'processes'; Sections = $sections; Findings = $findings; Errors = $errors }
}

# ============================================================ process.end ==

function Set-WcProcessEndRequest {
    <#
        How the UI passes the selected process to the 'process.end' handler:
            Set-WcProcessEndRequest -Context $ctx -ProcessId 1234 -ProcessName 'notepad' [-Force]
        stores $ctx.Parameters['process.end'] = @{ ProcessId; ProcessName; Force }.
        ProcessName (the row's Name) guards against PID reuse between preview and execution.
        -Force only after the confirmation dialog explicitly offered and the user chose "force".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Context,
        [Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int] $ProcessId,
        [string] $ProcessName,
        [switch] $Force
    )
    if (-not $Context.ContainsKey('Parameters') -or $Context['Parameters'] -isnot [hashtable]) { $Context['Parameters'] = @{} }
    $Context['Parameters']['process.end'] = @{ ProcessId = $ProcessId; ProcessName = $ProcessName; Force = [bool]$Force }
    return $Context
}

function Get-WcProcessEndRequest {
    <# Pure: reads and validates $Context.Parameters['process.end']. Throws when nothing valid was selected. #>
    [CmdletBinding()]
    param($Context)
    $req = $null
    if ($Context -is [System.Collections.IDictionary] -and $Context.Contains('Parameters') -and $Context['Parameters'] -is [System.Collections.IDictionary]) {
        $req = $Context['Parameters']['process.end']
    }
    if ($null -eq $req) { throw "process.end: no process selected (Context.Parameters['process.end'].ProcessId is missing)." }
    $procId = 0
    if (-not [int]::TryParse([string](Get-WcProcValue $req 'ProcessId'), [ref]$procId) -or $procId -le 0) { throw 'process.end: invalid ProcessId.' }
    $force = $false
    $f = Get-WcProcValue $req 'Force'
    if ($f -is [bool]) { $force = $f }
    return [pscustomobject]@{ ProcessId = $procId; ProcessName = [string](Get-WcProcValue $req 'ProcessName'); Force = $force }
}

function Test-WcProcessEndAllowed {
    <#
        Pure deny-list decision. Target: {ProcessId, Name, SessionId, Path, Company, Owner, Services[]}.
        Environment: {IsAdmin, CurrentUser, CurrentSessionId, SelfPid}.
        Reasons (localized as processes.refuse.<code>):
          not-running, pid-mismatch, self, critical-pid, critical-name, security-tool, hosts-services,
          system-account, session0, other-user, owner-unknown.
        Admin rights lift only other-user / owner-unknown; nothing lifts the rest.
    #>
    [CmdletBinding()]
    param($Target, [Parameter(Mandatory = $true)] $Environment, [string] $ExpectedName)
    $reasons = @()
    if ($null -eq $Target) { return [pscustomobject]@{ Allowed = $false; Reasons = @('not-running') } }
    $name = [string]$Target.Name
    $bare = $name -replace '(?i)\.exe$', ''
    $procId = [int]$Target.ProcessId
    if ($ExpectedName -and ($ExpectedName -replace '(?i)\.exe$', '') -ne $bare) { $reasons += 'pid-mismatch' }
    if ($procId -eq [int]$Environment.SelfPid) { $reasons += 'self' }
    if ($procId -eq 0 -or $procId -eq 4) { $reasons += 'critical-pid' }
    foreach ($n in $script:WcProcessCriticalNames) { if ($bare -eq $n) { $reasons += 'critical-name'; break } }
    $sec = $false
    foreach ($n in $script:WcProcessSecurityNames) { if ($bare -eq $n) { $sec = $true; break } }
    $company = [string](Get-WcProcValue $Target 'Company')
    if (-not $sec -and $company) { foreach ($c in $script:WcProcessSecurityCompanies) { if ($company.IndexOf($c, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $sec = $true; break } } }
    $path = [string](Get-WcProcValue $Target 'Path')
    if (-not $sec -and $path) { foreach ($frag in $script:WcProcessSecurityPaths) { if ($path.IndexOf($frag, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $sec = $true; break } } }
    if ($sec) { $reasons += 'security-tool' }
    if (@(Get-WcProcValue $Target 'Services' | Where-Object { $_ }).Count -gt 0) { $reasons += 'hosts-services' }
    $owner = [string](Get-WcProcValue $Target 'Owner')
    if ($owner) { foreach ($a in $script:WcProcessSystemAccounts) { if ($owner -eq $a) { $reasons += 'system-account'; break } } }
    $session = Get-WcProcValue $Target 'SessionId'
    $curSession = Get-WcProcValue $Environment 'CurrentSessionId'
    if ($null -ne $session -and [int]$session -eq 0 -and ($null -eq $curSession -or [int]$curSession -ne 0)) { $reasons += 'session0' }
    if (-not [bool]$Environment.IsAdmin) {
        if (-not $owner) { $reasons += 'owner-unknown' }
        elseif ($Environment.CurrentUser -and $owner -ne [string]$Environment.CurrentUser) { $reasons += 'other-user' }
    }
    $reasons = @($reasons | Select-Object -Unique)
    return [pscustomobject]@{ Allowed = ($reasons.Count -eq 0); Reasons = $reasons }
}

function Get-WcProcessEndEnvironment {
    <# Thin I/O: who/where WinCare runs. #>
    $user = $null
    try { $user = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { $user = $null }
    $session = $null
    try { $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId } catch { $session = $null }
    return [pscustomobject]@{ IsAdmin = [bool](Test-WcIsAdmin); CurrentUser = $user; CurrentSessionId = $session; SelfPid = $PID }
}

function Get-WcProcessEndTarget {
    <#
        Thin I/O: facts about ONE process for the deny-list. $null when it is not running.
        Owner via Win32_Process.GetOwner (DOMAIN\user; $null when access is denied).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateRange(1, 2147483647)][int] $ProcessId)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $null }
    $t = [ordered]@{ ProcessId = $ProcessId; Name = $p.ProcessName; SessionId = $null; Path = $null; Company = ''; Description = ''
        Owner = $null; Services = @(); WorkingSet = $null; PrivateBytes = $null; HasWindow = $false
    }
    try { $t.SessionId = [int]$p.SessionId } catch { $t.SessionId = $null }
    try { $t.WorkingSet = [long]$p.WorkingSet64 } catch { $t.WorkingSet = $null }
    try { $t.PrivateBytes = [long]$p.PrivateMemorySize64 } catch { $t.PrivateBytes = $null }
    try { $t.HasWindow = ($p.MainWindowHandle -ne [IntPtr]::Zero) } catch { $t.HasWindow = $false }
    try { $t.Path = [string]$p.Path } catch { $t.Path = $null }
    $cim = @(Get-WcCimData -ClassName 'Win32_Process' -Filter ('ProcessId = {0}' -f $ProcessId)) | Select-Object -First 1
    if ($cim) {
        if (-not $t.Path) { $t.Path = [string](Get-WcProcValue $cim 'ExecutablePath') }
        try {
            $o = Invoke-CimMethod -InputObject $cim -MethodName 'GetOwner' -ErrorAction Stop
            if ($o -and [int]$o.ReturnValue -eq 0 -and $o.User) {
                if ($o.Domain) { $t.Owner = ('{0}\{1}' -f $o.Domain, $o.User) } else { $t.Owner = [string]$o.User }
            }
        }
        catch { $t.Owner = $null }
    }
    $t.Services = @(@(Get-WcCimData -ClassName 'Win32_Service' -Filter ('ProcessId = {0}' -f $ProcessId)) | Where-Object { $_ } | ForEach-Object { [string](Get-WcProcValue $_ 'Name') })
    if ($t.Path) {
        $vi = Get-WcFileVersionText -Path $t.Path
        $t.Company = $vi.Company; $t.Description = $vi.Description
    }
    return [pscustomobject]$t
}

function Invoke-WcProcessClose {
    <# Thin I/O: CloseMainWindow (graceful, like clicking X) and wait. Returns {SentClose, Exited}. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $ProcessId, [int] $GraceSeconds = 10)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return [pscustomobject]@{ SentClose = $false; Exited = $true } }
    $sent = $false
    try { $sent = $p.CloseMainWindow() } catch { $sent = $false }
    $exited = $false
    if ($sent) { try { $exited = $p.WaitForExit($GraceSeconds * 1000) } catch { $exited = $false } }
    return [pscustomobject]@{ SentClose = [bool]$sent; Exited = [bool]$exited }
}

function Invoke-WcProcessStop {
    <# Thin I/O: Stop-Process (TerminateProcess - unsaved work is lost) and wait. Returns $true when gone. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int] $ProcessId, [int] $WaitSeconds = 5)
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if (-not $p) { return $true }
    Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    try { return [bool]$p.WaitForExit($WaitSeconds * 1000) } catch { return $true }
}

function ConvertTo-WcProcessEndItem {
    <# Pure: target -> preview/result row. #>
    param($Target, [string] $Mode, [string] $Status)
    return [pscustomobject]@{
        Name = $Target.Name; ProcPid = $Target.ProcessId; ProcWorkingSet = (ConvertTo-WcProcBytesText $Target.WorkingSet)
        ProcPrivate = (ConvertTo-WcProcBytesText $Target.PrivateBytes); Path = $Target.Path; User = $Target.Owner; Mode = $Mode; Status = $Status
    }
}

function Invoke-WcProcessEnd {
    <#
        Preview (default) or -Execute for process.end. Execute re-reads the process and re-applies
        the deny-list; then CloseMainWindow + wait (-GraceSeconds); Stop-Process only if the request
        has Force=$true. Without Force a process that does not close is reported as a failure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Context, [switch] $Execute, [int] $GraceSeconds = 10)
    $req = Get-WcProcessEndRequest -Context $Context
    $target = Get-WcProcessEndTarget -ProcessId $req.ProcessId
    $envInfo = Get-WcProcessEndEnvironment
    $decision = Test-WcProcessEndAllowed -Target $target -Environment $envInfo -ExpectedName $req.ProcessName
    $label = ('{0} (PID {1})' -f $req.ProcessName, $req.ProcessId)
    if ($target) { $label = ('{0} (PID {1})' -f $target.Name, $target.ProcessId) }
    $mode = 'graceful'
    if ($req.Force) { $mode = 'graceful-then-force' }
    if (-not $decision.Allowed) {
        $msg = ('process.end refused for {0}: {1}.' -f $label, ($decision.Reasons -join ', '))
        if ($Execute) {
            Write-WcLog -Level Audit -Category 'Processes' -Message $msg | Out-Null
            throw $msg
        }
        $items = @()
        if ($target) { $items = @(ConvertTo-WcProcessEndItem -Target $target -Mode $mode -Status 'Refused') }
        $r = New-WcActionResult -Summary ('Would refuse. ' + $msg) -Items $items
        $r | Add-Member -NotePropertyName Refused -NotePropertyValue $decision.Reasons
        return $r
    }
    if (-not $Execute) {
        $how = 'Stop-Process only if the confirmation explicitly says Force (unsaved work is lost)'
        if ($req.Force) { $how = 'then Stop-Process (Force confirmed; unsaved work is lost)' }
        $summary = ('Would ask {0}, {1} working set / {2} private, to close (CloseMainWindow, wait {3} s); {4}.' -f $label, (ConvertTo-WcProcBytesText $target.WorkingSet), (ConvertTo-WcProcBytesText $target.PrivateBytes), $GraceSeconds, $how)
        return (New-WcActionResult -Summary $summary -Items @(ConvertTo-WcProcessEndItem -Target $target -Mode $mode -Status 'Pending') -BytesBefore $target.PrivateBytes)
    }
    Write-WcLog -Level Audit -Category 'Processes' -Message ('Ending {0} (mode {1}, owner {2}).' -f $label, $mode, $target.Owner) | Out-Null
    $close = Invoke-WcProcessClose -ProcessId $target.ProcessId -GraceSeconds $GraceSeconds
    if ($close.Exited) {
        $msg = ('{0} closed gracefully.' -f $label)
        Write-WcLog -Level Audit -Category 'Processes' -Message $msg | Out-Null
        return (New-WcActionResult -Summary $msg -Items @(ConvertTo-WcProcessEndItem -Target $target -Mode $mode -Status 'Closed') -BytesBefore $target.PrivateBytes -BytesAfter 0 -BytesFreed $target.PrivateBytes)
    }
    if (-not $req.Force) {
        $why = 'no main window'
        if ($close.SentClose) { $why = ('close request not completed in {0} s' -f $GraceSeconds) }
        $msg = ('{0} is still running ({1}); not forced because the confirmation did not say Force.' -f $label, $why)
        Write-WcLog -Level Audit -Category 'Processes' -Message $msg | Out-Null
        throw $msg
    }
    $gone = Invoke-WcProcessStop -ProcessId $target.ProcessId
    if (-not $gone) {
        $msg = ('{0} did not exit after Stop-Process.' -f $label)
        Write-WcLog -Level Audit -Category 'Processes' -Message $msg | Out-Null
        throw $msg
    }
    $msg = ('{0} ended with Stop-Process (forced after graceful close failed).' -f $label)
    Write-WcLog -Level Audit -Category 'Processes' -Message $msg | Out-Null
    return (New-WcActionResult -Summary $msg -Items @(ConvertTo-WcProcessEndItem -Target $target -Mode $mode -Status 'Forced') -BytesBefore $target.PrivateBytes -BytesAfter 0 -BytesFreed $target.PrivateBytes)
}

function Measure-WcProcessEndTarget {
    <# F5 Measure: is the selected process running and its working set (read-only). #>
    [CmdletBinding()]
    param($Context)
    $req = Get-WcProcessEndRequest -Context $Context
    $p = Get-Process -Id $req.ProcessId -ErrorAction SilentlyContinue
    $running = 0; $ws = 0L
    if ($p -and (-not $req.ProcessName -or $p.ProcessName -eq ($req.ProcessName -replace '(?i)\.exe$', ''))) {
        $running = 1
        try { $ws = [long]$p.WorkingSet64 } catch { $ws = 0L }
    }
    $target = ('PID {0}' -f $req.ProcessId)
    return @(
        (New-WcMetric -Source Action -Name 'ProcessRunning' -Target $target -Unit 'Count' -Value $running),
        (New-WcMetric -Source Action -Name 'ProcessWorkingSet' -Target $target -Unit 'Bytes' -Value $ws)
    )
}

# ============================================= memory.schedule-diagnostic ==

function Get-WcMdSchedPath {
    <# Pure: absolute path of MdSched.exe (Sysnative from a 32-bit host on 64-bit Windows). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $SystemRoot = $env:SystemRoot, [bool] $Is64BitOs = [System.Environment]::Is64BitOperatingSystem, [bool] $Is64BitProcess = [System.Environment]::Is64BitProcess)
    if (-not $SystemRoot) { throw 'SystemRoot is not defined.' }
    $dir = 'System32'
    if ($Is64BitOs -and -not $Is64BitProcess) { $dir = 'Sysnative' }
    return ($SystemRoot.TrimEnd('\') + '\' + $dir + '\MdSched.exe')
}

function Start-WcMdSched {
    <# Thin I/O: opens the Windows Memory Diagnostic dialog (UAC prompt). Never passes arguments. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    Start-Process -FilePath $Path | Out-Null
}

function Invoke-WcMemoryDiagnostic {
    <#
        memory.schedule-diagnostic. MdSched.exe has no documented command-line switch to schedule
        the test silently, so WinCare only OPENS it; the user picks "Restart now and check" or
        "Check for problems the next time I start my computer". WinCare never restarts the PC.
    #>
    [CmdletBinding()]
    param([switch] $Execute)
    $path = Get-WcMdSchedPath
    $item = [pscustomobject]@{ Item = 'MdSched.exe'; Value = $path; Source = 'Windows Memory Diagnostic (interactive)' }
    if (-not $Execute) {
        return (New-WcActionResult -Summary ('Would open {0}. No silent scheduling switch is documented: you choose "restart now" or "next start" in the dialog. WinCare never restarts the computer.' -f $path) -Items @($item))
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('MdSched.exe not found: {0}' -f $path) }
    Write-WcLog -Level Audit -Category 'Processes' -Message ('Opening the Windows Memory Diagnostic: ' + $path) | Out-Null
    Start-WcMdSched -Path $path
    return (New-WcActionResult -Summary ('Opened {0}. Choose in the dialog when to test; save your work first if you pick "restart now". WinCare did not schedule or restart anything by itself.' -f $path) -Items @($item))
}

# ------------------------------------------------------------- handlers --

function Register-WcProcessesHandler {
    <# Called lazily by Core (Initialize-WcActionHandlers). #>
    [CmdletBinding()]
    param()
    Register-WcActionHandler -Name 'Processes-End' -Preview { param($Context) Invoke-WcProcessEnd -Context $Context } -Execute { param($Context) Invoke-WcProcessEnd -Context $Context -Execute } -Measure { param($Context) Measure-WcProcessEndTarget -Context $Context }
    Register-WcActionHandler -Name 'Memory-ScheduleDiagnostic' -Preview { param($Context) Invoke-WcMemoryDiagnostic } -Execute { param($Context) Invoke-WcMemoryDiagnostic -Execute }
}

Export-ModuleMember -Function @(
    'Get-WcProcessesPageData', 'Get-WcProcessesThreshold', 'Register-WcProcessesHandler',
    'Get-WcLevelStatus', 'Get-WcProcSeverity', 'ConvertTo-WcProcBytesText', 'ConvertTo-WcHardFaultRate', 'ConvertTo-WcMemoryFacts', 'ConvertTo-WcMemoryOverviewRows',
    'ConvertTo-WcProcessKind', 'ConvertTo-WcServiceMap', 'ConvertTo-WcServiceListText', 'ConvertTo-WcProcessInventory', 'Select-WcTopProcess', 'ConvertTo-WcTopMemoryRows',
    'Test-WcProcessGrowth', 'ConvertTo-WcGrowthSeries', 'ConvertTo-WcGrowthRows', 'ConvertTo-WcCpuRows',
    'ConvertTo-WcProcessLocationKind', 'Test-WcProcessWorthReview', 'Select-WcSignatureCandidate', 'ConvertTo-WcSignerName', 'ConvertTo-WcReviewRows',
    'Get-WcProcessSnapshot', 'Get-WcFileVersionText', 'Get-WcFileSignature', 'Clear-WcSignatureCache', 'Get-WcUserWritableRoots', 'Get-WcMemoryPerfRaw', 'Get-WcProcessCimLite',
    'Set-WcProcessEndRequest', 'Get-WcProcessEndRequest', 'Test-WcProcessEndAllowed', 'Get-WcProcessEndEnvironment', 'Get-WcProcessEndTarget',
    'Invoke-WcProcessClose', 'Invoke-WcProcessStop', 'Invoke-WcProcessEnd', 'Measure-WcProcessEndTarget',
    'Get-WcMdSchedPath', 'Start-WcMdSched', 'Invoke-WcMemoryDiagnostic'
)

# Handlers are NOT registered at import time: Core's Initialize-WcActionHandlers
# (called by New-WcPlan) invokes the exported Register-WcProcessesHandler.
