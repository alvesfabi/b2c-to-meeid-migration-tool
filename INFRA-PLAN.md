# Infrastructure Plan: Azure VM Deploy

**Branch:** `infra/azure-vm-deploy`
**Goal:** GitHub Action to deploy 5 VMs (1 master + 2 user-workers + 2 phone-workers) in a VNet with private endpoints to Storage, so migration runs in Azure (not locally).

## Current State

✅ Bicep modules exist: `infra/main.bicep` + `network.bicep` + `storage.bicep` + `vm.bicep`
✅ VNet with workers subnet + private-endpoints subnet
✅ NAT Gateway for outbound internet (Graph API calls)
✅ Storage Account with private endpoint (queue only) + DNS zone
✅ 4 Ubuntu VMs with cloud-init (.NET 8 runtime), SSH auth, Managed Identity
✅ Role assignment: each VM gets Storage Queue Data Contributor on storage account

## What's Missing

### Task 1: GitHub Action for Bicep Deploy
- `.github/workflows/deploy-infra.yml`
- Trigger: `workflow_dispatch` (manual) with inputs for subscription, storage suffix, SSH key
- Uses `azure/login@v2` with OIDC (federated credential) or service principal
- Steps: `az deployment sub create --location eastus --template-file infra/main.bicep --parameters ...`
- Output: resource group name, storage account name, VM IPs

### Task 2: Add Table Storage Private Endpoint
- Current storage.bicep only has queue PE — Advanced Mode also needs Table Storage
- Add `table` group ID to private endpoint (or second PE)
- Add `privatelink.table.core.windows.net` DNS zone + VNet link

### Task 3: Add Blob Storage Private Endpoint
- Simple Mode uses Blob Storage for export/import
- Add `blob` group ID PE + `privatelink.blob.core.windows.net` DNS zone

### Task 4: VM Provisioning Script (cloud-init improvements)
- Current cloud-init only installs .NET 8 runtime
- Need to also: clone repo, build the console app, install PowerShell 7
- Or: use a deploy script that copies the published app via SCP/Bastion
- Decision: **Use GitHub Action to build + publish artifact, then deploy to VMs via custom script extension**

### Task 5: Azure Bastion for VM Access
- VMs have no public IP (by design) — need Bastion to SSH in
- Add `AzureBastionSubnet` to VNet + Bastion host resource
- Or: use custom script extensions only (no interactive SSH needed)
- Decision: **Add Bastion (Standard SKU) — useful for debugging, can be stopped when not needed**

### Task 6: GitHub Action for App Deploy to VMs
- Second workflow or job: build .NET app → publish artifact → use custom script extension to pull and run on each VM
- Each VM gets its own `appsettings.workerN.json` (from Key Vault or GitHub secrets)
- Alternative: use `az vm run-command` to execute setup scripts

### Task 7: Role Assignments for Graph API Access
- VMs need to call Microsoft Graph (B2C + EEID tenants)
- This requires **App Registrations** (not Managed Identity — Graph doesn't support MI for multi-tenant)
- Config files with client credentials need to be securely delivered to VMs
- Plan: store secrets in Key Vault, VMs access via Managed Identity → Key Vault access policy

### Task 8: Key Vault Integration
- Add Key Vault resource to Bicep
- Store: app registration secrets, connection strings
- VMs access via Managed Identity (Key Vault Secrets User role)
- GitHub Action retrieves secrets for initial deploy

### Task 9: Documentation Updates
- Update ARCHITECTURE_GUIDE.md § Deployment & Operations with Azure VM deploy instructions
- Update DEVELOPER_GUIDE.md with GitHub Action usage
- Add `infra/README.md` with deployment runbook

### Task 10: Orchestration Script
- Master script that runs on VM-1 as "coordinator":
  - `harvest` to populate queue
  - Signal workers to start `worker-migrate`
  - After workers finish, run `phone-registration`
- Or: each VM runs independently, pulling from queue (already the design — workers are autonomous)

## Execution Order

```
T1 (GitHub Action deploy)  ──┐
T2 (Table PE)              ──┤
T3 (Blob PE)               ──┼── Can be parallel (all Bicep changes)
T5 (Bastion)               ──┤
T8 (Key Vault)             ──┘
T4 (cloud-init / build)   ── After T1-T8 merged
T7 (Graph API creds)       ── After T8
T6 (App deploy action)    ── After T4, T7
T9 (Docs)                 ── Throughout
T10 (Orchestration)        ── Last
```

## Estimated Cost (running)
- 4x Standard_B2s: ~$4/day ($1/day each)
- Bastion Standard: ~$5/day (stop when not needed)
- Storage: negligible
- NAT Gateway: ~$1/day
- **Total: ~$10/day while running, $0 if VMs deallocated + Bastion stopped**

## Az CLI Access
For Claudito to deploy directly:
- Option A: Service Principal with Contributor on subscription/RG → `az login --service-principal`
- Option B: `az login --use-device-code` in a tmux session Claudito can use
- Recommendation: Create SP scoped to `rg-b2c-migration` resource group
