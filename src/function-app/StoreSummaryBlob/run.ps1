param($InputData)

<#
.SYNOPSIS
    Activity function: stores the orchestration summary to Blob Storage.
    Uses Write-StringToBlob from BlobStorageService (which has built-in retry).
#>

$summary = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }
$correlationId = $summary.CorrelationId

Write-Host "[$correlationId] StoreSummaryBlob: Writing orchestration summary"

function Get-InputPropertyValue {
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

function Get-UniqueSummaryDataTypes {
    param(
        [Parameter(Mandatory)]$PartnerResult
    )

    $summaryDataTypes = @()
    $declaredDataTypes = @(Get-InputPropertyValue -InputObject $PartnerResult -Name 'SummaryDataTypes' -DefaultValue @())
    foreach ($dataType in $declaredDataTypes) {
        if (-not [string]::IsNullOrWhiteSpace([string]$dataType)) {
            $summaryDataTypes += Get-OrchestrationSummaryDataType -Value ([string]$dataType)
        }
    }

    $details = @(Get-InputPropertyValue -InputObject $PartnerResult -Name 'Details' -DefaultValue @())
    foreach ($detail in $details) {
        $summaryDataTypes += Get-OrchestrationSummaryDataType -Value $detail
    }

    return @($summaryDataTypes | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function New-DataTypeTenantResult {
    param(
        [Parameter(Mandatory)]$PartnerResult,
        [Parameter(Mandatory)][string]$DataType
    )

    $details = @(Get-InputPropertyValue -InputObject $PartnerResult -Name 'Details' -DefaultValue @())
    $typedDetails = @($details | Where-Object { (Get-OrchestrationSummaryDataType -Value $_) -eq $DataType })

    $succeeded = @($typedDetails | Where-Object { $_.Status -eq 'Succeeded' }).Count
    $failed = @($typedDetails | Where-Object { $_.Status -eq 'Failed' }).Count
    $partial = @($typedDetails | Where-Object { $_.Status -eq 'Partial' }).Count
    $skipped = @($typedDetails | Where-Object { $_.Status -eq 'Skipped' }).Count
    $status = if ($typedDetails.Count -eq 0) { [string](Get-InputPropertyValue -InputObject $PartnerResult -Name 'Status' -DefaultValue 'Succeeded') }
    elseif ($failed -eq $typedDetails.Count) { 'Failed' }
    elseif ($failed -gt 0 -or $partial -gt 0) { 'Partial' }
    else { 'Succeeded' }

    $tenantResult = [ordered]@{
        TenantId           = Get-InputPropertyValue -InputObject $PartnerResult -Name 'TenantId'
        TenantName         = Get-InputPropertyValue -InputObject $PartnerResult -Name 'TenantName'
        DataType           = $DataType
        Status             = $status
        ItemsTotal         = $typedDetails.Count
        ItemsSucceeded     = $succeeded
        ItemsFailed        = $failed
        ItemsPartial       = $partial
        ItemsSkipped       = $skipped
        CircuitBreakerOpen = [bool](Get-InputPropertyValue -InputObject $PartnerResult -Name 'CircuitBreakerOpen' -DefaultValue $false)
        ForceCollection    = [bool](Get-InputPropertyValue -InputObject $PartnerResult -Name 'ForceCollection' -DefaultValue $false)
        CompletedUtc       = Get-InputPropertyValue -InputObject $PartnerResult -Name 'CompletedUtc'
        Details            = $typedDetails
    }

    $errorValue = Get-InputPropertyValue -InputObject $PartnerResult -Name 'Error'
    if (-not [string]::IsNullOrWhiteSpace([string]$errorValue)) {
        $tenantResult.Error = $errorValue
    }

    return $tenantResult
}

try {
    $config = Get-IntegrationConfig
    $partnerResults = if ($summary.PSObject.Properties['PartnerResults']) { @($summary.PartnerResults) } else { @() }
    if ($partnerResults.Count -eq 0) {
        throw 'Orchestration summary did not contain PartnerResults. No tenant summary blobs were written.'
    }

    $completedUtc = [DateTimeOffset]::Parse($summary.CompletedUtc)

    $writtenSummaries = @()
    foreach ($partnerResult in $partnerResults) {
        $tenantId = [string]$partnerResult.TenantId
        $tenantName = [string]$partnerResult.TenantName
        if ([string]::IsNullOrWhiteSpace($tenantId)) { throw 'PartnerResult is missing TenantId.' }
        if ([string]::IsNullOrWhiteSpace($tenantName)) { $tenantName = "partner-$($tenantId.Substring(0, [Math]::Min(8, $tenantId.Length)))" }

        $summaryDataTypes = @(Get-UniqueSummaryDataTypes -PartnerResult $partnerResult)
        if ($summaryDataTypes.Count -eq 0) {
            throw "PartnerResult for tenant '$tenantName' did not contain any summary data types."
        }

        foreach ($dataType in $summaryDataTypes) {
            $blobPath = Get-OrchestrationSummaryBlobPath -TenantId $tenantId -TenantName $tenantName -DataType $dataType -CompletedUtc $completedUtc
            $dataTypeTenantResult = New-DataTypeTenantResult -PartnerResult $partnerResult -DataType $dataType
            $tenantSummary = [ordered]@{
                CorrelationId     = $summary.CorrelationId
                OrchestrationId   = $summary.OrchestrationId
                DataType          = $dataType
                OverallStatus     = $summary.Status
                PartnersTotal     = $summary.PartnersTotal
                PartnersSucceeded = $summary.PartnersSucceeded
                PartnersFailed    = $summary.PartnersFailed
                PartnersPartial   = $summary.PartnersPartial
                StartedUtc        = $summary.StartedUtc
                CompletedUtc      = $summary.CompletedUtc
                ForceCollection   = $summary.ForceCollection
                TenantId          = $tenantId
                TenantName        = $tenantName
                TenantStatus      = $dataTypeTenantResult.Status
                TenantResult      = $dataTypeTenantResult
            }

            $jsonContent = $tenantSummary | ConvertTo-Json -Depth 20
            Write-StringToBlob `
                -BlobPath $blobPath `
                -Content $jsonContent `
                -ContentType 'application/json'

            $writtenSummaries += [pscustomobject]@{
                TenantId   = $tenantId
                TenantName = $tenantName
                DataType   = $dataType
                BlobPath   = "$($config.StorageContainerName)/$blobPath"
            }
        }
    }

    $archiveResult = [pscustomobject]@{ Moved = 0 }
    $archiveWarning = $null
    try {
        $archiveResult = Move-LegacyOrchestrationSummaryBlobsToArchive
    }
    catch {
        $archiveWarning = $_.Exception.Message
        Write-Host "[$correlationId] StoreSummaryBlob: WARNING - legacy hourly summary cleanup failed: $archiveWarning"
    }

    Write-Host "[$correlationId] StoreSummaryBlob: Tenant data-type summaries written=$($writtenSummaries.Count); legacyHourlyMoved=$($archiveResult.Moved)"

    return @{
        BlobPaths                  = $writtenSummaries
        LegacyHourlySummariesMoved = $archiveResult.Moved
        ArchiveWarning             = $archiveWarning
        Status                     = if ($archiveWarning) { 'SucceededWithArchiveWarning' } else { 'Succeeded' }
    }

}
catch {
    Write-Host "[$correlationId] StoreSummaryBlob: FAILED - $($_.Exception.Message)"
    return @{
        BlobPath = $null
        Status   = 'Failed'
        Error    = $_.Exception.Message
    }
}
