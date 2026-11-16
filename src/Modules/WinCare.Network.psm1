#Requires -Version 5.1
<#
    WinCare.Network - page 'network' ("Rede"), phase F6.
    Page data contract: docs/CONTRATO-ACOES.md section 6.

    Page sections (Get-WcNetworkPageData, read-only):
      adapters      Get-NetAdapter + Get-NetIPConfiguration; fallback Win32_NetworkAdapterConfiguration (CIM)
      connectivity  gateway ping, DNS resolution, NCSI HTTP probe, HTTPS reachability (OK/Fail + latency)
      proxy         WinHTTP proxy ('netsh winhttp show proxy', parsed) + user WinINet proxy (registry)
      vpn           Get-VpnConnection (user + all-user) and VPN-looking adapters, information only

    Actions (Core/actions.d/f6-network.json):
      network.flush-dns      Clear-DnsClientCache, fallback ipconfig /flushdns   (Low)
      network.renew-ip       ipconfig /renew                                     (Medium, managed-blocked)
      network.reset-winsock  netsh winsock reset (needs a restart; never reboots) (High, admin, managed-blocked)

    Never touched: firewall rules, VPN profiles, proxy settings, DNS server settings, adapter
    enable state. Firewall and VPN are protected features in Core; catalog 'Touches' are honest.

    Connectivity probes send no identifying data: no cookies, no credentials (not even to a
    proxy: a 407 is reported as 'proxy-auth-required'), no custom headers, no User-Agent,
    no redirects followed. Endpoints:
      * DNS name:  www.msftconnecttest.com (Windows NCSI host)
      * HTTP:      http://www.msftconnecttest.com/connecttest.txt, body must be exactly
                   'Microsoft Connect Test' (the same probe Windows NCSI uses; a different body
                   means a captive portal or an intercepting proxy).
      * HTTPS:     https://www.microsoft.com/ (HEAD). www.msftconnecttest.com has no valid HTTPS
                   certificate (checked with curl on 2026-11-16), so it cannot be the HTTPS probe.

    'netsh winhttp show proxy' output is localized; the parser is language-independent:
    lines shaped '<label> : <value>' are taken by position (1st = proxy server, 2nd = bypass
    list); no such line = direct access. Proxy credentials (user:pass@) are always redacted.
#>

$script:WcNcsiHost = 'www.msftconnecttest.com'
$script:WcNcsiUri = 'http://www.msftconnecttest.com/connecttest.txt'
$script:WcNcsiBody = 'Microsoft Connect Test'
$script:WcHttpsProbeUri = 'https://www.microsoft.com/'
$script:WcProbeTimeoutMs = 5000
$script:WcVpnPattern = '(?i)\bVPN\b|TAP-Windows|Wintun|WireGuard|AnyConnect|GlobalProtect|PANGP|Fortinet|FortiClient|SonicWall|Juniper|Pulse Secure|Ivanti|Zscaler|OpenVPN|NordLynx|Check Point|Array Networks|F5 '

# ------------------------------------------------------------ pure helpers --

function Get-WcNetValue {
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

function Format-WcLinkSpeed {
    <# Pure: bits per second -> '100 Mbps' / '1 Gbps'. Strings (Get-NetAdapter LinkSpeed) pass through. #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value)
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value.Trim() }
    $b = [double]$Value
    if ($b -le 0) { return '' }
    if ($b -ge 1e9) { return ('{0:0.#} Gbps' -f ($b / 1e9)) }
    if ($b -ge 1e6) { return ('{0:0.#} Mbps' -f ($b / 1e6)) }
    return ('{0:0} Kbps' -f ($b / 1e3))
}

function ConvertTo-WcNetIPConfigRecord {
    <#
        Pure: joins Get-NetAdapter objects with Get-NetIPConfiguration -Detailed objects by
        InterfaceIndex. Shapes used: adapter Name/InterfaceDescription/Status/LinkSpeed/
        InterfaceIndex; ipconfig IPv4Address[].IPAddress, IPv6Address[].IPAddress,
        IPv4DefaultGateway[].NextHop, DNSServer[].ServerAddresses, NetIPv4Interface.Dhcp.
        MAC addresses are deliberately not collected.
    #>
    [CmdletBinding()]
    param([object[]] $Adapter = @(), [object[]] $IPConfig = @())
    $byIndex = @{}
    foreach ($c in @($IPConfig)) {
        if ($null -eq $c) { continue }
        $idx = Get-WcNetValue $c 'InterfaceIndex'
        if ($null -ne $idx) { $byIndex[[string]$idx] = $c }
    }
    $out = @()
    foreach ($a in @($Adapter)) {
        if ($null -eq $a) { continue }
        $c = $null
        $idx = Get-WcNetValue $a 'InterfaceIndex'
        if ($null -ne $idx -and $byIndex.ContainsKey([string]$idx)) { $c = $byIndex[[string]$idx] }
        $v4 = @(); $v6 = @(); $gw = @(); $dns = @(); $dhcp = ''
        if ($null -ne $c) {
            foreach ($x in @(Get-WcNetValue $c 'IPv4Address')) { $ip = Get-WcNetValue $x 'IPAddress'; if ($ip) { $v4 += [string]$ip } }
            foreach ($x in @(Get-WcNetValue $c 'IPv6Address')) { $ip = Get-WcNetValue $x 'IPAddress'; if ($ip) { $v6 += [string]$ip } }
            foreach ($x in @(Get-WcNetValue $c 'IPv4DefaultGateway')) { $h = Get-WcNetValue $x 'NextHop'; if ($h) { $gw += [string]$h } }
            foreach ($x in @(Get-WcNetValue $c 'DNSServer')) { foreach ($s in @(Get-WcNetValue $x 'ServerAddresses')) { if ($s -and $dns -notcontains [string]$s) { $dns += [string]$s } } }
            $if4 = Get-WcNetValue $c 'NetIPv4Interface'
            $d = Get-WcNetValue $if4 'Dhcp'
            if ($null -ne $d) { $dhcp = [string]$d }
        }
        $out += [pscustomobject]@{
            Name = [string](Get-WcNetValue $a 'Name'); Description = [string](Get-WcNetValue $a 'InterfaceDescription')
            Status = [string](Get-WcNetValue $a 'Status'); LinkSpeed = (Format-WcLinkSpeed (Get-WcNetValue $a 'LinkSpeed'))
            IPv4 = $v4; IPv6 = $v6; Gateway = $gw; DnsServers = $dns; Dhcp = $dhcp; Source = 'NetTCPIP'
        }
    }
    return $out
}

function ConvertTo-WcWin32AdapterRecord {
    <#
        Pure fallback: Win32_NetworkAdapterConfiguration (IPEnabled) + optional Win32_NetworkAdapter
        (NetConnectionID, NetConnectionStatus, Speed) joined by Index. IPv6 = addresses with ':'.
    #>
    [CmdletBinding()]
    param([object[]] $Configuration = @(), [object[]] $Adapter = @())
    $byIndex = @{}
    foreach ($a in @($Adapter)) { if ($null -ne $a -and $null -ne (Get-WcNetValue $a 'Index')) { $byIndex[[string](Get-WcNetValue $a 'Index')] = $a } }
    $statusMap = @{ '0' = 'Disconnected'; '1' = 'Connecting'; '2' = 'Up'; '3' = 'Disconnecting'; '4' = 'Hardware not present'; '5' = 'Hardware disabled'; '6' = 'Hardware malfunction'; '7' = 'Media disconnected' }
    $out = @()
    foreach ($c in @($Configuration)) {
        if ($null -eq $c) { continue }
        $en = Get-WcNetValue $c 'IPEnabled'
        if ($null -ne $en -and -not [bool]$en) { continue }
        $a = $null
        $idx = Get-WcNetValue $c 'Index'
        if ($null -ne $idx -and $byIndex.ContainsKey([string]$idx)) { $a = $byIndex[[string]$idx] }
        $v4 = @(); $v6 = @()
        foreach ($ip in @(Get-WcNetValue $c 'IPAddress')) { if ($ip) { if ([string]$ip -match ':') { $v6 += [string]$ip } else { $v4 += [string]$ip } } }
        $gw = @(@(Get-WcNetValue $c 'DefaultIPGateway') | Where-Object { $_ -and [string]$_ -notmatch ':' } | ForEach-Object { [string]$_ })
        $dns = @(@(Get-WcNetValue $c 'DNSServerSearchOrder') | Where-Object { $_ } | ForEach-Object { [string]$_ })
        $dhcp = 'Disabled'
        if ([bool](Get-WcNetValue $c 'DHCPEnabled')) { $dhcp = 'Enabled' }
        $name = [string](Get-WcNetValue $a 'NetConnectionID')
        $status = 'Up'
        $st = Get-WcNetValue $a 'NetConnectionStatus'
        if ($null -ne $st -and $statusMap.ContainsKey([string]$st)) { $status = $statusMap[[string]$st] }
        $out += [pscustomobject]@{
            Name = $name; Description = [string](Get-WcNetValue $c 'Description'); Status = $status
            LinkSpeed = (Format-WcLinkSpeed (Get-WcNetValue $a 'Speed'))
            IPv4 = $v4; IPv6 = $v6; Gateway = $gw; DnsServers = $dns; Dhcp = $dhcp; Source = 'CIM'
        }
    }
    return $out
}

function ConvertTo-WcNetAdapterRow {
    <# Pure: adapter records -> display rows (lists joined with ', '); connected adapters first. #>
    [CmdletBinding()]
    param([object[]] $Record = @())
    $rows = @()
    foreach ($r in @($Record)) {
        if ($null -eq $r) { continue }
        $rows += [pscustomobject]@{
            Name = $r.Name; Description = $r.Description; Status = $r.Status; LinkSpeed = $r.LinkSpeed
            IPv4 = (@($r.IPv4) -join ', '); IPv6 = (@($r.IPv6) -join ', '); Gateway = (@($r.Gateway) -join ', ')
            DnsServers = (@($r.DnsServers) -join ', '); Dhcp = $r.Dhcp
        }
    }
    $up = @($rows | Where-Object { $_.Status -eq 'Up' })
    $other = @($rows | Where-Object { $_.Status -ne 'Up' })
    return @($up + $other)
}

function Select-WcGatewayTarget {
    <# Pure: first IPv4 default gateway of an adapter that is Up; $null when none. #>
    [CmdletBinding()]
    param([object[]] $Record = @())
    foreach ($r in @($Record)) {
        if ($null -eq $r -or $r.Status -ne 'Up') { continue }
        foreach ($g in @($r.Gateway)) { if ($g -and [string]$g -match '^\d{1,3}(\.\d{1,3}){3}$' -and [string]$g -ne '0.0.0.0') { return [string]$g } }
    }
    return $null
}

function Test-WcVpnAdapter {
    <# Pure heuristic: adapter description/name that looks like a VPN client adapter (information only). #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string] $Description)
    if (-not $Description) { return $false }
    if ($Description -match '(?i)WAN Miniport') { return $false }
    return ($Description -match $script:WcVpnPattern)
}

function ConvertTo-WcVpnRow {
    <#
        Pure: Get-VpnConnection objects (Scope tagged 'User' / 'AllUsers') + adapter records ->
        rows Name, Type, Status, Source. Server addresses are deliberately not shown.
    #>
    [CmdletBinding()]
    param([object[]] $Connection = @(), [object[]] $Adapter = @())
    $rows = @()
    foreach ($c in @($Connection)) {
        if ($null -eq $c) { continue }
        $src = 'VpnConnection (user)'
        if ([string](Get-WcNetValue $c 'Scope') -eq 'AllUsers') { $src = 'VpnConnection (all users)' }
        $rows += [pscustomobject]@{
            Name = [string](Get-WcNetValue $c 'Name'); Type = [string](Get-WcNetValue $c 'TunnelType')
            Status = [string](Get-WcNetValue $c 'ConnectionStatus'); Source = $src
        }
    }
    foreach ($a in @($Adapter)) {
        if ($null -eq $a) { continue }
        $d = [string](Get-WcNetValue $a 'Description')
        if (-not (Test-WcVpnAdapter -Description $d)) { continue }
        $rows += [pscustomobject]@{ Name = [string](Get-WcNetValue $a 'Name'); Type = $d; Status = [string](Get-WcNetValue $a 'Status'); Source = 'Adapter' }
    }
    return $rows
}

function ConvertTo-WcRedactedProxy {
    <# Pure: removes credentials from proxy strings ('user:pass@host' -> '***@host'). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string] $Value)
    if (-not $Value) { return '' }
    return [regex]::Replace($Value, '(?<=^|[;=\s]|://)[^;=\s/@]+@', '***@')
}

function ConvertFrom-WcWinHttpProxyText {
    <#
        Pure, language-independent parse of 'netsh winhttp show proxy'.
        Mode: Direct (no '<label> : <value>' line) | Proxy | Unknown (empty text).
    #>
    [CmdletBinding()]
    param([string] $Text)
    if (-not $Text -or -not $Text.Trim()) { return [pscustomobject]@{ Mode = 'Unknown'; Server = ''; Bypass = '' } }
    $values = @()
    foreach ($l in [regex]::Split($Text, '\r\n|\n|\r')) {
        $m = [regex]::Match($l, '^\s*([^:]+?)\s*:\s+(\S.*?)\s*$')
        if ($m.Success) { $values += $m.Groups[2].Value }
    }
    if ($values.Count -eq 0) { return [pscustomobject]@{ Mode = 'Direct'; Server = ''; Bypass = '' } }
    $bypass = ''
    if ($values.Count -gt 1) { $bypass = $values[1] }
    return [pscustomobject]@{ Mode = 'Proxy'; Server = (ConvertTo-WcRedactedProxy $values[0]); Bypass = $bypass }
}

function ConvertTo-WcProxyRow {
    <#
        Pure: WinHTTP parse + user WinINet values (ProxyEnable, ProxyServer, ProxyOverride,
        AutoConfigURL) + policy presence -> rows Source, Item, Value. Values are redacted.
    #>
    [CmdletBinding()]
    param($WinHttp, [hashtable] $UserValues = @{}, [bool] $PolicyPresent = $false, [string] $WinHttpError = '')
    $rows = @()
    if ($WinHttpError) { $rows += [pscustomobject]@{ Source = 'WinHTTP'; Item = 'Error'; Value = $WinHttpError } }
    elseif ($null -ne $WinHttp) {
        $rows += [pscustomobject]@{ Source = 'WinHTTP'; Item = 'Mode'; Value = $WinHttp.Mode }
        if ($WinHttp.Mode -eq 'Proxy') {
            $rows += [pscustomobject]@{ Source = 'WinHTTP'; Item = 'Server'; Value = $WinHttp.Server }
            if ($WinHttp.Bypass) { $rows += [pscustomobject]@{ Source = 'WinHTTP'; Item = 'Bypass'; Value = $WinHttp.Bypass } }
        }
    }
    $enabled = $false
    if ($UserValues.ContainsKey('ProxyEnable') -and $null -ne $UserValues['ProxyEnable'] -and "$($UserValues['ProxyEnable'])" -eq '1') { $enabled = $true }
    $mode = 'Direct'
    if ($enabled) { $mode = 'Proxy' }
    $rows += [pscustomobject]@{ Source = 'User (WinINet)'; Item = 'Mode'; Value = $mode }
    if ($UserValues['ProxyServer']) { $rows += [pscustomobject]@{ Source = 'User (WinINet)'; Item = 'Server'; Value = (ConvertTo-WcRedactedProxy ([string]$UserValues['ProxyServer'])) } }
    if ($UserValues['ProxyOverride']) { $rows += [pscustomobject]@{ Source = 'User (WinINet)'; Item = 'Bypass'; Value = [string]$UserValues['ProxyOverride'] } }
    if ($UserValues['AutoConfigURL']) { $rows += [pscustomobject]@{ Source = 'User (WinINet)'; Item = 'AutoConfigURL'; Value = (ConvertTo-WcRedactedProxy ([string]$UserValues['AutoConfigURL'])) } }
    $pol = 'No'
    if ($PolicyPresent) { $pol = 'Yes' }
    $rows += [pscustomobject]@{ Source = 'Policy'; Item = 'Internet Settings policy'; Value = $pol }
    return $rows
}

function New-WcConnectivityRow {
    <# Pure: one connectivity check row. Status OK | Fail | Skipped; LatencyRaw in ms (sorting). #>
    [CmdletBinding()]
    param([string] $Check, [string] $Target, [ValidateSet('OK', 'Fail', 'Skipped')][string] $Status, $LatencyMs = $null, [string] $Detail = '')
    $lat = ''
    $raw = $null
    if ($null -ne $LatencyMs) { $raw = [long][math]::Round([double]$LatencyMs); $lat = ('{0} ms' -f $raw) }
    return [pscustomobject]@{ Check = $Check; Target = $Target; Status = $Status; Latency = $lat; LatencyRaw = $raw; Detail = $Detail }
}

function ConvertTo-WcNcsiVerdict {
    <# Pure: NCSI HTTP probe -> OK only for 200 with the exact expected body. #>
    [CmdletBinding()]
    param($StatusCode, [string] $Body, [string] $ErrorStatus = '')
    if ($ErrorStatus) { return [pscustomobject]@{ Status = 'Fail'; Detail = $ErrorStatus } }
    $code = 0
    if ($null -ne $StatusCode) { $code = [int]$StatusCode }
    if ($code -eq 407) { return [pscustomobject]@{ Status = 'Fail'; Detail = 'proxy-auth-required' } }
    if ($code -eq 200 -and ([string]$Body).Trim() -eq $script:WcNcsiBody) { return [pscustomobject]@{ Status = 'OK'; Detail = 'HTTP 200' } }
    if ($code -ge 200 -and $code -lt 400) { return [pscustomobject]@{ Status = 'Fail'; Detail = ('captive-portal-or-interception (HTTP {0})' -f $code) } }
    return [pscustomobject]@{ Status = 'Fail'; Detail = ('HTTP {0}' -f $code) }
}

function ConvertTo-WcHttpsVerdict {
    <# Pure: HTTPS probe -> OK for any HTTP answer below 500 except 407 (TLS handshake succeeded). #>
    [CmdletBinding()]
    param($StatusCode, [string] $ErrorStatus = '')
    if ($ErrorStatus) { return [pscustomobject]@{ Status = 'Fail'; Detail = $ErrorStatus } }
    $code = 0
    if ($null -ne $StatusCode) { $code = [int]$StatusCode }
    if ($code -eq 407) { return [pscustomobject]@{ Status = 'Fail'; Detail = 'proxy-auth-required' } }
    if ($code -ge 100 -and $code -lt 500) { return [pscustomobject]@{ Status = 'OK'; Detail = ('HTTP {0}' -f $code) } }
    return [pscustomobject]@{ Status = 'Fail'; Detail = ('HTTP {0}' -f $code) }
}

function ConvertTo-WcConnectivityVerdict {
    <#
        Pure: rows (Check = Gateway | DNS | HTTP | HTTPS) -> verdict code:
          ok | no-network | dns | captive-portal | proxy-auth | internet-or-proxy | gateway-icmp | partial | unknown
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]] $Row = @())
    $s = @{}
    $d = @{}
    foreach ($r in @($Row)) { if ($null -ne $r) { $s[[string]$r.Check] = [string]$r.Status; $d[[string]$r.Check] = [string]$r.Detail } }
    if ($s.Count -eq 0) { return 'unknown' }
    $fail = @($s.Keys | Where-Object { $s[$_] -eq 'Fail' })
    if ($fail.Count -eq 0) { return 'ok' }
    if ($s['DNS'] -eq 'Fail' -and $s['HTTPS'] -eq 'Fail' -and $s['Gateway'] -ne 'OK') { return 'no-network' }
    if ($s['DNS'] -eq 'Fail') { return 'dns' }
    if (($d['HTTP'] -match 'proxy-auth') -or ($d['HTTPS'] -match 'proxy-auth')) { return 'proxy-auth' }
    if ($s['HTTP'] -eq 'Fail' -and $d['HTTP'] -match 'captive') { return 'captive-portal' }
    if ($s['HTTPS'] -eq 'Fail' -or $s['HTTP'] -eq 'Fail') { return 'internet-or-proxy' }
    if ($fail.Count -eq 1 -and $s['Gateway'] -eq 'Fail') { return 'gateway-icmp' }
    return 'partial'
}

# ------------------------------------------------------------ I/O wrappers --

function Get-WcNetCimData {
    param([string] $ClassName, [string] $Filter)
    $p = @{ ClassName = $ClassName; ErrorAction = 'Stop' }
    if ($Filter) { $p['Filter'] = $Filter }
    return @(Get-CimInstance @p)
}

function Get-WcNetAdapterRecord {
    <# Thin I/O: NetAdapter/NetTCPIP cmdlets, falling back to CIM Win32_NetworkAdapterConfiguration. #>
    [CmdletBinding()]
    param()
    $primaryError = $null
    if ((Get-Command -Name 'Get-NetAdapter' -ErrorAction SilentlyContinue) -and (Get-Command -Name 'Get-NetIPConfiguration' -ErrorAction SilentlyContinue)) {
        try {
            $ad = @(Get-NetAdapter -ErrorAction Stop)
            $ip = @(Get-NetIPConfiguration -Detailed -ErrorAction Stop)
            return @(ConvertTo-WcNetIPConfigRecord -Adapter $ad -IPConfig $ip)
        }
        catch { $primaryError = $_.Exception.Message }
    }
    if ($primaryError) { Write-WcLog -Level Warning -Category 'Network' -Message ('Get-NetAdapter failed, using CIM: ' + $primaryError) | Out-Null }
    $cfg = Get-WcNetCimData -ClassName 'Win32_NetworkAdapterConfiguration' -Filter 'IPEnabled = TRUE'
    $ad = @()
    try { $ad = Get-WcNetCimData -ClassName 'Win32_NetworkAdapter' -Filter 'PhysicalAdapter = TRUE OR NetConnectionStatus = 2' } catch { $ad = @() }
    return @(ConvertTo-WcWin32AdapterRecord -Configuration $cfg -Adapter $ad)
}

function Test-WcPing {
    <# Thin I/O: one ICMP echo (default empty 32-byte payload), timeout in ms. #>
    param([Parameter(Mandatory = $true)][string] $Address, [int] $TimeoutMs = 1000)
    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($Address, $TimeoutMs)
        $ok = ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
        $lat = $null
        if ($ok) { $lat = [long]$reply.RoundtripTime }
        return [pscustomobject]@{ Success = $ok; LatencyMs = $lat; Detail = [string]$reply.Status }
    }
    catch { return [pscustomobject]@{ Success = $false; LatencyMs = $null; Detail = $_.Exception.GetBaseException().Message } }
    finally { $ping.Dispose() }
}

function Test-WcDnsResolve {
    <# Thin I/O: A-record lookup via Resolve-DnsName -DnsOnly, fallback [Net.Dns]. #>
    param([Parameter(Mandatory = $true)][string] $Name)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $addrs = @()
        if (Get-Command -Name 'Resolve-DnsName' -ErrorAction SilentlyContinue) {
            $addrs = @(Resolve-DnsName -Name $Name -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress } | ForEach-Object { [string]$_.IPAddress })
        }
        else { $addrs = @([System.Net.Dns]::GetHostAddresses($Name) | ForEach-Object { $_.ToString() }) }
        $sw.Stop()
        if ($addrs.Count -eq 0) { return [pscustomobject]@{ Success = $false; LatencyMs = $null; Detail = 'no A record' } }
        return [pscustomobject]@{ Success = $true; LatencyMs = $sw.ElapsedMilliseconds; Detail = ('{0} address(es)' -f $addrs.Count) }
    }
    catch {
        $sw.Stop()
        return [pscustomobject]@{ Success = $false; LatencyMs = $null; Detail = $_.Exception.GetBaseException().Message }
    }
}

function Invoke-WcHttpProbe {
    <#
        Thin I/O: one anonymous request. No cookies, no credentials, no custom headers,
        no User-Agent, redirects not followed, short timeout. System proxy is used (as Windows does).
    #>
    param([Parameter(Mandatory = $true)][string] $Uri, [ValidateSet('GET', 'HEAD')][string] $Method = 'GET', [int] $TimeoutMs = 5000)
    if (([System.Net.ServicePointManager]::SecurityProtocol -band [System.Net.SecurityProtocolType]::Tls12) -eq 0) {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12
    }
    $req = [System.Net.WebRequest]::Create($Uri)
    $req.Method = $Method
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.AllowAutoRedirect = $false
    $req.KeepAlive = $false
    $req.UseDefaultCredentials = $false
    $req.CookieContainer = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $resp = $null
    try {
        try { $resp = $req.GetResponse() }
        catch [System.Net.WebException] {
            if ($null -ne $_.Exception.Response) { $resp = $_.Exception.Response }
            else { $sw.Stop(); return [pscustomobject]@{ StatusCode = $null; Body = ''; LatencyMs = $null; Error = [string]$_.Exception.Status } }
        }
        $sw.Stop()
        $body = ''
        if ($Method -eq 'GET') {
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            try { $buf = New-Object char[] 256; $n = $sr.Read($buf, 0, 256); if ($n -gt 0) { $body = New-Object string($buf, 0, $n) } } finally { $sr.Dispose() }
        }
        return [pscustomobject]@{ StatusCode = [int]$resp.StatusCode; Body = $body; LatencyMs = $sw.ElapsedMilliseconds; Error = '' }
    }
    catch { return [pscustomobject]@{ StatusCode = $null; Body = ''; LatencyMs = $null; Error = $_.Exception.GetBaseException().Message } }
    finally { if ($null -ne $resp) { $resp.Close() } }
}

function Get-WcConnectivityCheck {
    <# I/O orchestration of the four checks (each I/O call mockable). Never throws. #>
    [CmdletBinding()]
    param([object[]] $AdapterRecord = @())
    $rows = @()
    $gw = Select-WcGatewayTarget -Record $AdapterRecord
    if ($gw) {
        $p = Test-WcPing -Address $gw -TimeoutMs 1000
        $st = 'Fail'; if ($p.Success) { $st = 'OK' }
        $rows += New-WcConnectivityRow -Check 'Gateway' -Target $gw -Status $st -LatencyMs $p.LatencyMs -Detail $p.Detail
    }
    else { $rows += New-WcConnectivityRow -Check 'Gateway' -Target '' -Status 'Skipped' -Detail 'no IPv4 default gateway on a connected adapter' }

    $d = Test-WcDnsResolve -Name $script:WcNcsiHost
    $st = 'Fail'; if ($d.Success) { $st = 'OK' }
    $rows += New-WcConnectivityRow -Check 'DNS' -Target $script:WcNcsiHost -Status $st -LatencyMs $d.LatencyMs -Detail $d.Detail

    $h = Invoke-WcHttpProbe -Uri $script:WcNcsiUri -Method GET -TimeoutMs $script:WcProbeTimeoutMs
    $v = ConvertTo-WcNcsiVerdict -StatusCode $h.StatusCode -Body $h.Body -ErrorStatus $h.Error
    $rows += New-WcConnectivityRow -Check 'HTTP' -Target $script:WcNcsiUri -Status $v.Status -LatencyMs $h.LatencyMs -Detail $v.Detail

    $s = Invoke-WcHttpProbe -Uri $script:WcHttpsProbeUri -Method HEAD -TimeoutMs $script:WcProbeTimeoutMs
    $v = ConvertTo-WcHttpsVerdict -StatusCode $s.StatusCode -ErrorStatus $s.Error
    $rows += New-WcConnectivityRow -Check 'HTTPS' -Target $script:WcHttpsProbeUri -Status $v.Status -LatencyMs $s.LatencyMs -Detail $v.Detail
    return $rows
}

function Get-WcNetRegistryValues {
    param([Parameter(Mandatory = $true)][string] $Path, [Parameter(Mandatory = $true)][string[]] $Name)
    $result = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $result }
    foreach ($n in $Name) { $p = $item.PSObject.Properties[$n]; if ($p) { $result[$n] = $p.Value } }
    return $result
}

function Get-WcWinHttpProxyText {
    <# Thin I/O: 'netsh winhttp show proxy' (read-only), System32 path, OEM output. #>
    $exe = Get-WcNativeToolPath -Name 'netsh.exe'
    $r = Invoke-WcNativeCommand -FilePath $exe -ArgumentList @('winhttp', 'show', 'proxy') -LogCategory 'Network'
    if ($r.ExitCode -ne 0) { throw ('netsh winhttp show proxy exit code {0}' -f $r.ExitCode) }
    return [string]$r.StdOut
}

function Get-WcProxyInfo {
    <# I/O: WinHTTP + user WinINet + policy presence. Read-only. #>
    [CmdletBinding()]
    param()
    $winHttp = $null; $err = ''
    try { $winHttp = ConvertFrom-WcWinHttpProxyText -Text (Get-WcWinHttpProxyText) } catch { $err = $_.Exception.Message }
    $user = Get-WcNetRegistryValues -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -Name @('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL')
    $pol = $false
    foreach ($k in @('HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings', 'HKCU:\Software\Policies\Microsoft\Windows\CurrentVersion\Internet Settings')) {
        if (Test-Path -LiteralPath $k) { $pol = $true }
    }
    return @(ConvertTo-WcProxyRow -WinHttp $winHttp -UserValues $user -PolicyPresent $pol -WinHttpError $err)
}

function Get-WcVpnConnectionRaw {
    <# Thin I/O: user and all-user VPN profiles (Get-VpnConnection), tagged with Scope. Read-only. #>
    [CmdletBinding()]
    param()
    $out = @()
    if (-not (Get-Command -Name 'Get-VpnConnection' -ErrorAction SilentlyContinue)) { return $out }
    foreach ($c in @(Get-VpnConnection -ErrorAction SilentlyContinue)) {
        $out += [pscustomobject]@{ Name = $c.Name; TunnelType = [string]$c.TunnelType; ConnectionStatus = [string]$c.ConnectionStatus; Scope = 'User' }
    }
    foreach ($c in @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)) {
        $out += [pscustomobject]@{ Name = $c.Name; TunnelType = [string]$c.TunnelType; ConnectionStatus = [string]$c.ConnectionStatus; Scope = 'AllUsers' }
    }
    return $out
}

# ---------------------------------------------------------------- page data --

function New-WcNetSection {
    param([string] $Id, [string] $TitleKey, [string] $NoteKey = $null, [object[]] $Rows = @(), [string] $Severity = 'Info')
    return [pscustomobject]@{ Id = $Id; TitleKey = $TitleKey; NoteKey = $NoteKey; Rows = @($Rows); Severity = $Severity }
}

function Get-WcNetworkPageData {
    <# Page 'network' (docs/CONTRATO-ACOES.md section 6). Read-only; never throws. #>
    [CmdletBinding()]
    param([hashtable] $Context)
    $sections = @()
    $errors = @()

    $records = @()
    try { $records = @(Get-WcNetAdapterRecord) } catch { $errors += ('adapters: ' + $_.Exception.Message) }
    $sections += New-WcNetSection -Id 'adapters' -TitleKey 'section.network.adapters' -NoteKey 'section.network.adapters.note' -Rows @(ConvertTo-WcNetAdapterRow -Record $records)

    $conn = @()
    try { $conn = @(Get-WcConnectivityCheck -AdapterRecord $records) } catch { $errors += ('connectivity: ' + $_.Exception.Message) }
    $verdict = ConvertTo-WcConnectivityVerdict -Row $conn
    $sev = 'Info'
    if (@('no-network', 'dns', 'captive-portal', 'proxy-auth', 'internet-or-proxy', 'partial') -contains $verdict) { $sev = 'Warning' }
    if ($verdict -eq 'no-network') { $sev = 'Critical' }
    $sections += New-WcNetSection -Id 'connectivity' -TitleKey 'section.network.connectivity' -NoteKey ('section.network.connectivity.verdict.' + $verdict) -Rows $conn -Severity $sev

    $proxy = @()
    try { $proxy = @(Get-WcProxyInfo) } catch { $errors += ('proxy: ' + $_.Exception.Message) }
    $sections += New-WcNetSection -Id 'proxy' -TitleKey 'section.network.proxy' -NoteKey 'section.network.proxy.note' -Rows $proxy

    $vpn = @()
    try { $vpn = @(ConvertTo-WcVpnRow -Connection (Get-WcVpnConnectionRaw) -Adapter $records) } catch { $errors += ('vpn: ' + $_.Exception.Message) }
    $sections += New-WcNetSection -Id 'vpn' -TitleKey 'section.network.vpn' -NoteKey 'section.network.vpn.note' -Rows $vpn

    return [pscustomobject]@{ PageId = 'network'; Sections = @($sections); Findings = @(); Errors = @($errors) }
}

# ------------------------------------------------------------------ actions --

$script:WcNetworkCommands = @{
    'network.flush-dns'     = @{ Exe = 'ipconfig.exe'; Args = @('/flushdns') }
    'network.renew-ip'      = @{ Exe = 'ipconfig.exe'; Args = @('/renew') }
    'network.reset-winsock' = @{ Exe = 'netsh.exe'; Args = @('winsock', 'reset') }
}

function Get-WcNetworkCommand {
    <# Fixed command for a catalog id (absolute System32 path, fixed arguments). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Id)
    if (-not $script:WcNetworkCommands.ContainsKey($Id)) { throw "Unknown network action: $Id" }
    $def = $script:WcNetworkCommands[$Id]
    $path = Get-WcNativeToolPath -Name $def.Exe
    return [pscustomobject]@{ Id = $Id; FilePath = $path; Arguments = @($def.Args); CommandLine = ('{0} {1}' -f $path, ($def.Args -join ' ')) }
}

function Test-WcDnsCacheCmdlet { return [bool](Get-Command -Name 'Clear-DnsClientCache' -ErrorAction SilentlyContinue) }

function Invoke-WcClearDnsCache {
    <# Thin I/O: the DnsClient cmdlet. Mocked in tests. #>
    Clear-DnsClientCache -ErrorAction Stop
}

function Measure-WcDnsCache {
    <# F5 Measure: number of entries in the DNS client cache (read-only). No metric when the cmdlet is missing. #>
    if (-not (Get-Command -Name 'Get-DnsClientCache' -ErrorAction SilentlyContinue)) { return @() }
    $n = @(Get-DnsClientCache -ErrorAction SilentlyContinue).Count
    return @(New-WcMetric -Source Action -Name 'DnsCacheEntries' -Target 'DnsClient' -Unit 'Count' -Value $n)
}

function Invoke-WcNetworkAction {
    <#
        Preview (default): exact command + warnings; runs nothing.
        -Execute: runs the fixed command. reset-winsock and renew-ip need administrator.
        Nothing here restarts Windows.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][ValidateSet('network.flush-dns', 'network.renew-ip', 'network.reset-winsock')][string] $Id, [switch] $Execute)
    $cmd = Get-WcNetworkCommand -Id $Id
    if (-not $Execute) {
        switch ($Id) {
            'network.flush-dns' {
                $how = 'ipconfig /flushdns'
                if (Test-WcDnsCacheCmdlet) { $how = 'Clear-DnsClientCache (fallback: ipconfig /flushdns)' }
                return (New-WcActionResult -Summary ('Would clear the DNS client cache with {0}. Harmless: names are resolved again on next use. Nothing to undo.' -f $how) -Items @(
                        [pscustomobject]@{ Command = $how; RequiresAdmin = $false; RestartRequired = $false }))
            }
            'network.renew-ip' {
                return (New-WcActionResult -Summary ('Would run {0}: the connection drops briefly while DHCP leases are renewed on every adapter, and active VPN sessions may disconnect. Static IP settings are not changed. Requires administrator.' -f $cmd.CommandLine) -Items @(
                        [pscustomobject]@{ Command = $cmd.CommandLine; RequiresAdmin = $true; RestartRequired = $false }))
            }
            'network.reset-winsock' {
                return (New-WcActionResult -Summary ('Would run {0}: resets the Winsock catalog to defaults. Requires a Windows RESTART to complete (WinCare never restarts) and can break VPN, proxy or security clients that installed Winsock providers (they may need reinstalling). A System Restore point is requested first when System Protection is on. Requires administrator.' -f $cmd.CommandLine) -Items @(
                        [pscustomobject]@{ Command = $cmd.CommandLine; RequiresAdmin = $true; RestartRequired = $true }))
            }
        }
    }
    if ($Id -eq 'network.flush-dns' -and (Test-WcDnsCacheCmdlet)) {
        try {
            Invoke-WcClearDnsCache
            Write-WcLog -Level Audit -Category 'Network' -Message 'DNS client cache cleared (Clear-DnsClientCache).' | Out-Null
            return (New-WcActionResult -Summary 'DNS client cache cleared (Clear-DnsClientCache).' -Items @([pscustomobject]@{ Command = 'Clear-DnsClientCache'; Status = 'OK' }))
        }
        catch { Write-WcLog -Level Warning -Category 'Network' -Message ('Clear-DnsClientCache failed, using ipconfig /flushdns: ' + $_.Exception.Message) | Out-Null }
    }
    if ($Id -ne 'network.flush-dns' -and -not (Test-WcIsAdmin)) { throw "$Id requires an elevated (administrator) session." }
    $run = Invoke-WcNativeCommand -FilePath $cmd.FilePath -ArgumentList $cmd.Arguments -LogCategory 'Network'
    $output = [string]$run.StdOut
    if ($run.StdErr) { $output = $output + "`r`n" + $run.StdErr }
    if ($run.ExitCode -ne 0) { throw ('{0} failed with exit code {1}.' -f $cmd.CommandLine, $run.ExitCode) }
    $summary = '{0} completed.'
    if ($Id -eq 'network.reset-winsock') { $summary = '{0} completed. Restart Windows to finish (WinCare does not restart).' }
    $restart = ($Id -eq 'network.reset-winsock')
    return (New-WcActionResult -Summary ($summary -f $cmd.CommandLine) -Items @([pscustomobject]@{ Command = $cmd.CommandLine; Status = 'OK'; RestartRequired = $restart }) -Output $output -ExitCode $run.ExitCode)
}

function Register-WcNetworkHandler {
    <# Called lazily by Core (Initialize-WcActionHandlers). #>
    [CmdletBinding()]
    param()
    Register-WcActionHandler -Name 'Network-FlushDns' -Preview { param($Context) Invoke-WcNetworkAction -Id 'network.flush-dns' } -Execute { param($Context) Invoke-WcNetworkAction -Id 'network.flush-dns' -Execute } -Measure { param($Context) Measure-WcDnsCache }
    Register-WcActionHandler -Name 'Network-RenewIp' -Preview { param($Context) Invoke-WcNetworkAction -Id 'network.renew-ip' } -Execute { param($Context) Invoke-WcNetworkAction -Id 'network.renew-ip' -Execute }
    Register-WcActionHandler -Name 'Network-ResetWinsock' -Preview { param($Context) Invoke-WcNetworkAction -Id 'network.reset-winsock' } -Execute { param($Context) Invoke-WcNetworkAction -Id 'network.reset-winsock' -Execute }
}

Export-ModuleMember -Function @(
    'Get-WcNetworkPageData', 'Register-WcNetworkHandler',
    'Format-WcLinkSpeed', 'ConvertTo-WcNetIPConfigRecord', 'ConvertTo-WcWin32AdapterRecord', 'ConvertTo-WcNetAdapterRow', 'Select-WcGatewayTarget',
    'Test-WcVpnAdapter', 'ConvertTo-WcVpnRow', 'ConvertTo-WcRedactedProxy', 'ConvertFrom-WcWinHttpProxyText', 'ConvertTo-WcProxyRow',
    'New-WcConnectivityRow', 'ConvertTo-WcNcsiVerdict', 'ConvertTo-WcHttpsVerdict', 'ConvertTo-WcConnectivityVerdict',
    'Get-WcNetAdapterRecord', 'Get-WcConnectivityCheck', 'Get-WcProxyInfo', 'Get-WcVpnConnectionRaw',
    'Get-WcNetworkCommand', 'Invoke-WcNetworkAction', 'Measure-WcDnsCache'
)

# Handlers are NOT registered at import time: Core's Initialize-WcActionHandlers
# (called by New-WcPlan) invokes the exported Register-WcNetworkHandler.
