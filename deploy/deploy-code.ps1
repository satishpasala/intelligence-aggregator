# ==============================================================================
# deploy-code.ps1 - Intelligence Aggregator: Full Code Deployment
# ==============================================================================
# Deploys all application code to an existing Azure environment:
#   1. Builds and pushes container images (API + Functions) to GHCR
#   2. Updates both Container Apps to the new images
#   3. Runs EF Core database migrations
#   4. Builds and deploys the Angular frontend to Static Web App
#
# Usage (from repo root):
#   .\deploy\deploy-code.ps1
#
# Prerequisites:
#   - Azure CLI logged in:  az login && az account set --subscription <id>
#   - Podman running
#   - .NET 9 SDK installed
#   - Node.js 20+ and @azure/static-web-apps-cli installed globally:
#       npm i -g @azure/static-web-apps-cli
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------------------------
# Configuration - edit these two values before running
# ------------------------------------------------------------------------------

$RESOURCE_GROUP = "daily-brefing"
$GHCR_USER      = "satishpasala"

# PAT is read securely at runtime - never stored in this file
$GHCR_PAT = Read-Host -Prompt "GitHub PAT (read:packages + write:packages)" -AsSecureString
$GHCR_PAT_PLAIN = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($GHCR_PAT)
)

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host ""
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "  $msg" -ForegroundColor Cyan
    Write-Host "--------------------------------------------------------------" -ForegroundColor Cyan
}

function Assert-Tool([string]$name) {
    if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
        Write-Error "Required tool '$name' not found. Please install it and re-run."
    }
}

# Must run from the repo root (contains both src/ and deploy/)
if (-not (Test-Path "src") -or -not (Test-Path "deploy")) {
    Write-Error "Run this script from the repository root (the folder containing src/ and deploy/)."
}

# ------------------------------------------------------------------------------
# Step 1 - Preflight checks
# ------------------------------------------------------------------------------

Write-Step "1 / 7  Preflight checks"

Assert-Tool "az"
Assert-Tool "podman"
Assert-Tool "dotnet"
Assert-Tool "node"
Assert-Tool "swa"

Write-Host "  Checking Azure login..." -ForegroundColor Gray
$null = az account show 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "Not logged in to Azure. Run: az login" }

Write-Host "  Checking Podman..." -ForegroundColor Gray
$null = podman info 2>&1
if ($LASTEXITCODE -ne 0) { Write-Error "Podman is not running. Start Podman Desktop (or 'podman machine start') and retry." }

Write-Host "  All checks passed." -ForegroundColor Green

# ------------------------------------------------------------------------------
# Step 2 - Resolve Azure resource names
# ------------------------------------------------------------------------------

Write-Step "2 / 7  Resolving Azure resource names"

$API_APP  = az containerapp list -g $RESOURCE_GROUP --query "[?contains(name,'api') && !contains(name,'-fn-')].name" -o tsv
$FN_APP   = az containerapp list -g $RESOURCE_GROUP --query "[?contains(name,'-fn-')].name" -o tsv
$SWA_NAME = az staticwebapp list -g $RESOURCE_GROUP --query "[0].name" -o tsv
$KV_NAME  = az keyvault list     -g $RESOURCE_GROUP --query "[0].name" -o tsv
$SQL_SRV  = az sql server list   -g $RESOURCE_GROUP --query "[0].name" -o tsv

if (-not $API_APP)  { Write-Error "Could not find the API Container App in resource group '$RESOURCE_GROUP'." }
if (-not $FN_APP)   { Write-Error "Could not find the Functions Container App in resource group '$RESOURCE_GROUP'." }
if (-not $SWA_NAME) { Write-Error "Could not find the Static Web App in resource group '$RESOURCE_GROUP'." }
if (-not $KV_NAME)  { Write-Error "Could not find the Key Vault in resource group '$RESOURCE_GROUP'." }
if (-not $SQL_SRV)  { Write-Error "Could not find the SQL Server in resource group '$RESOURCE_GROUP'." }

Write-Host "  API Container App : $API_APP"  -ForegroundColor Gray
Write-Host "  Fn  Container App : $FN_APP"   -ForegroundColor Gray
Write-Host "  Static Web App    : $SWA_NAME" -ForegroundColor Gray
Write-Host "  Key Vault         : $KV_NAME"  -ForegroundColor Gray
Write-Host "  SQL Server        : $SQL_SRV"  -ForegroundColor Gray

# ------------------------------------------------------------------------------
# Step 3 - Build and push container images to GHCR
# ------------------------------------------------------------------------------

Write-Step "3 / 7  Building and pushing container images to GHCR"

$API_IMAGE = "ghcr.io/$GHCR_USER/intelligence-aggregator-api:latest"
$FN_IMAGE  = "ghcr.io/$GHCR_USER/intelligence-aggregator-functions:latest"

Write-Host "  Authenticating with GHCR..." -ForegroundColor Gray
$GHCR_PAT_PLAIN | podman login ghcr.io -u $GHCR_USER --password-stdin
if ($LASTEXITCODE -ne 0) { Write-Error "Podman login to GHCR failed." }

Write-Host "  Building API image: $API_IMAGE" -ForegroundColor Gray
podman build -f src/IntelligenceAggregator.Api/Dockerfile -t $API_IMAGE .
if ($LASTEXITCODE -ne 0) { Write-Error "API image build failed." }

Write-Host "  Pushing API image..." -ForegroundColor Gray
podman push $API_IMAGE
if ($LASTEXITCODE -ne 0) { Write-Error "API image push failed." }

Write-Host "  Building Functions image: $FN_IMAGE" -ForegroundColor Gray
podman build -f src/IntelligenceAggregator.Functions/Dockerfile -t $FN_IMAGE .
if ($LASTEXITCODE -ne 0) { Write-Error "Functions image build failed." }

Write-Host "  Pushing Functions image..." -ForegroundColor Gray
podman push $FN_IMAGE
if ($LASTEXITCODE -ne 0) { Write-Error "Functions image push failed." }

Write-Host "  Images pushed successfully." -ForegroundColor Green

# ------------------------------------------------------------------------------
# Step 4 - Update Container Apps with the new images
# ------------------------------------------------------------------------------

Write-Step "4 / 7  Updating Container Apps with new images"

Write-Host "  Updating API Container App..." -ForegroundColor Gray
az containerapp update --name $API_APP --resource-group $RESOURCE_GROUP --image $API_IMAGE --output none
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to update API Container App." }

Write-Host "  Updating Functions Container App..." -ForegroundColor Gray
az containerapp update --name $FN_APP --resource-group $RESOURCE_GROUP --image $FN_IMAGE --output none
if ($LASTEXITCODE -ne 0) { Write-Error "Failed to update Functions Container App." }

Write-Host "  Container Apps updated." -ForegroundColor Green

# ------------------------------------------------------------------------------
# Step 5 - EF Core database migrations
# ------------------------------------------------------------------------------

Write-Step "5 / 7  Running EF Core database migrations"

Write-Host "  Fetching SQL connection string from Key Vault..." -ForegroundColor Gray
$SQL_CONN = az keyvault secret show --vault-name $KV_NAME --name "SqlConnectionString" --query value -o tsv
if ($LASTEXITCODE -ne 0 -or -not $SQL_CONN) { Write-Error "Could not retrieve SqlConnectionString from Key Vault." }

# Temporarily open the SQL firewall for this machine
$MY_IP = (Invoke-RestMethod https://api.ipify.org).Trim()
Write-Host "  Adding temporary firewall rule for $MY_IP..." -ForegroundColor Gray
az sql server firewall-rule create `
    -g $RESOURCE_GROUP -s $SQL_SRV -n "deploy-temp-$MY_IP" `
    --start-ip-address $MY_IP --end-ip-address $MY_IP --output none

try {
    $env:ConnectionStrings__DefaultConnection = $SQL_CONN
    Push-Location "src/IntelligenceAggregator.Api"
    Write-Host "  Running dotnet ef database update..." -ForegroundColor Gray
    dotnet ef database update --project ../IntelligenceAggregator.Infrastructure
    if ($LASTEXITCODE -ne 0) { Write-Error "EF Core migration failed." }
    Write-Host "  Migrations applied." -ForegroundColor Green
}
finally {
    Pop-Location
    $env:ConnectionStrings__DefaultConnection = $null
    Write-Host "  Removing temporary firewall rule..." -ForegroundColor Gray
    az sql server firewall-rule delete `
        -g $RESOURCE_GROUP -s $SQL_SRV -n "deploy-temp-$MY_IP" --yes --output none
}

# ------------------------------------------------------------------------------
# Step 6 - Build and deploy Angular frontend
# ------------------------------------------------------------------------------

Write-Step "6 / 7  Building and deploying Angular frontend"

Push-Location "src/IntelligenceAggregator.Web"
try {
    Write-Host "  Installing npm dependencies..." -ForegroundColor Gray
    npm install --prefer-offline
    if ($LASTEXITCODE -ne 0) { Write-Error "npm install failed." }

    Write-Host "  Building Angular production bundle..." -ForegroundColor Gray
    npm run build -- --configuration production
    if ($LASTEXITCODE -ne 0) { Write-Error "Angular build failed." }

    Write-Host "  Fetching Static Web App deployment token..." -ForegroundColor Gray
    $SWA_TOKEN = az staticwebapp secrets list --name $SWA_NAME --query "properties.apiKey" -o tsv
    if ($LASTEXITCODE -ne 0 -or -not $SWA_TOKEN) { Write-Error "Could not retrieve SWA deployment token." }

    Write-Host "  Deploying to Static Web App..." -ForegroundColor Gray
    swa deploy ./dist/IntelligenceAggregator.Web/browser --deployment-token $SWA_TOKEN --env production
    if ($LASTEXITCODE -ne 0) { Write-Error "Static Web App deployment failed." }

    Write-Host "  Frontend deployed." -ForegroundColor Green
}
finally {
    Pop-Location
}

# ------------------------------------------------------------------------------
# Step 7 - Summary
# ------------------------------------------------------------------------------

Write-Step "7 / 7  Deployment complete"

$API_FQDN = az containerapp show -g $RESOURCE_GROUP -n $API_APP `
    --query "properties.configuration.ingress.fqdn" -o tsv
$SWA_URL  = az staticwebapp show -g $RESOURCE_GROUP -n $SWA_NAME `
    --query "defaultHostname" -o tsv

Write-Host ""
Write-Host "  Frontend : https://$SWA_URL"  -ForegroundColor Green
Write-Host "  API      : https://$API_FQDN" -ForegroundColor Green
Write-Host ""
Write-Host "  API health check:" -ForegroundColor Gray
try {
    Invoke-RestMethod "https://$API_FQDN/health" | ConvertTo-Json
}
catch {
    Write-Host "  (health endpoint not reachable yet - Container App may still be warming up)" -ForegroundColor Yellow
}
