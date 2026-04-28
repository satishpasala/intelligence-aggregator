// ============================================================
// modules/static-web-app.bicep
// ============================================================
// Provisions an Azure Static Web App for the Angular frontend.
//
// SKU: Free tier (no custom domain, 0.5 GB bandwidth/month free)
// The Angular app is deployed separately via the SWA CLI or
// GitHub Actions – this Bicep only creates the Azure resource.
//
// Default hostname is auto-assigned by Azure (*.azurestaticapps.net)
// ============================================================

param prefix   string
param location string
param tags     object

// Static Web Apps have limited region availability; 'centralus'
// and 'eastus2' are broadly available. Falls back to provided location.
var swaLocation = contains(['eastus2', 'centralus', 'westus2', 'westeurope', 'eastasia'], location)
  ? location
  : 'eastus2'

resource staticWebApp 'Microsoft.Web/staticSites@2023-12-01' = {
  name: '${prefix}-swa'
  location: swaLocation
  tags: tags
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    // Build configuration is handled at deploy time (SWA CLI / GitHub Actions).
    // Leave provider as 'None' so we can deploy manually or via CI.
    provider: 'None'
    enterpriseGradeCdnStatus: 'Disabled'
  }
}

// ── Outputs ─────────────────────────────────────────────────

@description('Default hostname of the Static Web App (no https:// prefix)')
output defaultHostname string = 'https://${staticWebApp.properties.defaultHostname}'

@description('Name of the Static Web App resource')
output staticWebAppName string = staticWebApp.name

@description('Resource ID of the Static Web App')
output staticWebAppId string = staticWebApp.id
