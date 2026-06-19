// ============================================================================
// Key Vault module — existing Key Vault diagnostic settings
// ============================================================================

param keyVaultName string
param logAnalyticsWorkspaceId string

var kvName = keyVaultName

// --- Existing Key Vault ---
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: kvName
}

// --- Diagnostic Settings ---
resource kvDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${kvName}'
  scope: keyVault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'audit'
        enabled: true
      }
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

// --- Outputs ---
output keyVaultName string = keyVault.name
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri
