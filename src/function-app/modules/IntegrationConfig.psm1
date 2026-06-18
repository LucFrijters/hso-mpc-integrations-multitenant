<#
.SYNOPSIS
    Centralized configuration module for the HSO Partner Insights + Partner Security Score integration.
    Consolidates environment variables, retry settings, API surfaces, and operational constants
    into a single source of truth.

.NOTES
    Topology: data is collected PARTNER-GLOBAL from the HSO Production Partner Center (and any
    additional partner accounts in partner-config). The Partner Insights datasets already carry
    per-customer rows, and the Partner Security Score exposes per-customer posture via
    customerInsights, so there is NO per-CSP-customer-tenant fan-out.
#>

# ─── Configuration Cache ────────────────────────────────────────────────────
# Loaded once at module import time and reused throughout the function app lifetime.

$script:ConfigCache = $null

function Get-IntegrationConfig {
    <#
    .SYNOPSIS
        Returns the full integration configuration as a hashtable.
        Values are read from environment variables with safe defaults.
        The result is cached for the lifetime of the PowerShell worker.
    #>
    [CmdletBinding()]
    param()

    if ($script:ConfigCache) {
        return $script:ConfigCache
    }

    $script:ConfigCache = @{

        # ── Azure Resources ──────────────────────────────────────────────
        KeyVaultUri                = $env:KEY_VAULT_URI
        KeyVaultName               = ($env:KEY_VAULT_URI -replace 'https://|\.vault\.azure\.net/?', '')
        StorageAccountName         = $env:STORAGE_ACCOUNT_NAME
        StorageContainerName       = $env:STORAGE_CONTAINER_NAME ?? 'partner-data-raw'
        AppClientId                = $env:APP_CLIENT_ID
        AppCertificateName         = $env:APP_CERTIFICATE_NAME ?? 'app-certificate'

        # Partner-account registry (replaces per-customer 'tenant-config').
        # JSON array: [{ TenantId, DisplayName, MpnId, Enabled, InsightsAuthMode }]
        PartnerConfigSecretName    = $env:PARTNER_CONFIG_SECRET_NAME ?? 'partner-config'

        # ── Concurrency ─────────────────────────────────────────────────
        # Partner accounts are few (typically 1). Endpoint-level concurrency still
        # applies to the security-score + insights activities within an account.
        MaxConcurrentPartners      = [int]($env:MAX_CONCURRENT_PARTNERS ?? '4')
        MaxConcurrentEndpoints     = [int]($env:MAX_CONCURRENT_ENDPOINTS ?? '5')
        CollectionTimeoutMinutes   = [int]($env:COLLECTION_TIMEOUT_MINUTES ?? '25')

        # ── Retry / Resilience ───────────────────────────────────────────
        MaxRetries                 = 3
        InitialBackoffSeconds      = 2
        BackoffMultiplier          = 2
        MaxBackoffSeconds          = 60
        JitterPercent              = 0.25
        ThrottleDefaultWaitSec     = 30
        CircuitBreakerThreshold    = 5

        # ── Pagination ───────────────────────────────────────────────────
        MaxPages                   = 100

        # ── Partner Insights (programmatic analytics) ─────────────────────
        # The Insights API is asynchronous: ensure a scheduled report per dataset,
        # then download the latest completed execution and convert CSV/TSV -> JSON.
        Insights                   = @{
            # Partner Center APIs (incl. the Insights surface) require the Secure Application
            # Model with multifactor auth, so App+User is the default. AppOnly remains available
            # only as an explicit override for non-MFA-gated scenarios / local testing.
            AuthMode                = $env:INSIGHTS_AUTH_MODE ?? 'AppPlusUser'   # AppPlusUser | AppOnly
            ReportNamePrefix        = $env:INSIGHTS_REPORT_PREFIX ?? 'hso-auto-'
            # RecurrenceInterval minimum enforced by the API is 4h; default to daily.
            RecurrenceIntervalHours = [int]($env:INSIGHTS_RECURRENCE_HOURS ?? '24')
            RecurrenceCount         = [int]($env:INSIGHTS_RECURRENCE_COUNT ?? '600')
            ReportFormat            = $env:INSIGHTS_REPORT_FORMAT ?? 'CSV'        # CSV | TSV
            # When true, ensure a SELECT-all report for every dataset returned by
            # ScheduledDataset (covers "all datasets"); registry entries take precedence.
            EnsureAllDatasets       = ($env:INSIGHTS_ENSURE_ALL_DATASETS -ne 'false')
            # Max rows of CSV to parse into JSON in a single activity (memory guard).
            MaxRowsPerReport        = [int]($env:INSIGHTS_MAX_ROWS_PER_REPORT ?? '500000')
        }

        # ── API Surfaces ─────────────────────────────────────────────────
        ApiSurfaces                = @{
            'partner-insights' = @{
                BaseUrl        = 'https://api.partnercenter.microsoft.com/insights/v1/mpn'
                Scope          = 'https://api.partnercenter.microsoft.com/.default'
                DelegatedScope = 'https://api.partnercenter.microsoft.com/user_impersonation'
            }
            'graph-beta'       = @{
                BaseUrl = 'https://graph.microsoft.com/beta'
                Scope   = 'https://graph.microsoft.com/.default'
            }
        }

        # ── Blob Retry ───────────────────────────────────────────────────
        BlobRetryMaxAttempts       = 3
        BlobRetryBaseDelayMs       = 500

        # ── Token / Secrets ──────────────────────────────────────────────
        TokenEndpointTemplate      = 'https://login.microsoftonline.com/{0}/oauth2/v2.0/token'
        # Single canonical refresh-token secret naming (fixes prior code/doc mismatch).
        RefreshTokenSecretTemplate = 'refresh-token-{0}'
    }

    return $script:ConfigCache
}


function Get-ApiSurfaceConfig {
    <#
    .SYNOPSIS
        Returns BaseUrl and Scope for a given API surface name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('partner-insights', 'graph-beta')]
        [string]$ApiSurface
    )

    $config = Get-IntegrationConfig
    $surface = $config.ApiSurfaces[$ApiSurface]
    if (-not $surface) {
        throw "Unknown API surface: $ApiSurface"
    }
    return $surface
}


function Get-ApiSurfaceTokenScope {
    <#
    .SYNOPSIS
        Returns the OAuth2 scope to request for an API surface and auth mode.
        Partner Center Secure Application Model App+User flows use the delegated
        user_impersonation scope; app-only flows use the .default application scope.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('partner-insights', 'graph-beta')]
        [string]$ApiSurface,

        [ValidateSet('AppOnly', 'AppPlusUser')]
        [string]$AuthMode = 'AppOnly',

        [switch]$IncludeOfflineAccess
    )

    $surface = Get-ApiSurfaceConfig -ApiSurface $ApiSurface
    $scope = if ($ApiSurface -eq 'partner-insights' -and $AuthMode -eq 'AppPlusUser' -and $surface.DelegatedScope) {
        $surface.DelegatedScope
    }
    else {
        $surface.Scope
    }

    if ($IncludeOfflineAccess) {
        return "offline_access $scope"
    }
    return $scope
}


function Get-RefreshTokenSecretName {
    <#
    .SYNOPSIS
        Builds the Key Vault secret name that stores the refresh token for a partner tenant.
        Centralized so token acquisition and operational scripts never drift apart.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TenantId)

    $config = Get-IntegrationConfig
    return ($config.RefreshTokenSecretTemplate -f $TenantId)
}


function Reset-IntegrationConfigCache {
    <#
    .SYNOPSIS
        Clears the cached configuration. Useful for testing or after env var changes.
    #>
    [CmdletBinding()]
    param()

    $script:ConfigCache = $null
}


function Split-IntoBatches {
    <#
    .SYNOPSIS
        Splits an array into batches of a given size.
        Shared helper used by the orchestrators for bounded fan-out.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [array]$Items,

        [Parameter(Mandatory)]
        [int]$BatchSize
    )

    $batches = @()
    for ($i = 0; $i -lt $Items.Count; $i += $BatchSize) {
        $end = [Math]::Min($i + $BatchSize, $Items.Count)
        $batches += , ($Items[$i..($end - 1)])
    }
    return $batches
}


function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a script block with exponential backoff retry logic.
        Used for Key Vault reads, blob writes, and other non-API operations.
    .PARAMETER ScriptBlock
        The operation to execute.
    .PARAMETER OperationName
        A descriptive name for logging.
    .PARAMETER MaxRetries
        Maximum number of retry attempts (default: from config).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [string]$OperationName = 'Operation',

        [int]$MaxRetries = 0
    )

    $config = Get-IntegrationConfig
    if ($MaxRetries -le 0) { $MaxRetries = $config.MaxRetries }

    $attempt = 0
    while ($true) {
        try {
            $attempt++
            return (& $ScriptBlock)
        }
        catch {
            if ($attempt -ge $MaxRetries) {
                Write-Host "[$OperationName] Failed after $attempt attempts: $($_.Exception.Message)"
                throw
            }

            $backoff = [Math]::Min(
                $config.InitialBackoffSeconds * [Math]::Pow($config.BackoffMultiplier, $attempt - 1),
                $config.MaxBackoffSeconds
            )
            $jitter = Get-Random -Minimum 0.0 -Maximum ($backoff * $config.JitterPercent)
            $waitSeconds = $backoff + $jitter

            Write-Host "[$OperationName] Attempt $attempt/$MaxRetries failed: $($_.Exception.Message). Retrying in ${waitSeconds}s"
            Start-Sleep -Seconds ([int][Math]::Max(1, $waitSeconds))
        }
    }
}


Export-ModuleMember -Function @(
    'Get-IntegrationConfig'
    'Get-ApiSurfaceConfig'
    'Get-ApiSurfaceTokenScope'
    'Get-RefreshTokenSecretName'
    'Reset-IntegrationConfigCache'
    'Split-IntoBatches'
    'Invoke-WithRetry'
)
