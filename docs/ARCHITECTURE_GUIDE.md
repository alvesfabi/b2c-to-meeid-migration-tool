# B2C Migration Kit - Architecture Guide

**Audience**: Solutions Architects, Technical Leads, Security Reviewers

---

## Table of Contents

1. [Executive Summary](#1-executive-summary) — Migration modes overview & decision table
2. [System Overview](#2-system-overview) — Architecture diagrams, Simple Mode & Advanced Mode data flows
3. [Design Principles](#3-design-principles)
4. [Component Architecture](#4-component-architecture)
5. [Bulk Migration Pipeline](#5-bulk-migration-pipeline) — Simple Mode (Export/Import) + Advanced Mode (Workers)
6. [Just-In-Time (JIT) Migration](#6-just-in-time-jit-migration)
7. [Security Architecture](#7-security-architecture)
8. [Scalability & Performance](#8-scalability--performance)
9. [Deployment & Operations](#9-deployment--operations)

---

## 1. Executive Summary

The **B2C Migration Kit** migrates user identities from **Azure AD B2C** to **Microsoft Entra External ID**.

The kit has two independent concerns:

1. **Bulk user migration** — export/import user profiles from B2C to External ID, with two modes:
   - **Simple Mode — Export/Import**: Simple blob-based pipeline (`export` → Blob Storage → `import`). Best for small tenants, no MFA phone migration needed.
   - **Advanced Mode — Workers**: Queue-based parallel pipeline (`harvest` → `worker-migrate` → `phone-registration`). Best for large tenants, full MFA phone migration, parallel scaling.
2. **JIT Password Migration** — Seamless password validation on first login via Custom Authentication Extension. Works independently of which bulk mode you choose — it runs as an Azure Function triggered on each user's first login after bulk migration.

### Choose Your Bulk Migration Mode

| Factor | Simple Mode (Export/Import) | Advanced Mode (Workers) |
|--------|----------------------|-------------------|
| **Best for** | Small/medium tenants < 1 million users, no MFA phones | Large tenants, MFA phone migration |
| **Infrastructure** | Blob Storage only | Queue + Table Storage |
| **Parallelism** | Single-threaded | N worker pairs, configurable concurrency |
| **MFA phones** | ❌ Not implemented | ✅ Full phone method migration |
| **Commands** | `export` → `import` (2 steps) | `harvest` → `worker-migrate` → `phone-registration` (3 steps) |
| **Complexity** | Low | Medium |

---

## 2. System Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Subscription                           │
│                                                                 │
│  ┌──────────────────────────┐  ┌──────────────┐               │
│  │ Console App              │  │Azure Function│               │
│  │  Simple Mode: Export/Import   │  │(JIT Auth)    │               │
│  │  Advanced Mode: Harvest/Worker/ │  │              │               │
│  │          PhoneReg        │  │              │               │
│  └──────┬───────────────────┘  └──────┬───────┘               │
│         │                             │                        │
│  ┌──────▼─────────────────────────────▼───────────────┐       │
│  │                 Shared Core Library                 │       │
│  │   (Services, Models, Orchestrators, Abstractions)   │       │
│  └──────┬───────────┬───────────┬──────────┬──────────┘       │
│         ▼           ▼           ▼          ▼                   │
│  ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌──────────┐          │
│  │ Storage  │ │ Table   │ │Key Vault │ │App       │          │
│  │Queue/Blob│ │ Storage │ │ *Future  │ │ Insights │          │
│  └──────────┘ └─────────┘ └──────────┘ └──────────┘          │
└─────────────────────────────────────────────────────────────────┘
         │                           │
         ▼                           ▼
┌─────────────────┐         ┌─────────────────┐
│ Azure AD B2C    │         │ External ID     │
│ (Source Tenant) │         │ (Target Tenant) │
└─────────────────┘         └─────────────────┘
```

### Data Flow

The kit supports two migration pipelines. Choose based on your scenario (see [Choose Your Migration Mode](#choose-your-migration-mode)).

---

### Simple Mode — Export/Import Pipeline

A simple two-step blob-based pipeline for straightforward migrations without MFA phone migration.

#### Step 1 — `export` (run once)

```
B2C Tenant → GET /users?$select={fields}&$top={pageSize}
  └─ ExportOrchestrator
     └─► Blob Storage: b2c-export/{blobPrefix}page-{N}.json
```

Pages all B2C users with configurable `$select` fields, writes each page as a JSON blob. Supports optional client-side filtering by `displayName`/`userPrincipalName` pattern. Exits when all pages are processed.

- **Config**: `Export.SelectFields`, `Export.FilterPattern` (optional), `Storage.ExportContainerName`, `Storage.ExportBlobPrefix`
- **Permissions**: B2C `User.Read.All` (Application)

#### Step 2 — `import` (run once)

```
Blob Storage: b2c-export/*.json
  └─ ImportOrchestrator
     ├─ Read user JSON from each blob
     ├─ Transform: UPN domain rewrite, extension attrs, email identity, random password
     ├─ POST /users → EEID
     │   ├─ 201 Created  → audit(Created)
     │   ├─ 409 Conflict → audit(Duplicate)
     │   └─ Other error  → audit(Failed)
     └─► Blob Storage: b2c-import-audit/import-audit-{blob}.json
```

Reads exported blobs sequentially, transforms each user profile, creates in EEID. Audit results written as JSON blobs. Single-threaded — no queue coordination needed.

- **Config**: `Import.ExtensionAttributes`, `Storage.ImportAuditContainerName`
- **Permissions**: B2C `User.Read.All` (for export), EEID `User.ReadWrite.All` (Application)

> **Limitations**: No MFA phone migration, no parallel scaling, no Table Storage audit trail. For large tenants or MFA scenarios, use Advanced Mode.

---

### Advanced Mode — Worker Pipeline

A queue-based parallel pipeline for large-scale migrations with full MFA phone support.

#### Step 1 — `harvest` (run once)

```
B2C Tenant → GET /users?$select=id&$top=999
  └─ HarvestOrchestrator
     └─► Queue: user-ids-to-process  (JSON arrays of 20 IDs per message)
```

Pages B2C with `$select=id` (cheapest Graph query), splits into batches of 20, enqueues each. Exits when all pages are processed.

#### Step 2a — `worker-migrate` (run N parallel instances)

```
Queue: user-ids-to-process
└─ WorkerMigrateOrchestrator (independent app registration per instance)
   ├─ GET /$batch → B2C (up to 20 full profiles per batch)
   ├─ Transform: UPN domain rewrite, extension attrs, email identity, random password
   ├─ POST /users → EEID
   │   ├─ 201 Created  → audit(Created)   + enqueue phone task
   │   ├─ 409 Conflict → audit(Duplicate) + enqueue phone task
   │   └─ Other error  → audit(Failed, errorCode, errorMessage)
   ├─► Table Storage: migration-audit
   └─► Queue: phone-registration  ({ B2CUserId, EEIDUpn } — no phone number stored)
```

#### Step 2b — `phone-registration` (run M parallel instances)

```
Queue: phone-registration
└─ PhoneRegistrationWorker (independent app registrations for B2C and EEID)
   ├─ GET /users/{B2CUserId}/authentication/phoneMethods → B2C
   ├─ If phone found: POST to EEID → audit(PhoneRegistered)
   ├─ If no phone: audit(PhoneSkipped)
   └─ 409 Conflict → treated as success (idempotent)
```

Phone numbers are fetched at drain time — never stored in the queue (PII protection).

> **Throttle note**: `phoneMethods` API is throttled at **30 requests / 10 seconds per app registration** (~3 RPS). Default `ThrottleDelayMs` is **400 ms**. Scale by adding workers with dedicated app registration pairs.

#### Step 3 — JIT Migration (first login, Azure Function)

```
User Login → EEID checks RequiresMigration = true
  └─ Custom Authentication Extension → Azure Function
     ├─ Decrypt password (RSA private key)
     ├─ Reverse UPN transform → B2C UPN
     ├─ POST /oauth2/v2.0/token (ROPC) → B2C
     │   ├─ Valid   → MigratePassword → EEID sets password + RequiresMigration=false
     │   └─ Invalid → BlockSignIn
     └─ Subsequent logins: direct EEID auth (no JIT call)
```

---

## 2.1 End-to-End Pipeline Narrative

This section walks through both migration pipelines from start to finish, explaining **why** each stage exists and how they connect.

### Simple Mode — Export/Import Narrative

Simple Mode is a straightforward two-step pipeline:

1. **Export** pages all B2C users and writes full profiles to Blob Storage as JSON files. Each page becomes one blob (~999 users). Optional client-side filtering (`FilterPattern`) limits export to matching users.
2. **Import** reads each blob sequentially, transforms user profiles (UPN rewrite, extension attribute mapping, email identity, random password with `RequiresMigration` flag), and creates each user in EEID via `POST /users`. Results are written to audit blobs.

**Why blobs?** For small tenants, the overhead of queues and Table Storage is unnecessary. Blobs provide a simple checkpoint — if import fails mid-blob, re-run skips duplicates (409 = idempotent). Export blobs also serve as a backup of the source data.

### Advanced Mode — Worker Pipeline Narrative

### Stage 1 — Harvest (single instance, run once)

The harvest step pages all B2C users using the cheapest possible Graph query (`$select=id`, page size 999). It splits the collected IDs into batches of 20 and enqueues each batch as a single message to the `user-ids-to-process` queue. The harvest process exits when all pages have been processed.

**Why batch of 20?** Graph `$batch` requests support up to 20 individual requests per call, so each queue message maps directly to one `$batch` call downstream.

### Stage 2 — Worker-Migrate (N parallel instances)

Each worker-migrate instance dequeues a batch message, fetches full user profiles from B2C via a single `POST /$batch` request (up to 20 profiles), transforms each profile to the External ID schema (UPN domain rewrite, extension attributes, email identity, random password), and creates the user in EEID via `POST /users`.

After creating (or detecting a duplicate of) each user, the worker **enqueues a phone-registration message** containing `{ B2CUserId, EEIDUpn }` — no phone number, just references. Phone registration is a separate stage because:

1. **Dependency**: The EEID user must exist before a phone method can be registered on it.
2. **Rate limit isolation**: The `phoneMethods` API has its own throttle budget. Running phone registration inline would bottleneck the entire pipeline.

### Stage 3 — Phone-Registration Worker (N parallel instances)

Each phone-registration worker reads from the queue populated by **its paired worker-migrate instance**. For each message it fetches the phone number from B2C (`GET /authentication/phoneMethods`) and registers it in EEID (`POST /authentication/phoneMethods`). Phone numbers are fetched at drain time — never stored in the queue (PII protection).

The worker runs with `ThrottleDelayMs` (default 400 ms) to stay under the `phoneMethods` rate limit. It treats 409 Conflict as success (idempotent).

### Stage 4 — Telemetry & Audit

All workers emit structured JSONL telemetry to local files (`worker{N}-telemetry.jsonl`, `phone-registration{N}-telemetry.jsonl`) and write audit records to Azure Table Storage (`migration-audit`). This enables post-run analysis via `Analyze-Telemetry.ps1` and full traceability of every user processed.

### Stage 5 — Scaling

Throughput scales along two axes:

1. **More worker pairs** — each pair consists of one worker-migrate instance + one phone-registration instance, with **dedicated app registration pairs** (B2C + EEID) and **per-pair queues** for phone registration (e.g., `phone-reg-w1`, `phone-reg-w2`). This multiplies the API throttle budget linearly.
2. **More concurrency within a worker** — increase `MaxConcurrency` (default 1, sweet spot 8). Beyond ~8 threads per app registration, latency spikes without throughput gains.

### Per-Worker Queue Pairing

> **Note**: Per-pair queues are a **configuration pattern**, not an automatic feature. By default, all workers share a single `phone-registration` queue (suitable for single-instance or smoke-test runs). For multi-instance production deployments, configure each worker pair with a distinct `PhoneRegistration.QueueName` (e.g., `phone-reg-w1`, `phone-reg-w2`) to achieve throttle isolation.

Each worker-migrate instance communicates with its dedicated phone-registration worker through a **per-pair queue**, not a shared queue:

```
Worker 1  (App Reg B2C-1 / EEID-1)  ──► queue: phone-reg-w1  ──► Phone Worker 1
Worker 2  (App Reg B2C-2 / EEID-2)  ──► queue: phone-reg-w2  ──► Phone Worker 2
Worker 3  (App Reg B2C-3 / EEID-3)  ──► queue: phone-reg-w3  ──► Phone Worker 3
Worker N  (App Reg B2C-N / EEID-N)  ──► queue: phone-reg-wN  ──► Phone Worker N
```

**Why per-pair queues?**

- **Throttle isolation**: Each phone-registration worker uses its own app registration.
- **Clean telemetry**: Per-worker JSONL files stay isolated, making analysis straightforward.
- **No cross-contamination**: If a worker restarts, only its own queue has stale messages.

> **⚠️ Stale messages**: If you re-run a migration without clearing per-worker queues, the phone-registration workers will process leftover messages from the prior run. This causes >100% coverage in telemetry analysis. Clear queues before re-running: `az storage queue clear --name phone-reg-w1 --connection-string "UseDevelopmentStorage=true"`.

---

## 3. Design Principles

> **🚧 Note**: Principles describe the **target production architecture**. v1.0 implements core migration for local development. SFI features (Private Endpoints, VNet, Key Vault) are design guidance for future releases.

| Principle | Details |
|-----------|---------|
| **Modular Architecture** | Shared Core Library (business logic) + Console (CLI) + Azure Functions (JIT). Zero hosting-specific dependencies in Core. |
| **Security First** | Target: Private Endpoints, Managed Identity, Key Vault. Current v1.0: client secrets for local dev. Encryption at rest + in transit (TLS 1.2+). Least privilege permissions. |
| **Observability** | Structured logging (App Insights), run summaries, distributed tracing, custom metrics. |
| **Reliability** | Idempotent operations, graceful degradation, checkpoint/resume via queue visibility timeouts, Polly exponential backoff + jitter on 429s. |
| **Scalability** | Multi-app parallelization via per-worker-pair queues (see [§2.1](#21-end-to-end-pipeline-narrative)). Each worker pair has dedicated app registrations (B2C + EEID) and a per-pair phone-registration queue. Two scaling axes: add more worker pairs (linear throughput), or increase `MaxConcurrency` within a worker (sweet spot: 8). |

---

## 4. Component Architecture

### Core Library Structure

```
B2CMigrationKit.Core/
├── Abstractions/          # IOrchestrator, IGraphClient, IQueueClient, ITableStorageClient, etc.
├── Configuration/         # MigrationOptions, B2COptions, ExternalIdOptions, StorageOptions, etc.
├── Models/                # UserProfile, MigrationAuditRecord, RunSummary, PhoneRegistrationMessage, etc.
├── Services/
│   ├── Orchestrators/     # ExportOrchestrator, ImportOrchestrator (Simple Mode), HarvestOrchestrator, WorkerMigrateOrchestrator, PhoneRegistrationWorker (Advanced Mode), JitMigrationService
│   ├── Infrastructure/    # GraphClient, QueueStorageClient, TableStorageClient, BlobStorageClient, etc.
│   └── Observability/     # TelemetryService
└── Extensions/            # ServiceCollectionExtensions (DI registration)
```

### Dependency Injection

All services use constructor injection with interface-based abstractions. Keyed services distinguish B2C vs EEID graph clients:

```csharp
services.AddCoreServices(configuration);

public class WorkerMigrateOrchestrator : IOrchestrator
{
    public WorkerMigrateOrchestrator(
        [FromKeyedServices("b2c")] IGraphClient b2cClient,
        [FromKeyedServices("externalId")] IGraphClient externalIdClient,
        IQueueClient queueClient,
        ITableStorageClient auditClient,
        ITelemetryService telemetry,
        ILogger<WorkerMigrateOrchestrator> logger) { }
}
```

---

## 5. Bulk Migration Pipeline

### 5.0 Simple Mode — Export

Pages B2C users with configurable `$select` fields, writes each page as a JSON blob to `ExportContainerName`. Supports optional `FilterPattern` for client-side filtering by `displayName`/`userPrincipalName`.

- **Permissions**: B2C `User.Read.All` (Application)
- **Config**: `Export.SelectFields`, `Export.FilterPattern`, `PageSize` (default: 999)
- **Output**: `{ExportContainerName}/{ExportBlobPrefix}page-{N}.json`

### 5.0b Simple Mode — Import

Reads exported blobs sequentially, transforms user profiles (UPN domain rewrite, extension attribute mapping, email identity, random password + `RequiresMigration` JIT flag), creates users in EEID. Audit results written as JSON blobs to `ImportAuditContainerName`.

- **Permissions**: EEID `User.ReadWrite.All` (Application)
- **Config**: `Import.ExtensionAttributes` (source → target attribute mapping)
- **Idempotency**: 409 Conflict = duplicate, skipped gracefully

### 5.1 Advanced Mode — Harvest

Pages B2C with `$select=id` (~10× cheaper than full profile fetch), splits into batches of `IdsPerMessage` (default: 20), enqueues to `user-ids-to-process`. Single instance, exits on completion.

- **Permissions**: B2C `User.Read.All` (Application) — read-only, no EEID access needed
- **Config**: `HarvestOptions.PageSize` (default: 999), `HarvestOptions.IdsPerMessage` (default: 20)

### 5.2 Advanced Mode — Worker Migrate

Consumes harvest queue, fetches full profiles via `$batch`, transforms and creates users in EEID, enqueues phone tasks. Replaces the old three-step blob pipeline.

**Per-message flow**: Dequeue (20 IDs) → `$batch` fetch from B2C → Transform (UPN, attrs, email identity, random password) → `POST /users` to EEID → Audit → Enqueue phone task → Delete message.

**Audit trail** (Azure Table `migration-audit`):

| Field | Description |
|---|---|
| `PartitionKey` | Date `yyyyMMdd` |
| `RowKey` | `migrate_{B2CObjectId}` |
| `Status` | `Created` / `Duplicate` / `Failed` |
| `ErrorCode` | HTTP status or exception type |
| `ErrorMessage` | Truncated to 4 KB |
| `DurationMs` | API call duration |

**Permissions**: B2C `User.Read.All`, EEID `User.ReadWrite.All` (both Application).

### 5.3 Advanced Mode — Phone Registration

Registers MFA phone numbers in EEID so users confirm (not re-register) on first JIT login. 

Queue messages contain only `{ B2CUserId, EEIDUpn }` — phone numbers are fetched at drain time (PII never persisted in queue).

| Setting | Default | Purpose |
|---|---|---|
| `ThrottleDelayMs` | 400 ms | Rate control — increase if sustained 429s |
| `MessageVisibilityTimeoutSeconds` | 120 s | Retry delay on failure |
| `MaxEmptyPolls` | 3 | Exit after N consecutive empty polls |

**Permissions**: B2C `UserAuthenticationMethod.Read.All`, EEID `UserAuthenticationMethod.ReadWrite.All` (both Application).

---

## 6. Just-In-Time (JIT) Migration

### Overview

JIT enables seamless password validation on first External ID login:

1. User logs in → EEID checks `RequiresMigration = true`
2. Custom Authentication Extension calls Azure Function with encrypted password + UPN
3. Function decrypts password (RSA private key from Key Vault)
4. Function reverses UPN transform: `user@externalid.com` → `user@b2c.com`
5. Function validates via ROPC against B2C
6. If valid → `MigratePassword` (EEID sets password, clears flag). If invalid → `BlockSignIn`

**UPN Flow**:
```
Import:  user@b2c.com → user@externalid.com  (preserve local part)
JIT:     user@externalid.com → user@b2c.com  (reverse using same local part)
```

### Security Measures

| Layer | Control |
|-------|---------|
| **Encryption at rest** | RSA private key in Key Vault (Function MI with `Get Secret` only). Passwords never stored/logged. |
| **Encryption in transit** | Password field RSA-encrypted by Custom Extension. All traffic TLS 1.2+. |
| **AuthN: EEID → Function** | Azure AD bearer token, audience = Custom Extension app ID URI |
| **AuthN: Function → B2C** | ROPC flow (ClientId + ClientSecret). No Graph permissions needed. |
| **AuthN: Function → EEID** | Managed Identity or Service Principal, `User.ReadWrite.All` |
| **Replay protection** | Nonce in encrypted payload, validated by function |
| **Timeout** | EEID hard limit: 2s. Function internal: 1.5s (configurable). Exceeds → `BlockSignIn`. |

---

## 7. Security Architecture

> **⚠️ STATUS**: v1.0 includes TLS 1.2+, client secret auth, no secrets in code. 

### Service Principal Permissions

| Process | Mode | Tenant | Permission | Type |
|---|---|---|---|---|
| `export` | A | B2C | `User.Read.All` | Application |
| `import` | A | EEID | `User.ReadWrite.All` | Application |
| `harvest` | B | B2C | `User.Read.All` | Application |
| `worker-migrate` | B | B2C | `User.Read.All` | Application |
| `worker-migrate` | B | EEID | `User.ReadWrite.All` | Application |
| `phone-registration` | B | B2C | `UserAuthenticationMethod.Read.All` | Application |
| `phone-registration` | B | EEID | `UserAuthenticationMethod.ReadWrite.All` | Application |
| JIT Function | Both | EEID | `User.ReadWrite.All` | Application |

> Admin consent required for all. `Directory.ReadWrite.All` / `Directory.Read.All` are **not required** — least-privilege approach.

### Data Protection

- **At rest**: Azure SSE (Storage), HSM-backed keys (Key Vault Premium), encrypted App Insights logs (90-day retention)
- **In transit**: TLS 1.2+ everywhere, strict certificate validation, HTTPS enforced
- **Secrets**: Target: Key Vault references (`@Microsoft.KeyVault(SecretUri=...)`). Current: config files (gitignored)

### Audit & Compliance

- Key Vault audit logs (all secret access tracked)
- Function invocation logs (correlation IDs, user IDs, results)
- External ID sign-in audit logs (30-day retention, export for long-term)
- Table Storage migration audit (permanent, queryable)

---

## 9. Deployment & Operations

### Development Environment

```
Developer Workstation
├── Console App (harvest, worker-migrate, phone-registration)
├── Azure Function (localhost:7071) + ngrok tunnel
├── Azurite (local storage emulator)
└── External ID Test Tenant (Custom Extension → ngrok URL)
```

- Fast iteration, full debugging, inline RSA keys, no Key Vault dependency.

### Production Environment (🔜 v2.0)

- Azure Function App (Linux Premium EP1) with VNet integration + Managed Identity
- Private Endpoints for Key Vault, Storage (Queue/Table/Blob)
- Application Insights with dashboards and alert rules
- Auto-scale 1-20 instances

### Multi-Instance Deployment

```
Container 1  (App Reg B2C-1/EEID-1, IP: 10.0.1.10)
Container 2  (App Reg B2C-2/EEID-2, IP: 10.0.1.11)
...
Container N  (App Reg B2C-N/EEID-N, IP: 10.0.1.NN)
```

Options: ACI, AKS (StatefulSet), or separate VMs.

### Monitoring (Sample KQL)

> These are reference queries. This repo does not deploy App Insights resources.

**Migration progress**:
```kql
traces
| where message contains "RUN SUMMARY"
| extend TotalUsers = toint(extract("Total: ([0-9]+)", 1, message))
| extend SuccessCount = toint(extract("Success: ([0-9]+)", 1, message))
| summarize TotalMigrated = sum(SuccessCount) by bin(timestamp, 1h)
| render timechart
```

**Throttling events**:
```kql
traces
| where message contains "throttle" or message contains "429"
| summarize ThrottleCount = count() by cloud_RoleInstance, bin(timestamp, 5m)
| render timechart
```

### Alerting

| Alert | Condition |
|-------|-----------|
| JIT failures | >5% error rate in 5-min window |
| Migration stalled | No RUN SUMMARY in 30 min |
| Key Vault access failure | >3 unauthorized requests in 5 min |
