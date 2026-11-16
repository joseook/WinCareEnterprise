#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Integration tests for a REAL Windows machine. Read-only: they query CIM,
# registry and Authenticode, and load XAML without showing a window.
# Excluded automatically on non-Windows hosts (tag 'Windows').

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'TestHelpers.ps1')
    Import-Module (Join-Path $script:SrcRoot 'WinCare.psd1') -Force -DisableNameChecking
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'win.jsonl') | Out-Null
    Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR' | Out-Null
}

Describe 'Real Windows data (read-only)' -Tag 'Windows' {
    It 'detects Windows family, edition and build' {
        $w = Get-WcWindowsInfo
        $w.Build | Should -BeGreaterThan 10000
        $w.Family | Should -BeIn @('Windows 10', 'Windows 11', 'Windows Server')
        $w.EditionId | Should -Not -BeNullOrEmpty
    }
    It 'reads CPU with a valid sampled usage' {
        $c = Get-WcCpuInfo -SampleMilliseconds 500
        $c.LogicalProcessors | Should -BeGreaterThan 0
        $c.UsagePercent | Should -BeGreaterOrEqual 0
        $c.UsagePercent | Should -BeLessOrEqual 100
    }
    It 'reads memory and uptime' {
        $s = Get-WcSystemInfo -CpuSampleMilliseconds 250
        $s.Memory.TotalBytes | Should -BeGreaterThan 1GB
        $s.Memory.UsedPercent | Should -BeGreaterThan 0
        $s.Uptime.TotalHours | Should -BeGreaterOrEqual 0
    }
    It 'reads the system volume' {
        $v = @(Get-WcVolumeInfo | Where-Object IsSystem)
        $v.Count | Should -Be 1
        $v[0].SizeBytes | Should -BeGreaterThan 0
    }
    It 'reads processes, startup items and management signals without throwing' {
        { Get-WcTopProcess -Top 5 } | Should -Not -Throw
        { Get-WcStartupItem } | Should -Not -Throw
        { Get-WcManagementState } | Should -Not -Throw
        { Get-WcProtectionState } | Should -Not -Throw
    }
    It 'runs the full diagnostic with no section errors' {
        $s = Invoke-WcDiagnostic -CatalogPath (Join-Path $script:SrcRoot 'Core/actions.json')
        @($s.Errors).Count | Should -Be 0 -Because (($s.Errors | ForEach-Object { "$($_.Section): $($_.Error)" }) -join '; ')
    }
    It 'runs Start-WinCare -NoGui and writes JSON and HTML reports' {
        $env:WINCARE_DATA_ROOT = $script:Tmp
        try {
            & (Join-Path $script:SrcRoot 'Start-WinCare.ps1') -NoGui -OutputPath (Join-Path $script:Tmp 'r.json') | Out-Null
            & (Join-Path $script:SrcRoot 'Start-WinCare.ps1') -NoGui -OutputPath (Join-Path $script:Tmp 'r.html') | Out-Null
        }
        finally { Remove-Item Env:\WINCARE_DATA_ROOT -ErrorAction SilentlyContinue }
        (Get-Content -Raw (Join-Path $script:Tmp 'r.json') | ConvertFrom-Json).Meta.Tool | Should -Be 'WinCare Enterprise'
        Get-Content -Raw (Join-Path $script:Tmp 'r.html') | Should -Match '<table>'
    }
}

Describe 'Real WPF (no window shown)' -Tag 'Windows' {
    BeforeAll {
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        Import-Module (Join-Path $script:SrcRoot 'UI/WinCare.UI.psm1') -Force -DisableNameChecking
    }
    It 'runs on an STA thread (required by WPF)' {
        [System.Threading.Thread]::CurrentThread.GetApartmentState() | Should -Be 'STA'
    }
    It 'loads every XAML file with XamlReader' {
        foreach ($f in Get-ChildItem (Join-Path $script:SrcRoot 'UI') -Recurse -Filter *.xaml) {
            { Import-WcXaml -Path $f.FullName } | Should -Not -Throw -Because $f.Name
        }
    }
    It 'builds the main window with themes, styles and every page attached' {
        $w = Import-WcXaml -Path (Join-Path $script:SrcRoot 'UI/MainWindow.xaml')
        $w.Resources.MergedDictionaries.Add((Import-WcXaml (Join-Path $script:SrcRoot 'UI/Themes/Dark.xaml')))
        $w.Resources.MergedDictionaries.Add((Import-WcXaml (Join-Path $script:SrcRoot 'UI/Themes/Styles.xaml')))
        $w.FindName('NavList').Items.Count | Should -Be 11
        foreach ($f in Get-ChildItem (Join-Path $script:SrcRoot 'UI/Pages') -Filter *.xaml) {
            $w.FindName('PageHost').Content = Import-WcXaml -Path $f.FullName
        }
        $w.Close()
    }
}

Describe 'Real Authenticode rejection' -Tag 'Windows' {
    BeforeAll { . (Join-Path $script:RepoRoot 'bootstrap/Install-WinCare.ps1') }
    It 'rejects an unsigned package with the real cmdlets' {
        $d = New-WcTestDir
        Set-Content -LiteralPath (Join-Path $d 'a.ps1') -Value '#'
        New-FileCatalog -Path $d -CatalogFilePath (Join-Path $d 'WinCare.cat') -CatalogVersion 2.0 | Out-Null
        $r = Test-WcbPackage -Root $d -TrustedThumbprints @('0000000000000000000000000000000000000000')
        $r.Valid | Should -BeFalse
        ($r.Errors -join ' ') | Should -Match 'NotSigned|not valid'
    }
}
