// ============================================================
// modules/monitoring.bicep
// ============================================================
// Provisions:
//   - Log Analytics Workspace  (PerGB2018, 30-day retention)
//   - Application Insights     (workspace-based, web type)
//
// Both resources are shared by the App Service and Function App.
// ============================================================

param prefix   string
param location string
param tags     object

// ── Log Analytics Workspace ──────────────────────────────────
// PerGB2018 SKU = pay-per-GB, cheapest operational tier.
// 30-day retention is the free default; increase if needed.

resource logAnalyticsWorkspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
    // Cap at 0.1 GB/day (~3 GB/month) to stay well inside the 5 GB/month
    // free allowance and prevent unexpected charges in dev.
    workspaceCapping: {
      dailyQuotaGb: json('0.1')
    }
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ── Application Insights ─────────────────────────────────────
// Workspace-based mode links AI to the Log Analytics workspace
// so all telemetry lands in a single queryable store.

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${prefix}-ai'
  location: location
  tags: tags
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logAnalyticsWorkspace.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// ── Outputs ─────────────────────────────────────────────────

@description('Resource ID of the Log Analytics Workspace')
output logAnalyticsWorkspaceId string = logAnalyticsWorkspace.id

@description('Instrumentation key (legacy – prefer connection string)')
output appInsightsInstrumentationKey string = appInsights.properties.InstrumentationKey

@description('Application Insights connection string (recommended)')
output appInsightsConnectionString string = appInsights.properties.ConnectionString
