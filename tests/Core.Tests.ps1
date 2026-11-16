#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @()
    $script:Tmp = New-WcTestDir
    $env:WINCARE_DATA_ROOT = $script:Tmp
    Initialize-WcLog -Path (Join-Path $script:Tmp 'test.jsonl') | Out-Null
    Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR' | Out-Null

    function New-TestAction {
        param([hashtable] $Override = @{})
        $a = @{ Id = 'test.action'; Category = 'Storage'; Risk = 'Low'; Modifies = $true; RequiresAdmin = $false
            Reversible = $true; Handler = 'Test-Handler'; TitleKey = 'action.test' }
        foreach ($k in $Override.Keys) { $a[$k] = $Override[$k] }
        return $a
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\WINCARE_DATA_ROOT -ErrorAction SilentlyContinue
}

Describe 'Logging' {
    It 'writes parseable JSON lines with level and category' {
        Write-WcLog -Level Audit -Category 'UnitTest' -Message 'hello' -Data @{ n = 1 } | Out-Null
        $last = @(Read-WcLog)[-1]
        $last.level | Should -Be 'Audit'
        $last.category | Should -Be 'UnitTest'
        $last.data.n | Should -Be 1
    }
    It 'pushes a display line to the sink' {
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
        Set-WcLogSink -Sink $q
        Write-WcLog -Message 'to sink' | Out-Null
        Set-WcLogSink -Sink $null
        $line = $null
        $q.TryDequeue([ref]$line) | Should -BeTrue
        $line | Should -Match 'to sink'
    }
    It 'writes UTF-8 without BOM' {
        $bytes = [System.IO.File]::ReadAllBytes((Get-WcLogPath))
        $bytes[0] | Should -Not -Be 0xEF
    }
}

Describe 'Localization' {
    It 'formats arguments, including zero' {
        Get-WcString -Key 'cli.findings' -Arguments @(0) | Should -Be 'Alertas: 0'
    }
    It 'returns a visible marker for missing keys' {
        Get-WcString -Key 'does.not.exist' | Should -Be '[does.not.exist]'
    }
    It 'falls back to pt-BR for unsupported languages' {
        Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'xx-XX' | Out-Null
        Get-WcString 'nav.settings' | Should -Be ('Configura' + [char]0x00E7 + [char]0x00F5 + 'es')
    }
    It 'loads en-US' {
        Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'en-US' | Out-Null
        Get-WcString 'nav.settings' | Should -Be 'Settings'
        Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR' | Out-Null
    }
}

Describe 'Settings' {
    It 'replaces invalid values with defaults' {
        $s = Test-WcSettings -Settings @{ Theme = 'Neon'; Language = 'en-US'; Profile = 'Root' }
        $s.Theme | Should -Be 'Dark'
        $s.Language | Should -Be 'en-US'
        $s.Profile | Should -Be 'Diagnostico'
    }
    It 'round-trips through disk' {
        $p = Join-Path $script:Tmp 'settings.json'
        Save-WcSettings -Settings @{ Theme = 'Light'; Language = 'en-US'; Profile = 'Corporativo' } -Path $p | Out-Null
        $r = Read-WcSettings -Path $p
        $r.Theme | Should -Be 'Light'
        $r.Profile | Should -Be 'Corporativo'
    }
    It 'returns defaults for a corrupt file' {
        $p = Join-Path $script:Tmp 'bad.json'
        Set-Content -LiteralPath $p -Value '{ not json'
        (Read-WcSettings -Path $p).Profile | Should -Be 'Diagnostico'
    }
}

Describe 'Profiles' {
    It 'defines exactly the four profiles' {
        (Get-WcProfile -All).Name | Should -Be @('Diagnostico', 'Conservador', 'Corporativo', 'Avancado')
    }
    It 'makes Diagnostico read-only' {
        $p = Get-WcProfile 'Diagnostico'
        $p.AllowModify | Should -BeFalse
        $p.MaxRisk | Should -Be 'None'
    }
    It 'rejects unknown profiles' {
        { Get-WcProfile 'GodMode' } | Should -Throw
    }
}

Describe 'Action catalog validation' {
    It 'accepts a valid action' {
        @(Test-WcActionDefinition -Action (New-TestAction)).Count | Should -Be 0
    }
    It 'rejects actions touching protected features (<_>)' -ForEach @('Defender', 'Firewall', 'BitLocker', 'WindowsUpdate', 'GroupPolicy', 'MDM', 'EDR', 'VPN') {
        $errs = Test-WcActionDefinition -Action (New-TestAction @{ Touches = @($_) })
        ($errs -join ';') | Should -Match 'protected feature'
    }
    It 'rejects a modifying action declared as risk None' {
        (Test-WcActionDefinition -Action (New-TestAction @{ Risk = 'None' })) -join ';' | Should -Match 'risk None'
    }
    It 'rejects malformed ids and categories' {
        (Test-WcActionDefinition -Action (New-TestAction @{ Id = 'Bad Id'; Category = 'Hacks' })).Count | Should -Be 2
    }
    It 'rejects non-boolean flags' {
        (Test-WcActionDefinition -Action (New-TestAction @{ Modifies = 'yes' })) -join ';' | Should -Match 'boolean'
    }
    It 'fails the whole load on one bad entry and on duplicates' {
        $p = Join-Path $script:Tmp 'cat.json'
        Set-Content -LiteralPath $p -Value '{"actions":[{"Id":"a.b","Category":"Storage","Risk":"Low","Modifies":true,"RequiresAdmin":false,"Reversible":true,"Handler":"H","TitleKey":"t","Touches":["Defender"]}]}'
        { Import-WcActionCatalog -Path $p } | Should -Throw '*protected feature*'
        Set-Content -LiteralPath $p -Value '{"actions":[{"Id":"a.b","Category":"Storage","Risk":"Low","Modifies":true,"RequiresAdmin":false,"Reversible":true,"Handler":"H","TitleKey":"t"},{"Id":"a.b","Category":"Storage","Risk":"Low","Modifies":true,"RequiresAdmin":false,"Reversible":true,"Handler":"H","TitleKey":"t"}]}'
        { Import-WcActionCatalog -Path $p } | Should -Throw '*Duplicate*'
    }
    It 'loads the shipped catalog' {
        $c = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        $c.Count | Should -BeGreaterThan 0
        @($c | Where-Object { $_.Modifies }).Count | Should -Be 0 -Because 'phase F1/F2 ships read-only actions only'
    }
}

Describe 'Policy engine' {
    BeforeAll {
        $script:Ctx = New-WcContext -IsAdmin $true -IsManaged $false -Build 22631 -EditionId 'Enterprise'
    }
    It 'Diagnostico blocks any modifying action' {
        $r = Test-WcActionAllowed -Action (New-TestAction) -OperationProfile (Get-WcProfile 'Diagnostico') -Context $script:Ctx
        $r.Allowed | Should -BeFalse
        $r.Reasons | Should -Contain 'policy.readonly-profile'
    }
    It 'Diagnostico allows read-only actions' {
        $a = New-TestAction @{ Modifies = $false; Risk = 'None' }
        (Test-WcActionAllowed -Action $a -OperationProfile (Get-WcProfile 'Diagnostico') -Context $script:Ctx).Allowed | Should -BeTrue
    }
    It 'Conservador blocks Medium risk' {
        $r = Test-WcActionAllowed -Action (New-TestAction @{ Risk = 'Medium' }) -OperationProfile (Get-WcProfile 'Conservador') -Context $script:Ctx
        $r.Reasons | Should -Contain 'policy.risk-above-profile'
    }
    It 'Avancado allows High risk with admin' {
        (Test-WcActionAllowed -Action (New-TestAction @{ Risk = 'High' }) -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx).Allowed | Should -BeTrue
    }
    It 'requires admin when declared' {
        $ctx = New-WcContext -IsAdmin $false -Build 22631
        (Test-WcActionAllowed -Action (New-TestAction @{ RequiresAdmin = $true }) -OperationProfile (Get-WcProfile 'Avancado') -Context $ctx).Reasons | Should -Contain 'policy.requires-admin'
    }
    It 'blocks managed-sensitive actions on managed devices in every profile' {
        $ctx = New-WcContext -IsAdmin $true -IsManaged $true -Build 22631
        foreach ($p in (Get-WcProfile -All)) {
            (Test-WcActionAllowed -Action (New-TestAction @{ BlockedWhenManaged = $true; Risk = 'Low' }) -OperationProfile $p -Context $ctx).Allowed | Should -BeFalse
        }
    }
    It 'Corporativo blocks managed-sensitive actions even without detected management' {
        $r = Test-WcActionAllowed -Action (New-TestAction @{ BlockedWhenManaged = $true }) -OperationProfile (Get-WcProfile 'Corporativo') -Context $script:Ctx
        $r.Reasons | Should -Contain 'policy.managed-strict'
    }
    It 'enforces MinBuild and Editions' {
        $ctx = New-WcContext -IsAdmin $true -Build 19045 -EditionId 'Professional'
        $r = Test-WcActionAllowed -Action (New-TestAction @{ MinBuild = 22000; Editions = @('Enterprise') }) -OperationProfile (Get-WcProfile 'Avancado') -Context $ctx
        $r.Reasons | Should -Contain 'policy.build-unsupported'
        $r.Reasons | Should -Contain 'policy.edition-unsupported'
    }
}

Describe 'Plan and dry-run' {
    BeforeEach {
        Clear-WcActionHandlers
        $script:Calls = @{ Preview = 0; Execute = 0 }
        Register-WcActionHandler -Name 'Test-Handler' -Preview { param($c) $script:Calls.Preview++; 'would do' } -Execute { param($c) $script:Calls.Execute++; 'done' }
        $script:Catalog = @((New-TestAction), (New-TestAction @{ Id = 'test.readonly'; Modifies = $false; Risk = 'None' }))
        $script:Ctx = New-WcContext -IsAdmin $true -Build 22631
    }
    It 'rejects ids that are not in the catalog' {
        { New-WcPlan -Catalog $script:Catalog -ActionId 'rm.everything' -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx } | Should -Throw '*allowlist*'
    }
    It 'marks actions without a registered handler as blocked' {
        Clear-WcActionHandlers
        $plan = New-WcPlan -Catalog $script:Catalog -ActionId 'test.action' -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $plan.Items[0].Status | Should -Be 'Blocked'
        $plan.Items[0].Reasons | Should -Contain 'policy.no-handler'
    }
    It 'dry-run calls Preview and never Execute' {
        $plan = New-WcPlan -Catalog $script:Catalog -ActionId 'test.action' -OperationProfile (Get-WcProfile 'Conservador') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -DryRun -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Previewed'
        $r[0].Output | Should -Be 'would do'
        $script:Calls.Execute | Should -Be 0
    }
    It 'skips modifying actions without confirmation' {
        $plan = New-WcPlan -Catalog $script:Catalog -ActionId 'test.action' -OperationProfile (Get-WcProfile 'Conservador') -Context $script:Ctx
        (Invoke-WcPlan -Plan $plan -Context $script:Ctx)[0].Status | Should -Be 'Skipped'
        (Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $false })[0].Status | Should -Be 'Skipped'
        $script:Calls.Execute | Should -Be 0
    }
    It 'executes after confirmation and runs read-only actions without asking' {
        $plan = New-WcPlan -Catalog $script:Catalog -ActionId @('test.action', 'test.readonly') -OperationProfile (Get-WcProfile 'Conservador') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { param($item) $item.ActionId -eq 'test.action' }
        $r.Status | Should -Be @('Succeeded', 'Succeeded')
        $script:Calls.Execute | Should -Be 2
    }
    It 'never runs blocked items, even when confirmed' {
        $plan = New-WcPlan -Catalog $script:Catalog -ActionId 'test.action' -OperationProfile (Get-WcProfile 'Diagnostico') -Context $script:Ctx
        (Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true })[0].Status | Should -Be 'Blocked'
        $script:Calls.Execute | Should -Be 0
    }
    It 'records handler failures and audits each item' {
        Register-WcActionHandler -Name 'Test-Handler' -Preview { 'p' } -Execute { throw 'boom' }
        $plan = New-WcPlan -Catalog $script:Catalog -ActionId 'test.action' -OperationProfile (Get-WcProfile 'Conservador') -Context $script:Ctx
        $r = Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { $true }
        $r[0].Status | Should -Be 'Failed'
        $r[0].Error | Should -Be 'boom'
        @(Read-WcLog | Where-Object { $_.category -eq 'Plan' -and $_.message -like "test.action: Failed" }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Parameter validation' {
    It 'detects path traversal' {
        $root = Join-Path $script:Tmp 'reports'
        Test-WcPathWithin -Path (Join-Path $root 'a.json') -AllowedRoots $root | Should -BeTrue
        Test-WcPathWithin -Path (Join-Path $root '../../etc/passwd') -AllowedRoots $root | Should -BeFalse
        Test-WcPathWithin -Path ($root + '-evil/x') -AllowedRoots $root | Should -BeFalse
    }
    It 'validates drive letters' {
        Test-WcDriveLetter 'C:' | Should -BeTrue
        Test-WcDriveLetter 'C:\; rm' | Should -BeFalse
    }
}
