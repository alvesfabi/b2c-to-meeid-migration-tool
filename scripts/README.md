# B2C Migration Kit - Scripts

This directory contains PowerShell scripts for local development, testing, and JIT migration setup.

**📖 For complete setup instructions, see the [Developer Guide](../docs/DEVELOPER_GUIDE.md)**

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Migration Scripts](#migration-scripts)
  - [Start-LocalHarvest.ps1](#start-localharvestps1--producer-phase)
  - [Start-LocalWorkerMigrate.ps1](#start-localworkermigrateps1--worker-phase)
  - [Start-LocalPhoneRegistration.ps1](#start-localphoneregistrationps1--phone-registration-phase)
- [JIT Migration Setup](#jit-migration-setup)
  - [Generate RSA Keys](#1-generate-rsa-keys)
  - [Configure External ID](#2-configure-external-id)
  - [Switch Environments](#3-switch-environments)
- [Testing & Utility Scripts](#testing--utility-scripts)
  - [New-TestUser.ps1](#new-testuserps1--create-test-users)
  - [Manage-MigrationFlag.ps1](#manage-migrationflagps1--manage-migration-flag)
  - [New-WorkerAppRegistrations.ps1](#new-workerappregistrationsps1--provision-worker-app-registrations)
  - [Analyze-Telemetry.ps1](#analyze-telemetryps1--analyze-migration-telemetry)
- [Shared Helpers](#shared-helpers)
  - [_Common.ps1](#_commonps1--shared-helper-functions)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### For Migration Operations

1. **.NET 8.0 SDK** - Build and run the console application
   ```powershell
   dotnet --version  # Should be 8.0+
   ```

2. **Azurite VS Code Extension** - Azure Storage emulator for local development
   - Install from VS Code Marketplace: [`ms-azuretools.vscode-azurite`](https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-azurite)
   - Or search "Azurite" in the VS Code Extensions panel
   - **Do NOT use `npm install -g azurite`** – the extension is the recommended approach
     (no npm dependency, integrates with VS Code status bar)

   Start Azurite before running any script:
   ```
   Ctrl+Shift+P  →  "Azurite: Start Service"
   ```
   Or click the **Azurite Blob Service** / **Azurite Queue Service** icons in the status bar.

3. **Configuration** - credentials file per operation (copy the relevant `.example.json`)
   - See [Developer Guide - Configuration](../docs/DEVELOPER_GUIDE.md#configuration-guide)

### For JIT Migration Testing

4. **PowerShell 7.0+** - Modern PowerShell features
   ```powershell
   $PSVersionTable.PSVersion  # Should be 7.0+
   ```

5. **ngrok** - Expose local function to internet
   ```powershell
   choco install ngrok
   # Or download from https://ngrok.com/download
   ```

6. **Azure Function Core Tools** - Run functions locally
   ```powershell
   npm install -g azure-functions-core-tools@4
   ```

---

## Quick Start

**Recommended workflow:** Use the PowerShell scripts that automatically handle Azurite verification.

> ⚠️ **Azurite must be running first.** Start it from VS Code: `Ctrl+Shift+P` → `Azurite: Start Service`

```powershell
# Step 1: run ONCE – enqueues all user IDs (fast, only fetches the 'id' field)
.\scripts\Start-LocalHarvest.ps1

# Step 2: run in PARALLEL, each in its own terminal with its own App Registration
.\scripts\Start-LocalWorkerMigrate.ps1                                        # Terminal 1: default config (appsettings.worker1.json)
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json   # Terminal 2
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker3.json   # Terminal 3

# Step 3: (optional) drain phone-registration queue after workers are done
.\scripts\Start-LocalPhoneRegistration.ps1
```

**✅ What the scripts do automatically:**
- Verify Azurite is running via the VS Code extension (port check – no npm needed)
- Auto-detect whether local Azurite or cloud storage is configured
- Pre-create queues (`user-ids-to-process`, `phone-registration`) and tables (`migration-audit`) via Azure CLI (if available)
- Build and run the console application
- Display color-coded progress and status messages

---

## Migration Scripts

### Start-LocalHarvest.ps1  *(Producer phase)*

Fetches **only user IDs** from B2C at maximum speed (page size 999, `$select=id`) and
enqueues batches of IDs to the Azure Queue `user-ids-to-process`.

Run this **once** before starting any worker instances. It exits automatically when
all user IDs have been enqueued.

**Usage:**
```powershell
.\Start-LocalHarvest.ps1 [-VerboseLogging] [-ConfigFile "config.json"] [-SkipAzurite]
```

**Parameters:**
- `-ConfigFile` - Configuration file (default: `appsettings.master.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite port check (use cloud storage)

**What it does:**
1. Verifies Azurite ports are open
2. Pre-creates the queues and tables
3. Downloads all user IDs from B2C — extremely fast (only `id` field, page size 999)
4. Groups IDs into batches and sends each batch as one queue message
5. Prints a summary with next-step instructions

**Smoke-test cap (`MaxUsers`):** To run an end-to-end test with a small number of users,
set `Harvest.MaxUsers` in `appsettings.master.json` before running the script:

```json
"Harvest": {
  "QueueName": "user-ids-to-process",
  "IdsPerMessage": 20,
  "PageSize": 999,
  "MaxUsers": 20
}
```

- `MaxUsers: 20` — stops after enqueuing 20 users (smoke test)
- `MaxUsers: 0` — no cap, enqueues all users (full migration)

---

### Start-LocalWorkerMigrate.ps1  *(Worker phase)*

Consumes the `user-ids-to-process` queue populated by the harvest phase. Each worker
performs a complete batch migration per message:

1. Dequeues one message (batch of user IDs)
2. Calls `POST /$batch` to B2C to fetch full profiles in a single HTTP request
3. Transforms each profile to the External ID schema (UPN, extension attributes, etc.)
4. Creates each user in Entra External ID (`POST /users`)
5. Sets the `RequiresMigration` flag and copies extension attributes
6. Writes each outcome to the `migration-audit` Table Storage
7. If phone numbers are present, enqueues a `{ B2CUserId, EEIDUpn }` message to
   the `phone-registration` queue
8. Deletes the message from the queue (ACK)

Run multiple instances simultaneously — each with a **different App Registration config**
to multiply the API throttle limit by the number of workers.

**Usage:**
```powershell
# Terminal 1 (default config: appsettings.worker1.json)
.\Start-LocalWorkerMigrate.ps1

# Terminal 2 (simultaneously, dedicated config for worker 2)
.\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json

# Terminal 3 (simultaneously, dedicated config for worker 3)
.\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker3.json
```

**Parameters:**
- `-ConfigFile` - Configuration file (default: `appsettings.worker1.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite port check

**Resilience:** if a worker crashes before ACKing a message, the message automatically
reappears in the queue after the `MessageVisibilityTimeout` (default 5 min) and another
worker (or a re-run) will process it.

---

### Start-LocalPhoneRegistration.ps1  *(Phone registration phase)*

Drains the `phone-registration` queue populated by the worker-migrate phase and registers
MFA phone numbers in Entra External ID at a throttle-safe rate (~2.5 RPS / 400 ms gap).

Run **after** (or concurrently with) `Start-LocalWorkerMigrate.ps1`.

**Usage:**
```powershell
.\Start-LocalPhoneRegistration.ps1 [-VerboseLogging] [-ConfigFile "config.json"] [-SkipAzurite]
```

**Parameters:**
- `-ConfigFile` - Configuration file (default: `appsettings.phone-registration.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite port check

**What it does:**
1. Validates configuration file exists
2. Detects storage mode (local vs cloud)
3. Verifies Azurite ports 10000/10001 are open (VS Code extension)
4. Builds and runs the `phone-registration` worker
5. Worker dequeues `{ B2CUserId, EEIDUpn }` messages
6. Fetches the MFA phone number from B2C for each user
7. Calls `POST /users/{upn}/authentication/phoneMethods` on Entra External ID
8. Treats 409 Conflict as success (idempotent — phone already registered)
9. Writes each outcome to the `migration-audit` Table Storage
10. Exits automatically after `MaxEmptyPolls` consecutive empty queue polls

**Prerequisites:**
- Entra External ID app registration must have `UserAuthenticationMethod.ReadWrite.All` (Application) granted and admin-consented
- Worker-migrate must have run with phone registration enabled

> **Why async?** The `POST /authentication/phoneMethods` API has a lower throttle budget than the user-creation API. Running phone registration inline would stall the pipeline; decoupling via queue lets each run at its own optimal rate.

---

## JIT Migration Setup

Complete setup for Just-In-Time password migration during user's first login.

### 1. Generate RSA Keys

**Script:** `New-LocalJitRsaKeyPair.ps1`

Generates RSA-2048 key pair for local testing (files stored in `scripts/` directory).

**Usage:**
```powershell
.\New-LocalJitRsaKeyPair.ps1
```

**Files Generated** (automatically git-ignored):
- `jit-private-key.pem` - RSA private key (keep secret!)
- `jit-certificate.txt` - X.509 certificate (upload to Azure)
- `jit-public-key-x509.txt` - Public key in X.509 format
- `jit-public-key.jwk.json` - Public key in JWK format

**What each file is used for:**

1. **jit-private-key.pem** ⚠️ SECRET
   - Used by Azure Function to decrypt payloads from External ID
   - Add to `local.settings.json` → `Migration__JitAuthentication__InlineRsaPrivateKey`
   - Never commit or share this file

2. **jit-certificate.txt**
   - X.509 certificate in base64 format
   - Upload to Custom Extension App Registration in Azure Portal
   - Used by External ID to encrypt payloads sent to your function

3. **jit-public-key.jwk.json**
   - Public key in JSON Web Key format
   - Used by `Configure-ExternalIdJit.ps1` script
   - Safe to share (it's a public key)

**🔐 Security Notes:**
- These keys are for **LOCAL TESTING ONLY**
- For production, use Azure Key Vault with HSM-protected keys
- Never commit private keys to source control (already in `.gitignore`)

**Verify keys created:**
```powershell
Get-ChildItem .\jit-*.* | Select-Object Name, Length

# Expected output:
# Name                        Length
# ----                        ------
# jit-private-key.pem          1704
# jit-certificate.txt          1159
# jit-public-key-x509.txt       451
# jit-public-key.jwk.json       394
```

### 2. Configure External ID

**Script:** `Configure-ExternalIdJit.ps1`

Automates complete External ID configuration for JIT migration using device code flow.

**What it creates:**
1. Custom Authentication Extension App registration
2. Encryption certificate upload
3. Custom Authentication Extension (links to your Azure Function)
4. Test Client Application (for testing sign-in flows)
5. Service Principal (required for Event Listener)
6. Extension Attribute (`RequiresMigration` boolean)
7. Event Listener Policy (triggers JIT on password submission)
8. User Flow (enables sign-up/sign-in with JIT)

**Usage:**
```powershell
# Basic usage
.\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-function.azurewebsites.net/api/JitAuthentication" `
    -MigrationPropertyId "extension_{ExtensionAppId}_RequiresMigration"

# For local testing with ngrok
.\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-domain.ngrok-free.dev/api/JitAuthentication" `
    -MigrationPropertyId "extension_{ExtensionAppId}_RequiresMigration" `
    -SkipClientApp
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `TenantId` | Yes | External ID tenant ID |
| `CertificatePath` | Yes | Path to `jit-certificate.txt` file |
| `FunctionUrl` | Yes | Azure Function endpoint URL |
| `MigrationPropertyId` | No | Extension attribute ID (format: `extension_{AppId}_RequiresMigration`). Prompted if not provided. |
| `ExtensionAppName` | No | Name for custom auth extension app (default: "EEID Auth Extension - JIT Migration") |
| `ClientAppName` | No | Name for test client app (default: "JIT Migration Test Client") |
| `SkipClientApp` | No | Skip creating the test client application |

**How to find Migration Property ID:**
1. Azure Portal → Your B2C Tenant → App registrations
2. Find your `b2c-extensions-app` and copy the **Application (client) ID**
3. Remove dashes from the ID (e.g., `a1b2c3d4-...` → `a1b2c3d4...`)
4. Format: `extension_{AppIdWithoutDashes}_RequiresMigration`
5. Example: `extension_a1b2c3d4e5f6g7h8i9j0k1l2m3n4o5p6_RequiresMigration`

**Authentication Flow:**
1. Script opens device code login (`https://microsoft.com/devicelogin`)
2. Sign in with External ID admin account
3. Grant required permissions:
   - `Application.ReadWrite.All`
   - `CustomAuthenticationExtension.ReadWrite.All`
   - `User.Read`

**Manual Steps Required:**
- **Step 2:** Grant admin consent in Azure Portal for Extension App
  - Portal → App registrations → [Extension App] → API permissions
  - Click "Grant admin consent for [Tenant]"
- **Step 5:** (Optional) Grant consent for test client app (not needed for JIT)

**Output:**
After successful completion, the script displays a configuration summary with all IDs:

```
═══════════════════════════════════════════════════════════════
  CONFIGURATION SUMMARY
═══════════════════════════════════════════════════════════════

Custom Extension App:
  → App ID: 00000000-0000-0000-0000-000000000001

Custom Authentication Extension:
  → Extension ID: 00000000-0000-0000-0000-000000000002

Test Client App:
  → App ID: 00000000-0000-0000-0000-000000000003

Event Listener:
  → Migration Property: extension_00000000000000000000000000000001_RequiresMigration

User Flow:
  → Display Name: JIT Migration Flow (20251219-123721)
```

**Save these IDs** for testing and troubleshooting.

### 3. Switch Environments

**Script:** `Switch-JitEnvironment.ps1`

Toggle Custom Authentication Extension between local (ngrok) and Azure Function endpoints.

**Usage:**
```powershell
# Switch to local ngrok for development
.\Switch-JitEnvironment.ps1 -Environment Local

# Switch to Azure Function for production
.\Switch-JitEnvironment.ps1 -Environment Azure
```

**Parameters:**
- `-Environment` - Target environment (`Local` or `Azure`)

**What it does:**
- Updates Custom Authentication Extension target URL
- For Local: Uses ngrok URL from configuration
- For Azure: Uses Azure Function URL
- Validates endpoint is reachable before switching

---

## Testing & Utility Scripts

Utility scripts for creating test users and managing migration state.

### New-TestUser.ps1  *(Create test users)*

Creates one or more test users in Entra External ID with `emailAddress` identity.
Optionally sets the `RequiresMigration` flag for JIT migration testing.

**Usage:**
```powershell
# Create a single user with migration flag set to true
.\New-TestUser.ps1 -Email "testuser@domain.com"

# Create a single user with a specific display name
.\New-TestUser.ps1 -Email "testuser@domain.com" -DisplayName "Test User"

# Create 10 bulk test users (testjit1@slider-inc.com … testjit10@slider-inc.com)
.\New-TestUser.ps1 -Prefix "testjit" -Count 10

# Create users starting at a specific index
.\New-TestUser.ps1 -Prefix "testjit" -Count 5 -StartIndex 20

# Create users without setting the migration flag
.\New-TestUser.ps1 -Prefix "testjit" -Count 3 -SetMigrationFlag none

# Preview users that would be created (dry run)
.\New-TestUser.ps1 -Prefix "testjit" -Count 5 -WhatIf
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `ConfigFile` | No | `appsettings.worker1.json` | Configuration file path |
| `Email` | No* | — | Single user email address |
| `DisplayName` | No | From email | Display name for single user |
| `Prefix` | No* | `testjit` | Prefix for bulk user creation |
| `Domain` | No | `slider-inc.com` | Email domain for bulk users |
| `Count` | No | `1` | Number of users to create |
| `StartIndex` | No | `1` | First index for bulk naming |
| `Password` | No | `TempP@ssw0rd!2026` | Password for created users |
| `SetMigrationFlag` | No | `true` | Set migration flag: `true`, `false`, or `none` |
| `AttributeName` | No | From config | Override extension attribute name |
| `WhatIf` | No | — | Preview without creating users |

\*Either `-Email` (single mode) or `-Prefix` (bulk mode) should be used.

**What it does:**
1. Reads tenant and credential configuration from the specified config file
2. Acquires access token using client credentials
3. Creates user(s) with `emailAddress` sign-in identity
4. Sets `RequiresMigration` extension attribute (if not `none`)
5. Handles conflicts (user already exists) gracefully

**UPN convention:**
External ID UPN is derived from email: `user_domain.com#EXT#@<tenantDomain>`

---

### Manage-MigrationFlag.ps1  *(Manage migration flag)*

Queries and updates the `RequiresMigration` flag for users in Entra External ID.
Useful for monitoring migration progress and resetting users for re-testing.

**Usage:**
```powershell
# List users that still need JIT migration (flag = true)
.\Manage-MigrationFlag.ps1

# List users already migrated (flag = false)
.\Manage-MigrationFlag.ps1 -Filter false

# List users without the flag set
.\Manage-MigrationFlag.ps1 -Filter notset

# List all users regardless of flag
.\Manage-MigrationFlag.ps1 -Filter all

# Clear migration flag for all pending users (preview)
.\Manage-MigrationFlag.ps1 -Filter true -SetFlag false -WhatIf

# Clear migration flag for all pending users
.\Manage-MigrationFlag.ps1 -Filter true -SetFlag false

# Set flag for a specific user by Object ID
.\Manage-MigrationFlag.ps1 -UserId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SetFlag true

# Set flag for a specific user by UPN
.\Manage-MigrationFlag.ps1 -UserUpn "user_domain.com#EXT#@tenant.onmicrosoft.com" -SetFlag true

# Discover available extension attributes in tenant
.\Manage-MigrationFlag.ps1 -Discover
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `ConfigFile` | No | `appsettings.worker1.json` | Configuration file path |
| `Filter` | No | `true` | Filter by flag value: `true`, `false`, `notset`, `all` |
| `SetFlag` | No | — | Update flag to `true` or `false` |
| `UserId` | No | — | Target single user by Object ID |
| `UserUpn` | No | — | Target single user by UPN |
| `AttributeName` | No | From config | Override extension attribute name |
| `MaxUsers` | No | `100` | Maximum users to retrieve/update |
| `Discover` | No | — | List all extension properties in tenant |
| `WhatIf` | No | — | Preview without making changes |

**What it does:**
1. Reads configuration from the specified config file
2. Acquires access token using client credentials
3. Queries users via Microsoft Graph with OData filter
4. Displays user list with current flag values
5. Updates flag for matched users (if `-SetFlag` specified)

**Common use cases:**
- **Monitor progress:** List users still pending migration (`-Filter true`)
- **Verify completion:** List already migrated users (`-Filter false`)
- **Reset for testing:** Set flag back to `true` for re-testing JIT
- **Troubleshoot:** Find users missing the attribute (`-Filter notset`)
- **Debug:** Discover exact attribute names (`-Discover`)

### New-WorkerAppRegistrations.ps1  *(Provision worker app registrations)*

Provisions additional app registrations in both B2C and External ID tenants for parallel
migration workers. For each worker number, it creates a B2C app (with `User.Read.All`),
an External ID app (with `User.ReadWrite.All`), grants admin consent, generates client
secrets, and writes a ready-to-use `appsettings.workerN.json` file.

Authentication uses device code flow — you will be prompted to sign in as an admin once
per tenant.

**Usage:**
```powershell
# Provision workers 5-8 (default)
.\New-WorkerAppRegistrations.ps1

# Provision only worker 6
.\New-WorkerAppRegistrations.ps1 -StartWorker 6 -EndWorker 6

# Preview everything without touching Azure
.\New-WorkerAppRegistrations.ps1 -WhatIf

# Overwrite existing config files
.\New-WorkerAppRegistrations.ps1 -Force
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `StartWorker` | No | `5` | First worker number to provision (1-99) |
| `EndWorker` | No | `8` | Last worker number to provision (1-99) |
| `ConfigFile` | No | `appsettings.worker1.json` | Template config for tenant IDs |
| `SecretExpiryYears` | No | `2` | Client secret validity period (1-5 years) |
| `Force` | No | — | Overwrite existing `appsettings.workerN.json` files |
| `WhatIf` | No | — | Preview actions without calling Graph API |

**What it does per worker:**
1. Creates a B2C app registration with `User.Read.All` (Application) + admin consent
2. Creates an External ID app registration with `User.ReadWrite.All` (Application) + admin consent
3. Generates a client secret for each registration
4. Writes `appsettings.workerN.json` to `src/B2CMigrationKit.Console/`

**Prerequisites:**
- Application Administrator (or Global Administrator) role in both tenants
- An existing `appsettings.worker1.json` (or specified template) with tenant IDs

**Security:** Generated config files contain client secrets and are already in `.gitignore`.

---

### Analyze-Telemetry.ps1  *(Analyze migration telemetry)*

Aggregates and analyzes telemetry JSONL files produced by migrate workers and phone
registration workers. Outputs latency percentiles, throughput, throttle counts, and a
cross-pipeline summary.

**Usage:**
```powershell
# Aggregate all 4 workers (default)
.\Analyze-Telemetry.ps1

# Aggregate 8 workers
.\Analyze-Telemetry.ps1 -WorkerCount 8

# Analyze a single file
.\Analyze-Telemetry.ps1 -TelemetryFile ..\src\B2CMigrationKit.Console\worker2-telemetry.jsonl
```

**Parameters:**

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `WorkerCount` | No | `4` | Number of workers to aggregate (loads `worker1..N-telemetry.jsonl`) |
| `ConsoleDir` | No | `../src/B2CMigrationKit.Console` | Directory containing telemetry files |
| `TelemetryFile` | No | — | Analyze a single JSONL file instead of aggregating |

**Report sections:**
- **Migrate Workers** — B2C fetch and EEID create latency (per-user and per-batch), wall time breakdown, throughput (users/sec), tail latency (>1s), and 429 throttle counts
- **Phone Registration Workers** — Outcomes (succeeded/skipped/failed), B2C GET and EEID POST latency, throughput, failure breakdown by step and error code, throttle counts
- **Cross-Pipeline Summary** — Total users migrated vs phones registered, coverage percentage

#### JSONL Telemetry Format

Each worker emits one JSON object per line to its telemetry file. Every event has a `ts` (ISO-8601 timestamp) and `name` field, plus event-specific fields:

| Event Name | Emitted By | Fields | Description |
|---|---|---|---|
| `WorkerMigrate.Started` | worker-migrate | *(none)* | Run boundary marker — marks the start of a new run |
| `WorkerMigrate.B2CFetch` | worker-migrate | `fetchMs` | Time to fetch a batch of profiles from B2C via `$batch` |
| `WorkerMigrate.UserCreated` | worker-migrate | `eeidCreateMs`, `eeidApiMs` | Per-user EEID creation timing (total operation vs pure API call) |
| `WorkerMigrate.BatchDone` | worker-migrate | `b2cFetchMs`, `eeidAvgMs`, `eeidMaxMs` | Per-batch summary: B2C fetch time, average and max EEID create time |
| `Graph.Throttled` | both | `tenantRole` (`B2C` or `EEID`) | A 429 response was received (Polly will retry) |
| `PhoneRegistration.Started` | phone-registration | *(none)* | Run boundary marker for phone registration |
| `PhoneRegistration.Success` | phone-registration | `b2cGetPhoneMs`, `eeidRegisterMs`, `totalMs` | Phone successfully registered in EEID |
| `PhoneRegistration.Skipped` | phone-registration | `b2cGetPhoneMs` | User has no phone number in B2C — nothing to register |
| `PhoneRegistration.Failed` | phone-registration | `step` (`b2c-get-phone` or `eeid-register`), `errorCode` | Phone registration failed after retries exhausted |
| `PhoneRegistration.B2CApiCall` | phone-registration | `b2cGetPhoneMs` | Every B2C GET phone call (success, skip, and failed) |
| `PhoneRegistration.EEIDApiCall` | phone-registration | `eeidRegisterMs` | Every EEID POST phone call (success and failed) |

**Example JSONL lines:**

```jsonl
{"ts":"2026-03-14T10:00:00.000Z","name":"WorkerMigrate.Started"}
{"ts":"2026-03-14T10:00:01.234Z","name":"WorkerMigrate.B2CFetch","fetchMs":"842"}
{"ts":"2026-03-14T10:00:02.567Z","name":"WorkerMigrate.UserCreated","eeidCreateMs":"1354","eeidApiMs":"1280"}
{"ts":"2026-03-14T10:00:03.890Z","name":"WorkerMigrate.BatchDone","b2cFetchMs":"842","eeidAvgMs":"1300","eeidMaxMs":"1520"}
{"ts":"2026-03-14T10:00:04.100Z","name":"Graph.Throttled","tenantRole":"EEID"}
{"ts":"2026-03-14T10:05:00.000Z","name":"PhoneRegistration.Started"}
{"ts":"2026-03-14T10:05:01.200Z","name":"PhoneRegistration.Success","b2cGetPhoneMs":"310","eeidRegisterMs":"420","totalMs":"730"}
{"ts":"2026-03-14T10:05:02.100Z","name":"PhoneRegistration.Skipped","b2cGetPhoneMs":"280"}
{"ts":"2026-03-14T10:05:03.500Z","name":"PhoneRegistration.Failed","step":"eeid-register","errorCode":"Authorization_RequestDenied"}
{"ts":"2026-03-14T10:05:01.200Z","name":"PhoneRegistration.B2CApiCall","b2cGetPhoneMs":"310"}
{"ts":"2026-03-14T10:05:01.600Z","name":"PhoneRegistration.EEIDApiCall","eeidRegisterMs":"420"}
```

#### File Naming Convention

Telemetry files are written to the console application directory (`src/B2CMigrationKit.Console/`):

| Worker Type | File Pattern | Example |
|---|---|---|
| Worker-migrate | `worker{N}-telemetry.jsonl` | `worker1-telemetry.jsonl`, `worker2-telemetry.jsonl` |
| Phone-registration | `phone-registration{N}-telemetry.jsonl` | `phone-registration1-telemetry.jsonl` |

The `-WorkerCount` parameter tells the script how many file pairs to load (default: 4).

#### Last-Run Boundary Logic

Each telemetry file may contain events from multiple runs (e.g., if the worker was restarted). The script finds the **last** `WorkerMigrate.Started` (or `PhoneRegistration.Started`) event in each file and **ignores all events before it**. This ensures the report reflects only the most recent run.

If no `*.Started` marker is found, all events in the file are included.

#### Analysis Pipeline

The script computes the following for each section:

1. **Latency percentiles** — p50, p90, p95, p99, min, max, and average for each metric (B2C fetch, EEID create, phone GET/POST, etc.)
2. **Wall-time breakdown** — Percentage of total batch wall time spent in B2C fetch vs EEID create (migrate) or B2C GET vs EEID POST (phone)
3. **Throughput** — Users/sec and users/min (migrate), messages/sec and registered/min (phone), calculated from first `*.Started` to last event timestamp
4. **Theoretical max** — Best-case throughput based on average and minimum batch wall times (migrate only)
5. **Tail latency** — Count and percentage of operations exceeding 1 second
6. **Throttle counts** — 429 responses broken down by tenant (B2C vs EEID)
7. **Cross-pipeline coverage** — Users migrated vs phone messages processed; coverage >100% indicates stale messages from a prior run (clear per-worker queues with `az storage queue clear`)

**Note:** Only analyzes the last run per file (events before the last `*.Started` marker are ignored).

---

## Shared Helpers

### _Common.ps1  *(Shared helper functions)*

Shared PowerShell module dot-sourced by all local-run scripts. Provides:

- **Output helpers** — Color-coded console output: `Write-Success` (green), `Write-Info` (cyan), `Write-Warn` (yellow), `Write-Err` (red)
- **`Confirm-AzuriteRunning`** — Checks that Azurite blob (port 10000) and queue (port 10001) ports are open; exits with instructions if not
- **`Get-StorageMode`** — Reads `ConnectionStringOrUri` from a config file and returns whether local Azurite or cloud storage is configured
- **`Initialize-LocalStorage`** — Pre-creates queues (`user-ids-to-process`, `phone-registration`) and audit table via Azure CLI (if available)
- **`Invoke-ConsoleApp`** — Builds and runs the .NET console application with the specified operation and config file

This file is not meant to be run directly. Each script loads it via:
```powershell
. (Join-Path $PSScriptRoot "_Common.ps1")
```

---

## Configuration

### Local Development Configuration

Each operation uses its own config file. Copy the matching example and fill in your credentials:

| Operation | Default config | Copy from |
|-----------|---------------|-----------|
| `harvest` | `appsettings.master.json` | `appsettings.master.example.json` |
| `worker-migrate` | `appsettings.worker1.json` | `appsettings.worker1.example.json` |
| `phone-registration` | `appsettings.phone-registration.json` | `appsettings.phone-registration.example.json` |

All local configs share the same Azurite storage settings:

```json
{
  "Migration": {
    "Storage": {
      "ConnectionStringOrUri": "UseDevelopmentStorage=true",
      "UseManagedIdentity": false
    },
    "Harvest": {
      "QueueName": "user-ids-to-process",
      "IdsPerMessage": 20,
      "PageSize": 999
    },
    "KeyVault": null,
    "Telemetry": {
      "Enabled": false
    }
  }
}
```

**What this means:**
- ✅ **Storage**: Local Azurite emulator (no Azure Storage account needed)
- ✅ **Queue**: Azurite queue service on port 10001
- ✅ **Secrets**: Use `ClientSecret` directly in config (no Key Vault needed)
- ✅ **Telemetry**: Console logging only (no Application Insights needed)

**To run locally, you only need:**
1. Install the **Azurite VS Code extension** (`ms-azuretools.vscode-azurite`)
2. Start Azurite: `Ctrl+Shift+P` → `Azurite: Start Service`
3. Copy each `.example.json` to its corresponding filename and fill in your credentials
4. Run: `.\scripts\Start-LocalHarvest.ps1` then `.\scripts\Start-LocalWorkerMigrate.ps1`

### Production/Cloud Storage

To use Azure Storage instead of Azurite:

```json
{
  "Migration": {
    "Storage": {
      "ConnectionStringOrUri": "https://yourstorage.blob.core.windows.net",
      "UseManagedIdentity": true
    },
    "KeyVault": {
      "VaultUri": "https://yourkeyvault.vault.azure.net/",
      "UseManagedIdentity": true
    }
  }
}
```

The scripts will automatically detect this and skip Azurite.

**📖 See [Developer Guide - Configuration](../docs/DEVELOPER_GUIDE.md#configuration-guide) for complete setup instructions**

### Security Warning

**NEVER commit config files with real secrets to source control!**

All `appsettings.*.json` files (without `.example`) are already in `.gitignore`.

### Azurite Storage Location

When using the VS Code extension, data is stored in the workspace root by default
(same `__azurite_db_*.json` and `__blobstorage__` / `__queuestorage__` files already
in the repo root). To customise the location, set `azurite.location` in VS Code settings.

To view data: use **Azure Storage Explorer** → connect to **Local Emulator**.

**Stopping Azurite:**
- VS Code status bar → click **Azurite Blob Service** → **Stop**
- Or `Ctrl+Shift+P` → `Azurite: Close Service`

---

## Troubleshooting

**"Azurite is not running" / ports not open**

The scripts check TCP ports 10000 (Blob) and 10001 (Queue). If they are not open:

1. Open VS Code
2. Press `Ctrl+Shift+P`
3. Type `Azurite: Start Service` and press Enter
4. Verify the status bar shows **Azurite Blob Service** and **Azurite Queue Service**
5. Re-run the script

Extension install: `ext install ms-azuretools.vscode-azurite`

**"Configuration file not found"**
- Ensure you're in the repository root
- Or use `-ConfigFile` parameter with full path

**"Azurite port already in use"**
- Another process occupies port 10000 or 10001
- Stop the other Azurite instance: VS Code status bar → **Azurite** → **Stop**
- Or terminate the conflict: `Get-Process -Name azurite | Stop-Process`

**"Certificate not found"** (JIT setup)
- Verify path: `Test-Path ".\jit-certificate.txt"`
- Make sure you ran `New-LocalJitRsaKeyPair.ps1` first

**Build errors**
```powershell
dotnet --version  # Should be 8.0+
dotnet clean
```

**Function not called** (JIT)
- Event Listener has correct `appId` in conditions
- User Flow associated with test client app
- User has correct extension attribute set to `true`
- ngrok tunnel is active and URL matches configuration

**"B2C credential validation failed"** (JIT)
- B2C ROPC app configured correctly
- User exists in B2C with same username
- Password matches B2C password
- B2C tenant ID and policy in Function configuration

### Workflow Example

Complete local development workflow:

```powershell
# 1. Start Azurite (VS Code: Ctrl+Shift+P → "Azurite: Start Service")

# 2. Harvest: enqueue all user IDs (run once)
.\scripts\Start-LocalHarvest.ps1 -VerboseLogging

# 3. Workers: migrate users in parallel (open separate terminals)
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json

# 4. (optional) Register MFA phone numbers once workers are done
.\scripts\Start-LocalPhoneRegistration.ps1 -VerboseLogging

# 5. Inspect audit results (use Azure Storage Explorer → Local Emulator → Tables → migration-audit)

# 6. Generate JIT keys
.\scripts\New-LocalJitRsaKeyPair.ps1

# 7. Configure External ID for JIT
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-ngrok.ngrok-free.dev/api/JitAuthentication" `
    -MigrationPropertyId "extension_{ExtensionAppId}_RequiresMigration"

# 8. Test JIT (use Portal → User flows → Run user flow)

# 9. Stop Azurite when done (VS Code status bar → click Azurite → Stop)
```

---

## Additional Resources

- **[Developer Guide](../docs/DEVELOPER_GUIDE.md)** - Complete development documentation
- **[Azurite Documentation](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)** - Local storage emulator
- **[Azure Storage Explorer](https://azure.microsoft.com/features/storage-explorer/)** - Inspect storage data
- **[ngrok Documentation](https://ngrok.com/docs)** - Local tunnel setup
