<#
.SYNOPSIS
    Rotates the certificate used by the HSO MPC Integration app.

.DESCRIPTION
    Generates a new self-signed certificate in Azure Key Vault, updates the
    app registration, and verifies the rotation. The old certificate is
    kept until its expiry for a graceful transition period.

.PARAMETER KeyVaultName
    Name of the Azure Key Vault holding the certificate.

.PARAMETER CertificateName
    Name of the certificate in Key Vault. Default: regapp-certificate-hso-mpc-integration

.PARAMETER ClientId
    The Application (client) ID of the multi-tenant app registration.

.PARAMETER ValidityMonths
    Certificate validity period in months. Default: 12

.PARAMETER SubjectName
    Certificate subject. Default: CN=regapp-certificate-hso-mpc-integration

.EXAMPLE
    .\Rotate-Certificate.ps1 -KeyVaultName "kv-hso-mpc-integration" -ClientId "11111111-1111-1111-1111-111111111111"
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter()]
    [string]$KeyVaultName = 'kv-hso-mpc-integration',

    [string]$CertificateName = 'regapp-certificate-hso-mpc-integration',

    [Parameter()]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$ClientId = '05573d61-6ddf-403b-90c6-d8572e6c867f',

    [ValidateRange(1, 36)]
    [int]$ValidityMonths = 12,

    [string]$SubjectName = 'CN=regapp-certificate-hso-mpc-integration'
)

$ErrorActionPreference = 'Stop'

Write-Host "=== HSO MPC Integration — Certificate Rotation ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Key Vault       : $KeyVaultName"
Write-Host "Certificate Name : $CertificateName"
Write-Host "Client ID        : $ClientId"
Write-Host "Validity         : $ValidityMonths months"
Write-Host ""

# Step 1: Check current certificate
Write-Host "[1/5] Checking current certificate..." -ForegroundColor Yellow

$currentCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -ErrorAction SilentlyContinue
if ($currentCert) {
    Write-Host "  Current version : $($currentCert.Version)"
    Write-Host "  Thumbprint      : $($currentCert.Thumbprint)"
    Write-Host "  Expires         : $($currentCert.Expires)"
    Write-Host "  Enabled         : $($currentCert.Enabled)"
}
else {
    Write-Host "  No existing certificate found. Creating new one." -ForegroundColor Yellow
}

# Step 2: Create new certificate version in Key Vault
Write-Host ""
Write-Host "[2/5] Creating new certificate in Key Vault..." -ForegroundColor Yellow

$certPolicy = New-AzKeyVaultCertificatePolicy `
    -SubjectName $SubjectName `
    -IssuerName 'Self' `
    -ValidityInMonths $ValidityMonths `
    -KeyType 'RSA' `
    -KeySize 2048 `
    -KeyUsage 'DigitalSignature' `
    -SecretContentType 'application/x-pkcs12' `
    -RenewAtPercentageLifetime 80

if ($PSCmdlet.ShouldProcess($CertificateName, "Create new certificate version in $KeyVaultName")) {
    $operation = Add-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName -CertificatePolicy $certPolicy

    # Wait for certificate to be created
    $maxWait = 120
    $waited = 0
    while ($operation.Status -ne 'completed' -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 5
        $waited += 5
        $operation = Get-AzKeyVaultCertificateOperation -VaultName $KeyVaultName -Name $CertificateName
        Write-Host "  Status: $($operation.Status) (waited ${waited}s)" -ForegroundColor Gray
    }

    if ($operation.Status -ne 'completed') {
        throw "Certificate creation did not complete within ${maxWait} seconds."
    }
}

# Step 3: Get the new certificate
Write-Host ""
Write-Host "[3/5] Retrieving new certificate..." -ForegroundColor Yellow

$newCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName
Write-Host "  New version  : $($newCert.Version)"
Write-Host "  Thumbprint   : $($newCert.Thumbprint)"
Write-Host "  Expires      : $($newCert.Expires)"

# Step 4: Update the app registration with the new certificate
Write-Host ""
Write-Host "[4/5] Updating app registration with new certificate..." -ForegroundColor Yellow

$certBytes = $newCert.Certificate.GetRawCertData()
$base64Cert = [System.Convert]::ToBase64String($certBytes)

if ($PSCmdlet.ShouldProcess($ClientId, "Add new certificate credential to app registration")) {
    $app = Get-AzADApplication -ApplicationId $ClientId

    # Add the new credential (don't remove old ones yet for graceful transition)
    New-AzADAppCredential -ObjectId $app.Id -CertValue $base64Cert -EndDate $newCert.Certificate.NotAfter

    Write-Host "  ✓ Certificate added to app registration" -ForegroundColor Green

    # List all credentials
    $creds = Get-AzADAppCredential -ObjectId $app.Id
    Write-Host "  Current credentials ($($creds.Count) total):" -ForegroundColor Gray
    foreach ($cred in $creds) {
        $status = if ($cred.EndDateTime -lt (Get-Date)) { "(EXPIRED)" } else { "(active)" }
        Write-Host "    - $($cred.DisplayName) | Expires: $($cred.EndDateTime) $status"
    }
}

# Step 5: Verify
Write-Host ""
Write-Host "[5/5] Verification..." -ForegroundColor Yellow

$verifyCert = Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name $CertificateName
if ($verifyCert.Thumbprint -eq $newCert.Thumbprint) {
    Write-Host "  ✓ Key Vault certificate is current" -ForegroundColor Green
}
else {
    Write-Host "  ✗ Key Vault certificate mismatch" -ForegroundColor Red
}

Write-Host ""
Write-Host "Certificate rotation complete." -ForegroundColor Cyan
Write-Host ""
Write-Host "IMPORTANT:" -ForegroundColor Yellow
Write-Host "  - The old certificate is still active for a graceful transition."
Write-Host "  - After verifying the new certificate works, remove expired credentials:"
Write-Host "    Remove-AzADAppCredential -ObjectId <appObjectId> -KeyId <expiredKeyId>"
Write-Host ""
