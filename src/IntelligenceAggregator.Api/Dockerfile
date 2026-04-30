# ── Build stage ──────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/sdk:9.0 AS build
WORKDIR /src

COPY ["src/IntelligenceAggregator.Api/IntelligenceAggregator.Api.csproj",               "IntelligenceAggregator.Api/"]
COPY ["src/IntelligenceAggregator.Application/IntelligenceAggregator.Application.csproj","IntelligenceAggregator.Application/"]
COPY ["src/IntelligenceAggregator.Domain/IntelligenceAggregator.Domain.csproj",          "IntelligenceAggregator.Domain/"]
COPY ["src/IntelligenceAggregator.Infrastructure/IntelligenceAggregator.Infrastructure.csproj","IntelligenceAggregator.Infrastructure/"]
RUN dotnet restore "IntelligenceAggregator.Api/IntelligenceAggregator.Api.csproj"

COPY src/ .
WORKDIR "/src/IntelligenceAggregator.Api"
RUN dotnet publish "IntelligenceAggregator.Api.csproj" \
    -c Release \
    -o /app/publish \
    --no-restore

# ── Runtime stage ─────────────────────────────────────────────────────────────
FROM mcr.microsoft.com/dotnet/aspnet:9.0 AS final
WORKDIR /app

# Container Apps terminates TLS at the ingress; the app listens on HTTP 8080.
EXPOSE 8080
ENV ASPNETCORE_HTTP_PORTS=8080

COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "IntelligenceAggregator.Api.dll"]
