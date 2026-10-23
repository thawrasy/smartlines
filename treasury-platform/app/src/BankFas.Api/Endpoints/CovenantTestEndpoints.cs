using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using BankFas.Data.Finance;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record TestReviewRequest(string? Note);
public sealed record ManualValueRequest(decimal? Value, Guid? Evidence, string? Note);

/// <summary>
/// The covenant tests of a facility and their results (SCR-OBL-03, R-OBL-02; FR-OBL-011, FR-FIN-012, FR-FIN-013): each
/// test with its period, due date, state, result, actual value, threshold and headroom, and "why this result" from its
/// snapshot (the formula version, the statements, accounts and flows read). A holder of fin.verify.run evaluates a test
/// again (a new row once evaluated) or enters a value by hand with its evidence; obl.record marks an evaluation
/// reviewed with a note. The results need the COVENANTS module (OQ-10).
/// </summary>
public static class CovenantTestEndpoints
{
    private const string Verify = "fin.verify.run";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/facilities/{id:guid}/covenant-tests", ListAsync);
        api.MapGet("/covenant-tests/{id:guid}", GetAsync);
        api.MapPost("/covenant-tests/{id:guid}/actions/evaluate", EvaluateAsync);
        api.MapPost("/covenant-tests/{id:guid}/actions/review", ReviewAsync);
        api.MapPost("/covenant-tests/{id:guid}/actions/manual-value", ManualValueAsync);
        api.MapGet("/reports/statement-breaches", StatementBreachesAsync);
    }

    private static async Task<(BoundUser U, CompanyScope Scope)> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, permission);
        try
        {
            await u.RequireModuleAsync(FinanceAccess.Module, http.RequestAborted);
            return (u, scope);
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }

    internal sealed class Row
    {
        public long CovenantTestId { get; init; }
        public Guid PublicId { get; init; }
        public long CovenantRootId { get; init; }
        public long ObligationRootId { get; init; }
        public string ObligationTitleAr { get; init; } = "";
        public string? ObligationTitleEn { get; init; }
        public string MeasureKind { get; init; } = "";
        public string? FormulaCode { get; init; }
        public string TestFrequency { get; init; } = "";
        public DateTime PeriodStart { get; init; }
        public DateTime PeriodEnd { get; init; }
        public DateTime DueDate { get; init; }
        public int EvaluationNo { get; init; }
        public string State { get; init; } = "";
        public string? Result { get; init; }
        public string Method { get; init; } = "";
        public decimal? ActualValue { get; init; }
        public decimal? ThresholdApplied { get; init; }
        public string? OperatorApplied { get; init; }
        public decimal? Headroom { get; init; }
        public decimal? HeadroomPct { get; init; }
        public string? ThresholdUnit { get; init; }
        public string? InputsSnapshot { get; init; }
        public DateTime? EvaluatedAt { get; init; }
        public string? CancelReason { get; init; }
        public string? ReviewNote { get; init; }
        public long FacilityId { get; init; }
        public Guid FacilityPublicId { get; init; }
        public long BorrowerCompanyId { get; init; }
        public bool IsLatest { get; init; }
    }

    private const string Select = """
        SELECT t.CovenantTestId, t.PublicId, t.CovenantRootId, o.RootId AS ObligationRootId, o.TitleAr AS ObligationTitleAr, o.TitleEn AS ObligationTitleEn, cv.MeasureKind,
               mf.Code AS FormulaCode, cv.TestFrequency, t.PeriodStart, t.PeriodEnd, t.DueDate, t.EvaluationNo, t.State, t.Result, t.Method, t.ActualValue, t.ThresholdApplied,
               t.OperatorApplied, t.Headroom, t.HeadroomPct, cv.ThresholdUnit, t.InputsSnapshot, t.EvaluatedAt, t.CancelReason, t.ReviewNote, f.FacilityId,
               f.PublicId AS FacilityPublicId, f.BorrowerCompanyId,
               CAST(CASE WHEN t.EvaluationNo = (SELECT MAX(x.EvaluationNo) FROM obl.CovenantTest AS x WHERE x.CovenantRootId = t.CovenantRootId AND x.PeriodEnd = t.PeriodEnd)
                         THEN 1 ELSE 0 END AS BIT) AS IsLatest
          FROM obl.CovenantTest AS t
          JOIN obl.Covenant AS cv ON cv.CovenantId = t.CovenantId
          JOIN obl.Obligation AS o ON o.ObligationId = cv.ObligationId
          JOIN fac.Facility AS f ON f.FacilityId = o.FacilityId
          LEFT JOIN fin.MeasureFormula AS mf ON mf.MeasureFormulaId = cv.FormulaId
        """;

    private static object Shape(Row t, OpaqueRefs refs, int tenant, bool snapshot) => new
    {
        id = t.PublicId, obligation = refs.ItemRef(tenant, "obligation", t.ObligationRootId), obligationTitleAr = t.ObligationTitleAr, obligationTitleEn = t.ObligationTitleEn,
        measureKind = t.MeasureKind, formula = t.FormulaCode, testFrequency = t.TestFrequency, periodStart = FacilityEndpoints.D(t.PeriodStart), periodEnd = FacilityEndpoints.D(t.PeriodEnd),
        dueDate = FacilityEndpoints.D(t.DueDate), evaluationNo = t.EvaluationNo, state = t.State, result = t.Result, method = t.Method, actualValue = t.ActualValue,
        threshold = t.ThresholdApplied, @operator = t.OperatorApplied, unit = t.ThresholdUnit, headroom = t.Headroom, headroomPct = t.HeadroomPct, evaluatedAt = t.EvaluatedAt,
        cancelReason = t.CancelReason, reviewNote = t.ReviewNote, isLatest = t.IsLatest,
        inputs = snapshot && t.InputsSnapshot is { } s ? JsonSerializer.Deserialize<JsonElement>(s) : (JsonElement?)null,
    };

    private static async Task<Row> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var t = await u.Connection.QuerySingleOrDefaultAsync<Row>(new CommandDefinition(Select + " WHERE t.PublicId = @id;", new { id }, tx, cancellationToken: ct));
        return t is not null && scope.Allows(t.BorrowerCompanyId) ? t : throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> ListAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "obligation", "all");
        var (u, scope) = await OpenAsync(http, db, ObligationEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var q = http.Request.Query;
        long? root = q["obligation"].Count > 0 ? refs.ItemId(u.TenantId, "obligation", q["obligation"]) ?? throw ApiProblemException.NotFound() : null;
        var rows = (await u.Connection.QueryAsync<Row>(new CommandDefinition(Select + " WHERE f.FacilityId = @f AND (@root IS NULL OR o.RootId = @root) ORDER BY t.PeriodEnd, o.TitleAr, t.EvaluationNo;",
            new { f = f.FacilityId, root }, cancellationToken: ct))).Where(t => q["all"] == "true" || t.IsLatest);
        return Results.Ok(new { items = rows.Select(t => Shape(t, refs, u.TenantId, false)) });
    }

    /// <summary>A test with "why this result": its inputs, and the other evaluations of the same covenant and period.</summary>
    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await OpenAsync(http, db, ObligationEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var t = await FindAsync(u, null, id, scope, ct);
        var history = await u.Connection.QueryAsync<Row>(new CommandDefinition(Select + " WHERE t.CovenantRootId = @r AND t.PeriodEnd = @e ORDER BY t.EvaluationNo;",
            new { r = t.CovenantRootId, e = t.PeriodEnd }, cancellationToken: ct));
        var breach = await u.Connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT TOP (1) PublicId AS id, Status AS status, NeedsReview AS needsReview, CureDeadline AS cureDeadline FROM obl.ObligationBreach
             WHERE CovenantRootId = @r AND TestPeriodEnd = @e ORDER BY ObligationBreachId DESC;
            """, new { r = t.CovenantRootId, e = t.PeriodEnd }, cancellationToken: ct));
        return Results.Ok(new { test = Shape(t, refs, u.TenantId, true), history = history.Select(h => Shape(h, refs, u.TenantId, false)), breach });
    }

    private static async Task<IResult> EvaluateAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await OpenAsync(http, db, Verify);
        await using var _ = u;
        var ct = http.RequestAborted;
        var today = clock.GetUtcNow().UtcDateTime.Date;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await FindAsync(u, tx, id, scope, ct);
        if (t.State == "CANCELLED") throw new ApiProblemException(409, "TEST_STATE", "A cancelled test is not evaluated.");
        if (t.PeriodEnd >= today) throw new ApiProblemException(409, "TEST_STATE", "A test is evaluated once its period has ended.");
        if (!t.IsLatest) throw new ApiProblemException(409, "TEST_STATE", "Evaluate the latest evaluation of the covenant and period.");
        var r = await CovenantEngine.EvaluateAsync(u.Connection, tx, t.CovenantTestId, today, u.UserId, again: true, ct);
        await tx.CommitAsync(ct);
        if (r.TestId is null) return Results.Ok(new { state = "PENDING_DATA" });
        var row = await FindAsync(u, null, r.PublicId!.Value, scope, ct);
        return Results.Ok(new { test = Shape(row, refs, u.TenantId, true) });
    }

    private static async Task<IResult> ReviewAsync(Guid id, TestReviewRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await OpenAsync(http, db, ObligationEndpoints.Record);
        await using var _ = u;
        var ct = http.RequestAborted;
        var note = b.Note?.Trim();
        if (string.IsNullOrEmpty(note) || note.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the review note, at most 1,000 characters.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await FindAsync(u, tx, id, scope, ct);
        if (t.State != "EVALUATED") throw new ApiProblemException(409, "TEST_STATE", "An evaluated test is reviewed, once.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE obl.CovenantTest SET State = 'REVIEWED', ReviewNote = @note, ReviewedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ReviewedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CovenantTestId = @id;
            """, new { note, id = t.CovenantTestId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COVENANT_TEST_REVIEWED", "TREASURY", "obl.CovenantTest", t.CovenantTestId,
            AfterJson: JsonSerializer.Serialize(new { note })), t.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>A value entered by hand with its evidence document, judged on the covenant's threshold (a new evaluation).</summary>
    private static async Task<IResult> ManualValueAsync(Guid id, ManualValueRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await OpenAsync(http, db, Verify);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Value is null || b.Evidence is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the value and the document it comes from.");
        if (b.Note is { Length: > 1000 }) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The note has at most 1,000 characters.");
        var today = clock.GetUtcNow().UtcDateTime.Date;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var t = await FindAsync(u, tx, id, scope, ct);
        if (t.State == "CANCELLED" || t.MeasureKind == "NONE") throw new ApiProblemException(409, "TEST_STATE", "A cancelled or descriptive test takes no value.");
        if (t.PeriodEnd >= today) throw new ApiProblemException(409, "TEST_STATE", "A test is evaluated once its period has ended.");
        if (!t.IsLatest) throw new ApiProblemException(409, "TEST_STATE", "Evaluate the latest evaluation of the covenant and period.");
        var evidence = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT DocumentId FROM doc.Document WHERE PublicId = @e AND Status = 'ACTIVE';", new { e = b.Evidence }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The evidence is an active document on file.");
        var r = await CovenantEngine.ManualValueAsync(u.Connection, tx, t.CovenantTestId, b.Value.Value, evidence, b.Note?.Trim(), today, u.UserId, ct);
        await tx.CommitAsync(ct);
        var row = await FindAsync(u, null, r.PublicId!.Value, scope, ct);
        return Results.Ok(new { test = Shape(row, refs, u.TenantId, true) });
    }

    /// <summary>R-FIN-05 (FR-FIN-017): each breach and early warning the latest evaluation of a covenant on the statements found, with the statement and the breach record.</summary>
    private static async Task<IResult> StatementBreachesAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT co.PublicId AS company, co.NameAr AS companyNameAr, f.PublicId AS facility, r.FacilityNo AS facilityNo, i.Code AS bank, r.ObligationTitleAr AS obligationTitleAr,
                   r.ClauseRef AS clauseRef, r.MeasureKind AS measureKind, r.FormulaCode AS formula, r.FormulaVersionNo AS formulaVersion, t.PublicId AS test,
                   r.PeriodEnd AS periodEnd, r.EvaluationNo AS evaluationNo, r.Result AS result, r.Severity AS severity, r.ActualValue AS actualValue,
                   r.OperatorApplied AS operator, r.ThresholdApplied AS threshold, r.Headroom AS headroom, r.HeadroomPct AS headroomPct, s.PublicId AS statement,
                   r.StatementVersionNo AS statementVersion, r.Basis AS basis, r.Assurance AS assurance, r.StatementSuperseded AS statementSuperseded,
                   b.PublicId AS breach, r.BreachStatus AS breachStatus, r.NeedsReview AS needsReview
              FROM fin.v_StatementBreachReport AS r
              JOIN org.Company AS co ON co.CompanyId = r.CompanyId
              JOIN fac.Facility AS f ON f.FacilityId = r.FacilityId
              JOIN obl.CovenantTest AS t ON t.CovenantTestId = r.CovenantTestId
              JOIN fin.FinancialStatement AS s ON s.FinancialStatementId = r.StatementId
              LEFT JOIN ins.Institution AS i ON i.InstitutionId = r.BankInstitutionId
              LEFT JOIN obl.ObligationBreach AS b ON b.ObligationBreachId = r.ObligationBreachId
             WHERE (@company IS NULL OR co.PublicId = @company) AND (@all = 1 OR r.CompanyId IN @ids)
             ORDER BY r.PeriodEnd DESC, co.NameAr, r.FacilityNo;
            """, new { company, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }
}
