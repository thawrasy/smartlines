using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record BaseRateRequest(string? Code, string? NameAr, string? NameEn, string? Kind, Guid? Institution, string? FamilyCode, string? Tenor, string? Currency,
    int? StaleAfterDays, List<string>? Aliases, bool? IsActive);
public sealed record BaseRateValueRequest(string? EffectiveDate, decimal? ValuePct, string? SourceNote);
public sealed record BaseRateCorrectionRequest(decimal? ValuePct, string? Reason);

/// <summary>
/// Base rates and their values (FR-CAT-015, FR-CAT-016; BR-CAT-011 to 013) and SVC-05 ResolveBaseRate. A market rate
/// has no institution and is unique by family and tenor; an internal rate belongs to one bank, so two banks may share a
/// family and tenor. Aliases (SIBOR for SAIBOR) are unique in their scope and found without regard to case. Values are
/// never deleted: a correction adds a row and marks the old one SUPERSEDED; zero and negative values are accepted. The
/// value on a date is the VALID value with the latest effective date on or before it, else NO_VALUE.
/// </summary>
public static partial class BaseRateEndpoints
{
    private const string View = "cat.view";
    private const string Manage = "cat.manage.financial";
    private const string Enter = "cat.baserate.enter";
    private static readonly string[] Tenors = ["ON", "1M", "3M", "6M", "12M"];

    [GeneratedRegex("^[A-Z][A-Z0-9_]{1,39}$", RegexOptions.CultureInvariant)]
    private static partial Regex FamilyPattern();

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/base-rates", ListAsync);
        api.MapPost("/base-rates", CreateAsync);
        api.MapGet("/base-rates/{code}", GetAsync);
        api.MapPatch("/base-rates/{code}", PatchAsync);
        api.MapPost("/base-rates/{code}/values", AddValueAsync);
        api.MapPost("/base-rates/{code}/values/{reference}/actions/correct", CorrectAsync);
        api.MapGet("/services/base-rate", ResolveAsync);
    }

    private sealed record RateRow(int BaseRateId, string Code, string NameAr, string? NameEn, string Kind, long? InstitutionId, Guid? Institution, string? InstitutionCode,
        string FamilyCode, string Tenor, string Currency, int? StaleAfterDays, bool IsActive, bool IsSystem, long ScopeKey, byte[] RowVersion);

    private const string Select =
        """
        SELECT r.BaseRateId, r.Code, r.NameAr, r.NameEn, r.Kind, r.InstitutionId, i.PublicId AS Institution, i.Code AS InstitutionCode, r.FamilyCode, r.Tenor,
               cu.Code AS Currency, r.StaleAfterDays, r.IsActive, r.IsSystem, r.ScopeKey, r.RowVersion
          FROM cat.BaseRate AS r JOIN ref.Currency AS cu ON cu.CurrencyId = r.CurrencyId LEFT JOIN ins.Institution AS i ON i.InstitutionId = r.InstitutionId
        """;

    private static object Shape(RateRow r, IEnumerable<string> aliases) => new
    {
        code = r.Code, nameAr = r.NameAr, nameEn = r.NameEn, kind = r.Kind, institution = r.Institution, institutionCode = r.InstitutionCode, familyCode = r.FamilyCode,
        tenor = r.Tenor, currency = r.Currency, staleAfterDays = r.StaleAfterDays, isActive = r.IsActive, isSystem = r.IsSystem, aliases, etag = ETags.Of(r.RowVersion),
    };

    private static async Task<RateRow> FindAsync(SqlConnection c, SqlTransaction? tx, string code, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<RateRow>(new CommandDefinition(Select + " WHERE r.Code = @code;", new { code = code.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.NotFound();

    private static async Task<ILookup<int, string>> AliasesAsync(SqlConnection c, SqlTransaction? tx, int[] ids, CancellationToken ct) =>
        (await c.QueryAsync<(int Id, string Alias)>(new CommandDefinition("SELECT BaseRateId, Alias FROM cat.BaseRateAlias WHERE BaseRateId IN @ids ORDER BY Alias;",
            new { ids = ids.DefaultIfEmpty(-1).ToArray() }, tx, cancellationToken: ct))).ToLookup(a => a.Id, a => a.Alias);

    /// <summary>FR-CAT-015: "q" finds a rate by its code, its family or one of its aliases, without regard to case.</summary>
    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "q", "kind", "tenor", "institution", "includeInactive");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var q = http.Request.Query;
        var text = q["q"].ToString().Trim().ToUpperInvariant();
        var rows = (await u.Connection.QueryAsync<RateRow>(new CommandDefinition(
            Select + """
             WHERE (@inactive = 1 OR r.IsActive = 1) AND (@kind IS NULL OR r.Kind = @kind) AND (@tenor IS NULL OR r.Tenor = @tenor)
               AND (@institution IS NULL OR i.PublicId = @institution)
               AND (@q = '' OR r.Code = @q OR r.FamilyCode = @q OR EXISTS (SELECT 1 FROM cat.BaseRateAlias AS a WHERE a.BaseRateId = r.BaseRateId AND a.AliasKey = @q))
             ORDER BY r.Kind DESC, r.FamilyCode, r.SortOrder, r.Tenor;
            """,
            new
            {
                inactive = string.Equals(q["includeInactive"], "true", StringComparison.OrdinalIgnoreCase), kind = q["kind"].ToString() is { Length: > 0 } k ? k.ToUpperInvariant() : null,
                tenor = q["tenor"].ToString() is { Length: > 0 } t ? t.ToUpperInvariant() : null, institution = Guid.TryParse(q["institution"], out var g) ? g : (Guid?)null, q = text,
            }, cancellationToken: http.RequestAborted))).ToList();
        var aliases = await AliasesAsync(u.Connection, null, [.. rows.Select(r => r.BaseRateId)], http.RequestAborted);
        return Results.Ok(new { items = rows.Select(r => Shape(r, aliases[r.BaseRateId])) });
    }

    private static async Task<IResult> GetAsync(string code, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var r = await FindAsync(u.Connection, null, code, http.RequestAborted);
        var aliases = await AliasesAsync(u.Connection, null, [r.BaseRateId], http.RequestAborted);
        var values = await u.Connection.QueryAsync<(long Id, DateTime EffectiveDate, decimal ValuePct, string Source, string? SourceNote, string Status, long? SupersedesId,
            DateTime EnteredOn, string? EnteredBy)>(new CommandDefinition(
            """
            SELECT v.BaseRateValueId, v.EffectiveDate, v.ValuePct, v.Source, v.SourceNote, v.Status, v.SupersedesId, v.EnteredOn, ISNULL(au.DisplayNameAr, au.DisplayNameEn)
              FROM cat.BaseRateValue AS v LEFT JOIN sec.AppUser AS au ON au.AppUserId = v.EnteredBy
             WHERE v.BaseRateId = @r ORDER BY v.EffectiveDate DESC, v.BaseRateValueId DESC;
            """, new { r = r.BaseRateId }, cancellationToken: http.RequestAborted));
        ETags.Set(http.Response, r.RowVersion);
        return Results.Ok(new
        {
            rate = Shape(r, aliases[r.BaseRateId]),
            values = values.Select(v => new
            {
                id = refs.ItemRef(u.TenantId, "base-rate-value", v.Id), effectiveDate = v.EffectiveDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), valuePct = v.ValuePct,
                source = v.Source, sourceNote = v.SourceNote, status = v.Status,
                supersedes = v.SupersedesId is { } s ? refs.ItemRef(u.TenantId, "base-rate-value", s) : null, enteredOn = v.EnteredOn, enteredBy = v.EnteredBy,
            }),
        });
    }

    private static async Task SetAliasesAsync(SqlConnection c, SqlTransaction tx, RateRow r, List<string> aliases, CancellationToken ct)
    {
        var clean = aliases.Select(a => a.Trim()).Where(a => a.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
        if (clean.Any(a => a.Length > 60)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "An alias is up to 60 characters.");
        await c.ExecuteAsync(new CommandDefinition("DELETE FROM cat.BaseRateAlias WHERE BaseRateId = @r;", new { r = r.BaseRateId }, tx, cancellationToken: ct));
        foreach (var alias in clean)
        {
            try
            {
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT cat.BaseRateAlias (TenantId, BaseRateId, Tenor, ScopeKey, Alias, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @tenor, @scope, @alias, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                    """, new { r = r.BaseRateId, tenor = r.Tenor, scope = r.ScopeKey, alias }, tx, cancellationToken: ct));
            }
            catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
            {
                throw new ApiProblemException(409, "V-CAT-03", $"The alias {alias} is already used by another rate of this tenor in the same scope.");
            }
        }
    }

    private static async Task<IResult> CreateAsync(BaseRateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var kind = b.Kind?.Trim().ToUpperInvariant();
        if (kind is not ("MARKET" or "BANK_INTERNAL")) throw ApiProblemException.Invalid("V-CAT-03", "The kind is MARKET or BANK_INTERNAL.");
        // BR-CAT-011: a market rate has no institution, an internal rate has one.
        if (kind == "MARKET" && b.Institution is not null) throw ApiProblemException.Invalid("V-CAT-03", "A market rate has no institution.");
        if (kind == "BANK_INTERNAL" && b.Institution is null) throw ApiProblemException.Invalid("V-CAT-03", "An internal rate belongs to an institution.");
        (long Id, string Code)? institution = null;
        if (b.Institution is { } ig)
        {
            var i = await InstitutionEndpoints.FindAsync(u.Connection, tx, ig, ct);
            institution = (i.InstitutionId, i.Code);
        }
        var family = b.FamilyCode?.Trim().ToUpperInvariant() ?? "";
        if (!FamilyPattern().IsMatch(family)) throw ApiProblemException.Invalid("V-CAT-01", "The family code is 2 to 40 capital letters, digits or underscores, starting with a letter.");
        var tenor = b.Tenor?.Trim().ToUpperInvariant();
        if (tenor is null || !Tenors.Contains(tenor)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The tenor is ON, 1M, 3M, 6M or 12M.");
        var currencyId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @c AND IsActive = 1;",
            new { c = b.Currency?.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose the currency.");
        if (b.StaleAfterDays is <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The staleness alert is after 1 day or more.");
        var nameAr = b.NameAr?.Trim() is { Length: > 0 and <= 200 } ar ? ar : throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the Arabic name.");
        // The code is unique in the tenant; an internal rate's default code carries its institution.
        var code = (b.Code?.Trim().ToUpperInvariant() is { Length: > 0 } given ? given
            : institution is { } inst ? $"{family}_{tenor}_{Regex.Replace(inst.Code, "[^A-Z0-9_]", "_")}" : $"{family}_{tenor}");
        if (!Regex.IsMatch(code, "^[A-Z][A-Z0-9_]{1,79}$", RegexOptions.CultureInvariant)) throw ApiProblemException.Invalid("V-CAT-01", "The code is capital letters, digits and underscores.");
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM cat.BaseRate WHERE FamilyCode = @family AND Tenor = @tenor AND ((@i IS NULL AND InstitutionId IS NULL) OR InstitutionId = @i);",
                new { family, tenor, i = institution?.Id }, tx, cancellationToken: ct)) > 0)
            throw new ApiProblemException(409, "V-CAT-03", institution is null
                ? $"A market rate {family} {tenor} exists."
                : $"The institution {institution.Value.Code} already has a rate {family} {tenor}.");
        int id;
        try
        {
            id = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id INT);
                INSERT cat.BaseRate (TenantId, Code, NameAr, NameEn, Kind, InstitutionId, FamilyCode, Tenor, CurrencyId, StaleAfterDays, CreatedBy)
                OUTPUT inserted.BaseRateId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @ar, @en, @kind, @i, @family, @tenor, @currency, @stale, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """,
                new { code, ar = nameAr, en = b.NameEn?.Trim(), kind, i = institution?.Id, family, tenor, currency = currencyId, stale = b.StaleAfterDays }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "V-CAT-03", $"A rate with the code {code} exists.");
        }
        var row = await u.Connection.QuerySingleAsync<RateRow>(new CommandDefinition(Select + " WHERE r.BaseRateId = @id;", new { id }, tx, cancellationToken: ct));
        if (b.Aliases is { Count: > 0 } aliases) await SetAliasesAsync(u.Connection, tx, row, aliases, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BASE_RATE_CREATED", "CONFIG", "cat.BaseRate", id,
            AfterJson: JsonSerializer.Serialize(new { code, kind, family, tenor, institution = institution?.Code, aliases = b.Aliases })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/base-rates/{code}", new { code });
    }

    private static async Task<IResult> PatchAsync(string code, BaseRateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await FindAsync(u.Connection, tx, code, ct);
        if ((b.Kind ?? b.FamilyCode ?? b.Tenor ?? b.Currency) is not null || b.Institution is not null || (b.Code is not null && !string.Equals(b.Code, r.Code, StringComparison.OrdinalIgnoreCase)))
            throw ApiProblemException.Invalid("V-CAT-01", "The code, kind, institution, family, tenor and currency of a rate do not change.");
        if (b.StaleAfterDays is <= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The staleness alert is after 1 day or more.");
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE cat.BaseRate SET NameAr = ISNULL(@ar, NameAr), NameEn = ISNULL(@en, NameEn), StaleAfterDays = ISNULL(@stale, StaleAfterDays), IsActive = ISNULL(@active, IsActive),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
            OUTPUT inserted.RowVersion INTO @o WHERE BaseRateId = @r AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """, new { ar = b.NameAr?.Trim(), en = b.NameEn?.Trim(), stale = b.StaleAfterDays, active = b.IsActive, r = r.BaseRateId, rv = expected }, tx, cancellationToken: ct))
            ?? throw ETags.Conflict();
        if (b.Aliases is not null) await SetAliasesAsync(u.Connection, tx, r, b.Aliases, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BASE_RATE_UPDATED", "CONFIG", "cat.BaseRate", r.BaseRateId,
            AfterJson: JsonSerializer.Serialize(new { b.NameAr, b.NameEn, b.StaleAfterDays, b.IsActive, b.Aliases })), null, ct);
        await tx.CommitAsync(ct);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static async Task<long> InsertValueAsync(SqlConnection c, SqlTransaction tx, RateRow r, DateTime date, decimal value, string? note, long? supersedes,
        CancellationToken ct)
    {
        if (value is < -100m or > 1000m) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The value is a percentage between -100 and 1000.");
        try
        {
            return await c.ExecuteScalarAsync<long>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT cat.BaseRateValue (TenantId, BaseRateId, EffectiveDate, ValuePct, Source, SourceNote, Status, SupersedesId, EnteredBy, EnteredOn, CreatedBy)
                OUTPUT inserted.BaseRateValueId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @date, @value, 'MANUAL', @note, 'VALID', @supersedes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
                        SYSUTCDATETIME(), CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                SELECT Id FROM @o;
                """, new { r = r.BaseRateId, date, value, note, supersedes }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "V-CAT-03", "This rate has a value on this date: correct it instead.");
        }
    }

    /// <summary>FR-CAT-016: a value on a date, retroactive dates included; one VALID value per date (BR-CAT-012).</summary>
    private static async Task<IResult> AddValueAsync(string code, BaseRateValueRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Enter);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await FindAsync(u.Connection, tx, code, ct);
        if (!r.IsActive) throw new ApiProblemException(409, "V-CAT-INACTIVE", "The rate is inactive.");
        if (!DateTime.TryParseExact(b.EffectiveDate, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The effective date is a date YYYY-MM-DD.");
        if (b.ValuePct is not { } value) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the value.");
        var id = await InsertValueAsync(u.Connection, tx, r, date, value, b.SourceNote?.Trim() is { Length: > 0 } n ? n[..Math.Min(n.Length, 300)] : null, null, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BASE_RATE_VALUE_ENTERED", "CONFIG", "cat.BaseRateValue", id,
            AfterJson: JsonSerializer.Serialize(new { rate = r.Code, date = b.EffectiveDate, value })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "base-rate-value", id) });
    }

    /// <summary>BR-CAT-012: the correction is a new VALID row for the same date; the old row stays, SUPERSEDED.</summary>
    private static async Task<IResult> CorrectAsync(string code, string reference, BaseRateCorrectionRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Enter);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var r = await FindAsync(u.Connection, tx, code, ct);
        var valueId = refs.ItemId(u.TenantId, "base-rate-value", reference) ?? throw ApiProblemException.NotFound();
        var old = await u.Connection.QuerySingleOrDefaultAsync<(DateTime Date, decimal Value, string Status)?>(new CommandDefinition(
            "SELECT EffectiveDate, ValuePct, Status FROM cat.BaseRateValue WHERE BaseRateValueId = @v AND BaseRateId = @r;", new { v = valueId, r = r.BaseRateId }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        if (old.Status != "VALID") throw new ApiProblemException(409, "V-CAT-SUPERSEDED", "This value was already corrected.");
        if (b.ValuePct is not { } value) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the corrected value.");
        var reason = b.Reason?.Trim() is { Length: > 0 } x ? x[..Math.Min(x.Length, 300)] : throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the reason for the correction.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE cat.BaseRateValue SET Status = 'SUPERSEDED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE BaseRateValueId = @v;",
            new { v = valueId }, tx, cancellationToken: ct));
        var id = await InsertValueAsync(u.Connection, tx, r, old.Date, value, reason, valueId, ct);
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("BASE_RATE_VALUE_CORRECTED", "CONFIG", "cat.BaseRateValue", id,
            BeforeJson: JsonSerializer.Serialize(new { value = old.Value }), AfterJson: JsonSerializer.Serialize(new { rate = r.Code, value, reason })), null, ct);
        await tx.CommitAsync(ct);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "base-rate-value", id) });
    }

    /// <summary>
    /// SVC-05: by the rate's code, or by a name (family or alias) with its tenor, in the market scope or that of one
    /// institution; the VALID value of the latest effective date on or before asOf (BR-CAT-013).
    /// </summary>
    private static async Task<IResult> ResolveAsync(HttpContext http, SqlConnectionFactory db, TimeProvider clock)
    {
        Query.Allow(http.Request, "rate", "name", "tenor", "institution", "asOf");
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var q = http.Request.Query;
        var asOf = q["asOf"].ToString() is { Length: > 0 } a
            ? DateTime.TryParseExact(a, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
                : throw ApiProblemException.Invalid("VALIDATION_FAILED", "asOf is a date YYYY-MM-DD.")
            : clock.GetUtcNow().UtcDateTime.Date;
        int? rateId;
        if (q["rate"].ToString() is { Length: > 0 } rate)
            rateId = (await FindAsync(u.Connection, null, rate, ct)).BaseRateId;
        else
        {
            var name = q["name"].ToString().Trim().ToUpperInvariant();
            var tenor = q["tenor"].ToString().Trim().ToUpperInvariant();
            if (name.Length == 0 || !Tenors.Contains(tenor)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the rate, or a name and a tenor.");
            long scope = 0;
            if (Guid.TryParse(q["institution"], out var ig)) scope = (await InstitutionEndpoints.FindAsync(u.Connection, null, ig, ct)).InstitutionId;
            rateId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
                """
                SELECT TOP (1) r.BaseRateId FROM cat.BaseRate AS r
                 WHERE r.ScopeKey = @scope AND r.Tenor = @tenor
                   AND (r.FamilyCode = @name OR EXISTS (SELECT 1 FROM cat.BaseRateAlias AS al WHERE al.BaseRateId = r.BaseRateId AND al.AliasKey = @name))
                 ORDER BY CASE WHEN r.FamilyCode = @name THEN 0 ELSE 1 END;
                """, new { scope, tenor, name }, cancellationToken: ct));
            if (rateId is null) throw ApiProblemException.NotFound();
        }
        var r = await u.Connection.QuerySingleAsync<RateRow>(new CommandDefinition(Select + " WHERE r.BaseRateId = @id;", new { id = rateId }, cancellationToken: ct));
        var value = await u.Connection.QuerySingleOrDefaultAsync<(DateTime Date, decimal Value)?>(new CommandDefinition(
            """
            SELECT TOP (1) EffectiveDate, ValuePct FROM cat.BaseRateValue
             WHERE BaseRateId = @r AND Status = 'VALID' AND EffectiveDate <= @asOf ORDER BY EffectiveDate DESC;
            """, new { r = r.BaseRateId, asOf }, cancellationToken: ct));
        return Results.Ok(new
        {
            rate = r.Code, status = value is null ? "NO_VALUE" : "VALUE", effectiveDate = value?.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), valuePct = value?.Value,
        });
    }
}
