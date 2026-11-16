#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F6 'processes' page on a REAL Windows machine (real Get-Process / CIM / Authenticode).
# The ONLY process this file ends is a 'ping -t' child it starts itself. Close/Stop of any
# other PID is mocked to fail the test. MdSched.exe is never opened (it is interactive).
# Excluded automatically on non-Windows hosts (tag 'Windows').

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.ps1')
    Import-Module (Join-Path $script:SrcRoot 'WinCare.psd1') -Force -DisableNameChecking
    # Import directly so Mock -ModuleName targets it.
    foreach ($n in 'System', 'Processes') { Import-Module (Join-Path $script:SrcRoot "Modules/WinCare.$n.psm1") -Force -Global -DisableNameChecking }
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'processeswin.jsonl') | Out-Null
    $script:Child = $null
}

AfterAll {
    # Safety net: only the child this file started.
    if ($script:Child -and -not $script:Child.HasExited) { $script:Child.Kill() }
}

Describe 'Processes page on real Windows' -Tag 'Windows' {
    BeforeAll {
        $script:Page = Get-WcProcessesPageData -SampleCount 2 -SampleIntervalSeconds 1 -SignatureCheckCount 10
        $script:Sec = @{}
        foreach ($s in $script:Page.Sections) { $script:Sec[$s.Id] = $s }
    }
    It 'returns every section' {
        @($script:Page.Sections | ForEach-Object { $_.Id }) | Should -Be @('memory-overview', 'top-memory', 'growth', 'review', 'cpu-now', 'no-ram-cleaner')
        Write-Host ('Page errors: ' + ($script:Page.Errors -join ' | '))
    }
    It 'reads real memory figures' {
        $rows = @($script:Sec['memory-overview'].Rows)
        ($rows | Where-Object { $_.Metric -like 'Installed*' -or $_.Metric -like 'Mem*instalada*' } | Select-Object -First 1).Value | Should -Not -Be '-'
        ($rows | Where-Object { $_.ProcStatusRaw -ne 'Unknown' }).Count | Should -BeGreaterThan 2
    }
    It 'lists top processes with PID and working set, and never a command line' {
        $rows = @($script:Sec['top-memory'].Rows)
        $rows.Count | Should -BeGreaterThan 3
        $rows[0].ProcWorkingSetRaw | Should -BeGreaterThan 0
        ($script:Page | ConvertTo-Json -Depth 6) | Should -Not -Match '"CommandLine"'
    }
    It 'maps svchost to its services' {
        $svc = @($script:Sec['top-memory'].Rows | Where-Object { $_.Name -eq 'svchost' -and $_.ProcServices })
        if (@($script:Sec['top-memory'].Rows | Where-Object { $_.Name -eq 'svchost' }).Count -eq 0) { Set-ItResult -Inconclusive -Because 'no svchost in the top list'; return }
        $svc.Count | Should -BeGreaterThan 0
    }
    It 'reports a valid Authenticode signature for an in-box binary (cached on second call)' {
        $p = Join-Path $env:SystemRoot 'System32\notepad.exe'
        if (-not (Test-Path -LiteralPath $p)) { $p = Join-Path $env:SystemRoot 'System32\cmd.exe' }
        Clear-WcSignatureCache
        $a = Get-WcFileSignature -Path $p
        $a.Status | Should -Be 'Valid'
        $b = Get-WcFileSignature -Path $p
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
    }
    It 'previews the memory diagnostic without opening it' {
        Mock -ModuleName WinCare.Processes Start-WcMdSched { throw 'MdSched must not be opened by tests' }
        $r = Invoke-WcMemoryDiagnostic
        $r.Summary | Should -Match 'MdSched\.exe'
        if (-not (Test-Path -LiteralPath (Get-WcMdSchedPath))) { Set-ItResult -Inconclusive -Because 'MdSched.exe not present on this SKU' }
    }
}

Describe 'process.end on real Windows (own child only)' -Tag 'Windows' {
    BeforeAll {
        $ping = Join-Path $env:SystemRoot 'System32\PING.EXE'
        $script:Child = Start-Process -FilePath $ping -ArgumentList @('-t', '127.0.0.1') -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 800
        $script:ChildId = $script:Child.Id
    }
    BeforeEach {
        Mock -ModuleName WinCare.Processes Invoke-WcProcessClose { throw "Close of PID $ProcessId is not allowed in tests" } -ParameterFilter { $ProcessId -ne $script:ChildId }
        Mock -ModuleName WinCare.Processes Invoke-WcProcessStop { throw "Stop of PID $ProcessId is not allowed in tests" } -ParameterFilter { $ProcessId -ne $script:ChildId }
    }
    It 'refuses System (PID 4) and lsass in preview and on execute' {
        $ctx = Set-WcProcessEndRequest -Context (New-WcContext -IsAdmin (Test-WcIsAdmin) -Build 26100) -ProcessId 4 -ProcessName 'System' -Force
        (Invoke-WcProcessEnd -Context $ctx).Summary | Should -Match '^Would refuse'
        { Invoke-WcProcessEnd -Context $ctx -Execute } | Should -Throw '*refused*'
        $lsass = Get-Process -Name lsass -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($lsass) {
            Set-WcProcessEndRequest -Context $ctx -ProcessId $lsass.Id -ProcessName 'lsass' -Force | Out-Null
            $r = Invoke-WcProcessEnd -Context $ctx
            $r.Refused | Should -Contain 'critical-name'
            (Get-Process -Id $lsass.Id -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty
        }
    }
    It 'previews the child with its memory and owner' {
        $ctx = Set-WcProcessEndRequest -Context (New-WcContext -Build 26100) -ProcessId $script:ChildId -ProcessName 'PING'
        $r = Invoke-WcProcessEnd -Context $ctx
        $r.Summary | Should -Match ('^Would ask PING \(PID {0}\)' -f $script:ChildId)
        $r.Items[0].User | Should -Not -BeNullOrEmpty
        $script:Child.HasExited | Should -BeFalse
    }
    It 'ends the child through the plan: graceful first, Stop-Process only with Force' {
        $cat = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        $ctx = Set-WcProcessEndRequest -Context (New-WcContext -IsAdmin (Test-WcIsAdmin) -Build 26100) -ProcessId $script:ChildId -ProcessName 'PING'
        $plan = New-WcPlan -Catalog $cat -ActionId @('process.end') -OperationProfile (Get-WcProfile 'Avancado') -Context $ctx
        $plan.Items[0].Allowed | Should -BeTrue -Because (@($plan.Items[0].Reasons) -join ',')
        $first = @(Invoke-WcPlan -Plan $plan -Context $ctx -ConfirmCallback { param($i) $true } -Measure Modifying -RestorePointPolicy Off)
        if ($first[0].Status -eq 'Succeeded') {
            # A hidden console may still accept WM_CLOSE: then it closed gracefully.
            $script:Child.WaitForExit(5000) | Should -BeTrue
            return
        }
        $first[0].Status | Should -Be 'Failed'
        $first[0].Error | Should -Match 'not forced'
        $script:Child.HasExited | Should -BeFalse
        Set-WcProcessEndRequest -Context $ctx -ProcessId $script:ChildId -ProcessName 'PING' -Force | Out-Null
        $second = @(Invoke-WcPlan -Plan $plan -Context $ctx -ConfirmCallback { param($i) $true } -Measure Modifying -RestorePointPolicy Off)
        $second[0].Status | Should -Be 'Succeeded' -Because $second[0].Error
        $second[0].Output.Items[0].Status | Should -Be 'Forced'
        $script:Child.WaitForExit(5000) | Should -BeTrue
        $running = @($second[0].Comparison.Rows | Where-Object { $_.Name -eq 'ProcessRunning' })
        if ($running.Count -gt 0) { $running[0].After | Should -Be 0 }
    }
}
