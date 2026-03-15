# B2C Migration Kit - Scripts

PowerShell scripts for running bulk migrations, configuring JIT password migration, and analyzing telemetry.

**📖 For complete configuration reference, see the [Developer Guide](../docs/DEVELOPER_GUIDE.md)**

## Table of Contents

- [Prerequisites](#prerequisites)
- [Simple Mode (Export → Import)](#simple-mode-export--import)
- [Advanced Mode (Harvest → Workers)](#advanced-mode-harvest--workers)
- [JIT Password Migration Setup](#jit-password-migration-setup)
- [Telemetry Analysis](#telemetry-analysis)
- [Utility Scripts](#utility-scripts)

---

## Prerequisites

1. **.NET 8.0 SDK** — `dotnet --version` (8.0+)
2. **Azurite VS Code Extension** — `ms-azuretools.vscode-azurite` (start with `Ctrl+Shift+P` → `Azurite: Start Service`)
3. **Configuration files** — copy the relevant `.example.json` and fill in your tenant credentials (see [Developer Guide](../docs/DEVELOPER_GUIDE.md#configuration-guide))

Additional for JIT testing: **PowerShell 7.0+**, **ngrok**, **Azure Function Core Tools v4**.

---

## Simple Mode (Export → Import)

Two sequential commands for straightforward bulk migration without MFA phone migration.

### 1. Export

Pages all B2C users and writes full profiles to Blob Storage as JSON files.

```powershell
cd src/B2CMigrationKit.Console
dotnet run -- export --config appsettings.export-import.json
```

Set `Export.MaxUsers` to a small number (e.g., `20`) for smoke tests.

### 2. Import

Reads exported blobs, transforms profiles, and creates users in External ID.

```powershell
dotnet run -- import --config appsettings.export-import.json
```

Users are created with `RequiresMigration=true` — JIT handles real password on first login. Duplicates (409) are skipped gracefully.

**Config template:** `appsettings.export-import.example.json`

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
# Aggregate all 4 workers (default)
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
