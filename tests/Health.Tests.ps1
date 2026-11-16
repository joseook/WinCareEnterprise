#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F6 'health' page (WinCare.Health). Pure converters with fixtures; every Windows
# query (Get-WinEvent, Get-ScheduledTask, Get-PhysicalDisk, CIM, COM, powercfg) is mocked.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    if (-not (Get-Command -Name 'Get-WinEvent' -ErrorAction SilentlyContinue)) {
        function global:Get-WinEvent { [CmdletBinding()] param([hashtable[]] $FilterHashtable, [long] $MaxEvents) throw 'Stub for Get-WinEvent was called without a mock.' }
    }
    foreach ($name in @('Get-ScheduledTask', 'Get-ScheduledTaskInfo', 'Get-PhysicalDisk', 'Get-StorageReliabilityCounter')) {
        if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
            $body = "[CmdletBinding()] param([Parameter(ValueFromRemainingArguments = `$true)] `$Rest) throw 'Stub for $name was called without a mock.'"
            Set-Item -Path ("function:global:$name") -Value ([scriptblock]::Create($body))
        }
    }
    # On Windows, mocking the CDXML cmdlets (Get-PhysicalDisk...) needs their enum types loaded.
    if (Get-Module -ListAvailable -Name Storage -ErrorAction SilentlyContinue) { Import-Module Storage -ErrorAction SilentlyContinue }
    Import-WcTestModules -Name @('System', 'Health')
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'health.jsonl') | Out-Null
    $script:OldDataRoot = $env:WINCARE_DATA_ROOT
    $script:OldSystemRoot = $env:SystemRoot
    $env:WINCARE_DATA_ROOT = $script:Tmp
    if (-not $env:SystemRoot) { $env:SystemRoot = 'C:\Windows' }
    $script:LocDir = Join-Path $script:SrcRoot 'Localization'
    function New-Ev([string] $Provider, [int] $Id, [datetime] $When, [object[]] $Data = @(), [int] $Level = 2) {
        [pscustomobject]@{ ProviderName = $Provider; Id = $Id; Level = $Level; TimeCreated = $When; Data = $Data }
    }
}

AfterAll {
    $env:WINCARE_DATA_ROOT = $script:OldDataRoot
    $env:SystemRoot = $script:OldSystemRoot
    Import-WcLocalization -Root $script:LocDir -Language 'pt-BR' | Out-Null
}

Describe 'Critical events' {
    It 'classifies <P> <Id> (level <L>) as <Expected>' -ForEach @(
        @{ P = 'Microsoft-Windows-Kernel-Power'; Id = 41; L = 1; D = @(); Expected = 'UnexpectedShutdown' }
        @{ P = 'EventLog'; Id = 6008; L = 2; D = @(); Expected = 'UnexpectedShutdown' }
        @{ P = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; L = 2; D = @(); Expected = 'BugCheck' }
        @{ P = 'BugCheck'; Id = 1001; L = 2; D = @(); Expected = 'BugCheck' }
        @{ P = 'disk'; Id = 153; L = 3; D = @(); Expected = 'Disk' }
        @{ P = 'disk'; Id = 7; L = 2; D = @(); Expected = 'Disk' }
        @{ P = 'Ntfs'; Id = 55; L = 2; D = @(); Expected = 'Disk' }
        @{ P = 'Microsoft-Windows-Ntfs'; Id = 98; L = 2; D = @(); Expected = 'Disk' }
        @{ P = 'Microsoft-Windows-Ntfs'; Id = 98; L = 4; D = @(); Expected = $null }
        @{ P = 'Microsoft-Windows-WHEA-Logger'; Id = 19; L = 3; D = @(); Expected = 'Whea' }
        @{ P = 'Microsoft-Windows-WHEA-Logger'; Id = 46; L = 4; D = @(); Expected = $null }
        @{ P = 'Application Error'; Id = 1000; L = 2; D = @('app.exe'); Expected = 'AppCrash' }
        @{ P = 'Windows Error Reporting'; Id = 1001; L = 4; D = @('1', '2', 'APPCRASH', '', '', 'app.exe'); Expected = 'AppCrash' }
        @{ P = 'Windows Error Reporting'; Id = 1001; L = 4; D = @('1', '2', 'WindowsUpdateFailure3', '', '', 'x'); Expected = $null }
        @{ P = 'Service Control Manager'; Id = 7000; L = 2; D = @(); Expected = $null }
        @{ P = 'Microsoft-Windows-Kernel-Power'; Id = 42; L = 4; D = @(); Expected = $null }
    ) {
        Get-WcHealthEventCategory -ProviderName $P -Id $Id -Level $L -Data $D | Should -Be $Expected
    }

    It 'builds one capped query per category for the requested window' {
        $now = [datetime]'2026-11-16T12:00:00'
        $q = @(Get-WcHealthEventQuery -Days 3 -Now $now)
        $q.Count | Should -Be 5
        @($q | ForEach-Object { $_.Category }) | Should -Be @('UnexpectedShutdown', 'BugCheck', 'Disk', 'Whea', 'AppCrash')
        foreach ($x in $q) {
            $x.Filter.StartTime | Should -Be $now.AddDays(-3)
            $x.MaxEvents | Should -BeGreaterThan 0
            $x.MaxEvents | Should -BeLessOrEqual 500
        }
        ($q | Where-Object { $_.Category -eq 'AppCrash' }).Filter.LogName | Should -Be 'Application'
    }

    It 'groups events by category, source and id with first/last dates and bugcheck codes' {
        $ev = @(
            New-Ev 'Microsoft-Windows-Kernel-Power' 41 ([datetime]'2026-11-10T08:00:00') @() 1
            New-Ev 'Microsoft-Windows-Kernel-Power' 41 ([datetime]'2026-11-12T09:30:00') @() 1
            New-Ev 'EventLog' 6008 ([datetime]'2026-11-12T09:31:00')
            New-Ev 'Microsoft-Windows-WER-SystemErrorReporting' 1001 ([datetime]'2026-11-11T10:00:00') @('0x0000009f (0x3, 0x1)')
            New-Ev 'Microsoft-Windows-WER-SystemErrorReporting' 1001 ([datetime]'2026-11-13T10:00:00') @('0x000000ef (0x1)')
            New-Ev 'Service Control Manager' 7000 ([datetime]'2026-11-13T10:00:00')
        )
        $s = ConvertTo-WcHealthEventSummary -Event $ev -Days 7
        $s.Totals['UnexpectedShutdown'] | Should -Be 3
        $s.Totals['BugCheck'] | Should -Be 2
        @($s.Rows).Count | Should -Be 3
        $kp = $s.Rows | Where-Object { $_.EventId -eq 41 }
        $kp.Events | Should -Be 2
        $kp.FirstSeen | Should -Be '2026-11-10 08:00'
        $kp.LastSeen | Should -Be '2026-11-12 09:30'
        $kp.Source | Should -Be 'Microsoft-Windows-Kernel-Power'
        ($s.Rows | Where-Object { $_.EventId -eq 1001 }).Detail | Should -Be '0x0000009f, 0x000000ef'
        $s.Rows[0].EventId | Should -Be 1001  # newest first
    }

    It 'groups application crashes by program name only (no paths) with separate counts' {
        $ev = @(
            New-Ev 'Application Error' 1000 ([datetime]'2026-11-10T08:00:00') @('Contoso.exe', '1.0')
            New-Ev 'Application Error' 1000 ([datetime]'2026-11-11T08:00:00') @('contoso.exe', '1.0')
            New-Ev 'Windows Error Reporting' 1001 ([datetime]'2026-11-11T08:00:05') @('b', '5', 'APPCRASH', 'n', '0', 'C:\Users\alice\AppData\Local\Contoso.exe') 4
            New-Ev 'Windows Error Reporting' 1001 ([datetime]'2026-11-12T08:00:00') @('b', '5', 'AppHangB1', 'n', '0', 'Hang.exe') 4
            New-Ev 'Application Error' 1000 ([datetime]'2026-11-12T08:00:00') @()
        )
        $s = ConvertTo-WcHealthEventSummary -Event $ev
        $s.Totals['AppCrash'] | Should -Be 5
        @($s.Rows).Count | Should -Be 0
        @($s.CrashRows).Count | Should -Be 3
        $c = $s.CrashRows | Where-Object { $_.Program -eq 'Contoso.exe' }
        $c.Crashes | Should -Be 2
        $c.WerReports | Should -Be 1
        $s.CrashRows[0].Program | Should -Be 'Contoso.exe'
        @($s.CrashRows | Where-Object { $_.Program -match 'alice|\\' }).Count | Should -Be 0
        @($s.CrashRows.Program) | Should -Contain '(unknown)'
    }

    It 'returns empty summary for no events' {
        $s = ConvertTo-WcHealthEventSummary -Event @()
        @($s.Rows).Count | Should -Be 0
        @($s.CrashRows).Count | Should -Be 0
    }

    It 'program names are trimmed to the file name and 64 characters' {
        ConvertTo-WcHealthProgramName 'C:\x\y\z.exe' | Should -Be 'z.exe'
        ConvertTo-WcHealthProgramName ('a' * 100) | Should -HaveCount 1
        (ConvertTo-WcHealthProgramName ('a' * 100)).Length | Should -Be 64
        ConvertTo-WcHealthProgramName $null | Should -Be '(unknown)'
    }

    Context 'Get-WcHealthEventRaw' {
        It 'keeps only provider, id, level, time and the first 6 property values' {
            Mock -ModuleName WinCare.Health Get-WinEvent {
                $props = @(1..10 | ForEach-Object { [pscustomobject]@{ Value = "v$_" } })
                [pscustomobject]@{ ProviderName = 'Application Error'; Id = 1000; Level = 2; TimeCreated = [datetime]'2026-11-10'; Properties = $props; Message = 'secret user text' }
            }
            $r = @(Get-WcHealthEventRaw -Query @{ Category = 'AppCrash'; MaxEvents = 5; Filter = @{ LogName = 'Application' } })
            $r.Count | Should -Be 1
            @($r[0].Data).Count | Should -Be 6
            $r[0].PSObject.Properties.Name | Should -Not -Contain 'Message'
            Should -Invoke -ModuleName WinCare.Health Get-WinEvent -Times 1 -ParameterFilter { $MaxEvents -eq 5 }
        }
        It 'treats "no matching events" as empty' {
            Mock -ModuleName WinCare.Health Get-WinEvent {
                throw (New-Object System.Management.Automation.ErrorRecord((New-Object System.Exception 'No events were found'), 'NoMatchingEventsFound,Microsoft.PowerShell.Commands.GetWinEventCommand', 'ObjectNotFound', $null))
            }
            @(Get-WcHealthEventRaw -Query @{ Category = 'X'; MaxEvents = 5; Filter = @{ LogName = 'System' } }).Count | Should -Be 0
        }
        It 'rethrows other errors; Get-WcHealthEventData records them and continues' {
            Mock -ModuleName WinCare.Health Get-WinEvent { throw 'access denied' }
            { Get-WcHealthEventRaw -Query @{ Category = 'X'; MaxEvents = 5; Filter = @{ LogName = 'System' } } } | Should -Throw
            $d = Get-WcHealthEventData -Days 7
            @($d.Errors).Count | Should -Be 5
            @($d.Rows).Count | Should -Be 0
        }
    }
}

Describe 'Devices' {
    It 'maps documented codes with severity' {
        $m = Get-WcPnpErrorMeaning -Code 28
        $m.Severity | Should -Be 'Warning'
        $m.Text | Should -Not -BeNullOrEmpty
        (Get-WcPnpErrorMeaning -Code 22).Severity | Should -Be 'Info'
        (Get-WcPnpErrorMeaning -Code 45).Severity | Should -Be 'Info'
        (Get-WcPnpErrorMeaning -Code 999).Text | Should -Match 'Unknown|desconhecido'
    }
    It 'uses the localized text when strings are loaded' {
        Import-WcLocalization -Root $script:LocDir -Language 'en-US' | Out-Null
        (Get-WcPnpErrorMeaning -Code 43).Text | Should -Be 'Device reported problems and was stopped'
        Import-WcLocalization -Root $script:LocDir -Language 'pt-BR' | Out-Null
        (Get-WcPnpErrorMeaning -Code 43).Text | Should -Not -Be 'Device reported problems and was stopped'
    }
    It 'builds rows, skips code 0 and lists faults before informational states' {
        $rows = @(ConvertTo-WcHealthDeviceRows -Device @(
                @{ Name = 'B disabled'; PNPClass = 'Net'; ConfigManagerErrorCode = 22 }
                @{ Name = 'A broken'; PNPClass = 'USB'; ConfigManagerErrorCode = 43 }
                @{ Name = 'OK'; PNPClass = 'USB'; ConfigManagerErrorCode = 0 }
                @{ Description = 'No name'; PNPClass = 'Unknown'; ConfigManagerErrorCode = 28 }
            ))
        $rows.Count | Should -Be 3
        $rows[0].SeverityRaw | Should -Be 'Warning'
        $rows[2].Name | Should -Be 'B disabled'
        ($rows | Where-Object { $_.ErrorCode -eq 28 }).Name | Should -Be 'No name'
    }
}

Describe 'Disks' {
    It 'maps health status <V> to <E>' -ForEach @(
        @{ V = 0; E = 'Healthy' }, @{ V = 1; E = 'Warning' }, @{ V = 2; E = 'Unhealthy' }, @{ V = 'Healthy'; E = 'Healthy' }, @{ V = $null; E = 'Unknown' }
    ) { ConvertTo-WcDiskHealthText $V | Should -Be $E }
    It 'maps operational status' {
        ConvertTo-WcDiskOperationalText @(2) | Should -Be 'OK'
        ConvertTo-WcDiskOperationalText @(3, 5) | Should -Be 'Degraded, Predictive Failure'
        ConvertTo-WcDiskOperationalText 'OK' | Should -Be 'OK'
    }
    It 'builds rows with counters, admin-required status and attention lists' {
        $e = @(
            @{ Disk = @{ FriendlyName = 'NVMe A'; MediaType = 4; BusType = 17; Size = 512GB; HealthStatus = 0; OperationalStatus = @(2) }
                Counter = @{ Wear = 3; Temperature = 41; TemperatureMax = 80; ReadErrorsUncorrected = 0; WriteErrorsUncorrected = 0 }; CounterStatus = 'Ok' }
            @{ Disk = @{ FriendlyName = 'HDD B'; MediaType = 'HDD'; BusType = 'SATA'; Size = 1TB; HealthStatus = 'Warning'; OperationalStatus = @('Predictive Failure') }
                Counter = $null; CounterStatus = 'RequiresAdmin' }
            @{ Disk = @{ FriendlyName = 'SSD C'; MediaType = 4; BusType = 11; Size = 256GB; HealthStatus = 0; OperationalStatus = @(2) }
                Counter = @{ Wear = 85; Temperature = 0; ReadErrorsUncorrected = 0; WriteErrorsUncorrected = 0 }; CounterStatus = 'Ok' }
        )
        $r = ConvertTo-WcHealthDiskRows -Entry $e
        @($r.Rows).Count | Should -Be 3
        $a = $r.Rows[0]
        $a.MediaType | Should -Be 'SSD'
        $a.BusType | Should -Be 'NVMe'
        $a.Size | Should -Be '512 GB'
        $a.WearPercent | Should -Be 3
        $a.TemperatureC | Should -Be 41
        $a.SeverityRaw | Should -Be 'Info'
        $r.Rows[1].Reliability | Should -Match 'admin'
        $r.Rows[1].WearPercent | Should -BeNullOrEmpty
        @($r.Unhealthy) | Should -Be @('HDD B')
        @($r.Attention) | Should -Be @('SSD C')
    }
    It 'Get-WcHealthDiskRaw reports RequiresAdmin instead of failing when counters are denied' {
        Mock -ModuleName WinCare.Health Get-PhysicalDisk { [pscustomobject]@{ FriendlyName = 'D'; DeviceId = '0' } }
        Mock -ModuleName WinCare.Health Get-StorageReliabilityCounter { throw 'Access denied' }
        Mock -ModuleName WinCare.Health Test-WcIsAdmin { $false }
        $r = @(Get-WcHealthDiskRaw)
        $r.Count | Should -Be 1
        $r[0].CounterStatus | Should -Be 'RequiresAdmin'
    }
}

Describe 'Startup: scheduled tasks' {
    It 'classifies Microsoft task paths' {
        Test-WcHealthMicrosoftTaskPath '\Microsoft\Windows\Defrag\' | Should -BeTrue
        Test-WcHealthMicrosoftTaskPath '\microsoft\Office\' | Should -BeTrue
        Test-WcHealthMicrosoftTaskPath '\' | Should -BeFalse
        Test-WcHealthMicrosoftTaskPath '\Contoso\' | Should -BeFalse
    }
    It 'detects logon/boot triggers only' {
        @(Get-WcHealthStartupTrigger @('MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger', 'MSFT_TaskLogonTrigger')) | Should -Be @('Logon', 'Boot')
        @(Get-WcHealthStartupTrigger @('MSFT_TaskDailyTrigger')).Count | Should -Be 0
    }
    It 'selects non-Microsoft logon/boot tasks (Microsoft only with -IncludeMicrosoft)' {
        $t = @(
            @{ TaskPath = '\'; TaskName = 'Updater'; TriggerTypes = @('MSFT_TaskLogonTrigger') }
            @{ TaskPath = '\'; TaskName = 'Daily'; TriggerTypes = @('MSFT_TaskDailyTrigger') }
            @{ TaskPath = '\Microsoft\Windows\X\'; TaskName = 'MsBoot'; TriggerTypes = @('MSFT_TaskBootTrigger') }
        )
        @(Select-WcHealthStartupTask -Task $t | ForEach-Object { $_.TaskName }) | Should -Be @('Updater')
        @(Select-WcHealthStartupTask -Task $t -IncludeMicrosoft).Count | Should -Be 2
    }
    It 'formats last result <V> as <E>' -ForEach @(
        @{ V = 0; E = '^.+ \(0x0\)$' }, @{ V = 267011; E = '\(0x41303\)$' }, @{ V = 2147942402; E = '^0x80070002$' }, @{ V = -2147024894; E = '^0x80070002$' }
    ) { ConvertTo-WcTaskResultText $V | Should -Match $E }
    It 'builds task rows with path, author, trigger and last run' {
        $t = @([pscustomobject]@{ TaskPath = '\Contoso\'; TaskName = 'Sync'; Author = 'Contoso'; State = 'Ready'; TriggerTypes = @('MSFT_TaskLogonTrigger'); Actions = @('C:\Program Files\Contoso\sync.exe', '(COM handler)') })
        $info = @{ '\Contoso\Sync' = [pscustomobject]@{ LastRunTime = [datetime]'2026-11-15T07:05:00'; LastTaskResult = 0 } }
        $r = @(ConvertTo-WcHealthTaskRows -Task $t -Info $info)
        $r[0].Name | Should -Be 'Sync'
        $r[0].Path | Should -Be 'C:\Program Files\Contoso\sync.exe; (COM handler)'
        $r[0].LastRun | Should -Be '2026-11-15 07:05'
        $r[0].Triggers | Should -Not -BeNullOrEmpty
        $never = @(ConvertTo-WcHealthTaskRows -Task $t -Info @{ '\Contoso\Sync' = [pscustomobject]@{ LastRunTime = [datetime]'1999-11-30'; LastTaskResult = 267011 } })
        $never[0].LastRun | Should -Not -Match '1999'
    }
    It 'thin collectors simplify tasks and never read action arguments' {
        Mock -ModuleName WinCare.Health Get-ScheduledTask {
            $trig = [pscustomobject]@{ CimClass = [pscustomobject]@{ CimClassName = 'MSFT_TaskLogonTrigger' } }
            [pscustomobject]@{ TaskPath = '\'; TaskName = 'T'; Author = 'A'; State = 'Ready'; Triggers = @($trig); Actions = @([pscustomobject]@{ Execute = 'x.exe'; Arguments = '--token=SECRET' }) }
        }
        $r = @(Get-WcHealthScheduledTaskRaw)
        $r[0].TriggerTypes | Should -Be @('MSFT_TaskLogonTrigger')
        $r[0].Actions | Should -Be @('x.exe')
        ($r | ConvertTo-Json -Depth 4) | Should -Not -Match 'SECRET'
        Mock -ModuleName WinCare.Health Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = [datetime]'2026-01-01'; LastTaskResult = 1 } }
        $i = Get-WcHealthScheduledTaskInfo -Task $r
        $i['\T'].LastTaskResult | Should -Be 1
    }
}

Describe 'Startup: services' {
    It 'parses <In>' -ForEach @(
        @{ In = '"C:\Program Files\Contoso\svc.exe" -k run'; Out = 'C:\Program Files\Contoso\svc.exe' }
        @{ In = 'C:\Program Files\Contoso\svc.exe /service'; Out = 'C:\Program Files\Contoso\svc.exe' }
        @{ In = 'C:\WINDOWS\system32\svchost.exe -k netsvcs -p'; Out = 'C:\WINDOWS\system32\svchost.exe' }
        @{ In = '%SystemRoot%\System32\svchost.exe -k LocalService'; Out = 'C:\Windows\System32\svchost.exe' }
        @{ In = '\SystemRoot\System32\drivers\x.sys'; Out = 'C:\Windows\System32\drivers\x.sys' }
        @{ In = '\??\C:\Tools\agent.exe'; Out = 'C:\Tools\agent.exe' }
        @{ In = 'system32\lsass.exe'; Out = 'C:\Windows\system32\lsass.exe' }
        @{ In = '%ProgramFiles%\Contoso\a.exe'; Out = 'C:\Program Files\Contoso\a.exe' }
        @{ In = ''; Out = '' }
    ) {
        ConvertTo-WcServiceBinaryPath -PathName $In -WindowsDir 'C:\Windows' -Environment @{ ProgramFiles = 'C:\Program Files' } | Should -Be $Out
    }
    It 'path containment uses Windows semantics and blocks ..' {
        Test-WcHealthPathUnder 'C:\WINDOWS\system32\a.exe' 'C:\Windows' | Should -BeTrue
        Test-WcHealthPathUnder 'C:\WindowsApps\a.exe' 'C:\Windows' | Should -BeFalse
        Test-WcHealthPathUnder 'C:\Windows\..\Tools\a.exe' 'C:\Windows' | Should -BeFalse
    }
    It 'extracts the signer name and recognizes Microsoft signatures' {
        ConvertTo-WcCertificateName 'CN=Contoso Ltd, O=Contoso, C=US' | Should -Be 'Contoso Ltd'
        ConvertTo-WcCertificateName 'O="Fabrikam, Inc.", C=US' | Should -Be 'Fabrikam, Inc.'
        Test-WcMicrosoftSigner -Status 'Valid' -Subject 'CN=Microsoft Windows, O=Microsoft Corporation, L=Redmond, C=US' | Should -BeTrue
        Test-WcMicrosoftSigner -Status 'HashMismatch' -Subject 'CN=Microsoft Windows, O=Microsoft Corporation' | Should -BeFalse
        Test-WcMicrosoftSigner -Status 'Valid' -Subject 'CN=Evil, O=Microsoft Corporation Fake' | Should -BeFalse
    }
    It 'keeps auto-start services outside %windir% and hides Microsoft-signed ones by default' {
        $svc = @(
            @{ Name = 'svcA'; DisplayName = 'Contoso Agent'; StartMode = 'Auto'; State = 'Running'; PathName = '"C:\Program Files\Contoso\agent.exe"' }
            @{ Name = 'WinDefend'; DisplayName = 'Defender'; StartMode = 'Auto'; State = 'Running'; PathName = '"C:\ProgramData\Microsoft\Windows Defender\Platform\4\MsMpEng.exe"' }
            @{ Name = 'Dnscache'; DisplayName = 'DNS'; StartMode = 'Auto'; State = 'Running'; PathName = 'C:\Windows\system32\svchost.exe -k NetworkService' }
            @{ Name = 'manual'; DisplayName = 'Manual'; StartMode = 'Manual'; State = 'Stopped'; PathName = 'C:\Tools\m.exe' }
        )
        $third = @(Select-WcHealthThirdPartyService -Service $svc -WindowsDir 'C:\Windows')
        @($third.Name) | Should -Be @('svcA', 'WinDefend')
        $sig = @{
            'c:\program files\contoso\agent.exe'                                   = [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=Contoso Ltd, O=Contoso Ltd, C=US' }
            'c:\programdata\microsoft\windows defender\platform\4\msmpeng.exe' = [pscustomobject]@{ Status = 'Valid'; Subject = 'CN=Microsoft Windows Publisher, O=Microsoft Corporation, C=US' }
        }
        $rows = @(ConvertTo-WcHealthServiceRows -Service $third -Signature $sig)
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'Contoso Agent'
        $rows[0].ServiceName | Should -Be 'svcA'
        $rows[0].SignedBy | Should -Be 'Contoso Ltd'
        $rows[0].Signature | Should -Be 'Valid'
        @(ConvertTo-WcHealthServiceRows -Service $third -Signature $sig -IncludeMicrosoft).Count | Should -Be 2
    }
    It 'caches signature checks per path' {
        $f = Join-Path $script:Tmp 'agent.exe'
        Set-Content -LiteralPath $f -Value 'x'
        Clear-WcHealthSignatureCache
        Mock -ModuleName WinCare.Health Get-AuthenticodeSignature { [pscustomobject]@{ Status = 'NotSigned'; SignerCertificate = $null } }
        (Get-WcHealthFileSignature -Path $f).Status | Should -Be 'NotSigned'
        (Get-WcHealthFileSignature -Path $f).Status | Should -Be 'NotSigned'
        Should -Invoke -ModuleName WinCare.Health Get-AuthenticodeSignature -Times 1 -Exactly
        (Get-WcHealthFileSignature -Path (Join-Path $script:Tmp 'missing.exe')).Status | Should -Be 'NotFound'
    }
}

Describe 'Battery' {
    It 'computes wear percent' {
        Get-WcWearPercent 50000 40000 | Should -Be 20
        Get-WcWearPercent 50000 55000 | Should -Be 0
        Get-WcWearPercent 0 40000 | Should -BeNullOrEmpty
        Get-WcWearPercent $null 40000 | Should -BeNullOrEmpty
    }
    It 'matches root\wmi static data and full-charge capacity by instance' {
        $r = ConvertTo-WcHealthBatteryRows -StaticData @(@{ InstanceName = 'ACPI\PNP0C0A\1_0'; DesignedCapacity = 57000; DeviceName = 'DELL ABC' }) `
            -FullCharge @(@{ InstanceName = 'ACPI\PNP0C0A\1_0'; FullChargedCapacity = 31350 }) -Win32Battery @(@{ Name = 'x' })
        $r.HasBattery | Should -BeTrue
        $r.Rows[0].Name | Should -Be 'DELL ABC'
        $r.Rows[0].WearPercent | Should -Be 45
        $r.MaxWear | Should -Be 45
    }
    It 'falls back to Win32_Battery and reports no battery when nothing exists' {
        $r = ConvertTo-WcHealthBatteryRows -Win32Battery @(@{ Name = 'Internal'; DesignCapacity = $null; FullChargeCapacity = $null })
        $r.HasBattery | Should -BeTrue
        $r.Rows[0].WearPercent | Should -BeNullOrEmpty
        (ConvertTo-WcHealthBatteryRows).HasBattery | Should -BeFalse
    }
    It 'does not query root\wmi when there is no battery' {
        Mock -ModuleName WinCare.Health Get-WcCimData { $null }
        (Get-WcHealthBattery).HasBattery | Should -BeFalse
        Should -Invoke -ModuleName WinCare.Health Get-WcCimData -Times 0 -ParameterFilter { $Namespace -eq 'root/wmi' }
    }
}

Describe 'Windows Update (read-only)' {
    It 'parses InstalledOn <V>' -ForEach @(
        @{ V = '11/3/2026'; E = '2026-11-03' }, @{ V = '20261103'; E = '2026-11-03' }, @{ V = '01d1a1b2c3d4e5f6'; E = 'x' }, @{ V = 'garbage'; E = $null }, @{ V = ''; E = $null }
    ) {
        $d = ConvertTo-WcHotFixDate $V
        if ($null -eq $E) { $d | Should -BeNullOrEmpty }
        elseif ($E -eq 'x') { $d | Should -BeOfType [datetime] }
        else { $d.ToString('yyyy-MM-dd') | Should -Be $E }
    }
    It 'summarizes history, hotfixes and the restart flag' {
        $now = [datetime]'2026-11-16T12:00:00'
        $hist = @(
            @{ Date = [datetime]'2026-11-01T10:00:00'; Title = 'KB5000001 cumulative'; ResultCode = 2; Operation = 1 }
            @{ Date = [datetime]'2026-11-05T10:00:00'; Title = 'KB5000002 failed'; ResultCode = 4; Operation = 1 }
            @{ Date = [datetime]'2026-11-06T10:00:00'; Title = 'uninstall'; ResultCode = 2; Operation = 2 }
        )
        $hf = @(@{ HotFixID = 'KB1'; InstalledOn = '10/20/2026' }, @{ HotFixID = 'KB2'; InstalledOn = '11/2/2026' })
        $r = ConvertTo-WcHealthUpdateRows -History $hist -HotFix $hf -PendingReboot ([pscustomobject]@{ IsPending = $true; Sources = @('CbsRebootPending') }) -Now $now
        $r.DaysSinceInstall | Should -Be 14
        $r.Failed | Should -Be 1
        $r.RebootPending | Should -BeTrue
        @($r.Rows).Count | Should -Be 6
        $r.Rows[0].Value | Should -Match 'KB5000001'
        $r.Rows[1].Value | Should -Be '2026-11-02 - KB2'
        $r.Rows[4].Value | Should -Match 'CbsRebootPending'
    }
    It 'never fails without history (COM error is shown in the row)' {
        $r = ConvertTo-WcHealthUpdateRows -HistoryError 'COM not available'
        $r.DaysSinceInstall | Should -BeNullOrEmpty
        $r.Rows[0].Value | Should -Match 'COM not available'
    }
}

Describe 'Time and uptime' {
    It 'computes uptime and reads the configured source' {
        $r = ConvertTo-WcHealthTimeRows -LastBootUpTime ([datetime]'2026-11-01T12:00:00') -Now ([datetime]'2026-11-16T14:30:00') -TimeConfig @{ Type = 'NTP'; NtpServer = 'time.windows.com,0x9' } -TimeService @{ State = 'Running'; StartMode = 'Manual' }
        $r.UptimeDays | Should -Be 15.1
        $r.Rows[0].Value | Should -Be '15d 2h 30min'
        $r.Rows[2].Value | Should -Be 'Running / Manual'
        $r.Rows[4].Value | Should -Be 'time.windows.com,0x9'
        $r.ClockIssue | Should -BeFalse
    }
    It 'flags a boot time in the future and NoSync' {
        $r = ConvertTo-WcHealthTimeRows -LastBootUpTime ([datetime]'2027-01-01') -Now ([datetime]'2026-11-16') -TimeConfig @{ Type = 'NoSync' }
        $r.ClockIssue | Should -BeTrue
        $r.NoSync | Should -BeTrue
        $r.UptimeDays | Should -BeNullOrEmpty
    }
}

Describe 'Findings' {
    It 'creates findings at the thresholds only' {
        $f = @(Get-WcHealthFinding -Metric @{
                Days = 7; EventTotals = @{ UnexpectedShutdown = 2; BugCheck = 1; Disk = 0; Whea = 0; AppCrash = 9 }
                DeviceProblems = 1; UnhealthyDisks = @('HDD B'); BatteryWear = 45; DaysSinceUpdate = 61; UptimeDays = 31.5; ClockIssue = $false
            })
        @($f.Id) | Should -Be @('health-bugchecks', 'health-disk-unhealthy', 'health-unexpected-shutdowns', 'health-device-problems', 'health-battery-worn', 'health-update-stale', 'health-uptime-long')
        ($f | Where-Object { $_.Id -eq 'health-bugchecks' }).Evidence | Should -Be @(1, 7)
        ($f | Where-Object { $_.Id -eq 'health-uptime-long' }).Evidence | Should -Be @(31)
        $f[0].TitleKey | Should -Be 'finding.health-bugchecks.title'
        @(Get-WcHealthFinding -Metric @{ Days = 7; BatteryWear = 39.9; DaysSinceUpdate = 59; UptimeDays = 2 }).Count | Should -Be 0
        @(Get-WcHealthFinding -Metric @{}).Count | Should -Be 0
    }
}

Describe 'Get-WcHealthPageData (contract section 6)' {
    BeforeAll {
        $script:Pt = Get-Content -Raw -Encoding UTF8 (Join-Path $script:LocDir 'pt-BR.d/f6-health.json') | ConvertFrom-Json
        $script:En = Get-Content -Raw -Encoding UTF8 (Join-Path $script:LocDir 'en-US.d/f6-health.json') | ConvertFrom-Json
        function Get-AllKeys([string] $Lang) {
            $keys = @((Get-Content -Raw -Encoding UTF8 (Join-Path $script:LocDir "$Lang.json") | ConvertFrom-Json).PSObject.Properties.Name)
            foreach ($f in Get-ChildItem (Join-Path $script:LocDir "$Lang.d") -Filter '*.json') { $keys += @((Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json).PSObject.Properties.Name) }
            return $keys
        }
        $script:PtAll = @(Get-AllKeys 'pt-BR'); $script:EnAll = @(Get-AllKeys 'en-US')
    }
    BeforeEach {
        Mock -ModuleName WinCare.Health Get-WcHealthEventRaw {
            switch ($Query.Category) {
                'UnexpectedShutdown' { @([pscustomobject]@{ ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; Level = 1; TimeCreated = [datetime]'2026-11-12'; Data = @() }) }
                'AppCrash' { @([pscustomobject]@{ ProviderName = 'Application Error'; Id = 1000; Level = 2; TimeCreated = [datetime]'2026-11-12'; Data = @('a.exe') }) }
                default { @() }
            }
        }
        Mock -ModuleName WinCare.Health Get-WcCimData {
            switch ($ClassName) {
                'Win32_PnPEntity' { @([pscustomobject]@{ Name = 'Cam'; PNPClass = 'Camera'; ConfigManagerErrorCode = 28 }) }
                'Win32_Service' {
                    if ($Filter -match 'W32Time') { [pscustomobject]@{ State = 'Running'; StartMode = 'Manual' } }
                    else { @([pscustomobject]@{ Name = 's'; DisplayName = 'S'; StartMode = 'Auto'; State = 'Running'; PathName = 'C:\Tools\s.exe' }) }
                }
                'Win32_OperatingSystem' { [pscustomobject]@{ LastBootUpTime = (Get-Date).AddDays(-2) } }
                'Win32_QuickFixEngineering' { @([pscustomobject]@{ HotFixID = 'KB1'; InstalledOn = (Get-Date).AddDays(-3).ToString('M/d/yyyy', [System.Globalization.CultureInfo]::InvariantCulture) }) }
                default { $null }
            }
        }
        Mock -ModuleName WinCare.Health Get-WcHealthDiskRaw { @([pscustomobject]@{ Disk = @{ FriendlyName = 'D'; MediaType = 4; BusType = 17; Size = 1GB; HealthStatus = 0; OperationalStatus = @(2) }; Counter = $null; CounterStatus = 'RequiresAdmin' }) }
        Mock -ModuleName WinCare.Health Get-WcHealthScheduledTaskRaw { @([pscustomobject]@{ TaskPath = '\'; TaskName = 'T'; Author = 'A'; State = 'Ready'; TriggerTypes = @('MSFT_TaskBootTrigger'); Actions = @('t.exe') }) }
        Mock -ModuleName WinCare.Health Get-WcHealthScheduledTaskInfo { @{ '\T' = [pscustomobject]@{ LastRunTime = [datetime]'2026-11-15'; LastTaskResult = 0 } } }
        Mock -ModuleName WinCare.Health Get-WcHealthFileSignature { [pscustomobject]@{ Status = 'NotSigned'; Subject = '' } }
        Mock -ModuleName WinCare.Health Get-WcHealthUpdateHistory { @() }
        Mock -ModuleName WinCare.Health Get-WcPendingReboot { [pscustomobject]@{ IsPending = $false; Sources = @() } }
        Mock -ModuleName WinCare.Health Get-WcRegistryValues { @{ Type = 'NTP'; NtpServer = 'time.windows.com' } }
    }
    It 'returns the page shape with every section, no errors and findings' {
        $d = Get-WcHealthPageData -Context (New-WcContext)
        $d.PageId | Should -Be 'health'
        @($d.Sections.Id) | Should -Be @('critical-events', 'app-crashes', 'devices', 'disks', 'startup-tasks', 'startup-services', 'battery', 'updates', 'time-uptime')
        @($d.Errors).Count | Should -Be 0 -Because (@($d.Errors) -join '; ')
        ($d.Sections | Where-Object { $_.Id -eq 'battery' }).NoteKey | Should -Be 'section.health.battery.none'
        ($d.Sections | Where-Object { $_.Id -eq 'critical-events' }).Severity | Should -Be 'Warning'
        ($d.Sections | Where-Object { $_.Id -eq 'devices' }).Severity | Should -Be 'Warning'
        @(($d.Sections | Where-Object { $_.Id -eq 'startup-services' }).Rows).Count | Should -Be 1
        @($d.Findings.Id) | Should -Contain 'health-unexpected-shutdowns'
        @($d.Findings.Id) | Should -Contain 'health-device-problems'
    }
    It 'every title, note, column and finding key exists in both languages' {
        $d = Get-WcHealthPageData
        $keys = @()
        foreach ($s in $d.Sections) {
            $keys += $s.TitleKey; $keys += $s.NoteKey
            foreach ($r in @($s.Rows)) { foreach ($p in $r.PSObject.Properties.Name) { if ($p -notmatch 'Raw$') { $keys += "col.$p" } } }
        }
        foreach ($f in $d.Findings) { $keys += $f.TitleKey; $keys += $f.RecommendationKey }
        $keys += 'section.health.unavailable'
        foreach ($k in ($keys | Sort-Object -Unique)) {
            $script:PtAll | Should -Contain $k
            $script:EnAll | Should -Contain $k
        }
    }
    It 'fragments have the same keys and placeholders, and no col key duplicates another file' {
        Compare-Object @($script:Pt.PSObject.Properties.Name) @($script:En.PSObject.Properties.Name) | Should -BeNullOrEmpty
        foreach ($k in $script:Pt.PSObject.Properties.Name) {
            $a = @([regex]::Matches($script:Pt.$k, '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
            $b = @([regex]::Matches($script:En.$k, '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
            $a | Should -Be $b -Because $k
        }
        @($script:PtAll | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }
    It 'never throws: a failing collector becomes an error and an empty section' {
        Mock -ModuleName WinCare.Health Get-WcHealthDiskRaw { throw 'boom' }
        Mock -ModuleName WinCare.Health Get-WcHealthScheduledTaskRaw { throw 'denied' }
        $d = Get-WcHealthPageData
        @($d.Sections).Count | Should -Be 9
        @($d.Errors) | Should -Contain 'disks: boom'
        @($d.Errors) | Should -Contain 'startup-tasks: denied'
        ($d.Sections | Where-Object { $_.Id -eq 'disks' }).NoteKey | Should -Be 'section.health.unavailable'
    }
}

Describe 'Health actions' {
    It 'tool validation allows <Desc>' -ForEach @(
        @{ Desc = 'powercfg with a reports path'; Exe = 'C:\Windows\System32\powercfg.exe'; A = @('/batteryreport', '/output', 'C:\Users\a b\AppData\Local\WinCare\reports\battery-report.html'); Ok = $true }
        @{ Desc = 'Sysnative'; Exe = 'C:\Windows\Sysnative\powercfg.exe'; A = @('/energy', '/duration', '60'); Ok = $true }
        @{ Desc = 'no exe outside System32'; Exe = 'C:\Temp\powercfg.exe'; A = @(); Ok = $false }
        @{ Desc = 'no path outside reports'; Exe = 'C:\Windows\System32\powercfg.exe'; A = @('/output', 'C:\Windows\x.html'); Ok = $false }
        @{ Desc = 'no traversal'; Exe = 'C:\Windows\System32\powercfg.exe'; A = @('/output', 'C:\Users\a b\AppData\Local\WinCare\reports\..\..\x.html'); Ok = $false }
        @{ Desc = 'no quotes'; Exe = 'C:\Windows\System32\powercfg.exe'; A = @('C:\Users\a b\AppData\Local\WinCare\reports\x" & calc'); Ok = $false }
        @{ Desc = 'no shell metacharacters'; Exe = 'C:\Windows\System32\powercfg.exe'; A = @('/x&calc'); Ok = $false }
    ) {
        $why = Test-WcHealthToolCommand -FilePath $Exe -ArgumentList $A -SystemRoot 'C:\Windows' -ReportsDir 'C:\Users\a b\AppData\Local\WinCare\reports'
        if ($Ok) { $why | Should -BeNullOrEmpty } else { $why | Should -Not -BeNullOrEmpty }
    }
    It 'previews power reports without running anything' {
        Mock -ModuleName WinCare.Health Invoke-WcHealthTool { throw 'must not run' }
        $b = Invoke-WcHealthPowerReport -Kind Battery
        $b.Summary | Should -Match '^Would run: .+powercfg\.exe /batteryreport /output .+battery-report\.html'
        $e = Invoke-WcHealthPowerReport -Kind Energy
        $e.Summary | Should -Match '/energy /output .+energy-report\.html /duration 60'
        $e.Items[0].RequiresAdmin | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Health Invoke-WcHealthTool -Times 0
    }
    It 'battery report returns the written path' {
        Mock -ModuleName WinCare.Health Invoke-WcHealthTool { Set-Content -LiteralPath $ArgumentList[2] -Value '<html></html>'; [pscustomobject]@{ ExitCode = 0; StdOut = 'Battery life report saved'; StdErr = '' } }
        $r = Invoke-WcHealthPowerReport -Kind Battery -Execute
        $r.Summary | Should -Match 'battery-report\.html'
        $r.ExitCode | Should -Be 0
        Test-Path -LiteralPath $r.Items[0].Path | Should -BeTrue
        Should -Invoke -ModuleName WinCare.Health Invoke-WcHealthTool -Times 1 -ParameterFilter { $ArgumentList[0] -eq '/batteryreport' -and $FilePath -match 'System32\\powercfg\.exe$' }
    }
    It 'fails clearly when powercfg writes no report (e.g. no battery)' {
        Remove-Item -LiteralPath (Join-Path (Get-WcHealthReportDir) 'battery-report.html') -ErrorAction SilentlyContinue
        Mock -ModuleName WinCare.Health Invoke-WcHealthTool { [pscustomobject]@{ ExitCode = 1; StdOut = 'Unable to perform operation.'; StdErr = '' } }
        { Invoke-WcHealthPowerReport -Kind Battery -Execute } | Should -Throw '*exit code 1*'
    }
    It 'energy report refuses without administrator' {
        Mock -ModuleName WinCare.Health Test-WcIsAdmin { $false }
        Mock -ModuleName WinCare.Health Invoke-WcHealthTool { throw 'must not run' }
        { Invoke-WcHealthPowerReport -Kind Energy -Execute } | Should -Throw '*administrator*'
        Should -Invoke -ModuleName WinCare.Health Invoke-WcHealthTool -Times 0
    }
    It 'exports summarized events to JSON without message text' {
        Mock -ModuleName WinCare.Health Get-WcHealthEventRaw {
            if ($Query.Category -eq 'BugCheck') { @([pscustomobject]@{ ProviderName = 'BugCheck'; Id = 1001; Level = 2; TimeCreated = [datetime]'2026-11-12'; Data = @('0x0000001a (0x1)') }) } else { @() }
        }
        $r = Export-WcHealthEvent -Directory $script:Tmp
        Test-Path -LiteralPath $r.Path | Should -BeTrue
        $r.Path | Should -Match 'health-events-\d{8}-\d{6}\.json$'
        $j = Get-Content -Raw -LiteralPath $r.Path | ConvertFrom-Json
        $j.Totals.BugCheck | Should -Be 1
        @($j.CriticalEvents)[0].Detail | Should -Be '0x0000001a'
        (Get-Content -Raw -LiteralPath $r.Path) | Should -Not -Match '"Message"'
    }
    It 'registers a handler for every health catalog action; previews do not execute' {
        Clear-WcActionHandlers
        Register-WcHealthHandler
        $all = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        $cat = @($all | Where-Object { $_.Id -like 'health.*' })
        $cat.Count | Should -Be 4
        $names = Get-WcActionHandlerNames
        foreach ($a in $cat) { $names | Should -Contain $a.Handler }
        Mock -ModuleName WinCare.Health Start-WcHealthReliabilityMonitor { throw 'must not open' }
        Mock -ModuleName WinCare.Health Export-WcHealthEvent { throw 'must not export' }
        $plan = New-WcPlan -Catalog $cat -ActionId @($cat.Id) -OperationProfile (Get-WcProfile 'Diagnostico') -Context (New-WcContext -IsAdmin $true -Build 26100)
        @($plan.Items | Where-Object { -not $_.Allowed }).Count | Should -Be 0 -Because 'read-only actions are allowed in the Diagnostico profile'
        Clear-WcActionHandlers
    }
}

Describe 'Health safety' {
    It 'catalog actions are read-only, risk None, page health and never touch protected features' {
        $frag = Get-Content -Raw (Join-Path $script:SrcRoot 'Core/actions.d/f6-health.json') | ConvertFrom-Json
        foreach ($a in @($frag.actions)) {
            $a.Risk | Should -Be 'None'
            $a.Modifies | Should -BeFalse
            $a.Reversibility | Should -Be 'ReadOnly'
            @($a.Pages) | Should -Be @('health')
            $a.PSObject.Properties.Name | Should -Not -Contain 'Touches'
        }
    }
    It 'the module never clears logs, disables tasks/services, changes drivers or Windows Update' {
        $path = Join-Path $script:SrcRoot 'Modules/WinCare.Health.psm1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$null)
        $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } | Where-Object { $_ })
        $forbidden = 'Clear-EventLog', 'Remove-EventLog', 'Limit-EventLog', 'Disable-ScheduledTask', 'Unregister-ScheduledTask', 'Set-ScheduledTask', 'Stop-ScheduledTask',
        'Set-Service', 'Stop-Service', 'Remove-Service', 'Disable-PnpDevice', 'Remove-PnpDevice', 'Set-ItemProperty', 'Remove-Item', 'New-ItemProperty', 'Stop-Process'
        foreach ($f in $forbidden) { $cmds | Should -Not -Contain $f }
        $text = Get-Content -Raw -LiteralPath $path
        $text | Should -Not -Match '(?i)wevtutil|pnputil|sc\.exe|UsoClient|wuauclt|\.Install\(\)|\.Download\(\)|CreateUpdateInstaller|CreateUpdateDownloader'
    }
}
