# Turns the services that were disabled on the disk back to their saved start
# type, then starts them. Run elevated on the guest, or through
# lab-ctl.sh restore-services. Safe to run twice.
$ErrorActionPreference = 'Stop'
$Root = 'C:\Windows\Temp\pve-ga'
$List = Join-Path $Root 'held-services.tsv'
$Log = Join-Path $Root 'restore-services.log'

function Write-Log([string]$Message) {
    Add-Content -LiteralPath $Log -Value ('{0} {1}' -f (Get-Date -Format 'o'), $Message) -Encoding UTF8
}

if (-not (Test-Path -LiteralPath $List)) {
    Write-Log 'no held-services.tsv; nothing to restore'
    Write-Output 'Nothing to restore.'
    exit 0
}

$rows = @()
foreach ($line in Get-Content -LiteralPath $List) {
    if ($line -match '^(?<name>[^\t]+)\t(?<start>[0-3])\s*$') {
        $rows += [pscustomobject]@{ Name = $Matches['name']; Start = [int]$Matches['start'] }
    }
}
# The database engine first, then Configuration Manager.
$rows = $rows | Sort-Object @{ Expression = { $_.Name -like 'SMS*' } }, Name

$failed = 0
foreach ($row in $rows) {
    $key = "HKLM:\SYSTEM\CurrentControlSet\Services\$($row.Name)"
    if (-not (Test-Path -LiteralPath $key)) {
        Write-Log "$($row.Name): service not found"
        continue
    }
    Set-ItemProperty -LiteralPath $key -Name 'Start' -Value $row.Start -Type DWord
    Write-Log "$($row.Name): start type $($row.Start)"
}
foreach ($row in $rows) {
    if ($row.Start -ne 2) { continue }
    try {
        $service = Get-Service -Name $row.Name -ErrorAction Stop
        if ($service.Status -ne 'Running') {
            Start-Service -Name $row.Name -ErrorAction Stop
            Write-Log "$($row.Name): started"
        }
    }
    catch {
        $failed++
        Write-Log "$($row.Name): $($_.Exception.Message)"
    }
}
Write-Output ('Restored {0} services, {1} did not start.' -f $rows.Count, $failed)
if ($failed -eq 0) {
    Move-Item -LiteralPath $List -Destination "$List.restored" -Force
}
exit $failed
