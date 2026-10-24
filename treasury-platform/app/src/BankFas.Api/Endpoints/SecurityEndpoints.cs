using System.Globalization;
using System.Net;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record IpBlockRequest(string? ClientIp, string? Reason, int? Hours, string? MfaCode);
public sealed record IncidentRequest(string? Title, string? Severity, string? DetectedAt, string? Description, string? ClientIps, string? MfaCode);
public sealed record IncidentChange(string? Status, string? RootCause, string? Actions, string? ClientIps, string? MfaCode);
public sealed record PlatformMfaRequest(bool? Required, string? MfaCode);

/// <summary>
/// The security page of the operator panel (docs/31 row 48, ADR 0047): the guard's settings, the blocked addresses and
/// the latest security events, a manual block and its lift, and the incident register (DOC-S15). Reading is open to
/// every operator; a block, a lift and an incident need an OPERATOR_ADMIN and a fresh code, and each is recorded in the
/// platform log under SECURITY.
/// </summary>
public static class SecurityEndpoints
{
    private static readonly string[] Severities = ["LOW", "MEDIUM", "HIGH", "CRITICAL"];
    private static readonly string[] Statuses = ["OPEN", "CONTAINED", "RESOLVED", "CLOSED"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/security/overview", OverviewAsync);
        api.MapPost("/security/blocks", BlockAsync);
        api.MapPost("/security/blocks/{id:guid}/actions/lift", LiftAsync);
        api.MapGet("/security/incidents", IncidentsAsync);
        api.MapPost("/security/incidents", OpenIncidentAsync);
        api.MapPatch("/security/incidents/{id:guid}", ChangeIncidentAsync);
        api.MapPut("/security/mfa", PlatformMfaAsync);
    }

    private static Task<int> WriteSecurityAuditAsync(SqlConnection c, SqlTransaction tx, int operatorId, string action, string entityType, long id, object after, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId, AfterJson, Result)
            SELECT NULL, SYSUTCDATETIME(), 'OPERATOR', PublicId, @action, 'SECURITY', 'HIGH', @type, @id, @after, 'SUCCESS'
            FROM plat.PlatformOperator WHERE PlatformOperatorId = @op;
            """, new { action, type = entityType, id, after = JsonSerializer.Serialize(after), op = operatorId }, tx, cancellationToken: ct));

    private static async Task<IResult> OverviewAsync(HttpContext http, SqlConnectionFactory db, SecurityGuard guard, TimeProvider clock)
    {
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            var blocks = await c.QueryAsync(new CommandDefinition(
                """
                SELECT TOP (200) b.PublicId AS id, b.ClientIp AS clientIp, b.Source AS source, b.Reason AS reason, b.BlockedAt AS blockedAt,
                       b.BlockedUntil AS blockedUntil, o.Email AS blockedBy
                FROM plat.IpBlock AS b LEFT JOIN plat.PlatformOperator AS o ON o.PlatformOperatorId = b.BlockedBy
                WHERE b.LiftedAt IS NULL AND (b.BlockedUntil IS NULL OR b.BlockedUntil > @now)
                ORDER BY b.BlockedAt DESC;
                """, new { now = clock.GetUtcNow().UtcDateTime }, cancellationToken: http.RequestAborted));
            var events = await c.QueryAsync(new CommandDefinition(
                """
                SELECT TOP (100) OccurredAt AS occurredAt, ActorType AS actorType, Action AS action, Severity AS severity, EntityType AS entityType,
                       IpAddress AS ipAddress, Result AS result, AfterJson AS detail
                FROM aud.AuditLog WHERE TenantId IS NULL AND Category = 'SECURITY'
                ORDER BY OccurredAt DESC;
                """, cancellationToken: http.RequestAborted));
            var counts = await c.QuerySingleAsync(new CommandDefinition(
                """
                SELECT (SELECT COUNT(*) FROM plat.IpBlock WHERE Source = 'AUTO' AND BlockedAt > DATEADD(DAY, -1, @now)) AS autoBlocks24h,
                       (SELECT COUNT(*) FROM plat.SecurityIncident WHERE Status <> 'CLOSED') AS openIncidents;
                """, new { now = clock.GetUtcNow().UtcDateTime }, cancellationToken: http.RequestAborted));
            var o = guard.Options;
            var mfa = await c.ExecuteScalarAsync<string?>(new CommandDefinition(
                "SELECT DefaultValueJson FROM cfg.SettingDefinition WHERE [Key] = 'security.mfa.required';", cancellationToken: http.RequestAborted));
            var tenantsMfa = await c.QueryAsync(new CommandDefinition(
                "SELECT MfaPolicy AS policy, COUNT(*) AS tenants FROM plat.Tenant GROUP BY MfaPolicy;", cancellationToken: http.RequestAborted));
            return Results.Ok(new
            {
                mfa = new { platformRequired = mfa?.Trim() != "false", tenants = tenantsMfa },
                settings = new
                {
                    guardEnabled = o.GuardEnabled, apiPerMinute = o.ApiPerMinute, refusalLimit = o.RefusalLimit, refusalWindowSeconds = o.RefusalWindowSeconds,
                    blockMinutes = o.BlockMinutes, trustedProxies = o.TrustedProxies, alertRecipients = o.AlertEmails.Length,
                },
                counts, blocks, events,
            });
        }
    }

    private static async Task<IResult> BlockAsync(IpBlockRequest b, HttpContext http, SqlConnectionFactory db, SecurityGuard guard, IKeyWrapper keys, TimeProvider clock)
    {
        if (!IPAddress.TryParse(b.ClientIp?.Trim(), out var address)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter an IPv4 or IPv6 address.");
        if (address.IsIPv4MappedToIPv6) address = address.MapToIPv4();
        if (guard.Key(address) is null)
            throw new ApiProblemException(409, "V-SEC-TRUSTED", "This address is loopback or a trusted proxy; blocking it would shut every user out.");
        if (string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for the block.");
        if (b.Hours is < 1 or > 24 * 365) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The block lasts from 1 hour to a year, or until lifted.");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await OperatorEndpoints.StepUpAsync(c, b.MfaCode, keys, clock, http);
            var ip = address.ToString();
            var now = clock.GetUtcNow().UtcDateTime;
            DateTime? until = b.Hours is { } h ? now.AddHours(h) : null;
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(http.RequestAborted);
            var row = await c.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
                """
                INSERT plat.IpBlock (ClientIp, Source, Reason, BlockedAt, BlockedUntil, BlockedBy)
                OUTPUT inserted.IpBlockId, inserted.PublicId
                VALUES (@ip, 'MANUAL', @reason, @now, @until, @op);
                """, new { ip, reason = b.Reason.Trim(), now, until, op = s.OperatorId }, tx, cancellationToken: http.RequestAborted));
            await WriteSecurityAuditAsync(c, tx, s.OperatorId, "IP_BLOCKED", "plat.IpBlock", row.Id, new { source = "MANUAL", clientIp = ip, until }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            await guard.ReloadAsync(http.RequestAborted);
            return Results.Created($"/api/v1/operator/security/blocks/{row.PublicId}", new { id = row.PublicId, clientIp = ip, blockedUntil = until });
        }
    }

    private static async Task<IResult> LiftAsync(Guid id, OperatorActionRequest b, HttpContext http, SqlConnectionFactory db, SecurityGuard guard, IKeyWrapper keys, TimeProvider clock)
    {
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await OperatorEndpoints.StepUpAsync(c, b.MfaCode, keys, clock, http);
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(http.RequestAborted);
            var row = await c.QuerySingleOrDefaultAsync<(long Id, string Ip)?>(new CommandDefinition(
                """
                UPDATE plat.IpBlock SET LiftedAt = CASE WHEN @now > BlockedAt THEN @now ELSE BlockedAt END, LiftedBy = @op, UpdatedAt = SYSUTCDATETIME()
                OUTPUT inserted.IpBlockId, inserted.ClientIp
                WHERE PublicId = @id AND LiftedAt IS NULL;
                """, new { id, op = s.OperatorId, now = clock.GetUtcNow().UtcDateTime }, tx, cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
            await WriteSecurityAuditAsync(c, tx, s.OperatorId, "IP_BLOCK_LIFTED", "plat.IpBlock", row.Id, new { clientIp = row.Ip }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            await guard.ReloadAsync(http.RequestAborted);
            return Results.NoContent();
        }
    }

    /// <summary>
    /// The platform default of two-step verification for tenant users (security.mfa.required, ADR 0048): off for the
    /// trial, on for the public launch. A tenant's own policy overrides it (OperatorAdminEndpoints). Admin, fresh code.
    /// </summary>
    private static async Task<IResult> PlatformMfaAsync(PlatformMfaRequest b, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock)
    {
        if (b.Required is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Say whether two-step verification is required.");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await OperatorEndpoints.StepUpAsync(c, b.MfaCode, keys, clock, http);
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(http.RequestAborted);
            var changed = await c.ExecuteAsync(new CommandDefinition(
                "UPDATE cfg.SettingDefinition SET DefaultValueJson = @v, UpdatedAt = SYSUTCDATETIME() WHERE [Key] = 'security.mfa.required';",
                new { v = b.Required.Value ? "true" : "false" }, tx, cancellationToken: http.RequestAborted));
            if (changed == 0) throw new ApiProblemException(409, "NOT_READY", "The setting is not installed; run the platform seed.");
            await WriteSecurityAuditAsync(c, tx, s.OperatorId, "PLATFORM_MFA_CHANGED", "cfg.SettingDefinition", 0, new { required = b.Required.Value }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.NoContent();
        }
    }

    private static async Task<IResult> IncidentsAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            var rows = await c.QueryAsync(new CommandDefinition(
                """
                SELECT TOP (500) i.PublicId AS id, i.IncidentNo AS incidentNo, i.Title AS title, i.Severity AS severity, i.Status AS status,
                       i.DetectedAt AS detectedAt, i.Description AS description, i.RootCause AS rootCause, i.Actions AS actions, i.ClientIps AS clientIps,
                       o.Email AS openedBy, i.ClosedAt AS closedAt, x.Email AS closedBy
                FROM plat.SecurityIncident AS i JOIN plat.PlatformOperator AS o ON o.PlatformOperatorId = i.OpenedBy
                LEFT JOIN plat.PlatformOperator AS x ON x.PlatformOperatorId = i.ClosedBy
                ORDER BY i.DetectedAt DESC, i.SecurityIncidentId DESC;
                """, cancellationToken: http.RequestAborted));
            return Results.Ok(new { items = rows });
        }
    }

    private static async Task<IResult> OpenIncidentAsync(IncidentRequest b, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock)
    {
        if (string.IsNullOrWhiteSpace(b.Title) || string.IsNullOrWhiteSpace(b.Description)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the title and what was seen.");
        if (!Severities.Contains(b.Severity)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a severity.");
        var now = clock.GetUtcNow().UtcDateTime;
        var detected = now;
        if (!string.IsNullOrWhiteSpace(b.DetectedAt)
            && (!DateTime.TryParse(b.DetectedAt, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out detected) || detected > now.AddMinutes(5)))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The detection time is not a past date and time.");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await OperatorEndpoints.StepUpAsync(c, b.MfaCode, keys, clock, http);
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, http.RequestAborted);
            // Numbered INC-YYYY-NNN by the year of detection; the serializable read keeps two operators from taking one number.
            var year = detected.Year;
            var last = await c.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT MAX(CAST(RIGHT(IncidentNo, LEN(IncidentNo) - 9) AS INT)) FROM plat.SecurityIncident WITH (UPDLOCK, HOLDLOCK) WHERE IncidentNo LIKE @p;",
                new { p = $"INC-{year}-%" }, tx, cancellationToken: http.RequestAborted)) ?? 0;
            var no = $"INC-{year}-{last + 1:000}";
            var row = await c.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
                """
                INSERT plat.SecurityIncident (IncidentNo, Title, Severity, Status, DetectedAt, Description, ClientIps, OpenedBy)
                OUTPUT inserted.SecurityIncidentId, inserted.PublicId
                VALUES (@no, @title, @sev, 'OPEN', @detected, @desc, @ips, @op);
                """, new { no, title = b.Title.Trim(), sev = b.Severity, detected, desc = b.Description.Trim(), ips = NullIfBlank(b.ClientIps), op = s.OperatorId },
                tx, cancellationToken: http.RequestAborted));
            await WriteSecurityAuditAsync(c, tx, s.OperatorId, "INCIDENT_OPENED", "plat.SecurityIncident", row.Id, new { incidentNo = no, severity = b.Severity }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.Created($"/api/v1/operator/security/incidents/{row.PublicId}", new { id = row.PublicId, incidentNo = no, status = "OPEN" });
        }
    }

    private static async Task<IResult> ChangeIncidentAsync(Guid id, IncidentChange b, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock)
    {
        if (b.Status is not null && !Statuses.Contains(b.Status)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a status.");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await OperatorEndpoints.StepUpAsync(c, b.MfaCode, keys, clock, http);
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(http.RequestAborted);
            var cur = await c.QuerySingleOrDefaultAsync<(long Id, string No, string Status, string? RootCause)?>(new CommandDefinition(
                "SELECT SecurityIncidentId, IncidentNo, Status, RootCause FROM plat.SecurityIncident WITH (UPDLOCK) WHERE PublicId = @id;",
                new { id }, tx, cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
            if (cur.Status == "CLOSED") throw new ApiProblemException(409, "V-SEC-INC-CLOSED", "A closed incident is not changed; open a new one.");
            var status = b.Status ?? cur.Status;
            var rootCause = NullIfBlank(b.RootCause) ?? cur.RootCause;
            if (status == "CLOSED" && rootCause is null)
                throw ApiProblemException.Invalid("V-SEC-INC-ROOT", "An incident is closed with its root cause and the corrective actions (DOC-S15 step 12).");
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE plat.SecurityIncident
                SET Status = @status, RootCause = @rootCause, Actions = COALESCE(@actions, Actions), ClientIps = COALESCE(@ips, ClientIps),
                    ClosedAt = CASE WHEN @status = 'CLOSED' THEN SYSUTCDATETIME() END, ClosedBy = CASE WHEN @status = 'CLOSED' THEN @op END,
                    UpdatedAt = SYSUTCDATETIME()
                WHERE SecurityIncidentId = @id;
                """, new { status, rootCause, actions = NullIfBlank(b.Actions), ips = NullIfBlank(b.ClientIps), op = s.OperatorId, id = cur.Id },
                tx, cancellationToken: http.RequestAborted));
            await WriteSecurityAuditAsync(c, tx, s.OperatorId, "INCIDENT_CHANGED", "plat.SecurityIncident", cur.Id, new { incidentNo = cur.No, from = cur.Status, to = status }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.Ok(new { id, incidentNo = cur.No, status });
        }
    }

    private static string? NullIfBlank(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();
}
