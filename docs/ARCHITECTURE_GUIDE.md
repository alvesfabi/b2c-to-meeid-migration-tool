# B2C Migration Kit - Architecture Guide

**Target Audience**: Solutions Architects, Technical Leads, Security Reviewers, Decision Makers

**Purpose**: This document provides a comprehensive architectural overview of the B2C Migration Kit, designed to assist with migrating users from Azure AD B2C to Microsoft Entra External ID. It covers system components, design principles, scalability considerations, security measures, and deployment patterns.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Overview](#2-system-overview)
3. [Design Principles](#3-design-principles)
4. [Component Architecture](#4-component-architecture)
5. [Bulk Migration Components](#5-bulk-migration-components)
   - [5.1 Harvest — Master/Producer Phase](#51-harvest--masterproducer-phase)
   - [5.2 Worker Migrate — B2C Fetch + EEID Create](#52-worker-migrate--b2c-fetch--eeid-create)
   - [5.3 Phone Registration Worker](#53-phone-registration-worker)
6. [Just-In-Time (JIT) Migration Architecture](#6-just-in-time-jit-migration-architecture)
7. [Security Architecture](#7-security-architecture)
8. [Scalability & Performance](#8-scalability--performance)
9. [Deployment Topologies](#9-deployment-topologies)
10. [Operational Considerations](#10-operational-considerations)

---

## 1. Executive Summary

> **⚠️ IMPORTANT**: This document describes the **target architecture** for a production-ready migration solution. The current release (v1.0) is a **sample/preview implementation** validated for local development scenarios. Production features including full SFI compliance, automated infrastructure deployment, and Key Vault integration are **documented here as design patterns** but will be fully implemented and tested in future releases.

### What Is This Migration Kit?

The **B2C Migration Kit** is a sample solution for migrating user identities from **Azure AD B2C** to **Microsoft Entra External ID**. It currently supports:

- **Bulk Migration**: Migrate users with a queue-based (harvest → worker-migrate → phone-registration)
- **Just-In-Time (JIT) Password Migration**: Seamless password validation during first login (tested with Custom Authentication Extension)

### What will be added in the future?

- **Enterprise Security Architecture**: SFI-compliant design patterns with private endpoints, Managed Identity, and Key Vault integration - architecture is ready for SFI but not yet implemented in this sample.


### Why Use This Kit?

- **Proven Approach**: Validated migration pattern for B2C to External ID transitions
- **Scale-Ready Design**: Horizontal scaling via multiple parallel workers; throughput bounded by the B2C tenant's default 200 RPS Graph API limit
- **Zero Downtime**: Users migrate transparently on first login (no forced password resets)
- **Local Development**: Fully functional sample for testing and validation without cloud resources

### When to Use This Kit

| Scenario | Recommendation |
|----------|----------------|
| Migrating from B2C to External ID when User Flows are implemented (no custom policies) | ✅ Primary use case |
| Local development & testing | ✅ Fully validated |
| Production with SFI requirements | ⚠️ Wait for future release or implement security hardening |

---

## 2. System Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Subscription                           │
│                                                                 │
│  ┌──────────────────────────┐  ┌──────────────┐               │
│  │ Console App                    │  │Azure Function│               │
│  │(Harvest/WorkerMigrate/          │  │(JIT Auth)    │               │
│  │ PhoneRegistration)              │  │              │               │
│  └──────┬───────────────────┘  └──────┬───────┘               │
│         │                             │                        │
│  ┌──────▼─────────────────────────────▼───────────────┐       │
│  │                 Shared Core Library                 │       │
│  │   (Services, Models, Orchestrators, Abstractions)   │       │
│  └──────┬───────────┬───────────┬──────────┬──────────┘       │
│         │           │           │          │                   │
│         ▼           ▼           ▼          ▼                   │
│  ┌──────────┐ ┌─────────┐ ┌──────────┐ ┌──────────┐          │
│  │ Storage  │ │ Table   │ │Key Vault │ │App       │          │
│  │ Queue    │ │ Storage │ │          │ │ Insights │          │
│  │(pipeline)│ │ (audit) │ │ *Future  │ │          │          │
│  └──────────┘ └─────────┘ └──────────┘ └──────────┘          │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
         │                           │
         │                           │
         ▼                           ▼
┌─────────────────┐         ┌─────────────────┐
│ Azure AD B2C    │         │ External ID     │
│ (Source Tenant) │         │ (Target Tenant) │
└─────────────────┘         └─────────────────┘
```

### Data Flow

The bulk migration pipeline consists of three commands that run sequentially. Start each command only after the previous step has finished (or with enough queue depth to keep workers busy).

#### Step 1 — `harvest` (run once)

```
B2C Tenant
└─ GET /users?$select=id&$top=999  (ID-only pages, very cheap)
   └─ HarvestOrchestrator
      └─► Queue: user-ids-to-process  (JSON arrays of 20 IDs per message)
```

`HarvestOrchestrator` pages through B2C using `$select=id` — the least expensive Graph query. Each page is split into batches of 20 IDs and enqueued as individual messages. No blob files are produced. The command exits when all IDs are enqueued.

The key insight is that **fetching only IDs is fast and cheap** (no heavy user-profile data), and placing them in a shared queue lets **any number of `worker-migrate` instances pull work concurrently and independently** — there is no central coordinator assigning ranges, no risk of overlap, and no wasted capacity when one worker finishes ahead of others.

#### Step 2a — `worker-migrate` (run N parallel instances)

```
Queue: user-ids-to-process
└─ WorkerMigrateOrchestrator (one per instance, independent App Registration)
   ├─ GET /$batch → B2C (up to 20 full user profiles per batch request)
   ├─ Transform: UPN domain rewrite · extension attrs · email identity · random password
   ├─ POST /users → Entra External ID
   │   ├─ 201 Created  → audit(Created)   + enqueue phone task
   │   ├─ 409 Conflict → audit(Duplicate) + enqueue phone task
   │   └─ Other error  → audit(Failed, errorCode, errorMessage)
   ├─► Table Storage: migration-audit  (every outcome written in real time)
   └─► Queue: phone-registration  ({ B2CUserId, EEIDUpn } — no phone number stored)
```

Each worker instance uses an **independent app registration** and (ideally) a separate IP address so API quotas scale linearly. Workers exit automatically when the queue is empty (`MaxEmptyPolls` reached).

#### Step 2b — `phone-registration` (run M parallel instances)

```
Queue: phone-registration
└─ PhoneRegistrationWorker (one per instance, independent App Registrations for B2C and EEID)
   ├─ GET /users/{B2CUserId}/authentication/phoneMethods → B2C  (0.5 RPS per worker)
   ├─ If phone found: POST /users/{EEIDUpn}/authentication/phoneMethods → EEID
   │   ├─ 201 Created  → audit(PhoneRegistered)
   │   └─ 409 Conflict → audit(PhoneRegistered, idempotent)
   ├─ If no phone:     → audit(PhoneSkipped)
   └─► Table Storage: migration-audit
```

Phone numbers are fetched from B2C **at drain time** — they are never stored in the queue. This keeps PII out of the message store and in memory only for the duration of a single API call pair.

> **Throttle limit**: The `authenticationMethod` Graph API family is limited to **5 req / 10 s (0.5 RPS) per app per tenant**. The default `ThrottleDelayMs` of **2 000 ms** matches this limit. Run additional `phone-registration` instances each with their own EEID app registration to increase throughput — 3 instances ≈ 1.5 RPS ≈ 138 K phones in ~26 hours.

#### Step 3 — JIT Migration (first login — Azure Function, always running)

```
User Login → EEID checks RequiresMigration = true
          └─ Custom Authentication Extension → Azure Function (JitAuthenticationFunction)
             ├─ Decrypt password (RSA private key from Key Vault)
             ├─ Reverse UPN transform: user@eeid.onmicrosoft.com → user@b2c.onmicrosoft.com
             ├─ POST /oauth2/v2.0/token (ROPC) → B2C
             │   ├─ Valid   → { action: MigratePassword }  → EEID sets password + RequiresMigration=false
             │   └─ Invalid → { action: BlockSignIn }
             └─ Subsequent logins: authenticate directly in EEID (RequiresMigration=false)
```

After `phone-registration` has run, users whose phones were registered are prompted to **confirm** their existing phone (SMS code) on first JIT login — not to register a new MFA method from scratch.

---

## 3. Design Principles

> **🚧 Note**: The principles below describe the **target production architecture**. Current release (v1.0) implements core migration functionality for local development. SFI compliance features (Private Endpoints, VNet, Key Vault) are documented here as design guidance for future implementation or custom deployments.

### 3.1 SFI-Aligned Modular Architecture (Target Design)

1. **Shared Core Library** (`B2CMigrationKit.Core`)
   - All business logic, models, abstractions
   - Reusable across Console, Function, and future hosting environments
   - Zero hosting-specific dependencies

2. **Console Application** (`B2CMigrationKit.Console`)
   - Developer-friendly local execution
   - Rich CLI with verbose logging
   - Fast iteration and debugging

3. **Azure Functions** (`B2CMigrationKit.Function`)
   - Production-grade cloud execution
   - Scalable, event-driven architecture
   - Integrated with Azure monitoring and security

### 3.2 Security First

- **Private Endpoints Only**: All Azure PaaS resources (Storage, Key Vault) accessible only via private network
- **Managed Identity**: Zero secrets in code or configuration (except Key Vault references)
- **Encryption Everywhere**: At rest (Storage/Key Vault) and in transit (HTTPS/TLS 1.2+)
- **Least Privilege**: Service principals with minimal required permissions

### 3.3 Observability

- **Structured Logging**: Application Insights with named properties (no string concatenation)
- **Run Summaries**: Single aggregated log per execution (counts, duration, errors)
- **Distributed Tracing**: Correlation IDs across components
- **Custom Metrics**: Track migration progress, throttling events, performance

### 3.4 Reliability

- **Idempotency**: Safe to retry operations without duplication
- **Graceful Degradation**: Continue processing on non-critical failures
- **Checkpoint/Resume**: Workers restart automatically by re-processing any queue message that returned after a visibility timeout (at-least-once delivery)
- **Circuit Breaker**: Automatic backoff on API throttling (HTTP 429)

### 3.5 Scalability

- **Multi-App Parallelization**: Use 3-5 app registrations to multiply throughput
- **Stateless Design**: Horizontal scaling without shared state
- **Batching**: Efficient Graph API batch requests (20 user IDs per queue message, resolved via `$batch`)

---

## 4. Component Architecture

### 4.1 Core Library Structure

```
B2CMigrationKit.Core/
├── Abstractions/
│   ├── IOrchestrator.cs              # Coordinates multi-step workflows
│   ├── IGraphClient.cs               # Graph API operations (CRUD users)
│   ├── IBlobStorageClient.cs         # Blob storage (JIT RSA key PEM)
│   ├── IQueueClient.cs               # Azure Queue operations
│   ├── ITableStorageClient.cs        # Azure Table Storage (audit trail)
│   ├── IAuthenticationService.cs     # B2C ROPC validation
│   ├── ICredentialManager.cs         # App credential resolution
│   ├── ISecretProvider.cs            # Key Vault integration
│   └── ITelemetryService.cs          # Custom metrics/events
├── Configuration/
│   ├── MigrationOptions.cs           # Root configuration binding
│   ├── B2COptions.cs                 # B2C tenant configuration
│   ├── ExternalIdOptions.cs          # External ID tenant configuration
│   ├── ExportOptions.cs              # $select fields for $batch fetch
│   ├── HarvestOptions.cs             # Harvest page size, batch size
│   ├── ImportOptions.cs              # UPN transform, attribute mapping
│   ├── PhoneRegistrationOptions.cs   # Throttle delay, poll settings
│   ├── StorageOptions.cs             # Queue names + AuditTableName
│   ├── RetryOptions.cs               # Throttling/backoff settings
│   └── JitAuthenticationOptions.cs   # JIT function settings
├── Models/
│   ├── UserProfile.cs                # Unified user model
│   ├── ExecutionResult.cs            # Per-user operation outcome
│   ├── RunSummary.cs                 # Aggregated run statistics
│   ├── MigrationAuditRecord.cs       # ITableEntity for audit table
│   ├── PhoneRegistrationMessage.cs   # { B2CUserId, EEIDUpn } queue message
│   ├── JitAuthenticationRequest.cs   # JIT payload from External ID
│   └── JitAuthenticationResponse.cs  # JIT response to External ID
├── Services/
│   ├── Orchestrators/
│   │   ├── HarvestOrchestrator.cs        # harvest command
│   │   ├── WorkerMigrateOrchestrator.cs  # worker-migrate command
│   │   ├── PhoneRegistrationWorker.cs    # phone-registration command
│   │   └── JitMigrationService.cs        # JIT validation logic (Function)
│   ├── Infrastructure/
│   │   ├── GraphClient.cs                # Graph API implementation
│   │   ├── GraphClientFactory.cs         # Creates typed IGraphClient instances
│   │   ├── BlobStorageClient.cs          # Azure Blob operations
│   │   ├── QueueStorageClient.cs         # Azure Queue operations
│   │   ├── TableStorageClient.cs         # Azure Table Storage (audit)
│   │   ├── CredentialManager.cs          # Credential resolution
│   │   ├── AuthenticationService.cs      # B2C ROPC implementation
│   │   └── SecretProvider.cs             # Key Vault / inline secret provider
│   └── Observability/
│       └── TelemetryService.cs           # Application Insights wrapper
└── Extensions/
    └── ServiceCollectionExtensions.cs    # DI registration for all services
```

### 4.2 Dependency Injection Pattern

All services use **constructor injection** with interface-based abstractions:

```csharp
// Registration (Console + Function)
services.AddCoreServices(configuration);

// Example: worker-migrate orchestrator receives dual graph clients + queue + table
public class WorkerMigrateOrchestrator : IOrchestrator
{
    private readonly IGraphClient _b2cClient;
    private readonly IGraphClient _externalIdClient;
    private readonly IQueueClient _queueClient;
    private readonly ITableStorageClient _auditClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<WorkerMigrateOrchestrator> _logger;

    public WorkerMigrateOrchestrator(
        [FromKeyedServices("b2c")] IGraphClient b2cClient,
        [FromKeyedServices("externalId")] IGraphClient externalIdClient,
        IQueueClient queueClient,
        ITableStorageClient auditClient,
        ITelemetryService telemetry,
        ILogger<WorkerMigrateOrchestrator> logger)
    {
        // ...
    }
}
```

---

## 5. Bulk Migration Components

### 5.1 Harvest — Master/Producer Phase

**Purpose**: Page through the entire B2C tenant using `$select=id` (the cheapest possible Graph query), split the IDs into batches of 20, and enqueue each batch to `user-ids-to-process`. This decouples *work discovery* from *work execution*: a single harvest instance does the cheap enumeration upfront, then any number of `worker-migrate` instances can drain the queue in parallel without any central assignment logic — each worker simply pulls the next available message, processes it, and loops. This is the Producer/Consumer pattern that enables the horizontal scaling described in section 5.2.

#### Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  HarvestOrchestrator  (single instance, `harvest` command)      │
│                                                                  │
│  GET /users?$select=id&$top=999                                  │
│  ↺  follow @odata.nextLink until exhausted                       │
│                                                                  │
│  for every 20 IDs collected:                                     │
│    SendMessage(queue: user-ids-to-process, ["id1","id2",...])    │
│                                                                  │
│  Exits when all pages are processed                              │
└──────────────────────────────────────────────────────────────────┘
                             │
                             │  Azure Queue Storage
                             ▼
                   Queue: user-ids-to-process
                   (each message = JSON array of up to 20 IDs)
```

#### Key Features

- **Enables parallelization**: By depositing all user IDs into a shared queue before migration begins, an arbitrary number of `worker-migrate` instances can pull and process messages concurrently. Workers need no coordination — queue visibility timeouts guarantee each message is processed by exactly one worker at a time.
- **Minimal API cost**: `$select=id` returns only the object ID — approximately 10× cheaper per page than a full profile fetch, so the harvest finishes quickly even for multi-million-user tenants
- **No blob files produced**: IDs flow directly from B2C into the queue; there are no intermediate exports
- **Configurable batch/page size**: `HarvestOptions.BatchSize` (default: 20 IDs per message) and `HarvestOptions.PageSize` (default: 999 users per Graph page)
- **Single-pass, exits on completion**: Once all `@odata.nextLink` pages are exhausted and every ID is enqueued, the `harvest` command exits automatically

#### Process Flow

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Ensure queue exists (create if missing)                      │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 2. Fetch page of IDs from B2C                                   │
│    GET /users?$select=id&$top=999                                │
│    Follow @odata.nextLink until no next page                     │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 3. Accumulate IDs into batches of 20                            │
│    When batch is full (or last page end), enqueue:              │
│    SendMessage(queue, "[\"id1\",\"id2\",...\"id20\"]")           │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 4. Log RunSummary (total IDs enqueued, messages sent, duration) │
└──────────────────────────────────────────────────────────────────┘
```

#### Required Permissions

The harvest instance uses **one** app registration:

**B2C app registration**:
```
User.Read.All   (Application permission)   # or Directory.Read.All
```

No write permissions are required; no access to External ID is needed during harvest.

#### Security Measures

- **Service Principal**: Minimal read-only access to B2C (`User.Read.All`)
- **Network**: Queue writes go through the shared `IQueueClient` (Managed Identity or connection string)

### 5.2 Worker Migrate — B2C Fetch + EEID Create

**Purpose**: Consume the harvest queue, fetch full user profiles from B2C, transform them, create the accounts in Entra External ID, and enqueue lightweight phone-registration tasks for the parallel phone worker. This single step replaces the old three-step blob pipeline (worker-export → blob → import).

#### Architecture Overview

```
          Azure Queue: user-ids-to-process
                       │
     ┌─────────────────┼─────────────────┐
     │                 │                 │
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│ WORKER 1         │ │ WORKER 2         │ │ WORKER N         │
│ WorkerMigrate    │ │ WorkerMigrate    │ │ WorkerMigrate    │
│ App Reg 1        │ │ App Reg 2        │ │ App Reg N        │
│ 1. $batch B2C    │ │ 1. $batch B2C    │ │ 1. $batch B2C    │
│ 2. POST EEID     │ │ 2. POST EEID     │ │ 2. POST EEID     │
│ 3. Audit Table   │ │ 3. Audit Table   │ │ 3. Audit Table   │
│ 4. Enqueue phone │ │ 4. Enqueue phone │ │ 4. Enqueue phone │
└─────────────────┘ └─────────────────┘ └─────────────────┘
     │                 │                 │
     └─────────────────┼─────────────────┘
                       │
          Azure Queue: phone-registration
```

#### Key Features

- **No intermediate blob hop**: B2C fetch and EEID create happen in the same process, eliminating the export→blob→import latency overhead
- **Unified transformation**: UPN domain rewrite, extension-attribute stamping, email identity injection, and random-password generation are all applied inline
- **409 Duplicate handling**: If a user already exists in EEID (idempotent re-run), status is recorded as `Duplicate` and a phone-registration task is still enqueued
- **Azure Table Storage audit trail**: Every user outcome (Created / Duplicate / Failed) is written to the `migration-audit` table with error code and duration
- **Parallel scalability**: N worker instances share the same queue; each uses an independent app registration and (ideally) a separate IP for full API-quota independence

#### Process Flow (per message)

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Dequeue message (20 IDs) with visibility timeout             │
└──────────────────────────────────────────────────────────────────┘
             │
             │
┌──────────────────────────────────────────────────────────────────┐
│ 2. Fetch full profiles from B2C: GET /$batch (up to 20 IDs)     │
└──────────────────────────────────────────────────────────────────┘
             │
             │ for each user:
┌──────────────────────────────────────────────────────────────────┐
│ 3. Transform: UPN domain, ext attrs, email identity, password   │
└──────────────────────────────────────────────────────────────────┘
             │
┌──────────────────────────────────────────────────────────────────┐
│ 4. POST /users in EEID                                          │
│    ─── Created (201) → audit(Created) + enqueue phone task       │
│    ─── Conflict (409) → audit(Duplicate) + enqueue phone task    │
│    ─── Other error → audit(Failed + errorCode + message)         │
└──────────────────────────────────────────────────────────────────┘
             │
┌──────────────────────────────────────────────────────────────────┐
│ 5. Delete queue message (ACK)                                   │
└──────────────────────────────────────────────────────────────────┘
```

#### Audit Trail

Every user outcome is written to Azure Table Storage (`migration-audit` table) in real time:

| Field | Description |
|---|---|
| `PartitionKey` | Date in `yyyyMMdd` format |
| `RowKey` | `migrate_{B2CObjectId}` |
| `Status` | `Created`, `Duplicate`, or `Failed` |
| `ErrorCode` | HTTP status or exception type |
| `ErrorMessage` | Truncated to 4 KB |
| `DurationMs` | Time taken for the API call |

#### Security Measures

- **B2C Service Principal**: `Directory.Read.All` (application permission)
- **EEID Service Principal**: `User.ReadWrite.All` (application permission)
- **Audit Storage**: Managed Identity or storage key (Key Vault recommended for production)

---

### 5.3 Phone Registration Worker

**Purpose**: Register each migrated user's MFA phone number in Entra External ID as a `phoneAuthenticationMethod` entry, so that on first JIT login the user is only asked to **confirm** their existing phone (SMS code), not perform a full re-registration.

#### Why a Separate Async Worker?

The Graph endpoint `POST /users/{id}/authentication/phoneMethods` has a significantly lower throttle budget than the main `/users` endpoints. Calling it inline during the migrate phase would stall the creation pipeline. Instead, `WorkerMigrateOrchestrator` enqueues a lightweight `{ B2CUserId, EEIDUpn }` message — no phone number stored — and this dedicated worker fetches the phone from B2C at drain time, then registers it in EEID.

**Why not store the phone in the queue?**

Phone numbers are PII. Storing them in plain-text queue messages creates an unnecessary data risk. Fetching at drain time means the phone number is only held in memory for the duration of a single API call pair and never persists outside the two tenants.

#### Architecture

```
WorkerMigrate ──► Queue: phone-registration ──► PhoneRegistrationWorker
 (enqueue { B2CUserId, EEIDUpn })               1. GET B2C phone (phoneMethods API)
                                                 2. POST EEID /authentication/phoneMethods
                                                 3. audit(PhoneRegistered / PhoneSkipped / PhoneFailed)
                                                 409 Conflict → treated as success (idempotent)
                                                 null phone → audit(PhoneSkipped), delete message
                                                 Failure → message stays in queue (retry via visibility timeout)
```

#### Throttle Strategy

| Setting | Default | Notes |
|---|---|---|
| `ThrottleDelayMs` | 2000 ms | 0.5 RPS — matches documented `phoneMethods` tenant limit |
| `MessageVisibilityTimeoutSeconds` | 120 s | If processing fails, message re-appears after this delay |
| `MaxEmptyPolls` | 3 | Worker exits after 3 consecutive empty polls (for CLI use) |
| `EmptyQueuePollDelayMs` | 5000 ms | Wait before re-polling when queue is empty |

Multiple `PhoneRegistrationWorker` instances can run in parallel with different app registrations to increase throughput: 3 instances = 1.5 RPS ≈ 138K phones registered in ~26 hours.


#### Required Permissions

The phone worker uses **two** app registrations:

**B2C app registration** (for reading MFA phones):
```
UserAuthenticationMethod.Read.All   (Application permission)
```

**External ID app registration** (for registering phones):
```
UserAuthenticationMethod.ReadWrite.All  (Application permission)
```

---

## 6. Just-In-Time (JIT) Migration Architecture

### 6.1 Overview

JIT migration enables **seamless password validation** during first login to External ID, eliminating the need for users to reset passwords.

**Key Concept**: When a user logs in to External ID for the first time:
1. External ID checks `RequiresMigration` custom attribute
2. If `RequiresMigration = true` (not yet migrated), trigger Custom Authentication Extension
3. Extension calls Azure Function with encrypted password and user's UPN
4. Function **reverses the UPN domain transformation** (External ID domain → B2C domain)
   - External ID UPN: `user@externalid.onmicrosoft.com`
   - Extracts local part: `user` (preserved from import)
   - Reconstructs B2C UPN: `user@b2c.onmicrosoft.com`
5. Function validates password against B2C via ROPC using the reconstructed B2C UPN
6. If valid, External ID sets the password and marks `RequiresMigration = false`
7. Subsequent logins skip JIT flow (authenticate directly with External ID)

**Critical UPN Flow**:
```
Import Phase:  B2C UPN (user@b2c.com) → Transform → External ID UPN (user@externalid.com)
                                                     [Preserve local part: "user"]

JIT Phase:     External ID UPN (user@externalid.com) → Reverse Transform → B2C UPN (user@b2c.com)
                                                         [Use same local part: "user"]
```

### 6.2 Architectural Components

```
┌────────────────────────────────────────────────────────────────────┐
│                         External ID Tenant                         │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ User Sign-In Flow                                            │ │
│  │ 1. User submits UPN + Password                               │ │
│  │ 2. Check RequiresMigration attribute                         │ │
│  │ 3. If true → Trigger OnPasswordSubmit listener               │ │
│  └──────────────────────────┬───────────────────────────────────┘ │
│                             │                                      │
│  ┌──────────────────────────▼───────────────────────────────────┐ │
│  │ Custom Authentication Extension                              │ │
│  │ - App Registration with RSA Public Key                       │ │
│  │ - Encrypts password field with RSA public key                │ │
│  │ - Sends POST to Azure Function                               │ │
│  │ - Timeout: 2 seconds max                                     │ │
│  └──────────────────────────┬───────────────────────────────────┘ │
└────────────────────────────┼────────────────────────────────────────┘
                             │ HTTPS (encrypted password field)
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│                   Azure Function (JIT Endpoint)                    │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ 1. Decrypt Password                                          │ │
│  │    - Retrieve RSA private key from Key Vault (cached)        │ │
│  │    - Decrypt password context → {password, nonce}            │ │
│  │    - Validate nonce present (replay protection)              │ │
│  └──────────────────────────┬───────────────────────────────────┘ │
│                             │                                      │
│  ┌──────────────────────────▼───────────────────────────────────┐ │
│  │ 2. Transform UPN and Validate Credentials (B2C ROPC)         │ │
│  │    a) Reverse UPN transformation:                            │ │
│  │       - Input: user@externalid.onmicrosoft.com               │ │
│  │       - Extract local part: "user"                           │ │
│  │       - Reconstruct: user@b2c.onmicrosoft.com                │ │
│  │    b) POST to B2C /oauth2/v2.0/token                         │ │
│  │       - grant_type=password                                  │ │
│  │       - username={reconstructed-b2c-upn}                     │ │
│  │       - password={decrypted-password}                        │ │
│  │    Success → Token received (valid password)                 │ │
│  │    Failure → invalid_grant (wrong password)                  │ │
│  └──────────────────────────┬───────────────────────────────────┘ │
│                             │                                      │
│  ┌──────────────────────────▼───────────────────────────────────┐ │
│  │ 3. Return Response to External ID                            │ │
│  │    Success:                                                  │ │
│  │    { "actions": [{ "action": "MigratePassword" }] }          │ │
│  │                                                              │ │
│  │    Failure:                                                  │ │
│  │    { "actions": [{ "action": "BlockSignIn" }] }              │ │
│  └──────────────────────────┬───────────────────────────────────┘ │
└────────────────────────────┼────────────────────────────────────────┘
                             │
                             ▼
┌────────────────────────────────────────────────────────────────────┐
│                         External ID Tenant                         │
│                                                                    │
│  ┌──────────────────────────────────────────────────────────────┐ │
│  │ If MigratePassword:                                          │ │
│  │ - Set user's password to submitted value                     │ │
│  │ - Set RequiresMigration = false (mark as migrated)           │ │
│  │ - Complete authentication flow                               │ │
│  │ - Issue tokens to application                                │ │
│  └──────────────────────────────────────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘
```

### 6.3 Security Measures

#### 6.3.1 Encryption at Rest

- **Private Key**: Stored in Azure Key Vault as Secret (PEM format)
  - Access restricted to Function Managed Identity (`Get Secret` permission only)
  - Key Vault audit logs enabled (all access tracked)
- **Passwords**: NEVER stored or logged
  - Exist only in memory during request processing
  - Cleared immediately after validation

#### 6.3.2 Encryption in Transit

- **External ID → Function**: HTTPS with encrypted password context
  - Password field encrypted with the RSA public key configured in the Custom Authentication Extension
  - Only Azure Function (with matching RSA private key) can decrypt the password
  - Payload is a JSON HTTP POST; the password field is the only encrypted part
- **Function → B2C**: HTTPS with TLS 1.2+
  - ROPC endpoint uses OAuth 2.0 secure token endpoint
- **Function → External ID Graph API**: OAuth 2.0 Client Credentials flow
  - Short-lived access tokens (1-hour validity)

#### 6.3.3 Authentication & Authorization

**External ID → Function**:
- Azure AD Token Authentication
- Function validates bearer token issued by External ID tenant
- Token audience must match Custom Extension app ID URI

**Function → B2C**:
- Service Principal with `Directory.Read.All` (application permission)
- Client credentials flow (ClientId + ClientSecret from Key Vault)

**Function → External ID**:
- Managed Identity or Service Principal
- Graph API permissions: `User.ReadWrite.All` (application)

#### 6.3.4 Replay Protection

- **Nonce**: Random value included in encrypted payload
- Validated by function (must be present)

#### 6.3.5 Timeout Protection

- **External ID Timeout**: 2 seconds max (hard limit)
  - Function MUST respond within this window
- **Function Internal Timeout**: 1.5 seconds (configurable)
  - Aborts B2C ROPC call if exceeds limit
  - Returns `BlockSignIn` to prevent partial state

### 6.4 Performance Optimization

#### Target Metrics

- **Total JIT Flow**: <500ms (well within 2-second timeout)
  - Step 1 (Decrypt): <20ms
  - Step 2 (B2C ROPC): 200-400ms (network + auth)
  - Step 3 (Complexity check): <10ms
  - Step 4 (Response): <5ms

#### Optimization Strategies

**1. RSA Key Caching**
```csharp
private static string? _cachedPrivateKey;
private static readonly SemaphoreSlim _keyLoadLock = new(1, 1);

// First request: Load from Key Vault (~100ms)
// Subsequent requests: Retrieve from cache (~1ms)
```

**2. Connection Pooling**
- HttpClient singleton with connection reuse
- Token cache for B2C and External ID Graph API

**3. Regional Deployment**
- Deploy Function in same region as External ID tenant
- Reduce network latency (<50ms)

**4. Background Processing**
- Audit logging and telemetry as Fire-and-Forget
- Use durable queue for critical non-blocking tasks

---

## 7. Security Architecture

> **⚠️ IMPLEMENTATION STATUS**: The security patterns described in this section represent the **target production architecture**. Current release (v1.0) includes:
> - ✅ **Available**: TLS 1.2+, Client Secret authentication, no secrets in code
> - 🔜 **Future releases**: Key Vault integration, Managed Identity, Private Endpoints, VNet integration, full SFI compliance
>
> **Upcoming features (v2.0+)**:
> - Production Key Vault integration
> - Private Endpoint configurations
> - Automated infrastructure deployment (Bicep/Terraform)
> - Managed Identity implementation

### 7.1 Network Security (SFI Compliance - Target Architecture)

**Target State**: All Azure PaaS resources MUST be private-endpoint only with public network access disabled.

**Current State**: Architecture and code patterns provided; requires validation and testing for production use.

#### Baseline Controls

```
┌────────────────────────────────────────────────────────────────┐
│                      Virtual Network (VNet)                    │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ App Subnet (10.0.1.0/24)                                │  │
│  │ - Azure Function VNet Integration                       │  │
│  │ - NSG: Allow outbound to Private Endpoint subnet        │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                                │
│  ┌─────────────────────────────────────────────────────────┐  │
│  │ Private Endpoint Subnet (10.0.2.0/24)                   │  │
│  │ ┌────────────┐  ┌────────────┐  ┌────────────┐          │  │
│  │ │ PE: Blob/  │  │ PE: Key    │  │ PE: Queue/ │          │  │
│  │ │ Table      │  │ Vault      │  │ Table      │          │  │
│  │ └────────────┘  └────────────┘  └────────────┘          │  │
│  └─────────────────────────────────────────────────────────┘  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

#### Infrastructure as Code (Bicep Example)

```bicep
// Key Vault with Private Endpoint
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-migration-prod'
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'premium' }
    publicNetworkAccess: 'Disabled'  // SFI requirement
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'None'
    }
  }
}

// Private Endpoint for Key Vault
module kvPe 'modules/privateEndpoint.bicep' = {
  name: 'kvPe'
  params: {
    privateLinkServiceId: kv.id
    groupIds: ['vault']
    subnetId: privateEndpointSubnet.id
  }
}

// Storage Account with Private Endpoint
resource storage 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'stmigrationprod'
  location: location
  sku: { name: 'Standard_ZRS' }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'  // SFI requirement
    allowBlobPublicAccess: false
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
  }
}
```

### 7.2 Identity & Access Management

#### Managed Identity Strategy

All Azure services use **System-Assigned Managed Identity** (no service principals with secrets):

```
┌──────────────────┐
│ Azure Function   │
│ (Managed Identity│
│  Object ID: xxx) │
└────────┬─────────┘
         │
         │ Azure RBAC
         ▼
┌────────────────────────────────────────────────────────────┐
│ Azure Resources                                            │
│                                                            │
│ ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐ │
│ │ Key Vault    │  │ Blob Storage │  │ Queue        │  │ Table        │ │
│ │ Role:        │  │ Role:        │  │ Role:        │  │ Storage      │ │
│ │ Get Secret   │  │ Blob Data    │  │ Queue Data   │  │ Role:        │ │
│ │              │  │ Contributor  │  │ Contributor  │  │ Table Data   │ │
│ └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘ │
└────────────────────────────────────────────────────────────┘
```

#### Service Principal Permissions

**B2C App Registration** (for bulk migration reading and JIT ROPC):
- `User.Read.All` (application permission) — sufficient for harvest and $batch profile reads
- NO write permissions to B2C

**External ID App Registration** (for bulk user creation, phone registration, and JIT updates):
- `User.ReadWrite.All` (application permission) — user creation and attribute updates
- `UserAuthenticationMethod.ReadWrite.All` (application permission) — phone registration
- Restricted to listed permissions (no Global Administrator role required)

### 7.3 Data Protection

#### Encryption at Rest

- **Queue Storage**: Azure Storage Service Encryption (SSE) with Microsoft-managed keys
- **Table Storage**: Azure Storage Service Encryption (SSE) — audit records at rest
- **Blob Storage**: Azure Storage Service Encryption (SSE) — JIT RSA key PEM files
- **Key Vault**: Hardware Security Module (HSM) backed keys (Premium tier)
- **Application Insights**: Encrypted logs with 90-day retention

#### Encryption in Transit

- **All HTTP traffic**: TLS 1.2 or higher (TLS 1.3 where supported)
- **Certificate validation**: Strict certificate pinning for Azure endpoints
- **No plain HTTP**: All connections enforce HTTPS

#### Secrets Management

**Zero secrets in code or configuration files**:
- All secrets stored in Azure Key Vault
- Configuration uses Key Vault references:
  ```json
  {
    "B2C:ClientSecret": "@Microsoft.KeyVault(SecretUri=https://kv-prod.vault.azure.net/secrets/B2CAppSecret/)"
  }
  ```

### 7.4 Audit & Compliance

#### Audit Logging

**Key Vault Audit Logs**:
```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where OperationName == "SecretGet"
| project TimeGenerated, CallerIPAddress, identity_claim_appid_g, ResultSignature
```

**Function Invocation Logs**:
```kql
traces
| where operation_Name == "JitAuthentication"
| extend UserId = customDimensions.UserId
| extend Result = customDimensions.Result
| project timestamp, UserId, Result, duration
```

**User Sign-In Audit (External ID)**:
- Integrated with Azure AD audit logs
- Tracks JIT migration events with custom extension results
- Retention: 30 days (export to Blob for long-term retention)

---

## 8. Scalability & Performance

### 8.1 Graph API Throttling Model

**CRITICAL**: Microsoft Graph API throttling works on **two dimensions**:

1. **Per App Registration (Client ID)** - ~60 operations/second per app
2. **Per IP Address** - Cumulative limit across all apps from that IP
3. **Per Tenant** - 200 RPS for all apps in tenant
4. **Write operations** (create users) have a lower throttling limit 

**Implications**:
- ✅ Single instance with 1 app = ~60 ops/sec
- ❌ Single instance with 3 apps ≠ 180 ops/sec (still limited by IP)
- ✅ 3 instances (different IPs) with 1 app each = ~180 ops/sec

### 8.2 Multi-Instance Scaling Architecture

To scale beyond 60 ops/sec, deploy **multiple instances** on **different IP addresses**:

```
┌─────────────────┐
│  Container 1    │  App Registration 1
│  IP: 10.0.1.10  │  ~60 ops/sec
└─────────────────┘
         +
┌─────────────────┐
│  Container 2    │  App Registration 2
│  IP: 10.0.1.11  │  ~60 ops/sec
└─────────────────┘
         +
┌─────────────────┐
│  Container 3    │  App Registration 3
│  IP: 10.0.1.12  │  ~60 ops/sec
└─────────────────┘
         =
   ~180 ops/sec total
```

#### Deployment Options

**Option 1: Azure Container Instances (ACI)**
```bash
az container create \
  --name migration-worker-migrate-1 \
  --image migrationkit:latest \
  --vnet my-vnet --subnet subnet-1 \
  --environment-variables APPSETTINGS_PATH=appsettings.worker1.json
```

**Option 2: Azure Kubernetes Service (AKS)**
- Deploy 3-5 pods with unique IP addresses
- Use DaemonSet or StatefulSet for IP assignment
- Configure network policies to ensure IP diversity

**Option 3: Virtual Machines**
- Deploy 3-5 VMs in different subnets
- Each VM runs Console app with different app registration

### 8.3 Throttling Management

#### Retry Policy Configuration

```csharp
// Exponential backoff with jitter
var retryPolicy = Policy
    .Handle<HttpRequestException>()
    .Or<RateLimitExceededException>()
    .WaitAndRetryAsync(
        retryCount: 5,
        sleepDurationProvider: attempt => 
            TimeSpan.FromSeconds(Math.Pow(2, attempt)) 
            + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 1000)),
        onRetry: (exception, timespan, attempt, context) =>
        {
            _logger.LogWarning(
                "Throttled (429). Retry {Attempt} after {Delay}ms",
                attempt, timespan.TotalMilliseconds);
        });
```

#### Circuit Breaker Pattern

```csharp
var circuitBreakerPolicy = Policy
    .Handle<HttpRequestException>()
    .CircuitBreakerAsync(
        handledEventsAllowedBeforeBreaking: 10,
        durationOfBreak: TimeSpan.FromMinutes(1),
        onBreak: (exception, duration) =>
        {
            _logger.LogError("Circuit breaker opened for {Duration}", duration);
        },
        onReset: () =>
        {
            _logger.LogInformation("Circuit breaker reset");
        });
```

---

## 9. Deployment Topologies

### 9.1 Development Environment

```
┌─────────────────────────────────────────────────────────────┐
│  Developer Workstation                                      │
│                                                             │
│  ┌────────────────────────────────────────────────────┐    │
│  │ Local Function (localhost:7071)                    │    │
│  │ - InlineRsaPrivateKey (test key)                   │    │
│  │ - UseKeyVault = false                              │    │
│  │ - Azurite (local blob storage)                     │    │
│  └────────────────┬───────────────────────────────────┘    │
│                   │                                         │
│                   ▼                                         │
│  ┌────────────────────────────────────────────────────┐    │
│  │ ngrok (public HTTPS tunnel)                        │    │
│  │ https://abc123.ngrok-free.app →                    │    │
│  │   http://localhost:7071                            │    │
│  └────────────────┬───────────────────────────────────┘    │
└───────────────────┼─────────────────────────────────────────┘
                    │
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  External ID Test Tenant (Cloud)                            │
│  - Custom Extension: https://abc123.ngrok-free.app          │
│  - OnPasswordSubmit Listener (priority 500)                 │
└─────────────────────────────────────────────────────────────┘
```

**Characteristics**:
- Fast iteration cycle (no deployments)
- Full debugging with breakpoints
- Inline RSA keys (no Key Vault dependency)
- ngrok for public endpoint (External ID → local function)

### 9.2 Production Environment (🔜 Coming in v2.0)

**Status**: Target architecture design provided. Key Vault, Private Endpoints, and VNet integration will be fully implemented in v2.0.

**Implementation Timeline**: Planned for v2.0 release with complete automation and deployment templates.

```
┌─────────────────────────────────────────────────────────────┐
│  Azure Subscription (Production)                            │
│                                                             │
│  ┌────────────────────────────────────────────────────┐    │
│  │ Azure Function App (Linux Premium EP1)            │    │
│  │ - System-Assigned Managed Identity                 │    │
│  │ - VNet Integration (App Subnet)                    │    │
│  │ - Application Insights monitoring                  │    │
│  │ - Custom domain + SSL certificate                  │    │
│  │ - Auto-scale: 1-20 instances                       │    │
│  └────────────────┬───────────────────────────────────┘    │
│                   │                                         │
│                   │  Private Network                        │
│                   ▼                                         │
│  ┌────────────────────────────────────────────────────┐    │
│  │ Private Endpoint Subnet                            │    │
│  │ ┌────────────┐  ┌────────────┐  ┌────────────┐    │    │
│  │ │ PE: Key    │  │ PE: Blob/  │  │ PE: Queue/ │    │    │
│  │ │ Vault      │  │ Table      │  │ Table      │    │    │
│  │ └────────────┘  └────────────┘  └────────────┘    │    │
│  └────────────────────────────────────────────────────┘    │
│                                                             │
│  ┌────────────────────────────────────────────────────┐    │
│  │ Application Insights (Log Analytics Workspace)     │    │
│  │ - 90-day retention                                 │    │
│  │ - Custom dashboards                                │    │
│  │ - Alert rules                                      │    │
│  └────────────────────────────────────────────────────┘    │
└───────────────────┼─────────────────────────────────────────┘
                    │
                    │  HTTPS (Public Internet)
                    ▼
┌─────────────────────────────────────────────────────────────┐
│  External ID Production Tenant                              │
│  - Custom Extension: https://func.contoso.com/api/JitAuth   │
│  - OnPasswordSubmit Listener (priority 500)                 │
│  - Public key configured on Extension app registration      │
└─────────────────────────────────────────────────────────────┘
```

**Characteristics**:
- SFI-compliant private network architecture
- Managed Identity for all Azure resource access
- Production RSA keys in Key Vault (Premium tier with HSM)
- Auto-scaling based on request volume
- Comprehensive monitoring and alerting


## 10. Operational Considerations

### 10.1 Monitoring & Dashboards

> **Note:** The KQL queries in this section are sample reference queries. This repository does not deploy any Application Insights resources, dashboards, or alert rules. To use these queries, configure Application Insights in your environment and set `Telemetry:UseApplicationInsights: true` with a valid connection string.

#### Key Metrics

**Migration Progress**:
```kql
// worker-migrate progress (last 24 hours)
traces
| where message contains "RUN SUMMARY"
| where message contains "worker-migrate" or message contains "WorkerMigrate"
| extend TotalUsers = toint(extract("Total: ([0-9]+)", 1, message))
| extend SuccessCount = toint(extract("Success: ([0-9]+)", 1, message))
| extend FailureCount = toint(extract("Failed: ([0-9]+)", 1, message))
| summarize 
    TotalMigrated = sum(SuccessCount),
    TotalFailed = sum(FailureCount)
    by bin(timestamp, 1h)
| render timechart
```

**JIT Migration Success Rate**:
```kql
customEvents
| where name == "JIT_Migration_Completed"
| extend Result = tostring(customDimensions.Result)
| summarize 
    Total = count(),
    Success = countif(Result == "Success"),
    Failure = countif(Result == "Failure")
    by bin(timestamp, 5m)
| extend SuccessRate = (Success * 100.0) / Total
| render timechart
```

**API Throttling Events**:
```kql
traces
| where message contains "throttle" or message contains "429"
| extend InstanceId = cloud_RoleInstance
| summarize ThrottleCount = count() by InstanceId, bin(timestamp, 5m)
| render timechart
```

### 10.2 Alerting Strategy

#### Critical Alerts

**1. JIT Function Failures (>5% error rate)**
```kql
customEvents
| where name == "JIT_Migration_Completed"
| extend Result = tostring(customDimensions.Result)
| summarize 
    Total = count(),
    Failures = countif(Result == "Failure")
    by bin(timestamp, 5m)
| extend ErrorRate = (Failures * 100.0) / Total
| where ErrorRate > 5.0
```

**2. Migration Stalled (No progress in 30 minutes)**
```kql
traces
| where message contains "RUN SUMMARY"
| summarize LastRun = max(timestamp)
| where LastRun < ago(30m)
```

**3. Key Vault Access Failures**
```kql
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.KEYVAULT"
| where ResultSignature == "Unauthorized"
| summarize FailureCount = count() by bin(TimeGenerated, 5m)
| where FailureCount > 3
```

---
