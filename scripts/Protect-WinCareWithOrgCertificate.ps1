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
    3. Writes WinCare.FileHashes.ps1 (SHA-256 of ALL files: JSON catalog, XAML,
       localization) and signs it; Test-WcOrgFileHashes audits the folder.
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

$script:WcOrgHashFile = 'WinCare.FileHashes.ps1'

function Get-WcOrgFileHash {
    <# SHA-256 with retries: antivirus often holds freshly copied files for a moment. #>
    param([string] $Path)
    for ($i = 1; $i -le 10; $i++) {
        try {
            # FileShare ReadWrite+Delete: Get-FileHash (PS 5.1) opens with FileShare.Read and fails
            # when another process (e.g. antivirus) holds the file with write access.
            $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
            $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
            $sha = [System.Security.Cryptography.SHA256]::Create()
            try { return ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '') }
            finally { $sha.Dispose(); $fs.Dispose() }
        }
        catch {
            if ($i -eq 10) { throw }
            Start-Sleep -Milliseconds (300 * $i)
        }
    }
}

function Test-WcOrgFileHashes {
    <# Audit: signed hash list is Valid and every file matches (no missing/extra/modified). Returns problems. #>
    param([Parameter(Mandatory = $true)][string] $Root)
    $list = Join-Path $Root $script:WcOrgHashFile
    if (-not (Test-Path -LiteralPath $list)) { return @("$($script:WcOrgHashFile) not found.") }
    $sig = Get-AuthenticodeSignature -LiteralPath $list
    if ([string]$sig.Status -ne 'Valid') { return @("$($script:WcOrgHashFile) signature: $($sig.Status)") }
    $expected = Import-PowerShellDataFile -LiteralPath $list
    $problems = @()
    $seen = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Name -ne $script:WcOrgHashFile })) {
        $rel = $f.FullName.Substring($Root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        $seen[$rel] = $true
        if (-not $expected.ContainsKey($rel)) { $problems += "Extra file: $rel"; continue }
        if ((Get-WcOrgFileHash $f.FullName) -ne $expected[$rel]) { $problems += "Modified file: $rel" }
    }
    foreach ($k in $expected.Keys) { if (-not $seen.ContainsKey($k)) { $problems += "Missing file: $k" } }
    return $problems
}

function Protect-WcFolderWithCertificate {
    <# Signs scripts + a catalog of every file under $Root. Returns the list of problems (empty = OK). #>
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)] $Certificate,
        [string] $TimestampServer
    )
    $problems = @()
    $scripts = @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension.ToLowerInvariant() })
    foreach ($f in $scripts) {
        $p = @{ FilePath = $f.FullName; Certificate = $Certificate; HashAlgorithm = 'SHA256' }
        if ($TimestampServer) { $p.TimestampServer = $TimestampServer }
        $r = Set-AuthenticodeSignature @p
        if ([string]$r.Status -ne 'Valid') { $problems += ('{0}: {1} {2}' -f $f.FullName, $r.Status, $r.StatusMessage) }
    }
    # Hash list of EVERY file (JSON catalog, XAML, localization), stored as a signed
    # .ps1 data file: Authenticode protects it and it loads even under AllSigned.
    # (New-FileCatalog was the first choice but fails on Windows PowerShell 5.1.)
    $list = Join-Path $Root $script:WcOrgHashFile
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# WinCare file hashes (SHA-256), signed by the organization. Data only.')
    $lines.Add('@{')
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { $_.Name -ne $script:WcOrgHashFile } | Sort-Object FullName)) {
        $rel = $f.FullName.Substring($Root.TrimEnd('\', '/').Length + 1).Replace('\', '/')
        if ($rel -notmatch '^[A-Za-z0-9._/ -]+$') { $problems += "Unexpected characters in file name: $rel"; continue }
        $lines.Add(("    '{0}' = '{1}'" -f $rel, (Get-WcOrgFileHash $f.FullName)))
    }
    $lines.Add('}')
    [System.IO.File]::WriteAllText($list, (($lines -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    $p = @{ FilePath = $list; Certificate = $Certificate; HashAlgorithm = 'SHA256' }
    if ($TimestampServer) { $p.TimestampServer = $TimestampServer }
    $r = Set-AuthenticodeSignature @p
    if ([string]$r.Status -ne 'Valid') { $problems += ('{0}: {1} {2}' -f $script:WcOrgHashFile, $r.Status, $r.StatusMessage) }
    $problems += @(Test-WcOrgFileHashes -Root $Root)
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
Write-Host "Signed $($res.ScriptCount) scripts + WinCare.FileHashes.ps1 with $($cert.Subject) ($($cert.Thumbprint))."
Write-Host "Output: $OutputDirectory"
