param($Context)

<#
.SYNOPSIS
    Main orchestrator: loads the partner-account list and the collection registry, then fans out
    to a per-partner sub-orchestrator. Typically there is a single partner account
    (the HSO Production Partner Center); the fan-out supports additional partner accounts.

    Concurrency and feature flags are passed via orchestrator input to avoid non-deterministic
    $env: reads during Durable Functions replay.
#>

$orchInput = $Context.Input | ConvertFrom-Json
$correlationId = $orchInput.CorrelationId
$maxConcurrentPartners = [int]($orchInput.MaxConcurrentPartners ?? 4)
$maxConcurrentEndpoints = [int]($orchInput.MaxConcurrentEndpoints ?? 5)
$ensureAllDatasets = [bool]($orchInput.EnsureAllDatasets ?? $true)
$insightsDailyHour = [int]($orchInput.InsightsDailyHourUtc ?? 2)

Write-Host "[$correlationId] OrchestrateAllTenants started. Instance: $($Context.InstanceId)"

# Step 1: Load partner-account configuration
$partnerConfig = Invoke-DurableActivity -FunctionName 'LoadTenantConfig' -Input $correlationId

if (-not $partnerConfig -or $partnerConfig.Count -eq 0) {
    Write-Host "[$correlationId] ERROR: No partner configuration found. Aborting."
    return @{
        CorrelationId = $correlationId
        Status        = 'Failed'
        Error         = 'No partner configuration found'
        CompletedUtc  = $Context.CurrentUtcDateTime.ToString('o')
    }
}

$partners = @($partnerConfig | Where-Object { $_.Enabled -eq $true })
Write-Host "[$correlationId] Loaded $($partners.Count) enabled partner account(s) of $($partnerConfig.Count) total"

# Step 2: Load collection registry (security score endpoints + insights catalog/reports)
$registry = Invoke-DurableActivity -FunctionName 'LoadEndpointRegistry' -Input $correlationId

# Step 3: Fan out per partner account (batched)
$allResults = @()
$partnerBatches = Split-IntoBatches -Items $partners -BatchSize $maxConcurrentPartners

foreach ($batch in $partnerBatches) {
    $tasks = @()

    foreach ($partner in $batch) {
        $subInput = @{
            CorrelationId          = $correlationId
            TenantId               = $partner.TenantId
            TenantName             = $partner.DisplayName
            InsightsAuthMode       = $partner.InsightsAuthMode ?? 'AppPlusUser'
            SecurityScoreEndpoints = $registry.SecurityScoreEndpoints
            InsightsCatalog        = $registry.InsightsCatalog
            InsightsReports        = $registry.InsightsReports
            EnsureAllDatasets      = $ensureAllDatasets
            TriggeredAtUtc         = $orchInput.TriggeredAtUtc
            MaxConcurrentEndpoints = $maxConcurrentEndpoints
            InsightsDailyHourUtc   = $insightsDailyHour
        } | ConvertTo-Json -Depth 10 -Compress

        $tasks += Invoke-DurableSubOrchestrator `
            -FunctionName 'OrchestrateTenant' `
            -Input $subInput `
            -InstanceId "$($Context.InstanceId):$($partner.TenantId)" `
            -NoWait
    }

    $allResults += Wait-DurableTask -Task $tasks
}

# Step 4: Aggregate
$succeeded = @($allResults | Where-Object { $_.Status -eq 'Succeeded' }).Count
$failed = @($allResults | Where-Object { $_.Status -eq 'Failed' }).Count
$partial = @($allResults | Where-Object { $_.Status -eq 'Partial' }).Count

$summary = @{
    CorrelationId    = $correlationId
    OrchestrationId  = $Context.InstanceId
    Status           = if ($allResults.Count -eq 0) { 'Failed' }
                       elseif ($failed -eq $allResults.Count) { 'Failed' }
                       elseif ($failed -gt 0 -or $partial -gt 0) { 'Partial' }
                       else { 'Succeeded' }
    PartnersTotal    = $allResults.Count
    PartnersSucceeded = $succeeded
    PartnersFailed   = $failed
    PartnersPartial  = $partial
    StartedUtc       = $orchInput.TriggeredAtUtc
    CompletedUtc     = $Context.CurrentUtcDateTime.ToString('o')
    PartnerResults   = $allResults
}

Write-Host "[$correlationId] OrchestrateAllTenants completed: $($summary.Status) | OK=$succeeded FAIL=$failed PARTIAL=$partial"

# Step 5: Store run summary
Invoke-DurableActivity -FunctionName 'StoreSummaryBlob' -Input ($summary | ConvertTo-Json -Depth 20 -Compress)

return $summary
