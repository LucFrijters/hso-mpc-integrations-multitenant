<#
.SYNOPSIS
    Core HTTP client: throttle-aware, retrying invocation plus Microsoft Graph pagination.
    Shared by the Partner Insights client (InsightsClient.psm1) and the Graph-based
    Partner Security Score collection.
#>

function Invoke-ApiWithRetry {
    <#
    .SYNOPSIS
        Makes an HTTP request with retry logic for 429 (throttle) and 5xx (server) errors.
        Supports GET and POST (with a JSON body). Returns the raw web response.
    .OUTPUTS
        The Invoke-WebRequest BasicHtmlWebResponseObject, or $null for 404 (not found / not ready).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][hashtable]$Headers,
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method = 'GET',
        [string]$Body,
        [string]$ContentType = 'application/json',
        [int]$MaxRetries = 3
    )

    for ($attempt = 0; $attempt -lt $MaxRetries; $attempt++) {
        try {
            $requestParams = @{
                Uri         = $Uri
                Headers     = $Headers
                Method      = $Method
                ContentType = $ContentType
                ErrorAction = 'Stop'
            }
            if ($Body) { $requestParams['Body'] = $Body }

            return Invoke-WebRequest @requestParams

        } catch {
            $statusCode = $null
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            }

            if ($statusCode -eq 429) {
                # Throttled — honour Retry-After, add jitter.
                $retryAfter = Get-RetryAfterSeconds -Response $_.Exception.Response -Default 30
                $jitter = Get-Random -Minimum 0.0 -Maximum ($retryAfter * 0.25)
                $waitSeconds = [Math]::Max(1, $retryAfter + $jitter)

                Write-Warning "429 Throttled on $Uri. Waiting ${waitSeconds}s (attempt $($attempt + 1)/$MaxRetries)"
                Start-Sleep -Seconds ([int]$waitSeconds)
                continue
            }
            elseif ($statusCode -ge 500 -and $statusCode -lt 600) {
                # Server error — exponential backoff with jitter.
                $backoff = [Math]::Pow(2, $attempt) * 2
                $jitter = Get-Random -Minimum 0.0 -Maximum ($backoff * 0.25)
                $waitSeconds = $backoff + $jitter

                Write-Warning "${statusCode} on $Uri. Backoff ${waitSeconds}s (attempt $($attempt + 1)/$MaxRetries)"
                Start-Sleep -Seconds ([int]$waitSeconds)
                continue
            }
            elseif ($statusCode -eq 404) {
                # Not found / not ready (e.g. Insights execution before first run). Caller decides.
                Write-Warning "404 Not Found: $Uri"
                return $null
            }
            else {
                # 400, 401, 403, etc. — permanent for this call; do not retry.
                throw (New-HttpErrorMessage -Uri $Uri -Method $Method -Response $_.Exception.Response -FallbackMessage $_.Exception.Message -ErrorDetailsMessage $_.ErrorDetails.Message)
            }
        }
    }

    throw "API call to $Uri failed after $MaxRetries attempts"
}


function Get-HttpErrorBody {
    <#
    .SYNOPSIS
        Extracts an HTTP error response body across PowerShell/.NET response shapes.
    #>
    [CmdletBinding()]
    param($Response)

    if (-not $Response) { return $null }

    try {
        $stream = $Response.GetResponseStream()
        if ($stream) {
            $reader = [System.IO.StreamReader]::new($stream)
            try { return $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
    }
    catch {
        Write-Verbose "Could not read HTTP error response stream: $($_.Exception.Message)"
    }

    try {
        if ($Response.Content) {
            if ($Response.Content.PSObject.Methods.Name -contains 'ReadAsStringAsync') {
                return $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
            return [string]$Response.Content
        }
    }
    catch {
        Write-Verbose "Could not read HTTP error response content: $($_.Exception.Message)"
    }

    return $null
}


function New-HttpErrorMessage {
    <#
    .SYNOPSIS
        Builds a richer permanent HTTP error message including the response body when available.
    #>
    [CmdletBinding()]
    param(
        [string]$Uri,
        [string]$Method,
        $Response,
        [string]$FallbackMessage,
        [string]$ErrorDetailsMessage
    )

    $statusCode = $null
    $reasonPhrase = $null
    if ($Response) {
        try { $statusCode = [int]$Response.StatusCode } catch { Write-Verbose "Could not read HTTP response status code: $($_.Exception.Message)" }
        try { $reasonPhrase = [string]$Response.ReasonPhrase } catch { Write-Verbose "Could not read HTTP response reason phrase: $($_.Exception.Message)" }
        if (-not $reasonPhrase) {
            try { $reasonPhrase = [string]$Response.StatusDescription } catch { Write-Verbose "Could not read HTTP response status description: $($_.Exception.Message)" }
        }
    }

    $message = if ($statusCode) { "HTTP $statusCode" } else { $FallbackMessage }
    if ($reasonPhrase) { $message += " $reasonPhrase" }
    $message += " for $Method $Uri"

    $body = $ErrorDetailsMessage
    if ([string]::IsNullOrWhiteSpace($body)) {
        $body = Get-HttpErrorBody -Response $Response
    }
    if (-not [string]::IsNullOrWhiteSpace($body)) {
        $message += ": $body"
    }

    return $message
}


function Get-RetryAfterSeconds {
    <#
    .SYNOPSIS
        Reads the Retry-After header. Supports both delta-seconds and HTTP-date forms.
    #>
    param($Response, [int]$Default = 30)

    if ($Response -and $Response.Headers) {
        try {
            $retryAfterValues = $Response.Headers.GetValues('Retry-After')
            if ($retryAfterValues -and $retryAfterValues.Count -gt 0) {
                $value = $retryAfterValues[0]

                # delta-seconds form
                $parsed = 0
                if ([int]::TryParse($value, [ref]$parsed)) {
                    return [Math]::Max(1, $parsed)
                }

                # HTTP-date form
                $date = [datetime]::MinValue
                if ([datetime]::TryParse($value, [ref]$date)) {
                    $delta = [int]([datetimeoffset]$date - [datetimeoffset]::UtcNow).TotalSeconds
                    if ($delta -gt 0) { return $delta }
                }
            }
        } catch {
            Write-Verbose "Retry-After header not parseable: $_"
        }
    }
    return $Default
}


function Invoke-GraphBetaApi {
    <#
    .SYNOPSIS
        Calls a Microsoft Graph beta endpoint, following @odata.nextLink pagination.
        Used for Partner Security Score collection (score, requirements, history, customerInsights).
    .OUTPUTS
        Hashtable: Records (array), PageCount, TotalBytes, RawJson.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$AccessToken,
        [string]$CorrelationId = [guid]::NewGuid().ToString(),
        [int]$MaxPages = 100,
        [int]$MaxRetries = 3
    )

    $baseUrl = 'https://graph.microsoft.com/beta'
    $url = "$baseUrl$Path"
    $allRecords = @()
    $pageCount = 0
    $totalBytes = 0

    $headers = @{
        'Authorization'    = "Bearer $AccessToken"
        'Accept'           = 'application/json'
        'ms-correlationid' = $CorrelationId
        'ms-requestid'     = [guid]::NewGuid().ToString()
    }

    while ($url -and $pageCount -lt $MaxPages) {
        $pageCount++

        $response = Invoke-ApiWithRetry -Uri $url -Headers $headers -Method GET -MaxRetries $MaxRetries
        if ($null -eq $response) { break }

        $body = $response.Content | ConvertFrom-Json
        $totalBytes += $response.Content.Length

        # A collection response has a 'value' array; a single resource is itself one record.
        if ($null -ne $body.value) {
            $allRecords += $body.value
        } else {
            $allRecords += $body
        }

        $url = $body.'@odata.nextLink'
        $headers['ms-requestid'] = [guid]::NewGuid().ToString()
    }

    return @{
        Records    = $allRecords
        PageCount  = $pageCount
        TotalBytes = $totalBytes
        RawJson    = ($allRecords | ConvertTo-Json -Depth 50)
    }
}


Export-ModuleMember -Function @(
    'Invoke-ApiWithRetry'
    'Get-RetryAfterSeconds'
    'Get-HttpErrorBody'
    'New-HttpErrorMessage'
    'Invoke-GraphBetaApi'
)
