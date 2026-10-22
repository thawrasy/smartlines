namespace BankFas.Core.Collateral;

/// <summary>An insurance assignment measured against what it must cover (BR-COL-003).</summary>
public sealed record InsuranceCover(decimal Required, decimal SumInsured, decimal Shortfall, decimal CoveragePct, bool Expired);

/// <summary>A phase of a valuation schedule (FR-COL-008): years [FromYear, ToYear] from the reference date, every FrequencyMonths (0 = once).</summary>
public sealed record ValuationPhase(int PhaseNo, int FromYear, int? ToYear, int RequiredValuerCount, int FrequencyMonths, DateTime ReferenceDate);

/// <summary>A valuation that is due: its date and the number of valuers it needs (BR-COL-004).</summary>
public sealed record ValuationDue(DateTime Date, int PhaseNo, int Valuers);

/// <summary>The derived values of collateral (spec 12 section 8, BR-COL-002 to 004); none of them is stored.</summary>
public static class CollateralMath
{
    /// <summary>BR-COL-002: the note amount over the cap of the linked limit (or the facility total), in percent; it may exceed 100.</summary>
    public static decimal NoteRatioPct(decimal noteAmount, decimal cap) => cap <= 0 ? 0 : Math.Round(noteAmount / cap * 100m, 2, MidpointRounding.AwayFromZero);

    /// <summary>BR-COL-002: an annual note is renewed twelve months after its last renewal, or after its issue.</summary>
    public static DateTime? NextRenewalDue(string renewalCycle, DateTime issuedOn, DateTime? lastRenewedOn) =>
        renewalCycle == "ANNUAL" ? (lastRenewedOn ?? issuedOn).AddMonths(12) : null;

    /// <summary>
    /// BR-COL-003: what the policy must cover is a percent of the cap (PCT_OF_LIMIT), a fixed amount, or the caps of the
    /// main limits inside the total (FULL_LIMITS, given by the caller). An expired policy covers nothing.
    /// </summary>
    public static InsuranceCover Insurance(string basis, decimal? pct, decimal? amount, decimal cap, decimal fullLimits, decimal sumInsured, DateTime expiry, DateTime asOf)
    {
        var required = basis switch
        {
            "PCT_OF_LIMIT" => Math.Round(cap * (pct ?? 0) / 100m, 2, MidpointRounding.AwayFromZero),
            "FIXED_AMOUNT" => amount ?? 0,
            "FULL_LIMITS" => fullLimits,
            _ => throw new ArgumentOutOfRangeException(nameof(basis), basis, "The coverage basis is PCT_OF_LIMIT, FIXED_AMOUNT or FULL_LIMITS."),
        };
        var expired = expiry.Date < asOf.Date;
        var insured = expired ? 0 : sumInsured;
        var pctCovered = required <= 0 ? 100m : Math.Round(insured / required * 100m, 2, MidpointRounding.AwayFromZero);
        return new InsuranceCover(required, insured, Math.Max(required - insured, 0), pctCovered, expired);
    }

    /// <summary>
    /// BR-COL-004: the valuations of a schedule from its reference date: phase k covers its years, the first valuation on
    /// the reference date plus the phase's start, then every FrequencyMonths while inside the phase (an open phase runs to
    /// the horizon). Dates are returned in order, from the given date on.
    /// </summary>
    public static IReadOnlyList<ValuationDue> Valuations(IEnumerable<ValuationPhase> phases, DateTime from, DateTime horizon)
    {
        var dues = new List<ValuationDue>();
        foreach (var p in phases.OrderBy(p => p.PhaseNo))
        {
            var start = p.ReferenceDate.AddYears(p.FromYear - 1);
            var end = p.ToYear is { } to ? p.ReferenceDate.AddYears(to) : horizon.AddDays(1);
            var d = start;
            for (var n = 1; d < end && d <= horizon; n++)
            {
                if (d >= from.Date) dues.Add(new ValuationDue(d, p.PhaseNo, p.RequiredValuerCount));
                if (p.FrequencyMonths == 0) break;
                d = start.AddMonths(p.FrequencyMonths * n);
            }
        }
        return [.. dues.OrderBy(d => d.Date)];
    }

    /// <summary>V-COL-01: the closed phases do not overlap and at most one phase is open, the last.</summary>
    public static bool PhasesOverlap(IEnumerable<ValuationPhase> phases)
    {
        var list = phases.OrderBy(p => p.FromYear).ToList();
        for (var i = 1; i < list.Count; i++)
            if (list[i - 1].ToYear is not { } prevTo || list[i].FromYear <= prevTo) return true;
        return false;
    }
}
