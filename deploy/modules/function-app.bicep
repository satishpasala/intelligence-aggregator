// ============================================================
// modules/function-app.bicep
// ============================================================
// Provisions:
//   - App Service Plan  (Linux Consumption Y1 – pay-per-execution)
//   - Azure Function App (.NET 8 isolated worker, system-assigned MI)
//
// This Function App hosts ALL application logic:
//   • HTTP-triggered API endpoints used by the Angular UI and Admin UI
//   • Timer-triggered background jobs (news, trends, daily briefing)
//
// Key Vault references are used for all secrets.
// KV access (Secrets User role) is granted in key-vault.bicep.
// CORS is configured to allow the Static Web App origin.
// ============================================================

param prefix                      string
param uniqueSuffix                string
param location                    string
param tags                        object
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

var functionAppName = '${prefix}-func-${uniqueSuffix}'
var planName        = '${prefix}-func-plan'

// ── Consumption App Service Plan ─────────────────────────────
// Y1 Consumption = pay only for executions (generous monthly free grant).
// Perfect for twice-daily timer triggers and low-traffic HTTP APIs.

resource functionPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true   // Required for Linux Consumption plan
  }
}

// Retrieve the storage account to build the AzureWebJobsStorage connection string.
resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${storageAccount.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

// Build CORS allowed origins – always include the SWA hostname when provided.
var corsOrigins = staticWebAppHostname != ''
  ? [ staticWebAppHostname, 'https://portal.azure.com' ]
  : [ 'https://portal.azure.com' ]

// ── Function App ─────────────────────────────────────────────
// Hosts:
//   HTTP APIs : /api/briefings/*, /api/trends/*, /api/news/*, /api/admin/*
//   Timers    : NewsAggregationFunction, TrendAggregationFunction,
//               DailyBriefingFunction

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'   // Managed identity – no stored credentials
  }
  properties: {
    serverFarmId: functionPlan.id
    httpsOnly: true          // Redirect all HTTP → HTTPS
    siteConfig: {
      linuxFxVersion: 'DOTNET-ISOLATED|8.0'   // .NET 8 isolated worker
      minTlsVersion: '1.2'
      http20Enabled: true
      cors: {
        // Allow the Angular Static Web App to call these HTTP endpoints.
        // Add additional origins here if you add a custom domain later.
        allowedOrigins: corsOrigins
        supportCredentials: false
      }
      appSettings: [
        // ── Functions runtime ────────────────────────────────
        {
          name: 'FUNCTIONS_EXTENSION_VERSION'
          value: '~4'
        }
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'dotnet-isolated'
        }
        {
          // Storage account used by the Functions host (triggers, leases, state)
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }

        // ── Application Insights ─────────────────────────────
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsightsConnectionString
        }
        {
          name: 'ApplicationInsightsAgent_EXTENSION_VERSION'
          value: '~3'
        }

        // ── ASP.NET Core environment ─────────────────────────
        {
          // Controls ASP.NET Core middleware behaviour inside isolated worker
          name: 'ASPNETCORE_ENVIRONMENT'
          value: environment
        }

        // ── Key Vault ────────────────────────────────────────
        {
          name: 'KeyVault__VaultUri'
          value: keyVaultUri
        }

        // ── Secrets (Key Vault references) ───────────────────
        // The managed identity resolves these at runtime.
        // Values are placeholders until KV is provisioned (Phase 3).
        {
          name: 'ConnectionStrings__DefaultConnection'
          value: sqlConnectionStringSecretUri != ''
            ? '@Microsoft.KeyVault(SecretUri=${sqlConnectionStringSecretUri})'
            : 'PLACEHOLDER_SET_AFTER_DEPLOY'
        }
        {
          name: 'OpenAI__ApiKey'
          value: openAiApiKeySecretUri != ''
            ? '@Microsoft.KeyVault(SecretUri=${openAiApiKeySecretUri})'
            : 'PLACEHOLDER_SET_AFTER_DEPLOY'
        }

        // ── OpenAI ───────────────────────────────────────────
        {
          name: 'OpenAI__Model'
          value: openAiModel
        }

        // ── Aggregation timer schedules (NCRONTAB, UTC) ──────
        // Format: {second} {minute} {hour} {day} {month} {day-of-week}
        {
          // NewsAggregationFunction: 06:00 and 18:00 UTC daily
          name: 'Aggregation__NewsSchedule'
          value: newsSchedule
        }
        {
          // TrendAggregationFunction: 06:15 and 18:15 UTC daily
          name: 'Aggregation__TrendSchedule'
          value: trendSchedule
        }
        {
          // DailyBriefingFunction: 06:30 and 18:30 UTC daily
          name: 'Aggregation__BriefingSchedule'
          value: briefingSchedule
        }

        // ── Application tuning ───────────────────────────────
        {
          name: 'Aggregation__MaxArticlesPerRun'
          value: string(maxArticlesPerRun)
        }
        {
          name: 'AppSettings__MaxArticlesPerRun'
          value: string(maxArticlesPerRun)
        }
        {
          name: 'AppSettings__MaxAiCallsPerDay'
          value: string(maxAiCallsPerDay)
        }
        {
          name: 'AppSettings__EnableAiSummaries'
          value: string(enableAiSummaries)
        }
      ]
    }
  }
}

// ── Outputs ─────────────────────────────────────────────────

@description('System-assigned managed identity principal ID')
output principalId string = functionApp.identity.principalId

@description('Name of the Function App')
output functionAppName string = functionApp.name

@description('Default HTTPS hostname of the Function App')
output defaultHostname string = 'https://${functionApp.properties.defaultHostName}'
