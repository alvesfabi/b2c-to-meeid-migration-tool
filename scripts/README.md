# B2C Migration Kit - Scripts

This directory contains PowerShell scripts for local development, testing, and JIT migration setup.

**📖 For complete setup instructions, see the [Developer Guide](../docs/DEVELOPER_GUIDE.md)**

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Export & Import Scripts](#export--import-scripts)
- [JIT Migration Setup](#jit-migration-setup)
  - [Generate RSA Keys](#1-generate-rsa-keys)
  - [Configure External ID](#2-configure-external-id)
  - [Switch Environments](#3-switch-environments)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### For Export/Import Operations

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

3. **Configuration** - `appsettings.local.json` with tenant credentials
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

---

## Quick Start

**Recommended workflow:** Use the PowerShell scripts that automatically handle Azurite verification.

> ⚠️ **Azurite must be running first.** Start it from VS Code: `Ctrl+Shift+P` → `Azurite: Start Service`

### Option A – Single-instance export (simple, smaller tenants)

```powershell
.\.scripts\Start-LocalExport.ps1     # Export all users via full pagination
.\.scripts\Start-LocalImport.ps1     # Import to External ID
```

### Option B – Master/Worker export (recommended for 50K+ users)

```powershell
# Step 1: run ONCE – enqueues all user IDs (fast, only fetches 'id' field)
.\scripts\Start-LocalHarvest.ps1

# Step 2: run in PARALLEL, each in its own terminal with its own App Registration
.\scripts\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app1.json
.\scripts\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app2.json
.\scripts\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app3.json

# Step 3: import (same as before)
.\scripts\Start-LocalImport.ps1
```

**✅ What the scripts do automatically:**
- Verify Azurite is running via the VS Code extension (port check – no npm needed)
- Auto-detect whether local Azurite or cloud storage is configured
- Pre-create storage containers (`user-exports`, `migration-errors`, `import-audit`) and queue (`user-ids-to-process`) via Azure CLI (if available)
- Build and run the console application
- Display color-coded progress and status messages

---

## Export & Import Scripts

### Start-LocalExport.ps1

Exports users from Azure AD B2C to local Azurite storage using full pagination (single instance).

**Usage:**
```powershell
.\Start-LocalExport.ps1 [-VerboseLogging] [-ConfigFile "config.json"] [-SkipAzurite]
```

**Parameters:**
- `-ConfigFile` - Configuration file path (default: `appsettings.local.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite port check (use cloud storage)

**What it does:**
1. Validates configuration file exists
2. Detects storage mode (local vs cloud)
3. Verifies Azurite ports 10000/10001 are open (VS Code extension)
4. Pre-creates blob containers via Azure CLI
5. Builds and runs `export` (full B2C pagination → Blob Storage)

> For large tenants use `Start-LocalHarvest.ps1` + `Start-LocalWorkerExport.ps1` instead.

---

### Start-LocalImport.ps1

Imports users from local Azurite Blob Storage to Entra External ID.

**Usage:**
```powershell
.\Start-LocalImport.ps1 [-VerboseLogging] [-ConfigFile "config.json"] [-SkipAzurite]
```

**Parameters:**
- `-ConfigFile` - Configuration file path (default: `appsettings.local.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite port check (use cloud storage)

**What it does:**
1. Validates configuration file exists
2. Detects storage mode (local vs cloud)
3. Verifies Azurite ports 10000/10001 are open (VS Code extension)
4. Pre-creates blob containers via Azure CLI
5. Builds and runs `import` (Blob Storage → Entra External ID)

---

### Start-LocalHarvest.ps1  *(Master/Producer phase)*

Fetches **only user IDs** from B2C at maximum speed (page size 999, `$select=id`) and
enqueues batches of 20 IDs to the Azure Queue `user-ids-to-process`.

**Usage:**
```powershell
.\Start-LocalHarvest.ps1 [-VerboseLogging] [-ConfigFile "config.json"] [-SkipAzurite]
```

**Parameters:**
- `-ConfigFile` - Configuration file (default: `appsettings.local.json`). Use `appsettings.master.json` for a dedicated master config.
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite port check

**What it does:**
1. Verifies Azurite ports are open
2. Pre-creates the queue (`user-ids-to-process`) and blob containers
3. Downloads all user IDs from B2C — extremely fast (only `id` field)
4. Groups IDs into batches of 20 and sends each batch as one queue message
5. Prints a summary with next-step instructions

---

### Start-LocalWorkerExport.ps1  *(Worker/Consumer phase)*

Consumes the queue populated by the harvest phase. Each worker:
- Dequeues one message (20 user IDs)
- Calls `POST /$batch` to fetch full profiles in one HTTP request
- Uploads a blob to `user-exports`
- Deletes the message (ACK)
- Repeats until the queue is empty

Run multiple instances simultaneously, each with a **different App Registration config**
to multiply the API throttle limit by the number of workers.

**Usage:**
```powershell
# Terminal 1
.\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app1.json

# Terminal 2 (simultaneously)
.\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app2.json

# Terminal 3 (simultaneously)
.\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app3.json
```

**Parameters:**
- `-ConfigFile` - Configuration file (default: `appsettings.local.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite port check

**Resilience:** if a worker crashes before ACKing a message, the message automatically
reappears in the queue after the `MessageVisibilityTimeout` (default 5 min) and another
worker (or a re-run) will process it.

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

---

## Configuration

### Local Development Configuration

The scripts use `appsettings.local.json` by default, pre-configured for Azurite:

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
3. Copy `appsettings.json` to `appsettings.local.json`
4. Add your B2C/External ID app registration credentials
5. Run: `.\scripts\Start-LocalHarvest.ps1` then `.\scripts\Start-LocalWorkerExport.ps1`

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

**NEVER commit `appsettings.local.json` with real secrets to source control!**

The file is already in `.gitignore`. For production:
- Use Azure Key Vault for secrets
- Set `Migration.KeyVault.VaultUri`
- Use `ClientSecretName` instead of `ClientSecret`
- Enable Managed Identity authentication

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

# Option A – single-instance export
.\scripts\Start-LocalExport.ps1 -VerboseLogging

# Option B – Master/Worker export (recommended for large tenants)
# 2a. Harvest: enqueue all user IDs (run once)
.\scripts\Start-LocalHarvest.ps1 -VerboseLogging

# 2b. Workers: process queue in parallel (open separate terminals)
.\scripts\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app1.json
.\scripts\Start-LocalWorkerExport.ps1 -ConfigFile appsettings.app2.json

# 3. Inspect exported data (optional – use Azure Storage Explorer, connect to local)

# 4. Import to External ID
.\scripts\Start-LocalImport.ps1 -VerboseLogging

# 5. Generate JIT keys
.\scripts\New-LocalJitRsaKeyPair.ps1

# 6. Configure External ID for JIT
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-ngrok.ngrok-free.dev/api/JitAuthentication" `
    -MigrationPropertyId "extension_{ExtensionAppId}_RequiresMigration"

# 7. Test JIT (use Portal → User flows → Run user flow)

# 8. Stop Azurite when done (VS Code status bar → click Azurite → Stop)
```

---

## Additional Resources

- **[Developer Guide](../docs/DEVELOPER_GUIDE.md)** - Complete development documentation
- **[Azurite Documentation](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)** - Local storage emulator
- **[Azure Storage Explorer](https://azure.microsoft.com/features/storage-explorer/)** - Inspect storage data
- **[ngrok Documentation](https://ngrok.com/docs)** - Local tunnel setup
