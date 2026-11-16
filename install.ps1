#Requires -Version 5.1
<#
.SYNOPSIS
    Verifies and starts a WinCare Enterprise release. One command, no installer,
    no execution-policy bypass.

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
      7. Elevated runs never execute user-writable code: as administrator the cache
         is under Program Files (admin-only write), and -Elevate makes the elevated
         process download install.ps1 again into Program Files and check that its
         SHA-256 equals this file before running it.

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
.PARAMETER PowerShellHost
    Auto (default): PowerShell 7 if installed in Program Files, else Windows PowerShell 5.1.
    WindowsPowerShell or PowerShell7 force one host.
.PARAMETER Elevate
    Ask for administrator rights (UAC) and run from Program Files. Needed to apply
    maintenance actions that require admin. Online mode only.
#>
[CmdletBinding()]
param(
    [string] $Version,
    [string] $PackagePath,
    [string] $ManifestPath,
    [string] $ExpectedSha256,
    [string] $CacheRoot,
    [switch] $VerifyOnly,
    [switch] $Elevate,
    [ValidateSet('Auto', 'WindowsPowerShell', 'PowerShell7')][string] $PowerShellHost = 'Auto'
)

Set-StrictMode -Version 2.0

# ----------------------------------------------------------- trust anchors --
$script:WcbDefaultVersion = '0.3.0'
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

function Test-WcbIsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

function Get-WcbMachineRoot {
    <# Program Files\WinCare: only administrators can write there (default ACL). #>
    $pf = $env:ProgramFiles
    if (-not $pf) { $pf = 'C:\Program Files' }
    return ($pf.TrimEnd('\') + '\WinCare')
}

function Get-WcbDefaultCacheRoot {
    param([switch] $Machine)
    if ($Machine) { return ((Get-WcbMachineRoot) + '\app') }
    $base = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::LocalApplicationData)
    if (-not $base) { $base = [System.IO.Path]::GetTempPath() }
    return (Join-Path (Join-Path $base 'WinCare') 'app')
}

function Get-WcbSha256 {
    <# Retries: antivirus often holds freshly extracted files for a moment. #>
    param([string] $Path)
    for ($i = 1; $i -le 10; $i++) {
        try { return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() }
        catch {
            if ($i -eq 10 -or -not (Test-Path -LiteralPath $Path)) { throw }
            Start-Sleep -Milliseconds (300 * $i)
        }
    }
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
    foreach ($f in @(Get-ChildItem -LiteralPath $Root -Recurse -File | Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension.ToLowerInvariant() })) {
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
    # Corporate proxies that require Windows authentication.
    try { [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials } catch { Write-Verbose 'No default proxy.' }
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
}

function Get-WcbHostCandidates {
    <#
        Hosts that may run the app. PowerShell 7 is used only from its default machine-wide
        location (Program Files: admin-only write), never from PATH or a user folder.
    #>
    $sysRoot = $env:SystemRoot
    if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
    $pf = $env:ProgramFiles
    if (-not $pf) { $pf = 'C:\Program Files' }
    $ps7 = $pf.TrimEnd('\') + '\PowerShell\7\pwsh.exe'
    return [pscustomobject]@{
        WindowsPowerShell = $sysRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
        PowerShell7       = $ps7
        HasPowerShell7    = [bool](Test-Path -LiteralPath $ps7)
    }
}

function Select-WcbAppHost {
    <# Pure: Auto = PowerShell 7 when installed, else Windows PowerShell 5.1 (always present). #>
    param([string] $Preference = 'Auto', [Parameter(Mandatory = $true)] $Candidates)
    switch ($Preference) {
        'WindowsPowerShell' { return $Candidates.WindowsPowerShell }
        'PowerShell7' {
            if (-not $Candidates.HasPowerShell7) { throw ('PowerShell 7 not found at {0}.' -f $Candidates.PowerShell7) }
            return $Candidates.PowerShell7
        }
        default {
            if ($Candidates.HasPowerShell7) { return $Candidates.PowerShell7 }
            return $Candidates.WindowsPowerShell
        }
    }
}

function Get-WcbEnvironmentBlock {
    <#
        Returns $null when the app can start here, or a message explaining which
        corporate control blocks it. Never tries to work around the control.
        $LanguageMode / $Policies are parameters so the logic is testable.
    #>
    param(
        [string] $LanguageMode = [string]$ExecutionContext.SessionState.LanguageMode,
        [hashtable] $Policies,
        [string[]] $TrustedThumbprints = $script:WcbTrustedThumbprints
    )
    if ($LanguageMode -and $LanguageMode -ne 'FullLanguage') {
        return ("PowerShell is in {0} (AppLocker/WDAC). WinCare needs FullLanguage; ask IT to allow the WinCare publisher or the signed package. See docs/CORPORATIVO.md." -f $LanguageMode)
    }
    if ($null -eq $Policies) {
        $Policies = @{}
        foreach ($sc in 'MachinePolicy', 'UserPolicy') {
            try { $Policies[$sc] = [string](Get-ExecutionPolicy -Scope $sc) } catch { $Policies[$sc] = 'Undefined' }
        }
    }
    $signed = (@($TrustedThumbprints | Where-Object { $_ }).Count -gt 0)
    foreach ($sc in 'MachinePolicy', 'UserPolicy') {
        $p = [string]$Policies[$sc]
        if ($p -eq 'Restricted') { return ("Group Policy ({0}) sets the execution policy to Restricted: no script can run. Ask IT; see docs/CORPORATIVO.md." -f $sc) }
        if ($p -eq 'AllSigned' -and -not $signed) { return ("Group Policy ({0}) requires AllSigned and this build has no Authenticode signature. IT can sign it with the organization certificate (scripts/Protect-WinCareWithOrgCertificate.ps1); see docs/CORPORATIVO.md." -f $sc) }
    }
    return $null
}

function New-WcbElevatedCommand {
    <#
        Script text for the elevated process (passed by -EncodedCommand, so no
        user-writable file is executed as admin). It downloads install.ps1 into
        Program Files, checks the SHA-256 and runs it. Inputs are validated: the
        result never contains caller-controlled code.
    #>
    param(
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $InstallUri,
        [Parameter(Mandatory = $true)][string] $InstallSha256,
        [string[]] $AllowedHosts = $script:WcbAllowedHosts
    )
    if (-not (Test-WcbVersion $Version)) { throw 'Invalid version.' }
    if (-not (Test-WcbSha256Text $InstallSha256)) { throw 'Invalid SHA-256.' }
    if (-not (Test-WcbReleaseUri -Uri $InstallUri -AllowedHosts $AllowedHosts)) { throw "Refusing non-official or non-HTTPS URL: $InstallUri" }
    # The URL is embedded in a quoted string: allow only characters that cannot break out.
    if ($InstallUri -notmatch '^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$') { throw 'URL has characters that are not allowed.' }
    $lines = @(
        '$ErrorActionPreference = ''Stop''',
        'try {',
        '    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12',
        '    try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { Write-Verbose ''no proxy'' }',
        '    $pf = $env:ProgramFiles; if (-not $pf) { $pf = ''C:\Program Files'' }',
        '    $d = Join-Path $pf ''WinCare\bootstrap''',
        '    New-Item -ItemType Directory -Path $d -Force | Out-Null',
        ('    $f = Join-Path $d ''install-{0}.ps1''' -f $Version),
        ('    Invoke-WebRequest -Uri ''{0}'' -UseBasicParsing -OutFile $f' -f $InstallUri),
        ('    if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne ''{0}'') {{ Remove-Item -LiteralPath $f -Force; throw ''install.ps1 hash mismatch - nothing was started.'' }}' -f $InstallSha256.ToUpperInvariant()),
        '    $ps = Join-Path $env:SystemRoot ''System32\WindowsPowerShell\v1.0\powershell.exe''',
        ('    & $ps -NoProfile -ExecutionPolicy RemoteSigned -File $f -Version ''{0}''' -f $Version),
        '    if ($LASTEXITCODE -ne 0) { throw (''install.ps1 exited with code '' + $LASTEXITCODE) }',
        '}',
        'catch { Write-Host (''WinCare: '' + $_.Exception.Message) -ForegroundColor Red; Read-Host ''Press Enter to close'' | Out-Null }'
    )
    return ($lines -join "`r`n")
}

function ConvertTo-WcbEncodedCommand {
    param([Parameter(Mandatory = $true)][string] $Text)
    return [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($Text))
}

function Start-WcbElevated {
    <# Re-runs this release elevated (UAC). Online mode only. #>
    param([string] $Version, [string] $SelfPath)
    if (-not $SelfPath -or -not (Test-Path -LiteralPath $SelfPath)) { throw '-Elevate needs install.ps1 to run from a file.' }
    $uri = '{0}/v{1}/install.ps1' -f $script:WcbReleaseBaseUri, $Version
    $cmd = New-WcbElevatedCommand -Version $Version -InstallUri $uri -InstallSha256 (Get-WcbSha256 $SelfPath)
    $sysRoot = $env:SystemRoot
    if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
    $ps51 = $sysRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-Host 'Requesting administrator rights (UAC)...'
    Start-Process -FilePath $ps51 -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-EncodedCommand', (ConvertTo-WcbEncodedCommand $cmd)) | Out-Null
}

# -------------------------------------------------------------------- main --

function Invoke-WcbMain {
    param(
        [string] $Version, [string] $PackagePath, [string] $ManifestPath, [string] $ExpectedSha256,
        [string] $CacheRoot, [switch] $VerifyOnly, [switch] $Elevate, [string] $SelfPath,
        [ValidateSet('Auto', 'WindowsPowerShell', 'PowerShell7')][string] $PowerShellHost = 'Auto'
    )
    if (-not $Version) { $Version = $script:WcbDefaultVersion }
    if (-not (Test-WcbVersion $Version)) { throw 'Use -Version x.y.z (explicit version is required).' }
    if ($ExpectedSha256 -and -not (Test-WcbSha256Text $ExpectedSha256)) { throw '-ExpectedSha256 must be 64 hex characters.' }
    $block = Get-WcbEnvironmentBlock
    if ($block) { throw $block }
    $isAdmin = Test-WcbIsAdmin
    if ($Elevate -and -not $isAdmin) {
        if ($PackagePath -or $ManifestPath) { throw '-Elevate works online only. Offline: copy the package to an admin-only folder and run install.ps1 from an elevated PowerShell.' }
        Start-WcbElevated -Version $Version -SelfPath $SelfPath
        return $null
    }
    # As administrator the cache lives where standard users cannot write.
    if (-not $CacheRoot) { $CacheRoot = Get-WcbDefaultCacheRoot -Machine:$isAdmin }
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
    $appHost = Select-WcbAppHost -Preference $PowerShellHost -Candidates (Get-WcbHostCandidates)
    Write-Host ("Starting with {0}" -f $appHost)
    # Process-scope RemoteSigned: lets the verified local copy run on machines left at
    # the default 'Restricted'. Group Policy (MachinePolicy/UserPolicy) still wins.
    Start-Process -FilePath $appHost -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'RemoteSigned', '-File', ('"{0}"' -f (Join-Path $target 'src\Start-WinCare.ps1')))
    return $target
}

# Dot-sourcing (tests) only loads the functions.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-WcbMain -Version $Version -PackagePath $PackagePath -ManifestPath $ManifestPath -ExpectedSha256 $ExpectedSha256 -CacheRoot $CacheRoot -VerifyOnly:$VerifyOnly -Elevate:$Elevate -SelfPath $PSCommandPath -PowerShellHost $PowerShellHost | Out-Null
    }
    catch {
        Write-Error ('WinCare bootstrap stopped: ' + $_.Exception.Message)
        exit 1
    }
}
