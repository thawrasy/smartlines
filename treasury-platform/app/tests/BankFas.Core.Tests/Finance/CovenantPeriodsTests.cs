using BankFas.Core.Finance;

namespace BankFas.Core.Tests.Finance;

public sealed class CovenantPeriodsTests
{
    private static string[] Ends(DateTime from, DateTime to, string frequency, int fye) =>
        [.. CovenantPeriods.PeriodEnds(from, to, frequency, fye).Select(d => d.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture))];

    [Fact]
    public void Quarterly_with_a_December_year_end_tests_the_four_quarter_ends()
    {
        Assert.Equal(["2026-03-31", "2026-06-30", "2026-09-30", "2026-12-31"], Ends(new DateTime(2026, 1, 1), new DateTime(2026, 12, 31), "QUARTERLY", 12));
        Assert.Equal(new DateTime(2026, 1, 1), CovenantPeriods.PeriodStart(new DateTime(2026, 3, 31), "QUARTERLY"));
    }

    [Fact]
    public void Periods_follow_the_fiscal_year_end_of_the_tested_company()
    {
        Assert.Equal(["2026-09-30", "2026-12-31", "2027-03-31", "2027-06-30"], Ends(new DateTime(2026, 7, 15), new DateTime(2027, 6, 30), "QUARTERLY", 6));
        Assert.Equal(["2026-06-30", "2027-06-30"], Ends(new DateTime(2026, 1, 1), new DateTime(2027, 12, 31), "ANNUAL", 6));
        Assert.Equal(["2026-06-30", "2026-12-31"], Ends(new DateTime(2026, 2, 1), new DateTime(2026, 12, 31), "SEMIANNUAL", 12));
        Assert.Equal(new DateTime(2026, 1, 31), CovenantPeriods.FirstPeriodEnd(new DateTime(2026, 1, 31), "MONTHLY", 12));
        Assert.Equal(new DateTime(2025, 4, 1), CovenantPeriods.PeriodStart(new DateTime(2026, 3, 31), "ROLLING_12M"));
    }
}
