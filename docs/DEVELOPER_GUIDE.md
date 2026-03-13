# B2C Migration Kit - Developer Guide

This guide covers the architecture, configuration, and local development workflow for the B2C to External ID Migration Kit.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Configuration Guide](#configuration-guide)
- [Development Workflow](#development-workflow)
  - [Local Development Setup](#local-development-setup)
  - [Building the Solution](#building-the-solution)
  - [Debugging JIT Function with ngrok](#debugging-jit-function-with-ngrok)
- [Attribute Mapping Configuration](#attribute-mapping-configuration)
- [Migration Audit Table](#migration-audit-table)
- [Deployment Guide](#deployment-guide)
- [Operations & Monitoring](#operations--monitoring)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)

## Overview and Current Focus

> **📋 IMPLEMENTATION STATUS**: This repository is focused on exemplifying the implementation of the [Just-In-Time password migration public preview](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-migrate-passwords-just-in-time?tabs=graph). The current implementation provides working examples of export, import, and JIT authentication functions that developers can use as a reference.
>
> **Future Roadmap**: Automated deployment aligned with Secure Future Initiative (SFI) standards, including Bicep/Terraform templates for infrastructure provisioning, is planned for upcoming releases. The current focus is on providing validated migration patterns and code examples rather than production automation tooling.

## Architecture Overview

### Design Principles

The migration kit follows the SFI-Aligned Modular Architecture pattern with these key principles:

1. **Separation of Concerns**: Business logic in Core library, hosting in Console/Function
2. **Dependency Injection**: All services registered via DI for testability
3. **Idempotency**: All operations can be safely retried
4. **Observability**: ILogger-based structured logging; optional Application Insights integration (requires a connection string, untested outside local development)
5. **Security**: SFI-compliant design patterns for future production deployment

### Component Architecture

```
B2CMigrationKit.Core/
├── Abstractions/          # Service interfaces
├── Models/                # Domain models
├── Configuration/         # Configuration classes
├── Services/
│   ├── Infrastructure/    # Azure service clients
│   ├── Observability/     # Telemetry services
│   └── Orchestrators/     # Migration orchestrators
└── Extensions/            # DI registration

B2CMigrationKit.Console/   # CLI for local operations
B2CMigrationKit.Function/  # Azure Function for JIT
```

**Orchestrators**

| Class | Operation | Description |
|---|---|---|
| `HarvestOrchestrator` | `harvest` | Step 1 — pages B2C user IDs, enqueues batches to the migrate queue |
| `WorkerMigrateOrchestrator` | `worker-migrate` | Step 2a — dequeues ID batches, fetches users from B2C, creates in EEID, enqueues phone tasks |
| `PhoneRegistrationWorker` | `phone-registration` | Step 2b — dequeues phone tasks, fetches MFA phone from B2C, registers in EEID (default 400 ms throttle delay) |
| `JitMigrationService` | *(Azure Function)* | Validates B2C credentials and returns `MigratePassword` action |

## Configuration Guide

### Configuration Structure

The toolkit uses hierarchical configuration with `MigrationOptions` as the root:

```json
{
  "Migration": {
    "B2C": { ... },
    "ExternalId": { ... },
    "Storage": { ... },
    "Telemetry": { ... },
    "Retry": { ... },
    "BatchSize": 100
  }
}
```

### B2C Configuration

```json
"B2C": {
  "TenantId": "your-b2c-tenant-id",
  "TenantDomain": "yourtenant.onmicrosoft.com",
  "AppRegistration": {
    "ClientId": "app-id-1",
    "ClientSecretName": "B2CAppSecret1",
    "Name": "B2C App 1",
    "Enabled": true
  },
  "Scopes": [ "https://graph.microsoft.com/.default" ]
}
```

**App Registration Requirements:**
- **Permissions (harvest + worker-migrate)**: `User.Read.All` (Application) — read user IDs and full profiles
- **Permissions (phone-registration)**: `UserAuthenticationMethod.Read.All` (Application) — read MFA phone numbers
- **Authentication**: Client credentials flow (app + secret)
- **Secrets**: Use client secrets directly in configuration for local development
- **Scaling**: Each worker instance needs a **dedicated** B2C app registration on a **dedicated IP** to get independent throttle quotas

### External ID Configuration

```json
"ExternalId": {
  "TenantId": "your-external-id-tenant-id",
  "TenantDomain": "yourtenant.onmicrosoft.com",
  "ExtensionAppId": "00000000000000000000000000000000",
  "AppRegistration": {
    "ClientId": "app-id-1",
    "ClientSecretName": "ExternalIdAppSecret1",
    "Name": "External ID App 1",
    "Enabled": true
  },
}
```

**App Registration Requirements:**

| Process | Required Permission | Type |
|---|---|---|
| `worker-migrate` | `User.ReadWrite.All` | Application |
| `phone-registration` | `UserAuthenticationMethod.ReadWrite.All` | Application |

- **Admin consent** must be granted for each permission in the Azure Portal
- **`Directory.ReadWrite.All` is NOT required** — `User.ReadWrite.All` is sufficient
- **Extension App ID**: the Application ID (without hyphens) used to define custom extension attributes (`RequiresMigration`, `B2CObjectId`)
- **Scaling**: Each worker instance needs a **dedicated** EEID app registration on a **dedicated IP** to get independent throttle quotas

### Harvest Configuration

```json
"Harvest": {
  "QueueName": "user-ids-to-process",
  "IdsPerMessage": 20,
  "PageSize": 999,
  "MessageVisibilityTimeout": "00:30:00"
}
```

**Options:**
- `QueueName` — Storage Queue that worker-migrate instances consume
- `IdsPerMessage` — Number of user IDs packed into a single queue message (tune based on profile size)
- `PageSize` — How many users to request per Graph API page (max 999)
- `MessageVisibilityTimeout` — How long a dequeued message is hidden before becoming visible again if a worker crashes. Default **30 minutes** — covers worst-case retry storms on large batches.

### Phone Registration Configuration

`PhoneRegistration` controls the async phone worker. Worker-migrate automatically enqueues a `{ B2CUserId, EEIDUpn }` message for every user it processes (creates or finds as duplicate). The phone worker then fetches the MFA phone number from B2C at drain time and registers it in EEID.

```json
"PhoneRegistration": {
  "QueueName": "phone-registration",
  "ThrottleDelayMs": 400,
  "MessageVisibilityTimeoutSeconds": 120,
  "EmptyQueuePollDelayMs": 5000,
  "MaxEmptyPolls": 3
}
```

**Options:**
- `ThrottleDelayMs` — Delay (ms) between processing consecutive queue messages (1 GET on B2C + 1 POST on EEID). The phoneMethods API has a significantly lower throttle budget than the user-creation API. Increase this value if you see sustained HTTP 429 responses. To increase throughput, run multiple workers each using **separate B2C and EEID app registrations** (see [Scaling Patterns](#scaling-patterns)). Default: **400 ms**.
- `MessageVisibilityTimeoutSeconds` — How long a message is invisible while being processed. If the worker crashes, the message reappears after this timeout.
- `EmptyQueuePollDelayMs` — How long the worker sleeps between polls when the queue is empty.
- `MaxEmptyPolls` — How many consecutive empty polls before the CLI process exits cleanly.

> **Why async?** The phoneMethods API has a significantly lower throttle budget than the user-creation API. Decoupling via queue lets worker-migrate proceed at full speed while phone registration runs independently at a safe rate.

### Storage Configuration

```json
"Storage": {
  "ConnectionStringOrUri": "https://yourstorage.blob.core.windows.net",
  "AuditTableName": "migrationAudit",
  "UseManagedIdentity": true
}
```

**Required Roles:**
- Console/Function Managed Identity needs:
  - `Storage Queue Data Contributor`
  - `Storage Table Data Contributor`

### Retry Configuration

```json
"Retry": {
  "MaxRetries": 5,
  "InitialDelayMs": 1000,
  "MaxDelayMs": 30000,
  "BackoffMultiplier": 2.0,
  "UseRetryAfterHeader": true,
  "OperationTimeoutSeconds": 120
}
```

### Telemetry Configuration

The toolkit supports dual telemetry output: console logging (local development) and Application Insights (production monitoring).

```json
"Telemetry": {
  "Enabled": true,
  "UseConsoleLogging": true,
  "UseApplicationInsights": false,
  "ConnectionString": "",
  "SamplingPercentage": 100.0,
  "TrackDependencies": true,
  "TrackExceptions": true
}
```

**Configuration Options:**
- `Enabled` - Master switch for all telemetry
- `UseConsoleLogging` - Write telemetry to console (recommended for local development)
- `UseApplicationInsights` - Send telemetry to Azure App Insights (production)
- `ConnectionString` - App Insights connection string (required when UseApplicationInsights=true)
- `SamplingPercentage` - Sampling rate (1.0-100.0) to reduce costs
- `TrackDependencies` - Track HTTP calls, database queries
- `TrackExceptions` - Track unhandled exceptions

**Telemetry Metrics:**
- Harvest: `harvest.users.enqueued`, `harvest.messages.sent`
- Worker Migrate: `WorkerMigrate.UserCreated`, `WorkerMigrate.UserDuplicate`, `WorkerMigrate.UserFailed`
- Phone Registration: `PhoneRegistration.Started`, `PhoneRegistration.Success`, `PhoneRegistration.Failed`, `PhoneRegistration.Completed`, `GraphClient.PhoneMethodRegistered`
- JIT: `JITAuth.PasswordValidated`, `JITAuth.MigrationSuccess`

## Development Workflow

### Local Development Setup

1. **Install Prerequisites**
   ```bash
   # .NET 8.0 SDK
   dotnet --version  # Should be 8.0+

   # Azure Functions Core Tools v4
   func --version  # Should be 4.x

   # Azure CLI (for authentication)
   az login
   ```

   **IDE:** [Visual Studio Code](https://code.visualstudio.com/) with the [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit) extension. The repository includes `.vscode/launch.json` and `.vscode/tasks.json` for debugging Azure Functions locally.

2. **Configure Local Settings**
   
   > **Important:** Each operation uses its own config file. Copy the matching example and fill in your credentials. The example files use `ClientSecret` with direct secret values for local development (no Key Vault required).
   
   ```bash
   cd src/B2CMigrationKit.Console
   cp appsettings.master.example.json appsettings.master.json
   cp appsettings.worker1.example.json appsettings.worker1.json
   cp appsettings.phone-registration.example.json appsettings.phone-registration1.json
   # Edit each file with your tenant credentials
   ```
   
   **Configuration patterns:**
   - **Local development (no Key Vault):** Use `ClientSecret` with the actual secret value
   - **Production (with Key Vault):** Use `ClientSecretName` with the Key Vault secret name

3. **Run Harvest**

   Harvest pages all B2C user IDs and enqueues them in batches to `user-ids-to-process`. Use `MaxUsers` in `appsettings.master.json` to cap results (e.g. `20` for a smoke test, `0` for unlimited).

   ```powershell
   .\scripts\Start-LocalHarvest.ps1
   ```

4. **Run Worker Migrate**

   Worker Migrate dequeues ID batches, fetches full user profiles from B2C, creates users in EEID, and enqueues `{ B2CUserId, EEIDUpn }` messages to `phone-registration`.

   **Single instance (smoke test):**
   ```powershell
   .\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json -VerboseLogging
   ```

   **Multiple parallel instances (production scale — open a separate terminal for each):**
   ```powershell
   # Terminal 1
   .\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json
   # Terminal 2
   .\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json
   # Terminal 3
   .\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker3.json
   # Terminal 4
   .\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker4.json
   ```

   Each config file must reference a **different B2C and EEID app registration**. Workers pull from the same queue with no coordination needed — queue visibility timeouts guarantee at-most-once delivery per message. Workers exit automatically when the queue is empty.

   Users that already exist in EEID are recorded as `Duplicate` (handled gracefully; phone task is still enqueued).

   **Required app registration permissions (grant with Admin Consent):**

   | Tenant | Permission | Type |
   |---|---|---|
   | B2C | `User.Read.All` | Application |
   | Entra External ID | `User.ReadWrite.All` | Application |

5. **Run Phone Registration Worker**

   After worker-migrate (or while it is still running), drain the `phone-registration` queue. The worker fetches each user's MFA phone number from B2C and registers it in EEID. Users with no MFA phone are recorded as `PhoneSkipped`.

   **Single instance:**
   ```powershell
   .\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.phone-registration1.json -VerboseLogging
   ```

   **Multiple parallel instances (open a separate terminal for each):**
   ```powershell
   # Terminal 1
   .\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.phone-registration1.json
   # Terminal 2
   .\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.phone-registration2.json
   # Terminal 3
   .\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.phone-registration3.json
   # Terminal 4
   .\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.phone-registration4.json
   ```

   Each config file must reference a **different B2C and EEID app registration**. Workers process independently — each drains the phone queue at its own `ThrottleDelayMs` rate and exits after `MaxEmptyPolls` consecutive empty polls.

   The worker treats 409 Conflict as success (phone already registered — idempotent).

   **Required app registration permissions (grant with Admin Consent):**

   | Tenant | Permission | Type | Notes |
   |---|---|---|---|
   | B2C | `UserAuthenticationMethod.Read.All` | Application | Read MFA phone numbers |
   | Entra External ID | `UserAuthenticationMethod.ReadWrite.All` | Application | Register phone methods |

### Building the Solution

```bash
# Build all projects
dotnet build

# Build specific project
dotnet build src/B2CMigrationKit.Core

# Build for release
dotnet build -c Release
```


### JIT (Just-In-Time) Migration Implementation

⏱️ **Quick Start Time:** 15 minutes to running local test

The JIT authentication function integrates with External ID Custom Authentication Extension to migrate user passwords during their first login attempt. This section covers the complete implementation from local development to production deployment.

---

#### Prerequisites

**Required Tools:**
- [Visual Studio Code](https://code.visualstudio.com/) with the [C# Dev Kit](https://marketplace.visualstudio.com/items?itemName=ms-dotnettools.csdevkit) extension
- .NET 8+ SDK
- Azure Functions Core Tools v4 (`func --version`)
- ngrok (free tier: [ngrok.com](https://ngrok.com))
- PowerShell 7+
- OpenSSL (only if generating RSA keys manually instead of using the PowerShell script)

**Required Access:**
- Azure AD B2C tenant with test users
- External ID tenant with admin access
- Test users with known passwords

---

#### Understanding JIT Trigger Mechanism

**Critical Requirement:** External ID ONLY triggers JIT migration when:
1. User enters password that **does NOT match** stored password in External ID
2. AND `extension_<appId>_RequiresMigration == true`

**Why This Matters:**

During the bulk import phase, `WorkerMigrateOrchestrator` generates **unique 16-character random passwords** for each user. These are **NOT** the user's real B2C passwords. This intentional mismatch ensures password validation fails on first login, triggering the JIT migration flow.

**User Login Flow:**

| Phase | What happens |
|---|---|
| **Worker Migrate** | `WorkerMigrateOrchestrator` creates the EEID user with a random 16-char placeholder password and sets `RequiresMigration = true`. |
| **First login** | User enters their real B2C password → mismatch triggers JIT → function validates against B2C, updates EEID password, sets `RequiresMigration = false`. |
| **Subsequent logins** | EEID password matches → normal authentication, no JIT call. |

**Password Generation Implementation:**

Located in `WorkerMigrateOrchestrator.cs` (line 530). 16-char password with guaranteed 1 uppercase + 1 lowercase + 1 digit + 1 special char, shuffled to prevent patterns. Purpose: ensure mismatch with the real B2C password to reliably trigger JIT on first login.

---

#### JIT Function Local Setup

**Step 1: Generate RSA Key Pair (5 minutes)**

**Option A: Use automation script (recommended)**
```powershell
.\scripts\New-LocalJitRsaKeyPair.ps1 -OutputPath ".\scripts\keys"
```

**Option B: Manual with OpenSSL**
```bash
# Generate private key (2048-bit RSA)
openssl genrsa -out private_key.pem 2048

# Extract public key
openssl rsa -in private_key.pem -pubout -out public_key.pem
```

**Verify keys created:**
```powershell
Get-ChildItem .\scripts\keys\

# Expected output:
# jit-private-key.pem       (RSA private key - NEVER commit to Git)
# jit-public-key.jwk.json   (Public key in JWK format)
# jit-certificate.txt       (X.509 certificate for Custom Extension)
# jit-public-key-x509.txt   (Public key in X.509 format)
```

---

**Step 2: Configure local.settings.json**

Create or update `src/B2CMigrationKit.Function/local.settings.json`:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",

    "Migration__B2C__TenantId": "YOUR_B2C_TENANT_ID_GUID",
    "Migration__B2C__TenantDomain": "YOUR_B2C_TENANT.onmicrosoft.com",
    "Migration__B2C__AppRegistration__ClientId": "YOUR_ENTRA_APP_CLIENT_ID",
    "Migration__B2C__AppRegistration__ClientSecret": "YOUR_ENTRA_APP_CLIENT_SECRET",
    "Migration__B2C__AppRegistration__Name": "B2C Entra ROPC App (JIT Auth)",
    "Migration__B2C__AppRegistration__Enabled": "true",

    "Migration__ExternalId__TenantId": "YOUR_EXTERNAL_ID_TENANT_ID",
    "Migration__ExternalId__TenantDomain": "YOUR_EXTERNAL_ID_TENANT.onmicrosoft.com",
    "Migration__ExternalId__ExtensionAppId": "YOUR_EXTENSION_APP_ID_WITHOUT_DASHES",
    "Migration__ExternalId__AppRegistration__ClientId": "YOUR_EXTERNAL_ID_CLIENT_ID",
    "Migration__ExternalId__AppRegistration__ClientSecret": "YOUR_EXTERNAL_ID_CLIENT_SECRET",
    "Migration__ExternalId__AppRegistration__Name": "External ID App Registration",
    "Migration__ExternalId__AppRegistration__Enabled": "true",

    "Migration__JitAuthentication__UseKeyVault": "false",
    "Migration__JitAuthentication__TestMode": "true",
    "Migration__JitAuthentication__RsaKeyName": "JIT-RSA-PrivateKey",
    "Migration__JitAuthentication__MigrationAttributeName": "RequiresMigration",
    "Migration__JitAuthentication__InlineRsaPrivateKey": "-----BEGIN PRIVATE KEY-----\nYOUR_RSA_PRIVATE_KEY_HERE\n-----END PRIVATE KEY-----",
    "Migration__JitAuthentication__CachePrivateKey": "true",
    "Migration__JitAuthentication__TimeoutSeconds": "1.5"
  }
}
```

> **Note:** Azure Functions `local.settings.json` uses flat keys with `__` as separator (not nested JSON objects). See `local.settings.example.json` for a complete template.

**Key Configuration Notes:**
- **UseKeyVault: false** → Uses inline RSA key for local development (set to true for production with Key Vault)
- **TestMode: true** → Skips B2C validation (for testing without B2C access)
- **InlineRsaPrivateKey** → Paste entire private key content (including headers), replacing newlines with `\n`

---

**Step 3: Start Function Locally with ngrok**

Use the provided PowerShell script that handles both the function and ngrok tunnel:

```powershell
cd src\B2CMigrationKit.Function
.\start-local.ps1
```

**What the script does:**
- Builds the function
- Starts ngrok tunnel with static domain (or dynamic if not configured)
- Starts Azure Function on port 7071
- Copies the public endpoint URL to clipboard

**Expected Output:**
```
═══════════════════════════════════════════════
✅ ngrok Tunnel Active (Static Domain)
═══════════════════════════════════════════════

  Function URL: https://your-domain.ngrok-free.dev/api/JitAuthentication
  Static Domain: your-domain.ngrok-free.dev

✅ Function endpoint URL copied to clipboard!

Functions:
  JitAuthentication: [POST] http://localhost:7071/api/JitAuthentication
```

**Manual alternative** (without automation script):
```powershell
# Terminal 1: Start ngrok
ngrok http 7071

# Terminal 2: Start function
cd src\B2CMigrationKit.Function
func start
```

**✅ Success Indicators:**
- Function running on `http://localhost:7071`
- ngrok tunnel active with public HTTPS URL
- No errors about missing RSA key
- Logs show "Using inline RSA private key"

---

**Step 3b: Set Up VS Code Debugging**

The repository includes pre-configured VS Code debug files in `.vscode/` that let you attach the debugger to the running Azure Function process. This is essential for setting breakpoints in the JIT authentication flow.

The repository includes pre-configured `.vscode/launch.json` ("Attach to .NET Functions") and `.vscode/tasks.json` ("build-function"). No manual setup required.

**To debug:**
1. Start the function with `start-local.ps1` (or manually with `func start`)
2. In VS Code, press **F5** (or **Run → Start Debugging**)
3. Select **"Attach to .NET Functions"** from the configuration dropdown
4. Pick the **`dotnet`** process running the function (look for `B2CMigrationKit.Function.dll`)
5. Set breakpoints in `JitAuthenticationFunction.cs` and trigger a login flow

**Useful breakpoints:**
- `JitAuthenticationFunction.cs:60` — Parse External ID payload
- `JitAuthenticationFunction.cs:123` — Call JitMigrationService
- `JitMigrationService.cs:73` — Get user and check migration status
- `JitMigrationService.cs:125` — Validate credentials against B2C via ROPC
- `JitMigrationService.cs:156` — Validate password complexity
- `JitMigrationService.cs:193` — Update user extension attributes

---

**Step 4: Configure Custom Authentication Extension**

**Prerequisites Checklist:**
- ✅ RSA keys generated (jit-private-key.pem, jit-public-key.jwk.json)
- ✅ Function local.settings.json configured with keys and credentials
- ✅ Users imported to External ID with RequiresMigration=true
- ✅ External ID tenant admin access
- ✅ Function running locally with ngrok tunnel active

**Sub-Step 1: Create Custom Extension App Registration**

1. **Go to Azure Portal → External ID Tenant**
2. **Navigate to:** App registrations → New registration
3. **Configuration:**
   - Name: `Custom Authentication Extension - JIT Migration`
   - Supported account types: `Accounts in this organizational directory only`
   - Redirect URI: Leave blank
   - Click **Register**

4. **Record the IDs:**
   ```
   Application (client) ID: ______________________
   Object ID: ______________________
   Directory (tenant) ID: ______________________
   ```

5. **Create Client Secret:**
   - Go to **Certificates & secrets**
   - **Client secrets** → **New client secret**
   - Description: `Custom Extension Secret`
   - Expires: 6 months (for testing)
   - Click **Add**
   - **COPY THE VALUE IMMEDIATELY**

---

**Sub-Step 2: Upload RSA Public Key**

⚠️ **IMPORTANT:** Azure Portal does NOT support uploading custom keys via UI. You MUST use Graph API.

```powershell
# Read the public key JWK
$publicKeyPath = "c:\code\B2C Migration\scripts\jit-public-key.jwk.json"
$publicKeyJwk = Get-Content $publicKeyPath -Raw | ConvertFrom-Json

# Custom Extension App details (from Sub-Step 1)
$tenantId = "your-tenant-id"
$customExtensionAppObjectId = "PASTE_OBJECT_ID_HERE"

# Get admin token
$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

# Prepare key credential
$keyCred = @{
    type = "AsymmetricX509Cert"
    usage = "Verify"
    key = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicKeyJwk | ConvertTo-Json -Compress))
    displayName = "JIT Migration RSA Public Key"
    customKeyIdentifier = [System.Text.Encoding]::UTF8.GetBytes($publicKeyJwk.kid)
}

# Upload to app registration
$body = @{
    keyCredentials = @($keyCred)
    tokenEncryptionKeyId = $publicKeyJwk.kid
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Patch `
    -Uri "https://graph.microsoft.com/beta/applications/$customExtensionAppObjectId" `
    -Headers @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    } `
    -Body $body

Write-Host "✓ Public key uploaded successfully!" -ForegroundColor Green
```

---

**Sub-Step 3: Create Custom Authentication Extension Resource**

```powershell
$tenantId = "your-tenant-id"
$ngrokUrl = "https://abc123.ngrok.app"
$customExtensionAppClientId = "PASTE_CLIENT_ID_HERE"

$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

$extensionBody = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitCustomExtension"
    displayName = "JIT Password Migration Extension - Local Testing"
    description = "Validates passwords against B2C and migrates users on first successful login"
    targetUrl = "$ngrokUrl/api/JitAuthentication"
    authenticationConfiguration = @{
        "@odata.type" = "#microsoft.graph.azureAdTokenAuthentication"
        resourceId = "api://$customExtensionAppClientId"
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" `
    -Headers @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    } `
    -Body $extensionBody

Write-Host "✓ Custom Extension created successfully!" -ForegroundColor Green
Write-Host "Extension ID: $($response.id)" -ForegroundColor Cyan

$extensionId = $response.id
$extensionId | Out-File "custom-extension-id.txt"
```

---

**Sub-Step 4: Create OnPasswordSubmit Listener Policy**

```powershell
$extensionAppId = "d7e9bb7927284f7c85d0fa045ec77b1f"  # Without dashes
$extensionId = Get-Content "custom-extension-id.txt"

# Apply to ALL applications (easier for testing)
$conditions = @{
    applications = @{
        includeAllApplications = $true
    }
}

$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

$listenerBody = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitListener"
    priority = 500
    conditions = $conditions
    handler = @{
        "@odata.type" = "#microsoft.graph.onPasswordMigrationCustomExtensionHandler"
        migrationPropertyId = "extension_${extensionAppId}_RequiresMigration"
        customExtension = @{
            id = $extensionId
        }
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" `
    -Headers @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    } `
    -Body $listenerBody

Write-Host "✓ Authentication Event Listener created successfully!" -ForegroundColor Green
```

**Verification Checklist:**
- [ ] Custom Extension app registered
- [ ] RSA public key uploaded
- [ ] Azure Function running locally
- [ ] ngrok tunnel active
- [ ] Custom Extension resource created
- [ ] Authentication Event Listener created
- [ ] Test user exists with RequiresMigration=true

---

**Step 4: Import Test User**

Run worker-migrate to create users in EEID with random passwords:

```powershell
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json
```

**Verify in External ID:**
- User exists: `user@domain.com`
- `extension_<appId>_RequiresMigration == true`
- Password is NOT the real B2C password

---

**Step 5: Test JIT Flow**

**Test with HTTP Client:**

Create `test-jit.http`:
```http
POST https://abc123.ngrok.app/api/JitAuthentication
Content-Type: application/json

{
  "type": "customAuthenticationExtension",
  "data": {
    "authenticationContext": {
      "correlationId": "test-12345",
      "user": {
        "id": "user-object-id-from-external-id",
        "userPrincipalName": "testuser@yourdomain.com"
      }
    },
    "passwordContext": {
      "userPassword": "RealB2CPassword123!",
      "nonce": "test-nonce-value"
    }
  }
}
```

**Expected Response (TestMode=true):**
```json
{
  "data": {
    "actions": [
      {
        "@odata.type": "microsoft.graph.customAuthenticationExtension.migratePassword"
      }
    ]
  }
}
```

---

#### ngrok Web Interface

Access the ngrok web interface for request inspection:

```
http://localhost:4040
```

**Features:**
- View all HTTP requests to your function
- Inspect request/response headers and body
- **Replay requests** - Reproduce errors without redoing login flow
- Filter by path (`/api/JitAuthentication`) or status code

---

#### Production Deployment

> **⚠️ IMPORTANT**: Production deployment with secure certificate management and automated infrastructure provisioning will be **fully implemented and validated in v2.0**. 
>
> **Current Release (v1.0)**:
> - ✅ Local development with self-signed certificates and inline secrets (gitignored configuration files)
> - ✅ Development testing and validation with ngrok
>
> **Future Release (v2.0)**:
> - 🔜 Secure certificate management automation
> - 🔜 Managed Identity for Azure Function
> - 🔜 Production Azure Function deployment templates
> - 🔜 Automated infrastructure deployment aligned with SFI

---

#### JIT Troubleshooting

**Issue: JIT Not Triggering**

**Symptom:** User enters correct B2C password but no JIT call happens

**Solutions:**
```powershell
# Verify user has random password (not real B2C password)
Get-MgUser -UserId "user@domain.com" | Select-Object PasswordProfile

# Check RequiresMigration status
Get-MgUser -UserId "user@domain.com" -Property "extension_*" | 
    Select-Object -ExpandProperty AdditionalProperties

# Verify custom extension is assigned
Get-MgIdentityAuthenticationEventsFlow
```

---

**Issue: ngrok URL Changes on Restart**

**Solutions:**

Quick update with automation:
```powershell
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-tenant-id" `
    -FunctionUrl "https://NEW-URL.ngrok.app/api/JitAuthentication" `
    -CertificatePath ".\keys\jit-certificate.txt"
```

Or use ngrok paid plan for static domain:
```powershell
ngrok http 7071 --domain=myapp.ngrok.app
```

---

**Issue: Function Timeout (2 seconds)**

**Optimize configuration:**
```json
{
  "Migration": {
    "JitAuthentication": {
      "TimeoutSeconds": 1.5,
      "CachePrivateKey": true
    },
    "Retry": {
      "MaxRetries": 1,
      "DelaySeconds": 0.1
    }
  }
}
```

**Monitor performance:**
```kusto
requests
| where name == "JitAuthentication"
| summarize avg(duration), max(duration), percentile(duration, 95)
```

**Target: < 1500ms for 95th percentile**

---

**Issue: Test Mode Enabled in Production**

⚠️ **Security Warning:** TestMode=true in production:
- Skips B2C credential validation (ANY password accepted)
- Skips password complexity checks
- Allows unauthorized access
- **NEVER use in production**

**Solution:**
```powershell
az functionapp config appsettings set `
    --name my-function `
    --resource-group my-rg `
    --settings "Migration__JitAuthentication__TestMode=false"
```

---

#### JIT Configuration Reference

**Local Development:**
```json
{
  "Migration": {
    "JitAuthentication": {
      "UseKeyVault": false,
      "TestMode": true,
      "InlineRsaPrivateKey": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
      "TimeoutSeconds": 1.5,
      "CachePrivateKey": true
    }
  }
}
```

> **Note**: Production configuration will be documented in v2.0 with automated deployment templates.

#### Common JIT Debugging Scenarios

**Scenario: User Not Found**
- Check userId in payload: `[JIT Function] Parsed External ID payload | UserId: ...`
- Verify user exists: `az ad user show --id "<userId>"`
- Check app registration permissions

**Scenario: B2C Credential Validation Failed**
- Verify ROPC policy exists: `B2C_1_ROPC`
- Test B2C login directly:
  ```bash
  curl -X POST https://b2cprod.b2clogin.com/b2cprod.onmicrosoft.com/B2C_1_ROPC/oauth2/v2.0/token \
    -d "grant_type=password" \
    -d "username=test@b2cprod.onmicrosoft.com" \
    -d "password=Test123!@#" \
    -d "client_id=<client-id>" \
    -d "scope=openid"
  ```
- Check UPN transformation between External ID and B2C

**Scenario: Password Complexity Failed**
- Check password policy in `local.settings.json`
- Verify password has: 8+ chars, uppercase, lowercase, digit, special char
- Set breakpoint at `JitMigrationService.cs:156`
- User must reset password via SSPR

**Scenario: Graph API Throttling (HTTP 429)**
- General Users API limit: ~60 ops/sec per app registration
- `authenticationMethod` API limit: **30 req/10s per app registration (~3 RPS)** — default `ThrottleDelayMs` is 400 ms; increase if you see sustained 429s
- View retry logs: `[GraphClient] Request throttled (429/503) - Retrying in X ms...`
- For load testing, add delays between requests

#### JIT Debugging Tips

- **Use ngrok replay** to reproduce errors quickly
- **Filter logs by CorrelationId** to trace end-to-end operations
- **Use conditional breakpoints**: Right-click breakpoint → `userPrincipalName.Contains("testuser")`
- **Monitor ngrok web UI** (localhost:4040) for all requests in real-time
- **Rebuild after code changes**: `dotnet build src/B2CMigrationKit.Function`

---

## Attribute Mapping Configuration

### Overview

Both Azure AD B2C and Entra External ID use the same Microsoft Graph User object model. Most attributes can be copied directly without mapping. However, you may need to:

1. **Map custom extension attributes** with different names between tenants
2. **Exclude certain fields** from being copied
3. **Configure migration-specific attributes** (B2CObjectId, RequiresMigration)

### Configuration Structure

#### Export Configuration

Controls which fields are exported from B2C:

```json
{
  "Migration": {
    "Export": {
      "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities,extension_abc123_CustomerId"
    }
  }
}
```

**Default fields:**
- `id` - User's ObjectId (required)
- `userPrincipalName` - UPN
- `displayName` - Display name
- `givenName` - First name
- `surname` - Last name
- `mail` - Email address
- `mobilePhone` - Mobile phone
- `identities` - All user identities

**To add custom extension attributes:**
Add them to the comma-separated list in `SelectFields`. For example:
```
"SelectFields": "id,userPrincipalName,displayName,...,extension_abc123_CustomerId,extension_abc123_Department"
```

#### Import Configuration

Controls how attributes are imported into External ID:

```json
{
  "Migration": {
    "Import": {
      "AttributeMappings": {
        "extension_abc123_LegacyId": "extension_xyz789_CustomerId"
      },
      "ExcludeFields": ["createdDateTime"],
      "MigrationAttributes": {
        "StoreB2CObjectId": true,
        "B2CObjectIdTarget": "extension_xyz789_OriginalB2CId",
        "SetRequireMigration": true,
        "RequiresMigrationTarget": "extension_xyz789_RequiresMigration"
      }
    }
  }
}
```

##### AttributeMappings

Maps source attribute names to different target names.

**Key** = source attribute name in B2C
**Value** = target attribute name in External ID

Example:
```json
"AttributeMappings": {
  "extension_b2c_app_LegacyCustomerId": "extension_extid_app_CustomerId",
  "extension_b2c_app_Department": "extension_extid_app_DepartmentCode"
}
```

**Behavior:**
- If attribute is in mappings: rename it to target name
- If attribute is NOT in mappings: copy as-is (same name)
- All attributes not explicitly mapped or excluded are copied unchanged

##### ExcludeFields

List of field names to exclude from import. These fields will not be copied to External ID.

```json
"ExcludeFields": [
  "createdDateTime",
  "lastPasswordChangeDateTime",
  "extension_abc123_TemporaryField"
]
```

##### MigrationAttributes

Controls migration-specific attributes:

**StoreB2CObjectId** (bool, default: `true`)
- Whether to store the original B2C ObjectId in External ID
- Useful for correlation and troubleshooting
- Set to `false` if you don't need this tracking

**B2CObjectIdTarget** (string, optional)
- Target attribute name for storing B2C ObjectId
- Default: `extension_{ExtensionAppId}_B2CObjectId`
- Only used if `StoreB2CObjectId` is `true`

**SetRequireMigration** (bool, default: `true`)
- Whether to set the RequiresMigration flag
- Used by JIT authentication to know if password needs migration
- The value is set to `true` by default (password NOT yet migrated)
- Set to `false` if using a different migration tracking mechanism

**RequiresMigrationTarget** (string, optional)
- Target attribute name for the RequiresMigration flag
- Default: `extension_{ExtensionAppId}_RequiresMigration`
- Only used if `SetRequireMigration` is `true`

### Common Mapping Scenarios

**Scenario 1 (no custom attributes):** Leave `AttributeMappings` as `{}` — standard fields copy automatically.

#### Scenario 2: Different Extension Attribute Names

If attribute names differ between B2C and External ID:

```json
{
  "Export": {
    "SelectFields": "id,userPrincipalName,...,extension_b2c_CustomerId"
  },
  "Import": {
    "AttributeMappings": {
      "extension_b2c_CustomerId": "extension_extid_LegacyUserId"
    }
  }
}
```

The `extension_b2c_CustomerId` will be renamed to `extension_extid_LegacyUserId` during import.

#### Scenario 3: Complex Mapping with Multiple Custom Attributes

```json
{
  "Export": {
    "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities,extension_abc_CustomerId,extension_abc_Department,extension_abc_EmployeeType,extension_abc_CostCenter"
  },
  "Import": {
    "AttributeMappings": {
      "extension_abc_CustomerId": "extension_xyz_LegacyId",
      "extension_abc_Department": "extension_xyz_DeptCode",
      "extension_abc_EmployeeType": "extension_xyz_UserType"
    },
    "ExcludeFields": [
      "extension_abc_CostCenter"
    ],
    "MigrationAttributes": {
      "StoreB2CObjectId": true,
      "B2CObjectIdTarget": "extension_xyz_B2COriginalId",
      "SetRequireMigration": true,
      "RequiresMigrationTarget": "extension_xyz_RequiresMigration"
    }
  }
}
```

This configuration:
- Exports 4 custom extension attributes
- Maps 3 of them to different names
- Excludes `CostCenter` from import
- Stores B2C ObjectId as `extension_xyz_B2COriginalId`
- Sets migration flag as `extension_xyz_Migrated`

### Important Notes for Attribute Mapping

#### 1. Create Extension Attributes First

Before importing, ensure all target custom attributes exist in your External ID tenant:

1. Go to **Azure Portal** → **External Identities** → **Custom user attributes**
2. Create each custom attribute you plan to use
3. Note the full attribute name: `extension_{appId}_{attributeName}`

#### 2. Extension App ID

The `ExtensionAppId` (without dashes) is used to construct full attribute names:

```json
{
  "ExternalId": {
    "ExtensionAppId": "abc123def456..."  // No dashes!
  }
}
```

Full attribute name format: `extension_{ExtensionAppId}_{attributeName}`

#### 3. Standard User Object Fields

Standard Graph API User fields are copied automatically (if included in export):
- displayName, givenName, surname
- mail, mobilePhone, otherMails
- streetAddress, city, state, postalCode, country
- userPrincipalName, identities
- accountEnabled

These do NOT need mapping unless you're using a non-standard scenario.

#### 4. Automatic Transformations

The import process automatically handles:
- **UPN domain update**: Changes `user@b2c.onmicrosoft.com` to `user@externalid.onmicrosoft.com`
- **Identity issuer update**: Updates identity issuer from B2C domain to External ID domain
- **Password replacement**: Sets random placeholder password for JIT migration

### UPN and Email Identity Transformation

**Background**: Entra External ID enforces stricter validation than Azure AD B2C:
- UPNs must belong to the External ID tenant domain
- All users must have an `emailAddress` identity (required for OTP and password reset)
- B2C allows users without email addresses; External ID does not

**Automatic Transformation Logic**:

The import orchestrator automatically applies these transformations:

#### 1. UPN Domain Transformation

**Code Location**: `WorkerMigrateOrchestrator.cs:TransformUpn()`

**Purpose**: Changes the UPN domain from B2C to External ID while **preserving the local part identifier** to enable JIT authentication. This approach serves as a workaround to enable the use of the [sign-in alias](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-sign-in-alias) feature **during** JIT password migration in Entra External ID.

**Note**: This implementation differs from the official Microsoft documentation approach, which creates entirely new UPNs. By preserving the local part of the UPN, we maintain user identifier continuity across both tenants, enabling seamless JIT authentication and supporting sign-in alias scenarios during the migration process.

```csharp
// Original B2C UPN
user.UserPrincipalName = "user#EXT#@b2cprod.onmicrosoft.com"

// Transformation steps:
// 1. Extract local part (before @): "user#EXT#"
// 2. Remove #EXT# markers: "user"
// 3. Remove underscores and dots from local part: "user" (unchanged in this case)
// 4. Replace domain with External ID tenant domain
// 5. If local part is empty after cleaning, generate GUID-based identifier

// Result
user.UserPrincipalName = "user@externalid.onmicrosoft.com"
// OR (if local part becomes empty after cleaning)
user.UserPrincipalName = "28687c60@externalid.onmicrosoft.com"
```

**Why Preserve the Local Part?**

The local part (identifier before @) is preserved because the **JIT Function reverses this transformation** during authentication:

```csharp
// JIT Function: TransformUpnForB2C() - Located in JitAuthenticationFunction.cs

// 1. External ID provides UPN during login
string externalIdUpn = "user@externalid.onmicrosoft.com";

// 2. JIT extracts local part
string localPart = "user";  // Everything before @

// 3. Reconstructs B2C UPN with B2C domain
string b2cUpn = "user@b2cprod.onmicrosoft.com";

// 4. Validates credentials against B2C ROPC using this B2C UPN
```

**Key Points**:
- ✅ **Local part preserved**: Acts as unique identifier across both tenants
- ✅ **Only domain changes**: From B2C domain to External ID domain (import) and vice versa (JIT)
- ✅ **Bidirectional mapping**: Import transforms B2C→External ID, JIT transforms External ID→B2C
- ⚠️ **Critical for JIT**: If local part is not preserved, JIT cannot map users back to B2C

**Configuration**: The target domain is taken from `Migration.ExternalId.TenantDomain` in appsettings.json.

#### 2. Authentication Method Handling (Email Identity)

**Code Location**: `WorkerMigrateOrchestrator.cs:EnsureEmailIdentity()`

**Important**: External ID requires all users to have an email identity for authentication. The import logic ensures every user gets an email identity for the Email+Password flow with JIT migration.

```csharp
// Decision tree (WorkerMigrateOrchestrator.cs:EnsureEmailIdentity):
// 1. User already has emailAddress identity → keep it, no change
// 2. User has 'mail' field → create emailAddress identity from mail
// 3. User has NO 'mail' → use userPrincipalName as email fallback (logs a warning)
```

**Identity rules applied to every user:**
- All identity `issuer` fields are updated from the B2C domain to the EEID domain
- `userName` and `userPrincipalName` identities are preserved as-is (only issuer changes)
- A `emailAddress` identity is added if one is not already present (required by EEID)

### Impact on Attribute Mapping

**UPN and Authentication Methods** are NOT subject to attribute mapping configuration:
- UPN transformation happens automatically regardless of `AttributeMappings`
- Email identity creation logic cannot be disabled
- SMS (mobilePhone) is automatically migrated if present
- Standard identity transformations cannot be disabled

**Standard User Fields** are migrated automatically (no mapping needed):
- `mobilePhone` - **Critical for SMS-based SSPR**
- `mail` - Used for email identity if present
- `displayName`, `givenName`, `surname`
- `streetAddress`, `city`, `state`, `postalCode`, `country`
- `userPrincipalName`, `identities`, `accountEnabled`

**Custom Extension Attributes** ARE subject to mapping:
- Use `AttributeMappings` to rename extension attributes
- Use `ExcludeFields` to prevent copying specific attributes

### Debugging UPN/Email/SMS Transformations

Enable verbose logging to see transformation details:

```json
{
  "Migration": {
    "VerboseLogging": true
  }
}
```

## Migration Audit Table

### Overview

Every user processed by the worker-migrate and phone-registration steps is recorded as a row in the `migrationAudit` Azure Table Storage table. This provides a durable, queryable audit trail of each migration outcome without requiring blob containers.

### Benefits

- **Compliance**: Permanent, tamper-evident record of all migration activities
- **Auditing**: Query by user ID, status, or time range at any point
- **Troubleshooting**: Error codes and messages are stored per-row for instant diagnosis
- **No extra containers**: Uses Table Storage — no blob containers required

### Table Schema

| Column | Type | Description |
|---|---|---|
| `PartitionKey` | string | Run date in `yyyyMMdd` format (groups all records for a day) |
| `RowKey` | string | `{stage}_{B2CObjectId}` where stage is `migrate` or `phone` |
| `Status` | string | `Created`, `Duplicate`, `Failed`, `PhoneRegistered`, `PhoneSkipped` |
| `DurationMs` | double | How long the Graph API call took |
| `ErrorCode` | string | OData error code when `Status = Failed` (otherwise empty) |
| `ErrorMessage` | string | Human-readable error detail when `Status = Failed` (otherwise empty) |

### Status Values

| Status | Meaning |
|---|---|
| `Created` | User was successfully created in EEID |
| `Duplicate` | User already existed in EEID (idempotent re-run) |
| `Failed` | User creation failed for a non-duplicate reason |
| `PhoneRegistered` | MFA phone number registered in EEID successfully |
| `PhoneSkipped` | User had no MFA phone in B2C — no phone registration needed |

### Configuration

The table name is set via `Migration.Storage.AuditTableName`:

```json
{
  "Migration": {
    "Storage": {
      "AuditTableName": "migrationAudit"
    }
  }
}
```

The table is created automatically if it does not exist.

### Viewing the Audit Table

#### Azure Portal

1. Navigate to your Storage Account
2. Select **Tables** in the left menu
3. Open the `migrationAudit` table
4. Use the query editor to filter by `PartitionKey` (B2C objectId) or `Status`

#### Azure Storage Explorer

1. Connect to your storage account (or use `UseDevelopmentStorage=true` for Azurite)
2. Expand **Tables**
3. Open `migrationAudit`
4. Right-click → **Query** to filter rows

#### Azure CLI

List all rows for a specific user:
```bash
az storage entity query \
  --account-name <storage-account> \
  --table-name migrationAudit \
  --filter "PartitionKey eq '<b2c-object-id>'" \
  --output table
```

Count failed rows:
```bash
az storage entity query \
  --account-name <storage-account> \
  --table-name migrationAudit \
  --filter "Status eq 'Failed'" \
  --output table
```

#### Local Development (Azurite)

Open Azure Storage Explorer, connect with `UseDevelopmentStorage=true`, then expand **Tables** → `migrationAudit`.

### Generating a Migration Report

PowerShell example using the Azure.Data.Tables SDK:

```powershell
$storageAccountName = "<storage-account>"
$ctx = New-AzStorageContext -StorageAccountName $storageAccountName -UseConnectedAccount

# Query all audit rows
$rows = Get-AzTableRow -TableName "migrationAudit" -Context $ctx

# Summarise by status
$rows | Group-Object Status | Select-Object Name, Count | Format-Table -AutoSize

# Export failures for review
$rows | Where-Object { $_.Status -eq "Failed" } |
    Select-Object PartitionKey, RowKey, ErrorCode, ErrorMessage |
    Export-Csv -Path "migration-failures.csv" -NoTypeInformation
```

### Security Considerations

#### Sensitive Data

Audit rows contain:
- ✅ Source B2C `objectId` (PartitionKey)
- ✅ Operation timestamp (RowKey)
- ✅ Migration status
- ❌ Passwords (never logged)
- ❌ PII beyond objectId (display names, UPNs are not stored)

#### Access Control

Restrict access to the audit table using RBAC:
- **`Storage Table Data Reader`** — read-only audit review
- **`Storage Table Data Contributor`** — required by the migration process itself
- Use **Private Endpoints** and **encryption at rest** (Azure default) for production deployments

## Deployment Guide

### Infrastructure Deployment

1. **Deploy Azure Resources** *(example — Bicep templates not included in this repo; planned for v2.0)*
   ```bash
   # Example: Deploy via Bicep (when templates are available)
   az deployment group create \
     --resource-group rg-b2c-migration \
     --template-file infra/main.bicep
   ```

2. **Configure Private Endpoints** (planned for v2.0)
   - Storage Account
   - (Optional) Function App

3. **Set Up Managed Identity**
   ```bash
   # Enable system-assigned identity on Function
   az functionapp identity assign \
     --name func-b2c-migration \
     --resource-group rg-b2c-migration

   # Grant permissions
   az role assignment create \
     --assignee <managed-identity-id> \
     --role "Storage Queue Data Contributor" \
     --scope <storage-account-resource-id>

   az role assignment create \
     --assignee <managed-identity-id> \
     --role "Storage Table Data Contributor" \
     --scope <storage-account-resource-id>
   ```

### Function Deployment

```bash
cd src/B2CMigrationKit.Function

# Publish locally
dotnet publish -c Release

# Deploy to Azure
func azure functionapp publish func-b2c-migration

# Restart function (critical!)
az functionapp restart \
  --name func-b2c-migration \
  --resource-group rg-b2c-migration
```

**Important**: Always restart the Function App after deployment to load new binaries.

### Configuration Deployment

```bash
# Set application settings
az functionapp config appsettings set \
  --name func-b2c-migration \
  --resource-group rg-b2c-migration \
  --settings \
    "Migration__B2C__TenantId=your-tenant-id" \
    "Migration__ExternalId__TenantId=your-tenant-id"
```

## Operations & Monitoring

### Phone Registration Monitoring

**Phone Registration Progress (KQL)**
```kql
customMetrics
| where name in ("PhoneRegistration.Success", "PhoneRegistration.Failed")
| summarize Count = sum(value) by bin(timestamp, 5m), name
| render timechart
```

**Completion Summary**
```kql
traces
| where message contains "Phone registration completed"
| extend Success = toint(extract("Success: ([0-9]+)", 1, message))
| extend Failed = toint(extract("Failed: ([0-9]+)", 1, message))
| extend AlreadyRegistered = toint(extract("AlreadyRegistered: ([0-9]+)", 1, message))
| project timestamp, Success, Failed, AlreadyRegistered
| order by timestamp desc
```

**Throttle Health Check**
```kql
traces
| where message contains "phoneMethods" and (message contains "429" or message contains "throttle")
| summarize ThrottleHits = count() by bin(timestamp, 5m)
| render timechart
```

If you see sustained 429s, increase `PhoneRegistration.ThrottleDelayMs` in your config (e.g., from 1200 to 2000).

**Key Counters:**
| Metric | Description |
|---|---|
| `PhoneRegistration.Success` | Phones successfully registered (new) |
| `PhoneRegistration.Failed` | Messages that failed and will be retried |
| `PhoneRegistration.Completed` | Total messages processed (success + already-registered) |
| `GraphClient.PhoneMethodRegistered` | Raw Graph API 201-Created count |

> **409 Conflict** is treated as a silent success — the phone was already registered in a previous run. This makes the worker fully idempotent.

### Sample Log Queries

> The following KQL queries are sample reference patterns. This repository does not deploy any Application Insights resources, dashboards, or alert rules. To use these queries, configure Application Insights in your environment and set `Telemetry:UseApplicationInsights: true` with a valid connection string.

**Migration Progress**
```kql
let startTime = ago(24h);
traces
| where timestamp > startTime
| where message contains "RUN SUMMARY"
| extend Operation = extract("([A-Z][a-z]+ [A-Z][a-z]+)", 1, message)
| extend TotalItems = toint(extract("Total: ([0-9]+)", 1, message))
| extend SuccessCount = toint(extract("Success: ([0-9]+)", 1, message))
| extend FailureCount = toint(extract("Failed: ([0-9]+)", 1, message))
| project timestamp, Operation, TotalItems, SuccessCount, FailureCount
```

**JIT Migration Tracking**
```kql
customMetrics
| where name == "JIT.MigrationsCompleted"
| summarize MigrationsCompleted = sum(value) by bin(timestamp, 1h)
| render timechart
```

**Throttling Analysis**
```kql
traces
| where message contains "throttle" or message contains "429"
| summarize ThrottleCount = count() by bin(timestamp, 5m), severity = severityLevel
| render timechart
```

### Performance Tuning & Scaling Patterns

#### Graph API Throttling Fundamentals

Microsoft Graph API throttling works on **two dimensions**:

1. **Per App Registration (Client ID)** - ~60 operations/second per app
2. **Per IP Address** - Cumulative limit across all apps from that IP

This means:
- ✅ Single instance (1 IP) with 1 app = ~60 ops/sec
- ❌ Single instance (1 IP) with 3 apps ≠ 180 ops/sec (still limited by IP)
- ✅ 3 instances (3 different IPs) with 1 app each = ~180 ops/sec

**Key Principle**: Each instance (Console App or Azure Function) uses **1 app registration**. To scale, deploy **multiple instances** on **different IP addresses**.

#### Authentication Methods API — Throttle Behaviour

The `GET` and `POST/PATCH /users/{id}/authentication/phoneMethods` endpoints have a **significantly lower throttle budget** than the main Users API, and GET and POST/PATCH calls count together against the same per-app budget.

**Key implications for our architecture**:
- Each worker calls two different tenants: B2C (GET) and EEID (POST). Because they are different tenants, each call is counted against a different tenant's quota independently — they do not share a budget. Client-side throughput is governed by `ThrottleDelayMs`.
- If you observe sustained HTTP 429 responses, increase `ThrottleDelayMs`.

**Scaling phone registration**:
- Run multiple `phone-registration` workers, each with a **dedicated pair of app registrations** (1 B2C app + 1 EEID app)
- Each additional worker pair increases throughput proportionally (limited by the tenant-level budget shared across all app registrations)

#### Console App Scaling

| Scale | Setup | Throughput |
|---|---|---|
| Single instance | 1 process, 1 app registration, 1 IP | ~60 ops/sec |
| Multiple instances | N processes on N different IPs, each with a dedicated app registration | ~N × 60 ops/sec |

Run each instance with its own config file (e.g. `appsettings.worker1.json`, `appsettings.worker2.json`), each pointing to a dedicated app registration. Use `Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.workerN.json` for local runs or deploy to separate VMs/containers for production scale.

**Recommended thresholds:** single instance up to ~100K users; multiple instances for larger volumes or time-sensitive cutovers.

## Security Best Practices

### Secret Management

1. **Never commit secrets** to source control
2. **Use local configuration files** (gitignored) for development secrets
3. **Rotate secrets** regularly
4. **Use separate secrets** for dev/test/prod
5. **Future**: Secure secret management with Azure Key Vault will be included in v2.0

### Network Security

1. **Private endpoints only** for production (planned for v2.0)
2. **VNet integration** for Functions (planned for v2.0)
3. **NSG rules** to restrict traffic
4. **Disable public access** on Storage

### Authentication

1. **Prefer Managed Identity** over service principals
2. **Use certificate-based auth** if client secrets required
3. **Limit permissions** to minimum required
4. **Review audit logs** regularly

### Data Protection

1. **Encrypt data at rest** (enabled by default on Azure Storage)
2. **Use HTTPS only** for all communication
3. **Do not log passwords** or sensitive data
4. **Clean up export files** after migration

## Troubleshooting

### Common Errors

**Error: "Throttle limit exceeded (HTTP 429)"**
- Solution: Reduce batch size or add delay between batches

**Error: "User already exists"**
- Solution: Check for duplicate users, use `B2CObjectId` to correlate


### Debugging Tips

1. **Enable verbose logging** with `--verbose` flag
2. **Check Application Insights** for detailed error traces
3. **Test with small subset** before full migration
4. **Use breakpoints** in Visual Studio/VS Code for local debugging
5. **Review Graph API responses** in telemetry

### Support Resources

- Microsoft Graph API Documentation: https://docs.microsoft.com/graph
- Azure AD B2C Documentation: https://docs.microsoft.com/azure/active-directory-b2c
- Entra External ID Documentation: https://docs.microsoft.com/entra/external-id

---

For additional support, consult your Microsoft representative.
