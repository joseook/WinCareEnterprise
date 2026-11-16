#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Office (F4) on a REAL Windows machine. Read-only: registry, files and process
# list only. Word is never started here (the measurement is validated by hand,
# see the F4 notes). Excluded automatically on non-Windows hosts (tag 'Windows').

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.ps1')
    Import-WcTestModules -Name @('System', 'Office')
    Initialize-WcLog -Path (Join-Path (New-WcTestDir) 'office-win.jsonl') | Out-Null
}

Describe 'Real Office data (read-only)' -Tag 'Windows' {
    It 'collects the inventory without throwing' {
        { Get-WcOfficeInventory } | Should -Not -Throw
    }
    It 'reports a consistent installation when Office is present' {
        $i = Get-WcOfficeInventory
        $word = @($i.AppPaths | Where-Object { $_.Name -eq 'Word' -and $_.Found })
        if (-not $i.ClickToRun.Installed -and @($i.Products).Count -eq 0 -and $word.Count -eq 0) {
            Set-ItResult -Skipped -Because 'Office not installed on this machine'
            return
        }
        if ($i.ClickToRun.Installed) {
            $i.ClickToRun.Version | Should -Match '^\d+\.\d+\.\d+\.\d+$'
            $i.ClickToRun.Platform | Should -BeIn @('x86', 'x64')
        }
        if ($word.Count -gt 0) { Test-Path -LiteralPath $word[0].Path | Should -BeTrue }
        $rows = @(ConvertTo-WcOfficeInventoryRows -Inventory $i)
        $rows.Count | Should -BeGreaterThan 0
    }
    It 'resolves WINWORD.EXE to an existing absolute path or $null' {
        $p = Get-WcWordExecutablePath
        if ($p) { [System.IO.Path]::IsPathRooted($p) | Should -BeTrue; Test-Path -LiteralPath $p | Should -BeTrue }
    }
    It 'Preview of the measurement starts nothing' {
        $before = @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue).Count
        $frag = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Core/actions.d/f4-office.json')
        $ctx = New-WcContext -IsWindows $true -Build 19045
        $plan = New-WcPlan -Catalog @($frag.actions) -ActionId @('office.measure-word-start') -OperationProfile (Get-WcProfile 'Conservador') -Context $ctx
        Invoke-WcPlan -Plan $plan -Context $ctx -DryRun | Out-Null
        @(Get-Process -Name 'WINWORD' -ErrorAction SilentlyContinue).Count | Should -Be $before
    }
}
