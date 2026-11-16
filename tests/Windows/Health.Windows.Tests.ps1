#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F6 'health' page on a REAL Windows machine (GitHub windows-latest = Windows Server:
# no battery, some event sources may be missing). Asserts shape and no-throw only.
# Read-only: powercfg, perfmon and the export are mocked to fail if ever reached.
# Excluded automatically on non-Windows hosts (tag 'Windows').

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.ps1')
    Import-Module (Join-Path $script:SrcRoot 'WinCare.psd1') -Force -DisableNameChecking
    Import-Module (Join-Path $script:SrcRoot 'Modules/WinCare.Health.psm1') -Force -Global -DisableNameChecking
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'healthwin.jsonl') | Out-Null
}

Describe 'Health page on real Windows (read-only)' -Tag 'Windows' {
    BeforeEach {
        Mock -ModuleName WinCare.Health Invoke-WcHealthTool { throw 'powercfg must not run in read-only tests' }
        Mock -ModuleName WinCare.Health Start-WcHealthReliabilityMonitor { throw 'perfmon must not open in read-only tests' }
    }
    It 'Get-WcHealthPageData returns every section without throwing' {
        $d = $null
        { $script:Page = Get-WcHealthPageData -Context (New-WcContext -IsAdmin (Test-WcIsAdmin)) } | Should -Not -Throw
        $d = $script:Page
        $d.PageId | Should -Be 'health'
        @($d.Sections.Id) | Should -Be @('critical-events', 'app-crashes', 'devices', 'disks', 'startup-tasks', 'startup-services', 'battery', 'updates', 'time-uptime')
        foreach ($s in $d.Sections) {
            $s.TitleKey | Should -Be ('section.health.' + $s.Id)
            @('Info', 'Warning', 'Critical') | Should -Contain $s.Severity
            foreach ($r in @($s.Rows)) { $r | Should -BeOfType [pscustomobject] }
        }
        Write-Host ('Health errors: ' + (@($d.Errors) -join ' | '))
    }
    It 'real queries work on this host: events, devices, disks, tasks, services, update and time' {
        { Get-WcHealthEventData -Days 7 } | Should -Not -Throw
        { Get-WcHealthDevice } | Should -Not -Throw
        @(Get-WcHealthDiskRaw).Count | Should -BeGreaterThan 0
        @(Get-WcHealthScheduledTaskRaw).Count | Should -BeGreaterThan 0
        { Get-WcHealthStartupService } | Should -Not -Throw
        (Get-WcHealthUpdate).Rows.Count | Should -Be 6
        (Get-WcHealthTime).UptimeDays | Should -Not -BeNullOrEmpty
    }
    It 'event rows never carry message text' {
        $e = Get-WcHealthEventData -Days 7
        foreach ($r in @($e.Rows) + @($e.CrashRows)) { $r.PSObject.Properties.Name | Should -Not -Contain 'Message' }
    }
    It 'battery section is consistent with Win32_Battery' {
        $b = Get-WcHealthBattery
        $hasW32 = @(Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
        $b.HasBattery | Should -Be $hasW32
    }
    It 'Microsoft task paths are excluded by default' {
        $sel = @(Select-WcHealthStartupTask -Task @(Get-WcHealthScheduledTaskRaw))
        @($sel | Where-Object { $_.TaskPath -like '\Microsoft\*' }).Count | Should -Be 0
    }
    It 'previews power reports with the System32 powercfg path and runs nothing' {
        (Invoke-WcHealthPowerReport -Kind Battery).Summary | Should -Match '^Would run: .+(System32|Sysnative)\\powercfg\.exe /batteryreport'
        (Invoke-WcHealthPowerReport -Kind Energy).Summary | Should -Match '/energy /output'
        Test-Path -LiteralPath (Get-WcHealthToolPath -Name 'powercfg.exe') -PathType Leaf | Should -BeTrue
        Test-Path -LiteralPath (Get-WcHealthToolPath -Name 'perfmon.exe') -PathType Leaf | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Health Invoke-WcHealthTool -Times 0
    }
}
