// ============================================================================
// Storage module — existing Storage Account, container, lifecycle policy
// ============================================================================

param storageAccountName string

var containerName = 'mpc-insights-data-raw'

// --- Existing Storage Account ---
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

// --- Blob Services config ---
resource blobServices 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    // isVersioningEnabled: true
  }
}

// --- Container ---
resource container 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobServices
  name: containerName
  properties: {
    publicAccess: 'None'
  }
}

// // --- Lifecycle Management Policy ---
// resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
//   parent: storageAccount
//   name: 'default'
//   properties: {
//     policy: {
//       rules: [
//         {
//           name: 'tier-to-cool-after-7-days'
//           enabled: true
//           type: 'Lifecycle'
//           definition: {
//             filters: {
//               blobTypes: ['blockBlob']
//               prefixMatch: ['${containerName}/']
//             }
//             actions: {
//               baseBlob: {
//                 tierToCool: { daysAfterModificationGreaterThan: 7 }
//                 tierToArchive: { daysAfterModificationGreaterThan: 90 }
//                 delete: { daysAfterModificationGreaterThan: 365 }
//               }
//               snapshot: {
//                 delete: { daysAfterCreationGreaterThan: 90 }
//               }
//             }
//           }
//         }
//       ]
//     }
//   }
// }

// --- Outputs ---
output storageAccountName string = storageAccount.name
output storageAccountId string = storageAccount.id
output containerName string = containerName
