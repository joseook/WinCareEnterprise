#Requires -Version 5.1
<#
    WinCare.Security - read-only detection of corporate management and of the
    state of fundamental protections. WinCare never changes any of these; the
    result only restricts which actions are offered (see Core policy engine).

    Management signals (any one => IsManaged):
      DomainJoined   Win32_ComputerSystem.PartOfDomain
      AzureAdJoined  HKLM\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo has subkeys
      MdmEnrolled    HKLM\SOFTWARE\Microsoft\Enrollments\<guid> with a non-empty ProviderID
      PolicyKeys     HKLM\SOFTWARE\Policies\Microsoft has subkeys (GPO/MDM-written policy)
    These are signals, not proof. Absence of signals does not prove the device is
    unmanaged - which is why the Corporativo profile blocks sensitive actions anyway.
#>

function ConvertTo-WcManagementState {
    [CmdletBinding()]
    param([hashtable] $Signals = @{})
    $found = @()
    foreach ($k in @('DomainJoined', 'AzureAdJoined', 'MdmEnrolled', 'PolicyKeys')) {
        if ($Signals[$k]) { $found += $k }
    }
    return [pscustomobject]@{
        IsManaged  = ($found.Count -gt 0)
        Signals    = $found
        Domain     = $Signals['Domain']
        MdmProvider = $Signals['MdmProvider']
    }
}

function Get-WcManagementState {
    [CmdletBinding()]
    param()
    $signals = @{ DomainJoined = $false; AzureAdJoined = $false; MdmEnrolled = $false; PolicyKeys = $false; Domain = $null; MdmProvider = $null }
    $cs = Get-WcCimData -ClassName 'Win32_ComputerSystem' | Select-Object -First 1
    if ($cs -and (Get-WcObjectValue $cs 'PartOfDomain')) {
        $signals.DomainJoined = $true
        $signals.Domain = [string](Get-WcObjectValue $cs 'Domain')
    }
    $join = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
    if ((Test-Path -LiteralPath $join) -and @(Get-ChildItem -LiteralPath $join -ErrorAction SilentlyContinue).Count -gt 0) { $signals.AzureAdJoined = $true }
    $enroll = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path -LiteralPath $enroll) {
        foreach ($k in @(Get-ChildItem -LiteralPath $enroll -ErrorAction SilentlyContinue)) {
            $prov = $null
            try { $prov = (Get-ItemProperty -LiteralPath $k.PSPath -Name 'ProviderID' -ErrorAction Stop).ProviderID } catch { $prov = $null }
            if ($prov) { $signals.MdmEnrolled = $true; $signals.MdmProvider = [string]$prov; break }
        }
    }
    $pol = 'HKLM:\SOFTWARE\Policies\Microsoft'
    if ((Test-Path -LiteralPath $pol) -and @(Get-ChildItem -LiteralPath $pol -ErrorAction SilentlyContinue).Count -gt 0) { $signals.PolicyKeys = $true }
    return (ConvertTo-WcManagementState -Signals $signals)
}

function ConvertTo-WcProtectionState {
    <# Each field is $true/$false, or $null when it could not be determined. #>
    [CmdletBinding()]
    param($DefenderStatus, [object[]] $FirewallProfile)
    $defender = $null; $realtime = $null
    if ($null -ne $DefenderStatus) {
        $defender = [bool](Get-WcObjectValue $DefenderStatus 'AMServiceEnabled')
        $realtime = [bool](Get-WcObjectValue $DefenderStatus 'RealTimeProtectionEnabled')
    }
    $fwAll = $null
    $fw = @($FirewallProfile | Where-Object { $null -ne $_ })
    if ($fw.Count -gt 0) {
        $fwAll = $true
        foreach ($p in $fw) {
            $enabled = Get-WcObjectValue $p 'Enabled'
            if (-not ($enabled -eq $true -or [string]$enabled -eq 'True' -or [string]$enabled -eq '1')) { $fwAll = $false }
        }
    }
    return [pscustomobject]@{
        DefenderService     = $defender
        DefenderRealTime    = $realtime
        FirewallAllProfiles = $fwAll
    }
}

function Get-WcProtectionState {
    [CmdletBinding()]
    param()
    $def = $null; $fw = $null
    if (Get-Command -Name 'Get-MpComputerStatus' -ErrorAction SilentlyContinue) {
        try { $def = Get-MpComputerStatus -ErrorAction Stop } catch { Write-WcLog -Level Info -Category 'Security' -Message ('Defender status unavailable: ' + $_.Exception.Message) | Out-Null }
    }
    if (Get-Command -Name 'Get-NetFirewallProfile' -ErrorAction SilentlyContinue) {
        try { $fw = @(Get-NetFirewallProfile -ErrorAction Stop) } catch { Write-WcLog -Level Info -Category 'Security' -Message ('Firewall status unavailable: ' + $_.Exception.Message) | Out-Null }
    }
    return (ConvertTo-WcProtectionState -DefenderStatus $def -FirewallProfile $fw)
}

Export-ModuleMember -Function @('ConvertTo-WcManagementState', 'Get-WcManagementState', 'ConvertTo-WcProtectionState', 'Get-WcProtectionState')
