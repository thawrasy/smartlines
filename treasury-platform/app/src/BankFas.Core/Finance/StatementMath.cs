namespace BankFas.Core.Finance;

/// <summary>
/// A line of the statement catalogue as the grid and the checks read it (FR-FIN-001): its kind comes from the standard
/// lines (LINE, TOTAL, OF_WHICH, DETAIL, MEMO); a tenant's own line is a LINE.
/// </summary>
public sealed record LineDef(string Code, string Section, string Kind, bool IsRequired, string? TotalFormula, int SortOrder = 0, string? Parent = null);

/// <summary>A total as computed from its components, beside what was entered for it (BR-FIN-001).</summary>
public sealed record TotalCheck(string Code, decimal Computed, decimal? Entered, decimal? Variance, bool Matches);

/// <summary>The checks of a statement (FR-FIN-004, V-FIN-01): its totals, the balance, the required lines left empty.</summary>
public sealed record StatementCheck(IReadOnlyList<TotalCheck> Totals, decimal? BalanceDifference, bool Balanced, IReadOnlyList<string> MissingRequired)
{
    /// <summary>The errors that refuse a submission: a required line left empty (an imbalance is a warning with a reason).</summary>
    public bool CanSubmit => MissingRequired.Count == 0;
}

/// <summary>A line as stored: the entered amount times the unit scale, and the computed amount of a total.</summary>
public sealed record StoredLine(string Code, decimal? EnteredAmount, decimal? ComputedAmount);

/// <summary>
/// The totals and the balance of a statement (BR-FIN-001, BR-FIN-002). Amounts are in the statement's currency, already
/// multiplied by its unit scale; the tolerance of a comparison is one input unit (the scale). A total is the sum of its
/// formula's components (codes joined by + and -), each a line or another total; a component with no value counts 0.
/// </summary>
public static class StatementMath
{
    public const string TotalAssets = "TOTAL_ASSETS", TotalLiabilities = "TOTAL_LIABS", TotalEquity = "TOTAL_EQUITY";

    /// <summary>The kinds whose empty cell stays absent at submission, because their absence is unknown, not zero (BR-FIN-002).</summary>
    public static bool StaysAbsent(string kind) => kind is "OF_WHICH" or "DETAIL" or "MEMO";

    /// <summary>BR-FIN-002: 12,000 entered in thousands is 12,000,000.</summary>
    public static decimal Scale(decimal entered, int unitScale) => entered * unitScale;

    /// <summary>The components of a total formula, each with its sign (+1 or -1).</summary>
    public static IReadOnlyList<(string Code, int Sign)> Components(string formula)
    {
        var parts = new List<(string, int)>();
        var sign = 1;
        foreach (var raw in formula.Replace("+", " + ", StringComparison.Ordinal).Replace("-", " - ", StringComparison.Ordinal)
                     .Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            if (raw == "+") sign = 1;
            else if (raw == "-") sign = -1;
            else { parts.Add((raw, sign)); sign = 1; }
        }
        return parts;
    }

    /// <summary>The computed value of every total of the catalogue from the stored amounts (an entered total is not a component's source: its parts are).</summary>
    public static IReadOnlyDictionary<string, decimal> ComputeTotals(IReadOnlyList<LineDef> lines, IReadOnlyDictionary<string, decimal?> stored)
    {
        var defs = lines.ToDictionary(l => l.Code, StringComparer.Ordinal);
        var memo = new Dictionary<string, decimal>(StringComparer.Ordinal);
        var stack = new HashSet<string>(StringComparer.Ordinal);
        decimal Value(string code)
        {
            if (defs.TryGetValue(code, out var d) && d.TotalFormula is { } f)
            {
                if (memo.TryGetValue(code, out var known)) return known;
                if (!stack.Add(code)) throw new InvalidOperationException($"The total {code} reads itself.");
                var sum = Components(f).Sum(c => c.Sign * Value(c.Code));
                stack.Remove(code);
                return memo[code] = sum;
            }
            return stored.TryGetValue(code, out var v) && v is { } x ? x : 0m;
        }
        foreach (var l in lines.Where(l => l.TotalFormula is not null)) Value(l.Code);
        return memo;
    }

    /// <summary>FR-FIN-004 and V-FIN-01: each total against what was entered for it, the balance, the required lines left empty.</summary>
    public static StatementCheck Check(IReadOnlyList<LineDef> lines, IReadOnlyDictionary<string, decimal?> stored, int unitScale)
    {
        var totals = ComputeTotals(lines, stored);
        var checks = lines.Where(l => l.TotalFormula is not null).OrderBy(l => l.SortOrder).Select(l =>
        {
            var computed = totals[l.Code];
            var entered = stored.TryGetValue(l.Code, out var e) ? e : null;
            var variance = entered is { } x ? x - computed : (decimal?)null;
            return new TotalCheck(l.Code, computed, entered, variance, variance is null || Math.Abs(variance.Value) <= unitScale);
        }).ToList();
        decimal? Final(string code) => stored.TryGetValue(code, out var e) && e is { } x ? x : totals.TryGetValue(code, out var t) ? t : null;
        var hasBalance = lines.Any(l => l.Code == TotalAssets);
        decimal? difference = hasBalance && Final(TotalAssets) is { } a ? a - ((Final(TotalLiabilities) ?? 0) + (Final(TotalEquity) ?? 0)) : null;
        var missing = lines.Where(l => l.IsRequired && l.TotalFormula is null && !(stored.TryGetValue(l.Code, out var v) && v is not null))
            .OrderBy(l => l.SortOrder).Select(l => l.Code).ToList();
        return new StatementCheck(checks, difference, difference is null || Math.Abs(difference.Value) <= unitScale, missing);
    }

    /// <summary>
    /// The lines written at submission (BR-FIN-002): what was entered; an optional line left empty as an explicit 0; a
    /// detail, an "of which" or a memorandum line left empty stays absent; each total with its computed amount.
    /// </summary>
    public static IReadOnlyList<StoredLine> ForSubmission(IReadOnlyList<LineDef> lines, IReadOnlyDictionary<string, decimal?> stored)
    {
        var filled = lines.ToDictionary(l => l.Code, l => stored.TryGetValue(l.Code, out var v) ? v : null, StringComparer.Ordinal);
        foreach (var l in lines.Where(l => l.TotalFormula is null && filled[l.Code] is null && !StaysAbsent(l.Kind) && !l.IsRequired)) filled[l.Code] = 0m;
        var totals = ComputeTotals(lines, filled);
        return [.. lines.Select(l => new StoredLine(l.Code, filled[l.Code], totals.TryGetValue(l.Code, out var t) ? t : null))
            .Where(s => s.EnteredAmount is not null || s.ComputedAmount is not null)];
    }
}

/// <summary>The catalogue lines the entry grid shows first: the 51 of spec 12 section 6.6 (owner default OQ-1 of S2-b); the others are details of their section.</summary>
public static class LineCatalog
{
    public static readonly IReadOnlySet<string> SpecLines = new HashSet<string>(StringComparer.Ordinal)
    {
        "CASH", "AR", "CONTRACT_ASSETS", "INVENTORY", "DUE_FROM_RELATED", "OTHER_CA", "TOTAL_CA", "PPE", "INTANGIBLES", "OTHER_NCA", "TOTAL_ASSETS",
        "ST_LOANS", "BANK_ACCEPTANCES", "CURRENT_PORTION_LTD", "AP", "DUE_TO_RELATED", "OTHER_CL", "TOTAL_CL", "LT_LOANS", "LEASE_LIABS",
        "SHAREHOLDER_LOANS_SUB", "EOSB", "OTHER_NCL", "TOTAL_LIABS", "SHARE_CAPITAL", "RETAINED_EARNINGS", "REVALUATION_RESERVE", "OTHER_EQUITY",
        "MINORITY_INTEREST", "TOTAL_EQUITY", "REVENUE", "COGS", "GROSS_PROFIT", "OPEX", "OPERATING_PROFIT", "DEPR_AMORT", "EBITDA", "FINANCE_COSTS",
        "OTHER_INCOME", "ZAKAT_TAX", "NET_PROFIT", "OP_CASH_FLOW", "CAPEX", "PRINCIPAL_REPAID", "INTEREST_PAID", "DIVIDENDS", "LC_OUTSTANDING",
        "LG_PERFORMANCE", "LG_FINANCIAL", "GUARANTEES_GIVEN", "ZAKAT_DISPUTED",
    };
}
