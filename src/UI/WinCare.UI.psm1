#Requires -Version 5.1
<#
    WinCare.UI - WPF shell. WINDOWS ONLY (needs .NET Framework WPF and an STA thread).
    Not loaded on Linux; covered there only by static XAML tests.

    Threading model:
      * The WPF dispatcher thread never runs diagnostics.
      * Long work runs in a separate runspace (Start-WcUiJob) that imports the
        WinCare manifest; a DispatcherTimer polls completion and drains the log
        queue, so all UI updates happen on the UI thread.
      * Cancel calls PowerShell.BeginStop() on running jobs.
#>

$script:Ui = $null

$script:PageDefs = [ordered]@{
    overview    = @{ Xaml = 'Overview.xaml' }
    diagnostics = @{ Xaml = 'Diagnostics.xaml' }
    quick       = @{ Xaml = 'Actions.xaml'; Actions = $true }
    advanced    = @{ Xaml = 'Actions.xaml'; Actions = $true }
    storage     = @{ Xaml = 'Storage.xaml' }
    startup     = @{ Xaml = 'Startup.xaml' }
    office      = @{ Xaml = 'Actions.xaml'; Actions = $true }
    integrity   = @{ Xaml = 'Actions.xaml'; Actions = $true }
    security    = @{ Xaml = 'Security.xaml' }
    reports     = @{ Xaml = 'Reports.xaml' }
    settings    = @{ Xaml = 'Settings.xaml' }
}

# ------------------------------------------------------------------ helpers --

function Import-WcXaml {
    <# Loads a XAML file with DTD processing disabled. #>
    param([Parameter(Mandatory = $true)][string] $Path)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $settings)
    try { return [System.Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
}

function Invoke-WcUiSafe {
    <# Runs an event-handler body; errors are logged and shown, never crash the window. #>
    param([scriptblock] $Body)
    try { & $Body }
    catch {
        Write-WcLog -Level Error -Category 'UI' -Message $_.Exception.Message | Out-Null
        # Headless (snapshot/CI): never open a modal dialog nobody can close.
        if ($script:Ui -and $script:Ui.Headless) { [void]$script:Ui.Errors.Add(('{0} @ {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage)); return }
        [System.Windows.MessageBox]::Show($_.Exception.Message, 'WinCare Enterprise', 'OK', 'Error') | Out-Null
    }
}

function Get-WcUiElement {
    param($Root, [string] $Name)
    $el = $Root.FindName($Name)
    if ($null -eq $el) { throw "XAML element not found: $Name" }
    return $el
}

function Get-WcRawString {
    param([string] $Key)
    return (Get-WcLocalizedValue -Key $Key)
}

function Format-WcPercent {
    param($Value)
    if ($null -eq $Value) { return '-' }
    return ('{0:N1}%' -f [double]$Value)
}

# ---------------------------------------------------------------- resources --

function Set-WcTheme {
    param([ValidateSet('Dark', 'Light')][string] $Theme)
    $dict = Import-WcXaml -Path (Join-Path $script:Ui.UiRoot ("Themes\$Theme.xaml"))
    $script:Ui.Window.Resources.MergedDictionaries[0] = $dict
    $script:Ui.Settings.Theme = $Theme
}

function Set-WcStrings {
    param([string] $Language)
    Import-WcLocalization -Root $script:Ui.LocRoot -Language $Language | Out-Null
    $dict = New-Object System.Windows.ResourceDictionary
    $all = Get-WcLocalizedValue
    foreach ($k in $all.Keys) {
        if ($all[$k] -is [string]) { $dict[('str.' + $k)] = $all[$k] }
    }
    $script:Ui.Window.Resources.MergedDictionaries[2] = $dict
    $script:Ui.Settings.Language = $Language
}

# --------------------------------------------------------------- async jobs --

function Start-WcUiJob {
    <#
        Runs $Script in a background runspace with the WinCare manifest imported.
        $OnComplete runs on the UI thread with (output, errorText).
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [Parameter(Mandatory = $true)][scriptblock] $Script,
        [hashtable] $Arguments = @{},
        [Parameter(Mandatory = $true)][scriptblock] $OnComplete
    )
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule([string[]]@($script:Ui.ManifestPath))
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($iss)
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('WcLogQueue', $script:Ui.LogQueue)
    $rs.SessionStateProxy.SetVariable('WcLogFile', (Get-WcLogPath))
    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $wrapper = 'param($Body, $Arguments) Initialize-WcLog -Path $WcLogFile -Sink $WcLogQueue | Out-Null; $sb = [scriptblock]::Create($Body); & $sb $Arguments'
    [void]$ps.AddScript($wrapper).AddArgument($Script.ToString()).AddArgument($Arguments)
    $job = @{ Name = $Name; PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); OnComplete = $OnComplete; Cancelled = $false }
    $script:Ui.Jobs.Add($job) | Out-Null
    Write-WcLog -Category 'UI' -Message ("Job started: {0}" -f $Name) | Out-Null
    Update-WcBusyState
}

function Stop-WcUiJobs {
    foreach ($j in @($script:Ui.Jobs)) {
        if (-not $j.Handle.IsCompleted) {
            $j.Cancelled = $true
            [void]$j.PS.BeginStop($null, $null)
            Write-WcLog -Level Warning -Category 'UI' -Message ("Cancel requested: {0}" -f $j.Name) | Out-Null
        }
    }
}

function Complete-WcUiJobs {
    foreach ($j in @($script:Ui.Jobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        $script:Ui.Jobs.Remove($j)
        $output = $null; $err = $null
        try {
            $output = $j.PS.EndInvoke($j.Handle)
            if ($j.PS.Streams.Error.Count -gt 0) { $err = ($j.PS.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ' }
        }
        catch {
            if ($j.Cancelled) { $err = Get-WcString 'status.cancelled' } else { $err = $_.Exception.Message }
        }
        finally {
            $j.PS.Dispose()
            $j.Runspace.Dispose()
        }
        $result = $null
        if ($output -and $output.Count -gt 0) { $result = $output[$output.Count - 1] }
        $cb = $j.OnComplete
        Invoke-WcUiSafe { & $cb $result $err }
    }
    Update-WcBusyState
}

function Update-WcBusyState {
    $busy = ($script:Ui.Jobs.Count -gt 0)
    $w = $script:Ui.Window
    if ($busy) { $w.FindName('BusyBar').Visibility = 'Visible' } else { $w.FindName('BusyBar').Visibility = 'Hidden' }
    $w.FindName('CancelButton').IsEnabled = $busy
    $w.FindName('RefreshButton').IsEnabled = -not $busy
    $page = $script:Ui.Pages['diagnostics']
    if ($page) { $page.FindName('RunDiagnosticButton').IsEnabled = -not $busy }
    foreach ($id in @($script:PageDefs.Keys)) {
        if ($script:PageDefs[$id].Actions -and $script:Ui.Pages[$id]) {
            $script:Ui.Pages[$id].FindName('PreviewButton').IsEnabled = -not $busy
            $script:Ui.Pages[$id].FindName('RunButton').IsEnabled = -not $busy
        }
    }
}

function Receive-WcLogQueue {
    $box = $script:Ui.Window.FindName('LogBox')
    $line = $null
    $added = $false
    while ($script:Ui.LogQueue.TryDequeue([ref]$line)) {
        $box.AppendText($line + [Environment]::NewLine)
        $script:Ui.Window.FindName('StatusText').Text = $line
        $added = $true
    }
    if ($added) {
        if ($box.LineCount -gt 2000) { $box.Text = ($box.Text -split [Environment]::NewLine | Select-Object -Last 1500) -join [Environment]::NewLine }
        $box.ScrollToEnd()
    }
}

# --------------------------------------------------------------- diagnostic --

function Start-WcDiagnostic {
    $args0 = @{ CatalogPath = $script:Ui.CatalogPath; Version = $script:Ui.Version; Profile = $script:Ui.Settings.Profile }
    Start-WcUiJob -Name 'diagnostic' -Arguments $args0 -Script {
        param($a)
        Invoke-WcDiagnostic -CatalogPath $a.CatalogPath -AppVersion $a.Version -OperationProfileName $a.Profile
    } -OnComplete {
        param($result, $err)
        if ($err) { Write-WcLog -Level Error -Category 'Diagnostic' -Message $err | Out-Null }
        if ($result) {
            $script:Ui.Snapshot = $result
            Write-WcLog -Category 'Diagnostic' -Message ("Diagnostic finished: {0} finding(s), {1} section error(s)." -f @($result.Findings).Count, @($result.Errors).Count) | Out-Null
            Update-WcAllPages
        }
    }
}

# ------------------------------------------------------------------- render --

function Set-WcGridRows {
    param($Grid, [object[]] $Rows)
    $Grid.ItemsSource = $null
    $clean = @($Rows | Where-Object { $null -ne $_ })
    $Grid.ItemsSource = $clean
}

function Update-WcHeader {
    $w = $script:Ui.Window
    $w.FindName('ProfileBadge').Text = (Get-WcString 'header.profile') + ': ' + (Get-WcString ('profile.' + $script:Ui.Settings.Profile))
    if ($script:Ui.IsAdmin) { $w.FindName('AdminBadge').Text = Get-WcString 'header.admin' } else { $w.FindName('AdminBadge').Text = Get-WcString 'header.standard-user' }
    $snap = $script:Ui.Snapshot
    $managedText = Get-WcString 'header.managed-unknown'
    if ($snap -and $snap.Security) {
        if ($snap.Security.Management.IsManaged) { $managedText = Get-WcString 'header.managed' } else { $managedText = Get-WcString 'header.unmanaged' }
    }
    $w.FindName('ManagedBadge').Text = $managedText
    $w.FindName('VersionText').Text = 'v' + $script:Ui.Version
}

function Update-WcOverview {
    $p = $script:Ui.Pages['overview']; if (-not $p) { return }
    $s = $script:Ui.Snapshot; if (-not $s) { return }
    if ($s.System) {
        $win = $s.System.Windows
        $p.FindName('WinFamilyText').Text = ('{0} {1}' -f $win.Family, $win.Edition)
        $p.FindName('WinDetailText').Text = ('{0} | build {1}.{2} | {3}' -f $win.DisplayVersion, $win.Build, $win.Ubr, $win.Architecture)
        $cpu = $s.System.Cpu
        $p.FindName('CpuUsageText').Text = Format-WcPercent $cpu.UsagePercent
        if ($null -ne $cpu.UsagePercent) { $p.FindName('CpuBar').Value = [double]$cpu.UsagePercent }
        $p.FindName('CpuDetailText').Text = ('{0} | {1}C/{2}T' -f $cpu.Name, $cpu.Cores, $cpu.LogicalProcessors)
        $m = $s.System.Memory
        $p.FindName('RamUsageText').Text = Format-WcPercent $m.UsedPercent
        if ($null -ne $m.UsedPercent) { $p.FindName('RamBar').Value = [double]$m.UsedPercent }
        $p.FindName('RamDetailText').Text = Get-WcString 'card.memory-detail' -Arguments @((Format-WcBytes $m.AvailableBytes), (Format-WcBytes $m.TotalBytes))
        $up = $s.System.Uptime
        if ($up) { $p.FindName('UptimeText').Text = ('{0}d {1}h {2}min' -f $up.Days, $up.Hours, $up.Minutes) }
        $pr = $s.System.PendingReboot
        if ($pr -and $pr.IsPending) { $p.FindName('RebootText').Text = Get-WcString 'card.reboot-pending' -Arguments @(($pr.Sources -join ', ')) }
        elseif ($pr) { $p.FindName('RebootText').Text = Get-WcString 'card.reboot-none' }
    }
    $sysVol = @($s.Storage | Where-Object { $_ -and $_.IsSystem }) | Select-Object -First 1
    if ($sysVol) {
        $usedPct = $null
        if ($null -ne $sysVol.FreePercent) { $usedPct = 100 - $sysVol.FreePercent }
        $p.FindName('DiskUsageText').Text = Get-WcString 'card.disk-free' -Arguments @((Format-WcBytes $sysVol.FreeBytes))
        if ($null -ne $usedPct) { $p.FindName('DiskBar').Value = [double]$usedPct }
        $p.FindName('DiskDetailText').Text = ('{0} | {1} | {2} {3}' -f $sysVol.Drive, (Format-WcBytes $sysVol.SizeBytes), $sysVol.MediaType, $sysVol.BusType)
    }
    if ($s.Security) {
        $mg = $s.Security.Management
        if ($mg.IsManaged) { $p.FindName('ManagedText').Text = Get-WcString 'header.managed' } else { $p.FindName('ManagedText').Text = Get-WcString 'header.unmanaged' }
        $sig = Get-WcString 'card.management-none'
        if (@($mg.Signals).Count -gt 0) { $sig = (@($mg.Signals) | ForEach-Object { Get-WcString ('signal.' + $_) }) -join ', ' }
        $p.FindName('ManagedDetailText').Text = $sig
    }
    $items = @()
    foreach ($f in @($s.Findings)) {
        if ($null -eq $f) { continue }
        $items += [pscustomobject]@{
            Severity       = $f.Severity
            SeverityText   = Get-WcString ('severity.' + $f.Severity)
            Title          = Get-WcString -Key $f.TitleKey -Arguments $f.Evidence
            Recommendation = Get-WcString -Key $f.RecommendationKey -Arguments $f.Evidence
        }
    }
    $p.FindName('FindingsList').ItemsSource = $items
    if ($items.Count -gt 0) { $p.FindName('FindingsEmptyText').Visibility = 'Collapsed' } else { $p.FindName('FindingsEmptyText').Visibility = 'Visible' }
}

function Update-WcDiagnosticsPage {
    $p = $script:Ui.Pages['diagnostics']; if (-not $p) { return }
    $s = $script:Ui.Snapshot; if (-not $s) { return }
    $p.FindName('LastRunText').Text = Get-WcString 'diagnostics.last-run' -Arguments @(([datetime]$s.Meta.Created).ToLocalTime().ToString('g'), $s.Meta.DurationMs)
    $rows = @()
    if ($s.System) {
        $w = $s.System.Windows
        $rows += [pscustomobject]@{ Item = 'Windows'; Value = ('{0} {1} ({2})' -f $w.Family, $w.Edition, $w.EditionId); Source = 'Win32_OperatingSystem, CurrentVersion' }
        $rows += [pscustomobject]@{ Item = 'Build'; Value = ('{0}.{1} {2} | {3}' -f $w.Build, $w.Ubr, $w.DisplayVersion, $w.Architecture); Source = 'Win32_OperatingSystem, CurrentVersion' }
        $rows += [pscustomobject]@{ Item = 'LTSC / IoT'; Value = ('{0} / {1}' -f $w.IsLtsc, $w.IsIoT); Source = 'EditionID' }
        $rows += [pscustomobject]@{ Item = (Get-WcString 'diagnostics.matrix'); Value = [string]$w.InSupportMatrix; Source = 'docs/COMPATIBILIDADE.md' }
        $rows += [pscustomobject]@{ Item = 'CPU'; Value = ('{0} | {1} | {2}C/{3}T' -f $s.System.Cpu.Name, (Format-WcPercent $s.System.Cpu.UsagePercent), $s.System.Cpu.Cores, $s.System.Cpu.LogicalProcessors); Source = $s.System.Cpu.UsageMethod }
        $rows += [pscustomobject]@{ Item = 'RAM'; Value = ('{0} / {1} ({2})' -f (Format-WcBytes $s.System.Memory.AvailableBytes), (Format-WcBytes $s.System.Memory.TotalBytes), (Format-WcPercent $s.System.Memory.UsedPercent)); Source = 'Win32_ComputerSystem, Win32_OperatingSystem' }
        if ($s.System.Uptime) { $rows += [pscustomobject]@{ Item = 'Uptime'; Value = ('{0}d {1}h {2}min' -f $s.System.Uptime.Days, $s.System.Uptime.Hours, $s.System.Uptime.Minutes); Source = 'LastBootUpTime' } }
        $rows += [pscustomobject]@{ Item = (Get-WcString 'diagnostics.reboot'); Value = ('{0} {1} | PendingFileRename={2}' -f $s.System.PendingReboot.IsPending, ($s.System.PendingReboot.Sources -join ','), $s.System.PendingReboot.PendingFileRename); Source = 'Registry (CBS, WindowsUpdate, Session Manager)' }
        $rows += [pscustomobject]@{ Item = 'PowerShell'; Value = ('{0} {1} | admin={2}' -f $s.System.PowerShell, $s.System.PSEdition, $s.System.IsAdmin); Source = '$PSVersionTable' }
    }
    Set-WcGridRows -Grid $p.FindName('SystemGrid') -Rows $rows
    $errs = @($s.Errors | Where-Object { $_ })
    Set-WcGridRows -Grid $p.FindName('ErrorsGrid') -Rows $errs
    if ($errs.Count -gt 0) { $p.FindName('ErrorsEmptyText').Visibility = 'Collapsed' } else { $p.FindName('ErrorsEmptyText').Visibility = 'Visible' }
}

function Update-WcStoragePage {
    $p = $script:Ui.Pages['storage']; if (-not $p) { return }
    $s = $script:Ui.Snapshot; if (-not $s) { return }
    $rows = foreach ($v in @($s.Storage | Where-Object { $_ })) {
        [pscustomobject]@{ Drive = $v.Drive; Label = $v.Label; FileSystem = $v.FileSystem; Size = (Format-WcBytes $v.SizeBytes); Free = (Format-WcBytes $v.FreeBytes)
            FreePercent = (Format-WcPercent $v.FreePercent); MediaType = $v.MediaType; BusType = $v.BusType; Model = $v.Model; IsSystem = $v.IsSystem }
    }
    Set-WcGridRows -Grid $p.FindName('StorageGrid') -Rows @($rows)
}

function Update-WcStartupPage {
    $p = $script:Ui.Pages['startup']; if (-not $p) { return }
    $s = $script:Ui.Snapshot; if (-not $s) { return }
    $procs = foreach ($x in @($s.Processes | Where-Object { $_ })) {
        [pscustomobject]@{ Name = $x.Name; Id = $x.Id; Memory = (Format-WcBytes $x.WorkingSetBytes); CpuSecondsTotal = $x.CpuSecondsTotal; Company = $x.Company }
    }
    Set-WcGridRows -Grid $p.FindName('ProcessGrid') -Rows @($procs)
    Set-WcGridRows -Grid $p.FindName('StartupGrid') -Rows @($s.Startup)
}

function Update-WcSecurityPage {
    $p = $script:Ui.Pages['security']; if (-not $p) { return }
    $s = $script:Ui.Snapshot; if (-not $s -or -not $s.Security) { return }
    $mg = $s.Security.Management
    $rows = @()
    foreach ($sig in @('DomainJoined', 'AzureAdJoined', 'MdmEnrolled', 'PolicyKeys')) {
        $rows += [pscustomobject]@{ Signal = (Get-WcString ('signal.' + $sig)); Detected = (@($mg.Signals) -contains $sig) }
    }
    if ($mg.Domain) { $rows += [pscustomobject]@{ Signal = 'Domain'; Detected = $mg.Domain } }
    if ($mg.MdmProvider) { $rows += [pscustomobject]@{ Signal = 'MDM ProviderID'; Detected = $mg.MdmProvider } }
    Set-WcGridRows -Grid $p.FindName('ManagementGrid') -Rows $rows
    $pr = $s.Security.Protection
    $unknown = Get-WcString 'common.unknown'
    $fmt = { param($v) if ($null -eq $v) { $unknown } else { [string]$v } }
    $prot = @(
        [pscustomobject]@{ Protection = 'Microsoft Defender (service)'; State = (& $fmt $pr.DefenderService) }
        [pscustomobject]@{ Protection = 'Microsoft Defender (real-time)'; State = (& $fmt $pr.DefenderRealTime) }
        [pscustomobject]@{ Protection = 'Windows Firewall (all profiles)'; State = (& $fmt $pr.FirewallAllProfiles) }
    )
    Set-WcGridRows -Grid $p.FindName('ProtectionGrid') -Rows $prot
}

function Update-WcReportsPage {
    $p = $script:Ui.Pages['reports']; if (-not $p) { return }
    $dir = $script:Ui.ReportsDir
    $p.FindName('ReportsFolderText').Text = (Get-WcString 'reports.folder') + ' ' + $dir
    $p.FindName('LogFileText').Text = (Get-WcString 'reports.logfile') + ' ' + (Get-WcLogPath)
    $hasSnap = ($null -ne $script:Ui.Snapshot)
    $p.FindName('ExportJsonButton').IsEnabled = $hasSnap
    $p.FindName('ExportHtmlButton').IsEnabled = $hasSnap
    $files = @()
    if (Test-Path -LiteralPath $dir) {
        $files = Get-ChildItem -LiteralPath $dir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 50 |
            ForEach-Object { [pscustomobject]@{ File = $_.Name; Modified = $_.LastWriteTime.ToString('g'); Size = (Format-WcBytes $_.Length) } }
    }
    Set-WcGridRows -Grid $p.FindName('HistoryGrid') -Rows @($files)
    $hist = foreach ($h in @(Read-WcHistory -Directory (Join-Path (Get-WcDataRoot) 'history') -Last 200)) {
        $freed = ''; if ($null -ne $h.bytesFreed) { $freed = Format-WcBytes $h.bytesFreed }
        [pscustomobject]@{ Modified = ([datetime]$h.time).ToLocalTime().ToString('g'); Action = (Get-WcString ('action.' + $h.action)); Mode = $h.mode; Status = $h.status; Summary = $h.summary; Freed = $freed }
    }
    [array]::Reverse($hist)
    Set-WcGridRows -Grid $p.FindName('ActionsHistoryGrid') -Rows @($hist)
}

function Get-WcUiContext {
    $s = $script:Ui.Snapshot
    $managed = $false; $build = 0; $edition = ''
    if ($s -and $s.Security -and $s.Security.Management) { $managed = [bool]$s.Security.Management.IsManaged }
    if ($s -and $s.System -and $s.System.Windows) { $build = [int]$s.System.Windows.Build; $edition = [string]$s.System.Windows.EditionId }
    return (New-WcContext -IsAdmin $script:Ui.IsAdmin -IsManaged $managed -Build $build -EditionId $edition -IsWindows (Test-WcIsWindows))
}

function Get-WcPageActions {
    param([string] $PageId)
    return @($script:Ui.Catalog | Where-Object { $_.ContainsKey('Pages') -and (@($_.Pages) -contains $PageId) })
}

function Update-WcActionsPage {
    param([string] $PageId)
    $p = $script:Ui.Pages[$PageId]; if (-not $p) { return }
    $p.FindName('ActionsIntro').Text = Get-WcString ("actions.intro.$PageId")
    $prof = Get-WcProfile $script:Ui.Settings.Profile
    if ($prof.AllowModify) { $p.FindName('ActionsProfileHint').Visibility = 'Collapsed' }
    else {
        $p.FindName('ActionsProfileHint').Visibility = 'Visible'
        $p.FindName('ActionsProfileHint').Text = Get-WcString 'actions.profile-hint' -Arguments @((Get-WcString ('profile.' + $prof.Name)))
    }
    $list = $p.FindName('ActionsList')
    $list.Children.Clear()
    $ctx = Get-WcUiContext
    $actions = Get-WcPageActions -PageId $PageId
    if ($actions.Count -gt 0) { $p.FindName('ActionsEmptyText').Visibility = 'Collapsed' } else { $p.FindName('ActionsEmptyText').Visibility = 'Visible' }
    foreach ($a in $actions) {
        $decision = Test-WcActionAllowed -Action $a -OperationProfile $prof -Context $ctx
        $border = New-Object System.Windows.Controls.Border
        $border.SetResourceReference([System.Windows.FrameworkElement]::StyleProperty, 'Card')
        $border.Margin = '0,0,0,8'; $border.Padding = '14,10'
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Tag = $a.Id
        $cb.IsEnabled = $decision.Allowed
        $cb.SetResourceReference([System.Windows.Controls.Control]::ForegroundProperty, 'Brush.Text')
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = '6,0,0,0'
        $t = New-Object System.Windows.Controls.TextBlock
        $t.Text = Get-WcString $a.TitleKey; $t.FontWeight = 'SemiBold'; $t.TextWrapping = 'Wrap'
        $t.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Text')
        [void]$panel.Children.Add($t)
        if ($a.ContainsKey('DescriptionKey') -and $a.DescriptionKey) {
            $d = New-Object System.Windows.Controls.TextBlock
            $d.Text = Get-WcString $a.DescriptionKey; $d.TextWrapping = 'Wrap'; $d.FontSize = 12
            $d.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Muted')
            [void]$panel.Children.Add($d)
        }
        $tags = @(Get-WcString ('actions.risk.' + $a.Risk))
        if ($a.RequiresAdmin) { $tags += Get-WcString 'actions.admin' }
        if ($a.Modifies) { if ($a.Reversible) { $tags += Get-WcString 'actions.reversible' } else { $tags += Get-WcString 'actions.irreversible' } }
        $m = New-Object System.Windows.Controls.TextBlock
        $m.Text = ($tags -join '  |  '); $m.FontSize = 12; $m.Margin = '0,4,0,0'
        $brush = 'Brush.Info'
        if ($a.Risk -eq 'Medium' -or $a.Risk -eq 'High' -or ($a.Modifies -and -not $a.Reversible)) { $brush = 'Brush.Warning' }
        $m.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, $brush)
        [void]$panel.Children.Add($m)
        if (-not $decision.Allowed) {
            $r = New-Object System.Windows.Controls.TextBlock
            $r.Text = Get-WcString 'actions.blocked' -Arguments @((@($decision.Reasons) | ForEach-Object { Get-WcString $_ }) -join ' ')
            $r.TextWrapping = 'Wrap'; $r.FontSize = 12
            $r.SetResourceReference([System.Windows.Controls.TextBlock]::ForegroundProperty, 'Brush.Muted')
            [void]$panel.Children.Add($r)
        }
        $cb.Content = $panel
        $border.Child = $cb
        [void]$list.Children.Add($border)
    }
}

function Get-WcSelectedActionIds {
    param($Page)
    return @($Page.FindName('ActionsList').Children | ForEach-Object { $_.Child } | Where-Object { $_.IsChecked -eq $true } | ForEach-Object { [string]$_.Tag })
}

function Show-WcActionResults {
    param([string] $PageId, $Results)
    $p = $script:Ui.Pages[$PageId]; if (-not $p) { return }
    $rows = @(); $details = @(); $text = New-Object System.Text.StringBuilder
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $summary = ''; $freed = ''
        $o = $r.Output
        if ($o -and $o.PSObject.Properties['Summary']) {
            $summary = [string]$o.Summary
            if ($null -ne $o.BytesFreed) { $freed = Format-WcBytes $o.BytesFreed }
            foreach ($i in @($o.Items)) { if ($null -ne $i) { $details += $i } }
            if ($o.Output) { [void]$text.AppendLine(('==== {0} ====' -f $r.ActionId)); [void]$text.AppendLine([string]$o.Output) }
        }
        elseif ($o) { $summary = [string]$o }
        if ($r.Error) { $summary = ($summary + ' ' + $r.Error).Trim() }
        $rows += [pscustomobject]@{ Action = (Get-WcString ('action.' + $r.ActionId)); Mode = $r.Mode; Status = $r.Status; Summary = $summary; Freed = $freed }
    }
    Set-WcGridRows -Grid $p.FindName('ResultGrid') -Rows $rows
    Set-WcGridRows -Grid $p.FindName('DetailGrid') -Rows @($details | Select-Object -First 500)
    $p.FindName('OutputBox').Text = $text.ToString()
}

function Start-WcActionRun {
    param([string] $PageId, [switch] $DryRun)
    $p = $script:Ui.Pages[$PageId]
    $ids = Get-WcSelectedActionIds -Page $p
    if ($ids.Count -eq 0) { [System.Windows.MessageBox]::Show((Get-WcString 'actions.nothing-selected'), 'WinCare Enterprise') | Out-Null; return }
    $confirmed = @()
    if (-not $DryRun) {
        # Individual confirmation on the UI thread, before any background work starts.
        foreach ($id in $ids) {
            $a = @($script:Ui.Catalog | Where-Object { $_.Id -eq $id })[0]
            $needs = ([bool]$a.Modifies -or [string]$a.Risk -ne 'None')
            if (-not $needs) { $confirmed += $id; continue }
            $desc = ''; if ($a.ContainsKey('DescriptionKey') -and $a.DescriptionKey) { $desc = Get-WcString $a.DescriptionKey }
            $flag = ''; if ($a.Modifies -and -not $a.Reversible) { $flag = (Get-WcString 'actions.irreversible').ToUpperInvariant() }
            $msg = Get-WcString 'actions.confirm-text' -Arguments @((Get-WcString $a.TitleKey), $desc, (Get-WcString ('actions.risk.' + $a.Risk)), $flag)
            $ans = [System.Windows.MessageBox]::Show($script:Ui.Window, $msg, (Get-WcString 'actions.confirm-title'), 'YesNo', 'Warning', 'No')
            if ($ans -eq 'Yes') { $confirmed += $id }
        }
        if ($confirmed.Count -eq 0) { return }
        $ids = $confirmed
    }
    $ctx = Get-WcUiContext
    $jobArgs = @{ CatalogPath = $script:Ui.CatalogPath; Ids = $ids; Confirmed = $confirmed; Profile = $script:Ui.Settings.Profile; Context = $ctx; DryRun = [bool]$DryRun; PageId = $PageId; HistoryDir = (Join-Path (Get-WcDataRoot) 'history') }
    Start-WcUiJob -Name ('actions-' + $PageId) -Arguments $jobArgs -Script {
        param($a)
        $catalog = Import-WcActionCatalog -Path $a.CatalogPath
        $plan = New-WcPlan -Catalog $catalog -ActionId $a.Ids -OperationProfile (Get-WcProfile $a.Profile) -Context $a.Context
        $confirmed = $a.Confirmed
        if ($a.DryRun) { $res = Invoke-WcPlan -Plan $plan -Context $a.Context -DryRun }
        else { $res = Invoke-WcPlan -Plan $plan -Context $a.Context -ConfirmCallback { param($item) $confirmed -contains $item.ActionId }.GetNewClosure() }
        Add-WcHistory -Directory $a.HistoryDir -Plan $plan -Results $res | Out-Null
        [pscustomobject]@{ PageId = $a.PageId; Results = $res }
    } -OnComplete {
        param($result, $err)
        if ($err) { Write-WcLog -Level Error -Category 'Actions' -Message $err | Out-Null }
        if ($result) { Show-WcActionResults -PageId $result.PageId -Results $result.Results; Update-WcReportsPage }
    }
}

function Update-WcSettingsPage {
    $p = $script:Ui.Pages['settings']; if (-not $p) { return }
    $script:Ui.SuppressSettingEvents = $true
    try {
        $p.FindName('ThemeDark').IsChecked = ($script:Ui.Settings.Theme -eq 'Dark')
        $p.FindName('ThemeLight').IsChecked = ($script:Ui.Settings.Theme -eq 'Light')
        $p.FindName('LangPt').IsChecked = ($script:Ui.Settings.Language -eq 'pt-BR')
        $p.FindName('LangEn').IsChecked = ($script:Ui.Settings.Language -eq 'en-US')
        foreach ($n in @('Diagnostico', 'Conservador', 'Corporativo', 'Avancado')) { $p.FindName("Profile$n").IsChecked = ($script:Ui.Settings.Profile -eq $n) }
        $p.FindName('AboutText').Text = Get-WcString 'settings.about-text' -Arguments @($script:Ui.Version, $script:Ui.AppRoot, (Get-WcDataRoot), $PSVersionTable.PSVersion.ToString())
    }
    finally { $script:Ui.SuppressSettingEvents = $false }
}

function Update-WcAllPages {
    Update-WcHeader
    Update-WcOverview
    Update-WcDiagnosticsPage
    Update-WcStoragePage
    Update-WcStartupPage
    Update-WcSecurityPage
    Update-WcReportsPage
    Update-WcSettingsPage
    foreach ($id in $script:PageDefs.Keys) { if ($script:PageDefs[$id].Actions) { Update-WcActionsPage -PageId $id } }
}

# ---------------------------------------------------------------- settings --

function Save-WcUiSettings {
    $script:Ui.Settings = Save-WcSettings -Settings $script:Ui.Settings
    Write-WcLog -Level Audit -Category 'Settings' -Message ('Settings saved: theme={0} language={1} profile={2}' -f $script:Ui.Settings.Theme, $script:Ui.Settings.Language, $script:Ui.Settings.Profile) | Out-Null
}

function Register-WcSettingsEvents {
    param($Page)
    $Page.FindName('ThemeDark').Add_Checked({ if (-not $script:Ui.SuppressSettingEvents) { Invoke-WcUiSafe { Set-WcTheme -Theme 'Dark'; Save-WcUiSettings } } })
    $Page.FindName('ThemeLight').Add_Checked({ if (-not $script:Ui.SuppressSettingEvents) { Invoke-WcUiSafe { Set-WcTheme -Theme 'Light'; Save-WcUiSettings } } })
    $Page.FindName('LangPt').Add_Checked({ if (-not $script:Ui.SuppressSettingEvents) { Invoke-WcUiSafe { Set-WcStrings -Language 'pt-BR'; Save-WcUiSettings; Update-WcAllPages; Update-WcPageTitle } } })
    $Page.FindName('LangEn').Add_Checked({ if (-not $script:Ui.SuppressSettingEvents) { Invoke-WcUiSafe { Set-WcStrings -Language 'en-US'; Save-WcUiSettings; Update-WcAllPages; Update-WcPageTitle } } })
    foreach ($n in @('Diagnostico', 'Conservador', 'Corporativo', 'Avancado')) {
        $rb = $Page.FindName("Profile$n")
        $rb.Tag = $n
        $rb.Add_Checked({
                param($sender, $e)
                if ($script:Ui.SuppressSettingEvents) { return }
                Invoke-WcUiSafe {
                    $script:Ui.Settings.Profile = [string]$sender.Tag
                    Save-WcUiSettings
                    Update-WcAllPages
                }
            })
    }
}

# -------------------------------------------------------------- navigation --

function Get-WcPage {
    param([string] $PageId)
    if ($script:Ui.Pages.ContainsKey($PageId)) { return $script:Ui.Pages[$PageId] }
    $def = $script:PageDefs[$PageId]
    $page = Import-WcXaml -Path (Join-Path $script:Ui.UiRoot ("Pages\" + $def.Xaml))
    $script:Ui.Pages[$PageId] = $page
    switch ($PageId) {
        'diagnostics' { $page.FindName('RunDiagnosticButton').Add_Click({ Invoke-WcUiSafe { Start-WcDiagnostic } }) }
        'reports' {
            $page.FindName('ExportJsonButton').Add_Click({ Invoke-WcUiSafe { Export-WcUiReport -Format 'Json' } })
            $page.FindName('ExportHtmlButton').Add_Click({ Invoke-WcUiSafe { Export-WcUiReport -Format 'Html' } })
            $page.FindName('OpenFolderButton').Add_Click({ Invoke-WcUiSafe {
                        if (-not (Test-Path -LiteralPath $script:Ui.ReportsDir)) { New-Item -ItemType Directory -Path $script:Ui.ReportsDir -Force | Out-Null }
                        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $script:Ui.ReportsDir)
                    } })
        }
        'settings' { Register-WcSettingsEvents -Page $page }
    }
    if ($def.Actions) {
        $page.FindName('PreviewButton').Tag = $PageId
        $page.FindName('RunButton').Tag = $PageId
        $page.FindName('PreviewButton').Add_Click({ param($sender, $e) Invoke-WcUiSafe { Start-WcActionRun -PageId ([string]$sender.Tag) -DryRun } })
        $page.FindName('RunButton').Add_Click({ param($sender, $e) Invoke-WcUiSafe { Start-WcActionRun -PageId ([string]$sender.Tag) } })
    }
    # Localised column headers for every auto-generated DataGrid on the page.
    foreach ($gridName in @('SystemGrid', 'ErrorsGrid', 'StorageGrid', 'ProcessGrid', 'StartupGrid', 'ManagementGrid', 'ProtectionGrid', 'HistoryGrid', 'ResultGrid', 'DetailGrid', 'ActionsHistoryGrid')) {
        $g = $page.FindName($gridName)
        if ($g) { $g.Add_AutoGeneratingColumn({ param($sender, $e) $e.Column.Header = Get-WcString ('col.' + $e.PropertyName) }) }
    }
    return $page
}

function Update-WcPageTitle {
    $id = $script:Ui.CurrentPage
    if ($id) { $script:Ui.Window.FindName('PageTitle').Text = Get-WcString ('nav.' + $id) }
}

function Show-WcPage {
    param([string] $PageId)
    $page = Get-WcPage -PageId $PageId
    $script:Ui.CurrentPage = $PageId
    $script:Ui.Window.FindName('PageHost').Content = $page
    Update-WcPageTitle
    Update-WcAllPages
}

function Export-WcUiReport {
    param([ValidateSet('Json', 'Html')][string] $Format)
    if (-not $script:Ui.Snapshot) { return }
    if (-not (Test-Path -LiteralPath $script:Ui.ReportsDir)) { New-Item -ItemType Directory -Path $script:Ui.ReportsDir -Force | Out-Null }
    $dlg = New-Object Microsoft.Win32.SaveFileDialog
    $dlg.InitialDirectory = $script:Ui.ReportsDir
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    if ($Format -eq 'Json') { $dlg.Filter = 'JSON (*.json)|*.json'; $dlg.FileName = "wincare-$env:COMPUTERNAME-$stamp.json" }
    else { $dlg.Filter = 'HTML (*.html)|*.html'; $dlg.FileName = "wincare-$env:COMPUTERNAME-$stamp.html" }
    if ($dlg.ShowDialog($script:Ui.Window)) {
        Export-WcReport -Snapshot $script:Ui.Snapshot -Path $dlg.FileName -Format $Format -Language $script:Ui.Settings.Language | Out-Null
        Update-WcReportsPage
    }
}

# --------------------------------------------------------------------- main --

function Initialize-WcUi {
    <# Builds UI state and the main window (not shown). Shared by Show-WcMainWindow and Export-WcUiSnapshot. #>
    param([string] $AppRoot, [string] $Version, [hashtable] $Settings, [bool] $AutoDiagnostic)
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
    $script:Ui = @{
        AppRoot      = $AppRoot
        UiRoot       = Join-Path $AppRoot 'UI'
        LocRoot      = Join-Path $AppRoot 'Localization'
        ManifestPath = Join-Path $AppRoot 'WinCare.psd1'
        CatalogPath  = Join-Path $AppRoot 'Core\actions.json'
        ReportsDir   = Join-Path (Get-WcDataRoot) 'reports'
        Version      = $Version
        Settings     = $Settings
        IsAdmin      = Test-WcIsAdmin
        Pages        = @{}
        Jobs         = New-Object System.Collections.ArrayList
        LogQueue     = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Snapshot     = $null
        CurrentPage  = $null
        SuppressSettingEvents = $false
        AutoDiagnostic = $AutoDiagnostic
        Catalog      = $null
        Headless     = $false
        Errors       = New-Object System.Collections.ArrayList
    }
    $script:Ui.Catalog = Import-WcActionCatalog -Path $script:Ui.CatalogPath
    Set-WcLogSink -Sink $script:Ui.LogQueue

    $window = Import-WcXaml -Path (Join-Path $script:Ui.UiRoot 'MainWindow.xaml')
    $script:Ui.Window = $window
    # Slots: 0 = theme brushes, 1 = styles, 2 = strings.
    $window.Resources.MergedDictionaries.Add((Import-WcXaml -Path (Join-Path $script:Ui.UiRoot 'Themes\Dark.xaml')))
    $window.Resources.MergedDictionaries.Add((Import-WcXaml -Path (Join-Path $script:Ui.UiRoot 'Themes\Styles.xaml')))
    $window.Resources.MergedDictionaries.Add((New-Object System.Windows.ResourceDictionary))
    Set-WcTheme -Theme $Settings.Theme
    Set-WcStrings -Language $Settings.Language

    $nav = Get-WcUiElement $window 'NavList'
    $nav.Add_SelectionChanged({ Invoke-WcUiSafe {
                $item = $script:Ui.Window.FindName('NavList').SelectedItem
                if ($item) { Show-WcPage -PageId ([string]$item.Tag) }
            } })
    (Get-WcUiElement $window 'RefreshButton').Add_Click({ Invoke-WcUiSafe { Start-WcDiagnostic } })
    (Get-WcUiElement $window 'CancelButton').Add_Click({ Invoke-WcUiSafe { Stop-WcUiJobs } })

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(200)
    $timer.Add_Tick({ Receive-WcLogQueue; if ($script:Ui.Jobs.Count -gt 0) { Complete-WcUiJobs } })
    $script:Ui.Timer = $timer
    return $window
}

function Show-WcMainWindow {
    <# Builds and shows the main window (blocking until closed). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $AppRoot,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][hashtable] $Settings,
        [switch] $NoAutoDiagnostic
    )
    $window = Initialize-WcUi -AppRoot $AppRoot -Version $Version -Settings $Settings -AutoDiagnostic (-not $NoAutoDiagnostic)
    $window.Add_ContentRendered({
            $script:Ui.Timer.Start()
            Write-WcLog -Category 'UI' -Message ('WinCare Enterprise {0} started (PS {1}, admin={2}).' -f $script:Ui.Version, $PSVersionTable.PSVersion, $script:Ui.IsAdmin) | Out-Null
            if ($script:Ui.AutoDiagnostic) { Invoke-WcUiSafe { Start-WcDiagnostic } }
        })
    $window.Add_Closing({
            Stop-WcUiJobs
            $script:Ui.Timer.Stop()
            Write-WcLog -Category 'UI' -Message 'WinCare Enterprise closed.' | Out-Null
        })
    $window.FindName('NavList').SelectedIndex = 0
    Update-WcHeader
    [void]$window.ShowDialog()
    Set-WcLogSink -Sink $null
}

function Export-WcUiSnapshot {
    <#
        Validation aid: renders every page to PNG (both themes) with a real
        diagnostic snapshot, without user interaction. Used by CI and the kit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $AppRoot,
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $OutputDirectory,
        [Parameter(Mandatory = $true)] $Snapshot,
        [string] $Language = 'pt-BR',
        [string[]] $Theme = @('Dark', 'Light')
    )
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
    $settings = @{ Theme = $Theme[0]; Language = $Language; Profile = 'Diagnostico' }
    $window = Initialize-WcUi -AppRoot $AppRoot -Version $Version -Settings $settings -AutoDiagnostic $false
    $script:Ui.Headless = $true
    $script:Ui.Snapshot = $Snapshot
    $window.WindowStartupLocation = 'Manual'
    $window.Left = 0; $window.Top = 0; $window.Width = 1240; $window.Height = 800
    $window.ShowActivated = $false
    $window.Show()
    $files = @()
    foreach ($t in $Theme) {
        Set-WcTheme -Theme $t
        $i = 0
        foreach ($id in @($script:PageDefs.Keys)) {
            $i++
            Write-Host ("  [{0}/{1}] {2} ({3})" -f $i, $script:PageDefs.Count, $id, $t)
            $window.FindName('NavList').SelectedIndex = $i - 1
            Invoke-WcUiSafe { Show-WcPage -PageId $id }
            $window.UpdateLayout()
            $window.Dispatcher.Invoke([System.Action]{ }, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)
            $w = [int]$window.ActualWidth; $h = [int]$window.ActualHeight
            $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($window)
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $file = Join-Path $OutputDirectory ('{0:D2}-{1}-{2}-{3}.png' -f $i, $id, $t.ToLowerInvariant(), $Language)
            $fs = [System.IO.File]::Create($file)
            try { $enc.Save($fs) } finally { $fs.Dispose() }
            $files += $file
        }
    }
    $window.Close()
    Set-WcLogSink -Sink $null
    if ($script:Ui.Errors.Count -gt 0) {
        foreach ($e in $script:Ui.Errors) { Write-Warning $e }
        throw ('{0} UI error(s) while rendering pages (see warnings).' -f $script:Ui.Errors.Count)
    }
    return $files
}

Export-ModuleMember -Function @('Show-WcMainWindow', 'Export-WcUiSnapshot', 'Import-WcXaml')
