#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a SIGNED release (WINDOWS ONLY): signs every script, creates and signs
    WinCare.cat, verifies the result with the bootstrapper's own checks, zips it
    and writes the release manifest.

.DESCRIPTION
    NOT VALIDATED YET - phase F6. Requires a code-signing certificate in
    Cert:\CurrentUser\My. Publishing to GitHub Releases is a separate, manual step
    that needs explicit authorization.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Fa-f0-9]{40}$')][string] $CertificateThumbprint,
    [string] $TimestampServer,
    [string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) { throw 'Signing requires Windows.' }
$repo = Split-Path -Parent $PSScriptRoot
$version = (Import-PowerShellDataFile (Join-Path $repo 'src\WinCare.psd1')).ModuleVersion
$cert = Get-Item -LiteralPath ("Cert:\CurrentUser\My\{0}" -f $CertificateThumbprint)
if (-not $cert.HasPrivateKey) { throw 'Certificate has no private key.' }

$stage = Join-Path $OutputDirectory "release-stage\WinCare-$version"
if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage -Force | Out-Null
foreach ($item in 'src', 'README.md', 'SECURITY.md', 'LICENSE') { Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $stage -Recurse }

$sigParams = @{ Certificate = $cert; HashAlgorithm = 'SHA256' }
if ($TimestampServer) { $sigParams['TimestampServer'] = $TimestampServer }
foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1') {
    $r = Set-AuthenticodeSignature -FilePath $f.FullName @sigParams
    if ($r.Status -ne 'Valid') { throw "Signing failed for $($f.FullName): $($r.StatusMessage)" }
}
$cat = Join-Path $stage 'WinCare.cat'
New-FileCatalog -Path $stage -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
$r = Set-AuthenticodeSignature -FilePath $cat @sigParams
if ($r.Status -ne 'Valid') { throw "Catalog signing failed: $($r.StatusMessage)" }

. (Join-Path $repo 'bootstrap\Install-WinCare.ps1')
$check = Test-WcbPackage -Root $stage -TrustedThumbprints @($CertificateThumbprint)
if (-not $check.Valid) { throw ('Self-verification failed: ' + ($check.Errors -join '; ')) }

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = Join-Path $OutputDirectory "WinCare-$version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
$manifest = [ordered]@{ version = $version; kind = 'release-signed'; signer = $CertificateThumbprint.ToUpperInvariant(); created = (Get-Date).ToUniversalTime().ToString('o'); files = @([ordered]@{ name = "WinCare-$version.zip"; sha256 = $hash; size = (Get-Item -LiteralPath $zip).Length }) }
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputDirectory "WinCare-$version.manifest.json") -Encoding UTF8
Write-Host "Release: $zip"
Write-Host "SHA256:  $hash"
Write-Host 'Next: add the thumbprint to bootstrap\Install-WinCare.ps1, set the official URL, sign the bootstrapper. Publishing needs explicit authorization.'
