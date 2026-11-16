#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# WinCare.Office (F4). Pure converters with fixtures; registry, file and process
# access always mocked. No real process is ever started.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @('System', 'Office')
    Initialize-WcLog -Path (Join-Path (New-WcTestDir) 'test.jsonl') | Out-Null

    function New-FakeWordProcess {
        param([int] $HandleAfterPolls = 2, [bool] $ExitOnClose = $true, [bool] $ExitImmediately = $false)
        $o = [pscustomobject]@{ Id = 4242; HasExited = $ExitImmediately; MainWindowHandle = [IntPtr]::Zero; Polls = 0
            HandleAfter = $HandleAfterPolls; ExitOnClose = $ExitOnClose; Closed = $false }
        $o | Add-Member -MemberType ScriptMethod -Name WaitForInputIdle -Value {
            param($ms)
            $this.Polls++
            if ($this.HandleAfter -gt 0 -and $this.Polls -ge $this.HandleAfter) { $this.MainWindowHandle = [IntPtr]1234 }
            return $true
        }
        $o | Add-Member -MemberType ScriptMethod -Name Refresh -Value { }
        $o | Add-Member -MemberType ScriptMethod -Name CloseMainWindow -Value { $this.Closed = $true; if ($this.ExitOnClose) { $this.HasExited = $true }; return $true }
        $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return [bool]$this.HasExited }
        return $o
    }
}

Describe 'Click-to-Run detection and channel' {
    It 'maps the documented channel GUID <Guid> to <Name>' -ForEach @(
        @{ Guid = '492350f6-3a01-4f97-b9c0-c7c6ddf67d60'; Name = 'Current Channel' }
        @{ Guid = '55336b82-a18d-4dd6-b5f6-9e5095c314a6'; Name = 'Monthly Enterprise Channel' }
        @{ Guid = '7ffbc6bf-bc32-4f92-8982-f9dd17fd3114'; Name = 'Semi-Annual Enterprise Channel' }
        @{ Guid = '5440fd1f-7ecb-4221-8110-145efaa6372f'; Name = 'Beta Channel' }
    ) {
        $c = ConvertTo-WcOfficeChannel -Configuration @{ CDNBaseUrl = "http://officecdn.microsoft.com/pr/$Guid" }
        $c.Name | Should -Be $Name
        $c.Source | Should -Be 'CDNBaseUrl'
    }
    It 'reports an unknown GUID raw, without inventing a name' {
        $c = ConvertTo-WcOfficeChannel -Configuration @{ CDNBaseUrl = 'http://officecdn.microsoft.com/pr/11111111-2222-3333-4444-555555555555' }
        $c.Name | Should -BeNullOrEmpty
        $c.Raw | Should -Match '11111111'
    }
    It 'prefers UpdateUrl (ODT) over CDNBaseUrl' {
        $c = ConvertTo-WcOfficeChannel -Configuration @{ UpdateUrl = 'http://officecdn.microsoft.com/pr/55336b82-a18d-4dd6-b5f6-9e5095c314a6'; CDNBaseUrl = 'http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60' }
        $c.Source | Should -Be 'UpdateUrl'
        $c.Name | Should -Be 'Monthly Enterprise Channel'
    }
    It 'shapes the Click-to-Run configuration' {
        $r = ConvertTo-WcOfficeClickToRun -Configuration @{ VersionToReport = '16.0.17928.20156'; Platform = 'x64'; ProductReleaseIds = 'O365ProPlusRetail, ProofingTools'; CDNBaseUrl = 'http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60' }
        $r.Installed | Should -BeTrue
        $r.Platform | Should -Be 'x64'
        $r.ProductReleaseIds | Should -Be @('O365ProPlusRetail', 'ProofingTools')
        $r.Channel.Name | Should -Be 'Current Channel'
    }
    It 'returns not installed for an empty key' {
        (ConvertTo-WcOfficeClickToRun -Configuration @{}).Installed | Should -BeFalse
    }
}

Describe 'Uninstall entries, App Paths and processes' {
    It 'keeps visible Office products and classifies the install type' {
        $e = @(
            @{ DisplayName = 'Microsoft 365 Apps for enterprise - en-us'; DisplayVersion = '16.0.1'; UninstallString = '"C:\Program Files\Common Files\Microsoft Shared\ClickToRun\OfficeClickToRun.exe" scenario=install'; Hive = '64'; KeyName = 'O365ProPlusRetail - en-us' }
            @{ DisplayName = 'Microsoft Office Professional Plus 2016'; DisplayVersion = '16.0.4266.1001'; WindowsInstaller = 1; Hive = 'WOW6432Node'; KeyName = 'Office16.PROPLUS' }
            @{ DisplayName = 'Microsoft Office Proofing (English) 2016'; WindowsInstaller = 1; Hive = '64' }
            @{ DisplayName = 'Microsoft Office 64-bit Components 2016'; WindowsInstaller = 1; SystemComponent = 1; Hive = '64' }
            @{ DisplayName = 'Notepad++'; Hive = '64' }
        )
        $r = ConvertTo-WcOfficeUninstallEntry -Entry $e
        $r.Count | Should -Be 2
        $r[0].InstallType | Should -Be 'ClickToRun'
        $r[1].InstallType | Should -Be 'MSI'
        $r[1].Architecture | Should -Be 'x86'
    }
    It 'parses App Paths and flags the x86 path heuristic' {
        $r = ConvertTo-WcOfficeAppPath -AppPath @{ Word = '"C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE"'; Excel = 'C:\Program Files\Microsoft Office\root\Office16\EXCEL.EXE' }
        ($r | Where-Object Name -eq 'Word').ArchitectureHint | Should -Be 'x86'
        ($r | Where-Object Name -eq 'Word').Path | Should -Not -Match '"'
        ($r | Where-Object Name -eq 'PowerPoint').Found | Should -BeFalse
    }
    It 'shapes running processes' {
        $r = ConvertTo-WcOfficeProcess -Process @([pscustomobject]@{ ProcessName = 'WINWORD'; Id = 10; WorkingSet64 = 104857600; StartTime = (Get-Date '2026-11-16T10:00:00') })
        $r[0].WorkingSetMB | Should -Be 100
        $r[0].Name | Should -Be 'WINWORD'
    }
    It 'Get-WcOfficeInstallation reads registry through mocks and reports policies as managed' {
        Mock -ModuleName WinCare.Office Get-WcRegistryValues {
            if ($Path -like '*ClickToRun\Configuration') { return @{ VersionToReport = '16.0.1'; Platform = 'x86'; CDNBaseUrl = 'http://officecdn.microsoft.com/pr/492350f6-3a01-4f97-b9c0-c7c6ddf67d60' } }
            if ($Path -like '*WINWORD.EXE') { return @{ '(default)' = 'C:\Program Files (x86)\Microsoft Office\root\Office16\WINWORD.EXE' } }
            return @{}
        }
        Mock -ModuleName WinCare.Office Get-WcRegistrySubkeyData { return @() }
        Mock -ModuleName WinCare.Office Test-Path { return ($LiteralPath -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Office') }
        $i = Get-WcOfficeInstallation
        $i.ClickToRun.Version | Should -Be '16.0.1'
        $i.Architecture | Should -Be 'x86'
        $i.ArchitectureSource | Should -Be 'ClickToRun Platform'
        $i.ManagedByOrganization | Should -BeTrue
        $i.PolicyKeys | Should -Be @('HKLM:\SOFTWARE\Policies\Microsoft\Office')
        Should -Invoke -ModuleName WinCare.Office Get-WcRegistrySubkeyData -Times 2 -Exactly
    }
    It 'Get-WcOfficeProcess asks only for the Office process names' {
        Mock -ModuleName WinCare.Office Get-Process { return @() }
        Get-WcOfficeProcess | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinCare.Office Get-Process -Times 1 -ParameterFilter { (@($Name) -join ',') -eq 'WINWORD,EXCEL,POWERPNT' }
    }
}

Describe 'Add-ins, templates and resiliency (read-only)' {
    It 'interprets LoadBehavior <Value> as <Meaning>' -ForEach @(
        @{ Value = 3; Meaning = 'LoadAtStartup'; Startup = $true }
        @{ Value = 2; Meaning = 'StartupDisabledOrFailed'; Startup = $false }
        @{ Value = 0; Meaning = 'NotLoaded'; Startup = $false }
        @{ Value = 9; Meaning = 'OnDemandLoaded'; Startup = $false }
        @{ Value = 16; Meaning = 'FirstTimeThenOnDemand'; Startup = $false }
        @{ Value = $null; Meaning = 'NotSet'; Startup = $false }
        @{ Value = 'abc'; Meaning = 'Invalid'; Startup = $false }
    ) {
        $r = ConvertTo-WcOfficeLoadBehavior -Value $Value
        $r.Meaning | Should -Be $Meaning
        $r.LoadsAtStartup | Should -Be $Startup
    }
    It 'sorts startup add-ins first and falls back to the ProgId' {
        $r = ConvertTo-WcOfficeAddin -Entry @(
            @{ Application = 'Word'; Scope = 'HKCU'; KeyName = 'A.Connect'; FriendlyName = 'Alpha'; LoadBehavior = 0 }
            @{ Application = 'Word'; Scope = 'HKLM'; KeyName = 'Slow.Addin'; LoadBehavior = 3 }
        )
        $r[0].ProgId | Should -Be 'Slow.Addin'
        $r[0].Name | Should -Be 'Slow.Addin'
        $r[0].LoadsAtStartup | Should -BeTrue
    }
    It 'Get-WcOfficeAddin queries every app and scope and tags entries' {
        Mock -ModuleName WinCare.Office Get-WcRegistrySubkeyData {
            if ($Path -eq 'HKCU:\Software\Microsoft\Office\Word\Addins') { return @{ KeyName = 'X.Connect'; FriendlyName = 'X'; LoadBehavior = 3 } }
            return @()
        }
        $r = @(Get-WcOfficeAddin)
        $r.Count | Should -Be 1
        $r[0].Application | Should -Be 'Word'
        $r[0].Scope | Should -Be 'HKCU'
        Should -Invoke -ModuleName WinCare.Office Get-WcRegistrySubkeyData -Times 12 -Exactly
    }
    It 'Get-WcRegistrySubkeyData reads subkeys without writing' {
        Mock -ModuleName WinCare.Office Test-Path { $true }
        Mock -ModuleName WinCare.Office Get-ChildItem { @([pscustomobject]@{ PSChildName = 'P.Id'; PSPath = 'fake::P.Id' }) }
        Mock -ModuleName WinCare.Office Get-ItemProperty { [pscustomobject]@{ FriendlyName = 'P'; LoadBehavior = 3; Other = 1 } }
        $r = @(Get-WcRegistrySubkeyData -Path 'HKCU:\x' -Name @('FriendlyName', 'LoadBehavior'))
        $r[0].KeyName | Should -Be 'P.Id'
        $r[0].ContainsKey('Other') | Should -BeFalse
    }
    It 'lists Word STARTUP files and Normal.dotm' {
        $d = New-WcTestDir
        $startup = Join-Path (Join-Path (Join-Path $d 'Microsoft') 'Word') 'STARTUP'
        $tpl = Join-Path (Join-Path $d 'Microsoft') 'Templates'
        New-Item -ItemType Directory -Path $startup, $tpl -Force | Out-Null
        Set-Content -Path (Join-Path $startup 'macros.dotm') -Value 'x'
        Set-Content -Path (Join-Path $tpl 'Normal.dotm') -Value 'y'
        $r = @(Get-WcWordTemplateFile -AppData $d)
        $r.Count | Should -Be 2
        ($r | Where-Object Kind -eq 'StartupFolder').Name | Should -Be 'macros.dotm'
        ($r | Where-Object Kind -eq 'NormalTemplate').Name | Should -Be 'Normal.dotm'
        Test-Path (Join-Path $startup 'macros.dotm') | Should -BeTrue
    }
    It 'reports DisabledItems only when values exist' {
        Mock -ModuleName WinCare.Office Get-WcRegistryValueCount { if ($Path -like '*16.0\Word\Resiliency*') { 2 } else { $null } }
        $r = @(Get-WcOfficeDisabledItem)
        $r.Count | Should -Be 1
        $r[0].Count | Should -Be 2
    }
}

Describe 'Word startup comparison heuristic' {
    It 'flags add-ins when normal > 2x safe and difference > 3 s' {
        $c = ConvertTo-WcOfficeStartComparison -NormalMs 9000 -SafeMs 2000
        $c.Verdict | Should -Be 'AddinsLikely'
        $c.VerdictKey | Should -Be 'office.verdict.addins-likely'
        $c.Ratio | Should -Be 4.5
    }
    It 'does not flag a large ratio with a small absolute difference' {
        (ConvertTo-WcOfficeStartComparison -NormalMs 2500 -SafeMs 800).Verdict | Should -Be 'NoClearDifference'
    }
    It 'does not flag a large difference with a small ratio' {
        (ConvertTo-WcOfficeStartComparison -NormalMs 14000 -SafeMs 10000).Verdict | Should -Be 'NoClearDifference'
    }
    It 'is incomplete without both measurements' {
        (ConvertTo-WcOfficeStartComparison -NormalMs 5000 -SafeMs $null).Verdict | Should -Be 'Incomplete'
    }
}

Describe 'Measure-WcWordStartup (mocked processes)' {
    BeforeEach {
        Clear-WcWordMeasurementHistory
        Mock -ModuleName WinCare.Office Get-WcWordExecutablePath { 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE' }
        Mock -ModuleName WinCare.Office Get-Process { @() }
        Mock -ModuleName WinCare.Office Stop-Process { }
        Mock -ModuleName WinCare.Office Start-Sleep { }
    }
    It 'refuses when Word is already running and starts nothing' {
        Mock -ModuleName WinCare.Office Get-Process { @([pscustomobject]@{ Id = 77; ProcessName = 'WINWORD' }) }
        Mock -ModuleName WinCare.Office Start-Process { throw 'must not start' }
        { Measure-WcWordStartup -Mode Normal } | Should -Throw '*already running*'
        Should -Invoke -ModuleName WinCare.Office Start-Process -Times 0 -Exactly
    }
    It 'starts Word with /q /n, measures, closes politely and never kills' {
        $script:Fake = New-FakeWordProcess -HandleAfterPolls 2
        Mock -ModuleName WinCare.Office Start-Process { $script:Fake }
        $m = Measure-WcWordStartup -Mode Normal
        $m.Mode | Should -Be 'Normal'
        $m.Milliseconds | Should -BeGreaterOrEqual 0
        $m.CloseMethod | Should -Be 'CloseMainWindow'
        $script:Fake.Closed | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Office Start-Process -Times 1 -Exactly -ParameterFilter { (@($ArgumentList) -join ' ') -eq '/q /n' -and $PassThru }
        Should -Invoke -ModuleName WinCare.Office Stop-Process -Times 0 -Exactly
        @(Get-WcWordMeasurementHistory).Count | Should -Be 1
    }
    It 'uses /safe in safe mode' {
        $script:Fake = New-FakeWordProcess -HandleAfterPolls 1
        Mock -ModuleName WinCare.Office Start-Process { $script:Fake }
        (Measure-WcWordStartup -Mode Safe).Arguments | Should -Be '/q /n /safe'
    }
    It 'kills only its own PID when Word does not exit after CloseMainWindow' {
        $script:Fake = New-FakeWordProcess -HandleAfterPolls 1 -ExitOnClose $false
        Mock -ModuleName WinCare.Office Start-Process { $script:Fake }
        $m = Measure-WcWordStartup -Mode Normal -CloseTimeoutSeconds 1
        $m.CloseMethod | Should -Be 'Killed'
        Should -Invoke -ModuleName WinCare.Office Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 }
    }
    It 'fails (and cleans up) when no window appears before the timeout' {
        $script:Fake = New-FakeWordProcess -HandleAfterPolls 0
        Mock -ModuleName WinCare.Office Start-Process { $script:Fake }
        { Measure-WcWordStartup -Mode Normal -TimeoutSeconds 1 } | Should -Throw '*main window*'
        $script:Fake.Closed | Should -BeTrue
        @(Get-WcWordMeasurementHistory).Count | Should -Be 0
    }
    It 'fails when Word exits before showing a window' {
        $script:Fake = New-FakeWordProcess -HandleAfterPolls 0 -ExitImmediately $true
        Mock -ModuleName WinCare.Office Start-Process { $script:Fake }
        { Measure-WcWordStartup -Mode Normal } | Should -Throw '*exited before*'
    }
    It 'refuses when WINWORD.EXE is not found' {
        Mock -ModuleName WinCare.Office Get-WcWordExecutablePath { $null }
        Mock -ModuleName WinCare.Office Start-Process { }
        { Measure-WcWordStartup } | Should -Throw '*not found*'
        Should -Invoke -ModuleName WinCare.Office Start-Process -Times 0 -Exactly
    }
}

Describe 'Get-WcWordExecutablePath validation' {
    It 'rejects a value that is not WINWORD.EXE' {
        Mock -ModuleName WinCare.Office Get-WcRegistryValues { @{ '(default)' = 'C:\Temp\evil.exe' } }
        Get-WcWordExecutablePath | Should -BeNullOrEmpty
    }
    It 'rejects a relative path' {
        Mock -ModuleName WinCare.Office Get-WcRegistryValues { @{ '(default)' = 'WINWORD.EXE' } }
        Get-WcWordExecutablePath | Should -BeNullOrEmpty
    }
}

Describe 'Catalog, localization and handlers (F4 fragment)' {
    BeforeAll {
        $script:Frag = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Core/actions.d/f4-office.json')
        $script:PtFrag = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'Localization/pt-BR.d/f4-office.json') | ConvertFrom-Json
        $script:EnFrag = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'Localization/en-US.d/f4-office.json') | ConvertFrom-Json
    }
    It 'every action is valid, Office-page only and non-modifying' {
        @($script:Frag.actions).Count | Should -Be 4
        foreach ($a in $script:Frag.actions) {
            @(Test-WcActionDefinition -Action $a).Count | Should -Be 0 -Because $a.Id
            $a.Modifies | Should -BeFalse
            $a.RequiresAdmin | Should -BeFalse
            @($a.Pages) | Should -Be @('office')
        }
        ($script:Frag.actions | Where-Object { $_.Id -eq 'office.inventory' }).Risk | Should -Be 'None'
    }
    It 'every handler is registered by Initialize-WcActionHandlers' {
        $names = Initialize-WcActionHandlers
        foreach ($a in $script:Frag.actions) { $names | Should -Contain $a.Handler }
    }
    It 'pt-BR and en-US fragments have the same keys and cover titles and descriptions' {
        $pt = @($script:PtFrag.PSObject.Properties.Name)
        $en = @($script:EnFrag.PSObject.Properties.Name)
        Compare-Object $pt $en | Should -BeNullOrEmpty
        foreach ($a in $script:Frag.actions) { $pt | Should -Contain $a.TitleKey; $pt | Should -Contain $a.DescriptionKey }
    }
    It 'fragment keys do not collide with the main localization files' {
        $main = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'Localization/pt-BR.json') | ConvertFrom-Json
        $mainKeys = @($main.PSObject.Properties.Name)
        foreach ($k in $script:PtFrag.PSObject.Properties.Name) { $mainKeys | Should -Not -Contain $k }
    }
    It 'Preview of the measure action starts nothing' {
        Mock -ModuleName WinCare.Office Start-Process { throw 'must not start' }
        Mock -ModuleName WinCare.Office Get-Process { @() }
        Mock -ModuleName WinCare.Office Get-WcWordExecutablePath { 'C:\x\WINWORD.EXE' }
        $catalog = @($script:Frag.actions)
        $plan = New-WcPlan -Catalog $catalog -ActionId @('office.measure-word-start', 'office.measure-word-start-safe', 'office.open-repair') -OperationProfile (Get-WcProfile 'Conservador') -Context (New-WcContext -IsWindows $true -Build 19045)
        $res = Invoke-WcPlan -Plan $plan -Context (New-WcContext -IsWindows $true -Build 19045) -DryRun
        @($res | Where-Object Status -eq 'Previewed').Count | Should -Be 3
        $res[0].Output.Summary | Should -Match '/q /n'
        $res[1].Output.Summary | Should -Match '/safe'
        Should -Invoke -ModuleName WinCare.Office Start-Process -Times 0 -Exactly
    }
    It 'measure actions are blocked in the read-only Diagnostico profile' {
        $plan = New-WcPlan -Catalog @($script:Frag.actions) -ActionId @('office.inventory', 'office.measure-word-start') -OperationProfile (Get-WcProfile 'Diagnostico') -Context (New-WcContext -IsWindows $true -Build 19045)
        $plan.Items[0].Allowed | Should -BeTrue
        $plan.Items[1].Allowed | Should -BeFalse
    }
    It 'measure Execute returns the measurement and the comparison after normal + safe runs' {
        Clear-WcWordMeasurementHistory
        Mock -ModuleName WinCare.Office Measure-WcWordStartup {
            $m = [pscustomobject]@{ Mode = $Mode; Milliseconds = $(if ($Mode -eq 'Safe') { 2000 } else { 9000 }); Measured = 'now' }
            Add-WcWordMeasurement -Measurement $m
            $m
        }
        $ctx = New-WcContext -IsWindows $true -Build 19045
        $plan = New-WcPlan -Catalog @($script:Frag.actions) -ActionId @('office.measure-word-start', 'office.measure-word-start-safe') -OperationProfile (Get-WcProfile 'Conservador') -Context $ctx
        $res = Invoke-WcPlan -Plan $plan -Context $ctx -ConfirmCallback { $true }
        $res[0].Status | Should -Be 'Succeeded'
        $res[0].Output.Comparison.Verdict | Should -Be 'Incomplete'
        $res[1].Output.Comparison.Verdict | Should -Be 'AddinsLikely'
        $res[1].Output.Summary | Should -Match 'likely cause'
        @($res[1].Output.Items | Where-Object Section -eq 'measurement').Count | Should -Be 2
    }
    It 'open-repair opens only the Settings URI' {
        Mock -ModuleName WinCare.Office Start-Process { }
        $r = Open-WcOfficeRepair
        $r.Summary | Should -Match 'does not run repairs'
        Should -Invoke -ModuleName WinCare.Office Start-Process -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'ms-settings:appsfeatures' -and -not $ArgumentList }
    }
    It 'inventory Execute returns table rows with existing column names' {
        Mock -ModuleName WinCare.Office Get-WcOfficeInventory {
            [pscustomobject]@{
                ClickToRun = (ConvertTo-WcOfficeClickToRun -Configuration @{ VersionToReport = '16.0.1'; Platform = 'x64' })
                Products = @(); AppPaths = (ConvertTo-WcOfficeAppPath -AppPath @{ Word = 'C:\P\WINWORD.EXE' })
                Architecture = 'x64'; ArchitectureSource = 'ClickToRun Platform'; ManagedByOrganization = $true; PolicyKeys = @('HKCU:\Software\Policies\Microsoft\Office')
                Processes = @(); Addins = (ConvertTo-WcOfficeAddin -Entry @(@{ Application = 'Word'; Scope = 'HKCU'; KeyName = 'S.A'; LoadBehavior = 3 }))
                Templates = @(); DisabledItems = @()
            }
        }
        $ctx = New-WcContext -IsWindows $true -Build 19045
        $plan = New-WcPlan -Catalog @($script:Frag.actions) -ActionId @('office.inventory') -OperationProfile (Get-WcProfile 'Diagnostico') -Context $ctx
        $res = Invoke-WcPlan -Plan $plan -Context $ctx -ConfirmCallback { $true }
        $res[0].Status | Should -Be 'Succeeded'
        $res[0].Output.Summary | Should -Match '1 add-in\(s\) load at startup'
        $rows = @($res[0].Output.Items)
        foreach ($r in $rows) { @($r.PSObject.Properties.Name) | Should -Be @('Section', 'Item', 'Value', 'Source') }
        ($rows | Where-Object Item -eq 'Managed by organization').Value | Should -Match '^Yes'
    }
}
