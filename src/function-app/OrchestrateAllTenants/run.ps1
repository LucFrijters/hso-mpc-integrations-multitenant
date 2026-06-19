param($Context)

<#
.SYNOPSIS
    Main orchestrator: loads the tenant configuration and the collection registry, then runs
    partner-level collection inline. Typically there is a single partner account
    (the HSO Production Partner Center); endpoint collection still fans out to activities.

    Concurrency and feature flags are passed via orchestrator input to avoid non-deterministic
    $env: reads during Durable Functions replay.
#>

function Get-OrchestrationInputValue {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        $DefaultValue = $null
    )

    if ($InputObject -is [System.Collections.IDictionary] -and $InputObject.Contains($Name)) {
        return $InputObject[$Name]
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $property) {
        return $property.Value
    }

    return $DefaultValue
}

function Get-OrchestrationBooleanFlag {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Name,
        [bool]$DefaultValue = $true
    )

    $value = Get-OrchestrationInputValue -InputObject $InputObject -Name $Name -DefaultValue $null
    if ($null -eq $value) { return $DefaultValue }
    return [bool]$value
}

$orchInput = $Context.Input | ConvertFrom-Json
$correlationId = $orchInput.CorrelationId
$maxConcurrentPartners = [int]($orchInput.MaxConcurrentPartners ?? 4)
$maxConcurrentEndpoints = [int]($orchInput.MaxConcurrentEndpoints ?? 5)
$forceCollection = $false
if ($orchInput.PSObject.Properties['ForceCollection']) {
    $forceCollection = [bool]$orchInput.ForceCollection
}

Write-Host "[$correlationId] OrchestrateAllTenants started. Instance: $($Context.InstanceId); forceCollection=$forceCollection"

# Step 1: Load tenant configuration
$tenantsConfig = Invoke-DurableActivity -FunctionName 'LoadTenantConfig' -Input $correlationId

if (-not $tenantsConfig -or $tenantsConfig.Count -eq 0) {
    Write-Host "[$correlationId] ERROR: No tenant configuration found. Aborting."
    return @{
        CorrelationId = $correlationId
        Status        = 'Failed'
        Error         = 'No tenant configuration found'
        CompletedUtc  = $Context.CurrentUtcDateTime.ToString('o')
    }
}

$partners = @($tenantsConfig | Where-Object { Get-OrchestrationBooleanFlag -InputObject $_ -Name 'Enabled' -DefaultValue $true })
Write-Host "[$correlationId] Loaded $($partners.Count) enabled partner account(s) of $($tenantsConfig.Count) total"

# Step 2: Load collection registry (security score endpoints + insights catalog/reports)
$registry = Invoke-DurableActivity -FunctionName 'LoadEndpointRegistry' -Input $correlationId

# Step 3: Collect per partner account.
# The PowerShell Durable SDK in this runtime does not expose a sub-orchestrator cmdlet,
# so the per-partner orchestration is performed inline while endpoint calls remain activity fan-out.
$allResults = @()
$currentHourUtc = [int]([DateTimeOffset]::Parse($orchInput.TriggeredAtUtc).Hour)
$isEvery4hCycle = ($currentHourUtc % 4) -eq 0

foreach ($partner in $partners) {
    $tenantId = Get-OrchestrationInputValue -InputObject $partner -Name 'TenantId'
    $tenantName = Get-OrchestrationInputValue -InputObject $partner -Name 'DisplayName' -DefaultValue "partner-$(([string]$tenantId).Substring(0,8))"
    $securityEndpoints = @($registry.SecurityScoreEndpoints)
    $insightsCatalog = @($registry.InsightsCatalog)
    $insightsReports = @($registry.InsightsReports)

    $collectPartnerInsights = Get-OrchestrationBooleanFlag -InputObject $partner -Name 'CollectPartnerInsights' -DefaultValue $true
    $collectPartnerSecurityScore = Get-OrchestrationBooleanFlag -InputObject $partner -Name 'CollectPartnerSecurityScore' -DefaultValue $true

    $logPrefix = "[$correlationId][$tenantName]"
    Write-Host "$logPrefix Partner collection started for $tenantId; forceCollection=$forceCollection"

    $results = @()
    $circuitBreakerFailures = 0
    $circuitBreakerThreshold = 5

    try {
        $activeSecurity = @()
        if ($collectPartnerSecurityScore) {
            $activeSecurity = if ($forceCollection) {
                @($securityEndpoints)
            }
            else {
                @($securityEndpoints | Where-Object {
                        switch ($_.Frequency) {
                            'Hourly' { $true }
                            'Every4h' { $isEvery4hCycle }
                            'Every6h' { ($currentHourUtc % 6) -eq 0 }
                            default { $true }
                        }
                    })
            }
        }

        $includeInsights = $collectPartnerInsights -and ($isEvery4hCycle -or $forceCollection)

        Write-Host "$logPrefix Active security endpoints: $($activeSecurity.Count)/$($securityEndpoints.Count); includeInsights=$includeInsights; collectPartnerInsights=$collectPartnerInsights; collectPartnerSecurityScore=$collectPartnerSecurityScore; forceCollection=$forceCollection"

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
                foreach ($securityBatch in $batches) {
                    if ($circuitBreakerFailures -ge $circuitBreakerThreshold) {
                        Write-Host "$logPrefix Circuit breaker OPEN - skipping remaining security endpoints."
                        break
                    }

                    $securityTasks = @()
                    foreach ($ep in $securityBatch) {
                        $activityInput = @{
                            CorrelationId               = $correlationId
                            TenantId                    = $tenantId
                            TenantName                  = $tenantName
                            Endpoint                    = $ep
                            AccessToken                 = $graphToken.AccessToken
                            TriggeredAtUtc              = $orchInput.TriggeredAtUtc
                            CollectPartnerSecurityScore = $collectPartnerSecurityScore
                        } | ConvertTo-Json -Depth 10 -Compress

                        $securityTasks += Invoke-DurableActivity -FunctionName 'CollectSecurityScore' -Input $activityInput -NoWait
                    }

                    if ($securityTasks.Count -gt 0) {
                        $batchResults = @(Wait-DurableTask -Task $securityTasks)
                        $results += $batchResults
                        foreach ($r in $batchResults) {
                            if ($r.Status -eq 'Failed') { $circuitBreakerFailures++ } else { $circuitBreakerFailures = 0 }
                        }
                    }
                }
            }
        }

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
                    CorrelationId          = $correlationId
                    TenantId               = $tenantId
                    TenantName             = $tenantName
                    AccessToken            = $insightsToken.AccessToken
                    InsightsAuthMode       = $insightsToken.AuthMode
                    InsightsCatalog        = $insightsCatalog
                    RegistryReports        = $insightsReports
                    EnsureAllDatasets      = $true
                    TriggeredAtUtc         = $orchInput.TriggeredAtUtc
                    CollectPartnerInsights = $collectPartnerInsights
                } | ConvertTo-Json -Depth 10 -Compress

                $results += Invoke-DurableActivity -FunctionName 'CollectInsights' -Input $insightsInput
            }
        }

        $succeeded = @($results | Where-Object { $_.Status -eq 'Succeeded' }).Count
        $failed = @($results | Where-Object { $_.Status -eq 'Failed' }).Count
        $partial = @($results | Where-Object { $_.Status -eq 'Partial' }).Count
        $skipped = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count

        $partnerStatus = if ($results.Count -eq 0) { 'Succeeded' }
        elseif ($failed -eq $results.Count) { 'Failed' }
        elseif ($failed -gt 0 -or $partial -gt 0) { 'Partial' }
        else { 'Succeeded' }

        Write-Host "$logPrefix Partner collection completed: $partnerStatus | OK=$succeeded FAIL=$failed PARTIAL=$partial SKIP=$skipped"

        $allResults += @{
            TenantId           = $tenantId
            TenantName         = $tenantName
            Status             = $partnerStatus
            ItemsTotal         = $results.Count
            ItemsSucceeded     = $succeeded
            ItemsFailed        = $failed
            ItemsPartial       = $partial
            ItemsSkipped       = $skipped
            CircuitBreakerOpen = ($circuitBreakerFailures -ge $circuitBreakerThreshold)
            ForceCollection    = $forceCollection
            CompletedUtc       = $Context.CurrentUtcDateTime.ToString('o')
            Details            = $results
        }
    }
    catch {
        Write-Host "$logPrefix ERROR: Unhandled exception in partner collection: $_"
        $allResults += @{
            TenantId     = $tenantId
            TenantName   = $tenantName
            Status       = 'Failed'
            Error        = $_.Exception.Message
            CompletedUtc = $Context.CurrentUtcDateTime.ToString('o')
        }
    }
}

# Step 4: Aggregate
$succeeded = @($allResults | Where-Object { $_.Status -eq 'Succeeded' }).Count
$failed = @($allResults | Where-Object { $_.Status -eq 'Failed' }).Count
$partial = @($allResults | Where-Object { $_.Status -eq 'Partial' }).Count

$summary = @{
    CorrelationId     = $correlationId
    OrchestrationId   = $Context.InstanceId
    Status            = if ($allResults.Count -eq 0) { 'Failed' }
    elseif ($failed -eq $allResults.Count) { 'Failed' }
    elseif ($failed -gt 0 -or $partial -gt 0) { 'Partial' }
    else { 'Succeeded' }
    PartnersTotal     = $allResults.Count
    PartnersSucceeded = $succeeded
    PartnersFailed    = $failed
    PartnersPartial   = $partial
    StartedUtc        = $orchInput.TriggeredAtUtc
    ForceCollection   = $forceCollection
    CompletedUtc      = $Context.CurrentUtcDateTime.ToString('o')
    PartnerResults    = $allResults
}

Write-Host "[$correlationId] OrchestrateAllTenants completed: $($summary.Status) | OK=$succeeded FAIL=$failed PARTIAL=$partial"

# Step 5: Store run summary
$null = Invoke-DurableActivity -FunctionName 'StoreSummaryBlob' -Input ($summary | ConvertTo-Json -Depth 20 -Compress)

return $summary
