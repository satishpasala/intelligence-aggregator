# Intelligence Aggregator – Azure Deployment Guide

This guide deploys the full infrastructure at **near-zero monthly cost** using only
free or free-tier Azure services, plus GitHub Container Registry (GHCR) for images.

---

## Monthly cost summary

| Resource | Cost |
|----------|------|
| Static Web App (Free tier) | **$0** |
| Container Apps – API (Consumption, scale-to-zero) | **$0** |
| Container Apps – Functions (Consumption, scale-to-zero) | **$0** |
| Container Apps Environment (Consumption profile) | **$0** |
| Azure SQL Database (serverless, free offer) | **$0** |
| Key Vault (≤10k ops/month) | **$0** |
| Application Insights (workspace-based, ≤5 GB) | **$0** |
| Log Analytics (≤5 GB/month free) | **$0** |
| **Storage Account (LRS)** | **~$1–2/mo** |
| **GitHub Container Registry** | **$0** |
| **Total** | **~$1–2/month** |

> Storage Account is unavoidable — it's required by the Azure Functions runtime for
> host coordination, queue triggers, and timer state. Everything else is free.

---

## Architecture

```
deploy/
├── main.bicep
├── parameters/
│   └── dev.bicepparam
└── modules/
    ├── monitoring.bicep          # Log Analytics + Application Insights
    ├── storage.bicep             # Storage Account (Functions host storage)
    ├── sql.bicep                 # Azure SQL Server + Database (free serverless)
    ├── key-vault.bicep           # Key Vault + secrets + RBAC
    ├── static-web-app.bicep      # Angular SPA (Free tier)
    ├── container-apps-env.bicep  # Shared Container Apps Environment (Consumption)
    ├── api-container-app.bicep   # .NET 9 Web API Container App
    └── function-app.bicep        # Azure Functions Container App (timer triggers)
```

Images are stored in **GitHub Container Registry (ghcr.io)** — free for all GitHub accounts.

---

## Prerequisites

| Tool | Minimum version | Install |
|------|----------------|---------|
| Azure CLI | 2.57+ | https://aka.ms/installazurecli |
| Bicep CLI | 0.26+ | `az bicep install` |
| .NET SDK | 9.0 | https://dotnet.microsoft.com |
| Docker Desktop | latest | https://www.docker.com/products/docker-desktop |
| Node.js | 20 LTS | For SWA CLI |
| Azure Static Web Apps CLI | latest | `npm i -g @azure/static-web-apps-cli` |

---

## Step 1 – Create a GitHub PAT for GHCR

Go to **https://github.com/settings/tokens → Generate new token (classic)**

Required scopes:
- `read:packages` — for Container Apps to pull images at runtime
- `write:packages` — for `docker push` from your local machine

Keep the token value handy; you will pass it as `--parameters ghcrPat=<token>` during deploy.

---

## Step 2 – Replace Placeholder Values

Open `parameters/dev.bicepparam` and replace every value marked `← REPLACE`:

| Parameter | Description |
|-----------|-------------|
| `location` | Azure region, e.g. `eastus` |
| `uniqueSuffix` | 6-char suffix (see tip below) |
| `sqlAdminObjectId` | AAD Object ID of the deploying user |
| `sqlAdminPassword` | Strong SQL password |
| `ghcrUsername` | Your GitHub username |

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

## Step 3 – Login and Set Subscription

```bash
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

---

## Step 4 – Deploy the Infrastructure

```bash
az deployment group create \
  --resource-group "<YOUR_RESOURCE_GROUP_NAME>" \
  --template-file deploy/main.bicep \
  --parameters deploy/parameters/dev.bicepparam \
  --parameters ghcrPat="<YOUR_GITHUB_PAT>" \
  --name "intelligence-aggregator-deploy-$(date +%Y%m%d%H%M%S)"
```

The deployment runs in 4 phases (Bicep handles ordering):

1. **Foundation** – Monitoring, Storage, SQL, Static Web App, Container Apps Env (parallel)
2. **Compute** – API Container App + Functions Container App (to get managed identity IDs)
3. **Secrets** – Key Vault (creates vault, stores secrets, assigns Secrets User to both identities)
4. **Config** – Re-deploys both Container Apps with real Key Vault secret references

Estimated deploy time: **8–15 minutes**.

---

## Step 5 – Capture Outputs

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
| `apiUrl` | .NET Web API HTTPS URL (Container App) |
| `functionAppName` | Functions Container App name |
| `sqlServerName` | SQL Server FQDN |
| `keyVaultUri` | Key Vault URI |

---

## Step 6 – Set the Real OpenAI API Key

```bash
KV_NAME=$(az keyvault list --resource-group "<YOUR_RG>" --query "[0].name" -o tsv)
az keyvault secret set --vault-name "$KV_NAME" --name "OpenAiApiKey" --value "<YOUR_KEY>"
```

Restart both Container Apps to pick up the new secret:

```bash
RG="<YOUR_RESOURCE_GROUP_NAME>"
az containerapp revision restart \
  --name $(az containerapp list -g $RG --query "[?contains(name,'api')].name" -o tsv) \
  --resource-group "$RG"
az containerapp revision restart \
  --name $(az containerapp list -g $RG --query "[?contains(name,'-fn-')].name" -o tsv) \
  --resource-group "$RG"
```

---

## Step 7 – Run Database Migrations

```bash
cd src/IntelligenceAggregator.Api
$env:ConnectionStrings__DefaultConnection = "<SQL_CONNECTION_STRING>"
dotnet ef database update --project ../IntelligenceAggregator.Infrastructure
```

---

## Step 8 – Deploy the Angular Frontend

```bash
cd src/IntelligenceAggregator.Web
npm install
npm run build -- --configuration production

SWA_NAME=$(az staticwebapp list -g "<YOUR_RG>" --query "[0].name" -o tsv)
SWA_TOKEN=$(az staticwebapp secrets list --name "$SWA_NAME" --query "properties.apiKey" -o tsv)

swa deploy ./dist/IntelligenceAggregator.Web/browser \
  --deployment-token "$SWA_TOKEN" \
  --env production
```

---

## Step 9 – Build and Push Images to GHCR

Run from the **repo root** (where `.dockerignore` lives).

```bash
GHCR_USER="<YOUR_GITHUB_USERNAME>"

# Authenticate Docker with GHCR (uses the same PAT from Step 1)
echo "<YOUR_GITHUB_PAT>" | docker login ghcr.io -u "$GHCR_USER" --password-stdin

# Build and push the Functions image
docker build \
  -f src/IntelligenceAggregator.Functions/Dockerfile \
  -t "ghcr.io/$GHCR_USER/intelligence-aggregator-functions:latest" \
  .
docker push "ghcr.io/$GHCR_USER/intelligence-aggregator-functions:latest"

# Build and push the API image
docker build \
  -f src/IntelligenceAggregator.Api/Dockerfile \
  -t "ghcr.io/$GHCR_USER/intelligence-aggregator-api:latest" \
  .
docker push "ghcr.io/$GHCR_USER/intelligence-aggregator-api:latest"
```

> **GHCR visibility**: After pushing, go to your GitHub profile → Packages and set
> each package to **Private** (default) or **Public**. If Private, the GHCR PAT
> you supplied in Step 4 is used by Container Apps to pull at runtime.

---

## Step 10 – Update Container Apps with Real Images

After pushing, point the Container Apps at the custom images:

```bash
RG="<YOUR_RESOURCE_GROUP_NAME>"
GHCR_USER="<YOUR_GITHUB_USERNAME>"

API_APP=$(az containerapp list -g $RG --query "[?contains(name,'api')].name" -o tsv)
FN_APP=$(az containerapp list -g $RG --query "[?contains(name,'-fn-')].name" -o tsv)

az containerapp update --name "$API_APP" --resource-group "$RG" \
  --image "ghcr.io/$GHCR_USER/intelligence-aggregator-api:latest"

az containerapp update --name "$FN_APP" --resource-group "$RG" \
  --image "ghcr.io/$GHCR_USER/intelligence-aggregator-functions:latest"
```

> **Subsequent deploys**: just rebuild, push, and run `az containerapp update` again.

---

## Resource Explanation

| Resource | SKU / Tier | Cost | Purpose |
|----------|-----------|------|---------|
| Log Analytics Workspace | PerGB2018 | $0 (≤5 GB free) | Log storage |
| Application Insights | Workspace-based | $0 | APM telemetry |
| Storage Account | Standard LRS | ~$1–2/mo | Functions host storage |
| SQL Server | – | $0 | Logical SQL server |
| SQL Database | GP_S_Gen5 serverless | $0 (free offer) | App data, auto-pauses |
| Key Vault | Standard | $0 (≤10k ops) | Secrets |
| Static Web App | Free | $0 | Angular SPA |
| Container Apps Environment | Consumption | $0 | Shared runtime env |
| Container App – API | Consumption, scale-to-zero | $0 | .NET Web API |
| Container App – Functions | Consumption, scale-to-zero | $0 | Timer jobs |
| GitHub Container Registry | Free | $0 | Docker image storage |

---

## Security Notes

- All secrets live in Key Vault; no plaintext credentials in app settings.
- Both Container Apps use **system-assigned managed identities** for Key Vault access.
- GHCR pull credentials are stored as Container App secrets (not in app settings).
- TLS is terminated by the Container App ingress; apps communicate over HTTP internally.
- SQL uses AAD Default auth at runtime (managed identity); SQL password is for admin only.
- In production, set `publicNetworkAccess: 'Disabled'` on SQL and Key Vault behind a VNet.

---

## Tearing Down

```bash
az group delete --name "<YOUR_RESOURCE_GROUP_NAME>" --yes --no-wait
```

> Key Vault enters soft-delete for 7 days. Purge manually if needed:
> `az keyvault purge --name <kv-name>`
