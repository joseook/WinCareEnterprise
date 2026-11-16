#Requires -Version 5.1
<#
    WinCare.Integrity - official Windows integrity tools (F3, docs/CONTRATO-ACOES.md).

      integrity.sfc-verify          sfc.exe /verifyonly                              (read-only)
      integrity.sfc-scannow         sfc.exe /scannow                                 (Medium, irreversible)
      integrity.dism-checkhealth    Dism.exe /Online /Cleanup-Image /CheckHealth     (read-only)
      integrity.dism-scanhealth     Dism.exe /Online /Cleanup-Image /ScanHealth      (read-only)
      integrity.dism-restorehealth  Dism.exe /Online /Cleanup-Image /RestoreHealth   (Medium, irreversible)
      integrity.chkdsk-scan         chkdsk.exe <system drive> /scan                  (Low, online scan)

    Execution rules: absolute path under %SystemRoot%\System32 (Sysnative from a 32-bit
    host), fixed argument arrays, validated drive letter, stdout/stderr and exit code
    captured, progress streamed to Write-WcLog (percent lines throttled to 10% steps).

    Output encoding (ASSUMPTION, unverified on real Windows): sfc.exe is widely reported
    to write UTF-16LE when its output is redirected; DISM and chkdsk write in the OEM code
    page. The first chunk of stdout is inspected (BOM or NUL-byte ratio) to pick UTF-16LE,
    otherwise the OEM code page is used. Stray NUL characters are always removed.

    Result parsing: exit codes first (documented ones only). English phrases are a
    fallback and are English-only; on localized Windows (e.g. pt-BR) unmatched output
    yields 'Unknown' instead of a guess.
#>

$script:WcIntegrityCommands = @{
    'integrity.sfc-verify'         = @{ Tool = 'sfc'; Exe = 'sfc.exe'; Args = @('/verifyonly'); Modifies = $false }
    'integrity.sfc-scannow'        = @{ Tool = 'sfc'; Exe = 'sfc.exe'; Args = @('/scannow'); Modifies = $true }
    'integrity.dism-checkhealth'   = @{ Tool = 'dism'; Exe = 'Dism.exe'; Args = @('/Online', '/Cleanup-Image', '/CheckHealth'); Modifies = $false }
    'integrity.dism-scanhealth'    = @{ Tool = 'dism'; Exe = 'Dism.exe'; Args = @('/Online', '/Cleanup-Image', '/ScanHealth'); Modifies = $false }
    'integrity.dism-restorehealth' = @{ Tool = 'dism'; Exe = 'Dism.exe'; Args = @('/Online', '/Cleanup-Image', '/RestoreHealth'); Modifies = $true }
    'integrity.chkdsk-scan'        = @{ Tool = 'chkdsk'; Exe = 'chkdsk.exe'; Args = @('{SystemDrive}', '/scan'); Modifies = $false }
}

# ------------------------------------------------------------ commands --

function Get-WcNativeToolPath {
    <# Absolute path of an in-box tool. 32-bit host on 64-bit Windows -> Sysnative (avoids WOW64 redirection). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z0-9]+\.exe$')][string] $Name)
    if (-not $env:SystemRoot) { throw 'SystemRoot is not defined.' }
    $dir = 'System32'
    if ([System.Environment]::Is64BitOperatingSystem -and -not [System.Environment]::Is64BitProcess) { $dir = 'Sysnative' }
    return [System.IO.Path]::Combine($env:SystemRoot, $dir, $Name)
}

function Get-WcIntegrityCommand {
    <# Fixed command for a catalog id. Nothing here comes from free text. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Id)
    if (-not $script:WcIntegrityCommands.ContainsKey($Id)) { throw "Unknown integrity action: $Id" }
    $def = $script:WcIntegrityCommands[$Id]
    $argList = @()
    foreach ($a in $def.Args) {
        if ($a -eq '{SystemDrive}') {
            $drive = $env:SystemDrive
            if (-not $drive) { $drive = 'C:' }
            if (-not (Test-WcDriveLetter -Value $drive)) { throw "Invalid system drive: '$drive'" }
            $argList += $drive.ToUpperInvariant()
        }
        else { $argList += $a }
    }
    $path = Get-WcNativeToolPath -Name $def.Exe
    return [pscustomobject]@{
        Id = $Id; Tool = $def.Tool; FilePath = $path; Arguments = $argList; Modifies = $def.Modifies
        CommandLine = ('{0} {1}' -f $path, ($argList -join ' '))
    }
}

# ------------------------------------------------------ output decoding --

function Get-WcOemEncoding {
    try { return [System.Text.Encoding]::GetEncoding([System.Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage) }
    catch { return [System.Text.Encoding]::UTF8 }
}

function Get-WcOutputEncoding {
    <# Pure: UTF-16LE if the sample has a FF FE BOM or NUL in >= 40% of odd bytes; otherwise OEM. #>
    [CmdletBinding()]
    param([byte[]] $Sample, [ValidateSet('Auto', 'Unicode', 'Oem')][string] $Preferred = 'Auto')
    if ($Preferred -eq 'Unicode') { return [System.Text.Encoding]::Unicode }
    if ($Preferred -eq 'Oem') { return (Get-WcOemEncoding) }
    if ($null -ne $Sample -and $Sample.Length -ge 2) {
        if ($Sample[0] -eq 0xFF -and $Sample[1] -eq 0xFE) { return [System.Text.Encoding]::Unicode }
        $odd = 0; $nul = 0
        for ($i = 1; $i -lt $Sample.Length; $i += 2) { $odd++; if ($Sample[$i] -eq 0) { $nul++ } }
        if ($odd -gt 0 -and ($nul / $odd) -ge 0.4) { return [System.Text.Encoding]::Unicode }
    }
    return (Get-WcOemEncoding)
}

function New-WcOutputState {
    param([ValidateSet('Auto', 'Unicode', 'Oem')][string] $Encoding = 'Auto')
    return @{ Preferred = $Encoding; Encoding = $null; Decoder = $null; Pending = ''; Lines = (New-Object System.Collections.Generic.List[string]); LastLine = $null; LastBucket = -1 }
}

function Select-WcOutputLine {
    <# Pure-ish: decides whether a line is kept/logged. Percent lines only every 10%, no consecutive duplicates. #>
    param([hashtable] $State, [string] $Line)
    $t = $Line.Trim()
    if (-not $t -or $t -eq $State.LastLine) { return $false }
    $m = [regex]::Match($t, '(\d{1,3})(?:[\.,]\d+)?\s*%')
    if ($m.Success) {
        $bucket = [int][math]::Floor([int]$m.Groups[1].Value / 10)
        if ($bucket -eq $State.LastBucket) { return $false }
        $State.LastBucket = $bucket
    }
    $State.LastLine = $t
    return $true
}

function Add-WcOutputBytes {
    <# Decodes a stdout chunk (stateful, handles split UTF-16 code units). Returns new kept lines. #>
    param([hashtable] $State, [byte[]] $Buffer, [int] $Count)
    if ($Count -le 0) { return }
    if ($null -eq $State.Decoder) {
        $sample = New-Object byte[] $Count
        [Array]::Copy($Buffer, $sample, $Count)
        $State.Encoding = Get-WcOutputEncoding -Sample $sample -Preferred $State.Preferred
        $State.Decoder = $State.Encoding.GetDecoder()
    }
    $chars = New-Object char[] ($State.Encoding.GetMaxCharCount($Count))
    $n = $State.Decoder.GetChars($Buffer, 0, $Count, $chars, 0)
    return (Add-WcOutputText -State $State -Text (New-Object string($chars, 0, $n)))
}

function Add-WcOutputText {
    param([hashtable] $State, [string] $Text, [switch] $Final)
    $all = ($State.Pending + $Text).Replace([string][char]0, '')
    $parts = [regex]::Split($all, '\r\n|\r|\n')
    $State.Pending = ''
    $last = $parts.Count - 1
    if (-not $Final) { $State.Pending = $parts[$last]; $last-- }
    $kept = @()
    for ($i = 0; $i -le $last; $i++) {
        if (Select-WcOutputLine -State $State -Line $parts[$i]) { $State.Lines.Add($parts[$i].Trim()); $kept += $parts[$i].Trim() }
    }
    return $kept
}

function Invoke-WcNativeCommand {
    <#
        Runs an in-box tool and streams its stdout to Write-WcLog. Mocked in tests.
        Only absolute paths under %SystemRoot%\System32 (or Sysnative); arguments must
        be simple tokens (letters, digits, : / - .).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $FilePath,
        [string[]] $ArgumentList = @(),
        [ValidateSet('Auto', 'Unicode', 'Oem')][string] $Encoding = 'Auto',
        [string] $LogCategory = 'Native'
    )
    $sysRoot = $env:SystemRoot
    if (-not $sysRoot -or -not [System.IO.Path]::IsPathRooted($FilePath) -or
        -not (Test-WcPathWithin -Path $FilePath -AllowedRoots @([System.IO.Path]::Combine($sysRoot, 'System32'), [System.IO.Path]::Combine($sysRoot, 'Sysnative')))) {
        throw "Refusing to run '$FilePath': only absolute paths under %SystemRoot%\System32 are allowed."
    }
    foreach ($a in $ArgumentList) { if ($a -notmatch '^[A-Za-z0-9:/\-\.]+$') { throw "Refusing argument '$a'." } }
    if (-not [System.IO.File]::Exists($FilePath)) { throw "Executable not found: $FilePath" }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($ArgumentList -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    Write-WcLog -Level Audit -Category $LogCategory -Message ('Running: {0} {1}' -f $FilePath, $psi.Arguments) | Out-Null
    try {
        [void]$proc.Start()
        $errTask = $proc.StandardError.ReadToEndAsync()
        $state = New-WcOutputState -Encoding $Encoding
        $stream = $proc.StandardOutput.BaseStream
        $buf = New-Object byte[] 4096
        while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
            foreach ($l in (Add-WcOutputBytes -State $state -Buffer $buf -Count $n)) { Write-WcLog -Category $LogCategory -Message $l | Out-Null }
        }
        foreach ($l in (Add-WcOutputText -State $state -Text '' -Final)) { Write-WcLog -Category $LogCategory -Message $l | Out-Null }
        $proc.WaitForExit()
        $stderr = ([string]$errTask.Result).Replace([string][char]0, '').Trim()
        $encName = $null
        if ($state.Encoding) { $encName = $state.Encoding.WebName }
        Write-WcLog -Level Audit -Category $LogCategory -Message ('Exit code {0}: {1}' -f $proc.ExitCode, $FilePath) | Out-Null
        return [pscustomobject]@{ ExitCode = $proc.ExitCode; StdOut = ($state.Lines -join "`r`n"); StdErr = $stderr; Encoding = $encName }
    }
    finally { $proc.Dispose() }
}

# --------------------------------------------------------------- parsing --

function ConvertTo-WcIntegrityResult {
    <#
        Pure. Status: Healthy | Repaired | CorruptionFound | Failed | Unknown.
        MatchedBy: ExitCode | Phrase | None. Phrases are English-only (unverified on
        localized Windows) and only used where the exit code is not conclusive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sfc', 'dism', 'chkdsk')][string] $Tool,
        $ExitCode,
        [string] $Output = ''
    )
    $status = 'Unknown'; $by = 'None'; $detail = 'Output not recognized (phrase matching is English-only); review the output.'
    $text = [string]$Output
    $phrase = {
        param([object[]] $Rules)
        foreach ($r in $Rules) { if ($text.IndexOf($r[0], [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $r } }
        return $null
    }
    if ($null -eq $ExitCode) { $status = 'Failed'; $by = 'ExitCode'; $detail = 'The process did not run (no exit code).' }
    elseif ([int64]$ExitCode -eq 740) { $status = 'Failed'; $by = 'ExitCode'; $detail = 'Elevation required (exit code 740).' }
    elseif ($Tool -eq 'dism') {
        $code = [uint32]([int64]$ExitCode -band 0xFFFFFFFFL)
        if ($code -ne 0) {
            $known = @{ 87L = 'invalid parameter'; 0x800F081FL = 'source files could not be found'; 0x800F0906L = 'source files could not be downloaded' }
            $why = 'DISM error'
            if ($known.ContainsKey([int64]$code)) { $why = $known[[int64]$code] }
            $status = 'Failed'; $by = 'ExitCode'; $detail = ('{0} (exit code 0x{1:X8}).' -f $why, $code)
        }
        else {
            $m = & $phrase @(
                , @('component store corruption was repaired', 'Repaired', 'Component store corruption was repaired.')
                , @('No component store corruption detected', 'Healthy', 'No component store corruption detected.')
                , @('component store cannot be repaired', 'CorruptionFound', 'Component store is corrupted and cannot be repaired.')
                , @('component store is repairable', 'CorruptionFound', 'Component store is repairable (run RestoreHealth).')
                , @('restore operation completed successfully', 'Healthy', 'Restore operation completed successfully.')
            )
            if ($m) { $status = $m[1]; $by = 'Phrase'; $detail = $m[2] }
            else { $detail = 'DISM succeeded (exit code 0) but the result phrase was not recognized (English-only).' }
        }
    }
    elseif ($Tool -eq 'sfc') {
        # sfc exit codes are not documented; phrases only.
        $m = & $phrase @(
            , @('did not find any integrity violations', 'Healthy', 'No integrity violations found.')
            , @('found corrupt files and successfully repaired them', 'Repaired', 'Corrupt files were found and repaired.')
            , @('unable to fix some of them', 'CorruptionFound', 'Corrupt files were found; some could not be repaired.')
            , @('found integrity violations', 'CorruptionFound', 'Integrity violations found.')
            , @('system repair pending', 'Failed', 'A system repair is pending; restart and run again.')
            , @('could not perform the requested operation', 'Failed', 'Windows Resource Protection could not perform the operation.')
            , @('must be an administrator', 'Failed', 'Administrator rights required.')
        )
        if ($m) { $status = $m[1]; $by = 'Phrase'; $detail = $m[2] }
        else { $detail = ('Output not recognized (exit code {0}; sfc exit codes are undocumented, phrase matching is English-only).' -f $ExitCode) }
    }
    else {
        # chkdsk exit codes (documented): 0 no errors, 1 errors fixed, 2 cleanup done/skipped, 3 not checked or not fixed.
        switch ([int64]$ExitCode) {
            0 { $status = 'Healthy'; $by = 'ExitCode'; $detail = 'No errors found (exit code 0).' }
            1 { $status = 'Repaired'; $by = 'ExitCode'; $detail = 'Errors were found and fixed (exit code 1).' }
            2 { $status = 'Healthy'; $by = 'ExitCode'; $detail = 'Disk cleanup performed or skipped; no errors reported (exit code 2).' }
            3 {
                $m = & $phrase @(
                    , @('found problems', 'CorruptionFound', 'File system problems found (exit code 3).')
                    , @('Access Denied', 'Failed', 'Access denied (exit code 3).')
                    , @('Cannot open volume', 'Failed', 'Cannot open volume (exit code 3).')
                )
                if ($m) { $status = $m[1]; $by = 'Phrase'; $detail = $m[2] }
                else { $detail = 'Exit code 3: errors found and not fixed, or the disk could not be checked; review the output.' }
            }
            default { $detail = ('Unexpected chkdsk exit code {0}.' -f $ExitCode) }
        }
    }
    return [pscustomobject]@{ Tool = $Tool; Status = $status; ExitCode = $ExitCode; Detail = $detail; MatchedBy = $by }
}

# --------------------------------------------------------------- actions --

function Invoke-WcIntegrityAction {
    <# Preview (default) returns the exact command; -Execute runs it and parses the result. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Id,
        [switch] $Execute
    )
    $cmd = Get-WcIntegrityCommand -Id $Id
    if (-not $Execute) {
        $item = [pscustomobject]@{ Command = $cmd.CommandLine; RequiresAdmin = $true; Modifies = $cmd.Modifies; Duration = 'unknown/varies' }
        return (New-WcActionResult -Summary ('Would run: {0} (requires administrator; duration unknown/varies).' -f $cmd.CommandLine) -Items @($item))
    }
    if (-not (Test-WcIsAdmin)) { throw "$Id requires an elevated (administrator) session." }
    $run = Invoke-WcNativeCommand -FilePath $cmd.FilePath -ArgumentList $cmd.Arguments -LogCategory 'Integrity'
    $output = [string]$run.StdOut
    if ($run.StdErr) { $output = $output + "`r`n" + $run.StdErr }
    $res = ConvertTo-WcIntegrityResult -Tool $cmd.Tool -ExitCode $run.ExitCode -Output $output
    Write-WcLog -Level Audit -Category 'Integrity' -Message ('{0}: {1} ({2})' -f $Id, $res.Status, $res.Detail) | Out-Null
    if ($res.Status -eq 'Failed') { throw ('{0} failed: {1}' -f $cmd.CommandLine, $res.Detail) }
    return (New-WcActionResult -Summary ('{0}: {1}. {2}' -f $cmd.Tool, $res.Status, $res.Detail) -Items @($res) -Output $output -ExitCode $run.ExitCode)
}

# -------------------------------------------------------------- handlers --

Register-WcActionHandler -Name 'Integrity-SfcVerify' -Preview { param($Context) Invoke-WcIntegrityAction -Id 'integrity.sfc-verify' } -Execute { param($Context) Invoke-WcIntegrityAction -Id 'integrity.sfc-verify' -Execute }
Register-WcActionHandler -Name 'Integrity-SfcScannow' -Preview { param($Context) Invoke-WcIntegrityAction -Id 'integrity.sfc-scannow' } -Execute { param($Context) Invoke-WcIntegrityAction -Id 'integrity.sfc-scannow' -Execute }
Register-WcActionHandler -Name 'Integrity-DismCheckHealth' -Preview { param($Context) Invoke-WcIntegrityAction -Id 'integrity.dism-checkhealth' } -Execute { param($Context) Invoke-WcIntegrityAction -Id 'integrity.dism-checkhealth' -Execute }
Register-WcActionHandler -Name 'Integrity-DismScanHealth' -Preview { param($Context) Invoke-WcIntegrityAction -Id 'integrity.dism-scanhealth' } -Execute { param($Context) Invoke-WcIntegrityAction -Id 'integrity.dism-scanhealth' -Execute }
Register-WcActionHandler -Name 'Integrity-DismRestoreHealth' -Preview { param($Context) Invoke-WcIntegrityAction -Id 'integrity.dism-restorehealth' } -Execute { param($Context) Invoke-WcIntegrityAction -Id 'integrity.dism-restorehealth' -Execute }
Register-WcActionHandler -Name 'Integrity-ChkdskScan' -Preview { param($Context) Invoke-WcIntegrityAction -Id 'integrity.chkdsk-scan' } -Execute { param($Context) Invoke-WcIntegrityAction -Id 'integrity.chkdsk-scan' -Execute }

Export-ModuleMember -Function @(
    'Get-WcNativeToolPath', 'Get-WcIntegrityCommand', 'Get-WcOutputEncoding', 'New-WcOutputState', 'Select-WcOutputLine',
    'Add-WcOutputBytes', 'Add-WcOutputText', 'Invoke-WcNativeCommand', 'ConvertTo-WcIntegrityResult', 'Invoke-WcIntegrityAction'
)
