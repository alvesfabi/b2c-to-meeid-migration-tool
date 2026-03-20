<#
.SYNOPSIS
    Runs a command on an Azure VM via Bastion SSH tunnel.

.DESCRIPTION
    Internal helper used by other Azure VM operational scripts.
    Wraps `az network bastion ssh --command` for single-shot remote execution.

.PARAMETER ResourceGroup
    Azure resource group name. Default: rg-b2c-migration

.PARAMETER BastionName
    Azure Bastion resource name. Default: bas-b2c-migration

.PARAMETER VmName
    Name of the target VM (e.g. vm-b2c-worker1).

.PARAMETER Command
    Shell command to execute on the VM.

.PARAMETER SshKeyPath
    Path to the SSH private key. Default: $env:USERPROFILE\.ssh\b2c-migration-key

.EXAMPLE
    . .\scripts\Invoke-RemoteCommand.ps1
    $output = Invoke-RemoteCommand -VmName "vm-b2c-worker1" -Command "hostname"
#>
param(
    [string]$ResourceGroup = 'rg-b2c-migration',
    [string]$BastionName   = 'bas-b2c-migration',
    [string]$VmName,
    [string]$Command,
    [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\b2c-migration-key"
)

$ErrorActionPreference = 'Stop'

function Invoke-RemoteCommand {
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$Command,
        [string]$ResourceGroup = 'rg-b2c-migration',
        [string]$BastionName   = 'bas-b2c-migration',
        [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\b2c-migration-key"
    )

    # Resolve VM resource ID
    $vmId = az vm show -g $ResourceGroup -n $VmName --query id -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve VM '$VmName' in resource group '$ResourceGroup': $vmId"
    }

    # Validate SSH key exists
    if (-not (Test-Path $SshKeyPath)) {
        throw "SSH key not found at '$SshKeyPath'. Generate with: ssh-keygen -t ed25519 -f `"$SshKeyPath`""
    }

    # Execute command via Bastion SSH
    $output = az network bastion ssh `
        --name $BastionName `
        --resource-group $ResourceGroup `
        --target-resource-id $vmId `
        --auth-type ssh-key `
        --username azureuser `
        --ssh-key $SshKeyPath `
        --command $Command 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Remote command failed on '$VmName': $output"
    }

    return $output
}

# If called directly (not dot-sourced), execute the command
if ($VmName -and $Command) {
    $result = Invoke-RemoteCommand -VmName $VmName -Command $Command `
        -ResourceGroup $ResourceGroup -BastionName $BastionName -SshKeyPath $SshKeyPath
    Write-Output $result
}
