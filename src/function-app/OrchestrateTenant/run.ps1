param($Context)

<#
.SYNOPSIS
    Per-partner sub-orchestrator. Collects two PARTNER-GLOBAL data sources for one partner account:
      - Partner Security Score (Microsoft Graph beta) — fanned out per endpoint.
      - Partner Insights datasets/queries/reports — a single CollectInsights activity.

    There is NO per-CSP-customer fan-out: customer detail is already inside the datasets and the
    security score's customerInsights.

    Input (orchestrator input JSON):
        CorrelationId          : string
        TenantId               : string   - partner tenant ID
        TenantName             : string
        SecurityScoreEndpoints : array
        InsightsCatalog        : array
        InsightsReports        : array
        CollectPartnerInsights      : bool
        CollectPartnerSecurityScore : bool
        TriggeredAtUtc         : string
        MaxConcurrentEndpoints : int
#>

$orchInput = $Context.Input | ConvertFrom-Json
$correlationId = $orchInput.CorrelationId
$tenantId = $orchInput.TenantId
$tenantName = $orchInput.TenantName
$securityEndpoints = @($orchInput.SecurityScoreEndpoints)
$insightsCatalog = @($orchInput.InsightsCatalog)
$insightsReports = @($orchInput.InsightsReports)
$triggeredAtUtc = $orchInput.TriggeredAtUtc
$maxConcurrentEndpoints = [int]($orchInput.MaxConcurrentEndpoints ?? 5)
$collectPartnerInsights = $true
if ($orchInput.PSObject.Properties['CollectPartnerInsights']) {
    $collectPartnerInsights = [bool]$orchInput.CollectPartnerInsights
}
$collectPartnerSecurityScore = $true
if ($orchInput.PSObject.Properties['CollectPartnerSecurityScore']) {
    $collectPartnerSecurityScore = [bool]$orchInput.CollectPartnerSecurityScore
}

$logPrefix = "[$correlationId][$tenantName]"
Write-Host "$logPrefix OrchestrateTenant (partner-global) started for $tenantId"

# Deterministic: derive the cycle hour from the passed trigger time (never use UtcNow here).
$currentHourUtc = [int]([DateTimeOffset]::Parse($triggeredAtUtc).Hour)
$isEvery4hCycle = ($currentHourUtc % 4) -eq 0

$results = @()
$circuitBreakerFailures = 0
$circuitBreakerThreshold = 5

try {
    # ── Step 1: which security endpoints run this cycle? ─────────────────
    $activeSecurity = @()
    if ($collectPartnerSecurityScore) {
        $activeSecurity = @($securityEndpoints | Where-Object {
                switch ($_.Frequency) {
                    'Hourly' { $true }
                    'Every4h' { $isEvery4hCycle }
                    'Every6h' { ($currentHourUtc % 6) -eq 0 }
                    default { $true }
                }
            })
    }

    $includeInsights = $collectPartnerInsights -and $isEvery4hCycle

    Write-Host "$logPrefix Active security endpoints: $($activeSecurity.Count)/$($securityEndpoints.Count); includeInsights=$includeInsights; collectPartnerInsights=$collectPartnerInsights; collectPartnerSecurityScore=$collectPartnerSecurityScore"

    # ── Step 2: Partner Security Score (Graph, AppOnly) ──────────────────
    if ($activeSecurity.Count -gt 0) {
        $graphTokenInput = @{
            CorrelationId = $correlationId
            TenantId      = $tenantId
            TenantName    = $tenantName
            Resource      = 'graph'
            AuthMode      = 'AppOnly'
        } | ConvertTo-Json -Compress

        $graphToken = Invoke-DurableActivity -FunctionName 'AcquireToken' -Input $graphTokenInput

        if (-not $graphToken -or $graphToken.Error) {
            Write-Host "$logPrefix WARNING: Graph token failed: $($graphToken.Error). Security endpoints skipped."
            foreach ($ep in $activeSecurity) {
                $results += @{ EndpointName = $ep.Name; ApiSurface = $ep.ApiSurface; Status = 'Skipped'; Error = 'No Graph token' }
            }
        }
        else {
            $batches = Split-IntoBatches -Items $activeSecurity -BatchSize $maxConcurrentEndpoints
            foreach ($batch in $batches) {
                if ($circuitBreakerFailures -ge $circuitBreakerThreshold) {
                    Write-Host "$logPrefix Circuit breaker OPEN — skipping remaining security endpoints."
                    break
                }

                $tasks = @()
                foreach ($ep in $batch) {
                    $activityInput = @{
                        CorrelationId  = $correlationId
                        TenantId       = $tenantId
                        TenantName     = $tenantName
                        Endpoint       = $ep
                        AccessToken    = $graphToken.AccessToken
                        TriggeredAtUtc = $triggeredAtUtc
                    } | ConvertTo-Json -Depth 10 -Compress

                    $tasks += Invoke-DurableActivity -FunctionName 'CollectSecurityScore' -Input $activityInput -NoWait
                }

                if ($tasks.Count -gt 0) {
                    $batchResults = Wait-DurableTask -Task $tasks
                    $results += $batchResults
                    foreach ($r in $batchResults) {
                        if ($r.Status -eq 'Failed') { $circuitBreakerFailures++ } else { $circuitBreakerFailures = 0 }
                    }
                }
            }
        }
    }

    # ── Step 3: Partner Insights (single activity, AppOnly/AppPlusUser) ───
    if ($includeInsights) {
        $insightsTokenInput = @{
            CorrelationId = $correlationId
            TenantId      = $tenantId
            TenantName    = $tenantName
            Resource      = 'insights'
            AuthMode      = 'AppPlusUser'
        } | ConvertTo-Json -Compress

        $insightsToken = Invoke-DurableActivity -FunctionName 'AcquireToken' -Input $insightsTokenInput

        if (-not $insightsToken -or $insightsToken.Error) {
            Write-Host "$logPrefix WARNING: Insights token failed: $($insightsToken.Error). Insights skipped."
            $results += @{ EndpointName = 'partner-insights'; ApiSurface = 'partner-insights'; Status = 'Skipped'; Error = "No Insights token: $($insightsToken.Error)" }
        }
        else {
            $insightsInput = @{
                CorrelationId     = $correlationId
                TenantId          = $tenantId
                TenantName        = $tenantName
                AccessToken       = $insightsToken.AccessToken
                InsightsAuthMode  = $insightsToken.AuthMode
                InsightsCatalog   = $insightsCatalog
                RegistryReports   = $insightsReports
                EnsureAllDatasets = $true
                TriggeredAtUtc    = $triggeredAtUtc
            } | ConvertTo-Json -Depth 10 -Compress

            $insightsResult = Invoke-DurableActivity -FunctionName 'CollectInsights' -Input $insightsInput
            $results += $insightsResult
        }
    }

    # ── Step 4: summary ──────────────────────────────────────────────────
    $succeeded = @($results | Where-Object { $_.Status -eq 'Succeeded' }).Count
    $failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
    $partial = @($results | Where-Object { $_.Status -eq 'Partial' }).Count
    $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

    $status = if ($results.Count -eq 0) { 'Succeeded' }
    elseif ($failed -eq $results.Count) { 'Failed' }
    elseif ($failed -gt 0 -or $partial -gt 0) { 'Partial' }
    else { 'Succeeded' }

    Write-Host "$logPrefix OrchestrateTenant completed: $status | OK=$succeeded FAIL=$failed PARTIAL=$partial SKIP=$skipped"

    return @{
        TenantId           = $tenantId
        TenantName         = $tenantName
        Status             = $status
        ItemsTotal         = $results.Count
        ItemsSucceeded     = $succeeded
        ItemsFailed        = $failed
        ItemsPartial       = $partial
        ItemsSkipped       = $skipped
        CircuitBreakerOpen = ($circuitBreakerFailures -ge $circuitBreakerThreshold)
        CompletedUtc       = $Context.CurrentUtcDateTime.ToString('o')
        Details            = $results
    }

}
catch {
    Write-Host "$logPrefix ERROR: Unhandled exception in OrchestrateTenant: $_"
    return @{
        TenantId     = $tenantId
        TenantName   = $tenantName
        Status       = 'Failed'
        Error        = $_.Exception.Message
        CompletedUtc = $Context.CurrentUtcDateTime.ToString('o')
    }
}
