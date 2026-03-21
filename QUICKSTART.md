# Quick Start — Local Dev with Azurite

Get running in ~5 minutes using Simple Mode (Export/Import) with test users.

## Prerequisites

| Tool | Install |
|------|---------|
| .NET 8 SDK | [dotnet.microsoft.com/download](https://dotnet.microsoft.com/download) |
| PowerShell 7+ | [github.com/PowerShell/PowerShell](https://github.com/PowerShell/PowerShell#get-powershell) |
| Azurite (VS Code) | Install extension `ms-azuretools.vscode-azurite`, then **Azurite: Start** from command palette |
| Azure AD B2C tenant | Source tenant with users to migrate |
| Entra External ID tenant | Target tenant (can be a dev/trial tenant) |

## 1. Clone & Build

```bash
git clone https://github.com/alvesfabi/b2c-to-meeid-migration-tool.git
cd b2c-to-meeid-migration-tool
dotnet build
```

## 2. Run the Setup Wizard (Recommended)

The interactive wizard handles app registration, config generation, and deployment in one step:

```powershell
./scripts/Setup-Migration.ps1
```

It will prompt you for tenant IDs, create app registrations via device code auth, generate all config files, and print the exact commands to run. **Skip to step 6** after the wizard completes.

> If you prefer manual setup, continue with steps 3–5 below.

## 3. Register App Registrations (Manual Alternative)

You need **two** app registrations (one per tenant):

**B2C tenant app:**
- API permissions: `User.Read.All` (Application) → Grant admin consent

**External ID tenant app:**
- API permissions: `User.ReadWrite.All`, `Directory.ReadWrite.All` (Application) → Grant admin consent
- Note the **extension app ID** (Entra admin center → App registrations → `b2c-extensions-app` or equivalent)

## 4. Configure (Manual Alternative)

```bash
cp src/B2CMigrationKit.Console/appsettings.export-import.example.json \
   src/B2CMigrationKit.Console/appsettings.json
```

Edit `appsettings.json` — fill in:

| Field | Value |
|-------|-------|
| `B2C.TenantId` | Your B2C tenant ID |
| `B2C.AppRegistration.ClientId` / `ClientSecret` | B2C app credentials |
| `ExternalId.TenantId` | Your External ID tenant ID |
| `ExternalId.ExtensionAppId` | Extension app ID (no hyphens) |
| `ExternalId.AppRegistration.ClientId` / `ClientSecret` | External ID app credentials |

Storage defaults to `UseDevelopmentStorage=true` (Azurite) — no changes needed.

## 5. Create Test Users (Optional)

Seed 20 test users in your B2C tenant:

```powershell
./scripts/New-TestUser.ps1 -ConfigFile src/B2CMigrationKit.Console/appsettings.json -Count 20
```

## 6. Validate Setup

```powershell
./scripts/Validate-MigrationReadiness.ps1 -ConfigFile src/B2CMigrationKit.Console/appsettings.json
```

All checks should show ✅. Fix any ❌ before proceeding.

## 7. Run Migration

```bash
# Start Azurite in VS Code (if not already running)

# Export users from B2C → Blob Storage
dotnet run --project src/B2CMigrationKit.Console -- export --config src/B2CMigrationKit.Console/appsettings.json

# Import users from Blob Storage → External ID
dotnet run --project src/B2CMigrationKit.Console -- import --config src/B2CMigrationKit.Console/appsettings.json
```

## 8. Verify

Check the Entra External ID admin center — your migrated users should appear with:
- `requiresMigration` extension attribute set to `true`
- Original B2C object ID stored in extension attributes

## What's Next?

- **JIT Password Migration** — Deploy the Azure Function (`src/B2CMigrationKit.Function`) to handle password migration on first login. See [Architecture Guide](docs/ARCHITECTURE_GUIDE.md).
- **Large-scale migration** — Use Advanced Mode (queue-based workers) for tenants with >1M users or MFA phone migration. See [Developer Guide](docs/DEVELOPER_GUIDE.md).
- **Azure VM deployment** — For production worker deployments, see the [Infrastructure Runbook](infra/README.md).
