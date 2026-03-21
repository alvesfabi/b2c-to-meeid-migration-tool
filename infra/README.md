# Infrastructure Runbook

## Prerequisites

- Azure subscription with Contributor access
- GitHub repo secrets configured (see below)
- SSH key pair: `ssh-keygen -t ed25519 -C "b2c-migration"`
- Azure CLI (`az`) installed locally for Bastion tunnel

## 1. Configure GitHub Secrets

In **Settings → Secrets → Actions**, add:

| Secret | Value |
|--------|-------|
| `AZURE_CLIENT_ID` | Service Principal app ID |
| `AZURE_TENANT_ID` | Azure AD tenant ID |
| `AZURE_SUBSCRIPTION_ID` | Target subscription |
| `VM_SSH_PUBLIC_KEY` | Contents of `~/.ssh/id_ed25519.pub` |
| `STORAGE_ACCOUNT_NAME` | Globally unique name (e.g. `stb2cmig<suffix>`) |

### OIDC Setup (recommended over client secret)

```bash
# Create SP
az ad sp create-for-rbac --name sp-github-b2c-migration \
  --role Contributor --scopes /subscriptions/<SUB_ID>

# Add federated credential
az ad app federated-credential create --id <APP_ID> --parameters '{
  "name": "github-deploy",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:<owner>/<repo>:ref:refs/heads/infra/azure-vm-deploy",
  "audiences": ["api://AzureADTokenExchange"]
}'
```

## 2. Deploy Infrastructure

Run the **Deploy Infrastructure** workflow (`workflow_dispatch`). Choose region, VM size, and whether to deploy Bastion.

Creates: Resource Group, VNet, 4 VMs, Storage (Queue/Blob/Table + Private Endpoints), Key Vault, NAT Gateway, Bastion (optional).

## 3. Upload Worker Configs to Key Vault

Each VM needs its own `appsettings.json` with its app registration credentials. Store them as Key Vault secrets:

```bash
KV_NAME=$(az keyvault list -g rg-b2c-migration --query "[0].name" -o tsv)

az keyvault secret set --vault-name $KV_NAME \
  --name appsettings-worker1 --file appsettings.worker1.json
az keyvault secret set --vault-name $KV_NAME \
  --name appsettings-worker2 --file appsettings.worker2.json
az keyvault secret set --vault-name $KV_NAME \
  --name appsettings-worker3 --file appsettings.worker3.json
az keyvault secret set --vault-name $KV_NAME \
  --name appsettings-worker4 --file appsettings.worker4.json
```

## 4. Build & Deploy App

Run the **Build & Deploy Migration App** workflow. It builds the .NET console app, uploads to blob storage, and attempts to provision each VM via `az vm run-command`.

If `run-command` is blocked by policy, deploy manually per VM via Bastion (step 5).

## 5. Connect via Bastion

```powershell
# Terminal 1: open tunnel to worker 1 (port 2201)
./scripts/Connect-Worker.ps1 -WorkerIndex 1

# Terminal 2: SSH through tunnel
ssh -p 2201 azureuser@localhost
```

If the app wasn't deployed automatically, run the setup script on the VM:

```bash
bash /dev/stdin stb2cmig123 kv-b2c-mig-xxx appsettings-worker1 < <(curl -sL https://raw.githubusercontent.com/<owner>/<repo>/infra/azure-vm-deploy/scripts/Setup-Worker.sh)
# Or copy Setup-Worker.sh via scp and run locally
```

## 6. Run Migration

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

## 7. Monitor

Use `Watch-Migration.ps1` locally (via Bastion tunnel) or on a worker VM:

```powershell
# From your local machine (with telemetry files copied/synced)
.\scripts\Watch-Migration.ps1 -WorkerCount 4 -RefreshSeconds 3

# On the VM directly
cd /opt/b2c-migration/app
pwsh -File ../scripts/Watch-Migration.ps1
```

Shows live counters: users migrated, phones registered, errors, throttles. Press `Ctrl+C` for a final summary.

## 8. Analyze Results

After migration completes, generate a full report:

```powershell
# Aggregate all workers
.\scripts\Analyze-Telemetry.ps1 -WorkerCount 4

# Single worker file
.\scripts\Analyze-Telemetry.ps1 -TelemetryFile worker2-telemetry.jsonl
```

Upload telemetry to blob storage for archival:

```powershell
.\scripts\Upload-Telemetry.ps1
```

## 9. Validate Before Running

Run the pre-flight checker before starting migration:

```powershell
# Simple mode (export/import)
.\scripts\Validate-MigrationReadiness.ps1

# Worker mode (queue-based)
.\scripts\Validate-MigrationReadiness.ps1 -ConfigFile appsettings.worker1.json -Mode worker
```

Checks: Graph API connectivity, permissions, extension attributes, storage reachability, queue/table/blob existence.

## 10. Teardown

Deallocate VMs and stop Bastion to stop billing:

```bash
# Stop VMs (keeps disks, $0 compute)
for i in 1 2 3 4; do
  az vm deallocate -g rg-b2c-migration -n vm-b2c-worker$i --no-wait
done

# Stop Bastion
az network bastion delete -g rg-b2c-migration -n bastion-b2c-migration

# Full cleanup (deletes everything)
az group delete -n rg-b2c-migration --yes --no-wait
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
