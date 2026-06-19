@{
    <#
    .SYNOPSIS
        Collection registry for the HSO Partner Insights + Partner Security Score integration.

        This solution collects two PARTNER-GLOBAL data sources from the HSO Production Partner
        Center (no per-CSP-customer-tenant fan-out):

          1. Partner Insights programmatic analytics  -> all Datasets and Queries, plus full
             dataset exports delivered as scheduled reports (CSV/TSV) converted to JSON.
          2. Partner Security Score (Microsoft Graph beta) -> score, requirements, history and
             per-customer insights (covers all CSP customers in a single call).

        Frequency values:
            Hourly  - every cycle
            Every6h - at 00, 06, 12, 18 UTC
            Every4h - at 00, 04, 08, 12, 16, 20 UTC
        ApiSurface values:
            partner-insights - Partner Center Insights API (https://api.partnercenter.microsoft.com/insights/v1/mpn)
            graph-beta       - Microsoft Graph beta       (https://graph.microsoft.com/beta)
    #>

    # ================================================================
    # MICROSOFT GRAPH BETA — PARTNER SECURITY SCORE  (all CSP scores)
    # Application permission: PartnerSecurity.Read.All  (admin-consented in the HSO partner tenant)
    # ================================================================
    SecurityScoreEndpoints = @(
        @{
            Name        = 'security-score'
            Category    = 'partner-security-score'
            ApiSurface  = 'graph-beta'
            Path        = '/security/partner/securityScore'
            Frequency   = 'Every6h'
            Description = 'Aggregate partner security score (currentScore, maxScore, refresh times)'
        }
        @{
            Name        = 'security-score-requirements'
            Category    = 'partner-security-score'
            ApiSurface  = 'graph-beta'
            Path        = '/security/partner/securityScore/requirements'
            Frequency   = 'Every6h'
            Description = 'Per-requirement breakdown (compliance status, score, action URL)'
        }
        @{
            Name        = 'security-score-history'
            Category    = 'partner-security-score'
            ApiSurface  = 'graph-beta'
            Path        = '/security/partner/securityScore/history'
            Frequency   = 'Every4h'
            Description = 'History of partner security score changes'
        }
        @{
            Name        = 'security-score-customer-insights'
            Category    = 'partner-security-score'
            ApiSurface  = 'graph-beta'
            Path        = '/security/partner/securityScore/customerInsights'
            Frequency   = 'Every6h'
            Description = 'Per-CSP-customer security posture for all customers (single partner-level call)'
        }
    )

    # ================================================================
    # PARTNER INSIGHTS — CATALOG (already JSON; cheap; lists everything available)
    # Satisfies "retrieve all Insight Datasets and Queries".
    # ================================================================
    InsightsCatalog        = @(
        @{
            Name        = 'datasets'
            Category    = 'insights-catalog'
            ApiSurface  = 'partner-insights'
            Path        = '/ScheduledDataset'
            Frequency   = 'Every4h'
            Description = 'All available Insights datasets: tables, columns, metrics, time ranges'
        }
        @{
            Name        = 'queries'
            Category    = 'insights-catalog'
            ApiSurface  = 'partner-insights'
            Path        = '/ScheduledQueries'
            Frequency   = 'Every4h'
            Description = 'All report queries (system-provided and user-defined)'
        }
    )

    # ================================================================
    # PARTNER INSIGHTS — REPORT DEFINITIONS (full dataset exports)
    # Each entry is ensured idempotently (created once) then the latest completed
    # execution is downloaded and converted CSV/TSV -> JSON every cycle.
    #
    # SystemQueryId values are Microsoft-provided system queries (6-month window).
    # Every dataset returned by /ScheduledDataset that is not listed here also gets
    # a generated "SELECT <selectableColumns>" report when selectableColumns exist.
    # Column-less datasets are skipped because the query grammar has no SELECT *.
    # Entries below take precedence.
    # ================================================================
    InsightsReports        = @(
        @{ DatasetName = 'CustomersAndTenants'; SystemQueryId = '6664daf3-c161-423a-92a1-0ea6db2c0384'; Frequency = 'Every4h'; Description = 'Customers report (6M)' }
        @{ DatasetName = 'SeatsSubscriptionsAndRevenue'; SystemQueryId = 'c9fc1c79-4408-49ff-97f9-e1aa3f155804'; Frequency = 'Every4h'; Description = 'Seats, subscriptions and revenue (6M)' }
        @{ DatasetName = 'Profile'; SystemQueryId = 'e65f3a4f-fb99-4319-97ff-59e57566a871'; Frequency = 'Every4h'; Description = 'Partner profile' }
        @{ DatasetName = 'AzureUsage'; SystemQueryId = 'd1a4d75e-5ca8-4847-845f-ee0a9be6f07b'; Frequency = 'Every4h'; Description = 'Azure usage (6M)' }
        @{ DatasetName = 'OfficeUsage'; SystemQueryId = 'd8349f7b-a7d1-467e-b26d-434d4a50f26a'; Frequency = 'Every4h'; Description = 'Office usage (6M)' }
        @{ DatasetName = 'DynamicsUsage'; SystemQueryId = '6209a8fd-93af-442e-8b3f-3df0f77e8463'; Frequency = 'Every4h'; Description = 'Dynamics usage (6M)' }
        @{ DatasetName = 'PowerBIUsage'; SystemQueryId = '40ebfe2f-7183-4427-a911-5c9b45b6df15'; Frequency = 'Every4h'; Description = 'Power BI usage (6M)' }
        @{ DatasetName = 'EMSUsage'; SystemQueryId = 'd7f20ea4-8751-4d6b-b1d7-821c316acd6a'; Frequency = 'Every4h'; Description = 'EMS usage (6M)' }
        @{ DatasetName = 'CloudProductsResellerPerformance'; SystemQueryId = 'c09c2eda-861b-4664-8ee8-48a14745a26a'; Frequency = 'Every4h'; Description = 'Cloud products reseller performance (6M)' }
        @{ DatasetName = 'CLASAgreementRenewalsPropensity'; SystemQueryId = 'c4fc87ac-4cca-44cd-bf4d-835ac513f9ee'; Frequency = 'Every4h'; Description = 'CLAS agreement renewals propensity' }
        @{ DatasetName = 'CLASAzurePropensity'; SystemQueryId = '9a18bd70-8f90-4bd2-8266-5f6e453e3ee7'; Frequency = 'Every4h'; Description = 'CLAS Azure propensity' }
        @{ DatasetName = 'CLASD365Propensity'; SystemQueryId = '258fdcac-6e9c-4072-af27-b1b3d97be16c'; Frequency = 'Every4h'; Description = 'CLAS Dynamics 365 propensity' }
        @{ DatasetName = 'CLASM365Propensity'; SystemQueryId = 'fbe00e32-fdde-4465-b3e4-41bbd021a130'; Frequency = 'Every4h'; Description = 'CLAS Microsoft 365 propensity' }
        @{ DatasetName = 'CLASSurfacePropensity'; SystemQueryId = 'ba339743-7594-439f-bb01-1a2e754df7b7'; Frequency = 'Every4h'; Description = 'CLAS Surface propensity' }
        @{ DatasetName = 'TeamsUsage3PApps'; SystemQueryId = '42d287be-cc76-4109-a066-f3140ad97fe2'; Frequency = 'Every4h'; Description = 'Teams usage 3P apps (6M)' }
        @{ DatasetName = 'TeamsUsageWorkload'; SystemQueryId = '817fe875-acb0-4c45-9201-b7a35a60235a'; Frequency = 'Every4h'; Description = 'Teams usage workload (6M)' }
        @{ DatasetName = 'TeamsUsageMeetingsAndCalls'; SystemQueryId = 'b7bd73a8-47e8-4c57-b915-445708cfd7bf'; Frequency = 'Every4h'; Description = 'Teams usage meetings and calls (6M)' }
        @{ DatasetName = 'TrainingCompletions'; SystemQueryId = '20f5da57-3c2a-481b-b6a0-ec34d6db14e2'; Frequency = 'Every4h'; Description = 'Training completions (6M)' }
        @{ DatasetName = 'MSLearn'; SystemQueryId = '0e06c7c3-75ab-4cd5-8178-8cf1a2de49cc'; Frequency = 'Every4h'; Description = 'Microsoft Learn (6M)' }
    )
}
