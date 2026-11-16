#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# WinCare.Network (F6). Pure converters with fixtures (tests/fixtures/network); cmdlets,
# CIM, sockets, HTTP and native tools are always mocked. Nothing is run for real here.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-WcTestModules -Name @('Integrity', 'Network')
    Initialize-WcLog -Path (Join-Path (New-WcTestDir) 'network.jsonl') | Out-Null
    $script:Fix = Join-Path $PSScriptRoot 'fixtures/network'
    function Get-FixtureText([string] $Name) { [System.IO.File]::ReadAllText((Join-Path $script:Fix $Name), [System.Text.Encoding]::UTF8) }
    function Get-LocKeys([string] $Lang) {
        $keys = @((Get-Content -Raw -Encoding UTF8 (Join-Path $script:SrcRoot "Localization/$Lang.json") | ConvertFrom-Json).PSObject.Properties.Name)
        foreach ($f in Get-ChildItem (Join-Path $script:SrcRoot "Localization/$Lang.d") -Filter '*.json') {
            $keys += @((Get-Content -Raw -Encoding UTF8 $f.FullName | ConvertFrom-Json).PSObject.Properties.Name)
        }
        return $keys
    }
    function New-Rec([string] $Name, [string] $Status, [string[]] $Gateway = @(), [string] $Description = 'Intel Ethernet') {
        [pscustomobject]@{ Name = $Name; Description = $Description; Status = $Status; LinkSpeed = '1 Gbps'; IPv4 = @('192.168.0.10'); IPv6 = @(); Gateway = $Gateway; DnsServers = @('192.168.0.1'); Dhcp = 'Enabled'; Source = 'NetTCPIP' }
    }
}

Describe 'Adapters' {
    It 'formats link speed' {
        Format-WcLinkSpeed -Value ([uint64]1000000000) | Should -Be '1 Gbps'
        Format-WcLinkSpeed -Value ([uint64]100000000) | Should -Be '100 Mbps'
        Format-WcLinkSpeed -Value '2.5 Gbps' | Should -Be '2.5 Gbps'
        Format-WcLinkSpeed -Value $null | Should -Be ''
        Format-WcLinkSpeed -Value 0 | Should -Be ''
    }
    It 'joins Get-NetAdapter and Get-NetIPConfiguration by interface index' {
        $ad = @(
            [pscustomobject]@{ Name = 'Ethernet'; InterfaceDescription = 'Intel(R) Ethernet'; Status = 'Up'; LinkSpeed = '1 Gbps'; InterfaceIndex = 7; MacAddress = '00-11-22-33-44-55' }
            [pscustomobject]@{ Name = 'Wi-Fi'; InterfaceDescription = 'Intel Wi-Fi 6'; Status = 'Disconnected'; LinkSpeed = '0 bps'; InterfaceIndex = 9 }
        )
        $ip = @([pscustomobject]@{
                InterfaceIndex = 7
                IPv4Address = @([pscustomobject]@{ IPAddress = '192.168.0.10' })
                IPv6Address = @([pscustomobject]@{ IPAddress = 'fe80::1' })
                IPv4DefaultGateway = @([pscustomobject]@{ NextHop = '192.168.0.1' })
                DNSServer = @([pscustomobject]@{ ServerAddresses = @('192.168.0.1', '8.8.8.8') }, [pscustomobject]@{ ServerAddresses = @('fe80::1', '192.168.0.1') })
                NetIPv4Interface = [pscustomobject]@{ Dhcp = 'Enabled' }
            })
        $r = @(ConvertTo-WcNetIPConfigRecord -Adapter $ad -IPConfig $ip)
        $r.Count | Should -Be 2
        $r[0].IPv4 | Should -Be @('192.168.0.10')
        $r[0].Gateway | Should -Be @('192.168.0.1')
        $r[0].DnsServers | Should -Be @('192.168.0.1', '8.8.8.8', 'fe80::1')
        $r[0].Dhcp | Should -Be 'Enabled'
        @($r[1].IPv4).Count | Should -Be 0
        @($r[0].PSObject.Properties.Name) | Should -Not -Contain 'MacAddress'
    }
    It 'falls back to Win32_NetworkAdapterConfiguration (CIM shapes)' {
        $cfg = @(
            [pscustomobject]@{ Index = 1; Description = 'Realtek PCIe GbE'; IPEnabled = $true; IPAddress = @('10.0.0.5', 'fe80::5'); DefaultIPGateway = @('10.0.0.1'); DNSServerSearchOrder = @('10.0.0.1'); DHCPEnabled = $false }
            [pscustomobject]@{ Index = 2; Description = 'Disabled one'; IPEnabled = $false }
        )
        $ad = @([pscustomobject]@{ Index = 1; NetConnectionID = 'Ethernet'; NetConnectionStatus = 2; Speed = [uint64]1000000000 })
        $r = @(ConvertTo-WcWin32AdapterRecord -Configuration $cfg -Adapter $ad)
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Ethernet'
        $r[0].Status | Should -Be 'Up'
        $r[0].IPv4 | Should -Be @('10.0.0.5')
        $r[0].IPv6 | Should -Be @('fe80::5')
        $r[0].Dhcp | Should -Be 'Disabled'
        $r[0].LinkSpeed | Should -Be '1 Gbps'
        $r[0].Source | Should -Be 'CIM'
    }
    It 'builds display rows with connected adapters first' {
        $rows = @(ConvertTo-WcNetAdapterRow -Record @((New-Rec 'Wi-Fi' 'Disconnected'), (New-Rec 'Ethernet' 'Up' @('192.168.0.1'))))
        $rows[0].Name | Should -Be 'Ethernet'
        $rows[0].Gateway | Should -Be '192.168.0.1'
        @($rows[0].PSObject.Properties.Name) | Should -Be @('Name', 'Description', 'Status', 'LinkSpeed', 'IPv4', 'IPv6', 'Gateway', 'DnsServers', 'Dhcp')
    }
    It 'selects the IPv4 gateway of a connected adapter' {
        Select-WcGatewayTarget -Record @((New-Rec 'A' 'Disconnected' @('10.9.9.9')), (New-Rec 'B' 'Up' @('fe80::1', '192.168.0.1'))) | Should -Be '192.168.0.1'
        Select-WcGatewayTarget -Record @((New-Rec 'A' 'Up' @('0.0.0.0'))) | Should -BeNullOrEmpty
        Select-WcGatewayTarget -Record @() | Should -BeNullOrEmpty
    }
}

Describe 'VPN (information only)' {
    It 'recognizes VPN adapter <_>' -ForEach @('Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter', 'PANGP Virtual Ethernet Adapter', 'TAP-Windows Adapter V9', 'WireGuard Tunnel', 'Fortinet Virtual Ethernet Adapter (NDIS 6.30)', 'Zscaler Network Adapter 1.0.2.0') {
        Test-WcVpnAdapter -Description $_ | Should -BeTrue
    }
    It 'ignores normal adapters and WAN Miniports (<_>)' -ForEach @('Intel(R) Ethernet Connection I219-LM', 'WAN Miniport (IKEv2)', 'WAN Miniport (SSTP)', 'Hyper-V Virtual Ethernet Adapter', '') {
        Test-WcVpnAdapter -Description $_ | Should -BeFalse
    }
    It 'lists VPN profiles and VPN adapters without server addresses' {
        $conn = @([pscustomobject]@{ Name = 'Corp VPN'; TunnelType = 'Ikev2'; ConnectionStatus = 'Disconnected'; Scope = 'AllUsers'; ServerAddress = 'vpn.corp.example' })
        $rows = @(ConvertTo-WcVpnRow -Connection $conn -Adapter @((New-Rec 'Ethernet 3' 'Up' @() 'PANGP Virtual Ethernet Adapter'), (New-Rec 'Ethernet' 'Up')))
        $rows.Count | Should -Be 2
        $rows[0].Source | Should -Be 'VpnConnection (all users)'
        $rows[1].Source | Should -Be 'Adapter'
        foreach ($r in $rows) { @($r.PSObject.Properties.Name) | Should -Be @('Name', 'Type', 'Status', 'Source'); [string]($r.PSObject.Properties.Value) | Should -Not -Match 'vpn\.corp' }
    }
}

Describe 'Proxy' {
    It 'parses direct access in <_>' -ForEach @('winhttp-direct-en-US.txt', 'winhttp-direct-pt-BR.txt') {
        $r = ConvertFrom-WcWinHttpProxyText -Text (Get-FixtureText $_)
        $r.Mode | Should -Be 'Direct'
        $r.Server | Should -Be ''
    }
    It 'parses a proxy server and bypass list in English' {
        $r = ConvertFrom-WcWinHttpProxyText -Text (Get-FixtureText 'winhttp-proxy-en-US.txt')
        $r.Mode | Should -Be 'Proxy'
        $r.Server | Should -Be 'http=proxy.corp.example:8080;https=proxy.corp.example:8443'
        $r.Bypass | Should -Be '<local>;*.corp.example'
    }
    It 'parses a proxy server by position in a localized (pt-BR) output' {
        $r = ConvertFrom-WcWinHttpProxyText -Text (Get-FixtureText 'winhttp-proxy-pt-BR.txt')
        $r.Mode | Should -Be 'Proxy'
        $r.Server | Should -Be 'proxy.corp.example:3128'
        $r.Bypass | Should -Be '(nenhum)'
    }
    It 'returns Unknown for empty output' {
        (ConvertFrom-WcWinHttpProxyText -Text '').Mode | Should -Be 'Unknown'
    }
    It 'redacts proxy credentials (<In>)' -ForEach @(
        @{ In = 'http=user:pass@proxy:8080;https=proxy:8443'; Out = 'http=***@proxy:8080;https=proxy:8443' }
        @{ In = 'http://DOMAIN\user:p4ss@proxy.corp:80'; Out = 'http://***@proxy.corp:80' }
        @{ In = 'proxy.corp:3128'; Out = 'proxy.corp:3128' }
        @{ In = 'bob@proxy:1'; Out = '***@proxy:1' }
    ) {
        ConvertTo-WcRedactedProxy -Value $In | Should -Be $Out
    }
    It 'builds WinHTTP, user and policy rows' {
        $w = ConvertFrom-WcWinHttpProxyText -Text (Get-FixtureText 'winhttp-proxy-en-US.txt')
        $rows = @(ConvertTo-WcProxyRow -WinHttp $w -UserValues @{ ProxyEnable = 1; ProxyServer = 'u:p@proxy:8080'; ProxyOverride = '<local>'; AutoConfigURL = 'http://wpad/wpad.dat' } -PolicyPresent $true)
        ($rows | Where-Object { $_.Source -eq 'WinHTTP' -and $_.Item -eq 'Server' }).Value | Should -Match 'proxy.corp.example:8080'
        ($rows | Where-Object { $_.Source -eq 'User (WinINet)' -and $_.Item -eq 'Mode' }).Value | Should -Be 'Proxy'
        ($rows | Where-Object { $_.Source -eq 'User (WinINet)' -and $_.Item -eq 'Server' }).Value | Should -Be '***@proxy:8080'
        ($rows | Where-Object { $_.Source -eq 'Policy' }).Value | Should -Be 'Yes'
        foreach ($r in $rows) { @($r.PSObject.Properties.Name) | Should -Be @('Source', 'Item', 'Value') }
    }
    It 'reports a netsh failure as a row and still shows the user proxy' {
        $rows = @(ConvertTo-WcProxyRow -WinHttp $null -UserValues @{} -WinHttpError 'netsh failed')
        $rows[0].Item | Should -Be 'Error'
        ($rows | Where-Object { $_.Source -eq 'User (WinINet)' }).Value | Should -Be 'Direct'
    }
}

Describe 'Connectivity verdicts' {
    It 'NCSI probe is OK only for 200 with the expected body' {
        (ConvertTo-WcNcsiVerdict -StatusCode 200 -Body "Microsoft Connect Test").Status | Should -Be 'OK'
        $v = ConvertTo-WcNcsiVerdict -StatusCode 200 -Body '<html>login</html>'
        $v.Status | Should -Be 'Fail'; $v.Detail | Should -Match 'captive'
        (ConvertTo-WcNcsiVerdict -StatusCode 302 -Body '').Detail | Should -Match 'captive'
        (ConvertTo-WcNcsiVerdict -StatusCode 407 -Body '').Detail | Should -Be 'proxy-auth-required'
        (ConvertTo-WcNcsiVerdict -StatusCode $null -Body '' -ErrorStatus 'NameResolutionFailure').Detail | Should -Be 'NameResolutionFailure'
    }
    It 'HTTPS probe is OK for any answer below 500 except 407' {
        (ConvertTo-WcHttpsVerdict -StatusCode 200).Status | Should -Be 'OK'
        (ConvertTo-WcHttpsVerdict -StatusCode 302).Status | Should -Be 'OK'
        (ConvertTo-WcHttpsVerdict -StatusCode 407).Status | Should -Be 'Fail'
        (ConvertTo-WcHttpsVerdict -StatusCode 503).Status | Should -Be 'Fail'
        (ConvertTo-WcHttpsVerdict -StatusCode $null -ErrorStatus 'TrustFailure').Detail | Should -Be 'TrustFailure'
    }
    It 'formats latency and keeps a raw value' {
        $r = New-WcConnectivityRow -Check 'DNS' -Target 'x' -Status 'OK' -LatencyMs 12.4
        $r.Latency | Should -Be '12 ms'
        $r.LatencyRaw | Should -Be 12
        (New-WcConnectivityRow -Check 'Gateway' -Target '' -Status 'Skipped').Latency | Should -Be ''
    }
    It 'verdict <Expected>' -ForEach @(
        @{ G = 'OK'; D = 'OK'; H = 'OK'; S = 'OK'; HD = ''; Expected = 'ok' }
        @{ G = 'Skipped'; D = 'OK'; H = 'OK'; S = 'OK'; HD = ''; Expected = 'ok' }
        @{ G = 'Fail'; D = 'Fail'; H = 'Fail'; S = 'Fail'; HD = 'Timeout'; Expected = 'no-network' }
        @{ G = 'OK'; D = 'Fail'; H = 'Fail'; S = 'Fail'; HD = 'NameResolutionFailure'; Expected = 'dns' }
        @{ G = 'OK'; D = 'OK'; H = 'Fail'; S = 'OK'; HD = 'captive-portal-or-interception (HTTP 200)'; Expected = 'captive-portal' }
        @{ G = 'OK'; D = 'OK'; H = 'Fail'; S = 'Fail'; HD = 'proxy-auth-required'; Expected = 'proxy-auth' }
        @{ G = 'OK'; D = 'OK'; H = 'OK'; S = 'Fail'; HD = ''; Expected = 'internet-or-proxy' }
        @{ G = 'Fail'; D = 'OK'; H = 'OK'; S = 'OK'; HD = ''; Expected = 'gateway-icmp' }
    ) {
        $rows = @(
            (New-WcConnectivityRow -Check 'Gateway' -Target 'g' -Status $G),
            (New-WcConnectivityRow -Check 'DNS' -Target 'd' -Status $D),
            (New-WcConnectivityRow -Check 'HTTP' -Target 'h' -Status $H -Detail $HD),
            (New-WcConnectivityRow -Check 'HTTPS' -Target 's' -Status $S))
        ConvertTo-WcConnectivityVerdict -Row $rows | Should -Be $Expected
    }
    It 'verdict is unknown without rows' {
        ConvertTo-WcConnectivityVerdict -Row @() | Should -Be 'unknown'
    }
}

Describe 'Connectivity checks (I/O mocked)' {
    BeforeEach {
        Mock -ModuleName WinCare.Network Test-WcPing { [pscustomobject]@{ Success = $true; LatencyMs = 2; Detail = 'Success' } }
        Mock -ModuleName WinCare.Network Test-WcDnsResolve { [pscustomobject]@{ Success = $true; LatencyMs = 15; Detail = '2 address(es)' } }
        Mock -ModuleName WinCare.Network Invoke-WcHttpProbe {
            if ($Method -eq 'GET') { [pscustomobject]@{ StatusCode = 200; Body = 'Microsoft Connect Test'; LatencyMs = 40; Error = '' } }
            else { [pscustomobject]@{ StatusCode = 200; Body = ''; LatencyMs = 90; Error = '' } }
        }
    }
    It 'runs the four checks against the fixed neutral endpoints only' {
        $rows = @(Get-WcConnectivityCheck -AdapterRecord @((New-Rec 'Ethernet' 'Up' @('192.168.0.1'))))
        @($rows.Check) | Should -Be @('Gateway', 'DNS', 'HTTP', 'HTTPS')
        @($rows | Where-Object Status -ne 'OK').Count | Should -Be 0
        Should -Invoke -ModuleName WinCare.Network Test-WcPing -Times 1 -Exactly -ParameterFilter { $Address -eq '192.168.0.1' }
        Should -Invoke -ModuleName WinCare.Network Test-WcDnsResolve -Times 1 -Exactly -ParameterFilter { $Name -eq 'www.msftconnecttest.com' }
        Should -Invoke -ModuleName WinCare.Network Invoke-WcHttpProbe -Times 2 -Exactly
        Should -Invoke -ModuleName WinCare.Network Invoke-WcHttpProbe -Times 0 -ParameterFilter { @('http://www.msftconnecttest.com/connecttest.txt', 'https://www.microsoft.com/') -notcontains $Uri }
    }
    It 'skips the gateway ping when no connected adapter has an IPv4 gateway' {
        $rows = @(Get-WcConnectivityCheck -AdapterRecord @())
        $rows[0].Status | Should -Be 'Skipped'
        Should -Invoke -ModuleName WinCare.Network Test-WcPing -Times 0
    }
    It 'the HTTP probe code sends no credentials, cookies or user agent' {
        $src = Get-Content -Raw (Join-Path $script:SrcRoot 'Modules/WinCare.Network.psm1')
        $src | Should -Match 'UseDefaultCredentials = \$false'
        $src | Should -Match 'AllowAutoRedirect = \$false'
        $src | Should -Not -Match '(?i)\.UserAgent\s*=|\.Headers\.Add|DefaultNetworkCredentials|Invoke-WebRequest|Invoke-RestMethod'
    }
}

Describe 'Get-WcNetworkPageData' {
    BeforeAll {
        $script:PtKeys = @(Get-LocKeys 'pt-BR')
        $script:EnKeys = @(Get-LocKeys 'en-US')
    }
    BeforeEach {
        Mock -ModuleName WinCare.Network Get-WcNetAdapterRecord { @((New-Rec 'Ethernet' 'Up' @('192.168.0.1')), (New-Rec 'VPN' 'Up' @() 'WireGuard Tunnel')) }
        Mock -ModuleName WinCare.Network Get-WcConnectivityCheck { @((New-WcConnectivityRow -Check 'Gateway' -Target 'g' -Status 'OK' -LatencyMs 1), (New-WcConnectivityRow -Check 'DNS' -Target 'd' -Status 'Fail' -Detail 'x')) }
        Mock -ModuleName WinCare.Network Get-WcWinHttpProxyText { Get-FixtureText 'winhttp-direct-pt-BR.txt' }
        Mock -ModuleName WinCare.Network Get-WcNetRegistryValues { @{ ProxyEnable = 0 } }
        Mock -ModuleName WinCare.Network Get-WcVpnConnectionRaw { @() }
    }
    It 'returns the four sections with translated titles, notes and columns' {
        $d = Get-WcNetworkPageData
        $d.PageId | Should -Be 'network'
        @($d.Sections.Id) | Should -Be @('adapters', 'connectivity', 'proxy', 'vpn')
        @($d.Errors).Count | Should -Be 0
        foreach ($s in $d.Sections) {
            $script:PtKeys | Should -Contain $s.TitleKey
            $script:PtKeys | Should -Contain $s.NoteKey
            $script:EnKeys | Should -Contain $s.NoteKey
            foreach ($r in @($s.Rows)) {
                foreach ($p in $r.PSObject.Properties.Name) {
                    $script:PtKeys | Should -Contain "col.$p"
                    $script:EnKeys | Should -Contain "col.$p"
                }
            }
        }
        $c = $d.Sections | Where-Object Id -eq 'connectivity'
        $c.NoteKey | Should -Be 'section.network.connectivity.verdict.dns'
        $c.Severity | Should -Be 'Warning'
        @(($d.Sections | Where-Object Id -eq 'vpn').Rows).Count | Should -Be 1
        ((($d.Sections | Where-Object Id -eq 'proxy').Rows) | Where-Object Source -eq 'WinHTTP').Value | Should -Be 'Direct'
    }
    It 'every connectivity verdict has a note in both languages' {
        foreach ($v in 'ok', 'no-network', 'dns', 'captive-portal', 'proxy-auth', 'internet-or-proxy', 'gateway-icmp', 'partial', 'unknown') {
            $script:PtKeys | Should -Contain "section.network.connectivity.verdict.$v"
            $script:EnKeys | Should -Contain "section.network.connectivity.verdict.$v"
        }
    }
    It 'never throws: failing sections go to Errors' {
        Mock -ModuleName WinCare.Network Get-WcNetAdapterRecord { throw 'CIM down' }
        Mock -ModuleName WinCare.Network Get-WcVpnConnectionRaw { throw 'no VpnClient' }
        Mock -ModuleName WinCare.Network Get-WcWinHttpProxyText { throw 'netsh missing' }
        $d = Get-WcNetworkPageData
        @($d.Errors) | Should -Contain 'adapters: CIM down'
        @($d.Errors) | Should -Contain 'vpn: no VpnClient'
        ((($d.Sections | Where-Object Id -eq 'proxy').Rows) | Where-Object Item -eq 'Error').Value | Should -Be 'netsh missing'
        @($d.Sections).Count | Should -Be 4
    }
}

Describe 'Network actions' {
    BeforeEach {
        Mock -ModuleName WinCare.Network Get-WcNativeToolPath { 'C:\Windows\System32\' + $Name }
        Mock -ModuleName WinCare.Network Invoke-WcNativeCommand { [pscustomobject]@{ ExitCode = 0; StdOut = 'ok'; StdErr = ''; Encoding = 'ibm850' } }
        Mock -ModuleName WinCare.Network Invoke-WcClearDnsCache { }
        Mock -ModuleName WinCare.Network Test-WcDnsCacheCmdlet { $true }
        Mock -ModuleName WinCare.Network Test-WcIsAdmin { $true }
        Mock -ModuleName WinCare.Network Restart-Computer { throw 'must never restart' }
    }
    It 'Preview of <_> runs nothing' -ForEach @('network.flush-dns', 'network.renew-ip', 'network.reset-winsock') {
        $r = Invoke-WcNetworkAction -Id $_
        $r.Summary | Should -Match '^Would '
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 0
        Should -Invoke -ModuleName WinCare.Network Invoke-WcClearDnsCache -Times 0
    }
    It 'renew-ip Preview warns about the drop and VPN sessions' {
        (Invoke-WcNetworkAction -Id 'network.renew-ip').Summary | Should -Match 'drops briefly.*VPN sessions may disconnect'
    }
    It 'reset-winsock Preview states the restart and VPN/proxy risk' {
        $r = Invoke-WcNetworkAction -Id 'network.reset-winsock'
        $r.Summary | Should -Match 'RESTART'
        $r.Summary | Should -Match 'never restarts'
        $r.Summary | Should -Match 'VPN, proxy'
        $r.Items[0].RestartRequired | Should -BeTrue
    }
    It 'flush-dns uses Clear-DnsClientCache when present' {
        $r = Invoke-WcNetworkAction -Id 'network.flush-dns' -Execute
        $r.Summary | Should -Match 'Clear-DnsClientCache'
        Should -Invoke -ModuleName WinCare.Network Invoke-WcClearDnsCache -Times 1 -Exactly
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 0
    }
    It 'flush-dns falls back to ipconfig /flushdns when the cmdlet fails or is missing' {
        Mock -ModuleName WinCare.Network Invoke-WcClearDnsCache { throw 'Access denied' }
        Invoke-WcNetworkAction -Id 'network.flush-dns' -Execute | Out-Null
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 1 -Exactly -ParameterFilter { $FilePath -like '*ipconfig.exe' -and ($ArgumentList -join ' ') -eq '/flushdns' }
        Mock -ModuleName WinCare.Network Test-WcDnsCacheCmdlet { $false }
        Mock -ModuleName WinCare.Network Test-WcIsAdmin { $false }
        Invoke-WcNetworkAction -Id 'network.flush-dns' -Execute | Out-Null
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 2 -Exactly
    }
    It 'renew-ip and reset-winsock refuse a non-elevated session' {
        Mock -ModuleName WinCare.Network Test-WcIsAdmin { $false }
        { Invoke-WcNetworkAction -Id 'network.renew-ip' -Execute } | Should -Throw '*administrator*'
        { Invoke-WcNetworkAction -Id 'network.reset-winsock' -Execute } | Should -Throw '*administrator*'
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 0
    }
    It 'reset-winsock runs only netsh winsock reset and never restarts' {
        $r = Invoke-WcNetworkAction -Id 'network.reset-winsock' -Execute
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 1 -Exactly -ParameterFilter { $FilePath -like '*System32\netsh.exe' -and ($ArgumentList -join ' ') -eq 'winsock reset' }
        Should -Invoke -ModuleName WinCare.Network Restart-Computer -Times 0
        $r.Summary | Should -Match 'Restart Windows to finish'
    }
    It 'renew-ip runs ipconfig /renew and reports a failing exit code' {
        Invoke-WcNetworkAction -Id 'network.renew-ip' -Execute | Out-Null
        Should -Invoke -ModuleName WinCare.Network Invoke-WcNativeCommand -Times 1 -Exactly -ParameterFilter { ($ArgumentList -join ' ') -eq '/renew' }
        Mock -ModuleName WinCare.Network Invoke-WcNativeCommand { [pscustomobject]@{ ExitCode = 1; StdOut = 'unable to contact DHCP server'; StdErr = ''; Encoding = 'ibm850' } }
        { Invoke-WcNetworkAction -Id 'network.renew-ip' -Execute } | Should -Throw '*exit code 1*'
    }
    It 'the module never changes firewall, VPN, proxy, DNS servers or adapter state, and never restarts' {
        $src = Get-Content -Raw (Join-Path $script:SrcRoot 'Modules/WinCare.Network.psm1')
        $src | Should -Not -Match '(?i)advfirewall|Set-NetFirewall|New-NetFirewall|Remove-NetFirewall|Set-VpnConnection|Add-VpnConnection|Remove-VpnConnection|rasdial|winhttp\W+(set|reset|import)|Set-DnsClientServerAddress|Disable-NetAdapter|Enable-NetAdapter|Restart-NetAdapter|Set-ItemProperty|New-ItemProperty|Restart-Computer|shutdown(\.exe)?\s+/r'
    }
}

Describe 'f6-network catalog' {
    BeforeAll {
        $script:Cat = Read-WcJsonFile -Path (Join-Path $script:SrcRoot 'Core/actions.d/f6-network.json')
        $script:Protected = @('Defender', 'Firewall', 'BitLocker', 'WindowsUpdate', 'GroupPolicy', 'MDM', 'EDR', 'VPN', 'Authentication', 'Inventory', 'ExecutionPolicy', 'UAC', 'SmartScreen')
    }
    It 'every entry is valid, on the network page, touches no protected feature and is translated' {
        $pt = @(Get-LocKeys 'pt-BR'); $en = @(Get-LocKeys 'en-US')
        foreach ($a in $script:Cat.actions) {
            @(Test-WcActionDefinition -Action $a).Count | Should -Be 0 -Because $a.Id
            @($a.Pages) | Should -Be @('network')
            foreach ($t in @($a.Touches)) { $script:Protected | Should -Not -Contain $t }
            $pt | Should -Contain $a.TitleKey; $en | Should -Contain $a.DescriptionKey
        }
    }
    It 'declares the agreed risk, admin and policy flags' {
        $f = $script:Cat.actions | Where-Object { $_.Id -eq 'network.flush-dns' }
        $f.Risk | Should -Be 'Low'; $f.Modifies | Should -BeTrue; $f.Reversibility | Should -Be 'None'
        $r = $script:Cat.actions | Where-Object { $_.Id -eq 'network.renew-ip' }
        $r.Risk | Should -Be 'Medium'; $r.BlockedWhenManaged | Should -BeTrue
        $w = $script:Cat.actions | Where-Object { $_.Id -eq 'network.reset-winsock' }
        $w.Risk | Should -Be 'High'; $w.RequiresAdmin | Should -BeTrue; $w.BlockedWhenManaged | Should -BeTrue; $w.Reversibility | Should -Be 'RestorePoint'
    }
    It 'reset-winsock asks the plan engine for a restore point' {
        $w = $script:Cat.actions | Where-Object { $_.Id -eq 'network.reset-winsock' }
        $item = [pscustomobject]@{ Modifies = $true; Risk = $w.Risk; Reversibility = $w.Reversibility }
        Test-WcRestorePointRequired -Item $item -Policy High | Should -BeTrue
    }
    It 'the validator would reject the same action declaring VPN or Firewall' {
        $w = ($script:Cat.actions | Where-Object { $_.Id -eq 'network.reset-winsock' }).Clone()
        $w['Touches'] = @('WinsockCatalog', 'VPN')
        @(Test-WcActionDefinition -Action $w) | Should -Contain "touches protected feature 'VPN'"
    }
    It 'registers a handler (with Measure for flush-dns) for every action' {
        Clear-WcActionHandlers
        Register-WcNetworkHandler
        foreach ($a in $script:Cat.actions) { Get-WcActionHandlerNames | Should -Contain $a.Handler }
    }
}
