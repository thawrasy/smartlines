using System.Globalization;
using BankFas.Api.Infrastructure;
using BankFas.Core.Calendar;
using BankFas.Data;
using BankFas.Data.Calendar;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record NonWorkingDayRequest(string? Country, string? OnDate, string? NameAr, string? NameEn, string? Kind);

/// <summary>
/// The calendar of non-working days (FR-PLT-035, BR-PLT-014): the platform's holidays per country, read by every tenant
/// and entered by an operator, and the tenant's own days, entered by its administrator. The working-day service and the
/// Hijri conversion (FR-PLT-033) are answered for the screens.
/// </summary>
public static class CalendarEndpoints
{
    private static readonly string[] Kinds = ["HOLIDAY", "BRIDGE", "OTHER"];

    public static void MapPortal(RouteGroupBuilder api)
    {
        api.MapGet("/non-working-days", ListAsync);
        api.MapPost("/non-working-days", AddAsync);
        api.MapDelete("/non-working-days/{reference}", DeleteAsync);
        api.MapGet("/services/working-days", WorkingDaysAsync);
        api.MapGet("/services/hijri", Hijri);
    }

    public static void MapOperator(RouteGroupBuilder panel)
    {
        panel.MapGet("/non-working-days", OperatorListAsync);
        panel.MapPost("/non-working-days", OperatorAddAsync);
    }

    private sealed record Day(long NonWorkingDayId, int? TenantId, string Country, DateTime OnDate, string? NameAr, string? NameEn, string Kind);

    private const string Select =
        "SELECT d.NonWorkingDayId, d.TenantId, c.Iso2 AS Country, d.OnDate, d.NameAr, d.NameEn, d.Kind FROM cfg.NonWorkingDay AS d JOIN ref.Country AS c ON c.CountryId = d.CountryId";

    private static (int Year, string? Country) Filter(HttpRequest r)
    {
        Query.Allow(r, "year", "country");
        var year = int.TryParse(r.Query["year"], NumberStyles.None, CultureInfo.InvariantCulture, out var y) ? y : DateTime.UtcNow.Year;
        return (year, r.Query["country"].ToString() is { Length: 2 } c ? c.ToUpperInvariant() : null);
    }

    private static async Task<int> CountryAsync(SqlConnection c, SqlTransaction? tx, string? iso2, CancellationToken ct) =>
        await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CountryId FROM ref.Country WHERE Iso2 = @c;", new { c = iso2?.Trim().ToUpperInvariant() }, tx,
            cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The country is an ISO code of two letters.");

    private static (DateTime Date, string Kind) Validate(NonWorkingDayRequest b)
    {
        if (!DateTime.TryParseExact(b.OnDate, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "The day is a date YYYY-MM-DD.");
        var kind = b.Kind?.Trim().ToUpperInvariant() ?? "HOLIDAY";
        if (!Kinds.Contains(kind)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The kind is a holiday, a bridge day or another day.");
        if (string.IsNullOrWhiteSpace(b.NameAr) && string.IsNullOrWhiteSpace(b.NameEn)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the name of the day.");
        return (d, kind);
    }

    private static object Shape(Day d, int tenant, OpaqueRefs refs) => new
    {
        id = d.TenantId is null ? null : refs.ItemRef(tenant, "non-working-day", d.NonWorkingDayId), platform = d.TenantId is null, country = d.Country,
        onDate = d.OnDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), nameAr = d.NameAr, nameEn = d.NameEn, kind = d.Kind,
    };

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (year, country) = Filter(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db);
        var rows = await u.Connection.QueryAsync<Day>(new CommandDefinition(Select + " WHERE YEAR(d.OnDate) = @y AND (@c IS NULL OR c.Iso2 = @c) ORDER BY d.OnDate;",
            new { y = year, c = country }, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows.Select(d => Shape(d, u.TenantId, refs)) });
    }

    private static async Task<IResult> AddAsync(NonWorkingDayRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (date, kind) = Validate(b);
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.settings.manage");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var country = await CountryAsync(u.Connection, tx, b.Country, http.RequestAborted);
        if (await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM cfg.NonWorkingDay WHERE CountryId = @c AND OnDate = @d;",
                new { c = country, d = date }, tx, cancellationToken: http.RequestAborted)) > 0)
            throw new ApiProblemException(409, "V-PLT-DAY-EXISTS", "This day is already a non-working day.");
        var id = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameAr, NameEn, Kind) OUTPUT inserted.NonWorkingDayId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @c, @d, @ar, @en, @k);
            SELECT Id FROM @o;
            """, new { c = country, d = date, ar = b.NameAr?.Trim(), en = b.NameEn?.Trim(), k = kind }, tx, cancellationToken: http.RequestAborted));
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("NON_WORKING_DAY_ADDED", "CONFIG", "cfg.NonWorkingDay", id,
            AfterJson: System.Text.Json.JsonSerializer.Serialize(new { country = b.Country, onDate = b.OnDate, kind })), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created("/api/v1/non-working-days", new { id = refs.ItemRef(u.TenantId, "non-working-day", id) });
    }

    private static async Task<IResult> DeleteAsync(string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, "cfg.settings.manage");
        var id = refs.ItemId(u.TenantId, "non-working-day", reference) ?? throw ApiProblemException.NotFound();
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition("DELETE FROM cfg.NonWorkingDay WHERE NonWorkingDayId = @id AND TenantId IS NOT NULL;",
            new { id }, tx, cancellationToken: http.RequestAborted));
        if (n == 0) throw ApiProblemException.NotFound();
        await AuditWriter.WriteAsync(u.Connection, tx, new AuditEntry("NON_WORKING_DAY_REMOVED", "CONFIG", "cfg.NonWorkingDay", id), null, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>N working days after (or, negative, before) a date in a country (BR-OBL-004).</summary>
    private static async Task<IResult> WorkingDaysAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "country", "from", "days");
        if (!DateOnly.TryParseExact(http.Request.Query["from"], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var from)
            || !int.TryParse(http.Request.Query["days"], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var days) || Math.Abs(days) > 3660)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start date YYYY-MM-DD and a number of working days.");
        await using var u = await BoundUser.OpenAsync(http, db);
        var country = await CountryAsync(u.Connection, null, http.Request.Query["country"], http.RequestAborted);
        var result = await WorkingCalendar.AddWorkingDaysAsync(u.Connection, null, country, from, days, http.RequestAborted);
        return Results.Ok(new { date = result.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) });
    }

    /// <summary>FR-PLT-033: the Gregorian date of a Hijri date, or the Hijri date of a Gregorian one.</summary>
    private static IResult Hijri(HttpRequest r)
    {
        Query.Allow(r, "hijri", "gregorian");
        if (r.Query["hijri"].ToString() is { Length: > 0 } h)
            return HijriDates.ToGregorian(h) is { } g
                ? Results.Ok(new { gregorian = g.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), hijri = h })
                : throw ApiProblemException.Invalid("V-PLT-HIJRI", "This Hijri date does not exist.");
        if (DateOnly.TryParseExact(r.Query["gregorian"], "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
            return Results.Ok(new { gregorian = d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), hijri = HijriDates.FromGregorian(d) });
        throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give a Hijri or a Gregorian date.");
    }

    // ---------- the operator's platform holidays ----------

    private static async Task<IResult> OperatorListAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (year, country) = Filter(http.Request);
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            var rows = await c.QueryAsync<Day>(new CommandDefinition(Select + " WHERE d.TenantId IS NULL AND YEAR(d.OnDate) = @y AND (@c IS NULL OR c.Iso2 = @c) ORDER BY d.OnDate;",
                new { y = year, c = country }, cancellationToken: http.RequestAborted));
            return Results.Ok(new
            {
                items = rows.Select(d => new { country = d.Country, onDate = d.OnDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), nameAr = d.NameAr, nameEn = d.NameEn, kind = d.Kind }),
            });
        }
    }

    private static async Task<IResult> OperatorAddAsync(NonWorkingDayRequest b, HttpContext http, SqlConnectionFactory db)
    {
        var (date, kind) = Validate(b);
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(http.RequestAborted);
            var country = await CountryAsync(c, tx, b.Country, http.RequestAborted);
            if (await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT COUNT(*) FROM cfg.NonWorkingDay WHERE TenantId IS NULL AND CountryId = @c AND OnDate = @d;",
                    new { c = country, d = date }, tx, cancellationToken: http.RequestAborted)) > 0)
                throw new ApiProblemException(409, "V-PLT-DAY-EXISTS", "This day is already a non-working day.");
            await c.ExecuteAsync(new CommandDefinition(
                "INSERT cfg.NonWorkingDay (TenantId, CountryId, OnDate, NameAr, NameEn, Kind) VALUES (NULL, @c, @d, @ar, @en, @k);",
                new { c = country, d = date, ar = b.NameAr?.Trim(), en = b.NameEn?.Trim(), k = kind }, tx, cancellationToken: http.RequestAborted));
            await OperatorAdminEndpoints.WritePlatformAuditAsync(c, tx, s.OperatorId, "PLATFORM_HOLIDAY_ADDED", "cfg.NonWorkingDay", null,
                new { country = b.Country, onDate = b.OnDate, kind }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.Created("/api/v1/operator/non-working-days", new { onDate = b.OnDate });
        }
    }
}
