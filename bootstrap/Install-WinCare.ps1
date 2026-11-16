#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies and starts a WinCare Enterprise release. One command, no installer,
    no "irm | iex", no execution-policy bypass.

.DESCRIPTION
    Trust model (fail closed - any check that cannot be completed stops the run):
      1. Trust anchors are constants in THIS file: the official release URL and the
         pinned thumbprints of the code-signing certificate(s). This bootstrapper
         is itself Authenticode-signed and obtained from a trusted channel
         (internal share, signed release, or copied by the technician).
      2. The package (zip) is downloaded over HTTPS from the pinned URL, or taken
         from a local path for offline use.
      3. Transport integrity: SHA-256 of the zip must match the release manifest
         and, if given, -ExpectedSha256 obtained out of band. These hashes are NOT
         treated as proof of authenticity (same origin).
      4. Authenticity: the zip is expanded with path-traversal checks into a
         staging folder; WinCare.cat (signed file catalog) must have a Valid
         Authenticode signature from a pinned thumbprint; Test-FileCatalog must
         report every file unchanged and no extra files; every .ps1/.psm1/.psd1
         must also carry a Valid signature from a pinned thumbprint.
      5. Only then is the package moved into a versioned cache and started.
         The cached copy is re-verified on every start.

.PARAMETER Version
    Release to start, e.g. 0.1.0. Required: versions are always explicit.

.PARAMETER PackagePath
    Offline mode: local WinCare-<version>.zip previously obtained from a trusted source.

.PARAMETER ManifestPath
    Offline mode: local release manifest (optional but recommended).

.PARAMETER ExpectedSha256
    SHA-256 of the zip obtained out of band (e.g. from the change ticket).

.PARAMETER VerifyOnly
    Verify and cache, but do not start the interface.

.EXAMPLE
    powershell.exe -NoProfile -File .\Install-WinCare.ps1 -Version 0.1.0
.EXAMPLE
    powershell.exe -NoProfile -File .\Install-WinCare.ps1 -Version 0.1.0 -PackagePath E:\WinCare-0.1.0.zip -ManifestPath E:\WinCare-0.1.0.manifest.json
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
# Edit ONLY when cutting an official release, then sign this file.
$script:WcbReleaseBaseUri = 'https://github.com/OWNER/WinCareEnterprise/releases/download'
$script:WcbAllowedHosts = @('github.com')
# SHA-1 thumbprints (as shown by Get-AuthenticodeSignature) of trusted signing certs.
# Empty = no trusted publisher yet = every package is rejected.
$script:WcbTrustedThumbprints = @()

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
    <# HTTPS + allowlisted host + not the placeholder. #>
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

function Read-WcbManifest {
    <# { "version": "x.y.z", "files": [ { "name": "...", "sha256": "...", "size": n } ] } #>
    param([string] $Path)
    $m = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not ($m.PSObject.Properties['version'] -and $m.PSObject.Properties['files'])) { throw 'Manifest missing version/files.' }
    foreach ($f in @($m.files)) {
        if (-not (Test-WcbSha256Text $f.sha256)) { throw ("Manifest has an invalid hash for '{0}'." -f $f.name) }
        if ($f.name -match '[\\/]' -or $f.name -match '\.\.') { throw ("Manifest has an invalid file name '{0}'." -f $f.name) }
    }
    return $m
}

function Test-WcbFileAgainstManifest {
    param([string] $FilePath, $Manifest, [string] $Version)
    $name = [System.IO.Path]::GetFileName($FilePath)
    if ([string]$Manifest.version -ne $Version) { return "Manifest version '$($Manifest.version)' differs from requested '$Version'." }
    $entry = @($Manifest.files | Where-Object { $_.name -eq $name }) | Select-Object -First 1
    if (-not $entry) { return "File '$name' not listed in manifest." }
    if ((Get-WcbSha256 $FilePath) -ne ([string]$entry.sha256).ToUpperInvariant()) { return "SHA-256 mismatch for '$name'." }
    return $null
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

function Test-WcbSignature {
    param([string] $Path, [string[]] $TrustedThumbprints)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    if ([string]$sig.Status -ne 'Valid') { return ("Signature not valid ({0}): {1}" -f $sig.Status, $Path) }
    if (-not $sig.SignerCertificate) { return "No signer certificate: $Path" }
    if ($TrustedThumbprints -notcontains $sig.SignerCertificate.Thumbprint.ToUpperInvariant()) { return "Signer not trusted ($($sig.SignerCertificate.Thumbprint)): $Path" }
    return $null
}

function Test-WcbPackage {
    <# Verifies an expanded package folder. Returns @{ Valid; Errors }. #>
    param([Parameter(Mandatory = $true)][string] $Root, [string[]] $TrustedThumbprints = $script:WcbTrustedThumbprints)
    $errors = @()
    $trusted = @($TrustedThumbprints | ForEach-Object { ([string]$_).ToUpperInvariant() } | Where-Object { $_ })
    if ($trusted.Count -eq 0) { return [pscustomobject]@{ Valid = $false; Errors = @('No trusted publisher configured in the bootstrapper (fail closed).') } }
    $cat = Join-Path $Root 'WinCare.cat'
    if (-not (Test-Path -LiteralPath $cat)) { return [pscustomobject]@{ Valid = $false; Errors = @('WinCare.cat not found.') } }
    $e = Test-WcbSignature -Path $cat -TrustedThumbprints $trusted
    if ($e) { $errors += $e }
    try {
        $res = Test-FileCatalog -CatalogFilePath $cat -Path $Root -Detailed -FilesToSkip 'WinCare.cat' -ErrorAction Stop
        if ([string]$res.Status -ne 'Valid') { $errors += "File catalog validation failed ($($res.Status))." }
        $catKeys = @($res.CatalogItems.Keys | ForEach-Object { ([string]$_).ToLowerInvariant() })
        foreach ($p in @($res.PathItems.Keys)) {
            if ($catKeys -notcontains ([string]$p).ToLowerInvariant()) { $errors += "File not covered by catalog: $p" }
        }
    }
    catch { $errors += ('Test-FileCatalog failed: ' + $_.Exception.Message) }
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1')) {
        $e = Test-WcbSignature -Path $f.FullName -TrustedThumbprints $trusted
        if ($e) { $errors += $e }
    }
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
    if (-not (Test-WcbVersion $Version)) { throw 'Use -Version x.y.z (explicit version is required).' }
    if ($ExpectedSha256 -and -not (Test-WcbSha256Text $ExpectedSha256)) { throw '-ExpectedSha256 must be 64 hex characters.' }
    if (-not $CacheRoot) { $CacheRoot = Get-WcbDefaultCacheRoot }
    $target = Join-Path $CacheRoot $Version
    $zipName = "WinCare-$Version.zip"

    if (Test-Path -LiteralPath $target) {
        Write-Host "Verifying cached release $Version..."
        $check = Test-WcbPackage -Root $target
        if (-not $check.Valid) {
            $check.Errors | ForEach-Object { Write-Warning $_ }
            throw "Cached release $Version failed verification. Remove '$target' and run again."
        }
    }
    else {
        $work = Join-Path $CacheRoot ('.staging-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $work -Force | Out-Null
        try {
            if ($PackagePath) {
                $zip = (Resolve-Path -LiteralPath $PackagePath).ProviderPath
            }
            else {
                $zip = Join-Path $work $zipName
                $ManifestPath = Join-Path $work "WinCare-$Version.manifest.json"
                Get-WcbDownload -Uri ("{0}/v{1}/{2}" -f $script:WcbReleaseBaseUri, $Version, $zipName) -OutFile $zip
                Get-WcbDownload -Uri ("{0}/v{1}/WinCare-{1}.manifest.json" -f $script:WcbReleaseBaseUri, $Version) -OutFile $ManifestPath
            }
            if ($ManifestPath) {
                $err = Test-WcbFileAgainstManifest -FilePath $zip -Manifest (Read-WcbManifest $ManifestPath) -Version $Version
                if ($err) { throw $err }
            }
            if ($ExpectedSha256 -and (Get-WcbSha256 $zip) -ne $ExpectedSha256.ToUpperInvariant()) { throw 'SHA-256 differs from -ExpectedSha256.' }
            $stage = Join-Path $work 'pkg'
            Expand-WcbZipSafe -ZipPath $zip -Destination $stage
            $check = Test-WcbPackage -Root $stage
            if (-not $check.Valid) {
                $check.Errors | ForEach-Object { Write-Warning $_ }
                throw 'Package rejected: signature/catalog verification failed. Nothing was started.'
            }
            Move-Item -LiteralPath $stage -Destination $target
        }
        finally {
            if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    Write-Host "WinCare $Version verified: $target"
    if ($VerifyOnly) { return $target }
    $ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps51 -ArgumentList @('-NoProfile', '-STA', '-File', ('"{0}"' -f (Join-Path $target 'src\Start-WinCare.ps1')))
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
