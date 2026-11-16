#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F5 checks on a REAL Windows machine (GitHub windows-latest runner or a VM).
# Real CIM free-space measurement around a harmless test action, and restore point
# DETECTION only: Checkpoint-Computer is mocked to fail the test if it is ever reached,
# so CI never creates a restore point. Excluded automatically on non-Windows hosts.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.ps1')
    # Direct imports (Core + modules) so Mock -ModuleName targets them and they share one Core state.
    Import-WcTestModules -Name @('System', 'Baseline')
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'f5win.jsonl') | Out-Null
}

AfterAll {
    Clear-WcPlanHooks
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'F5 on real Windows' -Tag 'Windows' {
    BeforeEach {
        Mock -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer { throw 'Checkpoint-Computer must never run in tests' }
    }
    It 'measures free space of every fixed drive through real CIM' {
        $m = @(Measure-WcSystemFreeSpace)
        $m.Count | Should -BeGreaterThan 0
        $sys = @($m | Where-Object { $_.Target -eq $env:SystemDrive.ToUpperInvariant() })
        $sys.Count | Should -Be 1
        $sys[0].Value | Should -BeGreaterThan 0
        $sys[0].Source | Should -Be 'System'
    }
    It 'compares before/after around a harmless action run through the plan' {
        Clear-WcActionHandlers
        Clear-WcPlanHooks
        Register-WcBaselineHandler
        $file = Join-Path $script:Tmp 'f5-harmless.bin'
        $exec = {
            param($c)
            [System.IO.File]::WriteAllBytes($file, (New-Object byte[] 1048576))
            New-WcActionResult -Summary 'wrote 1 MB in the test folder'
        }.GetNewClosure()
        $measure = {
            param($c)
            $len = 0L
            if (Test-Path -LiteralPath $file) { $len = (Get-Item -LiteralPath $file).Length }
            New-WcMetric -Name 'FolderBytes' -Target $file -Value $len
        }.GetNewClosure()
        Register-WcActionHandler -Name 'F5-Harmless' -Preview { param($c) New-WcActionResult -Summary 'would write 1 MB in the test folder' } -Execute $exec -Measure $measure
        $cat = @(@{ Id = 'test.f5-harmless'; Category = 'Storage'; Risk = 'Low'; Modifies = $true; RequiresAdmin = $false; Reversible = $false; Reversibility = 'None'; Handler = 'F5-Harmless'; TitleKey = 'action.test' })
        $ctx = New-WcContext -IsAdmin (Test-WcIsAdmin) -Build 19045
        $plan = New-WcPlan -Catalog $cat -ActionId 'test.f5-harmless' -OperationProfile (Get-WcProfile 'Conservador') -Context $ctx
        $r = Invoke-WcPlan -Plan $plan -Context $ctx -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Succeeded'
        $r[0].Comparison | Should -Not -BeNullOrEmpty
        @($r[0].Comparison.Rows | Where-Object { $_.Source -eq 'System' -and $_.Name -eq 'FreeBytes' }).Count | Should -BeGreaterThan 0
        $r[0].Comparison.FreeBytesDelta | Should -Not -BeNullOrEmpty
        ($r[0].Comparison.Rows | Where-Object { $_.Name -eq 'FolderBytes' }).Delta | Should -Be 1048576
        $r[0].RestorePoint | Should -BeNullOrEmpty
        $dir = Join-Path $script:Tmp 'history'
        Add-WcHistory -Directory $dir -Plan $plan -Results $r | Should -Be 1
        (@(Read-WcHistory -Directory $dir))[0].freeBytesDelta | Should -Not -BeNullOrEmpty
    }
    It 'detects restore point availability read-only and consistently' {
        $f = Get-WcRestorePointFacts
        $f.IsWindows | Should -BeTrue
        $av = ConvertTo-WcRestorePointAvailability -Facts $f
        $av.Reason | Should -BeIn @('', 'powershell-edition', 'cmdlet-missing', 'server-sku', 'disabled-by-policy', 'protection-disabled', 'requires-admin')
        if ($PSVersionTable.PSEdition -ne 'Desktop') { $f.DesktopBridge | Should -BeTrue -Because 'PowerShell 7 uses the Windows PowerShell 5.1 bridge' }
        if ($null -ne $f.ProductType -and [int]$f.ProductType -ne 1 -and $f.HasCheckpointCommand) { $av.Reason | Should -Be 'server-sku' }
        Write-Host ('Restore point availability: available={0} reason={1} protection={2} productType={3} edition={4}' -f $av.Available, $av.Reason, $av.ProtectionEnabled, $f.ProductType, $PSVersionTable.PSEdition)
    }
    It 'Windows PowerShell 5.1 bridge runs a fixed script and returns JSON' {
        $r = @(Invoke-WcDesktopPowerShell -Script 'ConvertTo-Json -Compress -InputObject @([string]$PSVersionTable.PSEdition, $PSVersionTable.PSVersion.Major)')
        $r[0] | Should -Be 'Desktop'
        $r[1] | Should -Be 5
        { Invoke-WcDesktopPowerShell -Script 'exit 3' } | Should -Throw '*(3)*'
    }
    It 'New-WcRestorePoint never calls Checkpoint-Computer when unavailable, and only queries otherwise' {
        $av = Get-WcRestorePointAvailability
        if ($av.Available) {
            # Real client with protection on: query only (mock blocks creation, so the outcome is Skipped or Failed, never Created).
            $o = New-WcRestorePoint -Description 'WinCare test never created'
            $o.Status | Should -Not -Be 'Created'
        }
        else {
            $o = New-WcRestorePoint -Description 'WinCare test never created'
            $o.Status | Should -Be 'Unavailable'
            $o.Reason | Should -Be $av.Reason
            Should -Invoke -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer -Times 0 -Exactly
        }
    }
    It 'lists restore points read-only without throwing' {
        $l = Get-WcRestorePoint
        $l.Status | Should -BeIn @('Ok', 'Unavailable', 'Error')
        if ($l.Status -eq 'Ok') { foreach ($p in $l.Points) { $p.SequenceNumber | Should -BeGreaterThan 0 } }
        Should -Invoke -ModuleName WinCare.Baseline Invoke-WcCheckpointComputer -Times 0 -Exactly
    }
}
