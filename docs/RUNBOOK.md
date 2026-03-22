# Operations Runbook — Azure VM Bulk Migration

Step-by-step guide to deploy, configure, run, and monitor a bulk B2C-to-External-ID migration on Azure VMs.

---

## Prerequisites

Before you begin, ensure you have:

- [ ] **Azure subscription** with Contributor access
- [ ] **Azure CLI** installed and logged in (`az login`)
- [ ] **PowerShell 7+** installed
- [ ] **.NET 8.0 SDK** installed locally (for local testing)
- [ ] **App registrations** created per worker (B2C + External ID) — see [Developer Guide](DEVELOPER_GUIDE.md#configuration-guide)
- [ ] **SSH key pair** — generate if you don't have one:
  ```bash
  ssh-keygen -t ed25519 -f scripts/b2c-mig-deploy -C "b2c-migration"
  ```
- [ ] Code committed and pushed to a remote branch accessible by the VMs

---

## Step 1: Deploy Infrastructure + VMs

From the repo root:

```powershell
.\scripts\Deploy-All.ps1 `
    -ResourceGroup rg-b2c-eeid-mig-test1 `
    -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub
```

This will:
1. Deploy Azure infrastructure via Bicep (VNet, Storage, VMs, Bastion, Key Vault, NAT Gateway)
2. Provision each VM: install .NET SDK + git, clone your repo, build the app, copy example config

**To re-provision VMs without redeploying infra** (e.g., after a code change):

```powershell
# Commit and push your changes first!
git add -A && git commit -m "update" && git push origin <branch>

.\scripts\Deploy-All.ps1 `
    -ResourceGroup rg-b2c-eeid-mig-test1 `
    -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub `
    -SkipInfra
```

**Expected output:**
```
Step 2: Provision VMs
Provisioning vm-b2c-worker1 ...
  vm-b2c-worker1 provisioned.
Provisioning vm-b2c-worker2 ...
  vm-b2c-worker2 provisioned.
...
VMs Provisioned:   4 / 4
```

---

## Step 2: Connect to a VM

You need **two terminals**: one for the Bastion tunnel, one for SSH.

### Terminal 1 — Open Bastion tunnel

```powershell
cd scripts
.\Connect-Worker.ps1 -WorkerIndex 1
```

Wait until you see: `Tunnel is ready, connect on port 2201`

### Terminal 2 — SSH through the tunnel

```powershell
ssh -p 2201 -i .\scripts\b2c-mig-deploy azureuser@localhost
```

Accept the host key fingerprint, enter the passphrase if your key has one.

> **Tip:** To connect to other workers, use `-WorkerIndex 2` (port 2202), `-WorkerIndex 3` (port 2203), etc.

---

## Step 3: Configure Each Worker

On each VM, run the interactive configuration script — it asks for each value one by one and generates the appsettings.json automatically:

```bash
bash ~/b2c-to-meeid-migration-tool/scripts/Configure-Worker.sh
```

The script will:
1. Ask whether this VM is a **master** (harvest only) or **worker** (migrate + phone-registration)
2. Prompt for B2C tenant ID, domain, client ID, client secret
3. Prompt for External ID tenant ID, domain, client ID, client secret, extension app ID
4. Prompt for the storage account name (just the name — it builds the URI automatically)
5. Write `/opt/b2c-migration/app/appsettings.json` with permissions `600`
6. Run `validate` to verify all connections work

You can also pass `--role worker` or `--role master` to skip the role prompt:

```bash
bash ~/b2c-to-meeid-migration-tool/scripts/Configure-Worker.sh --role worker --worker-id 2
```

> **Manual editing:** If you prefer to edit manually, run `nano /opt/b2c-migration/app/appsettings.json` instead. See `appsettings.worker1.example.json` for the full structure.

Key values to fill in:

| Section | Setting | Value |
|---------|---------|-------|
| `Migration.B2C` | `TenantId`, `TenantDomain` | Your B2C tenant |
| `Migration.B2C.AppRegistration` | `ClientId`, `ClientSecret` | B2C app reg for this worker |
| `Migration.ExternalId` | `TenantId`, `TenantDomain`, `ExtensionAppId` | Your External ID tenant |
| `Migration.ExternalId.AppRegistration` | `ClientId`, `ClientSecret` | EEID app reg for this worker |
| `Migration.Storage` | `ConnectionStringOrUri` | `https://<STORAGE_ACCOUNT>.blob.core.windows.net` |
| `Migration.Storage` | `UseManagedIdentity` | `true` (VMs have RBAC on the storage account) |

**Storage config example** — the VMs already have managed identity with Blob/Queue/Table Contributor roles:

```json
"Storage": {
  "ConnectionStringOrUri": "https://strgb2ceeidmigtewkpji0.blob.core.windows.net",
  "UseManagedIdentity": true,
  "AuditTableName": "migrationAudit",
  "AuditMode": "Table"
}
```

> Replace `strgb2ceeidmigtewkpji0` with your actual storage account name (check the Deploy-All output or run `az storage account list -g <RG> --query "[].name" -o tsv`).

**Important**: Each worker VM must have a **dedicated app registration** with its own client ID/secret for independent Graph API throttle quotas.

Save with `Ctrl+O`, exit with `Ctrl+X`.

Repeat for each worker VM (connect via different `WorkerIndex`).

---

## Step 4: Validate Readiness

### Option A: From the VM (recommended)

SSH into any worker VM and run:

```bash
cd ~/b2c-to-meeid-migration-tool/src/B2CMigrationKit.Console
dotnet run -- validate --config appsettings.json
```

This checks connectivity to B2C Graph API, Entra External ID Graph API, Azure Queue Storage, and Azure Blob Storage. All four checks must pass (✓) before starting migration.

### Option B: From your local machine

```powershell
.\scripts\Validate-MigrationReadiness.ps1 -ConfigFile src\B2CMigrationKit.Console\appsettings.worker1.json -Mode worker
```

This checks: Graph API connectivity, permissions, extension attributes, storage reachability, queue/table existence.

---

## Step 5: Run Migration

### 5a. Harvest (ONE worker only)

SSH into **worker 1** and run:

```bash
cd /opt/b2c-migration/app
./B2CMigrationKit.Console harvest --config appsettings.json
```

This pages all B2C user IDs and enqueues them to the migration queue. Wait for it to complete before starting workers.

### 5b. Worker Migrate (ALL workers in parallel)

SSH into **each worker** and run:

```bash
cd /opt/b2c-migration/app
./B2CMigrationKit.Console worker-migrate --config appsettings.json
```

Workers dequeue ID batches, fetch full profiles from B2C, and create users in External ID. Each worker auto-exits when the queue is empty.

> **Tip:** Use `nohup` to keep the process running if you disconnect:
> ```bash
> nohup ./B2CMigrationKit.Console worker-migrate --config appsettings.json > migrate.log 2>&1 &
> ```

### 5c. Phone Registration (ALL workers, after worker-migrate completes)

```bash
cd /opt/b2c-migration/app
./B2CMigrationKit.Console phone-registration --config appsettings.json
```

Reads MFA phone numbers from B2C and registers them in External ID. Throttled to avoid 429s.

---

## Step 6: Monitor Progress

From your local machine:

```powershell
.\scripts\Watch-Migration.ps1 -WorkerCount 4 -RefreshSeconds 3
```

Shows live counters: users migrated, phones registered, errors, throttles. Press `Ctrl+C` for a final summary.

You can also check the audit table directly:

```bash
az storage entity query --table-name migrationAudit \
    --account-name <storage-account> --auth-mode login \
    --filter "Status eq 'Failed'" --output table
```

---

## Step 7: Analyze Results

After migration completes:

```powershell
.\scripts\Analyze-Telemetry.ps1 -WorkerCount 4
```

Upload telemetry to blob storage for archival:

```powershell
.\scripts\Upload-Telemetry.ps1
```

---

## Step 8: Teardown

### Stop VMs (keeps disks, $0 compute cost)

```bash
for i in 1 2 3 4; do
  az vm deallocate -g rg-b2c-eeid-mig-test1 -n vm-b2c-worker$i --no-wait
done
```

### Delete Bastion (saves ~$140/month)

```bash
az network bastion delete -g rg-b2c-eeid-mig-test1 -n bastion-b2c-migration
```

### Full cleanup (deletes everything)

```bash
az group delete -n rg-b2c-eeid-mig-test1 --yes --no-wait
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `Permission denied (publickey)` on SSH | Missing `-i` flag with private key | Use `ssh -p 220N -i ./scripts/b2c-mig-deploy azureuser@localhost` |
| Bastion extension not installed | First time using `az network bastion` | Script auto-installs it; or run `az extension add --name bastion --yes` |
| `run-command` fails or times out | Azure policy blocks RunCommand | Connect via Bastion manually and run `bash /opt/b2c-migration/repo/scripts/Setup-Worker.sh` |
| App not found in `/opt/b2c-migration/app/` | Provisioning failed silently | Re-run `Deploy-All.ps1 -SkipInfra` or manually: clone repo, `dotnet publish` |
| `403 Insufficient privileges` on Graph | App registration missing permissions | Grant `User.ReadWrite.All` (EEID) / `User.Read.All` (B2C), admin consent |
| HTTP 429 (throttle) | Too many concurrent requests | Reduce `MaxConcurrency`, increase `ThrottleDelayMs`, or add workers with separate app regs |
| VM can't reach storage | Private endpoint DNS not resolving | SSH into VM, run `nslookup <account>.queue.core.windows.net` — should resolve to private IP |
| `QueueNotFound` / `TableNotFound` | Storage containers not created | Run the app once with `harvest` — it auto-creates queues/tables |

---

## Quick Reference

| Action | Command |
|--------|---------|
| Deploy everything | `.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub` |
| Re-provision VMs | `.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub -SkipInfra` |
| Open Bastion tunnel | `.\scripts\Connect-Worker.ps1 -WorkerIndex <N>` |
| SSH to worker | `ssh -p 220<N> -i .\scripts\b2c-mig-deploy azureuser@localhost` |
| Edit config on VM | `nano /opt/b2c-migration/app/appsettings.json` |
| Run harvest | `./B2CMigrationKit.Console harvest --config appsettings.json` |
| Run worker-migrate | `./B2CMigrationKit.Console worker-migrate --config appsettings.json` |
| Run phone-registration | `./B2CMigrationKit.Console phone-registration --config appsettings.json` |
| Monitor progress | `.\scripts\Watch-Migration.ps1 -WorkerCount 4` |
| Analyze results | `.\scripts\Analyze-Telemetry.ps1 -WorkerCount 4` |
| Stop VMs | `az vm deallocate -g rg-b2c-eeid-mig-test1 -n vm-b2c-worker<N> --no-wait` |
| Full cleanup | `az group delete -n rg-b2c-eeid-mig-test1 --yes --no-wait` |
