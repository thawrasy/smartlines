using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;

namespace BankFas.Api.Endpoints;

public sealed record GrantRequest(Guid? OperatorId, int? Hours, string? Reason);

/// <summary>
/// Temporary support access granted by the tenant (SCR-PLT-11, FR-PLT-007, BR-PLT-017, AC-PLT-8), with
/// sec.support.grant: the tenant administrator picks an active operator (sec.usp_ListSupportOperators, GAP-5a), a
/// window of 1 to 72 hours (4 by default) and a reason; revoking is final. Both are audited HIGH. Every page the
/// operator then opens is in the tenant's own log (sec.usp_WriteSupportPageView, GAP-6).
/// </summary>
public static class SupportEndpoints
{
    private const string Grant = "sec.support.grant";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/support-operators", OperatorsAsync);
        api.MapGet("/support-grants", ListAsync);
        api.MapPost("/support-grants", CreateAsync);
        api.MapPost("/support-grants/{reference}/actions/revoke", RevokeAsync);
    }

    private sealed record OperatorRow(int OperatorId, Guid PublicId, string? DisplayName, string Role);

    private static async Task<List<OperatorRow>> OperatorRowsAsync(BoundUser u, CancellationToken ct) =>
        [.. await u.Connection.QueryAsync<OperatorRow>(new CommandDefinition("sec.usp_ListSupportOperators", new { TenantId = u.TenantId },
            commandType: System.Data.CommandType.StoredProcedure, cancellationToken: ct))];

    private static async Task<IResult> OperatorsAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Grant);
        var rows = await OperatorRowsAsync(u, http.RequestAborted);
        return Results.Ok(new { items = rows.Select(o => new { id = o.PublicId, displayName = o.DisplayName, role = o.Role }) });
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Grant);
        var operators = (await OperatorRowsAsync(u, http.RequestAborted)).ToDictionary(o => o.OperatorId);
        var rows = await u.Connection.QueryAsync<(long Id, int OperatorId, DateTime StartsAt, DateTime EndsAt, string Reason, DateTime? RevokedAt, DateTime CreatedAt)>(
            new CommandDefinition(
                "SELECT SupportAccessGrantId, OperatorId, StartsAt, EndsAt, Reason, RevokedAt, CreatedAt FROM plat.SupportAccessGrant ORDER BY SupportAccessGrantId DESC;",
                cancellationToken: http.RequestAborted));
        var now = DateTime.UtcNow;
        return Results.Ok(new
        {
            items = rows.Select(g => new
            {
                id = refs.Cursor("grant", g.Id),
                operatorId = operators.TryGetValue(g.OperatorId, out var o) ? o.PublicId : (Guid?)null,
                operatorName = operators.TryGetValue(g.OperatorId, out var o2) ? o2.DisplayName : null,
                startsAt = g.StartsAt, endsAt = g.EndsAt, reason = g.Reason, revokedAt = g.RevokedAt,
                status = g.RevokedAt is not null ? "REVOKED" : g.EndsAt <= now ? "ENDED" : g.StartsAt > now ? "SCHEDULED" : "ACTIVE",
            }),
        });
    }

    private static async Task<IResult> CreateAsync(GrantRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var hours = body.Hours ?? 4;
        if (body.OperatorId is null || hours is < 1 or > 72 || string.IsNullOrWhiteSpace(body.Reason) || body.Reason.Length > 500)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose an operator, 1 to 72 hours and a reason.");
        await using var u = await BoundUser.OpenAsync(http, db, Grant);
        var op = (await OperatorRowsAsync(u, http.RequestAborted)).FirstOrDefault(o => o.PublicId == body.OperatorId)
                 ?? throw ApiProblemException.Invalid("REFERENCE_INVALID", "The operator is not available for support.");
        var id = await u.Connection.QuerySingleAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            DECLARE @now DATETIME2(3) = SYSUTCDATETIME();
            INSERT plat.SupportAccessGrant (TenantId, OperatorId, GrantedBy, StartsAt, EndsAt, Reason)
            OUTPUT inserted.SupportAccessGrantId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @op, @by, @now, DATEADD(HOUR, @hours, @now), @reason);
            SELECT Id FROM @o;
            """, new { op = op.OperatorId, by = u.UserId, hours, reason = body.Reason.Trim() }, cancellationToken: http.RequestAborted));
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("SUPPORT_ACCESS_GRANTED", "SECURITY", "plat.SupportAccessGrant", id,
            AfterJson: JsonSerializer.Serialize(new { @operator = op.PublicId, hours, reason = body.Reason.Trim() }), Severity: "HIGH"), http.RequestAborted);
        return Results.Created("/api/v1/support-grants", new { id = refs.Cursor("grant", id), hours });
    }

    private static async Task<IResult> RevokeAsync(string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var id = refs.AfterId("grant", reference) ?? throw ApiProblemException.NotFound();
        await using var u = await BoundUser.OpenAsync(http, db, Grant);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE plat.SupportAccessGrant SET RevokedAt = SYSUTCDATETIME(), RevokedBy = @by WHERE SupportAccessGrantId = @id AND RevokedAt IS NULL;",
            new { by = u.UserId, id }, cancellationToken: http.RequestAborted));
        if (n == 0) throw new ApiProblemException(409, "STATE_CONFLICT", "The grant is already revoked, or it does not exist.");
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("SUPPORT_ACCESS_REVOKED", "SECURITY", "plat.SupportAccessGrant", id,
            Severity: "HIGH"), http.RequestAborted);
        return Results.NoContent();
    }
}
