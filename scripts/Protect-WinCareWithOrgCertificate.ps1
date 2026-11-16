#Requires -Version 5.1
<#
.SYNOPSIS
    For IT: verifies an official WinCare release and re-signs it with the
    ORGANIZATION's code-signing certificate, for machines where Group Policy
    requires AllSigned or AppLocker/WDAC allows only trusted publishers.

.DESCRIPTION
    1. Verifies the release exactly like install.ps1 (RSA-signed manifest with the
       pinned key, zip hash, every file hash, no extra files). Nothing is signed if
       this fails.
    2. Copies the verified files to -OutputDirectory and signs every .ps1/.psm1/.psd1
       with the given certificate (SHA-256, optional RFC 3161 timestamp).
    3. Creates WinCare.cat (New-FileCatalog) covering ALL files (JSON catalog,
       XAML, localization) and signs it, so Test-FileCatalog can audit them.
    4. Checks every signature is Valid on this machine and writes
       WINCARE-ORG-SIGNED.json (source manifest hash, signer, date).
    Deploy the output folder to an admin-only location (e.g. Program Files) with
    your tooling (Intune, ConfigMgr, GPO) and start src\Start-WinCare.ps1.
    The certificate's chain must be trusted by the targets (Trusted Publishers +
    root). Re-signed files no longer match the RSA manifest by design: from here
    on the Authenticode signature of your organization is the integrity control.

.EXAMPLE
    .\Protect-WinCareWithOrgCertificate.ps1 -ReleaseDirectory .\v0.3.0 -CertificateThumbprint 0123...ABCD -OutputDirectory D:\deploy\WinCare-0.3.0 -TimestampServer http://timestamp.example.org
#>
# Parameters are validated in the body (not Mandatory) so tests can dot-source the functions.
[CmdletBinding()]
param(
    [string] $ReleaseDirectory,
    [string] $CertificateThumbprint,
    [string] $OutputDirectory,
    [string] $TimestampServer,
    [string] $BootstrapPath
)
$ErrorActionPreference = 'Stop'

function Get-WcOrgCertificate {
    param([string] $Thumbprint)
    $tp = ($Thumbprint -replace '\s', '').ToUpperInvariant()
    if ($tp -notmatch '^[A-F0-9]{40}$') { throw 'CertificateThumbprint must be 40 hex characters.' }
    foreach ($store in 'Cert:\CurrentUser\My', 'Cert:\LocalMachine\My') {
        $c = Get-ChildItem -Path $store -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $tp } | Select-Object -First 1
        if ($c) {
            # EKU 1.3.6.1.5.5.7.3.3 = code signing.
            $eku = @($c.EnhancedKeyUsageList | ForEach-Object { $_.ObjectId })
            if ($eku -notcontains '1.3.6.1.5.5.7.3.3') { throw "Certificate $tp is not a code-signing certificate." }
            if (-not $c.HasPrivateKey) { throw "Certificate $tp has no private key on this machine." }
            return $c
        }
    }
    throw "Code-signing certificate $tp not found in CurrentUser\My or LocalMachine\My."
}

function Protect-WcFolderWithCertificate {
    <# Signs scripts + a catalog of every file under $Root. Returns the list of problems (empty = OK). #>
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)] $Certificate,
        [string] $TimestampServer
    )
    $problems = @()
    $scripts = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')
    foreach ($f in $scripts) {
        $p = @{ FilePath = $f.FullName; Certificate = $Certificate; HashAlgorithm = 'SHA256' }
        if ($TimestampServer) { $p.TimestampServer = $TimestampServer }
        $r = Set-AuthenticodeSignature @p
        if ([string]$r.Status -ne 'Valid') { $problems += ('{0}: {1} {2}' -f $f.FullName, $r.Status, $r.StatusMessage) }
    }
    $cat = Join-Path $Root 'WinCare.cat'
    if (Test-Path -LiteralPath $cat) { Remove-Item -LiteralPath $cat -Force }
    New-FileCatalog -Path $Root -CatalogFilePath $cat -CatalogVersion 2.0 | Out-Null
    $p = @{ FilePath = $cat; Certificate = $Certificate; HashAlgorithm = 'SHA256' }
    if ($TimestampServer) { $p.TimestampServer = $TimestampServer }
    $r = Set-AuthenticodeSignature @p
    if ([string]$r.Status -ne 'Valid') { $problems += ('WinCare.cat: {0} {1}' -f $r.Status, $r.StatusMessage) }
    $check = Test-FileCatalog -CatalogFilePath $cat -Path $Root -FilesToSkip 'WinCare.cat'
    if ([string]$check -ne 'Valid') { $problems += "Test-FileCatalog: $check" }
    return [pscustomobject]@{ Problems = $problems; ScriptCount = $scripts.Count }
}

# Dot-sourcing (tests) only loads the functions.
if ($MyInvocation.InvocationName -eq '.') { return }
foreach ($req in 'ReleaseDirectory', 'CertificateThumbprint', 'OutputDirectory') {
    if (-not (Get-Variable -Name $req -ValueOnly)) { throw "-$req is required." }
}

if (-not $BootstrapPath) {
    $candidate = Join-Path $ReleaseDirectory 'install.ps1'
    if (Test-Path -LiteralPath $candidate) { $BootstrapPath = $candidate }
    else { $BootstrapPath = Join-Path (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)) 'bootstrap\Install-WinCare.ps1' }
}
. $BootstrapPath

$manifest = @(Get-ChildItem -LiteralPath $ReleaseDirectory -Filter 'WinCare-*.manifest.json')
if ($manifest.Count -ne 1) { throw 'Expected exactly one WinCare-<version>.manifest.json in ReleaseDirectory.' }
$manPath = $manifest[0].FullName
$sigErr = Test-WcbManifestSignature -ManifestPath $manPath -SignaturePath ($manPath + '.sig')
if ($sigErr) { throw "Release signature check failed: $sigErr" }
$m = Read-WcbManifest $manPath
$zip = Join-Path $ReleaseDirectory ([string]$m.package.name)
if ((Get-WcbSha256 $zip) -ne ([string]$m.package.sha256).ToUpperInvariant()) { throw 'Zip SHA-256 differs from the signed manifest.' }
if (Test-Path -LiteralPath $OutputDirectory) { throw "OutputDirectory already exists: $OutputDirectory" }
Expand-WcbZipSafe -ZipPath $zip -Destination $OutputDirectory
Copy-Item -LiteralPath $manPath -Destination (Join-Path $OutputDirectory '.wincare-manifest.json')
Copy-Item -LiteralPath ($manPath + '.sig') -Destination (Join-Path $OutputDirectory '.wincare-manifest.json.sig')
$check = Test-WcbPackage -Root $OutputDirectory -ManifestPath (Join-Path $OutputDirectory '.wincare-manifest.json') -TrustedThumbprints @()
if (-not $check.Valid) {
    Remove-Item -LiteralPath $OutputDirectory -Recurse -Force
    throw ('Release verification failed: ' + ($check.Errors -join '; '))
}
Write-Host "Release $($m.version) verified (RSA manifest + every file)."

$cert = Get-WcOrgCertificate -Thumbprint $CertificateThumbprint
$res = Protect-WcFolderWithCertificate -Root $OutputDirectory -Certificate $cert -TimestampServer $TimestampServer
$record = [ordered]@{
    version              = [string]$m.version
    sourceManifestSha256 = (Get-WcbSha256 $manPath)
    sourcePackageSha256  = ([string]$m.package.sha256).ToUpperInvariant()
    signerThumbprint     = $cert.Thumbprint
    signerSubject        = $cert.Subject
    signedScripts        = $res.ScriptCount
    timestamped          = [bool]$TimestampServer
    signedAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
    problems             = @($res.Problems)
}
[System.IO.File]::WriteAllText((Join-Path $OutputDirectory 'WINCARE-ORG-SIGNED.json'), (ConvertTo-Json -InputObject $record -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
if ($res.Problems.Count -gt 0) {
    $res.Problems | ForEach-Object { Write-Warning $_ }
    throw 'Some signatures are not Valid on this machine (is the certificate chain trusted?). See WINCARE-ORG-SIGNED.json.'
}
Write-Host "Signed $($res.ScriptCount) scripts + WinCare.cat with $($cert.Subject) ($($cert.Thumbprint))."
Write-Host "Output: $OutputDirectory"
