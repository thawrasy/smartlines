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
DataProtectionKeys.Configure(builder.Services.AddDataProtection().SetApplicationName("BankFas"), builder.Configuration, builder.Environment);
builder.Services.AddSingleton<PendingSecretProtector>();
builder.Services.AddSingleton<TenantKeyRing>();
builder.Services.AddSingleton<OpaqueRefs>();
builder.Services.AddSingleton<AccountMail>();
builder.Services.AddSingleton<BankFas.Core.Mail.IMailSender>(_ => BankFas.Core.Mail.MailSenders.Create(k => builder.Configuration[k],
    () => builder.Configuration.GetSection("Mail:Smtp").Get<BankFas.Core.Mail.SmtpOptions>() ?? new()));
// The leaked-password list (DQ-S04-1), opened right after the build so a server without it does not start; a partial
// list is for tests only.
builder.Services.AddSingleton(sp =>
{
    var config = sp.GetRequiredService<IConfiguration>();
    var allowPartial = config.GetValue<bool>("Passwords:BreachedList:AllowMissingRanges");
    if (allowPartial && !builder.Environment.IsDevelopment() && !builder.Environment.IsEnvironment("Testing"))
        throw new InvalidOperationException("A partial leaked-password list is for development and tests only (DQ-S04-1).");
    return new BankFas.Core.Security.BreachedPasswords(config["Passwords:BreachedList:Directory"] ?? "", allowPartial);
});
// The document store and its malware check (DOC-S02 section 8, FR-PLT-029): ClamAV in production; the EICAR-only
// test scanner in development and tests.
builder.Services.AddSingleton(_ => new BankFas.Core.Files.FileStore(builder.Configuration["Files:Root"] ?? ""));
builder.Services.AddSingleton<BankFas.Core.Files.IMalwareScanner>(_ => builder.Configuration["Scanning:Provider"] switch
{
    "clamav" => new BankFas.Core.Files.ClamAvScanner(builder.Configuration["Scanning:Host"] ?? "127.0.0.1", builder.Configuration.GetValue("Scanning:Port", 3310)),
    "test" when builder.Environment.IsDevelopment() || builder.Environment.IsEnvironment("Testing") => new BankFas.Core.Files.EicarOnlyScanner(),
    _ => throw new InvalidOperationException("No malware scanner is configured (Scanning:Provider clamav; FR-PLT-029)."),
});
builder.Services.AddSingleton<IKeyWrapper>(sp => KeyWrapperFactory.Create(builder.Configuration, builder.Environment));
builder.Services.Configure<SecurityOptions>(builder.Configuration.GetSection("Security"));
builder.Services.AddSingleton<SecurityGuard>();
builder.Services.AddSingleton<PdfRenderer>();
builder.Services.AddSingleton<ProformaServices>();
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
    // Every API request counts against its client address (docs/31 row 48); an address unknown, of a trusted proxy or
    // loopback is not limited, so a misread proxy cannot shut every user out at once.
    o.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(ctx =>
    {
        var guard = ctx.RequestServices.GetRequiredService<SecurityGuard>();
        var key = ctx.Request.Path.StartsWithSegments("/api") ? guard.Key(ctx.Connection.RemoteIpAddress) : null;
        if (key is null) return RateLimitPartition.GetNoLimiter("-");
        return RateLimitPartition.GetFixedWindowLimiter(key, _ => new FixedWindowRateLimiterOptions
        {
            PermitLimit = Math.Max(1, guard.Options.ApiPerMinute),
            Window = TimeSpan.FromMinutes(1),
        });
    });
    Policy("login", 10, TimeSpan.FromMinutes(1));
    Policy("mfa", 10, TimeSpan.FromMinutes(15));
    Policy("reset", 10, TimeSpan.FromHours(1));
});

if (!builder.Environment.IsDevelopment() && !builder.Environment.IsEnvironment("Testing")
    && (builder.Configuration.GetValue<bool>("Database:TrustServerCertificate") || scale != 1))
    throw new InvalidOperationException("Database:TrustServerCertificate and RateLimits:Scale are for development and tests only (ADR 0013).");

// Only the trusted proxies (Security:TrustedProxies; Caddy on the host by default) may name the client, and only the
// nearest hop is taken (ADR 0047): a client cannot choose its own address by sending X-Forwarded-For itself.
builder.Services.Configure<Microsoft.AspNetCore.Builder.ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedFor | Microsoft.AspNetCore.HttpOverrides.ForwardedHeaders.XForwardedProto;
    o.ForwardLimit = 1;
    o.KnownIPNetworks.Clear();
    o.KnownProxies.Clear();
    foreach (var p in builder.Configuration.GetSection("Security:TrustedProxies").Get<string[]>() ?? ["127.0.0.1", "::1"])
        if (System.Net.IPAddress.TryParse(p.Trim(), out var a)) o.KnownProxies.Add(a);
});

var app = builder.Build();
// The issue of a proforma prints the proceeds account's IBAN and stores the printed proforma (S4, FR-LCE-005).
BankFas.Data.Lc.ProformaStore.Services = app.Services.GetRequiredService<ProformaServices>();
_ = app.Services.GetRequiredService<BankFas.Core.Security.BreachedPasswords>();
app.UseForwardedHeaders();
app.UseMiddleware<SecurityHeadersMiddleware>();
app.UseMiddleware<SecurityGuardMiddleware>();
app.UseMiddleware<ProblemMiddleware>();
app.UseMiddleware<HostRoutingMiddleware>();

// The built front end (app/web/dist, or wwwroot in a published build): its files are served before routing, which
// otherwise picks the index.html fallback for them too; every other path outside /api gets index.html.
var webRoot = app.Configuration["Web:Root"];
StaticFileOptions? webFiles = null;
if (!string.IsNullOrEmpty(webRoot) && Directory.Exists(webRoot))
{
    webFiles = new StaticFileOptions { FileProvider = new Microsoft.Extensions.FileProviders.PhysicalFileProvider(Path.GetFullPath(webRoot)) };
    app.UseStaticFiles(webFiles);
}
app.UseRouting();
app.UseRateLimiter();
app.UseWhen(ctx => ctx.Request.Path.StartsWithSegments("/api"), a => a.UseMiddleware<CsrfMiddleware>());
app.UseMiddleware<IdempotencyMiddleware>();
app.UseMiddleware<DeadlockRetryMiddleware>();

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
SupportEndpoints.Map(portal);
CatalogEndpoints.Map(portal);
DocumentEndpoints.Map(portal);
CompanyEndpoints.Map(portal);
OwnershipEndpoints.Map(portal);
GovernanceEndpoints.Map(portal);
GrantEndpoints.Map(portal);
SignatoryEndpoints.Map(portal);
ConflictEndpoints.Map(portal);
PartyEndpoints.Map(portal);
InstitutionEndpoints.Map(portal);
AccountEndpoints.Map(portal);
BaseRateEndpoints.Map(portal);
NotificationEndpoints.Map(portal);
CalendarEndpoints.MapPortal(portal);
FacilityEndpoints.Map(portal);
FacilityFileEndpoints.Map(portal);
RelationshipBusinessEndpoints.Map(portal);
FacilityRevisionEndpoints.Map(portal);
LimitEndpoints.Map(portal);
TariffEndpoints.Map(portal);
PricingEndpoints.Map(portal);
CollateralEndpoints.Map(portal);
KycEndpoints.Map(portal);
ObligationEndpoints.Map(portal);
TermEndpoints.Map(portal);
StatementEndpoints.Map(portal);
FinanceCatalogEndpoints.Map(portal);
MonthlyFigureEndpoints.Map(portal);
FormulaEndpoints.Map(portal);
CovenantTestEndpoints.Map(portal);
CreditEndpoints.Map(portal);
CreditReportPrintEndpoints.Map(portal);
ReadinessEndpoints.Map(portal);
CreditInputsEndpoints.Map(portal);
RequestEndpoints.Map(portal);
InboxEndpoints.Map(portal);
DashboardEndpoints.Map(portal);
TemplateEndpoints.Map(portal);
RequestTypeEndpoints.Map(portal);
LcTermsEndpoints.Map(portal);
LcEndpoints.Map(portal);
SalesEndpoints.Map(portal);
SalesLcEndpoints.Map(portal);
ReportEndpoints.Map(portal);
RequestPrintEndpoints.Map(portal);
AttachmentUploadEndpoints.Map(portal);
DataExportEndpoints.Map(portal);
FormTemplateEndpoints.Map(portal);
var panel = app.MapGroup("/api/v1/operator").AddEndpointFilter(SurfaceFilter(Surface.OperatorPanel));
OperatorEndpoints.Map(panel);
OperatorAdminEndpoints.Map(panel);
SecurityEndpoints.Map(panel);
CalendarEndpoints.MapOperator(panel);

// No sitemap and nothing to index (docs/31 row 48): robots.txt refuses every path without naming one, a sitemap is not
// found, and a path that looks like a file (a dot in its last segment) gets 404 instead of the application page.
app.MapGet("/robots.txt", () => Results.Text("User-agent: *\nDisallow: /\n", "text/plain"));
app.MapGet("/{name:regex(^(?i)sitemap.*$)}", () => Results.NotFound());
if (webFiles is not null)
{
    // The root has no path value, which the regex of the fallback does not match; it gets the page on its own.
    app.MapFallbackToFile("{*path:regex(^(?!api/|health/)(?!.*\\.[^/]*$).*$)}", "index.html", webFiles);
    app.MapGet("/", () => Results.File(Path.Combine(Path.GetFullPath(webRoot!), "index.html"), "text/html; charset=utf-8"));
}

app.Run();

static Func<EndpointFilterInvocationContext, EndpointFilterDelegate, ValueTask<object?>> SurfaceFilter(Surface surface) =>
    (ctx, next) => RequestContext.Of(ctx.HttpContext).Surface == surface ? next(ctx) : throw ApiProblemException.NotFound();

/// <summary>The entry point, visible to the integration tests (WebApplicationFactory).</summary>
public partial class Program;
