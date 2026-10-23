using System.Data;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Core.Text;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record CompanyRequest(string? CompanyCode, string? NameAr, string? NameEn, string? LegalForm, bool? IsHolding, Guid? Parent, bool? ClearParent,
    string? Country, string? Industry, string? Status, string? EstablishedOn, string? CrNumber, string? CrDate, string? CrDateHijri, string? ErpCompanyCode,
    int? FiscalYearEndMonth, int? FiscalYearEndDay, bool? FiscalYearEndOfMonth, string? BaseCurrency);
public sealed record ArchiveRequest(string? Reason);
public sealed record TaxRateRequest(string? TaxCode, decimal? RatePercent, string? EffectiveFrom);
/// <summary>Head: the user who heads the department (BR-WFL-005 resolves a requester's manager to it); ClearHead removes it.</summary>
public sealed record DepartmentRequest(string? Code, string? NameAr, string? NameEn, string? Function, bool? IsTreasury, Guid? Company, bool? IsActive,
    Guid? Head = null, bool? ClearHead = null);

/// <summary>
/// Companies (FR-ORG-001 to 014; screens 13 and 14 of spec 10): a company and its mirror party are created in one
/// transaction (FR-PTY-003, the party code from the PARTY numbering); the tree has no cycle and is at most 10 levels
/// deep (BR-ORG-002); the commercial registration is unique per country and the ERP code always unique among companies
/// that are not archived (BR-ORG-001, owner decision DR-47); a company in use is not archived (FR-ORG-010). The fiscal
/// periods are derived from the year end (FR-ORG-006); tax rates are dated (FR-ORG-007); addresses and contacts are
/// those of the mirror party (FR-ORG-009). Every list and read is limited to the user's company scope.
/// </summary>
public static partial class CompanyEndpoints
{
    private const string View = "org.company.view";
    private const string Manage = "org.company.manage";
    private const int MaxDepth = 10;

    [GeneratedRegex("^[A-Z0-9][A-Z0-9_-]{0,19}$", RegexOptions.CultureInvariant)] private static partial Regex CodePattern();

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/companies", ListAsync);
        api.MapPost("/companies", CreateAsync);
        api.MapGet("/companies/{id:guid}", GetAsync);
        api.MapPatch("/companies/{id:guid}", PatchAsync);
        api.MapPost("/companies/{id:guid}/actions/archive", ArchiveAsync);
        api.MapGet("/companies/{id:guid}/fiscal-periods", FiscalPeriodsAsync);
        api.MapGet("/companies/{id:guid}/tax-rates", TaxRatesAsync);
        api.MapPost("/companies/{id:guid}/tax-rates", AddTaxRateAsync);
        api.MapGet("/tax-rates", TenantTaxRatesAsync);
        api.MapPost("/tax-rates", AddTenantTaxRateAsync);
        api.MapGet("/companies/{id:guid}/contacts", ContactsAsync);
        api.MapPost("/companies/{id:guid}/addresses", AddAddressAsync);
        api.MapPost("/companies/{id:guid}/addresses/{reference}/actions/retire", RetireAddressAsync);
        api.MapPost("/companies/{id:guid}/contact-methods", AddContactMethodAsync);
        api.MapDelete("/companies/{id:guid}/contact-methods/{reference}", DeleteContactMethodAsync);
        api.MapGet("/departments", DepartmentsAsync);
        api.MapPost("/departments", CreateDepartmentAsync);
        api.MapPatch("/departments/{reference}", PatchDepartmentAsync);
    }

    internal sealed record CompanyRow(long CompanyId, Guid PublicId, string CompanyCode, string NameAr, string NameEn, long PartyId, string PartyCode, Guid PartyPublicId,
        string LegalFormCode, string? LegalFormNameAr, string? LegalFormNameEn, bool IsHolding, long? ParentCompanyId, Guid? ParentPublicId, string Country,
        string? Industry, string Status, DateTime? EstablishedOn, string? CrNumber, DateTime? CrDate, string? CrDateHijriText, string? ErpCompanyCode,
        byte FiscalYearEndMonth, byte? FiscalYearEndDay, string? BaseCurrency, string OwnershipStatus, byte[] RowVersion);

    private const string Select =
        """
        SELECT c.CompanyId, c.PublicId, c.CompanyCode, c.NameAr, c.NameEn, c.PartyId, p.PartyCode, p.PublicId AS PartyPublicId, l.Code AS LegalFormCode, l.NameAr AS LegalFormNameAr,
               l.NameEn AS LegalFormNameEn, c.IsHolding, c.ParentCompanyId, pc.PublicId AS ParentPublicId, co.Iso2 AS Country, i.Code AS Industry, c.Status,
               c.EstablishedOn, c.CrNumber, c.CrDate, c.CrDateHijriText, c.ErpCompanyCode, c.FiscalYearEndMonth, c.FiscalYearEndDay, cu.Code AS BaseCurrency,
               c.OwnershipStatus, c.RowVersion
          FROM org.Company AS c
          JOIN pty.Party AS p ON p.PartyId = c.PartyId
          JOIN cat.LegalEntityType AS l ON l.LegalEntityTypeId = c.LegalEntityTypeId
          JOIN ref.Country AS co ON co.CountryId = c.CountryId
          LEFT JOIN ref.Industry AS i ON i.IndustryId = c.IndustryId
          LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = c.BaseCurrencyId
          LEFT JOIN org.Company AS pc ON pc.CompanyId = c.ParentCompanyId
        """;

    private static string? D(DateTime? d) => d?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static object Shape(CompanyRow c) => new
    {
        id = c.PublicId, companyCode = c.CompanyCode, nameAr = c.NameAr, nameEn = c.NameEn, partyCode = c.PartyCode, party = c.PartyPublicId,
        legalForm = new { code = c.LegalFormCode, nameAr = c.LegalFormNameAr, nameEn = c.LegalFormNameEn }, isHolding = c.IsHolding, parent = c.ParentPublicId,
        country = c.Country, industry = c.Industry, status = c.Status, establishedOn = D(c.EstablishedOn), crNumber = c.CrNumber, crDate = D(c.CrDate),
        crDateHijri = c.CrDateHijriText, erpCompanyCode = c.ErpCompanyCode, fiscalYearEndMonth = c.FiscalYearEndMonth, fiscalYearEndDay = c.FiscalYearEndDay,
        baseCurrency = c.BaseCurrency, ownershipStatus = c.OwnershipStatus, etag = ETags.Of(c.RowVersion),
    };

    internal static async Task<CompanyRow> FindAsync(BoundUser u, SqlTransaction? tx, Guid id, CompanyScope scope, CancellationToken ct)
    {
        var c = await u.Connection.QuerySingleOrDefaultAsync<CompanyRow>(new CommandDefinition(Select + " WHERE c.PublicId = @id;", new { id }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        return scope.Allows(c.CompanyId) ? c : throw ApiProblemException.NotFound();
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "includeArchived", "q", "status");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        var q = http.Request.Query["q"].ToString();
        var rows = await u.Connection.QueryAsync<CompanyRow>(new CommandDefinition(
            Select + """
             WHERE (@archived = 1 OR c.Status <> 'ARCHIVED') AND (@status IS NULL OR c.Status = @status)
               AND (@q IS NULL OR c.NameAr LIKE @q OR c.NameEn LIKE @q OR c.CompanyCode LIKE @q OR c.CrNumber LIKE @q OR c.ErpCodeNormalized LIKE @erp)
               AND (@all = 1 OR c.CompanyId IN @ids)
             ORDER BY c.CompanyCode;
            """,
            new
            {
                archived = string.Equals(http.Request.Query["includeArchived"], "true", StringComparison.OrdinalIgnoreCase),
                status = http.Request.Query["status"].ToString() is { Length: > 0 } st ? st.ToUpperInvariant() : null,
                q = q.Length > 0 ? "%" + q + "%" : null, erp = q.Length > 0 ? "%" + Normalizer.Code(q) + "%" : null, all = scope.All, ids = scope.SqlIds,
            }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(Shape) });
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var c = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var children = await u.Connection.QueryAsync<Guid>(new CommandDefinition(
            "SELECT PublicId FROM org.Company WHERE ParentCompanyId = @c AND Status <> 'ARCHIVED';", new { c = c.CompanyId }, cancellationToken: http.RequestAborted));
        ETags.Set(http.Response, c.RowVersion);
        return Results.Ok(new { company = Shape(c), children });
    }

    // ---------- writing ----------

    private sealed record Resolved(int LegalFormId, int CountryId, int? IndustryId, int? CurrencyId, long? ParentId);

    private static DateTime? Date(string? text, string field) =>
        string.IsNullOrWhiteSpace(text) ? null
        : DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is a date YYYY-MM-DD.");

    /// <summary>The references of the request by code; the legal form must be of the company's country (BR-ORG-016).</summary>
    private static async Task<Resolved> ResolveAsync(BoundUser u, SqlTransaction tx, CompanyRequest b, CompanyRow? current, CompanyScope scope, CancellationToken ct)
    {
        var country = b.Country ?? current?.Country ?? throw ApiProblemException.Invalid("COUNTRY_UNKNOWN", "Choose a country from the list.");
        var countryId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CountryId FROM ref.Country WHERE Iso2 = @c AND IsActive = 1;",
            new { c = country.ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("COUNTRY_UNKNOWN", "Choose a country from the list.");
        var form = b.LegalForm ?? current?.LegalFormCode ?? throw ApiProblemException.Invalid("V-ORG-LEGAL-FORM", "Choose the legal form.");
        var formId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
            "SELECT LegalEntityTypeId FROM cat.LegalEntityType WHERE Code = @f AND CountryId = @c AND (IsActive = 1 OR @keep = 1);",
            new { f = form, c = countryId, keep = current is not null && b.LegalForm is null && b.Country is null }, tx, cancellationToken: ct))
            ?? throw ApiProblemException.Invalid("V-ORG-LEGAL-FORM", "The legal form is not one of the company's country.");
        int? industryId = null;
        var industry = b.Industry ?? current?.Industry;
        if (industry is { Length: > 0 })
            industryId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT IndustryId FROM ref.Industry WHERE Code = @i;", new { i = industry }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-ORG-INDUSTRY", "The activity code is not in the classification.");
        int? currencyId = null;
        var currency = b.BaseCurrency ?? current?.BaseCurrency;
        if (currency is { Length: > 0 })
            currencyId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c AND IsActive = 1;",
                new { c = currency.ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-ORG-CURRENCY", "The currency is not known.");
        long? parentId = current?.ParentCompanyId;
        if (b.ClearParent == true) parentId = null;
        else if (b.Parent is { } parent)
        {
            var p = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Status)>(new CommandDefinition(
                "SELECT CompanyId, Status FROM org.Company WHERE PublicId = @p;", new { p = parent }, tx, cancellationToken: ct));
            if (p.Id == 0 || p.Status == "ARCHIVED" || !scope.Allows(p.Id)) throw ApiProblemException.Invalid("V-ORG-PARENT", "The parent company does not exist or is archived.");
            parentId = p.Id;
        }
        return new Resolved(formId, countryId, industryId, currencyId, parentId);
    }

    /// <summary>No cycle, direct or indirect, and at most 10 levels (FR-ORG-004, BR-ORG-002).</summary>
    private static async Task CheckTreeAsync(BoundUser u, SqlTransaction tx, long? companyId, long? parentId, CancellationToken ct)
    {
        if (parentId is null) return;
        var chain = (await u.Connection.QueryAsync<long>(new CommandDefinition(
            """
            WITH up AS (SELECT CompanyId, ParentCompanyId, 1 AS Depth FROM org.Company WHERE CompanyId = @p
                        UNION ALL SELECT c.CompanyId, c.ParentCompanyId, up.Depth + 1 FROM org.Company AS c JOIN up ON c.CompanyId = up.ParentCompanyId WHERE up.Depth < 50)
            SELECT CompanyId FROM up OPTION (MAXRECURSION 60);
            """, new { p = parentId }, tx, cancellationToken: ct))).ToList();
        if (companyId is not null && chain.Contains(companyId.Value)) throw ApiProblemException.Invalid("V-ORG-CYCLE", "A company cannot be placed under itself or one of its own companies.");
        var below = companyId is null ? 0 : await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            WITH down AS (SELECT CompanyId, 0 AS Depth FROM org.Company WHERE CompanyId = @c
                          UNION ALL SELECT c.CompanyId, down.Depth + 1 FROM org.Company AS c JOIN down ON c.ParentCompanyId = down.CompanyId WHERE down.Depth < 50)
            SELECT MAX(Depth) FROM down OPTION (MAXRECURSION 60);
            """, new { c = companyId }, tx, cancellationToken: ct));
        if (chain.Count + 1 + below > MaxDepth) throw ApiProblemException.Invalid("V-ORG-DEPTH", "The company tree is at most 10 levels deep.");
    }

    private static (byte Month, byte? Day) FiscalEnd(CompanyRequest b, CompanyRow? current)
    {
        var month = b.FiscalYearEndMonth ?? current?.FiscalYearEndMonth ?? 12;
        int? day = b.FiscalYearEndOfMonth == true ? null : b.FiscalYearEndDay ?? (b.FiscalYearEndMonth is null ? current?.FiscalYearEndDay : null);
        if (month is < 1 or > 12) throw ApiProblemException.Invalid("V-ORG-FISCAL", "The year-end month is 1 to 12.");
        if (day is not null && (day < 1 || day > DateTime.DaysInMonth(2024, month)))
            throw ApiProblemException.Invalid("V-ORG-FISCAL", "The year-end day is not a day of that month.");
        return ((byte)month, (byte?)day);
    }

    /// <summary>The unique indexes of the company as their own problems.</summary>
    private static ApiProblemException? Unique(SqlException ex) => ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation
        ? ex.Message.Contains("UQ_Company_CompanyCode", StringComparison.Ordinal) ? new ApiProblemException(409, "V-ORG-CODE-TAKEN", "A company with this code already exists.")
        : ex.Message.Contains("UQ_Company_CountryId_CrNumber", StringComparison.Ordinal) ? new ApiProblemException(409, "V-ORG-CR-TAKEN", "A company of this country has this commercial registration.")
        : ex.Message.Contains("UQ_Company_ErpCodeNormalized", StringComparison.Ordinal) ? new ApiProblemException(409, "V-ORG-ERP-TAKEN", "Another company has this ERP code.")
        : null
        : null;

    private static string? Erp(string? text) => text is null ? null : text.Trim().Length == 0 ? null : text.Trim().Length > 20
        ? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The ERP code is up to 20 characters.") : text.Trim();

    private static async Task<IResult> CreateAsync(CompanyRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var code = b.CompanyCode?.Trim().ToUpperInvariant();
        if (code is null || !CodePattern().IsMatch(code)) throw ApiProblemException.Invalid("V-ORG-CODE", "The company code is 1 to 20 capital letters, digits, - and _.");
        if (string.IsNullOrWhiteSpace(b.NameAr) || string.IsNullOrWhiteSpace(b.NameEn) || b.NameAr.Trim().Length > 200 || b.NameEn.Trim().Length > 200)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter both names (up to 200 characters).");
        var (month, day) = FiscalEnd(b, null);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var r = await ResolveAsync(u, tx, b, null, scope, http.RequestAborted);
        await CheckTreeAsync(u, tx, null, r.ParentId, http.RequestAborted);
        var (partyCode, issueId) = await AllocatePartyCodeAsync(u.Connection, tx, http.RequestAborted);
        try
        {
            var partyId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT pty.Party (TenantId, PartyCode, Kind, NameAr, NameEn, NameNormalized, CountryId, CreatedBy)
                OUTPUT inserted.PartyId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, 'ORGANIZATION', @ar, @en, @norm, @country, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { code = partyCode, ar = b.NameAr.Trim(), en = b.NameEn.Trim(), norm = Norm(b.NameAr, b.NameEn), country = r.CountryId }, tx,
                cancellationToken: http.RequestAborted));
            await RecordPartyAsync(u.Connection, tx, issueId, partyId, http.RequestAborted);
            var company = await u.Connection.QuerySingleAsync<(long Id, Guid PublicId)>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT, PublicId UNIQUEIDENTIFIER);
                INSERT org.Company (TenantId, CompanyCode, NameAr, NameEn, PartyId, LegalEntityTypeId, IsHolding, ParentCompanyId, CountryId, IndustryId,
                                    EstablishedOn, CrNumber, CrDate, CrDateHijriText, ErpCompanyCode, FiscalYearEndMonth, FiscalYearEndDay, BaseCurrencyId, CreatedBy)
                OUTPUT inserted.CompanyId, inserted.PublicId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @ar, @en, @party, @form, @holding, @parent, @country, @industry, @est, @cr, @crDate,
                        @crH, @erp, @month, @day, @currency, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id, PublicId FROM @o;
                """,
                new
                {
                    code, ar = b.NameAr.Trim(), en = b.NameEn.Trim(), party = partyId, form = r.LegalFormId, holding = b.IsHolding == true, parent = r.ParentId,
                    country = r.CountryId, industry = r.IndustryId, est = Date(b.EstablishedOn, "establishment date"), cr = b.CrNumber?.Trim() is { Length: > 0 } cr ? cr : null,
                    crDate = Date(b.CrDate, "registration date"), crH = b.CrDateHijri, erp = Erp(b.ErpCompanyCode), month, day, currency = r.CurrencyId,
                }, tx, cancellationToken: http.RequestAborted));
            // A user with a selected scope sees the company they create (FR-PLT-020).
            if (!scope.All)
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    "INSERT sec.UserCompanyScope (TenantId, UserId, CompanyId, IncludeDescendants) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @u, @c, 0);",
                    new { u = u.UserId, c = company.Id }, tx, cancellationToken: http.RequestAborted));
            await Outbox.EmitAsync(u.Connection, tx, "company.created", "org.Company", company.Id, new { company = company.PublicId, code }, http.RequestAborted);
            await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COMPANY_CREATED", "TREASURY", "org.Company", company.Id,
                AfterJson: JsonSerializer.Serialize(new { code, b.NameAr, b.NameEn, b.LegalForm, b.Country, b.CrNumber, b.ErpCompanyCode, partyCode })),
                company.Id, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.Created($"/api/v1/companies/{company.PublicId}", new { id = company.PublicId, code, partyCode });
        }
        catch (SqlException ex) when (Unique(ex) is { } problem) { throw problem; }
    }

    /// <summary>The next code of the PARTY numbering, in the transaction of the party it numbers (CORE.NUMBERING).</summary>
    /// <remarks>The issue names its party once the party exists (<see cref="RecordPartyAsync"/>).</remarks>
    internal static async Task<(string Code, long IssueId)> AllocatePartyCodeAsync(SqlConnection c, SqlTransaction tx, CancellationToken ct)
    {
        var p = new DynamicParameters();
        p.Add("@SequenceKey", "PARTY", DbType.AnsiString, size: 50);
        p.Add("@IssuedNumber", null, DbType.String, ParameterDirection.Output, 60);
        p.Add("@NumberIssueId", null, DbType.Int64, ParameterDirection.Output);
        await c.ExecuteAsync(new CommandDefinition("cfg.usp_AllocateNumber", p, tx, commandType: CommandType.StoredProcedure, cancellationToken: ct));
        return (p.Get<string>("@IssuedNumber"), p.Get<long>("@NumberIssueId"));
    }

    internal static Task RecordPartyAsync(SqlConnection c, SqlTransaction tx, long issueId, long partyId, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition("UPDATE cfg.NumberIssue SET EntityType = 'pty.Party', EntityId = @p WHERE NumberIssueId = @i;",
            new { p = partyId, i = issueId }, tx, cancellationToken: ct));

    internal static string Norm(string? ar, string? en) => (Normalizer.Name(ar) + " " + Normalizer.Name(en)).Trim() is { Length: > 400 } n ? n[..400] : (Normalizer.Name(ar) + " " + Normalizer.Name(en)).Trim();

    private static async Task<IResult> PatchAsync(Guid id, CompanyRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        if (b.CompanyCode is not null) throw ApiProblemException.Invalid("V-ORG-CODE-FIXED", "The company code does not change.");
        if (b.Status is not null && b.Status.ToUpperInvariant() is not ("ACTIVE" or "DORMANT" or "LIQUIDATED"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The status is active, dormant or liquidated; archive through its action.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var c = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (c.Status == "ARCHIVED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "An archived company is read-only.");
        var r = await ResolveAsync(u, tx, b, c, scope, http.RequestAborted);
        await CheckTreeAsync(u, tx, c.CompanyId, r.ParentId, http.RequestAborted);
        var (month, day) = b.FiscalYearEndMonth is null && b.FiscalYearEndDay is null && b.FiscalYearEndOfMonth is null ? (c.FiscalYearEndMonth, c.FiscalYearEndDay) : FiscalEnd(b, c);
        var ar = b.NameAr?.Trim() ?? c.NameAr;
        var en = b.NameEn?.Trim() ?? c.NameEn;
        if (ar.Length is 0 or > 200 || en.Length is 0 or > 200) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter both names (up to 200 characters).");
        try
        {
            var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
                """
                DECLARE @o TABLE (RowVersion BINARY(8));
                UPDATE org.Company SET NameAr = @ar, NameEn = @en, LegalEntityTypeId = @form, IsHolding = ISNULL(@holding, IsHolding), ParentCompanyId = @parent,
                       CountryId = @country, IndustryId = @industry, Status = ISNULL(@status, Status), EstablishedOn = ISNULL(@est, EstablishedOn),
                       CrNumber = CASE WHEN @crSet = 1 THEN @cr ELSE CrNumber END, CrDate = ISNULL(@crDate, CrDate), CrDateHijriText = ISNULL(@crH, CrDateHijriText),
                       ErpCompanyCode = CASE WHEN @erpSet = 1 THEN @erp ELSE ErpCompanyCode END, FiscalYearEndMonth = @month, FiscalYearEndDay = @day,
                       BaseCurrencyId = @currency, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
                OUTPUT inserted.RowVersion INTO @o WHERE CompanyId = @id AND RowVersion = @rv;
                SELECT RowVersion FROM @o;
                """,
                new
                {
                    ar, en, form = r.LegalFormId, holding = b.IsHolding, parent = r.ParentId, country = r.CountryId, industry = r.IndustryId,
                    status = b.Status?.ToUpperInvariant(), est = Date(b.EstablishedOn, "establishment date"), crSet = b.CrNumber is not null,
                    cr = b.CrNumber?.Trim() is { Length: > 0 } cr ? cr : null, crDate = Date(b.CrDate, "registration date"), crH = b.CrDateHijri,
                    erpSet = b.ErpCompanyCode is not null, erp = Erp(b.ErpCompanyCode), month, day, currency = r.CurrencyId, id = c.CompanyId, rv = expected,
                }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
            // The mirror party follows the names (OQ-6: names only; the registration stays on the company).
            if (ar != c.NameAr || en != c.NameEn)
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    "UPDATE pty.Party SET NameAr = @ar, NameEn = @en, NameNormalized = @norm, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE PartyId = @p;",
                    new { ar, en, norm = Norm(ar, en), p = c.PartyId }, tx, cancellationToken: http.RequestAborted));
            await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COMPANY_UPDATED", "TREASURY", "org.Company", c.CompanyId,
                BeforeJson: JsonSerializer.Serialize(Shape(c)), AfterJson: JsonSerializer.Serialize(b)), c.CompanyId, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            ETags.Set(http.Response, rv);
            return Results.NoContent();
        }
        catch (SqlException ex) when (Unique(ex) is { } problem) { throw problem; }
    }

    /// <summary>FR-ORG-010: a company with companies under it, or users whose scope is it, stays; the refusal says why.</summary>
    private static async Task<IResult> ArchiveAsync(Guid id, ArchiveRequest b, HttpContext http, SqlConnectionFactory db)
    {
        if (string.IsNullOrWhiteSpace(b.Reason)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var scope = await CompanyScope.OfAsync(u, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var c = await FindAsync(u, tx, id, scope, http.RequestAborted);
        if (c.Status == "ARCHIVED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "The company is already archived.");
        var usage = await u.Connection.QuerySingleAsync<(int Children, int Users)>(new CommandDefinition(
            """
            SELECT (SELECT COUNT(*) FROM org.Company WHERE ParentCompanyId = @c AND Status <> 'ARCHIVED'),
                   (SELECT COUNT(*) FROM sec.UserCompanyScope AS s JOIN sec.AppUser AS a ON a.AppUserId = s.UserId AND a.Status IN ('ACTIVE', 'INVITED', 'LOCKED') WHERE s.CompanyId = @c);
            """, new { c = c.CompanyId }, tx, cancellationToken: http.RequestAborted));
        if (usage.Children > 0 || usage.Users > 0)
            throw new ApiProblemException(409, "V-ORG-IN-USE",
                $"The company is in use: {usage.Children} active companies under it, {usage.Users} users whose scope it is.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE org.Company SET Status = 'ARCHIVED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE CompanyId = @c;",
            new { c = c.CompanyId }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("COMPANY_ARCHIVED", "TREASURY", "org.Company", c.CompanyId,
            BeforeJson: JsonSerializer.Serialize(new { c.Status }), AfterJson: JsonSerializer.Serialize(new { status = "ARCHIVED", reason = b.Reason.Trim() }),
            Severity: "HIGH"), c.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- fiscal periods and tax rates ----------

    /// <summary>The fiscal year that ends in the given year (FR-ORG-006): year end 30 June 2026 gives 2025-07-01 to 2026-06-30.</summary>
    internal static (DateOnly From, DateOnly To) FiscalYear(int year, int month, int? day)
    {
        var end = new DateOnly(year, month, Math.Min(day ?? DateTime.DaysInMonth(year, month), DateTime.DaysInMonth(year, month)));
        var prev = new DateOnly(year - 1, month, Math.Min(day ?? DateTime.DaysInMonth(year - 1, month), DateTime.DaysInMonth(year - 1, month)));
        return (prev.AddDays(1), end);
    }

    private static async Task<IResult> FiscalPeriodsAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "year");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var c = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        var year = int.TryParse(http.Request.Query["year"], CultureInfo.InvariantCulture, out var y) && y is > 1900 and < 2200 ? y : DateTime.UtcNow.Year;
        var (from, to) = FiscalYear(year, c.FiscalYearEndMonth, c.FiscalYearEndDay);
        var months = new List<object>();
        for (var start = from; start <= to;)
        {
            var next = start.AddMonths(1);
            var end = next.AddDays(-1) > to ? to : next.AddDays(-1);
            months.Add(new { from = start.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), to = end.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) });
            start = end.AddDays(1);
        }
        return Results.Ok(new
        {
            fiscalYear = year, from = from.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), to = to.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), months,
        });
    }

    private static async Task<IResult> TaxRatesFor(long? companyId, BoundUser u, CancellationToken ct)
    {
        var rows = await u.Connection.QueryAsync<(string TaxCode, decimal RatePercent, DateTime EffectiveFrom, DateTime? EffectiveTo)>(new CommandDefinition(
            "SELECT TaxCode, RatePercent, EffectiveFrom, EffectiveTo FROM org.CompanyTaxRate WHERE (CompanyId = @c OR (@c IS NULL AND CompanyId IS NULL)) ORDER BY TaxCode, EffectiveFrom DESC;",
            new { c = companyId }, cancellationToken: ct));
        return Results.Ok(new { items = rows.Select(r => new { taxCode = r.TaxCode, ratePercent = r.RatePercent, effectiveFrom = D(r.EffectiveFrom), effectiveTo = D(r.EffectiveTo) }) });
    }

    private static async Task<IResult> TaxRatesAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var c = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        return await TaxRatesFor(c.CompanyId, u, http.RequestAborted);
    }

    private static async Task<IResult> TenantTaxRatesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        return await TaxRatesFor(null, u, http.RequestAborted);
    }

    /// <summary>A new rate from a date: the open rate of the same tax closes the day before (FR-ORG-007, BR-ORG-005).</summary>
    private static async Task AddRateAsync(BoundUser u, long? companyId, TaxRateRequest b, CancellationToken ct)
    {
        var code = b.TaxCode?.Trim().ToUpperInvariant();
        if (code is null || code.Length is 0 or > 20) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the tax code, such as VAT.");
        if (b.RatePercent is not { } rate || rate < 0 || rate > 100) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The rate is 0 to 100 percent.");
        var from = Date(b.EffectiveFrom, "effective date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the effective date.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var open = await u.Connection.QuerySingleOrDefaultAsync<(long Id, DateTime From)>(new CommandDefinition(
            "SELECT CompanyTaxRateId, EffectiveFrom FROM org.CompanyTaxRate WITH (UPDLOCK) WHERE (CompanyId = @c OR (@c IS NULL AND CompanyId IS NULL)) AND TaxCode = @code AND EffectiveTo IS NULL;",
            new { c = companyId, code }, tx, cancellationToken: ct));
        if (open.Id != 0)
        {
            if (from <= open.From) throw ApiProblemException.Invalid("V-ORG-TAX-DATE", "A new rate starts after the current one.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE org.CompanyTaxRate SET EffectiveTo = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE CompanyTaxRateId = @id;",
                new { to = from.AddDays(-1), id = open.Id }, tx, cancellationToken: ct));
        }
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "INSERT org.CompanyTaxRate (TenantId, CompanyId, TaxCode, RatePercent, EffectiveFrom, CreatedBy) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @code, @rate, @from, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));",
            new { c = companyId, code, rate, from }, tx, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("TAX_RATE_ADDED", "CONFIG", "org.CompanyTaxRate", companyId,
            AfterJson: JsonSerializer.Serialize(new { taxCode = code, rate, from = D(from) })), companyId, ct);
        await tx.CommitAsync(ct);
    }

    private static async Task<IResult> AddTaxRateAsync(Guid id, TaxRateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var c = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        await AddRateAsync(u, c.CompanyId, b, http.RequestAborted);
        return Results.NoContent();
    }

    private static async Task<IResult> AddTenantTaxRateAsync(TaxRateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await AddRateAsync(u, null, b, http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- addresses and contacts through the mirror party (FR-ORG-009) ----------

    private static async Task<IResult> ContactsAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var c = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        return Results.Ok(await PartyContacts.ListAsync(u.Connection, c.PartyId, refs, u.TenantId, http.RequestAborted));
    }

    private static async Task<IResult> ChangeContactsAsync(Guid id, HttpContext http, SqlConnectionFactory db, string action,
        Func<BoundUser, SqlTransaction, CompanyRow, Task<object?>> change)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var c = await FindAsync(u, null, id, await CompanyScope.OfAsync(u, http.RequestAborted), http.RequestAborted);
        if (c.Status == "ARCHIVED") throw new ApiProblemException(409, "V-ORG-ARCHIVED", "An archived company is read-only.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var detail = await change(u, tx, c);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry(action, "TREASURY", "pty.Party", c.PartyId, AfterJson: JsonSerializer.Serialize(detail)),
            c.CompanyId, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    private static Task<IResult> AddAddressAsync(Guid id, AddressRequest b, HttpContext http, SqlConnectionFactory db) =>
        ChangeContactsAsync(id, http, db, "ADDRESS_ADDED", async (u, tx, c) =>
        {
            await PartyContacts.AddAddressAsync(u.Connection, tx, c.PartyId, b, http.RequestAborted);
            return new { b.AddressType, b.City, b.Country };
        });

    private static Task<IResult> RetireAddressAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        ChangeContactsAsync(id, http, db, "ADDRESS_RETIRED", async (u, tx, c) =>
        {
            var aid = refs.ItemId(u.TenantId, "address", reference) ?? throw ApiProblemException.NotFound();
            await PartyContacts.RetireAddressAsync(u.Connection, tx, c.PartyId, aid, http.RequestAborted);
            return new { address = aid };
        });

    private static Task<IResult> AddContactMethodAsync(Guid id, ContactMethodRequest b, HttpContext http, SqlConnectionFactory db) =>
        ChangeContactsAsync(id, http, db, "CONTACT_METHOD_ADDED", async (u, tx, c) =>
        {
            await PartyContacts.AddContactMethodAsync(u.Connection, tx, c.PartyId, c.Country, b, http.RequestAborted);
            return new { b.Kind, b.Label };
        });

    private static Task<IResult> DeleteContactMethodAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs) =>
        ChangeContactsAsync(id, http, db, "CONTACT_METHOD_REMOVED", async (u, tx, c) =>
        {
            var mid = refs.ItemId(u.TenantId, "contact-method", reference) ?? throw ApiProblemException.NotFound();
            await PartyContacts.DeleteContactMethodAsync(u.Connection, tx, c.PartyId, mid, http.RequestAborted);
            return new { contactMethod = mid };
        });

    // ---------- departments (FR-ORG-014) ----------

    private static readonly string[] Functions = ["PROCUREMENT", "SALES", "TREASURY", "FINANCE", "OTHER"];

    private static async Task<IResult> DepartmentsAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var rows = await u.Connection.QueryAsync<(long Id, string Code, string NameAr, string NameEn, string Function, bool IsTreasury, Guid? Company, bool IsActive, int Users, byte[] RowVersion, Guid? Head)>(
            new CommandDefinition(
                """
                SELECT d.DepartmentId, d.Code, d.NameAr, d.NameEn, d.[Function], d.IsTreasury, c.PublicId, d.IsActive,
                       (SELECT COUNT(*) FROM sec.AppUser AS a WHERE a.DepartmentId = d.DepartmentId AND a.Status <> 'DISABLED'), d.RowVersion, h.PublicId
                  FROM org.Department AS d LEFT JOIN org.Company AS c ON c.CompanyId = d.CompanyId
                  LEFT JOIN sec.AppUser AS h ON h.AppUserId = d.HeadUserId ORDER BY d.Code;
                """, cancellationToken: http.RequestAborted));
        var list = rows.ToList();
        return Results.Ok(new
        {
            items = list.Select(d => new
            {
                id = refs.ItemRef(u.TenantId, "department", d.Id), code = d.Code, nameAr = d.NameAr, nameEn = d.NameEn, function = d.Function, isTreasury = d.IsTreasury,
                company = d.Company, isActive = d.IsActive, users = d.Users, head = d.Head, etag = ETags.Of(d.RowVersion),
            }),
            warning = list.Any(d => d.IsActive && d.IsTreasury) ? null : "NO_TREASURY_DEPARTMENT",
        });
    }

    private static async Task<long?> DepartmentCompanyAsync(BoundUser u, SqlTransaction tx, Guid? company, CancellationToken ct)
    {
        if (company is null) return null;
        var scope = await CompanyScope.OfAsync(u, ct);
        var id = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT CompanyId FROM org.Company WHERE PublicId = @c AND Status <> 'ARCHIVED';",
            new { c = company }, tx, cancellationToken: ct));
        return id is not null && scope.Allows(id) ? id : throw ApiProblemException.Invalid("COMPANY_NOT_FOUND", "The company does not exist or is outside your scope.");
    }

    private static async Task<IResult> CreateDepartmentAsync(DepartmentRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var code = b.Code?.Trim().ToUpperInvariant();
        if (code is null || !CodePattern().IsMatch(code)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The code is 1 to 20 capital letters, digits, - and _.");
        if (string.IsNullOrWhiteSpace(b.NameAr) || string.IsNullOrWhiteSpace(b.NameEn)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter both names (up to 200 characters).");
        var function = b.Function?.ToUpperInvariant();
        if (function is null || !Functions.Contains(function)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the function of the department.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var company = await DepartmentCompanyAsync(u, tx, b.Company, http.RequestAborted);
        try
        {
            var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT org.Department (TenantId, Code, NameAr, NameEn, [Function], IsTreasury, CompanyId, CreatedBy)
                OUTPUT inserted.DepartmentId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @ar, @en, @function, @treasury, @company, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { code, ar = b.NameAr.Trim(), en = b.NameEn.Trim(), function, treasury = b.IsTreasury == true, company }, tx, cancellationToken: http.RequestAborted));
            await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DEPARTMENT_CREATED", "CONFIG", "org.Department", id,
                AfterJson: JsonSerializer.Serialize(new { code, function })), company, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.Created("/api/v1/departments", new { id = refs.ItemRef(u.TenantId, "department", id), code });
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "CODE_TAKEN", "An item with this code already exists.");
        }
    }

    /// <summary>A department with users is not deactivated (FR-ORG-014).</summary>
    private static async Task<IResult> PatchDepartmentAsync(string reference, DepartmentRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var expected = ETags.Required(http.Request);
        if (b.Code is not null) throw ApiProblemException.Invalid("CODE_FIXED", "The code of an item does not change.");
        var function = b.Function?.ToUpperInvariant();
        if (function is not null && !Functions.Contains(function)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the function of the department.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var id = refs.ItemId(u.TenantId, "department", reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        if (b.IsActive == false && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM sec.AppUser WHERE DepartmentId = @id AND Status <> 'DISABLED';", new { id }, tx, cancellationToken: http.RequestAborted)) > 0)
            throw new ApiProblemException(409, "V-ORG-DEPARTMENT-IN-USE", "The department has users: move them first.");
        var company = b.Company is null ? (long?)null : await DepartmentCompanyAsync(u, tx, b.Company, http.RequestAborted);
        long? head = null;
        if (b.Head is { } hid)
            head = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT AppUserId FROM sec.AppUser WHERE PublicId = @hid AND IsSystemUser = 0 AND ArchivedAt IS NULL AND Status <> 'DISABLED';", new { hid }, tx,
                cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.Invalid("HEAD_NOT_FOUND", "Choose an active user as the head of the department.");
        var headSet = b.Head is not null || b.ClearHead == true;
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE org.Department SET NameAr = ISNULL(@ar, NameAr), NameEn = ISNULL(@en, NameEn), [Function] = ISNULL(@function, [Function]),
                   IsTreasury = ISNULL(@treasury, IsTreasury), CompanyId = CASE WHEN @companySet = 1 THEN @company ELSE CompanyId END,
                   IsActive = ISNULL(@active, IsActive), HeadUserId = CASE WHEN @headSet = 1 THEN @head ELSE HeadUserId END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE DepartmentId = @id AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """,
            new
            {
                ar = b.NameAr?.Trim(), en = b.NameEn?.Trim(), function, treasury = b.IsTreasury, companySet = b.Company is not null, company, active = b.IsActive, id,
                rv = expected, headSet, head,
            }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("DEPARTMENT_UPDATED", "CONFIG", "org.Department", id, AfterJson: JsonSerializer.Serialize(b)),
            company, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }
}
