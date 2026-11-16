#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Pester 5 suite. On non-Windows hosts the 'Windows' tag is excluded
    automatically (those tests need real CIM, Authenticode and WPF).
.PARAMETER Tag
    Run only these tags (e.g. Windows).
.PARAMETER OutputDirectory
    Where NUnit XML results are written. Default: ./TestResults
#>
[CmdletBinding()]
param(
    [string[]] $Tag,
    [string] $OutputDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestResults')
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' -and $_.Version -lt [version]'6.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    # Offline validation kit ships Pester 5 under tools/Pester.
    $bundled = Get-ChildItem -Path (Join-Path $repo 'tools/Pester') -Recurse -Filter 'Pester.psd1' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bundled) { throw 'Pester 5.x not found. Install it (Install-Module Pester -RequiredVersion 5.9.1 -Scope CurrentUser) or use the validation kit.' }
    $pester = $bundled.FullName
}
Import-Module $pester -Force

$isWin = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
$cfg = New-PesterConfiguration
$cfg.Run.Path = (Join-Path $repo 'tests')
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
if ($Tag) { $cfg.Filter.Tag = $Tag }
if (-not $isWin) { $cfg.Filter.ExcludeTag = @('Windows') }
if (-not (Test-Path -LiteralPath $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputFormat = 'NUnitXml'
$cfg.TestResult.OutputPath = (Join-Path $OutputDirectory 'pester-results.xml')

$result = Invoke-Pester -Configuration $cfg
Write-Host ('Host: {0} {1} | Windows={2} | Passed={3} Failed={4} Skipped={5} NotRun={6}' -f $PSVersionTable.PSVersion, $PSVersionTable['PSEdition'], $isWin, $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.NotRunCount)
if ($result.FailedCount -gt 0) { exit 1 }
