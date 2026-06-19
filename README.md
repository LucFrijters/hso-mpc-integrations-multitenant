# HSO Partner Insights + Partner Security Score Integration

Centralized, partner-global collection of **Microsoft Partner Center Insights** (all datasets and queries, plus full dataset exports) and the **Partner Security Score** (Microsoft Graph beta), persisted as **JSON in Azure Blob Storage**. Built on **Azure Functions (PowerShell 7.6, Windows)** with **Durable Functions** orchestration.

> **Runtime note.** The worker targets **PowerShell 7.6**, which on Azure Functions is currently **preview, Windows-only, and requires .NET 10** — so the app must run on a **Windows** plan (Premium/Dedicated/Consumption), not Linux Consumption or Flex Consumption. PowerShell 7.4 remains GA until **2026-11-10**. The version is a single Bicep parameter (`powerShellVersion`, default `7.6`); set it to `7.4` per environment to stay on GA support until 7.6 reaches GA.

## What it collects

| Data source | API | Auth | Cadence |
|-------------|-----|------|---------|
| Insights **datasets** catalog | `GET /insights/v1/mpn/ScheduledDataset` | Partner Center SAM App+User token (`user_impersonation`) | Every 4h UTC |
| Insights **queries** catalog | `GET /insights/v1/mpn/ScheduledQueries` | Partner Center SAM App+User token (`user_impersonation`) | Every 4h UTC |
| Insights **report data** (every dataset) | `ScheduledReport` -> `ScheduledReport/execution` -> SAS download | Partner Center SAM App+User token (`user_impersonation`) | Every 4h UTC |
| Partner **Security Score** + requirements + history + **customerInsights** | `GET /beta/security/partner/securityScore[...]` | Graph app-only `PartnerSecurity.Read.All` | Every 4h / 6h by endpoint |

## Topology — partner-global, not per-customer

Both data sources are **partner-global**: they are read **once from the HSO Production Partner Center**, not iterated across the ~20 CSP customer tenants. Per-customer detail is already inside the data — the Insights `CustomersAndTenants` dataset carries per-customer rows, and the security score exposes per-customer posture via `customerInsights`. This is the core efficiency property of the design: one set of API calls instead of `customers × endpoints`.

The partner-account list lives in the Key Vault secret `tenants-config` (normally a single entry). Each entry can enable Partner Insights, Partner Security Score, or both using `CollectPartnerInsights` and `CollectPartnerSecurityScore`; the Durable fan-out still supports additional partner accounts if ever needed.

## The Insights flow is asynchronous

The Insights API does not return data on a simple GET. The `CollectInsights` activity:

1. enumerates all datasets and queries (stored directly as JSON);
2. resolves the reports to collect (registry-seeded system queries, plus a generated `SELECT` report for every other dataset so all datasets are exported);
3. **idempotently ensures** a scheduled report exists per dataset (created once, reused thereafter — `RecurrenceInterval` minimum is 4h, so the collection cadence is every 4 hours UTC);
4. downloads the latest **completed** execution via its secure SAS link and **converts the CSV/TSV payload to JSON** before storing.

The collection is intentionally full-cycle: every run writes the current catalog and the latest completed report execution for every dataset, even when the latest `executionId` matches a prior run.

## Repository structure

```
├── .gitattributes             LF line-ending policy for source/config files
├── .github/workflows/        CI (PSScriptAnalyzer + Pester + Bicep validate) and CD
├── docs/architecture/         ARCHITECTURE.md design document
├── infra/                     Bicep IaC (storage, keyvault, monitoring, function-app)
├── scripts/                   Deploy, Initialize-LocalDevelopment, Grant-AdminConsent, Initialize-SecureAppConsent, Update-RefreshToken, Rotate-Certificate, Verify-TenantConsent
├── src/function-app/
│   ├── modules/
│   │   ├── IntegrationConfig.psm1   Central config, API surfaces, retry, batching
│   │   ├── TokenService.psm1        Certificate JWT client assertion + token acquisition
│   │   ├── ApiClient.psm1           Retry/throttle core + Graph pagination
│   │   ├── InsightsClient.psm1      Insights async flow + CSV/TSV → JSON
│   │   ├── BlobStorageService.psm1  JSON blob writes (MI auth) + metadata sidecars
│   │   └── OrchestrationStarter.psm1 Shared Durable orchestration starter
│   ├── TimerStart/                  Timer trigger (fixed every 2h)
│   ├── ManualStart/                 HTTP trigger for operator-started collection cycles
│   ├── OrchestrateAllTenants/       Fan-out across partner accounts
│   ├── OrchestrateTenant/           Per-partner orchestration (security score + insights)
│   ├── AcquireToken/                Token activity (Graph AppOnly / Partner Insights AppPlusUser)
│   ├── CollectSecurityScore/        Activity: one Graph security-score endpoint → JSON
│   ├── CollectInsights/             Activity: full Insights flow → JSON
│   ├── LoadTenantConfig/            Loads tenants-config from Key Vault
│   ├── LoadEndpointRegistry/        Loads the collection registry
│   └── StoreSummaryBlob/            Writes the run summary
└── tests/                     Pester 5 suites (registry, IntegrationConfig, InsightsClient, TokenService)
```

## Prerequisites

- PowerShell 7.6 (local dev on Windows), Azure Functions Core Tools v4, Azure CLI
- A multi-tenant Entra app (certificate credential) consented in the HSO Production Partner Center with:
  - **Graph** `PartnerSecurity.Read.All` (application)
  - **Partner Center** `user_impersonation` (delegated) for the Secure Application Model refresh-token flow. Insights auth is fixed to `AppPlusUser`.
- A Key Vault certificate secret named `regapp-certificate-hso-mpc-integration` and a Secure Application Model refresh token stored as `refresh-token-<tenantId>` for each App+User partner account.

## Deployment

```powershell
$env:APP_CLIENT_ID = '<multi-tenant-app-client-id>'
$env:ALERT_EMAIL_ADDRESS = 'integration-alerts@hso.com'
.\scripts\Deploy.ps1 -Environment prod -AppClientId $env:APP_CLIENT_ID -AlertEmailAddress $env:ALERT_EMAIL_ADDRESS
```

The deployment script runs Bicep what-if, deploys infrastructure, builds a zip package that excludes `local.settings.json` and editor-only folders, deploys the Function App, and prints the post-deployment onboarding checklist.

CI uses the same safety rule: the package job stages `src/function-app` first and excludes `local.settings.json` and `.vscode` before publishing `function-app.zip`. Repository text files are pinned to LF by `.gitattributes`, so Windows and CI do not churn line endings.

## Onboarding the partner account

1. Store `tenants-config` in Key Vault: `[{ "TenantId": "<guid>", "DisplayName": "HSO Production", "Enabled": true, "MpnId": "<mpn>", "CollectPartnerInsights": true, "CollectPartnerSecurityScore": true }]`
2. Grant admin consent: `scripts/Grant-AdminConsent.ps1 -TenantId <guid> -ClientId <app-id>`
3. Capture the SAM refresh token with MFA: `scripts/Initialize-SecureAppConsent.ps1 -KeyVaultName <kv> -ClientId <app-id> -TenantId <guid>`
4. Verify: `scripts/Verify-TenantConsent.ps1 -KeyVaultName <kv> -ClientId <app-id>` (tests refresh-token exchange, Partner Center MFA validation via `ValidateMfa`, `ScheduledDataset`, and Graph `securityScore`)
5. Keep the refresh token alive during long pauses with `scripts/Update-RefreshToken.ps1 -KeyVaultName <kv> -ClientId <app-id>`.

## Manual collection trigger

Use the `ManualStart` HTTP function for operator-triggered collection cycles. It starts the same Durable orchestration as `TimerStart`, but avoids the Azure Portal timer-trigger hostruntime path that can return `404 NotFound` even when the function is indexed.

```powershell
$manualKey = az functionapp function keys list `
  --resource-group hso-mpc-multitenant-integration-prd-westeu `
  --name func-hso-mpc-integration-prd-westeu `
  --function-name ManualStart `
  --query default `
  --output tsv

Invoke-RestMethod -Method Post `
  -Uri "https://func-hso-mpc-integration-prd-westeu.azurewebsites.net/api/collection/start?code=$manualKey"
```

## Local development against the main Key Vault

The infrastructure intentionally does **not** require VNet integration or private endpoint connectivity. Key Vault and the data storage account expose public Azure service endpoints, while access is still controlled by Microsoft Entra ID and Azure RBAC. That lets the local Functions host use the same deployed Key Vault certificate, tenants-config, and refresh-token secrets as the cloud Function App without copying secrets into `local.settings.json`.

Run the local setup helper after signing in with Az PowerShell:

```powershell
.\scripts\Initialize-LocalDevelopment.ps1 `
  -Environment prod `
  -AppClientId <app-id> `
  -GrantCurrentUserKeyVaultRbac `
  -ValidateKeyVaultAccess
```

The script resolves the deployed Key Vault and storage account, enables Key Vault public authenticated access if needed, updates `src/function-app/local.settings.json`, and optionally grants the signed-in user the Key Vault data-plane roles required for local reads. Use `-KeyVaultNetworkMode AllowCurrentIpOnly` only when you also account for the cloud Function App's outbound IPs; the default `AllowPublicAuthenticated` matches the no-VNet Bicep deployment.

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.0.0 -Force
Invoke-Pester -Path ./tests -Output Detailed
```
