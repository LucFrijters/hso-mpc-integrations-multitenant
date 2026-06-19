<#
.SYNOPSIS
    Partner Center Insights programmatic analytics client.

    Implements the asynchronous report paradigm:
      1. Enumerate datasets (/ScheduledDataset) and queries (/ScheduledQueries)  -> stored as JSON.
      2. Ensure (idempotently) a scheduled report per dataset, using Microsoft system queries
         where available or a generated SELECT query otherwise.
      3. Download the latest COMPLETED execution via its secure SAS link.
      4. Convert the CSV/TSV report payload to JSON for blob storage.

    Resilience: all HTTP goes through Invoke-ApiWithRetry (429/5xx/Retry-After aware).
    Collection: reports are created once and reused; the latest completed execution is downloaded
    and stored every collection cycle so the blob store always has a full run snapshot.

    Requires ApiClient.psm1 (Invoke-ApiWithRetry) and IntegrationConfig.psm1 to be imported.
#>

# ─────────────────────────────────────────────────────────────────────────────
# Low-level request helpers
# ─────────────────────────────────────────────────────────────────────────────

function Get-HttpResponseHeaderValue {
    <# .SYNOPSIS Reads a response header across PowerShell/WebResponse header shapes. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not $Response -or -not $Response.Headers) { return $null }
    $headers = $Response.Headers

    if ($headers -is [System.Collections.IDictionary]) {
        foreach ($key in $headers.Keys) {
            if ([string]::Equals([string]$key, $Name, [System.StringComparison]::OrdinalIgnoreCase)) {
                $value = $headers[$key]
                if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                    return [string]($value | Select-Object -First 1)
                }
                return [string]$value
            }
        }
    }

    try {
        $values = $headers.GetValues($Name)
        if ($values -and $values.Count -gt 0) { return [string]$values[0] }
    }
    catch {
        Write-Verbose "Response headers do not support GetValues('$Name'): $($_.Exception.Message)"
    }

    try {
        $value = $headers[$Name]
        if ($value) {
            if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                return [string]($value | Select-Object -First 1)
            }
            return [string]$value
        }
    }
    catch {
        Write-Verbose "Response headers do not support index lookup for '$Name': $($_.Exception.Message)"
    }

    return $null
}


function Assert-PartnerCenterMfaCompliance {
    <# .SYNOPSIS Validates Partner Center's isMfaCompliant response header when present. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Response,
        [Parameter(Mandatory)][string]$Uri
    )

    $mfaHeader = Get-HttpResponseHeaderValue -Response $Response -Name 'isMfaCompliant'
    if (-not $mfaHeader) {
        Write-Warning "ValidateMfa was requested for $Uri, but Partner Center did not return the isMfaCompliant response header."
        return
    }

    if ($mfaHeader -ine 'true') {
        throw "Partner Center MFA validation failed for $Uri (isMfaCompliant=$mfaHeader). Re-run Secure Application Model consent with an MFA-compliant partner account."
    }
}


function Assert-InsightsResponseSuccess {
    <# .SYNOPSIS Fails when Partner Center returns an error envelope with HTTP 200. #>
    [CmdletBinding()]
    param(
        $Body,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Method
    )

    if (-not $Body -or -not ($Body.PSObject.Properties.Name -contains 'statusCode')) { return }

    $statusCode = 0
    if (-not [int]::TryParse([string]$Body.statusCode, [ref]$statusCode)) { return }
    if ($statusCode -lt 400) { return }

    $message = if ($Body.PSObject.Properties.Name -contains 'message' -and $Body.message) { [string]$Body.message } else { 'Partner Insights API returned an error response envelope.' }
    throw "Partner Insights API returned statusCode=$statusCode for $Method ${Path}: $message"
}

function Invoke-InsightsRequest {
    <#
    .SYNOPSIS
        Issues a single Insights API request and returns the parsed response body object.
    .OUTPUTS
        PSCustomObject (parsed JSON) or $null when the resource is not found / not ready (404).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AccessToken,
        [ValidateSet('GET', 'POST')][string]$Method = 'GET',
        $Body,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [int]$MaxRetries = 3,
        [switch]$RequireMfaCompliance
    )

    $surface = Get-ApiSurfaceConfig -ApiSurface 'partner-insights'
    $url = if ($Path -match '^https?://') { $Path } else { "$($surface.BaseUrl)$Path" }

    $headers = @{
        'Authorization'    = "Bearer $AccessToken"
        'Accept'           = 'application/json'
        'ms-correlationid' = $CorrelationId
        'ms-requestid'     = [guid]::NewGuid().ToString()
    }
    if ($RequireMfaCompliance) { $headers['ValidateMfa'] = 'true' }

    $jsonBody = $null
    if ($Body) {
        $jsonBody = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
    }

    $response = Invoke-ApiWithRetry -Uri $url -Headers $headers -Method $Method `
        -Body $jsonBody -ContentType 'application/json' -MaxRetries $MaxRetries

    if ($null -eq $response) { return $null }
    if ($RequireMfaCompliance) {
        Assert-PartnerCenterMfaCompliance -Response $response -Uri $url
    }
    $bodyObject = $response.Content | ConvertFrom-Json
    Assert-InsightsResponseSuccess -Body $bodyObject -Path $url -Method $Method
    return $bodyObject
}


function Get-InsightsCollection {
    <#
    .SYNOPSIS
        GETs an Insights collection endpoint and follows nextLink pagination.
        Aggregates the 'value' arrays from each page.
    .OUTPUTS
        Hashtable: Records (array), PageCount, TotalBytes, RawJson.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AccessToken,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [int]$MaxPages = 100,
        [int]$MaxRetries = 3,
        [switch]$RequireMfaCompliance
    )

    $surface = Get-ApiSurfaceConfig -ApiSurface 'partner-insights'
    $allRecords = @()
    $pageCount = 0
    $totalBytes = 0
    $nextPath = $Path

    while ($nextPath -and $pageCount -lt $MaxPages) {
        $pageCount++

        $body = Invoke-InsightsRequest -Path $nextPath -AccessToken $AccessToken `
            -Method GET -CorrelationId $CorrelationId -MaxRetries $MaxRetries `
            -RequireMfaCompliance:$RequireMfaCompliance
        if ($null -eq $body) { break }

        if ($null -ne $body.value) {
            $allRecords += $body.value
        }
        elseif ($null -ne $body) {
            $allRecords += $body
        }

        $totalBytes += ([System.Text.Encoding]::UTF8.GetByteCount(($body | ConvertTo-Json -Depth 50 -Compress)))

        # nextLink may be absolute or relative to the surface base URL.
        $next = $body.nextLink
        if ($next -and $next -notmatch '^https?://') {
            $next = "$($surface.BaseUrl)$next"
        }
        $nextPath = $next
    }

    return @{
        Records    = $allRecords
        PageCount  = $pageCount
        TotalBytes = $totalBytes
        RawJson    = ($allRecords | ConvertTo-Json -Depth 50 -AsArray)
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# Catalog: datasets and queries
# ─────────────────────────────────────────────────────────────────────────────

function Get-InsightsDatasets {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance
    )
    return Get-InsightsCollection -Path '/ScheduledDataset' -AccessToken $AccessToken `
        -CorrelationId $CorrelationId -RequireMfaCompliance:$RequireMfaCompliance
}


function Get-InsightsQueries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance
    )
    return Get-InsightsCollection -Path '/ScheduledQueries' -AccessToken $AccessToken `
        -CorrelationId $CorrelationId -RequireMfaCompliance:$RequireMfaCompliance
}


function Get-InsightsReportList {
    <#
    .SYNOPSIS
        Lists all scheduled reports already defined for the partner (used for idempotency).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AccessToken,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance
    )
    $result = Get-InsightsCollection -Path '/ScheduledReport' -AccessToken $AccessToken `
        -CorrelationId $CorrelationId -RequireMfaCompliance:$RequireMfaCompliance
    return @($result.Records)
}


# ─────────────────────────────────────────────────────────────────────────────
# Pure helpers (unit-testable, no network)
# ─────────────────────────────────────────────────────────────────────────────

function Get-InsightsDatasetName {
    <# .SYNOPSIS Defensively extracts a dataset's name across possible field spellings. #>
    [CmdletBinding()]
    param($Dataset)
    if (-not $Dataset) { return $null }
    foreach ($p in @('datasetName', 'DatasetName', 'name', 'Name')) {
        if ($Dataset.PSObject.Properties.Name -contains $p -and $Dataset.$p) { return [string]$Dataset.$p }
    }
    return $null
}


function Get-InsightsDatasetPropertyValue {
    <# .SYNOPSIS Reads a dataset property across possible field spellings. #>
    [CmdletBinding()]
    param(
        $Dataset,
        [Parameter(Mandatory)][string[]]$PropertyNames
    )

    if (-not $Dataset) { return $null }
    foreach ($propertyName in $PropertyNames) {
        if ($Dataset.PSObject.Properties.Name -contains $propertyName) {
            return $Dataset.$propertyName
        }
    }
    return $null
}


function Get-InsightsDatasetColumns {
    <# .SYNOPSIS Defensively extracts selectable column names from a dataset definition. #>
    [CmdletBinding()]
    param($Dataset)
    if (-not $Dataset) { return @() }

    $colContainer = Get-InsightsDatasetPropertyValue -Dataset $Dataset `
        -PropertyNames @('selectableColumns', 'SelectableColumns', 'columns', 'Columns', 'availableColumns')
    if (-not $colContainer) { return @() }

    $names = @()
    foreach ($column in @($colContainer)) {
        if ($column -is [string]) { $names += $column }
        elseif ($column.PSObject.Properties.Name -contains 'name') { $names += [string]$column.name }
        elseif ($column.PSObject.Properties.Name -contains 'columnName') { $names += [string]$column.columnName }
        elseif ($column.PSObject.Properties.Name -contains 'Name') { $names += [string]$column.Name }
    }
    return @($names | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}


function Get-InsightsDatasetAvailableDateRanges {
    <# .SYNOPSIS Extracts available TIMESPAN values for a dataset. #>
    [CmdletBinding()]
    param($Dataset)

    $rangeContainer = Get-InsightsDatasetPropertyValue -Dataset $Dataset `
        -PropertyNames @('availableDateRanges', 'AvailableDateRanges', 'dateRanges', 'DateRanges', 'availableTimeRanges', 'AvailableTimeRanges')
    if (-not $rangeContainer) { return @() }

    $ranges = @()
    foreach ($rangeItem in @($rangeContainer)) {
        if ($rangeItem -is [string]) {
            $ranges += $rangeItem
            continue
        }

        foreach ($propertyName in @('name', 'Name', 'value', 'Value', 'dateRange', 'DateRange', 'range', 'Range')) {
            if ($rangeItem.PSObject.Properties.Name -contains $propertyName -and $rangeItem.$propertyName) {
                $ranges += [string]$rangeItem.$propertyName
                break
            }
        }
    }

    return @($ranges | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
}


function Select-InsightsDatasetTimespan {
    <# .SYNOPSIS Chooses a valid query TIMESPAN from a dataset's availableDateRanges. #>
    [CmdletBinding()]
    param($Dataset)

    $availableRanges = @(Get-InsightsDatasetAvailableDateRanges -Dataset $Dataset)
    if ($availableRanges.Count -eq 0) { return $null }

    foreach ($preferredRange in @('LAST_6_MONTHS', 'LAST_12_MONTHS', 'LAST_3_MONTHS', 'LAST_MONTH', 'LAST_1_MONTH', 'LAST_30_DAYS', 'LAST_7_DAYS')) {
        $matchedRange = @($availableRanges | Where-Object { [string]::Equals($_, $preferredRange, [System.StringComparison]::OrdinalIgnoreCase) })
        if ($matchedRange.Count -gt 0) { return [string]$matchedRange[0] }
    }

    if (@($availableRanges | Where-Object { $_ -ne 'LIFETIME' }).Count -eq 0) { return $null }

    return [string]$availableRanges[0]
}


function Get-InsightsQueryId {
    <# .SYNOPSIS Defensively extracts queryId across field spellings. #>
    [CmdletBinding()]
    param($Query)

    if (-not $Query) { return $null }
    foreach ($propertyName in @('queryId', 'QueryId', 'id', 'Id')) {
        if ($Query.PSObject.Properties.Name -contains $propertyName -and $Query.$propertyName) {
            return [string]$Query.$propertyName
        }
    }
    return $null
}


function Get-InsightsQueryText {
    <# .SYNOPSIS Defensively extracts the query text across field spellings. #>
    [CmdletBinding()]
    param($Query)

    if (-not $Query) { return $null }
    foreach ($propertyName in @('query', 'Query', 'queryText', 'QueryText')) {
        if ($Query.PSObject.Properties.Name -contains $propertyName -and $Query.$propertyName) {
            return [string]$Query.$propertyName
        }
    }
    return $null
}


function Get-InsightsQueryProjectionColumns {
    <# .SYNOPSIS Extracts the SELECT projection columns from a Partner Insights query. #>
    [CmdletBinding()]
    param([string]$Query)

    if ([string]::IsNullOrWhiteSpace($Query)) { return @() }
    $match = [regex]::Match($Query, '(?is)^\s*SELECT\s+(.*?)\s+FROM\s+')
    if (-not $match.Success) { return @() }

    return @($match.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}


function Get-InsightsQueryMissingColumns {
    <# .SYNOPSIS Returns projected query columns absent from the current dataset selectableColumns. #>
    [CmdletBinding()]
    param(
        [string]$Query,
        [string[]]$DatasetColumns
    )

    $projectedColumns = @(Get-InsightsQueryProjectionColumns -Query $Query)
    if ($projectedColumns.Count -eq 0) { return @('__unparseable_query__') }

    $available = @{}
    foreach ($column in @($DatasetColumns)) {
        if (-not [string]::IsNullOrWhiteSpace($column)) { $available[$column] = $true }
    }

    return @($projectedColumns | Where-Object { -not $available.ContainsKey($_) })
}


function Test-InsightsSystemQueryCompatible {
    <# .SYNOPSIS Checks whether a system query projection matches live selectableColumns. #>
    [CmdletBinding()]
    param(
        [string]$Query,
        [string[]]$DatasetColumns
    )

    return (@(Get-InsightsQueryMissingColumns -Query $Query -DatasetColumns $DatasetColumns).Count -eq 0)
}


function Get-InsightsDatasetMinimumRecurrenceInterval {
    <# .SYNOPSIS Reads minimumRecurrenceInterval in hours when supplied by /ScheduledDataset. #>
    [CmdletBinding()]
    param($Dataset)

    $rawValue = Get-InsightsDatasetPropertyValue -Dataset $Dataset `
        -PropertyNames @('minimumRecurrenceInterval', 'MinimumRecurrenceInterval', 'minRecurrenceInterval', 'MinRecurrenceInterval')
    if ($null -eq $rawValue) { return $null }

    $firstValue = @($rawValue | Where-Object { $null -ne $_ } | Select-Object -First 1)
    if ($firstValue.Count -eq 0) { return $null }

    $parsedValue = 0
    if ([int]::TryParse([string]$firstValue[0], [ref]$parsedValue)) {
        return $parsedValue
    }
    return $null
}


function Get-ClampedInsightsRecurrenceInterval {
    <# .SYNOPSIS Applies Partner Insights RecurrenceInterval bounds: clamp(max(4, datasetMin), 4, 2160). #>
    [CmdletBinding()]
    param([AllowNull()]$MinimumRecurrenceIntervalHours)

    $datasetMinimum = 0
    if ($null -ne $MinimumRecurrenceIntervalHours) {
        [int]::TryParse([string]$MinimumRecurrenceIntervalHours, [ref]$datasetMinimum) | Out-Null
    }

    $interval = [Math]::Max(4, $datasetMinimum)
    return [Math]::Min(2160, [Math]::Max(4, $interval))
}


function New-DatasetSelectQuery {
    <#
    .SYNOPSIS
        Builds a report query that selects explicit selectableColumns from a dataset.
        Partner Center's report query grammar does not support SELECT *.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatasetName,
        [string[]]$Columns,
        [AllowNull()][string]$Timespan
    )

    $selectedColumns = @($Columns | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($selectedColumns.Count -eq 0) {
        throw "Dataset '$DatasetName' has no selectableColumns; skipping generated Partner Insights query."
    }

    $query = "SELECT $($selectedColumns -join ',') FROM $DatasetName"
    if (-not [string]::IsNullOrWhiteSpace($Timespan)) { $query += " TIMESPAN $Timespan" }
    return $query
}


function Get-InsightsReportName {
    <# .SYNOPSIS Deterministic, prefixed report name so ensure-report is idempotent. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatasetName,
        [Parameter(Mandatory)]$Config
    )
    $prefix = $Config.Insights.ReportNamePrefix
    return "$prefix$DatasetName"
}


function Get-InsightsQueryName {
    <# .SYNOPSIS Builds a Partner Center-safe generated query name: alphanumerics and whitespace only. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatasetName,
        [Parameter(Mandatory)]$Config
    )

    $prefix = [string]$Config.Insights.ReportNamePrefix
    $rawName = "$prefix $DatasetName query $([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
    $safeName = ($rawName -replace '[^a-zA-Z0-9\s]', ' ') -replace '\s+', ' '
    $safeName = $safeName.Trim()
    if ([string]::IsNullOrWhiteSpace($safeName)) { return "Insights query $([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))" }
    return $safeName
}

function Get-InsightsReportStatus {
    <# .SYNOPSIS Reads reportStatus defensively from a scheduled report record. #>
    [CmdletBinding()]
    param($Report)

    if (-not $Report) { return $null }
    foreach ($propertyName in @('reportStatus', 'ReportStatus', 'status', 'Status')) {
        if ($Report.PSObject.Properties.Name -contains $propertyName -and $Report.$propertyName) {
            return [string]$Report.$propertyName
        }
    }
    return $null
}


function Test-InsightsReportNameMatches {
    <# .SYNOPSIS Matches the deterministic base report name and recreated suffixed names. #>
    [CmdletBinding()]
    param(
        $Report,
        [Parameter(Mandatory)][string]$ReportName
    )

    if (-not $Report -or -not $Report.reportName) { return $false }
    return ($Report.reportName -eq $ReportName -or $Report.reportName -like "$ReportName-*")
}


function Test-InsightsReportIsReusable {
    <# .SYNOPSIS Only Active scheduled reports are safe to reuse. #>
    [CmdletBinding()]
    param($Report)

    $status = Get-InsightsReportStatus -Report $Report
    return ($status -and $status -ieq 'Active')
}


function New-InsightsRecreatedReportName {
    <# .SYNOPSIS Builds a unique report name while preserving the deterministic base prefix. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReportName)

    return "$ReportName-$([DateTimeOffset]::UtcNow.ToString('yyyyMMddHHmmss'))"
}


function Convert-DelimitedToJson {
    <#
    .SYNOPSIS
        Converts a CSV or TSV string into a JSON array of row objects.
        Honours a max-row guard to bound memory.
    .OUTPUTS
        Hashtable: Records (array), RowCount, Json (string), Truncated (bool).
    #>
    [CmdletBinding()]
    param(
        [string]$Content,
        [ValidateSet('CSV', 'TSV')][string]$Format = 'CSV',
        [int]$MaxRows = 500000
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @{ Records = @(); RowCount = 0; Json = '[]'; Truncated = $false }
    }

    $delimiter = if ($Format -eq 'TSV') { "`t" } else { ',' }

    # ConvertFrom-Csv correctly handles headers, quoted fields and embedded delimiters.
    $records = @($Content | ConvertFrom-Csv -Delimiter $delimiter)

    $truncated = $false
    if ($records.Count -gt $MaxRows) {
        $records = $records[0..($MaxRows - 1)]
        $truncated = $true
    }

    $json = $records | ConvertTo-Json -Depth 10 -AsArray
    if ([string]::IsNullOrEmpty($json)) { $json = '[]' }

    return @{ Records = $records; RowCount = $records.Count; Json = $json; Truncated = $truncated }
}


function Resolve-InsightsReportsToCollect {
    <#
    .SYNOPSIS
        Computes the full set of Insights reports to ensure + download:
        registry-defined reports first, then (optionally) one generated report per remaining dataset.
        Generated reports are skipped when a dataset has no selectableColumns.
    .OUTPUTS
        Array of definition hashtables: DatasetName, SystemQueryId, CustomQuery, Frequency, Source,
        RecurrenceIntervalHours, MinimumRecurrenceIntervalHours, Timespan, ColumnCount.
    #>
    [CmdletBinding()]
    param(
        $RegistryReports,
        $Datasets,
        $Queries,
        [bool]$EnsureAllDatasets = $true
    )

    $result = @()
    $covered = @{}
    $datasetByName = @{}
    $queryById = @{}

    foreach ($datasetRecord in @($Datasets)) {
        $datasetName = Get-InsightsDatasetName -Dataset $datasetRecord
        if (-not $datasetName) { continue }
        $datasetByName[$datasetName.ToLowerInvariant()] = $datasetRecord
    }

    foreach ($queryRecord in @($Queries)) {
        $queryId = Get-InsightsQueryId -Query $queryRecord
        if (-not $queryId) { continue }
        $queryById[$queryId] = $queryRecord
    }

    foreach ($registryReport in @($RegistryReports)) {
        if (-not $registryReport.DatasetName) { continue }
        $datasetKey = $registryReport.DatasetName.ToLowerInvariant()
        if (-not $datasetByName.ContainsKey($datasetKey)) { continue }
        $covered[$datasetKey] = $true

        $datasetRecord = if ($datasetByName.ContainsKey($datasetKey)) { $datasetByName[$datasetKey] } else { $null }
        $minimumRecurrenceInterval = Get-InsightsDatasetMinimumRecurrenceInterval -Dataset $datasetRecord
        $recurrenceInterval = Get-ClampedInsightsRecurrenceInterval -MinimumRecurrenceIntervalHours $minimumRecurrenceInterval
        $timespan = Select-InsightsDatasetTimespan -Dataset $datasetRecord
        $columns = @(Get-InsightsDatasetColumns -Dataset $datasetRecord)
        if ($columns.Count -eq 0) { continue }

        $systemQueryId = $null
        $customQuery = $null
        $source = 'registry'
        $missingColumns = @()
        $queryRecord = if ($registryReport.SystemQueryId -and $queryById.ContainsKey($registryReport.SystemQueryId)) { $queryById[$registryReport.SystemQueryId] } else { $null }
        $queryText = Get-InsightsQueryText -Query $queryRecord
        if ($queryText -and (Test-InsightsSystemQueryCompatible -Query $queryText -DatasetColumns $columns)) {
            $systemQueryId = $registryReport.SystemQueryId
        }
        else {
            $customQuery = New-DatasetSelectQuery -DatasetName $registryReport.DatasetName -Columns $columns -Timespan $timespan
            $source = if ($queryRecord) { 'registry-schema-fallback' } else { 'registry-catalog-fallback' }
            if ($queryText) { $missingColumns = @(Get-InsightsQueryMissingColumns -Query $queryText -DatasetColumns $columns) }
        }

        $result += @{
            DatasetName                     = $registryReport.DatasetName
            SystemQueryId                   = $systemQueryId
            CustomQuery                     = $customQuery
            Frequency                       = "Every${recurrenceInterval}h"
            Source                          = $source
            RecurrenceIntervalHours         = $recurrenceInterval
            MinimumRecurrenceIntervalHours  = $minimumRecurrenceInterval
            Timespan                        = $timespan
            ColumnCount                     = $columns.Count
            MissingSystemQueryColumns       = $missingColumns
        }
    }

    if ($EnsureAllDatasets -and $Datasets) {
        foreach ($ds in @($Datasets)) {
            $name = Get-InsightsDatasetName -Dataset $ds
            if (-not $name) { continue }
            if ($covered[$name.ToLower()]) { continue }
            $covered[$name.ToLowerInvariant()] = $true

            $cols = Get-InsightsDatasetColumns -Dataset $ds
            if (@($cols).Count -eq 0) { continue }
            $timespan = Select-InsightsDatasetTimespan -Dataset $ds
            $minimumRecurrenceInterval = Get-InsightsDatasetMinimumRecurrenceInterval -Dataset $ds
            $recurrenceInterval = Get-ClampedInsightsRecurrenceInterval -MinimumRecurrenceIntervalHours $minimumRecurrenceInterval

            $result += @{
                DatasetName                     = $name
                SystemQueryId                   = $null
                CustomQuery                     = (New-DatasetSelectQuery -DatasetName $name -Columns $cols -Timespan $timespan)
                Frequency                       = "Every${recurrenceInterval}h"
                Source                          = 'auto'
                RecurrenceIntervalHours         = $recurrenceInterval
                MinimumRecurrenceIntervalHours  = $minimumRecurrenceInterval
                Timespan                        = $timespan
                ColumnCount                     = @($cols).Count
            }
        }
    }

    return $result
}


# ─────────────────────────────────────────────────────────────────────────────
# Mutating operations: create query, create report, ensure report
# ─────────────────────────────────────────────────────────────────────────────

function New-InsightsQuery {
    <# .SYNOPSIS Creates a user-defined report query; returns the new queryId. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$AccessToken,
        [string]$Description = 'Auto-created by HSO Insights integration',
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance,
        [switch]$PassThruResponse
    )

    $payload = @{ Name = $Name; Description = $Description; Query = $Query }
    $body = Invoke-InsightsRequest -Path '/ScheduledQueries' -Method POST -Body $payload `
        -AccessToken $AccessToken -CorrelationId $CorrelationId `
        -RequireMfaCompliance:$RequireMfaCompliance

    $queryId = $body.value | Select-Object -First 1 -ExpandProperty queryId -ErrorAction SilentlyContinue
    if (-not $queryId) { throw "Create query '$Name' did not return a queryId (statusCode=$($body.statusCode), message=$($body.message))" }
    if ($PassThruResponse) { return @{ QueryId = $queryId; Response = $body } }
    return $queryId
}


function New-InsightsReport {
    <# .SYNOPSIS Creates a scheduled report from a queryId; returns the new reportId. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportName,
        [Parameter(Mandatory)][string]$QueryId,
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)]$Config,
        [int]$RecurrenceIntervalHours = 0,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance,
        [switch]$PassThruResponse
    )

    $requestedInterval = if ($RecurrenceIntervalHours -gt 0) { $RecurrenceIntervalHours } else { [int]$Config.Insights.RecurrenceIntervalHours }
    $interval = Get-ClampedInsightsRecurrenceInterval -MinimumRecurrenceIntervalHours $requestedInterval
    $startTime = [DateTimeOffset]::UtcNow.AddHours(4).AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ')

    $payload = @{
        ReportName         = $ReportName
        Description        = 'Auto-created by HSO Insights integration'
        QueryId            = $QueryId
        StartTime          = $startTime
        ExecuteNow         = $false
        QueryStartTime     = $null
        QueryEndTime       = $null
        RecurrenceInterval = $interval
        RecurrenceCount    = [int]$Config.Insights.RecurrenceCount
        Format             = $Config.Insights.ReportFormat
        CallbackUrl        = $null
        CallbackMethod     = $null
    }

    $body = Invoke-InsightsRequest -Path '/ScheduledReport' -Method POST -Body $payload `
        -AccessToken $AccessToken -CorrelationId $CorrelationId `
        -RequireMfaCompliance:$RequireMfaCompliance

    $reportId = $body.value | Select-Object -First 1 -ExpandProperty reportId -ErrorAction SilentlyContinue
    if (-not $reportId) { throw "Create report '$ReportName' did not return a reportId (statusCode=$($body.statusCode), message=$($body.message))" }
    if ($PassThruResponse) { return @{ ReportId = $reportId; Response = $body } }
    return $reportId
}


function Register-InsightsReport {
    <#
    .SYNOPSIS
        Idempotently ensures a scheduled report exists for a dataset definition.
        Reuses an existing report matched by deterministic name; otherwise creates the
        query (if needed) and the report.
    .OUTPUTS
        Hashtable: ReportId, ReportName, Created (bool).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Definition,
        [AllowNull()][AllowEmptyCollection()]$ExistingReports = @(),
        [Parameter(Mandatory)][string]$AccessToken,
        [Parameter(Mandatory)]$Config,
        [string]$CorrelationId = [guid]::NewGuid().ToString()
    )

    if ($null -eq $ExistingReports) { $ExistingReports = @() }

    $reportName = Get-InsightsReportName -DatasetName $Definition.DatasetName -Config $Config

    $matchingReports = @($ExistingReports) | Where-Object { Test-InsightsReportNameMatches -Report $_ -ReportName $reportName }
    $existing = @($matchingReports | Where-Object { Test-InsightsReportIsReusable -Report $_ }) | Select-Object -First 1
    if ($existing) {
        return @{
            ReportId       = $existing.reportId
            ReportName     = $existing.reportName
            QueryId        = $existing.queryId
            Created        = $false
            Recreated      = $false
            QueryCreated   = $false
            QueryName      = $null
            QueryResponse  = $null
            ReportResponse = $null
            ExistingStatus = (Get-InsightsReportStatus -Report $existing)
        }
    }

    $queryId = $Definition.SystemQueryId
    $queryCreated = $false
    $queryName = $null
    $queryResponse = $null
    if (-not $queryId) {
        if (-not $Definition.CustomQuery) {
            throw "No system query or custom query available for dataset '$($Definition.DatasetName)'"
        }
        $queryName = Get-InsightsQueryName -DatasetName $Definition.DatasetName -Config $Config
        $queryResult = New-InsightsQuery -Name $queryName -Query $Definition.CustomQuery `
            -AccessToken $AccessToken -CorrelationId $CorrelationId -PassThruResponse
        $queryId = $queryResult.QueryId
        $queryCreated = $true
        $queryResponse = $queryResult.Response
    }

    $createReportName = if (@($matchingReports).Count -gt 0) { New-InsightsRecreatedReportName -ReportName $reportName } else { $reportName }
    $reportResult = New-InsightsReport -ReportName $createReportName -QueryId $queryId `
        -AccessToken $AccessToken -Config $Config -RecurrenceIntervalHours $Definition.RecurrenceIntervalHours `
        -CorrelationId $CorrelationId -PassThruResponse

    return @{
        ReportId       = $reportResult.ReportId
        ReportName     = $createReportName
        QueryId        = $queryId
        Created        = $true
        Recreated      = (@($matchingReports).Count -gt 0)
        QueryCreated   = $queryCreated
        QueryName      = $queryName
        QueryResponse  = $queryResponse
        ReportResponse = $reportResult.Response
        ExistingStatus = if (@($matchingReports).Count -gt 0) { Get-InsightsReportStatus -Report (@($matchingReports)[0]) } else { $null }
    }
}


# ─────────────────────────────────────────────────────────────────────────────
# Execution retrieval + download + conversion
# ─────────────────────────────────────────────────────────────────────────────

function Get-InsightsLatestExecution {
    <#
    .SYNOPSIS
        Returns the latest COMPLETED execution for a report (with reportAccessSecureLink),
        or $null if none exists yet (the API returns 404 before the first successful run).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ReportId,
        [Parameter(Mandatory)][string]$AccessToken,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance
    )

    $path = "/ScheduledReport/execution/$ReportId`?executionStatus=Completed&getLatestExecution=true"
    $body = Invoke-InsightsRequest -Path $path -AccessToken $AccessToken -Method GET `
        -CorrelationId $CorrelationId -RequireMfaCompliance:$RequireMfaCompliance
    if ($null -eq $body) { return $null }

    $execution = $body.value | Select-Object -First 1
    if ($execution) {
        foreach ($propertyName in @('statusCode', 'message', 'dataRedacted')) {
            if ($body.PSObject.Properties.Name -contains $propertyName -and -not ($execution.PSObject.Properties.Name -contains $propertyName)) {
                $execution | Add-Member -NotePropertyName $propertyName -NotePropertyValue $body.$propertyName -Force
            }
        }
    }
    return $execution
}


function Invoke-InsightsReportDownload {
    <#
    .SYNOPSIS
        Downloads the report payload from a secure SAS link (no bearer auth) with retry.
    .OUTPUTS
        The raw report content (CSV/TSV string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SecureLink,
        [int]$MaxRetries = 3
    )

    # The secure link is pre-authorized (SAS); send no Authorization header.
    $response = Invoke-ApiWithRetry -Uri $SecureLink -Headers @{ 'Accept' = '*/*' } `
        -Method GET -ContentType 'application/octet-stream' -MaxRetries $MaxRetries

    if ($null -eq $response) { return $null }
    return $response.Content
}


function Get-InsightsReportData {
    <#
    .SYNOPSIS
        Downloads a completed execution's report and converts it to a JSON array.
    .OUTPUTS
        Hashtable: ExecutionId, GeneratedTime, Format, RowCount, Json, Truncated, or $null if no data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Execution,
        [Parameter(Mandatory)]$Config
    )

    if (-not $Execution.reportAccessSecureLink) { return $null }

    $format = if ($Execution.format) { ([string]$Execution.format).ToUpper() } else { $Config.Insights.ReportFormat }
    if ($format -ne 'TSV') { $format = 'CSV' }

    $content = Invoke-InsightsReportDownload -SecureLink $Execution.reportAccessSecureLink
    if ($null -eq $content) { return $null }

    $converted = Convert-DelimitedToJson -Content $content -Format $format -MaxRows $Config.Insights.MaxRowsPerReport

    return @{
        ExecutionId   = $Execution.executionId
        GeneratedTime = $Execution.reportGeneratedTime
        Format        = $format
        RowCount      = $converted.RowCount
        Json          = $converted.Json
        Truncated     = $converted.Truncated
    }
}


Export-ModuleMember -Function @(
    'Invoke-InsightsRequest'
    'Get-InsightsCollection'
    'Get-InsightsDatasets'
    'Get-InsightsQueries'
    'Get-InsightsReportList'
    'Assert-InsightsResponseSuccess'
    'Get-InsightsDatasetName'
    'Get-InsightsDatasetColumns'
    'Get-InsightsDatasetAvailableDateRanges'
    'Select-InsightsDatasetTimespan'
    'Get-InsightsQueryId'
    'Get-InsightsQueryText'
    'Get-InsightsQueryProjectionColumns'
    'Get-InsightsQueryMissingColumns'
    'Test-InsightsSystemQueryCompatible'
    'Get-InsightsDatasetMinimumRecurrenceInterval'
    'Get-ClampedInsightsRecurrenceInterval'
    'New-DatasetSelectQuery'
    'Get-InsightsReportName'
    'Get-InsightsQueryName'
    'Get-InsightsReportStatus'
    'Test-InsightsReportIsReusable'
    'Test-InsightsReportNameMatches'
    'Convert-DelimitedToJson'
    'Resolve-InsightsReportsToCollect'
    'New-InsightsQuery'
    'New-InsightsReport'
    'Register-InsightsReport'
    'Get-InsightsLatestExecution'
    'Invoke-InsightsReportDownload'
    'Get-InsightsReportData'
)
