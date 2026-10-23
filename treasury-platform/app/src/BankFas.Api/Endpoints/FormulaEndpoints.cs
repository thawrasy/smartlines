using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Finance;
using BankFas.Data;
using BankFas.Data.Finance;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record FormulaRequest(string? Code, string? NameAr, string? NameEn, string? Scope, string? Expression, string? ResultUnit, string? DefinitionNote);
public sealed record FormulaCheckRequest(string? Expression, Guid? Statement);
public sealed record FormulaCopyRequest(Guid? Facility);

/// <summary>
/// The formula library (spec 12 FR-FIN-011, FR-FIN-016; BR-FIN-009, BR-FIN-014; S2-b brief S2B-GAP-2, 10, 26 and OQ-3).
/// A formula is a tree of the BR-FIN-009 grammar, checked at save (known codes, depth, no division by a constant
/// zero) and never executed as text; its input kinds come from the codes it reads. A draft is approved by a holder of
/// fin.formula.approve who neither created nor last edited it; the approved version of the same code and facility is
/// superseded first, and an approved version is fixed (063). A change is a new version that keeps the result unit and
/// whether it reads statements, because a covenant copies both (DR-38). A template that an approved covenant uses is
/// not versioned: it is copied to the facility and the covenant repointed in a revision (OQ-3). The analysis measures
/// are computed on an approved statement into fin.StatementRatio with the inputs they read.
/// </summary>
public static class FormulaEndpoints
{
    private const string Manage = "fin.formula.manage";
    private const string ApproveFormula = "fin.formula.approve";
    private const string Verify = "fin.verify.run";
    private static readonly string[] Units = ["RATIO", "AMOUNT", "PERCENT", "DAYS"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/formulas", ListAsync);
        api.MapGet("/formulas/{id}", GetAsync);
        api.MapPost("/formulas", CreateAsync);
        api.MapPatch("/formulas/{id}", ChangeAsync);
        api.MapPost("/formulas/actions/validate", ValidateAsync);
        api.MapPost("/formulas/{id}/actions/new-version", NewVersionAsync);
        api.MapPost("/formulas/{id}/actions/approve", ApproveAsync);
        api.MapPost("/formulas/{id}/actions/copy", CopyAsync);
        api.MapGet("/financial-statements/{id:guid}/ratios", RatiosAsync);
        api.MapPost("/financial-statements/{id:guid}/ratios/actions/compute", ComputeAsync);
    }

    internal sealed class Row
    {
        public long MeasureFormulaId { get; init; }
        public string Code { get; init; } = "";
        public string NameAr { get; init; } = "";
        public string? NameEn { get; init; }
        public string Scope { get; init; } = "";
        public long? FacilityId { get; init; }
        public Guid? FacilityPublicId { get; init; }
        public string? FacilityNo { get; init; }
        public long? BorrowerCompanyId { get; init; }
        public long? BaseTemplateId { get; init; }
        public string? BaseTemplateCode { get; init; }
        public string Expression { get; init; } = "";
        public string InputKinds { get; init; } = "";
        public string ResultUnit { get; init; } = "";
        public bool UsesStatements { get; init; }
        public string? DefinitionNote { get; init; }
        public int VersionNo { get; init; }
        public string Status { get; init; } = "";
        public DateTime? ApprovedOn { get; init; }
        public long? CreatedBy { get; init; }
        public long? UpdatedBy { get; init; }
    }

    private const string Select = """
        SELECT m.MeasureFormulaId, m.Code, m.NameAr, m.NameEn, m.Scope, m.FacilityId, f.PublicId AS FacilityPublicId, f.FacilityNo, f.BorrowerCompanyId,
               m.BaseTemplateId, b.Code AS BaseTemplateCode, m.Expression, m.InputKinds, m.ResultUnit, m.UsesStatements, m.DefinitionNote, m.VersionNo, m.Status,
               m.ApprovedOn, m.CreatedBy, m.UpdatedBy
          FROM fin.MeasureFormula AS m
          LEFT JOIN fac.Facility AS f ON f.FacilityId = m.FacilityId
          LEFT JOIN fin.MeasureFormula AS b ON b.MeasureFormulaId = m.BaseTemplateId
        """;

    internal const string RefKind = "formula";

    private static object Shape(Row m, long me, OpaqueRefs refs, int tenant) => new
    {
        id = refs.ItemRef(tenant, RefKind, m.MeasureFormulaId), code = m.Code, nameAr = m.NameAr, nameEn = m.NameEn, scope = m.Scope,
        facility = m.FacilityPublicId is null ? null : new { id = m.FacilityPublicId, facilityNo = m.FacilityNo }, baseTemplate = m.BaseTemplateCode,
        expression = m.Expression, inputKinds = m.InputKinds.Split(',', StringSplitOptions.RemoveEmptyEntries), resultUnit = m.ResultUnit, definitionNote = m.DefinitionNote,
        versionNo = m.VersionNo, status = m.Status, approvedOn = m.ApprovedOn, preparedByMe = m.CreatedBy == me || m.UpdatedBy == me,
    };

    private static async Task<Row> FindAsync(BoundUser u, SqlTransaction? tx, string reference, OpaqueRefs refs, CompanyScope scope, CancellationToken ct, bool lockRow = false)
    {
        var id = refs.ItemId(u.TenantId, RefKind, reference) ?? throw ApiProblemException.NotFound();
        var m = await u.Connection.QuerySingleOrDefaultAsync<Row>(new CommandDefinition(
            Select.Replace("FROM fin.MeasureFormula AS m", lockRow ? "FROM fin.MeasureFormula AS m WITH (UPDLOCK, HOLDLOCK)" : "FROM fin.MeasureFormula AS m", StringComparison.Ordinal)
            + " WHERE m.MeasureFormulaId = @id;", new { id }, tx, cancellationToken: ct));
        return m is not null && (m.BorrowerCompanyId is null || scope.Allows(m.BorrowerCompanyId)) ? m : throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "scope", "facility", "code", "all");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? facility = q["facility"].Count > 0 ? (Guid.TryParse(q["facility"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "facility is an id.")) : null;
        var rows = (await u.Connection.QueryAsync<Row>(new CommandDefinition(Select + """
             WHERE (@scopeKind IS NULL OR m.Scope = @scopeKind) AND (@facility IS NULL OR f.PublicId = @facility) AND (@code IS NULL OR m.Code = @code)
               AND (@all = 1 OR m.Status <> 'SUPERSEDED')
             ORDER BY m.Scope, m.Code, f.FacilityNo, m.VersionNo DESC;
            """, new
        {
            scopeKind = q["scope"].Count > 0 ? q["scope"].ToString().ToUpperInvariant() : null, facility, code = q["code"].Count > 0 ? q["code"].ToString().ToUpperInvariant() : null,
            all = q["all"] == "true" ? 1 : 0,
        }, cancellationToken: http.RequestAborted))).Where(m => m.BorrowerCompanyId is null || scope.Allows(m.BorrowerCompanyId));
        return Results.Ok(new { items = rows.Select(m => Shape(m, u.UserId, refs, u.TenantId)) });
    }

    private static async Task<IResult> GetAsync(string id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var _ = u;
        var m = await FindAsync(u, null, id, refs, scope, http.RequestAborted);
        var versions = await u.Connection.QueryAsync<(long Id, int VersionNo, string Status, string Expression, DateTime? ApprovedOn)>(new CommandDefinition(
            """
            SELECT MeasureFormulaId, VersionNo, Status, Expression, ApprovedOn
              FROM fin.MeasureFormula WHERE Code = @c AND ((@f IS NULL AND FacilityId IS NULL) OR FacilityId = @f) ORDER BY VersionNo;
            """, new { c = m.Code, f = m.FacilityId }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            formula = Shape(m, u.UserId, refs, u.TenantId),
            versions = versions.Select(v => new { id = refs.ItemRef(u.TenantId, RefKind, v.Id), versionNo = v.VersionNo, status = v.Status, expression = v.Expression, approvedOn = v.ApprovedOn }),
        });
    }

    private static object Errors(ParsedFormula p) => p.Errors.Select(e => new { position = e.Position, code = e.Code, message = e.Message });

    /// <summary>The parsed formula, or 422 V-FIN-FORMULA with its errors in the title.</summary>
    private static async Task<ParsedFormula> ParsedAsync(BoundUser u, SqlTransaction? tx, string? expression, CancellationToken ct)
    {
        var parsed = Formula.Parse(expression, await FinanceInputs.CodesAsync(u.Connection, tx, ct));
        return parsed.IsValid ? parsed
            : throw ApiProblemException.Invalid("V-FIN-FORMULA", $"The formula is not valid: {string.Join(" ", parsed.Errors.Take(5).Select(e => e.Message))}");
    }

    private static readonly string[] KindOrder = ["STATEMENT", "ACCOUNT_STATS", "BANK_FLOWS"];

    private static string Kinds(ParsedFormula p) => string.Join(',', KindOrder.Where(p.InputKinds.Contains));

    /// <summary>The live check of the editor (SCR-FIN-03): the errors with their positions, the codes and input kinds; and, given an approved statement, the value on it.</summary>
    private static async Task<IResult> ValidateAsync(FormulaCheckRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        var parsed = Formula.Parse(b.Expression, await FinanceInputs.CodesAsync(u.Connection, null, ct));
        object? preview = null;
        if (parsed.IsValid && b.Statement is { } sid)
        {
            var (su, sscope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
            await using var __ = su;
            var s = await StatementEndpoints.FindAsync(su, null, sid, sscope, ct);
            var input = await FinanceInputs.StatementAsync(su.Connection, null, s.FinancialStatementId, ct);
            var (inputs, read) = await FinanceInputs.ForStatementAsync(su.Connection, null, input!, parsed.Tree!, null, ct);
            var v = Formula.Evaluate(parsed.Tree!, inputs);
            preview = new
            {
                value = v.Value, undefined = v.Undefined, statements = read.Select(r => new { id = r.PublicId, periodEnd = FacilityEndpoints.D(r.PeriodEnd), versionNo = r.VersionNo }),
                inputs = parsed.Codes.Where(c => Formula.KindOf(c) == "STATEMENT").Order().Select(c => new { code = c, value = input!.Lines.GetValueOrDefault(c) }),
            };
        }
        return Results.Ok(new
        {
            valid = parsed.IsValid, errors = Errors(parsed), codes = parsed.Codes.Order(), inputKinds = Kinds(parsed).Split(',', StringSplitOptions.RemoveEmptyEntries),
            depth = parsed.Depth, preview,
        });
    }

    private static (string Code, string NameAr, string? NameEn, string Unit, string? Note) Fields(FormulaRequest b, Row? was)
    {
        var code = (b.Code ?? was?.Code)?.Trim().ToUpperInvariant() ?? "";
        if (!System.Text.RegularExpressions.Regex.IsMatch(code, "^[A-Z][A-Z0-9_]{1,59}$"))
            throw ApiProblemException.Invalid("V-CAT-CODE", "A code is capital letters, digits and underscores, starting with a letter (BR-CAT-001).");
        var nameAr = (b.NameAr ?? was?.NameAr)?.Trim();
        if (string.IsNullOrEmpty(nameAr) || nameAr.Length > 200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the Arabic name, at most 200 characters.");
        var nameEn = b.NameEn is null ? was?.NameEn : b.NameEn.Trim() is { Length: > 0 } n ? (n.Length <= 200 ? n : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The English name has at most 200 characters.")) : null;
        var unit = (b.ResultUnit ?? was?.ResultUnit)?.Trim().ToUpperInvariant() ?? "";
        if (!Units.Contains(unit)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The result unit is RATIO, AMOUNT, PERCENT or DAYS.");
        var note = b.DefinitionNote is null ? was?.DefinitionNote : b.DefinitionNote.Trim() is { Length: > 0 } d ? (d.Length <= 1000 ? d
            : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The definition note has at most 1,000 characters.")) : null;
        return (code, nameAr, nameEn, unit, note);
    }

    /// <summary>A new formula of the library, a template of covenants or an analysis measure (DAYS for analysis only, BR-FIN-014), written as a draft.</summary>
    private static async Task<IResult> CreateAsync(FormulaRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, Manage, statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        var kind = b.Scope?.Trim().ToUpperInvariant() ?? "TEMPLATE";
        if (kind is not ("TEMPLATE" or "ANALYSIS")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A new formula is a TEMPLATE or an ANALYSIS measure; a facility's copy is made from a template.");
        var (code, nameAr, nameEn, unit, note) = Fields(b, null);
        if (unit == "DAYS" && kind != "ANALYSIS") throw ApiProblemException.Invalid("V-FIN-FORMULA", "Days are a unit of analysis measures only (BR-FIN-014).");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var parsed = await ParsedAsync(u, tx, b.Expression, ct);
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM fin.MeasureFormula WHERE Code = @code AND FacilityId IS NULL;", new { code }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-CAT-DUPLICATE", "A formula with this code exists; change it by a new version.");
        var made = refs.ItemRef(u.TenantId, RefKind, await InsertAsync(u, tx, code, nameAr, nameEn, kind, null, null, b.Expression!.Trim(), Kinds(parsed), unit, note, 1, ct));
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/formulas/{made}", new { id = made });
    }

    private static async Task<long> InsertAsync(BoundUser u, SqlTransaction tx, string code, string nameAr, string? nameEn, string kind, long? facility, long? baseTemplate,
        string expression, string inputKinds, string unit, string? note, int version, CancellationToken ct) =>
        await u.Connection.QuerySingleAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT fin.MeasureFormula (TenantId, Code, NameAr, NameEn, Scope, FacilityId, BaseTemplateId, Expression, InputKinds, ResultUnit, DefinitionNote, VersionNo, Status,
                                       NoSourceReason, CreatedBy)
            OUTPUT inserted.MeasureFormulaId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @nameAr, @nameEn, @kind, @facility, @base, @expression, @kinds, @unit, @note, @version, 'DRAFT',
                    N'Written in the formula library', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { code, nameAr, nameEn, kind, facility, @base = baseTemplate, expression, kinds = inputKinds, unit, note, version }, tx, cancellationToken: ct));

    /// <summary>A draft changes as the preparer edits it; a new version keeps its unit and whether it reads statements (DR-38).</summary>
    private static async Task<IResult> ChangeAsync(string id, FormulaRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Manage, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Code is not null || b.Scope is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The code and the scope of a formula do not change.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var m = await FindAsync(u, tx, id, refs, scope, ct, lockRow: true);
        if (m.Status != "DRAFT") throw new ApiProblemException(409, "APPROVED_FINAL", "An approved formula is fixed; change it by a new version (FR-FIN-011).");
        var (_, nameAr, nameEn, unit, note) = Fields(b, m);
        var expression = (b.Expression ?? m.Expression).Trim();
        var parsed = await ParsedAsync(u, tx, expression, ct);
        if (m.VersionNo > 1)
        {
            var first = await u.Connection.QuerySingleAsync<(string Unit, bool Statements)>(new CommandDefinition(
                "SELECT TOP (1) ResultUnit, UsesStatements FROM fin.MeasureFormula WHERE Code = @c AND ((@f IS NULL AND FacilityId IS NULL) OR FacilityId = @f) AND Status <> 'DRAFT' ORDER BY VersionNo DESC;",
                new { c = m.Code, f = m.FacilityId }, tx, cancellationToken: ct));
            if (unit != first.Unit || parsed.InputKinds.Contains("STATEMENT") != first.Statements)
                throw ApiProblemException.Invalid("V-FIN-FORMULA", "A new version keeps the unit of the formula and whether it reads the statements, as the covenants copy both (DR-38).");
        }
        if (unit == "DAYS" && m.Scope != "ANALYSIS") throw ApiProblemException.Invalid("V-FIN-FORMULA", "Days are a unit of analysis measures only (BR-FIN-014).");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.MeasureFormula SET NameAr = @nameAr, NameEn = @nameEn, Expression = @expression, InputKinds = @kinds, ResultUnit = @unit, DefinitionNote = @note,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE MeasureFormulaId = @id;
            """, new { nameAr, nameEn, expression, kinds = Kinds(parsed), unit, note, id = m.MeasureFormulaId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>The approved covenants that use a template's code (OQ-3): a template they use is not versioned.</summary>
    private static Task<int> InUseAsync(BoundUser u, SqlTransaction tx, string code, CancellationToken ct) =>
        u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(*) FROM obl.Covenant AS c
              JOIN fin.MeasureFormula AS m ON m.MeasureFormulaId = c.FormulaId
              JOIN obl.Obligation AS o ON o.ObligationId = c.ObligationId
              JOIN fac.Facility AS f ON f.FacilityId = o.FacilityId
             WHERE m.Code = @code AND m.FacilityId IS NULL AND f.ApprovedRevisionNo >= 1
               AND c.FromRevision <= f.ApprovedRevisionNo AND (c.ToRevision IS NULL OR c.ToRevision > f.ApprovedRevisionNo);
            """, new { code }, tx, cancellationToken: ct));

    private static async Task<IResult> NewVersionAsync(string id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Manage, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var m = await FindAsync(u, tx, id, refs, scope, ct, lockRow: true);
        if (m.Status != "APPROVED") throw new ApiProblemException(409, "FORMULA_STATE", "A new version is made from the approved formula.");
        if (m.Scope == "TEMPLATE" && await InUseAsync(u, tx, m.Code, ct) > 0)
            throw new ApiProblemException(409, "FORMULA_IN_USE", "An approved covenant uses this template: copy it to the facility and change the copy in a revision (OQ-3).");
        var (open, max) = await u.Connection.QuerySingleAsync<(int Open, int Max)>(new CommandDefinition(
            "SELECT SUM(CASE WHEN Status = 'DRAFT' THEN 1 ELSE 0 END), MAX(VersionNo) FROM fin.MeasureFormula WHERE Code = @c AND ((@f IS NULL AND FacilityId IS NULL) OR FacilityId = @f);",
            new { c = m.Code, f = m.FacilityId }, tx, cancellationToken: ct));
        if (open > 0) throw new ApiProblemException(409, "FORMULA_STATE", "This formula already has a draft version; open it.");
        var made = refs.ItemRef(u.TenantId, RefKind,
            await InsertAsync(u, tx, m.Code, m.NameAr, m.NameEn, m.Scope, m.FacilityId, m.BaseTemplateId, m.Expression, m.InputKinds, m.ResultUnit, m.DefinitionNote, max + 1, ct));
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/formulas/{made}", new { id = made, versionNo = max + 1 });
    }

    /// <summary>FR-FIN-011: approved by another user; the approved version of the code and facility superseded first, in the same transaction.</summary>
    private static async Task<IResult> ApproveAsync(string id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, ApproveFormula, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var m = await FindAsync(u, tx, id, refs, scope, ct, lockRow: true);
        if (m.Status != "DRAFT") throw new ApiProblemException(409, "FORMULA_STATE", "Only a draft formula is approved.");
        if (m.CreatedBy == u.UserId || m.UpdatedBy == u.UserId)
            throw ApiProblemException.Forbidden("V-FIN-SOD", "Who prepared a formula does not approve it; another user does (FR-FIN-011).");
        await ParsedAsync(u, tx, m.Expression, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.MeasureFormula SET Status = 'SUPERSEDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE Code = @c AND ((@f IS NULL AND FacilityId IS NULL) OR FacilityId = @f) AND Status = 'APPROVED';
            UPDATE fin.MeasureFormula SET Status = 'APPROVED', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE MeasureFormulaId = @id;
            """, new { c = m.Code, f = m.FacilityId, id = m.MeasureFormulaId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("FORMULA_APPROVED", "TREASURY", "fin.MeasureFormula", m.MeasureFormulaId,
            AfterJson: JsonSerializer.Serialize(new { code = m.Code, versionNo = m.VersionNo, expression = m.Expression })), m.BorrowerCompanyId, ct);
        await Outbox.EmitAsync(u.Connection, tx, "formula.approved", "fin.MeasureFormula", m.MeasureFormulaId, new { formula = m.MeasureFormulaId, code = m.Code, versionNo = m.VersionNo }, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "APPROVED" });
    }

    /// <summary>OQ-3: a template copied to a facility as its own formula (FACILITY_COPY), a draft that names the template it came from.</summary>
    private static async Task<IResult> CopyAsync(string id, FormulaCopyRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Manage, statements: false);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Facility is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the facility of the copy.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var m = await FindAsync(u, tx, id, refs, scope, ct);
        if (m.Scope != "TEMPLATE" || m.Status != "APPROVED") throw new ApiProblemException(409, "FORMULA_STATE", "An approved template is copied to a facility.");
        var facility = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long Company)?>(new CommandDefinition(
            "SELECT FacilityId, BorrowerCompanyId FROM fac.Facility WHERE PublicId = @f;", new { f = b.Facility }, tx, cancellationToken: ct));
        if (facility is not { } fac || !scope.Allows(fac.Company)) throw ApiProblemException.NotFound();
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM fin.MeasureFormula WHERE Code = @c AND FacilityId = @f;",
                new { c = m.Code, f = fac.Id }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-CAT-DUPLICATE", "This facility already has its copy of the formula; change it by a new version.");
        var made = refs.ItemRef(u.TenantId, RefKind,
            await InsertAsync(u, tx, m.Code, m.NameAr, m.NameEn, "FACILITY_COPY", fac.Id, m.MeasureFormulaId, m.Expression, m.InputKinds, m.ResultUnit, m.DefinitionNote, 1, ct));
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/formulas/{made}", new { id = made });
    }

    private static string Clip(string text, int max) => text.Length <= max ? text : text[..max];

    // ---------- analysis measures on a statement ----------

    private static async Task<IResult> RatiosAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var s = await StatementEndpoints.FindAsync(u, null, id, scope, http.RequestAborted);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT m.Code AS code, m.NameAr AS nameAr, m.NameEn AS nameEn, m.Scope AS scope, m.VersionNo AS versionNo, r.ResultUnit AS unit, r.Status AS status,
                   r.Value AS value, r.Reason AS reason, r.ComputedAt AS computedAt
              FROM fin.StatementRatio AS r JOIN fin.MeasureFormula AS m ON m.MeasureFormulaId = r.FormulaId
             WHERE r.StatementId = @s ORDER BY m.Scope, m.Code;
            """, new { s = s.FinancialStatementId }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    /// <summary>
    /// FR-FIN-016, BR-FIN-014: the approved analysis measures, and the approved templates that read statements only, on an
    /// approved statement; one result per statement and formula with the inputs it read; what cannot be computed carries why.
    /// </summary>
    private static async Task<IResult> ComputeAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, Verify, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await StatementEndpoints.FindAsync(u, tx, id, scope, ct);
        if (s.Status != "APPROVED") throw new ApiProblemException(409, "STATEMENT_STATE", "The measures are computed on an approved statement.");
        var input = (await FinanceInputs.StatementAsync(u.Connection, tx, s.FinancialStatementId, ct))!;
        var codes = await FinanceInputs.CodesAsync(u.Connection, tx, ct);
        var formulas = await u.Connection.QueryAsync<Row>(new CommandDefinition(Select +
            " WHERE m.Status = 'APPROVED' AND (m.Scope = 'ANALYSIS' OR (m.Scope = 'TEMPLATE' AND m.InputKinds = 'STATEMENT')) ORDER BY m.Code;", transaction: tx, cancellationToken: ct));
        var n = 0;
        foreach (var f in formulas)
        {
            var parsed = Formula.Parse(f.Expression, codes);
            decimal? value = null;
            string? reason;
            object snapshot;
            if (!parsed.IsValid)
            {
                reason = "The formula is not valid: " + string.Join(" ", parsed.Errors.Take(3).Select(e => e.Message));
                snapshot = new { formula = new { id = f.MeasureFormulaId, version = f.VersionNo, expression = f.Expression } };
            }
            else
            {
                var (inputs, read) = await FinanceInputs.ForStatementAsync(u.Connection, tx, input, parsed.Tree!, null, ct);
                var v = Formula.Evaluate(parsed.Tree!, inputs);
                value = v.Value is { } x ? Math.Round(x, 6) : null;
                reason = v.Undefined;
                snapshot = new
                {
                    formula = new { id = f.MeasureFormulaId, version = f.VersionNo, expression = f.Expression },
                    statements = read.Select(r => new { id = r.PublicId, version = r.VersionNo, basis = r.Basis, periodEnd = FacilityEndpoints.D(r.PeriodEnd) }),
                    inputs = parsed.Codes.Order().ToDictionary(c => c, c => input.Lines.GetValueOrDefault(c)),
                };
            }
            if (value is { } big && Math.Abs(big) >= 10_000_000_000_000m) { value = null; reason = "The value is too large to keep."; }
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE fin.StatementRatio SET ResultUnit = @unit, Status = @status, Value = @value, Reason = @reason, InputsSnapshot = @snap, ComputedAt = SYSUTCDATETIME(),
                       UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE StatementId = @s AND FormulaId = @f;
                IF @@ROWCOUNT = 0
                    INSERT fin.StatementRatio (TenantId, StatementId, FormulaId, ResultUnit, Status, Value, Reason, InputsSnapshot, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @s, @f, @unit, @status, @value, @reason, @snap, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new
            {
                s = s.FinancialStatementId, f = f.MeasureFormulaId, unit = f.ResultUnit, status = value is null ? "NOT_COMPUTABLE" : "COMPUTED", value,
                reason = value is null ? Clip(reason ?? "Not computable", 300) : null, snap = JsonSerializer.Serialize(snapshot),
            }, tx, cancellationToken: ct));
            n++;
        }
        await tx.CommitAsync(ct);
        return Results.Ok(new { computed = n });
    }
}
