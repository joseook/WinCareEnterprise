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

Export-ModuleMember -Function @('ConvertTo-WcReportJson', 'ConvertTo-WcReportHtml', 'Format-WcBytes', 'Export-WcReport')
