param($InputData)

<#
.SYNOPSIS
    Activity function: loads the partner-account configuration from Azure Key Vault.

    Returns an array of partner accounts (typically one: the HSO Production Partner Center).
    Each entry: TenantId, DisplayName, Enabled, InsightsAuthMode, MpnId.

    NOTE: These are PARTNER tenants, not CSP customer tenants. Customer data is contained
    within the partner-global Insights datasets and the security score's customerInsights,
    so customer tenants are NOT iterated here.

    Key Vault secret 'partner-config' JSON shape (InsightsAuthMode is optional and defaults to
    the Secure App Model 'AppPlusUser' required by Partner Center APIs):
        [ { "TenantId": "...", "DisplayName": "HSO Production", "Enabled": true,
            "InsightsAuthMode": "AppPlusUser", "MpnId": "123456" } ]
#>

$correlationId = $InputData
Write-Host "[$correlationId] LoadTenantConfig: loading partner-account configuration from Key Vault"

try {
    $config = Get-IntegrationConfig
    $vaultName = $config.KeyVaultName
    $secretName = $config.PartnerConfigSecretName

    $secret = Invoke-WithRetry -OperationName "KeyVaultRead:$secretName" -ScriptBlock {
        Get-AzKeyVaultSecret -VaultName $vaultName -Name $secretName -AsPlainText
    }

    $partners = $secret | ConvertFrom-Json

    $validPartners = @()
    foreach ($p in $partners) {
        if (-not $p.TenantId) {
            Write-Host "[$correlationId] LoadTenantConfig: WARNING - skipping partner entry with missing TenantId"
            continue
        }
        $validPartners += @{
            TenantId         = $p.TenantId
            DisplayName      = $p.DisplayName ?? "partner-$($p.TenantId.Substring(0,8))"
            Enabled          = $p.Enabled -ne $false           # default enabled
            InsightsAuthMode = $p.InsightsAuthMode ?? $config.Insights.AuthMode
            MpnId            = $p.MpnId
        }
    }

    Write-Host "[$correlationId] LoadTenantConfig: loaded $($validPartners.Count) partner account(s)"
    return $validPartners

} catch {
    Write-Host "[$correlationId] LoadTenantConfig: ERROR - $($_.Exception.Message)"
    throw
}
