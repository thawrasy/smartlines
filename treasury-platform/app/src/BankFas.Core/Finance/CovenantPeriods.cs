namespace BankFas.Core.Finance;

/// <summary>
/// The test periods of a covenant (FR-OBL-011, BR-OBL-005): counted from the tested company's fiscal year end month,
/// QUARTERLY at the fiscal year end plus 3, 6, 9 and 12 months, SEMIANNUAL plus 6 and 12, ANNUAL at the year end,
/// MONTHLY and ROLLING_12M (twelve months to the month) every month end. A period starts the day after the previous
/// end (ROLLING_12M twelve months before its end).
/// </summary>
public static class CovenantPeriods
{
    public static int Months(string frequency) => frequency switch
    {
        "ANNUAL" => 12, "SEMIANNUAL" => 6, "QUARTERLY" => 3, _ => 1,
    };

    private static DateTime EndOf(int year, int month) => new DateTime(year, month, 1).AddMonths(1).AddDays(-1);

    /// <summary>Whether a month end is a period end of the frequency for a fiscal year ending in <paramref name="fyeMonth"/>.</summary>
    public static bool IsPeriodEnd(DateTime monthEnd, string frequency, int fyeMonth) =>
        (monthEnd.Month - fyeMonth + 12) % 12 % Months(frequency) == 0;

    /// <summary>The first period end on or after a date.</summary>
    public static DateTime FirstPeriodEnd(DateTime from, string frequency, int fyeMonth)
    {
        var m = EndOf(from.Year, from.Month);
        while (!IsPeriodEnd(m, frequency, fyeMonth)) m = EndOf(m.AddDays(1).Year, m.AddDays(1).Month);
        return m;
    }

    /// <summary>The period ends from the first through the last date.</summary>
    public static IEnumerable<DateTime> PeriodEnds(DateTime first, DateTime through, string frequency, int fyeMonth)
    {
        var step = Months(frequency);
        for (var m = FirstPeriodEnd(first, frequency, fyeMonth); m <= through; m = EndOf(m.AddDays(1).AddMonths(step - 1).Year, m.AddDays(1).AddMonths(step - 1).Month))
            yield return m;
    }

    /// <summary>The first day of the period that ends on <paramref name="periodEnd"/>.</summary>
    public static DateTime PeriodStart(DateTime periodEnd, string frequency) =>
        new DateTime(periodEnd.Year, periodEnd.Month, 1).AddMonths(1 - (frequency == "ROLLING_12M" ? 12 : Months(frequency)));
}
