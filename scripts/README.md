# B2C Migration Kit - Scripts

PowerShell and Bash scripts for deploying infrastructure, running bulk migrations, configuring JIT password migration, and analyzing telemetry.

**📖 For complete configuration reference, see the [Developer Guide](../docs/DEVELOPER_GUIDE.md)**
**📖 For Azure VM deployment runbook, see the [Infra README](../infra/README.md)**

## Table of Contents

- [Setup & Deploy](#setup--deploy)
- [Local Development](#local-development)
- [Azure VM Operations](#azure-vm-operations)
- [Telemetry & Analysis](#telemetry--analysis)
- [JIT Password Migration Setup](#jit-password-migration-setup)
- [Utility Scripts](#utility-scripts)

---

## Setup & Deploy

Scripts for provisioning infrastructure, app registrations, and tearing down.

| Script | Description |
|--------|-------------|
| `Deploy.ps1` | Deploy Azure infra (Bicep) + build .NET app + SCP to VMs via Bastion. Also supports `-Teardown`. |
| `deploy.sh` | Bash equivalent of `Deploy.ps1`. Use `--teardown` flag for cleanup. |
| `Teardown.ps1` | Delete the resource group (interactive confirmation, or `-Force`). |
| `teardown.sh` | Bash equivalent of `Teardown.ps1`. |
| `New-WorkerAppRegistrations.ps1` | Provision B2C + EEID app registrations for parallel workers. Generates `appsettings.workerN.json` files. |

### Deploy.ps1 / deploy.sh

```powershell
# Deploy infrastructure + app
.\scripts\Deploy.ps1 -StorageAccountName "stb2cmigration" -VmCount 2

# Bash equivalent
STORAGE_ACCOUNT_NAME=stb2cmigration VM_COUNT=2 ./scripts/deploy.sh
```

| Parameter | Default | Env Var | Description |
|-----------|---------|---------|-------------|
| `-Location` | `eastus` | `LOCATION` | Azure region |
| `-ResourceGroup` | `rg-b2c-migration` | `RESOURCE_GROUP` | Resource group name |
| `-StorageAccountName` | *(prompted)* | `STORAGE_ACCOUNT_NAME` | Globally unique name |
| `-VmCount` | `2` | `VM_COUNT` | Number of worker VMs |
| `-VmSize` | `Standard_B2s` | `VM_SIZE` | VM SKU |

**What it does:** Generates SSH key → deploys Bicep (VNet, Bastion, Storage w/ private endpoints, VMs) → `dotnet publish` locally → SCP to each VM via Bastion tunnel.

### New-WorkerAppRegistrations.ps1

```powershell
.\scripts\New-WorkerAppRegistrations.ps1                          # provision workers 5-8
.\scripts\New-WorkerAppRegistrations.ps1 -StartWorker 2 -EndWorker 4   # specific range
.\scripts\New-WorkerAppRegistrations.ps1 -WhatIf                  # preview only
```

Creates app registrations in B2C and External ID, grants admin consent, generates secrets, writes `appsettings.workerN.json`. Uses device code flow for authentication.

---

## Local Development

Scripts for running migration locally with Azurite. All require Azurite running via VS Code: `Ctrl+Shift+P` → `Azurite: Start Service`.

### Prerequisites

1. **.NET 8.0 SDK** — `dotnet --version` (8.0+)
2. **Azurite VS Code Extension** — `ms-azuretools.vscode-azurite`
3. **Configuration files** — copy `.example.json` templates and fill in credentials (see [Developer Guide](../docs/DEVELOPER_GUIDE.md#configuration-guide))

### Simple Mode (Export → Import)

Two sequential scripts for straightforward migration without MFA phone migration.

| Script | Config Default | Description |
|--------|---------------|-------------|
| `Start-LocalExport.ps1` | `appsettings.export-import.json` | Pages all B2C users → Blob Storage JSON files |
| `Start-LocalImport.ps1` | `appsettings.export-import.json` | Reads blobs → creates users in External ID |

```powershell
.\scripts\Start-LocalExport.ps1
.\scripts\Start-LocalImport.ps1
```

### Advanced Mode (Harvest → Workers)

Queue-based parallel pipeline for large tenants with MFA phone migration.

| Script | Config Default | Description |
|--------|---------------|-------------|
| `Start-LocalHarvest.ps1` | `appsettings.master.json` | Enqueues all B2C user IDs |
| `Start-LocalWorkerMigrate.ps1` | `appsettings.worker1.json` | Dequeues batches, fetches B2C profiles, creates EEID users, enqueues phone tasks |
| `Start-LocalPhoneRegistration.ps1` | `appsettings.phone-registration.json` | Drains phone queue, registers MFA phones in EEID |

```powershell
# 1. Harvest
.\scripts\Start-LocalHarvest.ps1

# 2. Workers (one per terminal, each with different app registration)
.\scripts\Start-LocalWorkerMigrate.ps1
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json

# 3. Phone registration
.\scripts\Start-LocalPhoneRegistration.ps1
```

### Common Parameters

All local scripts accept:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ConfigFile` | *(per script)* | Configuration file path |
| `-VerboseLogging` | `false` | Enable detailed logging |
| `-SkipAzurite` | `false` | Skip Azurite port check (for cloud storage) |

---

## Azure VM Operations

Scripts for operating on Azure VMs accessed via Bastion tunnels. For the full deployment runbook, see **[infra/README.md](../infra/README.md)**.

### Prerequisites

- Logged in via `az login`
- VMs deployed with `Deploy.ps1` or `deploy.sh`
- SSH key at `$env:USERPROFILE\.ssh\b2c-migration-key`

### Script Reference

| Script | Description |
|--------|-------------|
| `Start-AzureHarvest.ps1` | Run harvest on VM1 (master/producer) |
| `Start-AzureWorkers.ps1` | Launch worker processes on all VMs in parallel windows |
| `Stop-AzureWorkers.ps1` | Kill migration processes on all VMs |
| `Get-AzureWorkerStatus.ps1` | Health check: processes, disk, memory, telemetry |
| `Get-AzureTelemetry.ps1` | Download JSONL telemetry from VMs, optionally analyze |
| `Invoke-RemoteCommand.ps1` | Internal helper for Bastion SSH commands |
| `Clear-MigrationQueues.ps1` | Purge Azure Storage queues via VM1 (private endpoint access) |
| `Remove-BulkExternalIdUsers.ps1` | Bulk delete test users from External ID via Graph API |

### Common Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ResourceGroup` | `rg-b2c-migration` | Azure resource group |
| `-BastionName` | `bas-b2c-migration` | Azure Bastion resource name |
| `-VmCount` | `2` | Number of worker VMs |
| `-SshKeyPath` | `$env:USERPROFILE\.ssh\b2c-migration-key` | SSH private key path |

### Usage Examples

```powershell
# Check VM status
.\scripts\Get-AzureWorkerStatus.ps1

# Clear queues from previous run
.\scripts\Clear-MigrationQueues.ps1 -StorageAccountName stb2cmigration

# Run harvest
.\scripts\Start-AzureHarvest.ps1

# Start workers (opens separate windows per VM)
.\scripts\Start-AzureWorkers.ps1
.\scripts\Start-AzureWorkers.ps1 -VmCount 4 -Command phone-registration

# Stop workers
.\scripts\Stop-AzureWorkers.ps1

# Download and analyze telemetry
.\scripts\Get-AzureTelemetry.ps1 -Analyze

# Clean up test users
.\scripts\Remove-BulkExternalIdUsers.ps1 -WhatIf
.\scripts\Remove-BulkExternalIdUsers.ps1 -Force
.\scripts\Remove-BulkExternalIdUsers.ps1 -Filter "all" -Force
```

---

## Telemetry & Analysis

### Analyze-Telemetry.ps1

Aggregates and analyzes JSONL telemetry files produced by migration workers.

```powershell
.\scripts\Analyze-Telemetry.ps1                        # aggregate all 4 workers (default)
.\scripts\Analyze-Telemetry.ps1 -WorkerCount 8         # 8 workers
.\scripts\Analyze-Telemetry.ps1 -TelemetryFile path.jsonl  # single file
.\scripts\Analyze-Telemetry.ps1 -ListRuns              # show available runs
.\scripts\Analyze-Telemetry.ps1 -RunIndex 1            # second-to-last run
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-WorkerCount` | `4` | Number of worker file pairs to load |
| `-ConsoleDir` | `../src/B2CMigrationKit.Console` | Directory containing telemetry files |
| `-TelemetryFile` | — | Analyze a single file instead |
| `-RunIndex` | `0` | Which run (0=last, 1=second-to-last) |
| `-ListRuns` | — | List available runs and exit |

**Report sections:** Migrate Workers (latency percentiles, throughput, tail latency, 429 counts) → Phone Registration (outcomes, latency, failure breakdown) → Cross-Pipeline Summary.

### JSONL Format

Workers emit `worker{N}-telemetry.jsonl` and `phone-registration{N}-telemetry.jsonl`. Each line is a JSON object with `ts` (ISO-8601) and `name` fields:

| Event | Source | Key Fields |
|-------|--------|------------|
| `WorkerMigrate.Started` | worker | *(run boundary)* |
| `WorkerMigrate.B2CFetch` | worker | `fetchMs` |
| `WorkerMigrate.UserCreated` | worker | `eeidCreateMs`, `eeidApiMs` |
| `WorkerMigrate.BatchDone` | worker | `b2cFetchMs`, `eeidAvgMs`, `eeidMaxMs` |
| `Graph.Throttled` | both | `tenantRole` (B2C/EEID) |
| `PhoneRegistration.Started` | phone | *(run boundary)* |
| `PhoneRegistration.Success` | phone | `b2cGetPhoneMs`, `eeidRegisterMs`, `totalMs` |
| `PhoneRegistration.Skipped` | phone | `b2cGetPhoneMs` |
| `PhoneRegistration.Failed` | phone | `step`, `errorCode` |

---

## JIT Password Migration Setup

After bulk migration, configure JIT so passwords migrate on each user's first login.

### 1. Generate RSA Keys

```powershell
.\scripts\New-LocalJitRsaKeyPair.ps1
```

Generates four files (git-ignored): `jit-private-key.pem` (⚠️ SECRET), `jit-certificate.txt`, `jit-public-key-x509.txt`, `jit-public-key.jwk.json`.

### 2. Configure External ID

```powershell
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-domain.ngrok-free.dev/api/JitAuthentication"
```

Automates full setup via device code flow: Custom Auth Extension app registration, extension resource, test client app, event listener, user flow.

**Manual step required:** Grant admin consent for the Extension App in Azure Portal after the script completes.

### 3. Switch Environments

```powershell
.\scripts\Switch-JitEnvironment.ps1 -Environment Local   # ngrok
.\scripts\Switch-JitEnvironment.ps1 -Environment Azure    # production
```

### 4. Start Function Locally

```powershell
cd src\B2CMigrationKit.Function
.\start-local.ps1    # builds, starts ngrok + function on port 7071
```

---

## Utility Scripts

| Script | Description |
|--------|-------------|
| `New-TestUser.ps1` | Create test users in External ID with `RequiresMigration` flag |
| `Manage-MigrationFlag.ps1` | Query and update `RequiresMigration` flag on EEID users |
| `_Common.ps1` | Shared helpers (Azurite checks, storage init, colored output, build+run). Not run directly. |

### New-TestUser.ps1

```powershell
.\scripts\New-TestUser.ps1 -Email "testuser@domain.com"        # single user
.\scripts\New-TestUser.ps1 -Prefix "testjit" -Count 10         # bulk: testjit1..10
.\scripts\New-TestUser.ps1 -Prefix "testjit" -Count 5 -WhatIf  # dry run
```

### Manage-MigrationFlag.ps1

```powershell
.\scripts\Manage-MigrationFlag.ps1                              # list pending users
.\scripts\Manage-MigrationFlag.ps1 -Filter all                  # list all users
.\scripts\Manage-MigrationFlag.ps1 -Filter true -SetFlag false  # clear flag
.\scripts\Manage-MigrationFlag.ps1 -Discover                    # list extension attributes
```
