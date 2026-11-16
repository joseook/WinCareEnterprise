#Requires -Version 5.1
<#
    WinCare.Elevation - "run as administrator" from the interface.

    The elevated process never runs a user-writable file: it receives a short
    script by -EncodedCommand that downloads install.ps1 of THIS release into
    Program Files (admin-only write), checks the SHA-256 recorded in the signed
    package (Core\release.json, covered by the RSA manifest) and runs it, which
    verifies the whole release again before starting WinCare elevated.
    Must produce exactly the same script as New-WcbElevatedCommand in
    bootstrap/Install-WinCare.ps1 (a test enforces it).
#>
Set-StrictMode -Version 2.0

$script:WcElevationAllowedHosts = @('github.com')

function Test-WcElevationUri {
    param([string] $Uri)
    $u = $null
    if (-not $Uri -or -not [System.Uri]::TryCreate($Uri, [System.UriKind]::Absolute, [ref]$u)) { return $false }
    if ($u.Scheme -ne 'https') { return $false }
    return ($script:WcElevationAllowedHosts -contains $u.Host.ToLowerInvariant())
}

function Get-WcReleaseInfo {
    <# Reads Core\release.json written by the release build. $null when running from source. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $AppRoot)
    $p = Join-Path (Join-Path $AppRoot 'Core') 'release.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    $j = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
    $info = [pscustomobject]@{ Version = [string]$j.version; InstallUri = [string]$j.installUri; InstallSha256 = [string]$j.installSha256 }
    if ($info.Version -notmatch '^\d{1,4}\.\d{1,4}\.\d{1,4}$') { throw 'release.json: invalid version.' }
    if ($info.InstallSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'release.json: invalid SHA-256.' }
    if (-not (Test-WcElevationUri $info.InstallUri)) { throw 'release.json: install URL is not official HTTPS.' }
    return $info
}

function New-WcElevationCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Version,
        [Parameter(Mandatory = $true)][string] $InstallUri,
        [Parameter(Mandatory = $true)][string] $InstallSha256
    )
    if ($Version -notmatch '^\d{1,4}\.\d{1,4}\.\d{1,4}$') { throw 'Invalid version.' }
    if ($InstallSha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Invalid SHA-256.' }
    if (-not (Test-WcElevationUri $InstallUri)) { throw "Refusing non-official or non-HTTPS URL: $InstallUri" }
    # The URL is embedded in a quoted string: allow only characters that cannot break out.
    if ($InstallUri -notmatch '^https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]+$') { throw 'URL has characters that are not allowed.' }
    $lines = @(
        '$ErrorActionPreference = ''Stop''',
        'try {',
        '    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12',
        '    try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { Write-Verbose ''no proxy'' }',
        '    $pf = $env:ProgramFiles; if (-not $pf) { $pf = ''C:\Program Files'' }',
        '    $d = Join-Path $pf ''WinCare\bootstrap''',
        '    New-Item -ItemType Directory -Path $d -Force | Out-Null',
        ('    $f = Join-Path $d ''install-{0}.ps1''' -f $Version),
        ('    Invoke-WebRequest -Uri ''{0}'' -UseBasicParsing -OutFile $f' -f $InstallUri),
        ('    if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne ''{0}'') {{ Remove-Item -LiteralPath $f -Force; throw ''install.ps1 hash mismatch - nothing was started.'' }}' -f $InstallSha256.ToUpperInvariant()),
        '    $ps = Join-Path $env:SystemRoot ''System32\WindowsPowerShell\v1.0\powershell.exe''',
        ('    & $ps -NoProfile -ExecutionPolicy RemoteSigned -File $f -Version ''{0}''' -f $Version),
        '    if ($LASTEXITCODE -ne 0) { throw (''install.ps1 exited with code '' + $LASTEXITCODE) }',
        '}',
        'catch { Write-Host (''WinCare: '' + $_.Exception.Message) -ForegroundColor Red; Read-Host ''Press Enter to close'' | Out-Null }'
    )
    return ($lines -join "`r`n")
}

function Start-WcElevatedRelaunch {
    <#
        Asks for UAC and starts the verified release elevated. Returns $true when
        the elevated process was started; throws when not possible (running from
        source, UAC cancelled).
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string] $AppRoot)
    $info = Get-WcReleaseInfo -AppRoot $AppRoot
    if ($null -eq $info) { throw 'not-a-release' }
    $cmd = New-WcElevationCommand -Version $info.Version -InstallUri $info.InstallUri -InstallSha256 $info.InstallSha256
    $b64 = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd))
    $sysRoot = $env:SystemRoot
    if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
    $ps51 = $sysRoot.TrimEnd('\') + '\System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not $PSCmdlet.ShouldProcess('WinCare ' + $info.Version, 'Start elevated')) { return $false }
    Start-Process -FilePath $ps51 -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'RemoteSigned', '-EncodedCommand', $b64) | Out-Null
    return $true
}

Export-ModuleMember -Function @('Get-WcReleaseInfo', 'New-WcElevationCommand', 'Start-WcElevatedRelaunch')
