using System.Net;
using BankFas.Data;
using BankFas.Data.Jobs;
using Microsoft.Extensions.Caching.Memory;
using Microsoft.Extensions.Options;

namespace BankFas.Api.Infrastructure;

public enum Surface { TenantPortal, OperatorPanel }

/// <summary>Configuration section "Hosts": the operator panel's host, apart from every tenant sub-domain (DOC-S03 section 6).</summary>
public sealed class HostOptions
{
    public const string Section = "Hosts";
    public string Operator { get; set; } = "admin.bankfas.com";

    /// <summary>Sub-domains that are never a tenant (reserved, plat.ReservedSubdomain holds the rest).</summary>
    public string[] NotTenants { get; set; } = ["www", "api", "admin", "operator"];
}

/// <summary>What the host says about a request: which surface, which tenant, and its correlation id.</summary>
public sealed class RequestContext
{
    public Surface Surface { get; init; }
    public ResolvedTenant? Tenant { get; init; }
    public string TenantCode { get; init; } = "";
    public Guid CorrelationId { get; init; }
    public string? ClientIp { get; init; }

    public static Guid CorrelationOf(HttpContext context) =>
        context.Items[typeof(RequestContext)] is RequestContext r ? r.CorrelationId : Guid.Empty;

    public static RequestContext Of(HttpContext context) =>
        context.Items[typeof(RequestContext)] as RequestContext ?? throw new InvalidOperationException("No request context.");

    public ResolvedTenant RequireTenant() => Tenant ?? throw ApiProblemException.NotFound();
}

/// <summary>
/// Takes the tenant from the Host header alone, never from the body, query or path (FR-PLT-046, DOC-B04): the first
/// label of {code}.{domain}. The operator host goes to the panel before any tenant lookup. An unknown code, and an
/// archived tenant, get the same neutral 404 (decision 37, Q-1). Lookups are cached for a minute; the database checks
/// the status again at login and at every binding.
/// </summary>
public sealed class HostRoutingMiddleware(RequestDelegate next, IOptions<HostOptions> hosts, IOptions<PortalOptions> portal,
    SqlConnectionFactory db, IMemoryCache cache)
{
    public async Task InvokeAsync(HttpContext context)
    {
        var correlation = Guid.NewGuid();
        context.Response.Headers["X-Correlation-Id"] = correlation.ToString();
        var ip = context.Connection.RemoteIpAddress is { } a ? (a.IsIPv4MappedToIPv6 ? a.MapToIPv4() : a).ToString() : null;
        var host = context.Request.Host.Host.ToLowerInvariant();
        RequestContext rc;
        if (string.Equals(host, hosts.Value.Operator, StringComparison.OrdinalIgnoreCase))
        {
            rc = new RequestContext { Surface = Surface.OperatorPanel, CorrelationId = correlation, ClientIp = ip };
        }
        else
        {
            var suffix = "." + portal.Value.Domain.ToLowerInvariant();
            var code = host.EndsWith(suffix, StringComparison.Ordinal) ? host[..^suffix.Length] : "";
            ResolvedTenant? tenant = null;
            if (code.Length is > 0 and <= 30 && !code.Contains('.', StringComparison.Ordinal) && !hosts.Value.NotTenants.Contains(code))
            {
                tenant = await cache.GetOrCreateAsync("tenant:" + code, async e =>
                {
                    e.AbsoluteExpirationRelativeToNow = TimeSpan.FromSeconds(60);
                    await using var c = await db.OpenAsync(DbLogin.App, context.RequestAborted);
                    return await TenantAuthProcedures.ResolveTenantAsync(c, code, context.RequestAborted);
                });
            }
            rc = new RequestContext
            {
                Surface = Surface.TenantPortal,
                Tenant = tenant is { Status: not "ARCHIVED_READ_ONLY" } ? tenant : null,
                TenantCode = code,
                CorrelationId = correlation,
                ClientIp = ip,
            };
        }
        context.Items[typeof(RequestContext)] = rc;
        if (rc.Surface == Surface.TenantPortal && rc.Tenant is null && context.Request.Path.StartsWithSegments("/api"))
        {
            await ProblemMiddleware.WriteAsync(context, (int)HttpStatusCode.NotFound, "NOT_FOUND", "Not found.");
            return;
        }
        await next(context);
    }
}
