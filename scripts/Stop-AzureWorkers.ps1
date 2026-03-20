<#
.SYNOPSIS
    Kills running migration worker processes on all Azure VMs.

.PARAMETER ResourceGroup
    Azure resource group. Default: rg-b2c-migration

.PARAMETER BastionName
    Azure Bastion name. Default: bas-b2c-migration

.PARAMETER VmCount
    Number of worker VMs. Default: 2

.PARAMETER SshKeyPath
    SSH private key path. Default: $env:USERPROFILE\.ssh\b2c-migration-key

.EXAMPLE
    .\scripts\Stop-AzureWorkers.ps1
    .\scripts\Stop-AzureWorkers.ps1 -VmCount 4
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
Write-Host "  B2C Migration Kit - Stop Azure Workers"               -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$stopped = 0
$failed  = 0

for ($i = 1; $i -le $VmCount; $i++) {
    $vmName = "vm-b2c-worker${i}"
    Write-Info "Stopping workers on $vmName..."

    try {
        $output = Invoke-RemoteCommand -VmName $vmName `
            -Command "pkill -f B2CMigrationKit.Console || true" `
            -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath

        Write-Success "  ✓ $vmName — processes killed"
        $stopped++
    }
    catch {
        Write-Err "  ✗ $vmName — failed: $_"
        $failed++
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Stopped: $stopped / $VmCount   Failed: $failed"       -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "Green" })
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
