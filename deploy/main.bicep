// ============================================================
// main.bicep - Intelligence Aggregator Infrastructure
// ============================================================
// Orchestrates all modules for the News + Trend Aggregator app.
// Assumes the subscription and resource group already exist.
//
// Architecture:
//   - Azure Static Web App  → Angular public UI + Admin UI
//   - Azure Function App    → HTTP API endpoints + timer jobs
//   - Azure SQL Database    → application data
//   - Azure Key Vault       → secrets management
//   - Application Insights  → monitoring and telemetry
//   - Azure Storage Account → required by Functions runtime
//
// Deploy with:
//   az deployment group create \
//     --resource-group <YOUR_RG> \
//     --template-file deploy/main.bicep \
//     --parameters deploy/parameters/dev.bicepparam
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ──────────────────────────────────────────────

@description('Short environment tag (dev | staging | prod)')
@allowed(['dev', 'staging', 'prod'])
param environment string = 'dev'

@description('Primary Azure region for all resources')
param location string = resourceGroup().location

@description('Application name prefix used in resource naming')
param appName string = 'intelligence-aggregator'

@description('Random suffix appended to globally-unique resource names. Supply the same value on re-deployments to prevent drift.')
@maxLength(6)
param uniqueSuffix string = take(uniqueString(resourceGroup().id), 6)

@description('Azure AD Object ID of the DBA / deploying principal (for SQL AAD admin)')
param sqlAdminObjectId string

@description('AAD login name used as SQL Server AAD administrator')
param sqlAdminLogin string = 'sqladmin'

@description('SQL administrator password. Store this in a secure location – never commit plaintext.')
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

@description('NCRONTAB expression for news aggregation (twice daily, UTC). Format: {sec} {min} {hr} * * *')
param newsSchedule string = '0 0 6,18 * * *'

@description('NCRONTAB expression for trend aggregation (twice daily, UTC). Format: {sec} {min} {hr} * * *')
param trendSchedule string = '0 15 6,18 * * *'

@description('NCRONTAB expression for daily briefing generation (runs after aggregation, UTC). Format: {sec} {min} {hr} * * *')
param briefingSchedule string = '0 30 6,18 * * *'

// ── Variables ───────────────────────────────────────────────

var prefix = '${appName}-${environment}'
var tags = {
  application: appName
  environment: environment
  managedBy: 'bicep'
}

// ── Phase 1: Foundation resources ───────────────────────────
// These have no inter-module dependencies and deploy in parallel.

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
    location: location
    tags: tags
    sqlAdminLogin: sqlAdminLogin
    sqlAdminPassword: sqlAdminPassword
    sqlAdminObjectId: sqlAdminObjectId
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

// ── Phase 2: Function App ────────────────────────────────────
// Deployed before Key Vault so that the system-assigned managed
// identity principal ID is available for KV role assignment.
// Secrets use placeholder values on this first pass; they are
// replaced with Key Vault references in Phase 4 below.

module functionApp './modules/function-app.bicep' = {
  name: 'functionApp'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: location
    tags: tags
    environment: environment
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
    // Key Vault references are empty on first pass; set in Phase 4.
    sqlConnectionStringSecretUri: ''
    openAiApiKeySecretUri: ''
    keyVaultUri: ''
  }
}

// ── Phase 3: Key Vault ───────────────────────────────────────
// Creates the vault, stores secrets, and grants Key Vault
// Secrets User role to the Function App managed identity.

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
  }
}

// ── Phase 4: Wire Key Vault references into Function App ─────
// Re-deploys the Function App with Key Vault secret URIs
// injected as Key Vault references in app settings so that the
// runtime resolves them using the managed identity.

module functionAppConfig './modules/function-app.bicep' = {
  name: 'functionAppConfig'
  params: {
    prefix: prefix
    uniqueSuffix: uniqueSuffix
    location: location
    tags: tags
    environment: environment
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
    sqlConnectionStringSecretUri: keyVault.outputs.sqlConnectionStringSecretUri
    openAiApiKeySecretUri: keyVault.outputs.openAiApiKeySecretUri
    keyVaultUri: keyVault.outputs.keyVaultUri
  }
  dependsOn: [
    keyVault
  ]
}

// ── Outputs ─────────────────────────────────────────────────

@description('Default HTTPS URL of the Angular Static Web App')
output staticWebAppUrl string = staticWebApp.outputs.defaultHostname

@description('Default HTTPS URL of the Azure Function App (API host)')
output functionAppHostname string = functionAppConfig.outputs.defaultHostname

@description('Name of the Azure Function App')
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
