<#
.SYNOPSIS
    Full end-to-end manual deployment for the HSO MPC Multi-Tenant Integration.

.DESCRIPTION
    Performs all deployment steps locally without requiring GitHub Actions or any
    other CI/CD pipeline. Run this script from any machine with the prerequisites
    installed and with sufficient Azure RBAC (Contributor + User Access Administrator
    on the target subscription / resource group).

    Steps performed:
        1. Prerequisites check (Az CLI, Az PowerShell module, Bicep CLI)
        2. Azure authentication
        3. Configuration summary + confirmation
        4. Resource group creation (idempotent)
        5. Bicep what-if validation
        6. Infrastructure deployment (main.bicep)
        7. Function app code packaging
        8. Function app code deployment (zip deploy)
        9. Post-deployment verification
       10. Next-steps checklist

.PARAMETER Environment
    Target environment: 'dev' or 'prod'. Controls which parameter file is used.
    Default: 'dev'

.PARAMETER ResourceGroupName
    Azure resource group name. Defaults to 'rg-hso-mpc-multitenant-integration-{Environment}'.

.PARAMETER Location
    Azure region for the resource group. Default: 'westeurope'

.PARAMETER AppClientId
    The multi-tenant app registration (client) ID. Required unless the APP_CLIENT_ID
    environment variable is already set.

.PARAMETER AlertEmailAddress
    Email address for Azure Monitor action group notifications. Defaults to
    ALERT_EMAIL_ADDRESS or integration-alerts@hso.com.

.PARAMETER SubscriptionId
    Azure subscription ID to target. If omitted, uses the current default subscription.

.PARAMETER SkipInfra
    Skip the Bicep infrastructure deployment and jump straight to code deployment.
    Useful after infrastructure is already provisioned.

.PARAMETER SkipCode
    Skip the function app code deployment. Useful for infrastructure-only updates.

.PARAMETER Force
    Skip the interactive confirmation prompt before the actual deployment. Use with
    care in automated/unattended scenarios.

.EXAMPLE
    # Interactive full deployment to dev
    .\Deploy.ps1 -Environment dev -AppClientId "11111111-1111-1111-1111-111111111111"

.EXAMPLE
    # Production deployment to a specific subscription, no prompt
    .\Deploy.ps1 -Environment prod `
                 -AppClientId "11111111-1111-1111-1111-111111111111" `
                 -SubscriptionId "22222222-2222-2222-2222-222222222222" `
                 -Force

.EXAMPLE
    # Re-deploy function code only (infra already up)
    .\Deploy.ps1 -Environment prod -AppClientId "11111111-..." -SkipInfra

.EXAMPLE
    # Infrastructure only (e.g., after a Bicep change, no code change)
    .\Deploy.ps1 -Environment prod -AppClientId "11111111-..." -SkipCode
#>

[CmdletBinding()]
param (
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'prod',

    [string]$ResourceGroupName = "hso-mpc-multitenant-integration-prd-westeu",

    [string]$Location = 'westeurope',

    [string]$AppClientId = '05573d61-6ddf-403b-90c6-d8572e6c867f',

    [string]$AlertEmailAddress = 'lfrijters@hso.com',

    [string]$SubscriptionId = "12fe5cbf-2fab-4937-9368-655f987fecab", # HSO Group (DevTest)

    [switch]$SkipInfra,

    [switch]$SkipCode,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path $scriptRoot -Parent

# ─── Helpers ────────────────────────────────────────────────────────────────

function Write-Banner {
    param([string]$Text, [ConsoleColor]$Color = 'Cyan')
    $line = '─' * ($Text.Length + 4)
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host "  $Text" -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
}

function Write-Step {
    param([int]$N, [string]$Text)
    Write-Host ""
    Write-Host "[$N/$TotalSteps] $Text" -ForegroundColor Cyan
}

function Write-Ok { param([string]$M) Write-Host "  [OK] $M" -ForegroundColor Green }
function Write-Warn { param([string]$M) Write-Host "  [!]  $M" -ForegroundColor Yellow }
function Write-Err { param([string]$M) Write-Host "  [X]  $M" -ForegroundColor Red }

function Assert-ExitCode {
    param([string]$OperationName)
    if ($LASTEXITCODE -ne 0) {
        Write-Err "$OperationName failed (exit code $LASTEXITCODE)."
        exit 1
    }
}

function Test-CommandExists { param([string]$Name) $null -ne (Get-Command $Name -ErrorAction SilentlyContinue) }

$TotalSteps = 10

# ─── Banner ─────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  HSO MPC Multi-Tenant Integration — Manual Deployment Script     ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# ─── STEP 1: Prerequisites ──────────────────────────────────────────────────

Write-Step 1 "Checking prerequisites"

$failed = $false

# Azure CLI
if (Test-CommandExists 'az') {
    $azVer = (az version --output json 2>$null | ConvertFrom-Json).'azure-cli'
    Write-Ok "Azure CLI $azVer"
}
else {
    Write-Err "Azure CLI not found. Install: https://aka.ms/installazurecliwindows"
    $failed = $true
}

# Az PowerShell module
$azModule = Get-Module -Name Az.Accounts -ListAvailable -ErrorAction SilentlyContinue |
Sort-Object Version -Descending | Select-Object -First 1
if ($azModule) {
    Write-Ok "Az PowerShell module $($azModule.Version)"
}
else {
    Write-Warn "Az PowerShell module not found. Install with: Install-Module Az -Scope CurrentUser"
    Write-Warn "It is required by the function app scripts (TokenService, BlobStorageService)."
}

# Bicep CLI (via Az CLI extension — auto-install if missing)
$bicepCheck = az bicep version 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Bicep not available — installing via 'az bicep install'..."
    az bicep install
    Assert-ExitCode 'az bicep install'
    Write-Ok "Bicep CLI installed"
}
else {
    $bicepVer = ($bicepCheck -split '\s+')[-1]
    Write-Ok "Bicep CLI $bicepVer"
}

# APP_CLIENT_ID
if (-not $AppClientId) {
    Write-Err "AppClientId is required. Pass -AppClientId or set the APP_CLIENT_ID environment variable."
    $failed = $true
}
else {
    Write-Ok "APP_CLIENT_ID is set"
}

if ($failed) {
    Write-Host ""
    Write-Err "One or more prerequisites are missing. Resolve them and retry."
    exit 1
}

# ─── STEP 2: Azure authentication ───────────────────────────────────────────

Write-Step 2 "Azure authentication"

$account = az account show --output json 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "  Not logged in — launching 'az login'..." -ForegroundColor Yellow
    az login --output none
    Assert-ExitCode 'az login'
    $account = az account show --output json | ConvertFrom-Json
}
Write-Ok "Signed in as: $($account.user.name)"

if ($SubscriptionId) {
    az account set --subscription $SubscriptionId --output none
    Assert-ExitCode "az account set"
    $account = az account show --output json | ConvertFrom-Json
}
Write-Ok "Subscription : $($account.name) ($($account.id))"

# ─── STEP 3: Configuration summary ──────────────────────────────────────────

Write-Step 3 "Configuration"

if (-not $ResourceGroupName) {
    $ResourceGroupName = "rg-hso-mpc-multitenant-integration-$Environment"
}

$paramFile = Join-Path $repoRoot 'infra' 'parameters' "${Environment}.bicepparam"
$bicepFile = Join-Path $repoRoot 'infra' 'main.bicep'
$funcAppDir = Join-Path $repoRoot 'src' 'function-app'
$deployDir = Join-Path $repoRoot 'deploy'
$zipFile = Join-Path $deployDir 'function-app.zip'
$deployName = "manual-$Environment-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Validate required paths
foreach ($path in @($bicepFile, $paramFile, $funcAppDir)) {
    if (-not (Test-Path $path)) {
        Write-Err "Required path not found: $path"
        exit 1
    }
}

$rows = [ordered]@{
    'Environment'      = $Environment
    'Resource Group'   = $ResourceGroupName
    'Location'         = $Location
    'Subscription'     = "$($account.name) ($($account.id))"
    'Bicep template'   = $bicepFile
    'Parameter file'   = $paramFile
    'Function app dir' = $funcAppDir
    'Deploy zip'       = $zipFile
    'Skip infra'       = $SkipInfra.ToString()
    'Skip code'        = $SkipCode.ToString()
}

foreach ($kv in $rows.GetEnumerator()) {
    Write-Host ("    {0,-18} {1}" -f "$($kv.Key):", $kv.Value) -ForegroundColor Gray
}

if (-not $Force) {
    Write-Host ""
    $confirm = Read-Host "  Proceed with this configuration? [y/N]"
    if ($confirm -notmatch '^[Yy]$') {
        Write-Host "  Deployment cancelled." -ForegroundColor Yellow
        exit 0
    }
}

# ─── STEP 4: Resource group ──────────────────────────────────────────────────

Write-Step 4 "Resource group"

$rg = az group show --name $ResourceGroupName --output json 2>$null | ConvertFrom-Json
if ($rg) {
    Write-Ok "Resource group '$ResourceGroupName' already exists ($($rg.location))"
}
else {
    Write-Host "  Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Yellow
    az group create `
        --name $ResourceGroupName `
        --location $Location `
        --tags "project=hso-mpc-multitenant-integration" "environment=$Environment" "managedBy=manual-deploy" `
        --output none
    Assert-ExitCode "az group create"
    Write-Ok "Resource group created"
}

# ─── STEP 5: Bicep what-if ──────────────────────────────────────────────────

Write-Step 5 "Bicep what-if validation"

# Export APP_CLIENT_ID so readEnvironmentVariable() in the .bicepparam file resolves it
$env:APP_CLIENT_ID = $AppClientId
$env:ALERT_EMAIL_ADDRESS = $AlertEmailAddress

if (-not $SkipInfra) {
    Write-Host "  Running what-if analysis (no changes applied)..." -ForegroundColor Yellow
    az deployment sub what-if `
        --location $Location `
        --template-file $bicepFile `
        --parameters $paramFile `
        --parameters rgName=$ResourceGroupName rgLocation=$Location `
        --name $deployName `
        --output table
    Assert-ExitCode "az deployment sub what-if"
    Write-Ok "What-if completed"
}
else {
    Write-Warn "Skipped (--SkipInfra)"
}

# ─── STEP 6: Infrastructure deployment ──────────────────────────────────────

Write-Step 6 "Infrastructure deployment (Bicep)"

$functionAppName = $null

if (-not $SkipInfra) {
    Write-Host "  Deploying infrastructure — this typically takes 5–10 minutes..." -ForegroundColor Yellow

    $rawOutput = az deployment sub create `
        --location $Location `
        --template-file $bicepFile `
        --parameters $paramFile `
        --parameters rgName=$ResourceGroupName rgLocation=$Location `
        --name $deployName `
        --output json 2>&1

    Assert-ExitCode "az deployment sub create"

    $deployment = $rawOutput | ConvertFrom-Json
    $state = $deployment.properties.provisioningState

    if ($state -ne 'Succeeded') {
        Write-Err "Provisioning state: $state (expected Succeeded)"
        exit 1
    }

    $out = $deployment.properties.outputs
    $functionAppName = $out.functionAppName.value
    $storageAccountName = $out.storageAccountName.value
    $keyVaultName = $out.keyVaultName.value
    $appInsightsName = $out.appInsightsName.value
    $functionAppPrincipalId = $out.functionAppPrincipalId.value

    Write-Ok "Infrastructure deployed (state: $state)"
    Write-Host ""
    Write-Host "  Deployed resources:" -ForegroundColor Gray
    Write-Host "    Function App     : $functionAppName"       -ForegroundColor Gray
    Write-Host "    Storage Account  : $storageAccountName"    -ForegroundColor Gray
    Write-Host "    Key Vault        : $keyVaultName"          -ForegroundColor Gray
    Write-Host "    App Insights     : $appInsightsName"       -ForegroundColor Gray
    Write-Host "    MI Principal ID  : $functionAppPrincipalId" -ForegroundColor Gray

}
else {
    Write-Warn "Skipped (--SkipInfra)"

    # Resolve the function app name from the existing deployment
    $functionAppName = az functionapp list `
        --resource-group $ResourceGroupName `
        --query "[0].name" `
        --output tsv 2>$null

    if (-not $functionAppName) {
        Write-Err "No function app found in '$ResourceGroupName'. Deploy infrastructure first or remove --SkipInfra."
        exit 1
    }
    Write-Ok "Using existing function app: $functionAppName"
}

# ─── STEP 7: Package function app ────────────────────────────────────────────

Write-Step 7 "Packaging function app"

if (-not $SkipCode) {

    if (-not (Test-Path $deployDir)) {
        New-Item -ItemType Directory -Path $deployDir | Out-Null
    }
    if (Test-Path $zipFile) {
        Remove-Item $zipFile -Force
    }

    Write-Host "  Collecting files from: $funcAppDir" -ForegroundColor Yellow

    # Exclude local-only files that must not reach the cloud runtime
    $excludeFiles = @('local.settings.json')
    $excludeDirectories = @('.vscode')

    $filesToZip = Get-ChildItem -Path $funcAppDir -Recurse -File |
    Where-Object {
        $excludeFiles -notcontains $_.Name -and
        -not ($_.FullName.Substring($funcAppDir.Length + 1).Split([IO.Path]::DirectorySeparatorChar) | Where-Object { $excludeDirectories -contains $_ })
    }

    if ($filesToZip.Count -eq 0) {
        Write-Err "No files found in $funcAppDir"
        exit 1
    }

    # Build zip using .NET to handle Windows path separators correctly
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::Open($zipFile, 'Create')
    try {
        foreach ($file in $filesToZip) {
            # Store with forward slashes so the Linux-based runtime resolves paths correctly
            $entryName = $file.FullName.Substring($funcAppDir.Length + 1).Replace('\', '/')
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal
            ) | Out-Null
        }
    }
    finally {
        $zip.Dispose()
    }

    $sizeMb = [Math]::Round((Get-Item $zipFile).Length / 1MB, 2)
    Write-Ok "Package: $zipFile ($sizeMb MB, $($filesToZip.Count) files)"

}
else {
    Write-Warn "Skipped (--SkipCode)"
}

# ─── STEP 8: Deploy function app code ────────────────────────────────────────

Write-Step 8 "Deploying function app code"

if (-not $SkipCode) {

    Write-Host "  Uploading zip package to: $functionAppName" -ForegroundColor Yellow

    az functionapp deployment source config-zip `
        --resource-group $ResourceGroupName `
        --name $functionAppName `
        --src $zipFile `
        --output none

    Assert-ExitCode "az functionapp deployment source config-zip"

    Write-Ok "Code deployed to $functionAppName"

    foreach ($legacySettingName in @(
            'TIMER_SCHEDULE'
            'INSIGHTS_DAILY_HOUR_UTC'
            'INSIGHTS_AUTH_MODE'
            'INSIGHTS_ENSURE_ALL_DATASETS'
            'INSIGHTS_RECURRENCE_HOURS'
            'INSIGHTS_RECURRENCE_COUNT'
        )) {
        $legacySettingCount = az functionapp config appsettings list `
            --resource-group $ResourceGroupName `
            --name $functionAppName `
            --query "[?name=='$legacySettingName'] | length(@)" `
            --output tsv 2>$null

        if ($legacySettingCount -and [int]$legacySettingCount -gt 0) {
            Write-Host "  Removing legacy $legacySettingName app setting..." -ForegroundColor Yellow

            az functionapp config appsettings delete `
                --resource-group $ResourceGroupName `
                --name $functionAppName `
                --setting-names $legacySettingName `
                --output none

            Assert-ExitCode "az functionapp config appsettings delete $legacySettingName"
            Write-Ok "Removed legacy $legacySettingName app setting"
        }
    }

    Write-Host "  Waiting 30 seconds for the host to restart..." -ForegroundColor Gray
    Start-Sleep -Seconds 30

}
else {
    Write-Warn "Skipped (--SkipCode)"
}

# ─── STEP 9: Post-deployment verification ────────────────────────────────────

Write-Step 9 "Post-deployment verification"

if (-not $functionAppName) {
    $functionAppName = az functionapp list `
        --resource-group $ResourceGroupName `
        --query "[0].name" --output tsv 2>$null
}

# Function app health
$appInfo = az functionapp show `
    --resource-group $ResourceGroupName `
    --name $functionAppName `
    --query "{state:state, identity:identity.type, httpsOnly:httpsOnly, outboundIps:outboundIpAddresses}" `
    --output json 2>$null | ConvertFrom-Json

Write-Host ""
Write-Host "  Function app state    : $($appInfo.state)"
Write-Host "  Managed identity      : $($appInfo.identity)"
Write-Host "  HTTPS only            : $($appInfo.httpsOnly)"

if ($appInfo.state -eq 'Running') {
    Write-Ok "Function app is Running"
}
else {
    Write-Warn "State is '$($appInfo.state)' — check the portal for startup errors"
}

if ($appInfo.identity -eq 'SystemAssigned') {
    Write-Ok "System-assigned managed identity is enabled"
}
else {
    Write-Err "Managed identity type is '$($appInfo.identity)' — RBAC will not work"
}

if ($appInfo.httpsOnly) {
    Write-Ok "HTTPS-only is enforced"
}
else {
    Write-Warn "HTTPS-only is NOT enforced — update site configuration"
}

# Registered functions
Write-Host ""
Write-Host "  Registered functions:" -ForegroundColor Gray
$functions = az functionapp function list `
    --resource-group $ResourceGroupName `
    --name $functionAppName `
    --query "[].{name:name,disabled:isDisabled}" `
    --output json 2>$null | ConvertFrom-Json

if ($functions -and $functions.Count -gt 0) {
    Write-Ok "$($functions.Count) function(s) registered"
    foreach ($fn in $functions) {
        $shortName = $fn.name.Split('/')[-1]
        $status = if ($fn.disabled) { 'DISABLED' } else { 'enabled' }
        Write-Host "    - $shortName [$status]" -ForegroundColor Gray
    }
}
else {
    Write-Warn "No functions visible yet — the host may still be warming up."
    Write-Host "    Retry in ~1 minute:" -ForegroundColor Gray
    Write-Host "    az functionapp function list --resource-group $ResourceGroupName --name $functionAppName" -ForegroundColor Gray
}

# ─── STEP 10: Next-steps checklist ───────────────────────────────────────────

Write-Step 10 "Post-deployment checklist (manual steps)"

Write-Host ""
Write-Host "  Complete these steps before the first data collection cycle:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [ ] 1. Upload the certificate to Key Vault (creates the 'regapp-certificate-hso-mpc-integration' secret):"
Write-Host "         .\scripts\Rotate-Certificate.ps1 -KeyVaultName <kv-name> -ClientId $AppClientId" -ForegroundColor Gray
Write-Host ""
Write-Host "  [ ] 2. Store tenant configuration in Key Vault (secret name: 'tenants-config'):"
Write-Host "         JSON format: [{""TenantId"":""<guid>"",""DisplayName"":""HSO Production"",""Enabled"":true,""MpnId"":""123456"",""CollectPartnerInsights"":true,""CollectPartnerSecurityScore"":true}]" -ForegroundColor Gray
Write-Host ""
Write-Host "  [ ] 3. Grant admin consent in each partner account:"
Write-Host "         .\scripts\Grant-AdminConsent.ps1 -TenantId <tenant-guid> -ClientId $AppClientId" -ForegroundColor Gray
Write-Host ""
Write-Host "  [ ] 4. Capture the Secure Application Model refresh token with MFA:"
Write-Host "         .\scripts\Initialize-SecureAppConsent.ps1 -KeyVaultName <kv-name> -ClientId $AppClientId -TenantId <tenant-guid>" -ForegroundColor Gray
Write-Host ""
Write-Host "  [ ] 5. Verify consent and token acquisition for all partner accounts:"
Write-Host "         .\scripts\Verify-TenantConsent.ps1 -KeyVaultName <kv-name> -ClientId $AppClientId" -ForegroundColor Gray
Write-Host ""
Write-Host "  [ ] 6. Configure local development against the main Key Vault (optional):"
Write-Host "         .\scripts\Initialize-LocalDevelopment.ps1 -Environment $Environment -AppClientId $AppClientId -ValidateKeyVaultAccess" -ForegroundColor Gray
Write-Host ""
Write-Host "  [ ] 7. Trigger the first collection cycle manually (optional — otherwise waits for the fixed 2-hour timer cycle):"
Write-Host "         `$manualKey = az functionapp function keys list --resource-group $ResourceGroupName --name $functionAppName --function-name ManualStart --query default --output tsv" -ForegroundColor Gray
Write-Host "         Invoke-RestMethod -Method Post -Uri `"https://$functionAppName.azurewebsites.net/api/collection/start?code=`$manualKey`"" -ForegroundColor Gray
Write-Host ""
Write-Host "  [ ] 8. Monitor the orchestration in Application Insights:"
Write-Host "         Azure Portal → Function App → Monitor → Live Metrics" -ForegroundColor Gray

# ─── Done ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Deployment complete.                                             ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""
