#Requires -Version 5.1
<#
    WinCare.Startup - startup entries and resource-heavy processes. Read-only.

    Processes: ranked by working set (RAM in use now). CPU is reported as the
    accumulated processor time since the process started - NOT a current
    percentage - and is labelled as such in the UI.
    Startup: Win32_StartupCommand (Run keys and Startup folders). Scheduled tasks
    and services are out of scope for this phase.
#>

function ConvertTo-WcProcessInfo {
    [CmdletBinding()]
    param(
        [object[]] $Process,
        [ValidateRange(1, 100)][int] $Top = 10
    )
    $rows = @()
    foreach ($p in @($Process)) {
        if ($null -eq $p) { continue }
        $ws = Get-WcObjectValue $p 'WorkingSet64'
        $cpu = Get-WcObjectValue $p 'TotalProcessorTime'
        $cpuSeconds = $null
        if ($cpu -is [timespan]) { $cpuSeconds = [math]::Round($cpu.TotalSeconds, 1) }
        elseif ($null -ne $cpu) { $cpuSeconds = [math]::Round([double]$cpu, 1) }
        $wsOut = 0; if ($ws) { $wsOut = [double]$ws }
        $rows += [pscustomobject]@{
            Name              = [string](Get-WcObjectValue $p 'ProcessName')
            Id                = Get-WcObjectValue $p 'Id'
            WorkingSetBytes   = $wsOut
            CpuSecondsTotal   = $cpuSeconds
            Company           = [string](Get-WcObjectValue $p 'Company')
        }
    }
    $sorted = @($rows | Sort-Object -Property WorkingSetBytes -Descending | Select-Object -First $Top)
    return $sorted
}

function Get-WcTopProcess {
    [CmdletBinding()]
    param([ValidateRange(1, 100)][int] $Top = 10)
    $procs = @()
    try { $procs = @(Get-Process -ErrorAction Stop) }
    catch { Write-WcLog -Level Warning -Category 'Processes' -Message $_.Exception.Message | Out-Null }
    # TotalProcessorTime/Company throw for protected processes when not elevated;
    # read them defensively.
    $safe = foreach ($p in $procs) {
        $cpu = $null; $company = $null
        try { $cpu = $p.TotalProcessorTime } catch { $cpu = $null }
        try { $company = $p.Company } catch { $company = $null }
        @{ ProcessName = $p.ProcessName; Id = $p.Id; WorkingSet64 = $p.WorkingSet64; TotalProcessorTime = $cpu; Company = $company }
    }
    return (ConvertTo-WcProcessInfo -Process $safe -Top $Top)
}

function ConvertTo-WcStartupItem {
    [CmdletBinding()]
    param([object[]] $StartupCommand)
    $rows = @()
    foreach ($s in @($StartupCommand)) {
        if ($null -eq $s) { continue }
        $rows += [pscustomobject]@{
            Name     = [string](Get-WcObjectValue $s 'Name')
            Command  = [string](Get-WcObjectValue $s 'Command')
            Location = [string](Get-WcObjectValue $s 'Location')
            User     = [string](Get-WcObjectValue $s 'User')
        }
    }
    return @($rows | Sort-Object -Property Name)
}

function Get-WcStartupItem {
    [CmdletBinding()]
    param()
    return (ConvertTo-WcStartupItem -StartupCommand (Get-WcCimData -ClassName 'Win32_StartupCommand'))
}

Export-ModuleMember -Function @('ConvertTo-WcProcessInfo', 'Get-WcTopProcess', 'ConvertTo-WcStartupItem', 'Get-WcStartupItem')
