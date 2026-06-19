// ============================================================================
// Monitoring module — Application Insights, Log Analytics, Alert Rules
// ============================================================================

param location string
param suffix string
param tags object
param alertEmailAddress string

var lawName = 'law-hso-mpc-integration-prd-westeu'
var aiName = 'ai-func-hso-mpc-integration-prd-westeu'

// --- Log Analytics Workspace ---
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 90
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
  }
}

// --- Application Insights ---
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalytics.id
    IngestionMode: 'LogAnalytics'
    DisableLocalAuth: true // Enforce AAD auth for ingestion
  }
}

// --- Action Group ---
resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-hso-mpc-integration-prd-westeu'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'HsoMpcInt'
    enabled: true
    emailReceivers: [
      {
        name: 'IntegrationTeam'
        emailAddress: alertEmailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

// --- Alert: Collection cycle missed ---
resource missedCycleAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-missed-cycle-${suffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'MPC Integration - Collection Cycle Missed'
    description: 'No orchestration completion event detected in 2 hours'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT30M'
    windowSize: 'PT2H'
    scopes: [appInsights.id]
    criteria: {
      allOf: [
        {
          // Count completion events in the window. If < 1 → no cycle ran → alert.
          query: '''
            traces
            | where message has "OrchestrateAllTenants completed"
          '''
          timeAggregation: 'Count'
          operator: 'LessThan'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// --- Alert: Partner account collection failure ---
resource partnerFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-partner-failure-${suffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'MPC Integration - Partner Account Collection Failed'
    description: 'One or more partner accounts failed data collection'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [appInsights.id]
    criteria: {
      allOf: [
        {
          query: '''
            traces
            | where message has "OrchestrateTenant completed: Failed"
            | summarize FailCount = count() by bin(timestamp, 1h)
            | where FailCount > 0
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// --- Alert: High throttling ---
resource throttlingAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-throttling-${suffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'MPC Integration - High API Throttling'
    description: 'More than 50 HTTP 429 responses in a single cycle'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [appInsights.id]
    criteria: {
      allOf: [
        {
          query: '''
            traces
            | where message has "429 Throttled"
            | summarize ThrottleCount = count() by bin(timestamp, 1h)
            | where ThrottleCount > 50
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// --- Alert: Auth failure ---
resource authFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = {
  name: 'alert-auth-failure-${suffix}'
  location: location
  tags: tags
  properties: {
    displayName: 'MPC Integration - Authentication Failure'
    description: 'Token acquisition failed for one or more partner accounts'
    severity: 1
    enabled: true
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    scopes: [appInsights.id]
    criteria: {
      allOf: [
        {
          query: '''
            traces
            | where message has "AcquireToken: FAILED"
            | summarize FailCount = count() by bin(timestamp, 1h)
            | where FailCount > 0
          '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [actionGroup.id]
    }
  }
}

// --- Outputs ---
output appInsightsName string = appInsights.name
output appInsightsConnectionString string = appInsights.properties.ConnectionString
output logAnalyticsWorkspaceId string = logAnalytics.id
output actionGroupId string = actionGroup.id
