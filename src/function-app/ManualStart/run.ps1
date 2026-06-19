param($Request, $StarterClient)

$ErrorActionPreference = 'Stop'

try {
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
}
catch {
    Write-Host "ManualStart failed: $($_.Exception.Message)"

    $body = @{
        Status    = 'Failed'
        ErrorType = $_.Exception.GetType().FullName
        Error     = $_.Exception.Message
    } | ConvertTo-Json -Compress

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [System.Net.HttpStatusCode]::InternalServerError
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = $body
        })
}