#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module (Join-Path $script:RepoRoot 'src/Modules/WinCare.Elevation.psm1') -Force
    . (Join-Path $script:RepoRoot 'bootstrap/Install-WinCare.ps1')
    $script:uri = 'https://github.com/joseook/WinCareEnterprise/releases/download/v0.3.0/install.ps1'
    $script:hash = 'ab' * 32
}

Describe 'Elevation command' {
    It 'is identical to the bootstrapper elevated command' {
        $a = New-WcElevationCommand -Version '0.3.0' -InstallUri $script:uri -InstallSha256 $script:hash
        $b = New-WcbElevatedCommand -Version '0.3.0' -InstallUri $script:uri -InstallSha256 $script:hash
        $a | Should -BeExactly $b
    }
    It 'rejects injection in version, hash and URL' {
        { New-WcElevationCommand -Version "0.3.0';x;'" -InstallUri $script:uri -InstallSha256 $script:hash } | Should -Throw
        { New-WcElevationCommand -Version '0.3.0' -InstallUri $script:uri -InstallSha256 "$('a'*63)'" } | Should -Throw
        { New-WcElevationCommand -Version '0.3.0' -InstallUri "https://github.com/x';calc;'" -InstallSha256 $script:hash } | Should -Throw
        { New-WcbElevatedCommand -Version '0.3.0' -InstallUri "https://github.com/x';calc;'" -InstallSha256 $script:hash } | Should -Throw
        { New-WcElevationCommand -Version '0.3.0' -InstallUri 'https://github.com/a b' -InstallSha256 $script:hash } | Should -Throw
        { New-WcElevationCommand -Version '0.3.0' -InstallUri 'https://example.com/install.ps1' -InstallSha256 $script:hash } | Should -Throw
    }
}

Describe 'Release info' {
    BeforeEach {
        $script:root = Join-Path ([IO.Path]::GetTempPath()) ('wcel-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $script:root 'Core') -Force | Out-Null
    }
    AfterEach { Remove-Item -LiteralPath $script:root -Recurse -Force -ErrorAction SilentlyContinue }
    It 'returns null when running from source' {
        Get-WcReleaseInfo -AppRoot $script:root | Should -BeNullOrEmpty
    }
    It 'reads a valid release.json' {
        @{ version = '0.3.0'; installUri = $script:uri; installSha256 = $script:hash } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:root 'Core/release.json')
        (Get-WcReleaseInfo -AppRoot $script:root).Version | Should -Be '0.3.0'
    }
    It 'rejects a tampered release.json' {
        @{ version = '0.3.0'; installUri = 'https://evil.example/i.ps1'; installSha256 = $script:hash } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:root 'Core/release.json')
        { Get-WcReleaseInfo -AppRoot $script:root } | Should -Throw
    }
    It 'relaunch refuses when not a release' {
        { Start-WcElevatedRelaunch -AppRoot $script:root } | Should -Throw 'not-a-release'
    }
}
