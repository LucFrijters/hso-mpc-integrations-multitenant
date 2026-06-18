// ============================================================================
// HSO MPC Integration — Main Bicep template
// Deploys all infrastructure for the multi-tenant Partner Center integration.
// ============================================================================

targetScope = 'resourceGroup'

// --- Parameters ---
@description('Environment name (dev, staging, prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('Base name for resources')
param baseName string = 'hso-mpc-multitenant-integration'

@description('The multi-tenant app registration client ID')
@secure()
param appClientId string

@description('PowerShell worker version (7.6 = preview/Windows-only/.NET 10; 7.4 = GA until 2026-11-10). Pin per environment via the .bicepparam files.')
@allowed(['7.6', '7.4'])
param powerShellVersion string = '7.6'

@description('Email address used by Azure Monitor action group notifications.')
param alertEmailAddress string = 'integration-alerts@hso.com'

@description('Tags applied to all resources')
param tags object = {
  project: 'hso-mpc-multitenant-integration'
  environment: environment
  managedBy: 'bicep'
}

// --- Variables ---
var suffix = '${baseName}-${environment}'
var uniqueSuffix = uniqueString(resourceGroup().id, baseName, environment)

// Resource names (computed once so they are compile-time constants and can be
// used for RBAC scoping via 'existing' references).
var storageAccountName = take('hsomnpc${uniqueSuffix}', 24)
var keyVaultName = take('kv-${replace(suffix, '-', '')}${uniqueSuffix}', 24)

// --- Modules ---

module storage 'modules/storage.bicep' = {
  name: 'storage-${uniqueSuffix}'
  params: {
    location: location
    storageAccountName: storageAccountName
    tags: tags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyvault-${uniqueSuffix}'
  params: {
    location: location
    keyVaultName: keyVaultName
    tags: tags
    logAnalyticsWorkspaceId: monitoring.outputs.logAnalyticsWorkspaceId
  }
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'monitoring-${uniqueSuffix}'
  params: {
    location: location
    suffix: suffix
    tags: tags
    alertEmailAddress: alertEmailAddress
  }
}

module functionApp 'modules/function-app.bicep' = {
  name: 'function-app-${uniqueSuffix}'
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

// --- RBAC Assignments ---
// Reference deployed resources via 'existing' so role assignments can be
// scoped correctly and use compile-time deterministic GUIDs.

resource kvExisting 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
  dependsOn: [keyVault]
}

resource storageExisting 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
  dependsOn: [storage]
}

// Function App MI → Key Vault Secrets User
resource kvSecretsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kvExisting
  name: guid(kvExisting.id, 'kv-secrets-user', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    ) // Key Vault Secrets User
    principalId: functionApp.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function App MI → Key Vault Certificate User
resource kvCertRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kvExisting
  name: guid(kvExisting.id, 'kv-certificate-user', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
    ) // Key Vault Certificate User
    principalId: functionApp.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function App MI → Storage Blob Data Contributor (on data storage)
resource blobContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageExisting
  name: guid(storageExisting.id, 'storage-blob-data-contributor', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    ) // Storage Blob Data Contributor
    principalId: functionApp.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// Function App MI → Monitoring Metrics Publisher (App Insights ingestion)
resource metricsPublisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: resourceGroup()
  name: guid(resourceGroup().id, 'monitoring-metrics-publisher', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '3913510d-42f4-4e42-8a64-420c390055eb'
    ) // Monitoring Metrics Publisher
    principalId: functionApp.outputs.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Outputs ---
output functionAppName string = functionApp.outputs.functionAppName
output functionAppPrincipalId string = functionApp.outputs.principalId
output storageAccountName string = storage.outputs.storageAccountName
output keyVaultName string = keyVault.outputs.keyVaultName
output appInsightsName string = monitoring.outputs.appInsightsName
