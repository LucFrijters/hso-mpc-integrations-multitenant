param($InputData)

<#
.SYNOPSIS
    Activity function: collects one Microsoft Graph beta Partner Security Score endpoint
    and stores the raw response as JSON in Blob Storage.

    The Partner Security Score is PARTNER-GLOBAL: a single call returns the partner's score
    and (via customerInsights) the security posture of all CSP customers.

    Input:
        CorrelationId  : string
        TenantId       : string  - the HSO partner tenant ID
        TenantName     : string  - partner display name
        Endpoint       : object  - security score endpoint definition from the registry
        AccessToken    : string  - Microsoft Graph access token (AppOnly, PartnerSecurity.Read.All)
        TriggeredAtUtc : string
#>

$params = $InputData | ConvertFrom-Json
$correlationId = $params.CorrelationId
$tenantId = $params.TenantId
$tenantName = $params.TenantName
$endpoint = $params.Endpoint
$accessToken = $params.AccessToken
$triggeredAtUtc = $params.TriggeredAtUtc

$logPrefix = "[$correlationId][$tenantName][$($endpoint.Name)]"
Write-Host "$logPrefix CollectSecurityScore: starting"

$collectionStartUtc = [DateTimeOffset]::UtcNow
$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

try {
    $config = Get-IntegrationConfig

    $apiResult = Invoke-GraphBetaApi `
        -Path $endpoint.Path `
        -AccessToken $accessToken `
        -CorrelationId $correlationId `
        -MaxPages $config.MaxPages `
        -MaxRetries $config.MaxRetries

    $stopwatch.Stop()

    $recordCount = $apiResult.Records.Count
    $jsonPayload = @{
        records    = $apiResult.Records
        totalCount = $recordCount
    } | ConvertTo-Json -Depth 50

    $timestamp = [DateTimeOffset]::Parse($triggeredAtUtc)
    $metadata = @{
        correlationId          = $correlationId
        tenantId               = $tenantId
        tenantDisplayName      = $tenantName
        apiSurface             = $endpoint.ApiSurface
        endpointCategory       = $endpoint.Category
        endpointName           = $endpoint.Name
        httpMethod             = 'GET'
        requestUrl             = "https://graph.microsoft.com/beta$($endpoint.Path)"
        httpStatusCode         = 200
        responseContentLength  = $jsonPayload.Length
        recordCount            = $recordCount
        pageCount              = $apiResult.PageCount
        collectionStartedUtc   = $collectionStartUtc.ToString('o')
        collectionCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        durationMs             = $stopwatch.ElapsedMilliseconds
    }

    $blobResult = Write-CollectionToBlob `
        -TenantId $tenantId `
        -TenantName $tenantName `
        -Endpoint $endpoint `
        -JsonPayload $jsonPayload `
        -Metadata $metadata `
        -TimestampUtc $timestamp

    Write-Host "$logPrefix CollectSecurityScore: stored $recordCount records ($($stopwatch.ElapsedMilliseconds)ms)"

    return @{
        EndpointName = $endpoint.Name
        ApiSurface   = $endpoint.ApiSurface
        Category     = $endpoint.Category
        Status       = 'Succeeded'
        RecordCount  = $recordCount
        BlobPath     = $blobResult.BlobPath
        BytesWritten = $jsonPayload.Length
        DurationMs   = $stopwatch.ElapsedMilliseconds
        Error        = $null
    }

} catch {
    $stopwatch.Stop()
    $errorMsg = $_.Exception.Message
    Write-Host "$logPrefix CollectSecurityScore: FAILED - $errorMsg"

    return @{
        EndpointName = $endpoint.Name
        ApiSurface   = $endpoint.ApiSurface
        Category     = $endpoint.Category
        Status       = 'Failed'
        RecordCount  = 0
        BlobPath     = $null
        BytesWritten = 0
        DurationMs   = $stopwatch.ElapsedMilliseconds
        Error        = $errorMsg
    }
}
