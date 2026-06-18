<#
.SYNOPSIS
    One-time interactive Secure Application Model consent for a partner account.

.DESCRIPTION
    Partner Center APIs require the Secure Application Model with multifactor authentication
    (https://learn.microsoft.com/partner-center/developer/enable-secure-app-model). A human with
    the appropriate partner role (e.g. Admin Agent) must sign in interactively ONCE to grant
    consent and produce a long-lived refresh token. That refresh token is then stored in Azure
    Key Vault and used unattended by the function app, which rotates it on every run.

    This helper drives that one-time flow end-to-end:
      1. Loads the app certificate from Key Vault (same cert the runtime uses).
      2. Opens the browser for interactive sign-in (MFA) against the partner tenant.
      3. Captures the authorization code on a local loopback listener.
      4. Exchanges the code for a refresh token using the certificate client assertion.
      5. Stores the refresh token in Key Vault as 'refresh-token-<tenantId>'.
      6. Verifies the refresh token by immediately redeeming it for an access token.

    It reuses the function-app modules (TokenService / IntegrationConfig) so the consent exercises
    exactly the same auth code paths as the runtime.

.PARAMETER KeyVaultName
    Name of the Azure Key Vault holding the certificate and where the refresh token is stored.

.PARAMETER ClientId
    The Application (client) ID of the multi-tenant app registration.

.PARAMETER TenantId
    The partner tenant ID to grant consent in (the tenant whose API access you are enabling).

.PARAMETER CertificateName
    Name of the certificate secret in Key Vault. Default: app-certificate

.PARAMETER Resource
    Which API surface to consent for. Default: partner-insights

.PARAMETER RedirectPort
    Local loopback TCP port for the redirect listener. Must match a redirect URI registered on
    the app, e.g. http://localhost:8400/. Default: 8400

.EXAMPLE
    .\Initialize-SecureAppConsent.ps1 -KeyVaultName kv-hso-mpc-prod `
        -ClientId 1111... -TenantId 2222...

.NOTES
    Prerequisites:
      - The app registration must include the redirect URI http://localhost:<RedirectPort>/
        as a "Web" or "Mobile and desktop" platform redirect.
      - The app must have the delegated Partner Center 'user_impersonation' permission with
        admin consent granted (see Grant-AdminConsent.ps1).
      - Run this from a machine with a browser and Az PowerShell signed in
        (Connect-AzAccount) with access to the Key Vault.
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '',
    Justification = 'The refresh token is received over TLS and must be converted to a SecureString to persist it via Set-AzKeyVaultSecret.')]
param (
    [Parameter(Mandatory)]
    [string]$KeyVaultName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$TenantId,

    [string]$CertificateName = 'app-certificate',

    [ValidateSet('partner-insights', 'graph-beta')]
    [string]$Resource = 'partner-insights',

    [ValidateRange(1024, 65535)]
    [int]$RedirectPort = 8400
)

$ErrorActionPreference = 'Stop'

# Import the same modules the function app uses (single source of truth for auth logic).
$modulesPath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules'
foreach ($m in @('IntegrationConfig.psm1', 'TokenService.psm1')) {
    Import-Module (Join-Path $modulesPath $m) -Force
}

$redirectUri = "http://localhost:$RedirectPort/"

Write-Host '=== HSO Partner Insights — Secure App Model Consent ===' -ForegroundColor Cyan
Write-Host "Key Vault    : $KeyVaultName"
Write-Host "Client ID    : $ClientId"
Write-Host "Tenant ID    : $TenantId"
Write-Host "Resource     : $Resource"
Write-Host "Redirect URI : $redirectUri"
Write-Host ''

# Step 1: certificate (must match the cert the runtime authenticates with)
Write-Host "[1/5] Loading certificate '$CertificateName' from Key Vault..." -ForegroundColor Yellow
$cert = Get-CertificateFromKeyVault -VaultName $KeyVaultName -CertificateName $CertificateName
Write-Host "  Loaded (thumbprint: $($cert.Thumbprint), expires: $($cert.NotAfter))"
Write-Host ''

# Step 2: build the authorization request. 'offline_access' is required to receive a refresh token.
$scope = Get-ApiSurfaceTokenScope -ApiSurface $Resource -AuthMode AppPlusUser -IncludeOfflineAccess
$state = [guid]::NewGuid().ToString()

$authorizeUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize" +
"?client_id=$ClientId" +
"&response_type=code" +
"&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
"&response_mode=query" +
"&scope=$([uri]::EscapeDataString($scope))" +
"&state=$state" +
'&prompt=select_account'

# Step 3: start a loopback listener, open the browser, capture the code.
Write-Host '[2/5] Starting local listener and opening browser for interactive sign-in (MFA)...' -ForegroundColor Yellow
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($redirectUri)

try {
    $listener.Start()
}
catch {
    throw "Could not bind to $redirectUri. On Windows you may need to reserve the URL once " +
    "(run as admin): netsh http add urlacl url=$redirectUri user=$env:USERNAME. Error: $($_.Exception.Message)"
}

Write-Host '  Waiting for the redirect. Complete the sign-in in your browser...' -ForegroundColor Gray
Start-Process $authorizeUrl

$authCode = $null
try {
    $context = $listener.GetContext()   # blocks until the browser is redirected back
    $request = $context.Request

    $returnedState = $request.QueryString['state']
    $authCode = $request.QueryString['code']
    $oauthError = $request.QueryString['error']
    $oauthErrorDesc = $request.QueryString['error_description']

    # Respond to the browser so the user sees a friendly message.
    $responseHtml = if ($authCode) {
        '<html><body style="font-family:sans-serif"><h2>Consent captured.</h2>' +
        '<p>You can close this tab and return to the terminal.</p></body></html>'
    }
    else {
        "<html><body style='font-family:sans-serif'><h2>Consent failed.</h2><p>$oauthError</p></body></html>"
    }
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($responseHtml)
    $context.Response.ContentLength64 = $buffer.Length
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.OutputStream.Close()

    if ($oauthError) {
        throw "Authorization failed: $oauthError - $oauthErrorDesc"
    }
    if ($returnedState -ne $state) {
        throw 'State mismatch on the authorization response. Aborting to avoid a possible CSRF/replay.'
    }
    if (-not $authCode) {
        throw 'No authorization code was returned.'
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}

Write-Host '  Authorization code received.' -ForegroundColor Green
Write-Host ''

# Step 4: redeem the code for a refresh token (certificate client assertion).
Write-Host '[3/5] Exchanging authorization code for a refresh token...' -ForegroundColor Yellow
$tokenResult = Get-AuthorizationCodeToken `
    -ClientId $ClientId `
    -TenantId $TenantId `
    -Certificate $cert `
    -AuthorizationCode $authCode `
    -RedirectUri $redirectUri `
    -Scope $scope

if (-not $tokenResult.RefreshToken) {
    throw "No refresh token returned. Ensure 'offline_access' is consented and the app is a confidential client."
}
Write-Host '  Refresh token acquired.' -ForegroundColor Green
Write-Host ''

# Step 5: store the refresh token in Key Vault using the canonical secret name.
$secretName = Get-RefreshTokenSecretName -TenantId $TenantId
Write-Host "[4/5] Storing refresh token in Key Vault as '$secretName'..." -ForegroundColor Yellow
$secureValue = ConvertTo-SecureString -String $tokenResult.RefreshToken -AsPlainText -Force
Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue $secureValue | Out-Null
Write-Host '  Stored.' -ForegroundColor Green
Write-Host ''

# Step 6: verify by immediately redeeming the stored refresh token (the unattended runtime path).
Write-Host '[5/5] Verifying unattended renewal by redeeming the stored refresh token...' -ForegroundColor Yellow
$verify = Get-RefreshTokenAccessToken `
    -ClientId $ClientId `
    -TenantId $TenantId `
    -Certificate $cert `
    -RefreshToken $tokenResult.RefreshToken `
    -Scope (Get-ApiSurfaceTokenScope -ApiSurface $Resource -AuthMode AppPlusUser)

if ($verify.AccessToken) {
    Write-Host '  Access token obtained from the refresh token — unattended renewal works.' -ForegroundColor Green
    # If the verification rotated the refresh token, persist the latest value.
    if ($verify.RefreshToken -and $verify.RefreshToken -ne $tokenResult.RefreshToken) {
        Write-Host '  Refresh token rotated during verification — updating Key Vault.' -ForegroundColor Gray
        $rotated = ConvertTo-SecureString -String $verify.RefreshToken -AsPlainText -Force
        Set-AzKeyVaultSecret -VaultName $KeyVaultName -Name $secretName -SecretValue $rotated | Out-Null
    }
}
else {
    throw 'Verification failed: could not obtain an access token from the stored refresh token.'
}

Write-Host ''
Write-Host "Consent complete for $TenantId. The function app will now renew unattended." -ForegroundColor Cyan
