using Azure.Identity;

var builder = WebApplication.CreateBuilder(args);

// ── Key Vault integration (non-Development only) ──────────────
// App Service injects KeyVault__VaultUri via appsettings + env vars.
// Azure.Identity DefaultAzureCredential uses the system-assigned
// managed identity in Azure and falls back to developer credentials
// locally (az login / VS credential).
var keyVaultUri = builder.Configuration["KeyVault:VaultUri"];
if (!string.IsNullOrWhiteSpace(keyVaultUri) && !builder.Environment.IsDevelopment())
{
    builder.Configuration.AddAzureKeyVault(new Uri(keyVaultUri), new DefaultAzureCredential());
}

builder.Services.AddControllers();

builder.Services.AddOpenApi();

// ── CORS ──────────────────────────────────────────────────────
// Allow the Angular SWA origin (set CORS__AllowedOrigins in app settings
// or the default "*" is used in Development).
var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>()
    ?? ["*"];

builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        if (allowedOrigins is ["*"])
            policy.AllowAnyOrigin().AllowAnyMethod().AllowAnyHeader();
        else
            policy.WithOrigins(allowedOrigins).AllowAnyMethod().AllowAnyHeader().AllowCredentials();
    });
});

var app = builder.Build();

if (app.Environment.IsDevelopment())
{
    app.MapOpenApi();
    // HTTPS redirect only in local development; Container Apps terminates
    // TLS at the ingress layer so redirecting inside the container causes
    // an infinite redirect loop.
    app.UseHttpsRedirection();
}

app.UseCors();
app.UseAuthorization();
app.MapControllers();

app.Run();
