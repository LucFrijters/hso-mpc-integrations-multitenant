<#
.SYNOPSIS
    Verifies certificate auth and API access for all configured partner accounts.

.DESCRIPTION
    Reuses the function-app modules (TokenService, ApiClient, InsightsClient, IntegrationConfig)
    so the verification exercises exactly the same code paths as the runtime collection.

     For each partner account in 'tenants-config' it respects CollectPartnerInsights and
     CollectPartnerSecurityScore, then:
      1. Loads the certificate from Key Vault.
        2. For Insights-enabled tenants, redeems the stored Secure App Model refresh token and
            calls GET /ScheduledDataset.
        3. For Security Score-enabled tenants, acquires an AppOnly token for Microsoft Graph and
            calls GET /security/partner/securityScore.

.PARAMETER KeyVaultName
    Name of the Azure Key Vault holding the tenants config and certificate.

.PARAMETER ClientId
    The Application (client) ID of the multi-tenant app registration.

.PARAMETER CertificateName
    Name of the certificate in Key Vault. Default: regapp-certificate-hso-mpc-integration

.PARAMETER TenantsConfigSecretName
    Name of the Key Vault secret holding tenant JSON. Default: tenants-config

.EXAMPLE
    .\Verify-TenantConsent.ps1 -KeyVaultName "kv-hso-mpc-integration" -ClientId "11111111-1111-1111-1111-111111111111"
#>

[CmdletBinding()]
param (
    [Parameter()]
    [string]$KeyVaultName = 'kv-hso-mpc-integration',

    [Parameter()]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$ClientId = '05573d61-6ddf-403b-90c6-d8572e6c867f',

    [string]$CertificateName = 'regapp-certificate-hso-mpc-integration',

    [string]$TenantsConfigSecretName = 'tenants-config'
)

$ErrorActionPreference = 'Stop'

# Import the same modules the function app uses (single source of truth for auth + API logic).
$modulesPath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules'
foreach ($m in @('IntegrationConfig.psm1', 'TokenService.psm1', 'ApiClient.psm1', 'InsightsClient.psm1')) {
    Import-Module (Join-Path $modulesPath $m) -Force
}

Write-Host "=== HSO Partner Insights + Security Score — Consent Verification ===" -ForegroundColor Cyan
Write-Host "Key Vault : $KeyVaultName"
Write-Host "Client ID : $ClientId"
Write-Host ""

# Step 1: tenants configuration
Write-Host "[1/3] Loading tenants configuration ($TenantsConfigSecretName)..." -ForegroundColor Yellow
$configSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $TenantsConfigSecretName -AsPlainText
$partners = @($configSecret | ConvertFrom-Json)
Write-Host "  Found $($partners.Count) partner account(s)."
Write-Host ""

# Step 2: certificate
Write-Host "[2/3] Loading certificate '$CertificateName'..." -ForegroundColor Yellow
$cert = Get-CertificateFromKeyVault -VaultName $KeyVaultName -CertificateName $CertificateName
Write-Host "  Certificate loaded (thumbprint: $($cert.Thumbprint), expires: $($cert.NotAfter))"
Write-Host ""

# Step 3: per-partner checks
Write-Host "[3/3] Testing partner access..." -ForegroundColor Yellow
Write-Host ""

$insightsAppOnlyScope = Get-ApiSurfaceTokenScope -ApiSurface 'partner-insights' -AuthMode AppOnly
$insightsDelegatedScope = Get-ApiSurfaceTokenScope -ApiSurface 'partner-insights' -AuthMode AppPlusUser
$graphScope = (Get-ApiSurfaceConfig -ApiSurface 'graph-beta').Scope
$results = @()

foreach ($p in $partners) {
    $tenantId = $p.TenantId
    $displayName = $p.DisplayName ?? $tenantId
    $authMode = 'AppPlusUser'
    $collectPartnerInsights = $p.CollectPartnerInsights -ne $false
    $collectPartnerSecurityScore = $p.CollectPartnerSecurityScore -ne $false

    $r = [PSCustomObject]@{
        DisplayName                 = $displayName
        TenantId                    = $tenantId
        CollectPartnerInsights      = $collectPartnerInsights
        CollectPartnerSecurityScore = $collectPartnerSecurityScore
        InsightsAuthMode            = $authMode
        InsightsTokenStatus         = 'UNTESTED'
        InsightsApiStatus           = 'UNTESTED'
        GraphTokenStatus            = 'UNTESTED'
        GraphApiStatus              = 'UNTESTED'
        Errors                      = @()
    }

    Write-Host "  --- $displayName ($tenantId) ---" -ForegroundColor Cyan

    # Partner Insights (Secure App Model App+User)
    if (-not $collectPartnerInsights) {
        $r.InsightsTokenStatus = 'SKIPPED'
        $r.InsightsApiStatus = 'SKIPPED'
        Write-Host '    - Insights verification skipped (CollectPartnerInsights=false)' -ForegroundColor Gray
    }
    elseif ($authMode -eq 'AppPlusUser') {
        # Secure App Model: redeem the stored refresh token exactly as the runtime does.
        try {
            $secretName = Get-RefreshTokenSecretName -TenantId $tenantId
            $refreshToken = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -AsPlainText
            if (-not $refreshToken) {
                throw "No refresh token in Key Vault secret '$secretName'. Run Initialize-SecureAppConsent.ps1."
            }
            $tok = Get-RefreshTokenAccessToken -ClientId $ClientId -TenantId $tenantId -Certificate $cert -RefreshToken $refreshToken -Scope $insightsDelegatedScope
            $r.InsightsTokenStatus = 'OK'
            Write-Host "    ✓ Insights token acquired (AppPlusUser / Secure App Model)" -ForegroundColor Green
            try {
                $ds = Get-InsightsDatasets -AccessToken $tok.AccessToken -RequireMfaCompliance
                $r.InsightsApiStatus = "OK ($($ds.Records.Count) datasets)"
                Write-Host "    ✓ GET /ScheduledDataset returned $($ds.Records.Count) datasets" -ForegroundColor Green
            }
            catch {
                $r.InsightsApiStatus = 'FAILED'
                $r.Errors += "Insights API: $($_.Exception.Message)"
                Write-Host "    ✗ Insights API FAILED: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        catch {
            $r.InsightsTokenStatus = 'FAILED'
            $r.Errors += "Insights refresh token: $($_.Exception.Message)"
            Write-Host "    ✗ Insights refresh-token redemption FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    else {
        try {
            $tok = Get-MultiTenantAccessToken -ClientId $ClientId -TenantId $tenantId -Certificate $cert -Scope $insightsAppOnlyScope
            $r.InsightsTokenStatus = 'OK'
            Write-Host "    ✓ Insights token acquired" -ForegroundColor Green
            try {
                $ds = Get-InsightsDatasets -AccessToken $tok.AccessToken
                $r.InsightsApiStatus = "OK ($($ds.Records.Count) datasets)"
                Write-Host "    ✓ GET /ScheduledDataset returned $($ds.Records.Count) datasets" -ForegroundColor Green
            }
            catch {
                $r.InsightsApiStatus = 'FAILED'
                $r.Errors += "Insights API: $($_.Exception.Message)"
                Write-Host "    ✗ Insights API FAILED: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        catch {
            $r.InsightsTokenStatus = 'FAILED'
            $r.Errors += "Insights token: $($_.Exception.Message)"
            Write-Host "    ✗ Insights token FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    # Microsoft Graph — Partner Security Score (AppOnly, PartnerSecurity.Read.All)
    if (-not $collectPartnerSecurityScore) {
        $r.GraphTokenStatus = 'SKIPPED'
        $r.GraphApiStatus = 'SKIPPED'
        Write-Host '    - Graph security score verification skipped (CollectPartnerSecurityScore=false)' -ForegroundColor Gray
    }
    else {
        try {
            $gtok = Get-MultiTenantAccessToken -ClientId $ClientId -TenantId $tenantId -Certificate $cert -Scope $graphScope
            $r.GraphTokenStatus = 'OK'
            Write-Host "    ✓ Graph token acquired" -ForegroundColor Green
            try {
                $score = Invoke-GraphBetaApi -Path '/security/partner/securityScore' -AccessToken $gtok.AccessToken
                $r.GraphApiStatus = "OK ($($score.Records.Count) record)"
                Write-Host "    ✓ GET /security/partner/securityScore succeeded" -ForegroundColor Green
            }
            catch {
                $r.GraphApiStatus = 'FAILED'
                $r.Errors += "Graph API: $($_.Exception.Message)"
                Write-Host "    ✗ Graph API FAILED: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
        catch {
            $r.GraphTokenStatus = 'FAILED'
            $r.Errors += "Graph token: $($_.Exception.Message)"
            Write-Host "    ✗ Graph token FAILED: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    $results += $r
    Write-Host ""
}

Write-Host "=== Summary ===" -ForegroundColor Cyan
$results | Select-Object DisplayName, TenantId, CollectPartnerInsights, CollectPartnerSecurityScore, InsightsTokenStatus, InsightsApiStatus, GraphTokenStatus, GraphApiStatus | Format-Table -AutoSize

$failed = $results | Where-Object { $_.Errors.Count -gt 0 }
if ($failed) {
    Write-Host "Partners with errors:" -ForegroundColor Red
    foreach ($t in $failed) {
        Write-Host "  $($t.DisplayName):" -ForegroundColor Yellow
        $t.Errors | ForEach-Object { Write-Host "    - $_" -ForegroundColor Gray }
    }
}
else {
    Write-Host "All partner accounts passed verification." -ForegroundColor Green
}

$results
