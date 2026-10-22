using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Governance;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The governance conflicts (FR-ACC-018, R-ACC-04, SCR-ACC-06): the open and acknowledged conflicts by company and code,
/// each with its authority and the grant compared. Reading needs sig.view (the auditor reads them, owner default
/// OQ-10); acknowledging, with a written reason, needs sig.conflict.review. A printed report is audited. A conflict is
/// resolved by the comparison itself, never by hand.
/// </summary>
public static class ConflictEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/authority-conflicts", ListAsync);
        api.MapPost("/authority-conflicts/{reference}/actions/acknowledge", AcknowledgeAsync);
    }

    private sealed class Row
    {
        public long AuthorityConflictId { get; init; }
        public string ConflictCode { get; init; } = "";
        public string Status { get; init; } = "";
        public DateTime DetectedOn { get; init; }
        public DateTime? ResolvedOn { get; init; }
        public DateTime? ReviewedOn { get; init; }
        public string? Reason { get; init; }
        public long CompanyId { get; init; }
        public Guid Company { get; init; }
        public string CompanyCode { get; init; } = "";
        public string Institution { get; init; } = "";
        public Guid Signatory { get; init; }
        public string PartyNameAr { get; init; } = "";
        public string? PartyNameEn { get; init; }
        public string Operation { get; init; } = "";
        public string? AccountMask { get; init; }
        public Guid? Grant { get; init; }
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "company", "code", "status", "print");
        await using var u = await BoundUser.OpenAsync(http, db, "sig.view");
        await u.RequireModuleAsync("INSTITUTIONS", http.RequestAborted);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        Guid? company = Guid.TryParse(http.Request.Query["company"], out var c) ? c : null;
        var code = http.Request.Query["code"].ToString() is { Length: > 0 } k ? k.ToUpperInvariant() : null;
        var status = http.Request.Query["status"].ToString().ToUpperInvariant();
        var statuses = status switch { "" => new[] { "OPEN", "ACKNOWLEDGED" }, "ALL" => ["OPEN", "ACKNOWLEDGED", "RESOLVED"], _ => [status] };
        var rows = (await u.Connection.QueryAsync<Row>(new CommandDefinition(
            """
            SELECT x.AuthorityConflictId, x.ConflictCode, x.Status, x.DetectedOn, x.ResolvedOn, x.ReviewedOn, x.Reason, co.CompanyId, co.PublicId AS Company, co.CompanyCode,
                   i.Code AS Institution, s.PublicId AS Signatory, p.NameAr AS PartyNameAr, p.NameEn AS PartyNameEn, o.Code AS Operation, ba.AccountNoMask AS AccountMask,
                   g.PublicId AS [Grant]
              FROM acc.AuthorityConflict AS x JOIN acc.SignatoryAuthority AS a ON a.SignatoryAuthorityId = x.SignatoryAuthorityId
              JOIN acc.Signatory AS s ON s.SignatoryId = a.SignatoryId JOIN ins.Relationship AS r ON r.RelationshipId = a.RelationshipId
              JOIN org.Company AS co ON co.CompanyId = r.CompanyId JOIN ins.Institution AS i ON i.InstitutionId = r.InstitutionId
              JOIN pty.Party AS p ON p.PartyId = s.PartyId JOIN cat.OperationType AS o ON o.OperationTypeId = a.OperationTypeId
              LEFT JOIN acc.BankAccount AS ba ON ba.BankAccountId = a.BankAccountId LEFT JOIN org.AuthorityGrant AS g ON g.AuthorityGrantId = x.AuthorityGrantId
             WHERE x.Status IN @statuses AND (@code IS NULL OR x.ConflictCode = @code) AND (@company IS NULL OR co.PublicId = @company)
               AND (@all = 1 OR co.CompanyId IN @ids)
             ORDER BY co.CompanyCode, x.ConflictCode, x.DetectedOn;
            """, new { statuses, code, company, all = scope.All, ids = scope.SqlIds }, cancellationToken: http.RequestAborted))).ToList();
        if (string.Equals(http.Request.Query["print"], "true", StringComparison.OrdinalIgnoreCase))
            await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("REPORT_PRINTED", "TREASURY", "acc.AuthorityConflict", null,
                AfterJson: JsonSerializer.Serialize(new { report = "R-ACC-04", company, code, rows = rows.Count })), null, http.RequestAborted);
        var review = (await u.PermissionsAsync(http.RequestAborted)).Contains("sig.conflict.review");
        return Results.Ok(new
        {
            canAcknowledge = review,
            items = rows.Select(r => new
            {
                id = refs.ItemRef(u.TenantId, "authority-conflict", r.AuthorityConflictId), code = r.ConflictCode,
                label = GovernanceComparer.Labels.TryGetValue(r.ConflictCode, out var l) ? new { ar = l.Ar, en = l.En } : null,
                status = r.Status, detectedOn = r.DetectedOn, resolvedOn = r.ResolvedOn, reviewedOn = r.ReviewedOn, reason = r.Reason,
                company = new { id = r.Company, code = r.CompanyCode }, institution = r.Institution,
                signatory = new { id = r.Signatory, nameAr = r.PartyNameAr, nameEn = r.PartyNameEn }, operation = r.Operation, account = r.AccountMask, grant = r.Grant,
            }),
        });
    }

    private sealed record AckRequest(string? Reason);

    private static async Task<IResult> AcknowledgeAsync(string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var b = await http.Request.ReadFromJsonAsync<AckRequest>(http.RequestAborted) ?? new AckRequest(null);
        if (string.IsNullOrWhiteSpace(b.Reason) || b.Reason.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason of the decision.");
        await using var u = await BoundUser.OpenAsync(http, db, "sig.conflict.review");
        await u.RequireModuleAsync("INSTITUTIONS", http.RequestAborted);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var id = refs.ItemId(u.TenantId, "authority-conflict", reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var x = await u.Connection.QuerySingleOrDefaultAsync<(string Status, long CompanyId)>(new CommandDefinition(
            """
            SELECT x.Status, r.CompanyId FROM acc.AuthorityConflict AS x JOIN acc.SignatoryAuthority AS a ON a.SignatoryAuthorityId = x.SignatoryAuthorityId
              JOIN ins.Relationship AS r ON r.RelationshipId = a.RelationshipId WHERE x.AuthorityConflictId = @id;
            """, new { id }, tx, cancellationToken: http.RequestAborted));
        if (x.Status is null || !scope.Allows(x.CompanyId)) throw ApiProblemException.NotFound();
        if (x.Status != "OPEN") throw new ApiProblemException(409, "V-ACC-CONFLICT-STATE", "Only an open conflict is acknowledged.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE acc.AuthorityConflict SET Status = 'ACKNOWLEDGED', Reason = @r, ReviewedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ReviewedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE AuthorityConflictId = @id;
            """, new { id, r = b.Reason.Trim() }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("AUTHORITY_CONFLICT_ACKNOWLEDGED", "TREASURY", "acc.AuthorityConflict", id,
            AfterJson: JsonSerializer.Serialize(new { reason = b.Reason.Trim() }), Severity: "HIGH"), x.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }
}
