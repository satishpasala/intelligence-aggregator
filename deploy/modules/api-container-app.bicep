// ============================================================
// modules/api-container-app.bicep
// ============================================================
// Provisions a Container App (Consumption, scale-to-zero) that
// hosts the IntelligenceAggregator.Api ASP.NET Core 9 project.
//
// Cost: $0 — shares the same free Consumption grant as the
// Functions Container App.  Scale-to-zero means zero idle cost.
//
// INITIAL IMAGE:
//   First deploy uses a public Microsoft sample image so the
//   Container App is healthy before your code is pushed.
//   Replace it after you push to GHCR:
//     az containerapp update \
//       --name <appName> --resource-group <rg> \
//       --image ghcr.io/<user>/intelligence-aggregator-api:latest
//
// TLS is terminated by the Container App ingress; the app itself
// listens on HTTP port 8080.  Do NOT use UseHttpsRedirection()
// inside the container.
// ============================================================

param prefix       string
param uniqueSuffix string
param location     string
param tags         object
param environment  string

param containerAppsEnvId          string
param appInsightsConnectionString string
param staticWebAppHostname        string = ''

param keyVaultUri                  string = ''
param sqlConnectionStringSecretUri string = ''
param openAiApiKeySecretUri        string = ''

param openAiModel       string = 'gpt-4o-mini'
param maxAiCallsPerDay  int    = 50
param enableAiSummaries bool   = true

@description('GitHub username used to pull the custom image from GHCR (ghcr.io/<user>/...)')
param ghcrUsername string = ''

@description('GitHub PAT with read:packages scope for pulling private GHCR images')
@secure()
param ghcrPat string = ''

var apiAppName = '${take(prefix, 20)}-api-${uniqueSuffix}'
var useGhcr    = ghcrUsername != '' && ghcrPat != ''

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

// ── Key Vault secret references ───────────────────────────────

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
  { name: 'ASPNETCORE_ENVIRONMENT',                     value: environment }
  { name: 'ASPNETCORE_HTTP_PORTS',                      value: '8080' }
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING',      value: appInsightsConnectionString }
  { name: 'ApplicationInsightsAgent_EXTENSION_VERSION', value: '~3' }
  { name: 'KeyVault__VaultUri',                         value: keyVaultUri }
  { name: 'OpenAI__Model',                              value: openAiModel }
  { name: 'AppSettings__MaxAiCallsPerDay',              value: string(maxAiCallsPerDay) }
  { name: 'AppSettings__EnableAiSummaries',             value: string(enableAiSummaries) }
]

// ── Container App ─────────────────────────────────────────────

resource apiApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: apiAppName
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
        targetPort: 8080
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
          name: 'api'
          // Public placeholder – replaced by ghcr.io/<user>/intelligence-aggregator-api:latest
          // after your first docker push.
          image: useGhcr
            ? 'ghcr.io/${ghcrUsername}/intelligence-aggregator-api:latest'
            : 'mcr.microsoft.com/dotnet/samples:aspnetapp'
          resources: {
            cpu: json('0.25')
            memory: '0.5Gi'
          }
          env: concat(baseEnvVars, secretEnvVars)
        }
      ]
      scale: {
        minReplicas: 0    // Scale to zero when idle – no idle cost
        maxReplicas: 5
      }
    }
  }
}

// ── Outputs ──────────────────────────────────────────────────

@description('System-assigned managed identity principal ID')
output principalId string = apiApp.identity.principalId

@description('Container App name')
output apiAppName string = apiApp.name

@description('Default HTTPS URL of the API')
output defaultHostname string = 'https://${apiApp.properties.configuration.ingress.fqdn}'
