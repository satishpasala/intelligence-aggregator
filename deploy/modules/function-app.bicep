// ============================================================
// modules/function-app.bicep
// ============================================================
// Provisions a Container App (Consumption, scale-to-zero) that
// hosts the Azure Functions .NET 9 isolated worker.
//
// WHY CONTAINER APPS:
//   The Y1 Consumption and FC1 Flex Consumption App Service plans
//   require "Dynamic VMs" quota and feature flags that are blocked
//   on some PAYG subscriptions. Container Apps uses a completely
//   separate compute quota (Microsoft.App) and has a generous
//   free grant (180k vCore-s + 360k GB-s/month) at $0.
//
// INITIAL IMAGE:
//   On first deploy the container runs the base Functions runtime
//   image (no code). Deploy your function code after pushing
//   the custom image to GHCR, then run:
//     az containerapp update \
//       --name <functionAppName> --resource-group <rg> \
//       --image ghcr.io/<user>/intelligence-aggregator-functions:latest
//
// The Container Apps Environment is provisioned in container-apps-env.bicep
// and its resource ID is passed in via containerAppsEnvId.
// Key Vault access (Secrets User role) is granted in key-vault.bicep.
// ============================================================

param prefix                      string
param uniqueSuffix                string
param location                    string
param tags                        object
param containerAppsEnvId          string
param storageAccountName          string
param appInsightsConnectionString string
param environment                 string
param openAiModel                 string
param newsSchedule                string
param trendSchedule               string
param briefingSchedule            string
param maxArticlesPerRun           int
param maxAiCallsPerDay            int
param enableAiSummaries           bool   = true

@description('Default hostname of the Static Web App (with https://) used for CORS')
param staticWebAppHostname string = ''

param sqlConnectionStringSecretUri string = ''
param openAiApiKeySecretUri        string = ''
param keyVaultUri                  string = ''

@description('GitHub username used to pull the custom image from GHCR (ghcr.io/<user>/...)')
param ghcrUsername string = ''

@description('GitHub PAT with read:packages scope for pulling private GHCR images')
@secure()
param ghcrPat string = ''

// Container Apps name limit is 32 chars.
var functionAppName = '${take(prefix, 20)}-fn-${uniqueSuffix}'
var useGhcr         = ghcrUsername != '' && ghcrPat != ''

// ── Storage connection string ─────────────────────────────────

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${az.environment().suffixes.storage}'

// ── CORS origins ─────────────────────────────────────────────

var corsOrigins = staticWebAppHostname != ''
  ? [ staticWebAppHostname, 'https://portal.azure.com' ]
  : [ 'https://portal.azure.com' ]

// ── Registry (GHCR) ──────────────────────────────────────────

var registries = useGhcr ? [
  {
    server: 'ghcr.io'
    username: ghcrUsername
    passwordSecretRef: 'ghcr-pat'
  }
] : []

// ── Key Vault secret references (Phase 4 only) ───────────────
// When KV URIs are provided the Container App pulls secret values
// using the system-assigned managed identity at container startup.
// Phase 2 uses placeholder strings; Phase 4 uses proper KV refs.

var useKvSecrets = sqlConnectionStringSecretUri != ''

var kvSecrets = useKvSecrets ? [
  {
    name: 'sql-connection-string'
    keyVaultUrl: sqlConnectionStringSecretUri
    identity: 'system'
  }
  {
    name: 'openai-api-key'
    keyVaultUrl: openAiApiKeySecretUri
    identity: 'system'
  }
] : []

var secretEnvVars = useKvSecrets ? [
  { name: 'ConnectionStrings__DefaultConnection', secretRef: 'sql-connection-string' }
  { name: 'OpenAI__ApiKey',                       secretRef: 'openai-api-key' }
] : [
  { name: 'ConnectionStrings__DefaultConnection', value: 'PLACEHOLDER_SET_AFTER_DEPLOY' }
  { name: 'OpenAI__ApiKey',                       value: 'PLACEHOLDER_SET_AFTER_DEPLOY' }
]

// ── Secrets array: GHCR PAT + KV refs ────────────────────────

var ghcrSecrets = useGhcr ? [{ name: 'ghcr-pat', value: ghcrPat }] : []
var allSecrets  = concat(ghcrSecrets, kvSecrets)

// ── Base environment variables ────────────────────────────────

var baseEnvVars = [
  { name: 'AzureWebJobsStorage',                        value: storageConnectionString }
  { name: 'FUNCTIONS_EXTENSION_VERSION',                value: '~4' }
  { name: 'FUNCTIONS_WORKER_RUNTIME',                   value: 'dotnet-isolated' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',      value: appInsightsConnectionString }
  { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
  { name: 'ASPNETCORE_ENVIRONMENT',                     value: environment }
  { name: 'KeyVault__VaultUri',                         value: keyVaultUri }
  { name: 'OpenAI__Model',                              value: openAiModel }
  { name: 'Aggregation__NewsSchedule',                  value: newsSchedule }
  { name: 'Aggregation__TrendSchedule',                 value: trendSchedule }
  { name: 'Aggregation__BriefingSchedule',              value: briefingSchedule }
  { name: 'Aggregation__MaxArticlesPerRun',             value: string(maxArticlesPerRun) }
  { name: 'AppSettings__MaxArticlesPerRun',             value: string(maxArticlesPerRun) }
  { name: 'AppSettings__MaxAiCallsPerDay',              value: string(maxAiCallsPerDay) }
  { name: 'AppSettings__EnableAiSummaries',             value: string(enableAiSummaries) }
]

// ── Container App ─────────────────────────────────────────────
// Hosts the Azure Functions runtime (.NET 9 isolated worker).
// Scale-to-zero keeps cost at $0 during idle periods.

resource functionApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: functionAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    environmentId: containerAppsEnvId
    workloadProfileName: 'Consumption'
    configuration: {
      secrets: allSecrets
      registries: registries
      ingress: {
        external: true
        targetPort: 80
        corsPolicy: {
          allowedOrigins: corsOrigins
          allowedMethods: [ 'GET', 'POST', 'PUT', 'DELETE', 'OPTIONS', 'PATCH' ]
          allowedHeaders: [ '*' ]
          allowCredentials: false
        }
      }
    }
    template: {
      containers: [
        {
          name: 'functions'
          // Public placeholder – replaced by ghcr.io/<user>/intelligence-aggregator-functions:latest
          // after your first docker push.
          image: useGhcr
            ? 'ghcr.io/${ghcrUsername}/intelligence-aggregator-functions:latest'
            : 'mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated9.0'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: concat(baseEnvVars, secretEnvVars)
        }
      ]
      scale: {
        minReplicas: 0    // Scale to zero when idle – no idle cost
        maxReplicas: 10
      }
    }
  }
}

// ── Outputs ─────────────────────────────────────────────────

@description('System-assigned managed identity principal ID')
output principalId string = functionApp.identity.principalId

@description('Name of the Container App (Function App)')
output functionAppName string = functionApp.name

@description('Default HTTPS hostname of the Container App')
output defaultHostname string = 'https://${functionApp.properties.configuration.ingress.fqdn}'
