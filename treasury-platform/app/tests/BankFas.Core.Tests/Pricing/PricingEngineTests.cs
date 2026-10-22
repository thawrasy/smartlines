using BankFas.Core.Pricing;

namespace BankFas.Core.Tests.Pricing;

public sealed class PricingEngineTests
{
    private static readonly DateTime Start = new(2026, 1, 1);

    // Issuance: 0.25% for each 90 days or part, at least 500 (AC-FAC-4).
    private static readonly TariffItemSpec Issuance = new(1, "ISS", "PERCENT", 0.25m, null, null, "PER_PERIOD_OR_PART", 90, 500, null, "BAND", "EXCLUSIVE", []);

    private static RuleSpec AddOn(long root, long? limit, decimal addOn, long? company = null, DateTime? from = null, DateTime? to = null) =>
        new(root, limit, null, null, company, "FEE", "SET", "ISSUANCE", null, "TARIFF_PLUS_ADDON", Issuance, addOn, null, null, null, null, null, null, null, null, null, null,
            null, null, null, null, true, from ?? Start, to);

    private static readonly IReadOnlyList<ChainNode> L1 = [new("LIMIT", 1, "L1", "OWN")];
    private static readonly IReadOnlyList<ChainNode> L2 = [new("LIMIT", 2, "L2")];
    private static readonly IReadOnlyList<ChainNode> L3 = [new("LIMIT", 3, "L3", "OWN")];

    private static (decimal Value, DateTime Date)? NoBase(int id, DateTime on) => null;

    private static PricingQuery Lc(long company, decimal amount = 2_000_000, int days = 90, DateTime? on = null) => new("ISSUANCE", null, company, null, amount, days, on ?? new DateTime(2026, 5, 1));

    [Fact]
    public void AC_FAC_4_the_most_specific_rule_wins()
    {
        // R0 on the facility (+1.00); L1 OWN with R1 (+0.75) and R2 for company B (+0.50); L2 INHERIT; L3 OWN without rules.
        RuleSpec[] rules = [AddOn(10, null, 1.00m), AddOn(11, 1, 0.75m), AddOn(12, 1, 0.50m, company: 200)];
        var a1 = PricingEngine.Resolve(L1, rules, Lc(100), NoBase, 15);
        Assert.Equal((11L, 1.00m, 20_000m, 3_000m), (a1.WinnerRoot!.Value, a1.RatePct!.Value, a1.Amount!.Value, a1.VatAmount!.Value));
        Assert.Contains(a1.Losers, l => l.Root == 10 && l.Reason == "OUT_OF_CHAIN");
        Assert.Contains(a1.Losers, l => l.Root == 12 && l.Reason == "OTHER_COMPANY");
        var b1 = PricingEngine.Resolve(L1, rules, Lc(200), NoBase, 15);
        Assert.Equal((12L, 0.75m, 15_000m), (b1.WinnerRoot!.Value, b1.RatePct!.Value, b1.Amount!.Value));
        Assert.Contains(b1.Losers, l => l.Root == 11 && l.Reason == "LOWER_RANK");
        var a2 = PricingEngine.Resolve(L2, rules, Lc(100), NoBase, 15);
        Assert.Equal((10L, 1.25m, 25_000m), (a2.WinnerRoot!.Value, a2.RatePct!.Value, a2.Amount!.Value));
        Assert.Equal(40_000m, PricingEngine.Resolve(L1, rules, Lc(100, days: 91), NoBase, 15).Amount);
        Assert.Equal(500m, PricingEngine.Resolve(L2, rules, Lc(100, amount: 30_000), NoBase, 15).Amount);
        Assert.Equal("NO_RULE", PricingEngine.Resolve(L3, rules, Lc(100), NoBase, 15).Status);

        // A new version of R1 (+0.90) from 2026-07-01 closes the old one on 2026-06-30.
        RuleSpec[] versions = [AddOn(10, null, 1.00m), AddOn(11, 1, 0.75m, to: new DateTime(2026, 6, 30)), AddOn(13, 1, 0.90m, from: new DateTime(2026, 7, 1))];
        Assert.Equal(1.00m, PricingEngine.Resolve(L1, versions, Lc(100, on: new DateTime(2026, 6, 30)), NoBase, 15).RatePct);
        var later = PricingEngine.Resolve(L1, versions, Lc(100, on: new DateTime(2026, 7, 1)), NoBase, 15);
        Assert.Equal((1.15m, 23_000m), (later.RatePct!.Value, later.Amount!.Value));
    }

    private static RuleSpec Murabaha(decimal? floor = 0) => new(20, null, null, null, null, "FINANCING_RETURN", "SET", null, "MURABAHA", "BASE_PLUS_MARGIN", null, null, 7, 1.75m,
        floor, null, null, null, null, null, "PER_ANNUM", null, null, null, "FIXED_FOR_CONTRACT", "ACT_360", false, Start, null);

    [Fact]
    public void AC_FAC_5_base_rate_fixing_floor_and_penalty()
    {
        (decimal, DateTime)? Saibor(int id, DateTime on) =>
            on >= new DateTime(2026, 4, 1) ? (5.55m, new DateTime(2026, 4, 1)) : on >= new DateTime(2026, 1, 1) ? (5.40m, new DateTime(2026, 1, 1)) : null;
        PricingQuery Q(DateTime contract) => new(null, "MURABAHA", 1, null, 1_000_000, 180, new DateTime(2026, 6, 1), contract);
        var march = PricingEngine.Resolve(L2, [Murabaha()], Q(new DateTime(2026, 3, 15)), Saibor, null);
        Assert.Equal((7.15m, 35_750.00m), (march.RatePct!.Value, march.Amount!.Value));
        var april = PricingEngine.Resolve(L2, [Murabaha()], Q(new DateTime(2026, 4, 15)), Saibor, null);
        Assert.Equal((7.30m, 36_500.00m), (april.RatePct!.Value, april.Amount!.Value));
        var before = PricingEngine.Resolve(L2, [Murabaha()], Q(new DateTime(2025, 12, 31)), Saibor, null);
        Assert.Equal(("INCOMPLETE", "NO_BASE_VALUE"), (before.Status, before.Reason));
        var negative = PricingEngine.Resolve(L2, [Murabaha()], Q(new DateTime(2026, 3, 15)), (_, _) => (-0.10m, Start), null);
        Assert.Equal((1.75m, 8_750.00m), (negative.RatePct!.Value, negative.Amount!.Value));

        var penalty = new RuleSpec(30, null, null, null, null, "PENALTY_NON_INCOME", "SET", "LATE_PENALTY", null, "PERCENT_OF_AMOUNT", null, null, null, null, null, 16m, null, null,
            null, null, "PER_ANNUM", null, null, null, null, "ACT_360", true, Start, null);
        var late = PricingEngine.Resolve(L2, [penalty], new PricingQuery("LATE_PENALTY", null, 1, null, 500_000, 20, new DateTime(2026, 6, 1)), NoBase, 15);
        Assert.Equal((4_444.44m, true, (decimal?)null), (late.Amount!.Value, late.NotIncome, late.VatAmount));
    }

    [Fact]
    public void AC_FAC_10_a_rate_not_specified_is_incomplete_never_zero()
    {
        var blank = new RuleSpec(40, null, null, null, null, "FEE", "NOT_SPECIFIED_IN_AGREEMENT", "ARRANGEMENT", null, "PERCENT_OF_AMOUNT", null, null, null, null, null, null, null,
            null, null, null, "FLAT", null, null, null, null, null, true, Start, new DateTime(2026, 8, 31));
        var q = new PricingQuery("ARRANGEMENT", null, 1, null, 10_000_000, 365, new DateTime(2026, 5, 1));
        var r = PricingEngine.Resolve(L2, [blank], q, NoBase, 15);
        Assert.Equal(("INCOMPLETE", "RATE_NOT_SPECIFIED", (decimal?)null), (r.Status, r.Reason, r.Amount));
        Assert.Contains(r.Losers, l => l.Root == 40 && l.Reason == "RATE_NOT_SPECIFIED");
        var set = blank with { Root = 41, RateState = "SET", RatePct = 0.50m, EffectiveFrom = new DateTime(2026, 9, 1), EffectiveTo = null };
        Assert.Equal(50_000m, PricingEngine.Resolve(L2, [blank, set], q with { AsOf = new DateTime(2026, 9, 1) }, NoBase, null).Amount);
    }

    [Fact]
    public void BR_PRC_002_and_005_periods_tiers_and_per_million()
    {
        // 0.25% for the first 90 days, then 0.125% for each later period or part, on 2,000,000 for 200 days: 0.50% = 10,000.
        var tiered = new TariffItemSpec(2, "T", "TIERED", null, null, null, "PER_PERIOD_OR_PART", 90, null, null, "BAND", "EXCLUSIVE",
            [new(null, null, 0, 90, 0.25m, null), new(null, null, 90, 180, 0.125m, null)]);
        Assert.Equal((0.50m, 10_000m), PricingEngine.ItemFee(tiered, 2_000_000, 200, 0) is var (rate, fee) ? (rate!.Value, PricingEngine.Round(fee)) : default);
        var perMillion = new TariffItemSpec(3, "M", "PER_MILLION", null, null, 200, "FLAT", null, null, null, "BAND", "EXCLUSIVE", []);
        Assert.Equal(700m, PricingEngine.ItemFee(perMillion, 3_500_000, 30, 0).Fee);
        var bands = new TariffItemSpec(4, "B", "TIERED", null, null, null, "FLAT", null, null, null, "BAND", "EXCLUSIVE",
            [new(0, 1_000_000, null, null, 1m, null), new(1_000_000, null, null, null, 0.5m, null)]);
        Assert.Equal(15_000m, PricingEngine.ItemFee(bands, 2_000_000, 1, 0).Fee);
        Assert.Equal(10_000m, PricingEngine.ItemFee(bands with { TierCalcMode = "WHOLE" }, 2_000_000, 1, 0).Fee);
        var fixedItem = new TariffItemSpec(5, "F", "FIXED", null, 250, null, "FLAT", null, null, null, "BAND", "EXCLUSIVE", []);
        Assert.Throws<InvalidOperationException>(() => PricingEngine.ItemFee(fixedItem, 1, 1, 0.5m));
    }
}
