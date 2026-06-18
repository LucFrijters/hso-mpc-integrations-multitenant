param($Timer, $StarterClient)

<#
.SYNOPSIS
    Timer trigger that starts the main orchestrator.

    Schedule is configurable via the TIMER_SCHEDULE app setting (NCRONTAB).
    Default '0 0 */2 * * *' (every 2 hours) hits every gate: security 'Every6h' at 00/06/12/18 UTC,
    and the daily Insights + score-history pass at the configured InsightsDailyHourUtc (default 02).

    Concurrency and feature flags are resolved here (once, non-replayed) and passed into the
    orchestration input so the orchestrators stay deterministic during Durable replay.
#>

$ErrorActionPreference = 'Stop'

$correlationId = [guid]::NewGuid().ToString()
$startTime = [DateTimeOffset]::UtcNow

Write-Host "[$correlationId] Timer trigger fired at $($startTime.ToString('o')) (past due: $($Timer.IsPastDue))"

$config = Get-IntegrationConfig

$orchestratorInput = @{
    CorrelationId          = $correlationId
    TriggeredAtUtc         = $startTime.ToString('o')
    IsPastDue              = $Timer.IsPastDue
    MaxConcurrentPartners  = $config.MaxConcurrentPartners
    MaxConcurrentEndpoints = $config.MaxConcurrentEndpoints
    EnsureAllDatasets      = $config.Insights.EnsureAllDatasets
    InsightsDailyHourUtc   = [int]($env:INSIGHTS_DAILY_HOUR_UTC ?? '2')
} | ConvertTo-Json -Compress

$instanceId = Start-DurableOrchestration `
    -FunctionName 'OrchestrateAllTenants' `
    -Input $orchestratorInput `
    -DurableClient $StarterClient

Write-Host "[$correlationId] Started orchestration instance: $instanceId"
Write-Host "METRIC: collection.orchestration.started = 1 | correlationId=$correlationId orchestrationId=$instanceId"
