#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Security tests for bootstrap/Install-WinCare.ps1. Authenticode and catalog
# cmdlets are mocked (they are Windows-only); the real checks run in
# tests/Windows on a Windows machine.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . (Join-Path $script:RepoRoot 'bootstrap/Install-WinCare.ps1')
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $script:Thumb = 'AABBCCDDEEFF00112233445566778899AABBCCDD'

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
    function Set-SignatureMocks {
        param([string] $Status = 'Valid', [string] $Thumbprint = $script:Thumb, [string] $CatalogStatus = 'Valid', [switch] $ExtraFile)
        $sig = [pscustomobject]@{ Status = $Status; SignerCertificate = [pscustomobject]@{ Thumbprint = $Thumbprint } }
        Mock Get-AuthenticodeSignature { $sig }.GetNewClosure()
        $cat = @{ 'src/start-wincare.ps1' = 'H' }
        $path = @{ 'src/start-wincare.ps1' = 'H' }
        if ($ExtraFile) { $path['evil.ps1'] = 'X' }
        $res = [pscustomobject]@{ Status = $CatalogStatus; CatalogItems = $cat; PathItems = $path }
        Mock Test-FileCatalog { $res }.GetNewClosure()
    }
}

Describe 'Input validation' {
    It 'requires an explicit x.y.z version' {
        Test-WcbVersion '0.1.0' | Should -BeTrue
        foreach ($v in @('', 'latest', '1.0', '1.0.0; calc', '../1.0.0')) { Test-WcbVersion $v | Should -BeFalse }
    }
    It 'accepts only HTTPS URLs on allowlisted hosts' {
        Test-WcbReleaseUri 'https://github.com/acme/WinCareEnterprise/releases/download/v0.1.0/x.zip' | Should -BeTrue
        Test-WcbReleaseUri 'http://github.com/acme/x.zip' | Should -BeFalse
        Test-WcbReleaseUri 'https://github.com.evil.example/x.zip' | Should -BeFalse
        Test-WcbReleaseUri 'https://evil.example/x.zip' | Should -BeFalse
        Test-WcbReleaseUri 'file:///C:/x.zip' | Should -BeFalse
    }
    It 'refuses the unpublished placeholder URL' {
        Test-WcbReleaseUri ($script:WcbReleaseBaseUri + '/v0.1.0/x.zip') | Should -BeFalse
    }
    It 'refuses downloads from a bad URL before any network call' {
        Mock Invoke-WebRequest { throw 'should not be called' }
        { Get-WcbDownload -Uri 'http://example.com/x.zip' -OutFile 'x' } | Should -Throw '*Refusing*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
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

Describe 'Manifest checks' {
    BeforeAll {
        $script:MDir = New-WcTestDir
        $script:Zip = Join-Path $script:MDir 'WinCare-0.1.0.zip'
        Set-Content -LiteralPath $script:Zip -Value 'zip-bytes'
        $script:Hash = (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash
    }
    It 'accepts a matching hash' {
        $m = [pscustomobject]@{ version = '0.1.0'; files = @([pscustomobject]@{ name = 'WinCare-0.1.0.zip'; sha256 = $script:Hash }) }
        Test-WcbFileAgainstManifest -FilePath $script:Zip -Manifest $m -Version '0.1.0' | Should -BeNullOrEmpty
    }
    It 'rejects a tampered file, wrong version or missing entry' {
        $bad = [pscustomobject]@{ version = '0.1.0'; files = @([pscustomobject]@{ name = 'WinCare-0.1.0.zip'; sha256 = ('0' * 64) }) }
        Test-WcbFileAgainstManifest -FilePath $script:Zip -Manifest $bad -Version '0.1.0' | Should -Match 'mismatch'
        $ver = [pscustomobject]@{ version = '0.2.0'; files = @() }
        Test-WcbFileAgainstManifest -FilePath $script:Zip -Manifest $ver -Version '0.1.0' | Should -Match 'differs'
        $none = [pscustomobject]@{ version = '0.1.0'; files = @() }
        Test-WcbFileAgainstManifest -FilePath $script:Zip -Manifest $none -Version '0.1.0' | Should -Match 'not listed'
    }
    It 'rejects manifests with invalid hashes or path-like names' {
        $p = Join-Path $script:MDir 'm.json'
        Set-Content -LiteralPath $p -Value ('{"version":"0.1.0","files":[{"name":"../x.zip","sha256":"' + ('A' * 64) + '"}]}')
        { Read-WcbManifest $p } | Should -Throw '*invalid file name*'
        Set-Content -LiteralPath $p -Value '{"version":"0.1.0","files":[{"name":"x.zip","sha256":"abc"}]}'
        { Read-WcbManifest $p } | Should -Throw '*invalid hash*'
    }
}

Describe 'Package authenticity (mocked Authenticode)' {
    BeforeAll {
        $script:Pkg = New-WcTestDir
        New-Item -ItemType Directory -Path (Join-Path $script:Pkg 'src') | Out-Null
        Set-Content -LiteralPath (Join-Path $script:Pkg 'src/Start-WinCare.ps1') -Value '#'
        Set-Content -LiteralPath (Join-Path $script:Pkg 'WinCare.cat') -Value 'cat'
    }
    It 'fails closed when no trusted publisher is configured' {
        $r = Test-WcbPackage -Root $script:Pkg -TrustedThumbprints @()
        $r.Valid | Should -BeFalse
        $r.Errors[0] | Should -Match 'fail closed'
    }
    It 'accepts a package signed by a pinned thumbprint with a valid catalog' {
        Set-SignatureMocks
        (Test-WcbPackage -Root $script:Pkg -TrustedThumbprints @($script:Thumb.ToLowerInvariant())).Valid | Should -BeTrue
    }
    It 'rejects <Case>' -ForEach @(
        @{ Case = 'an unsigned package'; Status = 'NotSigned'; Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'; CatalogStatus = 'Valid'; Extra = $false }
        @{ Case = 'a hash mismatch signature'; Status = 'HashMismatch'; Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'; CatalogStatus = 'Valid'; Extra = $false }
        @{ Case = 'an untrusted signer'; Status = 'Valid'; Thumbprint = '1111111111111111111111111111111111111111'; CatalogStatus = 'Valid'; Extra = $false }
        @{ Case = 'a modified file (catalog)'; Status = 'Valid'; Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'; CatalogStatus = 'ValidationFailed'; Extra = $false }
        @{ Case = 'an extra file not in the catalog'; Status = 'Valid'; Thumbprint = 'AABBCCDDEEFF00112233445566778899AABBCCDD'; CatalogStatus = 'Valid'; Extra = $true }
    ) {
        Set-SignatureMocks -Status $Status -Thumbprint $Thumbprint -CatalogStatus $CatalogStatus -ExtraFile:$Extra
        (Test-WcbPackage -Root $script:Pkg -TrustedThumbprints @($script:Thumb)).Valid | Should -BeFalse
    }
    It 'rejects a package without WinCare.cat' {
        $d = New-WcTestDir
        (Test-WcbPackage -Root $d -TrustedThumbprints @($script:Thumb)).Errors | Should -Contain 'WinCare.cat not found.'
    }
}

Describe 'Offline end-to-end (mocked Authenticode)' {
    BeforeEach {
        $script:E = New-WcTestDir
        $script:Zip = Join-Path $script:E 'WinCare-0.1.0.zip'
        New-TestZip -Path $script:Zip -Entries @{ 'src/Start-WinCare.ps1' = '#'; 'WinCare.cat' = 'cat' }
        $h = (Get-FileHash -LiteralPath $script:Zip -Algorithm SHA256).Hash
        $script:Manifest = Join-Path $script:E 'WinCare-0.1.0.manifest.json'
        Set-Content -LiteralPath $script:Manifest -Value ('{"version":"0.1.0","files":[{"name":"WinCare-0.1.0.zip","sha256":"' + $h + '"}]}')
        $script:Cache = Join-Path $script:E 'cache'
        $script:WcbTrustedThumbprints = @($script:Thumb)
        Mock Start-Process {}
    }
    AfterEach { $script:WcbTrustedThumbprints = @() }
    It 'verifies, caches by version and does not launch with -VerifyOnly' {
        Set-SignatureMocks
        $t = Invoke-WcbMain -Version '0.1.0' -PackagePath $script:Zip -ManifestPath $script:Manifest -CacheRoot $script:Cache -VerifyOnly
        $t | Should -Be (Join-Path $script:Cache '0.1.0')
        Test-Path (Join-Path $t 'src/Start-WinCare.ps1') | Should -BeTrue
        Should -Invoke Start-Process -Times 0 -Exactly
        @(Get-ChildItem -LiteralPath $script:Cache -Force | Where-Object Name -like '.staging-*').Count | Should -Be 0
    }
    It 'rejects a package whose bytes differ from the manifest and caches nothing' {
        Set-SignatureMocks
        Add-Content -LiteralPath $script:Zip -Value 'tamper'
        { Invoke-WcbMain -Version '0.1.0' -PackagePath $script:Zip -ManifestPath $script:Manifest -CacheRoot $script:Cache -VerifyOnly } | Should -Throw '*mismatch*'
        Test-Path (Join-Path $script:Cache '0.1.0') | Should -BeFalse
    }
    It 'rejects -ExpectedSha256 mismatch' {
        Set-SignatureMocks
        { Invoke-WcbMain -Version '0.1.0' -PackagePath $script:Zip -ExpectedSha256 ('F' * 64) -CacheRoot $script:Cache -VerifyOnly } | Should -Throw '*ExpectedSha256*'
    }
    It 'rejects a bad signature and caches nothing' {
        Set-SignatureMocks -Status 'NotSigned'
        { Invoke-WcbMain -Version '0.1.0' -PackagePath $script:Zip -ManifestPath $script:Manifest -CacheRoot $script:Cache -VerifyOnly } | Should -Throw '*rejected*'
        Test-Path (Join-Path $script:Cache '0.1.0') | Should -BeFalse
    }
    It 're-verifies the cached copy and refuses it if tampered' {
        Set-SignatureMocks
        Invoke-WcbMain -Version '0.1.0' -PackagePath $script:Zip -ManifestPath $script:Manifest -CacheRoot $script:Cache -VerifyOnly | Out-Null
        Set-SignatureMocks -CatalogStatus 'ValidationFailed'
        { Invoke-WcbMain -Version '0.1.0' -CacheRoot $script:Cache -VerifyOnly } | Should -Throw '*failed verification*'
    }
}
