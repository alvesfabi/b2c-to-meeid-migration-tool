<#
.SYNOPSIS
    Starts worker processes on all Azure VMs in parallel via Bastion.

.DESCRIPTION
    Launches a separate PowerShell window for each VM, each running the specified
    command (worker-migrate or phone-registration) via Bastion SSH.

.PARAMETER ResourceGroup
    Azure resource group. Default: rg-b2c-migration

.PARAMETER BastionName
    Azure Bastion name. Default: bas-b2c-migration

.PARAMETER VmCount
    Number of worker VMs. Default: 2

.PARAMETER Command
    Worker command to run. Default: worker-migrate
    Also accepts: phone-registration

.PARAMETER ConfigFile
    Config file name on the VM (in ~/app/). Default: appsettings.json

.PARAMETER SshKeyPath
    SSH private key path. Default: $env:USERPROFILE\.ssh\b2c-migration-key

.EXAMPLE
    .\scripts\Start-AzureWorkers.ps1
    .\scripts\Start-AzureWorkers.ps1 -VmCount 4 -Command phone-registration
#>
param(
    [string]$ResourceGroup = 'rg-b2c-migration',
    [string]$BastionName   = 'bas-b2c-migration',
    [int]   $VmCount       = 2,
    [string]$Command       = 'worker-migrate',
    [string]$ConfigFile    = 'appsettings.json',
    [string]$SshKeyPath    = "$env:USERPROFILE\.ssh\b2c-migration-key"
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot "_Common.ps1")

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Start Azure Workers"              -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

Write-Info "Command     : $Command"
Write-Info "Config      : $ConfigFile"
Write-Info "VM count    : $VmCount"
Write-Info "SSH key     : $SshKeyPath"
Write-Host ""

if (-not (Test-Path $SshKeyPath)) {
    Write-Err "SSH key not found at '$SshKeyPath'."
    exit 1
}

$launched = @()

for ($i = 1; $i -le $VmCount; $i++) {
    $vmName = "vm-b2c-worker${i}"
    Write-Info "Launching worker on $vmName..."

    # Resolve VM resource ID
    $vmId = az vm show -g $ResourceGroup -n $vmName --query id -o tsv 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Err "  ✗ Could not resolve VM '$vmName': $vmId"
        continue
    }

    $remoteCmd = "cd ~/app && dotnet B2CMigrationKit.Console.dll $Command --config $ConfigFile"

    # Build the az bastion ssh command as a single string for Start-Process
    $azArgs = "network bastion ssh " +
        "--name $BastionName " +
        "--resource-group $ResourceGroup " +
        "--target-resource-id $vmId " +
        "--auth-type ssh-key " +
        "--username azureuser " +
        "--ssh-key `"$SshKeyPath`" " +
        "--command `"$remoteCmd`""

    # Launch in a new PowerShell window with a descriptive title
    $title = "[$vmName] $Command"
    $psCmd = "host.ui.RawUI.WindowTitle = '$title'; az $azArgs; Read-Host 'Press Enter to close'"

    Start-Process powershell -ArgumentList "-NoExit", "-Command", $psCmd
    $launched += $vmName
    Write-Success "  ✓ $vmName — window launched"
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Workers launched: $($launched.Count) / $VmCount"       -ForegroundColor Cyan
foreach ($vm in $launched) {
    Write-Host "    • $vm"                                           -ForegroundColor Green
}
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Info "Each worker runs in its own window. Close windows or use Stop-AzureWorkers.ps1 to stop."
