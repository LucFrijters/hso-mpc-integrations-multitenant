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
    # a generated "SELECT <all columns>" report so that ALL datasets are exported.
    # Entries below take precedence.
    # ================================================================
    InsightsReports        = @(
        @{ DatasetName = 'CustomersAndTenants'; SystemQueryId = '6664daf3-c161-423a-92a1-0ea6db2c0384'; Frequency = 'Every4h'; Description = 'Customers report (6M)' }
        @{ DatasetName = 'SeatsSubscriptionsAndRevenue'; SystemQueryId = 'c9fc1c79-4408-49ff-97f9-e1aa3f155804'; Frequency = 'Every4h'; Description = 'Seats, subscriptions and revenue (6M)' }
        @{ DatasetName = 'AzureUsage'; SystemQueryId = 'd1a4d75e-5ca8-4847-845f-ee0a9be6f07b'; Frequency = 'Every4h'; Description = 'Azure usage (6M)' }
        @{ DatasetName = 'OfficeUsage'; SystemQueryId = 'd8349f7b-a7d1-467e-b26d-434d4a50f26a'; Frequency = 'Every4h'; Description = 'Office usage (6M)' }
        @{ DatasetName = 'DynamicsUsage'; SystemQueryId = '6209a8fd-93af-442e-8b3f-3df0f77e8463'; Frequency = 'Every4h'; Description = 'Dynamics usage (6M)' }
        @{ DatasetName = 'Profile'; SystemQueryId = 'e65f3a4f-fb99-4319-97ff-59e57566a871'; Frequency = 'Every4h'; Description = 'Partner profile' }
    )
}
