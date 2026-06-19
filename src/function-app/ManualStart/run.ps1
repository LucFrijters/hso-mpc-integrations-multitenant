param($Request, $StarterClient)

$ErrorActionPreference = 'Stop'

$result = Start-CollectionOrchestration `
    -StarterClient $StarterClient `
    -TriggerSource 'ManualHttp' `
    -IsPastDue $false

$body = @{
    Status          = 'Started'
    CorrelationId   = $result.CorrelationId
    OrchestrationId = $result.InstanceId
    StartedAtUtc    = $result.StartedAtUtc
} | ConvertTo-Json -Compress

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [System.Net.HttpStatusCode]::Accepted
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = $body
    })