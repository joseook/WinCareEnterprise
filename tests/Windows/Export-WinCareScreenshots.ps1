#Requires -Version 5.1
<#
.SYNOPSIS
    Renders every WinCare page to PNG (dark + light, pt-BR + en-US) using a real
    diagnostic of this machine. Windows only; needs an STA host (powershell.exe -STA).
#>
[CmdletBinding()]
param([string] $OutputDirectory)
$ErrorActionPreference = 'Stop'
# $PSScriptRoot is empty inside param() defaults on Windows PowerShell 5.1 -File runs.
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path))
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repo 'TestResults\screenshots' }
$src = Join-Path $repo 'src'
Import-Module (Join-Path $src 'WinCare.psd1') -Force -DisableNameChecking
Import-Module (Join-Path $src 'UI\WinCare.UI.psm1') -Force -DisableNameChecking
$version = (Import-PowerShellDataFile (Join-Path $src 'WinCare.psd1')).ModuleVersion
Initialize-WcLog | Out-Null
Import-WcLocalization -Root (Join-Path $src 'Localization') -Language 'pt-BR' | Out-Null
$snap = Invoke-WcDiagnostic -CatalogPath (Join-Path $src 'Core\actions.json') -AppVersion $version
foreach ($lang in 'pt-BR', 'en-US') {
    $files = Export-WcUiSnapshot -AppRoot $src -Version $version -OutputDirectory $OutputDirectory -Snapshot $snap -Language $lang -Theme @('Dark', 'Light')
    Write-Host ("{0}: {1} screenshots" -f $lang, @($files).Count)
}
