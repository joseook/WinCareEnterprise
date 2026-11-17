# WinCare Enterprise - launcher for:  irm https://wincare.joseok.cloud/run | iex
# Read it before running. What it does:
#   1. downloads install.ps1 of release 0.3.1 and checks its SHA-256 (pinned below);
#   2. runs it as a FILE with process-scope RemoteSigned (Group Policy still wins);
#   3. install.ps1 verifies the RSA-signed release (every file hashed) before starting WinCare.
# As administrator, files go to Program Files (admin-only write); otherwise to %LOCALAPPDATA%.
# Stronger alternative (hash pinned on your side): see https://wincare.joseok.cloud
& {
    $ErrorActionPreference = 'Stop'
    $v = '0.3.1'
    $h = 'D0099E99AE846DA2508D209B82584AA5F3276589E04670EE71AF2ACCE26AB861'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try { [Net.WebRequest]::DefaultWebProxy.Credentials = [Net.CredentialCache]::DefaultNetworkCredentials } catch { Write-Verbose 'no proxy' }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) { $d = Join-Path $env:ProgramFiles 'WinCare\bootstrap' } else { $d = Join-Path $env:LOCALAPPDATA 'WinCare\bootstrap' }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    $f = Join-Path $d ('install-' + $v + '.ps1')
    Invoke-WebRequest -Uri 'https://wincare.joseok.cloud/install.ps1' -UseBasicParsing -OutFile $f
    if ((Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash -ne $h) {
        Remove-Item -LiteralPath $f -Force
        Write-Error 'install.ps1 nao confere com o hash publicado - nada foi executado.'
        return
    }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $ps -NoProfile -ExecutionPolicy RemoteSigned -File $f -Version $v
}
