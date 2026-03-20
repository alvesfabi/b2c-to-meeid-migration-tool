<#
.SYNOPSIS
    Runs the harvest operation on VM 1 (master/producer) via Azure Bastion.

.PARAMETER ResourceGroup
    Azure resource group. Default: rg-b2c-migration

.PARAMETER BastionName
    Azure Bastion name. Default: bas-b2c-migration

.PARAMETER ConfigFile
    Config file name on the VM (in ~/app/). Default: appsettings.json

.PARAMETER SshKeyPath
    SSH private key path. Default: $env:USERPROFILE\.ssh\b2c-migration-key

.EXAMPLE
    .\scripts\Start-AzureHarvest.ps1
    .\scripts\Start-AzureHarvest.ps1 -ConfigFile appsettings.master.json
#>
param(
    [string]$ResourceGroup = 'rg-b2c-migration',
    [string]$BastionName   = 'bas-b2c-migration',
    [string]$ConfigFile    = 'appsettings.json',
    [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\b2c-migration-key"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "_Common.ps1")
. (Join-Path $PSScriptRoot "Invoke-RemoteCommand.ps1")

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Azure Harvest (VM1)"              -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$vmName = "vm-b2c-worker1"
$cmd = "cd ~/app && dotnet B2CMigrationKit.Console.dll harvest --config $ConfigFile"

Write-Info "Target VM   : $vmName"
Write-Info "Command     : $cmd"
Write-Info "Config      : $ConfigFile"
Write-Host ""
Write-Info "Starting harvest via Bastion SSH tunnel..."
Write-Host ""

try {
    $output = Invoke-RemoteCommand -VmName $vmName -Command $cmd `
        -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath

    Write-Output $output
    Write-Host ""
    Write-Success "✓ Harvest completed on $vmName"
}
catch {
    Write-Err "✗ Harvest failed: $_"
    exit 1
}
