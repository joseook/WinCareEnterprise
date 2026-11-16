#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Security tests for bootstrap/Install-WinCare.ps1. RSA signatures are real
# (keys generated per run); Authenticode cmdlets are mocked (Windows-only) and
# exercised for real in tests/Windows.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $script:RepoRoot 'bootstrap/Install-WinCare.ps1')
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

    function New-TestKey {
        $rsa = [System.Security.Cryptography.RSA]::Create()
        $rsa.KeySize = 2048
        $p = $rsa.ExportParameters($false)
        return @{ Rsa = $rsa; Pub = @{ Id = 'test'; Modulus = [Convert]::ToBase64String($p.Modulus); Exponent = [Convert]::ToBase64String($p.Exponent) } }
    }
    function Write-Signature {
        param([string] $Path, $Key)
        $sig = $Key.Rsa.SignData([System.IO.File]::ReadAllBytes($Path), [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
        [System.IO.File]::WriteAllBytes($Path + '.sig', $sig)
    }
    function New-TestZip {
        param([string] $Path, [hashtable] $Entries)
        $fs = [System.IO.File]::Open($Path, 'Create')
        $zip = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
        foreach ($k in $Entries.Keys) {
            $e = $zip.CreateEntry($k)
            $w = New-Object System.IO.StreamWriter($e.Open())
            $w.Write($Entries[$k]); $w.Dispose()
        }
        $zip.Dispose(); $fs.Dispose()
    }
    function Get-TextSha256([string] $Text) {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return ([BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))) -replace '-', '')
    }
    # A complete signed release in a temp dir. Returns paths.
    function New-TestRelease {
        param($Key, [hashtable] $Files = @{ 'src/Start-WinCare.ps1' = '# start'; 'README.md' = 'readme' }, [string] $Version = '0.2.0')
        $d = New-WcTestDir
        $zip = Join-Path $d "WinCare-$Version.zip"
        New-TestZip -Path $zip -Entries $Files
        $list = foreach ($k in $Files.Keys) { [ordered]@{ path = $k; sha256 = (Get-TextSha256 $Files[$k]) } }
        $m = [ordered]@{ version = $Version; package = [ordered]@{ name = "WinCare-$Version.zip"; sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash; size = (Get-Item $zip).Length }; files = @($list) }
        $man = Join-Path $d "WinCare-$Version.manifest.json"
        [System.IO.File]::WriteAllText($man, (ConvertTo-Json $m -Depth 5))
        Write-Signature -Path $man -Key $Key
        return @{ Dir = $d; Zip = $zip; Manifest = $man; Cache = (Join-Path $d 'cache') }
    }
    $script:Key = New-TestKey
    $script:OtherKey = New-TestKey
}

Describe 'Input validation' {
    It 'requires an explicit x.y.z version' {
        Test-WcbVersion '0.1.0' | Should -BeTrue
        foreach ($v in @('', 'latest', '1.0', '1.0.0; calc', '../1.0.0')) { Test-WcbVersion $v | Should -BeFalse }
    }
    It 'accepts only HTTPS URLs on allowlisted hosts' {
        Test-WcbReleaseUri 'https://github.com/joseook/WinCareEnterprise/releases/download/v0.1.0/x.zip' | Should -BeTrue
        Test-WcbReleaseUri 'http://github.com/acme/x.zip' | Should -BeFalse
        Test-WcbReleaseUri 'https://github.com.evil.example/x.zip' | Should -BeFalse
        Test-WcbReleaseUri 'https://evil.example/x.zip' | Should -BeFalse
        Test-WcbReleaseUri 'file:///C:/x.zip' | Should -BeFalse
    }
    It 'refuses downloads from a bad URL before any network call' {
        Mock Invoke-WebRequest { throw 'should not be called' }
        { Get-WcbDownload -Uri 'http://example.com/x.zip' -OutFile 'x' } | Should -Throw '*Refusing*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
    It 'validates manifest relative paths' {
        foreach ($ok in 'src/a.ps1', 'README.md', 'src/UI/Pages/x.xaml') { Test-WcbRelativePath $ok | Should -BeTrue }
        foreach ($bad in '../a', '/etc/x', 'C:/x', 'a/../../b', 'a/./b', '', 'a;b') { Test-WcbRelativePath $bad | Should -BeFalse }
    }
}

Describe 'Safe extraction' {
    BeforeEach { $script:Dir = New-WcTestDir }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }
    It 'extracts a normal package' {
        $z = Join-Path $script:Dir 'ok.zip'
        New-TestZip -Path $z -Entries @{ 'src/Start-WinCare.ps1' = 'x'; 'README.md' = 'y' }
        Expand-WcbZipSafe -ZipPath $z -Destination (Join-Path $script:Dir 'out')
        Test-Path (Join-Path $script:Dir 'out/src/Start-WinCare.ps1') | Should -BeTrue
    }
    It 'rejects path traversal entries (<_>) and writes nothing outside' -ForEach @('../evil.txt', 'a/../../evil.txt', '/abs/evil.txt', 'C:/evil.txt', '..\evil.txt') {
        $z = Join-Path $script:Dir 'bad.zip'
        New-TestZip -Path $z -Entries @{ $_ = 'pwned' }
        { Expand-WcbZipSafe -ZipPath $z -Destination (Join-Path $script:Dir 'out') } | Should -Throw '*Unsafe path*'
        Test-Path (Join-Path $script:Dir 'evil.txt') | Should -BeFalse
    }
}

Describe 'Manifest signature (real RSA)' {
    BeforeAll { $script:R = New-TestRelease -Key $script:Key }
    It 'verifies with the pinned key' {
        Test-WcbManifestSignature -ManifestPath $script:R.Manifest -SignaturePath ($script:R.Manifest + '.sig') -Keys @($script:Key.Pub) | Should -BeNullOrEmpty
    }
    It 'fails closed with no pinned key' {
        Test-WcbManifestSignature -ManifestPath $script:R.Manifest -SignaturePath ($script:R.Manifest + '.sig') -Keys @() | Should -Match 'fail closed'
    }
    It 'rejects a signature from another key' {
        Test-WcbManifestSignature -ManifestPath $script:R.Manifest -SignaturePath ($script:R.Manifest + '.sig') -Keys @($script:OtherKey.Pub) | Should -Match 'invalid'
    }
    It 'rejects a manifest edited after signing' {
        $r = New-TestRelease -Key $script:Key
        Add-Content -LiteralPath $r.Manifest -Value ' '
        Test-WcbManifestSignature -ManifestPath $r.Manifest -SignaturePath ($r.Manifest + '.sig') -Keys @($script:Key.Pub) | Should -Match 'invalid'
    }
    It 'rejects a missing signature' {
        Test-WcbManifestSignature -ManifestPath $script:R.Manifest -SignaturePath 'nope.sig' -Keys @($script:Key.Pub) | Should -Match 'not found'
    }
    It 'rejects manifests with invalid paths or hashes' {
        $p = Join-Path (New-WcTestDir) 'm.json'
        Set-Content -LiteralPath $p -Value ('{"version":"0.2.0","package":{"name":"x.zip","sha256":"' + ('A' * 64) + '"},"files":[{"path":"../x","sha256":"' + ('A' * 64) + '"}]}')
        { Read-WcbManifest $p } | Should -Throw '*invalid file path*'
        Set-Content -LiteralPath $p -Value '{"version":"0.2.0","package":{"name":"x.zip","sha256":"abc"},"files":[]}'
        { Read-WcbManifest $p } | Should -Throw '*invalid package hash*'
    }
}

Describe 'End-to-end offline install (real RSA, no Authenticode layer)' {
    BeforeEach {
        $script:WcbTrustedKeys = @($script:Key.Pub)
        $script:WcbTrustedThumbprints = @()
        Mock Start-Process {}
    }
    AfterEach { $script:WcbTrustedKeys = @() }
    It 'verifies, caches by version and does not launch with -VerifyOnly' {
        $r = New-TestRelease -Key $script:Key
        $t = Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache -VerifyOnly
        Test-Path (Join-Path $t 'src/Start-WinCare.ps1') | Should -BeTrue
        Test-Path (Join-Path $t '.wincare-manifest.json.sig') | Should -BeTrue
        Should -Invoke Start-Process -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $r.Cache -Force | Where-Object Name -like '.staging-*').Count | Should -Be 0
    }
    It 'launches with process-scope RemoteSigned, never Bypass' {
        $r = New-TestRelease -Key $script:Key
        Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache | Out-Null
        Should -Invoke Start-Process -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -match 'RemoteSigned' -and ($ArgumentList -join ' ') -notmatch 'Bypass' }
    }
    It 'rejects a zip that differs from the signed manifest' {
        $r = New-TestRelease -Key $script:Key
        Add-Content -LiteralPath $r.Zip -Value 'tamper'
        { Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache -VerifyOnly } | Should -Throw '*mismatch*'
        Test-Path (Join-Path $r.Cache '0.2.0') | Should -BeFalse
    }
    It 'rejects a release signed by an untrusted key' {
        $r = New-TestRelease -Key $script:OtherKey
        { Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache -VerifyOnly } | Should -Throw '*not from a trusted key*'
    }
    It 'rejects a requested version that differs from the signed one' {
        $r = New-TestRelease -Key $script:Key
        { Invoke-WcbMain -Version '9.9.9' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache -VerifyOnly } | Should -Throw '*differs*'
    }
    It 'rejects -ExpectedSha256 mismatch' {
        $r = New-TestRelease -Key $script:Key
        { Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -ExpectedSha256 ('F' * 64) -CacheRoot $r.Cache -VerifyOnly } | Should -Throw '*ExpectedSha256*'
    }
    It 'rejects a zip with a file not covered by the manifest' {
        $r = New-TestRelease -Key $script:Key
        # Rebuild zip with an extra file and re-sign a manifest that only knows the original files + new zip hash.
        New-TestZip -Path $r.Zip -Entries @{ 'src/Start-WinCare.ps1' = '# start'; 'README.md' = 'readme'; 'evil.ps1' = 'x' }
        $m = Get-Content -Raw $r.Manifest | ConvertFrom-Json
        $m.package.sha256 = (Get-FileHash -LiteralPath $r.Zip -Algorithm SHA256).Hash
        [System.IO.File]::WriteAllText($r.Manifest, (ConvertTo-Json $m -Depth 5))
        Write-Signature -Path $r.Manifest -Key $script:Key
        { Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache -VerifyOnly } | Should -Throw '*rejected*'
    }
    It 're-verifies the cache and refuses a modified file' {
        $r = New-TestRelease -Key $script:Key
        $t = Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache -VerifyOnly
        Add-Content -LiteralPath (Join-Path $t 'src/Start-WinCare.ps1') -Value 'malicious'
        { Invoke-WcbMain -Version '0.2.0' -CacheRoot $r.Cache -VerifyOnly } | Should -Throw '*failed verification*'
    }
    It 're-verifies the cache and refuses an extra file' {
        $r = New-TestRelease -Key $script:Key
        $t = Invoke-WcbMain -Version '0.2.0' -PackagePath $r.Zip -ManifestPath $r.Manifest -CacheRoot $r.Cache -VerifyOnly
        Set-Content -LiteralPath (Join-Path $t 'src/extra.ps1') -Value 'x'
        { Invoke-WcbMain -Version '0.2.0' -CacheRoot $r.Cache -VerifyOnly } | Should -Throw '*failed verification*'
    }
}

Describe 'Optional Authenticode layer (mocked)' {
    BeforeAll {
        $script:Thumb = 'AABBCCDDEEFF00112233445566778899AABBCCDD'
        $script:Pkg = New-WcTestDir
        New-Item -ItemType Directory -Path (Join-Path $script:Pkg 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pkg 'src/Start-WinCare.ps1') -Value '#'
        Set-Content -LiteralPath (Join-Path $script:Pkg 'WinCare.cat') -Value 'cat'
    }
    It 'passes with Valid signatures from the pinned thumbprint' {
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD' } } }
        Mock Test-FileCatalog { [pscustomobject]@{ Status = 'Valid' } }
        @(Test-WcbAuthenticode -Root $script:Pkg -TrustedThumbprints @($script:Thumb)).Count | Should -Be 0
    }
    It 'fails on <Status> / untrusted signer / bad catalog' -ForEach @(@{ Status = 'NotSigned' }, @{ Status = 'HashMismatch' }) {
        $st = $Status
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = $st; SignerCertificate = [pscustomobject]@{ Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD' } } }.GetNewClosure()
        Mock Test-FileCatalog { [pscustomobject]@{ Status = 'Valid' } }
        @(Test-WcbAuthenticode -Root $script:Pkg -TrustedThumbprints @($script:Thumb)).Count | Should -BeGreaterThan 0
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Thumbprint = '1111111111111111111111111111111111111111' } } }
        @(Test-WcbAuthenticode -Root $script:Pkg -TrustedThumbprints @($script:Thumb)).Count | Should -BeGreaterThan 0
        Mock Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'Valid'; SignerCertificate = [pscustomobject]@{ Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD' } } }
        Mock Test-FileCatalog { [pscustomobject]@{ Status = 'ValidationFailed' } }
        @(Test-WcbAuthenticode -Root $script:Pkg -TrustedThumbprints @($script:Thumb)).Count | Should -BeGreaterThan 0
    }
}
