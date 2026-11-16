#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the UNSIGNED portable validation kit: dist/WinCare-Validation-<version>.zip
    plus .sha256 and a manifest. Runs on Linux (pwsh) or Windows.

.DESCRIPTION
    The kit is for lab/VM validation only. It contains the app, tests, the Windows
    validation script and (optionally) Pester 5 for offline machines.
    It is NOT a release: it is not Authenticode-signed and the bootstrapper rejects it.
#>
[CmdletBinding()]
param(
    [string] $OutputDirectory,
    [switch] $NoPester
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
$repo = Split-Path -Parent $PSScriptRoot
$version = (Import-PowerShellDataFile (Join-Path $repo 'src/WinCare.psd1')).ModuleVersion
$name = "WinCare-Validation-$version"
$stage = Join-Path $OutputDirectory "stage/$name"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null

foreach ($item in 'src', 'bootstrap', 'tests', 'scripts', 'docs', 'README.md', 'SECURITY.md', 'CONTRIBUTING.md', 'LICENSE') {
    $p = Join-Path $repo $item
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $stage -Recurse -Force }
}

if (-not $NoPester) {
    $pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.0.0' -and $_.Version -lt [version]'6.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
    if ($pester) {
        $dest = Join-Path $stage ("tools/Pester/{0}" -f $pester.Version)
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        Copy-Item -Path (Join-Path $pester.ModuleBase '*') -Destination $dest -Recurse -Force
        Set-Content -LiteralPath (Join-Path $stage 'tools/Pester/SOURCE.txt') -Value ("Pester {0} (Apache-2.0), copied from the build machine's module path for offline test runs. https://github.com/pester/Pester" -f $pester.Version)
        Write-Host "Bundled Pester $($pester.Version)"
    }
    else { Write-Warning 'Pester 5.x not found; the kit will need Pester installed on the Windows machine.' }
}

# SHA256SUMS of every file in the kit (forward slashes, relative paths).
$lines = foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName) {
    $rel = $f.FullName.Substring($stage.Length + 1).Replace('\', '/')
    '{0}  {1}' -f (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash, $rel
}
[System.IO.File]::WriteAllText((Join-Path $stage 'SHA256SUMS.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = Join-Path $OutputDirectory "$name.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $true)
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
[System.IO.File]::WriteAllText("$zip.sha256", ("{0}  {1}.zip`n" -f $hash, $name), (New-Object System.Text.UTF8Encoding($false)))
$manifest = [ordered]@{ version = $version; kind = 'validation-unsigned'; created = (Get-Date).ToUniversalTime().ToString('o'); files = @([ordered]@{ name = "$name.zip"; sha256 = $hash; size = (Get-Item -LiteralPath $zip).Length }) }
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory "$name.manifest.json"), ($manifest | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
Remove-Item -LiteralPath (Join-Path $OutputDirectory 'stage') -Recurse -Force
Write-Host "Kit:    $zip"
Write-Host "SHA256: $hash"
