# Shared setup for Pester 5 tests. Dot-source inside BeforeAll.
# Defines stubs for Windows-only commands so Pester can mock them on Linux.
# Stubs are never called for real: every test that needs them mocks them.

$script:RepoRoot = Split-Path -Parent $PSScriptRoot
$script:SrcRoot = Join-Path $script:RepoRoot 'src'

foreach ($name in @('Get-CimInstance', 'Get-MpComputerStatus', 'Get-NetFirewallProfile', 'Get-AuthenticodeSignature', 'Test-FileCatalog')) {
    if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
        $body = "[CmdletBinding()] param([Parameter(ValueFromRemainingArguments = `$true)] `$Rest) throw 'Stub for $name was called without a mock.'"
        Set-Item -Path ("function:global:$name") -Value ([scriptblock]::Create($body))
    }
}

function Import-WcTestModules {
    param([string[]] $Name = @('System', 'Storage', 'Startup', 'Security', 'Diagnostics', 'Reporting'))
    Import-Module (Join-Path $script:SrcRoot 'Core/WinCare.Core.psm1') -Force -Global -DisableNameChecking
    foreach ($n in $Name) {
        Import-Module (Join-Path $script:SrcRoot "Modules/WinCare.$n.psm1") -Force -Global -DisableNameChecking
    }
}

function New-WcTestDir {
    $d = Join-Path ([System.IO.Path]::GetTempPath()) ('wctest-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}
