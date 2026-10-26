using System.Data;
using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record ProductRateRequest(string? Charge, string? Basis, decimal? RatePct, decimal? FixedAmount, decimal? MinAmount, decimal? MaxAmount, string? Currency,
    string? ValidFrom, string? ValidTo, string? Notes);
public sealed record ProductVolumeRequest(string? PeriodStart, string? PeriodEnd, string? Currency, decimal? Volume, int? TxnCount, decimal? FeesPaid, decimal? BankProfit,
    decimal? CompanyReturn, decimal? EndBalance, string? Notes);

/// <summary>
/// The business of a company with a bank, product by product (docs/31 row 76): the rates the company agreed for the
/// charges of a product (PRODUCT_CHARGE, by the product's nature: the networks of POS, the transfers of payroll ...),
/// and the volumes it enters by period with the commissions and charges the bank took, the bank's profit, the company's
/// return and the balance at the end. The cross-sale view sums it per bank, so the treasury sees the whole relation
/// (and its weight in a negotiation) when it asks the bank for a facility.
/// </summary>
public static class RelationshipBusinessEndpoints
{
    private const string View = "ins.view";
    private const string Manage = "ins.relationship.manage";
    private static readonly string[] Bases = ["PERCENT", "FIXED"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/product-charges", ChargesAsync);
        api.MapGet("/relationships/{id:guid}/products/{product}/business", ProductBusinessAsync);
        api.MapPost("/relationships/{id:guid}/products/{product}/rates", AddRateAsync);
        api.MapPost("/relationships/{id:guid}/products/{product}/volumes", AddVolumeAsync);
        api.MapGet("/relationships/{id:guid}/business", RelationshipSummaryAsync);
        api.MapGet("/institutions/{id:guid}/business", InstitutionSummaryAsync);
    }

    private static DateTime? Date(string? text, string field) =>
        string.IsNullOrWhiteSpace(text) ? null
        : DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is a date YYYY-MM-DD.");

    private static string? D(DateTime? d) => d?.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static string? T(string? text, int max, string field)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var t = text.Trim();
        return t.Length <= max ? t : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is up to {max} characters.");
    }

    private static decimal? NonNegative(decimal? v, string field) =>
        v is null or >= 0 ? v : throw ApiProblemException.Invalid("VALIDATION_FAILED", $"The {field} is zero or more.");

    private sealed record ChargeRow(int Id, string Code, string NameAr, string? NameEn, string? Attributes);

    /// <summary>The charge fits the product: the attribute product names it, or family names its family, or neither is set.</summary>
    private static bool Fits(string? attributes, string product, string family)
    {
        if (string.IsNullOrWhiteSpace(attributes)) return true;
        using var doc = JsonDocument.Parse(attributes);
        var p = doc.RootElement.TryGetProperty("product", out var pe) ? pe.GetString() : null;
        var f = doc.RootElement.TryGetProperty("family", out var fe) ? fe.GetString() : null;
        return (p is null && f is null) || p == product || (p is null && f == family);
    }

    private static Task<IEnumerable<ChargeRow>> ChargeRowsAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct) =>
        c.QueryAsync<ChargeRow>(new CommandDefinition(
            """
            SELECT li.LookupItemId AS Id, li.Code, li.NameAr, li.NameEn, li.Attributes FROM cat.LookupItem AS li JOIN cat.LookupList AS ll ON ll.LookupListId = li.LookupListId
             WHERE ll.Code = 'PRODUCT_CHARGE' AND li.IsActive = 1 AND li.Status = 'ACTIVE' ORDER BY li.SortOrder, li.Code;
            """, transaction: tx, cancellationToken: ct));

    private static async Task<(string Code, string Family)> ProductAsync(SqlConnection c, SqlTransaction? tx, string code, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<(string, string)?>(new CommandDefinition(
            "SELECT Code, ProductFamily FROM cat.Product WHERE Code = @code;", new { code = code.Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> ChargesAsync(HttpContext http, SqlConnectionFactory db, string? product)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var rows = await ChargeRowsAsync(u.Connection, null, ct);
        if (product is not null)
        {
            var p = await ProductAsync(u.Connection, null, product, ct);
            rows = rows.Where(r => Fits(r.Attributes, p.Code, p.Family));
        }
        return Results.Ok(new { items = rows.Select(r => new { code = r.Code, nameAr = r.NameAr, nameEn = r.NameEn }) });
    }

    /// <summary>The product of the relationship, 404 when the relationship does not handle it.</summary>
    private static async Task<(InstitutionEndpoints.RelationshipRow R, long Rp, string Code, string Family)> RelationshipProductAsync(BoundUser u, SqlTransaction? tx, Guid id,
        string product, CancellationToken ct)
    {
        var r = await InstitutionEndpoints.RelationshipAsync(u, tx, id, ct);
        var p = await ProductAsync(u.Connection, tx, product, ct);
        var rp = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT rp.RelationshipProductId FROM ins.RelationshipProduct AS rp JOIN cat.Product AS p ON p.ProductId = rp.ProductId WHERE rp.RelationshipId = @r AND p.Code = @code;",
            new { r = r.RelationshipId, code = p.Code }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();
        return (r, rp, p.Code, p.Family);
    }

    private static async Task<int> CurrencyAsync(SqlConnection c, SqlTransaction tx, string? code, CancellationToken ct) =>
        await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT CurrencyId FROM ref.Currency WHERE Code = @code;",
            new { code = (code ?? "").Trim().ToUpperInvariant() }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The currency is an ISO 4217 code.");

    private static async Task<IResult> ProductBusinessAsync(Guid id, string product, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var ct = http.RequestAborted;
        var (_, rp, _, _) = await RelationshipProductAsync(u, null, id, product, ct);
        var rates = await u.Connection.QueryAsync<(string Charge, string NameAr, string? NameEn, string Basis, decimal? Pct, decimal? Fixed, decimal? Min, decimal? Max, string Currency,
            DateTime From, DateTime? To, string? Notes)>(new CommandDefinition(
            """
            SELECT li.Code, li.NameAr, li.NameEn, r.Basis, r.RatePct, r.FixedAmount, r.MinAmount, r.MaxAmount, cu.Code, r.ValidFrom, r.ValidTo, r.Notes
              FROM ins.RelationshipProductRate AS r JOIN cat.LookupItem AS li ON li.LookupItemId = r.ChargeItemId JOIN ref.Currency AS cu ON cu.CurrencyId = r.CurrencyId
             WHERE r.RelationshipProductId = @rp ORDER BY li.SortOrder, li.Code, r.ValidFrom DESC;
            """, new { rp }, cancellationToken: ct));
        var volumes = await u.Connection.QueryAsync<(DateTime Start, DateTime End, string Currency, decimal Volume, int? Count, decimal? Fees, decimal? Profit, decimal? Return,
            decimal? Balance, string? Notes)>(new CommandDefinition(
            """
            SELECT v.PeriodStart, v.PeriodEnd, cu.Code, v.Volume, v.TxnCount, v.FeesPaid, v.BankProfit, v.CompanyReturn, v.EndBalance, v.Notes
              FROM ins.RelationshipProductVolume AS v JOIN ref.Currency AS cu ON cu.CurrencyId = v.CurrencyId
             WHERE v.RelationshipProductId = @rp ORDER BY v.PeriodStart DESC, cu.Code;
            """, new { rp }, cancellationToken: ct));
        var today = DateTime.UtcNow.Date;
        return Results.Ok(new
        {
            rates = rates.Select(r => new
            {
                charge = r.Charge, chargeNameAr = r.NameAr, chargeNameEn = r.NameEn, basis = r.Basis, ratePct = r.Pct, fixedAmount = r.Fixed, minAmount = r.Min, maxAmount = r.Max,
                currency = r.Currency, validFrom = D(r.From), validTo = D(r.To), inForce = r.From <= today && (r.To is null || r.To >= today), notes = r.Notes,
            }),
            volumes = volumes.Select(v => new
            {
                periodStart = D(v.Start), periodEnd = D(v.End), currency = v.Currency, volume = v.Volume, txnCount = v.Count, feesPaid = v.Fees, bankProfit = v.Profit,
                companyReturn = v.Return, endBalance = v.Balance, notes = v.Notes,
            }),
        });
    }

    private static async Task<IResult> AddRateAsync(Guid id, string product, ProductRateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        var basis = b.Basis?.Trim().ToUpperInvariant();
        if (basis is null || !Bases.Contains(basis)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The basis is PERCENT or FIXED.");
        if (basis == "PERCENT" && b.RatePct is not (>= 0 and <= 100)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the rate as a percent from 0 to 100.");
        if (basis == "FIXED" && b.FixedAmount is not >= 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the fixed amount.");
        var min = NonNegative(b.MinAmount, "minimum");
        var max = NonNegative(b.MaxAmount, "cap");
        if (min is not null && max is not null && max < min) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The cap is at least the minimum.");
        var from = Date(b.ValidFrom, "start date") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the date the rate applies from.");
        var to = Date(b.ValidTo, "end date");
        if (to is not null && to < from) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The rate ends on or after its start.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(IsolationLevel.Serializable, ct);
        var (r, rp, code, family) = await RelationshipProductAsync(u, tx, id, product, ct);
        if (r.Status == "CLOSED") throw new ApiProblemException(409, "V-INS-CLOSED", "A closed relationship is read-only: reopen it first.");
        var charge = (await ChargeRowsAsync(u.Connection, tx, ct)).FirstOrDefault(c => c.Code == b.Charge?.Trim().ToUpperInvariant())
            ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The charge is an active item of the product charges list.");
        if (!Fits(charge.Attributes, code, family)) throw ApiProblemException.Invalid("V-INS-CHARGE", "The charge is not a charge of this product.");
        var currency = await CurrencyAsync(u.Connection, tx, b.Currency ?? "SAR", ct);
        // A new rate of the charge ends the one in force before it, on the day before.
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ins.RelationshipProductRate SET ValidTo = DATEADD(DAY, -1, @from), UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE RelationshipProductId = @rp AND ChargeItemId = @charge AND ValidFrom < @from AND (ValidTo IS NULL OR ValidTo >= @from);
            """, new { rp, charge = charge.Id, from }, tx, cancellationToken: ct));
        try
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT ins.RelationshipProductRate (TenantId, RelationshipProductId, ChargeItemId, Basis, RatePct, FixedAmount, MinAmount, MaxAmount, CurrencyId, ValidFrom, ValidTo, Notes, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @rp, @charge, @basis, @pct, @fixed, @min, @max, @currency, @from, @to, @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new
                {
                    rp, charge = charge.Id, basis, pct = basis == "PERCENT" ? b.RatePct : null, @fixed = basis == "FIXED" ? b.FixedAmount : null, min, max, currency, from, to,
                    notes = T(b.Notes, 500, "notes"),
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ApiProblemException(409, "V-INS-RATE-TAKEN", "The charge already has a rate from this date.");
        }
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/relationships/{id}/products/{code}/business", new { charge = charge.Code });
    }

    private static async Task<IResult> AddVolumeAsync(Guid id, string product, ProductVolumeRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        var start = Date(b.PeriodStart, "period start") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the start of the period.");
        var end = Date(b.PeriodEnd, "period end") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the end of the period.");
        if (end < start) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The period ends on or after its start.");
        var volume = NonNegative(b.Volume, "volume") ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the volume of the period.");
        if (b.TxnCount is < 0) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The number of transactions is zero or more.");
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var (_, rp, code, _) = await RelationshipProductAsync(u, tx, id, product, ct);
        var currency = await CurrencyAsync(u.Connection, tx, b.Currency ?? "SAR", ct);
        try
        {
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                INSERT ins.RelationshipProductVolume (TenantId, RelationshipProductId, PeriodStart, PeriodEnd, CurrencyId, Volume, TxnCount, FeesPaid, BankProfit, CompanyReturn, EndBalance, Notes, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @rp, @start, @end, @currency, @volume, @count, @fees, @profit, @return, @balance, @notes, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                """, new
                {
                    rp, start, end, currency, volume, count = b.TxnCount, fees = NonNegative(b.FeesPaid, "commissions and charges"), profit = b.BankProfit, @return = b.CompanyReturn,
                    balance = b.EndBalance, notes = T(b.Notes, 500, "notes"),
                }, tx, cancellationToken: ct));
        }
        catch (SqlException ex) when (ex.Number is 2601 or 2627)
        {
            throw new ApiProblemException(409, "V-INS-VOLUME-TAKEN", "The product already has figures for a period starting on this date in this currency.");
        }
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/relationships/{id}/products/{code}/business", new { periodStart = D(start) });
    }

    private sealed record SummaryRow(Guid Company, string CompanyName, string Product, string ProductNameAr, string? ProductNameEn, string Family, string? Currency,
        decimal? Volume, int? TxnCount, decimal? FeesPaid, decimal? BankProfit, decimal? CompanyReturn, decimal? EndBalance, int Rates);

    /// <summary>
    /// The cross-sale view: each active product of the relationships in scope, with the sums of the periods that end in the
    /// last months (12 by default) per currency, the balance of the latest period, and the number of rates in force.
    /// </summary>
    private static async Task<object> SummaryAsync(BoundUser u, long? relationship, long? institution, int months, CancellationToken ct, Guid? company = null)
    {
        var scope = await CompanyScope.OfAsync(u, ct);
        var since = DateTime.UtcNow.Date.AddMonths(-months);
        var rows = (await u.Connection.QueryAsync<SummaryRow>(new CommandDefinition(
            """
            SELECT co.PublicId AS Company, ISNULL(co.NameAr, co.NameEn) AS CompanyName, p.Code AS Product, p.NameAr AS ProductNameAr, p.NameEn AS ProductNameEn,
                   p.ProductFamily AS Family, cu.Code AS Currency, s.Volume, s.TxnCount, s.FeesPaid, s.BankProfit, s.CompanyReturn,
                   (SELECT TOP (1) v2.EndBalance FROM ins.RelationshipProductVolume AS v2
                     WHERE v2.RelationshipProductId = rp.RelationshipProductId AND v2.CurrencyId = s.CurrencyId AND v2.EndBalance IS NOT NULL ORDER BY v2.PeriodEnd DESC) AS EndBalance,
                   (SELECT COUNT(*) FROM ins.RelationshipProductRate AS ra
                     WHERE ra.RelationshipProductId = rp.RelationshipProductId AND ra.ValidFrom <= CAST(SYSUTCDATETIME() AS DATE)
                       AND (ra.ValidTo IS NULL OR ra.ValidTo >= CAST(SYSUTCDATETIME() AS DATE))) AS Rates
              FROM ins.RelationshipProduct AS rp JOIN ins.Relationship AS r ON r.RelationshipId = rp.RelationshipId
              JOIN org.Company AS co ON co.CompanyId = r.CompanyId JOIN cat.Product AS p ON p.ProductId = rp.ProductId
              OUTER APPLY (SELECT v.CurrencyId, SUM(v.Volume) AS Volume, SUM(v.TxnCount) AS TxnCount, SUM(v.FeesPaid) AS FeesPaid, SUM(v.BankProfit) AS BankProfit,
                                  SUM(v.CompanyReturn) AS CompanyReturn
                             FROM ins.RelationshipProductVolume AS v WHERE v.RelationshipProductId = rp.RelationshipProductId AND v.PeriodEnd >= @since
                            GROUP BY v.CurrencyId) AS s
              LEFT JOIN ref.Currency AS cu ON cu.CurrencyId = s.CurrencyId
             WHERE rp.IsActive = 1 AND (@relationship IS NULL OR r.RelationshipId = @relationship) AND (@institution IS NULL OR r.InstitutionId = @institution)
               AND (@company IS NULL OR co.PublicId = @company)
               AND (@all = 1 OR r.CompanyId IN @ids)
             ORDER BY p.SortOrder, p.Code, 2, cu.Code;
            """, new { relationship, institution, company, since, all = scope.All, ids = scope.SqlIds }, cancellationToken: ct))).ToList();
        var totals = rows.Where(r => r.Currency is not null).GroupBy(r => r.Currency!).Select(g => new
        {
            currency = g.Key, volume = g.Sum(x => x.Volume ?? 0), feesPaid = g.Sum(x => x.FeesPaid ?? 0), bankProfit = g.Sum(x => x.BankProfit ?? 0),
            companyReturn = g.Sum(x => x.CompanyReturn ?? 0), endBalance = g.Sum(x => x.EndBalance ?? 0),
        });
        return new
        {
            months, since = D(since),
            products = rows.Select(r => new
            {
                company = r.Company, companyName = r.CompanyName, product = r.Product, productNameAr = r.ProductNameAr, productNameEn = r.ProductNameEn, family = r.Family,
                currency = r.Currency, volume = r.Volume, txnCount = r.TxnCount, feesPaid = r.FeesPaid, bankProfit = r.BankProfit, companyReturn = r.CompanyReturn,
                endBalance = r.EndBalance, ratesInForce = r.Rates,
            }),
            productCount = rows.Select(r => r.Product).Distinct(StringComparer.Ordinal).Count(),
            totals,
        };
    }

    private static int Months(int? months) => months is null ? 12 : months is >= 1 and <= 120 ? months.Value
        : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The months are 1 to 120.");

    private static async Task<IResult> RelationshipSummaryAsync(Guid id, HttpContext http, SqlConnectionFactory db, int? months)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var r = await InstitutionEndpoints.RelationshipAsync(u, null, id, http.RequestAborted);
        return Results.Ok(await SummaryAsync(u, r.RelationshipId, null, Months(months), http.RequestAborted));
    }

    private static async Task<IResult> InstitutionSummaryAsync(Guid id, HttpContext http, SqlConnectionFactory db, int? months, Guid? company)
    {
        await using var u = await BoundUser.OpenAsync(http, db, View);
        var institution = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT InstitutionId FROM ins.Institution WHERE PublicId = @id;", new { id },
            cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
        return Results.Ok(await SummaryAsync(u, null, institution, Months(months), http.RequestAborted, company));
    }
}
