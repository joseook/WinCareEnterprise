#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules
    Initialize-WcLog -Path (Join-Path (New-WcTestDir) 'test.jsonl') | Out-Null
    $script:Catalog = Join-Path $script:SrcRoot 'Core/actions.json'

    function New-Snap {
        param($Storage = @(), $System = $null, $Security = $null)
        return [ordered]@{ Storage = $Storage; System = $System; Security = $Security }
    }
    function New-Vol { param($Free, $Size = 100GB, [bool] $IsSystem = $true, $Media = 'SSD', $Drive = 'C:')
        [pscustomobject]@{ Drive = $Drive; FreeBytes = $Free; SizeBytes = $Size; FreePercent = [math]::Round($Free / $Size * 100, 1); IsSystem = $IsSystem; MediaType = $Media }
    }
}

Describe 'Findings rules' {
    It 'raises Critical below 5% / 5 GB on the system disk' {
        (Get-WcFinding -Snapshot (New-Snap -Storage @(New-Vol -Free 3GB))).Id | Should -Contain 'disk-system-critical'
    }
    It 'raises Warning below 10% on the system disk' {
        $f = Get-WcFinding -Snapshot (New-Snap -Storage @(New-Vol -Free 80GB -Size 1TB))
        $f.Id | Should -Contain 'disk-system-low'
        $f.Id | Should -Not -Contain 'disk-system-critical'
    }
    It 'raises nothing for a healthy disk' {
        @(Get-WcFinding -Snapshot (New-Snap -Storage @(New-Vol -Free 60GB))).Count | Should -Be 0
    }
    It 'notes an HDD system disk as Info' {
        ((Get-WcFinding -Snapshot (New-Snap -Storage @(New-Vol -Free 60GB -Media 'HDD'))) | Where-Object Id -eq 'disk-system-hdd').Severity | Should -Be 'Info'
    }
    It 'raises memory, reboot, uptime and matrix findings from System' {
        $sys = [pscustomobject]@{
            Memory = [pscustomobject]@{ UsedPercent = 95 }; Cpu = [pscustomobject]@{ UsagePercent = 20 }
            PendingReboot = [pscustomobject]@{ IsPending = $true; Sources = @('CbsRebootPending') }
            Uptime = [pscustomobject]@{ TotalHours = 400; Days = 16 }
            Windows = [pscustomobject]@{ InSupportMatrix = $false; Family = 'Windows 11'; Edition = 'Home'; Build = 26100 }
        }
        $ids = (Get-WcFinding -Snapshot (New-Snap -System $sys)).Id
        $ids | Should -Contain 'memory-high'
        $ids | Should -Contain 'reboot-pending'
        $ids | Should -Contain 'uptime-long'
        $ids | Should -Contain 'windows-out-of-matrix'
        $ids | Should -Not -Contain 'cpu-high-sample'
    }
    It 'does not invent findings when data is missing' {
        @(Get-WcFinding -Snapshot (New-Snap)).Count | Should -Be 0
        $sec = [pscustomobject]@{ Protection = [pscustomobject]@{ DefenderService = $null; FirewallAllProfiles = $null } }
        @(Get-WcFinding -Snapshot (New-Snap -Security $sec)).Count | Should -Be 0
    }
    It 'orders Critical before Warning before Info' {
        $sys = [pscustomobject]@{ Memory = [pscustomobject]@{ UsedPercent = 95 }; Cpu = $null; PendingReboot = $null; Uptime = [pscustomobject]@{ TotalHours = 999; Days = 41 }; Windows = $null }
        $f = Get-WcFinding -Snapshot (New-Snap -Storage @(New-Vol -Free 1GB) -System $sys)
        $f.Severity | Should -Be @('Critical', 'Warning', 'Info')
    }
    It 'every finding id has localized title and recommendation' {
        $ids = @('disk-system-critical', 'disk-system-low', 'disk-system-hdd', 'disk-other-low', 'memory-high', 'cpu-high-sample', 'reboot-pending', 'uptime-long', 'windows-out-of-matrix', 'defender-inactive', 'firewall-profile-off')
        $src = Get-Content -Raw (Join-Path $script:SrcRoot 'Modules/WinCare.Diagnostics.psm1')
        $inCode = [regex]::Matches($src, "-Id '([a-z\-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
        $inCode | Should -Be ($ids | Sort-Object)
        foreach ($lang in 'pt-BR', 'en-US') {
            Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language $lang | Out-Null
            foreach ($id in $ids) {
                Get-WcString "finding.$id.title" | Should -Not -Match '^\['
                Get-WcString "finding.$id.recommendation" | Should -Not -Match '^\['
            }
        }
    }
}

Describe 'Invoke-WcDiagnostic (mocked collectors)' {
    BeforeAll {
        Mock -ModuleName WinCare.Diagnostics Test-WcIsWindows { $true }
        Mock -ModuleName WinCare.Diagnostics Test-WcIsAdmin { $false }
        Mock -ModuleName WinCare.Diagnostics Get-WcSystemInfo { [pscustomobject]@{ Memory = [pscustomobject]@{ UsedPercent = 40 }; Cpu = $null; PendingReboot = $null; Uptime = $null; Windows = $null } }
        Mock -ModuleName WinCare.Diagnostics Get-WcVolumeInfo { throw 'MSFT_Partition: access denied' }
        Mock -ModuleName WinCare.Diagnostics Get-WcTopProcess { @([pscustomobject]@{ Name = 'x' }) }
        Mock -ModuleName WinCare.Diagnostics Get-WcStartupItem { @() }
        Mock -ModuleName WinCare.Diagnostics Get-WcManagementState { [pscustomobject]@{ IsManaged = $true; Signals = @('DomainJoined') } }
        Mock -ModuleName WinCare.Diagnostics Get-WcProtectionState { [pscustomobject]@{ DefenderService = $true; FirewallAllProfiles = $true } }
    }
    It 'collects every section and isolates a failing one' {
        $s = Invoke-WcDiagnostic -CatalogPath $script:Catalog -AppVersion '9.9.9'
        $s.Meta.Version | Should -Be '9.9.9'
        $s.System.Memory.UsedPercent | Should -Be 40
        $s.Security.Management.IsManaged | Should -BeTrue
        $s.Storage | Should -BeNullOrEmpty
        $s.Errors.Section | Should -Be @('storage')
        $s.Errors[0].Error | Should -Match 'access denied'
    }
    It 'runs only the requested sections' {
        $s = Invoke-WcDiagnostic -CatalogPath $script:Catalog -Section 'processes'
        $s.Processes[0].Name | Should -Be 'x'
        $s.System | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinCare.Diagnostics Get-WcSystemInfo -Times 0 -Exactly -Scope It
    }
    It 'is read-only in every profile' {
        foreach ($p in (Get-WcProfile -All).Name) {
            $s = Invoke-WcDiagnostic -CatalogPath $script:Catalog -Section 'processes' -OperationProfileName $p
            @($s.Errors).Count | Should -Be 0
        }
    }
}
