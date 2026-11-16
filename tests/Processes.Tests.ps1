#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F6 page 'processes' (WinCare.Processes). Pure logic with fixtures; every I/O wrapper
# is mocked. Nothing here ends, closes or opens a real process.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @('System', 'Processes')
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'processes.jsonl') | Out-Null

    function New-Snap([int] $Id, [string] $Name, $Ws = 100MB, $Priv = 80MB, $Cpu = 1.0, $Session = 1, [bool] $Window = $false, [string] $Path = '') {
        [pscustomobject]@{ Id = $Id; Name = $Name; WorkingSet = $Ws; PrivateBytes = $Priv; CpuSeconds = $Cpu; SessionId = $Session; HasWindow = $Window; Path = $Path; StartTime = $null }
    }
    function New-Env([bool] $Admin = $false, [string] $User = 'PC\ana', $Session = 1, [int] $Self = 999) {
        [pscustomobject]@{ IsAdmin = $Admin; CurrentUser = $User; CurrentSessionId = $Session; SelfPid = $Self }
    }
    function New-Target([int] $Id = 1234, [string] $Name = 'notepad', $Session = 1, [string] $Owner = 'PC\ana', [string] $Path = 'C:\Windows\System32\notepad.exe', [string] $Company = 'Microsoft Corporation', [string[]] $Services = @()) {
        [pscustomobject]@{ ProcessId = $Id; Name = $Name; SessionId = $Session; Path = $Path; Company = $Company; Description = ''; Owner = $Owner
            Services = $Services; WorkingSet = 50MB; PrivateBytes = 40MB; HasWindow = $true }
    }
}

Describe 'Thresholds and status (pure)' {
    It 'higher-is-worse: <Value> -> <Expected>' -ForEach @(
        @{ Value = 50; Expected = 'Ok' }, @{ Value = 80; Expected = 'Pressure' }, @{ Value = 94.9; Expected = 'Pressure' }, @{ Value = 95; Expected = 'Critical' }, @{ Value = $null; Expected = 'Unknown' }
    ) {
        Get-WcLevelStatus -Value $Value -Pressure 80 -Critical 95 | Should -Be $Expected
    }
    It 'lower-is-worse: <Value> -> <Expected>' -ForEach @(
        @{ Value = 40; Expected = 'Ok' }, @{ Value = 15; Expected = 'Ok' }, @{ Value = 14.9; Expected = 'Pressure' }, @{ Value = 4; Expected = 'Critical' }
    ) {
        Get-WcLevelStatus -Value $Value -Pressure 15 -Critical 5 -LowerIsWorse | Should -Be $Expected
    }
    It 'documents every threshold' {
        $t = Get-WcProcessesThreshold
        foreach ($k in 'AvailablePressurePercent', 'AvailableCriticalPercent', 'CommitPressurePercent', 'CommitCriticalPercent', 'PagefilePressurePercent', 'HardFaultPressurePerSec', 'GrowthMinBytes', 'GrowthMinPercent') {
            $t.ContainsKey($k) | Should -BeTrue -Because $k
        }
    }
    It 'section severity follows the worst status' {
        Get-WcProcSeverity -Status @('Ok', 'Info') | Should -Be 'Info'
        Get-WcProcSeverity -Status @('Ok', 'Pressure') | Should -Be 'Warning'
        Get-WcProcSeverity -Status @('Pressure', 'Critical') | Should -Be 'Critical'
    }
}

Describe 'Memory overview (pure)' {
    It 'computes the hard-fault rate from two raw samples (Timestamp_Sys100NS)' {
        $a = [pscustomobject]@{ PagesInputPersec = 1000; Timestamp_Sys100NS = 0 }
        $b = [pscustomobject]@{ PagesInputPersec = 7000; Timestamp_Sys100NS = 60000000 }
        ConvertTo-WcHardFaultRate -First $a -Second $b | Should -Be 1000
    }
    It 'falls back to the measured wall time and rejects counter resets' {
        ConvertTo-WcHardFaultRate -First @{ PagesInputPersec = 10 } -Second @{ PagesInputPersec = 40 } -ElapsedSeconds 3 | Should -Be 10
        ConvertTo-WcHardFaultRate -First @{ PagesInputPersec = 50 } -Second @{ PagesInputPersec = 40 } -ElapsedSeconds 3 | Should -BeNullOrEmpty
        ConvertTo-WcHardFaultRate -First $null -Second @{ PagesInputPersec = 40 } -ElapsedSeconds 3 | Should -BeNullOrEmpty
    }
    It 'builds facts from CIM data in bytes' {
        $os = [pscustomobject]@{ TotalVisibleMemorySize = 8388608; FreePhysicalMemory = 1048576; TotalVirtualMemorySize = 12582912; FreeVirtualMemory = 4194304 }
        $perf = [pscustomobject]@{ AvailableBytes = 2GB; CommittedBytes = 9GB; CommitLimit = 12GB }
        $pf = @([pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = 4096; CurrentUsage = 1024; PeakUsage = 2048 })
        $f = ConvertTo-WcMemoryFacts -OperatingSystem $os -PerfMemory $perf -PageFile $pf -CompressedBytes 300MB -HardFaultsPerSec 12
        $f.TotalBytes | Should -Be 8GB
        $f.AvailableBytes | Should -Be 2GB
        $f.CommittedBytes | Should -Be 9GB
        $f.CommitLimitBytes | Should -Be 12GB
        $f.PageFiles[0].AllocatedBytes | Should -Be 4GB
        $f.PageFiles[0].UsedBytes | Should -Be 1GB
        $f.CompressedBytes | Should -Be 300MB
    }
    It 'falls back to Win32_OperatingSystem when the perf class is missing' {
        $os = [pscustomobject]@{ TotalVisibleMemorySize = 8388608; FreePhysicalMemory = 1048576; TotalVirtualMemorySize = 12582912; FreeVirtualMemory = 4194304 }
        $f = ConvertTo-WcMemoryFacts -OperatingSystem $os -PerfMemory $null -PageFile @()
        $f.AvailableBytes | Should -Be 1GB
        $f.CommitLimitBytes | Should -Be 12GB
        $f.CommittedBytes | Should -Be 8GB
        @($f.PageFiles).Count | Should -Be 0
        $f.CompressedBytes | Should -BeNullOrEmpty
    }
    It 'flags pressure and critical with the documented limits' {
        $f = [pscustomobject]@{ TotalBytes = 16GB; AvailableBytes = 0.5GB; CommittedBytes = 17GB; CommitLimitBytes = 20GB
            PageFiles = @([pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBytes = 4GB; UsedBytes = 3.5GB; PeakBytes = 3.9GB })
            CompressedBytes = 1GB; HardFaultsPerSec = 1500; SampleSeconds = 6
        }
        $rows = @(ConvertTo-WcMemoryOverviewRows -Facts $f)
        $byKey = @{}
        foreach ($r in $rows) { $byKey[$r.Metric] = $r.ProcStatusRaw }
        $byKey['Available memory'] | Should -Be 'Critical'          # 3.1 % < 5 %
        $byKey['Commit charge / limit'] | Should -Be 'Pressure'     # 85 %
        $byKey['Page file usage'] | Should -Be 'Pressure'           # 87.5 %
        $byKey['Hard faults (pages read from disk)'] | Should -Be 'Pressure'
        $byKey['Compressed memory (Memory Compression)'] | Should -Be 'Info'
        foreach ($r in $rows) { $r.PSObject.Properties.Name | Should -Be @('Metric', 'Value', 'Status', 'ProcThreshold', 'ProcStatusRaw') }
    }
    It 'reports OK and handles a missing page file and missing samples' {
        $f = [pscustomobject]@{ TotalBytes = 16GB; AvailableBytes = 8GB; CommittedBytes = 6GB; CommitLimitBytes = 18GB; PageFiles = @(); CompressedBytes = $null; HardFaultsPerSec = $null; SampleSeconds = 0 }
        $rows = @(ConvertTo-WcMemoryOverviewRows -Facts $f)
        ($rows | Where-Object { $_.Metric -eq 'Available memory' }).ProcStatusRaw | Should -Be 'Ok'
        ($rows | Where-Object { $_.Metric -eq 'Commit charge / limit' }).ProcStatusRaw | Should -Be 'Ok'
        ($rows | Where-Object { $_.Metric -eq 'Page file' }).Value | Should -Be 'none configured'
        ($rows | Where-Object { $_.Metric -like 'Hard faults*' }).ProcStatusRaw | Should -Be 'Unknown'
    }
}

Describe 'Process inventory (pure)' {
    It 'classifies <Name> (pid <Id>, session <S>, window <W>, services <Svc>) as <Expected>' -ForEach @(
        @{ Id = 4; Name = 'System'; S = 0; W = $false; Svc = 0; Expected = 'System' }
        @{ Id = 700; Name = 'lsass'; S = 0; W = $false; Svc = 1; Expected = 'System' }
        @{ Id = 1200; Name = 'svchost'; S = 0; W = $false; Svc = 3; Expected = 'Service' }
        @{ Id = 1300; Name = 'WmiPrvSE'; S = 0; W = $false; Svc = 0; Expected = 'Session0' }
        @{ Id = 5000; Name = 'WINWORD'; S = 1; W = $true; Svc = 0; Expected = 'App' }
        @{ Id = 5100; Name = 'OneDrive'; S = 1; W = $false; Svc = 0; Expected = 'Background' }
    ) {
        ConvertTo-WcProcessKind -ProcessId $Id -Name $Name -SessionId $S -HasWindow $W -ServiceCount $Svc | Should -Be $Expected
    }
    It 'maps services to their host process (running ones only)' {
        $svc = @(
            [pscustomobject]@{ Name = 'Dnscache'; ProcessId = 1200 }
            [pscustomobject]@{ Name = 'BITS'; ProcessId = 1200 }
            [pscustomobject]@{ Name = 'Stopped'; ProcessId = 0 }
            [pscustomobject]@{ Name = 'Spooler'; ProcessId = 1500 }
        )
        $m = ConvertTo-WcServiceMap -Service $svc
        $m[1200] | Should -Be @('BITS', 'Dnscache')
        $m.ContainsKey(0) | Should -BeFalse
        ConvertTo-WcServiceListText -Name @('a', 'b', 'c') -Max 2 | Should -Be 'a, b (+1)'
        ConvertTo-WcServiceListText -Name @() | Should -Be ''
    }
    It 'merges snapshot, CIM path/session and services; never carries the command line' {
        $snap = @((New-Snap 1200 'svchost' -Session $null), (New-Snap 5000 'app' -Path ''))
        $cim = @(
            [pscustomobject]@{ ProcessId = 1200; ExecutablePath = 'C:\Windows\System32\svchost.exe'; SessionId = 0; CommandLine = 'svchost -k secret' }
            [pscustomobject]@{ ProcessId = 5000; ExecutablePath = 'C:\Users\ana\AppData\Roaming\x\app.exe'; SessionId = 1; CommandLine = 'app --token=abc' }
        )
        $inv = @(ConvertTo-WcProcessInventory -Snapshot $snap -CimProcess $cim -ServiceMap @{ 1200 = @('BITS') })
        $inv[0].Path | Should -Be 'C:\Windows\System32\svchost.exe'
        $inv[0].SessionId | Should -Be 0
        $inv[0].Kind | Should -Be 'Service'
        $inv[1].Path | Should -Be 'C:\Users\ana\AppData\Roaming\x\app.exe'
        foreach ($o in $inv) { $o.PSObject.Properties.Name | Should -Not -Contain 'CommandLine' }
        $rows = @(ConvertTo-WcTopMemoryRows -Process $inv)
        ($rows | ConvertTo-Json -Depth 3) | Should -Not -Match 'secret|token'
        $rows[0].ProcServices | Should -Be 'BITS'
    }
    It 'selects the top N by working set and skips Idle' {
        $inv = @(
            [pscustomobject]@{ Id = 0; Name = 'Idle'; WorkingSet = 9GB }
            [pscustomobject]@{ Id = 10; Name = 'a'; WorkingSet = 1GB }
            [pscustomobject]@{ Id = 11; Name = 'b'; WorkingSet = 3GB }
            [pscustomobject]@{ Id = 12; Name = 'c'; WorkingSet = 2GB }
        )
        $top = @(Select-WcTopProcess -Inventory $inv -Top 2)
        @($top | ForEach-Object { $_.Name }) | Should -Be @('b', 'c')
    }
    It 'formats bytes for display' {
        ConvertTo-WcProcBytesText $null | Should -Be '-'
        ConvertTo-WcProcBytesText 512KB | Should -Match '^512 KB$'
        ConvertTo-WcProcBytesText (-20MB) | Should -Match '^-20 MB$'
    }
}

Describe 'Growth check (heuristic, pure)' {
    It 'flags steady growth above both minimums' {
        $g = Test-WcProcessGrowth -Sample @(100MB, 110MB, 125MB)
        $g.Growing | Should -BeTrue
        $g.DeltaBytes | Should -Be 25MB
        $g.Percent | Should -Be 25
    }
    It 'does not flag a dip, a flat sample, tiny growth or a single sample' {
        (Test-WcProcessGrowth -Sample @(100MB, 130MB, 125MB)).Growing | Should -BeFalse
        (Test-WcProcessGrowth -Sample @(100MB, 100MB, 140MB)).Growing | Should -BeFalse
        (Test-WcProcessGrowth -Sample @(100MB, 101MB, 102MB)).Growing | Should -BeFalse   # < 10 MB
        (Test-WcProcessGrowth -Sample @(2GB, 2GB + 6MB, 2GB + 12MB)).Growing | Should -BeFalse   # >= 10 MB but < 5 %
        (Test-WcProcessGrowth -Sample @(100MB)).Growing | Should -BeFalse
    }
    It 'builds series only for processes present in every sample with the same name (PID reuse)' {
        $s1 = @((New-Snap 10 'a' -Priv 300MB), (New-Snap 11 'b' -Priv 200MB), (New-Snap 12 'c' -Priv 100MB))
        $s2 = @((New-Snap 10 'a' -Priv 320MB), (New-Snap 11 'other' -Priv 220MB), (New-Snap 12 'c' -Priv 100MB))
        $s3 = @((New-Snap 10 'a' -Priv 340MB), (New-Snap 11 'other' -Priv 240MB))
        $series = @(ConvertTo-WcGrowthSeries -Snapshots (@(, $s1) + @(, $s2) + @(, $s3)) -Top 15)
        $series.Count | Should -Be 1
        $series[0].Name | Should -Be 'a'
        $series[0].Samples | Should -Be @(300MB, 320MB, 340MB)
        $rows = @(ConvertTo-WcGrowthRows -Series $series)
        $rows[0].ProcStatusRaw | Should -Be 'Growing'
        $rows[0].ProcSamples | Should -Match '->'
    }
    It 'sorts growing processes first' {
        $series = @(
            [pscustomobject]@{ Id = 1; Name = 'stable'; Samples = @(500MB, 400MB, 900MB) }
            [pscustomobject]@{ Id = 2; Name = 'leaky'; Samples = @(100MB, 120MB, 140MB) }
        )
        $rows = @(ConvertTo-WcGrowthRows -Series $series)
        $rows[0].Name | Should -Be 'leaky'
    }
}

Describe 'CPU now (pure)' {
    It 'computes % of total capacity, top N, skipping Idle, new and renamed PIDs' {
        $a = @((New-Snap 0 'Idle' -Cpu 100), (New-Snap 10 'busy' -Cpu 10), (New-Snap 11 'calm' -Cpu 5), (New-Snap 12 'reused' -Cpu 1), (New-Snap 13 'noaccess' -Cpu $null))
        $b = @((New-Snap 0 'Idle' -Cpu 120), (New-Snap 10 'busy' -Cpu 14), (New-Snap 11 'calm' -Cpu 5.5), (New-Snap 12 'other' -Cpu 9), (New-Snap 13 'noaccess' -Cpu $null), (New-Snap 14 'new' -Cpu 3))
        $rows = @(ConvertTo-WcCpuRows -First $a -Last $b -ElapsedSeconds 2 -LogicalProcessors 4 -Top 10)
        @($rows | ForEach-Object { $_.Name }) | Should -Be @('busy', 'calm')
        $rows[0].ProcCpuPercentRaw | Should -Be 50     # 4 s of CPU in 2 s on 4 logical CPUs
        $rows[1].ProcCpuPercentRaw | Should -Be 6.3
    }
    It 'returns nothing for an invalid window' {
        @(ConvertTo-WcCpuRows -First @() -Last @() -ElapsedSeconds 0).Count | Should -Be 0
    }
}

Describe 'Background programs worth reviewing (pure)' {
    It 'location <Path> -> <Expected>' -ForEach @(
        @{ Path = 'C:\Users\ana\AppData\Local\Temp\x\setup.exe'; Expected = 'Temp' }
        @{ Path = 'C:\Windows\Temp\a.exe'; Expected = 'Temp' }
        @{ Path = 'C:\Users\ana\AppData\Roaming\Tool\tool.exe'; Expected = 'AppData' }
        @{ Path = 'C:\Users\ana\Downloads\thing.exe'; Expected = 'Downloads' }
        @{ Path = 'C:\Users\ana\AppData\Local\Programs\Microsoft VS Code\Code.exe'; Expected = $null }
        @{ Path = 'C:\Program Files\App\app.exe'; Expected = $null }
        @{ Path = ''; Expected = $null }
    ) {
        ConvertTo-WcProcessLocationKind -Path $Path | Should -Be $Expected
    }
    It 'honours custom roots from the environment' {
        ConvertTo-WcProcessLocationKind -Path 'D:\T\x.exe' -TempRoot 'D:\T' | Should -Be 'Temp'
        ConvertTo-WcProcessLocationKind -Path 'E:\Baixados\x.exe' -DownloadsRoot 'E:\Baixados\' | Should -Be 'Downloads'
    }
    It 'worth review: <Loc>/<Sig> -> <Expected>' -ForEach @(
        @{ Loc = 'Temp'; Sig = 'Valid'; Expected = $true }
        @{ Loc = $null; Sig = 'NotSigned'; Expected = $true }
        @{ Loc = $null; Sig = 'HashMismatch'; Expected = $true }
        @{ Loc = $null; Sig = 'Valid'; Expected = $false }
        @{ Loc = $null; Sig = 'NotChecked'; Expected = $false }
    ) {
        Test-WcProcessWorthReview -LocationKind $Loc -SignatureStatus $Sig | Should -Be $Expected
    }
    It 'picks signature candidates: user-writable first, skips the Windows folder and duplicates, respects the budget' {
        $inv = @(
            [pscustomobject]@{ Name = 'big'; Path = 'C:\Program Files\Big\big.exe'; WorkingSet = 3GB }
            [pscustomobject]@{ Name = 'big'; Path = 'C:\Program Files\Big\big.exe'; WorkingSet = 2GB }
            [pscustomobject]@{ Name = 'svc'; Path = 'C:\Windows\System32\svchost.exe'; WorkingSet = 2.5GB }
            [pscustomobject]@{ Name = 'tmp'; Path = 'C:\Users\ana\AppData\Local\Temp\t.exe'; WorkingSet = 1MB }
            [pscustomobject]@{ Name = 'mid'; Path = 'C:\Program Files\Mid\mid.exe'; WorkingSet = 1GB }
        )
        $c = @(Select-WcSignatureCandidate -Inventory $inv -Max 2 -SystemRoot 'C:\Windows')
        $c | Should -Be @('C:\Users\ana\AppData\Local\Temp\t.exe', 'C:\Program Files\Big\big.exe')
    }
    It 'extracts the signer CN' {
        ConvertTo-WcSignerName -Subject 'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, C=US' | Should -Be 'Microsoft Corporation'
        ConvertTo-WcSignerName -Subject 'CN="Contoso, Ltd", O=Contoso' | Should -Be 'Contoso, Ltd'
        ConvertTo-WcSignerName -Subject 'O=Only Org' | Should -Be 'Only Org'
        ConvertTo-WcSignerName -Subject '' | Should -Be ''
    }
    It 'lists one row per executable that is user-writable or not validly signed' {
        $inv = @(
            [pscustomobject]@{ Id = 1; Name = 'tmp'; Path = 'C:\Users\ana\AppData\Local\Temp\t.exe'; Kind = 'Background' }
            [pscustomobject]@{ Id = 2; Name = 'tmp'; Path = 'C:\Users\ana\AppData\Local\Temp\t.exe'; Kind = 'Background' }
            [pscustomobject]@{ Id = 3; Name = 'ok'; Path = 'C:\Program Files\Ok\ok.exe'; Kind = 'App' }
            [pscustomobject]@{ Id = 4; Name = 'bad'; Path = 'C:\Program Files\Bad\bad.exe'; Kind = 'App' }
            [pscustomobject]@{ Id = 5; Name = 'nopath'; Path = ''; Kind = 'System' }
        )
        $sig = @{
            'c:\program files\ok\ok.exe'   = [pscustomobject]@{ Status = 'Valid'; Signer = 'Ok Inc' }
            'c:\program files\bad\bad.exe' = [pscustomobject]@{ Status = 'NotSigned'; Signer = '' }
        }
        $rows = @(ConvertTo-WcReviewRows -Inventory $inv -Signature $sig)
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'tmp'
        $rows[0].ProcInstances | Should -Be 2
        $rows[0].ProcSignatureRaw | Should -Be 'NotChecked'
        $rows[1].ProcSignatureRaw | Should -Be 'NotSigned'
    }
}

Describe 'process.end decision (pure deny-list)' {
    It 'allows an ordinary process of the current user' {
        $d = Test-WcProcessEndAllowed -Target (New-Target) -Environment (New-Env) -ExpectedName 'notepad.exe'
        $d.Allowed | Should -BeTrue
        @($d.Reasons).Count | Should -Be 0
    }
    It 'refuses the critical process <Name>' -ForEach @(
        @{ Name = 'System' }, @{ Name = 'Idle' }, @{ Name = 'smss' }, @{ Name = 'csrss' }, @{ Name = 'wininit' }, @{ Name = 'winlogon' },
        @{ Name = 'services' }, @{ Name = 'LSASS' }, @{ Name = 'svchost' }, @{ Name = 'dwm' }, @{ Name = 'fontdrvhost' }, @{ Name = 'Registry' }
    ) {
        $d = Test-WcProcessEndAllowed -Target (New-Target -Name $Name) -Environment (New-Env -Admin $true)
        $d.Allowed | Should -BeFalse
        $d.Reasons | Should -Contain 'critical-name'
    }
    It 'refuses security/EDR/VPN/Intune agent <Name> even as admin' -ForEach @(
        @{ Name = 'MsMpEng' }, @{ Name = 'MsSense' }, @{ Name = 'CSFalconService' }, @{ Name = 'SentinelAgent' }, @{ Name = 'vpnagent' },
        @{ Name = 'PanGPA' }, @{ Name = 'IntuneManagementExtension' }, @{ Name = 'ZSATunnel' }, @{ Name = 'openvpn' }
    ) {
        $d = Test-WcProcessEndAllowed -Target (New-Target -Name $Name -Company '' -Path 'C:\Program Files\X\x.exe') -Environment (New-Env -Admin $true)
        $d.Allowed | Should -BeFalse
        $d.Reasons | Should -Contain 'security-tool'
    }
    It 'refuses renamed security agents by company and Defender by path' {
        (Test-WcProcessEndAllowed -Target (New-Target -Name 'agent123' -Company 'CrowdStrike, Inc.' -Path 'C:\x\agent123.exe') -Environment (New-Env -Admin $true)).Reasons | Should -Contain 'security-tool'
        (Test-WcProcessEndAllowed -Target (New-Target -Name 'whatever' -Company '' -Path 'C:\ProgramData\Microsoft\Windows Defender\Platform\4.18\x.exe') -Environment (New-Env -Admin $true)).Reasons | Should -Contain 'security-tool'
    }
    It 'refuses PID 0/4, service hosts, system accounts, session 0, itself and a reused PID' {
        (Test-WcProcessEndAllowed -Target (New-Target -Id 4 -Name 'x') -Environment (New-Env -Admin $true)).Reasons | Should -Contain 'critical-pid'
        (Test-WcProcessEndAllowed -Target (New-Target -Name 'myhost' -Services @('MySvc')) -Environment (New-Env -Admin $true)).Reasons | Should -Contain 'hosts-services'
        (Test-WcProcessEndAllowed -Target (New-Target -Owner 'NT AUTHORITY\SYSTEM') -Environment (New-Env -Admin $true)).Reasons | Should -Contain 'system-account'
        (Test-WcProcessEndAllowed -Target (New-Target -Session 0) -Environment (New-Env -Admin $true)).Reasons | Should -Contain 'session0'
        (Test-WcProcessEndAllowed -Target (New-Target -Id 999) -Environment (New-Env -Self 999)).Reasons | Should -Contain 'self'
        (Test-WcProcessEndAllowed -Target (New-Target) -Environment (New-Env) -ExpectedName 'calc').Reasons | Should -Contain 'pid-mismatch'
        (Test-WcProcessEndAllowed -Target $null -Environment (New-Env)).Reasons | Should -Be @('not-running')
    }
    It 'allows a session-0 child when WinCare itself runs in session 0 (CI runner)' {
        (Test-WcProcessEndAllowed -Target (New-Target -Session 0) -Environment (New-Env -Session 0)).Allowed | Should -BeTrue
    }
    It 'refuses another user or an unknown owner unless admin' {
        (Test-WcProcessEndAllowed -Target (New-Target -Owner 'PC\bob') -Environment (New-Env)).Reasons | Should -Contain 'other-user'
        (Test-WcProcessEndAllowed -Target (New-Target -Owner '') -Environment (New-Env)).Reasons | Should -Contain 'owner-unknown'
        (Test-WcProcessEndAllowed -Target (New-Target -Owner 'PC\bob') -Environment (New-Env -Admin $true)).Allowed | Should -BeTrue
        (Test-WcProcessEndAllowed -Target (New-Target -Owner 'pc\ANA') -Environment (New-Env)).Allowed | Should -BeTrue
    }
    It 'every refusal code has text in both languages' {
        $pt = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'Localization/pt-BR.d/f6-processes.json') | ConvertFrom-Json
        $en = Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot 'Localization/en-US.d/f6-processes.json') | ConvertFrom-Json
        foreach ($c in 'not-running', 'pid-mismatch', 'self', 'critical-pid', 'critical-name', 'security-tool', 'hosts-services', 'system-account', 'session0', 'other-user', 'owner-unknown') {
            $pt.PSObject.Properties.Name | Should -Contain "processes.refuse.$c"
            $en.PSObject.Properties.Name | Should -Contain "processes.refuse.$c"
        }
    }
}

Describe 'process.end request parameters' {
    It 'stores and reads the UI selection in Context.Parameters' {
        $ctx = New-WcContext -IsAdmin $false
        Set-WcProcessEndRequest -Context $ctx -ProcessId 4321 -ProcessName 'notepad' | Out-Null
        $r = Get-WcProcessEndRequest -Context $ctx
        $r.ProcessId | Should -Be 4321
        $r.ProcessName | Should -Be 'notepad'
        $r.Force | Should -BeFalse
        Set-WcProcessEndRequest -Context $ctx -ProcessId 4321 -ProcessName 'notepad' -Force | Out-Null
        (Get-WcProcessEndRequest -Context $ctx).Force | Should -BeTrue
    }
    It 'throws without a selection or with an invalid PID; Force must be a real boolean' {
        { Get-WcProcessEndRequest -Context (New-WcContext) } | Should -Throw '*no process selected*'
        { Get-WcProcessEndRequest -Context @{ Parameters = @{ 'process.end' = @{ ProcessId = 'abc' } } } } | Should -Throw '*invalid ProcessId*'
        (Get-WcProcessEndRequest -Context @{ Parameters = @{ 'process.end' = @{ ProcessId = 5; Force = 'yes' } } }).Force | Should -BeFalse
    }
}

Describe 'process.end handler (mocked I/O)' {
    BeforeEach {
        Mock -ModuleName WinCare.Processes Get-WcProcessEndTarget { New-Target }
        Mock -ModuleName WinCare.Processes Get-WcProcessEndEnvironment { New-Env }
        Mock -ModuleName WinCare.Processes Invoke-WcProcessClose { [pscustomobject]@{ SentClose = $true; Exited = $true } }
        Mock -ModuleName WinCare.Processes Invoke-WcProcessStop { $true }
        Mock -ModuleName WinCare.Processes Stop-Process { throw 'Stop-Process must never be reached directly in tests' }
        $script:Ctx = Set-WcProcessEndRequest -Context (New-WcContext -Build 26100) -ProcessId 1234 -ProcessName 'notepad'
    }
    It 'Preview shows what would be ended and its memory, and touches nothing' {
        $r = Invoke-WcProcessEnd -Context $script:Ctx
        $r.Summary | Should -Match '^Would ask notepad \(PID 1234\)'
        $r.Summary | Should -Match 'only if the confirmation explicitly says Force'
        $r.Items[0].ProcWorkingSet | Should -Match 'MB'
        $r.BytesBefore | Should -Be 40MB
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessClose -Times 0 -Exactly
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessStop -Times 0 -Exactly
    }
    It 'Preview of a refused process explains why' {
        Mock -ModuleName WinCare.Processes Get-WcProcessEndTarget { New-Target -Name 'lsass' }
        Set-WcProcessEndRequest -Context $script:Ctx -ProcessId 1234 -ProcessName 'lsass' | Out-Null
        $r = Invoke-WcProcessEnd -Context $script:Ctx
        $r.Summary | Should -Match '^Would refuse.*critical-name'
        $r.Refused | Should -Contain 'critical-name'
    }
    It 'Execute closes gracefully and never forces when the window closes' {
        $r = Invoke-WcProcessEnd -Context $script:Ctx -Execute
        $r.Summary | Should -Match 'closed gracefully'
        $r.Items[0].Status | Should -Be 'Closed'
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessStop -Times 0 -Exactly
    }
    It 'Execute without Force fails clearly when the process does not close' {
        Mock -ModuleName WinCare.Processes Invoke-WcProcessClose { [pscustomobject]@{ SentClose = $false; Exited = $false } }
        { Invoke-WcProcessEnd -Context $script:Ctx -Execute } | Should -Throw '*not forced*'
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessStop -Times 0 -Exactly
    }
    It 'Execute with Force tries graceful first, then Stop-Process' {
        Mock -ModuleName WinCare.Processes Invoke-WcProcessClose { [pscustomobject]@{ SentClose = $true; Exited = $false } }
        Set-WcProcessEndRequest -Context $script:Ctx -ProcessId 1234 -ProcessName 'notepad' -Force | Out-Null
        $r = Invoke-WcProcessEnd -Context $script:Ctx -Execute
        $r.Items[0].Status | Should -Be 'Forced'
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessClose -Times 1 -Exactly
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessStop -Times 1 -Exactly -ParameterFilter { $ProcessId -eq 1234 }
    }
    It 'Execute re-checks the deny-list and refuses before touching the process' {
        Mock -ModuleName WinCare.Processes Get-WcProcessEndTarget { New-Target -Owner 'PC\bob' }
        Set-WcProcessEndRequest -Context $script:Ctx -ProcessId 1234 -ProcessName 'notepad' -Force | Out-Null
        { Invoke-WcProcessEnd -Context $script:Ctx -Execute } | Should -Throw '*other-user*'
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessClose -Times 0 -Exactly
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessStop -Times 0 -Exactly
    }
    It 'Execute refuses when the PID now belongs to another program' {
        Mock -ModuleName WinCare.Processes Get-WcProcessEndTarget { New-Target -Name 'calc' }
        { Invoke-WcProcessEnd -Context $script:Ctx -Execute } | Should -Throw '*pid-mismatch*'
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessClose -Times 0 -Exactly
    }
    It 'goes through the plan engine: dry-run previews, execute needs confirmation and is audited' {
        $cat = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        $a = $cat | Where-Object { $_.Id -eq 'process.end' }
        $a.Risk | Should -Be 'Medium'
        $a.Reversibility | Should -Be 'None'
        $a.Pages | Should -Be @('processes')
        $plan = New-WcPlan -Catalog $cat -ActionId @('process.end') -OperationProfile (Get-WcProfile 'Avancado') -Context $script:Ctx
        $plan.Items[0].Allowed | Should -BeTrue
        $plan.Items[0].RequiresConfirmation | Should -BeTrue
        $dry = @(Invoke-WcPlan -Plan $plan -Context $script:Ctx -DryRun)
        $dry[0].Status | Should -Be 'Previewed'
        $declined = @(Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { param($i) $false } -Measure None)
        $declined[0].Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName WinCare.Processes Invoke-WcProcessClose -Times 0 -Exactly
        $done = @(Invoke-WcPlan -Plan $plan -Context $script:Ctx -ConfirmCallback { param($i) $true } -Measure None)
        $done[0].Status | Should -Be 'Succeeded'
        $log = Get-Content -Raw (Get-WcLogPath)
        $log | Should -Match 'Ending notepad \(PID 1234\)'
        $log | Should -Match 'process.end: Succeeded'
    }
    It 'is blocked by the Conservador and Diagnostico profiles (risk Medium)' {
        $cat = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        foreach ($p in 'Conservador', 'Corporativo', 'Diagnostico') {
            (New-WcPlan -Catalog $cat -ActionId @('process.end') -OperationProfile (Get-WcProfile $p) -Context $script:Ctx).Items[0].Allowed | Should -BeFalse
        }
    }
}

Describe 'memory.schedule-diagnostic' {
    It 'resolves MdSched.exe under System32 (Sysnative from a 32-bit host)' {
        Get-WcMdSchedPath -SystemRoot 'C:\Windows' -Is64BitOs $true -Is64BitProcess $true | Should -Be 'C:\Windows\System32\MdSched.exe'
        Get-WcMdSchedPath -SystemRoot 'C:\Windows\' -Is64BitOs $true -Is64BitProcess $false | Should -Be 'C:\Windows\Sysnative\MdSched.exe'
        { Get-WcMdSchedPath -SystemRoot '' } | Should -Throw
    }
    It 'Preview opens nothing and says WinCare never restarts' {
        Mock -ModuleName WinCare.Processes Get-WcMdSchedPath { 'C:\Windows\System32\MdSched.exe' }
        Mock -ModuleName WinCare.Processes Start-WcMdSched { throw 'must not run' }
        $r = Invoke-WcMemoryDiagnostic
        $r.Summary | Should -Match 'never restarts'
        Should -Invoke -ModuleName WinCare.Processes Start-WcMdSched -Times 0 -Exactly
    }
    It 'Execute only opens the interactive dialog, without arguments' {
        Mock -ModuleName WinCare.Processes Get-WcMdSchedPath { 'C:\Windows\System32\MdSched.exe' }
        Mock -ModuleName WinCare.Processes Test-Path { $true }
        Mock -ModuleName WinCare.Processes Start-WcMdSched { }
        $r = Invoke-WcMemoryDiagnostic -Execute
        $r.Summary | Should -Match '^Opened'
        Should -Invoke -ModuleName WinCare.Processes Start-WcMdSched -Times 1 -Exactly -ParameterFilter { $Path -eq 'C:\Windows\System32\MdSched.exe' }
    }
    It 'source never calls bcdedit, Restart-Computer or memory purge APIs' {
        $src = Get-Content -Raw (Join-Path $script:SrcRoot 'Modules/WinCare.Processes.psm1')
        $tokens = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$tokens, [ref]$null)
        $code = (@($tokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' ')
        $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
        foreach ($bad in 'Restart-Computer', 'Stop-Computer', 'bcdedit', 'bcdedit.exe', 'shutdown', 'shutdown.exe') { $cmds | Should -Not -Contain $bad }
        $code | Should -Not -Match '(?i)EmptyWorkingSet|SetSystemFileCacheSize|NtSetSystemInformation|MemoryPurgeStandbyList'
        $code | Should -Not -Match '(?i)\.CommandLine\b'
    }
}

Describe 'Page data (mocked I/O)' {
    BeforeAll {
        $script:Snap = @(
            (New-Snap 0 'Idle' -Ws 8KB -Priv 0 -Cpu 100 -Session 0)
            (New-Snap 4 'System' -Ws 2MB -Priv 1MB -Cpu 50 -Session 0)
            (New-Snap 1200 'svchost' -Ws 300MB -Priv 250MB -Cpu 2 -Session 0)
            (New-Snap 1400 'Memory Compression' -Ws 700MB -Priv 1MB -Cpu 1 -Session 0)
            (New-Snap 5000 'WINWORD' -Ws 900MB -Priv 600MB -Cpu 10 -Session 1 -Window $true -Path 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE')
            (New-Snap 6000 'tool' -Ws 50MB -Priv 40MB -Cpu 1 -Session 1 -Path 'C:\Users\ana\Downloads\tool.exe')
        )
    }
    BeforeEach {
        $script:Call = 0
        Mock -ModuleName WinCare.Processes Get-WcProcessSnapshot {
            $script:Call++
            $grow = ($script:Call - 1) * 30MB
            @($script:Snap | ForEach-Object {
                    $o = $_.PSObject.Copy()
                    if ($o.Name -eq 'WINWORD') { $o.PrivateBytes = [long]$o.PrivateBytes + $grow; $o.CpuSeconds = [double]$o.CpuSeconds + $script:Call }
                    $o
                })
        }
        Mock -ModuleName WinCare.Processes Get-WcMemoryPerfRaw { [pscustomobject]@{ PagesInputPersec = 100 * $script:Call; Timestamp_Sys100NS = 10000000 * $script:Call } }
        Mock -ModuleName WinCare.Processes Get-WcCimData {
            switch ($ClassName) {
                'Win32_Service' { @([pscustomobject]@{ Name = 'Dnscache'; ProcessId = 1200 }) }
                'Win32_Process' { @([pscustomobject]@{ ProcessId = 1200; ExecutablePath = 'C:\Windows\System32\svchost.exe'; SessionId = 0; CommandLine = 'svchost -k password=hunter2' }) }
                'Win32_OperatingSystem' { [pscustomobject]@{ TotalVisibleMemorySize = 16777216; FreePhysicalMemory = 8388608; TotalVirtualMemorySize = 20971520; FreeVirtualMemory = 10485760 } }
                'Win32_PerfFormattedData_PerfOS_Memory' { [pscustomobject]@{ AvailableBytes = 8GB; CommittedBytes = 10GB; CommitLimit = 20GB } }
                'Win32_PageFileUsage' { @([pscustomobject]@{ Name = 'C:\pagefile.sys'; AllocatedBaseSize = 4096; CurrentUsage = 100; PeakUsage = 200 }) }
                default { $null }
            }
        }
        Mock -ModuleName WinCare.Processes Get-WcFileSignature { [pscustomobject]@{ Status = 'NotSigned'; Signer = '' } }
        Mock -ModuleName WinCare.Processes Get-WcFileVersionText { [pscustomobject]@{ Description = 'Desc'; Company = 'Co' } }
        Mock -ModuleName WinCare.Processes Get-WcUserWritableRoots { @{ Temp = 'C:\Users\ana\AppData\Local\Temp'; AppData = 'C:\Users\ana\AppData\Roaming'; Downloads = 'C:\Users\ana\Downloads' } }
    }
    It 'returns every section in contract shape without errors' {
        $d = Get-WcProcessesPageData -SampleIntervalSeconds 0
        $d.PageId | Should -Be 'processes'
        @($d.Errors).Count | Should -Be 0 -Because ($d.Errors -join '; ')
        @($d.Sections | ForEach-Object { $_.Id }) | Should -Be @('memory-overview', 'top-memory', 'growth', 'review', 'cpu-now', 'no-ram-cleaner')
        foreach ($s in $d.Sections) {
            $s.TitleKey | Should -Be ('section.processes.' + $s.Id)
            $s.NoteKey | Should -Not -BeNullOrEmpty
            @('Info', 'Warning', 'Critical') | Should -Contain $s.Severity
        }
        ($d.Sections | Where-Object { $_.Id -eq 'no-ram-cleaner' }).NoteKey | Should -Be 'processes.note.no-ram-cleaner'
    }
    It 'fills each section from the mocked data' {
        $d = Get-WcProcessesPageData -SampleIntervalSeconds 0
        $sec = @{}
        foreach ($s in $d.Sections) { $sec[$s.Id] = $s }
        $top = @($sec['top-memory'].Rows)
        $top[0].Name | Should -Be 'WINWORD'
        $top[0].Description | Should -Be 'Desc'
        ($top | Where-Object { $_.Name -eq 'svchost' }).ProcServices | Should -Be 'Dnscache'
        ($top | Where-Object { $_.Name -eq 'Idle' }) | Should -BeNullOrEmpty
        $g = @($sec['growth'].Rows)
        $g[0].Name | Should -Be 'WINWORD'
        $g[0].ProcStatusRaw | Should -Be 'Growing'
        $sec['growth'].Severity | Should -Be 'Warning'
        @($sec['review'].Rows | ForEach-Object { $_.Name }) | Should -Contain 'tool'
        ($sec['review'].Rows | Where-Object { $_.Name -eq 'tool' }).ProcLocation | Should -Be 'Downloads'
        @($sec['cpu-now'].Rows)[0].Name | Should -Be 'WINWORD'
        ($sec['memory-overview'].Rows | Where-Object { $_.Metric -like 'Compressed*' }).Value | Should -Match 'MB'
        ($sec['memory-overview'].Rows | Where-Object { $_.Metric -like 'Hard faults*' }).Value | Should -Match '^100 pages/s'
        @($d.Findings | ForEach-Object { $_.Id }) | Should -Contain 'processes-growth-suspect'
        ($d | ConvertTo-Json -Depth 6) | Should -Not -Match 'hunter2|CommandLine'
    }
    It 'checks signatures only within the budget and never under the Windows folder' {
        $old = $env:SystemRoot
        try {
            $env:SystemRoot = 'C:\Windows'
            Get-WcProcessesPageData -SampleIntervalSeconds 0 -SignatureCheckCount 1 | Out-Null
            Should -Invoke -ModuleName WinCare.Processes Get-WcFileSignature -Times 1 -Exactly
            Should -Invoke -ModuleName WinCare.Processes Get-WcFileSignature -Times 0 -Exactly -ParameterFilter { $Path -like 'C:\Windows\*' }
        }
        finally { $env:SystemRoot = $old }
    }
    It 'never throws: a failing collector becomes an error line' {
        Mock -ModuleName WinCare.Processes Get-WcFileSignature { throw 'boom' }
        Mock -ModuleName WinCare.Processes Get-WcCimData { throw 'cim down' } -ParameterFilter { $ClassName -eq 'Win32_OperatingSystem' }
        $d = Get-WcProcessesPageData -SampleIntervalSeconds 0
        @($d.Errors | Where-Object { $_ -like 'review:*' }).Count | Should -Be 1
        @($d.Errors | Where-Object { $_ -like 'memory-overview:*' }).Count | Should -Be 1
        @($d.Sections | ForEach-Object { $_.Id }) | Should -Contain 'top-memory'
    }
    It 'every column used by the rows has col.<Prop> in both languages' {
        $d = Get-WcProcessesPageData -SampleIntervalSeconds 0
        $props = @()
        foreach ($s in $d.Sections) { foreach ($r in @($s.Rows)) { $props += $r.PSObject.Properties.Name } }
        # process.end preview/result rows
        Mock -ModuleName WinCare.Processes Get-WcProcessEndTarget { New-Target }
        Mock -ModuleName WinCare.Processes Get-WcProcessEndEnvironment { New-Env }
        $ctx = Set-WcProcessEndRequest -Context (New-WcContext) -ProcessId 1234 -ProcessName 'notepad'
        $props += (Invoke-WcProcessEnd -Context $ctx).Items[0].PSObject.Properties.Name
        Mock -ModuleName WinCare.Processes Get-WcMdSchedPath { 'C:\Windows\System32\MdSched.exe' }
        $props += (Invoke-WcMemoryDiagnostic).Items[0].PSObject.Properties.Name
        $props = @($props | Sort-Object -Unique)
        $props.Count | Should -BeGreaterThan 10
        foreach ($lang in 'pt-BR', 'en-US') {
            $keys = @((Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot "Localization/$lang.json") | ConvertFrom-Json).PSObject.Properties.Name)
            foreach ($f in Get-ChildItem (Join-Path $script:SrcRoot "Localization/$lang.d") -Filter '*.json') {
                $keys += @((Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json).PSObject.Properties.Name)
            }
            foreach ($p in $props) { $keys | Should -Contain "col.$p" -Because "$lang col.$p" }
            foreach ($s in $d.Sections) {
                $keys | Should -Contain $s.TitleKey
                $keys | Should -Contain $s.NoteKey
            }
            foreach ($fi in @('processes-memory-pressure', 'processes-growth-suspect')) {
                $keys | Should -Contain "finding.$fi.title"
                $keys | Should -Contain "finding.$fi.recommendation"
            }
        }
    }
    It 'uses localized text when the string table is loaded' {
        Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR' | Out-Null
        try {
            $d = Get-WcProcessesPageData -SampleIntervalSeconds 0
            $mo = @(($d.Sections | Where-Object { $_.Id -eq 'memory-overview' }).Rows)
            $mo[0].Metric | Should -Not -Match '^\['
            $mo[0].Metric | Should -Not -Be 'Installed memory (usable)'
        }
        finally { Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'en-US' | Out-Null }
    }
}

Describe 'Handlers registration' {
    It 'registers a handler for every f6 catalog action' {
        Clear-WcActionHandlers
        Register-WcProcessesHandler
        $names = Get-WcActionHandlerNames
        $frag = Get-Content -Raw (Join-Path $script:SrcRoot 'Core/actions.d/f6-processes.json') | ConvertFrom-Json
        foreach ($a in @($frag.actions | ForEach-Object { $_ })) {
            $names | Should -Contain $a.Handler
            $a.Pages | Should -Be @('processes')
        }
    }
}
