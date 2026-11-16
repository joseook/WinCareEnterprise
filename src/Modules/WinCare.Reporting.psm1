#Requires -Version 5.1
<#
    WinCare.Reporting - JSON and HTML export of a diagnostic snapshot.
    Every value written to HTML is encoded (no script injection from process
    names, volume labels or startup commands). Pure; runs on any platform.
#>

function ConvertTo-WcReportJson {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Snapshot)
    return (ConvertTo-Json -InputObject $Snapshot -Depth 8)
}

function ConvertTo-WcHtmlText {
    param($Value)
    if ($null -eq $Value) { return '-' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function Format-WcBytes {
    [CmdletBinding()]
    param($Bytes)
    if ($null -eq $Bytes) { return '-' }
    $b = [double]$Bytes
    if ($b -ge 1TB) { return ('{0:N1} TB' -f ($b / 1TB)) }
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

function ConvertTo-WcHtmlTable {
    param([object[]] $Rows, [string[]] $Columns, [hashtable] $Format = @{})
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $Columns) { [void]$sb.Append('<th>' + (ConvertTo-WcHtmlText $c) + '</th>') }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($r in @($Rows)) {
        if ($null -eq $r) { continue }
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) {
            $v = Get-WcObjectValue $r $c
            if ($Format.ContainsKey($c)) { $v = & $Format[$c] $v }
            [void]$sb.Append('<td>' + (ConvertTo-WcHtmlText $v) + '</td>')
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function ConvertTo-WcReportHtml {
    <# Self-contained HTML (inline CSS, no scripts, no external resources). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Snapshot,
        [string] $Language = 'pt-BR'
    )
    $meta = Get-WcObjectValue $Snapshot 'Meta'
    $sys = Get-WcObjectValue $Snapshot 'System'
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!DOCTYPE html><html lang="' + (ConvertTo-WcHtmlText $Language) + '"><head><meta charset="utf-8">')
    [void]$sb.Append('<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">')
    [void]$sb.Append('<title>' + (ConvertTo-WcHtmlText (Get-WcString 'report.title')) + '</title>')
    [void]$sb.Append('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1f24;background:#fff}h1{font-size:22px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid #d0d7de;padding-bottom:4px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eaeef2;vertical-align:top}th{background:#f6f8fa}.Critical{color:#b42318;font-weight:600}.Warning{color:#9a6700;font-weight:600}.Info{color:#0b5cad}.muted{color:#57606a;font-size:12px}</style></head><body>')
    [void]$sb.Append('<h1>' + (ConvertTo-WcHtmlText (Get-WcString 'report.title')) + '</h1>')
    [void]$sb.Append('<p class="muted">' + (ConvertTo-WcHtmlText ('{0} {1} | {2} | {3} | {4}' -f $meta.Tool, $meta.Version, $meta.Computer, $meta.Created, $meta.Profile)) + '</p>')

    [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.findings')) + '</h2>')
    $findings = @(Get-WcObjectValue $Snapshot 'Findings')
    if ($findings.Count -eq 0) { [void]$sb.Append('<p>' + (ConvertTo-WcHtmlText (Get-WcString 'report.no-findings')) + '</p>') }
    else {
        [void]$sb.Append('<table><thead><tr><th>' + (ConvertTo-WcHtmlText (Get-WcString 'report.severity')) + '</th><th>' + (ConvertTo-WcHtmlText (Get-WcString 'report.finding')) + '</th><th>' + (ConvertTo-WcHtmlText (Get-WcString 'report.recommendation')) + '</th></tr></thead><tbody>')
        foreach ($f in $findings) {
            if ($null -eq $f) { continue }
            $title = Get-WcString -Key $f.TitleKey -Arguments $f.Evidence
            $rec = Get-WcString -Key $f.RecommendationKey -Arguments $f.Evidence
            $sev = Get-WcString -Key ('severity.' + $f.Severity)
            [void]$sb.Append('<tr><td class="' + (ConvertTo-WcHtmlText $f.Severity) + '">' + (ConvertTo-WcHtmlText $sev) + '</td><td>' + (ConvertTo-WcHtmlText $title) + '</td><td>' + (ConvertTo-WcHtmlText $rec) + '</td></tr>')
        }
        [void]$sb.Append('</tbody></table>')
    }

    if ($sys) {
        [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.system')) + '</h2>')
        $w = $sys.Windows
        $rows = @(
            [pscustomobject]@{ Item = 'Windows'; Value = ('{0} {1} ({2}) build {3}.{4} {5}' -f $w.Family, $w.Edition, $w.DisplayVersion, $w.Build, $w.Ubr, $w.Architecture) }
            [pscustomobject]@{ Item = 'CPU'; Value = ('{0} | {1} cores / {2} threads | {3}%' -f $sys.Cpu.Name, $sys.Cpu.Cores, $sys.Cpu.LogicalProcessors, $sys.Cpu.UsagePercent) }
            [pscustomobject]@{ Item = 'RAM'; Value = ('{0} / {1} ({2}%)' -f (Format-WcBytes $sys.Memory.AvailableBytes), (Format-WcBytes $sys.Memory.TotalBytes), $sys.Memory.UsedPercent) }
            [pscustomobject]@{ Item = 'Uptime'; Value = $(if ($sys.Uptime) { '{0}d {1}h {2}min' -f $sys.Uptime.Days, $sys.Uptime.Hours, $sys.Uptime.Minutes } else { '-' }) }
            [pscustomobject]@{ Item = 'Reboot'; Value = $(if ($sys.PendingReboot) { [string]$sys.PendingReboot.IsPending } else { '-' }) }
            [pscustomobject]@{ Item = 'PowerShell'; Value = ('{0} {1} | admin={2}' -f $sys.PowerShell, $sys.PSEdition, $sys.IsAdmin) }
        )
        [void]$sb.Append((ConvertTo-WcHtmlTable -Rows $rows -Columns @('Item', 'Value')))
    }
    $storage = @(Get-WcObjectValue $Snapshot 'Storage')
    if ($storage.Count -gt 0 -and $null -ne $storage[0]) {
        [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.storage')) + '</h2>')
        $fmt = @{ SizeBytes = { param($v) Format-WcBytes $v }; FreeBytes = { param($v) Format-WcBytes $v } }
        [void]$sb.Append((ConvertTo-WcHtmlTable -Rows $storage -Columns @('Drive', 'Label', 'FileSystem', 'SizeBytes', 'FreeBytes', 'FreePercent', 'MediaType', 'BusType') -Format $fmt))
    }
    $procs = @(Get-WcObjectValue $Snapshot 'Processes')
    if ($procs.Count -gt 0 -and $null -ne $procs[0]) {
        [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.processes')) + '</h2>')
        [void]$sb.Append((ConvertTo-WcHtmlTable -Rows $procs -Columns @('Name', 'Id', 'WorkingSetBytes', 'CpuSecondsTotal', 'Company') -Format @{ WorkingSetBytes = { param($v) Format-WcBytes $v } }))
    }
    $startup = @(Get-WcObjectValue $Snapshot 'Startup')
    if ($startup.Count -gt 0 -and $null -ne $startup[0]) {
        [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.startup')) + '</h2>')
        [void]$sb.Append((ConvertTo-WcHtmlTable -Rows $startup -Columns @('Name', 'Command', 'Location', 'User')))
    }
    $errors = @(Get-WcObjectValue $Snapshot 'Errors')
    if ($errors.Count -gt 0 -and $null -ne $errors[0]) {
        [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.errors')) + '</h2>')
        [void]$sb.Append((ConvertTo-WcHtmlTable -Rows $errors -Columns @('Section', 'Status', 'Error')))
    }
    [void]$sb.Append('<p class="muted">' + (ConvertTo-WcHtmlText (Get-WcString 'report.footer')) + '</p></body></html>')
    return $sb.ToString()
}

function Export-WcReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Snapshot,
        [Parameter(Mandatory = $true)][string] $Path,
        [ValidateSet('Json', 'Html')][string] $Format = 'Json',
        [string] $Language = 'pt-BR'
    )
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $expected = '.json'
    if ($Format -eq 'Html') { $expected = '.html' }
    if ($ext -ne $expected -and -not ($Format -eq 'Html' -and $ext -eq '.htm')) { throw "Report path must end with $expected" }
    if ($Format -eq 'Json') { $content = ConvertTo-WcReportJson -Snapshot $Snapshot }
    else { $content = ConvertTo-WcReportHtml -Snapshot $Snapshot -Language $Language }
    Write-WcTextFile -Path $Path -Content $content
    Write-WcLog -Level Audit -Category 'Report' -Message ("Report exported ({0})." -f $Format) -Data @{ path = $Path } | Out-Null
    return (Get-Item -LiteralPath $Path)
}

# ------------------------------------------------- action report (F5) --

function Format-WcBytesDelta {
    <# Signed byte delta: '+1.5 GB', '-300 MB', '0 KB'. #>
    [CmdletBinding()]
    param($Bytes)
    if ($null -eq $Bytes) { return '-' }
    $b = [double]$Bytes
    $sign = ''
    if ($b -gt 0) { $sign = '+' } elseif ($b -lt 0) { $sign = '-' }
    return ($sign + (Format-WcBytes ([math]::Abs($b))))
}

function Format-WcMetricValue {
    param($Value, [string] $Unit, [switch] $Delta)
    if ($null -eq $Value) { return '-' }
    if ($Unit -eq 'Bytes') {
        if ($Delta) { return (Format-WcBytesDelta $Value) }
        return (Format-WcBytes $Value)
    }
    if ($Delta -and [double]$Value -gt 0) { return ('+' + [string]$Value) }
    return [string]$Value
}

function New-WcActionReport {
    <#
        Action report data (plan results with before/after and restore point outcome).
        -Plan/-Results: straight from Invoke-WcPlan. -History: rows from Read-WcHistory
        (e.g. one plan: Read-WcHistory | Where-Object plan -eq $id).
    #>
    [CmdletBinding(DefaultParameterSetName = 'Results')]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = 'Results')] $Plan,
        [Parameter(ParameterSetName = 'Results')][object[]] $Results = @(),
        [Parameter(Mandatory = $true, ParameterSetName = 'History')][object[]] $History,
        [string] $AppVersion = '0.0.0'
    )
    $items = @()
    $planId = $null; $profileName = $null
    if ($PSCmdlet.ParameterSetName -eq 'Results') {
        $planId = $Plan.Id; $profileName = $Plan.Profile
        foreach ($r in @($Results)) { if ($null -ne $r) { $items += [pscustomobject](ConvertTo-WcHistoryEntry -Plan $Plan -Result $r) } }
    }
    else {
        $items = @($History | Where-Object { $null -ne $_ })
        if ($items.Count -gt 0) {
            $planId = (@($items | ForEach-Object { Get-WcResultValue $_ 'plan' } | Sort-Object -Unique)) -join ', '
            $profileName = Get-WcResultValue $items[0] 'profile'
        }
    }
    return [pscustomobject]@{
        Meta  = [pscustomobject]@{ Tool = 'WinCare Enterprise'; Version = $AppVersion; Computer = [System.Environment]::MachineName
            Created = (Get-Date).ToUniversalTime().ToString('o'); PlanId = $planId; Profile = $profileName
        }
        Items = @($items)
    }
}

function Get-WcRestorePointText {
    param($RestorePoint)
    if ($null -eq $RestorePoint) { return '-' }
    $status = [string](Get-WcResultValue $RestorePoint 'status')
    $text = Get-WcString ('restorepoint.status.' + $status)
    $reason = [string](Get-WcResultValue $RestorePoint 'reason')
    if ($reason) { $text = $text + ' (' + (Get-WcString ('restorepoint.reason.' + $reason)) + ')' }
    $seq = Get-WcResultValue $RestorePoint 'sequenceNumber'
    if ($null -ne $seq) { $text = $text + ' #' + [string]$seq }
    $created = Get-WcResultValue $RestorePoint 'creationTime'
    if ($created) { $text = $text + ' ' + [string]$created }
    return $text
}

function ConvertTo-WcActionReportHtml {
    <# Self-contained HTML (inline CSS, no scripts, CSP). Every value is HTML-encoded. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Report,
        [string] $Language = 'pt-BR'
    )
    $meta = $Report.Meta
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<!DOCTYPE html><html lang="' + (ConvertTo-WcHtmlText $Language) + '"><head><meta charset="utf-8">')
    [void]$sb.Append('<meta http-equiv="Content-Security-Policy" content="default-src ''none''; style-src ''unsafe-inline''">')
    [void]$sb.Append('<title>' + (ConvertTo-WcHtmlText (Get-WcString 'report.actions.title')) + '</title>')
    [void]$sb.Append('<style>body{font-family:Segoe UI,Arial,sans-serif;margin:24px;color:#1b1f24;background:#fff}h1{font-size:22px}h2{font-size:17px;margin-top:28px;border-bottom:1px solid #d0d7de;padding-bottom:4px}h3{font-size:14px;margin-top:18px}table{border-collapse:collapse;width:100%;font-size:13px}th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #eaeef2;vertical-align:top}th{background:#f6f8fa}.muted{color:#57606a;font-size:12px}</style></head><body>')
    [void]$sb.Append('<h1>' + (ConvertTo-WcHtmlText (Get-WcString 'report.actions.title')) + '</h1>')
    [void]$sb.Append('<p class="muted">' + (ConvertTo-WcHtmlText ('{0} {1} | {2} | {3} | {4} | {5}' -f $meta.Tool, $meta.Version, $meta.Computer, $meta.Created, $meta.Profile, $meta.PlanId)) + '</p>')
    $items = @($Report.Items | Where-Object { $null -ne $_ })
    [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.actions.items')) + '</h2>')
    if ($items.Count -eq 0) { [void]$sb.Append('<p>' + (ConvertTo-WcHtmlText (Get-WcString 'report.actions.no-items')) + '</p>') }
    else {
        $rows = @()
        foreach ($i in $items) {
            $id = [string](Get-WcResultValue $i 'action')
            $rev = [string](Get-WcResultValue $i 'reversibility')
            $revText = '-'
            if ($rev) { $revText = Get-WcString ('reversibility.' + $rev) }
            $rows += [pscustomobject]@{
                Action = (Get-WcString ('action.' + $id)); Mode = (Get-WcResultValue $i 'mode'); Status = (Get-WcResultValue $i 'status')
                Reversibility = $revText; RestorePoint = (Get-WcRestorePointText (Get-WcResultValue $i 'restorePoint'))
                FreeDelta = (Format-WcBytesDelta (Get-WcResultValue $i 'freeBytesDelta')); Summary = (Get-WcResultValue $i 'summary'); Error = (Get-WcResultValue $i 'error')
            }
        }
        $cols = @('Action', 'Mode', 'Status', 'Reversibility', 'RestorePoint', 'FreeDelta', 'Summary', 'Error')
        [void]$sb.Append('<table><thead><tr>')
        foreach ($c in $cols) { [void]$sb.Append('<th>' + (ConvertTo-WcHtmlText (Get-WcString ('report.col.' + $c))) + '</th>') }
        [void]$sb.Append('</tr></thead><tbody>')
        foreach ($r in $rows) {
            [void]$sb.Append('<tr>')
            foreach ($c in $cols) { [void]$sb.Append('<td>' + (ConvertTo-WcHtmlText $r.$c) + '</td>') }
            [void]$sb.Append('</tr>')
        }
        [void]$sb.Append('</tbody></table>')

        [void]$sb.Append('<h2>' + (ConvertTo-WcHtmlText (Get-WcString 'report.actions.comparison')) + '</h2>')
        $any = $false
        foreach ($i in $items) {
            $cmp = @(Get-WcResultValue $i 'comparison' | Where-Object { $null -ne $_ })
            $errs = @(Get-WcResultValue $i 'measurementErrors' | Where-Object { $_ })
            if ($cmp.Count -eq 0 -and $errs.Count -eq 0) { continue }
            $any = $true
            [void]$sb.Append('<h3>' + (ConvertTo-WcHtmlText (Get-WcString ('action.' + [string](Get-WcResultValue $i 'action')))) + '</h3>')
            if ($cmp.Count -gt 0) {
                [void]$sb.Append('<table><thead><tr>')
                foreach ($c in 'Metric', 'Target', 'Before', 'After', 'Delta') { [void]$sb.Append('<th>' + (ConvertTo-WcHtmlText (Get-WcString ('report.col.' + $c))) + '</th>') }
                [void]$sb.Append('</tr></thead><tbody>')
                foreach ($x in $cmp) {
                    $unit = [string](Get-WcResultValue $x 'unit')
                    $cells = @(
                        (Get-WcString ('metric.' + [string](Get-WcResultValue $x 'name'))),
                        (Get-WcResultValue $x 'target'),
                        (Format-WcMetricValue (Get-WcResultValue $x 'before') $unit),
                        (Format-WcMetricValue (Get-WcResultValue $x 'after') $unit),
                        (Format-WcMetricValue (Get-WcResultValue $x 'delta') $unit -Delta)
                    )
                    [void]$sb.Append('<tr>')
                    foreach ($v in $cells) { [void]$sb.Append('<td>' + (ConvertTo-WcHtmlText $v) + '</td>') }
                    [void]$sb.Append('</tr>')
                }
                [void]$sb.Append('</tbody></table>')
            }
            foreach ($e in $errs) { [void]$sb.Append('<p class="muted">' + (ConvertTo-WcHtmlText ((Get-WcString 'report.actions.measure-error') + ' ' + [string]$e)) + '</p>') }
        }
        if (-not $any) { [void]$sb.Append('<p>' + (ConvertTo-WcHtmlText (Get-WcString 'report.actions.no-comparison')) + '</p>') }
        [void]$sb.Append('<p class="muted">' + (ConvertTo-WcHtmlText (Get-WcString 'report.actions.note-free-space')) + '</p>')
    }
    [void]$sb.Append('<p class="muted">' + (ConvertTo-WcHtmlText (Get-WcString 'report.footer')) + '</p></body></html>')
    return $sb.ToString()
}

function Export-WcActionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] $Report,
        [Parameter(Mandatory = $true)][string] $Path,
        [ValidateSet('Json', 'Html')][string] $Format = 'Json',
        [string] $Language = 'pt-BR'
    )
    $ext = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    $expected = '.json'
    if ($Format -eq 'Html') { $expected = '.html' }
    if ($ext -ne $expected -and -not ($Format -eq 'Html' -and $ext -eq '.htm')) { throw "Report path must end with $expected" }
    if ($Format -eq 'Json') { $content = ConvertTo-Json -InputObject $Report -Depth 8 }
    else { $content = ConvertTo-WcActionReportHtml -Report $Report -Language $Language }
    Write-WcTextFile -Path $Path -Content $content
    Write-WcLog -Level Audit -Category 'Report' -Message ("Action report exported ({0})." -f $Format) -Data @{ path = $Path } | Out-Null
    return (Get-Item -LiteralPath $Path)
}

Export-ModuleMember -Function @('ConvertTo-WcReportJson', 'ConvertTo-WcReportHtml', 'Format-WcBytes', 'Export-WcReport',
    'Format-WcBytesDelta', 'New-WcActionReport', 'ConvertTo-WcActionReportHtml', 'Export-WcActionReport')
