<#
.SYNOPSIS
    Purges Azure Storage migration queues via a VM (private endpoint access).

.DESCRIPTION
    Since the storage account uses private endpoints (no public access), queue
    operations must be executed from inside a VM that has network access.
    This script SSH-es into VM1 via Bastion and runs `az storage message clear`.

.PARAMETER ResourceGroup
    Azure resource group. Default: rg-b2c-migration

.PARAMETER BastionName
    Azure Bastion name. Default: bas-b2c-migration

.PARAMETER StorageAccountName
    Name of the Azure Storage account. Required.

.PARAMETER SshKeyPath
    SSH private key path. Default: $env:USERPROFILE\.ssh\b2c-migration-key

.EXAMPLE
    .\scripts\Clear-MigrationQueues.ps1 -StorageAccountName stb2cmigration
#>
param(
    [Parameter(Mandatory)]
    [string]$StorageAccountName,

    [string]$ResourceGroup = 'rg-b2c-migration',
    [string]$BastionName   = 'bas-b2c-migration',
    [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\b2c-migration-key"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "_Common.ps1")
. (Join-Path $PSScriptRoot "Invoke-RemoteCommand.ps1")

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Clear Migration Queues"           -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$vmName = "vm-b2c-worker1"
$queues = @("user-ids-to-process", "phone-registration")

Write-Info "Storage account : $StorageAccountName"
Write-Info "Queues to clear : $($queues -join ', ')"
Write-Info "Executing via   : $vmName (private endpoint access)"
Write-Host ""

$cleared = 0
$failed  = 0

foreach ($queue in $queues) {
    Write-Info "Clearing queue '$queue'..."

    try {
        $cmd = "az storage message clear --queue-name $queue --account-name $StorageAccountName --auth-mode login 2>&1 || echo 'QUEUE_CLEAR_FAILED'"
        $output = Invoke-RemoteCommand -VmName $vmName -Command $cmd `
            -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath

        if ($output -match 'QUEUE_CLEAR_FAILED') {
            Write-Warn "  ⚠ Queue '$queue' — may not exist or clear failed"
            Write-Warn "    $output"
            $failed++
        }
        else {
            Write-Success "  ✓ Queue '$queue' cleared"
            $cleared++
        }
    }
    catch {
        Write-Err "  ✗ Queue '$queue' — error: $_"
        $failed++
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Cleared: $cleared / $($queues.Count)   Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { "Yellow" } else { "Green" })
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
