// ============================================================================
// RBAC module - role assignments for the Function App managed identity
// ============================================================================

param keyVaultName string
param storageAccountName string
param principalId string

// --- Existing resources ---
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// --- Function App MI: Key Vault Secrets User ---
resource kvSecretsRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, 'kv-secrets-user', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Function App MI: Key Vault Certificate User ---
resource kvCertRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, 'kv-certificate-user', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'db79e9a7-68ee-4b58-9aeb-b90e7c24fcba'
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Function App MI: Storage Blob Data Contributor on data storage ---
resource blobContributorRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, 'storage-blob-data-contributor', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

// --- Function App MI: Monitoring Metrics Publisher on the resource group ---
resource metricsPublisherRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, 'monitoring-metrics-publisher', 'function-app-mi')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '3913510d-42f4-4e42-8a64-420c390055eb'
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
