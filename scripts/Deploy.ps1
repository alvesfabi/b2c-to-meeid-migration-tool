<#
.SYNOPSIS
    Deploy B2C-to-MEEID migration infrastructure and worker app.

.DESCRIPTION
    PowerShell port of deploy.sh. Requires PowerShell 5.1+, Azure CLI, dotnet SDK, ssh-keygen.

.PARAMETER Teardown
    Delete the resource group instead of deploying.

.PARAMETER Location
    Azure region (default: eastus).

.PARAMETER ResourceGroup
    Resource group name (default: rg-b2c-migration).

.PARAMETER StorageAccountName
    Globally unique storage account name. Prompted if not supplied.

.PARAMETER VmCount
    Number of worker VMs (default: 2).

.PARAMETER VmSize
    VM SKU (default: Standard_B2s).
#>
[CmdletBinding()]
param(
    [switch]$Teardown,

    [string]$Location            = $(if ($env:LOCATION)             { $env:LOCATION }             else { 'eastus' }),
    [string]$ResourceGroup       = $(if ($env:RESOURCE_GROUP)       { $env:RESOURCE_GROUP }       else { 'rg-b2c-migration' }),
    [string]$StorageAccountName  = $(if ($env:STORAGE_ACCOUNT_NAME) { $env:STORAGE_ACCOUNT_NAME } else { '' }),
    [int]   $VmCount             = $(if ($env:VM_COUNT)             { [int]$env:VM_COUNT }        else { 2 }),
    [string]$VmSize              = $(if ($env:VM_SIZE)              { $env:VM_SIZE }              else { 'Standard_B2s' })
)

$ErrorActionPreference = 'Stop'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$RepoRoot  = Split-Path -Parent $ScriptDir
$SshKeyPath = Join-Path $env:USERPROFILE '.ssh\b2c-migration-key'
$AdminUsername = 'azureuser'

# ---------- Helpers ----------
function Write-Info  { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Green }
function Write-Warn  { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Err   { param([string]$Msg) Write-Host "[ERROR] $Msg" -ForegroundColor Red }

function Assert-Command {
    param([string]$Name, [string]$InstallHint)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        Write-Err "$Name not found. $InstallHint"
        exit 1
    }
}

# ---------- Teardown mode ----------
if ($Teardown) {
    Write-Info "Tearing down resource group: $ResourceGroup"
    az group delete --name $ResourceGroup --yes --no-wait
    if ($LASTEXITCODE -ne 0) { Write-Err "Failed to initiate deletion."; exit 1 }
    Write-Info "Deletion initiated (--no-wait). Monitor with: az group show -n $ResourceGroup"
    exit 0
}

# ---------- Prerequisites ----------
Write-Info "Checking prerequisites..."

Assert-Command 'az'         'Install: https://aka.ms/install-azure-cli'
Assert-Command 'dotnet'     'Install: https://dot.net/download'
Assert-Command 'ssh-keygen' 'ssh-keygen not found. Install OpenSSH.'

# Verify logged in
try {
    $null = az account show 2>$null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Err "Not logged in to Azure. Run: az login"
    exit 1
}
$currentUser = az account show --query user.name -o tsv
Write-Info "Logged in as: $currentUser"

# ---------- Storage account name ----------
if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
    $StorageAccountName = Read-Host 'Storage account name (globally unique, 3-24 lowercase alphanum)'
    if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
        Write-Err 'Storage account name is required.'
        exit 1
    }
}

# ---------- SSH key ----------
if (-not (Test-Path $SshKeyPath)) {
    Write-Info "Generating SSH keypair at $SshKeyPath"
    $sshDir = Split-Path -Parent $SshKeyPath
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    ssh-keygen -t ed25519 -C 'b2c-migration' -f $SshKeyPath -N '""'
    if ($LASTEXITCODE -ne 0) { Write-Err 'Failed to generate SSH key.'; exit 1 }
}
$SshPubKey = Get-Content "${SshKeyPath}.pub" -Raw
$SshPubKey = $SshPubKey.Trim()

# ---------- Deploy infrastructure ----------
Write-Info "Deploying infrastructure (location=$Location, rg=$ResourceGroup, vms=$VmCount, size=$VmSize)..."

$templateFile = Join-Path $RepoRoot 'infra\main.bicep'

$deploymentJson = az deployment sub create `
    --location $Location `
    --template-file $templateFile `
    --parameters `
        location=$Location `
        resourceGroupName=$ResourceGroup `
        storageAccountName=$StorageAccountName `
        vmCount=$VmCount `
        vmSize=$VmSize `
        adminUsername=$AdminUsername `
        adminSshPublicKey=$SshPubKey `
    --query 'properties.outputs' -o json

if ($LASTEXITCODE -ne 0) {
    Write-Err 'Infrastructure deployment failed.'
    exit 1
}

$outputs = $deploymentJson | ConvertFrom-Json
$BastionName   = $outputs.bastionName.value
$StorageName   = $outputs.storageAccountName.value
$QueueEndpoint = $outputs.storageQueueEndpoint.value

Write-Info "Infrastructure deployed successfully."
Write-Info "  Bastion: $BastionName"
Write-Info "  Storage: $StorageName"
Write-Info "  Queue:   $QueueEndpoint"

# ---------- Build .NET app ----------
$AppDir     = Join-Path $RepoRoot 'src'
$PublishDir = Join-Path $RepoRoot 'publish'

if (Test-Path $AppDir) {
    Write-Info "Building .NET console app..."
    dotnet publish $AppDir -c Release -o $PublishDir --nologo -v quiet
    if ($LASTEXITCODE -ne 0) { Write-Err 'dotnet publish failed.'; exit 1 }
    Write-Info "Published to $PublishDir"
} else {
    Write-Warn "No src/ directory found - skipping dotnet build."
    $PublishDir = ''
}

# ---------- Deploy app to VMs via Bastion tunnel ----------
if ($PublishDir -and (Test-Path $PublishDir)) {
    for ($i = 1; $i -le $VmCount; $i++) {
        $vmName = "vm-b2c-worker${i}"
        Write-Info "Deploying app to $vmName..."

        $vmId = az vm show --resource-group $ResourceGroup --name $vmName --query id -o tsv
        if ($LASTEXITCODE -ne 0) { Write-Warn "Could not find $vmName - skipping."; continue }

        $localPort = 2200 + $i

        # Open Bastion tunnel in background
        $tunnelProcess = Start-Process -FilePath 'az' -ArgumentList @(
            'network', 'bastion', 'tunnel',
            '--name', $BastionName,
            '--resource-group', $ResourceGroup,
            '--target-resource-id', $vmId,
            '--resource-port', '22',
            '--port', $localPort
        ) -PassThru -WindowStyle Hidden

        # Wait for tunnel to be ready
        Start-Sleep -Seconds 10

        try {
            # SCP published app
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
                -P $localPort -i $SshKeyPath `
                -r "$PublishDir\*" "${AdminUsername}@127.0.0.1:/home/${AdminUsername}/app/"

            # Copy appsettings if exists
            $appSettings = Join-Path $RepoRoot 'appsettings.json'
            if (Test-Path $appSettings) {
                scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
                    -P $localPort -i $SshKeyPath `
                    $appSettings "${AdminUsername}@127.0.0.1:/home/${AdminUsername}/app/"
            }
        } catch {
            Write-Warn "SCP to $vmName failed - you may need to copy manually."
        }

        # Kill tunnel
        try { Stop-Process -Id $tunnelProcess.Id -Force -ErrorAction SilentlyContinue } catch {}

        Write-Info "  $vmName done."
    }
}

# ---------- Summary ----------
Write-Host ''
Write-Host '============================================================'
Write-Host '  B2C Migration Infrastructure - Deployment Complete'
Write-Host '============================================================'
Write-Host ''
Write-Host "  Resource Group:  $ResourceGroup"
Write-Host "  Location:        $Location"
Write-Host "  Storage Account: $StorageName"
Write-Host "  Queue Endpoint:  $QueueEndpoint"
Write-Host "  Bastion:         $BastionName"
Write-Host "  Worker VMs:      $VmCount"
Write-Host ''
Write-Host '  SSH to a worker via Bastion:'
Write-Host "    az network bastion ssh ```"
Write-Host "      --name $BastionName ```"
Write-Host "      --resource-group $ResourceGroup ```"
Write-Host "      --target-resource-id <VM_RESOURCE_ID> ```"
Write-Host "      --auth-type ssh-key ```"
Write-Host "      --username $AdminUsername ```"
Write-Host "      --ssh-key $SshKeyPath"
Write-Host ''
Write-Host '  List VM IDs:'
Write-Host "    az vm list -g $ResourceGroup --query '[].{name:name, id:id}' -o table"
Write-Host ''
Write-Host '  Teardown:'
Write-Host '    .\scripts\Deploy.ps1 -Teardown'
Write-Host '============================================================'
