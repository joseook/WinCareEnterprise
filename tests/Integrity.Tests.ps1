#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F3 integrity tools (sfc, DISM, chkdsk). The parser is tested with fixtures; the
# process wrapper is mocked. The only real process started is a fake tool that the
# test writes into its own temp dir (non-Windows hosts only).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @('System', 'Storage', 'Integrity')
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'integrity.jsonl') | Out-Null
    $script:OldRoot = $env:SystemRoot
    $script:OldDrive = $env:SystemDrive
    function ConvertTo-Utf16Bytes([string] $Text) { return [System.Text.Encoding]::Unicode.GetBytes($Text) }
}

AfterAll {
    $env:SystemRoot = $script:OldRoot
    $env:SystemDrive = $script:OldDrive
}

Describe 'Integrity result parser (fixtures, English output)' {
    It '<Name>' -ForEach @(
        @{ Name = 'sfc healthy'; Tool = 'sfc'; Exit = 0; Out = 'Windows Resource Protection did not find any integrity violations.'; Status = 'Healthy'; By = 'Phrase' }
        @{ Name = 'sfc repaired'; Tool = 'sfc'; Exit = 0; Out = 'Windows Resource Protection found corrupt files and successfully repaired them.'; Status = 'Repaired'; By = 'Phrase' }
        @{ Name = 'sfc not fixed'; Tool = 'sfc'; Exit = 0; Out = 'Windows Resource Protection found corrupt files but was unable to fix some of them.'; Status = 'CorruptionFound'; By = 'Phrase' }
        @{ Name = 'sfc verifyonly violations'; Tool = 'sfc'; Exit = 0; Out = 'Windows Resource Protection found integrity violations.'; Status = 'CorruptionFound'; By = 'Phrase' }
        @{ Name = 'sfc repair pending'; Tool = 'sfc'; Exit = 0; Out = 'There is a system repair pending which requires reboot to complete.'; Status = 'Failed'; By = 'Phrase' }
        @{ Name = 'sfc localized pt-BR -> Unknown'; Tool = 'sfc'; Exit = 0; Out = 'A Protecao de Recursos do Windows nao encontrou violacoes de integridade.'; Status = 'Unknown'; By = 'None' }
        @{ Name = 'dism checkhealth healthy'; Tool = 'dism'; Exit = 0; Out = "Image Version: 10.0.22631.1`r`nNo component store corruption detected.`r`nThe operation completed successfully."; Status = 'Healthy'; By = 'Phrase' }
        @{ Name = 'dism scanhealth repairable'; Tool = 'dism'; Exit = 0; Out = 'The component store is repairable.'; Status = 'CorruptionFound'; By = 'Phrase' }
        @{ Name = 'dism restorehealth repaired'; Tool = 'dism'; Exit = 0; Out = "The restore operation completed successfully.`r`nThe component store corruption was repaired."; Status = 'Repaired'; By = 'Phrase' }
        @{ Name = 'dism restorehealth nothing to do'; Tool = 'dism'; Exit = 0; Out = 'The restore operation completed successfully.'; Status = 'Healthy'; By = 'Phrase' }
        @{ Name = 'dism localized exit 0 -> Unknown'; Tool = 'dism'; Exit = 0; Out = 'Nenhuma corrupcao detectada.'; Status = 'Unknown'; By = 'None' }
        @{ Name = 'dism source missing (0x800F081F)'; Tool = 'dism'; Exit = -2146498529; Out = 'Error: 0x800f081f'; Status = 'Failed'; By = 'ExitCode' }
        @{ Name = 'dism invalid parameter'; Tool = 'dism'; Exit = 87; Out = 'Error: 87'; Status = 'Failed'; By = 'ExitCode' }
        @{ Name = 'any tool elevation 740'; Tool = 'sfc'; Exit = 740; Out = ''; Status = 'Failed'; By = 'ExitCode' }
        @{ Name = 'chkdsk exit 0'; Tool = 'chkdsk'; Exit = 0; Out = 'Windows has scanned the file system and found no problems.'; Status = 'Healthy'; By = 'ExitCode' }
        @{ Name = 'chkdsk exit 1'; Tool = 'chkdsk'; Exit = 1; Out = ''; Status = 'Repaired'; By = 'ExitCode' }
        @{ Name = 'chkdsk exit 3 problems'; Tool = 'chkdsk'; Exit = 3; Out = 'Windows has scanned the file system and found problems.'; Status = 'CorruptionFound'; By = 'Phrase' }
        @{ Name = 'chkdsk exit 3 localized -> Unknown'; Tool = 'chkdsk'; Exit = 3; Out = 'O Windows encontrou problemas.'; Status = 'Unknown'; By = 'None' }
        @{ Name = 'no exit code -> Failed'; Tool = 'dism'; Exit = $null; Out = ''; Status = 'Failed'; By = 'ExitCode' }
    ) {
        $r = ConvertTo-WcIntegrityResult -Tool $Tool -ExitCode $Exit -Output $Out
        $r.Status | Should -Be $Status
        $r.MatchedBy | Should -Be $By
        $r.Detail | Should -Not -BeNullOrEmpty
    }
    It 'names the DISM HRESULT in hex' {
        (ConvertTo-WcIntegrityResult -Tool dism -ExitCode -2146498529).Detail | Should -Match '0x800F081F'
        (ConvertTo-WcIntegrityResult -Tool dism -ExitCode -2146498529).Detail | Should -Match 'source files could not be found'
    }
}

Describe 'Output decoding' {
    It 'detects UTF-16LE by NUL ratio and by BOM, otherwise OEM' {
        (Get-WcOutputEncoding -Sample (ConvertTo-Utf16Bytes 'Beginning system scan.')).WebName | Should -Be 'utf-16'
        (Get-WcOutputEncoding -Sample ([byte[]](0xFF, 0xFE, 0x41, 0x00))).WebName | Should -Be 'utf-16'
        (Get-WcOutputEncoding -Sample ([System.Text.Encoding]::ASCII.GetBytes('Deployment Image Servicing'))).WebName | Should -Not -Be 'utf-16'
    }
    It 'decodes UTF-16 split across chunks at an odd byte and splits CR progress lines' {
        $bytes = ConvertTo-Utf16Bytes "Beginning verification phase of system scan.`r`nVerification 5% complete.`rVerification 7% complete.`rVerification 12% complete.`r`nWindows Resource Protection did not find any integrity violations.`r`n"
        $state = New-WcOutputState
        $lines = @()
        $cut = 33
        $a = New-Object byte[] $cut; [Array]::Copy($bytes, 0, $a, 0, $cut)
        $b = New-Object byte[] ($bytes.Length - $cut); [Array]::Copy($bytes, $cut, $b, 0, $b.Length)
        $lines += Add-WcOutputBytes -State $state -Buffer $a -Count $a.Length
        $lines += Add-WcOutputBytes -State $state -Buffer $b -Count $b.Length
        $lines += Add-WcOutputText -State $state -Text '' -Final
        $lines | Should -Be @('Beginning verification phase of system scan.', 'Verification 5% complete.', 'Verification 12% complete.', 'Windows Resource Protection did not find any integrity violations.')
        ($state.Lines -join "`n") | Should -Not -Match ([string][char]0)
    }
    It 'throttles DISM progress bars to 10% steps' {
        $state = New-WcOutputState -Encoding Oem
        $t = "[=                          2.0%                           ]`r[==                         4.0%                           ]`r[=====                     10.0%                           ]`r`nThe operation completed successfully.`r`n"
        $lines = @(Add-WcOutputText -State $state -Text $t)
        $lines.Count | Should -Be 3
        $lines[2] | Should -Be 'The operation completed successfully.'
    }
}

Describe 'Command construction' {
    BeforeEach { $env:SystemRoot = 'C:\Windows'; $env:SystemDrive = 'C:' }
    It '<Id> -> <Cmd>' -ForEach @(
        @{ Id = 'integrity.sfc-verify'; Exe = 'sfc.exe'; Cmd = '/verifyonly' }
        @{ Id = 'integrity.sfc-scannow'; Exe = 'sfc.exe'; Cmd = '/scannow' }
        @{ Id = 'integrity.dism-checkhealth'; Exe = 'Dism.exe'; Cmd = '/Online /Cleanup-Image /CheckHealth' }
        @{ Id = 'integrity.dism-scanhealth'; Exe = 'Dism.exe'; Cmd = '/Online /Cleanup-Image /ScanHealth' }
        @{ Id = 'integrity.dism-restorehealth'; Exe = 'Dism.exe'; Cmd = '/Online /Cleanup-Image /RestoreHealth' }
        @{ Id = 'integrity.chkdsk-scan'; Exe = 'chkdsk.exe'; Cmd = 'C: /scan' }
    ) {
        $c = Get-WcIntegrityCommand -Id $Id
        ($c.Arguments -join ' ') | Should -Be $Cmd
        [System.IO.Path]::GetFileName($c.FilePath) | Should -Be $Exe
        Test-WcPathWithin -Path $c.FilePath -AllowedRoots @([System.IO.Path]::Combine('C:\Windows', 'System32'), [System.IO.Path]::Combine('C:\Windows', 'Sysnative')) | Should -BeTrue
        $c.CommandLine | Should -BeLike "*$Exe $Cmd"
    }
    It 'rejects unknown ids and an invalid system drive' {
        { Get-WcIntegrityCommand -Id 'integrity.format-c' } | Should -Throw '*Unknown*'
        $env:SystemDrive = 'C: /f /x'
        { Get-WcIntegrityCommand -Id 'integrity.chkdsk-scan' } | Should -Throw '*Invalid system drive*'
    }
}

Describe 'Native command wrapper guards' {
    BeforeEach { $env:SystemRoot = $script:Tmp }
    It 'refuses executables outside System32' {
        { Invoke-WcNativeCommand -FilePath (Join-Path $script:Tmp 'evil.exe') } | Should -Throw '*only absolute paths*'
        { Invoke-WcNativeCommand -FilePath 'sfc.exe' } | Should -Throw '*only absolute paths*'
        { Invoke-WcNativeCommand -FilePath ([System.IO.Path]::Combine($script:Tmp, 'System32', '..', 'evil.exe')) } | Should -Throw '*only absolute paths*'
    }
    It 'refuses free-text arguments' {
        $exe = [System.IO.Path]::Combine($script:Tmp, 'System32', 'sfc.exe')
        { Invoke-WcNativeCommand -FilePath $exe -ArgumentList @('/scannow & del x') } | Should -Throw '*Refusing argument*'
        { Invoke-WcNativeCommand -FilePath $exe -ArgumentList @('"/a"') } | Should -Throw '*Refusing argument*'
    }
    It 'runs a fake UTF-16 tool, streams lines to the log and returns the exit code' -Skip:([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT) {
        $sys = Join-Path $script:Tmp 'System32'
        New-Item -ItemType Directory -Path $sys -Force | Out-Null
        $data = Join-Path $script:Tmp 'out.bin'
        [System.IO.File]::WriteAllBytes($data, (ConvertTo-Utf16Bytes "Verification 100% complete.`r`nWindows Resource Protection did not find any integrity violations.`r`n"))
        $exe = Join-Path $sys 'fake.exe'
        [System.IO.File]::WriteAllText($exe, "#!/bin/sh`ncat '$data'`necho oops 1>&2`nexit 3`n")
        & chmod +x $exe
        $r = Invoke-WcNativeCommand -FilePath $exe -ArgumentList @('/verifyonly') -LogCategory 'IntegrityTest'
        $r.ExitCode | Should -Be 3
        $r.Encoding | Should -Be 'utf-16'
        $r.StdOut | Should -Match 'did not find any integrity violations'
        $r.StdErr | Should -Be 'oops'
        @(Read-WcLog | Where-Object { $_.category -eq 'IntegrityTest' -and $_.message -like '*integrity violations*' }).Count | Should -Be 1
    }
}

Describe 'Integrity actions (Preview / Execute)' {
    BeforeEach {
        $env:SystemRoot = 'C:\Windows'; $env:SystemDrive = 'C:'
        Mock -ModuleName WinCare.Integrity Test-WcIsAdmin { $true }
        Mock -ModuleName WinCare.Integrity Invoke-WcNativeCommand { [pscustomobject]@{ ExitCode = 0; StdOut = 'No component store corruption detected.'; StdErr = ''; Encoding = 'ibm437' } }
    }
    It 'Preview returns the exact command, admin requirement and unknown duration without running anything' {
        $r = Invoke-WcIntegrityAction -Id 'integrity.dism-restorehealth'
        $r.Summary | Should -BeLike '*Dism.exe /Online /Cleanup-Image /RestoreHealth*'
        $r.Items[0].RequiresAdmin | Should -BeTrue
        $r.Items[0].Duration | Should -Be 'unknown/varies'
        $r.Items[0].Modifies | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Integrity Invoke-WcNativeCommand -Times 0 -Exactly
    }
    It 'Execute runs the fixed command and parses the result' {
        $r = Invoke-WcIntegrityAction -Id 'integrity.dism-checkhealth' -Execute
        $r.Items[0].Status | Should -Be 'Healthy'
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'No component store corruption'
        Should -Invoke -ModuleName WinCare.Integrity Invoke-WcNativeCommand -Times 1 -Exactly -ParameterFilter {
            [System.IO.Path]::GetFileName($FilePath) -eq 'Dism.exe' -and ($ArgumentList -join ' ') -eq '/Online /Cleanup-Image /CheckHealth'
        }
    }
    It 'Execute throws when the tool failed so the plan marks it Failed' {
        Mock -ModuleName WinCare.Integrity Invoke-WcNativeCommand { [pscustomobject]@{ ExitCode = 740; StdOut = ''; StdErr = ''; Encoding = $null } }
        { Invoke-WcIntegrityAction -Id 'integrity.sfc-scannow' -Execute } | Should -Throw '*Elevation required*'
    }
    It 'Execute refuses without administrator rights and runs nothing' {
        Mock -ModuleName WinCare.Integrity Test-WcIsAdmin { $false }
        { Invoke-WcIntegrityAction -Id 'integrity.sfc-verify' -Execute } | Should -Throw '*administrator*'
        Should -Invoke -ModuleName WinCare.Integrity Invoke-WcNativeCommand -Times 0 -Exactly
    }
}
