// ============================================================================
// HSO MPC Integration — Main Bicep template
// Deploys all infrastructure for the multi-tenant Partner Center integration.
// ============================================================================

targetScope = 'subscription'
param rgName string = 'hso-mpc-multitenant-integration-prd-westeu'
param rgLocation string = 'westeurope'

// --- Parameters ---
@description('Environment name (dev, prd)')
@allowed(['dev', 'prd'])
param environment string = 'prd'

@description('Azure region for all resources')
param location string = rgLocation

@description('Base name for resources')
param baseName string = 'hso-mpc-integration'

@description('Name of the pre-created data storage account in this resource group')
param storageAccountName string = 'sthsompcintegrationprd'

@description('Name of the pre-created Key Vault in this resource group')
param keyVaultName string = 'kv-hso-mpc-integration'

@description('The multi-tenant app registration client ID')
param appClientId string = '05573d61-6ddf-403b-90c6-d8572e6c867f' // HSO MPC Multi-Tenant Integration

@description('PowerShell worker version (7.6 = preview/Windows-only/.NET 10; 7.4 = GA until 2026-11-10). Pin per environment via the .bicepparam files.')
@allowed(['7.6', '7.4'])
param powerShellVersion string = '7.6'

@description('Email address used by Azure Monitor action group notifications.')
param alertEmailAddress string = 'lfrijters@hso.com'

@description('Tags applied to all resources')
param tags object = {
  project: 'hso-mpc-integration'
  environment: environment
}

// --- Variables ---
var suffix = '${baseName}-${environment}-westeu'
var uniqueSuffix = uniqueString(rgName, baseName, environment)

// Existing deployment resource group.
resource targetResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' existing = {
  name: rgName
}

// --- Modules ---

module storage 'modules/storage.bicep' = {
  name: 'storage-${uniqueSuffix}'
  scope: targetResourceGroup
  params: {
    storageAccountName: storageAccountName
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-${uniqueSuffix}'
  scope: targetResourceGroup
  params: {
    keyVaultName: keyVaultName
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring-${uniqueSuffix}'
  scope: targetResourceGroup
  params: {
    location: location
    suffix: suffix
    tags: tags
    alertEmailAddress: alertEmailAddress
  }
}

module functionApp 'modules/function-app.bicep' = {
  name: 'function-app-${uniqueSuffix}'
  scope: targetResourceGroup
  params: {
    location: location
    suffix: suffix
    uniqueSuffix: uniqueSuffix
    tags: tags
    appClientId: appClientId
    keyVaultUri: keyVault.outputs.keyVaultUri
    storageAccountName: storage.outputs.storageAccountName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    powerShellVersion: powerShellVersion
  }
}

module rbac 'modules/rbac.bicep' = {
  name: 'rbac-${uniqueSuffix}'
  scope: targetResourceGroup
  params: {
    keyVaultName: keyVault.outputs.keyVaultName
    storageAccountName: storage.outputs.storageAccountName
    principalId: functionApp.outputs.principalId
  }
}

// --- Outputs ---
output resourceGroupId string = targetResourceGroup.id
output functionAppName string = functionApp.outputs.functionAppName
output functionAppPrincipalId string = functionApp.outputs.principalId
output storageAccountName string = storage.outputs.storageAccountName
output keyVaultName string = keyVault.outputs.keyVaultName
output appInsightsName string = monitoring.outputs.appInsightsName
