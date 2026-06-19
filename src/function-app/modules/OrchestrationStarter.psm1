function Start-CollectionOrchestration {
    [CmdletBinding()]
    param(
        $StarterClient,

        [Parameter(Mandatory)]
        [string]$TriggerSource,

        [bool]$IsPastDue = $false,

        [bool]$ForceCollection = $false
    )

    $correlationId = [guid]::NewGuid().ToString()
    $startTime = [DateTimeOffset]::UtcNow

    Write-Host "[$correlationId] $TriggerSource trigger fired at $($startTime.ToString('o')) (past due: $IsPastDue; force collection: $ForceCollection)"

    $config = Get-IntegrationConfig

    $orchestratorInput = @{
        CorrelationId          = $correlationId
        TriggeredAtUtc         = $startTime.ToString('o')
        TriggerSource          = $TriggerSource
        IsPastDue              = $IsPastDue
        ForceCollection        = $ForceCollection
        MaxConcurrentPartners  = $config.MaxConcurrentPartners
        MaxConcurrentEndpoints = $config.MaxConcurrentEndpoints
    } | ConvertTo-Json -Compress

    $startCommand = Get-Command -Name Start-DurableOrchestration -ErrorAction SilentlyContinue
    if (-not $startCommand) {
        $startCommand = Get-Command -Name Start-NewOrchestration -ErrorAction Stop
    }

    $startParameters = @{ FunctionName = 'OrchestrateAllTenants' }
    if ($startCommand.Parameters.ContainsKey('Input')) {
        $startParameters['Input'] = $orchestratorInput
    }
    elseif ($startCommand.Parameters.ContainsKey('InputObject')) {
        $startParameters['InputObject'] = $orchestratorInput
    }

    if ($null -ne $StarterClient -and $startCommand.Parameters.ContainsKey('DurableClient')) {
        $startParameters['DurableClient'] = $StarterClient
    }

    if ($startCommand.Name -eq 'Start-DurableOrchestration') {
        $instanceId = Start-DurableOrchestration @startParameters
    }
    else {
        $instanceId = Start-NewOrchestration @startParameters
    }

    Write-Host "[$correlationId] Started orchestration instance: $instanceId"
    Write-Host "METRIC: collection.orchestration.started = 1 | correlationId=$correlationId orchestrationId=$instanceId triggerSource=$TriggerSource"

    [pscustomobject]@{
        CorrelationId   = $correlationId
        InstanceId      = $instanceId
        StartedAtUtc    = $startTime.ToString('o')
        ForceCollection = $ForceCollection
    }
}

Export-ModuleMember -Function Start-CollectionOrchestration