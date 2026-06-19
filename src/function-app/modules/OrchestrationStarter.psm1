function Start-CollectionOrchestration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $StarterClient,

        [Parameter(Mandatory)]
        [string]$TriggerSource,

        [bool]$IsPastDue = $false
    )

    $correlationId = [guid]::NewGuid().ToString()
    $startTime = [DateTimeOffset]::UtcNow

    Write-Host "[$correlationId] $TriggerSource trigger fired at $($startTime.ToString('o')) (past due: $IsPastDue)"

    $config = Get-IntegrationConfig

    $orchestratorInput = @{
        CorrelationId          = $correlationId
        TriggeredAtUtc         = $startTime.ToString('o')
        TriggerSource          = $TriggerSource
        IsPastDue              = $IsPastDue
        MaxConcurrentPartners  = $config.MaxConcurrentPartners
        MaxConcurrentEndpoints = $config.MaxConcurrentEndpoints
    } | ConvertTo-Json -Compress

    $instanceId = Start-DurableOrchestration `
        -FunctionName 'OrchestrateAllTenants' `
        -Input $orchestratorInput `
        -DurableClient $StarterClient

    Write-Host "[$correlationId] Started orchestration instance: $instanceId"
    Write-Host "METRIC: collection.orchestration.started = 1 | correlationId=$correlationId orchestrationId=$instanceId triggerSource=$TriggerSource"

    [pscustomobject]@{
        CorrelationId = $correlationId
        InstanceId    = $instanceId
        StartedAtUtc  = $startTime.ToString('o')
    }
}

Export-ModuleMember -Function Start-CollectionOrchestration