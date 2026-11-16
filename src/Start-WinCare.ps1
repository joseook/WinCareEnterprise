#Requires -Version 5.1
<#
.SYNOPSIS
    Starts WinCare Enterprise (WPF interface) or runs a headless read-only diagnostic.

.DESCRIPTION
    Opening WinCare never changes the system. The GUI requires Windows with WPF and
    an STA thread; if the current host is not STA (e.g. pwsh), the script relaunches
    itself in Windows PowerShell 5.1 with -STA. It never changes the execution policy.

.PARAMETER NoGui
    Runs the diagnostic without the interface, prints a summary and (optionally)
    writes a report. Useful for remote sessions and the Windows validation kit.

.PARAMETER OutputPath
    Report path for -NoGui (.json or .html).

.PARAMETER Language
    pt-BR or en-US. Overrides the saved setting for this run.

.PARAMETER PassThru
    -NoGui only: also return the snapshot object.

.PARAMETER NoAutoDiagnostic
    GUI only: do not start the diagnostic automatically when the window opens.

.EXAMPLE
    powershell.exe -NoProfile -STA -File .\Start-WinCare.ps1
.EXAMPLE
    powershell.exe -NoProfile -File .\Start-WinCare.ps1 -NoGui -OutputPath .\diag.json
#>
[CmdletBinding()]
param(
    [switch] $NoGui,
    [string] $OutputPath,
    [ValidateSet('pt-BR', 'en-US')][string] $Language,
    [switch] $NoAutoDiagnostic,
    [switch] $PassThru
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$appRoot = $PSScriptRoot

# AppLocker/WDAC put unapproved scripts in Constrained Language Mode, where WPF and
# CIM helpers cannot load. Explain it instead of failing deep inside a module; the
# control is never bypassed (IT must allow the WinCare publisher/package).
if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Error ("WinCare: PowerShell is in {0} (AppLocker/WDAC). Ask IT to allow the signed WinCare package - see docs/CORPORATIVO.md. / PowerShell em {0} (AppLocker/WDAC): peca a TI para liberar o pacote assinado do WinCare - veja docs/CORPORATIVO.md." -f $ExecutionContext.SessionState.LanguageMode)
    exit 3
}

Import-Module (Join-Path $appRoot 'WinCare.psd1') -Force -DisableNameChecking
$version = (Import-PowerShellDataFile -Path (Join-Path $appRoot 'WinCare.psd1')).ModuleVersion
$logPath = Initialize-WcLog
$settings = Read-WcSettings
if ($Language) { $settings.Language = $Language }
Import-WcLocalization -Root (Join-Path $appRoot 'Localization') -Language $settings.Language | Out-Null
Write-WcLog -Category 'Startup' -Message ("WinCare {0} starting. PS {1} {2}. GUI={3}." -f $version, $PSVersionTable.PSVersion, $PSVersionTable['PSEdition'], (-not $NoGui)) | Out-Null

if ($NoGui) {
    Write-Host (Get-WcString 'cli.running')
    $snapshot = Invoke-WcDiagnostic -CatalogPath (Join-Path $appRoot 'Core/actions.json') -AppVersion $version -OperationProfileName $settings.Profile
    foreach ($f in @($snapshot.Findings)) {
        if ($null -eq $f) { continue }
        Write-Host ('[{0}] {1}' -f (Get-WcString ('severity.' + $f.Severity)), (Get-WcString -Key $f.TitleKey -Arguments $f.Evidence))
    }
    Write-Host (Get-WcString 'cli.findings' -Arguments @(@($snapshot.Findings).Count))
    Write-Host (Get-WcString 'cli.errors' -Arguments @(@($snapshot.Errors).Count))
    if ($OutputPath) {
        $format = 'Json'
        if ($OutputPath -match '\.html?$') { $format = 'Html' }
        $file = Export-WcReport -Snapshot $snapshot -Path $OutputPath -Format $format -Language $settings.Language
        Write-Host (Get-WcString 'cli.saved' -Arguments @($file.FullName))
    }
    if ($PassThru) { return $snapshot }
    return
}

if (-not (Test-WcIsWindows)) { throw 'The WinCare interface requires Windows (WPF). Use -NoGui elsewhere.' }

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    # WPF needs STA. Relaunch in Windows PowerShell 5.1 (the supported host) without
    # touching the execution policy.
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = @('-NoProfile', '-STA', '-File', ('"{0}"' -f $PSCommandPath))
    if ($Language) { $argList += @('-Language', $Language) }
    if ($NoAutoDiagnostic) { $argList += '-NoAutoDiagnostic' }
    Write-WcLog -Category 'Startup' -Message 'Host is not STA; relaunching in Windows PowerShell 5.1 -STA.' | Out-Null
    Start-Process -FilePath $ps51 -ArgumentList $argList | Out-Null
    return
}

Import-Module (Join-Path $appRoot 'UI\WinCare.UI.psm1') -Force -DisableNameChecking
Show-WcMainWindow -AppRoot $appRoot -Version $version -Settings $settings -NoAutoDiagnostic:$NoAutoDiagnostic
