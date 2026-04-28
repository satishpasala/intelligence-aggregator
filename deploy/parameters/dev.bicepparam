// ============================================================
// dev.bicepparam – Development environment parameters
// ============================================================
// Replace every value marked  ← REPLACE  before deploying.
// Do NOT commit real passwords or API keys to source control.
// ============================================================

using '../main.bicep'

// ── Identity & location ──────────────────────────────────────
param environment        = 'dev'
param location           = 'eastus'                // ← REPLACE with your Azure region (e.g. 'westeurope')
param appName            = 'intelligence-aggregator'

// Stable 6-char suffix – generate once with:
//   $(az group show -n <rg> --query id -o tsv | md5sum | cut -c1-6)
// then hard-code it here so re-deployments stay idempotent.
param uniqueSuffix       = 'abc123'               // ← REPLACE with your generated suffix

// ── SQL administrator ────────────────────────────────────────
// sqlAdminObjectId: Object ID of the AAD user/group/service-principal
// that will be set as the SQL Server AAD admin.
// Get it via: az ad user show --id <upn> --query id -o tsv
param sqlAdminObjectId   = '00000000-0000-0000-0000-000000000000'  // ← REPLACE
param sqlAdminLogin      = 'sqladmin'
param sqlAdminPassword   = 'PLACEHOLDER_CHANGE_ME_Aa1!'            // ← REPLACE (never commit real value)

// ── OpenAI ───────────────────────────────────────────────────
// After first deploy, store the real key in Key Vault manually:
//   az keyvault secret set --vault-name <kv-name> \
//     --name OpenAiApiKey --value "<real-key>"
param openAiApiKey       = 'PLACEHOLDER_SET_IN_KEYVAULT'           // ← REPLACE or set post-deploy
param openAiModel        = 'gpt-4o-mini'

// ── Application tuning ───────────────────────────────────────
param maxArticlesPerRun  = 100
param maxAiCallsPerDay   = 50
param enableAiSummaries  = true

// ── Aggregation schedules (Azure Functions NCRONTAB – UTC) ───
// Format: {second} {minute} {hour} {day} {month} {day-of-week}
param newsSchedule       = '0 0 6,18 * * *'    // 06:00 and 18:00 UTC  (6 AM / 6 PM)
param trendSchedule      = '0 15 6,18 * * *'   // 06:15 and 18:15 UTC  (6:15 AM / 6:15 PM)
param briefingSchedule   = '0 30 6,18 * * *'   // 06:30 and 18:30 UTC  (6:30 AM / 6:30 PM)
