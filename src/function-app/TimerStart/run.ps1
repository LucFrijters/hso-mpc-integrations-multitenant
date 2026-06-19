param($Timer, $StarterClient)

<#
.SYNOPSIS
    Timer trigger that starts the main orchestrator.

    Schedule is fixed in function.json as '0 0 */2 * * *' (every 2 hours).
    This hits every gate: Insights and score history every 4 hours UTC, and security
    'Every6h' endpoints at 00/06/12/18 UTC.

    Concurrency and feature flags are resolved here (once, non-replayed) and passed into the
    orchestration input so the orchestrators stay deterministic during Durable replay.
#>

$ErrorActionPreference = 'Stop'

$isPastDue = $false
if ($null -ne $Timer) {
    $isPastDueProperty = $Timer.PSObject.Properties['IsPastDue']
    if ($null -ne $isPastDueProperty) {
        $isPastDue = [bool]$isPastDueProperty.Value
    }
}

Start-CollectionOrchestration `
    -StarterClient $StarterClient `
    -TriggerSource 'Timer' `
    -IsPastDue $isPastDue | Out-Null
