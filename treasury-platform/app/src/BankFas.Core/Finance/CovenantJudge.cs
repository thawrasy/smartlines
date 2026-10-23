namespace BankFas.Core.Finance;

/// <summary>The judgement of a test: the result, the headroom (positive when compliant) and its share of the threshold.</summary>
public sealed record Judgement(string Result, decimal? Headroom, decimal? HeadroomPct);

/// <summary>
/// The judgement of a covenant test (BR-OBL-006, BR-OBL-007, BR-FIN-011): at full precision; GT and LT are strict;
/// the headroom is a − t for GE and GT, t − a for LE and LT, and −|a − t| for EQ (0 when equal); its share is the
/// headroom over |t| × 100, none when t is 0; a compliant result is a WARNING when the share is at most the covenant's
/// early warning percentage. A covenant without a set threshold is not assessed, never "compliant".
/// </summary>
public static class CovenantJudge
{
    public static Judgement Judge(decimal actual, decimal? threshold, string? op, decimal earlyWarningPct)
    {
        if (threshold is not { } t || op is null) return new Judgement("NOT_ASSESSED_NO_THRESHOLD", null, null);
        var met = op switch
        {
            "GE" => actual >= t, "GT" => actual > t, "LE" => actual <= t, "LT" => actual < t, "EQ" => actual == t,
            _ => throw new ArgumentOutOfRangeException(nameof(op), op, "An operator is GE, GT, LE, LT or EQ."),
        };
        var headroom = op switch { "GE" or "GT" => actual - t, "LE" or "LT" => t - actual, _ => -Math.Abs(actual - t) };
        decimal? pct = t == 0 ? null : headroom / Math.Abs(t) * 100;
        var result = !met ? "BREACH" : pct is { } p && p <= earlyWarningPct && op != "EQ" ? "WARNING" : "COMPLIANT";
        return new Judgement(result, headroom, pct);
    }

    /// <summary>Six decimals as stored (BR-FIN-011): the judgement is made on the full value before.</summary>
    public static decimal Stored(decimal value) => Math.Round(value, 6, MidpointRounding.AwayFromZero);

    /// <summary>
    /// BR-FIN-005: the balance of each month is the sum over the accounts of the scope; the months are taken as the
    /// covenant says: the lowest month, their average, the last month or their sum.
    /// </summary>
    public static decimal Aggregate(IReadOnlyList<decimal> months, string mode) => mode switch
    {
        "EACH_MONTH_MIN" => months.Min(),
        "PERIOD_AVERAGE" => months.Sum() / months.Count,
        "POINT_IN_TIME" => months[^1],
        "PERIOD_SUM" => months.Sum(),
        _ => throw new ArgumentOutOfRangeException(nameof(mode), mode, "An aggregation is EACH_MONTH_MIN, PERIOD_AVERAGE, POINT_IN_TIME or PERIOD_SUM."),
    };
}
