<#
.SYNOPSIS
    Configures local Azure Functions development to use the deployed Key Vault.

.DESCRIPTION
    Updates src/function-app/local.settings.json with the deployed Key Vault URI,
    storage account name, and app client ID. It can also update the Key Vault
    network configuration so local development can reach the main vault without
    VNet integration or private endpoint connectivity.

    No secret values are copied into local.settings.json. Local execution uses
    your Az PowerShell sign-in and Key Vault RBAC permissions.

.PARAMETER Environment
    Environment suffix used by the default resource group name. Default: prod.

.PARAMETER ResourceGroupName
    Resource group containing the deployed integration resources. Defaults to
    rg-hso-mpc-multitenant-integration-{Environment}.

.PARAMETER KeyVaultName
    Optional explicit Key Vault name. If omitted, the script discovers a single
    Key Vault in the resource group.

.PARAMETER StorageAccountName
    Optional explicit data storage account name. If omitted, the script discovers
    a single storage account in the resource group whose name starts with hsomnpc.

.PARAMETER AppClientId
    The multi-tenant app registration client ID. Defaults to APP_CLIENT_ID.

.PARAMETER KeyVaultNetworkMode
    DoNotChange: leave live Key Vault networking as-is.
    AllowPublicAuthenticated: enable public network access and allow all networks;
    RBAC still controls access. This matches the no-VNet Bicep default.
    AllowCurrentIpOnly: enable public network access, deny by default, and add the
    current public IP address. Use this only when the cloud Function App does not
    need to reach the vault, or after adding its outbound IPs too.

.PARAMETER GrantCurrentUserKeyVaultRbac
    Attempts to grant the signed-in user Key Vault Secrets User and Key Vault
    Certificate User on the vault. Requires Owner or User Access Administrator.

.PARAMETER ValidateKeyVaultAccess
    Checks that partner-config and regapp-certificate-hso-mpc-integration are visible through Key Vault
    metadata calls. Secret values are not printed.

.EXAMPLE
    .\scripts\Initialize-LocalDevelopment.ps1 -Environment prod -AppClientId $env:APP_CLIENT_ID

.EXAMPLE
    .\scripts\Initialize-LocalDevelopment.ps1 -KeyVaultName kv-main -StorageAccountName hsomnpcxxx -KeyVaultNetworkMode AllowCurrentIpOnly -ValidateKeyVaultAccess
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet('dev', 'prod')]
    [string]$Environment = 'prod',

    [string]$ResourceGroupName,

    [string]$KeyVaultName,

    [string]$StorageAccountName,

    [string]$AppClientId = $env:APP_CLIENT_ID,

    [ValidateSet('DoNotChange', 'AllowPublicAuthenticated', 'AllowCurrentIpOnly')]
    [string]$KeyVaultNetworkMode = 'AllowPublicAuthenticated',

    [switch]$GrantCurrentUserKeyVaultRbac,

    [switch]$ValidateKeyVaultAccess,

    [string]$LocalSettingsPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\function-app\local.settings.json')
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $ResourceGroupName) {
    $ResourceGroupName = "rg-hso-mpc-multitenant-integration-$Environment"
}

function Write-Ok {
    param([string]$Message)
    Write-Host "  [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "  [!] $Message" -ForegroundColor Yellow
}

function Get-CurrentPublicIpAddress {
    [CmdletBinding()]
    param()

    try {
        $response = Invoke-RestMethod -Uri 'https://api.ipify.org?format=json' -ErrorAction Stop
        if ($response.ip) { return [string]$response.ip }
    }
    catch {
        Write-Verbose "api.ipify.org lookup failed: $($_.Exception.Message)"
    }

    $plainResponse = Invoke-RestMethod -Uri 'https://ifconfig.me/ip' -ErrorAction Stop
    return ([string]$plainResponse).Trim()
}

function Resolve-SingleResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][array]$Resources,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$SelectorDescription
    )

    if ($Resources.Count -eq 1) { return $Resources[0] }
    if ($Resources.Count -eq 0) { throw "No $ResourceType found for $SelectorDescription." }

    $names = ($Resources | ForEach-Object { $_.Name ?? $_.StorageAccountName }) -join ', '
    throw "Multiple $ResourceType resources found for $SelectorDescription : $names. Pass the resource name explicitly."
}

function Set-LocalSettingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SettingsObject,
        [Parameter(Mandatory)][string]$Name,
        [AllowNull()][string]$Value
    )

    if ($null -eq $Value) { return }

    $property = $SettingsObject.Values.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
    }
    else {
        $SettingsObject.Values | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

Write-Host '=== HSO MPC Integration - Local Development Setup ===' -ForegroundColor Cyan
Write-Host "Resource group        : $ResourceGroupName"
Write-Host "Local settings path   : $LocalSettingsPath"
Write-Host "Key Vault network mode: $KeyVaultNetworkMode"
Write-Host ''

$context = Get-AzContext -ErrorAction SilentlyContinue
if (-not $context) {
    Write-Warn 'No Az context found. Opening Connect-AzAccount...'
    Connect-AzAccount -ErrorAction Stop | Out-Null
    $context = Get-AzContext -ErrorAction Stop
}

Write-Host "Azure account         : $($context.Account.Id)"
Write-Host "Azure subscription    : $($context.Subscription.Id)"
Write-Host ''

if ($KeyVaultName) {
    $vault = Get-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -ErrorAction Stop
}
else {
    $vaults = @(Get-AzKeyVault -ResourceGroupName $ResourceGroupName -ErrorAction Stop)
    $vault = Resolve-SingleResource -Resources $vaults -ResourceType 'Key Vault' -SelectorDescription "resource group '$ResourceGroupName'"
    $KeyVaultName = $vault.VaultName
}

if ($StorageAccountName) {
    $storage = Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Stop
}
else {
    $storageAccounts = @(Get-AzStorageAccount -ResourceGroupName $ResourceGroupName -ErrorAction Stop |
        Where-Object { $_.StorageAccountName -like 'hsomnpc*' })
    $storage = Resolve-SingleResource -Resources $storageAccounts -ResourceType 'data storage account' -SelectorDescription "resource group '$ResourceGroupName' and prefix 'hsomnpc'"
    $StorageAccountName = $storage.StorageAccountName
}

Write-Host "Resolved Key Vault    : $KeyVaultName"
Write-Host "Resolved Vault URI    : $($vault.VaultUri)"
Write-Host "Resolved storage      : $StorageAccountName"
Write-Host ''

switch ($KeyVaultNetworkMode) {
    'DoNotChange' {
        Write-Host 'Leaving Key Vault network rules unchanged.'
    }
    'AllowPublicAuthenticated' {
        if ($PSCmdlet.ShouldProcess($KeyVaultName, 'Enable public network access and allow authenticated clients from all networks')) {
            Update-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -PublicNetworkAccess Enabled | Out-Null
            Update-AzKeyVaultNetworkRuleSet -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -DefaultAction Allow -Bypass AzureServices | Out-Null
            Write-Ok 'Key Vault public network access enabled with defaultAction=Allow. RBAC still controls data access.'
        }
    }
    'AllowCurrentIpOnly' {
        $publicIp = Get-CurrentPublicIpAddress
        $ipRule = "$publicIp/32"
        if ($PSCmdlet.ShouldProcess($KeyVaultName, "Enable public network access and allow only current IP $ipRule")) {
            Update-AzKeyVault -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -PublicNetworkAccess Enabled | Out-Null
            Update-AzKeyVaultNetworkRuleSet -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -DefaultAction Deny -Bypass AzureServices | Out-Null
            Add-AzKeyVaultNetworkRule -VaultName $KeyVaultName -ResourceGroupName $ResourceGroupName -IpAddressRange $ipRule | Out-Null
            Write-Ok "Key Vault network rules restricted to current IP $ipRule."
            Write-Warn 'The Azure Function App also needs allowed outbound IPs if this mode is used after deployment.'
        }
    }
}

if ($GrantCurrentUserKeyVaultRbac) {
    foreach ($roleName in @('Key Vault Secrets User', 'Key Vault Certificate User')) {
        if ($PSCmdlet.ShouldProcess($KeyVaultName, "Grant $roleName to $($context.Account.Id)")) {
            try {
                New-AzRoleAssignment -SignInName $context.Account.Id -RoleDefinitionName $roleName -Scope $vault.ResourceId -ErrorAction Stop | Out-Null
                Write-Ok "Granted $roleName to $($context.Account.Id)."
            }
            catch {
                if ($_.Exception.Message -match 'already exists') {
                    Write-Ok "$roleName already assigned to $($context.Account.Id)."
                }
                else {
                    Write-Warn "Could not grant ${roleName}: $($_.Exception.Message)"
                }
            }
        }
    }
}

if (-not (Test-Path -Path $LocalSettingsPath)) {
    throw "local.settings.json not found at '$LocalSettingsPath'."
}

$settings = Get-Content -Path $LocalSettingsPath -Raw | ConvertFrom-Json
if (-not $settings.Values) {
    $settings | Add-Member -NotePropertyName Values -NotePropertyValue ([pscustomobject]@{})
}

Set-LocalSettingValue -SettingsObject $settings -Name 'KEY_VAULT_URI' -Value $vault.VaultUri
Set-LocalSettingValue -SettingsObject $settings -Name 'STORAGE_ACCOUNT_NAME' -Value $StorageAccountName
Set-LocalSettingValue -SettingsObject $settings -Name 'PARTNER_CONFIG_SECRET_NAME' -Value 'partner-config'
Set-LocalSettingValue -SettingsObject $settings -Name 'APP_CERTIFICATE_NAME' -Value 'regapp-certificate-hso-mpc-integration'
Set-LocalSettingValue -SettingsObject $settings -Name 'INSIGHTS_AUTH_MODE' -Value 'AppPlusUser'
if ($AppClientId) {
    Set-LocalSettingValue -SettingsObject $settings -Name 'APP_CLIENT_ID' -Value $AppClientId
}
else {
    Write-Warn 'APP_CLIENT_ID was not provided. local.settings.json keeps its existing APP_CLIENT_ID value.'
}

if ($PSCmdlet.ShouldProcess($LocalSettingsPath, 'Update local Function App settings')) {
    $settings | ConvertTo-Json -Depth 10 | Set-Content -Path $LocalSettingsPath -Encoding utf8
    Write-Ok 'local.settings.json updated for main Key Vault local development.'
}

if ($ValidateKeyVaultAccess) {
    Write-Host ''
    Write-Host 'Validating Key Vault metadata access...' -ForegroundColor Cyan
    Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name 'partner-config' -ErrorAction Stop | Out-Null
    Get-AzKeyVaultCertificate -VaultName $KeyVaultName -Name 'regapp-certificate-hso-mpc-integration' -ErrorAction Stop | Out-Null
    Write-Ok 'partner-config and regapp-certificate-hso-mpc-integration are reachable through Key Vault metadata calls.'
}

Write-Host ''
Write-Host 'Local development setup complete.' -ForegroundColor Cyan