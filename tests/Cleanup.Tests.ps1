#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# F3 cleanup / volume optimization. Real deletions happen ONLY inside a temp dir
# created by the test; everything else that is destructive is mocked.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @('System', 'Storage', 'Cleanup', 'Integrity')
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'cleanup.jsonl') | Out-Null

    function New-OldFile([string] $Path, [int] $Bytes = 10, [int] $AgeHours = 72) {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
        $t = (Get-Date).ToUniversalTime().AddHours(-$AgeHours)
        [System.IO.File]::SetCreationTimeUtc($Path, $t)
        [System.IO.File]::SetLastWriteTimeUtc($Path, $t)
    }
    function New-TempTree {
        # <base>/Temp with: 2 old files (one nested), 1 new file, a symlink to an outside dir with an old file.
        $base = New-WcTestDir
        $root = Join-Path $base 'Temp'
        $outside = Join-Path $base 'outside'
        New-OldFile (Join-Path $root 'old1.tmp') 100
        New-OldFile (Join-Path (Join-Path $root 'sub') 'old2.tmp') 50
        New-OldFile (Join-Path $root 'new.tmp') 7 1
        New-OldFile (Join-Path $outside 'keep.txt') 30
        # Junction on Windows (no admin needed), symlink elsewhere: both are reparse points.
        $type = 'SymbolicLink'
        if (Test-WcIsWindows) { $type = 'Junction' }
        New-Item -ItemType $type -Path (Join-Path $root 'link') -Target $outside | Out-Null
        return [pscustomobject]@{ Base = $base; Root = $root; Outside = $outside }
    }
}

Describe 'Temp root safety' {
    It 'accepts <Path> = <Expected>' -ForEach @(
        @{ Path = 'C:\Users\a\AppData\Local\Temp'; Expected = $true }
        @{ Path = 'C:\Users\a\AppData\Local\Temp\2'; Expected = $true }
        @{ Path = 'C:\Windows\Temp'; Expected = $true }
        @{ Path = '/var/tmp'; Expected = $true }
        @{ Path = 'C:\Users\a'; Expected = $false }
        @{ Path = 'C:\Windows'; Expected = $false }
        @{ Path = '/'; Expected = $false }
        @{ Path = ''; Expected = $false }
    ) {
        Test-WcTempRootSafe -Path $Path | Should -Be $Expected
    }
    It 'refuses a misconfigured TEMP that points to a profile folder' {
        $old = $env:TEMP
        try {
            $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetTempPath())
            $env:TEMP = [System.IO.Path]::Combine($root, 'Users', 'someone')
            { Get-WcTempRoot -Scope User } | Should -Throw '*unsafe*'
        }
        finally { $env:TEMP = $old }
    }
}

Describe 'Temp candidate filter (pure)' {
    BeforeAll {
        $script:Root = Join-Path $script:Tmp 'Temp'
        $script:Now = [datetime]'2026-11-16T12:00:00Z'
    }
    It 'keeps only files older than the cutoff, using the newest of write/creation time' {
        $e = @(
            [pscustomobject]@{ Path = (Join-Path $script:Root 'a'); Length = 5; LastWriteTimeUtc = $script:Now.AddDays(-2); CreationTimeUtc = $script:Now.AddDays(-2); IsReparsePoint = $false }
            [pscustomobject]@{ Path = (Join-Path $script:Root 'b'); Length = 5; LastWriteTimeUtc = $script:Now.AddHours(-2); CreationTimeUtc = $script:Now.AddDays(-9); IsReparsePoint = $false }
            [pscustomobject]@{ Path = (Join-Path $script:Root 'c'); Length = 5; LastWriteTimeUtc = $script:Now.AddDays(-9); CreationTimeUtc = $script:Now.AddHours(-1); IsReparsePoint = $false }
        )
        $c = ConvertTo-WcTempCandidate -Entry $e -Root $script:Root -NowUtc $script:Now
        @($c).Count | Should -Be 1
        $c[0].File | Should -Be ([System.IO.Path]::GetFullPath((Join-Path $script:Root 'a')))
    }
    It 'drops reparse points and anything outside the root (traversal)' {
        $old = $script:Now.AddDays(-5)
        $e = @(
            [pscustomobject]@{ Path = (Join-Path $script:Root 'link'); Length = 1; LastWriteTimeUtc = $old; CreationTimeUtc = $old; IsReparsePoint = $true }
            [pscustomobject]@{ Path = (Join-Path $script:Root '../evil.txt'); Length = 1; LastWriteTimeUtc = $old; CreationTimeUtc = $old; IsReparsePoint = $false }
            [pscustomobject]@{ Path = $script:Root; Length = 1; LastWriteTimeUtc = $old; CreationTimeUtc = $old; IsReparsePoint = $false }
        )
        @(ConvertTo-WcTempCandidate -Entry $e -Root $script:Root -NowUtc $script:Now).Count | Should -Be 0
    }
}

Describe 'Temp cleanup on a real tree inside a test dir' {
    BeforeEach {
        $script:T = New-TempTree
        Mock -ModuleName WinCare.Cleanup Get-WcTempRoot { $script:T.Root }
    }
    AfterEach {
        # Remove the link itself first (never its target), then the test tree.
        [System.IO.Directory]::Delete((Join-Path $script:T.Root 'link'))
        Remove-Item -LiteralPath $script:T.Base -Recurse -Force
    }
    It 'walk never follows the symlinked folder' {
        $w = Get-WcTempFileEntry -Root $script:T.Root
        @($w.Entries | Where-Object { $_.Path -like '*keep.txt' }).Count | Should -Be 0
    }
    It 'Preview lists old files and bytes and deletes nothing' {
        Mock -ModuleName WinCare.Cleanup Remove-WcTempFile { 'Deleted' }
        $r = Invoke-WcTempCleanup -Scope User
        @($r.Items).Count | Should -Be 2
        $r.BytesBefore | Should -Be 150
        $r.BytesFreed | Should -BeNullOrEmpty
        $r.Summary | Should -Match '^Would delete 2 file'
        Should -Invoke -ModuleName WinCare.Cleanup Remove-WcTempFile -Times 0 -Exactly
        Test-Path (Join-Path $script:T.Root 'old1.tmp') | Should -BeTrue
    }
    It 'Execute deletes only old files inside the root and reports measured bytes' {
        $r = Invoke-WcTempCleanup -Scope User -Execute
        $r.BytesFreed | Should -Be 150
        $r.BytesAfter | Should -Be 0
        @($r.Items | Where-Object { $_.Status -eq 'Deleted' }).Count | Should -Be 2
        Test-Path (Join-Path $script:T.Root 'old1.tmp') | Should -BeFalse
        Test-Path (Join-Path (Join-Path $script:T.Root 'sub') 'old2.tmp') | Should -BeFalse
        Test-Path (Join-Path $script:T.Root 'new.tmp') | Should -BeTrue
        Test-Path (Join-Path $script:T.Outside 'keep.txt') | Should -BeTrue
        Test-Path (Join-Path $script:T.Root 'sub') | Should -BeTrue
    }
    It 'Execute removes exactly the files Preview listed' {
        $preview = @((Invoke-WcTempCleanup -Scope User).Items | ForEach-Object { $_.File }) | Sort-Object
        $script:Removed = @()
        Mock -ModuleName WinCare.Cleanup Remove-WcTempFile { $script:Removed += $Path; 'Deleted' }
        Invoke-WcTempCleanup -Scope User -Execute | Out-Null
        (@($script:Removed) | Sort-Object) | Should -Be $preview
    }
    It 'skips and counts locked files without counting their bytes' {
        Mock -ModuleName WinCare.Cleanup Remove-WcTempFile { 'Locked' }
        $r = Invoke-WcTempCleanup -Scope User -Execute
        $r.BytesFreed | Should -Be 0
        @($r.Items | Where-Object { $_.Status -eq 'Locked' }).Count | Should -Be 2
        $r.Summary | Should -Match '2 locked'
    }
    It 'refuses paths that pass through a reparse point or leave the root' {
        Test-WcSafeDeletePath -Path (Join-Path (Join-Path $script:T.Root 'link') 'keep.txt') -Root $script:T.Root | Should -BeFalse
        Test-WcSafeDeletePath -Path (Join-Path $script:T.Outside 'keep.txt') -Root $script:T.Root | Should -BeFalse
        Test-WcSafeDeletePath -Path $script:T.Root -Root $script:T.Root | Should -BeFalse
        Test-WcSafeDeletePath -Path (Join-Path $script:T.Root 'old1.tmp') -Root $script:T.Root | Should -BeTrue
    }
    It 'Windows temp Execute requires admin and deletes nothing without it' {
        Mock -ModuleName WinCare.Cleanup Test-WcIsAdmin { $false }
        Mock -ModuleName WinCare.Cleanup Remove-WcTempFile { 'Deleted' }
        { Invoke-WcTempCleanup -Scope Windows -Execute } | Should -Throw '*administrator*'
        Should -Invoke -ModuleName WinCare.Cleanup Remove-WcTempFile -Times 0 -Exactly
    }
}

Describe 'Remove-WcTempFile' {
    It 'reports Gone for a file that no longer exists' {
        Remove-WcTempFile -Path (Join-Path $script:Tmp 'missing.tmp') | Should -Be 'Gone'
    }
}

Describe 'Volume optimization' {
    BeforeEach {
        Mock -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume { @('Current fragmentation: 1%') }
        Mock -ModuleName WinCare.Cleanup Test-WcIsAdmin { $true }
        $script:OldSys = $env:SystemDrive
        $env:SystemDrive = 'C:'
    }
    AfterEach { $env:SystemDrive = $script:OldSys }
    It 'ReTrim is refused on <Media> (Preview says so, Execute throws, nothing runs)' -ForEach @(@{ Media = 'HDD' }, @{ Media = 'Unknown' }) {
        $script:Media = $Media
        Mock -ModuleName WinCare.Cleanup Get-WcVolumeInfo { [pscustomobject]@{ Drive = 'C:'; IsSystem = $true; MediaType = $script:Media; BusType = 'SATA' } }
        (Invoke-WcOptimizeAction -Mode ReTrim).Summary | Should -Match 'Would refuse'
        { Invoke-WcOptimizeAction -Mode ReTrim -Execute } | Should -Throw '*only on SSD*'
        Should -Invoke -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume -Times 0 -Exactly
    }
    It 'ReTrim Preview shows the command on SSD and Execute runs it for the system drive' {
        Mock -ModuleName WinCare.Cleanup Get-WcVolumeInfo { [pscustomobject]@{ Drive = 'C:'; IsSystem = $true; MediaType = 'SSD'; BusType = 'NVMe' } }
        (Invoke-WcOptimizeAction -Mode ReTrim).Summary | Should -Match 'Would run: Optimize-Volume -DriveLetter C -ReTrim'
        Should -Invoke -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume -Times 0 -Exactly
        Invoke-WcOptimizeAction -Mode ReTrim -Execute | Out-Null
        Should -Invoke -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume -Times 1 -Exactly -ParameterFilter { $DriveLetter -eq 'C' -and $Mode -eq 'ReTrim' }
    }
    It 'Analyze captures the output' {
        $r = Invoke-WcOptimizeAction -Mode Analyze -Execute
        $r.Output | Should -Match 'fragmentation'
    }
    It 'rejects an invalid system drive' {
        $env:SystemDrive = 'C:;x'
        { Invoke-WcOptimizeAction -Mode Analyze } | Should -Throw '*Invalid system drive*'
    }
    It 'requires admin to execute' {
        Mock -ModuleName WinCare.Cleanup Test-WcIsAdmin { $false }
        { Invoke-WcOptimizeAction -Mode Analyze -Execute } | Should -Throw '*administrator*'
        Should -Invoke -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume -Times 0 -Exactly
    }
}

Describe 'F3 catalog and localization' {
    BeforeAll {
        $script:Catalog = Import-WcActionCatalog -Path (Join-Path $script:SrcRoot 'Core/actions.json')
        $script:Frag = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Core/actions.d/f3-maintenance.json')
        $script:Pt = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Localization/pt-BR.d/f3-maintenance.json')
        $script:En = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Localization/en-US.d/f3-maintenance.json')
    }
    It 'loads with the main catalog and every F3 action has a registered handler' {
        $names = Initialize-WcActionHandlers
        foreach ($a in $script:Frag.actions) {
            @($script:Catalog | Where-Object { $_.Id -eq $a.Id }).Count | Should -Be 1
            $names | Should -Contain $a.Handler
        }
        @($script:Frag.actions).Count | Should -Be 10
    }
    It 'irreversible and modifying actions are flagged as such' {
        foreach ($a in $script:Frag.actions) {
            if ($a.Modifies) { $a.Risk | Should -Not -Be 'None' }
        }
        ($script:Frag.actions | Where-Object { $_.Id -eq 'integrity.dism-restorehealth' }).Reversible | Should -BeFalse
        ($script:Frag.actions | Where-Object { $_.Id -eq 'cleanup.user-temp' }).RequiresAdmin | Should -BeFalse
    }
    It 'pt-BR and en-US fragments have the same keys and cover every title/description' {
        Compare-Object @($script:Pt.Keys) @($script:En.Keys) | Should -BeNullOrEmpty
        foreach ($a in $script:Frag.actions) {
            $script:Pt.Keys | Should -Contain $a.TitleKey
            $script:Pt.Keys | Should -Contain $a.DescriptionKey
        }
    }
    It 'loads through Import-WcLocalization without duplicate keys and keeps accents' {
        $s = Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR'
        $s['action.cleanup.user-temp'] | Should -Match ([string][char]0x00E1)
        Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'en-US' | Out-Null
    }
    It 'dry-run of the whole F3 catalog never executes anything' {
        Mock -ModuleName WinCare.Cleanup Remove-WcTempFile { 'Deleted' }
        Mock -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume { @() }
        Mock -ModuleName WinCare.Integrity Invoke-WcNativeCommand { throw 'must not run' }
        Mock -ModuleName WinCare.Cleanup Get-WcTempRoot { $script:Tmp }
        Mock -ModuleName WinCare.Cleanup Get-WcVolumeInfo { [pscustomobject]@{ Drive = 'C:'; IsSystem = $true; MediaType = 'SSD'; BusType = 'NVMe' } }
        $oldRoot = $env:SystemRoot; $oldDrive = $env:SystemDrive
        try {
            $env:SystemRoot = 'C:\Windows'; $env:SystemDrive = 'C:'
            $ids = @($script:Frag.actions | ForEach-Object { $_.Id })
            $ctx = New-WcContext -IsAdmin $true -Build 22631
            $plan = New-WcPlan -Catalog $script:Catalog -ActionId $ids -OperationProfile (Get-WcProfile 'Avancado') -Context $ctx
            $r = Invoke-WcPlan -Plan $plan -Context $ctx -DryRun
            @($r | Where-Object { $_.Status -ne 'Previewed' }).Count | Should -Be 0 -Because (($r | ForEach-Object { "$($_.ActionId)=$($_.Status) $($_.Error)" }) -join '; ')
        }
        finally { $env:SystemRoot = $oldRoot; $env:SystemDrive = $oldDrive }
        Should -Invoke -ModuleName WinCare.Cleanup Remove-WcTempFile -Times 0 -Exactly
        Should -Invoke -ModuleName WinCare.Cleanup Invoke-WcOptimizeVolume -Times 0 -Exactly
        Should -Invoke -ModuleName WinCare.Integrity Invoke-WcNativeCommand -Times 0 -Exactly
    }
}
