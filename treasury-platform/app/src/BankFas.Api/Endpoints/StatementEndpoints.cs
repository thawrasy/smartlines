using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Finance;
using BankFas.Data;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record StatementRequest(Guid? Company, string? PeriodType, string? PeriodStart, string? PeriodEnd, int? FiscalYear, string? Basis, string? Assurance,
    string? Nature, string? Currency, int? UnitScale, string? AccountingStandard, string? AuditorName, string? AuditOpinion, bool? GoingConcernUncertainty,
    string? EntryMethod, Guid? SourceDocument);
public sealed record StatementLineInput(string? Code, decimal? Amount);
public sealed record StatementLinesRequest(StatementLineInput[]? Lines, string? EntryMethod);
public sealed record StatementSubmitRequest(string? BalanceReason);
public sealed record StatementReasonRequest(string? Reason);
public sealed record PasteRow(string? Label, decimal? Amount);
public sealed record PasteRequest(PasteRow[]? Rows);
public sealed record ConsolidationUnitRequest(Guid? Company, string? Role, string? Method, decimal? OwnershipPct, string? IncludedFrom, string? IncludedTo, Guid? MemberStatement,
    string? Note);

/// <summary>
/// Financial statements (spec 12 section 6, FR-FIN-001 to 007 and 015; BR-FIN-001 to 004 and 012, 013; V-FIN-01). A
/// statement is entered as a DRAFT in its unit (1, 1,000 or 1,000,000) and stored times the unit (BR-FIN-002); the grid
/// shows the totals computed from their components and the balance live (BR-FIN-001). Submitting checks the required
/// lines and asks a reason for an imbalance, writes an explicit 0 for an optional line left empty (an "of which", a
/// detail or a memorandum line stays absent) and the computed amount of each total, and names the submitter as the
/// preparer (058). Another user with fin.stmt.approve approves it; the approved version of the same series is
/// superseded first, in the same transaction (one approved per series, BR-FIN-004), and statement.approved tells the
/// covenant engine to re-evaluate (OQ-13). A change of an approved statement is a new version (RESTATED or CORRECTION)
/// that copies it as a draft. A holding's consolidated statement lists its units (FR-FIN-015, BR-FIN-013).
/// </summary>
public static class StatementEndpoints
{
    private static readonly string[] PeriodTypes = ["ANNUAL", "SEMIANNUAL", "QUARTERLY", "MONTHLY"];
    private static readonly string[] Bases = ["STANDALONE", "CONSOLIDATED"];
    private static readonly string[] Assurances = ["AUDITED", "REVIEWED", "MANAGEMENT"];
    private static readonly string[] Opinions = ["UNQUALIFIED", "QUALIFIED", "ADVERSE", "DISCLAIMER"];
    private static readonly int[] Scales = [1, 1000, 1000000];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/financial-statements", ListAsync);
        api.MapPost("/financial-statements", CreateAsync);
        api.MapGet("/financial-statements/{id:guid}", GetAsync);
        api.MapPatch("/financial-statements/{id:guid}", PatchAsync);
        api.MapPut("/financial-statements/{id:guid}/lines", LinesAsync);
        api.MapPost("/financial-statements/{id:guid}/paste-preview", PastePreviewAsync);
        api.MapPost("/financial-statements/{id:guid}/actions/submit", SubmitAsync);
        api.MapPost("/financial-statements/{id:guid}/actions/approve", ApproveAsync);
        api.MapPost("/financial-statements/{id:guid}/actions/reject", RejectAsync);
        api.MapPost("/financial-statements/{id:guid}/actions/reopen", ReopenAsync);
        api.MapPost("/financial-statements/{id:guid}/actions/new-version", NewVersionAsync);
        api.MapGet("/financial-statements/{id:guid}/units", UnitsAsync);
        api.MapPost("/financial-statements/{id:guid}/units", AddUnitAsync);
        api.MapDelete("/financial-statements/{id:guid}/units/{company:guid}", RemoveUnitAsync);
    }

    internal sealed class Row
    {
        public long FinancialStatementId { get; init; }
        public Guid PublicId { get; init; }
        public long CompanyId { get; init; }
        public Guid CompanyPublicId { get; init; }
        public string CompanyNameAr { get; init; } = "";
        public string? CompanyNameEn { get; init; }
        public bool IsHolding { get; init; }
        public string PeriodType { get; init; } = "";
        public DateTime? PeriodStart { get; init; }
        public DateTime PeriodEnd { get; init; }
        public int FiscalYear { get; init; }
        public string Basis { get; init; } = "";
        public string Assurance { get; init; } = "";
        public string Nature { get; init; } = "";
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = "";
        public int UnitScale { get; init; }
        public string? AccountingStandard { get; init; }
        public string? AuditorName { get; init; }
        public string? AuditOpinion { get; init; }
        public bool GoingConcernUncertainty { get; init; }
        public int VersionNo { get; init; }
        public string VersionReason { get; init; } = "";
        public long? SupersedesId { get; init; }
        public Guid? SupersedesPublicId { get; init; }
        public string Status { get; init; } = "";
        public string EntryMethod { get; init; } = "";
        public string? BalanceReason { get; init; }
        public long? SourceDocumentId { get; init; }
        public Guid? SourceDocumentPublicId { get; init; }
        public long? PreparedBy { get; init; }
        public DateTime? PreparedOn { get; init; }
        public long? ApprovedBy { get; init; }
        public DateTime? ApprovedOn { get; init; }
        public long? CreatedBy { get; init; }
        public byte[] RowVersion { get; init; } = [];
    }

    private const string Select = """
        SELECT s.FinancialStatementId, s.PublicId, s.CompanyId, c.PublicId AS CompanyPublicId, c.NameAr AS CompanyNameAr, c.NameEn AS CompanyNameEn, c.IsHolding,
               s.PeriodType, s.PeriodStart, s.PeriodEnd, s.FiscalYear, s.Basis, s.Assurance, s.Nature, s.CurrencyId, cu.Code AS CurrencyCode, s.UnitScale,
               s.AccountingStandard, s.AuditorName, s.AuditOpinion, s.GoingConcernUncertainty, s.VersionNo, s.VersionReason, s.SupersedesId,
               p.PublicId AS SupersedesPublicId, s.Status, s.EntryMethod, s.BalanceReason, s.SourceDocumentId, d.PublicId AS SourceDocumentPublicId,
               s.PreparedBy, s.PreparedOn, s.ApprovedBy, s.ApprovedOn, s.CreatedBy, s.RowVersion
          FROM fin.FinancialStatement AS s
          JOIN org.Company AS c ON c.CompanyId = s.CompanyId
          JOIN ref.Currency AS cu ON cu.CurrencyId = s.CurrencyId
          LEFT JOIN fin.FinancialStatement AS p ON p.FinancialStatementId = s.SupersedesId
          LEFT JOIN doc.Document AS d ON d.DocumentId = s.SourceDocumentId
        """;

    internal static async Task<Row> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct, bool lockRow = false)
    {
        var s = await u.Connection.QuerySingleOrDefaultAsync<Row>(new CommandDefinition(
            Select.Replace("FROM fin.FinancialStatement AS s", lockRow ? "FROM fin.FinancialStatement AS s WITH (UPDLOCK, HOLDLOCK)" : "FROM fin.FinancialStatement AS s",
                StringComparison.Ordinal) + " WHERE s.PublicId = @id;", new { id }, tx, cancellationToken: ct));
        if (s is null || !scope.Allows(s.CompanyId)) throw ApiProblemException.NotFound();
        return s;
    }

    private static object Header(Row s) => new
    {
        id = s.PublicId, company = new { id = s.CompanyPublicId, nameAr = s.CompanyNameAr, nameEn = s.CompanyNameEn, isHolding = s.IsHolding },
        periodType = s.PeriodType, periodStart = FacilityEndpoints.D(s.PeriodStart), periodEnd = FacilityEndpoints.D(s.PeriodEnd), fiscalYear = s.FiscalYear,
        basis = s.Basis, assurance = s.Assurance, nature = s.Nature, currency = s.CurrencyCode, unitScale = s.UnitScale, accountingStandard = s.AccountingStandard,
        auditorName = s.AuditorName, auditOpinion = s.AuditOpinion, goingConcernUncertainty = s.GoingConcernUncertainty, versionNo = s.VersionNo,
        versionReason = s.VersionReason, supersedes = s.SupersedesPublicId, status = s.Status, entryMethod = s.EntryMethod, balanceReason = s.BalanceReason,
        sourceDocument = s.SourceDocumentPublicId, preparedOn = s.PreparedOn, approvedOn = s.ApprovedOn,
    };

    // ---------- the catalogue and the lines ----------

    internal sealed record CatalogLine(int LineCatalogItemId, string Code, string NameAr, string? NameEn, string Section, bool IsTotal, string? TotalFormula, bool IsRequired,
        bool IsActive, bool IsSystem, bool IsLocked, int SortOrder, string? LineKind, string? ParentCode)
    {
        public string Kind => LineKind ?? (IsTotal ? "TOTAL" : "LINE");
        public LineDef Def => new(Code, Section, Kind, IsRequired, TotalFormula, SortOrder, ParentCode);
    }

    internal static async Task<List<CatalogLine>> CatalogAsync(BoundUser u, SqlTransaction? tx, CancellationToken ct) =>
        [.. await u.Connection.QueryAsync<CatalogLine>(new CommandDefinition(
            """
            SELECT l.LineCatalogItemId, l.Code, l.NameAr, l.NameEn, l.Section, l.IsTotal, l.TotalFormula, l.IsRequired, l.IsActive, l.IsSystem, l.IsLocked, l.SortOrder,
                   sl.LineKind, sl.ParentCode
              FROM fin.LineCatalogItem AS l
              LEFT JOIN fin.StandardLine AS sl ON sl.Code = l.Code
             ORDER BY l.SortOrder, l.Code;
            """, transaction: tx, cancellationToken: ct))];

    private sealed record LineRow(int LineCatalogItemId, decimal? EnteredAmount, decimal? ComputedAmount);

    private static async Task<Dictionary<int, LineRow>> LinesOfAsync(BoundUser u, SqlTransaction? tx, long statement, CancellationToken ct) =>
        (await u.Connection.QueryAsync<LineRow>(new CommandDefinition(
            "SELECT LineCatalogItemId, EnteredAmount, ComputedAmount FROM fin.StatementLine WHERE StatementId = @s;", new { s = statement }, tx, cancellationToken: ct)))
        .ToDictionary(l => l.LineCatalogItemId);

    /// <summary>The lines of the check: the active lines, and an inactive one the statement holds (its value stays visible).</summary>
    private static List<CatalogLine> Shown(List<CatalogLine> catalog, Dictionary<int, LineRow> stored) =>
        [.. catalog.Where(l => l.IsActive || stored.ContainsKey(l.LineCatalogItemId))];

    private static Dictionary<string, decimal?> Entered(List<CatalogLine> lines, Dictionary<int, LineRow> stored) =>
        lines.ToDictionary(l => l.Code, l => stored.TryGetValue(l.LineCatalogItemId, out var r) ? r.EnteredAmount : null, StringComparer.Ordinal);

    /// <summary>Writes the lines as given (entered and computed amounts), removing what is no longer held; one statement, one call.</summary>
    private static async Task WriteLinesAsync(BoundUser u, SqlTransaction tx, long statement, IEnumerable<(int Id, decimal? Entered, decimal? Computed)> lines, CancellationToken ct)
    {
        var json = JsonSerializer.Serialize(lines.Where(l => l.Entered is not null || l.Computed is not null)
            .Select(l => new { id = l.Id, e = l.Entered, c = l.Computed }));
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            DECLARE @t TABLE (Id INT PRIMARY KEY, E DECIMAL(19,4) NULL, C DECIMAL(19,4) NULL);
            INSERT @t (Id, E, C) SELECT id, e, c FROM OPENJSON(@j) WITH (id INT, e DECIMAL(19,4), c DECIMAL(19,4));
            DELETE l FROM fin.StatementLine AS l WHERE l.StatementId = @s AND NOT EXISTS (SELECT 1 FROM @t AS t WHERE t.Id = l.LineCatalogItemId);
            UPDATE l SET EnteredAmount = t.E, ComputedAmount = t.C, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM fin.StatementLine AS l JOIN @t AS t ON t.Id = l.LineCatalogItemId
             WHERE l.StatementId = @s AND (EXISTS (SELECT l.EnteredAmount, l.ComputedAmount EXCEPT SELECT t.E, t.C));
            INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount, ComputedAmount, CreatedBy)
            SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), @s, t.Id, t.E, t.C, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM @t AS t WHERE NOT EXISTS (SELECT 1 FROM fin.StatementLine AS l WHERE l.StatementId = @s AND l.LineCatalogItemId = t.Id);
            """, new { s = statement, j = json }, tx, cancellationToken: ct));
    }

    /// <summary>The draft's lines with the totals computed again (they show live, BR-FIN-001).</summary>
    private static async Task SaveDraftLinesAsync(BoundUser u, SqlTransaction tx, long statement, List<CatalogLine> shown, Dictionary<string, decimal?> entered, CancellationToken ct)
    {
        var totals = StatementMath.ComputeTotals([.. shown.Select(l => l.Def)], entered);
        await WriteLinesAsync(u, tx, statement, shown.Select(l => (l.LineCatalogItemId, entered.GetValueOrDefault(l.Code),
            totals.TryGetValue(l.Code, out var t) ? t : (decimal?)null)), ct);
    }

    private static decimal? Unit(decimal? stored, int scale) => stored is { } v ? v / scale : null;

    private static object CheckShape(StatementCheck check, int scale) => new
    {
        totals = check.Totals.Select(t => new { code = t.Code, computed = t.Computed / scale, entered = Unit(t.Entered, scale), variance = Unit(t.Variance, scale), matches = t.Matches }),
        balanceDifference = Unit(check.BalanceDifference, scale), balanced = check.Balanced, missingRequired = check.MissingRequired, canSubmit = check.CanSubmit,
    };

    // ---------- reading ----------

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company", "fiscalYear", "basis", "status", "nature");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        int? year = q["fiscalYear"].Count > 0 ? (int.TryParse(q["fiscalYear"], CultureInfo.InvariantCulture, out var y) ? y
            : throw new ApiProblemException(400, "MALFORMED_REQUEST", "fiscalYear is a year.")) : null;
        var rows = await u.Connection.QueryAsync<Row>(new CommandDefinition(Select + """
             WHERE (@company IS NULL OR c.PublicId = @company) AND (@year IS NULL OR s.FiscalYear = @year) AND (@basis IS NULL OR s.Basis = @basis)
               AND (@status IS NULL OR s.Status = @status) AND (@nature IS NULL OR s.Nature = @nature) AND (@all = 1 OR s.CompanyId IN @ids)
             ORDER BY s.PeriodEnd DESC, c.NameAr, s.Basis, s.Assurance, s.VersionNo DESC;
            """, new
        {
            company, year, basis = Text(q["basis"]), status = Text(q["status"]), nature = Text(q["nature"]), all = scope.All ? 1 : 0, ids = scope.SqlIds,
        }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(Header) });
    }

    private static string? Text(Microsoft.Extensions.Primitives.StringValues v) => v.Count == 0 || string.IsNullOrWhiteSpace(v) ? null : v.ToString().Trim().ToUpperInvariant();

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var s = await FindAsync(u, null, id, scope, ct);
        var catalog = await CatalogAsync(u, null, ct);
        var stored = await LinesOfAsync(u, null, s.FinancialStatementId, ct);
        var shown = Shown(catalog, stored);
        var check = StatementMath.Check([.. shown.Select(l => l.Def)], Entered(shown, stored), s.UnitScale);
        var series = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT PublicId AS id, VersionNo AS versionNo, VersionReason AS versionReason, Status AS status, ApprovedOn AS approvedOn
              FROM fin.FinancialStatement
             WHERE CompanyId = @c AND Basis = @b AND Assurance = @a AND PeriodType = @p AND PeriodEnd = @e AND Nature = @n
             ORDER BY VersionNo;
            """, new { c = s.CompanyId, b = s.Basis, a = s.Assurance, p = s.PeriodType, e = s.PeriodEnd, n = s.Nature }, cancellationToken: ct));
        ETags.Set(http.Response, s.RowVersion);
        return Results.Ok(new
        {
            statement = Header(s), etag = ETags.Of(s.RowVersion),
            lines = shown.Select(l =>
            {
                var r = stored.GetValueOrDefault(l.LineCatalogItemId);
                return new
                {
                    code = l.Code, nameAr = l.NameAr, nameEn = l.NameEn, section = l.Section, kind = l.Kind, parent = l.ParentCode, isRequired = l.IsRequired,
                    isTotal = l.IsTotal, totalFormula = l.TotalFormula, isMain = LineCatalog.SpecLines.Contains(l.Code) || !l.IsSystem, isActive = l.IsActive, sortOrder = l.SortOrder,
                    entered = Unit(r?.EnteredAmount, s.UnitScale), amount = r?.EnteredAmount, computed = Unit(r?.ComputedAmount, s.UnitScale),
                };
            }),
            check = CheckShape(check, s.UnitScale), versions = series,
            preparedByMe = s.PreparedBy == u.UserId,
        });
    }

    // ---------- writing a draft ----------

    private sealed record Fields(string PeriodType, DateTime? PeriodStart, DateTime PeriodEnd, int FiscalYear, string Basis, string Assurance, string Nature, int Currency,
        int UnitScale, string? Standard, string? Auditor, string? Opinion, bool GoingConcern, string EntryMethod, long? Document);

    private static string Pick(string? value, string[] allowed, string label, string? fallback = null)
    {
        var v = string.IsNullOrWhiteSpace(value) ? fallback : value.Trim().ToUpperInvariant();
        return v is not null && allowed.Contains(v, StringComparer.Ordinal) ? v
            : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {label} is one of {string.Join(", ", allowed)}.");
    }

    private static string? Trimmed(string? s, int max, string label)
    {
        if (string.IsNullOrWhiteSpace(s)) return null;
        var t = s.Trim();
        return t.Length <= max ? t : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {label} has at most {max} characters.");
    }

    /// <summary>The header fields, checked as the model's constraints check them (a CHECK violation would read "a value is not valid").</summary>
    private static async Task<Fields> FieldsAsync(BoundUser u, SqlTransaction tx, StatementRequest b, Row? was, long company, bool holding, CancellationToken ct)
    {
        var periodType = Pick(b.PeriodType, PeriodTypes, "period type", was?.PeriodType);
        var end = LimitEndpoints.Date(b.PeriodEnd, "period end") ?? was?.PeriodEnd ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the period end.");
        var start = b.PeriodStart is not null ? LimitEndpoints.Date(b.PeriodStart, "period start") : was?.PeriodStart;
        if (start is { } st && st > end) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The period starts on or before its end.");
        var year = b.FiscalYear ?? was?.FiscalYear ?? end.Year;
        if (year is < 1900 or > 2200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The fiscal year is a year from 1900 to 2200.");
        var basis = Pick(b.Basis, Bases, "basis", was?.Basis ?? "STANDALONE");
        if (basis == "CONSOLIDATED" && !holding)
            throw ApiProblemException.Invalid("V-FIN-CONSOLIDATION", "Only a holding enters consolidated statements; this company enters standalone ones (BR-FIN-013).");
        var assurance = Pick(b.Assurance, Assurances, "assurance", was?.Assurance);
        var nature = Pick(b.Nature, ["ACTUAL", "BUDGET"], "nature", was?.Nature ?? "ACTUAL");
        var currency = b.Currency is not null ? await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct)
            : was?.CurrencyId ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the currency of the statement.");
        var scale = b.UnitScale ?? was?.UnitScale ?? 1;
        if (!Scales.Contains(scale)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The unit is 1, 1,000 or 1,000,000.");
        var opinion = b.AuditOpinion is not null ? (b.AuditOpinion.Length == 0 ? null : Pick(b.AuditOpinion, Opinions, "audit opinion")) : was?.AuditOpinion;
        var auditor = b.AuditorName is not null ? Trimmed(b.AuditorName, 200, "auditor's name") : was?.AuditorName;
        var going = b.GoingConcernUncertainty ?? was?.GoingConcernUncertainty ?? false;
        if (opinion is not null && assurance != "AUDITED") throw ApiProblemException.Invalid("VALIDATION_FAILED", "An audit opinion belongs to an audited statement (BR-FIN-012).");
        if (going && assurance == "MANAGEMENT") throw ApiProblemException.Invalid("VALIDATION_FAILED", "A going-concern paragraph comes from an auditor's report (audited or reviewed).");
        if (nature == "BUDGET" && assurance != "MANAGEMENT") throw ApiProblemException.Invalid("VALIDATION_FAILED", "A budget is prepared by the management (BR-FIN-039).");
        var method = Pick(b.EntryMethod, ["MANUAL", "PASTE"], "entry method", was?.EntryMethod ?? "MANUAL");
        long? document = was?.SourceDocumentId;
        if (b.SourceDocument is { } d)
            document = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND (OwnerCompanyId IS NULL OR OwnerCompanyId = @c);", new { d, c = company }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The source document is not an active document of the company.");
        return new Fields(periodType, start, end, year, basis, assurance, nature, currency, scale, b.AccountingStandard is not null ? Trimmed(b.AccountingStandard, 100, "standard")
            : was?.AccountingStandard, auditor, opinion, going, method, document);
    }

    private static async Task DuplicateAsync(BoundUser u, SqlTransaction tx, long company, Fields f, int version, long? except, CancellationToken ct)
    {
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                SELECT COUNT(*) FROM fin.FinancialStatement
                 WHERE CompanyId = @c AND PeriodType = @p AND PeriodEnd = @e AND Basis = @b AND Assurance = @a AND Nature = @n AND VersionNo = @v
                   AND (@x IS NULL OR FinancialStatementId <> @x);
                """, new { c = company, p = f.PeriodType, e = f.PeriodEnd, b = f.Basis, a = f.Assurance, n = f.Nature, v = version, x = except }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-FIN-DUPLICATE", "This company already has this statement (period, basis, assurance and version); open it or enter a new version (FR-FIN-002).");
    }

    private static async Task<IResult> CreateAsync(StatementRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Company is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company of the statement.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var company = await CompanyEndpoints.FindAsync(u, tx, b.Company.Value, scope, ct);
        var f = await FieldsAsync(u, tx, b, null, company.CompanyId, company.IsHolding, ct);
        await DuplicateAsync(u, tx, company.CompanyId, f, 1, null, ct);
        var made = await InsertAsync(u, tx, company.CompanyId, f, 1, "ORIGINAL", null, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("STATEMENT_CREATED", "TREASURY", "fin.FinancialStatement", made.Id,
            AfterJson: JsonSerializer.Serialize(new { periodEnd = FacilityEndpoints.D(f.PeriodEnd), f.Basis, f.Assurance, f.Nature, f.UnitScale })), company.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/financial-statements/{made.PublicId}", new { id = made.PublicId });
    }

    private static async Task<(long Id, Guid PublicId)> InsertAsync(BoundUser u, SqlTransaction tx, long company, Fields f, int version, string reason, long? supersedes,
        CancellationToken ct) =>
        await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT fin.FinancialStatement (TenantId, CompanyId, PeriodType, PeriodStart, PeriodEnd, FiscalYear, Basis, Assurance, Nature, CurrencyId, UnitScale,
                                           AccountingStandard, AuditorName, AuditOpinion, GoingConcernUncertainty, VersionNo, VersionReason, SupersedesId, Status,
                                           EntryMethod, SourceDocumentId, CreatedBy)
            OUTPUT inserted.FinancialStatementId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @pt, @ps, @pe, @fy, @b, @a, @n, @cur, @us, @std, @aud, @op, @gc, @v, @r, @sup, 'DRAFT', @em, @doc,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new
        {
            c = company, pt = f.PeriodType, ps = f.PeriodStart, pe = f.PeriodEnd, fy = f.FiscalYear, b = f.Basis, a = f.Assurance, n = f.Nature, cur = f.Currency,
            us = f.UnitScale, std = f.Standard, aud = f.Auditor, op = f.Opinion, gc = f.GoingConcern, v = version, r = reason, sup = supersedes, em = f.EntryMethod,
            doc = f.Document,
        }, tx, cancellationToken: ct));

    private static void Draft(Row s)
    {
        if (s.Status != "DRAFT")
            throw new ApiProblemException(409, "STATEMENT_FINAL", s.Status == "REJECTED"
                ? "A returned statement is reopened as a draft before it changes."
                : "A statement changes only as a draft; a change of an approved one is a new version (FR-FIN-005).");
    }

    /// <summary>The header of a draft (If-Match). A later version keeps its series (company, period, basis, assurance, nature); a new unit keeps the numbers as entered.</summary>
    private static async Task<IResult> PatchAsync(Guid id, StatementRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Company is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The company of a statement does not change; another company's statement is a new statement.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (!expected.AsSpan().SequenceEqual(s.RowVersion)) throw ETags.Conflict();
        Draft(s);
        var f = await FieldsAsync(u, tx, b, s, s.CompanyId, s.IsHolding, ct);
        if (s.VersionNo > 1 && (f.PeriodType != s.PeriodType || f.PeriodEnd != s.PeriodEnd || f.Basis != s.Basis || f.Assurance != s.Assurance || f.Nature != s.Nature))
            throw ApiProblemException.Invalid("V-FIN-SERIES", "A new version keeps the period, basis, assurance and nature of the statement it replaces.");
        if (f.Basis != s.Basis && s.Basis == "CONSOLIDATED" && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM fin.ConsolidationMember WHERE StatementId = @s;", new { s = s.FinancialStatementId }, tx, cancellationToken: ct)) > 0)
            throw ApiProblemException.Invalid("V-FIN-CONSOLIDATION", "Remove the units before the statement becomes standalone.");
        await DuplicateAsync(u, tx, s.CompanyId, f, s.VersionNo, s.FinancialStatementId, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.FinancialStatement
               SET PeriodType = @pt, PeriodStart = @ps, PeriodEnd = @pe, FiscalYear = @fy, Basis = @b, Assurance = @a, Nature = @n, CurrencyId = @cur, UnitScale = @us,
                   AccountingStandard = @std, AuditorName = @aud, AuditOpinion = @op, GoingConcernUncertainty = @gc, EntryMethod = @em, SourceDocumentId = @doc,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FinancialStatementId = @id;
            """, new
        {
            pt = f.PeriodType, ps = f.PeriodStart, pe = f.PeriodEnd, fy = f.FiscalYear, b = f.Basis, a = f.Assurance, n = f.Nature, cur = f.Currency, us = f.UnitScale,
            std = f.Standard, aud = f.Auditor, op = f.Opinion, gc = f.GoingConcern, em = f.EntryMethod, doc = f.Document, id = s.FinancialStatementId,
        }, tx, cancellationToken: ct));
        if (f.UnitScale != s.UnitScale)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE fin.StatementLine SET EnteredAmount = EnteredAmount / @old * @new, ComputedAmount = ComputedAmount / @old * @new, UpdatedAt = SYSUTCDATETIME(),
                       UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                 WHERE StatementId = @s;
                """, new { s = s.FinancialStatementId, old = (decimal)s.UnitScale, @new = (decimal)f.UnitScale }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// The grid's save (FR-FIN-002): each line given is set, in the unit of the statement; an amount left out of the body
    /// keeps its value and a null clears it. An incomplete draft is saved. The totals are computed again.
    /// </summary>
    private static async Task<IResult> LinesAsync(Guid id, StatementLinesRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Lines is null || b.Lines.Length == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the lines to save.");
        if (b.Lines.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A save has at most 1,000 lines.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        Draft(s);
        var catalog = await CatalogAsync(u, tx, ct);
        var byCode = catalog.ToDictionary(l => l.Code, StringComparer.Ordinal);
        var stored = await LinesOfAsync(u, tx, s.FinancialStatementId, ct);
        var shown = Shown(catalog, stored);
        var entered = Entered(shown, stored);
        var unknown = new List<string>();
        foreach (var line in b.Lines)
        {
            var code = line.Code?.Trim().ToUpperInvariant() ?? "";
            if (!byCode.TryGetValue(code, out var item) || (!item.IsActive && !stored.ContainsKey(item.LineCatalogItemId))) { unknown.Add(code); continue; }
            if (line.Amount is { } a && Math.Abs(a) > 1_000_000_000_000_000m / s.UnitScale)
                throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The amount of {code} is too large.");
            if (!shown.Contains(item)) shown.Add(item);
            entered[code] = line.Amount is { } x ? Math.Round(StatementMath.Scale(x, s.UnitScale), 4) : null;
        }
        if (unknown.Count > 0) throw ApiProblemException.Invalid("V-FIN-LINE", $"Not lines of the catalogue: {string.Join(", ", unknown.Take(10))}.");
        await SaveDraftLinesAsync(u, tx, s.FinancialStatementId, shown, entered, ct);
        var method = b.EntryMethod is null ? s.EntryMethod : Pick(b.EntryMethod, ["MANUAL", "PASTE"], "entry method");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE fin.FinancialStatement SET EntryMethod = @m, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FinancialStatementId = @s;",
            new { m = method, s = s.FinancialStatementId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        var check = StatementMath.Check([.. shown.Select(l => l.Def)], entered, s.UnitScale);
        return Results.Ok(new { check = CheckShape(check, s.UnitScale) });
    }

    /// <summary>
    /// FR-FIN-003: pasted rows matched to the catalogue by code, by name (Arabic or English) or by an alias, with the
    /// rows that match nothing. Nothing is written: the grid saves what the user confirms.
    /// </summary>
    private static async Task<IResult> PastePreviewAsync(Guid id, PasteRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Rows is null || b.Rows.Length == 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the pasted rows.");
        if (b.Rows.Length > 1000) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A paste has at most 1,000 rows.");
        var s = await FindAsync(u, null, id, scope, ct);
        Draft(s);
        var catalog = (await CatalogAsync(u, null, ct)).Where(l => l.IsActive).ToList();
        var aliases = await u.Connection.QueryAsync<(int Id, string Alias)>(new CommandDefinition(
            "SELECT LineCatalogItemId, Alias FROM fin.LineCatalogItemAlias;", cancellationToken: ct));
        static string Key(string t) => string.Join(' ', t.Trim().ToUpperInvariant().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        var index = new Dictionary<string, CatalogLine>(StringComparer.Ordinal);
        foreach (var l in catalog)
        {
            index.TryAdd(Key(l.Code), l);
            index.TryAdd(Key(l.NameAr), l);
            if (l.NameEn is not null) index.TryAdd(Key(l.NameEn), l);
        }
        foreach (var a in aliases)
            if (catalog.FirstOrDefault(l => l.LineCatalogItemId == a.Id) is { } l) index.TryAdd(Key(a.Alias), l);
        var matched = new List<object>();
        var unmatched = new List<object>();
        for (var i = 0; i < b.Rows.Length; i++)
        {
            var r = b.Rows[i];
            if (r.Label is { } label && index.TryGetValue(Key(label), out var line))
                matched.Add(new { row = i + 1, label, code = line.Code, nameAr = line.NameAr, nameEn = line.NameEn, amount = r.Amount, isTotal = line.IsTotal });
            else unmatched.Add(new { row = i + 1, label = r.Label, amount = r.Amount });
        }
        return Results.Ok(new { matched, unmatched });
    }

    // ---------- the lifecycle ----------

    private static Dictionary<string, object?> Values(Row s, string stageAr, string stageEn) => new()
    {
        ["companyName"] = new Dictionary<string, string?> { ["ar"] = s.CompanyNameAr, ["en"] = s.CompanyNameEn ?? s.CompanyNameAr },
        ["statementLabel"] = new Dictionary<string, string>
        {
            ["ar"] = $"{FacilityEndpoints.D(s.PeriodEnd)} ({(s.Basis == "CONSOLIDATED" ? "موحدة" : "منفردة")}، الإصدار {s.VersionNo})",
            ["en"] = $"{FacilityEndpoints.D(s.PeriodEnd)} ({(s.Basis == "CONSOLIDATED" ? "consolidated" : "standalone")}, version {s.VersionNo})",
        },
        ["stageLabel"] = new Dictionary<string, string> { ["ar"] = stageAr, ["en"] = stageEn },
    };

    /// <summary>
    /// V-FIN-01 and BR-FIN-002: required lines filled, an imbalance explained, an audited statement with its auditor and
    /// opinion, a consolidated one with its units; then the lines as submitted and the submitter as the preparer.
    /// </summary>
    private static async Task<IResult> SubmitAsync(Guid id, StatementSubmitRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        Draft(s);
        if (s.Nature == "BUDGET") throw ApiProblemException.Invalid("V-FIN-BUDGET", "A budget stays a draft: it is assessed as a trial, not submitted (BR-FIN-039).");
        if (s.Assurance == "AUDITED" && (s.AuditorName is null || s.AuditOpinion is null))
            throw ApiProblemException.Invalid("V-FIN-AUDIT", "An audited statement is submitted with its auditor and the auditor's opinion (BR-FIN-012).");
        if (s.Basis == "CONSOLIDATED")
        {
            var roles = (await u.Connection.QueryAsync<string>(new CommandDefinition(
                "SELECT Role FROM fin.ConsolidationMember WHERE StatementId = @s;", new { s = s.FinancialStatementId }, tx, cancellationToken: ct))).ToList();
            if (roles.Count(r => r == "PARENT") != 1 || roles.All(r => r == "PARENT"))
                throw ApiProblemException.Invalid("V-FIN-CONSOLIDATION", "A consolidated statement is submitted with the holding as its parent unit and every unit it consolidates (BR-FIN-013).");
        }
        var catalog = await CatalogAsync(u, tx, ct);
        var stored = await LinesOfAsync(u, tx, s.FinancialStatementId, ct);
        var shown = Shown(catalog, stored);
        var defs = shown.Select(l => l.Def).ToList();
        var entered = Entered(shown, stored);
        var check = StatementMath.Check(defs, entered, s.UnitScale);
        if (!check.CanSubmit)
            throw ApiProblemException.Invalid("V-FIN-01", $"Required lines are empty: {string.Join(", ", check.MissingRequired.Take(10))}.");
        var reason = Trimmed(b.BalanceReason, 500, "reason");
        if (!check.Balanced && reason is null)
            throw ApiProblemException.Invalid("V-FIN-01-BALANCE", "The assets differ from the liabilities and equity: give the reason to submit (FR-FIN-004).");
        var ids = shown.ToDictionary(l => l.Code, l => l.LineCatalogItemId, StringComparer.Ordinal);
        await WriteLinesAsync(u, tx, s.FinancialStatementId, StatementMath.ForSubmission(defs, entered).Select(l => (ids[l.Code], l.EnteredAmount, l.ComputedAmount)), ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.FinancialStatement
               SET Status = 'SUBMITTED', PreparedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), PreparedOn = SYSUTCDATETIME(), BalanceReason = @r,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FinancialStatementId = @s;
            """, new { r = check.Balanced ? null : reason, s = s.FinancialStatementId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("STATEMENT_SUBMITTED", "TREASURY", "fin.FinancialStatement", s.FinancialStatementId,
            AfterJson: JsonSerializer.Serialize(new { balanced = check.Balanced, balanceReason = check.Balanced ? null : reason })), s.CompanyId, ct);
        await Notifier.RequestAsync(u.Connection, tx, new NotificationRequest("FIN.STATEMENT_PENDING", "fin.FinancialStatement", s.FinancialStatementId,
            $"FIN.STATEMENT_PENDING:{s.FinancialStatementId}:SUBMITTED:{DateTime.UtcNow:yyyyMMddHHmmss}", s.CompanyId,
            Values(s, "بانتظار الاعتماد", "waiting for approval"), $"/financial-statements/{s.PublicId}", u.UserId), ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "SUBMITTED", balanced = check.Balanced });
    }

    /// <summary>
    /// FR-FIN-006 and BR-FIN-004: another user approves; the approved version of the series is superseded first (one
    /// approved per series), then this one is approved; the covenant tests are re-evaluated after the commit (OQ-13).
    /// </summary>
    private static async Task<IResult> ApproveAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Approve, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (s.Status != "SUBMITTED") throw new ApiProblemException(409, "STATEMENT_STATE", "Only a submitted statement is approved.");
        if (s.PreparedBy == u.UserId) throw ApiProblemException.Forbidden("V-FIN-SOD", "The preparer of a statement does not approve it; another user does (FR-FIN-006).");
        var superseded = await u.Connection.QueryAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            UPDATE fin.FinancialStatement
               SET Status = 'SUPERSEDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.FinancialStatementId INTO @o
             WHERE CompanyId = @c AND Basis = @b AND Assurance = @a AND PeriodType = @p AND PeriodEnd = @e AND Status = 'APPROVED' AND FinancialStatementId <> @s;
            SELECT Id FROM @o;
            """, new { c = s.CompanyId, b = s.Basis, a = s.Assurance, p = s.PeriodType, e = s.PeriodEnd, s = s.FinancialStatementId }, tx, cancellationToken: ct));
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.FinancialStatement
               SET Status = 'APPROVED', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FinancialStatementId = @s;
            """, new { s = s.FinancialStatementId }, tx, cancellationToken: ct));
        var previous = superseded.ToList();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("STATEMENT_APPROVED", "TREASURY", "fin.FinancialStatement", s.FinancialStatementId,
            AfterJson: JsonSerializer.Serialize(new { superseded = previous })), s.CompanyId, ct);
        await Outbox.EmitAsync(u.Connection, tx, "statement.approved", "fin.FinancialStatement", s.FinancialStatementId, new
        {
            statement = s.PublicId, company = s.CompanyPublicId, basis = s.Basis, periodEnd = FacilityEndpoints.D(s.PeriodEnd), fiscalYear = s.FiscalYear,
            supersededIds = previous,
        }, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "APPROVED", superseded = previous.Count, reevaluation = "PENDING" });
    }

    private static async Task<IResult> RejectAsync(Guid id, StatementReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Approve, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var reason = Trimmed(b.Reason, 500, "reason") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for returning the statement.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (s.Status != "SUBMITTED") throw new ApiProblemException(409, "STATEMENT_STATE", "Only a submitted statement is returned.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE fin.FinancialStatement SET Status = 'REJECTED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FinancialStatementId = @s;",
            new { s = s.FinancialStatementId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("STATEMENT_REJECTED", "TREASURY", "fin.FinancialStatement", s.FinancialStatementId,
            AfterJson: JsonSerializer.Serialize(new { reason })), s.CompanyId, ct);
        if (s.PreparedBy is { } preparer)
            await Notifier.RequestAsync(u.Connection, tx, new NotificationRequest("FIN.STATEMENT_PENDING", "fin.FinancialStatement", s.FinancialStatementId,
                $"FIN.STATEMENT_PENDING:{s.FinancialStatementId}:REJECTED:{DateTime.UtcNow:yyyyMMddHHmmss}", s.CompanyId,
                Values(s, "أعيدت إلى مُعِدّها", "returned to its preparer"), $"/financial-statements/{s.PublicId}", u.UserId, [preparer]), ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "REJECTED" });
    }

    private static async Task<IResult> ReopenAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (s.Status != "REJECTED") throw new ApiProblemException(409, "STATEMENT_STATE", "Only a returned statement is reopened as a draft.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE fin.FinancialStatement SET Status = 'DRAFT', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE FinancialStatementId = @s;",
            new { s = s.FinancialStatementId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("STATEMENT_REOPENED", "TREASURY", "fin.FinancialStatement", s.FinancialStatementId), s.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "DRAFT" });
    }

    /// <summary>
    /// FR-FIN-005: a change of an approved statement is a new version with its reason (RESTATED or CORRECTION), a draft
    /// copy of its header, lines and units; it has no effect until approved (BR-FIN-004). One live successor per version.
    /// </summary>
    private static async Task<IResult> NewVersionAsync(Guid id, StatementReasonRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var reason = Pick(b.Reason, ["RESTATED", "CORRECTION"], "reason of the version");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        if (s.Status != "APPROVED") throw new ApiProblemException(409, "STATEMENT_STATE", "A new version is made from the approved statement; a draft is edited as it is.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM fin.FinancialStatement WHERE SupersedesId = @s AND Status <> 'REJECTED';", new { s = s.FinancialStatementId }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-FIN-VERSION-OPEN", "This statement already has a new version in progress; open it.");
        var version = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT MAX(VersionNo) FROM fin.FinancialStatement WHERE CompanyId = @c AND PeriodType = @p AND PeriodEnd = @e AND Basis = @b AND Assurance = @a AND Nature = @n;",
            new { c = s.CompanyId, p = s.PeriodType, e = s.PeriodEnd, b = s.Basis, a = s.Assurance, n = s.Nature }, tx, cancellationToken: ct)) + 1;
        var f = new Fields(s.PeriodType, s.PeriodStart, s.PeriodEnd, s.FiscalYear, s.Basis, s.Assurance, s.Nature, s.CurrencyId, s.UnitScale, s.AccountingStandard,
            s.AuditorName, s.AuditOpinion, s.GoingConcernUncertainty, s.EntryMethod, s.SourceDocumentId);
        var made = await InsertAsync(u, tx, s.CompanyId, f, version, reason, s.FinancialStatementId, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT fin.StatementLine (TenantId, StatementId, LineCatalogItemId, EnteredAmount, ComputedAmount, CreatedBy)
            SELECT TenantId, @n, LineCatalogItemId, EnteredAmount, ComputedAmount, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) FROM fin.StatementLine WHERE StatementId = @s;
            INSERT fin.ConsolidationMember (TenantId, StatementBasis, StatementId, MemberCompanyId, Role, Method, OwnershipPct, IncludedFrom, IncludedTo, MemberStatementId, Note, CreatedBy)
            SELECT TenantId, StatementBasis, @n, MemberCompanyId, Role, Method, OwnershipPct, IncludedFrom, IncludedTo, MemberStatementId, Note, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM fin.ConsolidationMember WHERE StatementId = @s;
            """, new { n = made.Id, s = s.FinancialStatementId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("STATEMENT_VERSION_CREATED", "TREASURY", "fin.FinancialStatement", made.Id,
            AfterJson: JsonSerializer.Serialize(new { versionNo = version, reason, supersedes = s.PublicId })), s.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/financial-statements/{made.PublicId}", new { id = made.PublicId, versionNo = version });
    }

    // ---------- consolidation units ----------

    private static async Task<IResult> UnitsAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var s = await FindAsync(u, null, id, scope, ct);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT c.PublicId AS company, c.NameAr AS nameAr, c.NameEn AS nameEn, v.Role AS role, v.Method AS method, v.OwnershipPct AS ownershipPct,
                   v.RecordedOwnershipPct AS recordedOwnershipPct, v.IncludedFrom AS includedFrom, v.IncludedTo AS includedTo, v.HasStandalone AS hasStandalone,
                   ms.PublicId AS standaloneStatement, v.StandaloneAssurance AS standaloneAssurance, m.Note AS note
              FROM fin.v_ConsolidationUnits AS v
              JOIN fin.ConsolidationMember AS m ON m.StatementId = v.StatementId AND m.MemberCompanyId = v.MemberCompanyId
              JOIN org.Company AS c ON c.CompanyId = v.MemberCompanyId
              LEFT JOIN fin.FinancialStatement AS ms ON ms.FinancialStatementId = v.StandaloneStatementId
             WHERE v.StatementId = @s
             ORDER BY CASE v.Role WHEN 'PARENT' THEN 0 WHEN 'SUBSIDIARY' THEN 1 WHEN 'JOINT_VENTURE' THEN 2 ELSE 3 END, c.NameAr;
            """, new { s = s.FinancialStatementId }, cancellationToken: ct));
        return Results.Ok(new { items = rows });
    }

    /// <summary>A unit of a draft consolidated statement (FR-FIN-015, BR-FIN-013), its role and method checked as the model checks them; a second call for a company replaces its row.</summary>
    private static async Task<IResult> AddUnitAsync(Guid id, ConsolidationUnitRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Company is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company of the unit.");
        var role = Pick(b.Role, ["PARENT", "SUBSIDIARY", "ASSOCIATE", "JOINT_VENTURE"], "role");
        var method = Pick(b.Method, ["FULL", "EQUITY", "PROPORTIONATE", "NOT_CONSOLIDATED"], "method", role == "PARENT" ? "FULL" : null);
        var allowed = role switch
        {
            "PARENT" => ["FULL"],
            "SUBSIDIARY" => ["FULL", "NOT_CONSOLIDATED"],
            "ASSOCIATE" => ["EQUITY", "NOT_CONSOLIDATED"],
            _ => new[] { "EQUITY", "PROPORTIONATE", "NOT_CONSOLIDATED" },
        };
        if (!allowed.Contains(method)) throw ApiProblemException.Invalid("V-FIN-UNIT", $"A {role.ToLowerInvariant().Replace('_', ' ')} is consolidated by {string.Join(", ", allowed)} (BR-FIN-013).");
        if (role == "PARENT" ? b.OwnershipPct is not null : b.OwnershipPct is not (> 0 and <= 100))
            throw ApiProblemException.Invalid("V-FIN-UNIT", role == "PARENT" ? "The holding has no ownership percentage." : "Give the ownership at the period end, above 0 and at most 100 percent.");
        var from = LimitEndpoints.Date(b.IncludedFrom, "date of entry");
        var to = LimitEndpoints.Date(b.IncludedTo, "date of exit");
        if (from is not null && to is not null && to < from) throw ApiProblemException.Invalid("V-FIN-UNIT", "A unit leaves on or after the day it entered.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        Draft(s);
        if (s.Basis != "CONSOLIDATED") throw ApiProblemException.Invalid("V-FIN-CONSOLIDATION", "Units belong to a consolidated statement.");
        var member = await CompanyEndpoints.FindAsync(u, tx, b.Company.Value, scope, ct);
        if ((role == "PARENT") != (member.CompanyId == s.CompanyId))
            throw ApiProblemException.Invalid("V-FIN-CONSOLIDATION", "The parent unit is the holding itself, and the holding is no other unit (BR-FIN-013).");
        long? memberStatement = null;
        if (b.MemberStatement is { } ms)
        {
            if (role == "PARENT") throw ApiProblemException.Invalid("V-FIN-UNIT", "The holding's standalone statement does not stand for the consolidated one.");
            memberStatement = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT FinancialStatementId FROM fin.FinancialStatement WHERE PublicId = @ms AND CompanyId = @c AND Basis = 'STANDALONE';",
                new { ms, c = member.CompanyId }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("V-FIN-UNIT", "The unit's statement is a standalone statement of that company.");
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            DELETE fin.ConsolidationMember WHERE StatementId = @s AND MemberCompanyId = @m;
            INSERT fin.ConsolidationMember (TenantId, StatementBasis, StatementId, MemberCompanyId, Role, Method, OwnershipPct, IncludedFrom, IncludedTo, MemberStatementId, Note, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'CONSOLIDATED', @s, @m, @role, @method, @pct, @from, @to, @ms, @note, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { s = s.FinancialStatementId, m = member.CompanyId, role, method, pct = b.OwnershipPct, from, to, ms = memberStatement, note = Trimmed(b.Note, 500, "note") },
            tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveUnitAsync(Guid id, Guid company, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var s = await FindAsync(u, tx, id, scope, ct, lockRow: true);
        Draft(s);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            "DELETE m FROM fin.ConsolidationMember AS m JOIN org.Company AS c ON c.CompanyId = m.MemberCompanyId WHERE m.StatementId = @s AND c.PublicId = @c;",
            new { s = s.FinancialStatementId, c = company }, tx, cancellationToken: ct));
        if (n == 0) throw ApiProblemException.NotFound();
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }
}
