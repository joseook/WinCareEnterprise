#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Pure converters are tested with fixtures; I/O wrappers are tested with mocks.
# Nothing here touches the real system.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules
    Initialize-WcLog -Path (Join-Path (New-WcTestDir) 'test.jsonl') | Out-Null
}

Describe 'Windows detection' {
    It 'identifies <Expected> from build <Build> / <Edition>' -ForEach @(
        @{ Build = '19045'; Edition = 'Professional'; Expected = 'Windows 10'; Label = 'Pro'; Ltsc = $false; IoT = $false; InMatrix = $true }
        @{ Build = '19044'; Edition = 'EnterpriseS'; Expected = 'Windows 10'; Label = 'Enterprise LTSC'; Ltsc = $true; IoT = $false; InMatrix = $true }
        @{ Build = '19044'; Edition = 'IoTEnterpriseS'; Expected = 'Windows 10'; Label = 'IoT Enterprise LTSC'; Ltsc = $true; IoT = $true; InMatrix = $true }
        @{ Build = '22631'; Edition = 'Enterprise'; Expected = 'Windows 11'; Label = 'Enterprise'; Ltsc = $false; IoT = $false; InMatrix = $true }
        @{ Build = '26100'; Edition = 'IoTEnterprise'; Expected = 'Windows 11'; Label = 'IoT Enterprise'; Ltsc = $false; IoT = $true; InMatrix = $true }
        @{ Build = '26100'; Edition = 'Core'; Expected = 'Windows 11'; Label = 'Home'; Ltsc = $false; IoT = $false; InMatrix = $false }
    ) {
        $os = [pscustomobject]@{ BuildNumber = $Build; ProductType = 1; Caption = 'x'; Version = "10.0.$Build"; OSArchitecture = '64-bit' }
        $w = ConvertTo-WcWindowsInfo -OperatingSystem $os -CurrentVersion @{ EditionID = $Edition; DisplayVersion = '23H2'; UBR = 1 }
        $w.Family | Should -Be $Expected
        $w.Edition | Should -Be $Label
        $w.IsLtsc | Should -Be $Ltsc
        $w.IsIoT | Should -Be $IoT
        $w.InSupportMatrix | Should -Be $InMatrix
    }
    It 'flags Windows Server and keeps it out of the matrix' {
        $os = [pscustomobject]@{ BuildNumber = '20348'; ProductType = 3 }
        $w = ConvertTo-WcWindowsInfo -OperatingSystem $os -CurrentVersion @{ EditionID = 'ServerStandard' }
        $w.IsServer | Should -BeTrue
        $w.InSupportMatrix | Should -BeFalse
    }
    It 'survives missing data' {
        $w = ConvertTo-WcWindowsInfo -OperatingSystem $null
        $w.Family | Should -Be 'Unknown'
        $w.Build | Should -Be 0
    }
}

Describe 'CPU usage (PERF_100NSEC_TIMER_INV)' {
    It 'computes busy percent from idle delta' {
        $a = @{ PercentProcessorTime = 1000; Timestamp_Sys100NS = 10000 }
        $b = @{ PercentProcessorTime = 1250; Timestamp_Sys100NS = 11000 }
        ConvertTo-WcCpuUsage -First $a -Second $b | Should -Be 75
    }
    It 'returns null for invalid samples instead of guessing' {
        ConvertTo-WcCpuUsage -First $null -Second @{} | Should -BeNullOrEmpty
        ConvertTo-WcCpuUsage -First @{ PercentProcessorTime = 1; Timestamp_Sys100NS = 5 } -Second @{ PercentProcessorTime = 2; Timestamp_Sys100NS = 5 } | Should -BeNullOrEmpty
    }
    It 'clamps to 0..100' {
        ConvertTo-WcCpuUsage -First @{ PercentProcessorTime = 0; Timestamp_Sys100NS = 0 } -Second @{ PercentProcessorTime = 2000; Timestamp_Sys100NS = 1000 } | Should -Be 0
    }
    It 'sums cores across sockets' {
        $c = ConvertTo-WcCpuInfo -Processor @(@{ Name = ' Xeon '; NumberOfCores = 8; NumberOfLogicalProcessors = 16 }, @{ Name = 'Xeon'; NumberOfCores = 8; NumberOfLogicalProcessors = 16 }) -UsagePercent 10
        $c.Cores | Should -Be 16
        $c.Sockets | Should -Be 2
        $c.Name | Should -Be 'Xeon'
    }
}

Describe 'Memory, uptime and pending reboot' {
    It 'computes used percent from FreePhysicalMemory (KB) and TotalPhysicalMemory (bytes)' {
        $m = ConvertTo-WcMemoryInfo -OperatingSystem @{ FreePhysicalMemory = 4194304 } -ComputerSystem @{ TotalPhysicalMemory = 17179869184 }
        $m.AvailableBytes | Should -Be 4294967296
        $m.UsedPercent | Should -Be 75
    }
    It 'computes uptime and rejects a boot time in the future' {
        $now = Get-Date '2026-11-16T12:00:00'
        (ConvertTo-WcUptime -LastBootUpTime $now.AddDays(-3).AddHours(-2) -Now $now).Days | Should -Be 3
        ConvertTo-WcUptime -LastBootUpTime $now.AddHours(1) -Now $now | Should -BeNullOrEmpty
    }
    It 'treats PendingFileRename alone as informational' {
        $r = ConvertTo-WcPendingReboot -Signals @{ PendingFileRename = $true }
        $r.IsPending | Should -BeFalse
        $r.PendingFileRename | Should -BeTrue
        (ConvertTo-WcPendingReboot -Signals @{ CbsRebootPending = $true }).Sources | Should -Be @('CbsRebootPending')
    }
}

Describe 'CIM wrapper' {
    It 'returns null and logs instead of throwing' {
        Mock -ModuleName WinCare.System Get-CimInstance { throw 'Access denied' }
        Get-WcCimData -ClassName 'Win32_Nothing' | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinCare.System Get-CimInstance -Times 1
    }
    It 'Get-WcSystemInfo assembles data from mocked CIM and registry' {
        Mock -ModuleName WinCare.System Start-Sleep {}
        Mock -ModuleName WinCare.System Test-Path { $false }
        Mock -ModuleName WinCare.System Get-WcRegistryValues { @{ EditionID = 'Enterprise'; DisplayVersion = '23H2'; UBR = 4460 } }
        Mock -ModuleName WinCare.System Get-WcCimData {
            switch ($ClassName) {
                'Win32_OperatingSystem' { @([pscustomobject]@{ BuildNumber = '22631'; ProductType = 1; FreePhysicalMemory = 8388608; LastBootUpTime = (Get-Date).AddHours(-5); OSArchitecture = '64-bit' }) }
                'Win32_ComputerSystem' { @([pscustomobject]@{ TotalPhysicalMemory = 17179869184 }) }
                'Win32_Processor' { @([pscustomobject]@{ Name = 'CPU'; NumberOfCores = 4; NumberOfLogicalProcessors = 8 }) }
                'Win32_PerfRawData_PerfOS_Processor' { $script:n++; @([pscustomobject]@{ PercentProcessorTime = 1000 * $script:n; Timestamp_Sys100NS = 2000 * $script:n }) }
            }
        }
        $script:n = 0
        $s = Get-WcSystemInfo
        $s.Windows.Family | Should -Be 'Windows 11'
        $s.Memory.UsedPercent | Should -Be 50
        $s.Cpu.UsagePercent | Should -Be 50
        $s.Uptime.Hours | Should -Be 5
        $s.PendingReboot.IsPending | Should -BeFalse
    }
}

Describe 'Storage' {
    BeforeAll {
        $script:Ld = @(
            [pscustomobject]@{ DeviceID = 'C:'; VolumeName = 'OS'; FileSystem = 'NTFS'; Size = 256GB; FreeSpace = 20GB }
            [pscustomobject]@{ DeviceID = 'D:'; VolumeName = 'Data'; FileSystem = 'NTFS'; Size = 1TB; FreeSpace = 50GB }
            [pscustomobject]@{ DeviceID = 'E:'; VolumeName = ''; FileSystem = 'NTFS'; Size = 0; FreeSpace = 0 }
        )
        $script:Parts = @([pscustomobject]@{ DriveLetter = 'C'; DiskNumber = 0 }, [pscustomobject]@{ DriveLetter = 'D'; DiskNumber = 1 }, [pscustomobject]@{ DriveLetter = [char]0; DiskNumber = 0 })
        $script:Phys = @([pscustomobject]@{ DeviceId = '0'; MediaType = 4; BusType = 17; FriendlyName = 'NVMe SSD' }, [pscustomobject]@{ DeviceId = '1'; MediaType = 3; BusType = 11; FriendlyName = 'HDD' })
    }
    It 'maps media and bus types via partition -> physical disk' {
        $v = ConvertTo-WcVolumeInfo -LogicalDisk $script:Ld -Partition $script:Parts -PhysicalDisk $script:Phys -SystemDrive 'c:'
        $c = $v | Where-Object Drive -eq 'C:'
        $c.MediaType | Should -Be 'SSD'
        $c.BusType | Should -Be 'NVMe'
        $c.IsSystem | Should -BeTrue
        $c.FreePercent | Should -Be 7.8
        ($v | Where-Object Drive -eq 'D:').MediaType | Should -Be 'HDD'
    }
    It 'keeps Unknown when the disk cannot be matched, and handles zero size' {
        $v = ConvertTo-WcVolumeInfo -LogicalDisk $script:Ld -Partition @() -PhysicalDisk @()
        @($v | Where-Object MediaType -ne 'Unknown').Count | Should -Be 0
        ($v | Where-Object Drive -eq 'E:').FreePercent | Should -BeNullOrEmpty
    }
}

Describe 'Processes and startup' {
    It 'ranks by working set and keeps accumulated CPU seconds' {
        $p = @(
            @{ ProcessName = 'a'; Id = 1; WorkingSet64 = 100MB; TotalProcessorTime = [timespan]::FromSeconds(12.34) }
            @{ ProcessName = 'b'; Id = 2; WorkingSet64 = 900MB; TotalProcessorTime = $null }
            @{ ProcessName = 'c'; Id = 3; WorkingSet64 = 500MB }
        )
        $r = ConvertTo-WcProcessInfo -Process $p -Top 2
        $r.Name | Should -Be @('b', 'c')
        (ConvertTo-WcProcessInfo -Process $p -Top 3)[2].CpuSecondsTotal | Should -Be 12.3
    }
    It 'shapes startup commands' {
        $r = ConvertTo-WcStartupItem -StartupCommand @([pscustomobject]@{ Name = 'Zed'; Command = 'z.exe'; Location = 'HKU\Run'; User = 'u' }, [pscustomobject]@{ Name = 'Alpha'; Command = 'a.exe'; Location = 'Startup'; User = 'u' })
        $r[0].Name | Should -Be 'Alpha'
    }
}

Describe 'Security signals' {
    It 'is managed when any signal is present' {
        (ConvertTo-WcManagementState -Signals @{ MdmEnrolled = $true; MdmProvider = 'MS DM Server' }).IsManaged | Should -BeTrue
        (ConvertTo-WcManagementState -Signals @{}).IsManaged | Should -BeFalse
    }
    It 'reports protection state as unknown (null) when it cannot be read' {
        $p = ConvertTo-WcProtectionState -DefenderStatus $null -FirewallProfile $null
        $p.DefenderService | Should -BeNullOrEmpty
        $p.FirewallAllProfiles | Should -BeNullOrEmpty
    }
    It 'detects a disabled firewall profile' {
        $p = ConvertTo-WcProtectionState -DefenderStatus @{ AMServiceEnabled = $true; RealTimeProtectionEnabled = $true } -FirewallProfile @(@{ Enabled = 'True' }, @{ Enabled = 'False' })
        $p.FirewallAllProfiles | Should -BeFalse
        $p.DefenderRealTime | Should -BeTrue
    }
}
