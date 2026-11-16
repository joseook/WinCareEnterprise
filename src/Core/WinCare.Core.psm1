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
    # F5: plan-level hooks provided by feature modules (WinCare.Baseline):
    #   Measure      { param($Context) } -> metrics (generic: free bytes per fixed drive)
    #   RestorePoint { param($Plan, $Item) } -> restore point outcome
    PlanHooks = @{ Measure = $null; RestorePoint = $null }
}

$script:WcRiskOrder = @{ 'None' = 0; 'Low' = 1; 'Medium' = 2; 'High' = 3 }
$script:WcCategories = @('Diagnostics', 'Storage', 'Startup', 'Integrity', 'Processes', 'Applications',
    'Office', 'Services', 'Network', 'Performance', 'Security', 'Reporting')
# Fundamental protections. An action that declares it touches any of these is
# rejected when the catalog is loaded - no profile can ever enable it.
# Honest undo mechanism of an action (catalog field 'Reversibility', F5):
#   ReadOnly     - does not modify the system; nothing to undo.
#   None         - modifies and cannot be undone by WinCare (temp cleanup, SFC/DISM repair, ReTrim).
#   RestorePoint - system-state change that a Windows System Restore point taken before it can revert.
$script:WcReversibility = @('ReadOnly', 'None', 'RestorePoint')
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
        Measure (optional, F5): read-only, returns action-specific metrics
        (New-WcMetric) taken before and after Execute (docs/CONTRATO-ACOES.md).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z][A-Za-z0-9\-]+$')][string] $Name,
        [Parameter(Mandatory = $true)][scriptblock] $Preview,
        [Parameter(Mandatory = $true)][scriptblock] $Execute,
        [scriptblock] $Measure
    )
    $script:WcState.Handlers[$Name] = @{ Preview = $Preview; Execute = $Execute; Measure = $Measure }
}

function Register-WcPlanHook {
    <#
        F5 plan-level hooks, set by a feature module from its Register-Wc*Handler:
          Measure      { param($Context) }       generic before/after metrics (all actions)
          RestorePoint { param($Plan, $Item) }   creates/skips a restore point; returns an outcome
        Core stays platform-independent: without hooks there is no generic
        measurement and restore points are reported as Unavailable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Measure', 'RestorePoint')][string] $Name,
        [scriptblock] $ScriptBlock
    )
    $script:WcState.PlanHooks[$Name] = $ScriptBlock
}

function Clear-WcPlanHooks { $script:WcState.PlanHooks = @{ Measure = $null; RestorePoint = $null } }

function Get-WcActionHandlerNames { return @($script:WcState.Handlers.Keys) }

function Initialize-WcActionHandlers {
    <#
        Calls every exported Register-Wc*Handler function. Feature modules must NOT
        register at import time: when imported through WinCare.psd1 (NestedModules)
        Core's functions are not yet visible to sibling modules. Idempotent.
    #>
    [CmdletBinding()]
    param()
    foreach ($c in @(Get-Command -Name 'Register-Wc*Handler' -CommandType Function -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'Register-WcActionHandler' })) {
        try { & $c } catch { Write-WcLog -Level Error -Category 'Handlers' -Message ("{0} failed: {1}" -f $c.Name, $_.Exception.Message) | Out-Null }
    }
    return @($script:WcState.Handlers.Keys)
}

function Clear-WcActionHandlers { $script:WcState.Handlers = @{} }

function Test-WcActionDefinition {
    <# Validates one catalog entry. Returns an array of error strings (empty = valid). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable] $Action)
    $errors = @()
    foreach ($req in @('Id', 'Category', 'Risk', 'Modifies', 'RequiresAdmin', 'Reversible', 'Reversibility', 'Handler', 'TitleKey')) {
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
    $rev = [string]$Action.Reversibility
    if ($script:WcReversibility -notcontains $rev) { $errors += "invalid reversibility '$rev'" }
    elseif ($Action.Modifies -is [bool]) {
        if (-not $Action.Modifies -and $rev -ne 'ReadOnly') { $errors += "read-only action must have reversibility 'ReadOnly'" }
        if ($Action.Modifies -and $rev -eq 'ReadOnly') { $errors += "modifying action cannot have reversibility 'ReadOnly'" }
        if ($Action.Modifies -and $rev -eq 'None' -and $Action.Reversible -eq $true) { $errors += "reversibility 'None' contradicts Reversible=true" }
        if ($rev -eq 'RestorePoint' -and @('Medium', 'High') -notcontains [string]$Action.Risk) { $errors += "reversibility 'RestorePoint' requires risk Medium or High" }
    }
    if ($Action.ContainsKey('Touches')) {
        foreach ($t in @($Action.Touches)) {
            if ($script:WcProtectedFeatures -contains $t) { $errors += "touches protected feature '$t'" }
        }
    }
    if ($Action.ContainsKey('Pages')) {
        foreach ($pg in @($Action.Pages)) {
            if (@('quick', 'advanced', 'integrity', 'office', 'storage', 'startup', 'processes', 'health', 'apps', 'network') -notcontains $pg) { $errors += "invalid page '$pg'" }
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
    Initialize-WcActionHandlers | Out-Null
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
            Reversibility        = [string]$a.Reversibility
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

# ------------------------------------------------- before/after (F5) --

function New-WcMetric {
    <# One measured value. Source: System (plan hook) | Action (handler Measure). Value: number or $null. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Name,
        [string] $Target = '',
        [string] $Unit = 'Bytes',
        $Value = $null,
        [ValidateSet('System', 'Action')][string] $Source = 'Action'
    )
    return [pscustomobject]@{ Source = $Source; Name = $Name; Target = $Target; Unit = $Unit; Value = $Value }
}

function ConvertTo-WcMetricList {
    <# Pure: normalizes hook/handler output (metric objects or hashtables) and forces Source. #>
    [CmdletBinding()]
    param([object[]] $InputObject, [Parameter(Mandatory = $true)][ValidateSet('System', 'Action')][string] $Source)
    $out = @()
    $flat = @()
    foreach ($m in @($InputObject)) {
        # One level of nesting (a collector that returned ,@(...)) is flattened.
        if ($m -is [System.Array]) { $flat += @($m) } else { $flat += , $m }
    }
    foreach ($m in $flat) {
        if ($null -eq $m) { continue }
        $h = $m
        if ($m -isnot [System.Collections.IDictionary]) {
            $h = @{}
            foreach ($pr in $m.PSObject.Properties) { $h[$pr.Name] = $pr.Value }
        }
        if (-not $h.Contains('Name') -or -not $h['Name']) { continue }
        $target = ''; if ($h.Contains('Target') -and $null -ne $h['Target']) { $target = [string]$h['Target'] }
        $unit = 'Bytes'; if ($h.Contains('Unit') -and $h['Unit']) { $unit = [string]$h['Unit'] }
        $value = $null; if ($h.Contains('Value')) { $value = $h['Value'] }
        $out += New-WcMetric -Name ([string]$h['Name']) -Target $target -Unit $unit -Value $value -Source $Source
    }
    return $out
}

function Invoke-WcMeasurement {
    <#
        Takes one measurement: generic plan hook (System) + optional handler Measure (Action).
        Never throws: a failing collector is recorded in Errors and the action still runs.
    #>
    [CmdletBinding()]
    param([hashtable] $Context, [scriptblock] $ActionMeasure)
    $metrics = @()
    $errs = @()
    $hook = $script:WcState.PlanHooks['Measure']
    if ($hook) {
        try { $metrics += @(ConvertTo-WcMetricList -InputObject @(& $hook $Context) -Source System) }
        catch { $errs += ('system: ' + $_.Exception.Message) }
    }
    if ($ActionMeasure) {
        try { $metrics += @(ConvertTo-WcMetricList -InputObject @(& $ActionMeasure $Context) -Source Action) }
        catch { $errs += ('action: ' + $_.Exception.Message) }
    }
    return [pscustomobject]@{ Time = (Get-Date).ToUniversalTime().ToString('o'); Metrics = @($metrics); Errors = @($errs) }
}

function Test-WcNumber {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Value)
    if ($null -eq $Value) { return $false }
    foreach ($t in @([int], [long], [double], [decimal], [single], [uint32], [uint64], [int16], [uint16], [byte])) {
        if ($Value -is $t) { return $true }
    }
    return $false
}

function ConvertTo-WcComparison {
    <#
        Pure before/after comparison. Rows are matched by Source+Name+Target; Delta = After - Before
        (positive free bytes = space gained; negative folder bytes = space removed).
        FreeBytes* sum the System 'FreeBytes' rows present on both sides (drives that appeared or
        vanished between the two measurements are listed but not summed).
        Note: free space is system-wide; other processes can change it during the action.
    #>
    [CmdletBinding()]
    param($Before, $After)
    $order = New-Object System.Collections.Generic.List[string]
    $map = @{}
    foreach ($side in @('Before', 'After')) {
        $m = $Before
        if ($side -eq 'After') { $m = $After }
        if ($null -eq $m) { continue }
        foreach ($x in @($m.Metrics)) {
            if ($null -eq $x) { continue }
            $key = '{0}|{1}|{2}' -f $x.Source, $x.Name, $x.Target
            if (-not $map.ContainsKey($key)) {
                $map[$key] = [ordered]@{ Source = $x.Source; Name = $x.Name; Target = $x.Target; Unit = $x.Unit; Before = $null; After = $null; Delta = $null }
                $order.Add($key)
            }
            $map[$key][$side] = $x.Value
        }
    }
    $rows = @()
    $fb = 0.0; $fa = 0.0; $drives = 0; $incomplete = 0
    foreach ($k in $order) {
        $r = $map[$k]
        if ((Test-WcNumber $r.Before) -and (Test-WcNumber $r.After)) {
            $d = [double]$r.After - [double]$r.Before
            if ([math]::Floor($d) -eq $d -and [math]::Abs($d) -lt 9e15) { $r.Delta = [long]$d } else { $r.Delta = $d }
            if ($r.Source -eq 'System' -and $r.Name -eq 'FreeBytes') { $fb += [double]$r.Before; $fa += [double]$r.After; $drives++ }
        }
        else { $incomplete++ }
        $rows += [pscustomobject]$r
    }
    $errs = @()
    foreach ($m in @($Before, $After)) {
        if ($null -ne $m -and $m.PSObject.Properties['Errors']) { $errs += @($m.Errors) }
    }
    $freeBefore = $null; $freeAfter = $null; $freeDelta = $null
    if ($drives -gt 0) { $freeBefore = [long]$fb; $freeAfter = [long]$fa; $freeDelta = [long]($fa - $fb) }
    return [pscustomobject]@{
        Rows = @($rows); FreeBytesBefore = $freeBefore; FreeBytesAfter = $freeAfter; FreeBytesDelta = $freeDelta
        Complete = ($null -ne $Before -and $null -ne $After -and $incomplete -eq 0 -and $errs.Count -eq 0); Errors = @($errs)
    }
}

function Test-WcRestorePointRequired {
    <#
        Pure: does this plan item need a System Restore point before it runs?
        Policy Off = never; High = Risk High or Reversibility RestorePoint;
        MediumAndHigh = also Risk Medium. Read-only items never need one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)] $Item,
        [ValidateSet('Off', 'High', 'MediumAndHigh')][string] $Policy = 'High'
    )
    if ($Policy -eq 'Off' -or -not [bool]$Item.Modifies) { return $false }
    $rev = ''
    if ($Item.PSObject.Properties['Reversibility']) { $rev = [string]$Item.Reversibility }
    if ($rev -eq 'RestorePoint') { return $true }
    if ([string]$Item.Risk -eq 'High') { return $true }
    if ([string]$Item.Risk -eq 'Medium' -and $Policy -eq 'MediumAndHigh') { return $true }
    return $false
}

function New-WcRestorePointOutcome {
    <#
        Status: Created | Skipped | Unavailable | Failed.
        Reason: created-recently, not-windows, powershell-edition, cmdlet-missing, requires-admin,
        server-sku, disabled-by-policy, protection-disabled, no-provider, not-verified, error.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Created', 'Skipped', 'Unavailable', 'Failed')][string] $Status,
        [string] $Reason = '',
        $SequenceNumber = $null,
        [string] $CreationTime = $null,
        [string] $Description = $null,
        [string] $Detail = $null
    )
    return [pscustomobject]@{ Status = $Status; Reason = $Reason; SequenceNumber = $SequenceNumber; CreationTime = $CreationTime; Description = $Description; Detail = $Detail }
}

function Test-WcRestorePointUsable {
    <# Pure: true when the outcome gives a real rollback point (a new one, or a recent existing one). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Outcome)
    if ($null -eq $Outcome) { return $false }
    if ($Outcome.Status -eq 'Created') { return $true }
    return ($Outcome.Status -eq 'Skipped' -and $Outcome.Reason -eq 'created-recently' -and $null -ne $Outcome.SequenceNumber)
}

function Invoke-WcRestorePointHook {
    <# Calls the RestorePoint hook; never throws (a failure becomes an outcome). #>
    [CmdletBinding()]
    param($Plan, $Item)
    $hook = $script:WcState.PlanHooks['RestorePoint']
    $outcome = $null
    if (-not $hook) { $outcome = New-WcRestorePointOutcome -Status Unavailable -Reason 'no-provider' -Detail 'No restore point provider registered on this platform.' }
    else {
        try {
            $outcome = @(& $hook $Plan $Item) | Select-Object -Last 1
            if ($null -eq $outcome -or -not $outcome.PSObject.Properties['Status']) { $outcome = New-WcRestorePointOutcome -Status Failed -Reason 'error' -Detail 'Restore point provider returned no outcome.' }
        }
        catch { $outcome = New-WcRestorePointOutcome -Status Failed -Reason 'error' -Detail $_.Exception.Message }
    }
    Write-WcLog -Level Audit -Category 'RestorePoint' -Message ('Restore point for plan {0}: {1} {2}' -f $Plan.Id, $outcome.Status, $outcome.Reason) -Data @{ sequence = $outcome.SequenceNumber; detail = $outcome.Detail } | Out-Null
    return $outcome
}

function Invoke-WcPlan {
    <#
        Runs a plan. -DryRun calls only the Preview of each handler, never Execute.
        Items that require confirmation run only if -ConfirmCallback returns $true.
        Every decision is written to the audit log.
        F5 (never in DryRun):
          * each executed item is measured before and after (-Measure All | Modifying | None)
            and the result carries Before, After and Comparison (ConvertTo-WcComparison);
          * before the first confirmed item that needs one (Test-WcRestorePointRequired with
            -RestorePointPolicy) the RestorePoint hook runs ONCE per plan; the outcome is
            attached to every item that needed it. With -RequireRestorePoint those items are
            Skipped when no usable restore point exists. Nothing here enables System Protection.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object] $Plan,
        [Parameter(Mandatory = $true)][hashtable] $Context,
        [switch] $DryRun,
        [scriptblock] $ConfirmCallback,
        [ValidateSet('All', 'Modifying', 'None')][string] $Measure = 'All',
        [ValidateSet('Off', 'High', 'MediumAndHigh')][string] $RestorePointPolicy = 'High',
        [switch] $RequireRestorePoint
    )
    $results = @()
    $mode = 'Execute'
    if ($DryRun) { $mode = 'DryRun' }
    $rpOutcome = $null
    Write-WcLog -Level Audit -Category 'Plan' -Message ("Plan {0} started ({1}, profile {2})." -f $Plan.Id, $mode, $Plan.Profile) | Out-Null
    foreach ($item in $Plan.Items) {
        $rev = $null
        if ($item.PSObject.Properties['Reversibility']) { $rev = $item.Reversibility }
        $r = [ordered]@{ ActionId = $item.ActionId; Mode = $mode; Status = ''; Output = $null; Error = $null
            Started = (Get-Date).ToUniversalTime().ToString('o'); Finished = $null
            Reversibility = $rev; RestorePoint = $null; Before = $null; After = $null; Comparison = $null
        }
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
                    $run = $confirmed
                    if ($confirmed -and (Test-WcRestorePointRequired -Item $item -Policy $RestorePointPolicy)) {
                        if ($null -eq $rpOutcome) { $rpOutcome = Invoke-WcRestorePointHook -Plan $Plan -Item $item }
                        $r.RestorePoint = $rpOutcome
                        if ($RequireRestorePoint -and -not (Test-WcRestorePointUsable -Outcome $rpOutcome)) {
                            $run = $false
                            $r.Error = 'restorepoint.required-not-available'
                        }
                    }
                    if ($run) {
                        $doMeasure = ($Measure -eq 'All' -or ($Measure -eq 'Modifying' -and [bool]$item.Modifies))
                        $actionMeasure = $null
                        if ($handler.ContainsKey('Measure')) { $actionMeasure = $handler['Measure'] }
                        if ($doMeasure) { $r.Before = Invoke-WcMeasurement -Context $Context -ActionMeasure $actionMeasure }
                        try {
                            $r.Output = & $handler.Execute $Context
                            $r.Status = 'Succeeded'
                        }
                        finally {
                            # Measured even when Execute fails: a partial run may have changed something.
                            if ($doMeasure) {
                                $r.After = Invoke-WcMeasurement -Context $Context -ActionMeasure $actionMeasure
                                $r.Comparison = ConvertTo-WcComparison -Before $r.Before -After $r.After
                            }
                        }
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
        $logData = @{ plan = $Plan.Id; error = $r.Error }
        if ($null -ne $r.Comparison) { $logData['freeBytesDelta'] = $r.Comparison.FreeBytesDelta }
        if ($null -ne $r.RestorePoint) { $logData['restorePoint'] = ('{0} {1}' -f $r.RestorePoint.Status, $r.RestorePoint.Reason).Trim() }
        Write-WcLog -Level $level -Category 'Plan' -Message ("{0}: {1}" -f $item.ActionId, $r.Status) -Data $logData | Out-Null
        $results += [pscustomobject]$r
    }
    return $results
}

# ----------------------------------------------------------------- history --

function Get-WcResultValue {
    <# StrictMode-safe property read (old results and history rows may lack F5 fields). #>
    [CmdletBinding()]
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-WcHistoryEntry {
    <# Pure: one plan result -> the flat record written to history (also the action report row). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Plan, [Parameter(Mandatory = $true)] $Result)
    $o = Get-WcResultValue $Result 'Output'
    $summary = $null; $before = $null; $after = $null; $freed = $null; $exit = $null; $rollbackData = $false
    if ($o -and $o.PSObject.Properties['Summary']) {
        $summary = $o.Summary; $before = $o.BytesBefore; $after = $o.BytesAfter; $freed = $o.BytesFreed; $exit = $o.ExitCode
        $rollbackData = ($null -ne $o.RollbackData)
    }
    $cmp = Get-WcResultValue $Result 'Comparison'
    $rows = $null; $freeDelta = $null; $mErrors = $null
    if ($null -ne $cmp) {
        $rows = @(foreach ($x in @($cmp.Rows)) { [ordered]@{ source = $x.Source; name = $x.Name; target = $x.Target; unit = $x.Unit; before = $x.Before; after = $x.After; delta = $x.Delta } })
        $freeDelta = $cmp.FreeBytesDelta
        $mErrors = @($cmp.Errors)
    }
    $rp = Get-WcResultValue $Result 'RestorePoint'
    $rpEntry = $null
    if ($null -ne $rp) {
        $rpEntry = [ordered]@{ status = $rp.Status; reason = $rp.Reason; sequenceNumber = $rp.SequenceNumber; creationTime = $rp.CreationTime; description = $rp.Description; detail = $rp.Detail }
    }
    return [ordered]@{
        time = (Get-Date).ToUniversalTime().ToString('o'); plan = $Plan.Id; profile = $Plan.Profile; computer = [System.Environment]::MachineName
        action = (Get-WcResultValue $Result 'ActionId'); mode = (Get-WcResultValue $Result 'Mode'); status = (Get-WcResultValue $Result 'Status')
        summary = $summary; error = (Get-WcResultValue $Result 'Error')
        bytesBefore = $before; bytesAfter = $after; bytesFreed = $freed; exitCode = $exit
        rollbackAvailable = ($rollbackData -or (Test-WcRestorePointUsable -Outcome $rp))
        reversibility = (Get-WcResultValue $Result 'Reversibility'); restorePoint = $rpEntry
        freeBytesDelta = $freeDelta; comparison = $rows; measurementErrors = $mErrors
    }
}

function Add-WcHistory {
    <# Appends one JSON line per plan item to <Directory>/actions-YYYYMM.jsonl (audit trail: before/after, restore point). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Directory,
        [Parameter(Mandatory = $true)] $Plan,
        [object[]] $Results = @()
    )
    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $file = Join-Path $Directory ('actions-{0}.jsonl' -f (Get-Date).ToString('yyyyMM'))
    $n = 0
    foreach ($r in @($Results)) {
        if ($null -eq $r) { continue }
        $entry = ConvertTo-WcHistoryEntry -Plan $Plan -Result $r
        [System.IO.File]::AppendAllText($file, (ConvertTo-Json -InputObject $entry -Compress -Depth 6) + "`n", (New-Object System.Text.UTF8Encoding($false)))
        $n++
    }
    return $n
}

function Read-WcHistory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Directory, [int] $Last = 200)
    if (-not (Test-Path -LiteralPath $Directory)) { return @() }
    $rows = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Directory -Filter 'actions-*.jsonl' | Sort-Object Name)) {
        foreach ($line in [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)) {
            if ($line.Trim()) { try { $rows += ($line | ConvertFrom-Json) } catch { Write-Verbose 'Skipping malformed history line.' } }
        }
    }
    return @($rows | Select-Object -Last $Last)
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
    'Get-WcProfile', 'Register-WcActionHandler', 'Get-WcActionHandlerNames', 'Initialize-WcActionHandlers', 'Clear-WcActionHandlers',
    'Test-WcActionDefinition', 'Import-WcActionCatalog', 'New-WcActionResult', 'New-WcContext', 'Test-WcActionAllowed',
    'New-WcPlan', 'Invoke-WcPlan', 'Add-WcHistory', 'Read-WcHistory',
    'Register-WcPlanHook', 'Clear-WcPlanHooks', 'New-WcMetric', 'ConvertTo-WcMetricList', 'Invoke-WcMeasurement', 'ConvertTo-WcComparison',
    'Test-WcRestorePointRequired', 'New-WcRestorePointOutcome', 'Test-WcRestorePointUsable', 'Invoke-WcRestorePointHook',
    'Get-WcResultValue', 'ConvertTo-WcHistoryEntry', 'Test-WcNumber', 'Test-WcPathWithin', 'Test-WcDriveLetter'
)
