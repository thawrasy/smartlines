namespace BankFas.Core.Lc;

/// <summary>The facts of one terms version that the comparison reads (FR-LCT-031): the days are counted from the issue of the credit.</summary>
public sealed record CompareFacts
{
    public decimal? Amount { get; init; }
    public string? Currency { get; init; }
    public int? ExpiryDays { get; init; }
    public int? LatestShipmentDays { get; init; }
    public int? PresentationDays { get; init; }
    public string? LcType { get; init; }
    public string? PartialShipments { get; init; }
    public string? Transhipment { get; init; }
    public string? Confirmation { get; init; }
    public string? Incoterm { get; init; }
    public string? IncotermPlace { get; init; }
    public string? GoodsDescription { get; init; }
    public IReadOnlyDictionary<string, (int Originals, int Copies)> Documents { get; init; } = new Dictionary<string, (int, int)>();
    public IReadOnlyDictionary<string, string> Charges { get; init; } = new Dictionary<string, string>();
}

/// <summary>One field compared: its key, the two values as text and the verdict for the beneficiary (BR-LCT-021).</summary>
public sealed record CompareLine(string FieldKey, string? Baseline, string? Received, string Verdict);

/// <summary>
/// The comparison of a received credit with its proforma, from the beneficiary's side (BR-LCT-021; FR-LCT-031,
/// FR-LCE-023): a larger amount, a later expiry or latest shipment, more days to present, partial shipments and
/// transhipment allowed and a confirmation are MORE_FAVOURABLE; a document added, more originals or copies, or a charge
/// moved to the beneficiary are LESS_FAVOURABLE (a document added is ADDED, one dropped MISSING); a different type,
/// Incoterm or description is REVIEW; the same is MATCH. Verdicts only: the locked terms never change.
/// </summary>
public static class TermsComparison
{
    public const string Match = "MATCH";
    public const string More = "MORE_FAVOURABLE";
    public const string Less = "LESS_FAVOURABLE";
    public const string Added = "ADDED";
    public const string Missing = "MISSING";
    public const string Review = "REVIEW";

    private static string Order<T>(T? baseline, T? received, bool largerIsBetter) where T : struct, IComparable<T>
    {
        if (baseline is null && received is null) return Match;
        if (baseline is null) return Added;
        if (received is null) return Missing;
        var c = received.Value.CompareTo(baseline.Value);
        return c == 0 ? Match : (c > 0) == largerIsBetter ? More : Less;
    }

    private static int Rank(string? v, params string[] worstToBest) => v is null ? -1 : Array.IndexOf(worstToBest, v);

    private static string Ranked(string? baseline, string? received, params string[] worstToBest)
    {
        if (string.Equals(baseline, received, StringComparison.Ordinal)) return Match;
        var (a, b) = (Rank(baseline, worstToBest), Rank(received, worstToBest));
        return a < 0 || b < 0 ? Review : b > a ? More : Less;
    }

    private static string Same(string? baseline, string? received) =>
        string.Equals(baseline?.Trim(), received?.Trim(), StringComparison.OrdinalIgnoreCase) ? Match : Review;

    public static IReadOnlyList<CompareLine> Compare(CompareFacts baseline, CompareFacts received)
    {
        ArgumentNullException.ThrowIfNull(baseline);
        ArgumentNullException.ThrowIfNull(received);
        static string? S(object? v) => v switch { null => null, decimal d => d.ToString("0.##", System.Globalization.CultureInfo.InvariantCulture), _ => v.ToString() };
        var lines = new List<CompareLine>
        {
            new("currencyId", baseline.Currency, received.Currency, Same(baseline.Currency, received.Currency)),
            new("amount", S(baseline.Amount), S(received.Amount), Order(baseline.Amount, received.Amount, true)),
            new("expiryDays", S(baseline.ExpiryDays), S(received.ExpiryDays), Order(baseline.ExpiryDays, received.ExpiryDays, true)),
            new("latestShipmentDays", S(baseline.LatestShipmentDays), S(received.LatestShipmentDays), Order(baseline.LatestShipmentDays, received.LatestShipmentDays, true)),
            new("presentationDays", S(baseline.PresentationDays), S(received.PresentationDays), Order(baseline.PresentationDays, received.PresentationDays, true)),
            new("lcType", baseline.LcType, received.LcType, Same(baseline.LcType, received.LcType)),
            new("partialShipments", baseline.PartialShipments, received.PartialShipments, Ranked(baseline.PartialShipments, received.PartialShipments, "NOT_ALLOWED", "ALLOWED")),
            new("transhipment", baseline.Transhipment, received.Transhipment, Ranked(baseline.Transhipment, received.Transhipment, "NOT_ALLOWED", "ALLOWED")),
            new("confirmation", baseline.Confirmation, received.Confirmation, Ranked(baseline.Confirmation, received.Confirmation, "WITHOUT", "MAY_ADD", "CONFIRMED")),
            new("incotermId", baseline.Incoterm, received.Incoterm, Same(baseline.Incoterm, received.Incoterm)),
            new("incotermPlace", baseline.IncotermPlace, received.IncotermPlace, Same(baseline.IncotermPlace, received.IncotermPlace)),
            new("goodsDescription", baseline.GoodsDescription, received.GoodsDescription, Same(baseline.GoodsDescription, received.GoodsDescription)),
        };
        foreach (var code in baseline.Documents.Keys.Union(received.Documents.Keys).OrderBy(k => k, StringComparer.Ordinal))
        {
            var inBase = baseline.Documents.TryGetValue(code, out var a);
            var inRecv = received.Documents.TryGetValue(code, out var b);
            var verdict = !inBase ? Added : !inRecv ? Missing
                : a == b ? Match
                : b.Originals >= a.Originals && b.Copies >= a.Copies ? Less
                : b.Originals <= a.Originals && b.Copies <= a.Copies ? More : Review;
            lines.Add(new CompareLine("doc:" + code, inBase ? $"{a.Originals}+{a.Copies}" : null, inRecv ? $"{b.Originals}+{b.Copies}" : null, verdict));
        }
        foreach (var cat in baseline.Charges.Keys.Union(received.Charges.Keys).OrderBy(k => k, StringComparer.Ordinal))
        {
            baseline.Charges.TryGetValue(cat, out var a);
            received.Charges.TryGetValue(cat, out var b);
            // For the beneficiary, a charge on the applicant is better than a share, and a share better than bearing it.
            lines.Add(new CompareLine("charge:" + cat, a, b, Ranked(a, b, "BENEFICIARY", "SHARED", "APPLICANT")));
        }
        return lines;
    }
}
