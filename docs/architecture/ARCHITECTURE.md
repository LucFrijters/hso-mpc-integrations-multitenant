# HSO Partner Center Insights Analytics / Queries & Partner Security Score Integration

## Architecture Design Document

| Attribute       | Value                                           |
|-----------------|-------------------------------------------------|
| Author          | Luc Frijters                                    |
| Status          | Draft                                           |
| Version         | 2.5                                             |
| Last Updated    | 2026-06-19                                      |
| Classification  | Internal — Confidential                         |

---

> **Revision 2.0 — scope correction (2026-06-18).** Validation found that the v1.0 implementation collected the Partner Center *commerce* REST API (`/v1/customers`, `/v1/orders`, …) rather than the **Partner Center Insights programmatic analytics API** (datasets & queries) named in the objective. v2.0 corrects this:
>
> - **Insights programmatic API** (`/insights/v1/mpn/…`): enumerate all datasets and queries, then ensure scheduled reports and download the latest completed execution per dataset. Report files arrive as **CSV/TSV and are converted to JSON** before storage.
> - **Partner-global topology.** The Insights API and the Partner Security Score are both partner-level. They are collected **once from the HSO Production Partner Center**, not iterated per CSP customer tenant. Per-customer detail comes from inside the data (`CustomersAndTenants` rows; security-score `customerInsights`). The previous per-customer fan-out is removed — this is the principal efficiency gain.
> - **Security Score corrected**: added `customerInsights`; removed `securityAlerts` (not a documented method of the partner security namespace).
> - **Cadence**: Insights report freshness is dataset-driven. Each scheduled report uses the dataset's `minimumRecurrenceInterval`, clamped to Partner Center's 4..2160 hour bounds.
> - **Full-cycle collection**: scheduled reports are created once and reused, but the latest completed execution is downloaded and stored on every collection cycle.

> **Revision 2.1 — runtime to PowerShell 7.6 (2026-06-18).** The worker targets **PowerShell 7.6**, which on Azure Functions is currently **preview, Windows-only, and requires .NET 10**. PowerShell 7.4 is GA until **2026-11-10**, and 7.5 isn't offered on Functions, so 7.6 is the only forward version. Implications: the app must run on a **Windows** plan (the EP1 plan here is Windows, `reserved: false`); **Linux Consumption and Flex Consumption are not available on 7.6**. The runtime version is a Bicep parameter (`powerShellVersion`, default `7.6`, allowed `7.6`/`7.4`) so any environment can pin to `7.4` until 7.6 reaches GA. CI PowerShell jobs run on `windows-latest` to match the runtime.

> **Revision 2.2 — Secure Application Model alignment (2026-06-19).** Partner Insights uses the Microsoft Partner Center Secure Application Model App+User flow (`AppPlusUser`) using the delegated `https://api.partnercenter.microsoft.com/user_impersonation` scope. Refresh tokens are captured interactively with MFA, stored as Key Vault secrets named `refresh-token-{tenantId}`, rotated on redemption, and validated on Partner Center requests with `ValidateMfa: true` / `isMfaCompliant` where returned. Microsoft Graph Partner Security Score supports both delegated and application `PartnerSecurity.Read.All`; this implementation uses application permission by default, with the Partner Center service-principal authorization noted in §6.2.

> **Revision 2.3 — no VNet dependency / local Key Vault development (2026-06-19).** Function App VNet integration and private endpoints were removed. Key Vault and storage now use public Azure service endpoints with Microsoft Entra ID / RBAC authorization, which allows the local Functions host to use the main deployed Key Vault without VPN/private DNS. `scripts/Initialize-LocalDevelopment.ps1` configures local settings, can enable public Key Vault access, and can grant the signed-in developer the required Key Vault data-plane roles.

> **Revision 2.4 — production readiness hardening (2026-06-19).** CI/CD packaging now stages the Function App and excludes `local.settings.json` and editor-only folders before producing `function-app.zip`; resource-group naming is consistent across scripts and workflows; alert notification email is a Bicep parameter (`alertEmailAddress` / `ALERT_EMAIL_ADDRESS`); Application Insights local auth remains disabled and the Function App sets `APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`; `.gitattributes` pins source/config files to LF line endings.

> **Revision 2.5 — Partner Insights conformance hardening (2026-06-19).** The Insights flow now enforces dataset-driven scheduled-report recurrence, generates only explicit-column custom queries, skips registry system-query entries absent from the partner's dataset catalog, falls back to generated queries when a documented system query no longer matches live `selectableColumns`, reuses only `Active` scheduled reports, treats in-body `statusCode >= 400` envelopes as failures, records redaction/expiry/minimum-recurrence metadata, and skips re-downloading unchanged `executionId` payloads. Polling remains intentional instead of `CallbackUrl` because it avoids a public inbound surface and keeps Durable replay deterministic; execution batching remains an optional future optimization.

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Business Context](#2-business-context)
3. [Architecture Decision: Compute Platform](#3-architecture-decision-compute-platform)
4. [High-Level Architecture](#4-high-level-architecture)
5. [Authentication & Consent Flow Design](#5-authentication--consent-flow-design)
6. [API Permissions — Least Privilege Matrix](#6-api-permissions--least-privilege-matrix)
7. [Data Collection: Partner Insights Programmatic Analytics API](#7-data-collection-partner-insights-programmatic-analytics-api)
8. [Data Collection: Partner Security Score (Graph Beta)](#8-data-collection-partner-security-score-graph-beta)
9. [Blob Storage Layout](#9-blob-storage-layout)
10. [Error Handling, Throttling & Retry Strategy](#10-error-handling-throttling--retry-strategy)
11. [Observability: Logging, Metrics & Alerting](#11-observability-logging-metrics--alerting)
12. [Security Hardening](#12-security-hardening)
13. [Cost Optimization](#13-cost-optimization)
14. [Deployment & CI/CD](#14-deployment--cicd)
15. [Operational Runbook Summary](#15-operational-runbook-summary)
16. [Appendices](#16-appendices)

---

## 1. Executive Summary

This document designs a centralized integration that:

- Runs from the **HSO production tenant** (hub-and-spoke model).
- Uses a **single Microsoft Entra ID application registration** with admin consent and SAM refresh-token consent per partner account.
- Stores **raw JSON responses** in Azure Blob Storage with a structured prefix hierarchy.
- Covers **all Partner Center Insight Datasets and Queries** and **Partner Security Score API** (Microsoft Graph beta).

The solution is designed for **enterprise-grade reliability**, aligned with the **Azure Well-Architected Framework** (Reliability, Security, Cost Optimization, Operational Excellence, Performance Efficiency).

---

## 2. Business Context

### Goals

| Goal                        | Metric                                                       |
|-----------------------------|--------------------------------------------------------------|
| Complete data collection    | 100% of Partner Insights datasets/reports + Security Score endpoints covered |
| Freshness                   | Security Score no older than ~6 hours; Insights report generation follows each dataset's `minimumRecurrenceInterval` |
| Reliability                 | 99.9% successful collection cycles per month                 |
| Security                    | No client secrets; certificate auth, Managed Identity, and Key Vault-stored SAM refresh tokens only |
| Auditability                | Full lineage from API call to blob, with correlation IDs     |

---

## 3. Architecture Decision: Compute Platform

### Options Evaluated

## Decision: **Azure Functions — Windows Elastic Premium (EP1)**

**Trade-offs acknowledged:**

- Durable Functions add orchestration complexity vs. simple timer-triggered functions; however, the fan-out scale justifies this.
- **PowerShell 7.6 is Windows-only** (see Revision 2.1), so **Flex Consumption** and **Linux Consumption** are not available. The design uses a **Windows Elastic Premium EP1** plan; its always-ready instances also remove cold start. If an environment pins back to PowerShell 7.4, Flex Consumption becomes available again as a lower-cost option.
- Container Apps Jobs would be viable if the team prefers Docker-based workflows, but adds container registry management overhead without proportional benefit for this workload.

---

## 4. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       HSO PRODUCTION TENANT                             │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │                    Azure Functions (Durable)                      │   │
│  │  ┌─────────────┐    ┌──────────────────────────────────────────┐ │   │
│  │  │  Timer       │───▶│  Orchestrator: OrchestrateAllTenants    │ │   │
│  │  │  Trigger     │    │                                          │ │   │
│  │  │  (2-hour)    │    │  For each partner account:               │ │   │
│  │  └─────────────┘    │    ┌──────────────────────────────┐      │ │   │
│  │                      │    │ Inline partner collection    │      │ │   │
│  │                      │    │                              │      │ │   │
│  │                      │    │  1. AcquireToken (activity)  │      │ │   │
│  │                      │    │  2. Fan-out per endpoint:    │      │ │   │
│  │                      │    │     ┌───────────────────┐    │      │ │   │
│  │                      │    │     │ CollectInsights   │    │      │ │   │
│  │                      │    │     │ CallGraphBeta     │    │      │ │   │
│  │                      │    │     │ StoreToBlobJSON   │    │      │ │   │
│  │                      │    │     └───────────────────┘    │      │ │   │
│  │                      │    │  3. Fan-in: collect results  │      │ │   │
│  │                      │    └──────────────────────────────┘      │ │   │
│  │                      │                                          │ │   │
│  │                      │  Aggregate results, log summary          │ │   │
│  │                      └──────────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│           │              │                │                              │
│           │ MI           │ MI             │ MI                           │
│           ▼              ▼                ▼                              │
│  ┌──────────────┐ ┌────────────┐ ┌──────────────────┐                  │
│  │ Azure Key    │ │ Azure Blob │ │ Application       │                  │
│  │ Vault        │ │ Storage    │ │ Insights /        │                  │
│  │              │ │ (raw JSON) │ │ Log Analytics     │                  │
│  │ • Certs      │ │            │ │                    │                  │
│  │ • Refresh    │ │ • Per-     │ │ • Distributed     │                  │
│  │   tokens     │ │   partner  │ │   tracing          │                  │
│  │ • Partner    │ │ • Per-     │ │ • Custom metrics  │                  │
│  │   config     │ │   endpoint │ │ • Alerts           │                  │
│  └──────────────┘ │ • Per-     │ └──────────────────┘                  │
│                    │   timestamp│                                        │
│                    └────────────┘                                        │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Multi-Tenant App Registration (Microsoft Entra ID)              │   │
│  │  • AppId: {single-app-id}                                        │   │
│  │  • Certificate credential (no secrets)                           │   │
│  │  • API Permissions: Partner Center + Graph (see §6)              │   │
│  │  • Admin-consented in each partner account                     │   │
│  └──────────────────────────────────────────────────────────────────┘   │
│                                                                         │
│  ┌──────────────────────────────────────────────────────────────────┐   │
│  │  Public Azure service endpoints + Entra ID/RBAC authorization    │   │
│  └──────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────┘
         │                           │
         │  HTTPS (token per partner)│  HTTPS (token per partner)
         ▼                           ▼
┌──────────────────┐   ┌──────────────────────────────┐
│ Partner Insights │   │ Microsoft Graph (beta)        │
│ analytics API    │   │ Partner Security Score        │
│ api.partner      │   │ graph.microsoft.com/beta/     │
│ center.          │   │ security/partner/             │
│ microsoft.com    │   │ securityScore                 │
└──────────────────┘   └──────────────────────────────┘

         ┌ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ┐
           Partner account(s): HSO Production, optional additional accounts
         │  Admin consent + SAM refresh token per App+User account │
          ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
```

### Component Inventory

| Component                        | Azure Service                              | Purpose                                           |
|----------------------------------|--------------------------------------------|----------------------------------------------------|
| Orchestrator                     | Azure Functions (Durable) — Windows EP1 by default | Timer trigger -> fan-out/fan-in across partner accounts |
| Secrets & Certificates           | Azure Key Vault (Premium)                  | Certificate storage, refresh token storage         |
| Raw Data Store                   | Azure Blob Storage (StorageV2)             | JSON response and converted report persistence     |
| Observability                    | Application Insights + Log Analytics       | Distributed tracing, metrics, alerting             |
| Identity                         |              App Registration              | Single app consented in partner account(s)         |
| Runtime Identity                 | System-assigned Managed Identity           | Access to Key Vault, Blob, token acquisition       |
| Tenants Configuration            | Key Vault secrets or App Configuration     | Per-partner tenant metadata, MPN ID, and data-source selection |

---

## 5. Authentication & Consent Flow Design

### 5.1 Multi-Tenant App Registration

Create a **single app registration** in the HSO production tenant configured as **multi-tenant** (`signInAudience: AzureADMultipleOrgs`).

**Registration steps:**

1. In the HSO production tenant's **Microsoft Entra ID** → **App registrations** → **New registration**:
   - Name: `HSO-MPC-Integration-MultiTenant`
   - Supported account types: **Accounts in any organizational directory (Any Microsoft Entra ID tenant — Multitenant)**
    - Redirect URI: `http://localhost:8400/` (or another registered loopback URI used by `Initialize-SecureAppConsent.ps1`)

2. **Credentials**: Upload an X.509 certificate (no client secrets).
   - Generate certificate via Key Vault or internal PKI.
   - Upload the public key (.cer) to the app registration.
   - Store the private key (.pfx) in Azure Key Vault.
   - Set up a Key Vault certificate rotation policy (recommended: 12-month validity, auto-renew at 80%).

3. **API Permissions**: See [§6](#6-api-permissions--least-privilege-matrix) for the full permission matrix.

### 5.2 Admin Consent URL

For each partner account, a **Global Administrator** or **Privileged Role Administrator** of that tenant must navigate to the admin consent URL and grant the configured application permissions:

```
https://login.microsoftonline.com/{partner-tenant-id}/adminconsent
  ?client_id={app-client-id}
  &redirect_uri=https://localhost
  &scope=https://graph.microsoft.com/.default
```

For Partner Center API permissions (which use the resource `https://api.partnercenter.microsoft.com`), ensure the app registration includes the delegated `user_impersonation` permission. The admin-consent URL grants the configured Partner Center permissions; `scripts/Initialize-SecureAppConsent.ps1` then performs the interactive MFA authorization-code flow that creates the reusable refresh token.

```
https://login.microsoftonline.com/{partner-tenant-id}/adminconsent
  ?client_id={app-client-id}
  &redirect_uri=https://localhost
  &scope=https://api.partnercenter.microsoft.com/user_impersonation
```

> **Important**: As of April 1, 2026, all App+User usage of Partner Center APIs enforces MFA. For **app-only** (client_credentials) flows, MFA is not required on the service principal itself, but the admin granting consent must complete MFA.

### 5.3 Per-Partner Token Acquisition at Runtime

For Partner Insights, the Azure Function defaults to the Secure Application Model App+User refresh-token exchange:

```
POST https://login.microsoftonline.com/{partner-tenant-id}/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

client_id={app-client-id}
&scope=https://api.partnercenter.microsoft.com/user_impersonation
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion={signed-jwt-from-certificate}
&grant_type=refresh_token
&refresh_token={key-vault-refresh-token}
```

For app-only surfaces, such as Microsoft Graph Partner Security Score, the function uses `client_credentials` with certificate authentication:

```
POST https://login.microsoftonline.com/{partner-tenant-id}/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

client_id={app-client-id}
&scope=https://api.partnercenter.microsoft.com/.default
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion={signed-jwt-from-certificate}
&grant_type=client_credentials
```

Similarly for Microsoft Graph:

```
POST https://login.microsoftonline.com/{partner-tenant-id}/oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

client_id={app-client-id}
&scope=https://graph.microsoft.com/.default
&client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer
&client_assertion={signed-jwt-from-certificate}
&grant_type=client_credentials
```

### 5.4 Secure Application Model Considerations

The Partner Center API has specific requirements under the **Secure Application Model framework**:

- **App-only authentication** (`client_credentials` grant) is supported for many Partner Center endpoints but **not all**. Some endpoints require **App+User** authentication with a refresh token obtained through the partner consent process.
- For endpoints that require App+User:
  1. Perform a one-time interactive partner consent flow per partner account.
  2. Store the resulting **refresh token** securely in Azure Key Vault.
  3. At runtime, exchange the refresh token for an access token.
  4. Send `ValidateMfa: true` on Partner Center requests and fail if Partner Center returns `isMfaCompliant: false`.
  5. Implement refresh token rotation monitoring (refresh tokens have finite lifetimes and can be revoked).

**Token acquisition strategy by API surface:**

| API Surface                | Auth Flow           | Token Cache Strategy                        |
|---------------------------|---------------------|---------------------------------------------|
| Partner Center (app-only endpoints) | `client_credentials` + JWT assertion | Per-activity invocation (stateless)         |
| Partner Center (app+user endpoints) | Refresh token exchange with `https://api.partnercenter.microsoft.com/user_impersonation` | Refresh token in Key Vault, access token per-invocation |
| Microsoft Graph (beta)     | `client_credentials` + JWT assertion | Per-activity invocation (stateless)         |

### 5.5 Implementation with PowerShell 7 (JWT Client Assertion)

The solution uses **PowerShell 7.6** with a custom JWT client assertion for certificate-based auth (no MSAL dependency):

```powershell
# Build JWT assertion from certificate loaded from Key Vault
$cert = Get-AzKeyVaultCertificate -VaultName $kvName -Name 'regapp-certificate-hso-mpc-integration'
$jwt  = New-ClientAssertionJwt -Certificate $cert.Certificate `
    -ClientId $clientId -TenantId $tenantId

# Acquire token for Partner Center app-only overrides (not the default Insights path)
$body = @{
    client_id             = $clientId
    scope                 = 'https://api.partnercenter.microsoft.com/.default'
    grant_type            = 'client_credentials'
    client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
    client_assertion      = $jwt
}
$tokenResponse = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -Body $body -ContentType 'application/x-www-form-urlencoded'

# Acquire token for Graph (app-only) — same pattern, different scope
$body.scope = 'https://graph.microsoft.com/.default'
$graphToken = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -Body $body -ContentType 'application/x-www-form-urlencoded'
```

For App+User endpoints using stored refresh tokens:

```powershell
$refreshToken = Get-AzKeyVaultSecret -VaultName $kvName `
    -Name "refresh-token-$tenantId" -AsPlainText

$body = @{
    client_id     = $clientId
    grant_type    = 'refresh_token'
    refresh_token = $refreshToken
    scope         = 'https://api.partnercenter.microsoft.com/user_impersonation'
}
$result = Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
    -Body $body -ContentType 'application/x-www-form-urlencoded'

# Store rotated refresh token back to Key Vault if present
if ($result.refresh_token -and $result.refresh_token -ne $refreshToken) {
    Set-AzKeyVaultSecret -VaultName $kvName `
        -Name "refresh-token-$tenantId" `
        -SecretValue (ConvertTo-SecureString $result.refresh_token -AsPlainText -Force)
}
```

### 5.6 Token Caching Architecture

```
┌─────────────────────────────────────────────────────┐
│                 Token Cache Strategy                  │
│                                                       │
│  ┌─────────────────┐    ┌─────────────────────────┐  │
│  │ Activity-local    │    │  Azure Key Vault         │  │
│  │ access tokens     │    │                           │  │
│  │                   │    │  • X.509 Certificate     │  │
│  │  • No persistent  │◄───│  • Refresh tokens        │  │
│  │    token cache    │    │    (per partner account) │  │
│  │  • Per partner ID │    │  • tenants-config JSON   │  │
│  └─────────────────┘    └─────────────────────────┘  │
│                                                       │
│  Token identity: {tenantId}:{resource}:{authMode}       │
│  TTL: Access tokens requested per activity invocation   │
└─────────────────────────────────────────────────────┘
```

---

## 6. API Permissions — Least Privilege Matrix

### 6.1 Partner Center API Permissions

The Partner Center API uses the resource `https://api.partnercenter.microsoft.com` (Enterprise Application ID: `fa3d9a0c-3fb0-42cc-9193-47c7ecd2edbd`).

| Permission Scope                                | Type        | Justification                                                                 |
|--------------------------------------------------|-------------|-------------------------------------------------------------------------------|
| `user_impersonation`                             | Delegated   | Required for Secure Application Model App+User access to Partner Insights     |

> **Note**: Partner Center delegated access is role-sensitive. The user who completes the Secure Application Model flow must have the appropriate Partner Center role and MFA. App-only remains an explicit override only where the Partner Center surface supports it.

### 6.2 Microsoft Graph Permissions (Partner Security Score)

The Partner Security Score API is available under **Microsoft Graph beta** at:

```
GET https://graph.microsoft.com/beta/security/partner/securityScore
```

| Permission                                    | Type        | Justification                                                     |
|-----------------------------------------------|-------------|-------------------------------------------------------------------|
| `PartnerSecurity.Read.All`                    | Application | Read partner security score requirements and history (beta)       |

**Recommended least-privilege set for read-only collection:**

| Resource         | Permission                  | Type        | Grant Via       |
|------------------|-----------------------------|-------------|-----------------|
| Microsoft Graph  | `PartnerSecurity.Read.All`  | Application | Admin consent   |
| Partner Center   | `user_impersonation`        | Delegated   | Partner consent |

> **Operational note**: Microsoft Graph documents both delegated and application `PartnerSecurity.Read.All` for Partner Security Score. Application permission is valid, but the Partner Center backend can still require the app/service principal to be authorized in Partner Center. If app-only calls return backend errors such as `PCFraudEvents`, add the Entra application in Partner Center user management and assign the required Partner Center role, or use a delegated App+User flow with a Partner Center user that already has the required role.

### 6.3 Graph Beta — Partner Security Score Endpoints

| Endpoint                                                              | Method | Description                                          |
|-----------------------------------------------------------------------|--------|------------------------------------------------------|
| `/beta/security/partner/securityScore`                                | GET    | Get the partner security score                       |
| `/beta/security/partner/securityScore/requirements`                   | GET    | List all security requirements and their status      |
| `/beta/security/partner/securityScore/history`                        | GET    | Get the history of the partner security score        |
| `/beta/security/partner/securityScore/customerInsights`               | GET    | Per-CSP-customer security posture (all customers)    |

> **Note**: These are beta endpoints. Microsoft may introduce breaking changes. The integration should be resilient to schema changes (store raw JSON, validate gracefully).

---

## 7. Data Collection: Partner Insights Programmatic Analytics API

### 7.1 Base URL

```
https://api.partnercenter.microsoft.com/insights/v1/mpn/
```

This is the **partner-global** Insights analytics surface (`/mpn/`), distinct from the commerce REST API (`/v1/`). It is asynchronous: data is delivered as scheduled report executions, not as a direct GET response.

The Microsoft Learn [Partner insights reports and data definitions](https://learn.microsoft.com/en-us/partner-center/insights/insights-data-definitions) page is the human-readable schema dictionary for interpreting exported columns. Runtime query generation deliberately uses `/ScheduledDataset.selectableColumns` instead of hard-coded documentation columns, because the docs can change independently from a partner tenant's current entitlement/schema. Each Insights metadata sidecar carries both this data-definitions URL and the system-query reference URL for lineage.

### 7.2 Collection Pattern (per the Microsoft "programmatic access paradigm")

| Step | Call | Purpose |
|------|------|---------|
| 1 | `GET /ScheduledDataset` | Enumerate **all datasets** (tables, selectable columns, metrics, time ranges). Stored as JSON. |
| 2 | `GET /ScheduledQueries` | Enumerate **all queries** (system + user-defined). Stored as JSON. |
| 3 | Store resolved report definitions | Persist the full dataset-to-report plan for auditability before mutation. |
| 4 | `POST /ScheduledQueries` | (Only when needed) create a custom `SELECT <selectableColumns> FROM <dataset>` query → returns `queryId`. `SELECT *` is not valid; datasets without selectable columns are skipped for generated queries. System query IDs are used only when present and compatible with the live dataset schema. Creation responses are stored as JSON. |
| 5 | `POST /ScheduledReport` | Ensure an `Active` scheduled report exists for a `queryId` using the dataset's `minimumRecurrenceInterval` clamped to 4..2160h and a `StartTime` at least 4h in the future → returns `reportId`. Paused/inactive/exhausted reports are recreated. Creation responses are stored as run evidence; the scheduled-report inventory is stored once as current state. |
| 6 | `GET /ScheduledReport/execution/{reportId}?executionStatus=Completed&getLatestExecution=true` | Poll for the latest completed execution → returns `reportAccessSecureLink` (SAS) once ready. Requested reports can take hours; 404/no execution before first completion is treated as "pending", not an error. |
| 7 | Download `reportAccessSecureLink` | Fetch the report file (**CSV/TSV**) and **convert to JSON** before storing, unless the same `executionId` was already stored by a prior run. |

### 7.3 Idempotency & efficiency

- Reports are matched by a deterministic base name (`<prefix><DatasetName>`) and reused only while `reportStatus = Active`; non-active reports are recreated with a timestamped suffix so collection does not stall after recurrence exhaustion or a pause.
- The latest completed execution metadata for each report is stored on every collection cycle. The report payload itself is downloaded only once per `executionId`, using a small blob marker to avoid repeated SAS egress for unchanged daily datasets.
- The Create Report API is asynchronous: a successful `reportId` means the report was requested, not that data is available. Later cycles continue polling until a completed execution returns a secure download link, then the CSV/TSV payload is saved as JSON.
- The scheduled-report inventory is a singleton current-state artifact at `_collection-state/<tenant>/partner-insights-reports/scheduled-reports.json`, overwritten on every run. It is deliberately not written as timestamped run output.
- Registry system-query entries are used only when the corresponding dataset appears in `/ScheduledDataset` and their projected columns are present in live `selectableColumns`; otherwise the collector falls back to a generated explicit-column query for that dataset.
- Every dataset returned by step 1 that is not explicitly registered gets a generated explicit-column report when it publishes `selectableColumns`; column-less datasets are skipped because Partner Center's query grammar has no wildcard projection.

### 7.4 Authentication note

Insights tokens use the Secure Application Model App+User flow (`AppPlusUser`) with the delegated `https://api.partnercenter.microsoft.com/user_impersonation` scope and refresh tokens stored in Key Vault. Partner Center requests send `ValidateMfa: true` and fail if `isMfaCompliant` is returned as `false`. Pagination follows the `nextLink` field on catalog responses.

---

## 8. Data Collection: Partner Security Score (Graph Beta)

### 8.1 Endpoints

| Endpoint                                                  | Description                                     |
|-----------------------------------------------------------|-------------------------------------------------|
| `GET /beta/security/partner/securityScore`                  | Current partner security score (aggregate)      |
| `GET /beta/security/partner/securityScore/requirements`     | Security requirements breakdown                 |
| `GET /beta/security/partner/securityScore/history`          | Historical score trends                         |
| `GET /beta/security/partner/securityScore/customerInsights` | Per-CSP-customer security posture (all customers) |

### 8.2 Expected Response Structure (partnerSecurityScore)

```json
{
  "@odata.context": "https://graph.microsoft.com/beta/$metadata#security/partner/securityScore",
  "id": "...",
  "currentScore": 76.5,
  "maxScore": 100,
  "lastRefreshDateTime": "2026-04-20T10:00:00Z",
  "updatedDateTime": "2026-04-20T10:00:00Z",
  "requirements": [
    {
      "id": "...",
      "requirementType": "mfaEnforcedForAdmins",
      "complianceStatus": "compliant",
      "score": 20,
      "maxScore": 20,
      "actionUrl": "..."
    }
  ]
}
```

### 8.3 Beta API Resilience

Since these are **beta** endpoints:

- **Store raw JSON** without schema validation — schema may change.
- **Log and alert on HTTP 4xx/5xx** but do not fail the entire orchestration.
- **Version-pin the request** (always use `/beta/`, not `$metadata` negotiation).
- **Monitor the Microsoft Graph changelog** for deprecation notices.

---

## 9. Blob Storage Layout

### 9.1 Naming Convention

```
{container}/
  {tenant-display-name}_{tenant-id}/
    {yyyyMMddHH}/
      {data-type}/
        {endpoint-or-dataset-name}_{timestamp-utc}[_{execution-id}].json
        {endpoint-or-dataset-name}_{timestamp-utc}[_{execution-id}]_metadata.json
```

`{data-type}` is one of:

| Data type | Contents |
|-----------|----------|
| `security-score` | Microsoft Graph Partner Security Score endpoints |
| `partner-insights-reports` | Partner Insights catalogs and report execution JSON |

**Concrete example:**

```
mpc-insights-data-raw/
  hso-production_a1b2c3d4-e5f6-7890-abcd-ef1234567890/
    2026042014/
      partner-insights-reports/
        datasets_2026-04-20T14-00-00Z.json
        datasets_2026-04-20T14-00-00Z_metadata.json
        customersandtenants_2026-04-20T14-00-00Z_exec-123.json
        customersandtenants_2026-04-20T14-00-00Z_exec-123_metadata.json
      security-score/
        security-score_2026-04-20T14-00-00Z.json
        security-score_2026-04-20T14-00-00Z_metadata.json
```

### 9.2 Metadata Sidecar File

Each data file is accompanied by a `_metadata.json`:

```json
{
  "correlationId": "f47ac10b-58cc-4372-a567-0e02b2c3d479",
  "tenantId": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "tenantDisplayName": "HSO Production",
  "apiSurface": "partner-insights",
  "endpointCategory": "insights-catalog",
  "endpointName": "datasets",
  "httpMethod": "GET",
  "requestUrl": "https://api.partnercenter.microsoft.com/insights/v1/mpn/ScheduledDataset",
  "httpStatusCode": 200,
  "responseContentLength": 45230,
  "recordCount": 142,
  "pageCount": 2,
  "collectionStartedUtc": "2026-04-20T14:00:02.123Z",
  "collectionCompletedUtc": "2026-04-20T14:00:04.567Z",
  "durationMs": 2444,
  "functionInvocationId": "abc123",
  "orchestrationInstanceId": "def456"
}
```

### 9.3 Immutability Considerations

- Enable **blob versioning** on the storage account for auditability.
- For regulatory compliance, apply a **time-based immutability policy** at the container level with a retention interval matching your compliance requirements (e.g., 90 days).
- Use **legal hold** if litigation hold is needed.
- Enable **soft delete** (14-day retention) for accidental deletion recovery.

### 9.4 Storage Account Configuration

| Setting                    | Value                                   |
|----------------------------|-----------------------------------------|
| Account kind               | StorageV2 (general-purpose v2)          |
| Replication                | LRS (Locally Redundant Storage)         |
| Access tier (default)      | Hot                                     |
| Blob versioning            | Enabled                                 |
| Soft delete (blobs)        | Enabled, 14 days                        |
| Soft delete (containers)   | Enabled, 14 days                        |
| Hierarchical namespace     | Enabled (ADLS Gen2)                     |
| Minimum TLS version        | TLS 1.2                                 |
| Public network access      | Enabled; data access controlled by Entra ID/RBAC |
| Infrastructure encryption  | Enabled (double encryption)             |

---

## 10. Error Handling, Throttling & Retry Strategy

### 10.1 Error Classification

| Category              | HTTP Codes       | Action                                                          |
|-----------------------|------------------|-----------------------------------------------------------------|
| **Success**           | 200, 201, 204    | Store response, log success                                     |
| **Client error**      | 400, 403, 404    | Log error, skip endpoint, do NOT retry (permanent failure)      |
| **Auth failure**       | 401              | Refresh token, retry once; if 401 persists, alert               |
| **Throttling**        | 429              | Respect `Retry-After` header, exponential backoff               |
| **Server error**      | 500, 502, 503    | Retry with exponential backoff (max 3 attempts)                 |
| **Timeout**           | Request timeout  | Retry once with increased timeout                               |

### 10.2 Throttling Strategy (429 Handling)

Microsoft Partner Center and Graph APIs enforce rate limits. A 429 response includes a `Retry-After` header.

**Per-partner throttling approach:**

```
┌──────────────────────────────────────────────────┐
│             Throttling Architecture                │
│                                                    │
│  ┌─────────────┐                                  │
│  │ Orchestrator │                                  │
│  │ (partner loop)│── Partner accounts ───────────▶│
│  └─────────────┘                                  │
│        │                                          │
│        ▼                                          │
│  ┌─────────────────┐                              │
│  │ Activity Func   │                              │
│  │ (per endpoint)  │                              │
│  │                   │                              │
│  │ Retry policy:    │                              │
│  │ • Max 3 attempts │                              │
│  │ • Initial: 2s   │                              │
│  │ • Backoff: 2x   │                              │
│  │ • Max: 60s      │                              │
│  │ • Jitter: ±25%  │                              │
│  │ • 429: honor    │                              │
│  │   Retry-After   │                              │
│  └─────────────────┘                              │
└──────────────────────────────────────────────────┘
```

**Concurrency controls:**

| Level             | Max Concurrency | Rationale                                           |
|-------------------|-----------------|-----------------------------------------------------|
| Partner loop      | 4 configured; current PowerShell path processes partners inline | Partner accounts are few; keeps global API load bounded |
| Endpoint fan-out  | 5 per partner   | Per-partner rate limit safety margin                 |
| Retry attempts    | 3               | Balance between reliability and not amplifying load  |

### 10.3 Retry Policy Configuration (Durable Functions)

Retry is handled inside each activity function using `Invoke-ApiWithRetry` (see `modules/ApiClient.psm1`):

```powershell
# In OrchestrateAllTenants, endpoint fan-out calls:
$task = Invoke-DurableActivity -FunctionName 'CollectSecurityScore' -Input @{
    TenantId        = $tenantId
    AccessToken     = $token
    Endpoint        = $endpoint
    CorrelationId   = $correlationId
}

# Inside the collection activity (CollectSecurityScore / CollectInsights), retry logic:
#  - Max 3 attempts with exponential backoff (2s → 4s → 8s)
#  - 429: honour Retry-After header
#  - 5xx: exponential backoff with ±25% jitter
#  - 401: one token refresh attempt, then fail
```

### 10.4 429-Specific Handling in Activity Functions

```powershell
function Invoke-ApiWithRetry {
    param([string]$Uri, [hashtable]$Headers, [int]$MaxRetries = 3)

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -Headers $Headers -ErrorAction Stop
            return ($response.Content | ConvertFrom-Json)
        }
        catch {
            $statusCode = $_.Exception.Response.StatusCode.value__
            if ($statusCode -eq 429) {
                $retryAfter = $_.Exception.Response.Headers['Retry-After']
                $waitSec = if ($retryAfter) { [int]$retryAfter } else { 30 }
                Write-Warning "429 Throttled on $Uri — waiting ${waitSec}s (attempt $attempt/$MaxRetries)"
                Start-Sleep -Seconds $waitSec
            }
            elseif ($statusCode -ge 500 -and $attempt -lt $MaxRetries) {
                $backoff = [math]::Pow(2, $attempt) * (1 + (Get-Random -Minimum -0.25 -Maximum 0.25))
                Write-Warning "${statusCode} on $Uri — backoff ${backoff}s"
                Start-Sleep -Seconds $backoff
            }
            else { throw }
        }
    }
    throw "Exhausted $MaxRetries retries for $Uri"
}
```

### 10.5 Circuit Breaker Per Partner Account

If a partner account consistently fails (e.g., 5+ consecutive failures across endpoints), the sub-orchestrator should:

1. Log the circuit breaker open event.
2. Skip remaining endpoints for that partner account in the current cycle.
3. Store a failure summary blob.
4. Emit a custom metric for alerting.
5. Resume normal operation on the next scheduled cycle.

---

## 11. Observability: Logging, Metrics & Alerting

### 11.1 Application Insights Configuration

| Setting                         | Value                                |
|---------------------------------|--------------------------------------|
| Resource                        | Application Insights (Workspace-based) |
| Connected to                    | Log Analytics Workspace              |
| Sampling                        | Adaptive sampling, 50% for traces    |
| Connection via                  | Connection string (not instrumentation key) |
| Ingestion auth                  | AAD (`APPLICATIONINSIGHTS_AUTHENTICATION_STRING=Authorization=AAD`) |
| Local auth                      | Disabled on the Application Insights resource |
| Distributed tracing             | Enabled (W3C TraceContext)           |

### 11.2 Structured Logging Taxonomy

All log entries must include these custom dimensions:

| Dimension              | Example                              | Purpose                          |
|------------------------|--------------------------------------|----------------------------------|
| `TenantId`             | `a1b2c3d4-...`                       | Filter by partner account        |
| `TenantDisplayName`    | `HSO Production`                     | Human-readable partner account   |
| `ApiSurface`           | `partner-insights` / `graph-beta`    | Filter by API                    |
| `EndpointCategory`     | `insights-catalog` / `security-score` | Filter by data domain           |
| `EndpointName`         | `datasets` / `security-score`        | Specific endpoint                |
| `CorrelationId`        | `f47ac10b-...`                       | Trace through entire collection  |
| `OrchestrationId`      | `def456`                             | Durable Functions instance ID    |
| `HttpStatusCode`       | `200` / `429`                        | Response status                  |
| `DurationMs`           | `2444`                               | Call latency                     |
| `RecordCount`          | `142`                                | Items returned                   |
| `BlobPath`             | `mpc-insights-data-raw/.../file.json` | Where data was stored            |

### 11.3 Custom Metrics

| Metric Name                          | Type      | Description                                        |
|--------------------------------------|-----------|----------------------------------------------------|
| `collection.partners.total`          | Counter   | Total partner accounts processed per cycle         |
| `collection.partners.succeeded`      | Counter   | Partner accounts successfully collected            |
| `collection.partners.failed`         | Counter   | Partner accounts with failures                     |
| `collection.endpoints.total`         | Counter   | Total endpoint calls per cycle                     |
| `collection.endpoints.succeeded`     | Counter   | Successful endpoint calls                          |
| `collection.endpoints.failed`        | Counter   | Failed endpoint calls                              |
| `collection.endpoints.throttled`     | Counter   | 429 responses received                             |
| `collection.duration.total_ms`       | Histogram | Total orchestration duration                       |
| `collection.duration.per_partner_ms` | Histogram | Per-partner-account collection duration            |
| `collection.blob.bytes_written`      | Counter   | Total bytes written to Blob Storage                |
| `collection.token.acquisition_ms`    | Histogram | Token acquisition latency                          |

### 11.4 Alerting Rules

| Alert                                  | Condition                                                | Severity | Action Group          |
|----------------------------------------|----------------------------------------------------------|----------|-----------------------|
| Collection cycle missed                | No orchestration completion event in 2 hours             | Sev 1    | PagerDuty + Email     |
| Partner account collection failure     | `collection.partners.failed > 0`                         | Sev 2    | Email + Teams channel |
| High throttling rate                   | `collection.endpoints.throttled > 50` per cycle          | Sev 2    | Email + Teams channel |
| Auth failure (401 after retry)         | Any 401 persisting after token refresh                   | Sev 1    | PagerDuty + Email     |
| Refresh token expiring                 | Refresh token TTL < 7 days (custom health check)         | Sev 2    | Email                 |
| Collection duration exceeding SLA      | `collection.duration.total_ms > 3600000` (1 hour)        | Sev 2    | Email                 |
| Blob Storage write failures            | Any Blob write exception                                 | Sev 1    | PagerDuty + Email     |
| Function host health degraded          | Azure Functions host health check failures               | Sev 1    | PagerDuty             |

### 11.5 Dashboard (Azure Workbook)

Create an Azure Monitor Workbook with the following views:

1. **Collection Health Overview**: Success/failure rates across all partner accounts (last 24h, 7d, 30d).
2. **Per-Partner Status Grid**: Color-coded matrix of partner account x endpoint status.
3. **Throttling Heatmap**: 429 rates over time, per API surface.
4. **Duration Trends**: Collection cycle duration trends.
5. **Data Volume**: Blob storage bytes written per partner account, per day.
6. **Token Health**: Token acquisition success rates and latencies.
7. **Error Analysis**: Grouped error categorization with drill-down.

---

## 12. Security Hardening

### 12.1 Network Access Posture

The deployment intentionally avoids VNet integration and private endpoints. This keeps the cloud Function App and local Functions host on the same connectivity model: public Azure service endpoints protected by Microsoft Entra ID, Azure RBAC, TLS 1.2, and resource diagnostics.

| Resource              | Network Config                                              |
|-----------------------|-------------------------------------------------------------|
| Azure Functions       | Public HTTPS endpoint for the Functions host; outbound over Azure public network |
| Azure Key Vault       | Public network access enabled; data-plane access controlled by RBAC |
| Azure Blob Storage    | Public network access enabled; shared key disabled; data-plane access controlled by RBAC |
| Application Insights  | Workspace-based ingestion with local auth disabled          |

For local development, `scripts/Initialize-LocalDevelopment.ps1` can update an existing vault from private-only access to the no-VNet posture. Its default `AllowPublicAuthenticated` mode enables public network access while keeping RBAC as the authorization boundary. `AllowCurrentIpOnly` is available for local-only troubleshooting, but the cloud Function App's outbound IPs must also be allowed if that mode is used in a shared environment.

### 12.2 RBAC Assignments

| Principal                                | Resource            | Role                                        |
|------------------------------------------|---------------------|---------------------------------------------|
| Azure Functions Managed Identity         | Key Vault           | `Key Vault Secrets User`                    |
| Azure Functions Managed Identity         | Key Vault           | `Key Vault Certificate User`               |
| Azure Functions Managed Identity         | Blob Storage        | `Storage Blob Data Contributor`             |
| Azure Functions Managed Identity         | App Insights        | `Monitoring Metrics Publisher`              |
| CI/CD Service Principal                  | Resource Group      | `Contributor`                               |
| HSO Integration Team (Entra Group)       | Resource Group      | `Reader`                                    |
| HSO Integration Team (Entra Group)       | Blob Storage        | `Storage Blob Data Reader`                  |
| HSO Integration Team (Entra Group)       | Key Vault           | `Key Vault Secrets Officer` (break-glass)   |

> **Important**: Do **not** use Storage Account Keys. All access via RBAC + Managed Identity.

### 12.3 Key Vault Usage

| Secret / Certificate            | Purpose                                                   | Rotation                      |
|---------------------------------|-----------------------------------------------------------|-------------------------------|
| `regapp-certificate-hso-mpc-integration` | X.509 cert for multi-tenant app authentication            | Auto-rotate via KV policy, 12mo |
| `refresh-token-{tenantId}`      | Stored refresh tokens for App+User endpoints              | Monitored, re-consent if expired |
| `tenants-config`                | JSON array of enabled partner tenants and `CollectPartnerInsights` / `CollectPartnerSecurityScore` flags | Manual update on partner-account changes |

### 12.4 Additional Security Controls

| Control                              | Implementation                                                    |
|--------------------------------------|-------------------------------------------------------------------|
| Disable storage account key access   | `allowSharedKeyAccess: false`                                     |
| Enforce HTTPS-only                   | `supportsHttpsTrafficOnly: true`                                  |
| Minimum TLS version                  | `minimumTlsVersion: TLS1_2`                                      |
| Diagnostic logging                   | Enable diagnostic settings on all resources → Log Analytics       |
| Managed Identity only                | No service principal passwords in code or config                  |

---

## 13. Cost Optimization

### 13.1 Estimated Monthly Cost (partner-global schedule)

| Component                          | SKU / Config                     | Estimated Monthly Cost (USD) |
|------------------------------------|----------------------------------|------------------------------|
| Azure Functions                    | Windows Elastic Premium EP1      | ~$150                        |
| Azure Functions (optional if pinned to PowerShell 7.4) | Windows Consumption or Flex-compatible redesign | workload-dependent |
| Azure Key Vault                    | Premium (HSM-backed)             | ~$5 + $0.03/10K ops          |
| Azure Blob Storage                 | StorageV2, LRS                  | $20 – $60 (depends on volume)|
| Application Insights               | Workspace-based, pay-per-GB      | $10 – $30                    |
| Log Analytics Workspace            | Pay-per-GB ingestion             | $5 – $15                     |
| **Total (PowerShell 7.6 / EP1)**   |                                  | **~$190 – $290/month**       |

### 13.2 Cost Optimization Techniques

| Technique                                          | Savings                                             |
|----------------------------------------------------|-----------------------------------------------------|
| Pin to PowerShell 7.4 until 7.6 reaches GA          | Opens lower-cost hosting options if preview runtime is not required |
| Application Insights adaptive sampling             | Reduces ingestion cost by 50%+                      |
| Partner-global collection                           | Avoids per-customer fan-out while still collecting the complete partner dataset |

### 13.3 Endpoint Collection Frequency Optimization

Because collection is **partner-global**, volume is driven by *datasets + score endpoints*, not by `customers × endpoints`. Cadence is set by data volatility and API constraints:

| Frequency | Items                                                                                  |
|-----------|----------------------------------------------------------------------------------------|
| Every 6h  | Partner Security Score, requirements, customerInsights                                  |
| Every 4h UTC | Security score history; Insights datasets/queries catalog; latest completed Insights report downloads |

Insights scheduled-report freshness is dataset-driven. The collector reads `minimumRecurrenceInterval` from `/ScheduledDataset` and uses `clamp(max(4, datasetMin), 4, 2160)` for `POST /ScheduledReport`; for example, daily datasets such as `OfficeUsage` are scheduled at 24h rather than forced to 4h. With ~20 datasets + 4 score endpoints collected once at the partner level, a cycle issues on the order of **tens** of API calls — versus the thousands/day implied by the previous per-customer commerce-API fan-out. Each eligible cycle writes catalogs and latest execution metadata; unchanged report payloads are skipped by `executionId` marker to avoid repeated downloads. Operator-triggered `ManualStart` runs set `ForceCollection=true`, bypassing only the scheduled cadence gates; per-partner `CollectPartnerInsights` and `CollectPartnerSecurityScore` flags are still enforced by both the orchestrator and collector activities.

---

## 14. Deployment & CI/CD

### 14.1 Repository Structure

```
hso-mpc-integrations-multitenant/
├── .gitattributes                      # LF line-ending policy
├── .github/
│   └── workflows/
│       ├── ci.yml                        # Build, test, lint
│       └── cd.yml                        # Deploy to Azure Functions
├── docs/
│   └── architecture/
│       └── ARCHITECTURE.md               # This document
├── infra/
│   ├── main.bicep                        # Main infrastructure template
│   ├── modules/
│   │   ├── function-app.bicep
│   │   ├── storage.bicep
│   │   ├── keyvault.bicep
│   │   └── monitoring.bicep
│   └── parameters/
│       ├── dev.bicepparam
│       └── prod.bicepparam
├── src/
│   └── function-app/                        # Azure Functions (PowerShell 7.6, Windows)
│       ├── host.json                         # Durable Functions config
│       ├── local.settings.json               # Environment variables
│       ├── requirements.psd1                 # Az module dependencies
│       ├── profile.ps1                       # Startup — imports shared modules
│       ├── TimerStart/                       # Timer trigger, default every 2 hours
│       │   ├── function.json
│       │   └── run.ps1
│       ├── OrchestrateAllTenants/            # Main orchestrator (partner loop + endpoint fan-out)
│       │   ├── function.json
│       │   └── run.ps1
│       ├── OrchestrateTenant/                # Legacy sub-orchestrator kept for reference
│       │   ├── function.json
│       │   └── run.ps1
│       ├── AcquireToken/                     # Activity: cert-based token
│       │   ├── function.json
│       │   └── run.ps1
│       ├── CollectSecurityScore/             # Activity: one Graph security-score endpoint -> JSON
│       │   ├── function.json
│       │   └── run.ps1
│       ├── CollectInsights/                  # Activity: full Insights async flow -> JSON
│       │   ├── function.json
│       │   └── run.ps1
│       ├── LoadTenantConfig/                 # Activity: read tenants-config KV secret
│       │   ├── function.json
│       │   └── run.ps1
│       ├── LoadEndpointRegistry/             # Activity: import registry
│       │   ├── function.json
│       │   └── run.ps1
│       ├── StoreSummaryBlob/                 # Activity: write summary
│       │   ├── function.json
│       │   └── run.ps1
│       └── modules/                          # Shared PowerShell modules
│           ├── IntegrationConfig.psm1        # Central config, API surfaces, retry, batching
│           ├── TokenService.psm1             # JWT assertion + token acquisition
│           ├── ApiClient.psm1                # Retry/throttle core + Graph pagination
│           ├── InsightsClient.psm1           # Insights async flow + CSV/TSV -> JSON
│           ├── BlobStorageService.psm1       # JSON blob writes (data + metadata sidecars)
│           └── EndpointRegistry.psd1         # Security-score + Insights collection registry
├── tests/                                    # Pester 5 test suites
├── scripts/
│   ├── Deploy.ps1                         # End-to-end manual deployment helper
│   ├── Initialize-LocalDevelopment.ps1    # Local settings + main Key Vault access helper
│   ├── Grant-AdminConsent.ps1            # Admin consent helper
│   ├── Initialize-SecureAppConsent.ps1    # Interactive SAM refresh-token capture
│   ├── Update-RefreshToken.ps1            # Unattended SAM refresh-token renewal safety net
│   ├── Rotate-Certificate.ps1            # Certificate rotation
│   └── Verify-TenantConsent.ps1          # Consent status check
└── README.md
```

### 14.2 Infrastructure as Code

Use **Azure Bicep** for all infrastructure deployment. Key module responsibilities:

| Module                  | Resources Created                                              |
|-------------------------|----------------------------------------------------------------|
| `function-app.bicep`    | Function App, App Service Plan (EP1), System MI                |
| `storage.bicep`         | Storage Account, containers, RBAC-friendly public endpoint |
| `keyvault.bicep`        | Key Vault Premium, RBAC, diagnostics, public authenticated endpoint |
| `monitoring.bicep`      | App Insights, Log Analytics, Alert Rules, Action Groups        |

### 14.3 CI/CD Pipeline (GitHub Actions)

The pipeline is split into two workflows:

- **CI** (`.github/workflows/ci.yml`): Bicep build/validate, PSScriptAnalyzer lint, Pester 5 tests, safe package artifact.
- **CD** (`.github/workflows/cd.yml`): Deploys Bicep infra, then pushes the function app zip package.

```yaml
# Simplified CI structure (see .github/workflows/ci.yml for full version)
name: CI — Validate & Test
on:
  push:
    branches: [main, develop]
jobs:
  lint-powershell:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - shell: pwsh
        run: |
          Install-Module -Name PSScriptAnalyzer -Force -Scope CurrentUser
          Invoke-ScriptAnalyzer -Path ./src/function-app -Recurse -Severity Warning,Error
  test-powershell:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - shell: pwsh
        run: |
          Install-Module -Name Pester -Force -Scope CurrentUser -MinimumVersion 5.0.0
          Invoke-Pester -Path ./tests -CI
  package:
    needs: [lint-powershell, test-powershell]
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - shell: pwsh
        run: |
          # Full workflow stages src/function-app into ./deploy/function-app,
          # excludes local.settings.json and .vscode, then zips staged files.
          Compress-Archive -Path ./deploy/function-app/* -DestinationPath ./deploy/function-app.zip
      - uses: actions/upload-artifact@v4
        with:
          name: function-app-package
          path: ./deploy/function-app.zip
```

The package artifact is intentionally built from staged files instead of directly from `src/function-app/*`. This prevents local-only settings, editor folders, and development state from reaching Azure Functions.

---

## 15. Operational Runbook Summary

### 15.1 Onboarding a New Partner Account

1. Obtain the tenant ID and display name.
2. A Global Admin or Privileged Role Administrator in the partner tenant navigates to the admin consent URL (see §5.2).
3. Perform the Secure Application Model partner consent flow with `scripts/Initialize-SecureAppConsent.ps1` and store the refresh token in Key Vault.
4. Add the partner account to the `tenants-config` Key Vault secret or App Configuration, setting `CollectPartnerInsights` and `CollectPartnerSecurityScore` for the desired data sources.
5. Run `scripts/Verify-TenantConsent.ps1` to confirm permissions, refresh-token exchange, MFA validation, and API access.
6. The next scheduled cycle automatically picks up the new partner account.

#### `tenants-config` examples

Both collection flags default to `true` when omitted. Set them explicitly for clarity when onboarding or changing a tenant.

**Collect both Partner Insights and Partner Security Score**

```json
[
  {
    "TenantId": "<partner-tenant-guid>",
    "DisplayName": "HSO Production",
    "Enabled": true,
    "MpnId": "123456",
    "CollectPartnerInsights": true,
    "CollectPartnerSecurityScore": true
  }
]
```

**Collect only Microsoft Partner Insights**

Use this when the tenant should produce Insights datasets, queries, and report exports, but should not call Microsoft Graph Partner Security Score endpoints.

```json
[
  {
    "TenantId": "<partner-tenant-guid>",
    "DisplayName": "Insights only partner",
    "Enabled": true,
    "MpnId": "123456",
    "CollectPartnerInsights": true,
    "CollectPartnerSecurityScore": false
  }
]
```

**Collect only CSP Partner Security Score**

Use this when only Microsoft Graph Partner Security Score data is required. This tenant does not need a Secure Application Model refresh token unless Partner Insights is later enabled.

```json
[
  {
    "TenantId": "<partner-tenant-guid>",
    "DisplayName": "Security score only partner",
    "Enabled": true,
    "MpnId": "123456",
    "CollectPartnerInsights": false,
    "CollectPartnerSecurityScore": true
  }
]
```

**Mixed tenants in one secret**

```json
[
  {
    "TenantId": "9bc096ab-f225-476e-8e92-260401469868",
    "DisplayName": "HSO Production",
    "Enabled": true,
    "MpnId": "1021608",
    "CollectPartnerInsights": true,
    "CollectPartnerSecurityScore": false
  },
  {
    "TenantId": "HSOTTCSP",
    "DisplayName": "Insights only partner",
    "Enabled": true,
    "MpnId": "234567",
    "CollectPartnerInsights": true,
    "CollectPartnerSecurityScore": false
  }
]
```

Store the JSON in Key Vault:

```powershell
$tenantsConfigJson = Get-Content -Path .\docs\tenants-config.json -Raw
Set-AzKeyVaultSecret `
  -VaultName 'kv-hso-mpc-integration' `
  -Name 'tenants-config' `
  -SecretValue (ConvertTo-SecureString -String $tenantsConfigJson -AsPlainText -Force)
```

### 15.2 Certificate Rotation

1. Key Vault auto-generates a new certificate 20% before expiry (configurable).
2. Upload the new certificate's public key to the multi-tenant app registration.
3. Keep the old certificate active for a grace period (7 days overlap).
4. Remove the old certificate from the app registration.
5. Verify token acquisition works for all 35 tenants.

### 15.3 Refresh Token Re-consent

Full re-consent cannot be automated. The Secure Application Model App+User flow requires an interactive delegated sign-in by a Partner Center user with MFA, so a revoked or expired refresh token cannot be replaced by the Function App, managed identity, CI/CD, or an unattended job.

What can be automated:

1. Keep active refresh tokens alive with `scripts/Update-RefreshToken.ps1` on a scheduled job for tenants where `CollectPartnerInsights=true`.
2. Alert on token redemption failures such as `invalid_grant`, persistent 401, or Partner Center MFA validation failure.
3. Skip refresh-token renewal for tenants where `CollectPartnerInsights=false`; Security Score-only tenants use Microsoft Graph app-only auth and do not need a Secure Application Model refresh token, provided the app-only Partner Security Score path is authorized in Partner Center.

If a refresh token expires or is revoked:

1. Alert fires (`Refresh token expiring` or `Auth failure 401`).
2. A partner admin re-runs the interactive partner consent flow for the affected tenant.
3. New refresh token is stored in Key Vault.
4. Verify the next collection cycle succeeds.

### 15.4 Handling Persistent Failures

1. Check the **Per-Partner Status Grid** dashboard.
2. Identify whether the failure is auth-related (401), permission-related (403), or API-related (5xx).
3. For 403: verify consent is still active; re-consent if needed.
4. For 5xx: check Microsoft service health dashboard; file a support ticket if persistent.
5. For 401: rotate certificate or re-consent as appropriate.

---

## 16. Appendices

### Appendix A: Admin Consent URL Template

```
https://login.microsoftonline.com/{partner-tenant-id}/adminconsent?client_id={client-id}&redirect_uri=http://localhost

# Secure Application Model refresh-token capture:
scripts/Initialize-SecureAppConsent.ps1 -KeyVaultName <kv> -ClientId <client-id> -TenantId <partner-tenant-id>
```

### Appendix B: Key Vault Secret Naming Convention

| Secret Name                              | Content                                  |
|------------------------------------------|------------------------------------------|
| `regapp-certificate-hso-mpc-integration` | X.509 certificate (PFX)                 |
| `tenants-config`                         | JSON: `[{TenantId, DisplayName, Enabled, MpnId, CollectPartnerInsights, CollectPartnerSecurityScore}]` |
| `refresh-token-{tenant-id}`              | OAuth2 refresh token (Secure App Model)  |

### Appendix C: Well-Architected Framework Alignment

| Pillar                    | Key Design Decisions                                                                                |
|---------------------------|------------------------------------------------------------------------------------------------------|
| **Reliability**           | Durable Functions checkpointing, per-endpoint retry, circuit breaker per partner account, LRS storage |
| **Security**              | Secure Application Model App+User for Partner Center, certificate credentials, Managed Identity, RBAC, Key Vault, TLS 1.2 |
| **Cost Optimization**     | Partner-global collection, collection frequency optimization, adaptive sampling |
| **Operational Excellence**| Structured logging, custom metrics, dashboards, automated alerting, IaC, CI/CD, runbooks           |
| **Performance Efficiency**| Fan-out/fan-in parallelism, per-partner concurrency control, stateless access-token acquisition, pagination handling |

### Appendix D: References

- [programmatic access to analytics data](https://learn.microsoft.com/en-us/partner-center/insights/insights-programmatic-get-started)
- [Partner Center Datasets API](https://learn.microsoft.com/en-us/partner-center/insights/insights-programmatic-analytics-api-get-dataset)
- [Partner Center REST API Reference](https://learn.microsoft.com/en-us/partner-center/developer/partner-center-rest-api-reference)
- [Partner Center Authentication](https://learn.microsoft.com/en-us/partner-center/developer/partner-center-authentication)
- [Secure Application Model Framework](https://learn.microsoft.com/en-us/partner-center/developer/enable-secure-app-model)
- [Partner Security Requirements](https://learn.microsoft.com/en-us/partner-center/security/partner-security-requirements)
- [Partner Center API Scenarios](https://learn.microsoft.com/en-us/partner-center/developer/scenarios)
- [Microsoft Graph API — Use the API](https://learn.microsoft.com/en-us/graph/use-the-api)

---

*End of Architecture Design Document*
