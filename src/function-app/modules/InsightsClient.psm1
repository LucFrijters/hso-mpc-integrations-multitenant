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
    return ($response.Content | ConvertFrom-Json)
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


function Get-InsightsDatasetColumns {
    <# .SYNOPSIS Defensively extracts selectable column names from a dataset definition. #>
    [CmdletBinding()]
    param($Dataset)
    if (-not $Dataset) { return @() }

    $colContainer = $null
    foreach ($p in @('selectableColumns', 'SelectableColumns', 'columns', 'Columns', 'availableColumns')) {
        if ($Dataset.PSObject.Properties.Name -contains $p -and $Dataset.$p) { $colContainer = $Dataset.$p; break }
    }
    if (-not $colContainer) { return @() }

    $names = @()
    foreach ($c in $colContainer) {
        if ($c -is [string]) { $names += $c }
        elseif ($c.PSObject.Properties.Name -contains 'name') { $names += [string]$c.name }
        elseif ($c.PSObject.Properties.Name -contains 'columnName') { $names += [string]$c.columnName }
        elseif ($c.PSObject.Properties.Name -contains 'Name') { $names += [string]$c.Name }
    }
    return @($names | Where-Object { $_ })
}


function New-DatasetSelectQuery {
    <#
    .SYNOPSIS
        Builds a report query that selects all known columns from a dataset.
        Falls back to SELECT * when columns are unknown.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatasetName,
        [string[]]$Columns,
        [string]$Timespan = 'LAST_6_MONTHS'
    )
    $cols = if ($Columns -and $Columns.Count -gt 0) { ($Columns -join ',') } else { '*' }
    $query = "SELECT $cols FROM $DatasetName"
    if ($Timespan) { $query += " TIMESPAN $Timespan" }
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
    .OUTPUTS
        Array of definition hashtables: DatasetName, SystemQueryId, CustomQuery, Frequency, Source.
    #>
    [CmdletBinding()]
    param(
        $RegistryReports,
        $Datasets,
        [bool]$EnsureAllDatasets = $true
    )

    $result = @()
    $covered = @{}

    foreach ($r in @($RegistryReports)) {
        if (-not $r.DatasetName) { continue }
        $covered[$r.DatasetName.ToLower()] = $true
        $result += @{
            DatasetName   = $r.DatasetName
            SystemQueryId = $r.SystemQueryId
            CustomQuery   = $null
            Frequency     = ($r.Frequency ?? 'Every4h')
            Source        = 'registry'
        }
    }

    if ($EnsureAllDatasets -and $Datasets) {
        foreach ($ds in @($Datasets)) {
            $name = Get-InsightsDatasetName -Dataset $ds
            if (-not $name) { continue }
            if ($covered[$name.ToLower()]) { continue }
            $covered[$name.ToLower()] = $true

            $cols = Get-InsightsDatasetColumns -Dataset $ds
            $result += @{
                DatasetName   = $name
                SystemQueryId = $null
                CustomQuery   = (New-DatasetSelectQuery -DatasetName $name -Columns $cols)
                Frequency     = 'Every4h'
                Source        = 'auto'
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
        [switch]$RequireMfaCompliance
    )

    $payload = @{ Name = $Name; Description = $Description; Query = $Query }
    $body = Invoke-InsightsRequest -Path '/ScheduledQueries' -Method POST -Body $payload `
        -AccessToken $AccessToken -CorrelationId $CorrelationId `
        -RequireMfaCompliance:$RequireMfaCompliance

    $queryId = $body.value | Select-Object -First 1 -ExpandProperty queryId -ErrorAction SilentlyContinue
    if (-not $queryId) { throw "Create query '$Name' did not return a queryId (statusCode=$($body.statusCode), message=$($body.message))" }
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
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance
    )

    # API minimum RecurrenceInterval is 4 hours.
    $interval = [Math]::Max(4, [int]$Config.Insights.RecurrenceIntervalHours)
    $startTime = [DateTimeOffset]::UtcNow.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ')

    $payload = @{
        ReportName         = $ReportName
        Description        = 'Auto-created by HSO Insights integration'
        QueryId            = $QueryId
        StartTime          = $startTime
        ExecuteNow         = $false
        RecurrenceInterval = $interval
        RecurrenceCount    = [int]$Config.Insights.RecurrenceCount
        Format             = $Config.Insights.ReportFormat
    }

    $body = Invoke-InsightsRequest -Path '/ScheduledReport' -Method POST -Body $payload `
        -AccessToken $AccessToken -CorrelationId $CorrelationId `
        -RequireMfaCompliance:$RequireMfaCompliance

    $reportId = $body.value | Select-Object -First 1 -ExpandProperty reportId -ErrorAction SilentlyContinue
    if (-not $reportId) { throw "Create report '$ReportName' did not return a reportId (statusCode=$($body.statusCode), message=$($body.message))" }
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
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [switch]$RequireMfaCompliance
    )

    if ($null -eq $ExistingReports) { $ExistingReports = @() }

    $reportName = Get-InsightsReportName -DatasetName $Definition.DatasetName -Config $Config

    $existing = @($ExistingReports) | Where-Object { $_.reportName -eq $reportName } | Select-Object -First 1
    if ($existing) {
        return @{ ReportId = $existing.reportId; ReportName = $reportName; Created = $false }
    }

    $queryId = $Definition.SystemQueryId
    if (-not $queryId) {
        if (-not $Definition.CustomQuery) {
            throw "No system query or custom query available for dataset '$($Definition.DatasetName)'"
        }
        $queryId = New-InsightsQuery -Name "$reportName-query" -Query $Definition.CustomQuery `
            -AccessToken $AccessToken -CorrelationId $CorrelationId `
            -RequireMfaCompliance:$RequireMfaCompliance
    }

    $reportId = New-InsightsReport -ReportName $reportName -QueryId $queryId `
        -AccessToken $AccessToken -Config $Config -CorrelationId $CorrelationId `
        -RequireMfaCompliance:$RequireMfaCompliance

    return @{ ReportId = $reportId; ReportName = $reportName; Created = $true }
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

    return ($body.value | Select-Object -First 1)
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
    'Get-InsightsDatasetName'
    'Get-InsightsDatasetColumns'
    'New-DatasetSelectQuery'
    'Get-InsightsReportName'
    'Convert-DelimitedToJson'
    'Resolve-InsightsReportsToCollect'
    'New-InsightsQuery'
    'New-InsightsReport'
    'Register-InsightsReport'
    'Get-InsightsLatestExecution'
    'Invoke-InsightsReportDownload'
    'Get-InsightsReportData'
)
