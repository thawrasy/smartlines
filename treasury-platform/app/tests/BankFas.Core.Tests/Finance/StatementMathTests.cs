using BankFas.Core.Finance;

namespace BankFas.Core.Tests.Finance;

/// <summary>BR-FIN-001 and BR-FIN-002: totals, the balance, the unit scale, and what a submission stores.</summary>
public sealed class StatementMathTests
{
    private static readonly LineDef[] Lines =
    [
        new("CASH", "BS_ASSET", "LINE", true, null, 10),
        new("CASH_RESTRICTED", "BS_ASSET", "OF_WHICH", false, null, 20, "CASH"),
        new("AR", "BS_ASSET", "LINE", true, null, 30),
        new("OTHER_CA", "BS_ASSET", "LINE", false, null, 40),
        new("TOTAL_CA", "BS_ASSET", "TOTAL", true, "CASH + AR + OTHER_CA", 50),
        new("PPE", "BS_ASSET", "LINE", false, null, 60),
        new("TOTAL_ASSETS", "BS_ASSET", "TOTAL", true, "TOTAL_CA + PPE", 70),
        new("ST_LOANS", "BS_LIABILITY", "LINE", false, null, 80),
        new("TOTAL_LIABS", "BS_LIABILITY", "TOTAL", true, "ST_LOANS", 90),
        new("SHARE_CAPITAL", "BS_EQUITY", "LINE", true, null, 100),
        new("TREASURY_SHARES", "BS_EQUITY", "LINE", false, null, 105),
        new("TOTAL_EQUITY", "BS_EQUITY", "TOTAL", true, "SHARE_CAPITAL - TREASURY_SHARES", 110),
        new("LC_OUTSTANDING", "MEMO", "MEMO", false, null, 120),
    ];

    private static Dictionary<string, decimal?> Stored(params (string Code, decimal? Amount)[] v) => v.ToDictionary(x => x.Code, x => x.Amount, StringComparer.Ordinal);

    [Fact]
    public void Twelve_thousand_in_thousands_is_twelve_million()   // BR-FIN-002
    {
        Assert.Equal(12_000_000m, StatementMath.Scale(12_000m, 1000));
    }

    [Fact]
    public void Totals_come_from_their_components_and_the_balance_holds_within_one_unit()   // BR-FIN-001
    {
        var s = Stored(("CASH", 2_000_000m), ("AR", 3_000_000m), ("PPE", 5_000_000m), ("ST_LOANS", 4_000_000m), ("SHARE_CAPITAL", 6_500_000m), ("TREASURY_SHARES", 500_000m),
            ("TOTAL_CA", 5_000_000m));
        var c = StatementMath.Check(Lines, s, 1000);
        Assert.Equal(10_000_000m, c.Totals.Single(t => t.Code == "TOTAL_ASSETS").Computed);
        Assert.Equal(6_000_000m, c.Totals.Single(t => t.Code == "TOTAL_EQUITY").Computed);
        Assert.Equal((0m, true), (c.Totals.Single(t => t.Code == "TOTAL_CA").Variance!.Value, c.Totals.Single(t => t.Code == "TOTAL_CA").Matches));
        Assert.Equal((0m, true), (c.BalanceDifference!.Value, c.Balanced));
        Assert.True(c.CanSubmit);
    }

    [Fact]
    public void An_entered_total_off_by_more_than_one_unit_and_an_imbalance_are_flagged()
    {
        var s = Stored(("CASH", 2_000_000m), ("AR", 3_000_000m), ("ST_LOANS", 4_000_000m), ("SHARE_CAPITAL", 2_000_000m), ("TOTAL_CA", 5_002_000m));
        var c = StatementMath.Check(Lines, s, 1000);
        var ca = c.Totals.Single(t => t.Code == "TOTAL_CA");
        Assert.Equal((2_000m, false), (ca.Variance!.Value, ca.Matches));
        // TOTAL_ASSETS is computed from its components (5,000,000), not from the entered TOTAL_CA: 5,000,000 against 6,000,000.
        Assert.Equal((-1_000_000m, false), (c.BalanceDifference!.Value, c.Balanced));
    }

    [Fact]
    public void A_required_line_left_empty_refuses_the_submission()   // V-FIN-01
    {
        var c = StatementMath.Check(Lines, Stored(("CASH", 1m), ("SHARE_CAPITAL", 1m)), 1);
        Assert.Equal(["AR"], c.MissingRequired);
        Assert.False(c.CanSubmit);
    }

    [Fact]
    public void A_submission_stores_an_explicit_zero_for_optional_lines_and_nothing_for_details()   // BR-FIN-002
    {
        var stored = StatementMath.ForSubmission(Lines, Stored(("CASH", 2m), ("AR", 3m), ("SHARE_CAPITAL", 5m))).ToDictionary(l => l.Code);
        Assert.Equal(0m, stored["OTHER_CA"].EnteredAmount);
        Assert.Equal(0m, stored["PPE"].EnteredAmount);
        Assert.False(stored.ContainsKey("CASH_RESTRICTED"));
        Assert.False(stored.ContainsKey("LC_OUTSTANDING"));
        Assert.Equal((null, 5m), (stored["TOTAL_CA"].EnteredAmount, stored["TOTAL_CA"].ComputedAmount));
        Assert.Equal(5m, stored["TOTAL_ASSETS"].ComputedAmount);
    }

    [Fact]
    public void The_grid_shows_the_51_lines_of_the_specification_first()   // owner default OQ-1 of S2-b
    {
        Assert.Equal(51, LineCatalog.SpecLines.Count);
    }
}
