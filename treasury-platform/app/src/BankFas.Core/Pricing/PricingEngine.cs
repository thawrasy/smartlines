namespace BankFas.Core.Pricing;

/// <summary>A tier of a tariff item or a pricing rule: an amount band or a period band, with a rate, a margin or a fixed amount.</summary>
public sealed record Tier(decimal? AmountFrom, decimal? AmountTo, int? PeriodFromDays, int? PeriodToDays, decimal? RatePct, decimal? FixedAmount, decimal? MarginPct = null);

/// <summary>An item of an approved tariff schedule (FR-PRC-002, 003).</summary>
public sealed record TariffItemSpec(long Id, string Code, string ChargeKind, decimal? RatePct, decimal? FixedAmount, decimal? PerMillionAmount, string PeriodBasis, int? PeriodDays,
    decimal? MinAmount, decimal? MaxAmount, string TierCalcMode, string VatTreatment, IReadOnlyList<Tier> Tiers, string? DayCount = null, bool Approved = true);

/// <summary>
/// A pricing rule of a facility (prc.PricingRule): its scope (a line, a limit, the facility; a product; a company), the
/// component it prices (a fee type or a financing type), its method and values, and the dates it is in effect.
/// </summary>
public sealed record RuleSpec(long Root, long? ScopeLimitRoot, long? ScopeLineRoot, int? ScopeProductId, long? ScopeCompanyId, string ComponentKind, string RateState,
    string? FeeType, string? FinancingType, string Method, TariffItemSpec? TariffItem, decimal? AddOnPct, int? BaseRateId, decimal? MarginPct, decimal? BaseFloorPct,
    decimal? RatePct, decimal? RangeLowPct, decimal? RangeHighPct, decimal? FixedAmount, decimal? PerMillionAmount, string? PeriodBasis, int? PeriodDays,
    decimal? MinFeeAmount, decimal? MaxFeeAmount, string? RateFixing, string? DayCount, bool VatExclusive, DateTime EffectiveFrom, DateTime? EffectiveTo,
    IReadOnlyList<Tier>? Tiers = null);

/// <summary>A node of the pricing chain: a line, or a limit and its PricingMode (INHERIT or OWN).</summary>
public sealed record ChainNode(string Kind, long Root, string Label, string PricingMode = "INHERIT");

/// <summary>What is priced (SVC-FAC-05): the component, the company and product, the amount, the days and the dates.</summary>
public sealed record PricingQuery(string? FeeType, string? FinancingType, long? CompanyId, int? ProductId, decimal Amount, int Days, DateTime AsOf, DateTime? ContractDate = null);

public sealed record RuleOutcome(long Root, string Node, string Reason);

/// <summary>
/// The answer of ResolvePricing (BR-PRC-010): the winning rule and its value (rate, amount, the VAT line), or a status
/// that says why there is none (NO_RULE, INCOMPLETE with its reason, RANGE), with the rules set aside and why.
/// </summary>
public sealed record PricingResult(string Status, string? Reason, long? WinnerRoot, string? WinnerNode, decimal? RatePct, decimal? Amount, decimal? VatAmount,
    decimal? RangeLowPct, decimal? RangeHighPct, bool NotIncome, IReadOnlyList<RuleOutcome> Losers, IReadOnlyList<string> Warnings);

/// <summary>
/// The pricing of the platform (BR-PRC-001 to 012). The resolver walks the chain from the line to its limit and up
/// while the limit INHERITs, then to the facility; a limit that OWNs its pricing stops the walk, and with no rule there
/// the answer is NO_RULE (no silent climb). The candidates are the rules in effect on the date whose every scope field
/// matches; they rank by the nearest node, then the company-specific, then the product-specific, then the latest
/// start. A winner NOT_SPECIFIED_IN_AGREEMENT is INCOMPLETE (RATE_NOT_SPECIFIED), never zero. Amounts are rounded half up
/// to two decimals; the minimum and the maximum bound the sum of the item and its add-on; VAT is a line of its own.
/// </summary>
public static class PricingEngine
{
    public static decimal Round(decimal x) => Math.Round(x, 2, MidpointRounding.AwayFromZero);

    private static decimal Basis(string? dayCount) => dayCount == "ACT_365" ? 365m : 360m;

    /// <summary>The period factor of BR-PRC-002: FLAT 1, PER_ANNUM days over the basis, PER_PERIOD_OR_PART the started periods.</summary>
    public static decimal Factor(string? basis, int? periodDays, int days, string? dayCount) => basis switch
    {
        "PER_ANNUM" => days / Basis(dayCount),
        "PER_PERIOD_OR_PART" when periodDays is > 0 => Math.Max(1, (int)Math.Ceiling(days / (decimal)periodDays.Value)),
        _ => 1m,
    };

    public static PricingResult Resolve(IReadOnlyList<ChainNode> path, IReadOnlyList<RuleSpec> rules, PricingQuery q, Func<int, DateTime, (decimal Value, DateTime Date)?> baseValue,
        decimal? vatPct)
    {
        // (1) The chain: the path is from the line or limit upwards; an OWN limit ends it, else the facility closes it.
        var chain = new List<ChainNode>();
        foreach (var n in path)
        {
            chain.Add(n);
            if (n.Kind == "LIMIT" && n.PricingMode == "OWN") break;
        }
        if (chain.Count == path.Count && chain.LastOrDefault()?.PricingMode != "OWN") chain.Add(new ChainNode("FACILITY", 0, "FACILITY"));
        int? Distance(RuleSpec r)
        {
            var (kind, root) = r.ScopeLineRoot is { } l ? ("LINE", l) : r.ScopeLimitRoot is { } m ? ("LIMIT", m) : ("FACILITY", 0L);
            var i = chain.FindIndex(n => n.Kind == kind && n.Root == root);
            return i < 0 ? null : i;
        }
        string NodeOf(RuleSpec r) => Distance(r) is { } i ? chain[i].Label : r.ScopeLineRoot is not null ? "LINE" : r.ScopeLimitRoot is not null ? "LIMIT" : "FACILITY";

        var losers = new List<RuleOutcome>();
        var candidates = new List<(RuleSpec Rule, int Distance)>();
        foreach (var r in rules.Where(r => q.FeeType is not null ? r.FeeType == q.FeeType : r.FinancingType == q.FinancingType))
        {
            if (r.EffectiveFrom > q.AsOf || r.EffectiveTo < q.AsOf) { losers.Add(new(r.Root, NodeOf(r), "NOT_IN_EFFECT")); continue; }
            if (Distance(r) is not { } d) { losers.Add(new(r.Root, NodeOf(r), "OUT_OF_CHAIN")); continue; }
            if (r.ScopeCompanyId is { } c && c != q.CompanyId) { losers.Add(new(r.Root, NodeOf(r), "OTHER_COMPANY")); continue; }
            if (r.ScopeProductId is { } p && p != q.ProductId) { losers.Add(new(r.Root, NodeOf(r), "OTHER_PRODUCT")); continue; }
            candidates.Add((r, d));
        }
        // (3) The ranking.
        var ranked = candidates.OrderBy(x => x.Distance).ThenBy(x => x.Rule.ScopeCompanyId is null ? 1 : 0).ThenBy(x => x.Rule.ScopeProductId is null ? 1 : 0)
            .ThenByDescending(x => x.Rule.EffectiveFrom).ToList();
        if (ranked.Count == 0) return new PricingResult("NO_RULE", "NO_RULE", null, null, null, null, null, null, null, false, losers, []);
        var win = ranked[0].Rule;
        losers.AddRange(ranked.Skip(1).Select(x => new RuleOutcome(x.Rule.Root, NodeOf(x.Rule), "LOWER_RANK")));
        var notIncome = win.ComponentKind == "PENALTY_NON_INCOME";
        if (win.RateState == "NOT_SPECIFIED_IN_AGREEMENT")
        {
            losers.Add(new(win.Root, NodeOf(win), "RATE_NOT_SPECIFIED"));
            return new PricingResult("INCOMPLETE", "RATE_NOT_SPECIFIED", win.Root, NodeOf(win), null, null, null, null, null, notIncome, losers, []);
        }
        var warnings = new List<string>();
        var (status, reason, rate, amount, low, high) = Evaluate(win, q, baseValue, warnings);
        decimal? vat = null;
        if (amount is { } a && !notIncome && win.ComponentKind == "FEE" && win.VatExclusive && (win.TariffItem?.VatTreatment ?? "EXCLUSIVE") == "EXCLUSIVE" && vatPct is { } v)
            vat = Round(a * v / 100m);
        return new PricingResult(status, reason, win.Root, NodeOf(win), rate, amount, vat, low, high, notIncome, losers, warnings);
    }

    private static (string Status, string? Reason, decimal? Rate, decimal? Amount, decimal? Low, decimal? High) Evaluate(RuleSpec r, PricingQuery q,
        Func<int, DateTime, (decimal Value, DateTime Date)?> baseValue, List<string> warnings)
    {
        decimal Bound(decimal fee, decimal? min, decimal? max) => Round(Math.Min(Math.Max(fee, min ?? 0), max ?? decimal.MaxValue));
        switch (r.Method)
        {
            case "TARIFF_AS_IS" or "TARIFF_PLUS_ADDON":
                {
                    var item = r.TariffItem!;
                    if (!item.Approved) warnings.Add("V-PRC-02-TARIFF-NOT-APPROVED");
                    var addOn = r.Method == "TARIFF_PLUS_ADDON" ? r.AddOnPct ?? 0 : 0;
                    var (rate, fee) = ItemFee(item, q.Amount, q.Days, addOn);
                    return ("PRICED", null, rate, Bound(fee, r.MinFeeAmount ?? item.MinAmount, r.MaxFeeAmount ?? item.MaxAmount), null, null);
                }
            case "PERCENT_OF_AMOUNT":
                if (r.RatePct is null) return ("RANGE", "RANGE", null, null, r.RangeLowPct, r.RangeHighPct);
                return ("PRICED", null, r.RatePct, Bound(r.RatePct.Value / 100m * q.Amount * Factor(r.PeriodBasis, r.PeriodDays, q.Days, r.DayCount), r.MinFeeAmount, r.MaxFeeAmount), null, null);
            case "FIXED_AMOUNT":
                return ("PRICED", null, null, Bound(r.FixedAmount!.Value, r.MinFeeAmount, r.MaxFeeAmount), null, null);
            case "PER_MILLION":
                return ("PRICED", null, null, Bound(q.Amount / 1_000_000m * r.PerMillionAmount!.Value, r.MinFeeAmount, r.MaxFeeAmount), null, null);
            case "BASE_PLUS_MARGIN":
                {
                    // BR-PRC-006: the base on the contract date when fixed for the contract, else on the date priced; never a later value.
                    var on = r.RateFixing == "FIXED_FOR_CONTRACT" ? q.ContractDate ?? q.AsOf : q.AsOf;
                    if (baseValue(r.BaseRateId!.Value, on) is not { } b) return ("INCOMPLETE", "NO_BASE_VALUE", null, null, null, null);
                    if (r.MarginPct < 0) warnings.Add("V-PRC-02-NEGATIVE-MARGIN");
                    var rate = (r.BaseFloorPct is { } floor ? Math.Max(b.Value, floor) : b.Value) + (r.MarginPct ?? 0);
                    var amount = Round(q.Amount * rate / 100m * q.Days / Basis(r.DayCount));
                    return ("PRICED", null, rate, Bound(amount, r.MinFeeAmount, r.MaxFeeAmount), null, null);
                }
            case "TIERED":
                {
                    var item = new TariffItemSpec(0, "", "TIERED", null, null, null, r.PeriodBasis ?? "FLAT", r.PeriodDays, r.MinFeeAmount, r.MaxFeeAmount, "BAND", "EXCLUSIVE",
                        r.Tiers ?? [], r.DayCount);
                    var (rate, fee) = ItemFee(item, q.Amount, q.Days, 0);
                    return ("PRICED", null, rate, Bound(fee, r.MinFeeAmount, r.MaxFeeAmount), null, null);
                }
            default:
                return ("INCOMPLETE", "UNKNOWN_METHOD", null, null, null, null);
        }
    }

    /// <summary>
    /// The fee of a tariff item (BR-PRC-002, 004, 005): a percent with its add-on in points over the item's period basis,
    /// a fixed amount, an amount per million (pro rata), or tiers: amount bands (BAND on each part, WHOLE at the band of
    /// the whole amount) or period bands (the first period at its rate, the later ones at theirs).
    /// </summary>
    public static (decimal? Rate, decimal Fee) ItemFee(TariffItemSpec item, decimal amount, int days, decimal addOn)
    {
        switch (item.ChargeKind)
        {
            case "PERCENT":
                {
                    var rate = (item.RatePct ?? 0) + addOn;
                    return (rate, rate / 100m * amount * Factor(item.PeriodBasis, item.PeriodDays, days, item.DayCount));
                }
            case "FIXED":
                if (addOn != 0) throw new InvalidOperationException("An add-on is not allowed on a fixed-amount item (BR-PRC-004).");
                return (null, item.FixedAmount ?? 0);
            case "PER_MILLION":
                return (null, amount / 1_000_000m * (item.PerMillionAmount ?? 0));
            default:
                {
                    var byPeriod = item.Tiers.Where(t => t.PeriodFromDays is not null).OrderBy(t => t.PeriodFromDays).ToList();
                    if (byPeriod.Count > 0)
                    {
                        // The first tier's period at its rate, then each later period (or part) at the rate of the tier it falls in.
                        var first = byPeriod[0];
                        var periodLen = Math.Max(1, (first.PeriodToDays ?? days) - (first.PeriodFromDays ?? 0));
                        decimal pct = 0;
                        var periods = Math.Max(1, (int)Math.Ceiling(days / (decimal)periodLen));
                        for (var p = 0; p < periods; p++)
                        {
                            var startDay = p * periodLen;
                            var t = byPeriod.LastOrDefault(x => (x.PeriodFromDays ?? 0) <= startDay) ?? first;
                            pct += t.RatePct ?? 0;
                        }
                        return (pct + addOn * periods, (pct + addOn * periods) / 100m * amount);
                    }
                    var bands = item.Tiers.OrderBy(t => t.AmountFrom ?? 0).ToList();
                    if (item.TierCalcMode == "WHOLE")
                    {
                        var band = bands.LastOrDefault(t => (t.AmountFrom ?? 0) <= amount) ?? bands.FirstOrDefault();
                        if (band is null) return (null, 0);
                        return band.FixedAmount is { } fx ? (null, fx) : ((band.RatePct ?? 0) + addOn, ((band.RatePct ?? 0) + addOn) / 100m * amount);
                    }
                    decimal fee = 0;
                    foreach (var t in bands)
                    {
                        var from = t.AmountFrom ?? 0;
                        if (amount <= from) break;
                        var part = Math.Min(amount, t.AmountTo ?? decimal.MaxValue) - from;
                        fee += t.FixedAmount ?? ((t.RatePct ?? 0) + addOn) / 100m * part;
                    }
                    return (null, fee);
                }
        }
    }
}
