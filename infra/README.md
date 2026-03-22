# Infrastructure Guide

## Prerequisites

- Azure subscription with **Contributor** access
- SSH key pair for VM access: `ssh-keygen -t ed25519 -f scripts/b2c-mig-deploy -C "b2c-migration"`
- Azure CLI (`az`) installed and logged in (`az login`)
- PowerShell 7+

## Architecture

Deploy-All.ps1 creates the following resources:

- **Resource Group** with VNet, NAT Gateway, NSGs
- **Worker VMs** (Ubuntu 22.04, configurable count 1–16) with managed identity
- **Storage Account** with Queue, Blob, and Table Storage (private endpoints)
- **Key Vault** (deployed but not used for config currently)
- **Bastion** for secure SSH access (no public IPs on VMs)

VMs clone the repo from GitHub, build the .NET app locally, and copy the example config as a starting point.

## Quick Start

```powershell
# Full deployment (infra + VM provisioning)
./scripts/Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile ./scripts/b2c-mig-deploy.pub

# Re-provision VMs only (infra already exists)
./scripts/Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile ./scripts/b2c-mig-deploy.pub -SkipInfra
```

The script auto-detects your Git remote URL and current branch. Override with `-GitRepo` and `-GitBranch` if needed.

## Deploy-All.ps1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ResourceGroup` | *(required)* | Target Azure resource group |
| `-Location` | `eastus2` | Azure region |
| `-VmCount` | `4` | Number of worker VMs (1–16) |
| `-VmSize` | `Standard_B2s` | VM SKU |
| `-AdminUsername` | `azureuser` | VM admin user |
| `-SshPublicKeyFile` | `~/.ssh/id_ed25519.pub` | Path to SSH public key |
| `-DeployBastion` | `true` | Whether to deploy Azure Bastion |
| `-GitRepo` | *(auto-detected)* | Git repo URL for VMs to clone |
| `-GitBranch` | *(auto-detected)* | Git branch to checkout on VMs |
| `-ConfigProfile` | `worker` | Config file prefix (for example config copy) |
| `-SkipInfra` | `false` | Skip Bicep deployment, only re-provision VMs |
| `-WhatIf` | `false` | Dry run |

## Pipeline Steps

1. **Deploy infrastructure** via `az deployment sub create` (Bicep modules: network, storage, vm, keyvault, bastion)
2. **Provision each VM** via `az vm run-command invoke`:
   - Install .NET SDK 8.0 + git (if not present)
   - Clone the repo from GitHub
   - `dotnet publish` the console app to `/opt/b2c-migration/app/`
   - Copy `appsettings.worker1.example.json` as `appsettings.json`

## Connect via Bastion

SSH to VMs through Azure Bastion tunnel (no public IPs):

```powershell
# Terminal 1: open tunnel to worker 1 (port 2201)
./scripts/Connect-Worker.ps1 -WorkerIndex 1

# Terminal 2: SSH through tunnel
ssh -p 2201 -i ./scripts/b2c-mig-deploy azureuser@localhost
```

Each VM maps to port `2200 + WorkerIndex` (2201, 2202, 2203, 2204, ...).

## Configure Workers

After connecting via SSH, edit the config with your actual tenant credentials and secrets:

```bash
nano /opt/b2c-migration/app/appsettings.json
```

The example config is already in place with placeholder values. Fill in:
- B2C tenant ID, domain, and app registration credentials
- External ID tenant ID, domain, and app registration credentials
- Storage account connection settings (VMs use managed identity)

**Important**: Each worker needs a **dedicated app registration** on a dedicated IP for independent Graph API throttle quotas.

## Run Migration

On each worker VM:

```bash
cd /opt/b2c-migration/app

# Step 1: Harvest (run on ONE worker only — populates the queue)
./B2CMigrationKit.Console harvest --config appsettings.json

# Step 2: Worker migrate (run on ALL workers in parallel)
./B2CMigrationKit.Console worker-migrate --config appsettings.json

# Step 3: Phone registration (run on ALL workers after step 2 completes)
./B2CMigrationKit.Console phone-registration --config appsettings.json
```

## Monitor

```powershell
.\scripts\Watch-Migration.ps1 -WorkerCount 4 -RefreshSeconds 3
```

## Teardown

```bash
# Stop VMs (keeps disks, $0 compute)
for i in 1 2 3 4; do
  az vm deallocate -g rg-b2c-eeid-mig-test1 -n vm-b2c-worker$i --no-wait
done

# Stop Bastion
az network bastion delete -g rg-b2c-eeid-mig-test1 -n bastion-b2c-migration

# Full cleanup (deletes everything)
az group delete -n rg-b2c-eeid-mig-test1 --yes --no-wait
```

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `403 Insufficient privileges` on Graph | App registration missing permissions | Grant `User.ReadWrite.All`, `Directory.ReadWrite.All`; run `Validate-MigrationReadiness.ps1` to verify |
| `AuthenticationFailedException` | Wrong tenant ID or expired secret | Check `appsettings.json` credentials; rotate client secret in Entra |
| Bastion tunnel hangs | NSG blocking port 22, or Bastion not running | Verify NSG allows SSH from Bastion subnet; check `az network bastion show` |
| `run-command` times out | Azure policy blocks RunCommand extension | Deploy manually via Bastion (step 5) using `Setup-Worker.sh` |
| `QueueNotFound` / `TableNotFound` | Storage containers not created | Run `Validate-MigrationReadiness.ps1 -Mode worker`; or create manually: `az storage queue create` |
| Throttling (429 responses) | Too many workers hitting Graph simultaneously | Reduce worker count or increase `ThrottleDelayMs` in config |
| Phone registration failures | Temporary Auth Session API limits | Retry with fewer concurrent workers; check telemetry for specific error codes |
| VM can't reach storage | Private Endpoint DNS not resolving | Verify Private DNS Zone linked to VNet; `nslookup <account>.queue.core.windows.net` from VM |
| Telemetry files empty | App crashed on start | SSH into VM, check `journalctl` or `~/.b2c-migration/logs/` |

## Architecture

See [Architecture Guide § 9](../docs/ARCHITECTURE_GUIDE.md#9-deployment--operations) for diagrams and design decisions.
