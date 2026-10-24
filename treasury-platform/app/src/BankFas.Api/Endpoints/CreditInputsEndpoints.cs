using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record GuarantorRequest(Guid? Party, decimal? NetWorth, decimal? LiquidAssets, decimal? GuaranteesGiven, decimal? GuaranteedAmount, string? AsOfDate, Guid? Document);
public sealed record BureauRequest(string? ReportDate, Guid? Document, decimal? TotalLimits, decimal? TotalOutstanding, int? LenderCount, int? WorstDpd12m, int? WorstDpd24m,
    bool? CurrentDefault, int? Defaults24mCount, decimal? Defaults24mAmount, int? BouncedCheques12mCount, decimal? BouncedCheques12mAmount, int? JudgmentsCount,
    decimal? JudgmentsAmount, int? Inquiries6m, bool? Restructured);
public sealed record ProductLineRequest(Guid? Company, int? FiscalYear, string? NameAr, string? Category, decimal? RevenueSharePct, decimal? InventorySharePct,
    decimal? CashSalesPct, decimal? GovernmentSalesPct, decimal? ExportSalesPct, int? TypicalCreditDays);
public sealed record LenderDecisionRequest(Guid? Lender, string? DecisionDate, string? EffectiveDate, string? LimitAction, decimal? NewLimitAmount, int? MarginChangeBp,
    int? FeesChangeBp, string? Note, Guid? SourceDocument, string? SourcePage, string? OriginalText, string? NoSourceReason);

/// <summary>
/// What the analyst gives the credit assessment beside its statement (spec 12 FR-FIN-026 to 029 and 034; docs/35; ADR
/// 0021 and 0022), deferred from S2B-F and built after the external review 9.0 (docs/47 §4):
/// - the guarantors of an assessment, each with its net worth, liquid assets, the guarantees it already gave, the amount
///   it guarantees here, the date of those figures and their document (BR-FIN-026);
/// - the credit bureau report of an assessment, one per assessment (FR-FIN-026);
/// - the product lines of a company for a fiscal year, by category of the methodology, with their shares of revenue and
///   inventory and their sales mix (FR-FIN-028); the lines a computed assessment read are frozen by the database (058);
/// - the lender's actual decision on a facility (FR-FIN-034): kept, undrawn stopped, limit reduced to an amount, or not
///   renewed, with its dates and source; the latest one in force on the assessment date replaces the estimate of the
///   lender's stance for that facility (047), and the readiness reads it (049).
/// The guarantors and the bureau report change only while the assessment is a draft (046, 50063): a change asks for a
/// new computation before the submission, as any input does.
/// </summary>
public static class CreditInputsEndpoints
{
    private const string GuarantorKind = "assessment-guarantor";
    private const string DecisionKind = "lender-decision";
    private static readonly string[] LimitActions = ["MAINTAINED", "UNDRAWN_STOPPED", "LIMIT_REDUCED", "NOT_RENEWED"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/fin/assessments/{id:guid}/guarantors", GuarantorsAsync);
        api.MapPost("/fin/assessments/{id:guid}/guarantors", AddGuarantorAsync);
        api.MapDelete("/fin/assessments/{id:guid}/guarantors/{guarantor}", RemoveGuarantorAsync);
        api.MapGet("/fin/assessments/{id:guid}/bureau", BureauAsync);
        api.MapPut("/fin/assessments/{id:guid}/bureau", SetBureauAsync);
        api.MapDelete("/fin/assessments/{id:guid}/bureau", RemoveBureauAsync);
        api.MapGet("/fin/product-categories", CategoriesAsync);
        api.MapGet("/fin/product-lines", ProductLinesAsync);
        api.MapPost("/fin/product-lines", AddProductLineAsync);
        api.MapDelete("/fin/product-lines/{id:guid}", RemoveProductLineAsync);
        api.MapGet("/facilities/{id:guid}/lender-decisions", DecisionsAsync);
        api.MapPost("/facilities/{id:guid}/lender-decisions", AddDecisionAsync);
        api.MapPost("/facilities/{id:guid}/lender-decisions/{decision}/actions/verify", VerifyDecisionAsync);
    }

    private static async Task<long> DocumentAsync(BoundUser u, SqlTransaction? tx, Guid? document, string message, CancellationToken ct) =>
        document is { } d
            ? await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT DocumentId FROM doc.Document WHERE PublicId = @d AND Status = 'ACTIVE';", new { d }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", message)
            : throw ApiProblemException.Invalid("VALIDATION_FAILED", message);

    /// <summary>The assessment, locked, that must still be a draft.</summary>
    private static async Task<CreditEndpoints.Head> DraftAsync(BoundUser u, SqlTransaction tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var a = await CreditEndpoints.FindAsync(u, tx, id, scope, ct, lockRow: true);
        return a.Status == "DRAFT" ? a : throw new ApiProblemException(409, "ASSESSMENT_STATE", "An assessment changes only as a draft; a returned one is reopened first.");
    }

    // ---------- guarantors ----------

    private sealed record GuarantorRow(long CreditAssessmentGuarantorId, Guid Party, string? PartyNameAr, string? PartyNameEn, decimal NetWorth, decimal LiquidAssets,
        decimal GuaranteesGiven, decimal GuaranteedAmount, DateTime AsOfDate, Guid Document);

    private static async Task<IResult> GuarantorsAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await CreditEndpoints.FindAsync(u, null, id, scope, ct);
        var rows = await u.Connection.QueryAsync<GuarantorRow>(new CommandDefinition(
            """
            SELECT g.CreditAssessmentGuarantorId, p.PublicId AS Party, p.NameAr AS PartyNameAr, p.NameEn AS PartyNameEn, g.NetWorth, g.LiquidAssets, g.GuaranteesGiven,
                   g.GuaranteedAmount, g.AsOfDate, d.PublicId AS Document
              FROM fin.CreditAssessmentGuarantor AS g
              JOIN pty.Party AS p ON p.PartyId = g.PartyId
              JOIN doc.Document AS d ON d.DocumentId = g.DocumentId
             WHERE g.AssessmentId = @a ORDER BY g.CreditAssessmentGuarantorId;
            """, new { a = a.CreditAssessmentId }, cancellationToken: ct));
        return Results.Ok(new
        {
            items = rows.Select(g => new
            {
                id = refs.ItemRef(u.TenantId, GuarantorKind, g.CreditAssessmentGuarantorId), party = g.Party, partyNameAr = g.PartyNameAr, partyNameEn = g.PartyNameEn,
                netWorth = g.NetWorth, liquidAssets = g.LiquidAssets, guaranteesGiven = g.GuaranteesGiven, guaranteedAmount = g.GuaranteedAmount,
                asOfDate = FacilityEndpoints.D(g.AsOfDate), document = g.Document,
            }),
        });
    }

    /// <summary>BR-FIN-026: a guarantor's figures are dated and supported by a document; its liquid assets are part of its net worth.</summary>
    private static async Task<IResult> AddGuarantorAsync(Guid id, GuarantorRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        if (b.NetWorth is not { } worth || b.LiquidAssets is not { } liquid || b.GuaranteedAmount is not { } guaranteed)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the guarantor's net worth, liquid assets and the amount it guarantees.");
        var given = b.GuaranteesGiven ?? 0;
        if (worth < 0 || liquid < 0 || given < 0 || guaranteed <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The amounts are not negative, and the guaranteed amount is above zero.");
        if (liquid > worth) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The liquid assets are part of the net worth.");
        var on = LimitEndpoints.Date(b.AsOfDate, "date of the figures") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the guarantor's figures.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await DraftAsync(u, tx, id, scope, ct);
        var party = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT PartyId FROM pty.Party WHERE PublicId = @p AND IsActive = 1;", new { p = b.Party }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The guarantor is an active party on file.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM fin.CreditAssessmentGuarantor WHERE AssessmentId = @a AND PartyId = @party;", new { a = a.CreditAssessmentId, party }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "DUPLICATE", "This party is already a guarantor of the assessment.");
        var doc = await DocumentAsync(u, tx, b.Document, "The guarantor's figures come with their document, an active document on file.", ct);
        var gid = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT fin.CreditAssessmentGuarantor (TenantId, AssessmentId, PartyId, NetWorth, LiquidAssets, GuaranteesGiven, GuaranteedAmount, AsOfDate, DocumentId, CreatedBy)
            OUTPUT inserted.CreditAssessmentGuarantorId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @a, @party, @worth, @liquid, @given, @guaranteed, @on, @doc, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { a = a.CreditAssessmentId, party, worth, liquid, given, guaranteed, on, doc }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_GUARANTOR_ADDED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId,
            AfterJson: JsonSerializer.Serialize(new { guarantor = gid })), a.CompanyId, ct);
        await tx.CommitAsync(ct);
        var reference = refs.ItemRef(u.TenantId, GuarantorKind, gid);
        return Results.Created($"/api/v1/fin/assessments/{id}/guarantors/{reference}", new { id = reference });
    }

    private static async Task<IResult> RemoveGuarantorAsync(Guid id, string guarantor, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var gid = refs.ItemId(u.TenantId, GuarantorKind, guarantor) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await DraftAsync(u, tx, id, scope, ct);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition("DELETE fin.CreditAssessmentGuarantor WHERE CreditAssessmentGuarantorId = @gid AND AssessmentId = @a;",
            new { gid, a = a.CreditAssessmentId }, tx, cancellationToken: ct));
        if (n == 0) throw ApiProblemException.NotFound();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_GUARANTOR_REMOVED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId,
            AfterJson: JsonSerializer.Serialize(new { guarantor = gid })), a.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- the bureau report ----------

    private static async Task<IResult> BureauAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var a = await CreditEndpoints.FindAsync(u, null, id, scope, ct);
        var row = await u.Connection.QuerySingleOrDefaultAsync(new CommandDefinition(
            """
            SELECT b.ReportDate AS reportDate, d.PublicId AS document, b.TotalLimits AS totalLimits, b.TotalOutstanding AS totalOutstanding, b.LenderCount AS lenderCount,
                   b.WorstDpd12m AS worstDpd12m, b.WorstDpd24m AS worstDpd24m, b.CurrentDefault AS currentDefault, b.Defaults24mCount AS defaults24mCount,
                   b.Defaults24mAmount AS defaults24mAmount, b.BouncedCheques12mCount AS bouncedCheques12mCount, b.BouncedCheques12mAmount AS bouncedCheques12mAmount,
                   b.JudgmentsCount AS judgmentsCount, b.JudgmentsAmount AS judgmentsAmount, b.Inquiries6m AS inquiries6m, b.Restructured AS restructured
              FROM fin.CreditAssessmentBureau AS b JOIN doc.Document AS d ON d.DocumentId = b.DocumentId WHERE b.AssessmentId = @a;
            """, new { a = a.CreditAssessmentId }, cancellationToken: ct));
        return Results.Ok(new { report = row });
    }

    /// <summary>FR-FIN-026: the company's own bureau report, one per assessment; a second one replaces the first while the assessment is a draft.</summary>
    private static async Task<IResult> SetBureauAsync(Guid id, BureauRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var on = LimitEndpoints.Date(b.ReportDate, "report date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the bureau report.");
        if (b.TotalLimits is not { } limits || b.TotalOutstanding is not { } outstanding || b.LenderCount is not { } lenders)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the total limits, the total outstanding and the number of lenders the report shows.");
        int dpd12 = b.WorstDpd12m ?? 0, dpd24 = b.WorstDpd24m ?? dpd12;
        decimal[] amounts = [limits, outstanding, b.Defaults24mAmount ?? 0, b.BouncedCheques12mAmount ?? 0, b.JudgmentsAmount ?? 0];
        int[] counts = [lenders, dpd12, b.Defaults24mCount ?? 0, b.BouncedCheques12mCount ?? 0, b.JudgmentsCount ?? 0, b.Inquiries6m ?? 0];
        if (amounts.Any(x => x < 0) || counts.Any(x => x < 0)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The figures of the report are not negative.");
        if (dpd24 < dpd12) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The worst days past due over 24 months are at least those over 12 months.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await DraftAsync(u, tx, id, scope, ct);
        var doc = await DocumentAsync(u, tx, b.Document, "The bureau report is an active document on file.", ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            DELETE fin.CreditAssessmentBureau WHERE AssessmentId = @a;
            INSERT fin.CreditAssessmentBureau (TenantId, AssessmentId, ReportDate, DocumentId, TotalLimits, TotalOutstanding, LenderCount, WorstDpd12m, WorstDpd24m, CurrentDefault,
                                               Defaults24mCount, Defaults24mAmount, BouncedCheques12mCount, BouncedCheques12mAmount, JudgmentsCount, JudgmentsAmount, Inquiries6m,
                                               Restructured, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @a, @on, @doc, @limits, @outstanding, @lenders, @dpd12, @dpd24, @dflt, @dc, @da, @bc, @ba, @jc, @ja, @inq, @restr,
                    CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new
            {
                a = a.CreditAssessmentId, on, doc, limits, outstanding, lenders, dpd12, dpd24, dflt = b.CurrentDefault == true, dc = b.Defaults24mCount ?? 0, da = b.Defaults24mAmount ?? 0,
                bc = b.BouncedCheques12mCount ?? 0, ba = b.BouncedCheques12mAmount ?? 0, jc = b.JudgmentsCount ?? 0, ja = b.JudgmentsAmount ?? 0, inq = b.Inquiries6m ?? 0,
                restr = b.Restructured == true,
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_BUREAU_RECORDED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId), a.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { recorded = true });
    }

    private static async Task<IResult> RemoveBureauAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var a = await DraftAsync(u, tx, id, scope, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition("DELETE fin.CreditAssessmentBureau WHERE AssessmentId = @a;", new { a = a.CreditAssessmentId }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("CREDIT_BUREAU_REMOVED", "TREASURY", "fin.CreditAssessment", a.CreditAssessmentId), a.CompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- product lines ----------

    private static async Task<IResult> CategoriesAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (u, _) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var __ = u;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            "SELECT Code AS code, NameAr AS nameAr, NameEn AS nameEn FROM fin.ProductCategory ORDER BY Code;", cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> ProductLinesAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "company", "year");
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, FinanceAccess.View, statements: true);
        await using var _ = u;
        var q = http.Request.Query;
        Guid? company = q["company"].Count > 0 ? (Guid.TryParse(q["company"], out var g) ? g : throw new ApiProblemException(400, "MALFORMED_REQUEST", "company is an id.")) : null;
        int? year = q["year"].Count > 0 ? (int.TryParse(q["year"], out var y) ? y : throw new ApiProblemException(400, "MALFORMED_REQUEST", "year is a number.")) : null;
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT l.PublicId AS id, co.PublicId AS company, co.NameAr AS companyNameAr, l.FiscalYear AS fiscalYear, l.NameAr AS nameAr, pc.Code AS category,
                   pc.NameAr AS categoryNameAr, pc.NameEn AS categoryNameEn, l.RevenueSharePct AS revenueSharePct, l.InventorySharePct AS inventorySharePct,
                   l.CashSalesPct AS cashSalesPct, l.GovernmentSalesPct AS governmentSalesPct, l.ExportSalesPct AS exportSalesPct, l.TypicalCreditDays AS typicalCreditDays
              FROM fin.CompanyProductLine AS l
              JOIN org.Company AS co ON co.CompanyId = l.CompanyId
              JOIN fin.ProductCategory AS pc ON pc.ProductCategoryId = l.ProductCategoryId
             WHERE (@company IS NULL OR co.PublicId = @company) AND (@year IS NULL OR l.FiscalYear = @year) AND (@all = 1 OR l.CompanyId IN @ids)
             ORDER BY co.NameAr, l.FiscalYear DESC, l.RevenueSharePct DESC;
            """, new { company, year, all = scope.All ? 1 : 0, ids = scope.SqlIds }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    /// <summary>FR-FIN-028: a product line of a company's fiscal year; the revenue shares of a year add up to 100 percent at most.</summary>
    private static async Task<IResult> AddProductLineAsync(ProductLineRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        var name = b.NameAr?.Trim();
        if (string.IsNullOrEmpty(name) || name.Length > 200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Name the product line, at most 200 characters.");
        if (b.FiscalYear is not (>= 1900 and <= 2200) || b.RevenueSharePct is not (>= 0 and <= 100))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the fiscal year and the line's share of revenue, from 0 to 100 percent.");
        decimal inventory = b.InventorySharePct ?? 0, cash = b.CashSalesPct ?? 0, gov = b.GovernmentSalesPct ?? 0, export = b.ExportSalesPct ?? 0;
        if (inventory is < 0 or > 100 || cash < 0 || gov < 0 || export < 0 || cash + gov + export > 100)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The shares are from 0 to 100 percent, and cash, government and export sales add up to 100 percent at most.");
        if (b.TypicalCreditDays is < 0 or > 720) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The typical credit days are from 0 to 720.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var company = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT CompanyId FROM org.Company WHERE PublicId = @c;", new { c = b.Company }, tx,
            cancellationToken: ct)) is { } c && scope.Allows(c) ? c : throw ApiProblemException.NotFound();
        var category = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ProductCategoryId FROM fin.ProductCategory WHERE Code = @k;",
            new { k = b.Category?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The category is one of the methodology.");
        var total = await u.Connection.ExecuteScalarAsync<decimal>(new CommandDefinition(
            "SELECT ISNULL(SUM(RevenueSharePct), 0) FROM fin.CompanyProductLine WITH (UPDLOCK, HOLDLOCK) WHERE CompanyId = @company AND FiscalYear = @y;",
            new { company, y = b.FiscalYear }, tx, cancellationToken: ct));
        if (total + b.RevenueSharePct > 100) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The revenue shares of the year's product lines add up to 100 percent at most.");
        var id = await u.Connection.ExecuteScalarAsync<Guid>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id UNIQUEIDENTIFIER, RowId BIGINT);
            INSERT fin.CompanyProductLine (TenantId, CompanyId, FiscalYear, NameAr, ProductCategoryId, RevenueSharePct, InventorySharePct, CashSalesPct, GovernmentSalesPct,
                                           ExportSalesPct, TypicalCreditDays, CreatedBy)
            OUTPUT inserted.PublicId, inserted.CompanyProductLineId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @company, @y, @name, @category, @rev, @inventory, @cash, @gov, @export, @days, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { company, y = b.FiscalYear, name, category, rev = b.RevenueSharePct, inventory, cash, gov, export, days = b.TypicalCreditDays ?? 0 }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("PRODUCT_LINE_ADDED", "TREASURY", "org.Company", company,
            AfterJson: JsonSerializer.Serialize(new { line = id, year = b.FiscalYear })), company, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/fin/product-lines/{id}", new { id });
    }

    /// <summary>A line of a year that an approved assessment read is frozen by the database (058, 50173).</summary>
    private static async Task<IResult> RemoveProductLineAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (u, scope) = await FinanceAccess.OpenAsync(http, db, CreditEndpoints.Assess, statements: true);
        await using var _ = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var row = await u.Connection.QuerySingleOrDefaultAsync<(long Id, long Company)?>(new CommandDefinition(
            "SELECT CompanyProductLineId, CompanyId FROM fin.CompanyProductLine WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct));
        if (row is not { } r || !scope.Allows(r.Company)) throw ApiProblemException.NotFound();
        await u.Connection.ExecuteAsync(new CommandDefinition("DELETE fin.CompanyProductLine WHERE CompanyProductLineId = @i;", new { i = r.Id }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("PRODUCT_LINE_REMOVED", "TREASURY", "org.Company", r.Company,
            AfterJson: JsonSerializer.Serialize(new { line = id })), r.Company, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- the lender's actual decision on a facility ----------

    private sealed record DecisionRow(long FacilityLenderDecisionId, Guid? Lender, string? LenderNameAr, DateTime DecisionDate, DateTime EffectiveDate, string LimitAction,
        decimal? NewLimitAmount, int MarginChangeBp, int FeesChangeBp, string? Note, Guid? SourceDocument, string? SourcePage, string Confidence, long? CreatedBy);

    private static async Task<IResult> DecisionsAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.View);
        await using var _ = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, ct);
        var rows = await u.Connection.QueryAsync<DecisionRow>(new CommandDefinition(
            """
            SELECT x.FacilityLenderDecisionId, i.PublicId AS Lender, i.NameAr AS LenderNameAr, x.DecisionDate, x.EffectiveDate, x.LimitAction, x.NewLimitAmount, x.MarginChangeBp,
                   x.FeesChangeBp, x.Note, d.PublicId AS SourceDocument, x.SourcePage, x.Confidence, x.CreatedBy
              FROM fac.FacilityLenderDecision AS x
              LEFT JOIN ins.Institution AS i ON i.InstitutionId = x.LenderInstitutionId
              LEFT JOIN doc.Document AS d ON d.DocumentId = x.SourceDocumentId
             WHERE x.FacilityId = @f ORDER BY x.EffectiveDate DESC, x.FacilityLenderDecisionId DESC;
            """, new { f = f.FacilityId }, cancellationToken: ct));
        var today = await BankFas.Data.Workflow.Delegations.TodayAsync(u.Connection, null, clock.GetUtcNow(), ct);
        var inForce = rows.Where(r => r.EffectiveDate <= today).Select(r => r.FacilityLenderDecisionId).FirstOrDefault();
        return Results.Ok(new
        {
            items = rows.Select(r => new
            {
                id = refs.ItemRef(u.TenantId, DecisionKind, r.FacilityLenderDecisionId), lender = r.Lender, lenderNameAr = r.LenderNameAr,
                decisionDate = FacilityEndpoints.D(r.DecisionDate), effectiveDate = FacilityEndpoints.D(r.EffectiveDate), limitAction = r.LimitAction,
                newLimitAmount = r.NewLimitAmount, marginChangeBp = r.MarginChangeBp, feesChangeBp = r.FeesChangeBp, note = r.Note, sourceDocument = r.SourceDocument,
                sourcePage = r.SourcePage, confidence = r.Confidence, inForce = r.FacilityLenderDecisionId == inForce, enteredByMe = r.CreatedBy == u.UserId,
            }),
        });
    }

    /// <summary>FR-FIN-034: the decision with its dates and its source (the letter and page, or why there is none, BR-FAC-018); a later decision replaces an earlier one from its effective date.</summary>
    private static async Task<IResult> AddDecisionAsync(Guid id, LenderDecisionRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        var action = b.LimitAction?.Trim().ToUpperInvariant();
        if (action is null || !LimitActions.Contains(action))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The decision is MAINTAINED, UNDRAWN_STOPPED, LIMIT_REDUCED or NOT_RENEWED.");
        var decided = LimitEndpoints.Date(b.DecisionDate, "decision date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date of the decision.");
        var effective = LimitEndpoints.Date(b.EffectiveDate, "effective date") ?? decided;
        if (effective < decided) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A decision takes effect on or after its date.");
        if ((action == "LIMIT_REDUCED") != (b.NewLimitAmount is not null) || b.NewLimitAmount < 0)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "A reduced limit gives its new amount, and only a reduction does.");
        int margin = b.MarginChangeBp ?? 0, fees = b.FeesChangeBp ?? 0;
        if (margin is < -1000 or > 2000 || fees is < -1000 or > 2000)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "A change of margin or fees is from -1,000 to 2,000 basis points.");
        if (b.Note?.Length > 1000 || b.OriginalText?.Length > 2000 || b.SourcePage?.Length > 40 || b.NoSourceReason?.Length > 300)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "A field is longer than allowed.");
        if (b.SourceDocument is null && string.IsNullOrWhiteSpace(b.NoSourceReason))
            throw ApiProblemException.Invalid("V-SOURCE", "Give the lender's letter and its page, or the reason there is none (BR-FAC-018).");
        if (b.SourceDocument is not null && string.IsNullOrWhiteSpace(b.SourcePage)) throw ApiProblemException.Invalid("V-SOURCE", "Give the page of the letter.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct);
        long? lender = null;
        if (b.Lender is { } l)
            lender = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                """
                SELECT i.InstitutionId FROM ins.Institution AS i
                 WHERE i.PublicId = @l AND EXISTS (SELECT 1 FROM fac.FacilityLender AS x WHERE x.FacilityId = @f AND x.InstitutionId = i.InstitutionId);
                """, new { l, f = f.FacilityId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The lender is a lender of the facility.");
        long? doc = b.SourceDocument is null ? null : await DocumentAsync(u, tx, b.SourceDocument, "The letter is an active document on file.", ct);
        var did = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT fac.FacilityLenderDecision (TenantId, FacilityId, LenderInstitutionId, DecisionDate, EffectiveDate, LimitAction, NewLimitAmount, MarginChangeBp, FeesChangeBp,
                                               Note, SourceDocumentId, SourcePage, OriginalText, NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.FacilityLenderDecisionId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @lender, @decided, @effective, @action, @amount, @margin, @fees, @note, @doc, @page, @text, @none,
                    CASE WHEN @doc IS NULL THEN 'ENTERED_NO_DOCUMENT' ELSE 'READ_FROM_SCAN_UNVERIFIED' END, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new
            {
                f = f.FacilityId, lender, decided, effective, action, amount = b.NewLimitAmount, margin, fees, note = b.Note?.Trim(), doc,
                page = doc is null ? null : b.SourcePage?.Trim(), text = b.OriginalText?.Trim(), none = doc is null ? b.NoSourceReason?.Trim() : null,
            }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LENDER_DECISION_RECORDED", "TREASURY", "fac.Facility", f.FacilityId,
            AfterJson: JsonSerializer.Serialize(new { decision = did, action, effective = FacilityEndpoints.D(effective) })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        var reference = refs.ItemRef(u.TenantId, DecisionKind, did);
        return Results.Created($"/api/v1/facilities/{id}/lender-decisions/{reference}", new { id = reference });
    }

    /// <summary>Confirmed against the lender's letter by another user than the one who entered it.</summary>
    private static async Task<IResult> VerifyDecisionAsync(Guid id, string decision, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, FacilityEndpoints.Edit);
        await using var _ = u;
        var ct = http.RequestAborted;
        var did = refs.ItemId(u.TenantId, DecisionKind, decision) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var f = await FacilityEndpoints.FindAsync(u, tx, id, scope, ct);
        var r = await u.Connection.QuerySingleOrDefaultAsync<(long? CreatedBy, long? Doc, long? VerifiedBy)?>(new CommandDefinition(
            "SELECT CreatedBy, SourceDocumentId, VerifiedBy FROM fac.FacilityLenderDecision WITH (UPDLOCK) WHERE FacilityLenderDecisionId = @did AND FacilityId = @f;",
            new { did, f = f.FacilityId }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (r.VerifiedBy is not null) throw new ApiProblemException(409, "APPROVED_FINAL", "The decision is already confirmed against the lender's letter.");
        if (r.Doc is null) throw ApiProblemException.Invalid("V-SOURCE", "Only a decision with the lender's letter on file is confirmed against it.");
        if (r.CreatedBy == u.UserId) throw ApiProblemException.Forbidden("V-FAC-SOD", "Another user confirms the decision against the letter.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fac.FacilityLenderDecision SET Confidence = 'CONFIRMED_AGAINST_ORIGINAL', VerifiedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT), VerifiedOn = SYSUTCDATETIME(),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE FacilityLenderDecisionId = @did;
            """, new { did }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("LENDER_DECISION_VERIFIED", "TREASURY", "fac.Facility", f.FacilityId,
            AfterJson: JsonSerializer.Serialize(new { decision = did })), f.BorrowerCompanyId, ct);
        await tx.CommitAsync(ct);
        return Results.Ok(new { confidence = "CONFIRMED_AGAINST_ORIGINAL" });
    }
}
