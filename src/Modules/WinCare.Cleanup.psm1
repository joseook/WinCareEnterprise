#Requires -Version 5.1
<#
    WinCare.Cleanup - F3 maintenance actions for storage (docs/CONTRATO-ACOES.md).

      cleanup.user-temp        files older than 24h in %TEMP%              (Low, irreversible)
      cleanup.windows-temp     files older than 24h in %SystemRoot%\Temp   (Low, irreversible, admin)
      storage.optimize-analyze Optimize-Volume -Analyze on the system drive (read-only, admin)
      storage.optimize-retrim  Optimize-Volume -ReTrim, only on SSD         (Low, admin)

    Safety rules for temp cleanup:
      * only files (never folders) whose newest of LastWrite/Creation time is older than the cutoff;
      * the walk never descends into reparse points (junctions, symlinks) and skips reparse files;
      * every path is re-checked right before deletion: inside the root (Test-WcPathWithin)
        and no reparse point between the file and the root;
      * locked / denied files are skipped and counted; BytesFreed counts only files that
        are confirmed gone after the delete call.
    The cleanup of the recycle bin is intentionally NOT implemented (see docs).
#>

$script:WcTempMinAgeHours = 24

# ------------------------------------------------------------- temp roots --

function Test-WcTempRootSafe {
    <# Pure check: a cleanup root must be a non-root folder with a 'Temp' or 'Tmp' path segment. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Path)
    if (-not $Path) { return $false }
    $full = [System.IO.Path]::GetFullPath($Path)
    $trimmed = $full.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $root = ([string][System.IO.Path]::GetPathRoot($full)).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    if (-not $trimmed -or $trimmed -eq $root) { return $false }
    foreach ($seg in ($trimmed -split '[\\/]')) {
        if ($seg -match '^(?i)(temp|tmp)$') { return $true }
    }
    return $false
}

function Get-WcTempRoot {
    <# Resolves the cleanup root for a scope and refuses unsafe roots. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][ValidateSet('User', 'Windows')][string] $Scope)
    $root = $null
    if ($Scope -eq 'User') { $root = $env:TEMP }
    elseif ($env:SystemRoot) { $root = [System.IO.Path]::Combine($env:SystemRoot, 'Temp') }
    if (-not $root) { throw "Temp folder for scope '$Scope' is not defined." }
    $full = [System.IO.Path]::GetFullPath($root)
    if (-not (Test-WcTempRootSafe -Path $full)) { throw "Refusing unsafe cleanup root: $full" }
    if (-not [System.IO.Directory]::Exists($full)) { throw "Temp folder not found: $full" }
    if (([System.IO.File]::GetAttributes($full) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Temp folder is a reparse point; refusing: $full" }
    return $full
}

# -------------------------------------------------------------- scanning --

function Get-WcTempFileEntry {
    <# Walks Root without following reparse points. Returns raw entries + count of unreadable folders. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Root)
    $entries = New-Object System.Collections.Generic.List[object]
    $denied = 0
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $infos = $null
        try { $infos = (New-Object System.IO.DirectoryInfo($dir)).GetFileSystemInfos() }
        catch { $denied++; continue }
        foreach ($i in $infos) {
            $isReparse = (($i.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            if (($i.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                if (-not $isReparse) { $stack.Push($i.FullName) }
                continue
            }
            $len = 0L
            try { $len = [long]$i.Length } catch { $len = 0L }
            $entries.Add([pscustomobject]@{
                    Path = $i.FullName; Length = $len; LastWriteTimeUtc = $i.LastWriteTimeUtc
                    CreationTimeUtc = $i.CreationTimeUtc; IsReparsePoint = $isReparse
                })
        }
    }
    return [pscustomobject]@{ Entries = $entries.ToArray(); DeniedFolders = $denied }
}

function ConvertTo-WcTempCandidate {
    <# Pure filter: old enough, not a reparse point, strictly inside Root. #>
    [CmdletBinding()]
    param(
        [object[]] $Entry,
        [Parameter(Mandatory = $true)][string] $Root,
        [Parameter(Mandatory = $true)][datetime] $NowUtc,
        [int] $MinAgeHours = $script:WcTempMinAgeHours
    )
    $cutoff = $NowUtc.AddHours(-$MinAgeHours)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $result = @()
    foreach ($e in @($Entry)) {
        if ($null -eq $e -or $e.IsReparsePoint -or -not $e.Path) { continue }
        $full = [System.IO.Path]::GetFullPath([string]$e.Path)
        if ($full -eq $rootFull -or -not (Test-WcPathWithin -Path $full -AllowedRoots @($rootFull))) { continue }
        $newest = [datetime]$e.LastWriteTimeUtc
        if ($null -ne $e.CreationTimeUtc -and [datetime]$e.CreationTimeUtc -gt $newest) { $newest = [datetime]$e.CreationTimeUtc }
        if ($newest -gt $cutoff) { continue }
        $result += [pscustomobject]@{ File = $full; SizeBytes = [long]$e.Length; Modified = $newest.ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    }
    return $result
}

function Get-WcTempCleanupScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('User', 'Windows')][string] $Scope,
        [int] $MinAgeHours = $script:WcTempMinAgeHours
    )
    $root = Get-WcTempRoot -Scope $Scope
    $walk = Get-WcTempFileEntry -Root $root
    $cands = @(ConvertTo-WcTempCandidate -Entry $walk.Entries -Root $root -NowUtc (Get-Date).ToUniversalTime() -MinAgeHours $MinAgeHours)
    $total = 0L
    foreach ($c in $cands) { $total += $c.SizeBytes }
    return [pscustomobject]@{ Root = $root; Candidates = $cands; TotalBytes = $total; DeniedFolders = $walk.DeniedFolders }
}

# -------------------------------------------------------------- deletion --

function Test-WcSafeDeletePath {
    <# Re-checked right before deleting: inside Root and no reparse point from the file up to Root. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Root
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -eq $rootFull -or -not (Test-WcPathWithin -Path $full -AllowedRoots @($rootFull))) { return $false }
    $current = $full
    while ($current -and $current.Length -gt $rootFull.Length) {
        try {
            if (([System.IO.File]::GetAttributes($current) -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        catch { return $false }
        $current = [System.IO.Path]::GetDirectoryName($current)
    }
    return $true
}

function Remove-WcTempFile {
    <# Deletes one file. Returns Deleted | Gone | Locked | Denied | Failed. Never recursive, never a folder. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string] $Path)
    try {
        if (-not [System.IO.File]::Exists($Path)) { return 'Gone' }
        [System.IO.File]::Delete($Path)
    }
    catch [System.UnauthorizedAccessException] { return 'Denied' }
    catch [System.IO.IOException] { return 'Locked' }
    catch { return 'Failed' }
    if ([System.IO.File]::Exists($Path)) { return 'Locked' }
    return 'Deleted'
}

function Invoke-WcTempCleanup {
    <# Preview (default) or -Execute. Execute deletes only files from its own fresh scan. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('User', 'Windows')][string] $Scope,
        [switch] $Execute
    )
    if ($Execute -and $Scope -eq 'Windows' -and -not (Test-WcIsAdmin)) { throw 'cleanup.windows-temp requires an elevated (administrator) session.' }
    $scan = Get-WcTempCleanupScan -Scope $Scope
    $count = @($scan.Candidates).Count
    if (-not $Execute) {
        $summary = 'Would delete {0} file(s), {1} bytes, older than {2}h in {3} (unreadable folders: {4}).' -f $count, $scan.TotalBytes, $script:WcTempMinAgeHours, $scan.Root, $scan.DeniedFolders
        return (New-WcActionResult -Summary $summary -Items $scan.Candidates -BytesBefore $scan.TotalBytes)
    }
    Write-WcLog -Level Audit -Category 'Cleanup' -Message ('Deleting {0} file(s) in {1}.' -f $count, $scan.Root) | Out-Null
    $freed = 0L
    $tally = @{ Deleted = 0; Gone = 0; Locked = 0; Denied = 0; Failed = 0; Unsafe = 0 }
    $items = @()
    foreach ($c in $scan.Candidates) {
        $status = 'Unsafe'
        if (Test-WcSafeDeletePath -Path $c.File -Root $scan.Root) { $status = Remove-WcTempFile -Path $c.File }
        if (-not $tally.ContainsKey($status)) { $status = 'Failed' }
        $tally[$status]++
        if ($status -eq 'Deleted') { $freed += $c.SizeBytes }
        $items += [pscustomobject]@{ File = $c.File; SizeBytes = $c.SizeBytes; Status = $status }
    }
    $summary = 'Deleted {0} of {1} file(s), freed {2} bytes; skipped: {3} locked, {4} denied, {5} unsafe, {6} already gone, {7} failed.' -f $tally.Deleted, $count, $freed, $tally.Locked, $tally.Denied, $tally.Unsafe, $tally.Gone, $tally.Failed
    Write-WcLog -Level Audit -Category 'Cleanup' -Message $summary | Out-Null
    return (New-WcActionResult -Summary $summary -Items $items -BytesBefore $scan.TotalBytes -BytesAfter ($scan.TotalBytes - $freed) -BytesFreed $freed)
}

# ------------------------------------------------------- volume optimize --

function Get-WcOptimizeDriveLetter {
    <# System drive letter without colon (e.g. 'C'), validated. #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $d = $env:SystemDrive
    if (-not $d) { $d = 'C:' }
    if (-not (Test-WcDriveLetter -Value $d)) { throw "Invalid system drive: '$d'" }
    return $d.Substring(0, 1).ToUpperInvariant()
}

function Invoke-WcOptimizeVolume {
    <# Thin wrapper (mocked in tests). Captures the verbose stream as text lines. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[A-Za-z]$')][string] $DriveLetter,
        [Parameter(Mandatory = $true)][ValidateSet('Analyze', 'ReTrim')][string] $Mode
    )
    $params = @{ DriveLetter = $DriveLetter; Verbose = $true; ErrorAction = 'Stop' }
    $params[$Mode] = $true
    $records = Optimize-Volume @params 4>&1
    $lines = @()
    foreach ($r in @($records)) {
        if ($null -eq $r) { continue }
        if ($r -is [System.Management.Automation.VerboseRecord]) { $lines += $r.Message } else { $lines += [string]$r }
    }
    return , $lines
}

function Get-WcSystemVolumeMedia {
    $vol = @(Get-WcVolumeInfo | Where-Object { $_.IsSystem }) | Select-Object -First 1
    if (-not $vol) { return [pscustomobject]@{ Drive = $env:SystemDrive; MediaType = 'Unknown'; BusType = 'Unknown' } }
    return [pscustomobject]@{ Drive = $vol.Drive; MediaType = $vol.MediaType; BusType = $vol.BusType }
}

function Invoke-WcOptimizeAction {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Analyze', 'ReTrim')][string] $Mode,
        [switch] $Execute
    )
    $letter = Get-WcOptimizeDriveLetter
    $cmdText = 'Optimize-Volume -DriveLetter {0} -{1} -Verbose' -f $letter, $Mode
    $items = @()
    if ($Mode -eq 'ReTrim') {
        $media = Get-WcSystemVolumeMedia
        $items = @($media)
        if ($media.MediaType -ne 'SSD') {
            $msg = 'ReTrim refused: system volume media type is {0}; ReTrim runs only on SSD (defragmentation is out of scope).' -f $media.MediaType
            if ($Execute) { throw $msg }
            return (New-WcActionResult -Summary ('Would refuse. ' + $msg) -Items $items)
        }
    }
    if (-not $Execute) {
        return (New-WcActionResult -Summary ('Would run: {0} (requires administrator; duration unknown/varies).' -f $cmdText) -Items ($items + @([pscustomobject]@{ Command = $cmdText; RequiresAdmin = $true; Duration = 'unknown/varies' })))
    }
    if (-not (Test-WcIsAdmin)) { throw "$cmdText requires an elevated (administrator) session." }
    Write-WcLog -Level Audit -Category 'Storage' -Message ('Running: ' + $cmdText) | Out-Null
    $lines = @(Invoke-WcOptimizeVolume -DriveLetter $letter -Mode $Mode)
    foreach ($l in $lines) { if ($l) { Write-WcLog -Category 'Storage' -Message $l | Out-Null } }
    return (New-WcActionResult -Summary ('{0} completed ({1} output line(s)).' -f $cmdText, $lines.Count) -Items $items -Output ($lines -join "`r`n"))
}

# ------------------------------------------------------------- handlers --

Register-WcActionHandler -Name 'Cleanup-UserTemp' -Preview { param($Context) Invoke-WcTempCleanup -Scope User } -Execute { param($Context) Invoke-WcTempCleanup -Scope User -Execute }
Register-WcActionHandler -Name 'Cleanup-WindowsTemp' -Preview { param($Context) Invoke-WcTempCleanup -Scope Windows } -Execute { param($Context) Invoke-WcTempCleanup -Scope Windows -Execute }
Register-WcActionHandler -Name 'Storage-OptimizeAnalyze' -Preview { param($Context) Invoke-WcOptimizeAction -Mode Analyze } -Execute { param($Context) Invoke-WcOptimizeAction -Mode Analyze -Execute }
Register-WcActionHandler -Name 'Storage-OptimizeRetrim' -Preview { param($Context) Invoke-WcOptimizeAction -Mode ReTrim } -Execute { param($Context) Invoke-WcOptimizeAction -Mode ReTrim -Execute }

Export-ModuleMember -Function @(
    'Test-WcTempRootSafe', 'Get-WcTempRoot', 'Get-WcTempFileEntry', 'ConvertTo-WcTempCandidate', 'Get-WcTempCleanupScan',
    'Test-WcSafeDeletePath', 'Remove-WcTempFile', 'Invoke-WcTempCleanup',
    'Get-WcOptimizeDriveLetter', 'Invoke-WcOptimizeVolume', 'Get-WcSystemVolumeMedia', 'Invoke-WcOptimizeAction'
)
