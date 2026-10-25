namespace BankFas.Core.Lc;

/// <summary>A finding of the terms checks: an error blocks the lock, a warning is shown and may be acknowledged (FR-LCT-023).</summary>
public sealed record TermsFinding(string Code, string Severity, string? Field, string Message)
{
    public bool IsError => Severity == "E";
}

/// <summary>The facts of a terms version the checks read; values as stored, dates as dates.</summary>
public sealed record TermsFacts
{
    public string LcClass { get; init; } = "PURCHASE";
    public string Scope { get; init; } = "INTERNATIONAL";
    public string? LcType { get; init; }
    public int? DeferralDays { get; init; }
    public string? MaturityBasis { get; init; }
    public string? MixedPaymentText { get; init; }
    public bool? DraftRequired { get; init; }
    public string? DraftDrawee { get; init; }
    public string? ConfirmingBankBic { get; init; }
    public string? AdvisingBankBic { get; init; }
    public decimal? Amount { get; init; }
    public string ToleranceMode { get; init; } = "NONE";
    public decimal TolerancePlusPct { get; init; }
    public decimal ToleranceMinusPct { get; init; }
    public string? ExpiryRule { get; init; }
    public DateOnly? ExpiryDate { get; init; }
    public int? ExpiryDaysAfterIssue { get; init; }
    public DateOnly? EarliestShipmentDate { get; init; }
    public string? LatestShipmentRule { get; init; }
    public DateOnly? LatestShipmentDate { get; init; }
    public int? LatestShipmentDaysAfterIssue { get; init; }
    public int? PresentationDays { get; init; }
    public bool HasIncoterm { get; init; }
    public string? IncotermPlace { get; init; }
    public int DocumentCount { get; init; }
    public IReadOnlySet<string> ChargeCategories { get; init; } = new HashSet<string>();
    public string? DebitAuthorization { get; init; }
    public decimal? MarginPct { get; init; }
    public decimal? PrevLcAmount { get; init; }
    public decimal? PrevLcUtilizedAmount { get; init; }
    // The UCP 600 checks of docs/60: insurance (article 28), instalments (32), the expiry day (29) and transhipment (19 to 24).
    public string? IncotermCode { get; init; }
    public string? InsuranceResponsibility { get; init; }
    public decimal? InsuranceMinPct { get; init; }
    public bool HasInsuranceDocument { get; init; }
    public string? PartialShipments { get; init; }
    public string? InstallmentShipments { get; init; }
    public string? Transhipment { get; init; }
    public string? TransportMode { get; init; }
    /// <summary>The expiry date is a non-working day in the calendar of the applicant's country (article 29 a).</summary>
    public bool ExpiryOnNonWorkingDay { get; init; }
    /// <summary>The field keys that hold a value (beside the ones above), for the required fields of BR-LCT-002.</summary>
    public IReadOnlySet<string> Filled { get; init; } = new HashSet<string>();
}

/// <summary>
/// The rules of letter-of-credit terms (spec 14 sections 5.1 to 5.3): the exposure passed to the facility services
/// (BR-LCI-004), and the V-LCT checks run before a version is locked (FR-LCT-023): the required fields of the field
/// dictionary for the class, scope and purpose (BR-LCT-002), the dates (V-LCT-01, BR-LCT-005 to 007), the drawee
/// (V-LCT-03), the tenor (V-LCT-06, BR-LCT-009), the tolerance (V-LCT-07, BR-LCT-004), the Incoterm's named place
/// (V-LCT-09), the charges matrix (V-LCT-12), the previous credit (V-LCT-14), the presentation period (V-LCT-16), the
/// BICs (V-LCT-20), the margin (BR-LCT-015), and the UCP 600 checks of docs/60 (V-LCT-UCP28, 29, 32 and 20).
/// </summary>
public static class TermsRules
{
    public static readonly string[] ChargeCategories =
        ["ISSUING_BANK_LOCAL", "ADVISING", "CONFIRMATION", "NEGOTIATION_SETTLEMENT", "AMENDMENT", "OTHER_OUTSIDE_ISSUING"];

    /// <summary>BR-LCI-004: the amount, raised by the plus tolerance when the tenant's setting includes it, at the currency's decimals.</summary>
    public static decimal Exposure(decimal amount, decimal tolerancePlusPct, bool includeTolerance, int decimals) =>
        Math.Round(includeTolerance ? amount * (1 + tolerancePlusPct / 100m) : amount, decimals, MidpointRounding.AwayFromZero);

    private static bool Bic(string? b) => b is null || (b.Length is 8 or 11 && b.All(ch => ch is >= 'A' and <= 'Z' or >= '0' and <= '9'));

    public static IReadOnlyList<TermsFinding> Check(TermsFacts f, IEnumerable<(string Key, string Label)> requiredFields, DateOnly today, decimal warnTolerancePct,
        int defaultPresentationDays)
    {
        ArgumentNullException.ThrowIfNull(f);
        ArgumentNullException.ThrowIfNull(requiredFields);
        var x = new List<TermsFinding>();
        void E(string code, string? field, string msg) => x.Add(new TermsFinding(code, "E", field, msg));
        void W(string code, string? field, string msg) => x.Add(new TermsFinding(code, "W", field, msg));
        foreach (var (key, label) in requiredFields)
            if (!f.Filled.Contains(key)) E("V-LCT-REQUIRED", key, $"{label} is required.");

        // V-LCT-01 and BR-LCT-005 to 007: the dates in order, the expiry ahead.
        if (f.ExpiryRule == "ABSOLUTE" && f.ExpiryDate is null) E("V-LCT-01", "expiryDate", "The expiry date is required.");
        if (f.ExpiryRule == "DAYS_AFTER_ISSUE" && f.ExpiryDaysAfterIssue is not > 0) E("V-LCT-01", "expiryDaysAfterIssue", "The days from issue to expiry are required.");
        if (f.ExpiryDate is { } exp && exp <= today) E("V-LCT-01", "expiryDate", "The expiry date is after today.");
        if (f.LatestShipmentRule == "ABSOLUTE" && f.LatestShipmentDate is null) E("V-LCT-01", "latestShipmentDate", "The latest shipment date is required.");
        if (f.EarliestShipmentDate is { } e1 && f.LatestShipmentDate is { } l1 && e1 > l1) E("V-LCT-01", "earliestShipmentDate", "The earliest shipment is not after the latest.");
        if (f.ExpiryDate is { } e2 && f.LatestShipmentDate is { } l2 && e2 < l2) E("V-LCT-01", "expiryDate", "The credit does not expire before the latest shipment.");
        if (f.ExpiryDate is { } e3 && f.LatestShipmentDate is { } l3 && f.PresentationDays is { } pd && l3.AddDays(pd) > e3)
            W("V-LCT-01", "presentationDays", "The presentation period after the latest shipment runs past the expiry.");

        // V-LCT-06 and BR-LCT-009: the tenor follows the type.
        switch (f.LcType)
        {
            case "SIGHT" when f.DeferralDays is not null || f.MaturityBasis is not null:
                E("V-LCT-06", "deferralDays", "A sight credit has no deferral.");
                break;
            case "DEFERRED_PAYMENT" or "ACCEPTANCE" when f.DeferralDays is null || f.MaturityBasis is null:
                E("V-LCT-06", "deferralDays", "A deferred or acceptance credit gives its days and the date they run from.");
                break;
            case "MIXED" when string.IsNullOrWhiteSpace(f.MixedPaymentText):
                E("V-LCT-06", "mixedPaymentText", "A mixed payment describes its parts.");
                break;
        }
        if (f.DeferralDays is { } d && d is < 1 or > 720) E("V-LCT-06", "deferralDays", "The deferral is from 1 to 720 days.");
        // V-LCT-03 and BR-LCT-011: acceptance and negotiation need a draft, a drawee needs a draft.
        if (f.LcType is "ACCEPTANCE" or "NEGOTIATION" && f.DraftRequired != true) E("V-LCT-03", "draftRequired", "An acceptance or negotiation credit needs a draft.");
        if (f.DraftDrawee is not null && f.DraftRequired != true) E("V-LCT-03", "draftDrawee", "A drawee is named only for a draft.");

        // V-LCT-07 and BR-LCT-004: the tolerance.
        switch (f.ToleranceMode)
        {
            case "NONE" when f.TolerancePlusPct != 0 || f.ToleranceMinusPct != 0:
                E("V-LCT-07", "toleranceMode", "Without a tolerance the percentages are zero.");
                break;
            case "ABOUT" when f.TolerancePlusPct != 10 || f.ToleranceMinusPct != 10:
                E("V-LCT-07", "toleranceMode", "\"About\" is plus or minus 10 percent (UCP 600 article 30).");
                break;
            case "PLUS_MINUS":
                if (f.TolerancePlusPct is < 0 or > 100 || f.ToleranceMinusPct is < 0 or > 100) E("V-LCT-07", "tolerancePlusPct", "A tolerance is from 0 to 100 percent.");
                else if (f.TolerancePlusPct > warnTolerancePct || f.ToleranceMinusPct > warnTolerancePct)
                    W("V-LCT-07", "tolerancePlusPct", $"A tolerance above {warnTolerancePct} percent is unusual.");
                break;
        }
        if (f.Amount is not > 0) E("V-LCT-REQUIRED", "amount", "The amount is above zero.");

        // V-LCT-09 and BR-LCT-010: an Incoterm names its place.
        if (f.HasIncoterm && string.IsNullOrWhiteSpace(f.IncotermPlace)) E("V-LCT-09", "incotermPlace", "The Incoterm names its place.");
        // V-LCT-12: one row for each of the six charge categories.
        var missing = ChargeCategories.Where(cat => !f.ChargeCategories.Contains(cat)).ToList();
        if (missing.Count > 0) E("V-LCT-12", "charges", $"The charges matrix lacks {string.Join(", ", missing)}.");
        if (f.DocumentCount == 0) E("V-LCT-REQUIRED", "documents", "The documents required are listed.");
        // V-LCT-14: the previous credit's use within its amount.
        if (f.PrevLcAmount is { } pa && f.PrevLcUtilizedAmount is { } pu && pu > pa) E("V-LCT-14", "prevLcUtilizedAmount", "The previous credit's use is within its amount.");
        // V-LCT-16: a presentation period longer than the default.
        if (f.PresentationDays is { } p && p > defaultPresentationDays) W("V-LCT-16", "presentationDays", $"A presentation period above {defaultPresentationDays} days is unusual.");
        // V-LCT-20: BIC of 8 or 11 capital letters and digits.
        if (!Bic(f.AdvisingBankBic)) E("V-LCT-20", "advisingBankBic", "A BIC is 8 or 11 capital letters and digits.");
        if (!Bic(f.ConfirmingBankBic)) E("V-LCT-20", "confirmingBankBic", "A BIC is 8 or 11 capital letters and digits.");
        // UCP 600 article 28 (f) (ii): the cover is at least 110 percent of the CIF or CIP value unless the credit states otherwise.
        if (f.InsuranceResponsibility != "NOT_REQUIRED_BY_TERMS" && f.InsuranceMinPct is { } ins && ins < 110)
            W("V-LCT-UCP28", "insuranceMinPct", "An insurance cover below 110 percent of the CIF or CIP value departs from UCP 600 article 28 (f) (ii); state it in the credit.");
        // Under CIF and CIP the seller insures: the beneficiary, with an insurance document among those required (article 28, BR-LCT-010).
        if (f.IncotermCode is "CIF" or "CIP")
        {
            if (!f.HasInsuranceDocument) W("V-LCT-UCP28", "documents", "A CIF or CIP credit asks for an insurance document (UCP 600 article 28).");
            if (f.InsuranceResponsibility is not null and not "BENEFICIARY") W("V-LCT-UCP28", "insuranceResponsibility", "Under CIF or CIP the beneficiary insures the goods.");
        }
        // UCP 600 articles 31 and 32: shipment by instalments is shipment in parts, so it needs partial shipments allowed.
        if (!string.IsNullOrWhiteSpace(f.InstallmentShipments) && f.PartialShipments == "NOT_ALLOWED")
            E("V-LCT-UCP32", "partialShipments", "Instalment shipments need partial shipments allowed (UCP 600 articles 31 and 32).");
        // UCP 600 article 29 (a) and (c): an expiry on a day the bank is closed moves to the next banking day; the latest shipment does not.
        if (f.ExpiryOnNonWorkingDay)
            W("V-LCT-UCP29", "expiryDate", "The expiry falls on a non-working day: under UCP 600 article 29 (a) it moves to the next banking day, but the latest shipment date does not (29 c).");
        // UCP 600 articles 19 (c), 20 (c), 23 (c) and 24 (e): a transport document may show transhipment even when the credit forbids it.
        if (f.Transhipment == "NOT_ALLOWED" && f.TransportMode is "SEA" or "AIR" or "MULTIMODAL" or "ROAD" or "RAIL")
            W("V-LCT-UCP20", "transhipment", "Under UCP 600 articles 19 to 24 a transport document showing transhipment is still acceptable in the cases they list (one document covering the whole carriage, or goods in containers), even when the credit forbids it.");

        // BR-LCT-015: a debit of the full value means a margin of 100 percent.
        if (f.DebitAuthorization == "FULL_LC_VALUE" && f.MarginPct is not 100) E("BR-LCT-015", "marginPct", "A debit of the full value takes a margin of 100 percent.");
        return x;
    }
}
