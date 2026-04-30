// ============================================================
// modules/sql.bicep
// ============================================================
// Provisions:
//   - Azure SQL Server  (with AAD admin + SQL auth)
//   - Azure SQL Database (GeneralPurpose serverless, 1 vCore)
//
// Cost-saving choices:
//   - Serverless tier auto-pauses after 1 hour of inactivity
//   - Min capacity 0.5 vCores, max 1 vCore
//   - Auto-pause delay: 60 minutes
//
// No tables are created here; apply migrations from the app.
// ============================================================

param prefix           string
param uniqueSuffix     string
param location         string
param tags             object

@description('SQL login name for the SQL administrator account (used for SQL auth)')
param sqlAdminLogin string

@description('SQL administrator password')
@secure()
param sqlAdminPassword string

@description('AAD Object ID of the AAD SQL administrator principal')
param sqlAdminObjectId string

@description('Display name / UPN of the AAD SQL administrator. Must differ from sqlAdminLogin.')
param sqlAadAdminLogin string

var sqlServerName   = '${prefix}-sql-${uniqueSuffix}'
var sqlDatabaseName = 'intelligenceaggregator-db'

// ── SQL Server ───────────────────────────────────────────────

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: sqlServerName
  location: location
  tags: tags
  properties: {
    administratorLogin: sqlAdminLogin
    administratorLoginPassword: sqlAdminPassword
    minimalTlsVersion: '1.2'                   // Enforce TLS 1.2+
    publicNetworkAccess: 'Enabled'             // Required for dev; restrict in prod
    administrators: {
      administratorType: 'ActiveDirectory'
      login: sqlAadAdminLogin
      sid: sqlAdminObjectId
      tenantId: subscription().tenantId
      azureADOnlyAuthentication: false         // Allow both SQL + AAD auth in dev
    }
  }
}

// Allow Azure services to reach the SQL server (needed for App Service / Functions).
resource allowAzureServices 'Microsoft.Sql/servers/firewallRules@2023-08-01-preview' = {
  parent: sqlServer
  name: 'AllowAllWindowsAzureIps'
  properties: {
    startIpAddress: '0.0.0.0'
    endIpAddress: '0.0.0.0'
  }
}

// ── SQL Database ─────────────────────────────────────────────
// Free offer: 100,000 vCore-seconds/month + 32 GB storage at $0.
// One free database is allowed per subscription. If the free offer
// is already claimed, remove useFreeLimit and accept the serverless cost,
// or use a different subscription.
// Auto-pause after 1 h of inactivity; exhaustion pauses rather than bills.

resource sqlDatabase 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: sqlDatabaseName
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5'    // General Purpose Serverless Gen5
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: 1          // 1 vCore max
  }
  properties: {
    collation: 'SQL_Latin1_General_CP1_CI_AS'
    // maxSizeBytes must NOT be set when useFreeLimit + AutoPause are enabled;
    // the free offer only allows the default max size.
    autoPauseDelay: 60                         // Auto-pause after 60 min idle
    minCapacity: json('0.5')                   // Minimum 0.5 vCores when running
    requestedBackupStorageRedundancy: 'Local'  // Cheapest: locally-redundant backup
    zoneRedundant: false
    useFreeLimit: true                         // Azure SQL Database free offer ($0)
    freeLimitExhaustionBehavior: 'AutoPause'   // Pause instead of billing on overrun
  }
}

// ── Outputs ─────────────────────────────────────────────────

@description('Fully-qualified domain name of the SQL Server')
output sqlServerFqdn string = sqlServer.properties.fullyQualifiedDomainName

@description('Name of the SQL Server resource')
output sqlServerName string = sqlServer.name

@description('Name of the SQL Database')
output sqlDatabaseName string = sqlDatabase.name
