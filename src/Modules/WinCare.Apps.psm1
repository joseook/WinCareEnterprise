#Requires -Version 5.1
<#
    WinCare.Apps - page 'apps' ("Aplicativos e reparos"), phase F6.
    Page data contract: docs/CONTRATO-ACOES.md section 6. Selection contract: section 7.

    Page sections (Get-WcAppsPageData, read-only):
      installed         Uninstall keys HKLM 64/32-bit + HKCU (+ HKCU WOW6432Node)
      broken-uninstall  entries whose uninstaller file is missing
      winget-updates    'winget upgrade --include-unknown' (table parsed, see below)
      store-problems    Get-AppxPackage (current user) where Status is not Ok

    Actions (Core/actions.d/f6-apps.json):
      apps.winget-upgrade  winget upgrade --id <selected> --exact ... (one run per id, never --all)
      apps.store-reset     Reset-AppxPackage <selected PackageFullName> (deletes the app's local data)
      apps.open-repair     opens ms-settings:appsfeatures; never runs an uninstaller

    Sources (checked 2026-11-16):
      * winget options: Microsoft Learn "upgrade Command" (learn.microsoft.com/windows/package-manager/winget/upgrade):
        --id, -e/--exact, -h/--silent, -u/--include-unknown, --accept-source-agreements,
        --accept-package-agreements, --disable-interactivity. The page documents NO JSON
        or machine-readable output for 'upgrade', so the text table is parsed.
      * winget return codes: github.com/microsoft/winget-cli doc/windows/package-manager/winget/returnCodes.md.
      * The version that introduced --disable-interactivity could not be confirmed, so support
        is detected at run time from 'winget upgrade --help' (Test-WcWingetFlagSupported).
      * Reset-AppxPackage: Appx module, Windows 10 2004 (build 19041) and later.

    winget context (documented limitation): winget.exe is an App Execution Alias installed
    per user under %LOCALAPPDATA%\Microsoft\WindowsApps by App Installer. It is normally
    absent for SYSTEM and for accounts that never signed in interactively, so WinCare only
    runs it as the signed-in user and reports 'system-context' / 'not-found' otherwise.

    Output encoding (ASSUMPTION, unverified on real Windows): winget writes UTF-8 when its
    output is redirected. Bytes are decoded as strict UTF-8 first and fall back to the OEM
    code page when they are not valid UTF-8 (ConvertFrom-WcNativeOutputBytes). This does not
    depend on [Console]::OutputEncoding, so it behaves the same on PS 5.1 and 7.
#>

$script:WcWingetIdPattern = '^[A-Za-z0-9._+-]{1,128}$'
# PackageFullName = Name_Version_Architecture_ResourceId_PublisherId (ResourceId may be empty or '~').
$script:WcAppxFullNamePattern = '^[A-Za-z0-9.-]{1,64}_[0-9.]{1,32}_[A-Za-z0-9]{1,16}_[A-Za-z0-9.~-]{0,64}_[a-z0-9]{13}$'
$script:WcWingetListTimeoutSec = 180
$script:WcWingetUpgradeTimeoutSec = 1800

# Documented winget return codes (signed int32) -> outcome. Anything else = Failed with hex.
$script:WcWingetExitCodes = @{
    0             = @{ Status = 'Succeeded'; Reason = 'ok' }
    -1978335189   = @{ Status = 'NoUpdate'; Reason = 'update-not-applicable' }          # 0x8A15002B
    -1978335212   = @{ Status = 'Failed'; Reason = 'no-package-found' }                 # 0x8A150014
    -1978335210   = @{ Status = 'Failed'; Reason = 'multiple-packages-found' }          # 0x8A150016
    -1978335211   = @{ Status = 'Failed'; Reason = 'no-sources' }                       # 0x8A150015
    -1978335162   = @{ Status = 'Failed'; Reason = 'source-agreements-not-accepted' }   # 0x8A150046
    -1978335167   = @{ Status = 'Failed'; Reason = 'package-agreements-not-accepted' }  # 0x8A150041
    -1978335174   = @{ Status = 'BlockedByPolicy'; Reason = 'blocked-by-group-policy' } # 0x8A15003A
    -1978334961   = @{ Status = 'BlockedByPolicy'; Reason = 'install-blocked-by-policy' } # 0x8A15010F
    -1978334975   = @{ Status = 'Failed'; Reason = 'package-in-use' }                   # 0x8A150101
    -1978334967   = @{ Status = 'SucceededRebootRequired'; Reason = 'reboot-required-to-finish' } # 0x8A150109
    -1978334966   = @{ Status = 'Failed'; Reason = 'reboot-required-to-install' }       # 0x8A15010A
    -1978334964   = @{ Status = 'Failed'; Reason = 'cancelled-by-user' }                # 0x8A15010C
    -1978334972   = @{ Status = 'Failed'; Reason = 'missing-dependency' }               # 0x8A150104
    -1978334971   = @{ Status = 'Failed'; Reason = 'disk-full' }                        # 0x8A150105
    -1978334970   = @{ Status = 'Failed'; Reason = 'insufficient-memory' }              # 0x8A150106
    -1978334969   = @{ Status = 'Failed'; Reason = 'no-network' }                       # 0x8A150107
    -1978334968   = @{ Status = 'Failed'; Reason = 'installer-error-contact-support' }  # 0x8A150108
    -1978335152   = @{ Status = 'Failed'; Reason = 'upgrade-version-unknown' }          # 0x8A150050
    -1978335128   = @{ Status = 'Failed'; Reason = 'package-pinned' }                   # 0x8A150068
    -1978335231   = @{ Status = 'Failed'; Reason = 'winget-internal-error' }            # 0x8A150001
}

# ------------------------------------------------------------- selection --

function Get-WcAppsSelection {
    <#
        Pure: the ids the user selected for one action (docs/CONTRATO-ACOES.md section 7).
        The UI puts them in the plan context: $Context.Selection = @{ '<action id>' = @('a', 'b') }.
        Missing context/key -> empty array. Values are returned as strings, not validated here.
    #>
    [CmdletBinding()]
    param($Context, [Parameter(Mandatory = $true)][string] $ActionId)
    if ($null -eq $Context -or $Context -isnot [System.Collections.IDictionary] -or -not $Context.Contains('Selection')) { return @() }
    $sel = $Context['Selection']
    if ($null -eq $sel -or $sel -isnot [System.Collections.IDictionary] -or -not $sel.Contains($ActionId)) { return @() }
    $out = @()
    foreach ($v in @($sel[$ActionId])) { if ($null -ne $v) { $out += [string]$v } }
    return $out
}

function Test-WcWingetPackageId {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Id)
    if (-not $Id) { return $false }
    # The pattern allows '-', so --all or -h would match it: an id must not look like an option.
    if ($Id.StartsWith('-')) { return $false }
    return ($Id -cmatch $script:WcWingetIdPattern)
}

function Test-WcAppxPackageFullName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $FullName)
    if (-not $FullName) { return $false }
    return ($FullName -cmatch $script:WcAppxFullNamePattern)
}

function ConvertTo-WcPackageSelection {
    <#
        Pure: validates a selection list. Throws on the first invalid value (fail closed),
        removes duplicates (case-insensitive, first spelling kept). Kind: WingetId | AppxFullName.
    #>
    [CmdletBinding()]
    param([object[]] $InputObject = @(), [ValidateSet('WingetId', 'AppxFullName')][string] $Kind = 'WingetId', [int] $Max = 50)
    $seen = @{}
    $out = @()
    foreach ($v in @($InputObject)) {
        if ($null -eq $v) { continue }
        $s = [string]$v
        $ok = $false
        if ($Kind -eq 'WingetId') { $ok = Test-WcWingetPackageId -Id $s } else { $ok = Test-WcAppxPackageFullName -FullName $s }
        if (-not $ok) {
            $shown = $s
            if ($shown.Length -gt 60) { $shown = $shown.Substring(0, 60) + '...' }
            $shown = [regex]::Replace($shown, '[^\x20-\x7E]', '?')
            throw "Invalid $Kind in selection: '$shown'"
        }
        $k = $s.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $out += $s
    }
    if ($out.Count -gt $Max) { throw "Too many selected packages ($($out.Count)); the limit is $Max." }
    return $out
}

# ---------------------------------------------------- installed programs --

function ConvertTo-WcUninstallExecutable {
    <#
        Pure: extracts the executable from an UninstallString without exposing the arguments.
        Quoted path -> text inside the quotes; unquoted -> shortest prefix ending in
        .exe/.cmd/.bat/.com followed by a space or the end. %VAR% are expanded.
        Checkable = absolute drive path (C:\...). Bare names (MsiExec.exe, rundll32.exe) are
        resolved by Windows from System32 and are not file-checked.
    #>
    [CmdletBinding()]
    param([string] $UninstallString)
    $empty = [pscustomobject]@{ Executable = $null; FileName = $null; IsMsi = $false; Checkable = $false }
    if (-not $UninstallString -or -not $UninstallString.Trim()) { return $empty }
    $s = [System.Environment]::ExpandEnvironmentVariables($UninstallString.Trim())
    $path = $null
    if ($s.StartsWith('"')) {
        $end = $s.IndexOf('"', 1)
        if ($end -gt 1) { $path = $s.Substring(1, $end - 1) }
    }
    else {
        $m = [regex]::Match($s, '^(?i)(.+?\.(exe|cmd|bat|com))(?=\s|$)')
        if ($m.Success) { $path = $m.Groups[1].Value }
        else { $path = ($s -split '\s+')[0] }
    }
    if (-not $path) { return $empty }
    $path = $path.Trim()
    $file = $path
    $idx = $path.LastIndexOfAny([char[]]@('\', '/'))
    if ($idx -ge 0) { $file = $path.Substring($idx + 1) }
    return [pscustomobject]@{
        Executable = $path
        FileName   = $file
        IsMsi      = ($file -match '^(?i)msiexec(\.exe)?$')
        Checkable  = ($path -match '^[A-Za-z]:\\')
    }
}

function ConvertTo-WcInstallDate {
    <# Pure: Uninstall InstallDate (yyyyMMdd, sometimes other formats) -> 'yyyy-MM-dd' or the raw text. #>
    [CmdletBinding()]
    param($Value)
    if ($null -eq $Value) { return '' }
    $t = ([string]$Value).Trim()
    if (-not $t) { return '' }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($t, 'yyyyMMdd', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$d)) {
        return $d.ToString('yyyy-MM-dd')
    }
    return $t
}

function Format-WcAppsBytes {
    <# Pure: bytes -> short readable text ('' for null/0). #>
    param($Bytes)
    if ($null -eq $Bytes) { return '' }
    $b = [double]$Bytes
    if ($b -le 0) { return '' }
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

function Get-WcAppsValue {
    param($InputObject, [string] $Name)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $null
    }
    $p = $InputObject.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-WcInstalledProgram {
    <#
        Pure: Uninstall-key entries -> display rows.
        Entry: hashtable/object with DisplayName, DisplayVersion, Publisher, InstallDate,
        EstimatedSize (KB), UninstallString, SystemComponent, ParentKeyName, ReleaseType,
        WindowsInstaller, Hive (HKLM64 | HKLM32 | HKCU | HKCU32).
        Hidden: no DisplayName, SystemComponent=1, ParentKeyName set, ReleaseType update/hotfix.
        PathExists: scriptblock { param($Path) -> bool } (the I/O side passes a real file test).
        Uninstall: OK | MissingFile | MSI | NoUninstaller | NotChecked.
        The uninstall command line is never returned, only the executable path.
    #>
    [CmdletBinding()]
    param([object[]] $Entry = @(), [scriptblock] $PathExists = { param($p) $false })
    $scopes = @{ 'HKLM64' = 'Machine x64'; 'HKLM32' = 'Machine x86'; 'HKCU' = 'User'; 'HKCU32' = 'User x86' }
    $seen = @{}
    $rows = @()
    foreach ($e in @($Entry)) {
        if ($null -eq $e) { continue }
        $name = [string](Get-WcAppsValue $e 'DisplayName')
        if (-not $name.Trim()) { continue }
        $sys = Get-WcAppsValue $e 'SystemComponent'
        if ($null -ne $sys -and "$sys" -match '^\d+$' -and [int]"$sys" -eq 1) { continue }
        if ([string](Get-WcAppsValue $e 'ParentKeyName')) { continue }
        if ([string](Get-WcAppsValue $e 'ReleaseType') -match '(?i)update|hotfix') { continue }
        $hive = [string](Get-WcAppsValue $e 'Hive')
        $scope = $hive
        if ($scopes.ContainsKey($hive)) { $scope = $scopes[$hive] }
        $version = [string](Get-WcAppsValue $e 'DisplayVersion')
        $key = ('{0}|{1}|{2}' -f $name.Trim(), $version, $scope).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true

        $sizeRaw = $null
        $est = Get-WcAppsValue $e 'EstimatedSize'
        if ($null -ne $est -and "$est" -match '^\d+$') { $sizeRaw = [long]"$est" * 1024L }

        $exe = ConvertTo-WcUninstallExecutable -UninstallString ([string](Get-WcAppsValue $e 'UninstallString'))
        $wi = Get-WcAppsValue $e 'WindowsInstaller'
        $status = 'NotChecked'
        if (-not $exe.Executable) {
            if ($null -ne $wi -and "$wi" -eq '1') { $status = 'MSI' } else { $status = 'NoUninstaller' }
        }
        elseif ($exe.IsMsi) { $status = 'MSI' }
        elseif ($exe.Checkable) {
            $exists = $false
            try { $exists = [bool](& $PathExists $exe.Executable) } catch { $exists = $false }
            if ($exists) { $status = 'OK' } else { $status = 'MissingFile' }
        }
        $exeText = ''
        if ($exe.Executable) { $exeText = $exe.Executable }
        $rows += [pscustomobject]@{
            Name        = $name.Trim()
            Version     = $version
            Publisher   = [string](Get-WcAppsValue $e 'Publisher')
            InstallDate = (ConvertTo-WcInstallDate -Value (Get-WcAppsValue $e 'InstallDate'))
            Size        = (Format-WcAppsBytes -Bytes $sizeRaw)
            SizeRaw     = $sizeRaw
            Scope       = $scope
            Executable  = $exeText
            Uninstall   = $status
        }
    }
    return @($rows | Sort-Object -Property Name, Scope)
}

function ConvertTo-WcBrokenUninstallRow {
    <# Pure: installed rows -> only the ones whose uninstaller file is missing. #>
    [CmdletBinding()]
    param([object[]] $Program = @())
    $out = @()
    foreach ($p in @($Program)) {
        if ($null -eq $p -or $p.Uninstall -ne 'MissingFile') { continue }
        $out += [pscustomobject]@{ Name = $p.Name; Version = $p.Version; Scope = $p.Scope; Executable = $p.Executable }
    }
    return $out
}

function Get-WcAppsRegistrySubkeys {
    <# Thin I/O: values of every direct subkey of Path (+ KeyName). Missing key -> @(). Read-only. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string[]] $Name)
    $out = @()
    if (-not (Test-Path -LiteralPath $Path)) { return $out }
    foreach ($k in @(Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue)) {
        $h = @{ KeyName = $k.PSChildName }
        $item = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
        if ($item) {
            foreach ($n in $Name) {
                $p = $item.PSObject.Properties[$n]
                if ($p) { $h[$n] = $p.Value }
            }
        }
        $out += $h
    }
    return $out
}

function Get-WcUninstallEntry {
    <# Thin I/O: raw Uninstall entries from the four standard keys, tagged with Hive. #>
    [CmdletBinding()]
    param()
    $names = @('DisplayName', 'DisplayVersion', 'Publisher', 'InstallDate', 'EstimatedSize', 'UninstallString',
        'SystemComponent', 'ParentKeyName', 'ReleaseType', 'WindowsInstaller')
    $entries = @()
    foreach ($u in @(
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = 'HKLM64' }
            @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = 'HKLM32' }
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = 'HKCU' }
            @{ Path = 'HKCU:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'; Hive = 'HKCU32' })) {
        foreach ($e in @(Get-WcAppsRegistrySubkeys -Path $u.Path -Name $names)) {
            $e['Hive'] = $u.Hive
            $entries += $e
        }
    }
    return $entries
}

function Test-WcAppsFileExists {
    <# Thin I/O: file existence (no reparse following needed; only presence is reported). #>
    param([string] $Path)
    if (-not $Path) { return $false }
    try { return [System.IO.File]::Exists($Path) } catch { return $false }
}

# ----------------------------------------------------------------- winget --

function ConvertFrom-WcNativeOutputBytes {
    <#
        Pure: decodes captured stdout bytes. UTF-8 BOM / valid UTF-8 -> UTF-8; UTF-16LE BOM ->
        Unicode; otherwise the OEM code page (or -FallbackCodePage). NUL characters and ANSI/VT
        escape sequences (winget progress) are removed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([byte[]] $Bytes, [int] $FallbackCodePage = 0)
    if ($null -eq $Bytes -or $Bytes.Length -eq 0) { return '' }
    $text = $null
    if ($Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFF -and $Bytes[1] -eq 0xFE) {
        $text = [System.Text.Encoding]::Unicode.GetString($Bytes, 2, $Bytes.Length - 2)
    }
    else {
        $offset = 0
        if ($Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF) { $offset = 3 }
        try {
            $strict = New-Object System.Text.UTF8Encoding($false, $true)
            $text = $strict.GetString($Bytes, $offset, $Bytes.Length - $offset)
        }
        catch {
            $cp = $FallbackCodePage
            if ($cp -le 0) { $cp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage }
            $enc = $null
            try { $enc = [System.Text.Encoding]::GetEncoding($cp) } catch { $enc = [System.Text.Encoding]::GetEncoding(28591) }
            $text = $enc.GetString($Bytes)
        }
    }
    $text = $text.Replace([string][char]0, '')
    $text = [regex]::Replace($text, '\x1B\[[0-9;?]*[ -/]*[@-~]', '')
    return $text
}

function ConvertFrom-WcWingetTable {
    <#
        Pure, language-independent parser for the text table of 'winget upgrade' / 'winget list'.
        The header line (localized) is the last non-blank line before a dashes-only separator;
        column starts are the starts of its words, mapped by POSITION to
        Name, Id, Version, Available[, Source]. A row is accepted only when every column
        boundary falls on a space and the Id is a valid package id; lines starting with
        '<number> ' ('3 upgrades available.') are footers and ignored; anything else
        (e.g. wide-character misalignment) is counted in Unparsed instead of guessed.
        Several tables (e.g. 'require explicit targeting') are all parsed; duplicate ids are dropped.
    #>
    [CmdletBinding()]
    param([string] $Text)
    $result = [pscustomobject]@{ TableFound = $false; SeparatorFound = $false; Rows = @(); Unparsed = 0 }
    if (-not $Text) { return $result }
    $lines = [regex]::Split($Text, '\r\n|\n|\r')
    $fields = @('Name', 'Id', 'Version', 'Available', 'Source')
    $rows = @()
    $seen = @{}
    $unparsed = 0
    $i = 0
    while ($i -lt $lines.Count) {
        if ($lines[$i] -notmatch '^\s*-{3,}\s*$') { $i++; continue }
        $result.SeparatorFound = $true
        $h = $i - 1
        while ($h -ge 0 -and -not $lines[$h].Trim()) { $h-- }
        if ($h -lt 0) { $i++; continue }
        $header = $lines[$h].TrimEnd()
        $starts = @([regex]::Matches($header, '\S+') | ForEach-Object { $_.Index })
        if ($starts.Count -lt 4 -or $starts[0] -ne 0) { $i++; continue }
        if ($starts.Count -gt 5) { $starts = $starts[0..4] }
        $result.TableFound = $true
        $j = $i + 1
        while ($j -lt $lines.Count) {
            $line = $lines[$j].TrimEnd()
            if (-not $line.Trim()) { break }
            if ($line -match '^\s*-{3,}\s*$') { break }
            # next table header: followed by a separator line
            if ($j + 1 -lt $lines.Count -and $lines[$j + 1] -match '^\s*-{3,}\s*$') { break }
            $ok = ($line.Length -gt $starts[$starts.Count - 1])
            if ($ok) {
                for ($c = 1; $c -lt $starts.Count; $c++) {
                    if ($line[$starts[$c] - 1] -ne ' ') { $ok = $false; break }
                }
            }
            $rec = $null
            if ($ok) {
                $rec = [ordered]@{ Name = ''; Id = ''; Version = ''; Available = ''; Source = '' }
                for ($c = 0; $c -lt $starts.Count; $c++) {
                    $from = $starts[$c]
                    $to = $line.Length
                    if ($c + 1 -lt $starts.Count) { $to = [math]::Min($starts[$c + 1], $line.Length) }
                    $val = ''
                    if ($from -lt $line.Length) { $val = $line.Substring($from, $to - $from).Trim() }
                    $rec[$fields[$c]] = $val
                }
                if (-not (Test-WcWingetPackageId -Id $rec.Id) -or -not $rec.Name) { $ok = $false }
            }
            if ($ok) {
                $k = $rec.Id.ToLowerInvariant()
                if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $rows += [pscustomobject]$rec }
            }
            elseif ($line -notmatch '^\d+\s') { $unparsed++ }   # '<n> upgrades available.' style footers are not rows
            $j++
        }
        $i = $j
    }
    $result.Rows = @($rows)
    $result.Unparsed = $unparsed
    return $result
}

function Test-WcWingetFlagSupported {
    <# Pure: true when the help text of a winget command lists the option (e.g. --disable-interactivity). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $HelpText, [Parameter(Mandatory = $true)][string] $Flag)
    if (-not $HelpText) { return $false }
    return ($HelpText -match ('(?m)(^|[\s,])' + [regex]::Escape($Flag) + '(?![A-Za-z0-9-])'))
}

function ConvertTo-WcWingetExitResult {
    <# Pure: winget exit code -> Status (Succeeded | SucceededRebootRequired | NoUpdate | BlockedByPolicy | Failed), Reason, Hex. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $ExitCode)
    $code = [int64]$ExitCode
    if ($code -gt [int32]::MaxValue -and $code -le [uint32]::MaxValue) { $code = $code - 4294967296L }
    $hex = '0x{0:X8}' -f ([int32]$code)
    $key = [int]$code
    if ($script:WcWingetExitCodes.ContainsKey($key)) {
        $d = $script:WcWingetExitCodes[$key]
        return [pscustomobject]@{ ExitCode = $key; Hex = $hex; Status = $d.Status; Reason = $d.Reason }
    }
    return [pscustomobject]@{ ExitCode = $key; Hex = $hex; Status = 'Failed'; Reason = 'exit-code' }
}

function Get-WcWingetListArgument {
    <# Pure: arguments for the read-only upgrade listing. #>
    param([bool] $DisableInteractivity = $false)
    $a = @('upgrade', '--include-unknown', '--accept-source-agreements')
    if ($DisableInteractivity) { $a += '--disable-interactivity' }
    return $a
}

function Get-WcWingetUpgradeArgument {
    <# Pure: arguments for upgrading ONE validated id. Never --all. #>
    param([Parameter(Mandatory = $true)][string] $Id, [bool] $DisableInteractivity = $false)
    if (-not (Test-WcWingetPackageId -Id $Id)) { throw "Invalid winget package id: '$Id'" }
    $a = @('upgrade', '--id', $Id, '--exact', '--silent', '--include-unknown', '--accept-source-agreements', '--accept-package-agreements')
    if ($DisableInteractivity) { $a += '--disable-interactivity' }
    return $a
}

function ConvertTo-WcWingetListResult {
    <#
        Pure: listing run -> Status Ok | NoUpdates | Failed, Rows (display), Unparsed, Reason, Detail.
        Exit 0 without a table, UPDATE_NOT_APPLICABLE and NO_APPLICATIONS_FOUND mean no updates.
    #>
    [CmdletBinding()]
    param($ExitCode, [string] $Text, [bool] $TimedOut = $false)
    if ($TimedOut) { return [pscustomobject]@{ Status = 'Failed'; Reason = 'timeout'; Detail = 'winget did not finish in time.'; Rows = @(); Unparsed = 0 } }
    $table = ConvertFrom-WcWingetTable -Text $Text
    $exit = ConvertTo-WcWingetExitResult -ExitCode $ExitCode
    $rows = @()
    foreach ($r in @($table.Rows)) {
        $rows += [pscustomobject]@{ Name = $r.Name; PackageId = $r.Id; Version = $r.Version; Available = $r.Available; Source = $r.Source }
    }
    if ($rows.Count -gt 0) { return [pscustomobject]@{ Status = 'Ok'; Reason = 'ok'; Detail = ''; Rows = @($rows); Unparsed = $table.Unparsed } }
    if ($table.SeparatorFound -and ($table.Unparsed -gt 0 -or -not $table.TableFound)) {
        # A table was printed but nothing could be read safely: never report 'no updates' then.
        return [pscustomobject]@{ Status = 'Failed'; Reason = 'unparsed-output'; Detail = ('{0} line(s) not recognized' -f $table.Unparsed); Rows = @(); Unparsed = $table.Unparsed }
    }
    if ($exit.ExitCode -eq 0 -or $exit.Reason -eq 'update-not-applicable' -or $exit.Reason -eq 'no-package-found') {
        return [pscustomobject]@{ Status = 'NoUpdates'; Reason = 'no-updates'; Detail = ''; Rows = @(); Unparsed = $table.Unparsed }
    }
    $last = ''
    foreach ($l in @([regex]::Split([string]$Text, '\r\n|\n|\r'))) { if ($l.Trim() -and $l -notmatch '^\s*[-\\|/]\s*$') { $last = $l.Trim() } }
    if ($last.Length -gt 200) { $last = $last.Substring(0, 200) }
    return [pscustomobject]@{ Status = 'Failed'; Reason = $exit.Reason; Detail = ('{0} {1}' -f $exit.Hex, $last).Trim(); Rows = @(); Unparsed = $table.Unparsed }
}

function Test-WcIsSystemAccount {
    <# Thin I/O: true when running as LocalSystem (S-1-5-18), where winget is normally unavailable. #>
    if (-not (Test-WcIsWindows)) { return $false }
    try { return ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18') } catch { return $false }
}

function Get-WcWingetPath {
    <# Thin I/O: the per-user App Execution Alias. $null when absent. Never searches PATH. #>
    [CmdletBinding()]
    param()
    if (-not (Test-WcIsWindows) -or -not $env:LOCALAPPDATA) { return $null }
    $p = [System.IO.Path]::Combine($env:LOCALAPPDATA, 'Microsoft', 'WindowsApps', 'winget.exe')
    if ([System.IO.File]::Exists($p)) { return $p }
    return $null
}

function Invoke-WcWinget {
    <#
        Thin I/O: runs winget with fixed, validated tokens; stdin is closed so a prompt gets EOF
        instead of hanging; stdout bytes decoded by ConvertFrom-WcNativeOutputBytes. Mocked in tests.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]] $ArgumentList, [int] $TimeoutSeconds = 180)
    foreach ($a in $ArgumentList) {
        if ($a -notmatch '^(--?[a-z][a-z-]*|[A-Za-z0-9._+-]{1,128})$') { throw "Refusing winget argument '$a'." }
    }
    $exe = Get-WcWingetPath
    if (-not $exe) { throw 'winget was not found for this user (App Installer alias missing).' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $exe
    $psi.Arguments = ($ArgumentList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    Write-WcLog -Level Audit -Category 'Apps' -Message ('Running: winget {0}' -f $psi.Arguments) | Out-Null
    try {
        [void]$proc.Start()
        $proc.StandardInput.Close()
        $ms = New-Object System.IO.MemoryStream
        $copy = $proc.StandardOutput.BaseStream.CopyToAsync($ms)
        $errTask = $proc.StandardError.ReadToEndAsync()
        $timedOut = -not $proc.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            try { $proc.Kill() } catch { Write-Verbose 'winget already exited.' }
            [void]$proc.WaitForExit(5000)
        }
        else { $proc.WaitForExit() }
        [void]$copy.Wait(5000)
        $text = ConvertFrom-WcNativeOutputBytes -Bytes $ms.ToArray()
        $code = $null
        if (-not $timedOut) { $code = $proc.ExitCode }
        $err = ''
        if ($errTask.Wait(1000)) { $err = [string]$errTask.Result }
        Write-WcLog -Level Audit -Category 'Apps' -Message ('winget exit code {0} (timed out: {1})' -f $code, $timedOut) | Out-Null
        return [pscustomobject]@{ ExitCode = $code; Text = ($text + $err); TimedOut = $timedOut }
    }
    finally { $proc.Dispose() }
}

function Get-WcWingetCapability {
    <# I/O: winget path, SYSTEM check and --disable-interactivity support. Never throws. #>
    [CmdletBinding()]
    param()
    if (Test-WcIsSystemAccount) { return [pscustomobject]@{ Available = $false; Reason = 'system-context'; DisableInteractivity = $false } }
    if (-not (Get-WcWingetPath)) { return [pscustomobject]@{ Available = $false; Reason = 'not-found'; DisableInteractivity = $false } }
    $di = $false
    try {
        $help = Invoke-WcWinget -ArgumentList @('upgrade', '--help') -TimeoutSeconds 30
        $di = Test-WcWingetFlagSupported -HelpText $help.Text -Flag '--disable-interactivity'
    }
    catch { $di = $false }
    return [pscustomobject]@{ Available = $true; Reason = 'ok'; DisableInteractivity = $di }
}

function Get-WcWingetUpgradeList {
    <# I/O: runs the listing and parses it. Status Unavailable carries the reason (not-found, system-context). #>
    [CmdletBinding()]
    param($Capability = $null)
    if ($null -eq $Capability) { $Capability = Get-WcWingetCapability }
    if (-not $Capability.Available) {
        return [pscustomobject]@{ Status = 'Unavailable'; Reason = $Capability.Reason; Detail = ''; Rows = @(); Unparsed = 0 }
    }
    try {
        $run = Invoke-WcWinget -ArgumentList (Get-WcWingetListArgument -DisableInteractivity $Capability.DisableInteractivity) -TimeoutSeconds $script:WcWingetListTimeoutSec
    }
    catch {
        return [pscustomobject]@{ Status = 'Failed'; Reason = 'run-error'; Detail = $_.Exception.Message; Rows = @(); Unparsed = 0 }
    }
    return (ConvertTo-WcWingetListResult -ExitCode $run.ExitCode -Text $run.Text -TimedOut $run.TimedOut)
}

# --------------------------------------------------------------- store/appx --

function ConvertTo-WcAppxProblemRow {
    <# Pure: Get-AppxPackage objects -> rows for packages whose Status is not 'Ok' (frameworks included: they break apps too). #>
    [CmdletBinding()]
    param([object[]] $Package = @())
    $out = @()
    foreach ($p in @($Package)) {
        if ($null -eq $p) { continue }
        $status = [string](Get-WcAppsValue $p 'Status')
        if (-not $status -or $status -eq 'Ok') { continue }
        $out += [pscustomobject]@{
            Name            = [string](Get-WcAppsValue $p 'Name')
            Version         = [string](Get-WcAppsValue $p 'Version')
            Status          = $status
            PackageFullName = [string](Get-WcAppsValue $p 'PackageFullName')
        }
    }
    return @($out | Sort-Object -Property Name)
}

function Get-WcAppxPackageRaw {
    <# Thin I/O: current user's packages (Get-AppxPackage). Throws when the Appx module is unusable. #>
    [CmdletBinding()]
    param([string] $Name)
    if (-not (Get-Command -Name 'Get-AppxPackage' -ErrorAction SilentlyContinue)) { throw 'Get-AppxPackage is not available in this PowerShell session.' }
    if ($Name) { return @(Get-AppxPackage -Name $Name -ErrorAction Stop) }
    return @(Get-AppxPackage -ErrorAction Stop)
}

function Test-WcAppxResetAvailable {
    <# Thin I/O: Reset-AppxPackage exists (Windows 10 2004 / build 19041+ and 11). #>
    return [bool](Get-Command -Name 'Reset-AppxPackage' -ErrorAction SilentlyContinue)
}

function Invoke-WcAppxReset {
    <# Thin I/O: the only call that resets a Store app. Mocked in tests. #>
    param([Parameter(Mandatory = $true)][string] $PackageFullName)
    $cmd = Get-Command -Name ('Reset-' + 'AppxPackage') -ErrorAction Stop
    & $cmd -Package $PackageFullName -ErrorAction Stop
}

# ---------------------------------------------------------------- page data --

function New-WcPageSection {
    param([string] $Id, [string] $TitleKey, [string] $NoteKey = $null, [object[]] $Rows = @(), [string] $Severity = 'Info')
    return [pscustomobject]@{ Id = $Id; TitleKey = $TitleKey; NoteKey = $NoteKey; Rows = @($Rows); Severity = $Severity }
}

function Get-WcAppsPageData {
    <#
        Page 'apps' (docs/CONTRATO-ACOES.md section 6). Read-only; never throws: a failing
        section is listed in Errors and keeps an empty row list.
    #>
    [CmdletBinding()]
    param([hashtable] $Context)
    $sections = @()
    $errors = @()

    $installed = @()
    try {
        $installed = @(ConvertTo-WcInstalledProgram -Entry (Get-WcUninstallEntry) -PathExists { param($p) Test-WcAppsFileExists -Path $p })
    }
    catch { $errors += ('installed: ' + $_.Exception.Message) }
    $sections += New-WcPageSection -Id 'installed' -TitleKey 'section.apps.installed' -NoteKey 'section.apps.installed.note' -Rows $installed

    $broken = @(ConvertTo-WcBrokenUninstallRow -Program $installed)
    $sev = 'Info'
    if ($broken.Count -gt 0) { $sev = 'Warning' }
    $sections += New-WcPageSection -Id 'broken-uninstall' -TitleKey 'section.apps.broken-uninstall' -NoteKey 'section.apps.broken-uninstall.note' -Rows $broken -Severity $sev

    $wg = $null
    try { $wg = Get-WcWingetUpgradeList }
    catch { $errors += ('winget-updates: ' + $_.Exception.Message) }
    if ($null -ne $wg) {
        $note = 'section.apps.winget-updates.note'
        $rows = @($wg.Rows)
        $sev = 'Info'
        switch ($wg.Status) {
            'Ok' { if ($wg.Unparsed -gt 0) { $note = 'section.apps.winget-updates.note.partial' } }
            'NoUpdates' { $note = 'section.apps.winget-updates.note.none' }
            'Unavailable' { $note = 'section.apps.winget-updates.note.' + $wg.Reason }
            default {
                $note = 'section.apps.winget-updates.note.failed'
                $sev = 'Warning'
                $rows = @([pscustomobject]@{ Status = $wg.Reason; Detail = $wg.Detail })
            }
        }
        $sections += New-WcPageSection -Id 'winget-updates' -TitleKey 'section.apps.winget-updates' -NoteKey $note -Rows $rows -Severity $sev
    }
    else { $sections += New-WcPageSection -Id 'winget-updates' -TitleKey 'section.apps.winget-updates' -NoteKey 'section.apps.winget-updates.note.failed' -Severity 'Warning' }

    $store = @()
    try { $store = @(ConvertTo-WcAppxProblemRow -Package (Get-WcAppxPackageRaw)) }
    catch { $errors += ('store-problems: ' + $_.Exception.Message) }
    $sev = 'Info'
    if ($store.Count -gt 0) { $sev = 'Warning' }
    $sections += New-WcPageSection -Id 'store-problems' -TitleKey 'section.apps.store-problems' -NoteKey 'section.apps.store-problems.note' -Rows $store -Severity $sev

    return [pscustomobject]@{ PageId = 'apps'; Sections = @($sections); Findings = @(); Errors = @($errors) }
}

# ------------------------------------------------------------------ actions --

function Invoke-WcWingetUpgradeAction {
    <#
        Preview (default): lists the selected ids and the exact command per id; runs nothing.
        -Execute: re-lists available upgrades, skips ids that are not in that list, then runs
        winget once per id and maps the documented exit codes. Throws only when nothing succeeded.
    #>
    [CmdletBinding()]
    param($Context, [switch] $Execute)
    $ids = @(ConvertTo-WcPackageSelection -InputObject (Get-WcAppsSelection -Context $Context -ActionId 'apps.winget-upgrade') -Kind WingetId)
    if (-not $Execute) {
        if ($ids.Count -eq 0) { return (New-WcActionResult -Summary 'No package selected. Select packages in the winget updates list; WinCare never upgrades all packages.') }
        $items = @()
        foreach ($id in $ids) {
            $items += [pscustomobject]@{ PackageId = $id; Command = ('winget ' + ((Get-WcWingetUpgradeArgument -Id $id) -join ' ')) }
        }
        return (New-WcActionResult -Summary ('Would upgrade {0} selected package(s) with winget, one at a time (silent; accepts the source and package license agreements). Never uses --all; cannot be undone by WinCare.' -f $ids.Count) -Items $items)
    }
    if ($ids.Count -eq 0) { throw 'No package selected for apps.winget-upgrade.' }
    $cap = Get-WcWingetCapability
    if (-not $cap.Available) { throw ('winget unavailable: {0}.' -f $cap.Reason) }
    $list = Get-WcWingetUpgradeList -Capability $cap
    if ($list.Status -eq 'Failed') { throw ('winget upgrade listing failed: {0} {1}' -f $list.Reason, $list.Detail) }
    $available = @{}
    foreach ($r in @($list.Rows)) { $available[([string]$r.PackageId).ToLowerInvariant()] = $r }
    $items = @()
    $ok = 0; $failed = 0
    $outText = New-Object System.Text.StringBuilder
    foreach ($id in $ids) {
        if (-not $available.ContainsKey($id.ToLowerInvariant())) {
            $items += [pscustomobject]@{ PackageId = $id; Status = 'Skipped'; Reason = 'not-in-upgrade-list'; ExitCode = $null }
            continue
        }
        $run = Invoke-WcWinget -ArgumentList (Get-WcWingetUpgradeArgument -Id $id -DisableInteractivity $cap.DisableInteractivity) -TimeoutSeconds $script:WcWingetUpgradeTimeoutSec
        [void]$outText.AppendLine(('== {0}' -f $id)).AppendLine([string]$run.Text)
        if ($run.TimedOut) {
            $items += [pscustomobject]@{ PackageId = $id; Status = 'Failed'; Reason = 'timeout'; ExitCode = $null }
            $failed++
            continue
        }
        $res = ConvertTo-WcWingetExitResult -ExitCode $run.ExitCode
        $items += [pscustomobject]@{ PackageId = $id; Status = $res.Status; Reason = $res.Reason; ExitCode = $res.Hex }
        if ($res.Status -like 'Succeeded*' -or $res.Status -eq 'NoUpdate') { $ok++ } else { $failed++ }
        Write-WcLog -Level Audit -Category 'Apps' -Message ('winget upgrade {0}: {1} ({2})' -f $id, $res.Status, $res.Hex) | Out-Null
    }
    $summary = ('winget: {0} upgraded/up to date, {1} failed, {2} skipped (not in the current upgrade list).' -f $ok, $failed, @($items | Where-Object { $_.Status -eq 'Skipped' }).Count)
    if (@($items | Where-Object { $_.Status -eq 'SucceededRebootRequired' }).Count -gt 0) { $summary += ' Restart Windows to finish (WinCare does not restart).' }
    if ($ok -eq 0 -and $failed -gt 0) { throw $summary }
    return (New-WcActionResult -Summary $summary -Items $items -Output $outText.ToString())
}

function Invoke-WcStoreResetAction {
    <#
        Preview: what would be reset and that its local data is deleted. -Execute: exactly one
        selected PackageFullName of the CURRENT user, not a framework, Reset-AppxPackage present.
    #>
    [CmdletBinding()]
    param($Context, [switch] $Execute)
    $sel = @(ConvertTo-WcPackageSelection -InputObject (Get-WcAppsSelection -Context $Context -ActionId 'apps.store-reset') -Kind AppxFullName -Max 1)
    $available = Test-WcAppxResetAvailable
    if (-not $Execute) {
        if (-not $available) { return (New-WcActionResult -Summary 'Unavailable: Reset-AppxPackage is not present (requires Windows 10 2004 / build 19041 or Windows 11).') }
        if ($sel.Count -eq 0) { return (New-WcActionResult -Summary 'No Store app selected. Select one app in the Store apps list.') }
        return (New-WcActionResult -Summary ('Would reset {0}: the app returns to its first-run state and ALL its local data (settings, sign-in, cached files) is deleted. Cannot be undone.' -f $sel[0]) -Items @(
                [pscustomobject]@{ PackageFullName = $sel[0]; Command = 'Reset-AppxPackage -Package <selected>'; DeletesLocalData = $true }))
    }
    if (-not $available) { throw 'Reset-AppxPackage is not available on this Windows version (needs Windows 10 2004+ or Windows 11).' }
    if ($sel.Count -ne 1) { throw 'Select exactly one Store app for apps.store-reset.' }
    $full = $sel[0]
    $name = $full.Substring(0, $full.IndexOf('_'))
    $match = @(Get-WcAppxPackageRaw -Name $name | Where-Object { [string](Get-WcAppsValue $_ 'PackageFullName') -eq $full })
    if ($match.Count -eq 0) { throw "Package not installed for the current user: $full" }
    if ([bool](Get-WcAppsValue $match[0] 'IsFramework')) { throw "Refusing to reset a framework package: $full" }
    Write-WcLog -Level Audit -Category 'Apps' -Message ('Reset-AppxPackage {0}' -f $full) | Out-Null
    Invoke-WcAppxReset -PackageFullName $full
    return (New-WcActionResult -Summary ('Reset {0}. Its local data was deleted; open the app to set it up again.' -f $name) -Items @(
            [pscustomobject]@{ PackageFullName = $full; Status = 'Reset' }))
}

function Open-WcAppsSettings {
    <# Thin I/O: opens Settings > Apps. Fixed URI; nothing from the selection is passed to it. #>
    Start-Process -FilePath 'ms-settings:appsfeatures'
}

function Invoke-WcAppsOpenRepairAction {
    <#
        Opens ms-settings:appsfeatures. The selected app name (optional) is only echoed in the
        summary so the user knows what to look for; Settings has no documented deep link to a
        specific Win32 app. Never runs an uninstaller or a repair by itself.
    #>
    [CmdletBinding()]
    param($Context, [switch] $Execute)
    $label = ''
    $sel = @(Get-WcAppsSelection -Context $Context -ActionId 'apps.open-repair')
    if ($sel.Count -gt 0) {
        $label = [regex]::Replace([string]$sel[0], '[\x00-\x1F\x7F]', '')
        if ($label.Length -gt 128) { $label = $label.Substring(0, 128) }
    }
    $hint = ''
    if ($label) { $hint = " Look for '$label' in the list." }
    if (-not $Execute) {
        return (New-WcActionResult -Summary ('Would open Settings > Apps (ms-settings:appsfeatures).{0} Choose Modify/Repair or Advanced options > Repair there; WinCare never runs uninstallers or repairs.' -f $hint))
    }
    Write-WcLog -Level Audit -Category 'Apps' -Message 'Opening ms-settings:appsfeatures for a user-driven repair.' | Out-Null
    Open-WcAppsSettings
    return (New-WcActionResult -Summary ('Opened Settings > Apps.{0} Use Modify/Repair (or Advanced options > Repair/Reset for Store apps).' -f $hint) -Items @(
            [pscustomobject]@{ Item = 'Opened'; Value = 'ms-settings:appsfeatures' }))
}

function Register-WcAppsHandler {
    <# Called lazily by Core (Initialize-WcActionHandlers). #>
    [CmdletBinding()]
    param()
    Register-WcActionHandler -Name 'Apps-WingetUpgrade' -Preview { param($Context) Invoke-WcWingetUpgradeAction -Context $Context } -Execute { param($Context) Invoke-WcWingetUpgradeAction -Context $Context -Execute }
    Register-WcActionHandler -Name 'Apps-StoreReset' -Preview { param($Context) Invoke-WcStoreResetAction -Context $Context } -Execute { param($Context) Invoke-WcStoreResetAction -Context $Context -Execute }
    Register-WcActionHandler -Name 'Apps-OpenRepair' -Preview { param($Context) Invoke-WcAppsOpenRepairAction -Context $Context } -Execute { param($Context) Invoke-WcAppsOpenRepairAction -Context $Context -Execute }
}

Export-ModuleMember -Function @(
    'Get-WcAppsPageData', 'Register-WcAppsHandler',
    'Get-WcAppsSelection', 'Test-WcWingetPackageId', 'Test-WcAppxPackageFullName', 'ConvertTo-WcPackageSelection',
    'ConvertTo-WcUninstallExecutable', 'ConvertTo-WcInstallDate', 'ConvertTo-WcInstalledProgram', 'ConvertTo-WcBrokenUninstallRow',
    'ConvertFrom-WcNativeOutputBytes', 'ConvertFrom-WcWingetTable', 'Test-WcWingetFlagSupported', 'ConvertTo-WcWingetExitResult',
    'Get-WcWingetListArgument', 'Get-WcWingetUpgradeArgument', 'ConvertTo-WcWingetListResult', 'ConvertTo-WcAppxProblemRow',
    'Get-WcUninstallEntry', 'Get-WcWingetPath', 'Get-WcWingetCapability', 'Get-WcWingetUpgradeList', 'Invoke-WcWinget',
    'Invoke-WcWingetUpgradeAction', 'Invoke-WcStoreResetAction', 'Invoke-WcAppsOpenRepairAction'
)

# Handlers are NOT registered at import time: Core's Initialize-WcActionHandlers
# (called by New-WcPlan) invokes the exported Register-WcAppsHandler.
