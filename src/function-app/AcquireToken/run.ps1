[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The rotated refresh token is received over TLS and must be converted to a SecureString to persist it via Set-AzKeyVaultSecret. Only the AppOnly override (Graph / non-MFA scenarios) skips this path.')]
param($InputData)

<#
.SYNOPSIS
    Activity function: acquires an OAuth2 access token for a specific tenant and resource.
    Supports both AppOnly (client_credentials) and AppPlusUser (refresh_token) flows.

    Partner Center APIs (the 'insights' resource) require the Secure Application Model with
    multifactor auth, so they default to AppPlusUser. Microsoft Graph (the 'graph' resource,
    Partner Security Score) uses a genuine application permission and defaults to AppOnly.

    Input:
        CorrelationId : string
        TenantId      : string - the target CSP tenant ID
        TenantName    : string
        Resource      : string - 'insights' or 'graph'
        AuthMode      : string - 'AppOnly' or 'AppPlusUser' (default: resource-dependent)
#>

$params = $InputData | ConvertFrom-Json
$correlationId = $params.CorrelationId
$tenantId = $params.TenantId
$tenantName = $params.TenantName
$resource = $params.Resource
# Default is resource-aware: Partner Center (insights) requires the Secure App Model (App+User);
# Microsoft Graph (security score) uses an application permission (App-only).
$authMode = $params.AuthMode
if (-not $authMode) {
    $authMode = if ($resource -eq 'graph') { 'AppOnly' } else { 'AppPlusUser' }
}

$logPrefix = "[$correlationId][$tenantName]"
Write-Host "$logPrefix AcquireToken: Acquiring token for resource=$resource tenant=$tenantId authMode=$authMode"

try {
    $config = Get-IntegrationConfig
    $clientId = $config.AppClientId
    $vaultName = $config.KeyVaultName
    $certName = $config.AppCertificateName

    # Determine scope based on resource
    $surfaceKey = switch ($resource) {
        'insights' { 'partner-insights' }
        'graph' { 'graph-beta' }
        default { throw "Unknown resource: $resource" }
    }
    $scope = Get-ApiSurfaceTokenScope -ApiSurface $surfaceKey -AuthMode $authMode

    # Load certificate with private key from Key Vault (with retry)
    $x509Cert = Invoke-WithRetry -OperationName "$logPrefix KeyVaultCert" -ScriptBlock {
        Get-CertificateFromKeyVault -VaultName $vaultName -CertificateName $certName
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    if ($authMode -eq 'AppPlusUser') {
        # App+User flow: use stored refresh token (Secure Application Model).
        # Secret name comes from the centralized template (fixes prior code/doc drift).
        $refreshTokenSecretName = Get-RefreshTokenSecretName -TenantId $tenantId
        $refreshToken = Invoke-WithRetry -OperationName "$logPrefix RefreshTokenSecret" -ScriptBlock {
            Get-AzKeyVaultSecret -VaultName $vaultName -Name $refreshTokenSecretName -AsPlainText
        }

        if (-not $refreshToken) {
            throw "No refresh token found in Key Vault secret '$refreshTokenSecretName' for tenant $tenantId. Initial consent may be required."
        }

        $tokenResult = Get-RefreshTokenAccessToken `
            -ClientId $clientId `
            -TenantId $tenantId `
            -Certificate $x509Cert `
            -RefreshToken $refreshToken `
            -Scope $scope

        $stopwatch.Stop()

        # If the refresh token was rotated, update it in Key Vault
        if ($tokenResult.RefreshToken -and $tokenResult.RefreshToken -ne $refreshToken) {
            Write-Host "$logPrefix AcquireToken: Refresh token rotated, updating Key Vault"
            Invoke-WithRetry -OperationName "$logPrefix UpdateRefreshToken" -ScriptBlock {
                $secureValue = ConvertTo-SecureString -String $tokenResult.RefreshToken -AsPlainText -Force
                Set-AzKeyVaultSecret -VaultName $vaultName -Name $refreshTokenSecretName -SecretValue $secureValue | Out-Null
            }
        }

        Write-Host "$logPrefix AcquireToken: Success (AppPlusUser) for resource=$resource ($($stopwatch.ElapsedMilliseconds)ms)"

        return @{
            AccessToken = $tokenResult.AccessToken
            ExpiresIn   = $tokenResult.ExpiresIn
            Resource    = $resource
            TenantId    = $tenantId
            AuthMode    = 'AppPlusUser'
            Error       = $null
        }
    }
    else {
        # AppOnly flow: client_credentials
        $tokenResult = Get-MultiTenantAccessToken `
            -ClientId $clientId `
            -TenantId $tenantId `
            -Certificate $x509Cert `
            -Scope $scope

        $stopwatch.Stop()

        Write-Host "$logPrefix AcquireToken: Success (AppOnly) for resource=$resource ($($stopwatch.ElapsedMilliseconds)ms)"

        return @{
            AccessToken = $tokenResult.AccessToken
            ExpiresIn   = $tokenResult.ExpiresIn
            Resource    = $resource
            TenantId    = $tenantId
            AuthMode    = 'AppOnly'
            Error       = $null
        }
    }

}
catch {
    $errorMsg = $_.Exception.Message
    Write-Host "$logPrefix AcquireToken: FAILED for resource=$resource authMode=$authMode - $errorMsg"

    # Check if this is a consent/permission issue
    if ($errorMsg -match 'AADSTS65001|AADSTS700016|AADSTS50011') {
        Write-Host "$logPrefix AcquireToken: This appears to be a consent issue. Admin consent may need to be re-granted."
    }

    return @{
        AccessToken = $null
        ExpiresIn   = 0
        Resource    = $resource
        TenantId    = $tenantId
        AuthMode    = $authMode
        Error       = $errorMsg
    }
}
