#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F5: before/after measurement, restore points, history and the action report.
# Pure functions use fixtures; every Windows I/O (CIM, registry, Checkpoint-Computer,
# Get-ComputerRestorePoint) is mocked. Checkpoint-Computer is a global stub that throws.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @('System', 'Storage', 'Reporting', 'Cleanup', 'Baseline')
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'baseline.jsonl') | Out-Null
    Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR' | Out-Null
    # Safety net for real Windows hosts, where Checkpoint-Computer is a real cmdlet.
    Mock -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer { throw 'Checkpoint-Computer must never run in tests' }

    function New-F5Action {
        param([hashtable] $Override = @{})
        $a = @{ Id = 'test.f5'; Category = 'Storage'; Risk = 'Low'; Modifies = $true; RequiresAdmin = $false
            Reversible = $false; Reversibility = 'None'; Handler = 'F5-Handler'; TitleKey = 'action.test' }
        foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
        return $a
    }
    function New-Measurement([object[]] $Metric, [string[]] $Errors = @()) {
        return [pscustomobject]@{ Time = '2026-11-16T00:00:00Z'; Metrics = @($Metric); Errors = @($Errors) }
    }
    function New-Rp([long] $Seq, [string] $Dmtf, [int] $Type = 12, [string] $Desc = 'x') {
        return [pscustomobject]@{ SequenceNumber = $Seq; CreationTime = $Dmtf; RestorePointType = $Type; Description = $Desc }
    }
    function New-Facts([hashtable] $Override = @{}) {
        $f = @{ IsWindows = $true; PSEdition = 'Desktop'; HasCheckpointCommand = $true; IsAdmin = $true; ProductType = 1
            PolicyDisableSR = $null; ProtectedVolumes = @('\\?\Volume{1111}\:(C%3A)'); FrequencyMinutes = $null; SystemDrive = 'C:' }
        foreach ($k in $Override.Keys) { $f[$k] = $Override[$k] }
        return $f
    }
}

AfterAll {
    Clear-WcPlanHooks
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Catalog field Reversibility' {
    It 'accepts a consistent definition' {
        @(Test-WcActionDefinition -Action (New-F5Action)).Count | Should -Be 0
        @(Test-WcActionDefinition -Action (New-F5Action @{ Modifies = $false; Risk = 'None'; Reversible = $true; Reversibility = 'ReadOnly' })).Count | Should -Be 0
        @(Test-WcActionDefinition -Action (New-F5Action @{ Risk = 'High'; Reversible = $true; Reversibility = 'RestorePoint' })).Count | Should -Be 0
    }
    It 'rejects <Name>' -ForEach @(
        @{ Name = 'a missing field'; Override = @{ Reversibility = $null }; Pattern = "missing field 'Reversibility'" }
        @{ Name = 'an unknown value'; Override = @{ Reversibility = 'Magic' }; Pattern = 'invalid reversibility' }
        @{ Name = 'read-only action not ReadOnly'; Override = @{ Modifies = $false; Risk = 'None'; Reversibility = 'None' }; Pattern = 'must have reversibility' }
        @{ Name = 'modifying action marked ReadOnly'; Override = @{ Reversibility = 'ReadOnly' }; Pattern = 'cannot have reversibility' }
        @{ Name = 'None with Reversible=true'; Override = @{ Reversible = $true }; Pattern = 'contradicts' }
        @{ Name = 'RestorePoint on Low risk'; Override = @{ Reversibility = 'RestorePoint' }; Pattern = 'requires risk Medium or High' }
    ) {
        $a = New-F5Action $Override
        if ($null -eq $Override['Reversibility'] -and $Override.ContainsKey('Reversibility')) { $a.Remove('Reversibility') }
        (Test-WcActionDefinition -Action $a) -join ';' | Should -Match $Pattern
    }
    It 'every shipped action declares it honestly' {
        $c = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        foreach ($a in $c) {
            # F6: the Winsock catalog lives in the registry, which a System Restore point reverts.
            $expected = 'None'
            if ($a.Id -eq 'network.reset-winsock') { $expected = 'RestorePoint' }
            if ($a.Modifies) { $a.Reversibility | Should -Be $expected -Because $a.Id } else { $a.Reversibility | Should -Be 'ReadOnly' -Because $a.Id }
        }
        foreach ($id in 'cleanup.user-temp', 'cleanup.windows-temp', 'storage.optimize-retrim', 'integrity.sfc-scannow', 'integrity.dism-restorehealth') {
            $a = @($c | Where-Object { $_.Id -eq $id })[0]
            $a.Reversible | Should -BeFalse -Because $id
        }
    }
}

Describe 'Comparison (pure)' {
    It 'matches rows, computes deltas and sums free space of drives present on both sides' {
        $b = New-Measurement @(
            (New-WcMetric -Source System -Name FreeBytes -Target 'C:' -Value 1000L),
            (New-WcMetric -Source System -Name FreeBytes -Target 'D:' -Value 500L),
            (New-WcMetric -Source Action -Name FolderBytes -Target '/t' -Value 300L))
        $a = New-Measurement @(
            (New-WcMetric -Source System -Name FreeBytes -Target 'C:' -Value 1250L),
            (New-WcMetric -Source System -Name FreeBytes -Target 'D:' -Value 480L),
            (New-WcMetric -Source Action -Name FolderBytes -Target '/t' -Value 50L))
        $c = ConvertTo-WcComparison -Before $b -After $a
        $c.Rows.Count | Should -Be 3
        ($c.Rows | Where-Object Target -eq 'C:').Delta | Should -Be 250
        ($c.Rows | Where-Object Target -eq '/t').Delta | Should -Be -250
        $c.FreeBytesBefore | Should -Be 1500
        $c.FreeBytesAfter | Should -Be 1730
        $c.FreeBytesDelta | Should -Be 230
        $c.Complete | Should -BeTrue
    }
    It 'lists a drive that appeared without summing it and marks the comparison incomplete' {
        $b = New-Measurement @((New-WcMetric -Source System -Name FreeBytes -Target 'C:' -Value 10L))
        $a = New-Measurement @((New-WcMetric -Source System -Name FreeBytes -Target 'C:' -Value 15L), (New-WcMetric -Source System -Name FreeBytes -Target 'E:' -Value 99L))
        $c = ConvertTo-WcComparison -Before $b -After $a
        ($c.Rows | Where-Object Target -eq 'E:').Before | Should -BeNullOrEmpty
        ($c.Rows | Where-Object Target -eq 'E:').Delta | Should -BeNullOrEmpty
        $c.FreeBytesDelta | Should -Be 5
        $c.Complete | Should -BeFalse
    }
    It 'treats null or non-numeric values as unknown and carries collector errors' {
        $b = New-Measurement @((New-WcMetric -Name FolderBytes -Target 'x' -Value $null)) @('system: CIM down')
        $a = New-Measurement @((New-WcMetric -Name FolderBytes -Target 'x' -Value 'n/a'))
        $c = ConvertTo-WcComparison -Before $b -After $a
        $c.Rows[0].Delta | Should -BeNullOrEmpty
        $c.FreeBytesDelta | Should -BeNullOrEmpty
        $c.Errors | Should -Contain 'system: CIM down'
        $c.Complete | Should -BeFalse
    }
    It 'handles a missing side' {
        $c = ConvertTo-WcComparison -Before (New-Measurement @((New-WcMetric -Name FileCount -Unit Count -Value 3))) -After $null
        $c.Rows.Count | Should -Be 1
        $c.Complete | Should -BeFalse
    }
    It 'normalizes hashtables and one level of nested arrays into metrics' {
        $m = ConvertTo-WcMetricList -InputObject @(, @(@{ Name = 'FreeBytes'; Target = 'C:'; Value = 1 }, @{ Target = 'no-name' }, $null)) -Source System
        @($m).Count | Should -Be 1   # @(): a single PSCustomObject has no .Count on PS 5.1
        $m = @($m)
        $m[0].Source | Should -Be 'System'
        $m[0].Unit | Should -Be 'Bytes'
    }
}

Describe 'Restore point policy (pure)' {
    It '<Risk>/<Rev>/modifies=<Mod> with policy <Policy> -> <Expected>' -ForEach @(
        @{ Risk = 'High'; Rev = 'None'; Mod = $true; Policy = 'High'; Expected = $true }
        @{ Risk = 'High'; Rev = 'None'; Mod = $true; Policy = 'Off'; Expected = $false }
        @{ Risk = 'Medium'; Rev = 'None'; Mod = $true; Policy = 'High'; Expected = $false }
        @{ Risk = 'Medium'; Rev = 'None'; Mod = $true; Policy = 'MediumAndHigh'; Expected = $true }
        @{ Risk = 'Medium'; Rev = 'RestorePoint'; Mod = $true; Policy = 'High'; Expected = $true }
        @{ Risk = 'Low'; Rev = 'None'; Mod = $true; Policy = 'MediumAndHigh'; Expected = $false }
        @{ Risk = 'High'; Rev = 'ReadOnly'; Mod = $false; Policy = 'MediumAndHigh'; Expected = $false }
    ) {
        $item = [pscustomobject]@{ Risk = $Risk; Reversibility = $Rev; Modifies = $Mod }
        Test-WcRestorePointRequired -Item $item -Policy $Policy | Should -Be $Expected
    }
    It 'counts only Created or a recent existing point as usable' {
        Test-WcRestorePointUsable -Outcome (New-WcRestorePointOutcome -Status Created -SequenceNumber 5) | Should -BeTrue
        Test-WcRestorePointUsable -Outcome (New-WcRestorePointOutcome -Status Skipped -Reason 'created-recently' -SequenceNumber 4) | Should -BeTrue
        Test-WcRestorePointUsable -Outcome (New-WcRestorePointOutcome -Status Skipped -Reason 'created-recently') | Should -BeFalse
        Test-WcRestorePointUsable -Outcome (New-WcRestorePointOutcome -Status Unavailable -Reason 'protection-disabled') | Should -BeFalse
        Test-WcRestorePointUsable -Outcome $null | Should -BeFalse
    }
}

Describe 'Invoke-WcPlan before/after and restore point' {
    BeforeEach {
        # New-WcPlan would re-register the real Baseline hooks over the fakes below.
        Mock -ModuleName WinCare.Core Initialize-WcActionHandlers { @() }
        Clear-WcActionHandlers
        Clear-WcPlanHooks
        $script:Free = 1000L
        $script:Calls = @{ Execute = 0; Measure = 0; Rp = 0; Order = New-Object System.Collections.Generic.List[string] }
        Register-WcActionHandler -Name 'F5-Handler' -Preview { param($c) 'preview' } -Execute { param($c) $script:Calls.Execute++; $script:Calls.Order.Add('execute'); $script:Free += 200; New-WcActionResult -Summary 'ok' } -Measure { param($c) @{ Name = 'FolderBytes'; Target = 'T'; Value = (5000 - $script:Free) } }
        Register-WcPlanHook -Name Measure -ScriptBlock { param($c) $script:Calls.Measure++; $script:Calls.Order.Add('measure'); New-WcMetric -Source System -Name FreeBytes -Target 'C:' -Value $script:Free }
        Register-WcPlanHook -Name RestorePoint -ScriptBlock { param($p, $i) $script:Calls.Rp++; $script:Calls.Order.Add('restorepoint'); New-WcRestorePointOutcome -Status Created -SequenceNumber 42 -CreationTime '2026-11-16T10:00:00.0000000Z' }
        $script:Ctx = New-WcContext -IsAdmin $true -Build 22631
        $script:Cat = @(
            (New-F5Action),
            (New-F5Action @{ Id = 'test.high1'; Risk = 'High' }),
            (New-F5Action @{ Id = 'test.high2'; Risk = 'High' }),
            (New-F5Action @{ Id = 'test.medium'; Risk = 'Medium' }),
            (New-F5Action @{ Id = 'test.ro'; Modifies = $false; Risk = 'None'; Reversible = $true; Reversibility = 'ReadOnly' })
        )
    }
    It 'measures before and after every executed item and compares' {
        $plan = New-WcPlan -Catalog $script:Cat -ActionId 'test.f5' -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Succeeded'
        $r[0].Reversibility | Should -Be 'None'
        $r[0].Comparison.FreeBytesDelta | Should -Be 200
        ($r[0].Comparison.Rows | Where-Object Name -eq 'FolderBytes').Delta | Should -Be -200
        ($r[0].Comparison.Rows | Where-Object Name -eq 'FolderBytes').Source | Should -Be 'Action'
        $r[0].RestorePoint | Should -BeNullOrEmpty
        $script:Calls.Rp | Should -Be 0
        ($script:Calls.Order -join ',') | Should -Be 'measure,execute,measure'
    }
    It 'dry-run never measures and never creates a restore point' {
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.high1', 'test.f5') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -DryRun -ConfirmCallback { $true }
        $r.Status | Should -Be @('Previewed', 'Previewed')
        $script:Calls.Measure | Should -Be 0
        $script:Calls.Rp | Should -Be 0
        $r[0].Comparison | Should -BeNullOrEmpty
    }
    It 'does not measure skipped or blocked items' {
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.f5', 'test.high1') -OperationProfile (Get-WcProfile 'Conservador') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $false }
        $r.Status | Should -Be @('Skipped', 'Blocked')
        $script:Calls.Measure | Should -Be 0
        $script:Calls.Rp | Should -Be 0
    }
    It 'creates ONE restore point before the first High item, after confirmation, and attaches it to each' {
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.f5', 'test.high1', 'test.high2') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        $script:Calls.Rp | Should -Be 1
        $r[0].RestorePoint | Should -BeNullOrEmpty
        $r[1].RestorePoint.Status | Should -Be 'Created'
        $r[2].RestorePoint.SequenceNumber | Should -Be 42
        # Restore point is taken before the "before" measurement of the High item.
        ($script:Calls.Order -join ',') | Should -Be 'measure,execute,measure,restorepoint,measure,execute,measure,measure,execute,measure'
    }
    It 'never asks for a restore point when the High item is not confirmed' {
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.high1') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        (Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $false })[0].Status | Should -Be 'Skipped'
        $script:Calls.Rp | Should -Be 0
    }
    It 'Medium items get a restore point only with MediumAndHigh' {
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.medium') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        (Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true })[0].RestorePoint | Should -BeNullOrEmpty
        (Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true } -RestorePointPolicy MediumAndHigh)[0].RestorePoint.Status | Should -Be 'Created'
        $script:Calls.Rp | Should -Be 1
    }
    It '-RequireRestorePoint skips the item when no usable point exists, and runs it otherwise' {
        Register-WcPlanHook -Name RestorePoint -ScriptBlock { param($p, $i) $script:Calls.Rp++; New-WcRestorePointOutcome -Status Unavailable -Reason 'protection-disabled' }
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.high1', 'test.f5') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true } -RequireRestorePoint
        $r[0].Status | Should -Be 'Skipped'
        $r[0].Error | Should -Be 'restorepoint.required-not-available'
        $r[0].RestorePoint.Reason | Should -Be 'protection-disabled'
        $r[1].Status | Should -Be 'Succeeded'
        $script:Calls.Execute | Should -Be 1
    }
    It 'without -RequireRestorePoint the item runs and records Unavailable' {
        Register-WcPlanHook -Name RestorePoint -ScriptBlock { param($p, $i) New-WcRestorePointOutcome -Status Unavailable -Reason 'server-sku' }
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.high1') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Succeeded'
        $r[0].RestorePoint.Status | Should -Be 'Unavailable'
    }
    It 'reports no-provider without a hook and Failed when the hook throws' {
        Clear-WcPlanHooks
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.high1') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        (Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true })[0].RestorePoint.Reason | Should -Be 'no-provider'
        Register-WcPlanHook -Name RestorePoint -ScriptBlock { throw 'vss down' }
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        $r[0].RestorePoint.Status | Should -Be 'Failed'
        $r[0].RestorePoint.Detail | Should -Be 'vss down'
        $r[0].Status | Should -Be 'Succeeded'
    }
    It 'a failing collector never fails the action' {
        Register-WcPlanHook -Name Measure -ScriptBlock { throw 'CIM down' }
        $plan = New-WcPlan -Catalog $script:Cat -ActionId 'test.f5' -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Succeeded'
        $r[0].Comparison.Errors | Should -Contain 'system: CIM down'
        $r[0].Comparison.Complete | Should -BeFalse
    }
    It 'still measures after a failed Execute' {
        Register-WcActionHandler -Name 'F5-Handler' -Preview { 'p' } -Execute { $script:Free += 7; throw 'half done' }
        $plan = New-WcPlan -Catalog $script:Cat -ActionId 'test.f5' -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Failed'
        $r[0].Comparison.FreeBytesDelta | Should -Be 7
    }
    It '-Measure Modifying skips read-only items; -Measure None skips all' {
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.ro', 'test.f5') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true } -Measure Modifying
        $r[0].Comparison | Should -BeNullOrEmpty
        $r[1].Comparison | Should -Not -BeNullOrEmpty
        $script:Calls.Measure = 0
        Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true } -Measure None | Out-Null
        $script:Calls.Measure | Should -Be 0
    }
    It 'writes comparison and restore point to history and reads them back' {
        $dir = Join-Path $script:Tmp 'hist-f5'
        $plan = New-WcPlan -Catalog $script:Cat -ActionId @('test.high1', 'test.f5') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        Add-WcHistory -Directory $dir -Plan $plan -Results $r | Should -Be 2
        $h = @(Read-WcHistory -Directory $dir)
        $h[0].restorePoint.status | Should -Be 'Created'
        $h[0].restorePoint.sequenceNumber | Should -Be 42
        $h[0].rollbackAvailable | Should -BeTrue
        $h[0].reversibility | Should -Be 'None'
        $h[0].freeBytesDelta | Should -Be 200
        @($h[0].comparison).Count | Should -Be 2
        $h[1].restorePoint | Should -BeNullOrEmpty
        $h[1].rollbackAvailable | Should -BeFalse
    }
}

Describe 'Free space collector' {
    It 'converts Win32_LogicalDisk rows (fixture) to FreeBytes metrics' {
        $rows = @(
            [pscustomobject]@{ DeviceID = 'd:'; FreeSpace = [uint64]500; Size = [uint64]1000 }
            [pscustomobject]@{ DeviceID = 'C:'; FreeSpace = [uint64]100; Size = [uint64]1000 }
            [pscustomobject]@{ DeviceID = 'C:\; x'; FreeSpace = [uint64]1 }
            [pscustomobject]@{ DeviceID = 'E:'; FreeSpace = $null }
        )
        $m = @(ConvertTo-WcFreeSpaceMetric -Disk $rows)
        $m.Target | Should -Be @('C:', 'D:', 'E:')
        $m[1].Value | Should -Be 500
        $m[2].Value | Should -BeNullOrEmpty
        $m[0].Source | Should -Be 'System'
    }
    It 'returns nothing off Windows without touching CIM' {
        Mock -ModuleName WinCare.Baseline Test-WcIsWindows { $false }
        Mock -ModuleName WinCare.Baseline Get-WcFixedDriveRaw { throw 'must not run' }
        @(Measure-WcSystemFreeSpace).Count | Should -Be 0
        Should -Invoke -ModuleName WinCare.Baseline Get-WcFixedDriveRaw -Times 0 -Exactly
    }
    It 'queries fixed drives on Windows' {
        Mock -ModuleName WinCare.Baseline Test-WcIsWindows { $true }
        Mock -ModuleName WinCare.Baseline Get-WcFixedDriveRaw { @([pscustomobject]@{ DeviceID = 'C:'; FreeSpace = [uint64]42 }) }
        $m = @(Measure-WcSystemFreeSpace)
        $m.Count | Should -Be 1
        $m[0].Value | Should -Be 42
    }
}

Describe 'Restore point data (pure)' {
    It 'parses DMTF dates with offset' {
        $d = ConvertFrom-WcDmtfDate -Value '20261116103000.000000-180'
        $d.Kind | Should -Be 'Utc'
        $d.ToString('yyyy-MM-dd HH:mm') | Should -Be '2026-11-16 13:30'
        ConvertFrom-WcDmtfDate -Value 'garbage' | Should -BeNullOrEmpty
    }
    It 'shapes and sorts restore points newest first' {
        $rows = @(ConvertTo-WcRestorePointRow -RestorePoint @((New-Rp 3 '20261101080000.000000+000' 0 'Install'), (New-Rp 7 '20261110080000.000000+000' 12 '<b>x</b>'), $null))
        $rows.SequenceNumber | Should -Be @(7, 3)
        $rows[0].Type | Should -Be 'MODIFY_SETTINGS'
        $rows[1].Type | Should -Be 'APPLICATION_INSTALL'
        $rows[0].Created | Should -Match '^2026-11-10T08:00:00'
    }
    It 'finds a point inside the frequency window only' {
        $rows = @(ConvertTo-WcRestorePointRow -RestorePoint @((New-Rp 1 '20261115000000.000000+000'), (New-Rp 2 '20261116080000.000000+000')))
        $now = [datetime]::SpecifyKind([datetime]'2026-11-16T10:00:00', 'Utc')
        (Select-WcRecentRestorePoint -Row $rows -NowUtc $now -FrequencyMinutes 1440).SequenceNumber | Should -Be 2
        Select-WcRecentRestorePoint -Row $rows -NowUtc $now -FrequencyMinutes 60 | Should -BeNullOrEmpty
        Select-WcRecentRestorePoint -Row $rows -NowUtc $now -FrequencyMinutes 0 | Should -BeNullOrEmpty
    }
    It 'detects protection of the system drive from SPP Clients entries' {
        Test-WcVolumeProtected -ProtectedVolume @('\\?\Volume{a}\:(C%3A)') -Drive 'C:' | Should -BeTrue
        Test-WcVolumeProtected -ProtectedVolume @('\\?\Volume{a}\:(D%3A)') -Drive 'C:' | Should -BeFalse
        Test-WcVolumeProtected -ProtectedVolume @() -Drive 'C:' | Should -BeFalse
        Test-WcVolumeProtected -ProtectedVolume @('(C%3A)') -Drive 'C:\x' | Should -BeFalse
    }
    It 'availability: <Name> -> <Reason>' -ForEach @(
        @{ Name = 'all good'; Override = @{}; Reason = '' }
        @{ Name = 'Linux'; Override = @{ IsWindows = $false }; Reason = 'not-windows' }
        @{ Name = 'pwsh 7 without bridge'; Override = @{ PSEdition = 'Core'; DesktopBridge = $false }; Reason = 'powershell-edition' }
        @{ Name = 'pwsh 7 with 5.1 bridge'; Override = @{ PSEdition = 'Core'; DesktopBridge = $true }; Reason = '' }
        @{ Name = 'no cmdlet'; Override = @{ HasCheckpointCommand = $false }; Reason = 'cmdlet-missing' }
        @{ Name = 'server'; Override = @{ ProductType = 3 }; Reason = 'server-sku' }
        @{ Name = 'policy'; Override = @{ PolicyDisableSR = 1 }; Reason = 'disabled-by-policy' }
        @{ Name = 'protection off'; Override = @{ ProtectedVolumes = @() }; Reason = 'protection-disabled' }
        @{ Name = 'other drive protected'; Override = @{ ProtectedVolumes = @('\\?\Volume{x}\:(D%3A)') }; Reason = 'protection-disabled' }
        @{ Name = 'not admin'; Override = @{ IsAdmin = $false }; Reason = 'requires-admin' }
    ) {
        $av = ConvertTo-WcRestorePointAvailability -Facts (New-Facts $Override)
        $av.Reason | Should -Be $Reason
        $av.Available | Should -Be ($Reason -eq '')
    }
    It 'reads the frequency setting (default 1440) without changing it' {
        (ConvertTo-WcRestorePointAvailability -Facts (New-Facts)).FrequencyMinutes | Should -Be 1440
        (ConvertTo-WcRestorePointAvailability -Facts (New-Facts @{ FrequencyMinutes = 0 })).FrequencyMinutes | Should -Be 0
    }
    It 'builds a fixed ASCII description that passes the wrapper validation' {
        $d = Get-WcRestorePointDescription -PlanId '0f1e2d3c-aaaa-bbbb' -ActionId 'integrity.dism-restorehealth; rm -rf'
        $d | Should -Be 'WinCare plan 0f1e2d3c before integrity.dism-restorehealthrm-rf'
        $d | Should -Match '^[A-Za-z0-9 \.\-]{1,100}$'
    }
}

Describe 'Restore point facts and listing (read-only)' {
    It 'collects facts only through read-only helpers' {
        Mock -ModuleName WinCare.Baseline Test-WcIsWindows { $true }
        Mock -ModuleName WinCare.Baseline Test-WcIsAdmin { $true }
        Mock -ModuleName WinCare.Baseline Get-WcCimData { @([pscustomobject]@{ ProductType = 1 }) }
        Mock -ModuleName WinCare.Baseline Get-WcRegistryValues {
            if ($Path -like '*SPP\Clients') { return @{ '{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}' = @('\\?\Volume{1}\:(C%3A)') } }
            return @{}
        }
        $f = Get-WcRestorePointFacts
        $f.ProductType | Should -Be 1
        $f.ProtectedVolumes[0] | Should -Match 'C%3A'
        $f.FrequencyMinutes | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinCare.Baseline Get-WcRegistryValues -Times 3 -Exactly
    }
    It 'the module source never writes settings or enables System Protection' {
        $src = Get-Content -Raw (Join-Path $script:SrcRoot 'Modules/WinCare.Baseline.psm1')
        foreach ($bad in 'Enable-ComputerRestore', 'Disable-ComputerRestore', 'Set-ItemProperty', 'New-ItemProperty', 'Remove-ItemProperty', 'New-Item ', 'vssadmin', 'reg.exe', 'Restore-Computer', 'Invoke-CimMethod', 'Set-CimInstance') {
            $src | Should -Not -Match ([regex]::Escape($bad)) -Because $bad
        }
    }
    It 'lists restore points when available' {
        Mock -ModuleName WinCare.Baseline Get-WcRestorePointAvailability { ConvertTo-WcRestorePointAvailability -Facts (New-Facts) }
        Mock -ModuleName WinCare.Baseline Get-WcComputerRestorePointRaw { @((New-Rp 9 '20261116080000.000000+000')) }
        $l = Get-WcRestorePoint
        $l.Status | Should -Be 'Ok'
        $l.Points[0].SequenceNumber | Should -Be 9
    }
    It 'lists existing points even when protection is now off (admin)' {
        Mock -ModuleName WinCare.Baseline Get-WcRestorePointAvailability { ConvertTo-WcRestorePointAvailability -Facts (New-Facts @{ ProtectedVolumes = @() }) }
        Mock -ModuleName WinCare.Baseline Test-WcIsAdmin { $true }
        Mock -ModuleName WinCare.Baseline Get-WcComputerRestorePointRaw { @() }
        $l = Get-WcRestorePoint
        $l.Status | Should -Be 'Ok'
        $l.ProtectionEnabled | Should -BeFalse
    }
    It 'reports Unavailable/Error without throwing' {
        Mock -ModuleName WinCare.Baseline Get-WcRestorePointAvailability { ConvertTo-WcRestorePointAvailability -Facts (New-Facts @{ ProductType = 3 }) }
        Mock -ModuleName WinCare.Baseline Get-WcComputerRestorePointRaw { throw 'must not run' }
        (Get-WcRestorePoint).Reason | Should -Be 'server-sku'
        Mock -ModuleName WinCare.Baseline Get-WcRestorePointAvailability { ConvertTo-WcRestorePointAvailability -Facts (New-Facts) }
        Mock -ModuleName WinCare.Baseline Get-WcComputerRestorePointRaw { throw 'Access denied' }
        $l = Get-WcRestorePoint
        $l.Status | Should -Be 'Error'
        $l.Detail | Should -Be 'Access denied'
    }
}

Describe 'Restore point creation (mocked Checkpoint-Computer)' {
    BeforeEach {
        Mock -ModuleName WinCare.Baseline Get-WcRestorePointAvailability { ConvertTo-WcRestorePointAvailability -Facts (New-Facts) }
        $script:RpList = @((New-Rp 5 '20260101000000.000000+000'))
        Mock -ModuleName WinCare.Baseline Get-WcComputerRestorePointRaw { $script:RpList }
        Mock -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer { $script:RpList = @($script:RpList) + (New-Rp 6 ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') + '.000000+000') 12 $Description); , @() }
    }
    It 'creates and verifies a new point' {
        $o = New-WcRestorePoint -Description 'WinCare plan abc before x.y'
        $o.Status | Should -Be 'Created'
        $o.SequenceNumber | Should -Be 6
        Should -Invoke -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer -Times 1 -Exactly
    }
    It 'never calls Checkpoint-Computer when unavailable (e.g. protection off)' {
        Mock -ModuleName WinCare.Baseline Get-WcRestorePointAvailability { ConvertTo-WcRestorePointAvailability -Facts (New-Facts @{ ProtectedVolumes = @() }) }
        $o = New-WcRestorePoint -Description 'WinCare plan abc before x.y'
        $o.Status | Should -Be 'Unavailable'
        $o.Reason | Should -Be 'protection-disabled'
        Should -Invoke -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer -Times 0 -Exactly
        Should -Invoke -ModuleName WinCare.Baseline Get-WcComputerRestorePointRaw -Times 0 -Exactly
    }
    It 'skips (created-recently) and references the recent point instead of failing' {
        $script:RpList = @((New-Rp 8 ((Get-Date).ToUniversalTime().AddHours(-2).ToString('yyyyMMddHHmmss') + '.000000+000')))
        $o = New-WcRestorePoint -Description 'WinCare plan abc before x.y'
        $o.Status | Should -Be 'Skipped'
        $o.Reason | Should -Be 'created-recently'
        $o.SequenceNumber | Should -Be 8
        Test-WcRestorePointUsable -Outcome $o | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer -Times 0 -Exactly
    }
    It 'maps the Windows frequency warning to Skipped when no new point appears' {
        Mock -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer { , @('A new system restore point cannot be created because one has already been created within the past 1440 minutes.') }
        $o = New-WcRestorePoint -Description 'WinCare plan abc before x.y'
        $o.Status | Should -Be 'Skipped' -Because $o.Detail
        $o.Reason | Should -Be 'created-recently'
        Test-WcRestorePointUsable -Outcome $o | Should -BeFalse
    }
    It 'reports Failed/not-verified when nothing was created and no warning explains it' {
        Mock -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer { , @() }
        (New-WcRestorePoint -Description 'WinCare plan abc before x.y').Reason | Should -Be 'not-verified'
    }
    It 'reports Failed/error when Checkpoint-Computer throws' {
        Mock -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer { throw 'The service cannot be started' }
        $o = New-WcRestorePoint -Description 'WinCare plan abc before x.y'
        $o.Status | Should -Be 'Failed'
        $o.Detail | Should -Match 'cannot be started'
    }
    It 'refuses free-text descriptions at the wrapper' {
        { Invoke-WcCheckpointComputer -Description 'x; Remove-Item C:\' } | Should -Throw
    }
}

Describe 'Hooks registration and cleanup measurement' {
    It 'Register-WcBaselineHandler installs both hooks through Initialize-WcActionHandlers' {
        Clear-WcPlanHooks
        Initialize-WcActionHandlers | Out-Null
        Mock -ModuleName WinCare.Baseline Test-WcIsWindows { $true }
        Mock -ModuleName WinCare.Baseline Get-WcFixedDriveRaw { @([pscustomobject]@{ DeviceID = 'C:'; FreeSpace = [uint64]77 }) }
        $m = Invoke-WcMeasurement -Context @{}
        $m.Metrics[0].Value | Should -Be 77
        $m.Metrics[0].Source | Should -Be 'System'
        Mock -ModuleName WinCare.Baseline Get-WcRestorePointAvailability { ConvertTo-WcRestorePointAvailability -Facts (New-Facts @{ IsWindows = $false }) }
        (Invoke-WcRestorePointHook -Plan ([pscustomobject]@{ Id = 'p' }) -Item ([pscustomobject]@{ ActionId = 'a.b' })).Reason | Should -Be 'not-windows'
    }
    It 'temp folder metrics count bytes and files and ignore reparse entries' {
        $m = @(ConvertTo-WcFolderMetric -Root '/t' -Entry @(
                [pscustomobject]@{ Path = '/t/a'; Length = 10; IsReparsePoint = $false },
                [pscustomobject]@{ Path = '/t/b'; Length = 5; IsReparsePoint = $false },
                [pscustomobject]@{ Path = '/t/l'; Length = 999; IsReparsePoint = $true }))
        ($m | Where-Object Name -eq 'FolderBytes').Value | Should -Be 15
        ($m | Where-Object Name -eq 'FileCount').Value | Should -Be 2
    }
    It 'cleanup.user-temp run through the plan shows the folder shrinking by the freed bytes' {
        $base = New-WcTestDir
        $root = Join-Path $base 'Temp'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        foreach ($n in 'a.tmp', 'b.tmp') {
            $p = Join-Path $root $n
            [System.IO.File]::WriteAllBytes($p, (New-Object byte[] 64))
            $t = (Get-Date).ToUniversalTime().AddHours(-72)
            [System.IO.File]::SetCreationTimeUtc($p, $t); [System.IO.File]::SetLastWriteTimeUtc($p, $t)
        }
        [System.IO.File]::WriteAllBytes((Join-Path $root 'new.tmp'), (New-Object byte[] 8))
        Mock -ModuleName WinCare.Cleanup Get-WcTempRoot { $root }
        Mock -ModuleName WinCare.Baseline Test-WcIsWindows { $false }
        $cat = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        $ctx = New-WcContext -IsAdmin $false -Build 22631
        $plan = New-WcPlan -Catalog $cat -ActionId 'cleanup.user-temp' -OperationProfile (Get-WcProfile 'Conservador') -Context $ctx
        $r = Invoke-WcPlan -Plan $plan -Context $ctx -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Succeeded'
        $folder = $r[0].Comparison.Rows | Where-Object Name -eq 'FolderBytes'
        $folder.Before | Should -Be 136
        $folder.After | Should -Be 8
        $folder.Delta | Should -Be (-1 * $r[0].Output.BytesFreed)
        ($r[0].Comparison.Rows | Where-Object Name -eq 'FileCount').Delta | Should -Be -2
        $r[0].RestorePoint | Should -BeNullOrEmpty
        Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Action report' {
    BeforeAll {
        $script:Plan = [pscustomobject]@{ Id = 'plan-<1>'; Profile = 'Avancado' }
        $cmp = ConvertTo-WcComparison -Before (New-Measurement @((New-WcMetric -Source System -Name FreeBytes -Target 'C:' -Value 1000L), (New-WcMetric -Name FolderBytes -Target '<img src=x onerror=alert(1)>' -Value 3145728L))) `
            -After (New-Measurement @((New-WcMetric -Source System -Name FreeBytes -Target 'C:' -Value 3146728L), (New-WcMetric -Name FolderBytes -Target '<img src=x onerror=alert(1)>' -Value 0L)))
        $script:Results = @(
            [pscustomobject]@{ ActionId = 'cleanup.user-temp'; Mode = 'Execute'; Status = 'Succeeded'; Error = $null; Reversibility = 'None'
                Output = (New-WcActionResult -Summary '<script>alert(1)</script> & done' -BytesFreed 3145728); Comparison = $cmp
                RestorePoint = (New-WcRestorePointOutcome -Status Skipped -Reason 'created-recently' -SequenceNumber 12 -CreationTime '2026-11-16T08:00:00Z')
            }
            [pscustomobject]@{ ActionId = 'diag.system'; Mode = 'DryRun'; Status = 'Previewed'; Error = $null; Output = 'x' }
        )
        $script:Report = New-WcActionReport -Plan $script:Plan -Results $script:Results -AppVersion '0.3.0'
        $script:Html = ConvertTo-WcActionReportHtml -Report $script:Report
    }
    It 'carries before/after, reversibility and restore point per item' {
        $script:Report.Items.Count | Should -Be 2
        $script:Report.Items[0].freeBytesDelta | Should -Be 3145728
        $script:Report.Items[0].restorePoint.sequenceNumber | Should -Be 12
        $script:Report.Items[1].comparison | Should -BeNullOrEmpty
    }
    It 'encodes every value and stays self-contained with a CSP' {
        $script:Html | Should -Not -Match '<script'
        $script:Html | Should -Not -Match '<img src=x'
        $script:Html | Should -Match '&lt;script&gt;alert\(1\)&lt;/script&gt; &amp; done'
        $script:Html | Should -Match 'plan-&lt;1&gt;'
        $script:Html | Should -Match 'Content-Security-Policy'
        $script:Html | Should -Not -Match '(src|href)="https?:'
    }
    It 'shows the before/after table with signed deltas and localized labels' {
        $script:Html | Should -Match 'Antes e depois'
        $script:Html | Should -Match '\+3 MB'
        $script:Html | Should -Match '-3 MB'
        $script:Html | Should -Match 'N&#227;o pode ser desfeito'
        $script:Html | Should -Match '#12'
    }
    It 'builds the same report from history rows and exports JSON/HTML' {
        $dir = Join-Path $script:Tmp 'hist-report'
        Add-WcHistory -Directory $dir -Plan $script:Plan -Results $script:Results | Out-Null
        $rep = New-WcActionReport -History @(Read-WcHistory -Directory $dir)
        $rep.Meta.PlanId | Should -Be 'plan-<1>'
        $html = ConvertTo-WcActionReportHtml -Report $rep -Language 'pt-BR'
        $html | Should -Match '\+3 MB'
        $f = Export-WcActionReport -Report $rep -Path (Join-Path $script:Tmp 'act.json') -Format Json
        (Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json).Items[0].restorePoint.status | Should -Be 'Skipped'
        Export-WcActionReport -Report $rep -Path (Join-Path $script:Tmp 'act.html') -Format Html | Should -Not -BeNullOrEmpty
        { Export-WcActionReport -Report $rep -Path (Join-Path $script:Tmp 'act.exe') -Format Json } | Should -Throw
    }
    It 'formats signed byte deltas' {
        Format-WcBytesDelta $null | Should -Be '-'
        Format-WcBytesDelta 0 | Should -Be '0 KB'
        Format-WcBytesDelta (-1536MB) | Should -Match '^-1[.,]5 GB$'
    }
}

Describe 'F5 localization' {
    It 'pt-BR and en-US fragments have the same keys and placeholders' {
        $pt = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Localization/pt-BR.d/f5-baseline.json')
        $en = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Localization/en-US.d/f5-baseline.json')
        Compare-Object @($pt.Keys) @($en.Keys) | Should -BeNullOrEmpty
        foreach ($k in $pt.Keys) {
            (@([regex]::Matches($pt[$k], '\{\d+\}') | ForEach-Object Value) -join ',') | Should -Be (@([regex]::Matches($en[$k], '\{\d+\}') | ForEach-Object Value) -join ',') -Because $k
        }
    }
    It 'translates every reversibility value, restore point status and reason' {
        foreach ($lang in 'pt-BR', 'en-US') {
            Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language $lang | Out-Null
            foreach ($k in @('ReadOnly', 'None', 'RestorePoint' | ForEach-Object { "reversibility.$_" }) +
                @('Created', 'Skipped', 'Unavailable', 'Failed' | ForEach-Object { "restorepoint.status.$_" }) +
                @('created-recently', 'not-windows', 'powershell-edition', 'cmdlet-missing', 'requires-admin', 'server-sku', 'disabled-by-policy', 'protection-disabled', 'no-provider', 'not-verified', 'error' | ForEach-Object { "restorepoint.reason.$_" }) +
                @('restorepoint.required-not-available', 'metric.FreeBytes', 'metric.FolderBytes', 'metric.FileCount')) {
                Get-WcString $k | Should -Not -Match '^\[' -Because "$lang $k"
            }
        }
        Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR' | Out-Null
    }
}
