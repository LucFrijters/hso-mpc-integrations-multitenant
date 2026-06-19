<#
.SYNOPSIS
    Unattended refresh-token renewal safety-net for the Secure Application Model.

.DESCRIPTION
    The function app already keeps each partner refresh token alive automatically: every collection
    run redeems the stored token for an access token and, because Microsoft Entra rotates refresh
    tokens on redemption, writes the rotated token back to Key Vault. As long as the timer fires
    within the refresh-token lifetime (90 days of inactivity) no human interaction is ever needed.

    This script performs that same rotation on demand, as a safety net for periods when collection
    is paused (maintenance, disabled partner, region outage) so the refresh token does not lapse.
    Schedule it (e.g. weekly Azure Automation runbook, or a cron/Task Scheduler job) to guarantee
    the token is exercised even when the main pipeline is idle.

    For each AppPlusUser partner it:
      1. Reads the stored refresh token ('refresh-token-<tenantId>').
      2. Redeems it for an access token (rotating the refresh token).
      3. Writes the rotated refresh token back to Key Vault.

    It reuses the function-app modules so it exercises exactly the same runtime auth path.

.PARAMETER KeyVaultName
    Name of the Azure Key Vault holding the certificate, partner config, and refresh tokens.

.PARAMETER ClientId
    The Application (client) ID of the multi-tenant app registration.

.PARAMETER TenantId
    Optional. Renew only this partner tenant. If omitted, all AppPlusUser partners in
    'partner-config' are processed.

.PARAMETER CertificateName
    Name of the certificate secret in Key Vault. Default: regapp-certificate-hso-mpc-integration

.PARAMETER PartnerConfigSecretName
    Name of the Key Vault secret holding partner-account JSON. Default: partner-config

.PARAMETER Resource
    Which API surface scope to renew against. Default: partner-insights

.EXAMPLE
    .\Update-RefreshToken.ps1 -KeyVaultName kv-hso-mpc-integration -ClientId 1111...

.EXAMPLE
    .\Update-RefreshToken.ps1 -KeyVaultName kv-hso-mpc-integration -ClientId 1111... -TenantId 2222...

.NOTES
    If renewal fails with an invalid_grant / expired token error, the 90-day window has lapsed and
    a fresh interactive consent is required — re-run Initialize-SecureAppConsent.ps1.
#>

[CmdletBinding(SupportsShouldProcess)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The rotated refresh token is received over TLS and must be converted to a SecureString to persist it via Set-AzKeyVaultSecret.')]
param (
    [Parameter(Mandatory)]
    [string]$KeyVaultName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$ClientId,

    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$TenantId,

    [string]$CertificateName = 'regapp-certificate-hso-mpc-integration',

    [string]$PartnerConfigSecretName = 'partner-config',

    [ValidateSet('partner-insights', 'graph-beta')]
    [string]$Resource = 'partner-insights'
)

$ErrorActionPreference = 'Stop'

# Import the same modules the function app uses (single source of truth for auth logic).
$modulesPath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules'
foreach ($m in @('IntegrationConfig.psm1', 'TokenService.psm1')) {
    Import-Module (Join-Path $modulesPath $m) -Force
}

Write-Host '=== HSO Partner Insights — Unattended Refresh-Token Renewal ===' -ForegroundColor Cyan
Write-Host "Key Vault : $KeyVaultName"
Write-Host "Client ID : $ClientId"
Write-Host ''

# Resolve the set of partners to renew.
if ($TenantId) {
    $targets = @([PSCustomObject]@{ TenantId = $TenantId; DisplayName = $TenantId; InsightsAuthMode = 'AppPlusUser' })
}
else {
    $configSecret = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $PartnerConfigSecretName -AsPlainText
    $targets = @($configSecret | ConvertFrom-Json | Where-Object {
            ($_.InsightsAuthMode ?? 'AppPlusUser') -eq 'AppPlusUser'
        })
}

if ($targets.Count -eq 0) {
    Write-Host 'No AppPlusUser partners to renew.' -ForegroundColor Yellow
    return
}

# Load the certificate once (shared across partners).
$cert = Get-CertificateFromKeyVault -VaultName $KeyVaultName -CertificateName $CertificateName
$scope = Get-ApiSurfaceTokenScope -ApiSurface $Resource -AuthMode AppPlusUser

$results = @()
foreach ($p in $targets) {
    $tid = $p.TenantId
    $name = $p.DisplayName ?? $tid
    $secretName = Get-RefreshTokenSecretName -TenantId $tid

    Write-Host "--- $name ($tid) ---" -ForegroundColor Cyan

    $row = [PSCustomObject]@{ DisplayName = $name; TenantId = $tid; Status = 'UNKNOWN'; Rotated = $false; Error = $null }

    try {
        $current = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -AsPlainText
        if (-not $current) {
            $row.Status = 'NO_TOKEN'
            $row.Error = "Secret '$secretName' not found. Run Initialize-SecureAppConsent.ps1 first."
            Write-Host "  ✗ $($row.Error)" -ForegroundColor Red
            $results += $row
            continue
        }

        if ($PSCmdlet.ShouldProcess($secretName, 'Redeem and rotate refresh token')) {
            $token = Get-RefreshTokenAccessToken `
                -ClientId $ClientId `
                -TenantId $tid `
                -Certificate $cert `
                -RefreshToken $current `
                -Scope $scope

            if (-not $token.AccessToken) {
                throw 'No access token returned from refresh-token redemption.'
            }

            if ($token.RefreshToken -and $token.RefreshToken -ne $current) {
                $rotated = ConvertTo-SecureString -String $token.RefreshToken -AsPlainText -Force
                Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue $rotated | Out-Null
                $row.Rotated = $true
                Write-Host '  ✓ Renewed and rotated refresh token.' -ForegroundColor Green
            }
            else {
                Write-Host '  ✓ Renewed (refresh token not rotated this cycle).' -ForegroundColor Green
            }
            $row.Status = 'OK'
        }
        else {
            $row.Status = 'SKIPPED_WHATIF'
        }
    }
    catch {
        $row.Status = 'FAILED'
        $row.Error = $_.Exception.Message
        Write-Host "  ✗ Renewal FAILED: $($row.Error)" -ForegroundColor Red
        if ($row.Error -match 'invalid_grant|AADSTS70008|AADSTS700082|expired') {
            Write-Host '    The 90-day window has likely lapsed — re-run Initialize-SecureAppConsent.ps1.' -ForegroundColor Yellow
        }
    }

    $results += $row
}

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
$results | Format-Table DisplayName, TenantId, Status, Rotated -AutoSize

if ($results | Where-Object { $_.Status -in @('FAILED', 'NO_TOKEN') }) {
    exit 1
}
