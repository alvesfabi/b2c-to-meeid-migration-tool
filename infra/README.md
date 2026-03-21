# Azure VM Deployment Runbook

End-to-end guide for deploying and operating the B2C Migration Kit on Azure VMs via Bastion.

**Key design**: VMs have no public IPs. All access is through Azure Bastion SSH tunnels. The deploy scripts build the .NET app locally and SCP the published output to each VM. Storage uses private endpoints with Managed Identity — no connection strings on the VMs.

> For local development, see [scripts/README.md](../scripts/README.md). For architecture details, see [docs/ARCHITECTURE_GUIDE.md](../docs/ARCHITECTURE_GUIDE.md).

---

## Prerequisites

| Requirement | Check |
|-------------|-------|
| Azure CLI | `az --version` |
| .NET 8.0 SDK | `dotnet --version` |
| SSH (ssh-keygen, scp) | `ssh -V` |
| PowerShell 7+ | `pwsh --version` (for `.ps1` operation scripts) |
| Azure subscription access | `az login && az account show` |
| B2C + External ID app registrations | See Step 1 below |

---

## Step 1: Create App Registrations

Each worker VM needs dedicated app registrations (B2C + EEID) for independent throttle quotas.

```powershell
# Provision workers 1-4 (interactive device code auth)
.\scripts\New-WorkerAppRegistrations.ps1 -StartWorker 1 -EndWorker 4

# Preview without changes
.\scripts\New-WorkerAppRegistrations.ps1 -WhatIf
```

This creates app registrations in both tenants, grants admin consent, generates secrets, and writes `appsettings.workerN.json` files.

---

## Step 2: Deploy Infrastructure

### Option A: PowerShell

```powershell
.\scripts\Deploy.ps1 -StorageAccountName "stb2cmigration" -VmCount 2
```

### Option B: Bash

```bash
STORAGE_ACCOUNT_NAME=stb2cmigration VM_COUNT=2 ./scripts/deploy.sh
```

**What this does:**
1. Generates SSH keypair at `~/.ssh/b2c-migration-key` (if missing)
2. Deploys Bicep templates (VNet, Bastion, Storage with private endpoints, VMs)
3. Builds .NET app locally (`dotnet publish`)
4. SCPs published app to each VM via Bastion tunnel → `~/app/`

### Configuration

After deploy, copy your config to the VMs. The deploy script copies `appsettings.json` from repo root if it exists. Use `appsettings.azure-deploy.example.json` as a template:

```bash
cp appsettings.azure-deploy.example.json appsettings.json
# Edit with your tenant credentials, then re-deploy or SCP manually
```

| Parameter | Default | Env Var |
|-----------|---------|---------|
| Location | `eastus` | `LOCATION` |
| Resource Group | `rg-b2c-migration` | `RESOURCE_GROUP` |
| Storage Account | *(prompted)* | `STORAGE_ACCOUNT_NAME` |
| VM Count | `2` | `VM_COUNT` |
| VM Size | `Standard_B2s` | `VM_SIZE` |

### Infrastructure Resources (Bicep)

| Resource | Name Pattern | Purpose |
|----------|-------------|---------|
| Resource Group | `rg-b2c-migration` | Container for all resources |
| VNet + Subnets | `vnet-b2c-migration` | Workers subnet + PE subnet |
| Bastion | `bas-b2c-migration` | SSH access without public IPs |
| Storage Account | *(user-specified)* | Queues + Tables (private endpoints) |
| Worker VMs | `vm-b2c-worker{N}` | Run migration workloads |

---

## Step 3: Run Migration

### 3a. Harvest (enqueue user IDs — run once on VM1)

```powershell
.\scripts\Start-AzureHarvest.ps1
```

### 3b. Worker Migrate (parallel on all VMs)

```powershell
# Opens a separate window per VM
.\scripts\Start-AzureWorkers.ps1 -VmCount 2
```

### 3c. Phone Registration (after or alongside workers)

```powershell
.\scripts\Start-AzureWorkers.ps1 -VmCount 2 -Command phone-registration
```

### Typical Sequence

```powershell
# 1. Clear queues from any previous run
.\scripts\Clear-MigrationQueues.ps1 -StorageAccountName stb2cmigration

# 2. Harvest
.\scripts\Start-AzureHarvest.ps1

# 3. Start workers
.\scripts\Start-AzureWorkers.ps1

# 4. When workers finish, start phone registration
.\scripts\Start-AzureWorkers.ps1 -Command phone-registration
```

---

## Step 4: Monitor

### Quick health check

```powershell
.\scripts\Get-AzureWorkerStatus.ps1
```

Shows per-VM: running processes, disk/memory usage, telemetry file sizes.

### Download & analyze telemetry

```powershell
# Download JSONL files from all VMs
.\scripts\Get-AzureTelemetry.ps1

# Download and run analysis
.\scripts\Get-AzureTelemetry.ps1 -Analyze

# Analyze previously downloaded files
.\scripts\Analyze-Telemetry.ps1 -ConsoleDir .\telemetry\20250321-143000 -WorkerCount 2
```

---

## Step 5: Cleanup

### Stop workers

```powershell
.\scripts\Stop-AzureWorkers.ps1
```

### Clean up test users (optional)

```powershell
.\scripts\Remove-BulkExternalIdUsers.ps1 -WhatIf   # preview
.\scripts\Remove-BulkExternalIdUsers.ps1 -Force     # delete
```

### Tear down infrastructure

```powershell
.\scripts\Teardown.ps1          # PowerShell (interactive confirm)
.\scripts\Teardown.ps1 -Force   # skip confirmation
# or
./scripts/teardown.sh           # Bash
# or
.\scripts\Deploy.ps1 -Teardown  # via deploy script
```

---

## Troubleshooting

| Issue | Solution |
|-------|---------|
| `az network bastion ssh` hangs | Check Bastion is deployed and healthy in Portal. Ensure `az` CLI is up to date. |
| SCP fails during deploy | Tunnel may need more time. Increase sleep in deploy script. Retry manually. |
| VM can't access storage | Verify private endpoint + DNS. Check VM has Managed Identity with `Storage Queue Data Contributor` + `Storage Table Data Contributor`. |
| Workers exit immediately | SSH into VM and check `~/app/appsettings.json`. Verify config has correct tenant IDs and secrets. |
| No telemetry files | Workers haven't started or exited with error. Run `Get-AzureWorkerStatus.ps1` to check. |
| Queues not clearing | Queues are accessed via private endpoints. `Clear-MigrationQueues.ps1` runs the clear command on VM1 for this reason. |

### Manual SSH via Bastion

```powershell
# List VM IDs
az vm list -g rg-b2c-migration --query '[].{name:name, id:id}' -o table

# SSH to a VM
az network bastion ssh `
  --name bas-b2c-migration `
  --resource-group rg-b2c-migration `
  --target-resource-id <VM_RESOURCE_ID> `
  --auth-type ssh-key `
  --username azureuser `
  --ssh-key ~/.ssh/b2c-migration-key
```
