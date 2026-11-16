#Requires -Version 5.1
<#
.SYNOPSIS
    Windows validation kit for WinCare Enterprise. Produces the evidence needed to
    mark a feature as "validated" on a given Windows edition/build.

.DESCRIPTION
    Read-only for the system under test. Steps:
      1. Records the environment (edition, build, PS, .NET, culture, admin, policy).
      2. Verifies the kit files against SHA256SUMS.txt.
      3. Runs the full Pester suite including the 'Windows' integration tests.
      4. Runs the headless diagnostic and exports JSON + HTML.
      5. -Interactive: opens the GUI and walks the technician through a checklist.
    Results: validation-results/<COMPUTER>-<timestamp>/ (report JSON + Markdown).

.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\tests\Windows\Invoke-WinCareValidation.ps1 -Interactive
    (Lab/VM only, after checking the kit SHA-256 and running Unblock-File. See docs/VALIDACAO-WINDOWS.md.)
#>
[CmdletBinding()]
param(
    [switch] $Interactive,
    [string] $Tester = $env:USERNAME
)
$ErrorActionPreference = 'Stop'
$kit = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$out = Join-Path $kit ("validation-results\{0}-{1}" -f $env:COMPUTERNAME, $stamp)
New-Item -ItemType Directory -Path $out -Force | Out-Null
$checks = New-Object System.Collections.ArrayList

function Add-Check {
    param([string] $Id, [string] $Title, [ValidateSet('PASS', 'FAIL', 'SKIP')][string] $Result, [string] $Detail = '')
    [void]$checks.Add([pscustomobject]@{ Id = $Id; Title = $Title; Result = $Result; Detail = $Detail })
    $color = @{ PASS = 'Green'; FAIL = 'Red'; SKIP = 'Yellow' }[$Result]
    Write-Host ('[{0}] {1} {2}' -f $Result, $Title, $Detail) -ForegroundColor $color
}

# 1. Environment -------------------------------------------------------------
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$os = Get-CimInstance Win32_OperatingSystem
$net = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$envInfo = [ordered]@{
    Computer       = $env:COMPUTERNAME
    Caption        = $os.Caption
    EditionID      = $cv.EditionID
    DisplayVersion = $cv.DisplayVersion
    Build          = '{0}.{1}' -f $cv.CurrentBuildNumber, $cv.UBR
    Architecture   = $os.OSArchitecture
    PowerShell     = $PSVersionTable.PSVersion.ToString()
    PSEdition      = $PSVersionTable.PSEdition
    NetFxRelease   = $net
    Culture        = (Get-Culture).Name
    UICulture      = (Get-UICulture).Name
    IsAdmin        = $isAdmin
    Apartment      = [System.Threading.Thread]::CurrentThread.GetApartmentState().ToString()
    ExecutionPolicy = (Get-ExecutionPolicy -List | ForEach-Object { '{0}={1}' -f $_.Scope, $_.ExecutionPolicy }) -join '; '
    IsVirtualMachine = ((Get-CimInstance Win32_ComputerSystem).Model -match 'Virtual|VMware|KVM|HVM|VirtualBox')
    Tester         = $Tester
    Date           = (Get-Date).ToString('o')
}
$envInfo.GetEnumerator() | ForEach-Object { Write-Host ('{0,-16} {1}' -f $_.Key, $_.Value) }
if ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -eq 1) { Add-Check 'env.ps51' 'Windows PowerShell 5.1' 'PASS' } else { Add-Check 'env.ps51' 'Windows PowerShell 5.1' 'FAIL' ('running ' + $PSVersionTable.PSVersion) }

# 2. Kit integrity -----------------------------------------------------------
$sums = Join-Path $kit 'SHA256SUMS.txt'
if (Test-Path -LiteralPath $sums) {
    $bad = @()
    foreach ($line in Get-Content -LiteralPath $sums) {
        if ($line -notmatch '^([A-Fa-f0-9]{64})\s+\*?(.+)$') { continue }
        $p = Join-Path $kit ($Matches[2] -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p) -or (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $Matches[1].ToUpperInvariant()) { $bad += $Matches[2] }
    }
    if ($bad.Count -eq 0) { Add-Check 'kit.sha256' 'Kit files match SHA256SUMS.txt' 'PASS' } else { Add-Check 'kit.sha256' 'Kit files match SHA256SUMS.txt' 'FAIL' ($bad -join ', ') }
}
else { Add-Check 'kit.sha256' 'Kit files match SHA256SUMS.txt' 'SKIP' 'SHA256SUMS.txt not found (running from a clone?)' }

# 3. Pester ------------------------------------------------------------------
try {
    & (Join-Path $kit 'scripts\Invoke-WinCareTests.ps1') -OutputDirectory $out
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) { Add-Check 'pester' 'Pester suite (incl. Windows integration)' 'FAIL' 'see pester-results.xml' }
    else { Add-Check 'pester' 'Pester suite (incl. Windows integration)' 'PASS' }
}
catch { Add-Check 'pester' 'Pester suite (incl. Windows integration)' 'FAIL' $_.Exception.Message }

# 4. Headless diagnostic -----------------------------------------------------
try {
    $env:WINCARE_DATA_ROOT = Join-Path $out 'data'
    $start = Join-Path $kit 'src\Start-WinCare.ps1'
    & $start -NoGui -OutputPath (Join-Path $out 'diagnostic.json') | Out-Null
    & $start -NoGui -OutputPath (Join-Path $out 'diagnostic.html') | Out-Null
    $diag = Get-Content -Raw (Join-Path $out 'diagnostic.json') | ConvertFrom-Json
    if (@($diag.Errors).Count -eq 0) { Add-Check 'diag.headless' 'Headless diagnostic, no section errors' 'PASS' }
    else { Add-Check 'diag.headless' 'Headless diagnostic, no section errors' 'FAIL' (($diag.Errors | ForEach-Object { $_.Section + ': ' + $_.Error }) -join '; ') }
}
catch { Add-Check 'diag.headless' 'Headless diagnostic' 'FAIL' $_.Exception.Message }
finally { Remove-Item Env:\WINCARE_DATA_ROOT -ErrorAction SilentlyContinue }

# 5. Interactive GUI checklist -----------------------------------------------
$guiItems = @(
    @{ Id = 'gui.open'; Q = 'A janela abriu sem erro (tema escuro)?' }
    @{ Id = 'gui.responsive'; Q = 'Durante o diagnostico automatico a janela continuou responsiva (mover, rolar, navegar)?' }
    @{ Id = 'gui.dashboard'; Q = 'Visao geral mostra Windows/edicao/build, CPU, RAM, disco, tempo ligado e reinicializacao com valores coerentes com o Gerenciador de Tarefas?' }
    @{ Id = 'gui.nav'; Q = 'As 11 paginas abrem pelo menu lateral (mouse e teclado)?' }
    @{ Id = 'gui.grids'; Q = 'Tabelas de Diagnostico, Armazenamento, Processos e Seguranca preenchidas com cabecalhos traduzidos?' }
    @{ Id = 'gui.cancel'; Q = 'Atualizar diagnostico + Cancelar: o cancelamento aparece no console sem travar?' }
    @{ Id = 'gui.theme'; Q = 'Configuracoes > Tema claro/escuro troca na hora e o texto continua legivel?' }
    @{ Id = 'gui.lang'; Q = 'Configuracoes > Idioma troca pt-BR/en-US na hora?' }
    @{ Id = 'gui.export'; Q = 'Historico e relatorios: exportar JSON e HTML funciona e o HTML abre no navegador?' }
    @{ Id = 'gui.console'; Q = 'O console de logs (rodape) mostra as etapas do diagnostico?' }
    @{ Id = 'gui.icons'; Q = 'Os icones do menu aparecem (nao quadrados vazios)?' }
    @{ Id = 'gui.dpi'; Q = 'Layout correto com escala 100% e 150% (ou a escala da maquina)?' }
)
if ($Interactive) {
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $env:WINCARE_DATA_ROOT = Join-Path $out 'gui-data'
    $proc = Start-Process -FilePath $ps51 -ArgumentList @('-NoProfile', '-STA', '-File', ('"{0}"' -f (Join-Path $kit 'src\Start-WinCare.ps1'))) -PassThru
    Remove-Item Env:\WINCARE_DATA_ROOT -ErrorAction SilentlyContinue
    Write-Host 'Interface aberta. Responda s (sim), n (nao) ou p (pular).' -ForegroundColor Cyan
    foreach ($i in $guiItems) {
        $a = ''
        while ($a -notin @('s', 'n', 'p')) { $a = (Read-Host $i.Q).Trim().ToLowerInvariant() }
        $note = ''
        if ($a -eq 'n') { $note = Read-Host 'Descreva o problema' }
        $res = @{ s = 'PASS'; n = 'FAIL'; p = 'SKIP' }[$a]
        Add-Check $i.Id $i.Q $res $note
    }
    if ($proc -and -not $proc.HasExited) { Write-Host 'Feche a janela do WinCare quando terminar.' }
}
else {
    foreach ($i in $guiItems) { Add-Check $i.Id $i.Q 'SKIP' 'run with -Interactive' }
}

# Report ---------------------------------------------------------------------
$report = [ordered]@{ Environment = $envInfo; Checks = $checks; Version = (Import-PowerShellDataFile (Join-Path $kit 'src\WinCare.psd1')).ModuleVersion }
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $out 'validation-report.json') -Encoding UTF8
$md = New-Object System.Text.StringBuilder
[void]$md.AppendLine(('# WinCare {0} - validation {1}' -f $report.Version, $env:COMPUTERNAME))
[void]$md.AppendLine('')
foreach ($k in $envInfo.Keys) { [void]$md.AppendLine(('- **{0}**: {1}' -f $k, $envInfo[$k])) }
[void]$md.AppendLine('')
[void]$md.AppendLine('| Result | Check | Detail |')
[void]$md.AppendLine('|---|---|---|')
foreach ($c in $checks) { [void]$md.AppendLine(('| {0} | {1} | {2} |' -f $c.Result, $c.Title, ($c.Detail -replace '\|', '/'))) }
Set-Content -LiteralPath (Join-Path $out 'validation-report.md') -Value $md.ToString() -Encoding UTF8
$fail = @($checks | Where-Object Result -eq 'FAIL').Count
Write-Host ''
Write-Host ('Results: {0}  (FAIL={1})' -f $out, $fail)
if ($fail -gt 0) { exit 1 }
