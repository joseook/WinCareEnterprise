#Requires -Version 5.1
<#
    WinCare.Office - Microsoft Office diagnostics (phase F4). Focus: slow Word startup.

    Pattern (same as WinCare.System):
      Get-*        thin I/O wrapper (registry, file system, processes). Mocked in tests.
      ConvertTo-*  pure function that shapes raw data. Fully tested on Linux.

    Hard rules for this module:
      * Never deletes or changes documents, templates, profiles, credentials or
        registry keys. Policy keys (HKLM/HKCU\Software\Policies\Microsoft\Office)
        are only tested for presence and reported as "managed by organization".
      * The only processes started are WINWORD.EXE (measurement, closed politely
        afterwards; only the PID we started is ever killed) and the Settings URI
        ms-settings:appsfeatures (repair UI; the user runs the repair there).

    Sources (verified 2026-11-16 unless marked UNVERIFIED):
      * Click-to-Run: HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration
        (VersionToReport, Platform, CDNBaseUrl, UpdateChannel, UpdateUrl,
        UnmanagedUpdateURL, ProductReleaseIds). Precedence of the channel values per
        Microsoft Learn "Change the Microsoft 365 Apps update channel".
      * Channel GUIDs: Microsoft Learn "Build dynamic collections for Microsoft 365
        Apps with Configuration Manager" (officecdn.microsoft.com/pr/<guid>).
      * Word switches /q, /n, /safe: Microsoft Support "Command-line switches for
        Microsoft Office products".
      * App Paths, Uninstall keys (64-bit and WOW6432Node): standard Windows keys.
      * COM add-in keys Software\Microsoft\Office\<App>\Addins\<ProgId> with
        FriendlyName/Description/LoadBehavior: documented for COM/VSTO add-ins.
      * UNVERIFIED: Click-to-Run virtual registry add-in key
        HKLM\SOFTWARE\Microsoft\Office\ClickToRun\REGISTRY\MACHINE\Software\Microsoft\Office\<App>\Addins
      * UNVERIFIED (high confidence): Resiliency\DisabledItems under
        HKCU\Software\Microsoft\Office\<16.0|15.0>\<App>\Resiliency\DisabledItems.
        Values are binary blobs; only their count is reported, never decoded or changed.
#>

$script:WcOfficeApps = @(
    @{ Name = 'Word'; Exe = 'WINWORD.EXE'; Process = 'WINWORD' }
    @{ Name = 'Excel'; Exe = 'EXCEL.EXE'; Process = 'EXCEL' }
    @{ Name = 'PowerPoint'; Exe = 'POWERPNT.EXE'; Process = 'POWERPNT' }
)

# Channel GUID -> name (Microsoft Learn, see header). Anything else is reported raw.
$script:WcOfficeChannels = @{
    '492350f6-3a01-4f97-b9c0-c7c6ddf67d60' = 'Current Channel'
    '64256afe-f5d9-4f86-8936-8840a6a4f5be' = 'Current Channel (Preview)'
    '5440fd1f-7ecb-4221-8110-145efaa6372f' = 'Beta Channel'
    '55336b82-a18d-4dd6-b5f6-9e5095c314a6' = 'Monthly Enterprise Channel'
    '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114' = 'Semi-Annual Enterprise Channel'
    'b8f9b850-328d-4355-9145-c59439a0c4cf' = 'Semi-Annual Enterprise Channel (Preview)'
}

# Measurement heuristic (documented, NOT a proof): add-ins/templates are the likely
# cause when normal start > 2x safe start AND the difference is > 3000 ms.
$script:WcOfficeHeuristic = @{ Ratio = 2.0; MinDifferenceMs = 3000 }

# Session history of measurements (before/after comparison). Also persisted in the
# audit log (Write-WcLog category 'Office').
$script:WcOfficeMeasurements = New-Object System.Collections.ArrayList

# ------------------------------------------------------------- pure helpers --

function ConvertTo-WcOfficeChannel {
    <#
        Resolves the update channel. Precedence for the ClickToRun\Configuration
        values follows Microsoft Learn: UpdateUrl (ODT) > UnmanagedUpdateURL > CDNBaseUrl.
        UpdateChannel is reported too. Unknown GUIDs keep Name = $null and Raw = value.
    #>
    [CmdletBinding()]
    param([hashtable] $Configuration = @{})
    $source = $null; $raw = $null
    foreach ($k in @('UpdateChannel', 'UpdateUrl', 'UnmanagedUpdateURL', 'CDNBaseUrl')) {
        if ($Configuration.ContainsKey($k) -and $Configuration[$k]) { $source = $k; $raw = [string]$Configuration[$k]; break }
    }
    $name = $null; $guid = $null
    if ($raw) {
        $m = [regex]::Match($raw, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
        if ($m.Success) {
            $guid = $m.Value.ToLowerInvariant()
            if ($script:WcOfficeChannels.ContainsKey($guid)) { $name = $script:WcOfficeChannels[$guid] }
        }
    }
    return [pscustomobject]@{ Name = $name; Guid = $guid; Raw = $raw; Source = $source }
}

function ConvertTo-WcOfficeClickToRun {
    <# Shapes HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration values. #>
    [CmdletBinding()]
    param([hashtable] $Configuration = @{})
    if (-not $Configuration -or $Configuration.Count -eq 0 -or -not $Configuration['VersionToReport']) {
        return [pscustomobject]@{ Installed = $false; Version = $null; Platform = $null; Channel = $null; ProductReleaseIds = @() }
    }
    $ids = @()
    if ($Configuration['ProductReleaseIds']) {
        $ids = @(([string]$Configuration['ProductReleaseIds']).Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    return [pscustomobject]@{
        Installed         = $true
        Version           = [string]$Configuration['VersionToReport']
        Platform          = [string]$Configuration['Platform']
        Channel           = ConvertTo-WcOfficeChannel -Configuration $Configuration
        ProductReleaseIds = $ids
    }
}

function ConvertTo-WcOfficeUninstallEntry {
    <#
        Filters Uninstall-key entries down to visible Office products.
        Entry: hashtable with DisplayName, DisplayVersion, Publisher, UninstallString,
        WindowsInstaller, SystemComponent, KeyName and Hive ('64' or 'WOW6432Node').
        InstallType: ClickToRun when the uninstall string calls OfficeClickToRun.exe,
        MSI when WindowsInstaller = 1, otherwise Unknown.
    #>
    [CmdletBinding()]
    param([object[]] $Entry = @())
    $out = @()
    foreach ($e in @($Entry | Where-Object { $null -ne $_ })) {
        $name = [string](Get-WcObjectValue $e 'DisplayName')
        if (-not $name) { continue }
        if ($name -notmatch '^Microsoft (Office|365)') { continue }
        if ($name -match '(?i)(language pack|proofing|update for|security update|hotfix|MUI \()') { continue }
        $sys = Get-WcObjectValue $e 'SystemComponent'
        if ($null -ne $sys -and [int]$sys -eq 1) { continue }
        $uninstall = [string](Get-WcObjectValue $e 'UninstallString')
        $wi = Get-WcObjectValue $e 'WindowsInstaller'
        $type = 'Unknown'
        if ($uninstall -match '(?i)OfficeClickToRun\.exe') { $type = 'ClickToRun' }
        elseif ($null -ne $wi -and [int]$wi -eq 1) { $type = 'MSI' }
        $hive = [string](Get-WcObjectValue $e 'Hive')
        $arch = 'x64'
        if ($hive -eq 'WOW6432Node') { $arch = 'x86' }
        $out += [pscustomobject]@{
            Name         = $name
            Version      = [string](Get-WcObjectValue $e 'DisplayVersion')
            Publisher    = [string](Get-WcObjectValue $e 'Publisher')
            InstallType  = $type
            Architecture = $arch
            KeyName      = [string](Get-WcObjectValue $e 'KeyName')
        }
    }
    return $out
}

function ConvertTo-WcOfficeAppPath {
    <#
        App Paths values per application: hashtable Name -> raw '(default)' value.
        Architecture from the path is a HEURISTIC: 'Program Files (x86)' => x86 on a
        64-bit OS. Prefer the Click-to-Run Platform value when available.
    #>
    [CmdletBinding()]
    param([hashtable] $AppPath = @{})
    $out = @()
    foreach ($app in $script:WcOfficeApps) {
        $raw = $AppPath[$app.Name]
        $path = $null
        if ($raw) { $path = ([string]$raw).Trim().Trim('"') }
        $arch = $null
        if ($path) {
            if ($path -match '(?i)\\Program Files \(x86\)\\') { $arch = 'x86' } else { $arch = 'x64 (assumed)' }
        }
        $out += [pscustomobject]@{ Name = $app.Name; Executable = $app.Exe; Path = $path; Found = [bool]$path; ArchitectureHint = $arch }
    }
    return $out
}

function ConvertTo-WcOfficeProcess {
    <# Running Office processes (WINWORD, EXCEL, POWERPNT). #>
    [CmdletBinding()]
    param([object[]] $Process = @())
    $out = @()
    foreach ($p in @($Process | Where-Object { $null -ne $_ })) {
        $ws = Get-WcObjectValue $p 'WorkingSet64'
        $start = Get-WcObjectValue $p 'StartTime'
        $startText = $null
        if ($start) { try { $startText = ([datetime]$start).ToString('o') } catch { $startText = $null } }
        $out += [pscustomobject]@{
            Name         = [string](Get-WcObjectValue $p 'ProcessName')
            Id           = Get-WcObjectValue $p 'Id'
            StartTime    = $startText
            WorkingSetMB = $(if ($ws) { [math]::Round([double]$ws / 1MB, 1) } else { $null })
        }
    }
    return $out
}

function ConvertTo-WcOfficeLoadBehavior {
    <#
        LoadBehavior bitmask (Microsoft docs for COM/VSTO add-ins):
          0 = unloaded, not loaded automatically
          1 = loaded, not loaded automatically (connected manually)
          2 = unloaded, load at startup requested (Office often sets 2 after a
              failure or when the user disables it: it is NOT loading now)
          3 = loaded at startup  -> affects startup time
          8 = load on demand (unloaded), 9 = load on demand (loaded)
          16 = load the first time, then on demand
        LoadsAtStartup is true only for 3 (0x1 and 0x2 both set).
    #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') {
        return [pscustomobject]@{ Code = $null; Meaning = 'NotSet'; LoadsAtStartup = $false }
    }
    $v = 0
    if (-not [int]::TryParse([string]$Value, [ref]$v)) {
        return [pscustomobject]@{ Code = $null; Meaning = 'Invalid'; LoadsAtStartup = $false }
    }
    $meaning = switch ($v) {
        0 { 'NotLoaded'; break }
        1 { 'LoadedManually'; break }
        2 { 'StartupDisabledOrFailed'; break }
        3 { 'LoadAtStartup'; break }
        8 { 'OnDemandNotLoaded'; break }
        9 { 'OnDemandLoaded'; break }
        16 { 'FirstTimeThenOnDemand'; break }
        default { 'Other'; break }
    }
    return [pscustomobject]@{ Code = $v; Meaning = $meaning; LoadsAtStartup = (($v -band 3) -eq 3) }
}

function ConvertTo-WcOfficeAddin {
    <#
        Entry: hashtable with Application, Scope (HKCU/HKLM/HKLM-WOW6432Node/HKLM-C2R),
        KeyName (ProgId), FriendlyName, Description, LoadBehavior.
    #>
    [CmdletBinding()]
    param([object[]] $Entry = @())
    $out = @()
    foreach ($e in @($Entry | Where-Object { $null -ne $_ })) {
        $lb = ConvertTo-WcOfficeLoadBehavior -Value (Get-WcObjectValue $e 'LoadBehavior')
        $friendly = [string](Get-WcObjectValue $e 'FriendlyName')
        $progId = [string](Get-WcObjectValue $e 'KeyName')
        if (-not $friendly) { $friendly = $progId }
        $out += [pscustomobject]@{
            Application    = [string](Get-WcObjectValue $e 'Application')
            Name           = $friendly
            ProgId         = $progId
            Description    = [string](Get-WcObjectValue $e 'Description')
            Scope          = [string](Get-WcObjectValue $e 'Scope')
            LoadBehavior   = $lb.Code
            Meaning        = $lb.Meaning
            LoadsAtStartup = $lb.LoadsAtStartup
        }
    }
    return @($out | Sort-Object -Property @{ Expression = { -not $_.LoadsAtStartup } }, Application, Name)
}

function ConvertTo-WcWordTemplateFile {
    <# Files in the Word STARTUP folder (loaded on every start) and Normal.dotm. #>
    [CmdletBinding()]
    param([object[]] $File = @(), [string] $Kind = 'StartupFolder')
    $out = @()
    foreach ($f in @($File | Where-Object { $null -ne $_ })) {
        $len = Get-WcObjectValue $f 'Length'
        $mod = Get-WcObjectValue $f 'LastWriteTime'
        $modText = $null
        if ($mod) { try { $modText = ([datetime]$mod).ToString('o') } catch { $modText = $null } }
        $out += [pscustomobject]@{
            Kind      = $Kind
            Name      = [string](Get-WcObjectValue $f 'Name')
            Path      = [string](Get-WcObjectValue $f 'FullName')
            SizeBytes = $len
            Modified  = $modText
        }
    }
    return $out
}

function ConvertTo-WcOfficeStartComparison {
    <#
        HEURISTIC verdict from one normal and one safe-mode measurement (ms):
          AddinsLikely      normal > Ratio x safe AND normal - safe > MinDifferenceMs
          NoClearDifference both present but rule not met
          Incomplete        a measurement is missing
        Thresholds: $script:WcOfficeHeuristic (2.0 x and 3000 ms).
    #>
    [CmdletBinding()]
    param($NormalMs, $SafeMs)
    $rule = ('normal > {0}x safe and normal - safe > {1} ms (heuristic)' -f $script:WcOfficeHeuristic.Ratio, $script:WcOfficeHeuristic.MinDifferenceMs)
    if ($null -eq $NormalMs -or $null -eq $SafeMs -or [double]$SafeMs -le 0) {
        return [pscustomobject]@{ Verdict = 'Incomplete'; VerdictKey = 'office.verdict.incomplete'; NormalMs = $NormalMs; SafeMs = $SafeMs; Ratio = $null; DifferenceMs = $null; Rule = $rule }
    }
    $ratio = [math]::Round([double]$NormalMs / [double]$SafeMs, 2)
    $diff = [math]::Round([double]$NormalMs - [double]$SafeMs, 0)
    $verdict = 'NoClearDifference'
    if ($ratio -gt $script:WcOfficeHeuristic.Ratio -and $diff -gt $script:WcOfficeHeuristic.MinDifferenceMs) { $verdict = 'AddinsLikely' }
    $key = 'office.verdict.no-clear-difference'
    if ($verdict -eq 'AddinsLikely') { $key = 'office.verdict.addins-likely' }
    return [pscustomobject]@{ Verdict = $verdict; VerdictKey = $key; NormalMs = [double]$NormalMs; SafeMs = [double]$SafeMs; Ratio = $ratio; DifferenceMs = $diff; Rule = $rule }
}

function ConvertTo-WcOfficeInventoryRows {
    <# Flattens the inventory into uniform rows (Section, Item, Value, Source) for UI tables. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Inventory)
    $rows = New-Object System.Collections.ArrayList
    $add = { param($s, $i, $v, $src) [void]$rows.Add([pscustomobject]@{ Section = $s; Item = $i; Value = $v; Source = $src }) }
    $c2r = $Inventory.ClickToRun
    $c2rSrc = 'HKLM\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    if ($c2r -and $c2r.Installed) {
        & $add 'installation' 'Click-to-Run version' $c2r.Version $c2rSrc
        & $add 'installation' 'Platform' $c2r.Platform $c2rSrc
        $ch = $c2r.Channel
        $chText = $null
        if ($ch) { if ($ch.Name) { $chText = $ch.Name } else { $chText = $ch.Raw } }
        $chSrc = $c2rSrc
        if ($ch -and $ch.Source) { $chSrc = $c2rSrc + '\' + $ch.Source }
        & $add 'installation' 'Update channel' $chText $chSrc
        & $add 'installation' 'Products' ($c2r.ProductReleaseIds -join ', ') $c2rSrc
    }
    else { & $add 'installation' 'Click-to-Run' 'Not detected' $c2rSrc }
    foreach ($p in @($Inventory.Products)) { & $add 'installation' $p.Name ('{0} {1} {2}' -f $p.InstallType, $p.Version, $p.Architecture).Trim() 'Uninstall' }
    foreach ($a in @($Inventory.AppPaths)) {
        $v = 'Not found'
        if ($a.Found) { $v = $a.Path }
        & $add 'executables' $a.Name $v 'App Paths'
    }
    & $add 'installation' 'Architecture' $Inventory.Architecture $Inventory.ArchitectureSource
    $mgd = 'No'
    if ($Inventory.ManagedByOrganization) { $mgd = 'Yes: ' + (@($Inventory.PolicyKeys) -join ', ') }
    & $add 'policy' 'Managed by organization' $mgd 'Software\Policies\Microsoft\Office'
    if (@($Inventory.Processes).Count -eq 0) { & $add 'processes' 'Office' 'None running' 'Get-Process' }
    foreach ($p in @($Inventory.Processes)) { & $add 'processes' $p.Name ('PID {0}, {1} MB' -f $p.Id, $p.WorkingSetMB) 'Get-Process' }
    foreach ($a in @($Inventory.Addins)) {
        & $add 'addins' ('{0}: {1}' -f $a.Application, $a.Name) ('LoadBehavior {0} ({1})' -f $a.LoadBehavior, $a.Meaning) ($a.Scope + ' ' + $a.ProgId)
    }
    foreach ($t in @($Inventory.Templates)) { & $add 'templates' $t.Name ('{0} bytes, {1}' -f $t.SizeBytes, $t.Modified) $t.Path }
    foreach ($r in @($Inventory.DisabledItems)) { & $add 'resiliency' $r.Application ('{0} disabled item(s)' -f $r.Count) $r.Path }
    return $rows.ToArray()
}

# ------------------------------------------------------------ I/O wrappers --

function Get-WcRegistrySubkeyData {
    <#
        Reads selected values of every direct subkey of Path. Missing key -> @().
        Each result is a hashtable with the values plus KeyName. Read-only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $Name
    )
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    foreach ($k in @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $h = @{ KeyName = $k.PSChildName }
        $item = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($item) {
            foreach ($n in $Name) {
                $p = $item.PSObject.Properties[$n]
                if ($p) { $h[$n] = $p.Value }
            }
        }
        $out += $h
    }
    return $out
}

function Get-WcRegistryValueCount {
    <# Number of values in a key; $null when the key does not exist. Read-only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $key) { return $null }
    return [int]$key.ValueCount
}

function Get-WcOfficeInstallation {
    <# Click-to-Run + MSI/Uninstall entries + App Paths + architecture + policy presence. #>
    [CmdletBinding()]
    param()
    $cfg = Get-WcRegistryValues -Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration' -Name @(
        'VersionToReport', 'Platform', 'CDNBaseUrl', 'UpdateChannel', 'UpdateUrl', 'UnmanagedUpdateURL', 'ProductReleaseIds')
    $c2r = ConvertTo-WcOfficeClickToRun -Configuration $cfg

    $uninstallNames = @('DisplayName', 'DisplayVersion', 'Publisher', 'UninstallString', 'WindowsInstaller', 'SystemComponent')
    $entries = @()
    foreach ($u in @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = '64' }
            @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = 'WOW6432Node' })) {
        foreach ($e in @(Get-WcRegistrySubkeyData -Path $u.Path -Name $uninstallNames)) {
            $e['Hive'] = $u.Hive
            $entries += $e
        }
    }
    $products = @(ConvertTo-WcOfficeUninstallEntry -Entry $entries)

    $appRaw = @{}
    foreach ($app in $script:WcOfficeApps) {
        $v = Get-WcRegistryValues -Path ('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\' + $app.Exe) -Name @('(default)')
        if ($v.ContainsKey('(default)')) { $appRaw[$app.Name] = $v['(default)'] }
    }
    $appPaths = @(ConvertTo-WcOfficeAppPath -AppPath $appRaw)

    $arch = $null; $archSrc = $null
    if ($c2r.Installed -and $c2r.Platform) { $arch = $c2r.Platform; $archSrc = 'ClickToRun Platform' }
    else {
        $msi = @($products | Where-Object { $_.InstallType -eq 'MSI' } | Select-Object -First 1)
        if ($msi.Count -gt 0) { $arch = $msi[0].Architecture; $archSrc = 'Uninstall hive' }
        else {
            $w = @($appPaths | Where-Object { $_.Name -eq 'Word' -and $_.Found })
            if ($w.Count -gt 0) { $arch = $w[0].ArchitectureHint; $archSrc = 'App Paths (heuristic)' }
        }
    }

    $policyKeys = @()
    foreach ($pk in @('HKLM:\SOFTWARE\Policies\Microsoft\Office', 'HKCU:\Software\Policies\Microsoft\Office', 'HKLM:\SOFTWARE\Policies\Microsoft\cloud\office')) {
        if (Test-Path -LiteralPath $pk) { $policyKeys += $pk }
    }

    return [pscustomobject]@{
        ClickToRun            = $c2r
        Products              = $products
        AppPaths              = $appPaths
        Architecture          = $arch
        ArchitectureSource    = $archSrc
        ManagedByOrganization = ($policyKeys.Count -gt 0)
        PolicyKeys            = $policyKeys
    }
}

function Get-WcOfficeProcess {
    [CmdletBinding()]
    param()
    $names = @($script:WcOfficeApps | ForEach-Object { $_.Process })
    $procs = @(Get-Process -Name $names -ErrorAction SilentlyContinue)
    return (ConvertTo-WcOfficeProcess -Process $procs)
}

function Get-WcOfficeAddin {
    <# COM add-ins for Word, Excel and PowerPoint from every known scope. Read-only. #>
    [CmdletBinding()]
    param()
    $entries = @()
    foreach ($app in $script:WcOfficeApps) {
        $scopes = @(
            @{ Scope = 'HKCU'; Path = ('HKCU:\Software\Microsoft\Office\{0}\Addins' -f $app.Name) }
            @{ Scope = 'HKLM'; Path = ('HKLM:\SOFTWARE\Microsoft\Office\{0}\Addins' -f $app.Name) }
            @{ Scope = 'HKLM-WOW6432Node'; Path = ('HKLM:\SOFTWARE\WOW6432Node\Microsoft\Office\{0}\Addins' -f $app.Name) }
            # UNVERIFIED path (Click-to-Run virtual registry); read-only, absent key is harmless.
            @{ Scope = 'HKLM-C2R'; Path = ('HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\REGISTRY\MACHINE\Software\Microsoft\Office\{0}\Addins' -f $app.Name) }
        )
        foreach ($s in $scopes) {
            foreach ($e in @(Get-WcRegistrySubkeyData -Path $s.Path -Name @('FriendlyName', 'Description', 'LoadBehavior'))) {
                $e['Application'] = $app.Name
                $e['Scope'] = $s.Scope
                $entries += $e
            }
        }
    }
    return (ConvertTo-WcOfficeAddin -Entry $entries)
}

function Get-WcWordTemplateFile {
    <# Word STARTUP folder (%APPDATA%\Microsoft\Word\STARTUP) and Normal.dotm. Listing only. #>
    [CmdletBinding()]
    param([string] $AppData = $env:APPDATA)
    $out = @()
    if (-not $AppData) { return $out }
    $startup = Join-Path (Join-Path (Join-Path $AppData 'Microsoft') 'Word') 'STARTUP'
    if (Test-Path -LiteralPath $startup) {
        $files = @(Get-ChildItem -LiteralPath $startup -File -ErrorAction SilentlyContinue)
        $out += @(ConvertTo-WcWordTemplateFile -File $files -Kind 'StartupFolder')
    }
    $normal = Join-Path (Join-Path (Join-Path $AppData 'Microsoft') 'Templates') 'Normal.dotm'
    if (Test-Path -LiteralPath $normal) {
        $out += @(ConvertTo-WcWordTemplateFile -File @(Get-Item -LiteralPath $normal -ErrorAction SilentlyContinue) -Kind 'NormalTemplate')
    }
    return $out
}

function Get-WcOfficeDisabledItem {
    <# Presence/count of Resiliency\DisabledItems (hard-disabled add-ins). Path UNVERIFIED, see header. #>
    [CmdletBinding()]
    param()
    $out = @()
    foreach ($ver in @('16.0', '15.0')) {
        foreach ($app in $script:WcOfficeApps) {
            $p = 'HKCU:\Software\Microsoft\Office\{0}\{1}\Resiliency\DisabledItems' -f $ver, $app.Name
            $n = Get-WcRegistryValueCount -Path $p
            if ($null -ne $n -and $n -gt 0) { $out += [pscustomobject]@{ Application = $app.Name; Version = $ver; Count = $n; Path = $p } }
        }
    }
    return $out
}

function Get-WcOfficeInventory {
    <# Detection + add-ins + templates + resiliency. Read-only. #>
    [CmdletBinding()]
    param()
    $inst = Get-WcOfficeInstallation
    return [pscustomobject]@{
        ClickToRun            = $inst.ClickToRun
        Products              = $inst.Products
        AppPaths              = $inst.AppPaths
        Architecture          = $inst.Architecture
        ArchitectureSource    = $inst.ArchitectureSource
        ManagedByOrganization = $inst.ManagedByOrganization
        PolicyKeys            = $inst.PolicyKeys
        Processes             = @(Get-WcOfficeProcess)
        Addins                = @(Get-WcOfficeAddin)
        Templates             = @(Get-WcWordTemplateFile)
        DisabledItems         = @(Get-WcOfficeDisabledItem)
    }
}

# --------------------------------------------------------- measurement --

function Get-WcWordExecutablePath {
    <# WINWORD.EXE from App Paths; validated (rooted, file name, exists). $null otherwise. #>
    [CmdletBinding()]
    param()
    $v = Get-WcRegistryValues -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\WINWORD.EXE' -Name @('(default)')
    if (-not $v.ContainsKey('(default)') -or -not $v['(default)']) { return $null }
    $path = ([string]$v['(default)']).Trim().Trim('"')
    if (-not [System.IO.Path]::IsPathRooted($path)) { return $null }
    if ([System.IO.Path]::GetFileName($path) -ne 'WINWORD.EXE') { return $null }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return $path
}

function Get-WcWordStartArgument {
    <# Fixed argument lists. /q no splash, /n no document, /safe safe mode (Microsoft Support). #>
    [CmdletBinding()]
    param([ValidateSet('Normal', 'Safe')][string] $Mode = 'Normal')
    if ($Mode -eq 'Safe') { return @('/q', '/n', '/safe') }
    return @('/q', '/n')
}

function Measure-WcWordStartup {
    <#
        Methodology (docs: localization key action.office.measure-word-start.desc):
          1. Refuse if WINWORD is already running (warm instance = invalid measurement).
          2. Start WINWORD.EXE (absolute path from App Paths) with fixed switches
             /q /n [/safe] and a Stopwatch.
          3. Poll: WaitForInputIdle(500) + Refresh until MainWindowHandle != 0, up to
             TimeoutSeconds (default 120).
          4. Stop the clock; close politely (CloseMainWindow). If the process does not
             exit within 10 s, kill ONLY that PID. No document is open (/n), so nothing
             can be lost.
        The first start after boot is a cold start (disk cache empty) and is usually
        slower: compare runs of the same kind (cold vs cold, warm vs warm).
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('Normal', 'Safe')][string] $Mode = 'Normal',
        [ValidateRange(1, 600)][int] $TimeoutSeconds = 120,
        [ValidateRange(1, 60)][int] $CloseTimeoutSeconds = 10
    )
    $running = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        throw ('Word is already running (PID {0}). Close Word and try again: a warm instance makes the measurement invalid.' -f (($running | ForEach-Object { $_.Id }) -join ', '))
    }
    $exe = Get-WcWordExecutablePath
    if (-not $exe) { throw 'WINWORD.EXE not found (App Paths). Word does not seem to be installed.' }
    $argList = Get-WcWordStartArgument -Mode $Mode
    Write-WcLog -Level Info -Category 'Office' -Message ('Starting Word ({0}) for measurement: {1} {2}' -f $Mode, $exe, ($argList -join ' ')) | Out-Null

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -PassThru
    if (-not $proc) { throw 'Start-Process did not return a process object.' }
    $windowSeen = $false
    $exitedEarly = $false
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        try { [void]$proc.WaitForInputIdle(500) } catch { Start-Sleep -Milliseconds 100 }
        try { $proc.Refresh() } catch { Write-Verbose 'Refresh failed' }
        if ($proc.HasExited) { $exitedEarly = $true; break }
        if ([int64]$proc.MainWindowHandle -ne 0) { $windowSeen = $true; break }
        Start-Sleep -Milliseconds 100
    }
    $sw.Stop()
    $ms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)

    # Polite close; kill only our PID as a last resort.
    $closeMethod = 'AlreadyExited'
    if (-not $proc.HasExited) {
        $closeMethod = 'CloseMainWindow'
        try { [void]$proc.CloseMainWindow() } catch { Write-Verbose 'CloseMainWindow failed' }
        $exited = $false
        try { $exited = [bool]$proc.WaitForExit($CloseTimeoutSeconds * 1000) } catch { $exited = $false }
        if (-not $exited) {
            $closeMethod = 'Killed'
            Write-WcLog -Level Warning -Category 'Office' -Message ('Word PID {0} did not exit in {1} s; stopping that PID only.' -f $proc.Id, $CloseTimeoutSeconds) | Out-Null
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        }
    }
    if ($exitedEarly) { throw ('Word (PID {0}) exited before showing a window. Measurement invalid (activation/handoff to another instance?).' -f $proc.Id) }
    if (-not $windowSeen) { throw ('Word did not show a main window within {0} s. Measurement invalid.' -f $TimeoutSeconds) }

    $m = [pscustomobject]@{
        Mode          = $Mode
        Milliseconds  = $ms
        Arguments     = ($argList -join ' ')
        Executable    = $exe
        ProcessId     = $proc.Id
        CloseMethod   = $closeMethod
        Measured      = (Get-Date).ToUniversalTime().ToString('o')
        Method        = 'Stopwatch from Start-Process until MainWindowHandle != 0 (WaitForInputIdle + polling)'
    }
    Add-WcWordMeasurement -Measurement $m
    Write-WcLog -Level Audit -Category 'Office' -Message ('Word start ({0}): {1} ms' -f $Mode, $ms) -Data @{ mode = $Mode; ms = $ms; close = $closeMethod } | Out-Null
    return $m
}

function Add-WcWordMeasurement {
    <# Appends a measurement to the session history (used by Measure-WcWordStartup). #>
    param([Parameter(Mandatory = $true)] $Measurement)
    [void]$script:WcOfficeMeasurements.Add($Measurement)
}

function Get-WcWordMeasurementHistory { return @($script:WcOfficeMeasurements.ToArray()) }

function Clear-WcWordMeasurementHistory { $script:WcOfficeMeasurements.Clear() }

function Get-WcLastWordMeasurement {
    param([ValidateSet('Normal', 'Safe')][string] $Mode)
    $last = $null
    foreach ($m in $script:WcOfficeMeasurements) { if ($m.Mode -eq $Mode) { $last = $m } }
    return $last
}

function New-WcWordMeasurementResult {
    <# Builds the action result: current measurement, comparison and session history. #>
    param([Parameter(Mandatory = $true)] $Measurement)
    $normal = Get-WcLastWordMeasurement -Mode 'Normal'
    $safe = Get-WcLastWordMeasurement -Mode 'Safe'
    $nMs = $null; $sMs = $null
    if ($normal) { $nMs = $normal.Milliseconds }
    if ($safe) { $sMs = $safe.Milliseconds }
    $cmp = ConvertTo-WcOfficeStartComparison -NormalMs $nMs -SafeMs $sMs
    $items = @()
    $i = 0
    foreach ($h in $script:WcOfficeMeasurements) {
        $i++
        $items += [pscustomobject]@{ Section = 'measurement'; Item = ('#{0} {1}' -f $i, $h.Mode); Value = ('{0} ms' -f $h.Milliseconds); Source = $h.Measured }
    }
    $items += [pscustomobject]@{ Section = 'comparison'; Item = 'Verdict'; Value = $cmp.Verdict; Source = $cmp.Rule }
    $summary = ('Word {0} start: {1} ms. Comparison: {2}.' -f $Measurement.Mode, $Measurement.Milliseconds, $cmp.Verdict)
    if ($cmp.Verdict -eq 'AddinsLikely') { $summary += ' Add-ins/templates likely cause (heuristic).' }
    $r = New-WcActionResult -Summary $summary -Items $items
    $r | Add-Member -NotePropertyName Measurement -NotePropertyValue $Measurement
    $r | Add-Member -NotePropertyName Comparison -NotePropertyValue $cmp
    return $r
}

function Get-WcWordMeasurePreview {
    param([ValidateSet('Normal', 'Safe')][string] $Mode)
    $running = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue)
    $exe = Get-WcWordExecutablePath
    $argText = (Get-WcWordStartArgument -Mode $Mode) -join ' '
    $state = 'ready'
    if ($running.Count -gt 0) { $state = 'refused: Word is already running' }
    elseif (-not $exe) { $state = 'refused: WINWORD.EXE not found' }
    $items = @(
        [pscustomobject]@{ Section = 'measurement'; Item = 'Executable'; Value = $exe; Source = 'App Paths' }
        [pscustomobject]@{ Section = 'measurement'; Item = 'Arguments'; Value = $argText; Source = 'Microsoft Support command-line switches' }
        [pscustomobject]@{ Section = 'measurement'; Item = 'State'; Value = $state; Source = 'Get-Process WINWORD' }
    )
    return (New-WcActionResult -Summary ('Would start Word ({0}) with {1}, time until the main window appears, then close it ({2}).' -f $Mode, $argText, $state) -Items $items)
}

# -------------------------------------------------------------- repair UI --

function Open-WcOfficeRepair {
    <#
        Opens Settings > Apps (ms-settings:appsfeatures). The user picks Microsoft 365 /
        Office > Modify > Quick Repair or Online Repair. Nothing is repaired here.
        OfficeClickToRun.exe scenario=Repair arguments are NOT used: they could not be
        confirmed in official Microsoft documentation.
    #>
    [CmdletBinding()]
    param()
    Write-WcLog -Level Audit -Category 'Office' -Message 'Opening ms-settings:appsfeatures for a user-driven Office repair.' | Out-Null
    Start-Process -FilePath 'ms-settings:appsfeatures'
    return (New-WcActionResult -Summary 'Opened Settings > Apps. Select Microsoft 365/Office > Modify > Quick Repair (offline) or Online Repair. WinCare does not run repairs.' -Items @(
            [pscustomobject]@{ Section = 'repair'; Item = 'Opened'; Value = 'ms-settings:appsfeatures'; Source = 'Windows Settings URI' }))
}

# --------------------------------------------------------------- handlers --

function Register-WcOfficeHandler {
    <# Registers the handlers referenced by Core/actions.d/f4-office.json. #>
    [CmdletBinding()]
    param()
    Register-WcActionHandler -Name 'Office-Inventory' -Preview {
        param($c)
        New-WcActionResult -Summary 'Read Office installation, channel, executables, processes, COM add-ins, Word startup templates and resiliency (registry/files, read-only).'
    } -Execute {
        param($c)
        $inv = Get-WcOfficeInventory
        $rows = @(ConvertTo-WcOfficeInventoryRows -Inventory $inv)
        $startup = @($inv.Addins | Where-Object { $_.LoadsAtStartup }).Count
        $ver = 'not detected'
        if ($inv.ClickToRun.Installed) { $ver = 'Click-to-Run ' + $inv.ClickToRun.Version }
        elseif (@($inv.Products).Count -gt 0) { $ver = @($inv.Products)[0].InstallType + ' ' + @($inv.Products)[0].Version }
        $r = New-WcActionResult -Summary ('Office {0}; {1} add-in(s) load at startup; {2} template(s); managed: {3}.' -f $ver, $startup, @($inv.Templates).Count, $inv.ManagedByOrganization) -Items $rows
        $r | Add-Member -NotePropertyName Inventory -NotePropertyValue $inv
        $r
    }
    Register-WcActionHandler -Name 'Office-MeasureWordStart' -Preview { param($c) Get-WcWordMeasurePreview -Mode 'Normal' } -Execute {
        param($c)
        New-WcWordMeasurementResult -Measurement (Measure-WcWordStartup -Mode 'Normal')
    }
    Register-WcActionHandler -Name 'Office-MeasureWordStartSafe' -Preview { param($c) Get-WcWordMeasurePreview -Mode 'Safe' } -Execute {
        param($c)
        New-WcWordMeasurementResult -Measurement (Measure-WcWordStartup -Mode 'Safe')
    }
    Register-WcActionHandler -Name 'Office-OpenRepair' -Preview {
        param($c)
        New-WcActionResult -Summary 'Would open Settings > Apps (ms-settings:appsfeatures) so the user can run Quick/Online Repair. Nothing is repaired automatically.'
    } -Execute { param($c) Open-WcOfficeRepair }
}

Export-ModuleMember -Function @(
    'ConvertTo-WcOfficeChannel', 'ConvertTo-WcOfficeClickToRun', 'ConvertTo-WcOfficeUninstallEntry', 'ConvertTo-WcOfficeAppPath',
    'ConvertTo-WcOfficeProcess', 'ConvertTo-WcOfficeLoadBehavior', 'ConvertTo-WcOfficeAddin', 'ConvertTo-WcWordTemplateFile',
    'ConvertTo-WcOfficeStartComparison', 'ConvertTo-WcOfficeInventoryRows',
    'Get-WcRegistrySubkeyData', 'Get-WcRegistryValueCount', 'Get-WcOfficeInstallation', 'Get-WcOfficeProcess', 'Get-WcOfficeAddin',
    'Get-WcWordTemplateFile', 'Get-WcOfficeDisabledItem', 'Get-WcOfficeInventory',
    'Get-WcWordExecutablePath', 'Get-WcWordStartArgument', 'Measure-WcWordStartup',
    'Add-WcWordMeasurement', 'Get-WcWordMeasurementHistory', 'Clear-WcWordMeasurementHistory', 'Open-WcOfficeRepair', 'Register-WcOfficeHandler'
)

# Handlers are NOT registered at import time: Core's Initialize-WcActionHandlers
# (called by New-WcPlan) invokes the exported Register-WcOfficeHandler.
