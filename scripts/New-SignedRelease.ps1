#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a signed WinCare release on the maintainer machine (Linux or Windows
    with openssl). The private key never leaves this machine and is never used in CI.

.DESCRIPTION
    Output in dist/release/v<version>/:
      WinCare-<v>.zip                    app package (src, README, LICENSE, SECURITY)
      WinCare-<v>.manifest.json          zip hash + hash of every file inside
      WinCare-<v>.manifest.json.sig      RSA-3072 PKCS#1 v1.5 SHA-256 signature
      install.ps1                        bootstrapper with this version as default
      ONE-LINER.txt                      the command for technicians (pins install.ps1 SHA-256)
    And dist/site/ (index.html, install.ps1, run) for the short URL; `run` is the
    `irm .../run | iex` launcher (pins install.ps1 by hash, runs it as a file).
    Before finishing, it runs the generated install.ps1 against the package in a
    temporary cache (-VerifyOnly) - the release is only produced if that passes.
    Publishing (GitHub Release, site) is a separate step.
#>
[CmdletBinding()]
param(
    [string] $KeyPath = (Join-Path $HOME '.config/wincare-signing/release-key.pem'),
    [string] $SiteUrl = 'https://wincare.joseok.cloud',
    [string] $OutputDirectory
)
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'dist' }
$repo = Split-Path -Parent $PSScriptRoot
$version = (Import-PowerShellDataFile (Join-Path $repo 'src/WinCare.psd1')).ModuleVersion
if (-not (Test-Path -LiteralPath $KeyPath)) { throw "Signing key not found: $KeyPath" }
if (-not (Get-Command openssl -ErrorAction SilentlyContinue)) { throw 'openssl not found.' }
$utf8 = New-Object System.Text.UTF8Encoding($false)

$out = Join-Path $OutputDirectory "release/v$version"
$stage = Join-Path $OutputDirectory "release/stage-$version"
foreach ($d in $out, $stage) { if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force } }
New-Item -ItemType Directory -Path $out, $stage -Force | Out-Null
foreach ($item in 'src', 'README.md', 'LICENSE', 'SECURITY.md') { Copy-Item -LiteralPath (Join-Path $repo $item) -Destination $stage -Recurse }

# install.ps1 = committed bootstrapper + default version. Built first so its hash can
# go inside the signed package (Core/release.json, used by "Run as administrator").
$boot = [System.IO.File]::ReadAllText((Join-Path $repo 'bootstrap/Install-WinCare.ps1'))
$boot = $boot.Replace("`$script:WcbDefaultVersion = ''", "`$script:WcbDefaultVersion = '$version'")
$install = Join-Path $out 'install.ps1'
[System.IO.File]::WriteAllText($install, $boot.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8)
$installHash = (Get-FileHash -LiteralPath $install -Algorithm SHA256).Hash
$releaseInfo = [ordered]@{ version = $version; installUri = ('https://github.com/joseook/WinCareEnterprise/releases/download/v{0}/install.ps1' -f $version); installSha256 = $installHash }
[System.IO.File]::WriteAllText((Join-Path $stage 'src/Core/release.json'), (ConvertTo-Json -InputObject $releaseInfo), $utf8)

$files = foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File | Sort-Object FullName) {
    [ordered]@{ path = $f.FullName.Substring($stage.Length + 1).Replace('\', '/'); sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash }
}
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zipName = "WinCare-$version.zip"
$zip = Join-Path $out $zipName
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
Remove-Item -LiteralPath $stage -Recurse -Force

$manifest = [ordered]@{
    version = $version
    created = (Get-Date).ToUniversalTime().ToString('o')
    package = [ordered]@{ name = $zipName; sha256 = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash; size = (Get-Item -LiteralPath $zip).Length }
    files   = @($files)
}
$manPath = Join-Path $out "WinCare-$version.manifest.json"
[System.IO.File]::WriteAllText($manPath, (ConvertTo-Json -InputObject $manifest -Depth 5), $utf8)
& openssl dgst -sha256 -sign $KeyPath -out ($manPath + '.sig') $manPath
if ($LASTEXITCODE -ne 0) { throw 'openssl signing failed.' }

# Self-test: the generated install.ps1 must accept this exact package.
$tmpCache = Join-Path ([System.IO.Path]::GetTempPath()) ('wincare-selftest-' + [guid]::NewGuid().ToString('N'))
try {
    # Child scope: dot-sourcing install.ps1 defines $Version, which would clobber $version here.
    $null = & { param($i, $v, $z, $m, $c) . $i; Invoke-WcbMain -Version $v -PackagePath $z -ManifestPath $m -CacheRoot $c -VerifyOnly } $install $version $zip $manPath $tmpCache
}
finally { Remove-Item -LiteralPath $tmpCache -Recurse -Force -ErrorAction SilentlyContinue }

$oneLiner = '$f="$env:TEMP\wincare-install.ps1"; iwr ' + $SiteUrl + '/install.ps1 -UseBasicParsing -OutFile $f; if ((Get-FileHash $f -Algorithm SHA256).Hash -eq ''' + $installHash + ''') { powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File $f } else { Write-Error ''install.ps1 nao confere - nada foi executado'' }'
[System.IO.File]::WriteAllText((Join-Path $out 'ONE-LINER.txt'), $oneLiner + "`r`n", $utf8)

# Static site for the short URL.
$site = Join-Path $OutputDirectory 'site'
if (Test-Path -LiteralPath $site) { Remove-Item -LiteralPath $site -Recurse -Force }
New-Item -ItemType Directory -Path $site -Force | Out-Null
Copy-Item -LiteralPath $install -Destination (Join-Path $site 'install.ps1')
# irm | iex launcher: pins install.ps1 by hash and runs it as a file.
$run = [System.IO.File]::ReadAllText((Join-Path $repo 'site/run.template.ps1'), $utf8)
$run = $run.Replace('{{VERSION}}', $version).Replace('{{INSTALL_SHA256}}', $installHash).Replace('{{SITE_URL}}', $SiteUrl)
$runErr = $null
[void][System.Management.Automation.Language.Parser]::ParseInput($run, [ref]$null, [ref]$runErr)
if (@($runErr).Count -gt 0) { throw 'run.ps1 does not parse.' }
foreach ($runName in 'run', 'run.ps1') { [System.IO.File]::WriteAllText((Join-Path $site $runName), $run.Replace("`r`n", "`n").Replace("`n", "`r`n"), $utf8) }
$tpl = [System.IO.File]::ReadAllText((Join-Path $repo 'site/index.template.html'), $utf8)
$html = $tpl.Replace('{{SITE_URL}}', $SiteUrl).Replace('{{VERSION}}', $version).Replace('{{ONELINER}}', [System.Net.WebUtility]::HtmlEncode($oneLiner)).Replace('{{INSTALL_SHA256}}', $installHash).Replace('{{ZIP_SHA256}}', $manifest.package.sha256)
[System.IO.File]::WriteAllText((Join-Path $site 'index.html'), $html, $utf8)
$host1 = ([uri]$SiteUrl).Host
[System.IO.File]::WriteAllText((Join-Path $site 'CNAME'), $host1, $utf8)

Write-Host "Release v$version OK (self-test passed)"
Write-Host "  $out"
Write-Host "  install.ps1 SHA-256: $installHash"
Write-Host "  zip SHA-256:         $($manifest.package.sha256)"
Write-Host ''
Write-Host $oneLiner
