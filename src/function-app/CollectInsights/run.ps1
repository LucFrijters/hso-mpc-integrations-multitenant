param($InputData)

<#
.SYNOPSIS
    Activity function: executes the full Partner Insights collection flow for one partner account.

    Insights is PARTNER-GLOBAL and asynchronous, so the whole stateful flow runs inside this single
    activity (keeping the Durable orchestration history small and replay-safe):

      1. Enumerate datasets (/ScheduledDataset) and queries (/ScheduledQueries) -> store as JSON.
      2. Resolve the set of reports to collect (registry + every other dataset when EnsureAllDatasets).
      3. Idempotently ensure a scheduled report exists per dataset (create query + report if missing).
      4. Download the latest COMPLETED execution per report, de-duplicated by executionId, and
         convert the CSV/TSV payload to JSON before storing.

    Input:
        CorrelationId   : string
        TenantId        : string  - partner tenant ID
        TenantName      : string  - partner display name
        AccessToken     : string  - Insights access token (partnercenter/.default)
        InsightsAuthMode : string - AppPlusUser enables Partner Center MFA validation
        InsightsCatalog : array   - catalog endpoint definitions (datasets, queries)
        RegistryReports : array   - InsightsReports definitions from the registry
        EnsureAllDatasets : bool
        TriggeredAtUtc  : string
#>

$params = $InputData | ConvertFrom-Json
$correlationId = $params.CorrelationId
$tenantId = $params.TenantId
$tenantName = $params.TenantName
$accessToken = $params.AccessToken
$insightsAuthMode = $params.InsightsAuthMode ?? 'AppPlusUser'
$insightsCatalog = $params.InsightsCatalog
$registryReports = $params.RegistryReports
$ensureAllDatasets = [bool]$params.EnsureAllDatasets
$triggeredAtUtc = $params.TriggeredAtUtc

$logPrefix = "[$correlationId][$tenantName][insights]"
Write-Host "$logPrefix CollectInsights: starting"

$timestamp = [DateTimeOffset]::Parse($triggeredAtUtc)
$config = Get-IntegrationConfig
$requireMfaCompliance = ($insightsAuthMode -eq 'AppPlusUser')

$summary = @{
    DatasetsStored    = $false
    QueriesStored     = $false
    DatasetCount      = 0
    QueryCount        = 0
    ReportsResolved   = 0
    ReportsCreated    = 0
    ReportsDownloaded = 0
    ReportsPending    = 0
    ReportsSkipped    = 0
    Failures          = 0
    Details           = @()
}

# ── Step 1: Catalog (datasets + queries) ────────────────────────────────────
$datasetsRecords = @()
foreach ($cat in @($insightsCatalog)) {
    try {
        $res = Get-InsightsCollection -Path $cat.Path -AccessToken $accessToken `
            -CorrelationId $correlationId -MaxPages $config.MaxPages -MaxRetries $config.MaxRetries `
            -RequireMfaCompliance:$requireMfaCompliance

        $metadata = @{
            correlationId          = $correlationId
            tenantId               = $tenantId
            tenantDisplayName      = $tenantName
            apiSurface             = $cat.ApiSurface
            endpointCategory       = $cat.Category
            endpointName           = $cat.Name
            httpMethod             = 'GET'
            requestUrl             = "$($config.ApiSurfaces['partner-insights'].BaseUrl)$($cat.Path)"
            httpStatusCode         = 200
            recordCount            = $res.Records.Count
            pageCount              = $res.PageCount
            collectionCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }

        Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName -Endpoint $cat `
            -JsonPayload $res.RawJson -Metadata $metadata -TimestampUtc $timestamp | Out-Null

        if ($cat.Name -eq 'datasets') { $datasetsRecords = $res.Records; $summary.DatasetsStored = $true; $summary.DatasetCount = $res.Records.Count }
        if ($cat.Name -eq 'queries') { $summary.QueriesStored = $true; $summary.QueryCount = $res.Records.Count }

        Write-Host "$logPrefix catalog '$($cat.Name)': $($res.Records.Count) records stored"
    }
    catch {
        $summary.Failures++
        $summary.Details += @{ Item = "catalog:$($cat.Name)"; Status = 'Failed'; Error = $_.Exception.Message }
        Write-Host "$logPrefix catalog '$($cat.Name)': FAILED - $($_.Exception.Message)"
    }
}

# ── Step 2: Resolve reports to collect ──────────────────────────────────────
$reportDefs = Resolve-InsightsReportsToCollect -RegistryReports $registryReports `
    -Datasets $datasetsRecords -EnsureAllDatasets $ensureAllDatasets
$summary.ReportsResolved = @($reportDefs).Count
Write-Host "$logPrefix resolved $($summary.ReportsResolved) report definitions to collect"

# ── Step 3: existing reports (idempotency) ──────────────────────────────────
$existingReports = @()
try {
    $existingReports = Get-InsightsReportList -AccessToken $accessToken -CorrelationId $correlationId `
        -RequireMfaCompliance:$requireMfaCompliance
}
catch {
    Write-Host "$logPrefix WARNING: could not list existing reports: $($_.Exception.Message)"
}

# ── Step 4: ensure report + download latest execution per dataset ───────────
foreach ($def in @($reportDefs)) {
    $dataset = $def.DatasetName
    try {
        $reg = Register-InsightsReport -Definition $def -ExistingReports $existingReports `
            -AccessToken $accessToken -Config $config -CorrelationId $correlationId `
            -RequireMfaCompliance:$requireMfaCompliance

        if ($reg.Created) {
            $summary.ReportsCreated++
            # Track within this run so a later auto-dataset with same name is not recreated.
            $existingReports += [pscustomobject]@{ reportName = $reg.ReportName; reportId = $reg.ReportId }
        }

        $exec = Get-InsightsLatestExecution -ReportId $reg.ReportId -AccessToken $accessToken `
            -CorrelationId $correlationId -RequireMfaCompliance:$requireMfaCompliance
        if (-not $exec -or -not $exec.executionId) {
            $summary.ReportsPending++
            $summary.Details += @{ Item = "report:$dataset"; Status = 'Pending'; ReportId = $reg.ReportId }
            Write-Host "$logPrefix report '$dataset': no completed execution yet (pending)"
            continue
        }

        # Execution-level idempotency: skip if this execution was already collected.
        $markerPath = "_insights-state/$tenantId/$($reg.ReportId)/$($exec.executionId).json"
        if (Test-BlobExists -BlobPath $markerPath) {
            $summary.ReportsSkipped++
            $summary.Details += @{ Item = "report:$dataset"; Status = 'Skipped'; ExecutionId = $exec.executionId }
            Write-Host "$logPrefix report '$dataset': execution $($exec.executionId) already collected (skip)"
            continue
        }

        $data = Get-InsightsReportData -Execution $exec -Config $config
        if (-not $data) {
            $summary.ReportsPending++
            $summary.Details += @{ Item = "report:$dataset"; Status = 'Pending'; ReportId = $reg.ReportId }
            continue
        }

        $reportEndpoint = @{ Name = $dataset; Category = 'insights-reports'; ApiSurface = 'partner-insights' }
        $metadata = @{
            correlationId          = $correlationId
            tenantId               = $tenantId
            tenantDisplayName      = $tenantName
            apiSurface             = 'partner-insights'
            endpointCategory       = 'insights-reports'
            endpointName           = $dataset
            reportId               = $reg.ReportId
            executionId            = $data.ExecutionId
            reportGeneratedTime    = $data.GeneratedTime
            sourceFormat           = $data.Format
            recordCount            = $data.RowCount
            truncated              = $data.Truncated
            querySource            = $def.Source
            collectionCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }

        $blobResult = Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName `
            -Endpoint $reportEndpoint -JsonPayload $data.Json -Metadata $metadata `
            -TimestampUtc $timestamp -FileNameSuffix $data.ExecutionId

        # Write the idempotency marker only after a successful store.
        $markerContent = @{ collectedUtc = [DateTimeOffset]::UtcNow.ToString('o'); blobPath = $blobResult.BlobPath; rowCount = $data.RowCount } | ConvertTo-Json -Compress
        Write-StringToBlob -BlobPath $markerPath -Content $markerContent -ContentType 'application/json'

        $summary.ReportsDownloaded++
        $summary.Details += @{ Item = "report:$dataset"; Status = 'Downloaded'; ExecutionId = $data.ExecutionId; RowCount = $data.RowCount }
        Write-Host "$logPrefix report '$dataset': downloaded execution $($data.ExecutionId), $($data.RowCount) rows"

    }
    catch {
        $summary.Failures++
        $summary.Details += @{ Item = "report:$dataset"; Status = 'Failed'; Error = $_.Exception.Message }
        Write-Host "$logPrefix report '$dataset': FAILED - $($_.Exception.Message)"
    }
}

$status = if ($summary.Failures -gt 0 -and ($summary.ReportsDownloaded + $summary.ReportsSkipped) -eq 0 -and -not $summary.DatasetsStored) { 'Failed' }
elseif ($summary.Failures -gt 0) { 'Partial' }
else { 'Succeeded' }

Write-Host "$logPrefix CollectInsights: $status | datasets=$($summary.DatasetCount) queries=$($summary.QueryCount) created=$($summary.ReportsCreated) downloaded=$($summary.ReportsDownloaded) pending=$($summary.ReportsPending) skipped=$($summary.ReportsSkipped) failures=$($summary.Failures)"

return @{
    EndpointName    = 'partner-insights'
    ApiSurface      = 'partner-insights'
    Category        = 'insights'
    Status          = $status
    InsightsSummary = $summary
    Error           = $null
}
