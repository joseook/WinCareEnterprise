#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F3 checks on a REAL Windows machine. READ-ONLY: only Preview paths run; every
# destructive primitive is mocked to fail the test if it is ever reached.
# Excluded automatically on non-Windows hosts (tag 'Windows').

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.ps1')
    Import-Module (Join-Path $script:SrcRoot 'WinCare.psd1') -Force -DisableNameChecking
    # Import the F3 modules directly so Mock -ModuleName targets them (works before and after the manifest lists them).
    foreach ($n in 'Cleanup', 'Integrity') { Import-Module (Join-Path $script:SrcRoot "Modules/WinCare.$n.psm1") -Force -Global -DisableNameChecking }
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'f3win.jsonl') | Out-Null
}

Describe 'F3 on real Windows (read-only)' -Tag 'Windows' {
    BeforeEach {
        Mock -ModuleName WinCare.Cleanup Remove-WcTempFile { throw 'Remove-WcTempFile must not run in read-only tests' }
        Mock -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume { throw 'Optimize-Volume must not run in read-only tests' }
        Mock -ModuleName WinCare.Integrity Invoke-WcNativeCommand { throw 'Native tools must not run in read-only tests' }
    }
    It 'in-box tools exist at the resolved System32 paths' {
        foreach ($id in 'integrity.sfc-verify', 'integrity.dism-checkhealth', 'integrity.chkdsk-scan') {
            $c = Get-WcIntegrityCommand -Id $id
            Test-Path -LiteralPath $c.FilePath -PathType Leaf | Should -BeTrue -Because $c.FilePath
        }
    }
    It 'previews user temp cleanup on the real %TEMP% without deleting' {
        $r = Invoke-WcTempCleanup -Scope User
        $r.Summary | Should -Match '^Would delete'
        $r.BytesBefore | Should -BeGreaterOrEqual 0
    }
    It 'previews ReTrim according to the real system media type' {
        $media = (Get-WcSystemVolumeMedia).MediaType
        $r = Invoke-WcOptimizeAction -Mode ReTrim
        if ($media -eq 'SSD') { $r.Summary | Should -Match '^Would run' } else { $r.Summary | Should -Match '^Would refuse' }
    }
    It 'previews every integrity action with its exact command line' {
        foreach ($id in 'integrity.sfc-verify', 'integrity.sfc-scannow', 'integrity.dism-checkhealth', 'integrity.dism-scanhealth', 'integrity.dism-restorehealth', 'integrity.chkdsk-scan') {
            (Invoke-WcIntegrityAction -Id $id).Summary | Should -Match '^Would run: .+(System32|Sysnative)'
        }
    }
}
