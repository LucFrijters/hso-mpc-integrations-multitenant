<#
.SYNOPSIS
    Token acquisition module for multi-tenant Partner Center / Graph API integration.
    Provides JWT client assertion generation and token acquisition helpers.
#>

function New-ClientAssertionJwt {
    <#
    .SYNOPSIS
        Creates a signed JWT client assertion for certificate-based OAuth2 authentication.
    .PARAMETER Certificate
        The X509Certificate2 with a private key.
    .PARAMETER ClientId
        The application (client) ID.
    .PARAMETER TenantId
        The target tenant ID (used to build the audience).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$TenantId
    )

    $audience = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $now = [DateTimeOffset]::UtcNow
    $notBefore = $now.ToUnixTimeSeconds()
    $expiry = $now.AddMinutes(10).ToUnixTimeSeconds()
    $jti = [guid]::NewGuid().ToString()

    # Build header
    $thumbprint = $Certificate.GetCertHash()
    $x5t = [Convert]::ToBase64String($thumbprint) -replace '\+', '-' -replace '/', '_' -replace '='

    $header = @{
        alg = 'RS256'
        typ = 'JWT'
        x5t = $x5t
    } | ConvertTo-Json -Compress

    # Build payload
    $payload = @{
        aud = $audience
        iss = $ClientId
        sub = $ClientId
        jti = $jti
        nbf = $notBefore
        exp = $expiry
        iat = $notBefore
    } | ConvertTo-Json -Compress

    # Base64url encode
    $headerB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($header))
    $payloadB64 = ConvertTo-Base64Url -Bytes ([System.Text.Encoding]::UTF8.GetBytes($payload))

    $signingInput = "$headerB64.$payloadB64"

    # Sign with RSA-SHA256. Use the static extension method so this works
    # whether $Certificate exposes GetRSAPrivateKey() directly or only via
    # RSACertificateExtensions (depends on .NET surface area available).
    $rsa = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($Certificate)
    if (-not $rsa) {
        throw "Certificate does not contain an accessible RSA private key."
    }
    $signatureBytes = $rsa.SignData(
        [System.Text.Encoding]::UTF8.GetBytes($signingInput),
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
    )

    $signatureB64 = ConvertTo-Base64Url -Bytes $signatureBytes

    return "$signingInput.$signatureB64"
}


function Get-CertificateFromKeyVault {
    <#
    .SYNOPSIS
        Loads an X509Certificate2 (with private key) from Azure Key Vault.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$VaultName,

        [Parameter(Mandatory)]
        [string]$CertificateName
    )

    # Get the named certificate backing secret because the PFX private key is stored there.
    $secretValue = Get-AzKeyVaultSecret -VaultName $VaultName -Name $CertificateName -AsPlainText -WarningAction SilentlyContinue
    $certBytes = [Convert]::FromBase64String($secretValue)

    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
        $certBytes,
        [string]::Empty,
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::MachineKeySet -bor
        [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::Exportable
    )

    if (-not $cert.HasPrivateKey) {
        throw "Certificate '$CertificateName' from Key Vault does not contain a private key."
    }

    return $cert
}


function Get-MultiTenantAccessToken {
    <#
    .SYNOPSIS
        Acquires an access token for a specific tenant using client credentials + certificate.
    .PARAMETER ClientId
        Application client ID.
    .PARAMETER TenantId
        Target tenant ID.
    .PARAMETER Certificate
        X509Certificate2 with private key.
    .PARAMETER Scope
        The OAuth2 scope (e.g., 'https://graph.microsoft.com/.default').
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$Scope
    )

    $clientAssertion = New-ClientAssertionJwt -Certificate $Certificate -ClientId $ClientId -TenantId $TenantId

    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $body = @{
        client_id             = $ClientId
        scope                 = $Scope
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $clientAssertion
        grant_type            = 'client_credentials'
    }

    $response = Invoke-RestMethod -Uri $tokenEndpoint -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

    return @{
        AccessToken = $response.access_token
        ExpiresIn   = $response.expires_in
        TokenType   = $response.token_type
    }
}


function Get-RefreshTokenAccessToken {
    <#
    .SYNOPSIS
        Exchanges a stored refresh token for an access token (App+User flow).
    .PARAMETER ClientId
        Application client ID.
    .PARAMETER TenantId
        Target tenant ID.
    .PARAMETER Certificate
        X509Certificate2 with private key.
    .PARAMETER RefreshToken
        The stored refresh token.
    .PARAMETER Scope
        The OAuth2 scope.
    .RETURNS
        Hashtable with AccessToken, RefreshToken (new if rotated), ExpiresIn.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$RefreshToken,
        [Parameter(Mandatory)][string]$Scope
    )

    $clientAssertion = New-ClientAssertionJwt -Certificate $Certificate -ClientId $ClientId -TenantId $TenantId

    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $body = @{
        client_id             = $ClientId
        scope                 = $Scope
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $clientAssertion
        grant_type            = 'refresh_token'
        refresh_token         = $RefreshToken
    }

    $response = Invoke-RestMethod -Uri $tokenEndpoint -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

    return @{
        AccessToken  = $response.access_token
        RefreshToken = $response.refresh_token  # May be rotated
        ExpiresIn    = $response.expires_in
        TokenType    = $response.token_type
    }
}


# --- Utility ---
function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes) -replace '\+', '-' -replace '/', '_' -replace '='
}


function Get-AuthorizationCodeToken {
    <#
    .SYNOPSIS
        Exchanges an OAuth2 authorization code for an access + refresh token (Secure App Model
        one-time consent). Uses the same certificate client assertion as the runtime flows.
    .PARAMETER ClientId
        Application client ID.
    .PARAMETER TenantId
        Target tenant ID (the partner tenant the consent was granted in).
    .PARAMETER Certificate
        X509Certificate2 with private key.
    .PARAMETER AuthorizationCode
        The authorization code returned to the redirect URI after interactive sign-in.
    .PARAMETER RedirectUri
        The redirect URI used to obtain the authorization code (must match exactly).
    .PARAMETER Scope
        The OAuth2 scope. Must include 'offline_access' to receive a refresh token.
    .RETURNS
        Hashtable with AccessToken, RefreshToken, ExpiresIn, TokenType.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$AuthorizationCode,
        [Parameter(Mandatory)][string]$RedirectUri,
        [Parameter(Mandatory)][string]$Scope
    )

    $clientAssertion = New-ClientAssertionJwt -Certificate $Certificate -ClientId $ClientId -TenantId $TenantId

    $tokenEndpoint = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"

    $body = @{
        client_id             = $ClientId
        scope                 = $Scope
        code                  = $AuthorizationCode
        redirect_uri          = $RedirectUri
        client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'
        client_assertion      = $clientAssertion
        grant_type            = 'authorization_code'
    }

    $response = Invoke-RestMethod -Uri $tokenEndpoint -Method Post -Body $body `
        -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

    return @{
        AccessToken  = $response.access_token
        RefreshToken = $response.refresh_token
        ExpiresIn    = $response.expires_in
        TokenType    = $response.token_type
    }
}


Export-ModuleMember -Function @(
    'New-ClientAssertionJwt'
    'Get-CertificateFromKeyVault'
    'Get-MultiTenantAccessToken'
    'Get-RefreshTokenAccessToken'
    'Get-AuthorizationCodeToken'
    'ConvertTo-Base64Url'
)
