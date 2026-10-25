# Runs once from the planted RunOnce + autologon, on every hypervisor.
# Sets the kit LAN addresses, RRAS NAT on the gateway, and DHCP options on
# the DC, then starts the hypervisor tools installer if it is still needed.
$ErrorActionPreference = 'Stop'
$Root = 'C:\Windows\Temp\lab-kit'
$Log = Join-Path $Root 'first-boot.log'
$NetFile = Join-Path $Root 'guest-network.tsv'

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'o'), $Message
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Topology names are HYD-DC1. The kit hostnames inside the guest are DC1.
function Get-LabShortName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    $n = $Name.Trim().ToUpperInvariant()
    $cut = $n.LastIndexOf('-')
    if ($cut -ge 0 -and $cut -lt ($n.Length - 1)) {
        return $n.Substring($cut + 1)
    }
    return $n
}

function Test-LabGuestName([string]$Guest, [string]$ComputerName) {
    $g = $Guest.Trim().ToUpperInvariant()
    $c = $ComputerName.Trim().ToUpperInvariant()
    if ($g -eq $c) {
        return $true
    }
    return (Get-LabShortName $g) -eq (Get-LabShortName $c)
}

function Read-GuestNetwork {
    if (-not (Test-Path -LiteralPath $NetFile)) {
        throw "Missing $NetFile"
    }
    $rows = @()
    foreach ($line in Get-Content -LiteralPath $NetFile) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
            continue
        }
        $c = $line -split "`t"
        if ($c.Count -lt 8) {
            throw "Bad guest-network.tsv row: $line"
        }
        $rows += [pscustomobject]@{
            Guest   = $c[0].Trim()
            Role    = $c[1].Trim()
            Adapter = $c[2].Trim()
            Address = $c[3].Trim()
            Prefix  = $c[4].Trim()
            Gateway = $c[5].Trim()
            Dns     = $c[6].Trim()
            Nat     = $c[7].Trim()
        }
    }
    return $rows
}

function Get-LabAdapterIPv4 {
    param($Adapter)
    return @(Get-NetIPAddress -InterfaceIndex $Adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' })
}

# WAN: Up NIC with DHCP that is not the lab LAN (10.0.0.0/24). Corp: the other Up NIC.
function Resolve-LabAdapter {
    param(
        [string]$Preferred,
        [string]$Role
    )
    $up = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })
    $wan = $null
    foreach ($adapter in $up) {
        $ext = Get-LabAdapterIPv4 $adapter |
            Where-Object { $_.PrefixOrigin -eq 'Dhcp' -and $_.IPAddress -notlike '10.0.0.*' }
        if ($null -ne $ext) {
            $wan = $adapter
            break
        }
    }
    $corp = @($up | Where-Object { $null -eq $wan -or $_.ifIndex -ne $wan.ifIndex }) | Select-Object -First 1
    if ($Role -eq 'wan') {
        if ($null -ne $wan) {
            Write-Log ("wan adapter {0} (DHCP outside 10.0.0.0/24)" -f $wan.Name)
            return $wan
        }
        throw "No Up adapter has DHCP outside 10.0.0.0/24"
    }
    if ($Role -eq 'corp') {
        if ($null -ne $corp) {
            Write-Log ("corp adapter {0}" -f $corp.Name)
            return $corp
        }
        throw "No Up adapter left for the lab LAN"
    }
    if ($Preferred -and $Preferred -ne '-') {
        $named = Get-NetAdapter -Name $Preferred -ErrorAction SilentlyContinue
        if ($null -ne $named) {
            return $named
        }
    }
    if ($up.Count -ge 1) {
        return $up[0]
    }
    throw "No connected adapter for role $Role"
}

function Set-LabIPv4 {
    param(
        $Adapter,
        [string]$Address,
        [string]$Prefix,
        [string]$Gateway,
        [string]$Dns
    )
    $alias = $Adapter.Name
    Write-Log "static $Address/$Prefix on $alias gateway=$Gateway dns=$Dns"
    Set-NetIPInterface -InterfaceAlias $alias -Dhcp Disabled -ErrorAction SilentlyContinue
    Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceAlias $alias -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    $params = @{
        InterfaceAlias = $alias
        IPAddress      = $Address
        PrefixLength   = [int]$Prefix
        ErrorAction    = 'Stop'
    }
    if ($Gateway -and $Gateway -ne '-') {
        $params.DefaultGateway = $Gateway
    }
    New-NetIPAddress @params | Out-Null
    if ($Dns -and $Dns -ne '-') {
        $servers = @($Dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $servers
    }
}

function Invoke-Netsh {
    param([string[]]$ArgumentList)
    Write-Log ("netsh {0}" -f ($ArgumentList -join ' '))
    $proc = Start-Process -FilePath 'netsh.exe' -ArgumentList $ArgumentList -Wait -PassThru -NoNewWindow
    $code = 1
    if ($null -ne $proc) { $code = $proc.ExitCode }
    Write-Log ("netsh exit {0}" -f $code)
    return $code
}

function Set-LabNat {
    param($Rows)
    Write-Log 'RRAS NAT'
    Restart-Service -Name RemoteAccess -Force -ErrorAction SilentlyContinue
    [void](Invoke-Netsh @('routing', 'ip', 'nat', 'uninstall'))
    [void](Invoke-Netsh @('routing', 'ip', 'nat', 'install'))
    foreach ($row in $Rows) {
        if (-not $row.Nat -or $row.Nat -eq '-') {
            continue
        }
        $adapter = Resolve-LabAdapter -Preferred '-' -Role $row.Role
        $name = $adapter.Name
        Write-Log ("NAT {0} on {1}" -f $row.Nat, $name)
        $quoted = 'name="{0}"' -f $name
        $code = Invoke-Netsh @('routing', 'ip', 'nat', 'add', 'interface', $quoted, "mode=$($row.Nat)")
        if ($code -ne 0) {
            [void](Invoke-Netsh @('routing', 'ip', 'nat', 'set', 'interface', $quoted, "mode=$($row.Nat)"))
        }
    }
    Restart-Service -Name RemoteAccess -Force
}

function Complete-LabDhcp {
    param(
        [string]$ListenAddress,
        [string]$Router,
        [string]$Dns
    )
    Write-Log 'DHCP post-install'
    Start-Service -Name DHCPServer -ErrorAction SilentlyContinue
    Import-Module DhcpServer -ErrorAction Stop
    [void](Invoke-Netsh @('dhcp', 'add', 'securitygroups'))
    try {
        Add-DhcpServerSecurityGroup -ErrorAction Stop
    }
    catch {
        Write-Log $_.Exception.Message
    }
    $account = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    $net = Start-Process -FilePath 'net.exe' -ArgumentList @('localgroup', 'DHCP Administrators', $account, '/add') -Wait -PassThru -NoNewWindow
    if ($null -ne $net) {
        Write-Log ("net localgroup DHCP Administrators exit {0}" -f $net.ExitCode)
    }
    $net = Start-Process -FilePath 'net.exe' -ArgumentList @('group', 'DHCP Administrators', $env:USERNAME, '/add', '/domain') -Wait -PassThru -NoNewWindow
    if ($null -ne $net) {
        Write-Log ("net group DHCP Administrators exit {0}" -f $net.ExitCode)
    }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem
    $fqdn = $cs.Name
    if ($cs.PartOfDomain -and $cs.Domain) {
        $fqdn = '{0}.{1}' -f $cs.Name, $cs.Domain
    }
    try {
        Add-DhcpServerInDC -DnsName $fqdn -IPAddress $ListenAddress -ErrorAction Stop
        Write-Log "authorized $fqdn $ListenAddress"
    }
    catch {
        Write-Log $_.Exception.Message
    }
    $scopes = @(Get-DhcpServerv4Scope -ErrorAction Stop)
    if ($scopes.Count -eq 0) {
        Write-Log 'no IPv4 DHCP scopes'
    }
    foreach ($scope in $scopes) {
        Write-Log ("scope {0} router={1} dns={2}" -f $scope.ScopeId, $Router, $Dns)
        Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -Router $Router -ErrorAction Stop
        Set-DhcpServerv4OptionValue -ScopeId $scope.ScopeId -DnsServer $Dns -ErrorAction Stop
    }
    Set-DhcpServerv4OptionValue -DnsServer $Dns -ErrorAction Stop
    $role = 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12'
    if (Test-Path -LiteralPath $role) {
        Set-ItemProperty -LiteralPath $role -Name ConfigurationState -Value 2
        Write-Log 'Server Manager DHCP configuration marked complete'
    }
}

function Start-LabToolsInstall {
    $pveOk = 'C:\Windows\Temp\pve-ga\installed.ok'
    $vboxOk = 'C:\Windows\Temp\vbox-ga\installed.ok'
    $pve = 'C:\Windows\Temp\pve-ga\install-guest-agent.ps1'
    $vbox = 'C:\Windows\Temp\vbox-ga\install-guest-additions.ps1'
    if (Test-Path -LiteralPath $pveOk) {
        Write-Log 'qemu-ga already installed; skip tools'
        return
    }
    if (Test-Path -LiteralPath $vboxOk) {
        Write-Log 'Guest Additions already installed; skip tools'
        return
    }
    $ga = Get-Service -Name @('QEMU-GA', 'qemu-ga', 'VBoxService') -ErrorAction SilentlyContinue
    if ($ga) {
        Write-Log ("tools service already present: {0}" -f ($ga.Name -join ','))
        return
    }
    if (Test-Path -LiteralPath $pve) {
        Write-Log 'starting qemu-ga installer'
        & $pve
        exit $LASTEXITCODE
    }
    if (Test-Path -LiteralPath $vbox) {
        Write-Log 'starting Guest Additions installer'
        & $vbox
        exit $LASTEXITCODE
    }
    Write-Log 'no tools installer on this disk'
}

try {
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    Write-Log 'start'

    if (-not (Test-Elevated)) {
        Write-Log 'not elevated; relaunching'
        $argList = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs -Wait -PassThru
        $code = 1
        if ($null -ne $proc) { $code = $proc.ExitCode }
        Write-Log ("elevate exit {0}" -f $code)
        exit $code
    }

    $name = $env:COMPUTERNAME
    $rows = @(Read-GuestNetwork | Where-Object { Test-LabGuestName $_.Guest $name })
    if ($rows.Count -eq 0) {
        Write-Log "no guest-network rows for $name"
    }
    else {
        Write-Log ("using {0} network row(s) for {1}" -f $rows.Count, $name)
    }

    foreach ($row in $rows) {
        if ($row.Address -eq 'dhcp' -or $row.Address -eq '-' -or -not $row.Address) {
            Write-Log ("{0} {1} left on DHCP" -f $name, $row.Role)
            continue
        }
        $adapter = Resolve-LabAdapter -Preferred $row.Adapter -Role $row.Role
        Set-LabIPv4 -Adapter $adapter -Address $row.Address -Prefix $row.Prefix -Gateway $row.Gateway -Dns $row.Dns
    }

    if ($rows | Where-Object { $_.Nat -and $_.Nat -ne '-' }) {
        Set-LabNat -Rows $rows
    }

    $dc = $rows | Where-Object { $_.Role -eq 'corp' -and $_.Address -and $_.Address -ne 'dhcp' } | Select-Object -First 1
    if ((Get-LabShortName $name) -eq 'DC1' -and $null -ne $dc) {
        $dns = ($dc.Dns -split ',' | Select-Object -First 1)
        Complete-LabDhcp -ListenAddress $dc.Address -Router '10.0.0.1' -Dns $dns
    }

    Set-Content -LiteralPath (Join-Path $Root 'first-boot.ok') -Value (Get-Date -Format 'o') -Encoding UTF8
    Write-Log 'network done'
    Start-LabToolsInstall
    exit 0
}
catch {
    Write-Log $_.Exception.Message
    exit 1
}
