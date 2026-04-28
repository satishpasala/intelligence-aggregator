// ============================================================
// modules/key-vault.bicep
// ============================================================
// Provisions:
//   - Azure Key Vault  (standard SKU, RBAC authorization)
//   - Key Vault secrets for SQL connection string & OpenAI key
//   - Role assignment: Key Vault Secrets User for the Function
//     App managed identity
//
// App settings in function-app.bicep reference these secrets
// via Key Vault references:
//   @Microsoft.KeyVault(SecretUri=...)
// ============================================================

param prefix                  string
param uniqueSuffix            string
param location                string
param tags                    object

@description('SQL connection string to store as a secret')
@secure()
param sqlConnectionString string

@description('OpenAI API key to store as a secret')
@secure()
param openAiApiKey string

@description('Principal ID of the Function App managed identity')
param functionAppPrincipalId string

var keyVaultName = take('${replace(prefix, '-', '')}kv${uniqueSuffix}', 24)

// Key Vault Secrets User role definition ID (built-in)
var keyVaultSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

// ── Key Vault ────────────────────────────────────────────────

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true              // Use Azure RBAC (not legacy access policies)
    enableSoftDelete: true
    softDeleteRetentionInDays: 7              // Minimum retention; reduce recovery cost
    enablePurgeProtection: false             // Allow manual purge in dev
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

// ── Secrets ──────────────────────────────────────────────────

resource secretSqlConnection 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'SqlConnectionString'
  properties: {
    value: sqlConnectionString
    attributes: {
      enabled: true
    }
  }
}

resource secretOpenAiKey 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: keyVault
  name: 'OpenAiApiKey'
  properties: {
    value: openAiApiKey
    attributes: {
      enabled: true
    }
  }
}

// ── RBAC: Function App → Key Vault Secrets User ──────────────

resource functionAppKvRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: keyVault
  name: guid(keyVault.id, functionAppPrincipalId, keyVaultSecretsUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', keyVaultSecretsUserRoleId)
    principalId: functionAppPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs ─────────────────────────────────────────────────

@description('URI of the provisioned Key Vault')
output keyVaultUri string = keyVault.properties.vaultUri

@description('Name of the Key Vault')
output keyVaultName string = keyVault.name

@description('Secret URI for the SQL connection string')
output sqlConnectionStringSecretUri string = secretSqlConnection.properties.secretUri

@description('Secret URI for the OpenAI API key')
output openAiApiKeySecretUri string = secretOpenAiKey.properties.secretUri
