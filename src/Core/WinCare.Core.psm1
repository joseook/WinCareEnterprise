#Requires -Version 5.1
<#
    WinCare.Core - platform-independent core of WinCare Enterprise.

    Contains: platform detection, structured logging (JSONL), localization,
    settings, operation profiles, the action catalog (allowlist), the policy
    engine and the plan/dry-run executor.

    Rules for this file (enforced by tests/Syntax.Tests.ps1):
      * Windows PowerShell 5.1 syntax only (no ternary, no ?? / ?. operators).
      * ASCII only. User-facing text lives in src/Localization/*.json.
      * No Windows-only cmdlets here; everything must run under pwsh on Linux.
#>
Set-StrictMode -Version 2.0

$script:WcState = @{
    LogPath  = $null
    LogSink  = $null
    Strings  = @{}
    Language = 'pt-BR'
    Handlers = @{}
}

$script:WcRiskOrder = @{ 'None' = 0; 'Low' = 1; 'Medium' = 2; 'High' = 3 }
$script:WcCategories = @('Diagnostics', 'Storage', 'Startup', 'Integrity', 'Processes', 'Applications',
    'Office', 'Services', 'Network', 'Performance', 'Security', 'Reporting')
# Fundamental protections. An action that declares it touches any of these is
# rejected when the catalog is loaded - no profile can ever enable it.
$script:WcProtectedFeatures = @('Defender', 'Firewall', 'BitLocker', 'WindowsUpdate', 'GroupPolicy',
    'MDM', 'EDR', 'VPN', 'Authentication', 'Inventory', 'ExecutionPolicy', 'UAC', 'SmartScreen')

# ---------------------------------------------------------------- platform --

function Test-WcIsWindows {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
}

function Test-WcIsAdmin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-WcIsWindows)) { return $false }
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WcDataRoot {
    <# Per-user data folder. WINCARE_DATA_ROOT overrides it (tests, portable runs). #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:WINCARE_DATA_ROOT) { return $env:WINCARE_DATA_ROOT }
    $base = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path $base 'WinCare')
}

function ConvertTo-WcHashtable {
    <# Recursively converts ConvertFrom-Json output to hashtables (PS 5.1 lacks -AsHashtable). #>
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline = $true)] $InputObject)
    process {
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($k in $InputObject.Keys) { $h[$k] = ConvertTo-WcHashtable $InputObject[$k] }
            return $h
        }
        if ($InputObject -is [string]) { return $InputObject }
        if ($InputObject -is [System.Collections.IEnumerable]) {
            $list = @()
            foreach ($i in $InputObject) { $list += , (ConvertTo-WcHashtable $i) }
            return , $list
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $h = @{}
            foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-WcHashtable $p.Value }
            return $h
        }
        return $InputObject
    }
}

function Read-WcJsonFile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return (ConvertTo-WcHashtable ($text | ConvertFrom-Json))
}

function Write-WcTextFile {
    <# Writes UTF-8 without BOM (identical bytes on PS 5.1 and 7). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

# ----------------------------------------------------------------- logging --

function Initialize-WcLog {
    [CmdletBinding()]
    param(
        [string] $Path,
        [object] $Sink
    )
    if (-not $Path) {
        $stamp = (Get-Date).ToString('yyyyMMdd')
        $Path = Join-Path (Join-Path (Get-WcDataRoot) 'logs') ("wincare-$stamp.jsonl")
    }
    $script:WcState.LogPath = $Path
    if ($PSBoundParameters.ContainsKey('Sink')) { $script:WcState.LogSink = $Sink }
    return $Path
}

function Set-WcLogSink {
    <# Sink = System.Collections.Concurrent.ConcurrentQueue[string]; the UI drains it. #>
    [CmdletBinding()]
    param([object] $Sink)
    $script:WcState.LogSink = $Sink
}

function Get-WcLogPath { return $script:WcState.LogPath }

function Write-WcLog {
    [CmdletBinding()]
    param(
        [ValidateSet('Debug', 'Info', 'Warning', 'Error', 'Audit')]
        [string] $Level = 'Info',
        [Parameter(Mandatory = $true)][string] $Message,
        [string] $Category = 'General',
        [hashtable] $Data
    )
    $entry = [ordered]@{
        time     = (Get-Date).ToUniversalTime().ToString('o')
        level    = $Level
        category = $Category
        message  = $Message
        pid      = $PID
    }
    if ($Data) { $entry['data'] = $Data }
    $line = ConvertTo-Json -InputObject $entry -Compress -Depth 6
    if ($script:WcState.LogPath) {
        try {
            $dir = Split-Path -Parent $script:WcState.LogPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.File]::AppendAllText($script:WcState.LogPath, $line + "`n", (New-Object System.Text.UTF8Encoding($false)))
        }
        catch {
            Write-Verbose ("WinCare log write failed: " + $_.Exception.Message)
        }
    }
    if ($null -ne $script:WcState.LogSink) {
        $display = '{0} [{1}] {2}: {3}' -f (Get-Date).ToString('HH:mm:ss'), $Level.ToUpperInvariant(), $Category, $Message
        $script:WcState.LogSink.Enqueue($display)
    }
    return [pscustomobject]$entry
}

function Read-WcLog {
    [CmdletBinding()]
    param([string] $Path = $script:WcState.LogPath)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return @() }
    $result = @()
    foreach ($line in [System.IO.File]::ReadAllLines($Path, [System.Text.Encoding]::UTF8)) {
        if ($line.Trim()) {
            try { $result += ($line | ConvertFrom-Json) } catch { Write-Verbose 'Skipping malformed log line.' }
        }
    }
    return $result
}

# ------------------------------------------------------------ localization --

function Get-WcSupportedLanguages { return @('pt-BR', 'en-US') }

function Import-WcLocalization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [string] $Language = 'pt-BR'
    )
    if ((Get-WcSupportedLanguages) -notcontains $Language) { $Language = 'pt-BR' }
    $path = Join-Path $Root ("$Language.json")
    if (-not (Test-Path -LiteralPath $path)) { throw "Localization file not found: $path" }
    $strings = Read-WcJsonFile -Path $path
    # Module fragments: Localization/<lang>.d/*.json (one file per feature module).
    $fragDir = Join-Path $Root ("$Language.d")
    if (Test-Path -LiteralPath $fragDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $fragDir -Filter '*.json' | Sort-Object Name)) {
            $frag = Read-WcJsonFile -Path $f.FullName
            foreach ($k in $frag.Keys) {
                if ($strings.ContainsKey($k)) { throw "Duplicate localization key '$k' in $($f.Name)" }
                $strings[$k] = $frag[$k]
            }
        }
    }
    $script:WcState.Strings = $strings
    $script:WcState.Language = $Language
    return $script:WcState.Strings
}

function Get-WcString {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string] $Key,
        [object[]] $Arguments
    )
    $text = $null
    if ($script:WcState.Strings.ContainsKey($Key)) { $text = [string]$script:WcState.Strings[$Key] }
    if (-not $text) { return "[$Key]" }
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) { return ($text -f $Arguments) }
    return $text
}

function Get-WcLocalizedValue {
    <# Raw localized value (string, array or object). No key = the whole table. #>
    [CmdletBinding()]
    param([string] $Key)
    if (-not $Key) { return $script:WcState.Strings }
    if ($script:WcState.Strings.ContainsKey($Key)) { return $script:WcState.Strings[$Key] }
    return $null
}

# ---------------------------------------------------------------- settings --

function Get-WcDefaultSettings {
    return @{ Theme = 'Dark'; Language = 'pt-BR'; Profile = 'Diagnostico' }
}

function Test-WcSettings {
    <# Returns a copy where every invalid value is replaced by its default. #>
    [CmdletBinding()]
    param([hashtable] $Settings)
    $defaults = Get-WcDefaultSettings
    $clean = Get-WcDefaultSettings
    if (-not $Settings) { return $clean }
    if (@('Dark', 'Light') -contains $Settings['Theme']) { $clean.Theme = $Settings['Theme'] }
    if ((Get-WcSupportedLanguages) -contains $Settings['Language']) { $clean.Language = $Settings['Language'] }
    if ((Get-WcProfile -All).Name -contains $Settings['Profile']) { $clean.Profile = $Settings['Profile'] }
    foreach ($k in $defaults.Keys) {
        if ($Settings.ContainsKey($k) -and $Settings[$k] -ne $clean[$k]) {
            Write-WcLog -Level Warning -Category 'Settings' -Message ("Invalid value for '{0}' replaced by default." -f $k) | Out-Null
        }
    }
    return $clean
}

function Read-WcSettings {
    [CmdletBinding()]
    param([string] $Path = (Join-Path (Get-WcDataRoot) 'settings.json'))
    if (-not (Test-Path -LiteralPath $Path)) { return (Get-WcDefaultSettings) }
    try { $raw = Read-WcJsonFile -Path $Path }
    catch {
        Write-WcLog -Level Warning -Category 'Settings' -Message 'Settings file unreadable; using defaults.' | Out-Null
        return (Get-WcDefaultSettings)
    }
    return (Test-WcSettings -Settings $raw)
}

function Save-WcSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Settings,
        [string] $Path = (Join-Path (Get-WcDataRoot) 'settings.json')
    )
    $clean = Test-WcSettings -Settings $Settings
    Write-WcTextFile -Path $Path -Content (ConvertTo-Json -InputObject $clean -Depth 3)
    return $clean
}

# ---------------------------------------------------------------- profiles --

function Get-WcProfile {
    <#
        Operation profiles. MaxRisk caps what an action may carry; AllowModify=false
        means read-only. No profile can enable actions on protected features: those
        are rejected when the catalog loads.
    #>
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName', Position = 0)][string] $Name = 'Diagnostico',
        [Parameter(ParameterSetName = 'All')][switch] $All
    )
    $profiles = @(
        [pscustomobject]@{ Name = 'Diagnostico'; AllowModify = $false; MaxRisk = 'None'; StrictManaged = $true; ConfirmEach = $true }
        [pscustomobject]@{ Name = 'Conservador'; AllowModify = $true; MaxRisk = 'Low'; StrictManaged = $false; ConfirmEach = $true }
        [pscustomobject]@{ Name = 'Corporativo'; AllowModify = $true; MaxRisk = 'Low'; StrictManaged = $true; ConfirmEach = $true }
        [pscustomobject]@{ Name = 'Avancado'; AllowModify = $true; MaxRisk = 'High'; StrictManaged = $false; ConfirmEach = $true }
    )
    if ($All) { return $profiles }
    $match = $profiles | Where-Object { $_.Name -eq $Name }
    if (-not $match) { throw "Unknown profile: $Name" }
    return $match
}

# ---------------------------------------------------------- action catalog --

function Register-WcActionHandler {
    <#
        Registers the code behind an action. Only registered handlers can run; the
        catalog JSON can reference handlers but never carries code.
        Preview: returns what would happen (no side effects) - used by dry-run.
        Execute: performs the action. Both receive the context hashtable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z][A-Za-z0-9\-]+$')][string] $Name,
        [Parameter(Mandatory = $true)][scriptblock] $Preview,
        [Parameter(Mandatory = $true)][scriptblock] $Execute
    )
    $script:WcState.Handlers[$Name] = @{ Preview = $Preview; Execute = $Execute }
}

function Get-WcActionHandlerNames { return @($script:WcState.Handlers.Keys) }

function Clear-WcActionHandlers { $script:WcState.Handlers = @{} }

function Test-WcActionDefinition {
    <# Validates one catalog entry. Returns an array of error strings (empty = valid). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable] $Action)
    $errors = @()
    foreach ($req in @('Id', 'Category', 'Risk', 'Modifies', 'RequiresAdmin', 'Reversible', 'Handler', 'TitleKey')) {
        if (-not $Action.ContainsKey($req)) { $errors += "missing field '$req'" }
    }
    if ($errors.Count -gt 0) { return $errors }
    if ($Action.Id -notmatch '^[a-z0-9]+(\.[a-z0-9\-]+)+$') { $errors += "invalid id '$($Action.Id)'" }
    if ($script:WcCategories -notcontains $Action.Category) { $errors += "invalid category '$($Action.Category)'" }
    if (-not $script:WcRiskOrder.ContainsKey([string]$Action.Risk)) { $errors += "invalid risk '$($Action.Risk)'" }
    foreach ($b in @('Modifies', 'RequiresAdmin', 'Reversible')) {
        if ($Action[$b] -isnot [bool]) { $errors += "field '$b' must be boolean" }
    }
    if ($Action.Modifies -eq $true -and [string]$Action.Risk -eq 'None') { $errors += 'modifying action cannot have risk None' }
    if ($Action.ContainsKey('Touches')) {
        foreach ($t in @($Action.Touches)) {
            if ($script:WcProtectedFeatures -contains $t) { $errors += "touches protected feature '$t'" }
        }
    }
    if ($Action.ContainsKey('Pages')) {
        foreach ($pg in @($Action.Pages)) {
            if (@('quick', 'advanced', 'integrity', 'office', 'storage', 'startup') -notcontains $pg) { $errors += "invalid page '$pg'" }
        }
    }
    if ($Action.ContainsKey('MinBuild') -and $null -ne $Action.MinBuild -and $Action.MinBuild -isnot [int] -and $Action.MinBuild -isnot [long]) {
        $errors += 'MinBuild must be an integer'
    }
    return $errors
}

function Import-WcActionCatalog {
    <# Loads and validates the catalog. Any invalid entry aborts the load (fail closed). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)
    $data = Read-WcJsonFile -Path $Path
    if (-not $data.ContainsKey('actions')) { throw "Catalog has no 'actions' array: $Path" }
    $all = @($data.actions)
    # Module fragments: <catalog dir>/actions.d/*.json, same schema.
    $fragDir = Join-Path (Split-Path -Parent $Path) 'actions.d'
    if (Test-Path -LiteralPath $fragDir) {
        foreach ($f in @(Get-ChildItem -LiteralPath $fragDir -Filter '*.json' | Sort-Object Name)) {
            $frag = Read-WcJsonFile -Path $f.FullName
            if ($frag.ContainsKey('actions')) { $all += @($frag.actions) }
        }
    }
    $ids = @{}
    $actions = @()
    foreach ($a in $all) {
        $errs = @(Test-WcActionDefinition -Action $a)
        if ($errs.Count -gt 0) { throw ("Invalid action '{0}': {1}" -f $a['Id'], ($errs -join '; ')) }
        if ($ids.ContainsKey($a.Id)) { throw "Duplicate action id: $($a.Id)" }
        $ids[$a.Id] = $true
        $actions += , $a
    }
    return , $actions
}

function New-WcActionResult {
    <# Standard result object returned by every handler Preview/Execute (docs/CONTRATO-ACOES.md). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Summary,
        [object[]] $Items = @(),
        $BytesBefore = $null,
        $BytesAfter = $null,
        $BytesFreed = $null,
        [string] $Output = $null,
        $ExitCode = $null,
        $RollbackData = $null
    )
    return [pscustomobject]@{
        Summary = $Summary; Items = @($Items); BytesBefore = $BytesBefore; BytesAfter = $BytesAfter; BytesFreed = $BytesFreed
        Output = $Output; ExitCode = $ExitCode; RollbackData = $RollbackData
    }
}

# ----------------------------------------------------------- policy engine --

function New-WcContext {
    <# Execution context consumed by the policy engine. #>
    [CmdletBinding()]
    param(
        [bool] $IsAdmin = $false,
        [bool] $IsManaged = $false,
        [int] $Build = 0,
        [string] $EditionId = '',
        [bool] $IsWindows = $true
    )
    return @{ IsAdmin = $IsAdmin; IsManaged = $IsManaged; Build = $Build; EditionId = $EditionId; IsWindows = $IsWindows }
}

function Test-WcActionAllowed {
    <# Decides whether an action may run under a profile/context. Returns Allowed + Reasons (localization keys). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable] $Action,
        [Parameter(Mandatory = $true)][object] $OperationProfile,
        [Parameter(Mandatory = $true)][hashtable] $Context
    )
    $reasons = @()
    if ($Action.Modifies -and -not $OperationProfile.AllowModify) { $reasons += 'policy.readonly-profile' }
    if ($script:WcRiskOrder[[string]$Action.Risk] -gt $script:WcRiskOrder[[string]$OperationProfile.MaxRisk]) { $reasons += 'policy.risk-above-profile' }
    if ($Action.RequiresAdmin -and -not $Context.IsAdmin) { $reasons += 'policy.requires-admin' }
    if ($Action.ContainsKey('RequiresWindows') -and $Action.RequiresWindows -and -not $Context.IsWindows) { $reasons += 'policy.requires-windows' }
    $blockedManaged = ($Action.ContainsKey('BlockedWhenManaged') -and $Action.BlockedWhenManaged)
    if ($blockedManaged -and $Context.IsManaged) { $reasons += 'policy.managed-device' }
    # Corporate-strict profiles treat "managed sensitive" actions as blocked even when
    # management was not detected: detection can miss signals, policy must not.
    if ($blockedManaged -and $OperationProfile.StrictManaged -and $Action.Modifies -and -not $Context.IsManaged) { $reasons += 'policy.managed-strict' }
    if ($Action.ContainsKey('MinBuild') -and $Action.MinBuild -and $Context.Build -lt [int]$Action.MinBuild) { $reasons += 'policy.build-unsupported' }
    if ($Action.ContainsKey('Editions') -and $Action.Editions) {
        if (@($Action.Editions) -notcontains $Context.EditionId) { $reasons += 'policy.edition-unsupported' }
    }
    return [pscustomobject]@{ Allowed = ($reasons.Count -eq 0); Reasons = $reasons }
}

function New-WcPlan {
    <# Builds an ordered plan for the requested action ids. Unknown ids throw (allowlist). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object[]] $Catalog,
        [Parameter(Mandatory = $true)][string[]] $ActionId,
        [Parameter(Mandatory = $true)][object] $OperationProfile,
        [Parameter(Mandatory = $true)][hashtable] $Context
    )
    $index = @{}
    foreach ($a in $Catalog) { $index[$a.Id] = $a }
    $items = @()
    foreach ($id in $ActionId) {
        if (-not $index.ContainsKey($id)) { throw "Action not in catalog (allowlist): $id" }
        $a = $index[$id]
        $decision = Test-WcActionAllowed -Action $a -OperationProfile $OperationProfile -Context $Context
        if (-not $script:WcState.Handlers.ContainsKey([string]$a.Handler)) {
            $decision = [pscustomobject]@{ Allowed = $false; Reasons = @($decision.Reasons) + 'policy.no-handler' }
        }
        $status = 'Pending'
        if (-not $decision.Allowed) { $status = 'Blocked' }
        $items += [pscustomobject]@{
            ActionId             = $a.Id
            TitleKey             = $a.TitleKey
            Category             = $a.Category
            Risk                 = $a.Risk
            Modifies             = [bool]$a.Modifies
            Reversible           = [bool]$a.Reversible
            RequiresConfirmation = ([bool]$a.Modifies -or [string]$a.Risk -ne 'None')
            Allowed              = $decision.Allowed
            Reasons              = $decision.Reasons
            Handler              = $a.Handler
            Status               = $status
        }
    }
    return [pscustomobject]@{
        Id      = [guid]::NewGuid().ToString()
        Created = (Get-Date).ToUniversalTime().ToString('o')
        Profile = $OperationProfile.Name
        Items   = $items
    }
}

function Invoke-WcPlan {
    <#
        Runs a plan. -DryRun calls only the Preview of each handler, never Execute.
        Items that require confirmation run only if -ConfirmCallback returns $true.
        Every decision is written to the audit log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][hashtable] $Context,
        [switch] $DryRun,
        [scriptblock] $ConfirmCallback
    )
    $results = @()
    $mode = 'Execute'
    if ($DryRun) { $mode = 'DryRun' }
    Write-WcLog -Level Audit -Category 'Plan' -Message ("Plan {0} started ({1}, profile {2})." -f $Plan.Id, $mode, $Plan.Profile) | Out-Null
    foreach ($item in $Plan.Items) {
        $r = [ordered]@{ ActionId = $item.ActionId; Mode = $mode; Status = ''; Output = $null; Error = $null
            Started = (Get-Date).ToUniversalTime().ToString('o'); Finished = $null }
        if (-not $item.Allowed) {
            $r.Status = 'Blocked'
            $r.Error = ($item.Reasons -join ',')
        }
        else {
            $handler = $script:WcState.Handlers[[string]$item.Handler]
            try {
                if ($DryRun) {
                    $r.Output = & $handler.Preview $Context
                    $r.Status = 'Previewed'
                }
                else {
                    $confirmed = $true
                    if ($item.RequiresConfirmation) {
                        $confirmed = $false
                        if ($ConfirmCallback) { $confirmed = [bool](& $ConfirmCallback $item) }
                    }
                    if ($confirmed) {
                        $r.Output = & $handler.Execute $Context
                        $r.Status = 'Succeeded'
                    }
                    else { $r.Status = 'Skipped' }
                }
            }
            catch {
                $r.Status = 'Failed'
                $r.Error = $_.Exception.Message
            }
        }
        $r.Finished = (Get-Date).ToUniversalTime().ToString('o')
        $level = 'Audit'
        if ($r.Status -eq 'Failed') { $level = 'Error' }
        Write-WcLog -Level $level -Category 'Plan' -Message ("{0}: {1}" -f $item.ActionId, $r.Status) -Data @{ plan = $Plan.Id; error = $r.Error } | Out-Null
        $results += [pscustomobject]$r
    }
    return $results
}

# -------------------------------------------------------------- validation --

function Test-WcPathWithin {
    <# True if Path resolves inside one of AllowedRoots (blocks ..\ traversal). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string[]] $AllowedRoots
    )
    $full = [System.IO.Path]::GetFullPath($Path)
    $comparison = [System.StringComparison]::Ordinal
    if (Test-WcIsWindows) { $comparison = [System.StringComparison]::OrdinalIgnoreCase }
    foreach ($root in $AllowedRoots) {
        $r = [System.IO.Path]::GetFullPath($root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
        if ($full.Equals($r, $comparison)) { return $true }
        if ($full.StartsWith($r + [System.IO.Path]::DirectorySeparatorChar, $comparison)) { return $true }
    }
    return $false
}

function Test-WcDriveLetter {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Value)
    return ($Value -match '^[A-Za-z]:$')
}

Export-ModuleMember -Function @(
    'Test-WcIsWindows', 'Test-WcIsAdmin', 'Get-WcDataRoot', 'ConvertTo-WcHashtable', 'Read-WcJsonFile', 'Write-WcTextFile',
    'Initialize-WcLog', 'Set-WcLogSink', 'Get-WcLogPath', 'Write-WcLog', 'Read-WcLog',
    'Get-WcSupportedLanguages', 'Import-WcLocalization', 'Get-WcString', 'Get-WcLocalizedValue',
    'Get-WcDefaultSettings', 'Test-WcSettings', 'Read-WcSettings', 'Save-WcSettings',
    'Get-WcProfile', 'Register-WcActionHandler', 'Get-WcActionHandlerNames', 'Clear-WcActionHandlers',
    'Test-WcActionDefinition', 'Import-WcActionCatalog', 'New-WcActionResult', 'New-WcContext', 'Test-WcActionAllowed',
    'New-WcPlan', 'Invoke-WcPlan', 'Test-WcPathWithin', 'Test-WcDriveLetter'
)
