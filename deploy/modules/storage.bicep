// ============================================================
// modules/storage.bicep
// ============================================================
// Provisions a Storage Account required by Azure Functions.
//
// SKU: Standard_LRS  – lowest-cost locally-redundant storage.
// Public blob write access is disabled; HTTPS only; TLS 1.2+.
// ============================================================

param prefix       string
param uniqueSuffix string
param location     string
param tags         object

// Storage account names must be 3-24 chars, lowercase alphanum only.
// We strip hyphens from the prefix to stay within the limit.
var storageAccountName = take(replace('${prefix}sa${uniqueSuffix}', '-', ''), 24)

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // Globally unique name derived from prefix + suffix
  name: storageAccountName
  location: location
  tags: tags
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true              // Enforce HTTPS
    minimumTlsVersion: 'TLS1_2'               // Require TLS 1.2+
    allowBlobPublicAccess: false               // No anonymous blob reads
    allowSharedKeyAccess: true                 // Required by Azure Functions runtime
    networkAcls: {
      defaultAction: 'Allow'                   // Keep open for dev; restrict in prod
      bypass: 'AzureServices'
    }
  }
}

// ── Outputs ─────────────────────────────────────────────────

@description('Name of the provisioned Storage Account')
output storageAccountName string = storageAccount.name

@description('Resource ID of the Storage Account')
output storageAccountId string = storageAccount.id

@description('Primary blob endpoint')
output blobEndpoint string = storageAccount.properties.primaryEndpoints.blob
