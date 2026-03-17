<#
.SYNOPSIS
    Opens a Bastion SSH tunnel to a worker VM.

.DESCRIPTION
    Wraps 'az network bastion tunnel' for quick SSH access to worker VMs.
    Each VM gets a unique local port (2201-2204). After running this,
    SSH in a separate terminal: ssh -p <port> azureuser@localhost

.PARAMETER WorkerIndex
    Worker number (1-4). Default: 1

.PARAMETER ResourceGroup
    Resource group name. Default: rg-b2c-migration

.PARAMETER SubscriptionId
    Azure subscription ID. If not specified, uses current az account.

.EXAMPLE
    # Terminal 1: open tunnel
    ./Connect-Worker.ps1 -WorkerIndex 1

    # Terminal 2: SSH through tunnel
    ssh -p 2201 azureuser@localhost

    # On the VM: run migration
    cd /opt/b2c-migration/app
    ./B2CMigrationKit.Console worker-migrate --config appsettings.json
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 4)]
    [int]$WorkerIndex = 1,

    [string]$ResourceGroup = 'rg-b2c-migration',

    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

$vmName = "vm-b2c-worker$WorkerIndex"
$localPort = 2200 + $WorkerIndex
$bastionName = 'bastion-b2c-migration'

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv)
}

$vmResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

Write-Host "Opening Bastion tunnel to $vmName on localhost:$localPort" -ForegroundColor Cyan
Write-Host "In another terminal, run:" -ForegroundColor Yellow
Write-Host "  ssh -p $localPort azureuser@localhost" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+C to close the tunnel." -ForegroundColor DarkGray

az network bastion tunnel `
    --name $bastionName `
    --resource-group $ResourceGroup `
    --target-resource-id $vmResourceId `
    --resource-port 22 `
    --port $localPort
