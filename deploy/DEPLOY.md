# Intelligence Aggregator – Azure Deployment Guide

This guide covers everything needed to deploy the full Azure infrastructure
using the Bicep templates in this folder.

---

## Folder Structure

```
deploy/
├── main.bicep                    # Root orchestrator – deploys all modules
├── parameters/
│   └── dev.bicepparam            # Dev environment parameter values
└── modules/
    ├── monitoring.bicep          # Log Analytics Workspace + Application Insights
    ├── storage.bicep             # Storage Account (required by Functions)
    ├── sql.bicep                 # Azure SQL Server + Database
    ├── key-vault.bicep           # Key Vault + secrets + RBAC assignments
    ├── static-web-app.bicep      # Angular Static Web App
    ├── app-service.bicep         # App Service Plan + .NET Web API
    └── function-app.bicep        # Consumption Function App (timer triggers)
```

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Azure CLI | 2.57+ | https://aka.ms/installazurecli |
| Bicep CLI | 0.26+ | `az bicep install` |
| .NET SDK | 9.0 | https://dotnet.microsoft.com |
| Node.js | 20 LTS | For SWA CLI |
| Azure Static Web Apps CLI | latest | `npm i -g @azure/static-web-apps-cli` |

---

## Step 1 – Replace Placeholder Values

Open `parameters/dev.bicepparam` and replace every value marked `← REPLACE`:

| Parameter | Description |
|-----------|-------------|
| `location` | Azure region, e.g. `eastus` or `westeurope` |
| `uniqueSuffix` | 6-char suffix (see tip below) |
| `sqlAdminObjectId` | AAD Object ID of the deploying user / service principal |
| `sqlAdminPassword` | Strong SQL password (min 12 chars, mixed case + symbol + digit) |
| `openAiApiKey` | Your OpenAI API key (or set it post-deploy in Key Vault) |

**Generate a stable uniqueSuffix (PowerShell):**
```powershell
$rg = "YOUR_RESOURCE_GROUP_NAME"
$id = az group show --name $rg --query id -o tsv
[System.BitConverter]::ToString([System.Security.Cryptography.MD5]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($id))).Replace("-","").Substring(0,6).ToLower()
```

**Get your AAD Object ID:**
```bash
az ad signed-in-user show --query id -o tsv
```

---

## Step 2 – Login and Set Subscription

```bash
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

---

## Step 3 – Deploy the Infrastructure

```bash
az deployment group create \
  --resource-group "<YOUR_RESOURCE_GROUP_NAME>" \
  --template-file deploy/main.bicep \
  --parameters deploy/parameters/dev.bicepparam \
  --name "intelligence-aggregator-deploy-$(date +%Y%m%d%H%M%S)"
```

The deployment runs in 4 phases (Bicep handles ordering automatically):

1. **Foundation** – Monitoring, Storage, SQL, Static Web App (parallel)
2. **Compute** – App Service and Function App (to get managed identity IDs)
3. **Key Vault** – Create vault, store secrets, assign RBAC
4. **Config** – Re-apply app settings with Key Vault references wired in

Estimated deploy time: **8–15 minutes**.

---

## Step 4 – Capture Outputs

```bash
az deployment group show \
  --resource-group "<YOUR_RESOURCE_GROUP_NAME>" \
  --name "intelligence-aggregator-deploy-*" \
  --query properties.outputs
```

Key outputs:

| Output | Description |
|--------|-------------|
| `staticWebAppUrl` | Angular app public URL |
| `apiUrl` | .NET Web API HTTPS URL |
| `functionAppName` | Function App name (for CI/CD) |
| `sqlServerName` | SQL Server FQDN |
| `sqlDatabaseName` | SQL Database name |
| `keyVaultUri` | Key Vault URI |
| `appInsightsConnectionString` | AI connection string |

---

## Step 5 – Set the Real OpenAI API Key

The parameter file contains a placeholder. Set the real key in Key Vault:

```bash
KV_NAME=$(az keyvault list --resource-group "<YOUR_RG>" --query "[0].name" -o tsv)

az keyvault secret set \
  --vault-name "$KV_NAME" \
  --name "OpenAiApiKey" \
  --value "<YOUR_REAL_OPENAI_API_KEY>"
```

Then restart both apps to pick up the new secret:

```bash
RG="<YOUR_RESOURCE_GROUP_NAME>"
APP_NAME=$(az webapp list -g $RG --query "[?contains(name, 'api')].name" -o tsv)
FUNC_NAME=$(az functionapp list -g $RG --query "[0].name" -o tsv)

az webapp restart --name "$APP_NAME" --resource-group "$RG"
az functionapp restart --name "$FUNC_NAME" --resource-group "$RG"
```

---

## Step 6 – Run Database Migrations

The infrastructure creates the SQL Server and Database only.
Apply EF Core migrations from the application:

```bash
cd src/IntelligenceAggregator.Api

# Set the connection string for the local migration tool
$env:ConnectionStrings__DefaultConnection = "<SQL_CONNECTION_STRING>"

dotnet ef database update --project ../IntelligenceAggregator.Infrastructure
```

---

## Step 7 – Deploy the Angular Frontend

```bash
cd src/IntelligenceAggregator.Web

# Build the Angular app
npm install
npm run build -- --configuration production

# Deploy to Static Web Apps
SWA_NAME=$(az staticwebapp list -g "<YOUR_RG>" --query "[0].name" -o tsv)
SWA_TOKEN=$(az staticwebapp secrets list --name "$SWA_NAME" --query "properties.apiKey" -o tsv)

swa deploy ./dist/intelligence-aggregator-web \
  --deployment-token "$SWA_TOKEN" \
  --env production
```

---

## Step 8 – Deploy the .NET Web API

```bash
cd src/IntelligenceAggregator.Api
dotnet publish -c Release -o ./publish

APP_NAME="intelligence-aggregator-dev-api"   # adjust if prefix differs
RG="<YOUR_RESOURCE_GROUP_NAME>"

az webapp deploy \
  --resource-group "$RG" \
  --name "$APP_NAME" \
  --src-path ./publish \
  --type zip
```

---

## Step 9 – Deploy the Function App

```bash
cd src/IntelligenceAggregator.Functions
dotnet publish -c Release -o ./publish

FUNC_NAME=$(az functionapp list -g "<YOUR_RG>" --query "[0].name" -o tsv)

az functionapp deployment source config-zip \
  --resource-group "<YOUR_RG>" \
  --name "$FUNC_NAME" \
  --src ./publish.zip
```

---

## Resource Explanation

| Resource | SKU / Tier | Purpose |
|----------|-----------|---------|
| Log Analytics Workspace | PerGB2018 | Centralised log store |
| Application Insights | Workspace-based | APM telemetry for API + Functions |
| Storage Account | Standard_LRS | Azure Functions host storage |
| SQL Server | – | Logical SQL server (AAD + SQL auth) |
| SQL Database | GP_S_Gen5 (serverless, 1 vCore) | App data, auto-pauses when idle |
| Key Vault | Standard | Secrets management, no hardcoded credentials |
| Static Web App | Free | Angular public + admin UI |
| App Service Plan | B1 Linux | Hosts the .NET Web API |
| App Service | .NET 9 Linux | .NET Web API |
| Function App | Consumption Linux | Timer-triggered aggregation jobs |

---

## Security Notes

- All secrets are stored in Key Vault; no plaintext secrets in app settings.
- App Service and Function App use **system-assigned managed identities**;
  they authenticate to Key Vault and SQL via AAD – no passwords needed at runtime.
- HTTPS only is enforced on both App Service and Function App.
- TLS 1.2 minimum is set on SQL Server, Storage, App Service, and Function App.
- Public blob write access is disabled on the Storage Account.
- In production, tighten the SQL Server firewall to specific IP ranges and
  set `publicNetworkAccess: 'Disabled'` behind a VNet.

---

## Tearing Down

```bash
# Delete all resources by removing the resource group (irreversible!)
az group delete --name "<YOUR_RESOURCE_GROUP_NAME>" --yes --no-wait
```

> **Warning:** This deletes everything including the SQL database and Key Vault.
> Key Vault enters soft-delete state for 7 days; purge manually if needed:
> `az keyvault purge --name <kv-name>`
