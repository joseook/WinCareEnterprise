#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies and starts a WinCare Enterprise release. One command, no installer,
    no "irm | iex", no execution-policy bypass.

.DESCRIPTION
    Trust model (fail closed - any check that cannot be completed stops the run):
      1. Trust anchors are constants in THIS file: the official release URL and the
         pinned RSA public key(s) of the release signer (optionally also pinned
         Authenticode thumbprints). This file is obtained by a command that pins
         its SHA-256 (see docs/EXECUCAO.md).
      2. The release manifest lists the SHA-256 of the zip and of every file in it.
         Its detached signature (RSA-3072, PKCS#1 v1.5, SHA-256) must verify with a
         pinned key BEFORE anything else is trusted.
      3. The zip hash must match the signed manifest (and -ExpectedSha256, if given).
      4. The zip is expanded with path-traversal checks; the file set must match
         the manifest exactly (no missing, modified or extra files).
      5. If Authenticode thumbprints are pinned, every script and WinCare.cat must
         also carry a Valid signature from them (extra layer for signed builds).
      6. The verified package goes to a versioned cache and is re-verified on every
         start. WinCare is started with process-scope RemoteSigned, which never
         overrides Group Policy (MachinePolicy/UserPolicy win).

.PARAMETER Version
    Release to start (x.y.z). Defaults to the release this file was published with.
.PARAMETER PackagePath
    Offline mode: local WinCare-<version>.zip.
.PARAMETER ManifestPath
    Offline mode: local WinCare-<version>.manifest.json (its .sig must sit next to it).
.PARAMETER ExpectedSha256
    SHA-256 of the zip obtained out of band.
.PARAMETER VerifyOnly
    Verify and cache, but do not start the interface.
#>
[CmdletBinding()]
param(
    [string] $Version,
    [string] $PackagePath,
    [string] $ManifestPath,
    [string] $ExpectedSha256,
    [string] $CacheRoot,
    [switch] $VerifyOnly
)

Set-StrictMode -Version 2.0

# ----------------------------------------------------------- trust anchors --
$script:WcbDefaultVersion = '0.2.0'
$script:WcbReleaseBaseUri = 'https://github.com/joseook/WinCareEnterprise/releases/download'
$script:WcbAllowedHosts = @('github.com')
# Pinned release-signing public keys (RSA, base64 big-endian modulus/exponent).
# Empty = nothing is trusted = every package is rejected.
$script:WcbTrustedKeys = @(
    @{ Id = 'wincare-release-2026-9a1d48ccd780'; Exponent = 'AQAB'
        Modulus = 'r2BhlPWtx9W2BS2KawBDVvYOs7IFs6RqzgO0i24TtijX+fBPGm/HGPCMIbc83lyKOgSAjHfGDybAnApPsNzw3yFbBIQSDe7BKxLe6BUUyZsItdDYCBfad7A0aMBBtdc0YPNmHN89MkzSe6tYnA9uOFKcuc/rSNzbi2hZT7ORC6EnlOlRhNVa1lqeMmZAdV6p3teIyZ1ThZsuyEAjhzjmjw1ZEEp0mVxY6h9eokvLYByQT+6JT8OZ8DNM9fl1n3rXBfSgRgiyzyyUFEYLE0rEo50yXBLMqZN2iHVlXjbEJnnTZkDZSx1sumc6FzWuLJjKt/RJBxwaUvSlP3JmxHHkr5T0waYjQp9vhZTKyXbUxLH1oUze3W0v6EVmYwttVQAhgD/5Qp0LEVxiLYykZ9UDb/kE/jTP2x9957HX6aABXCXzD2tc4unYMdf38bZPdbTlNSN1D1llVXBY7zzvgn5vnILprSRhwTdrk3QI6H+H5yWu9zEC2kHnMe/tVZ4vzS17' }
)
# Optional extra layer: pinned Authenticode thumbprints. Empty = layer disabled.
$script:WcbTrustedThumbprints = @()
$script:WcbMetaFiles = @('.wincare-manifest.json', '.wincare-manifest.json.sig')

# ----------------------------------------------------------------- helpers --

function Test-WcbVersion {
    param([string] $Value)
    return ($Value -match '^\d{1,4}\.\d{1,4}\.\d{1,4}$')
}

function Test-WcbSha256Text {
    param([string] $Value)
    return ($Value -match '^[A-Fa-f0-9]{64}$')
}

function Test-WcbReleaseUri {
    <# HTTPS + allowlisted host + not a placeholder. #>
    param([string] $Uri, [string[]] $AllowedHosts = $script:WcbAllowedHosts)
    if (-not $Uri -or $Uri -match '/OWNER/') { return $false }
    $u = $null
    if (-not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https') { return $false }
    return ($AllowedHosts -contains $u.Host.ToLowerInvariant())
}

function Get-WcbDefaultCacheRoot {
    $base = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'WinCare') 'app')
}

function Get-WcbSha256 {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Test-WcbRelativePath {
    param([string] $Path)
    if (-not $Path) { return $false }
    $p = $Path.Replace('\', '/')
    if ($p.StartsWith('/') -or $p -match '^[A-Za-z]:' -or ($p.Split('/') -contains '..') -or ($p.Split('/') -contains '.')) { return $false }
    return ($p -match '^[A-Za-z0-9 _\-\./]+$')
}

function Test-WcbManifestSignature {
    <# Returns $null when the detached signature verifies with a pinned key, else an error string. #>
    param([string] $ManifestPath, [string] $SignaturePath, [object[]] $Keys = $script:WcbTrustedKeys)
    if (@($Keys).Count -eq 0) { return 'No trusted release key configured in the bootstrapper (fail closed).' }
    if (-not (Test-Path -LiteralPath $SignaturePath)) { return 'Manifest signature (.sig) not found.' }
    $data = [System.IO.File]::ReadAllBytes($ManifestPath)
    $sig = [System.IO.File]::ReadAllBytes($SignaturePath)
    foreach ($k in @($Keys)) {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        try {
            $p = New-Object System.Security.Cryptography.RSAParameters
            $p.Modulus = [System.Convert]::FromBase64String([string]$k.Modulus)
            $p.Exponent = [System.Convert]::FromBase64String([string]$k.Exponent)
            $rsa.ImportParameters($p)
            if ($rsa.VerifyData($data, $sig, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)) { return $null }
        }
        catch { Write-Verbose ('Key check failed: ' + $_.Exception.Message) }
        finally { $rsa.Dispose() }
    }
    return 'Manifest signature is invalid or not from a trusted key.'
}

function Read-WcbManifest {
    <# { version, package: { name, sha256, size }, files: [ { path, sha256 } ] } #>
    param([string] $Path)
    $m = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($req in 'version', 'package', 'files') { if (-not $m.PSObject.Properties[$req]) { throw "Manifest missing '$req'." } }
    if (-not (Test-WcbVersion ([string]$m.version))) { throw 'Manifest has an invalid version.' }
    if (-not (Test-WcbSha256Text ([string]$m.package.sha256))) { throw 'Manifest has an invalid package hash.' }
    if ([string]$m.package.name -match '[\\/]' -or [string]$m.package.name -match '\.\.') { throw 'Manifest has an invalid package name.' }
    foreach ($f in @($m.files)) {
        if (-not (Test-WcbRelativePath ([string]$f.path))) { throw ("Manifest has an invalid file path '{0}'." -f $f.path) }
        if (-not (Test-WcbSha256Text ([string]$f.sha256))) { throw ("Manifest has an invalid hash for '{0}'." -f $f.path) }
    }
    return $m
}

function Expand-WcbZipSafe {
    <# Extracts a zip rejecting absolute paths, '..' segments and anything outside Destination. #>
    param([Parameter(Mandatory = $true)][string] $ZipPath, [Parameter(Mandatory = $true)][string] $Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $destFull = [System.IO.Path]::GetFullPath($Destination).TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    New-Item -ItemType Directory -Path $destFull -Force | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            $name = $e.FullName.Replace('\', '/')
            if ($name.StartsWith('/') -or $name -match '^[A-Za-z]:' -or ($name.Split('/') -contains '..')) {
                throw "Unsafe path in package: $($e.FullName)"
            }
            $target = [System.IO.Path]::GetFullPath((Join-Path $destFull $name))
            if (-not $target.StartsWith($destFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe path in package: $($e.FullName)" }
            if ($name.EndsWith('/')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            $dir = Split-Path -Parent $target
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $false)
        }
    }
    finally { $zip.Dispose() }
}

function Test-WcbFileSet {
    <# Exact match between files on disk and the manifest list (no missing, modified or extra). #>
    param([string] $Root, $Manifest)
    $errors = @()
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $expected = @{}
    foreach ($f in @($Manifest.files)) { $expected[([string]$f.path).Replace('\', '/').ToLowerInvariant()] = ([string]$f.sha256).ToUpperInvariant() }
    $seen = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force)) {
        $rel = $file.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
        if ($script:WcbMetaFiles -contains $rel) { continue }
        $key = $rel.ToLowerInvariant()
        if (-not $expected.ContainsKey($key)) { $errors += "Extra file not in manifest: $rel"; continue }
        $seen[$key] = $true
        if ((Get-WcbSha256 $file.FullName) -ne $expected[$key]) { $errors += "Modified file: $rel" }
    }
    foreach ($k in $expected.Keys) { if (-not $seen.ContainsKey($k)) { $errors += "Missing file: $k" } }
    return $errors
}

function Test-WcbSignature {
    param([string] $Path, [string[]] $TrustedThumbprints)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$sig.Status -ne 'Valid') { return ("Signature not valid ({0}): {1}" -f $sig.Status, $Path) }
    if (-not $sig.SignerCertificate) { return "No signer certificate: $Path" }
    if ($TrustedThumbprints -notcontains $sig.SignerCertificate.Thumbprint.ToUpperInvariant()) { return "Signer not trusted ($($sig.SignerCertificate.Thumbprint)): $Path" }
    return $null
}

function Test-WcbAuthenticode {
    <# Optional layer: signed catalog + signed scripts from pinned thumbprints. #>
    param([string] $Root, [string[]] $TrustedThumbprints)
    $errors = @()
    $trusted = @($TrustedThumbprints | ForEach-Object { ([string]$_).ToUpperInvariant() } | Where-Object { $_ })
    $cat = Join-Path $Root 'WinCare.cat'
    if (-not (Test-Path -LiteralPath $cat)) { return @('WinCare.cat not found.') }
    $e = Test-WcbSignature -Path $cat -TrustedThumbprints $trusted
    if ($e) { $errors += $e }
    try {
        $skip = @('WinCare.cat') + $script:WcbMetaFiles
        $res = Test-FileCatalog -CatalogFilePath $cat -Path $Root -Detailed -FilesToSkip $skip -ErrorAction Stop
        if ([string]$res.Status -ne 'Valid') { $errors += "File catalog validation failed ($($res.Status))." }
    }
    catch { $errors += ('Test-FileCatalog failed: ' + $_.Exception.Message) }
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')) {
        $e = Test-WcbSignature -Path $f.FullName -TrustedThumbprints $trusted
        if ($e) { $errors += $e }
    }
    return $errors
}

function Test-WcbPackage {
    <# Verifies an expanded package. Returns @{ Valid; Errors }. #>
    param(
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][string] $ManifestPath,
        [object[]] $Keys = $script:WcbTrustedKeys,
        [string[]] $TrustedThumbprints = $script:WcbTrustedThumbprints
    )
    $errors = @()
    $sigErr = Test-WcbManifestSignature -ManifestPath $ManifestPath -SignaturePath ($ManifestPath + '.sig') -Keys $Keys
    if ($sigErr) { return [pscustomobject]@{ Valid = $false; Errors = @($sigErr) } }
    $m = Read-WcbManifest $ManifestPath
    $errors += @(Test-WcbFileSet -Root $Root -Manifest $m)
    if (@($TrustedThumbprints | Where-Object { $_ }).Count -gt 0) { $errors += @(Test-WcbAuthenticode -Root $Root -TrustedThumbprints $TrustedThumbprints) }
    return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors }
}

function Get-WcbDownload {
    param([string] $Uri, [string] $OutFile)
    if (-not (Test-WcbReleaseUri $Uri)) { throw "Refusing non-official or non-HTTPS URL: $Uri" }
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
}

# -------------------------------------------------------------------- main --

function Invoke-WcbMain {
    param(
        [string] $Version, [string] $PackagePath, [string] $ManifestPath, [string] $ExpectedSha256,
        [string] $CacheRoot, [switch] $VerifyOnly
    )
    if (-not $Version) { $Version = $script:WcbDefaultVersion }
    if (-not (Test-WcbVersion $Version)) { throw 'Use -Version x.y.z (explicit version is required).' }
    if ($ExpectedSha256 -and -not (Test-WcbSha256Text $ExpectedSha256)) { throw '-ExpectedSha256 must be 64 hex characters.' }
    if (-not $CacheRoot) { $CacheRoot = Get-WcbDefaultCacheRoot }
    $target = Join-Path $CacheRoot $Version
    $cachedManifest = Join-Path $target '.wincare-manifest.json'

    if (Test-Path -LiteralPath $target) {
        Write-Host "Verifying cached release $Version..."
        $check = Test-WcbPackage -Root $target -ManifestPath $cachedManifest
        if (-not $check.Valid) {
            $check.Errors | ForEach-Object { Write-Warning $_ }
            throw "Cached release $Version failed verification. Remove '$target' and run again."
        }
    }
    else {
        $work = Join-Path $CacheRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            $man = Join-Path $work 'manifest.json'
            if ($ManifestPath) {
                Copy-Item -LiteralPath $ManifestPath -Destination $man
                if (Test-Path -LiteralPath ($ManifestPath + '.sig')) { Copy-Item -LiteralPath ($ManifestPath + '.sig') -Destination ($man + '.sig') }
            }
            else {
                $base = '{0}/v{1}/WinCare-{1}.manifest.json' -f $script:WcbReleaseBaseUri, $Version
                Get-WcbDownload -Uri $base -OutFile $man
                Get-WcbDownload -Uri ($base + '.sig') -OutFile ($man + '.sig')
            }
            $sigErr = Test-WcbManifestSignature -ManifestPath $man -SignaturePath ($man + '.sig')
            if ($sigErr) { throw $sigErr }
            $m = Read-WcbManifest $man
            if ([string]$m.version -ne $Version) { throw "Manifest version '$($m.version)' differs from requested '$Version'." }
            if ($PackagePath) { $zip = (Resolve-Path -LiteralPath $PackagePath).ProviderPath }
            else {
                $zip = Join-Path $work ([string]$m.package.name)
                Get-WcbDownload -Uri ('{0}/v{1}/{2}' -f $script:WcbReleaseBaseUri, $Version, $m.package.name) -OutFile $zip
            }
            if ((Get-WcbSha256 $zip) -ne ([string]$m.package.sha256).ToUpperInvariant()) { throw 'SHA-256 mismatch between package and signed manifest.' }
            if ($ExpectedSha256 -and (Get-WcbSha256 $zip) -ne $ExpectedSha256.ToUpperInvariant()) { throw 'SHA-256 differs from -ExpectedSha256.' }
            $stage = Join-Path $work 'pkg'
            Expand-WcbZipSafe -ZipPath $zip -Destination $stage
            Copy-Item -LiteralPath $man -Destination (Join-Path $stage '.wincare-manifest.json')
            Copy-Item -LiteralPath ($man + '.sig') -Destination (Join-Path $stage '.wincare-manifest.json.sig')
            $check = Test-WcbPackage -Root $stage -ManifestPath (Join-Path $stage '.wincare-manifest.json')
            if (-not $check.Valid) {
                $check.Errors | ForEach-Object { Write-Warning $_ }
                throw 'Package rejected: verification failed. Nothing was started.'
            }
            Move-Item -LiteralPath $stage -Destination $target
        }
        finally {
            if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Host "WinCare $Version verified: $target"
    if ($VerifyOnly) { return $target }
    $sysRoot = $env:SystemRoot
    if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
    $ps51 = $sysRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
    # Process-scope RemoteSigned: lets the verified local copy run on machines left at
    # the default 'Restricted'. Group Policy (MachinePolicy/UserPolicy) still wins.
    Start-Process -FilePath $ps51 -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"{0}"' -f (Join-Path $target 'src\Start-WinCare.ps1')))
    return $target
}

# Dot-sourcing (tests) only loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-WcbMain -Version $Version -PackagePath $PackagePath -ManifestPath $ManifestPath -ExpectedSha256 $ExpectedSha256 -CacheRoot $CacheRoot -VerifyOnly:$VerifyOnly | Out-Null
    }
    catch {
        Write-Error ('WinCare bootstrap stopped: ' + $_.Exception.Message)
        exit 1
    }
}
