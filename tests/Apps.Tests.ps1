#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# WinCare.Apps (F6). Pure converters with fixtures (tests/fixtures/apps, UTF-8 with
# accented names); registry, winget, Appx and Settings access are always mocked.
# winget upgrade and Reset-AppxPackage never run here.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @('Apps')
    Initialize-WcLog -Path (Join-Path (New-WcTestDir) 'apps.jsonl') | Out-Null
    $script:Fix = Join-Path $PSScriptRoot 'fixtures/apps'
    function Get-FixtureText([string] $Name) { ConvertFrom-WcNativeOutputBytes -Bytes ([System.IO.File]::ReadAllBytes((Join-Path $script:Fix $Name))) }
    function Get-LocKeys([string] $Lang) {
        $keys = @((Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot "Localization/$Lang.json") | ConvertFrom-Json).PSObject.Properties.Name)
        foreach ($f in Get-ChildItem (Join-Path $script:SrcRoot "Localization/$Lang.d") -Filter '*.json') {
            $keys += @((Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json).PSObject.Properties.Name)
        }
        return $keys
    }
    # Accented strings built from code points: .ps1 files must stay ASCII-only.
    $script:AvancadoName = 'Bloco de Notas Avan' + [char]0x00E7 + 'ado'
    $script:AcaoName = 'Ferramenta de A' + [char]0x00E7 + [char]0x00E3 + 'o ' + [char]0x00DA + 'til'
}

Describe 'Selection contract' {
    It 'reads the ids of one action from Context.Selection' {
        $ctx = New-WcContext
        $ctx.Selection = @{ 'apps.winget-upgrade' = @('Microsoft.Edge', 'Mozilla.Firefox'); 'apps.store-reset' = @('x') }
        Get-WcAppsSelection -Context $ctx -ActionId 'apps.winget-upgrade' | Should -Be @('Microsoft.Edge', 'Mozilla.Firefox')
    }
    It 'returns an empty list without context, selection or key' {
        @(Get-WcAppsSelection -Context $null -ActionId 'apps.winget-upgrade').Count | Should -Be 0
        @(Get-WcAppsSelection -Context (New-WcContext) -ActionId 'apps.winget-upgrade').Count | Should -Be 0
        $ctx = New-WcContext; $ctx.Selection = @{ other = @('a') }
        @(Get-WcAppsSelection -Context $ctx -ActionId 'apps.winget-upgrade').Count | Should -Be 0
    }
    It 'accepts a single id given as a plain string' {
        $ctx = New-WcContext; $ctx.Selection = @{ 'apps.winget-upgrade' = 'Git.Git' }
        @(Get-WcAppsSelection -Context $ctx -ActionId 'apps.winget-upgrade') | Should -Be @('Git.Git')
    }
    It 'accepts valid winget id <_>' -ForEach @('Microsoft.Edge', 'Notepad++.Notepad++', '9NKSQGP7F2NH', 'Git.Git', 'a', 'Python.Python.3.12', 'Vendor.App_x', ('a' * 128)) {
        Test-WcWingetPackageId -Id $_ | Should -BeTrue
    }
    It 'rejects invalid winget id <_>' -ForEach @('', 'a b', 'x;calc', '--all', '-h', 'a&b', 'a|b', '"x"', '..\x', ('a' * 129), 'x`y', 'id$(1)') {
        Test-WcWingetPackageId -Id $_ | Should -BeFalse
    }
    It 'validates, de-duplicates and caps a selection' {
        ConvertTo-WcPackageSelection -InputObject @('Git.Git', 'git.git', 'Microsoft.Edge') | Should -Be @('Git.Git', 'Microsoft.Edge')
        { ConvertTo-WcPackageSelection -InputObject @('Git.Git', 'bad id') } | Should -Throw '*Invalid WingetId*'
        { ConvertTo-WcPackageSelection -InputObject @('A.One', 'B.Two') -Max 1 } | Should -Throw '*Too many*'
        @(ConvertTo-WcPackageSelection -InputObject @()).Count | Should -Be 0
    }
    It 'validates Store package full names' {
        Test-WcAppxPackageFullName -FullName 'Microsoft.WindowsCalculator_11.2210.0.0_x64__8wekyb3d8bbwe' | Should -BeTrue
        Test-WcAppxPackageFullName -FullName 'Microsoft.WindowsStore_22210.1401.6.0_neutral_~_8wekyb3d8bbwe' | Should -BeTrue
        foreach ($bad in @('Microsoft.WindowsCalculator', 'x_1_x64__short', 'a b_1.0_x64__8wekyb3d8bbwe', '*_1.0_x64__8wekyb3d8bbwe')) {
            Test-WcAppxPackageFullName -FullName $bad | Should -BeFalse -Because $bad
        }
    }
}

Describe 'Installed programs (Uninstall keys)' {
    It 'extracts <Exe> from <Cmd>' -ForEach @(
        @{ Cmd = '"C:\Program Files\App\unins000.exe" /SILENT'; Exe = 'C:\Program Files\App\unins000.exe'; Checkable = $true; Msi = $false }
        @{ Cmd = 'C:\Program Files\Other App\uninst.exe /S /D=C:\x'; Exe = 'C:\Program Files\Other App\uninst.exe'; Checkable = $true; Msi = $false }
        @{ Cmd = 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'; Exe = 'MsiExec.exe'; Checkable = $false; Msi = $true }
        @{ Cmd = 'rundll32.exe dfshim.dll,ShArpMaintain app.application'; Exe = 'rundll32.exe'; Checkable = $false; Msi = $false }
        @{ Cmd = '"C:\Users\u\AppData\Local\App\Update.exe" --uninstall -s'; Exe = 'C:\Users\u\AppData\Local\App\Update.exe'; Checkable = $true; Msi = $false }
    ) {
        $r = ConvertTo-WcUninstallExecutable -UninstallString $Cmd
        $r.Executable | Should -Be $Exe
        $r.Checkable | Should -Be $Checkable
        $r.IsMsi | Should -Be $Msi
    }
    It 'returns nothing for an empty uninstall string' {
        (ConvertTo-WcUninstallExecutable -UninstallString '').Executable | Should -BeNullOrEmpty
        (ConvertTo-WcUninstallExecutable -UninstallString '   ').Checkable | Should -BeFalse
    }
    It 'formats InstallDate yyyyMMdd and keeps unknown formats raw' {
        ConvertTo-WcInstallDate -Value '20240131' | Should -Be '2024-01-31'
        ConvertTo-WcInstallDate -Value '1/31/2024' | Should -Be '1/31/2024'
        ConvertTo-WcInstallDate -Value $null | Should -Be ''
    }
    Context 'rows' {
        BeforeAll {
            $script:Entries = @(
                @{ DisplayName = 'Good App'; DisplayVersion = '1.0'; Publisher = 'ACME'; InstallDate = '20240102'; EstimatedSize = 2048; UninstallString = '"C:\Apps\Good\uninst.exe" /S'; Hive = 'HKLM64' }
                @{ DisplayName = 'Gone App'; DisplayVersion = '2.0'; Publisher = 'ACME'; UninstallString = 'C:\Apps\Gone\uninst.exe /quiet /token=SECRET'; Hive = 'HKLM32' }
                @{ DisplayName = 'Msi App'; DisplayVersion = '3.0'; UninstallString = 'MsiExec.exe /I{AAAA}'; WindowsInstaller = 1; Hive = 'HKLM64' }
                @{ DisplayName = 'User App'; DisplayVersion = '4.0'; Hive = 'HKCU' }
                @{ DisplayName = 'Hidden Component'; SystemComponent = 1; UninstallString = 'C:\x.exe'; Hive = 'HKLM64' }
                @{ DisplayName = 'Security Update for X'; ParentKeyName = 'X'; Hive = 'HKLM64' }
                @{ DisplayName = 'KB123'; ReleaseType = 'Security Update'; Hive = 'HKLM64' }
                @{ DisplayName = ''; Hive = 'HKLM64' }
                @{ DisplayName = 'Good App'; DisplayVersion = '1.0'; Publisher = 'ACME'; UninstallString = '"C:\Apps\Good\uninst.exe" /S'; Hive = 'HKLM64' }
                @{ DisplayName = $script:AvancadoName; DisplayVersion = '5.0'; UninstallString = '"C:\Apps\Bloco\unins.exe"'; Hive = 'HKCU' }
            )
            $exists = { param($p) $p -like 'C:\Apps\Good\*' -or $p -like 'C:\Apps\Bloco\*' }
            $script:Rows = @(ConvertTo-WcInstalledProgram -Entry $script:Entries -PathExists $exists)
        }
        It 'hides system components, updates and nameless entries and de-duplicates' {
            $script:Rows.Count | Should -Be 5
            $script:Rows.Name | Should -Not -Contain 'Hidden Component'
            $script:Rows.Name | Should -Not -Contain 'KB123'
            @($script:Rows | Where-Object { $_.Name -eq 'Good App' }).Count | Should -Be 1
        }
        It 'flags a missing uninstaller file and keeps accented names' {
            ($script:Rows | Where-Object Name -eq 'Gone App').Uninstall | Should -Be 'MissingFile'
            ($script:Rows | Where-Object Name -eq 'Good App').Uninstall | Should -Be 'OK'
            ($script:Rows | Where-Object Name -eq 'Msi App').Uninstall | Should -Be 'MSI'
            ($script:Rows | Where-Object Name -eq 'User App').Uninstall | Should -Be 'NoUninstaller'
            ($script:Rows | Where-Object Name -eq $script:AvancadoName).Uninstall | Should -Be 'OK'
        }
        It 'never exposes uninstall arguments' {
            foreach ($r in $script:Rows) {
                foreach ($p in $r.PSObject.Properties) { [string]$p.Value | Should -Not -Match 'SECRET|/quiet|/S$|/I\{' }
            }
            ($script:Rows | Where-Object Name -eq 'Gone App').Executable | Should -Be 'C:\Apps\Gone\uninst.exe'
        }
        It 'formats size, date and scope' {
            $g = $script:Rows | Where-Object Name -eq 'Good App'
            $g.SizeRaw | Should -Be 2097152
            $g.Size | Should -Be ('{0:N0} MB' -f 2)
            $g.InstallDate | Should -Be '2024-01-02'
            $g.Scope | Should -Be 'Machine x64'
            ($script:Rows | Where-Object Name -eq 'Gone App').Scope | Should -Be 'Machine x86'
            ($script:Rows | Where-Object Name -eq 'User App').Scope | Should -Be 'User'
        }
        It 'lists only missing-file entries as broken' {
            $b = @(ConvertTo-WcBrokenUninstallRow -Program $script:Rows)
            $b.Count | Should -Be 1
            $b[0].Name | Should -Be 'Gone App'
            @($b[0].PSObject.Properties.Name) | Should -Be @('Name', 'Version', 'Scope', 'Executable')
        }
        It 'treats a failing existence test as missing, not as an error' {
            $r = @(ConvertTo-WcInstalledProgram -Entry @($script:Entries[0]) -PathExists { throw 'denied' })
            $r[0].Uninstall | Should -Be 'MissingFile'
        }
    }
}

Describe 'Native output decoding' {
    It 'decodes UTF-8 (accented names) and strips ANSI/VT escapes' {
        $t = Get-FixtureText 'winget-upgrade-pt-BR.txt'
        $t | Should -Match ([regex]::Escape($script:AvancadoName))
        $en = Get-FixtureText 'winget-upgrade-en-US.txt'
        $en | Should -Not -Match ([string][char]27)
    }
    It 'falls back to the OEM code page (cp850) when the bytes are not valid UTF-8' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:Fix 'winget-upgrade-pt-BR.txt'), [System.Text.Encoding]::UTF8)
        $bytes = [System.Text.Encoding]::GetEncoding(850).GetBytes($text)
        $decoded = ConvertFrom-WcNativeOutputBytes -Bytes $bytes -FallbackCodePage 850
        $decoded | Should -Match ([regex]::Escape($script:AcaoName))
    }
    It 'decodes UTF-16LE with BOM and removes NULs' {
        $bytes = [byte[]](@(0xFF, 0xFE) + [System.Text.Encoding]::Unicode.GetBytes('Caf' + [char]0x00E9 + [char]0 + 'X'))
        ConvertFrom-WcNativeOutputBytes -Bytes $bytes | Should -Be ('Caf' + [char]0x00E9 + 'X')
    }
    It 'returns an empty string for no output' {
        ConvertFrom-WcNativeOutputBytes -Bytes @() | Should -Be ''
    }
}

Describe 'winget table parsing' {
    It 'parses the en-US table, the explicit-targeting table and ignores the footer' {
        $r = ConvertFrom-WcWingetTable -Text (Get-FixtureText 'winget-upgrade-en-US.txt')
        $r.TableFound | Should -BeTrue
        $r.Unparsed | Should -Be 0
        @($r.Rows).Count | Should -Be 6
        $r.Rows[0].Id | Should -Be 'Microsoft.Edge'
        $r.Rows[0].Available | Should -Be '119.0.2151.44'
        ($r.Rows | Where-Object Id -eq 'Vendor.LongApp').Version | Should -Be '< 2.0'
        ($r.Rows | Where-Object Id -eq 'Microsoft.Teams.Classic').Version | Should -Be 'Unknown'
        ($r.Rows | Where-Object Id -eq 'Notepad++.Notepad++').Name | Should -Be 'Notepad++ (64-bit x64)'
        $r.Rows.Id | Should -Contain 'Discord.Discord'
    }
    It 'parses a localized (pt-BR) header and accented names by position' {
        $r = ConvertFrom-WcWingetTable -Text (Get-FixtureText 'winget-upgrade-pt-BR.txt')
        @($r.Rows).Count | Should -Be 4
        $r.Unparsed | Should -Be 0
        ($r.Rows | Where-Object Id -eq 'Exemplo.Acao').Name | Should -Be $script:AcaoName
        ($r.Rows | Where-Object Id -eq '9NKSQGP7F2NH').Source | Should -Be 'msstore'
    }
    It 'handles a 4-column table and counts a misaligned (wide character) row as unparsed' {
        $r = ConvertFrom-WcWingetTable -Text (Get-FixtureText 'winget-upgrade-4col.txt')
        @($r.Rows).Id | Should -Be @('Vendor.One', 'Vendor.Two')
        $r.Rows[0].Source | Should -Be ''
        $r.Unparsed | Should -Be 1
    }
    It 'finds no table when there are no updates' {
        $r = ConvertFrom-WcWingetTable -Text (Get-FixtureText 'winget-upgrade-none-en-US.txt')
        $r.TableFound | Should -BeFalse
        @($r.Rows).Count | Should -Be 0
    }
    It 'turns the listing into Ok / NoUpdates / Failed' {
        $ok = ConvertTo-WcWingetListResult -ExitCode 0 -Text (Get-FixtureText 'winget-upgrade-en-US.txt')
        $ok.Status | Should -Be 'Ok'
        @($ok.Rows[0].PSObject.Properties.Name) | Should -Be @('Name', 'PackageId', 'Version', 'Available', 'Source')
        (ConvertTo-WcWingetListResult -ExitCode 0 -Text (Get-FixtureText 'winget-upgrade-none-en-US.txt')).Status | Should -Be 'NoUpdates'
        (ConvertTo-WcWingetListResult -ExitCode -1978335189 -Text '').Status | Should -Be 'NoUpdates'
        $f = ConvertTo-WcWingetListResult -ExitCode -1978335162 -Text "Source agreements were not agreed to`r`n"
        $f.Status | Should -Be 'Failed'
        $f.Reason | Should -Be 'source-agreements-not-accepted'
        $f.Detail | Should -Match '0x8A150046'
        (ConvertTo-WcWingetListResult -ExitCode $null -Text '' -TimedOut $true).Reason | Should -Be 'timeout'
    }
    It 'never reports no updates when a table was printed but could not be read' {
        $text = "  junk Name   Id   Version   Available`r`n----------------------------`r`nApp  X.Y  1  2`r`n"
        $r = ConvertTo-WcWingetListResult -ExitCode 0 -Text $text
        $r.Status | Should -Be 'Failed'
        $r.Reason | Should -Be 'unparsed-output'
    }
}

Describe 'winget options and exit codes' {
    It 'detects --disable-interactivity from help text' {
        $new = "Options`r`n  --accept-source-agreements    Accept all source agreements`r`n  --disable-interactivity       Disable interactive prompts`r`n"
        $old = "Options`r`n  --accept-source-agreements    Accept all source agreements`r`n  --disable-interactivity-x  other`r`n"
        Test-WcWingetFlagSupported -HelpText $new -Flag '--disable-interactivity' | Should -BeTrue
        Test-WcWingetFlagSupported -HelpText $old -Flag '--disable-interactivity' | Should -BeFalse
        Test-WcWingetFlagSupported -HelpText '' -Flag '--disable-interactivity' | Should -BeFalse
    }
    It 'builds per-package upgrade arguments, never --all' {
        $a = Get-WcWingetUpgradeArgument -Id 'Microsoft.Edge' -DisableInteractivity $true
        $a | Should -Contain '--exact'
        $a | Should -Contain '--silent'
        $a | Should -Contain '--disable-interactivity'
        $a[$a.IndexOf('--id') + 1] | Should -Be 'Microsoft.Edge'
        $a | Should -Not -Contain '--all'
        $a | Should -Not -Contain '-r'
        (Get-WcWingetUpgradeArgument -Id 'Git.Git') | Should -Not -Contain '--disable-interactivity'
        { Get-WcWingetUpgradeArgument -Id '--all' } | Should -Throw
        Get-WcWingetListArgument -DisableInteractivity $false | Should -Be @('upgrade', '--include-unknown', '--accept-source-agreements')
    }
    It 'maps exit code <Code> to <Status>' -ForEach @(
        @{ Code = 0; Status = 'Succeeded' }
        @{ Code = -1978334967; Status = 'SucceededRebootRequired' }
        @{ Code = -1978335189; Status = 'NoUpdate' }
        @{ Code = -1978334961; Status = 'BlockedByPolicy' }
        @{ Code = -1978335174; Status = 'BlockedByPolicy' }
        @{ Code = -1978334975; Status = 'Failed' }
        @{ Code = 2316632107; Status = 'NoUpdate' }
        @{ Code = 1603; Status = 'Failed' }
    ) {
        (ConvertTo-WcWingetExitResult -ExitCode $Code).Status | Should -Be $Status
    }
    It 'reports the hex code of unknown failures' {
        $r = ConvertTo-WcWingetExitResult -ExitCode -1978334975
        $r.Hex | Should -Be '0x8A150101'
        $r.Reason | Should -Be 'package-in-use'
        (ConvertTo-WcWingetExitResult -ExitCode 1603).Reason | Should -Be 'exit-code'
    }
}

Describe 'Store apps' {
    It 'lists only packages whose status is not Ok' {
        $pk = @(
            [pscustomobject]@{ Name = 'Microsoft.WindowsCalculator'; Version = '11.0'; Status = 'Ok'; PackageFullName = 'a' }
            [pscustomobject]@{ Name = 'Contoso.App'; Version = '1.2'; Status = 'Modified, Tampered'; PackageFullName = 'Contoso.App_1.2.0.0_x64__abcdefghijklm' }
            [pscustomobject]@{ Name = 'Microsoft.Photos'; Version = '2.0'; Status = 'NeedsRemediation'; PackageFullName = 'Microsoft.Photos_2.0.0.0_x64__8wekyb3d8bbwe' }
        )
        $r = @(ConvertTo-WcAppxProblemRow -Package $pk)
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'Contoso.App'
        @($r[0].PSObject.Properties.Name) | Should -Be @('Name', 'Version', 'Status', 'PackageFullName')
    }
}

Describe 'Get-WcAppsPageData' {
    BeforeAll {
        $script:PtKeys = @(Get-LocKeys 'pt-BR')
        $script:EnKeys = @(Get-LocKeys 'en-US')
    }
    BeforeEach {
        Mock -ModuleName WinCare.Apps Get-WcUninstallEntry { @(@{ DisplayName = 'Gone'; DisplayVersion = '1'; UninstallString = 'C:\nope\u.exe'; Hive = 'HKLM64' }) }
        Mock -ModuleName WinCare.Apps Test-WcAppsFileExists { $false }
        Mock -ModuleName WinCare.Apps Get-WcAppxPackageRaw { @([pscustomobject]@{ Name = 'Contoso.App'; Version = '1'; Status = 'LicenseIssue'; PackageFullName = 'Contoso.App_1.0.0.0_x64__abcdefghijklm' }) }
        Mock -ModuleName WinCare.Apps Get-WcWingetCapability { [pscustomobject]@{ Available = $true; Reason = 'ok'; DisableInteractivity = $true } }
        Mock -ModuleName WinCare.Apps Invoke-WcWinget { [pscustomobject]@{ ExitCode = 0; Text = (Get-FixtureText 'winget-upgrade-pt-BR.txt'); TimedOut = $false } }
    }
    It 'returns the four sections with translated titles, notes and columns' {
        $d = Get-WcAppsPageData
        $d.PageId | Should -Be 'apps'
        @($d.Sections.Id) | Should -Be @('installed', 'broken-uninstall', 'winget-updates', 'store-problems')
        @($d.Errors).Count | Should -Be 0
        foreach ($s in $d.Sections) {
            $script:PtKeys | Should -Contain $s.TitleKey
            if ($s.NoteKey) { $script:PtKeys | Should -Contain $s.NoteKey; $script:EnKeys | Should -Contain $s.NoteKey }
            foreach ($r in @($s.Rows)) {
                foreach ($p in $r.PSObject.Properties.Name) {
                    $script:PtKeys | Should -Contain "col.$p"
                    $script:EnKeys | Should -Contain "col.$p"
                }
            }
        }
        ($d.Sections | Where-Object Id -eq 'broken-uninstall').Severity | Should -Be 'Warning'
        @(($d.Sections | Where-Object Id -eq 'winget-updates').Rows).Count | Should -Be 4
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--include-unknown' -and $ArgumentList -notcontains '--all' -and $ArgumentList -notcontains '--id' }
    }
    It 'explains why winget is unavailable (<Reason>)' -ForEach @(@{ Reason = 'not-found' }, @{ Reason = 'system-context' }) {
        Mock -ModuleName WinCare.Apps Get-WcWingetCapability { [pscustomobject]@{ Available = $false; Reason = $Reason; DisableInteractivity = $false } }
        $s = (Get-WcAppsPageData).Sections | Where-Object Id -eq 'winget-updates'
        $s.NoteKey | Should -Be "section.apps.winget-updates.note.$Reason"
        $script:PtKeys | Should -Contain $s.NoteKey
        @($s.Rows).Count | Should -Be 0
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 0
    }
    It 'shows the winget failure code as Status/Detail rows' {
        Mock -ModuleName WinCare.Apps Invoke-WcWinget { [pscustomobject]@{ ExitCode = -1978335162; Text = 'agreements'; TimedOut = $false } }
        $s = (Get-WcAppsPageData).Sections | Where-Object Id -eq 'winget-updates'
        $s.NoteKey | Should -Be 'section.apps.winget-updates.note.failed'
        $s.Rows[0].Status | Should -Be 'source-agreements-not-accepted'
        $s.Severity | Should -Be 'Warning'
    }
    It 'never throws: a failing section goes to Errors' {
        Mock -ModuleName WinCare.Apps Get-WcAppxPackageRaw { throw 'Appx unavailable' }
        Mock -ModuleName WinCare.Apps Get-WcUninstallEntry { throw 'registry denied' }
        $d = Get-WcAppsPageData
        @($d.Errors) | Should -Contain 'store-problems: Appx unavailable'
        @($d.Errors) | Should -Contain 'installed: registry denied'
        @($d.Sections).Count | Should -Be 4
    }
}

Describe 'apps.winget-upgrade handler' {
    BeforeEach {
        Mock -ModuleName WinCare.Apps Get-WcWingetCapability { [pscustomobject]@{ Available = $true; Reason = 'ok'; DisableInteractivity = $true } }
        Mock -ModuleName WinCare.Apps Invoke-WcWinget {
            if ($ArgumentList -contains '--id') { [pscustomobject]@{ ExitCode = 0; Text = 'Successfully installed'; TimedOut = $false } }
            else { [pscustomobject]@{ ExitCode = 0; Text = (Get-FixtureText 'winget-upgrade-en-US.txt'); TimedOut = $false } }
        }
        $script:Ctx = New-WcContext
        $script:Ctx.Selection = @{ 'apps.winget-upgrade' = @('Microsoft.Edge', 'Not.Listed') }
    }
    It 'Preview lists the selected ids and runs nothing' {
        $r = Invoke-WcWingetUpgradeAction -Context $script:Ctx
        $r.Summary | Should -Match '^Would upgrade 2 selected'
        @($r.Items.PackageId) | Should -Be @('Microsoft.Edge', 'Not.Listed')
        $r.Items[0].Command | Should -Match '--id Microsoft.Edge --exact'
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 0
        Should -Invoke -ModuleName WinCare.Apps Get-WcWingetCapability -Times 0
    }
    It 'Preview without selection says nothing would happen' {
        (Invoke-WcWingetUpgradeAction -Context (New-WcContext)).Summary | Should -Match '^No package selected'
    }
    It 'refuses an invalid id before running anything (Preview and Execute)' {
        $script:Ctx.Selection['apps.winget-upgrade'] = @('Microsoft.Edge', '--all')
        { Invoke-WcWingetUpgradeAction -Context $script:Ctx } | Should -Throw '*Invalid*'
        { Invoke-WcWingetUpgradeAction -Context $script:Ctx -Execute } | Should -Throw '*Invalid*'
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 0
    }
    It 'Execute upgrades only listed selected ids, one run per id, never --all' {
        $r = Invoke-WcWingetUpgradeAction -Context $script:Ctx -Execute
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--id' }
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 1 -Exactly -ParameterFilter { $ArgumentList -contains '--id' -and $ArgumentList -contains 'Microsoft.Edge' -and $ArgumentList -contains '--disable-interactivity' }
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 0 -ParameterFilter { $ArgumentList -contains '--all' -or $ArgumentList -contains '-r' -or $ArgumentList -contains '--recurse' }
        ($r.Items | Where-Object PackageId -eq 'Not.Listed').Status | Should -Be 'Skipped'
        ($r.Items | Where-Object PackageId -eq 'Microsoft.Edge').Status | Should -Be 'Succeeded'
        $r.Summary | Should -Match '1 upgraded'
    }
    It 'maps exit codes per package and throws when nothing succeeded' {
        Mock -ModuleName WinCare.Apps Invoke-WcWinget {
            if ($ArgumentList -contains '--id') { [pscustomobject]@{ ExitCode = -1978334975; Text = 'in use'; TimedOut = $false } }
            else { [pscustomobject]@{ ExitCode = 0; Text = (Get-FixtureText 'winget-upgrade-en-US.txt'); TimedOut = $false } }
        }
        $script:Ctx.Selection['apps.winget-upgrade'] = @('Microsoft.Edge')
        { Invoke-WcWingetUpgradeAction -Context $script:Ctx -Execute } | Should -Throw '*1 failed*'
    }
    It 'reports a restart need without restarting' {
        Mock -ModuleName WinCare.Apps Invoke-WcWinget {
            if ($ArgumentList -contains '--id') { [pscustomobject]@{ ExitCode = -1978334967; Text = ''; TimedOut = $false } }
            else { [pscustomobject]@{ ExitCode = 0; Text = (Get-FixtureText 'winget-upgrade-en-US.txt'); TimedOut = $false } }
        }
        $script:Ctx.Selection['apps.winget-upgrade'] = @('Mozilla.Firefox')
        $r = Invoke-WcWingetUpgradeAction -Context $script:Ctx -Execute
        $r.Items[0].Status | Should -Be 'SucceededRebootRequired'
        $r.Summary | Should -Match 'does not restart'
    }
    It 'Execute fails clearly when winget is unavailable' {
        Mock -ModuleName WinCare.Apps Get-WcWingetCapability { [pscustomobject]@{ Available = $false; Reason = 'system-context'; DisableInteractivity = $false } }
        { Invoke-WcWingetUpgradeAction -Context $script:Ctx -Execute } | Should -Throw '*system-context*'
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcWinget -Times 0
    }
    It 'Invoke-WcWinget refuses unsafe argument tokens' {
        { Invoke-WcWinget -ArgumentList @('upgrade', '--id', 'a b') } | Should -Throw '*Refusing*'
        { Invoke-WcWinget -ArgumentList @('upgrade', 'x;calc') } | Should -Throw '*Refusing*'
    }
}

Describe 'apps.store-reset and apps.open-repair handlers' {
    BeforeEach {
        Mock -ModuleName WinCare.Apps Invoke-WcAppxReset { }
        Mock -ModuleName WinCare.Apps Open-WcAppsSettings { }
        Mock -ModuleName WinCare.Apps Test-WcAppxResetAvailable { $true }
        Mock -ModuleName WinCare.Apps Get-WcAppxPackageRaw { @([pscustomobject]@{ Name = 'Contoso.App'; PackageFullName = 'Contoso.App_1.0.0.0_x64__abcdefghijklm'; IsFramework = $false }) }
        $script:Full = 'Contoso.App_1.0.0.0_x64__abcdefghijklm'
        $script:Ctx = New-WcContext
        $script:Ctx.Selection = @{ 'apps.store-reset' = @($script:Full); 'apps.open-repair' = @('Contoso App') }
    }
    It 'Store reset Preview warns about local data and resets nothing' {
        $r = Invoke-WcStoreResetAction -Context $script:Ctx
        $r.Summary | Should -Match 'local data'
        $r.Items[0].DeletesLocalData | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcAppxReset -Times 0
    }
    It 'Store reset is unavailable with a reason when Reset-AppxPackage is missing' {
        Mock -ModuleName WinCare.Apps Test-WcAppxResetAvailable { $false }
        (Invoke-WcStoreResetAction -Context $script:Ctx).Summary | Should -Match '^Unavailable: .*19041'
        { Invoke-WcStoreResetAction -Context $script:Ctx -Execute } | Should -Throw '*not available*'
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcAppxReset -Times 0
    }
    It 'Store reset Execute resets exactly the selected package of the current user' {
        $r = Invoke-WcStoreResetAction -Context $script:Ctx -Execute
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcAppxReset -Times 1 -Exactly -ParameterFilter { $PackageFullName -eq $script:Full }
        $r.Items[0].Status | Should -Be 'Reset'
    }
    It 'Store reset refuses frameworks, unknown packages, several or invalid selections' {
        Mock -ModuleName WinCare.Apps Get-WcAppxPackageRaw { @([pscustomobject]@{ Name = 'Contoso.App'; PackageFullName = 'Contoso.App_1.0.0.0_x64__abcdefghijklm'; IsFramework = $true }) }
        { Invoke-WcStoreResetAction -Context $script:Ctx -Execute } | Should -Throw '*framework*'
        Mock -ModuleName WinCare.Apps Get-WcAppxPackageRaw { @() }
        { Invoke-WcStoreResetAction -Context $script:Ctx -Execute } | Should -Throw '*not installed*'
        $script:Ctx.Selection['apps.store-reset'] = @($script:Full, 'Other.App_1.0.0.0_x64__abcdefghijklm')
        { Invoke-WcStoreResetAction -Context $script:Ctx -Execute } | Should -Throw '*Too many*'
        $script:Ctx.Selection['apps.store-reset'] = @('Contoso.App; rm')
        { Invoke-WcStoreResetAction -Context $script:Ctx -Execute } | Should -Throw '*Invalid*'
        Should -Invoke -ModuleName WinCare.Apps Invoke-WcAppxReset -Times 0
    }
    It 'open-repair Preview opens nothing; Execute opens Settings once' {
        (Invoke-WcAppsOpenRepairAction -Context $script:Ctx).Summary | Should -Match "Would open Settings.*'Contoso App'"
        Should -Invoke -ModuleName WinCare.Apps Open-WcAppsSettings -Times 0
        Invoke-WcAppsOpenRepairAction -Context $script:Ctx -Execute | Out-Null
        Should -Invoke -ModuleName WinCare.Apps Open-WcAppsSettings -Times 1 -Exactly
    }
    It 'the module never runs uninstallers or reset-all style commands' {
        $src = Get-Content -Raw (Join-Path $script:SrcRoot 'Modules/WinCare.Apps.psm1')
        $src | Should -Not -Match '(?i)Remove-AppxPackage|Uninstall-Package|msiexec\.exe\s*/x|Start-Process[^\r\n]*Uninstall'
        $src | Should -Not -Match "'--all'"
    }
}

Describe 'f6-apps catalog' {
    BeforeAll {
        $script:Cat = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Core/actions.d/f6-apps.json')
    }
    It 'every entry is valid, on the apps page, with title and description in both languages' {
        $pt = @(Get-LocKeys 'pt-BR'); $en = @(Get-LocKeys 'en-US')
        foreach ($a in $script:Cat.actions) {
            @(Test-WcActionDefinition -Action $a).Count | Should -Be 0 -Because $a.Id
            @($a.Pages) | Should -Be @('apps')
            $pt | Should -Contain $a.TitleKey; $en | Should -Contain $a.DescriptionKey
        }
    }
    It 'declares the agreed risk and policy flags' {
        $w = $script:Cat.actions | Where-Object { $_.Id -eq 'apps.winget-upgrade' }
        $w.Risk | Should -Be 'Medium'; $w.Modifies | Should -BeTrue; $w.Reversibility | Should -Be 'None'; $w.BlockedWhenManaged | Should -BeTrue
        ($script:Cat.actions | Where-Object { $_.Id -eq 'apps.store-reset' }).Risk | Should -Be 'Medium'
        ($script:Cat.actions | Where-Object { $_.Id -eq 'apps.open-repair' }).Risk | Should -Be 'Low'
    }
    It 'the Corporativo profile blocks winget upgrade even without detected management' {
        $a = $script:Cat.actions | Where-Object { $_.Id -eq 'apps.winget-upgrade' }
        $d = Test-WcActionAllowed -Action $a -OperationProfile (Get-WcProfile 'Corporativo') -Context (New-WcContext -Build 22631)
        $d.Allowed | Should -BeFalse
        @($d.Reasons) | Should -Contain 'policy.managed-strict'
    }
    It 'registers a handler for every action' {
        Clear-WcActionHandlers
        Register-WcAppsHandler
        foreach ($a in $script:Cat.actions) { Get-WcActionHandlerNames | Should -Contain $a.Handler }
    }
}
