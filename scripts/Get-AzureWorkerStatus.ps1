<#
.SYNOPSIS
    Quick health check — shows what's running on each Azure VM.

.DESCRIPTION
    SSH-es into each VM via Bastion and checks running processes, disk usage,
    and memory. Displays a formatted summary.

.PARAMETER ResourceGroup
    Azure resource group. Default: rg-b2c-migration

.PARAMETER BastionName
    Azure Bastion name. Default: bas-b2c-migration

.PARAMETER VmCount
    Number of worker VMs. Default: 2

.PARAMETER SshKeyPath
    SSH private key path. Default: $env:USERPROFILE\.ssh\b2c-migration-key

.EXAMPLE
    .\scripts\Get-AzureWorkerStatus.ps1
    .\scripts\Get-AzureWorkerStatus.ps1 -VmCount 4
#>
param(
    [string]$ResourceGroup = 'rg-b2c-migration',
    [string]$BastionName   = 'bas-b2c-migration',
    [int]   $VmCount       = 2,
    [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\b2c-migration-key"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "_Common.ps1")
. (Join-Path $PSScriptRoot "Invoke-RemoteCommand.ps1")

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Azure Worker Status"              -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

for ($i = 1; $i -le $VmCount; $i++) {
    $vmName = "vm-b2c-worker${i}"

    Write-Host "────────────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "  $vmName" -ForegroundColor Cyan
    Write-Host "────────────────────────────────────────────────────" -ForegroundColor DarkGray

    try {
        # Check running migration processes
        $cmd = "ps aux | grep B2CMigrationKit | grep -v grep || echo 'NO_PROCESSES'"
        $procs = Invoke-RemoteCommand -VmName $vmName -Command $cmd `
            -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath

        if ($procs -match 'NO_PROCESSES') {
            Write-Warn "  Processes : none running"
        }
        else {
            Write-Success "  Processes : ACTIVE"
            $procs -split "`n" | ForEach-Object { Write-Host "    $_" -ForegroundColor White }
        }

        # Disk usage
        $disk = Invoke-RemoteCommand -VmName $vmName -Command "df -h / | tail -1" `
            -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath
        Write-Info "  Disk      : $($disk.Trim())"

        # Memory
        $mem = Invoke-RemoteCommand -VmName $vmName -Command "free -m | grep Mem" `
            -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath
        Write-Info "  Memory    : $($mem.Trim())"

        # Telemetry file sizes
        $telemetry = Invoke-RemoteCommand -VmName $vmName `
            -Command "ls -lh ~/app/*-telemetry.jsonl 2>/dev/null || echo 'no telemetry files'" `
            -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath
        Write-Info "  Telemetry : $($telemetry.Trim())"
    }
    catch {
        Write-Err "  ✗ Failed to query $vmName : $_"
    }

    Write-Host ""
}

Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Status check complete for $VmCount VM(s)"             -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
