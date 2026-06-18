<#
.SYNOPSIS
    Grants admin consent for the multi-tenant app registration in a customer/partner tenant.

.DESCRIPTION
    This script automates the admin consent flow for the HSO MPC Integration app.
    It must be run by a Global Admin or Privileged Role Administrator in the target tenant.

.PARAMETER TenantId
    The Azure AD tenant ID of the customer/partner tenant.

.PARAMETER ClientId
    The Application (client) ID of the multi-tenant app registration.

.PARAMETER RedirectUri
    The redirect URI registered in the app registration. Default: http://localhost

.EXAMPLE
    .\Grant-AdminConsent.ps1 -TenantId "00000000-0000-0000-0000-000000000000" -ClientId "11111111-1111-1111-1111-111111111111"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$')]
    [string]$ClientId,

    [string]$RedirectUri = 'http://localhost'
)

$ErrorActionPreference = 'Stop'

Write-Host "=== HSO MPC Integration — Admin Consent ===" -ForegroundColor Cyan
Write-Host ""
Write-Host "Tenant ID : $TenantId"
Write-Host "Client ID : $ClientId"
Write-Host ""

# Build the admin consent URL
$consentUrl = "https://login.microsoftonline.com/$TenantId/adminconsent" +
    "?client_id=$ClientId" +
    "&redirect_uri=$([System.Uri]::EscapeDataString($RedirectUri))" +
    "&state=$(New-Guid)"

Write-Host "Opening admin consent URL in your default browser..." -ForegroundColor Yellow
Write-Host ""
Write-Host "URL: $consentUrl" -ForegroundColor Gray
Write-Host ""

Start-Process $consentUrl

Write-Host "After granting consent in the browser, verify the service principal was created:" -ForegroundColor Yellow
Write-Host ""

# Wait for user to complete consent
Read-Host "Press Enter after completing the consent flow in the browser"

# Verify the service principal exists
Write-Host "Verifying service principal in tenant $TenantId..." -ForegroundColor Cyan

try {
    Connect-AzAccount -TenantId $TenantId -ErrorAction Stop | Out-Null

    $sp = Get-AzADServicePrincipal -ApplicationId $ClientId -ErrorAction SilentlyContinue

    if ($sp) {
        Write-Host "Service principal found:" -ForegroundColor Green
        Write-Host "  Display Name : $($sp.DisplayName)"
        Write-Host "  Object ID    : $($sp.Id)"
        Write-Host "  App ID       : $($sp.AppId)"
        Write-Host ""

        # Check app role assignments
        $assignments = Get-AzADAppPermission -ObjectId $sp.Id -ErrorAction SilentlyContinue
        if ($assignments) {
            Write-Host "  Granted permissions:" -ForegroundColor Green
            $assignments | ForEach-Object {
                Write-Host "    - $($_.ResourceDisplayName): $($_.PermissionName) ($($_.ConsentType))"
            }
        }
    }
    else {
        Write-Host "Service principal NOT found. Consent may not have been granted." -ForegroundColor Red
        Write-Host "  Try running this script again and ensure you click 'Accept' in the consent prompt." -ForegroundColor Yellow
    }
}
catch {
    Write-Host "Warning: Could not verify service principal automatically." -ForegroundColor Yellow
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Manual verification steps:" -ForegroundColor Yellow
    Write-Host "1. Go to Azure Portal → Azure AD → Enterprise Applications"
    Write-Host "2. Search for application ID: $ClientId"
    Write-Host "3. Verify the service principal exists and permissions are granted"
}

Write-Host ""
Write-Host "Done." -ForegroundColor Cyan
