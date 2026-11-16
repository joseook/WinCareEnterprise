#Requires -Version 5.1
<#
    WinCare.Diagnostics - runs the read-only collection actions through the Core
    plan engine (so every step is audited) and turns the snapshot into findings.

    Findings are rule-based. Each rule has a documented threshold
    (docs/METODOLOGIA.md); there is no aggregated "health score".
#>

function Get-WcDefaultThreshold {
    return @{
        SystemDiskWarnPercent = 10
        SystemDiskWarnBytes   = 10GB
        SystemDiskCritPercent = 5
        SystemDiskCritBytes   = 5GB
        OtherDiskWarnPercent  = 10
        MemoryWarnPercent     = 90
        CpuSampleWarnPercent  = 90
        UptimeInfoHours       = 336
    }
}

function Register-WcDiagnosticHandler {
    <# Registers the read-only handlers referenced by actions.json. #>
    [CmdletBinding()]
    param()
    Register-WcActionHandler -Name 'Diag-System' -Preview { param($c) 'Read Windows, CPU, memory, uptime and pending reboot (CIM/registry, read-only).' } -Execute { param($c) Get-WcSystemInfo }
    Register-WcActionHandler -Name 'Diag-Storage' -Preview { param($c) 'Read fixed volumes and physical disk media type (read-only).' } -Execute { param($c) Get-WcVolumeInfo }
    Register-WcActionHandler -Name 'Diag-Processes' -Preview { param($c) 'List the processes using the most memory (read-only).' } -Execute { param($c) Get-WcTopProcess -Top 15 }
    Register-WcActionHandler -Name 'Diag-Startup' -Preview { param($c) 'List startup entries from Run keys and Startup folders (read-only).' } -Execute { param($c) Get-WcStartupItem }
    Register-WcActionHandler -Name 'Diag-Security' -Preview { param($c) 'Detect management signals and protection state (read-only).' } -Execute { param($c) [pscustomobject]@{ Management = Get-WcManagementState; Protection = Get-WcProtectionState } }
}

function Get-WcDiagnosticSectionMap {
    return [ordered]@{
        system    = 'diag.system'
        storage   = 'diag.storage'
        processes = 'diag.processes'
        startup   = 'diag.startup'
        security  = 'diag.security'
    }
}

function Invoke-WcDiagnostic {
    <#
        Runs the selected sections and returns a snapshot:
          Meta, System, Storage, Processes, Startup, Security, Errors, Findings
        A failing section is recorded in Errors; the others still run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $CatalogPath,
        [ValidateSet('system', 'storage', 'processes', 'startup', 'security')]
        [string[]] $Section = @('system', 'storage', 'processes', 'startup', 'security'),
        [string] $AppVersion = '0.0.0',
        [string] $OperationProfileName = 'Diagnostico'
    )
    Register-WcDiagnosticHandler
    $catalog = Import-WcActionCatalog -Path $CatalogPath
    $map = Get-WcDiagnosticSectionMap
    $ids = @(foreach ($s in $Section) { $map[$s] })
    $ctx = New-WcContext -IsAdmin (Test-WcIsAdmin) -IsWindows (Test-WcIsWindows)
    $plan = New-WcPlan -Catalog $catalog -ActionId $ids -OperationProfile (Get-WcProfile $OperationProfileName) -Context $ctx
    $started = Get-Date
    $results = Invoke-WcPlan -Plan $plan -Context $ctx

    $snapshot = [ordered]@{
        Meta      = [ordered]@{
            Tool          = 'WinCare Enterprise'
            Version       = $AppVersion
            Created       = $started.ToUniversalTime().ToString('o')
            DurationMs    = [int]((Get-Date) - $started).TotalMilliseconds
            Profile       = $OperationProfileName
            Computer      = [System.Environment]::MachineName
            PlanId        = $plan.Id
        }
        System    = $null
        Storage   = $null
        Processes = $null
        Startup   = $null
        Security  = $null
        Errors    = @()
        Findings  = @()
    }
    $keyById = @{}
    foreach ($k in $map.Keys) { $keyById[$map[$k]] = $k }
    foreach ($r in $results) {
        $name = $keyById[$r.ActionId]
        $prop = (Get-Culture).TextInfo.ToTitleCase($name)
        if ($r.Status -eq 'Succeeded') {
            if (@('Storage', 'Processes', 'Startup') -contains $prop) { $snapshot[$prop] = @($r.Output | Where-Object { $null -ne $_ }) }
            else { $snapshot[$prop] = $r.Output }
        }
        else { $snapshot.Errors += [pscustomobject]@{ Section = $name; Status = $r.Status; Error = $r.Error } }
    }
    $snapshot.Findings = @(Get-WcFinding -Snapshot $snapshot)
    return [pscustomobject]$snapshot
}

function New-WcFinding {
    param([string] $Id, [ValidateSet('Info', 'Warning', 'Critical')][string] $Severity, [object[]] $Evidence)
    return [pscustomobject]@{
        Id                = $Id
        Severity          = $Severity
        TitleKey          = "finding.$Id.title"
        RecommendationKey = "finding.$Id.recommendation"
        Evidence          = $Evidence
    }
}

function Get-WcFinding {
    <# Pure: snapshot in, findings out. Missing sections produce no findings (never guessed). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Snapshot,
        [hashtable] $Threshold = (Get-WcDefaultThreshold)
    )
    $out = @()
    $storage = Get-WcObjectValue $Snapshot 'Storage'
    foreach ($v in @($storage)) {
        if ($null -eq $v -or $null -eq $v.FreePercent) { continue }
        $freeGb = [math]::Round($v.FreeBytes / 1GB, 1)
        if ($v.IsSystem) {
            if ($v.FreePercent -lt $Threshold.SystemDiskCritPercent -or $v.FreeBytes -lt $Threshold.SystemDiskCritBytes) {
                $out += New-WcFinding -Id 'disk-system-critical' -Severity Critical -Evidence @($v.Drive, $freeGb, $v.FreePercent)
            }
            elseif ($v.FreePercent -lt $Threshold.SystemDiskWarnPercent -or $v.FreeBytes -lt $Threshold.SystemDiskWarnBytes) {
                $out += New-WcFinding -Id 'disk-system-low' -Severity Warning -Evidence @($v.Drive, $freeGb, $v.FreePercent)
            }
            if ($v.MediaType -eq 'HDD') {
                $out += New-WcFinding -Id 'disk-system-hdd' -Severity Info -Evidence @($v.Drive)
            }
        }
        elseif ($v.FreePercent -lt $Threshold.OtherDiskWarnPercent) {
            $out += New-WcFinding -Id 'disk-other-low' -Severity Warning -Evidence @($v.Drive, $freeGb, $v.FreePercent)
        }
    }
    $system = Get-WcObjectValue $Snapshot 'System'
    if ($system) {
        $mem = Get-WcObjectValue $system 'Memory'
        if ($mem -and $null -ne $mem.UsedPercent -and $mem.UsedPercent -ge $Threshold.MemoryWarnPercent) {
            $out += New-WcFinding -Id 'memory-high' -Severity Warning -Evidence @($mem.UsedPercent)
        }
        $cpu = Get-WcObjectValue $system 'Cpu'
        if ($cpu -and $null -ne $cpu.UsagePercent -and $cpu.UsagePercent -ge $Threshold.CpuSampleWarnPercent) {
            $out += New-WcFinding -Id 'cpu-high-sample' -Severity Info -Evidence @($cpu.UsagePercent)
        }
        $pr = Get-WcObjectValue $system 'PendingReboot'
        if ($pr -and $pr.IsPending) {
            $out += New-WcFinding -Id 'reboot-pending' -Severity Warning -Evidence @(($pr.Sources -join ', '))
        }
        $up = Get-WcObjectValue $system 'Uptime'
        if ($up -and $up.TotalHours -ge $Threshold.UptimeInfoHours) {
            $out += New-WcFinding -Id 'uptime-long' -Severity Info -Evidence @($up.Days)
        }
        $win = Get-WcObjectValue $system 'Windows'
        if ($win -and -not $win.InSupportMatrix) {
            $out += New-WcFinding -Id 'windows-out-of-matrix' -Severity Info -Evidence @($win.Family, $win.Edition, $win.Build)
        }
    }
    $sec = Get-WcObjectValue $Snapshot 'Security'
    if ($sec) {
        $prot = Get-WcObjectValue $sec 'Protection'
        if ($prot -and $prot.DefenderService -eq $false) {
            $out += New-WcFinding -Id 'defender-inactive' -Severity Info -Evidence @()
        }
        if ($prot -and $prot.FirewallAllProfiles -eq $false) {
            $out += New-WcFinding -Id 'firewall-profile-off' -Severity Warning -Evidence @()
        }
    }
    $rank = @{ Critical = 0; Warning = 1; Info = 2 }
    return @($out | Sort-Object -Property @{ Expression = { $rank[$_.Severity] } })
}

Export-ModuleMember -Function @('Get-WcDefaultThreshold', 'Register-WcDiagnosticHandler', 'Get-WcDiagnosticSectionMap', 'Invoke-WcDiagnostic', 'Get-WcFinding')
