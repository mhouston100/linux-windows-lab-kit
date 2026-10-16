# Runs once at the automatic logon planted before this VM's first boot.
# Installs VirtualBox Guest Additions from the files copied to this folder,
# then reboots so the additions service can report in to the host.
$ErrorActionPreference = 'Stop'
$Root = 'C:\Windows\Temp\vbox-ga'
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

    $cert = Join-Path $Root 'cert\VBoxCertUtil.exe'
    $publisher = Join-Path $Root 'cert\vbox-sha256.cer'
    $rootCer = Join-Path $Root 'cert\vbox-sha256-root.cer'
    if ((Test-Path -LiteralPath $cert) -and (Test-Path -LiteralPath $publisher)) {
        Write-Log 'trusting Oracle publisher cert'
        & $cert add-trusted-publisher $publisher --root $rootCer
        Write-Log ("certutil exit {0}" -f $LASTEXITCODE)
    }

    $exe = Join-Path $Root 'VBoxWindowsAdditions-amd64.exe'
    if (-not (Test-Path -LiteralPath $exe)) {
        throw "Missing installer: $exe"
    }
    $setupLog = Join-Path $Root 'vbox-setup.log'
    Write-Log "running $exe"
    $proc = Start-Process -FilePath $exe -ArgumentList @('/S', '/l', $setupLog) -Wait -PassThru
    $code = 1
    if ($null -ne $proc) { $code = $proc.ExitCode }
    Write-Log ("installer exit {0}" -f $code)
    if ($code -ne 0 -and $code -ne 3010) {
        exit $code
    }

    Set-Content -LiteralPath (Join-Path $Root 'installed.ok') -Value (Get-Date -Format 'o') -Encoding UTF8
    Write-Log 'rebooting so the additions service can start'
    & shutdown.exe /r /t 10 /f
    exit 0
}
catch {
    Write-Log $_.Exception.Message
    exit 1
}
