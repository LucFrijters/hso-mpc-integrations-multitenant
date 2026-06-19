param($InputData)

<#
.SYNOPSIS
    Activity function: loads the tenant configuration from Azure Key Vault.

    Returns an array of partner accounts (typically one: the HSO Production Partner Center).
    Each entry: TenantId, DisplayName, Enabled, MpnId, CollectPartnerInsights,
    CollectPartnerSecurityScore. Collection flags default to true when omitted.

    NOTE: These are PARTNER tenants, not CSP customer tenants. Customer data is contained
    within the partner-global Insights datasets and the security score's customerInsights,
    so customer tenants are NOT iterated here.

    Key Vault secret 'tenants-config' JSON shape:
        [ { "TenantId": "...", "DisplayName": "HSO Production", "Enabled": true,
            "MpnId": "123456", "CollectPartnerInsights": true,
            "CollectPartnerSecurityScore": true } ]
#>

$correlationId = $InputData
Write-Host "[$correlationId] LoadTenantConfig: loading tenant configuration from Key Vault"

try {
    $config = Get-IntegrationConfig
    $vaultName = $config.KeyVaultName
    $secretName = $config.TenantsConfigSecretName

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
        $validPartners += [pscustomobject]@{
            TenantId                    = $p.TenantId
            DisplayName                 = $p.DisplayName ?? "partner-$($p.TenantId.Substring(0,8))"
            Enabled                     = $p.Enabled -ne $false           # default enabled
            MpnId                       = $p.MpnId
            CollectPartnerInsights      = $p.CollectPartnerInsights -ne $false
            CollectPartnerSecurityScore = $p.CollectPartnerSecurityScore -ne $false
        }
    }

    Write-Host "[$correlationId] LoadTenantConfig: loaded $($validPartners.Count) partner account(s)"
    return $validPartners

}
catch {
    Write-Host "[$correlationId] LoadTenantConfig: ERROR - $($_.Exception.Message)"
    throw
}
