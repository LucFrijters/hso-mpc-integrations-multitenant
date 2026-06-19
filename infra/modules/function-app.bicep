// ============================================================================
// Function App module — Azure Functions (PowerShell 7.6, Windows) with Durable Functions
// ============================================================================

param location string
//param suffix string
//param uniqueSuffix string
param tags object

@secure()
param appClientId string
param keyVaultUri string
param storageAccountName string
param appInsightsConnectionString string

@description('PowerShell worker version. 7.6 (preview, Windows-only, .NET 10) is the forward version; 7.4 is GA until 2026-11-10. NOTE: 7.6 is not available on Linux Consumption / Flex Consumption — this app must run on a Windows plan.')
@allowed(['7.6', '7.4'])
param powerShellVersion string = '7.6'

var funcAppName = 'func-hso-mpc-integration-prd-westeu'
var planName = 'asp-hso-mpc-integration-prd-westeu'
// Durable Functions needs its own storage for state
var funcStorageName = 'sthsompcintegrationfunc'

// --- Function App Storage (for Durable Functions runtime) ---
// Note: identity-based connection used (AzureWebJobsStorage__accountName).
// The function app's MI must have Storage Blob Data Owner + Storage Queue Data Contributor
// + Storage Table Data Contributor roles on this account (assigned in main.bicep).
resource funcStorage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: funcStorageName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true // Required during initial provisioning; can be tightened post-deploy
  }
}

// --- App Service Plan (Elastic Premium EP1) ---
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'elastic'
  sku: {
    name: 'EP1'
    tier: 'ElasticPremium'
    family: 'EP'
  }
  properties: {
    maximumElasticWorkerCount: 5
    reserved: false // Windows plan (reserved=false). Required: PowerShell 7.6 is Windows-only.
  }
}

// --- Function App ---
resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: funcAppName
  location: location
  tags: tags
  kind: 'functionapp'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      powerShellVersion: powerShellVersion
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      http20Enabled: true
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};EndpointSuffix=${az.environment().suffixes.storage};AccountKey=${funcStorage.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING'
          value: 'DefaultEndpointsProtocol=https;AccountName=${funcStorage.name};EndpointSuffix=${az.environment().suffixes.storage};AccountKey=${funcStorage.listKeys().keys[0].value}'
        }
        {
          name: 'WEBSITE_CONTENTSHARE'
          value: toLower(funcAppName)
        }
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'powershell'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME_VERSION'
          value: powerShellVersion
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_AUTHENTICATION_STRING'
          value: 'Authorization=AAD'
        }
        {
          name: 'KEY_VAULT_URI'
          value: keyVaultUri
        }
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: storageAccountName
        }
        {
          name: 'STORAGE_CONTAINER_NAME'
          value: 'mpc-insights-data-raw'
        }
        {
          name: 'TENANTS_CONFIG_SECRET_NAME'
          value: 'tenants-config'
        }
        {
          name: 'APP_CERTIFICATE_NAME'
          value: 'regapp-certificate-hso-mpc-integration'
        }
        {
          name: 'APP_CLIENT_ID'
          value: appClientId
        }
        {
          name: 'INSIGHTS_REPORT_PREFIX'
          value: 'hso-auto-'
        }
        {
          name: 'INSIGHTS_REPORT_FORMAT'
          value: 'CSV'
        }
        {
          name: 'INSIGHTS_MAX_ROWS_PER_REPORT'
          value: '1000000'
        }
        {
          name: 'MAX_CONCURRENT_PARTNERS'
          value: '4'
        }
        {
          name: 'MAX_CONCURRENT_ENDPOINTS'
          value: '5'
        }
        {
          name: 'COLLECTION_TIMEOUT_MINUTES'
          value: '25'
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
      ]
    }
  }
}

// --- RBAC: Durable Functions state storage ---
// Durable Functions requires the MI to have Blob + Queue + Table contributor roles
// on the function runtime storage account for orchestration state management.

resource funcStorageBlobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, 'storage-blob-data-contributor', 'durable-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    ) // Storage Blob Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageQueueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, 'storage-queue-data-contributor', 'durable-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
    ) // Storage Queue Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageTableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: funcStorage
  name: guid(funcStorage.id, 'storage-table-data-contributor', 'durable-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
    ) // Storage Table Data Contributor
    principalId: functionApp.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Outputs ---
output functionAppName string = functionApp.name
output functionAppId string = functionApp.id
output principalId string = functionApp.identity.principalId
