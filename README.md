# Azure AD B2C to Entra External ID Migration Kit

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![.NET](https://img.shields.io/badge/.NET-8.0-blue.svg)](https://dotnet.microsoft.com/download)
[![PowerShell](https://img.shields.io/badge/PowerShell-7.0+-blue.svg)](https://github.com/PowerShell/PowerShell)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](CONTRIBUTING.md)

> **⚠️ PREVIEW/SAMPLE STATUS**  
> This is a **sample implementation** showcasing the [Just-In-Time password migration public preview](https://learn.microsoft.com/entra/external-id/customers/how-to-migrate-passwords-just-in-time). **NOT PRODUCTION-READY**. See [roadmap](#-next-steps-and-future-enhancements) for planned features.

A toolkit for migrating users from Azure AD B2C to Microsoft Entra External ID with minimal downtime and seamless password migration through Just-In-Time (JIT) authentication.

## 🎯 Overview

This migration kit provides a sample solution for identity migration with:

- ✅ **Two Bulk Migration Modes** — choose the right complexity for your scenario
- ✅ **Just-In-Time (JIT) Password Migration** — seamless password migration on user's first login

### Choose Your Migration Mode

| | **Mode A: Simple Export/Import** | **Mode B: Queue-based Workers** |
|---|---|---|
| **Commands** | `export` → `import` | `harvest` → `worker-migrate` + `phone-registration` |
| **Best for** | < 50K users, no MFA phones | Large tenants, MFA phone migration |
| **Azure infra** | Blob Storage only | Blob + Queue + Table Storage |
| **Parallelism** | Single process | N workers in parallel |
| **MFA phones** | ❌ Not supported | ✅ Throttled phone registration |
| **Complexity** | Low — 2 sequential commands | Medium — 3 commands, parallel workers |

## 🏗️ Architecture

**Key Components:**

1. **B2CMigrationKit.Console** — CLI tool with 5 bulk migration commands (export, import, harvest, worker-migrate, phone-registration)
2. **B2CMigrationKit.Function** — Azure Function for JIT password migration
3. **B2CMigrationKit.Core** — Shared business logic and services

### Mode A: Simple Export/Import

```mermaid
graph LR
    B2C[(Azure AD B2C)] -->|Page users| Export[1. export]
    Export -->|JSON files| Blob[(Blob Storage)]
    Blob -->|Read users| Import[2. import]
    Import -->|Create users| ExtID[(Entra External ID)]

    style Export fill:#0078d4,color:#fff
    style Import fill:#0078d4,color:#fff
```

### Mode B: Queue-based Workers

```mermaid
graph TB
    subgraph "Step 1: Harvest"
        B2C[(Azure AD B2C<br/>Source Tenant)]
        Harvest[1. harvest<br/>Enqueue user IDs]
        Queue1[(Azure Queue<br/>user-ids-to-process)]

        B2C -->|Page IDs only| Harvest
        Harvest -->|Batches of IDs| Queue1
    end

    subgraph "Step 2: Worker Migrate + Phone Registration"
        Worker[2a. worker-migrate × N<br/>Fetch profiles + create users]
        ExtID[(Entra External ID<br/>Target Tenant)]
        Queue2[(Azure Queue<br/>phone-registration)]
        PhoneWorker[2b. phone-registration × N<br/>Register MFA phones — throttled]
        AuditTable[(Azure Table<br/>migrationAudit)]

        Queue1 -->|Dequeue ID batch| Worker
        Worker -->|Fetch full profile| B2C
        Worker -->|Create user| ExtID
        Worker -->|Enqueue phone task| Queue2
        Worker -->|Audit record| AuditTable
        Queue2 -->|Dequeue phone task| PhoneWorker
        PhoneWorker -->|GET /authentication/phoneMethods| B2C
        PhoneWorker -->|POST /authentication/phoneMethods| ExtID
        PhoneWorker -->|Audit record| AuditTable
    end

    subgraph "Step 3: JIT Password Migration"
        User[User Login]
        ExtIDLogin[External ID<br/>Sign-In Policy]
        JIT[3. JIT Function<br/>HTTP Trigger]

        User -->|First login attempt| ExtIDLogin
        ExtIDLogin -->|Call with credentials| JIT
        JIT -->|Validate credentials via ROPC| B2C
        JIT -->|Return MigratePassword action| ExtIDLogin
    end

    style Harvest fill:#0078d4,color:#fff
    style Worker fill:#0078d4,color:#fff
    style PhoneWorker fill:#0078d4,color:#fff
    style JIT fill:#107c10,color:#fff
```

---

## 🔑 Key Features

### ✅ Currently Available

- **Mode A: Export/Import** — Simple two-step bulk migration via Blob Storage; ideal for smaller tenants without MFA phone migration needs
- **Mode B: Harvest + Worker Migrate** — Harvest phase enqueues user IDs; N parallel worker-migrate instances fetch full B2C profiles and create users directly in EEID (tested in local dev with up to ~23K users; throughput bounded by the B2C tenant's default 200 RPS Graph API limit)
- **Async Phone Registration** (Mode B) — MFA phone numbers fetched from B2C and registered in EEID at a throttle-safe rate (default 400 ms delay per app registration)
- **Audit Trail** — Every user operation (Created, Duplicate, Failed, PhoneRegistered, PhoneSkipped) written to Azure Table Storage (`migrationAudit`)
- **JIT Password Migration** via Custom Authentication Extension
- **UPN Domain Transformation** preserving local-part identifiers as a workaround to enable [sign-in alias](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-sign-in-alias) functionality
- **Built-in Retry Logic** with exponential backoff
- **Structured Logging** with optional Application Insights telemetry (requires a connection string; untested outside local development)
- **Local Development Mode** using Azurite emulator (no Azure resources)
  
> **⚠️ PREVIEW/SAMPLE STATUS**: This toolkit is currently a **sample implementation** to showcase how to implement the [Just-In-Time password migration public preview](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-migrate-passwords-just-in-time?tabs=graph) for bulk migration and JIT password migration. Production-ready features including full SFI compliance (Private Endpoints, VNet integration, automated infrastructure deployment) are planned for future releases. 

## 📚 Documentation

This migration kit includes two comprehensive guides:

### [Architecture Guide](docs/ARCHITECTURE_GUIDE.md)
Complete architectural overview for solutions architects, technical leads, and security reviewers:
- Executive summary and system design
- Component architecture (Harvest, Worker-Migrate, Phone-Registration, JIT)
- Security architecture and compliance patterns
- Scalability, performance benchmarks, and multi-instance deployments
- Deployment topologies and operational considerations
- Cost optimization strategies

**Target Audience:** Solutions Architects, Technical Leads, Security Reviewers

### [Developer Guide](docs/DEVELOPER_GUIDE.md)
Complete technical reference for developers implementing and operating the migration:
- Project structure and configuration guide
- Development workflow and local setup
- JIT (Just-In-Time) migration implementation with RSA keys and Custom Authentication Extensions
- Attribute mapping configuration and UPN transformation
- Import audit logs for compliance tracking
- Scaling for high-volume migrations (>100K users)
- Operations, logging, and troubleshooting
- Security best practices and deployment procedures

**Target Audience:** Developers, DevOps Engineers, Operations Teams

## 🚀 Next Steps and Future Enhancements

This repository currently focuses on exemplifying the implementation of the [Just-In-Time password migration public preview](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-migrate-passwords-just-in-time?tabs=graph). Future enhancements will include:

- **Automated Infrastructure Deployment**: Alignment with Secure Future Initiative (SFI) standards through automated deployment templates (Bicep/Terraform)
- **Production-Ready Security**: Full integration with Private Endpoints, VNet integration, and Managed Identity

These features are planned for upcoming releases to provide a complete enterprise-grade migration solution.

## 📊 Telemetry

This project uses Application Insights to collect telemetry data for monitoring and diagnostics. Telemetry collection is optional and can be controlled via configuration:

- To **enable telemetry**: Set `Telemetry:Enabled` to `true` and provide an Application Insights connection string in `appsettings.json`
- To **disable telemetry**: Set `Telemetry:Enabled` to `false` in your configuration

For local development, telemetry is disabled by default. See the [Developer Guide](docs/DEVELOPER_GUIDE.md#telemetry-configuration) for detailed configuration options.

**Privacy Note**: When telemetry is enabled, Microsoft may collect information about your use of the software. The data collected helps improve the quality and reliability of the software. For more information about Microsoft's privacy practices, please see the [Microsoft Privacy Statement](https://privacy.microsoft.com/privacystatement).

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guide](CONTRIBUTING.md) for details on:
- How to set up your development environment
- Coding standards and best practices
- Submitting pull requests
- Reporting issues

## 🔒 Security

Security is a top priority. If you discover a security vulnerability, please follow our [Security Policy](SECURITY.md) for responsible disclosure.

## 💬 Support

For questions, issues, or discussions, please see our [Support Guide](SUPPORT.md).

## Code of Conduct

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## ™️ Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party's policies.



