#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F6 pages 'apps' and 'network' on a REAL Windows machine (GitHub windows-latest runner =
# Windows Server, where winget and some Appx cmdlets may be missing). Read-only queries run
# for real. The ONLY real modifying action allowed here is network.flush-dns.
# winget upgrade, Store reset, ipconfig /renew and netsh winsock reset are mocked to fail
# the test if they are ever reached; their handlers are exercised through Preview only.
# Excluded automatically on non-Windows hosts (tag 'Windows').

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.ps1')
    Import-Module (Join-Path $script:SrcRoot 'WinCare.psd1') -Force -DisableNameChecking
    Import-WcTestModules -Name @('System', 'Integrity', 'Apps', 'Network')
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'f6win.jsonl') | Out-Null
    $script:Strings = Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR'
    $script:EnStrings = Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'en-US'
    function Assert-PageShape($Data, [string] $PageId) {
        $Data.PageId | Should -Be $PageId
        foreach ($s in @($Data.Sections)) {
            $script:Strings.ContainsKey($s.TitleKey) | Should -BeTrue -Because $s.TitleKey
            if ($s.NoteKey) { $script:Strings.ContainsKey($s.NoteKey) | Should -BeTrue -Because $s.NoteKey; $script:EnStrings.ContainsKey($s.NoteKey) | Should -BeTrue }
            foreach ($r in @($s.Rows)) {
                foreach ($p in $r.PSObject.Properties.Name) { $script:Strings.ContainsKey("col.$p") | Should -BeTrue -Because "col.$p" }
            }
        }
    }
}

Describe 'F6 apps page on real Windows (read-only)' -Tag 'Windows' {
    BeforeEach {
        Mock -ModuleName WinCare.Apps Invoke-WcWinget -ParameterFilter { $ArgumentList -contains '--id' -or $ArgumentList -contains '--all' } { throw 'winget upgrade must not run in CI' }
        Mock -ModuleName WinCare.Apps Invoke-WcAppxReset { throw 'Reset-AppxPackage must not run in CI' }
        Mock -ModuleName WinCare.Apps Open-WcAppsSettings { throw 'Settings must not open in CI' }
    }
    It 'collects the page without throwing and with translated sections/columns' {
        $d = Get-WcAppsPageData
        @($d.Sections.Id) | Should -Be @('installed', 'broken-uninstall', 'winget-updates', 'store-problems')
        Assert-PageShape $d 'apps'
        # Only the Appx section may fail (Appx module limits on PowerShell 7 / Server); report it, never throw.
        foreach ($e in @($d.Errors)) { $e | Should -Match '^store-problems: ' }
        @(($d.Sections | Where-Object Id -eq 'installed').Rows).Count | Should -BeGreaterThan 0
    }
    It 'installed rows never contain uninstall arguments' {
        $rows = @(ConvertTo-WcInstalledProgram -Entry (Get-WcUninstallEntry) -PathExists { param($p) [System.IO.File]::Exists($p) })
        foreach ($r in $rows) { $r.Executable | Should -Not -Match '\s/[A-Za-z]' }
    }
    It 'winget is either listed or explained (absent on many Windows Server runners)' {
        $cap = Get-WcWingetCapability
        $s = (Get-WcAppsPageData).Sections | Where-Object Id -eq 'winget-updates'
        if (-not $cap.Available) {
            $cap.Reason | Should -BeIn @('not-found', 'system-context')
            $s.NoteKey | Should -Be ('section.apps.winget-updates.note.' + $cap.Reason)
        }
        else {
            $s.NoteKey | Should -BeIn @('section.apps.winget-updates.note', 'section.apps.winget-updates.note.none', 'section.apps.winget-updates.note.partial', 'section.apps.winget-updates.note.failed')
        }
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 0 -ParameterFilter { $ArgumentList -contains '--id' -or $ArgumentList -contains '--all' }
    }
    It 'reports whether Reset-AppxPackage exists without calling it' {
        { Test-WcAppxResetAvailable } | Should -Not -Throw
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcAppxReset -Times 0
    }
    It 'previews every apps action through the plan engine (dry run) without side effects' {
        $frag = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Core/actions.d/f6-apps.json')
        $ctx = New-WcContext -IsAdmin (Test-WcIsAdmin) -IsWindows $true -Build ([System.Environment]::OSVersion.Version.Build)
        $ctx.Selection = @{ 'apps.winget-upgrade' = @('Microsoft.Edge'); 'apps.store-reset' = @('Microsoft.WindowsCalculator_11.2210.0.0_x64__8wekyb3d8bbwe'); 'apps.open-repair' = @('Calculator') }
        $plan = New-WcPlan -Catalog @($frag.actions) -ActionId @($frag.actions | ForEach-Object { $_.Id }) -OperationProfile (Get-WcProfile 'Avancado') -Context $ctx
        $res = @(Invoke-WcPlan -Plan $plan -Context $ctx -DryRun)
        foreach ($r in $res) {
            if ($r.Status -eq 'Blocked') { continue }   # e.g. MinBuild on an older Server image
            $r.Status | Should -Be 'Previewed' -Because ($r.ActionId + ' ' + $r.Error)
        }
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 0
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcAppxReset -Times 0
        Should -Invoke -ModuleName WinCare.Apps Open-WcAppsSettings -Times 0
    }
}

Describe 'F6 network page on real Windows' -Tag 'Windows' {
    BeforeEach {
        Mock -ModuleName WinCare.Network Invoke-WcNativeCommand -ParameterFilter { $ArgumentList -contains '/renew' -or $ArgumentList -contains '/release' -or $ArgumentList -contains 'winsock' } { throw 'renew/winsock must not run in CI' }
        Mock -ModuleName WinCare.Network Restart-Computer { throw 'must never restart' }
    }
    It 'collects the page without throwing and with translated sections/columns' {
        $d = Get-WcNetworkPageData
        @($d.Sections.Id) | Should -Be @('adapters', 'connectivity', 'proxy', 'vpn')
        Assert-PageShape $d 'network'
        @($d.Errors | Where-Object { $_ -match '^(adapters|proxy|connectivity): ' }).Count | Should -Be 0 -Because (@($d.Errors) -join '; ')
        @(($d.Sections | Where-Object Id -eq 'adapters').Rows).Count | Should -BeGreaterThan 0
    }
    It 'runs the four connectivity checks with OK/Fail/Skipped results' {
        $rows = @(Get-WcConnectivityCheck -AdapterRecord @(Get-WcNetAdapterRecord))
        @($rows.Check) | Should -Be @('Gateway', 'DNS', 'HTTP', 'HTTPS')
        foreach ($r in $rows) { $r.Status | Should -BeIn @('OK', 'Fail', 'Skipped') }
        # The runner has internet access: DNS and HTTPS are expected to work there.
        $why = ($rows | ForEach-Object { '{0}={1} ({2})' -f $_.Check, $_.Status, $_.Detail }) -join '; '
        ($rows | Where-Object Check -eq 'DNS').Status | Should -Be 'OK' -Because $why
        ($rows | Where-Object Check -eq 'HTTPS').Status | Should -Be 'OK' -Because $why
    }
    It 'parses the real (possibly localized) netsh winhttp output' {
        $rows = @(Get-WcProxyInfo)
        $mode = ($rows | Where-Object { $_.Source -eq 'WinHTTP' -and $_.Item -eq 'Mode' }).Value
        $mode | Should -BeIn @('Direct', 'Proxy')
    }
    It 'previews renew-ip and reset-winsock without running them' {
        (Invoke-WcNetworkAction -Id 'network.renew-ip').Summary | Should -Match 'ipconfig\.exe /renew'
        (Invoke-WcNetworkAction -Id 'network.reset-winsock').Summary | Should -Match 'netsh\.exe winsock reset'
        Test-Path -LiteralPath (Get-WcNetworkCommand -Id 'network.reset-winsock').FilePath | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 0
    }
    It 'executes network.flush-dns for real through the plan engine (the only real modifying action in CI)' {
        $frag = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Core/actions.d/f6-network.json')
        $ctx = New-WcContext -IsAdmin (Test-WcIsAdmin) -IsWindows $true -Build ([System.Environment]::OSVersion.Version.Build)
        $plan = New-WcPlan -Catalog @($frag.actions) -ActionId @('network.flush-dns') -OperationProfile (Get-WcProfile 'Conservador') -Context $ctx
        $plan.Items[0].Allowed | Should -BeTrue
        $res = @(Invoke-WcPlan -Plan $plan -Context $ctx -ConfirmCallback { param($i) $i.ActionId -eq 'network.flush-dns' } -Measure Modifying)
        $res[0].Status | Should -Be 'Succeeded' -Because $res[0].Error
        $res[0].Output.Summary | Should -Match 'DNS|flushdns'
        Should -Invoke -ModuleName WinCare.Network Restart-Computer -Times 0
    }
}
