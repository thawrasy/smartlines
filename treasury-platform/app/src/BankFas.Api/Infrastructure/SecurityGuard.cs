using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using BankFas.Core.Mail;
using BankFas.Data;
using Dapper;
using Microsoft.Extensions.Options;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// The settings of the network guard (docs/31 row 48, ADR 0047), from the platform's configuration (section Security).
/// TrustedProxies are the reverse proxies (Caddy on the host, and an edge if one is added): only they may name the
/// client in X-Forwarded-For, and they are never limited or blocked, so a wrong setting cannot shut every user out.
/// </summary>
public sealed class SecurityOptions
{
    public string[] TrustedProxies { get; set; } = ["127.0.0.1", "::1"];
    public bool GuardEnabled { get; set; } = true;
    /// <summary>Requests a minute from one client address to the API.</summary>
    public int ApiPerMinute { get; set; } = 600;
    /// <summary>Refusals (401, 403, 429) from one address within RefusalWindowSeconds that block it.</summary>
    public int RefusalLimit { get; set; } = 40;
    public int RefusalWindowSeconds { get; set; } = 300;
    public int BlockMinutes { get; set; } = 30;
    /// <summary>Addresses told of each automatic block, besides the warning in the log.</summary>
    public string[] AlertEmails { get; set; } = [];
}

/// <summary>
/// Counts the refusals of each client address and blocks an address that passes the limit for BlockMinutes (plat.IpBlock,
/// with a HIGH platform event in aud.AuditLog). The active blocks, the automatic and the operators', are kept in memory
/// and read again from the database every 30 seconds, so an operator's block or lift applies within that time. An
/// address unknown, of a trusted proxy or loopback is never counted or blocked.
/// </summary>
public sealed partial class SecurityGuard(SqlConnectionFactory db, IOptions<SecurityOptions> options, TimeProvider clock, IMailSender mail, ILogger<SecurityGuard> log) : IDisposable
{
    private readonly ConcurrentDictionary<string, Queue<DateTime>> _refusals = new(StringComparer.Ordinal);
    private volatile Dictionary<string, DateTime?> _blocks = new(StringComparer.Ordinal);
    private DateTime _loadedAt = DateTime.MinValue;
    private readonly SemaphoreSlim _load = new(1, 1);
    private HashSet<IPAddress>? _trusted;

    public SecurityOptions Options => options.Value;

    public HashSet<IPAddress> Trusted => _trusted ??= [.. options.Value.TrustedProxies.Select(p => IPAddress.TryParse(p.Trim(), out var a) ? a : null).OfType<IPAddress>()];

    /// <summary>The address the guard keys on, or null when it is not to be guarded.</summary>
    public string? Key(IPAddress? address)
    {
        if (address is null) return null;
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (IPAddress.IsLoopback(address) || Trusted.Contains(address)) return null;
        return address.ToString();
    }

    public async Task<bool> IsBlockedAsync(string ip, CancellationToken ct)
    {
        var now = clock.GetUtcNow().UtcDateTime;
        if (now - _loadedAt > TimeSpan.FromSeconds(30)) await ReloadAsync(ct, force: false);
        return _blocks.TryGetValue(ip, out var until) && (until is null || until > now);
    }

    public void Dispose() => _load.Dispose();

    /// <summary>Reads the active blocks again; without force, a read another request has just made is enough.</summary>
    public async Task ReloadAsync(CancellationToken ct, bool force = true)
    {
        await _load.WaitAsync(ct);
        try
        {
            if (!force && clock.GetUtcNow().UtcDateTime - _loadedAt <= TimeSpan.FromSeconds(30)) return;
            await using var c = await db.OpenAsync(DbLogin.Platform, ct);
            var rows = await c.QueryAsync<(string Ip, DateTime? Until)>(new CommandDefinition(
                "SELECT ClientIp, BlockedUntil FROM plat.IpBlock WHERE LiftedAt IS NULL AND (BlockedUntil IS NULL OR BlockedUntil > @now);",
                new { now = clock.GetUtcNow().UtcDateTime }, cancellationToken: ct));
            var map = new Dictionary<string, DateTime?>(StringComparer.Ordinal);
            foreach (var (ip, until) in rows) map[ip] = map.TryGetValue(ip, out var u) && (u is null || (until is not null && u > until)) ? u : until;
            _blocks = map;
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The last list stays in force; the next read is tried after the same 30 seconds, not on every request.
            LogReloadFailed(log, ex);
        }
        finally
        {
            _loadedAt = clock.GetUtcNow().UtcDateTime;
            _load.Release();
        }
    }

    /// <summary>A refusal answered to the address; past the limit within the window, the address is blocked.</summary>
    public async Task RefusedAsync(string ip, string path, CancellationToken ct)
    {
        var o = options.Value;
        if (!o.GuardEnabled) return;
        var now = clock.GetUtcNow().UtcDateTime;
        var q = _refusals.GetOrAdd(ip, _ => new Queue<DateTime>());
        int count;
        lock (q)
        {
            q.Enqueue(now);
            while (q.Count > 0 && now - q.Peek() > TimeSpan.FromSeconds(o.RefusalWindowSeconds)) q.Dequeue();
            count = q.Count;
            if (count > o.RefusalLimit) q.Clear();
        }
        if (count <= o.RefusalLimit || await IsBlockedAsync(ip, ct)) return;
        var until = now.AddMinutes(o.BlockMinutes);
        var reason = $"{count} refusals within {o.RefusalWindowSeconds} seconds; the last on {path}";
        await using (var c = await db.OpenAsync(DbLogin.Platform, ct))
        {
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT plat.IpBlock (ClientIp, Source, Reason, BlockedAt, BlockedUntil) VALUES (@ip, 'AUTO', @reason, @now, @until);
                INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, Action, Category, Severity, EntityType, AfterJson, IpAddress, Result)
                VALUES (NULL, SYSUTCDATETIME(), 'SYSTEM', 'IP_BLOCKED', 'SECURITY', 'HIGH', 'plat.IpBlock', @after, @ip, 'DENIED');
                """, new { ip, reason, now, until, after = JsonSerializer.Serialize(new { source = "AUTO", reason, until }) }, cancellationToken: ct));
        }
        var map = new Dictionary<string, DateTime?>(_blocks, StringComparer.Ordinal) { [ip] = until };
        _blocks = map;
        LogBlocked(log, ip, count, path);
        foreach (var to in o.AlertEmails.Where(e => !string.IsNullOrWhiteSpace(e)))
        {
            try
            {
                await mail.SendAsync(new OutgoingMail(to.Trim(), "BankFas security: an address was blocked",
                    $"The address {ip} was blocked until {until:yyyy-MM-dd HH:mm} UTC: {reason}. The operator panel lists it under Security."), ct);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                LogAlertFailed(log, ex, to);
            }
        }
    }

    [LoggerMessage(EventId = 4801, Level = LogLevel.Warning, Message = "SECURITY IP_BLOCKED {Ip} after {Count} refusals; last path {Path}")]
    private static partial void LogBlocked(ILogger logger, string ip, int count, string path);

    [LoggerMessage(EventId = 4803, Level = LogLevel.Error, Message = "SECURITY the block list could not be read")]
    private static partial void LogReloadFailed(ILogger logger, Exception ex);

    [LoggerMessage(EventId = 4802, Level = LogLevel.Error, Message = "SECURITY alert e-mail to {To} failed")]
    private static partial void LogAlertFailed(ILogger logger, Exception ex, string to);
}

/// <summary>
/// Placed outside the problem middleware so it sees the final status: a blocked address gets 403 IP_BLOCKED before
/// anything else runs, and each 401, 403 or 429 the platform answers is counted against the address.
/// </summary>
public sealed partial class SecurityGuardMiddleware(RequestDelegate next, SecurityGuard guard, ILogger<SecurityGuardMiddleware> logger)
{
    public async Task InvokeAsync(HttpContext context)
    {
        var ip = guard.Options.GuardEnabled ? guard.Key(context.Connection.RemoteIpAddress) : null;
        if (ip is not null && await guard.IsBlockedAsync(ip, context.RequestAborted))
        {
            await ProblemMiddleware.WriteAsync(context, 403, "IP_BLOCKED", "This address is blocked for a while after repeated refused requests.");
            return;
        }
        await next(context);
        if (ip is null || context.Response.StatusCode is not (401 or 403 or 429)) return;
        try
        {
            await guard.RefusedAsync(ip, context.Request.Path.Value ?? "", context.RequestAborted);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // The refusal is already answered; a failed block must not turn it into a 500.
            LogBlockFailed(logger, ex, ip);
        }
    }

    [LoggerMessage(EventId = 4804, Level = LogLevel.Error, Message = "SECURITY the block of {Ip} could not be recorded")]
    private static partial void LogBlockFailed(ILogger logger, Exception ex, string ip);
}
