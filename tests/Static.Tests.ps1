#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Static checks that protect Windows PowerShell 5.1 compatibility and the WPF
# shell without running WPF: parser, ASCII-only scripts, PSScriptAnalyzer
# compatibility rules, forbidden patterns, XAML structure, localization parity,
# theme contrast and manifest consistency.

BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $roots = @('src', 'bootstrap', 'scripts', 'tests') | ForEach-Object { Join-Path $repo $_ } | Where-Object { Test-Path $_ }
    $script:CodeFiles = @(Get-ChildItem -Path $roots -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($repo.Length + 1) } })
    $script:ShippedFiles = @($script:CodeFiles | Where-Object { $_.Name -notmatch '^tests' })
    $script:XamlFiles = @(Get-ChildItem -Path (Join-Path $repo 'src/UI') -Recurse -Filter '*.xaml' | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Pt = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'Localization/pt-BR.json') | ConvertFrom-Json
    $script:En = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'Localization/en-US.json') | ConvertFrom-Json
    # Base file + module fragments (Localization/<lang>.d/*.json), as Import-WcLocalization loads them.
    function Get-TestLocKeys([string] $Lang) {
        $keys = @((Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot "Localization/$Lang.json") | ConvertFrom-Json).PSObject.Properties.Name)
        $frag = Join-Path $script:SrcRoot "Localization/$Lang.d"
        if (Test-Path $frag) { foreach ($f in Get-ChildItem $frag -Filter '*.json') { $keys += @((Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json).PSObject.Properties.Name) } }
        return $keys
    }
    $script:PtKeys = @(Get-TestLocKeys 'pt-BR')
    $script:EnKeys = @(Get-TestLocKeys 'en-US')
}

Describe 'PowerShell sources' {
    It '<Name> parses without errors' -ForEach $script:CodeFiles {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
        @($errors).Count | Should -Be 0 -Because (($errors | ForEach-Object { $_.Message }) -join '; ')
    }
    It '<Name> is ASCII-only (PS 5.1 reads BOM-less files as ANSI)' -ForEach $script:CodeFiles {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
    It '<Name> has no forbidden execution patterns' -ForEach $script:ShippedFiles {
        $text = Get-Content -Raw -LiteralPath $Path
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }
        @($cmds | Where-Object { $_ -in @('Invoke-Expression', 'iex') }).Count | Should -Be 0
        $text | Should -Not -Match '(?i)-ExecutionPolicy\s+(Bypass|Unrestricted)'
        $text | Should -Not -Match '(?i)Set-ExecutionPolicy'
        $text | Should -Not -Match '(?i)DownloadString'
    }
}

Describe 'Windows PowerShell 5.1 compatibility (PSScriptAnalyzer)' {
    BeforeAll {
        $script:Pssa = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
    }
    It '<Name> uses only 5.1 syntax and commands' -ForEach $script:ShippedFiles {
        if (-not $script:Pssa) { Set-ItResult -Skipped -Because 'PSScriptAnalyzer not installed'; return }
        Import-Module $script:Pssa -Force
        $settings = @{
            Rules = @{
                PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1') }
                PSUseCompatibleCommands = @{ Enable = $true; TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') }
                PSUseCompatibleTypes    = @{ Enable = $true; TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework') }
            }
            IncludeRules = @('PSUseCompatibleSyntax', 'PSUseCompatibleCommands', 'PSUseCompatibleTypes')
        }
        # The 5.1 profile only knows the in-box Pester 3.4; the runner imports Pester 5 explicitly.
        $found = @(Invoke-ScriptAnalyzer -Path $Path -Settings $settings | Where-Object { $_.Message -notmatch "'(Invoke-Pester|New-PesterConfiguration)'" })
        $found.Count | Should -Be 0 -Because (($found | ForEach-Object { "L$($_.Line): $($_.Message)" }) -join ' | ')
    }
}

Describe 'XAML (static)' {
    It '<Name> is well-formed and loader-safe' -ForEach $script:XamlFiles {
        $xml = New-Object System.Xml.XmlDocument
        { $xml.Load($Path) } | Should -Not -Throw
        $raw = Get-Content -Raw -LiteralPath $Path
        $raw | Should -Not -Match 'x:Class='
        $raw | Should -Not -Match '\s(Click|Checked|Loaded|SelectionChanged|MouseDown|KeyDown)="'
        $raw | Should -Not -Match '<!DOCTYPE'
    }
    It '<Name> references only existing string keys' -ForEach $script:XamlFiles {
        $raw = Get-Content -Raw -LiteralPath $Path
        foreach ($m in [regex]::Matches($raw, '\{DynamicResource str\.([^}]+)\}')) {
            $script:PtKeys | Should -Contain $m.Groups[1].Value
        }
    }
    It '<Name> references only existing style/brush keys' -ForEach $script:XamlFiles {
        $defined = @()
        foreach ($f in 'Dark.xaml', 'Styles.xaml') {
            $defined += [regex]::Matches((Get-Content -Raw (Join-Path $script:SrcRoot "UI/Themes/$f")), 'x:Key="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        }
        $raw = Get-Content -Raw -LiteralPath $Path
        foreach ($m in [regex]::Matches($raw, '\{(?:Dynamic|Static)Resource ([^}\s]+)\}')) {
            $k = $m.Groups[1].Value
            if ($k -like 'str.*') { continue }
            $defined | Should -Contain $k
        }
    }
    It 'every element looked up by the UI module exists in some XAML' {
        $ui = Get-Content -Raw (Join-Path $script:SrcRoot 'UI/WinCare.UI.psm1')
        $names = @([regex]::Matches($ui, "FindName\('([A-Za-z]+)'\)") | ForEach-Object { $_.Groups[1].Value }) +
                 @([regex]::Matches($ui, "Get-WcUiElement \`$window '([A-Za-z]+)'") | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        $allXaml = (Get-ChildItem (Join-Path $script:SrcRoot 'UI') -Recurse -Filter *.xaml | ForEach-Object { Get-Content -Raw $_.FullName }) -join "`n"
        foreach ($n in $names) { $allXaml | Should -Match ('x:Name="' + $n + '"') -Because "UI module uses '$n'" }
        # Dynamic names built from loops.
        foreach ($n in 'ProfileDiagnostico', 'ProfileConservador', 'ProfileCorporativo', 'ProfileAvancado') { $allXaml | Should -Match ('x:Name="' + $n + '"') }
    }
    It 'every page referenced by the UI module exists' {
        $ui = Get-Content -Raw (Join-Path $script:SrcRoot 'UI/WinCare.UI.psm1')
        foreach ($m in [regex]::Matches($ui, "Xaml = '([A-Za-z]+\.xaml)'")) {
            Test-Path (Join-Path $script:SrcRoot ('UI/Pages/' + $m.Groups[1].Value)) | Should -BeTrue
        }
    }
    It 'every navigation tag has a page and a title' {
        $main = Get-Content -Raw (Join-Path $script:SrcRoot 'UI/MainWindow.xaml')
        $ui = Get-Content -Raw (Join-Path $script:SrcRoot 'UI/WinCare.UI.psm1')
        $tags = @([regex]::Matches($main, 'Tag="([a-z]+)"') | ForEach-Object { $_.Groups[1].Value })
        $tags.Count | Should -Be 15
        foreach ($t in $tags) {
            $ui | Should -Match ("(?m)^\s+$t\s+= @\{")
            $script:PtKeys | Should -Contain "nav.$t"
        }
    }
}

Describe 'Localization' {
    It 'pt-BR and en-US have the same keys' {
        Compare-Object $script:PtKeys $script:EnKeys | Should -BeNullOrEmpty
    }
    It 'placeholders match between languages' {
        foreach ($k in $script:PtKeys) {
            $a = $script:Pt.$k; $b = $script:En.$k
            if ($a -isnot [string]) { continue }
            $pa = @([regex]::Matches($a, '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique)
            $pb = @([regex]::Matches($b, '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique)
            ($pa -join ',') | Should -Be ($pb -join ',') -Because "key $k"
        }
    }
    It 'every grid column, policy reason, signal and catalog title is translated' {
        $ui = Get-Content -Raw (Join-Path $script:SrcRoot 'UI/WinCare.UI.psm1')
        $core = Get-Content -Raw (Join-Path $script:SrcRoot 'Core/WinCare.Core.psm1')
        foreach ($m in [regex]::Matches($core, "'(policy\.[a-z\-]+)'")) { $script:PtKeys | Should -Contain $m.Groups[1].Value }
        foreach ($s in 'DomainJoined', 'AzureAdJoined', 'MdmEnrolled', 'PolicyKeys') { $script:PtKeys | Should -Contain "signal.$s" }
        $cat = Get-Content -Raw (Join-Path $script:SrcRoot 'Core/actions.json') | ConvertFrom-Json
        foreach ($a in $cat.actions) { $script:PtKeys | Should -Contain $a.TitleKey }
        # Columns: every property used in grid rows built by the UI.
        $cols = 'Item', 'Value', 'Source', 'Section', 'Status', 'Error', 'Drive', 'Label', 'FileSystem', 'Size', 'Free', 'FreePercent', 'MediaType', 'BusType', 'Model', 'IsSystem',
        'Name', 'Id', 'Memory', 'CpuSecondsTotal', 'Company', 'Command', 'Location', 'User', 'Signal', 'Detected', 'Protection', 'State', 'File', 'Modified'
        foreach ($c in $cols) { $script:PtKeys | Should -Contain "col.$c" }
        foreach ($m in [regex]::Matches($ui, "Get-WcString '([a-z][a-z0-9\.\-]+)'")) { $script:PtKeys | Should -Contain $m.Groups[1].Value }
    }
}

Describe 'Theme contrast (WCAG 2.x AA)' {
    BeforeAll {
        function Get-Lum([string] $hex) {
            $c = @(1, 3, 5) | ForEach-Object { [Convert]::ToInt32($hex.Substring($_, 2), 16) / 255.0 }
            $l = $c | ForEach-Object { if ($_ -le 0.03928) { $_ / 12.92 } else { [math]::Pow(($_ + 0.055) / 1.055, 2.4) } }
            return 0.2126 * $l[0] + 0.7152 * $l[1] + 0.0722 * $l[2]
        }
        function Get-Ratio([string] $a, [string] $b) {
            $x = Get-Lum $a; $y = Get-Lum $b
            return ([math]::Max($x, $y) + 0.05) / ([math]::Min($x, $y) + 0.05)
        }
    }
    It '<_> theme meets 4.5:1 for text roles on every surface' -ForEach @('Dark', 'Light') {
        $raw = Get-Content -Raw (Join-Path $script:SrcRoot "UI/Themes/$_.xaml")
        $c = @{}
        foreach ($m in [regex]::Matches($raw, 'x:Key="Brush\.([A-Za-z]+)" Color="(#[0-9A-Fa-f]{6})"')) { $c[$m.Groups[1].Value] = $m.Groups[2].Value }
        foreach ($fg in 'Text', 'Muted', 'Critical', 'Warning', 'Info', 'Ok') {
            foreach ($bg in 'Bg', 'Surface', 'SurfaceAlt') {
                [math]::Round((Get-Ratio $c[$fg] $c[$bg]), 2) | Should -BeGreaterOrEqual 4.5 -Because "$fg on $bg"
            }
        }
        [math]::Round((Get-Ratio $c['OnAccent'] $c['Accent']), 2) | Should -BeGreaterOrEqual 4.5 -Because 'button text'
    }
}

Describe 'Module manifest' {
    It 'is valid and lists existing nested modules' {
        $m = Test-ModuleManifest -Path (Join-Path $script:SrcRoot 'WinCare.psd1') -ErrorAction Stop
        $m.Version.ToString() | Should -Match '^\d+\.\d+\.\d+$'
        $data = Import-PowerShellDataFile (Join-Path $script:SrcRoot 'WinCare.psd1')
        foreach ($n in $data.NestedModules) { Test-Path (Join-Path $script:SrcRoot $n) | Should -BeTrue }
    }
    It 'imports and exposes the public functions' {
        Import-Module (Join-Path $script:SrcRoot 'WinCare.psd1') -Force -DisableNameChecking
        foreach ($f in 'Invoke-WcDiagnostic', 'Export-WcReport', 'New-WcPlan', 'Get-WcVolumeInfo') { Get-Command $f -ErrorAction Stop | Should -Not -BeNullOrEmpty }
    }
    It 'imports in a clean session and every catalog action has a handler' {
        # Regression: nested modules cannot call Core during manifest import (found on real Windows CI).
        $ps = [System.Management.Automation.PowerShell]::Create([System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault())
        try {
            [void]$ps.AddScript({
                    param($src)
                    $ErrorActionPreference = 'Stop'
                    Import-Module (Join-Path $src 'WinCare.psd1') -DisableNameChecking
                    $cat = Import-WcActionCatalog -Path (Join-Path $src 'Core/actions.json')
                    $plan = New-WcPlan -Catalog $cat -ActionId @($cat | ForEach-Object { $_.Id }) -OperationProfile (Get-WcProfile 'Avancado') -Context (New-WcContext -IsAdmin $true -Build 26100)
                    @($plan.Items | Where-Object { @($_.Reasons) -contains 'policy.no-handler' } | ForEach-Object { $_.ActionId })
                }).AddArgument($script:SrcRoot)
            $missing = @($ps.Invoke())
            @($ps.Streams.Error).Count | Should -Be 0 -Because (($ps.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')
            $missing.Count | Should -Be 0 -Because ($missing -join ', ')
        }
        finally { $ps.Dispose() }
    }
}

Describe 'PS 5.1 pitfalls' {
    It '<Name> never combines Get-ChildItem -LiteralPath with -Include (5.1 ignores -Include)' -ForEach $script:ShippedFiles {
        Get-Content -Raw -LiteralPath $Path | Should -Not -Match 'Get-ChildItem\s+-LiteralPath[^|\r\n]*-Include'
    }
}
