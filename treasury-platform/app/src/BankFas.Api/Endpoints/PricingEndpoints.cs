using System.Globalization;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Pricing;
using BankFas.Data;
using BankFas.Data.Facilities;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record PricingTierRequest(decimal? AmountFrom, decimal? AmountTo, int? PeriodFromDays, int? PeriodToDays, decimal? RatePct, decimal? MarginPct, decimal? FixedAmount);
public sealed record PricingRuleRequest(string? ScopeLimit, string? ScopeLine, string? ScopeProduct, Guid? ScopeCompany, string? ComponentKind, string? RateState, string? FeeType,
    string? FinancingType, string? Method, string? TariffItem, decimal? AddOnPct, string? BaseRate, decimal? MarginPct, decimal? BaseFloorPct, decimal? RatePct,
    decimal? RateRangeLowPct, decimal? RateRangeHighPct, decimal? FixedAmount, decimal? PerMillionAmount, string? Currency, string? PeriodBasis, int? PeriodDays,
    decimal? MinFeeAmount, decimal? MaxFeeAmount, string? RateFixing, int? RepricingMonths, string? DayCount, bool? VatExclusive, string? BenchmarkReplacement,
    string? ReplacementText, string? BankMayChange, int? ObjectionDays, string? ObjectionDaysKind, string? TriggerEvent, string? EffectiveFrom, string? RetroactiveReason,
    PricingTierRequest[]? Tiers, Guid? SourceDocument, string? SourcePage, bool? ReadFromScan, string? OriginalText, string? NoSourceReason);
public sealed record ResolveRequest(Guid? Facility, string? Limit, string? Line, Guid? Company, string? Product, string? FeeType, string? FinancingType, decimal? Amount, int? Days,
    string? AsOf, string? ContractDate);

/// <summary>
/// The pricing rules of a facility, written in its draft revision (FR-PRC-006 to 017; BR-PRC-003 to 012), and
/// ResolvePricing (SVC-FAC-05, BR-PRC-010) on the approved revision. A rule names its scope (a line, a limit or the
/// facility; a product; a company) and the component it prices; its method fixes the fields it holds, and a rate the
/// signed agreement left blank is NOT_SPECIFIED_IN_AGREEMENT with no rate at all (BR-PRC-012). A new version from F
/// ends the previous one of the same scope on F-1 in the same revision (BR-PRC-011); a start before today is
/// retroactive and needs its reason.
/// </summary>
public static class PricingEndpoints
{
    private const string View = "prc.view";
    private const string Manage = "prc.manage";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/facilities/{id:guid}/pricing-rules", ListAsync);
        api.MapPost("/facilities/{id:guid}/pricing-rules", AddAsync);
        api.MapDelete("/facilities/{id:guid}/pricing-rules/{reference}", RemoveAsync);
        api.MapPost("/pricing/resolve", ResolveAsync);
    }

    internal sealed class RuleRow
    {
        public long PricingRuleId { get; init; }
        public long RootId { get; init; }
        public long? ScopeLimitRoot { get; init; }
        public string? ScopeLimitCode { get; init; }
        public long? ScopeLineRoot { get; init; }
        public int? ScopeProductId { get; init; }
        public string? ScopeProduct { get; init; }
        public long? ScopeCompanyId { get; init; }
        public Guid? ScopeCompany { get; init; }
        public string ComponentKind { get; init; } = "";
        public string RateState { get; init; } = "";
        public string? FeeType { get; init; }
        public string? FinancingType { get; init; }
        public string Method { get; init; } = "";
        public long? TariffItemId { get; init; }
        public decimal? AddOnPct { get; init; }
        public int? BaseRateId { get; init; }
        public string? BaseRate { get; init; }
        public decimal? MarginPct { get; init; }
        public decimal? BaseFloorPct { get; init; }
        public decimal? RatePct { get; init; }
        public decimal? RateRangeLowPct { get; init; }
        public decimal? RateRangeHighPct { get; init; }
        public decimal? FixedAmount { get; init; }
        public decimal? PerMillionAmount { get; init; }
        public string? PeriodBasis { get; init; }
        public int? PeriodDays { get; init; }
        public decimal? MinFeeAmount { get; init; }
        public decimal? MaxFeeAmount { get; init; }
        public string? RateFixing { get; init; }
        public string? DayCount { get; init; }
        public bool VatExclusive { get; init; }
        public string BankMayChange { get; init; } = "";
        public int? ObjectionDays { get; init; }
        public DateTime EffectiveFrom { get; init; }
        public DateTime? EffectiveTo { get; init; }
        public bool Retroactive { get; init; }
        public int FromRevision { get; init; }
    }

    private const string RuleSelect =
        """
        SELECT r.PricingRuleId, r.RootId, l.RootId AS ScopeLimitRoot, l.Code AS ScopeLimitCode, ln.RootId AS ScopeLineRoot, r.ScopeProductId, p.Code AS ScopeProduct,
               r.ScopeCompanyId, co.PublicId AS ScopeCompany, r.ComponentKind, r.RateState, ft.Code AS FeeType, fn.Code AS FinancingType, r.Method, r.TariffItemId, r.AddOnPct,
               r.BaseRateId, br.Code AS BaseRate, r.MarginPct, r.BaseFloorPct, r.RatePct, r.RateRangeLowPct, r.RateRangeHighPct, r.FixedAmount, r.PerMillionAmount, r.PeriodBasis,
               r.PeriodDays, r.MinFeeAmount, r.MaxFeeAmount, r.RateFixing, r.DayCount, r.VatExclusive, r.BankMayChange, r.ObjectionDays, r.EffectiveFrom, r.EffectiveTo, r.Retroactive,
               r.FromRevision
          FROM prc.PricingRule AS r
          LEFT JOIN fac.Limit AS l ON l.LimitId = r.ScopeLimitId
          LEFT JOIN fac.LimitProductLine AS ln ON ln.LimitProductLineId = r.ScopeLimitProductLineId
          LEFT JOIN cat.Product AS p ON p.ProductId = r.ScopeProductId
          LEFT JOIN org.Company AS co ON co.CompanyId = r.ScopeCompanyId
          LEFT JOIN cat.FeeType AS ft ON ft.FeeTypeId = r.FeeTypeId
          LEFT JOIN cat.FinancingType AS fn ON fn.FinancingTypeId = r.FinancingTypeId
          LEFT JOIN cat.BaseRate AS br ON br.BaseRateId = r.BaseRateId
        """;

    internal static async Task<List<RuleRow>> RulesAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, CancellationToken ct) =>
        [.. await c.QueryAsync<RuleRow>(new CommandDefinition(RuleSelect + (rev == int.MaxValue
            ? " WHERE r.FacilityId = @f AND r.ToRevision IS NULL"
            : " WHERE r.FacilityId = @f AND r.FromRevision <= @rev AND (r.ToRevision IS NULL OR r.ToRevision > @rev)") + " ORDER BY r.EffectiveFrom;",
            new { f = facility, rev }, tx, cancellationToken: ct))];

    private static async Task<Dictionary<long, TariffItemSpec>> ItemsAsync(SqlConnection c, SqlTransaction? tx, IEnumerable<long> ids, CancellationToken ct)
    {
        var list = ids.Distinct().ToArray();
        if (list.Length == 0) return [];
        var items = await c.QueryAsync<(long Id, string Code, string Kind, decimal? Rate, decimal? Fixed, decimal? PerMillion, string Basis, int? Days, decimal? Min, decimal? Max,
            string? TierMode, string Vat, string Status)>(new CommandDefinition(
            """
            SELECT t.TariffItemId, t.ItemCode, t.ChargeKind, t.Rate, t.FixedAmount, t.PerMillionAmount, t.PeriodBasis, t.PeriodDays, t.MinAmount, t.MaxAmount, t.TierCalcMode,
                   t.VatTreatment, s.Status
              FROM prc.TariffItem AS t JOIN prc.TariffSchedule AS s ON s.TariffScheduleId = t.ScheduleId WHERE t.TariffItemId IN @ids;
            """, new { ids = list }, tx, cancellationToken: ct));
        var tiers = (await c.QueryAsync<(long Item, decimal? AF, decimal? AT, int? PF, int? PT, decimal? Rate, decimal? Fixed)>(new CommandDefinition(
            "SELECT TariffItemId, AmountFrom, AmountTo, PeriodFromDays, PeriodToDays, Rate, FixedAmount FROM prc.TariffTier WHERE TariffItemId IN @ids ORDER BY SortOrder;",
            new { ids = list }, tx, cancellationToken: ct))).ToLookup(t => t.Item);
        return items.ToDictionary(i => i.Id, i => new TariffItemSpec(i.Id, i.Code, i.Kind, i.Rate, i.Fixed, i.PerMillion, i.Basis, i.Days, i.Min, i.Max, i.TierMode ?? "BAND", i.Vat,
            [.. tiers[i.Id].Select(t => new Tier(t.AF, t.AT, t.PF, t.PT, t.Rate, t.Fixed))], null, i.Status == "APPROVED"));
    }

    internal static async Task<List<RuleSpec>> SpecsAsync(SqlConnection c, SqlTransaction? tx, long facility, int rev, CancellationToken ct)
    {
        var rows = await RulesAsync(c, tx, facility, rev, ct);
        var items = await ItemsAsync(c, tx, rows.Where(r => r.TariffItemId is not null).Select(r => r.TariffItemId!.Value), ct);
        var tiers = (await c.QueryAsync<(long Rule, decimal? AF, decimal? AT, int? PF, int? PT, decimal? Rate, decimal? Margin, decimal? Fixed)>(new CommandDefinition(
            "SELECT PricingRuleId, AmountFrom, AmountTo, PeriodFromDays, PeriodToDays, RatePct, MarginPct, FixedAmount FROM prc.PricingTier WHERE FacilityId = @f AND "
            + (rev == int.MaxValue ? "ToRevision IS NULL" : "FromRevision <= @rev AND (ToRevision IS NULL OR ToRevision > @rev)") + " ORDER BY SortOrder;",
            new { f = facility, rev }, tx, cancellationToken: ct))).ToLookup(t => t.Rule);
        return [.. rows.Select(r => new RuleSpec(r.RootId, r.ScopeLimitRoot, r.ScopeLineRoot, r.ScopeProductId, r.ScopeCompanyId, r.ComponentKind, r.RateState, r.FeeType,
            r.FinancingType, r.Method, r.TariffItemId is { } t ? items.GetValueOrDefault(t) : null, r.AddOnPct, r.BaseRateId, r.MarginPct, r.BaseFloorPct, r.RatePct,
            r.RateRangeLowPct, r.RateRangeHighPct, r.FixedAmount, r.PerMillionAmount, r.PeriodBasis, r.PeriodDays, r.MinFeeAmount, r.MaxFeeAmount, r.RateFixing, r.DayCount,
            r.VatExclusive, r.EffectiveFrom, r.EffectiveTo, [.. tiers[r.PricingRuleId].Select(x => new Tier(x.AF, x.AT, x.PF, x.PT, x.Rate, x.Fixed, x.Margin))]))];
    }

    /// <summary>V-PRC-02 warnings of a revision: no base value at a rule's start, a negative margin, a tariff item not approved.</summary>
    internal static async Task<List<(string Code, string Message)>> WarningsAsync(SqlConnection c, SqlTransaction? tx, long facility, CancellationToken ct)
    {
        var rows = await RulesAsync(c, tx, facility, int.MaxValue, ct);
        var w = new List<(string, string)>();
        foreach (var r in rows.Where(r => r.RateState == "SET"))
        {
            if (r.BaseRateId is { } b && await c.ExecuteScalarAsync<int>(new CommandDefinition(
                    "SELECT COUNT(*) FROM cat.BaseRateValue WHERE BaseRateId = @b AND Status = 'VALID' AND EffectiveDate <= @d;", new { b, d = r.EffectiveFrom }, tx, cancellationToken: ct)) == 0)
                w.Add(("V-PRC-02", $"The base rate {r.BaseRate} has no value at the start of its rule."));
            if (r.MarginPct < 0) w.Add(("V-PRC-02", "A rule has a negative margin."));
            if (r.TariffItemId is { } t && await c.ExecuteScalarAsync<string>(new CommandDefinition(
                    "SELECT s.Status FROM prc.TariffItem AS i JOIN prc.TariffSchedule AS s ON s.TariffScheduleId = i.ScheduleId WHERE i.TariffItemId = @t;", new { t }, tx, cancellationToken: ct)) != "APPROVED")
                w.Add(("V-PRC-02", "A rule uses a tariff item whose schedule is not approved."));
        }
        return w;
    }

    private static object Shape(RuleRow r, int tenant, OpaqueRefs refs) => new
    {
        id = refs.ItemRef(tenant, "pricing-rule", r.RootId), scopeLimit = r.ScopeLimitCode, scopeLine = r.ScopeLineRoot is { } l ? refs.ItemRef(tenant, "line", l) : null,
        scopeProduct = r.ScopeProduct, scopeCompany = r.ScopeCompany, componentKind = r.ComponentKind, rateState = r.RateState, feeType = r.FeeType, financingType = r.FinancingType,
        method = r.Method, tariffItem = r.TariffItemId is { } t ? refs.ItemRef(tenant, "tariff-item", t) : null, addOnPct = r.AddOnPct, baseRate = r.BaseRate, marginPct = r.MarginPct,
        baseFloorPct = r.BaseFloorPct, ratePct = r.RatePct, rateRangeLowPct = r.RateRangeLowPct, rateRangeHighPct = r.RateRangeHighPct, fixedAmount = r.FixedAmount,
        perMillionAmount = r.PerMillionAmount, periodBasis = r.PeriodBasis, periodDays = r.PeriodDays, minFeeAmount = r.MinFeeAmount, maxFeeAmount = r.MaxFeeAmount,
        rateFixing = r.RateFixing, dayCount = r.DayCount, vatExclusive = r.VatExclusive, bankMayChange = r.BankMayChange, objectionDays = r.ObjectionDays,
        effectiveFrom = FacilityEndpoints.D(r.EffectiveFrom), effectiveTo = FacilityEndpoints.D(r.EffectiveTo), retroactive = r.Retroactive, fromRevision = r.FromRevision,
    };

    /// <summary>The rules of the approved revision, or of the draft (view=draft); R-PRC-02 lists those not specified in the agreement.</summary>
    private static async Task<IResult> ListAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "view");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _u = u;
        var f = await FacilityEndpoints.FindAsync(u, null, id, scope, http.RequestAborted);
        var rows = await RulesAsync(u.Connection, null, f.FacilityId, http.Request.Query["view"] == "draft" ? int.MaxValue : f.ApprovedRevisionNo, http.RequestAborted);
        return Results.Ok(new
        {
            items = rows.Select(r => Shape(r, u.TenantId, refs)),
            notSpecified = rows.Where(r => r.RateState == "NOT_SPECIFIED_IN_AGREEMENT").Select(r => new { feeType = r.FeeType, financingType = r.FinancingType, scopeLimit = r.ScopeLimitCode }),
        });
    }

    private static readonly string[] Methods = ["TARIFF_AS_IS", "TARIFF_PLUS_ADDON", "BASE_PLUS_MARGIN", "PERCENT_OF_AMOUNT", "FIXED_AMOUNT", "PER_MILLION", "TIERED"];

    /// <summary>V-PRC-02 and BR-PRC-012: a SET rule holds the fields its method needs and no other; a rule not specified in the agreement holds no rate at all.</summary>
    private static void CheckFields(PricingRuleRequest b, string method, string state)
    {
        var rateFields = new object?[] { b.AddOnPct, b.MarginPct, b.RatePct, b.RateRangeLowPct, b.RateRangeHighPct, b.FixedAmount, b.PerMillionAmount };
        if (state == "NOT_SPECIFIED_IN_AGREEMENT")
        {
            if (rateFields.Any(x => x is not null) || b.Tiers is { Length: > 0 })
                throw ApiProblemException.Invalid("V-PRC-02", "A rate the agreement leaves blank has no rate at all, not even zero (BR-PRC-012).");
            return;
        }
        var ok = method switch
        {
            "TARIFF_AS_IS" => b.TariffItem is not null && rateFields.All(x => x is null),
            "TARIFF_PLUS_ADDON" => b.TariffItem is not null && b.AddOnPct is not null,
            "BASE_PLUS_MARGIN" => b.BaseRate is not null && b.MarginPct is not null && b.RateFixing is not null && b.DayCount is not null,
            "PERCENT_OF_AMOUNT" => b.RatePct is not null || (b.RateRangeLowPct is not null && b.RateRangeHighPct is not null),
            "FIXED_AMOUNT" => b.FixedAmount is not null,
            "PER_MILLION" => b.PerMillionAmount is not null,
            _ => b.Tiers is { Length: > 0 },
        };
        if (!ok) throw ApiProblemException.Invalid("V-PRC-02", "Give the values the method needs: for a rate not in the agreement, mark it NOT_SPECIFIED_IN_AGREEMENT.");
        if (b.RatePct is < 0 or > 100) throw ApiProblemException.Invalid("V-PRC-02", "A rate is from 0 to 100.");
        if (b.RateRangeLowPct > b.RateRangeHighPct) throw ApiProblemException.Invalid("V-PRC-02", "The low end of the range is at most its high end.");
        if (b.RateFixing == "FLOATING" && b.RepricingMonths is not > 0) throw ApiProblemException.Invalid("V-PRC-02", "A floating rate gives its repricing months.");
        if (b.PeriodBasis == "PER_ANNUM" && b.DayCount is null) throw ApiProblemException.Invalid("V-PRC-02", "A rate per annum gives its day count (BR-PRC-009).");
    }

    private static async Task<IResult> AddAsync(Guid id, PricingRuleRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        var method = b.Method?.Trim().ToUpperInvariant() ?? "";
        var state = b.RateState?.Trim().ToUpperInvariant() ?? "SET";
        if (!Methods.Contains(method)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The method is one of the methods of the pricing rules.");
        if (state is not ("SET" or "NOT_SPECIFIED_IN_AGREEMENT")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The rate is SET or NOT_SPECIFIED_IN_AGREEMENT.");
        if ((b.FeeType is null) == (b.FinancingType is null)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A rule prices a fee type or a financing type.");
        CheckFields(b, method, state);
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, Manage);
        await using var _u = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var from = LimitEndpoints.Date(b.EffectiveFrom, "start date") ?? d.Rev.Header(d.F).Effective;
        if (from < today && string.IsNullOrWhiteSpace(b.RetroactiveReason)) throw ApiProblemException.Invalid("V-PRC-RETRO", "A rule that starts before today is retroactive: give the reason (BR-PRC-011).");

        // The scope, by the draft's rows.
        var limitRoot = refs.ItemId(u.TenantId, "limit", b.ScopeLimit);
        var lineRoot = refs.ItemId(u.TenantId, "line", b.ScopeLine);
        var line = lineRoot is null ? null : d.Rows.Lines.FirstOrDefault(x => x.RootId == lineRoot) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The line is not a line of the facility.");
        limitRoot ??= line?.LimitRootId;
        var limit = limitRoot is null ? null : d.Rows.Limits.FirstOrDefault(x => x.RootId == limitRoot) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The limit is not a limit of the facility.");
        if (line is not null && line.LimitRootId != limit!.RootId) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The line is a line of the limit given.");
        int? product = b.ScopeProduct is null ? null : await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ProductId FROM cat.Product WHERE Code = @c;",
            new { c = b.ScopeProduct.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The product is not in the catalogue.");
        long? company = b.ScopeCompany is null ? null : (await CompanyEndpoints.FindAsync(u, tx, b.ScopeCompany.Value, scope, ct)).CompanyId;

        // The component: a fee type (its nature decides a penalty, BR-PRC-008) or a financing type.
        var kind = b.ComponentKind?.Trim().ToUpperInvariant();
        int? feeType = null, financing = null;
        if (b.FeeType is not null)
        {
            var fee = await u.Connection.QuerySingleOrDefaultAsync<(int Id, string Nature)?>(new CommandDefinition("SELECT FeeTypeId, Nature FROM cat.FeeType WHERE Code = @c;",
                new { c = b.FeeType.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The fee type is not in the catalogue.");
            feeType = fee.Id;
            kind = fee.Nature == "PENALTY_NON_INCOME" ? "PENALTY_NON_INCOME" : kind ?? "FEE";
            if (kind == "FINANCING_RETURN") throw ApiProblemException.Invalid("VALIDATION_FAILED", "A financing return prices a financing type.");
        }
        else
        {
            financing = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT FinancingTypeId FROM cat.FinancingType WHERE Code = @c;",
                new { c = b.FinancingType!.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The financing type is not in the catalogue.");
            kind = "FINANCING_RETURN";
        }
        if (kind == "PENALTY_NON_INCOME" && b.TriggerEvent is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A penalty names the event that triggers it.");
        if (kind != "PENALTY_NON_INCOME" && b.TriggerEvent is not null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Only a penalty has a trigger event.");

        long? item = null;
        if (b.TariffItem is not null)
        {
            item = refs.ItemId(u.TenantId, "tariff-item", b.TariffItem) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The tariff item is not an item of a schedule.");
            var chargeKind = await u.Connection.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT ChargeKind FROM prc.TariffItem WHERE TariffItemId = @i;", new { i = item }, tx,
                cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The tariff item is not an item of a schedule.");
            if (method == "TARIFF_PLUS_ADDON" && chargeKind == "FIXED") throw ApiProblemException.Invalid("V-PRC-02", "An add-on is not allowed on a fixed-amount item (BR-PRC-004).");
        }
        int? baseRate = b.BaseRate is null ? null : await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT BaseRateId FROM cat.BaseRate WHERE Code = @c;",
            new { c = b.BaseRate.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "The base rate is not in the catalogue.");
        var src = await LimitEndpoints.SourceAsync(u, tx, d.F, b.SourceDocument, b.SourcePage, b.ReadFromScan, b.OriginalText, b.NoSourceReason, ct);

        // BR-PRC-011: the version of the same component and scope that is open ends the day before this one starts.
        var key = new { feeType, financing, limit = limit?.LimitId, line = line?.LimitProductLineId, product, company };
        var current = await u.Connection.QuerySingleOrDefaultAsync<(long Id, DateTime From)?>(new CommandDefinition(
            """
            SELECT TOP (1) PricingRuleId, EffectiveFrom FROM prc.PricingRule
             WHERE FacilityId = @fac AND ToRevision IS NULL AND EffectiveTo IS NULL
               AND (FeeTypeId = @feeType OR (FeeTypeId IS NULL AND @feeType IS NULL)) AND (FinancingTypeId = @financing OR (FinancingTypeId IS NULL AND @financing IS NULL))
               AND (ScopeLimitId = @limit OR (ScopeLimitId IS NULL AND @limit IS NULL)) AND (ScopeLimitProductLineId = @line OR (ScopeLimitProductLineId IS NULL AND @line IS NULL))
               AND (ScopeProductId = @product OR (ScopeProductId IS NULL AND @product IS NULL)) AND (ScopeCompanyId = @company OR (ScopeCompanyId IS NULL AND @company IS NULL))
             ORDER BY EffectiveFrom DESC;
            """, new { fac = d.F.FacilityId, key.feeType, key.financing, key.limit, key.line, key.product, key.company }, tx, cancellationToken: ct));
        if (current is { } cur)
        {
            if (cur.From >= from) throw new ApiProblemException(409, "V-PRC-VERSION", "The current version of this rule starts on or after this one.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "UPDATE prc.PricingRule SET EffectiveTo = @to, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE PricingRuleId = @id;",
                new { to = from.AddDays(-1), id = cur.Id }, tx, cancellationToken: ct));
        }
        var root = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (RootId BIGINT, Id BIGINT);
            INSERT prc.PricingRule (TenantId, FacilityId, ScopeLimitId, ScopeLimitProductLineId, ScopeProductId, ScopeCompanyId, ComponentKind, RateState, FeeTypeId, FinancingTypeId,
                                    Method, TariffItemId, AddOnPct, BaseRateId, MarginPct, BaseFloorPct, RatePct, RateRangeLowPct, RateRangeHighPct, FixedAmount, PerMillionAmount,
                                    CurrencyId, PeriodBasis, PeriodDays, MinFeeAmount, MaxFeeAmount, RateFixing, RepricingMonths, DayCount, VatExclusive, BenchmarkReplacement,
                                    ReplacementText, BankMayChange, ObjectionDays, ObjectionDaysKind, TriggerEvent, EffectiveFrom, Retroactive, RetroactiveReason, FromRevision,
                                    SourceDocumentId, SourcePage, ReadFromScan, OriginalText, NoSourceReason, Confidence, CreatedBy)
            OUTPUT inserted.RootId, inserted.PricingRuleId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @fac, @limit, @line, @product, @company, @kind, @state, @feeType, @financing, @method, @item, @addOn, @baseRate,
                    @margin, @floor, @rate, @low, @high, @fixed, @pm, @cur, @basis, @days, @min, @max, @fixing, @repricing, @dayCount, @vat, @bench, @benchText, @bank,
                    @objDays, @objKind, @trigger, @from, @retro, @retroReason, @r, @doc, @page, @scan, @orig, @nsr, @conf, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT RootId FROM @o;
            """, new
            {
                fac = d.F.FacilityId, key.limit, key.line, key.product, key.company, kind, state, key.feeType, key.financing, method, item, addOn = b.AddOnPct, baseRate,
                margin = b.MarginPct, floor = b.BaseFloorPct, rate = b.RatePct, low = b.RateRangeLowPct, high = b.RateRangeHighPct, @fixed = b.FixedAmount, pm = b.PerMillionAmount,
                cur = b.Currency is null ? null : (int?)await FacilityEndpoints.CurrencyAsync(u, tx, b.Currency, ct), basis = b.PeriodBasis?.ToUpperInvariant(), days = b.PeriodDays,
                min = b.MinFeeAmount, max = b.MaxFeeAmount, fixing = b.RateFixing?.ToUpperInvariant(), repricing = b.RepricingMonths, dayCount = b.DayCount?.ToUpperInvariant(),
                vat = b.VatExclusive ?? true, bench = b.BenchmarkReplacement?.ToUpperInvariant() ?? "NONE", benchText = b.ReplacementText, bank = b.BankMayChange?.ToUpperInvariant() ?? "NO",
                objDays = b.ObjectionDays, objKind = b.ObjectionDaysKind?.ToUpperInvariant(), trigger = b.TriggerEvent?.ToUpperInvariant(), from, retro = from < today,
                retroReason = from < today ? b.RetroactiveReason!.Trim() : null, r = d.Rev.RevisionNo, doc = src.Doc, page = src.Page, scan = src.Scan, orig = src.Original,
                nsr = src.Reason, conf = src.Confidence,
            }, tx, cancellationToken: ct));
        if (b.Tiers is { Length: > 0 })
        {
            var ruleId = await u.Connection.ExecuteScalarAsync<long>(new CommandDefinition("SELECT PricingRuleId FROM prc.PricingRule WHERE RootId = @r AND ToRevision IS NULL;",
                new { r = root }, tx, cancellationToken: ct));
            var sort = 0;
            foreach (var t in b.Tiers)
                await u.Connection.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT prc.PricingTier (TenantId, FacilityId, PricingRuleId, AmountFrom, AmountTo, PeriodFromDays, PeriodToDays, RatePct, MarginPct, FixedAmount, SortOrder, FromRevision, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @rule, @af, @at, @pf, @pt, @rate, @margin, @fixed, @sort, @r, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                    """, new
                    {
                        f = d.F.FacilityId, rule = ruleId, af = t.AmountFrom, at = t.AmountTo, pf = t.PeriodFromDays, pt = t.PeriodToDays, rate = t.RatePct, margin = t.MarginPct,
                        @fixed = t.FixedAmount, sort = ++sort, r = d.Rev.RevisionNo,
                    }, tx, cancellationToken: ct));
        }
        await LimitEndpoints.DoneAsync(u, tx, d, "PRICING_RULE_ADDED", new { method, state, feeType = b.FeeType, financingType = b.FinancingType, from = FacilityEndpoints.D(from) }, ct);
        await Outbox.EmitAsync(u.Connection, tx, "pricing.rule.changed", "fac.Facility", d.F.FacilityId, new { facility = d.F.PublicId }, ct);
        await tx.CommitAsync(ct);
        return Results.Created($"/api/v1/facilities/{id}/pricing-rules", new { id = refs.ItemRef(u.TenantId, "pricing-rule", root) });
    }

    /// <summary>A rule of the draft is voided; the version it had ended reopens.</summary>
    private static async Task<IResult> RemoveAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, Manage);
        await using var _u = u;
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        var d = await LimitEndpoints.DraftAsync(u, tx, id, scope, ct);
        var root = refs.ItemId(u.TenantId, "pricing-rule", reference) ?? throw ApiProblemException.NotFound();
        var rule = (await RulesAsync(u.Connection, tx, d.F.FacilityId, int.MaxValue, ct)).FirstOrDefault(r => r.RootId == root) ?? throw ApiProblemException.NotFound();
        await LimitEndpoints.DeleteDraftRowAsync(u, tx, "prc.PricingRule", "PricingRuleId", rule.PricingRuleId, ct);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE p SET EffectiveTo = NULL, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
              FROM prc.PricingRule AS p JOIN prc.PricingRule AS r ON r.PricingRuleId = @id
             WHERE p.FacilityId = r.FacilityId AND p.ToRevision IS NULL AND p.PricingRuleId <> r.PricingRuleId AND p.EffectiveTo = DATEADD(DAY, -1, r.EffectiveFrom)
               AND (p.FeeTypeId = r.FeeTypeId OR (p.FeeTypeId IS NULL AND r.FeeTypeId IS NULL)) AND (p.FinancingTypeId = r.FinancingTypeId OR (p.FinancingTypeId IS NULL AND r.FinancingTypeId IS NULL))
               AND (p.ScopeLimitId = r.ScopeLimitId OR (p.ScopeLimitId IS NULL AND r.ScopeLimitId IS NULL))
               AND (p.ScopeLimitProductLineId = r.ScopeLimitProductLineId OR (p.ScopeLimitProductLineId IS NULL AND r.ScopeLimitProductLineId IS NULL))
               AND (p.ScopeProductId = r.ScopeProductId OR (p.ScopeProductId IS NULL AND r.ScopeProductId IS NULL))
               AND (p.ScopeCompanyId = r.ScopeCompanyId OR (p.ScopeCompanyId IS NULL AND r.ScopeCompanyId IS NULL));
            """, new { id = rule.PricingRuleId }, tx, cancellationToken: ct));
        await LimitEndpoints.DoneAsync(u, tx, d, "PRICING_RULE_REMOVED", new { feeType = rule.FeeType, financingType = rule.FinancingType }, ct);
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    /// <summary>
    /// SVC-FAC-05: the price of a component on the approved revision of a facility for a line or limit, a company and a
    /// product, an amount and a number of days, on a date (and, for a rate fixed for the contract, the contract's date).
    /// The VAT line uses the borrower's VAT rate on that date (BR-PRC-009); a base value older than its rate's
    /// StaleAfterDays is a warning (FR-CAT-017).
    /// </summary>
    private static async Task<IResult> ResolveAsync(ResolveRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs, TimeProvider clock)
    {
        if (b.Facility is null || b.Amount is not >= 0 || (b.FeeType is null) == (b.FinancingType is null))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give the facility, the amount and the fee type or the financing type.");
        var (u, scope) = await FacilityEndpoints.OpenAsync(http, db, View);
        await using var _u = u;
        var ct = http.RequestAborted;
        var f = await FacilityEndpoints.FindAsync(u, null, b.Facility.Value, scope, ct);
        var asOf = LimitEndpoints.Date(b.AsOf, "date") ?? clock.GetUtcNow().UtcDateTime.Date;
        var contract = LimitEndpoints.Date(b.ContractDate, "contract date");
        var rows = await FacilityTreeStore.LoadAsync(u.Connection, null, f.FacilityId, f.ApprovedRevisionNo, ct);
        var lineRoot = refs.ItemId(u.TenantId, "line", b.Line);
        var limitRoot = refs.ItemId(u.TenantId, "limit", b.Limit) ?? rows.Lines.FirstOrDefault(l => l.RootId == lineRoot)?.LimitRootId;
        var path = new List<ChainNode>();
        if (lineRoot is { } lr) path.Add(new ChainNode("LINE", lr, "LINE"));
        if (limitRoot is { } root)
        {
            var byRoot = rows.Limits.ToDictionary(l => l.RootId);
            if (!byRoot.ContainsKey(root)) throw ApiProblemException.NotFound();
            for (long? r = root; r is { } x && byRoot.TryGetValue(x, out var l); r = l.ParentRootId) path.Add(new ChainNode("LIMIT", l.RootId, l.Code, l.PricingMode));
        }
        long? company = b.Company is null ? f.BorrowerCompanyId : (await CompanyEndpoints.FindAsync(u, null, b.Company.Value, scope, ct)).CompanyId;
        int? product = b.Product is not null
            ? await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT ProductId FROM cat.Product WHERE Code = @c;", new { c = b.Product.Trim().ToUpperInvariant() }, cancellationToken: ct))
            : rows.Lines.FirstOrDefault(l => l.RootId == lineRoot)?.ProductId;
        var specs = await SpecsAsync(u.Connection, null, f.FacilityId, f.ApprovedRevisionNo, ct);
        var values = (await u.Connection.QueryAsync<(int Rate, DateTime Date, decimal Value, int? Stale)>(new CommandDefinition(
            """
            SELECT v.BaseRateId, v.EffectiveDate, v.ValuePct, r.StaleAfterDays FROM cat.BaseRateValue AS v JOIN cat.BaseRate AS r ON r.BaseRateId = v.BaseRateId
             WHERE v.Status = 'VALID' AND v.BaseRateId IN @ids;
            """, new { ids = specs.Where(s => s.BaseRateId is not null).Select(s => s.BaseRateId!.Value).DefaultIfEmpty(-1).ToArray() }, cancellationToken: ct))).ToList();
        var stale = false;
        (decimal, DateTime)? Base(int rate, DateTime on)
        {
            var v = values.Where(x => x.Rate == rate && x.Date <= on).OrderByDescending(x => x.Date).FirstOrDefault();
            if (v.Date == default) return null;
            if (v.Stale is { } days && (on - v.Date).TotalDays > days) stale = true;
            return (v.Value, v.Date);
        }
        var vat = await u.Connection.ExecuteScalarAsync<decimal?>(new CommandDefinition(
            """
            SELECT TOP (1) RatePercent FROM org.CompanyTaxRate WHERE TaxCode = 'VAT' AND (CompanyId = @c OR CompanyId IS NULL) AND EffectiveFrom <= @d AND (EffectiveTo IS NULL OR EffectiveTo >= @d)
             ORDER BY CASE WHEN CompanyId IS NULL THEN 1 ELSE 0 END, EffectiveFrom DESC;
            """, new { c = company, d = asOf }, cancellationToken: ct));
        var result = PricingEngine.Resolve(path, specs, new PricingQuery(b.FeeType?.Trim().ToUpperInvariant(), b.FinancingType?.Trim().ToUpperInvariant(), company, product,
            b.Amount.Value, b.Days ?? 0, asOf, contract), Base, vat);
        var warnings = result.Warnings.ToList();
        if (stale) warnings.Add("FR-CAT-017-STALE-BASE");
        return Results.Ok(new
        {
            status = result.Status, reason = result.Reason, winner = result.WinnerRoot is { } w ? refs.ItemRef(u.TenantId, "pricing-rule", w) : null, node = result.WinnerNode,
            ratePct = result.RatePct, amount = result.Amount, vatAmount = result.VatAmount, rangeLowPct = result.RangeLowPct, rangeHighPct = result.RangeHighPct,
            notIncome = result.NotIncome, currency = f.CurrencyCode,
            losers = result.Losers.Select(l => new { rule = refs.ItemRef(u.TenantId, "pricing-rule", l.Root), node = l.Node, reason = l.Reason }), warnings,
        });
    }
}
