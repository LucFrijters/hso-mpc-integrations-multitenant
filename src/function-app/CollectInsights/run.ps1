param($InputData)

<#
.SYNOPSIS
    Activity function: executes the full Partner Insights collection flow for one partner account.

    Insights is PARTNER-GLOBAL and asynchronous, so the whole stateful flow runs inside this single
    activity (keeping the Durable orchestration history small and replay-safe):

      1. Enumerate datasets (/ScheduledDataset) and queries (/ScheduledQueries) -> store as JSON.
      2. Resolve the set of reports to collect (registry + every other dataset when EnsureAllDatasets).
        3. Idempotently ensure a scheduled report exists per dataset (create query + report if missing).
        4. Poll the latest COMPLETED execution per report. Newly requested reports can take hours;
            until then they are tracked as pending. Once a completed execution appears, convert the
            CSV/TSV payload to JSON before storing it.

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
        CollectPartnerInsights : bool - defensive tenant source flag
#>

$params = if ($InputData -is [string]) { $InputData | ConvertFrom-Json } else { $InputData }
$correlationId = $params.CorrelationId
$tenantId = $params.TenantId
$tenantName = $params.TenantName
$accessToken = $params.AccessToken
$insightsAuthMode = $params.InsightsAuthMode ?? 'AppPlusUser'
$insightsCatalog = $params.InsightsCatalog
$registryReports = $params.RegistryReports
$ensureAllDatasets = [bool]$params.EnsureAllDatasets
$triggeredAtUtc = $params.TriggeredAtUtc
$collectPartnerInsights = $true
if ($params.PSObject.Properties['CollectPartnerInsights']) {
    $collectPartnerInsights = [bool]$params.CollectPartnerInsights
}

$logPrefix = "[$correlationId][$tenantName][insights]"
if (-not $collectPartnerInsights) {
    Write-Host "$logPrefix CollectInsights: skipped because CollectPartnerInsights=false"
    return @{
        EndpointName    = 'partner-insights'
        ApiSurface      = 'partner-insights'
        Category        = 'insights'
        Status          = 'Skipped'
        InsightsSummary = $null
        Error           = 'CollectPartnerInsights=false'
    }
}

Write-Host "$logPrefix CollectInsights: starting"

$timestamp = [DateTimeOffset]::Parse($triggeredAtUtc)
$config = Get-IntegrationConfig
$requireMfaCompliance = ($insightsAuthMode -eq 'AppPlusUser')
$dataDefinitionsUrl = $config.Insights.DataDefinitionsUrl
$systemQueriesUrl = $config.Insights.SystemQueriesUrl

$summary = @{
    DatasetsStored          = $false
    QueriesStored           = $false
    ReportDefinitionsStored = $false
    ScheduledReportsStored  = $false
    ExecutionMetadataStored = 0
    DatasetCount            = 0
    QueryCount              = 0
    ScheduledReportCount    = 0
    ReportsResolved         = 0
    ReportsCreated          = 0
    ReportsRecreated        = 0
    QueriesCreated          = 0
    ReportsDownloaded       = 0
    ReportsSkippedUnchanged = 0
    ReportsPending          = 0
    Failures                = 0
    Details                 = @()
}

# ── Step 1: Catalog (datasets + queries) ────────────────────────────────────
$datasetsRecords = @()
$queriesRecords = @()
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
            dataDefinitionsUrl     = $dataDefinitionsUrl
            systemQueriesUrl       = $systemQueriesUrl
            collectionCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }

        Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName -Endpoint $cat `
            -JsonPayload $res.RawJson -Metadata $metadata -TimestampUtc $timestamp | Out-Null

        if ($cat.Name -eq 'datasets') { $datasetsRecords = $res.Records; $summary.DatasetsStored = $true; $summary.DatasetCount = $res.Records.Count }
        if ($cat.Name -eq 'queries') { $queriesRecords = $res.Records; $summary.QueriesStored = $true; $summary.QueryCount = $res.Records.Count }

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
    -Datasets $datasetsRecords -Queries $queriesRecords -EnsureAllDatasets $ensureAllDatasets
$summary.ReportsResolved = @($reportDefs).Count
Write-Host "$logPrefix resolved $($summary.ReportsResolved) report definitions to collect"

try {
    $definitionsEndpoint = @{ Name = 'report-definitions'; Category = 'insights-control'; ApiSurface = 'partner-insights' }
    $definitionsMetadata = @{
        correlationId          = $correlationId
        tenantId               = $tenantId
        tenantDisplayName      = $tenantName
        apiSurface             = 'partner-insights'
        endpointCategory       = 'insights-control'
        endpointName           = 'report-definitions'
        recordCount            = @($reportDefs).Count
        dataDefinitionsUrl     = $dataDefinitionsUrl
        systemQueriesUrl       = $systemQueriesUrl
        collectionCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }

    Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName -Endpoint $definitionsEndpoint `
        -JsonPayload (@($reportDefs) | ConvertTo-Json -Depth 20 -AsArray) `
        -Metadata $definitionsMetadata -TimestampUtc $timestamp | Out-Null
    $summary.ReportDefinitionsStored = $true
}
catch {
    $summary.Failures++
    $summary.Details += @{ Item = 'report-definitions'; Status = 'Failed'; Error = $_.Exception.Message }
    Write-Host "$logPrefix report definitions: FAILED - $($_.Exception.Message)"
}

# ── Step 3: existing reports (idempotency) ──────────────────────────────────
$existingReports = @()
try {
    $existingReports = @(Get-InsightsReportList -AccessToken $accessToken -CorrelationId $correlationId `
            -RequireMfaCompliance:$requireMfaCompliance)
}
catch {
    Write-Host "$logPrefix WARNING: could not list existing reports: $($_.Exception.Message)"
}

# ── Step 4: ensure report + download latest execution per dataset ───────────
foreach ($def in @($reportDefs)) {
    $dataset = $def.DatasetName
    try {
        $reg = Register-InsightsReport -Definition $def -ExistingReports $existingReports `
            -AccessToken $accessToken -Config $config -CorrelationId $correlationId

        if ($reg.Created) {
            $summary.ReportsCreated++
            if ($reg.Recreated) { $summary.ReportsRecreated++ }
            if ($reg.QueryCreated) { $summary.QueriesCreated++ }
            # Track within this run so a later auto-dataset with same name is not recreated.
            $existingReports = @($existingReports) + [pscustomobject]@{ reportName = $reg.ReportName; reportId = $reg.ReportId; queryId = $reg.QueryId; reportStatus = 'Active' }
            $summary.Details += @{ Item = "report:$dataset"; Status = $(if ($reg.Recreated) { 'Recreated' } else { 'Created' }); ReportId = $reg.ReportId; ReportName = $reg.ReportName; PreviousStatus = $reg.ExistingStatus }

            if ($reg.QueryResponse) {
                $queryEndpoint = @{ Name = "$dataset-created-query"; Category = 'insights-control'; ApiSurface = 'partner-insights' }
                $queryMetadata = @{
                    correlationId                    = $correlationId
                    tenantId                         = $tenantId
                    tenantDisplayName                = $tenantName
                    apiSurface                       = 'partner-insights'
                    endpointCategory                 = 'insights-control'
                    endpointName                     = "$dataset-created-query"
                    httpMethod                       = 'POST'
                    requestUrl                       = "$($config.ApiSurfaces['partner-insights'].BaseUrl)/ScheduledQueries"
                    queryId                          = $reg.QueryId
                    queryName                        = $reg.QueryName
                    datasetName                      = $dataset
                    datasetMinimumRecurrenceInterval = $def.MinimumRecurrenceIntervalHours
                    recurrenceIntervalHours          = $def.RecurrenceIntervalHours
                    timespan                         = $def.Timespan
                    responseStatusCode               = $reg.QueryResponse.statusCode
                    dataRedacted                     = $reg.QueryResponse.dataRedacted
                    dataDefinitionsUrl               = $dataDefinitionsUrl
                    systemQueriesUrl                 = $systemQueriesUrl
                    collectionCompletedUtc           = [DateTimeOffset]::UtcNow.ToString('o')
                }
                Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName -Endpoint $queryEndpoint `
                    -JsonPayload ($reg.QueryResponse | ConvertTo-Json -Depth 50) -Metadata $queryMetadata `
                    -TimestampUtc $timestamp -FileNameSuffix $reg.QueryId | Out-Null
            }

            if ($reg.ReportResponse) {
                $createdReportEndpoint = @{ Name = "$dataset-created-report"; Category = 'insights-control'; ApiSurface = 'partner-insights' }
                $createdReportMetadata = @{
                    correlationId                    = $correlationId
                    tenantId                         = $tenantId
                    tenantDisplayName                = $tenantName
                    apiSurface                       = 'partner-insights'
                    endpointCategory                 = 'insights-control'
                    endpointName                     = "$dataset-created-report"
                    httpMethod                       = 'POST'
                    requestUrl                       = "$($config.ApiSurfaces['partner-insights'].BaseUrl)/ScheduledReport"
                    queryId                          = $reg.QueryId
                    reportId                         = $reg.ReportId
                    reportName                       = $reg.ReportName
                    datasetName                      = $dataset
                    datasetMinimumRecurrenceInterval = $def.MinimumRecurrenceIntervalHours
                    recurrenceIntervalHours          = $def.RecurrenceIntervalHours
                    timespan                         = $def.Timespan
                    responseStatusCode               = $reg.ReportResponse.statusCode
                    dataRedacted                     = $reg.ReportResponse.dataRedacted
                    recreated                        = [bool]$reg.Recreated
                    previousReportStatus             = $reg.ExistingStatus
                    dataDefinitionsUrl               = $dataDefinitionsUrl
                    systemQueriesUrl                 = $systemQueriesUrl
                    collectionCompletedUtc           = [DateTimeOffset]::UtcNow.ToString('o')
                }
                Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName -Endpoint $createdReportEndpoint `
                    -JsonPayload ($reg.ReportResponse | ConvertTo-Json -Depth 50) -Metadata $createdReportMetadata `
                    -TimestampUtc $timestamp -FileNameSuffix $reg.ReportId | Out-Null
            }
        }

        $exec = Get-InsightsLatestExecution -ReportId $reg.ReportId -AccessToken $accessToken `
            -CorrelationId $correlationId -RequireMfaCompliance:$requireMfaCompliance
        if (-not $exec -or -not $exec.executionId) {
            $summary.ReportsPending++
            $summary.Details += @{ Item = "report:$dataset"; Status = 'Pending'; ReportId = $reg.ReportId }
            Write-Host "$logPrefix report '$dataset': no completed execution yet (pending)"
            continue
        }

        $executionEndpoint = @{ Name = "$dataset-execution"; Category = 'insights-executions'; ApiSurface = 'partner-insights' }
        $executionMetadata = @{
            correlationId                    = $correlationId
            tenantId                         = $tenantId
            tenantDisplayName                = $tenantName
            apiSurface                       = 'partner-insights'
            endpointCategory                 = 'insights-executions'
            endpointName                     = "$dataset-execution"
            httpMethod                       = 'GET'
            requestUrl                       = "$($config.ApiSurfaces['partner-insights'].BaseUrl)/ScheduledReport/execution/$($reg.ReportId)?executionStatus=Completed&getLatestExecution=true"
            queryId                          = $reg.QueryId
            reportId                         = $reg.ReportId
            executionId                      = $exec.executionId
            executionStatus                  = $exec.executionStatus
            reportExpiryTime                 = $exec.reportExpiryTime
            reportGeneratedTime              = $exec.reportGeneratedTime
            dataRedacted                     = $exec.dataRedacted
            responseStatusCode               = $exec.statusCode
            responseMessage                  = $exec.message
            datasetMinimumRecurrenceInterval = $def.MinimumRecurrenceIntervalHours
            recurrenceIntervalHours          = $def.RecurrenceIntervalHours
            timespan                         = $def.Timespan
            dataDefinitionsUrl               = $dataDefinitionsUrl
            systemQueriesUrl                 = $systemQueriesUrl
            collectionCompletedUtc           = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName -Endpoint $executionEndpoint `
            -JsonPayload ($exec | ConvertTo-Json -Depth 50) -Metadata $executionMetadata `
            -TimestampUtc $timestamp -FileNameSuffix $exec.executionId | Out-Null
        $summary.ExecutionMetadataStored++

        $reportEndpoint = @{ Name = $dataset; Category = 'insights-reports'; ApiSurface = 'partner-insights' }
        $executionAlreadyStored = $false
        try {
            $executionAlreadyStored = Test-CollectionExecutionSeen -TenantId $tenantId -TenantName $tenantName `
                -Endpoint $reportEndpoint -ExecutionId $exec.executionId
        }
        catch {
            Write-Host "$logPrefix report '$dataset': execution marker check warning - $($_.Exception.Message)"
        }

        if ($executionAlreadyStored) {
            $summary.ReportsSkippedUnchanged++
            $summary.Details += @{ Item = "report:$dataset"; Status = 'SkippedUnchanged'; ReportId = $reg.ReportId; ExecutionId = $exec.executionId }
            Write-Host "$logPrefix report '$dataset': skipped unchanged execution $($exec.executionId)"
            continue
        }

        $data = Get-InsightsReportData -Execution $exec -Config $config
        if (-not $data) {
            $summary.ReportsPending++
            $summary.Details += @{ Item = "report:$dataset"; Status = 'Pending'; ReportId = $reg.ReportId }
            continue
        }

        $metadata = @{
            correlationId                    = $correlationId
            tenantId                         = $tenantId
            tenantDisplayName                = $tenantName
            apiSurface                       = 'partner-insights'
            endpointCategory                 = 'insights-reports'
            endpointName                     = $dataset
            reportId                         = $reg.ReportId
            executionId                      = $data.ExecutionId
            executionStatus                  = $exec.executionStatus
            reportExpiryTime                 = $exec.reportExpiryTime
            reportGeneratedTime              = $data.GeneratedTime
            sourceFormat                     = $data.Format
            recordCount                      = $data.RowCount
            truncated                        = $data.Truncated
            querySource                      = $def.Source
            dataRedacted                     = $exec.dataRedacted
            datasetMinimumRecurrenceInterval = $def.MinimumRecurrenceIntervalHours
            recurrenceIntervalHours          = $def.RecurrenceIntervalHours
            timespan                         = $def.Timespan
            dataDefinitionsUrl               = $dataDefinitionsUrl
            systemQueriesUrl                 = $systemQueriesUrl
            collectionCompletedUtc           = [DateTimeOffset]::UtcNow.ToString('o')
        }

        $writeResult = Write-CollectionToBlob -TenantId $tenantId -TenantName $tenantName `
            -Endpoint $reportEndpoint -JsonPayload $data.Json -Metadata $metadata `
            -TimestampUtc $timestamp -FileNameSuffix $data.ExecutionId

        try {
            Set-CollectionExecutionSeen -TenantId $tenantId -TenantName $tenantName `
                -Endpoint $reportEndpoint -ExecutionId $data.ExecutionId -DataBlobPath $writeResult.BlobPath `
                -TimestampUtc $timestamp | Out-Null
        }
        catch {
            Write-Host "$logPrefix report '$dataset': execution marker write warning - $($_.Exception.Message)"
        }

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

try {
    $scheduledReports = Get-InsightsReportList -AccessToken $accessToken -CorrelationId $correlationId `
        -RequireMfaCompliance:$requireMfaCompliance
    $summary.ScheduledReportCount = @($scheduledReports).Count

    $scheduledReportsEndpoint = @{ Name = 'scheduled-reports'; Category = 'insights-control'; ApiSurface = 'partner-insights' }
    $scheduledReportsMetadata = @{
        correlationId          = $correlationId
        tenantId               = $tenantId
        tenantDisplayName      = $tenantName
        apiSurface             = 'partner-insights'
        endpointCategory       = 'insights-control'
        endpointName           = 'scheduled-reports'
        httpMethod             = 'GET'
        requestUrl             = "$($config.ApiSurfaces['partner-insights'].BaseUrl)/ScheduledReport"
        recordCount            = @($scheduledReports).Count
        dataDefinitionsUrl     = $dataDefinitionsUrl
        systemQueriesUrl       = $systemQueriesUrl
        collectionCompletedUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }

    $scheduledReportsJson = if (@($scheduledReports).Count -gt 0) { @($scheduledReports) | ConvertTo-Json -Depth 50 -AsArray } else { '[]' }
    Write-CollectionStateToBlob -TenantId $tenantId -TenantName $tenantName -Endpoint $scheduledReportsEndpoint `
        -JsonPayload $scheduledReportsJson `
        -Metadata $scheduledReportsMetadata | Out-Null
    $summary.ScheduledReportsStored = $true
    Write-Host "$logPrefix scheduled reports: $($summary.ScheduledReportCount) current-state records stored"
}
catch {
    $summary.Failures++
    $summary.Details += @{ Item = 'scheduled-reports'; Status = 'Failed'; Error = $_.Exception.Message }
    Write-Host "$logPrefix scheduled reports: FAILED - $($_.Exception.Message)"
}

$status = if ($summary.Failures -gt 0 -and $summary.ReportsDownloaded -eq 0 -and -not $summary.DatasetsStored) { 'Failed' }
elseif ($summary.Failures -gt 0) { 'Partial' }
else { 'Succeeded' }

Write-Host "$logPrefix CollectInsights: $status | datasets=$($summary.DatasetCount) queries=$($summary.QueryCount) scheduledReports=$($summary.ScheduledReportCount) created=$($summary.ReportsCreated) recreated=$($summary.ReportsRecreated) downloaded=$($summary.ReportsDownloaded) skippedUnchanged=$($summary.ReportsSkippedUnchanged) pending=$($summary.ReportsPending) failures=$($summary.Failures)"

return @{
    EndpointName    = 'partner-insights'
    ApiSurface      = 'partner-insights'
    Category        = 'insights'
    Status          = $status
    InsightsSummary = $summary
    Error           = $null
}
