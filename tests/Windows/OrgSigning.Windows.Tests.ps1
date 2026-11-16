#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Real Authenticode on Windows: signs a copy of src with a throwaway code-signing
# certificate (trusted only for the duration of the test) and proves that a
# process with execution policy AllSigned loads the signed copy and rejects the
# unsigned one. Needs administrator (LocalMachine trust stores, no UI prompts).

BeforeDiscovery {
    $script:IsWin = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($IsWindows -eq $true)
    $script:IsAdmin = $false
    if ($script:IsWin) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $script:IsAdmin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

Describe 'Organization signing (AllSigned)' -Tag 'Windows' -Skip:(-not ($script:IsWin -and $script:IsAdmin)) {
    BeforeAll {
        $repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        . (Join-Path $repo 'scripts\Protect-WinCareWithOrgCertificate.ps1')
        $script:work = Join-Path ([IO.Path]::GetTempPath()) ('wc-orgsign-' + [guid]::NewGuid().ToString('N'))
        $script:signed = Join-Path $script:work 'signed'
        $script:unsigned = Join-Path $script:work 'unsigned'
        New-Item -ItemType Directory -Path $script:work | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'src') -Destination (Join-Path $script:signed 'src') -Recurse
        Copy-Item -LiteralPath (Join-Path $repo 'src') -Destination (Join-Path $script:unsigned 'src') -Recurse
        $script:cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=WinCare CI Org Test' -CertStoreLocation 'Cert:\CurrentUser\My' -KeyAlgorithm RSA -KeyLength 3072 -NotAfter (Get-Date).AddDays(1)
        $script:stores = @()
        foreach ($name in 'Root', 'TrustedPublisher') {
            $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
            $st.Open('ReadWrite'); $st.Add($script:cert); $st.Close()
            $script:stores += $name
        }
        $script:result = Protect-WcFolderWithCertificate -Root $script:signed -Certificate $script:cert
        $script:ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    AfterAll {
        foreach ($name in $script:stores) {
            $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($name, 'LocalMachine')
            $st.Open('ReadWrite'); $st.Remove($script:cert); $st.Close()
        }
        if ($script:cert) { Remove-Item -LiteralPath ('Cert:\CurrentUser\My\' + $script:cert.Thumbprint) -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue
    }
    It 'signs every script and the catalog with no problems' {
        @($script:result.Problems).Count | Should -Be 0 -Because ($script:result.Problems -join '; ')
        $script:result.ScriptCount | Should -BeGreaterThan 10
        (Get-AuthenticodeSignature (Join-Path $script:signed 'src\WinCare.psd1')).Status | Should -Be 'Valid'
        (Get-AuthenticodeSignature (Join-Path $script:signed 'WinCare.FileHashes.ps1')).Status | Should -Be 'Valid'
        @(Test-WcOrgFileHashes -Root $script:signed).Count | Should -Be 0
    }
    It 'AllSigned process loads the signed copy' {
        $m = Join-Path $script:signed 'src\WinCare.psd1'
        $out = & $script:ps -NoProfile -NonInteractive -ExecutionPolicy AllSigned -Command "Import-Module '$m' -DisableNameChecking; (Get-Command Invoke-WcDiagnostic).Name" 2>&1
        ($out -join "`n") | Should -Match 'Invoke-WcDiagnostic'
    }
    It 'AllSigned process rejects the unsigned copy' {
        $m = Join-Path $script:unsigned 'src\WinCare.psd1'
        $out = & $script:ps -NoProfile -NonInteractive -ExecutionPolicy AllSigned -Command "try { Import-Module '$m' -DisableNameChecking -ErrorAction Stop; 'LOADED' } catch { 'BLOCKED: ' + `$_.Exception.Message }" 2>&1
        ($out -join "`n") | Should -Match 'BLOCKED'
    }
    It 'hash list detects a modified non-script file and an extra file' {
        Add-Content -LiteralPath (Join-Path $script:signed 'src\Core\actions.json') -Value ' '
        Set-Content -LiteralPath (Join-Path $script:signed 'src\extra.txt') -Value 'x'
        $p = @(Test-WcOrgFileHashes -Root $script:signed)
        ($p -join ';') | Should -Match 'Modified file: src/Core/actions.json'
        ($p -join ';') | Should -Match 'Extra file: src/extra.txt'
    }
}
