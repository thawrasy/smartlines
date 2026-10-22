using BankFas.Core.Collateral;

namespace BankFas.Core.Tests.Collateral;

public sealed class CollateralMathTests
{
    [Fact]
    public void BR_COL_002_note_ratio_and_renewal()
    {
        Assert.Equal(110m, CollateralMath.NoteRatioPct(44_000_000, 40_000_000));
        Assert.Equal(new DateTime(2027, 3, 1), CollateralMath.NextRenewalDue("ANNUAL", new DateTime(2025, 3, 1), new DateTime(2026, 3, 1)));
        Assert.Equal(new DateTime(2026, 3, 1), CollateralMath.NextRenewalDue("ANNUAL", new DateTime(2025, 3, 1), null));
        Assert.Null(CollateralMath.NextRenewalDue("NONE", new DateTime(2025, 3, 1), null));
    }

    [Fact]
    public void BR_COL_003_insurance_required_shortfall_and_expiry()
    {
        var full = CollateralMath.Insurance("FULL_LIMITS", null, null, 40_000_000, 40_000_000, 30_000_000, new DateTime(2026, 12, 15), new DateTime(2026, 10, 1));
        Assert.Equal((40_000_000m, 10_000_000m, 75m, false), (full.Required, full.Shortfall, full.CoveragePct, full.Expired));
        var pct = CollateralMath.Insurance("PCT_OF_LIMIT", 110, null, 40_000_000, 0, 50_000_000, new DateTime(2026, 12, 15), new DateTime(2026, 10, 1));
        Assert.Equal((44_000_000m, 0m), (pct.Required, pct.Shortfall));
        var expired = CollateralMath.Insurance("FIXED_AMOUNT", null, 20_000_000, 40_000_000, 0, 30_000_000, new DateTime(2026, 12, 15), new DateTime(2026, 12, 16));
        Assert.Equal((0m, 20_000_000m, 0m, true), (expired.SumInsured, expired.Shortfall, expired.CoveragePct, expired.Expired));
    }

    [Fact]
    public void BR_COL_004_three_valuers_in_the_first_year_then_one_a_year()
    {
        var reference = new DateTime(2026, 1, 1);
        ValuationPhase[] phases = [new(1, 1, 1, 3, 0, reference), new(2, 2, null, 1, 12, reference)];
        var dues = CollateralMath.Valuations(phases, reference, new DateTime(2028, 6, 30));
        Assert.Equal([(new DateTime(2026, 1, 1), 3), (new DateTime(2027, 1, 1), 1), (new DateTime(2028, 1, 1), 1)], dues.Select(d => (d.Date, d.Valuers)));
        Assert.False(CollateralMath.PhasesOverlap(phases));
        Assert.True(CollateralMath.PhasesOverlap([new(1, 1, 2, 3, 0, reference), new(2, 2, null, 1, 12, reference)]));
        Assert.True(CollateralMath.PhasesOverlap([new(1, 1, null, 3, 0, reference), new(2, 2, null, 1, 12, reference)]));
    }
}
