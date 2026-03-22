# B2C Migration Kit - Scripts

PowerShell scripts for running bulk migrations, configuring JIT password migration, and analyzing telemetry.

**📖 For complete configuration reference, see the [Developer Guide](../docs/DEVELOPER_GUIDE.md)**

> **🚀 New here?** Start with [`Setup-Migration.ps1`](#setup-wizard) — the interactive wizard that walks you through the entire setup end-to-end.

## Table of Contents

- [Setup Wizard (Recommended First Step)](#setup-wizard)
- [Full Deployment (Deploy-All)](#full-deployment-deploy-all)
- [Prerequisites](#prerequisites)
- [Readiness Validation](#readiness-validation)
- [Simple Mode (Export → Import)](#simple-mode-export--import)
- [Advanced Mode (Harvest → Workers)](#advanced-mode-harvest--workers)
- [JIT Password Migration Setup](#jit-password-migration-setup)
- [Telemetry Analysis](#telemetry-analysis)
- [Utility Scripts](#utility-scripts)

---

## Setup Wizard

### Setup-Migration.ps1

Interactive wizard that walks through the **entire setup process** end-to-end: tenant configuration, app registration provisioning, config file generation, migration mode selection, and deployment target.

**Run this first** — it replaces the manual steps in the Quick Start guide.

```powershell
# Fully interactive (recommended for first-time setup)
.\scripts\Setup-Migration.ps1

# Pre-fill values for faster setup
.\scripts\Setup-Migration.ps1 `
    -B2CTenantId "xxxxxxxx-..." -B2CTenantDomain "contosob2c.onmicrosoft.com" `
    -EeidTenantId "yyyyyyyy-..." -EeidTenantDomain "contosoeeid.onmicrosoft.com" `
    -ExtensionAppId "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

# Non-interactive (CI/automation)
.\scripts\Setup-Migration.ps1 -NonInteractive `
    -B2CTenantId "..." -B2CTenantDomain "..." `
    -EeidTenantId "..." -EeidTenantDomain "..." `
    -ExtensionAppId "..." -WorkerCount 4 -Mode Advanced -Target Local

# Dry run
.\scripts\Setup-Migration.ps1 -WhatIf
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-NonInteractive` | `false` | Accept defaults, fail if required values missing |
| `-B2CTenantId` | — | B2C tenant GUID |
| `-B2CTenantDomain` | — | B2C `.onmicrosoft.com` domain |
| `-EeidTenantId` | — | External ID tenant GUID |
| `-EeidTenantDomain` | — | External ID `.onmicrosoft.com` domain |
| `-ExtensionAppId` | — | Extension app ID (32 hex chars, no hyphens) |
| `-WorkerCount` | `4` | Number of parallel workers |
| `-Mode` | *(prompted)* | `Simple` (Export/Import) or `Advanced` (Harvest/Workers/Phone) |
| `-Target` | *(prompted)* | `Local` (Azurite) or `Azure` (VM deployment) |
| `-ResourceGroup` | `rg-b2c-migration` | Azure resource group (when Target=Azure) |
| `-Location` | `eastus2` | Azure region (when Target=Azure) |
| `-SecretExpiryYears` | `2` | Client secret validity |
| `-WhatIf` | `false` | Dry run |

**Wizard steps:**
1. **Tenant info** — collects and validates B2C/EEID tenant IDs, domains, extension app ID
2. **App registrations** — creates B2C (User.Read.All) + EEID (User.ReadWrite.All) apps per worker via device code auth, writes `appsettings.workerN.json`
3. **Migration mode** — Simple (export/import) or Advanced (queue-based workers + phone registration)
4. **Deployment target** — Local (Azurite) or Azure VMs (invokes Deploy-All.ps1)
5. **Summary** — prints everything created and the exact commands to run

The wizard detects existing config files and offers to skip already-completed steps.

---

## Full Deployment (Deploy-All)

### Deploy-All.ps1

Single script that orchestrates the complete Azure VM deployment: infrastructure provisioning via Bicep, and VM setup via `az vm run-command` (git clone → dotnet publish → example config copy).

VMs build the app themselves from source — no blob upload needed.

```powershell
# Full deployment (infra + VM provisioning)
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub

# Re-provision VMs only (infra already deployed)
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub -SkipInfra

# Dry run
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -WhatIf

# Custom worker count and location
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub -VmCount 8 -Location westus2
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ResourceGroup` | *(required)* | Target Azure resource group |
| `-Location` | `eastus2` | Azure region |
| `-VmCount` | `5` | Total number of VMs (derived from role counts) |
| `-MasterCount` | `1` | Number of master VMs (harvest) |
| `-UserWorkerCount` | `2` | Number of user-worker VMs (worker-migrate) |
| `-PhoneWorkerCount` | `2` | Number of phone-worker VMs (phone-registration) |
| `-VmSize` | `Standard_B2s` | VM SKU |
| `-AdminUsername` | `azureuser` | VM admin user |
| `-SshPublicKeyFile` | `~/.ssh/id_ed25519.pub` | Path to SSH public key |
| `-DeployBastion` | `true` | Whether to deploy Azure Bastion |
| `-GitRepo` | *(auto-detected from git remote)* | Git repo URL for VMs to clone |
| `-GitBranch` | *(auto-detected from current branch)* | Git branch to checkout on VMs |
| `-ConfigProfile` | *N/A* | Removed — role-appropriate config is auto-selected per VM |
| `-SkipInfra` | `false` | Skip Bicep deployment, only re-provision VMs |
| `-WhatIf` | `false` | Dry run — shows what would happen without making changes |

**Pipeline steps:**
1. Deploy infrastructure via `az deployment sub create` with `infra/main.bicep`
2. Provision each VM via `az vm run-command invoke`:
   - Install .NET SDK 8.0 + git if not present
   - Git clone the repo (auto-detected from your local remote/branch)
   - `dotnet publish` to `/opt/b2c-migration/app/`
   - Copy role-appropriate example config as `appsettings.json`:
     - VM 1: `appsettings.master.example.json`
     - VM 2–3: `appsettings.user-worker.example.json`
     - VM 4–5: `appsettings.phone-worker.example.json`
3. After deployment, connect via Bastion and run `Configure-Worker.sh` on each VM (or edit `appsettings.json` manually)

**Prerequisites:** Azure CLI logged in (`az login`), SSH key pair generated, config changes committed and pushed to your repo.

### Connect-Worker.ps1

Opens a Bastion SSH tunnel to a worker VM for secure access.

```powershell
# Terminal 1: Open tunnel
.\scripts\Connect-Worker.ps1 -WorkerIndex 1

# Terminal 2: SSH through tunnel
ssh -p 2201 -i .\scripts\b2c-mig-deploy azureuser@localhost
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-WorkerIndex` | `1` | Worker number (1–16). Maps to port 2200+N |
| `-ResourceGroup` | `rg-b2c-eeid-mig-test1` | Resource group name |
| `-SshPrivateKeyFile` | `scripts/b2c-mig-deploy` | Path to SSH private key |

The script auto-installs the Azure CLI bastion extension if not present.

### Configure-Worker.sh

Interactive script that runs **on the VM** to generate `appsettings.json` without manual editing.

```bash
# On the VM via SSH:
bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh

# Or skip the role prompt:
bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh --role worker --worker-id 2
```

The script prompts for B2C credentials, External ID credentials, and storage account name, then writes the config with `chmod 600` and runs `validate` automatically.

---

## Prerequisites

1. **.NET 8.0 SDK** — `dotnet --version` (8.0+)
2. **Azurite VS Code Extension** — `ms-azuretools.vscode-azurite` (start with `Ctrl+Shift+P` → `Azurite: Start Service`)
3. **Configuration files** — copy the relevant `.example.json` and fill in your tenant credentials (see [Developer Guide](../docs/DEVELOPER_GUIDE.md#configuration-guide))

Additional for JIT testing: **PowerShell 7.0+**, **ngrok**, **Azure Function Core Tools v4**.

---

## Readiness Validation

Run the pre-flight check before starting any migration to verify connectivity, permissions, and storage.

### Validate-MigrationReadiness.ps1

Comprehensive readiness checker that validates Graph API connectivity, required permissions, extension attributes, and storage infrastructure. Prints a PASS/FAIL summary report.

```powershell
.\scripts\Validate-MigrationReadiness.ps1                                    # default (simple mode)
.\scripts\Validate-MigrationReadiness.ps1 -Mode worker                       # validate worker mode prerequisites
.\scripts\Validate-MigrationReadiness.ps1 -ConfigFile "appsettings.worker1.json"  # custom config
```

| Check | What it validates |
|---|---|
| Config | JSON valid, tenant IDs and secrets not placeholders |
| Graph auth | OAuth2 client_credentials flow to both tenants |
| Permissions | User.Read and Directory access on each tenant |
| Extensions | Extension app and properties exist in EEID |
| Storage | Azurite ports or cloud storage reachable, containers/queues/tables |
| Tools | .NET SDK installed, PowerShell 7+ |

### Watch-Migration.ps1

Live monitoring dashboard that tails JSONL telemetry files and shows running counters (users migrated, phones registered, errors, throttles). Refreshes every few seconds; press Ctrl+C for a final summary.

```powershell
.\scripts\Watch-Migration.ps1                                # default (5 workers, 3s refresh)
.\scripts\Watch-Migration.ps1 -WorkerCount 8                 # monitor 8 workers
.\scripts\Watch-Migration.ps1 -RefreshSeconds 2              # faster refresh
```

| Parameter | Default | Description |
|---|---|---|
| `WorkerCount` | 4 | Number of migrate + phone workers to monitor |
| `ConsoleDir` | `../src/B2CMigrationKit.Console` | Directory with telemetry JSONL files |
| `RefreshSeconds` | 3 | Seconds between dashboard refreshes |

---

## Simple Mode (Export → Import)

Two sequential scripts for straightforward bulk migration without MFA phone migration.

> ⚠️ **Azurite must be running first.** Start via VS Code: `Ctrl+Shift+P` → `Azurite: Start Service`

### 1. Export

Pages all B2C users and writes full profiles to Blob Storage as JSON files.

```powershell
.\scripts\Start-LocalExport.ps1
```

- Uses `-ConfigFile appsettings.export-import.json` by default
- Set `Export.MaxUsers: 20` in config for smoke tests (`0` = all users)

### 2. Import

Reads exported blobs, transforms profiles, and creates users in External ID.

```powershell
.\scripts\Start-LocalImport.ps1
```

- Uses the same config file as export
- Users are created with `RequiresMigration=true` — JIT handles real password on first login
- Duplicates (409) are skipped gracefully

**Config template:** `appsettings.export-import.example.json`

Both scripts accept `-VerboseLogging` and `-SkipAzurite` parameters.

---

## Advanced Mode (Harvest → Workers)

Queue-based parallel pipeline for large tenants with MFA phone migration support.

> ⚠️ **Azurite must be running first.** Start via VS Code: `Ctrl+Shift+P` → `Azurite: Start Service`

### 1. Harvest (run once)

Enqueues all B2C user IDs to the migration queue.

```powershell
.\scripts\Start-LocalHarvest.ps1
```

- Uses `-ConfigFile appsettings.master.json` by default
- Set `Harvest.MaxUsers: 20` in config for smoke tests (`0` = all users)
- Exits when all IDs are enqueued

### 2. Worker Migrate (run N instances in parallel)

Each worker dequeues ID batches, fetches full profiles from B2C, creates users in External ID, and enqueues phone tasks.

```powershell
# Terminal 1
.\scripts\Start-LocalWorkerMigrate.ps1

# Terminal 2 (different app registration)
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json

# Terminal 3
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker3.json
```

Each instance needs a **dedicated app registration** for independent throttle quotas. Workers auto-exit when the queue is empty.

### 3. Phone Registration (run after or alongside workers)

Drains the phone queue and registers MFA phones in External ID.

```powershell
.\scripts\Start-LocalPhoneRegistration.ps1
```

- Uses `-ConfigFile appsettings.phone-registration.json` by default
- Handles 409 Conflict as success (idempotent)
- Exits after `MaxEmptyPolls` consecutive empty polls

### Common Parameters

All three scripts accept:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ConfigFile` | *(per script)* | Configuration file path |
| `-VerboseLogging` | `false` | Enable detailed logging |
| `-SkipAzurite` | `false` | Skip Azurite port check (for cloud storage) |

The scripts automatically verify Azurite, pre-create queues/tables, build and run the console app.

---

## JIT Password Migration Setup

After bulk migration (either mode), configure JIT so passwords migrate seamlessly on each user's first login.

### 1. Generate RSA Keys

```powershell
.\scripts\New-LocalJitRsaKeyPair.ps1
```

Generates four files (git-ignored):
- `jit-private-key.pem` — ⚠️ SECRET, used by the Azure Function to decrypt payloads
- `jit-certificate.txt` — upload to Custom Extension app registration
- `jit-public-key-x509.txt` — public key in X.509 format
- `jit-public-key.jwk.json` — public key in JWK format

### 2. Configure External ID

```powershell
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-domain.ngrok-free.dev/api/JitAuthentication" `
    -MigrationPropertyId "extension_{ExtensionAppId}_RequiresMigration"
```

This script automates the full setup via device code flow:
- Creates Custom Authentication Extension app registration + encryption cert upload
- Creates the Custom Authentication Extension resource (linked to your Function URL)
- Creates a test client app, service principal, extension attribute, event listener, and user flow

| Parameter | Required | Description |
|-----------|----------|-------------|
| `TenantId` | Yes | External ID tenant ID |
| `CertificatePath` | Yes | Path to `jit-certificate.txt` |
| `FunctionUrl` | Yes | Azure Function or ngrok endpoint URL |
| `MigrationPropertyId` | No | Extension attribute ID (prompted if not provided) |
| `SkipClientApp` | No | Skip creating the test client app |

**Manual step required:** Grant admin consent for the Extension App in Azure Portal after the script completes.

### 3. Switch Environments

Toggle JIT between local (ngrok) and Azure Function endpoints:

```powershell
.\scripts\Switch-JitEnvironment.ps1 -Environment Local   # ngrok
.\scripts\Switch-JitEnvironment.ps1 -Environment Azure    # production
```

### 4. Start the Function Locally

```powershell
cd src\B2CMigrationKit.Function
.\start-local.ps1    # builds, starts ngrok + function on port 7071
```

Test the JIT flow via Azure Portal → User flows → Run user flow.

---

## Telemetry Analysis

### Analyze-Telemetry.ps1

Aggregates and analyzes JSONL telemetry files produced by migration workers.

```powershell
# Aggregate all 5 workers (default)
.\scripts\Analyze-Telemetry.ps1

# Aggregate 8 workers
.\scripts\Analyze-Telemetry.ps1 -WorkerCount 8

# Analyze a single file
.\scripts\Analyze-Telemetry.ps1 -TelemetryFile ..\src\B2CMigrationKit.Console\worker2-telemetry.jsonl
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `WorkerCount` | `4` | Number of worker file pairs to load |
| `ConsoleDir` | `../src/B2CMigrationKit.Console` | Directory containing telemetry files |
| `TelemetryFile` | — | Analyze a single file instead of aggregating |

**Report sections:**
- **Migrate Workers** — B2C fetch and EEID create latency percentiles (p50/p90/p95/p99), wall time breakdown, throughput, tail latency (>1s), 429 throttle counts
- **Phone Registration** — Outcomes (succeeded/skipped/failed), latency percentiles, failure breakdown by step and error code, throttle counts
- **Cross-Pipeline Summary** — Users migrated vs phones registered, coverage percentage

### JSONL Format

Each worker emits `worker{N}-telemetry.jsonl` and `phone-registration{N}-telemetry.jsonl` in the console app directory. Each line is a JSON object with `ts` (ISO-8601) and `name` fields:

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

The script only analyzes the **last run** per file (ignores events before the last `*.Started` marker).

---

## Utility Scripts

### New-TestUser.ps1

Creates test users in External ID with `RequiresMigration` flag for JIT testing.

```powershell
.\scripts\New-TestUser.ps1 -Email "testuser@domain.com"             # single user
.\scripts\New-TestUser.ps1 -Prefix "testjit" -Count 10              # bulk: testjit1..10
.\scripts\New-TestUser.ps1 -Prefix "testjit" -Count 5 -WhatIf      # dry run
```

### Manage-MigrationFlag.ps1

Queries and updates the `RequiresMigration` flag on External ID users.

```powershell
.\scripts\Manage-MigrationFlag.ps1                          # list users pending migration
.\scripts\Manage-MigrationFlag.ps1 -Filter all              # list all users
.\scripts\Manage-MigrationFlag.ps1 -Filter true -SetFlag false   # clear flag for pending users
.\scripts\Manage-MigrationFlag.ps1 -Discover                # list extension attributes
```

### New-WorkerAppRegistrations.ps1

Provisions additional app registrations in B2C and External ID for parallel workers. Creates apps, grants permissions, generates secrets, and writes `appsettings.workerN.json` files.

```powershell
.\scripts\New-WorkerAppRegistrations.ps1                          # provision workers 5-8
.\scripts\New-WorkerAppRegistrations.ps1 -StartWorker 2 -EndWorker 4   # specific range
.\scripts\New-WorkerAppRegistrations.ps1 -WhatIf                  # preview only
```

### _Common.ps1

Shared helper module dot-sourced by all scripts. Provides Azurite checks, storage initialization, colored output, and the build+run wrapper. Not meant to be run directly.
