// The BankFas web application: the tenant portal and the operator panel API (DOC-B04), on ASP.NET Core (ADR 0040).
using System.Threading.RateLimiting;
using Microsoft.AspNetCore.DataProtection;
using BankFas.Api.Endpoints;
using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using BankFas.Data;
using BankFas.Data.Jobs;

var builder = WebApplication.CreateBuilder(args);
builder.Services.Configure<DatabaseOptions>(builder.Configuration.GetSection(DatabaseOptions.Section));
builder.Services.Configure<BankFas.Api.Infrastructure.HostOptions>(builder.Configuration.GetSection(BankFas.Api.Infrastructure.HostOptions.Section));
builder.Services.Configure<PortalOptions>(builder.Configuration.GetSection(PortalOptions.Section));
builder.Services.AddSingleton<SqlConnectionFactory>();
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddMemoryCache();
builder.Services.AddDataProtection().SetApplicationName("BankFas");
builder.Services.AddSingleton<PendingSecretProtector>();
builder.Services.AddSingleton<TenantKeyRing>();
builder.Services.AddSingleton<OpaqueRefs>();
builder.Services.AddSingleton<AccountMail>();
builder.Services.AddSingleton<BankFas.Core.Mail.IMailSender>(_ => new BankFas.Core.Mail.FileDropMailSender(builder.Configuration["Mail:DropDirectory"]
    ?? throw new InvalidOperationException("Mail:DropDirectory is not set; the SMTP relay comes with the hosting decision (docs/42).")));
builder.Services.AddSingleton<IKeyWrapper>(sp => KeyWrapperFactory.Create(builder.Configuration, builder.Environment));
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = System.Text.Json.JsonNamingPolicy.CamelCase);

// Rate limits per client address (DOC-S04 section 6): 10 password attempts a minute, 10 MFA attempts in 15 minutes,
// 10 reset requests an hour. "RateLimits:Scale" multiplies them (tests only; 1 elsewhere).
var scale = Math.Max(1, builder.Configuration.GetValue("RateLimits:Scale", 1));
builder.Services.AddRateLimiter(o =>
{
    o.RejectionStatusCode = StatusCodes.Status429TooManyRequests;
    void Policy(string name, int permits, TimeSpan window) => o.AddPolicy(name, ctx => RateLimitPartition.GetFixedWindowLimiter(
        ctx.Connection.RemoteIpAddress?.ToString() ?? "-", _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = permits * Math.Max(1, ctx.RequestServices.GetRequiredService<IConfiguration>().GetValue("RateLimits:Scale", 1)),
            Window = window,
        }));
    Policy("login", 10, TimeSpan.FromMinutes(1));
    Policy("mfa", 10, TimeSpan.FromMinutes(15));
    Policy("reset", 10, TimeSpan.FromHours(1));
});

if (!builder.Environment.IsDevelopment() && !builder.Environment.IsEnvironment("Testing")
    && (builder.Configuration.GetValue<bool>("Database:TrustServerCertificate") || scale != 1))
    throw new InvalidOperationException("Database:TrustServerCertificate and RateLimits:Scale are for development and tests only (ADR 0013).");

var app = builder.Build();
app.UseMiddleware<SecurityHeadersMiddleware>();
app.UseMiddleware<ProblemMiddleware>();
app.UseMiddleware<HostRoutingMiddleware>();
app.UseRateLimiter();
app.UseWhen(ctx => ctx.Request.Path.StartsWithSegments("/api"), a => a.UseMiddleware<CsrfMiddleware>());
app.UseMiddleware<IdempotencyMiddleware>();

app.MapGet("/health/live", () => Results.Ok(new { status = "live" }));
app.MapGet("/api/v1/csrf", (HttpContext http) => Results.Ok(new { token = CsrfMiddleware.Issue(http) }));

// One path space, two surfaces: the host decides which endpoints answer (HostRoutingMiddleware).
var portal = app.MapGroup("/api/v1").AddEndpointFilter(SurfaceFilter(Surface.TenantPortal));
TenantAuthEndpoints.Map(portal);
PortalEndpoints.Map(portal);
UserEndpoints.Map(portal);
RoleEndpoints.Map(portal);
MeEndpoints.Map(portal);
ConfigEndpoints.Map(portal);
var panel = app.MapGroup("/api/v1/operator").AddEndpointFilter(SurfaceFilter(Surface.OperatorPanel));
OperatorEndpoints.Map(panel);

// The built front end (app/web/dist, or wwwroot in a published build) for every path outside /api.
var webRoot = app.Configuration["Web:Root"];
if (!string.IsNullOrEmpty(webRoot) && Directory.Exists(webRoot))
{
    var files = new StaticFileOptions { FileProvider = new Microsoft.Extensions.FileProviders.PhysicalFileProvider(Path.GetFullPath(webRoot)) };
    app.UseStaticFiles(files);
    app.MapFallbackToFile("{*path:regex(^(?!api/|health/).*$)}", "index.html", files);
}

app.Run();

static Func<EndpointFilterInvocationContext, EndpointFilterDelegate, ValueTask<object?>> SurfaceFilter(Surface surface) =>
    (ctx, next) => RequestContext.Of(ctx.HttpContext).Surface == surface ? next(ctx) : throw ApiProblemException.NotFound();

/// <summary>The entry point, visible to the integration tests (WebApplicationFactory).</summary>
public partial class Program;
