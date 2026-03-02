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
   - [5.1 Export — Master/Worker Architecture](#51-export--masterworker-architecture)
   - [5.2 Bulk Import Architecture](#52-bulk-import-architecture)
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

- **Bulk Export/Import**: Migrate users with parallel processing (validated with 200k users locally)
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
| Migrating from B2C to External ID | ✅ Primary use case |
| Local development & testing | ✅ Fully validated |
| Proof of concept (< 200K users) | ✅ Sample tested with 181K users |
| Production with SFI requirements | ⚠️ Wait for future release or implement security hardening |
| User count > 1M | ⚠️ Use architecture guidance, requires scaling |

---

## 2. System Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Subscription                           │
│                                                                 │
│  ┌──────────────────────────┐  ┌──────────────┐               │
│  │ Console App              │  │Azure Function│               │
│  │(Harvest/WorkerExport/    │  │(JIT Auth)    │               │
│  │ Import/PhoneRegistration)│  │              │               │
│  └──────┬───────────────────┘  └──────┬───────┘               │
│         │                             │                        │
│  ┌──────▼─────────────────────────────▼───────────────┐       │
│  │                 Shared Core Library                 │       │
│  │   (Services, Models, Orchestrators, Abstractions)   │       │
│  └──────┬───────────┬───────────┬──────────┬──────────┘       │
│         │           │           │          │                   │
│         ▼           ▼           ▼          ▼                   │
│  ┌──────────┐ ┌─────────┐ ┌─────────┐ ┌──────────┐           │
│  │ Blob     │ │Key Vault│ │App      │ │ Storage  │           │
│  │ Storage  │ │         │ │ Insights│ │ Queue    │           │
│  │          │ │*Future  │ │         │ │          │           │
│  └──────────┘ └─────────┘ └─────────┘ └──────────┘           │
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

#### Phase 1a: Harvest (Master/Producer)
```
B2C Tenant → Graph API ($select=id only) → HarvestOrchestrator → Queue: user-ids-to-process
```

#### Phase 1b: Worker Export (Consumer × N)
```
Queue: user-ids-to-process → WorkerExportOrchestrator → Graph $batch → Blob Storage (JSON files)
```

> For small tenants the classic single-instance `export` command is also available and combines both phases.

#### Phase 2a: Bulk Import
```
Blob Storage → JSON Files → ImportOrchestrator → Graph API ($batch) → External ID Tenant
                                               ↓ (opt-in)
                                    Queue: phone-registration
```

#### Phase 2b: Phone Registration (async worker)
```
Queue: phone-registration → PhoneRegistrationWorker → POST /users/{upn}/authentication/phoneMethods → External ID
```

The phone registration worker runs independently from import, consuming the queue at a configurable throttle-safe rate (`ThrottleDelayMs`) to stay within the lower API budget of the `/authentication/phoneMethods` endpoint.

#### Phase 3: JIT Migration (First Login)
```
User Login → External ID → Custom Extension → JIT Function → B2C ROPC Validation
          ↓
External ID sets password + marks migrated → Complete authentication
```

Because MFA phone numbers are already registered (Phase 2b), users are only prompted to **confirm** their existing phone (receive an SMS code), not perform a full re-registration.

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
- **Checkpoint/Resume**: Export/Import can restart from last successful batch
- **Circuit Breaker**: Automatic backoff on API throttling (HTTP 429)

### 3.5 Scalability

- **Multi-App Parallelization**: Use 3-5 app registrations to multiply throughput
- **Stateless Design**: Horizontal scaling without shared state
- **Batching**: Efficient Graph API batch requests (50-100 users per call)

---

## 4. Component Architecture

### 4.1 Core Library Structure

```
B2CMigrationKit.Core/
├── Abstractions/
│   ├── IOrchestrator.cs              # Coordinates multi-step workflows
│   ├── IGraphClient.cs               # Graph API operations (CRUD users)
│   ├── IBlobStorageClient.cs         # Export/import file storage
│   ├── IAuthenticationService.cs     # B2C ROPC validation
│   ├── ISecretProvider.cs            # Key Vault integration
│   └── ITelemetryService.cs          # Custom metrics/events
├── Configuration/
│   ├── MigrationOptions.cs           # Root configuration binding
│   ├── B2COptions.cs                 # B2C tenant configuration
│   ├── ExternalIdOptions.cs          # External ID configuration
│   ├── JitAuthenticationOptions.cs   # JIT function settings
│   ├── StorageOptions.cs             # Blob storage configuration
│   └── RetryOptions.cs               # Throttling/backoff settings
├── Models/
│   ├── UserProfile.cs                # Unified user model
│   ├── ExportResult.cs               # Export operation outcome
│   ├── ImportResult.cs               # Import operation outcome
│   ├── JitAuthenticationRequest.cs   # JIT payload from External ID
│   └── JitAuthenticationResponse.cs  # JIT response to External ID
├── Services/
│   ├── Orchestrators/
│   │   ├── ExportOrchestrator.cs     # Bulk export workflow
│   │   ├── ImportOrchestrator.cs     # Bulk import workflow
│   │   └── JitMigrationService.cs    # JIT validation logic
│   ├── Graph/
│   │   ├── B2CGraphClient.cs         # B2C-specific operations
│   │   └── ExternalIdGraphClient.cs  # External ID operations
│   ├── Storage/
│   │   └── BlobStorageClient.cs      # Azure Blob operations
│   ├── Authentication/
│   │   ├── AuthenticationService.cs  # B2C ROPC implementation
│   │   └── RsaKeyProvider.cs         # JIT RSA key management
│   └── Observability/
│       └── TelemetryService.cs       # Application Insights wrapper
└── Extensions/
    ├── ServiceCollectionExtensions.cs # DI registration
    └── RetryPolicyExtensions.cs       # Polly retry policies
```

### 4.2 Dependency Injection Pattern

All services use **constructor injection** with interface-based abstractions:

```csharp
// Registration (Console + Function)
services.AddCoreServices(configuration);

// Example service dependencies
public class ImportOrchestrator : IOrchestrator<ImportResult>
{
    private readonly IGraphClient _externalIdClient;
    private readonly IBlobStorageClient _blobClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<ImportOrchestrator> _logger;

    public ImportOrchestrator(
        IGraphClient externalIdClient,
        IBlobStorageClient blobClient,
        ITelemetryService telemetry,
        ILogger<ImportOrchestrator> logger)
    {
        // ...
    }
}
```

---

## 5. Bulk Migration Components

### 5.1 Export — Master/Worker Architecture

**Purpose**: Extract all user profiles from B2C into JSON files for bulk import. For large tenants the **Master/Worker (Producer/Consumer) pattern** is recommended to overcome per-app-registration Graph API throttle limits.

#### Architecture Overview

```
┌──────────────────────────────────────────────────────────────────┐
│  MASTER  — HarvestOrchestrator                                  │
│  GET /users?$select=id&$top=999 (IDs only, very cheap)           │
│  → enqueues batches of 20 IDs to Queue: user-ids-to-process      │
└────────────────────────────┬─────────────────────────────────────┘
                             │ Azure Queue Storage
           ┌─────────────────┼─────────────────┐
           ▼                 ▼                 ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ WORKER 1         │ │ WORKER 2         │ │ WORKER N         │
│ WorkerExport     │ │ WorkerExport     │ │ WorkerExport     │
│ App Reg 1        │ │ App Reg 2        │ │ App Reg N        │
│ $batch(20 users) │ │ $batch(20 users) │ │ $batch(20 users) │
│ → Blob: users_*  │ │ → Blob: users_*  │ │ → Blob: users_*  │
└──────────────────┘ └──────────────────┘ └──────────────────┘
```

Each worker uses a **separate app registration** on a separate machine/IP so their API quotas are fully independent. A harvested message is invisible to other workers while being processed (visibility timeout), and only deleted after a successful blob upload — ensuring at-least-once delivery.

#### Key Features

- **Harvest phase**: Pages B2C using only `$select=id` — ~10× cheaper than full profile fetch
- **Worker phase**: Each worker dequeues up to a full batch of 20 IDs and resolves them via `POST /$batch`
- **Single-instance fallback**: The `export` command combines both phases in one process for small tenants
- **Resume support**: Workers restart by re-processing any message that returned to the queue after a crash
- **Throttling control**: Exponential backoff on HTTP 429 via Polly resilience pipeline

#### Process Flow (Master/Producer)

```
┌──────────────────────────┐
│ 1. Initialize Harvest    │
│    - Ensure queue exists │
└────────────┬─────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 2. Page B2C Users ($select=id only, PageSize=999)               │
│    GET /users?$top=999&$select=id                                │
│    - Process continuation tokens                                 │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 3. Enqueue Batches of 20 IDs                                     │
│    SendMessage(queue, "[\"id1\",\"id2\",...\"id20\"]")            │
└──────────────────────────────────────────────────────────────────┘
```

#### Process Flow (Worker/Consumer)

```
┌──────────────────────────────────────────────────────────────────┐
│ 1. Dequeue Message (20 IDs) with visibility timeout             │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 2. Fetch Full Profiles via Graph $batch                          │
│    POST /v1.0/$batch (up to 20 GET /users/{id} in one call)      │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 3. Write to Blob Storage (users_{prefix}{counter:D6}.json)       │
│    - Atomic write with retry                                     │
└────────────┬─────────────────────────────────────────────────────┘
             │
             ▼
┌──────────────────────────────────────────────────────────────────┐
│ 4. Delete message from queue (ACK)                               │
└──────────────────────────────────────────────────────────────────┘
```

#### Multi-App Parallelization Strategy

Run **N workers simultaneously**, each with its own app registration and (ideally) its own IP:

```
┌──────────────────┐
│ Worker 1         │  App Registration 1 — ~60 reads/sec
│ appsettings.app1 │
└──────────────────┘
        +
┌──────────────────┐
│ Worker 2         │  App Registration 2 — ~60 reads/sec
│ appsettings.app2 │
└──────────────────┘
        +
┌──────────────────┐
│ Worker 3         │  App Registration 3 — ~60 reads/sec
│ appsettings.app3 │
└──────────────────┘
        =
  ~180 reads/sec combined
```

#### Security Measures

- **Service Principal**: `Directory.Read.All` (application permission) in B2C
- **Credential Storage**: Client secret in Azure Key Vault
- **Network**: Private endpoint to Blob Storage and Queue Storage
- **Data Protection**: Exported files encrypted at rest (Azure Storage SSE)

### 5.2 Bulk Import Architecture

**Purpose**: Create all users in External ID tenant from exported JSON files, and optionally enqueue MFA phone-registration tasks for asynchronous processing.

#### Key Features

- **Chunked Reading**: Stream large JSON files without loading entire file in memory
- **Batch Requests**: Combine up to 20 user creations in a single Graph `$batch` call
- **UPN Domain Transformation**: Replace B2C domain with External ID domain (reversed during JIT)
- **Extended Attributes**: Set `B2CObjectId` and `RequiresMigration` custom attributes
- **Placeholder Passwords**: Generate random strong passwords (users cannot login until JIT)
- **Phone Registration Enqueue** *(opt-in)*: After each batch succeeds, enqueue `{ upn, mobilePhone }` to the `phone-registration` queue for each user that has a `mobilePhone` value. Set `Import.PhoneRegistration.EnqueuePhoneRegistration: true` to enable.
- **Verification**: Post-import user count validation

#### Process Flow

```
┌─────────────────────────────────────────────────────────────────┐
│ 1. Read Export Files from Blob Storage                          │
│    - List all users_*.json files                                │
│    - Process sequentially or in parallel                        │
└────────────┬────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 2. Parse JSON & Prepare Users                                   │
│    - Read 50-100 users per batch                                │
│    - Generate random password (16 chars, complex)               │
│    - Set forceChangePasswordNextSignIn = true                   │
└────────────┬────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 3. Transform UPN for External ID Compatibility                  │
│    - Replace B2C domain with External ID domain                 │
│    - Example: user@b2ctenant.onmicrosoft.com →                  │
│               user@externalidtenant.onmicrosoft.com             │
│    - Preserve local-part (username remains same)                │
│    - Update both UserPrincipalName and Identities               │
└────────────┬────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 4. Set Custom Attributes                                        │
│    - extension_{ExtensionAppId}_B2CObjectId = <B2C GUID>        │
│    - extension_{ExtensionAppId}_RequiresMigration = true        │
│    (true because password NOT yet migrated)                     │
└────────────┬────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 5. Create Users via Graph API (Batch Request)                   │
│    POST /v1.0/$batch                                             │
│    {                                                             │
│      "requests": [                                               │
│        { "method": "POST", "url": "/users", "body": {...} },    │
│        ...                                                       │
│      ]                                                           │
│    }                                                             │
└────────────┬────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 6. Handle Responses & Retry Failures                            │
│    - Success: Log user created                                  │
│    - Failure: Log error + retry with exponential backoff        │
│    - Collect failures for manual review                         │
└────────────┬────────────────────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────────────────────────────────┐
│ 7. Post-Import Verification                                     │
│    - Query External ID: Total user count                        │
│    - Compare with B2C export count                              │
│    - Report discrepancies                                       │
└─────────────────────────────────────────────────────────────────┘
```

#### Multi-App Parallelization Strategy

Similar to export, use **3-5 app registrations** to boost throughput:

```
┌──────────────────┐
│ Import Instance 1│  App Registration 1
│ Files: 1-50      │  ~60 writes/sec
└──────────────────┘
        +
┌──────────────────┐
│ Import Instance 2│  App Registration 2
│ Files: 51-100    │  ~60 writes/sec
└──────────────────┘
        +
┌──────────────────┐
│ Import Instance 3│  App Registration 3
│ Files: 101-150   │  ~60 writes/sec
└──────────────────┘
        =
  ~180 writes/sec combined
```

**Critical**: Each instance must run on **different IP addresses** to avoid IP-level throttling (see [Section 8.2](#82-multi-instance-scaling-architecture)).

#### Security Measures

- **Service Principal**: `User.ReadWrite.All` (application permission) in External ID
- **Credential Storage**: Client secret in Azure Key Vault
- **Network**: Private endpoint to Blob Storage and Key Vault
- **Audit Logging**: All user creations logged to Application Insights

---

### 5.3 Phone Registration Worker

**Purpose**: Register each migrated user's MFA phone number in Entra External ID as a `phoneAuthenticationMethod` entry, so that on first JIT login the user is only asked to **confirm** their existing phone (SMS code), not perform a full re-registration.

#### Why a Separate Async Worker?

The Graph endpoint `POST /users/{id}/authentication/phoneMethods` has a significantly lower throttle budget than the main `/users` endpoints. Calling it inline during import would:

- Stall the import pipeline waiting for each call to complete
- Rapidly exhaust the per-tenant quota, triggering 429 errors
- Make overall import throughput unpredictable

Instead, `ImportOrchestrator` **enqueues** `{ upn, phoneNumber }` messages after each batch — a near-zero-cost queue write — and a dedicated `PhoneRegistrationWorker` drains the queue at a controlled, configurable rate.

#### Architecture

```
Import ──► Queue: phone-registration ──► PhoneRegistrationWorker
 (enqueue { upn, phone })                 (ThrottleDelayMs between calls)
                                          POST /users/{upn}/authentication/phoneMethods
                                          409 Conflict → treated as success (idempotent)
                                          Failure → message stays in queue (retry via visibility timeout)
```

#### Throttle Strategy

| Setting | Default | Notes |
|---|---|---|
| `ThrottleDelayMs` | 1200 ms | ~50 calls/min — well below typical tenant limit |
| `MessageVisibilityTimeoutSeconds` | 120 s | If processing fails, message re-appears after this delay |
| `MaxEmptyPolls` | 3 | Worker exits after 3 consecutive empty polls (for CLI use) |
| `EmptyQueuePollDelayMs` | 5000 ms | Wait before re-polling when queue is empty |

Multiple `PhoneRegistrationWorker` instances can run in parallel with different app registrations to increase throughput proportionally.

#### User Experience Result

| Scenario | First JIT login experience |
|---|---|
| Phone registered (this worker ran) | "Confirm your identity" → SMS to existing number |
| Phone not registered (worker not run yet, or `mobilePhone` was null) | "Register an MFA method" → full re-registration |

#### Required Permissions

The External ID app registration used by the `PhoneRegistrationWorker` needs:

```
UserAuthenticationMethod.ReadWrite.All  (Application permission)
```

This is in addition to the standard `User.ReadWrite.All` already required for import.

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
│  │ │ PE: Blob   │  │ PE: Key    │  │ PE: Queue  │          │  │
│  │ │ Storage    │  │ Vault      │  │            │          │  │
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
│ ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│ │ Key Vault    │  │ Blob Storage │  │ Queue        │      │
│ │ Role:        │  │ Role:        │  │ Role:        │      │
│ │ Get Secret   │  │ Blob Data    │  │ Queue Data   │      │
│ │              │  │ Contributor  │  │ Contributor  │      │
│ └──────────────┘  └──────────────┘  └──────────────┘      │
└────────────────────────────────────────────────────────────┘
```

#### Service Principal Permissions

**B2C App Registration** (for export and JIT ROPC):
- `Directory.Read.All` (application permission)
- NO write permissions to B2C

**External ID App Registration** (for import and JIT updates):
- `User.ReadWrite.All` (application permission)
- Restricted to specific user properties (no global admin rights)

### 7.3 Data Protection

#### Encryption at Rest

- **Blob Storage**: Azure Storage Service Encryption (SSE) with Microsoft-managed keys
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
  --name migration-import-1 \
  --image migrationkit:latest \
  --vnet my-vnet --subnet subnet-1 \
  --environment-variables APPSETTINGS_PATH=appsettings.app1.json
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
│  │ │ PE: Key    │  │ PE: Blob   │  │ PE: Queue  │    │    │
│  │ │ Vault      │  │ Storage    │  │            │    │    │
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
// Export progress (last 24 hours)
traces
| where message contains "RUN SUMMARY"
| where message contains "Export"
| extend TotalUsers = toint(extract("Total: ([0-9]+)", 1, message))
| extend SuccessCount = toint(extract("Success: ([0-9]+)", 1, message))
| extend FailureCount = toint(extract("Failed: ([0-9]+)", 1, message))
| summarize 
    TotalExported = sum(SuccessCount),
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

**2. Import/Export Stalled (No progress in 30 minutes)**
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
