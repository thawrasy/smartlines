using System.Data;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Core.Finance;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record LineItemRequest(string? Code, string? NameAr, string? NameEn, string? Description, string? Section, int? SortOrder, bool? IsRequired, bool? IsActive);
public sealed record LineAliasRequest(string? Alias);
public sealed record RevenueEstimateRequest(Guid? Company, int? FiscalYear, string? Basis, decimal? Amount, string? Currency, string? BasisNote, Guid? Document);

/// <summary>
/// The statement line catalogue of the tenant (FR-FIN-001, FR-FIN-003) and the manual revenue estimates (FR-FIN-019,
/// BR-FIN-008). The 157 standard lines come from the pack FIN.LINES; the tenant renames, orders and deactivates the
/// lines that are not locked and adds its own (063 keeps the codes, sections and formulas of the system lines); the
/// aliases match pasted names. A revenue estimate is a draft of its preparer, approved by another user; the approved
/// one of the same company, year and basis is superseded first (one approved per year and basis).
/// </summary>
public static partial class FinanceCatalogEndpoints
{
    private const string CatalogManage = "cat.manage.financial";
    private static readonly string[] Sections = ["BS_ASSET", "BS_LIABILITY", "BS_EQUITY", "IS", "CF", "MEMO"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/line-catalogue", CatalogueAsync);
        api.MapPost("/line-catalogue", AddLineAsync);
        api.MapPatch("/line-catalogue/{code}", ChangeLineAsync);
        api.MapPost("/line-catalogue/{code}/aliases", AddAliasAsync);
        api.MapDelete("/line-catalogue/{code}/aliases/{alias}", RemoveAliasAsync);
        api.MapGet("/revenue-estimates", EstimatesAsync);
        api.MapPost("/revenue-estimates", CreateEstimateAsync);
        api.MapPatch("/revenue-estimates/{id:guid}", ChangeEstimateAsync);
        api.MapPost("/revenue-estimates/{id:guid}/actions/approve", ApproveEstimateAsync);
    }

    [GeneratedRegex("^[A-Z][A-Z0-9_]{1,79}$")]
    private static partial Regex CodePattern();

    // ---------- the line catalogue ----------

    private static async Task<IResult> CatalogueAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "includeInactive");
        var (u, _) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        var all = http.Request.Query["includeInactive"] == "true";
        var lines = await StatementEndpoints.CatalogAsync(u, null, ct);
        var aliases = (await u.Connection.QueryAsync<(int Id, string Alias)>(new CommandDefinition(
            "SELECT LineCatalogItemId, Alias FROM fin.LineCatalogItemAlias ORDER BY Alias;", cancellationToken: ct))).ToLookup(a => a.Id, a => a.Alias);
        return Results.Ok(new
        {
            items = lines.Where(l => all || l.IsActive).Select(l => new
            {
                code = l.Code, nameAr = l.NameAr, nameEn = l.NameEn, section = l.Section, kind = l.Kind, parent = l.ParentCode, isTotal = l.IsTotal,
                totalFormula = l.TotalFormula, isRequired = l.IsRequired, isActive = l.IsActive, isSystem = l.IsSystem, isLocked = l.IsLocked, sortOrder = l.SortOrder,
                isMain = LineCatalog.SpecLines.Contains(l.Code) || !l.IsSystem, aliases = aliases[l.LineCatalogItemId],
            }),
        });
    }

    private static string Name(string? text, string label, bool required)
    {
        var t = text?.Trim();
        if (string.IsNullOrEmpty(t)) return required ? throw ApiProblemException.Invalid("VALIDATION_FAILED", $"Give the {label}.") : "";
        return t.Length <= 200 ? t : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {label} has at most 200 characters.");
    }

    /// <summary>A line of the tenant (FR-FIN-001): its code, names and section; it enters no total and shows in the entry grid.</summary>
    private static async Task<IResult> AddLineAsync(LineItemRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, CatalogManage, statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        var code = b.Code?.Trim().ToUpperInvariant() ?? "";
        if (!CodePattern().IsMatch(code)) throw ApiProblemException.Invalid("V-CAT-CODE", "A code is capital letters, digits and underscores, starting with a letter (BR-CAT-001).");
        var section = b.Section?.Trim().ToUpperInvariant();
        if (section is null || !Sections.Contains(section)) throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The section is one of {string.Join(", ", Sections)}.");
        var nameAr = Name(b.NameAr, "Arabic name", true);
        var nameEn = Name(b.NameEn, "English name", true);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM fin.LineCatalogItem WHERE Code = @code;", new { code }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-CAT-DUPLICATE", "A line with this code exists.");
        var order = b.SortOrder ?? await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT ISNULL(MAX(SortOrder), 0) + 1 FROM fin.LineCatalogItem WHERE Section = @section;", new { section }, tx, cancellationToken: ct));
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT fin.LineCatalogItem (TenantId, Code, NameAr, NameEn, Description, IsActive, IsSystem, IsLocked, SortOrder, Section, IsTotal, IsRequired, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @nameAr, @nameEn, @desc, 1, 0, 0, @order, @section, 0, @req, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { code, nameAr, nameEn, desc = b.Description?.Trim(), order, section, req = b.IsRequired ?? false }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LINE_ITEM_ADDED", "CONFIG", "fin.LineCatalogItem", null,
            AfterJson: JsonSerializer.Serialize(new { code, section })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/line-catalogue/{code}", new { code });
    }

    private sealed record ItemRow(int LineCatalogItemId, string NameAr, string? NameEn, string? Description, int SortOrder, bool IsActive, bool IsSystem, bool IsLocked, bool IsRequired);

    private static async Task<ItemRow> ItemAsync(BoundUser u, SqlTransaction? tx, string code, CancellationToken ct) =>
        await u.Connection.QuerySingleOrDefaultAsync<ItemRow>(new CommandDefinition(
            "SELECT LineCatalogItemId, NameAr, NameEn, Description, SortOrder, IsActive, IsSystem, IsLocked, IsRequired FROM fin.LineCatalogItem WHERE Code = @code;",
            new { code = code.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    /// <summary>Names, order and activity of a line; a locked line stays active, and the required flag of a system line stays as the pack set it.</summary>
    private static async Task<IResult> ChangeLineAsync(string code, LineItemRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, CatalogManage, statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        if (b.Code is not null || b.Section is not null)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The code and the section of a line do not change; another line is a new line.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var item = await ItemAsync(u, tx, code, ct);
        if (b.IsActive == false && item.IsLocked)
            throw ApiProblemException.Invalid("V-FIN-LOCKED", "This line is a total, a component of a total or read by a formula: it stays active (FR-FIN-001).");
        if (b.IsRequired is not null && item.IsSystem && b.IsRequired != item.IsRequired)
            throw ApiProblemException.Invalid("V-FIN-LOCKED", "Whether a standard line is required comes with the standard lines.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.LineCatalogItem
               SET NameAr = @nameAr, NameEn = @nameEn, Description = @desc, SortOrder = @order, IsActive = @active, IsRequired = @req,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE LineCatalogItemId = @id;
            """, new
        {
            nameAr = b.NameAr is null ? item.NameAr : Name(b.NameAr, "Arabic name", true), nameEn = b.NameEn is null ? item.NameEn : Name(b.NameEn, "English name", true),
            desc = b.Description is null ? item.Description : b.Description.Trim(), order = b.SortOrder ?? item.SortOrder, active = b.IsActive ?? item.IsActive,
            req = b.IsRequired ?? item.IsRequired, id = item.LineCatalogItemId,
        }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> AddAliasAsync(string code, LineAliasRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, CatalogManage, statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        var alias = Name(b.Alias, "alias", true);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var item = await ItemAsync(u, tx, code, ct);
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM fin.LineCatalogItemAlias WHERE Alias = @alias;", new { alias }, tx,
                cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-FIN-ALIAS", "This alias already names a line; an alias matches one line (FR-FIN-003).");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            INSERT fin.LineCatalogItemAlias (TenantId, LineCatalogItemId, Alias, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @id, @alias, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { id = item.LineCatalogItemId, alias }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> RemoveAliasAsync(string code, string alias, HttpContext http, SqlConnectionFactory db)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, CatalogManage, statements: false);
        await using var __ = u;
        var ct = http.RequestAborted;
        var item = await ItemAsync(u, null, code, ct);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition("DELETE fin.LineCatalogItemAlias WHERE LineCatalogItemId = @id AND Alias = @alias;",
            new { id = item.LineCatalogItemId, alias = alias.Trim() }, cancellationToken: ct));
        return n == 0 ? throw ApiProblemException.NotFound() : Results.NoContent();
    }

    // ---------- revenue estimates ----------

    private sealed class EstimateRow
    {
        public long RevenueEstimateId { get; init; }
        public Guid PublicId { get; init; }
        public long CompanyId { get; init; }
        public Guid CompanyPublicId { get; init; }
        public string CompanyNameAr { get; init; } = "";
        public int FiscalYear { get; init; }
        public string Basis { get; init; } = "";
        public decimal Amount { get; init; }
        public int CurrencyId { get; init; }
        public string CurrencyCode { get; init; } = "";
        public string BasisNote { get; init; } = "";
        public long? DocumentId { get; init; }
        public Guid? DocumentPublicId { get; init; }
        public string Status { get; init; } = "";
        public long? PreparedBy { get; init; }
        public DateTime? ApprovedOn { get; init; }
    }

    private const string EstimateSelect = """
        SELECT e.RevenueEstimateId, e.PublicId, e.CompanyId, c.PublicId AS CompanyPublicId, c.NameAr AS CompanyNameAr, e.FiscalYear, e.Basis, e.Amount, e.CurrencyId,
               cu.Code AS CurrencyCode, e.BasisNote, e.DocumentId, d.PublicId AS DocumentPublicId, e.Status, e.PreparedBy, e.ApprovedOn
          FROM fin.RevenueEstimate AS e
          JOIN org.Company AS c ON c.CompanyId = e.CompanyId
          JOIN ref.Currency AS cu ON cu.CurrencyId = e.CurrencyId
          LEFT JOIN doc.Document AS d ON d.DocumentId = e.DocumentId
        """;

    private static object Shape(EstimateRow e, long me) => new
    {
        id = e.PublicId, company = new { id = e.CompanyPublicId, nameAr = e.CompanyNameAr }, fiscalYear = e.FiscalYear, basis = e.Basis, amount = e.Amount,
        currency = e.CurrencyCode, basisNote = e.BasisNote, document = e.DocumentPublicId, status = e.Status, approvedOn = e.ApprovedOn, preparedByMe = e.PreparedBy == me,
    };

    private static async Task<EstimateRow> EstimateAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct, bool lockRow = false)
    {
        var e = await u.Connection.QuerySingleOrDefaultAsync<EstimateRow>(new CommandDefinition(
            EstimateSelect.Replace("FROM fin.RevenueEstimate AS e", lockRow ? "FROM fin.RevenueEstimate AS e WITH (UPDLOCK, HOLDLOCK)" : "FROM fin.RevenueEstimate AS e",
                StringComparison.Ordinal) + " WHERE e.PublicId = @id;", new { id }, tx, cancellationToken: ct));
        return e is not null && scope.Allows(e.CompanyId) ? e : throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> EstimatesAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company", "fiscalYear");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        int? year = q["fiscalYear"].Count > 0 ? (int.TryParse(q["fiscalYear"], CultureInfo.InvariantCulture, out var y) ? y
            : throw new ApiProblemException(400, "MALFORMED_REQUEST", "fiscalYear is a year.")) : null;
        var rows = await u.Connection.QueryAsync<EstimateRow>(new CommandDefinition(EstimateSelect + """
             WHERE (@company IS NULL OR c.PublicId = @company) AND (@year IS NULL OR e.FiscalYear = @year) AND (@all = 1 OR e.CompanyId IN @ids)
             ORDER BY e.FiscalYear DESC, c.NameAr, e.Basis, e.CreatedAt DESC;
            """, new { company, year, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(e => Shape(e, u.UserId)) });
    }

    private static (int Year, string Basis, decimal Amount, string Note) EstimateFields(RevenueEstimateRequest b, EstimateRow? was)
    {
        var year = b.FiscalYear ?? was?.FiscalYear ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the fiscal year.");
        if (year is < 1900 or > 2200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The fiscal year is a year from 1900 to 2200.");
        var basis = b.Basis?.Trim().ToUpperInvariant() ?? was?.Basis ?? "STANDALONE";
        if (basis is not ("STANDALONE" or "CONSOLIDATED")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The basis is STANDALONE or CONSOLIDATED.");
        var amount = b.Amount ?? was?.Amount ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the estimated revenue.");
        if (amount <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The estimated revenue is above zero.");
        var note = (b.BasisNote ?? was?.BasisNote)?.Trim();
        if (string.IsNullOrEmpty(note)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the source of the estimate (an approved budget, the management's forecast...).");
        if (note.Length > 500) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The source of the estimate has at most 500 characters.");
        return (year, basis, amount, note);
    }

    private static async Task<long?> DocumentAsync(BoundUser u, SqlTransaction tx, Guid? document, long company, long? was, CancellationToken ct) =>
        document is not { } d ? was
            : await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                  "SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE' AND (OwnerCompanyId IS NULL OR OwnerCompanyId = @c);", new { d, c = company }, tx,
                  cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The document is not an active document of the company.");

    private static async Task<IResult> CreateEstimateAsync(RevenueEstimateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Company is null || b.Currency is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the company and the currency of the estimate.");
        var (year, basis, amount, note) = EstimateFields(b, null);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var company = await CompanyEndpoints.FindAsync(u, tx, b.Company.Value, scope, ct);
        if (basis == "CONSOLIDATED" && !company.IsHolding)
            throw ApiProblemException.Invalid("V-FIN-CONSOLIDATION", "Only a holding has a consolidated revenue (BR-FIN-013).");
        var currency = await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct);
        var doc = await DocumentAsync(u, tx, b.Document, company.CompanyId, null, ct);
        var made = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
            INSERT fin.RevenueEstimate (TenantId, CompanyId, FiscalYear, Basis, Amount, CurrencyId, BasisNote, DocumentId, Status, PreparedBy, CreatedBy)
            OUTPUT inserted.RevenueEstimateId, inserted.PublicId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @y, @b, @a, @cur, @n, @doc, 'DRAFT', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id, PublicId FROM @o;
            """, new { c = company.CompanyId, y = year, b = basis, a = amount, cur = currency, n = note, doc }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REVENUE_ESTIMATE_CREATED", "TREASURY", "fin.RevenueEstimate", made.Id,
            AfterJson: JsonSerializer.Serialize(new { fiscalYear = year, basis })), company.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/revenue-estimates/{made.PublicId}", new { id = made.PublicId });
    }

    /// <summary>A draft estimate changes in its preparer's name (the editor becomes the preparer, 058).</summary>
    private static async Task<IResult> ChangeEstimateAsync(Guid id, RevenueEstimateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Enter, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.Company is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The company of an estimate does not change.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var e = await EstimateAsync(u, tx, id, scope, ct, lockRow: true);
        if (e.Status != "DRAFT") throw new ApiProblemException(409, "APPROVED_FINAL", "An approved estimate does not change; a change is a new estimate that supersedes it.");
        var (year, basis, amount, note) = EstimateFields(b, e);
        var currency = b.Currency is null ? e.CurrencyId : await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct);
        var doc = await DocumentAsync(u, tx, b.Document, e.CompanyId, e.DocumentId, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.RevenueEstimate
               SET FiscalYear = @y, Basis = @b, Amount = @a, CurrencyId = @cur, BasisNote = @n, DocumentId = @doc, PreparedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RevenueEstimateId = @id;
            """, new { y = year, b = basis, a = amount, cur = currency, n = note, doc, id = e.RevenueEstimateId }, tx, cancellationToken: ct));
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    private static async Task<IResult> ApproveEstimateAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.Approve, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var e = await EstimateAsync(u, tx, id, scope, ct, lockRow: true);
        if (e.Status != "DRAFT") throw new ApiProblemException(409, "STATEMENT_STATE", "Only a draft estimate is approved.");
        if (e.PreparedBy == u.UserId) throw ApiProblemException.Forbidden("V-FIN-SOD", "The preparer of an estimate does not approve it; another user does (FR-FIN-019).");
        var superseded = await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fin.RevenueEstimate SET Status = 'SUPERSEDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE CompanyId = @c AND FiscalYear = @y AND Basis = @b AND Status = 'APPROVED';
            UPDATE fin.RevenueEstimate
               SET Status = 'APPROVED', ApprovedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), ApprovedOn = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RevenueEstimateId = @id;
            """, new { c = e.CompanyId, y = e.FiscalYear, b = e.Basis, id = e.RevenueEstimateId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("REVENUE_ESTIMATE_APPROVED", "TREASURY", "fin.RevenueEstimate", e.RevenueEstimateId), e.CompanyId, ct);
        await Outbox.EmitAsync(u.Connection, tx, "revenue.estimate.approved", "fin.RevenueEstimate", e.RevenueEstimateId,
            new { estimate = e.PublicId, company = e.CompanyPublicId, fiscalYear = e.FiscalYear, basis = e.Basis }, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { status = "APPROVED", superseded = superseded > 1 });
    }
}
