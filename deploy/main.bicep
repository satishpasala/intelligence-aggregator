// ============================================================
// main.bicep - Intelligence Aggregator Infrastructure
// ============================================================
// Orchestrates all modules for the News + Trend Aggregator app.
// Assumes the subscription and resource group already exist.
//
// Architecture (zero-cost design):
//   - Azure Static Web App     → Angular public UI  ($0 Free tier)
//   - Container App (API)      → .NET 9 Web API     ($0 Consumption)
//   - Container App (Functions)→ Timer-triggered jobs($0 Consumption)
//   - Container Apps Env       → Shared environment  ($0 Consumption)
//   - Azure SQL Database       → Application data    ($0 free limit)
//   - Azure Key Vault          → Secrets management  (~$0)
//   - Application Insights     → APM telemetry       ($0 ≤5 GB/mo)
//   - Azure Storage Account    → Functions host storage (~$1/mo)
//
// Container images are pulled from GitHub Container Registry (GHCR)
// which is free – no Azure Container Registry needed.
//
// Deploy with:
//   az deployment group create \
//     --resource-group <YOUR_RG> \
//     --template-file deploy/main.bicep \
//     --parameters deploy/parameters/dev.bicepparam \
//     --parameters ghcrPat=<your-github-pat>
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ──────────────────────────────────────────────

@description('Short environment tag (dev | staging | prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

@description('Primary Azure region for all resources')
param location string = resourceGroup().location

@description('Region for the Azure SQL Server.')
param sqlLocation string = 'centralus'

@description('Region for the Container Apps environment.')
param functionLocation string = 'centralus'

@description('Application name prefix used in resource naming')
param appName string = 'intelligence-aggregator'

@description('Random suffix appended to globally-unique resource names. Supply the same value on re-deployments to prevent drift.')
@maxLength(6)
param uniqueSuffix string = take(uniqueString(resourceGroup().id), 6)

@description('Azure AD Object ID of the DBA / deploying principal (for SQL AAD admin)')
param sqlAdminObjectId string

@description('SQL auth administrator login name')
param sqlAdminLogin string = 'sqladmin'

@description('Display name / UPN of the AAD user or group set as SQL Server AAD administrator.')
param sqlAadAdminLogin string

@description('SQL administrator password.')
@secure()
param sqlAdminPassword string

@description('OpenAI API key – set the real value after deployment via Key Vault.')
@secure()
param openAiApiKey string = 'PLACEHOLDER_SET_AFTER_DEPLOY'

@description('OpenAI model name, e.g. gpt-4o-mini')
param openAiModel string = 'gpt-4o-mini'

@description('Max news articles processed per aggregation run')
param maxArticlesPerRun int = 100

@description('Max AI calls permitted per day')
param maxAiCallsPerDay int = 50

@description('Enable AI-generated article summaries')
param enableAiSummaries bool = true

@description('NCRONTAB expression for news aggregation (UTC)')
param newsSchedule string = '0 0 6,18 * * *'

@description('NCRONTAB expression for trend aggregation (UTC)')
param trendSchedule string = '0 15 6,18 * * *'

@description('NCRONTAB expression for daily briefing generation (UTC)')
param briefingSchedule string = '0 30 6,18 * * *'

@description('GitHub username for pulling images from GHCR (ghcr.io/<user>/...). Leave empty to use public placeholder images on first deploy.')
param ghcrUsername string = ''

@description('GitHub Personal Access Token with read:packages scope for pulling private GHCR images. Pass at deploy time: --parameters ghcrPat=<token>')
@secure()
param ghcrPat string = ''


// ── Variables ───────────────────────────────────────────────

var prefix = '${appName}-${environment}'
var tags = {
  application: appName
  environment: environment
  managedBy: 'bicep'
}

// ── Phase 1: Foundation resources ───────────────────────────
// No inter-module dependencies – all deploy in parallel.

module monitoring './modules/monitoring.bicep' = {
  name: 'monitoring'
  params: {
    prefix: prefix
    location: location
    tags: tags
  }
}

module storage './modules/storage.bicep' = {
  name: 'storage'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: location
    tags: tags
  }
}

module sql './modules/sql.bicep' = {
  name: 'sql'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: sqlLocation
    tags: tags
    sqlAdminLogin: sqlAdminLogin
    sqlAdminPassword: sqlAdminPassword
    sqlAdminObjectId: sqlAdminObjectId
    sqlAadAdminLogin: sqlAadAdminLogin
  }
}

module staticWebApp './modules/static-web-app.bicep' = {
  name: 'staticWebApp'
  params: {
    prefix: prefix
    location: location
    tags: tags
  }
}

// Shared Container Apps environment (Consumption = $0)
module containerAppsEnv './modules/container-apps-env.bicep' = {
  name: 'containerAppsEnv'
  params: {
    prefix: prefix
    location: functionLocation
    tags: tags
  }
}

// ── Phase 2: Compute ─────────────────────────────────────────
// Both Container Apps share the environment from Phase 1.
// Deployed before Key Vault so their system-assigned managed
// identity principal IDs are available for KV role assignment.
// Secrets use placeholder values on this first pass; they are
// replaced with Key Vault references in Phase 4 below.

module apiApp './modules/api-container-app.bicep' = {
  name: 'apiApp'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: functionLocation
    tags: tags
    environment: environment
    containerAppsEnvId: containerAppsEnv.outputs.envId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    staticWebAppHostname: staticWebApp.outputs.defaultHostname
    openAiModel: openAiModel
    maxAiCallsPerDay: maxAiCallsPerDay
    enableAiSummaries: enableAiSummaries
    ghcrUsername: ghcrUsername
    ghcrPat: ghcrPat
    // Key Vault references are empty on first pass; set in Phase 4.
    keyVaultUri: ''
    sqlConnectionStringSecretUri: ''
    openAiApiKeySecretUri: ''
  }
}

module functionApp './modules/function-app.bicep' = {
  name: 'functionApp'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: functionLocation
    tags: tags
    environment: environment
    containerAppsEnvId: containerAppsEnv.outputs.envId
    storageAccountName: storage.outputs.storageAccountName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    staticWebAppHostname: staticWebApp.outputs.defaultHostname
    openAiModel: openAiModel
    newsSchedule: newsSchedule
    trendSchedule: trendSchedule
    briefingSchedule: briefingSchedule
    maxArticlesPerRun: maxArticlesPerRun
    maxAiCallsPerDay: maxAiCallsPerDay
    enableAiSummaries: enableAiSummaries
    ghcrUsername: ghcrUsername
    ghcrPat: ghcrPat
    // Key Vault references are empty on first pass; set in Phase 4.
    sqlConnectionStringSecretUri: ''
    openAiApiKeySecretUri: ''
    keyVaultUri: ''
  }
}

// ── Phase 3: Key Vault ───────────────────────────────────────
// Creates the vault, stores secrets, and grants Key Vault
// Secrets User role to both managed identities.

module keyVault './modules/key-vault.bicep' = {
  name: 'keyVault'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: location
    tags: tags
    sqlConnectionString: 'Server=tcp:${sql.outputs.sqlServerFqdn},1433;Initial Catalog=${sql.outputs.sqlDatabaseName};Authentication=Active Directory Default;'
    openAiApiKey: openAiApiKey
    functionAppPrincipalId: functionApp.outputs.principalId
    apiAppPrincipalId: apiApp.outputs.principalId
  }
}

// ── Phase 4: Wire Key Vault references into both Container Apps
// Re-deploys both apps with Key Vault secret URIs injected as
// secret references so the runtime resolves them at startup.

module apiAppConfig './modules/api-container-app.bicep' = {
  name: 'apiAppConfig'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: functionLocation
    tags: tags
    environment: environment
    containerAppsEnvId: containerAppsEnv.outputs.envId
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    staticWebAppHostname: staticWebApp.outputs.defaultHostname
    openAiModel: openAiModel
    maxAiCallsPerDay: maxAiCallsPerDay
    enableAiSummaries: enableAiSummaries
    ghcrUsername: ghcrUsername
    ghcrPat: ghcrPat
    keyVaultUri: keyVault.outputs.keyVaultUri
    sqlConnectionStringSecretUri: keyVault.outputs.sqlConnectionStringSecretUri
    openAiApiKeySecretUri: keyVault.outputs.openAiApiKeySecretUri
  }
  dependsOn: [ keyVault ]
}

module functionAppConfig './modules/function-app.bicep' = {
  name: 'functionAppConfig'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: functionLocation
    tags: tags
    environment: environment
    containerAppsEnvId: containerAppsEnv.outputs.envId
    storageAccountName: storage.outputs.storageAccountName
    appInsightsConnectionString: monitoring.outputs.appInsightsConnectionString
    staticWebAppHostname: staticWebApp.outputs.defaultHostname
    openAiModel: openAiModel
    newsSchedule: newsSchedule
    trendSchedule: trendSchedule
    briefingSchedule: briefingSchedule
    maxArticlesPerRun: maxArticlesPerRun
    maxAiCallsPerDay: maxAiCallsPerDay
    enableAiSummaries: enableAiSummaries
    ghcrUsername: ghcrUsername
    ghcrPat: ghcrPat
    sqlConnectionStringSecretUri: keyVault.outputs.sqlConnectionStringSecretUri
    openAiApiKeySecretUri: keyVault.outputs.openAiApiKeySecretUri
    keyVaultUri: keyVault.outputs.keyVaultUri
  }
  dependsOn: [ keyVault ]
}

// ── Outputs ─────────────────────────────────────────────────

@description('Default HTTPS URL of the Angular Static Web App')
output staticWebAppUrl string = staticWebApp.outputs.defaultHostname

@description('Default HTTPS URL of the .NET Web API (Container App)')
output apiUrl string = apiAppConfig.outputs.defaultHostname

@description('Container App name for the Web API')
output apiAppName string = apiAppConfig.outputs.apiAppName

@description('Default HTTPS URL of the Azure Function App')
output functionAppHostname string = functionAppConfig.outputs.defaultHostname

@description('Container App name for the Function App')
output functionAppName string = functionAppConfig.outputs.functionAppName

@description('Fully-qualified domain name of the SQL Server')
output sqlServerName string = sql.outputs.sqlServerFqdn

@description('Name of the Azure SQL Database')
output sqlDatabaseName string = sql.outputs.sqlDatabaseName

@description('URI of the Key Vault')
output keyVaultUri string = keyVault.outputs.keyVaultUri

@description('Application Insights connection string')
output appInsightsConnectionString string = monitoring.outputs.appInsightsConnectionString

@description('Name of the Storage Account used by the Function App')
output storageAccountName string = storage.outputs.storageAccountName
