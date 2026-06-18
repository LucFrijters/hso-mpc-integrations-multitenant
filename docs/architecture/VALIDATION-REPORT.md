# Validation & Transformation Report

| Attribute | Value |
|-----------|-------|
| Subject | HSO Partner Insights + Partner Security Score integration |
| Date | 2026-06-19 |
| Objective validated | "Retrieve all Microsoft Partner Insight Datasets and Queries and all CSP Security Scores, save all output as JSON to Blob Storage — efficient but resilient." |
| Verdict | v1.0 did **not** meet the objective; transformed to v2.4 (below) which does, aligns Partner Center calls with the Secure Application Model, supports local development against the main Key Vault without VNet connectivity, and has production-ready packaging/CI guardrails. |

## 1. Findings (validation of v1.0)

| # | Severity | Finding |
|---|----------|---------|
| 1 | **Critical** | **Wrong API.** The registry collected the Partner Center *commerce* REST API (`/v1/customers`, `/v1/orders`, `/v1/invoices`, …), not the **Partner Insights programmatic analytics API** (`/insights/v1/mpn/ScheduledDataset`, `ScheduledQueries`, `ScheduledReport`). "Datasets and Queries" were therefore not collected at all. |
| 2 | **High** | **Wrong topology / inefficient.** Both the Insights API and the Partner Security Score are *partner-global* (read once at the partner level). v1.0 fanned out across CSP customer tenants and iterated per-customer endpoints — unnecessary work, since per-customer detail is already inside the Insights datasets and the score's `customerInsights`. |
| 3 | **High** | **Non-existent endpoint.** `/beta/security/partner/securityAlerts` is not a documented method of the partner security namespace; it would error every cycle. The real per-customer endpoint, `securityScore/customerInsights`, was missing. |
| 4 | **Medium** | **Output format gap.** Insights report executions are delivered as **CSV/TSV**, but the objective requires JSON. v1.0 had no conversion step (and didn't reach the data at all). |
| 5 | **Medium** | **Cadence error.** Hourly collection was specified, but the Insights report `RecurrenceInterval` minimum is **4 hours** and the analytics refresh daily/monthly — hourly is impossible and wasteful. |
| 6 | **Low** | **Refresh-token secret name drift.** Code used `refresh-token-<tid>`; the design doc/appendix used `refresh-token--<tid>` (double dash). A real lookup-miss bug. |
| 7 | **Low** | **Double fetch.** `LoadCustomerIds` re-called `/v1/customers` after `CollectEndpointData` had already retrieved it. |
| 8 | **Low** | **Windows-only test.** `TokenService.Tests.ps1` used `New-SelfSignedCertificate`, which fails on the `ubuntu-latest` CI runner. |

What v1.0 got right and was kept: certificate-based JWT client assertion (zero client secrets), Managed Identity for Key Vault/Blob, Durable fan-out/fan-in, exponential backoff + `Retry-After` handling, circuit breaker, structured logging, lifecycle tiering, and the Bicep/CI scaffolding.

## 2. Transformation (v2.4)

- **New `InsightsClient.psm1`** implements the async paradigm: enumerate datasets/queries → idempotently ensure a scheduled report per dataset (system query where available, otherwise a generated `SELECT`-all from the dataset's columns) → download the latest completed execution via its SAS link → **convert CSV/TSV to JSON**.
- **Registry rewritten** (`EndpointRegistry.psd1`): Graph security-score endpoints (score, requirements, history, **customerInsights**; `securityAlerts` removed) + Insights catalog + Insights report definitions seeded with verified Microsoft system query IDs.
- **Partner-global topology**: orchestrator fans out across *partner accounts* (default one — the HSO Production Partner Center), not customer tenants. Commerce endpoints, per-customer fan-out, and `LoadCustomerIds` removed; `CollectEndpointData` replaced by `CollectSecurityScore` + `CollectInsights`.
- **Resilience/efficiency**: reports created once and reused; executions de-duplicated by `executionId` (marker blobs under `_insights-state/`); `RecurrenceInterval` floored at 4h; collection cadence daily for Insights / 6h for the score; per-report `try/catch` so one failure never aborts the cycle; "not yet executed" (404) treated as *pending*, not failure.
- **Secure Application Model alignment**: Partner Insights defaults to `InsightsAuthMode: AppPlusUser`, uses the delegated `https://api.partnercenter.microsoft.com/user_impersonation` scope, stores refresh tokens as `refresh-token-{tenantId}` in Key Vault, rotates refresh tokens on redemption, and sends `ValidateMfa: true` on Partner Center calls.
- **No-VNet local development path**: Function App VNet integration and private endpoints were removed. Key Vault and storage use public Azure service endpoints with RBAC authorization, and `scripts/Initialize-LocalDevelopment.ps1` updates local settings plus optional Key Vault network/RBAC access for developers.
- **Production readiness hardening**: CI/CD resource group naming now matches manual deployment, alert notification email is parameterized, Function App telemetry uses AAD ingestion auth to match Application Insights `DisableLocalAuth`, package creation excludes `local.settings.json`/`.vscode`, and `.gitattributes` enforces LF line endings across Windows and CI.
- **Config**: `partner-insights` API surface added, commerce surface removed; refresh-token secret name centralized (`Get-RefreshTokenSecretName`); `partner-config` replaces `tenant-config`; all new settings surfaced in `local.settings.json` and `function-app.bicep`.
- **Docs/tests/scripts** updated to match (`README`, `ARCHITECTURE` rev 2.4, `Deploy`, `Initialize-LocalDevelopment`, `Initialize-SecureAppConsent`, `Update-RefreshToken`, `Verify-TenantConsent`, cross-platform `TokenService` test, `IntegrationConfig` and `InsightsClient` test coverage).

## 3. Verification performed

- **PSScriptAnalyzer** (repo settings, Warning+Error): **clean** across all modules, activities, and scripts. The intentional `ConvertTo-SecureString -AsPlainText` paths are limited to receiving rotated refresh tokens over TLS and immediately persisting them to Key Vault.
- **Pester**: **30/30 passing** — registry shape (incl. "no securityAlerts", "has customerInsights"), `IntegrationConfig` SAM/app-only scope selection, `InsightsClient` pure functions and MFA header validation, and cross-platform `TokenService` JWT (3-part token, RS256, audience, signature verifies).
- **Bicep / diagnostics**: VS Code diagnostics are clean for the changed Bicep and PowerShell files. Standalone `bicep build .\infra\main.bicep` succeeds; the Azure CLI `az bicep build` wrapper failed locally with `WinError 193` before compilation because its bundled Bicep executable is invalid on this machine.
- **Packaging / repository hygiene**: package smoke test confirmed `function-app.zip` contains no `local.settings.json` or `.vscode` entries; `git diff --check -- .` passes; representative tracked files report `w/lf attr/text eol=lf` under the `.gitattributes` policy.

## 4. Open items to confirm before production

1. **Secure App Model bootstrap.** Keep `InsightsAuthMode: AppPlusUser` for Partner Insights and seed the Secure Application Model refresh token in Key Vault (`refresh-token-<tenantId>`) with `scripts/Initialize-SecureAppConsent.ps1` before the first production run. Schedule `scripts/Update-RefreshToken.ps1` as a safety net if collection may be paused for long periods.
2. **Graph permission.** `PartnerSecurity.Read.All` (application) must be admin-consented in the HSO partner tenant; it is a `/beta` API (no SLA, subject to change).
3. **System query IDs.** The seeded `SystemQueryId` values are Microsoft-published; with `INSIGHTS_ENSURE_ALL_DATASETS=true` every other dataset is still exported via a generated query, so unseeded/renamed datasets are covered automatically.
4. **Dataset response shape.** `Get-InsightsDatasetColumns` reads columns defensively across field spellings; confirm against a live `ScheduledDataset` response and tighten if needed.

## References

- Programmatic access to analytics data — <https://learn.microsoft.com/partner-center/insights/insights-programmatic-get-started>
- Available APIs / access paradigm — <https://learn.microsoft.com/partner-center/insights/insights-programmatic-analytics-available-api>
- System queries — <https://learn.microsoft.com/partner-center/insights/insights-programmatic-system-queries>
- Partner security score API (beta) — <https://learn.microsoft.com/graph/api/resources/partner-security-score-api-overview?view=graph-rest-beta>
- Secure Application Model — <https://learn.microsoft.com/partner-center/developer/enable-secure-app-model>
