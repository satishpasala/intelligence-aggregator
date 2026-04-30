# ── Build stage ──────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

# Restore all projects that Functions depends on
COPY ["src/IntelligenceAggregator.Functions/IntelligenceAggregator.Functions.csproj",     "IntelligenceAggregator.Functions/"]
COPY ["src/IntelligenceAggregator.Application/IntelligenceAggregator.Application.csproj", "IntelligenceAggregator.Application/"]
COPY ["src/IntelligenceAggregator.Domain/IntelligenceAggregator.Domain.csproj",           "IntelligenceAggregator.Domain/"]
COPY ["src/IntelligenceAggregator.Infrastructure/IntelligenceAggregator.Infrastructure.csproj", "IntelligenceAggregator.Infrastructure/"]
RUN dotnet restore "IntelligenceAggregator.Functions/IntelligenceAggregator.Functions.csproj"

# Copy source and publish
COPY src/ .
WORKDIR "/src/IntelligenceAggregator.Functions"
RUN dotnet publish "IntelligenceAggregator.Functions.csproj" \
    -c Release \
    -o /app/publish \
    --no-restore

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated9.0 AS final
WORKDIR /home/site/wwwroot

COPY --from=build /app/publish .

# Azure Functions runtime reads triggers/bindings from the assembly;
# the host.json must be present in the working directory.
ENV AzureWebJobsScriptRoot=/home/site/wwwroot \
    AzureFunctionsJobHost__Logging__Console__IsEnabled=true
