#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules
    $script:Tmp = New-WcTestDir
    Initialize-WcLog -Path (Join-Path $script:Tmp 'test.jsonl') | Out-Null
    Import-WcLocalization -Root (Join-Path $script:SrcRoot 'Localization') -Language 'pt-BR' | Out-Null
    $script:Snap = [pscustomobject]@{
        Meta      = [pscustomobject]@{ Tool = 'WinCare Enterprise'; Version = '0.1.0'; Computer = 'PC<1>'; Created = '2026-11-16T00:00:00Z'; Profile = 'Diagnostico' }
        System    = $null
        Storage   = @([pscustomobject]@{ Drive = 'C:'; Label = '<img src=x onerror=alert(1)>'; FileSystem = 'NTFS'; SizeBytes = 100GB; FreeBytes = 3GB; FreePercent = 3; MediaType = 'SSD'; BusType = 'NVMe' })
        Processes = @([pscustomobject]@{ Name = '<script>alert(1)</script>'; Id = 4; WorkingSetBytes = 1GB; CpuSecondsTotal = 1; Company = 'A&B' })
        Startup   = @()
        Errors    = @()
        Findings  = @([pscustomobject]@{ Id = 'disk-system-critical'; Severity = 'Critical'; TitleKey = 'finding.disk-system-critical.title'; RecommendationKey = 'finding.disk-system-critical.recommendation'; Evidence = @('C:', 3, 3) })
    }
}
AfterAll { Remove-Item -LiteralPath $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }

Describe 'HTML report' {
    BeforeAll { $script:Html = ConvertTo-WcReportHtml -Snapshot $script:Snap }
    It 'encodes every untrusted value' {
        $script:Html | Should -Not -Match '<script>alert'
        $script:Html | Should -Not -Match '<img src=x'
        $script:Html | Should -Match '&lt;script&gt;'
        $script:Html | Should -Match 'A&amp;B'
        $script:Html | Should -Match 'PC&lt;1&gt;'
    }
    It 'is self-contained (no scripts or external resources) and sets a CSP' {
        $script:Html | Should -Not -Match '<script'
        $script:Html | Should -Not -Match '(src|href)="https?:'
        $script:Html | Should -Match 'Content-Security-Policy'
    }
    It 'renders localized findings with evidence' {
        $script:Html | Should -Match 'Disco do sistema C: quase cheio'
    }
}

Describe 'Export' {
    It 'writes JSON that round-trips' {
        $f = Export-WcReport -Snapshot $script:Snap -Path (Join-Path $script:Tmp 'r.json') -Format Json
        $back = Get-Content -Raw -LiteralPath $f.FullName | ConvertFrom-Json
        $back.Meta.Version | Should -Be '0.1.0'
        $back.Findings[0].Evidence[0] | Should -Be 'C:'
    }
    It 'refuses a mismatched extension' {
        { Export-WcReport -Snapshot $script:Snap -Path (Join-Path $script:Tmp 'r.exe') -Format Json } | Should -Throw
        { Export-WcReport -Snapshot $script:Snap -Path (Join-Path $script:Tmp 'r.json') -Format Html } | Should -Throw
    }
    It 'formats bytes' {
        Format-WcBytes $null | Should -Be '-'
        Format-WcBytes 1536MB | Should -Match '^1[.,]5 GB$'
    }
}
