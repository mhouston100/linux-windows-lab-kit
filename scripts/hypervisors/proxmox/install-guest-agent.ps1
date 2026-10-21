# Runs once at the automatic logon planted before this VM's first boot.
# Installs the virtio-serial driver and the QEMU guest agent from the files
# copied to this folder, then reboots so the agent can answer the host.
$ErrorActionPreference = 'Stop'
$Root = 'C:\Windows\Temp\pve-ga'
$Log = Join-Path $Root 'install.log'

function Write-Log([string]$Message) {
    $line = '{0} {1}' -f (Get-Date -Format 'o'), $Message
    Add-Content -LiteralPath $Log -Value $line -Encoding UTF8
}

function Test-Elevated {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
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

    $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    Remove-ItemProperty -Path $winlogon -Name 'DefaultPassword' -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $winlogon -Name 'AutoAdminLogon' -Value '0'
    Set-ItemProperty -Path $winlogon -Name 'AutoLogonCount' -Value 0 -Type DWord
    Write-Log 'cleared autologon'

    $inf = Join-Path $Root 'vioser\vioser.inf'
    if (-not (Test-Path -LiteralPath $inf)) {
        throw "Missing virtio-serial driver: $inf"
    }
    Write-Log "pnputil $inf"
    $proc = Start-Process -FilePath 'pnputil.exe' -ArgumentList @('/add-driver', $inf, '/install') -Wait -PassThru -NoNewWindow
    $code = 1
    if ($null -ne $proc) { $code = $proc.ExitCode }
    Write-Log ("pnputil exit {0}" -f $code)
    if ($code -ne 0 -and $code -ne 259 -and $code -ne 3010) {
        exit $code
    }

    $msi = Join-Path $Root 'qemu-ga-x86_64.msi'
    if (-not (Test-Path -LiteralPath $msi)) {
        throw "Missing guest agent installer: $msi"
    }
    Write-Log "msiexec $msi"
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/qn', '/norestart') -Wait -PassThru
    $code = 1
    if ($null -ne $proc) { $code = $proc.ExitCode }
    Write-Log ("msiexec exit {0}" -f $code)
    if ($code -ne 0 -and $code -ne 3010) {
        exit $code
    }

    Set-Content -LiteralPath (Join-Path $Root 'installed.ok') -Value (Get-Date -Format 'o') -Encoding UTF8
    Write-Log 'rebooting so the guest agent can start'
    & shutdown.exe /r /t 10 /f
    exit 0
}
catch {
    Write-Log $_.Exception.Message
    exit 1
}
