param($InputData)

<#
.SYNOPSIS
    Activity function: stores the orchestration summary to Blob Storage.
    Uses Write-StringToBlob from BlobStorageService (which has built-in retry).
#>

$summary = $InputData | ConvertFrom-Json
$correlationId = $summary.CorrelationId

Write-Host "[$correlationId] StoreSummaryBlob: Writing orchestration summary"

try {
    $config = Get-IntegrationConfig

    $timestamp = [DateTimeOffset]::Parse($summary.CompletedUtc)
    $blobPath = "_orchestration-summaries/$($timestamp.ToString('yyyy'))/$($timestamp.ToString('MM'))/$($timestamp.ToString('dd'))/$($timestamp.ToString('HH'))/summary_$($timestamp.ToString('yyyy-MM-ddTHH-mm-ssZ')).json"

    $jsonContent = $summary | ConvertTo-Json -Depth 20

    # Write via BlobStorageService (includes retry logic)
    Write-StringToBlob `
        -BlobPath $blobPath `
        -Content $jsonContent `
        -ContentType 'application/json'

    Write-Host "[$correlationId] StoreSummaryBlob: Written to $($config.StorageContainerName)/$blobPath"

    return @{
        BlobPath = "$($config.StorageContainerName)/$blobPath"
        Status   = 'Succeeded'
    }

} catch {
    Write-Host "[$correlationId] StoreSummaryBlob: FAILED - $($_.Exception.Message)"
    return @{
        BlobPath = $null
        Status   = 'Failed'
        Error    = $_.Exception.Message
    }
}
