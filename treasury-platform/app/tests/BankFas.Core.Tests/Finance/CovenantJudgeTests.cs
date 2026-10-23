using BankFas.Core.Finance;

namespace BankFas.Core.Tests.Finance;

public sealed class CovenantJudgeTests
{
    [Fact]
    public void BR_FIN_007_a_flow_of_18_7M_against_20M_is_a_breach_with_1_3M_remaining()
    {
        var j = CovenantJudge.Judge(18_700_000, 20_000_000, "GE", 10);
        Assert.Equal(("BREACH", -1_300_000m, -6.5m), (j.Result, j.Headroom, j.HeadroomPct));
    }

    [Fact]
    public void BR_FIN_011_1_1996_against_1_20_is_a_breach_shown_as_1_1996()
    {
        var j = CovenantJudge.Judge(1.19964m, 1.20m, "GE", 10);
        Assert.Equal("BREACH", j.Result);
        Assert.Equal(1.19964m, CovenantJudge.Stored(1.19964m));
        Assert.Equal("BREACH", CovenantJudge.Judge(1.1999999m, 1.2m, "GE", 10).Result);
    }

    [Fact]
    public void BR_FIN_005_each_month_against_the_period_average()
    {
        decimal[] months = [620_000, 480_000, 700_000];
        var each = CovenantJudge.Judge(CovenantJudge.Aggregate(months, "EACH_MONTH_MIN"), 500_000, "GE", 10);
        Assert.Equal(("BREACH", -20_000m, -4m), (each.Result, each.Headroom, each.HeadroomPct));
        var avg = CovenantJudge.Judge(CovenantJudge.Aggregate(months, "PERIOD_AVERAGE"), 500_000, "GE", 10);
        Assert.Equal(("COMPLIANT", 100_000m, 20m), (avg.Result, avg.Headroom, avg.HeadroomPct));
        Assert.Equal(700_000m, CovenantJudge.Aggregate(months, "POINT_IN_TIME"));
        Assert.Equal(1_800_000m, CovenantJudge.Aggregate(months, "PERIOD_SUM"));
    }

    [Fact]
    public void BR_OBL_007_early_warning_strict_operators_and_no_threshold()
    {
        // 15.9% against 15%: a margin of 0.9 points is 6% of the threshold, within a 10% early warning (BR-FIN-008).
        var share = CovenantJudge.Judge(15.9m, 15m, "GE", 10);
        Assert.Equal("WARNING", share.Result);
        Assert.Equal(6m, Math.Round(share.HeadroomPct!.Value, 6));
        Assert.Equal("BREACH", CovenantJudge.Judge(2.5m, 2.5m, "LT", 10).Result);
        Assert.Equal("WARNING", CovenantJudge.Judge(2.5m, 2.5m, "LE", 10).Result);
        Assert.Equal("COMPLIANT", CovenantJudge.Judge(1.0m, 2.5m, "LE", 10).Result);
        Assert.Equal(("COMPLIANT", null), (CovenantJudge.Judge(5, 0, "GE", 10).Result, CovenantJudge.Judge(5, 0, "GE", 10).HeadroomPct));
        Assert.Equal("NOT_ASSESSED_NO_THRESHOLD", CovenantJudge.Judge(5, null, null, 10).Result);
    }
}
