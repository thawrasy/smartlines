namespace BankFas.Core.Workflow;

/// <summary>
/// The hooks the engine knows (FR-WFL-021, spec 13 section 5.4, V-WFL-02): a template may register only these keys, and
/// publishing refuses any other. Each key is implemented in the data layer; a key listed here and not yet implemented
/// fails its stage when it runs, so a template that uses it is published only once the slice that builds it is in.
/// </summary>
public static class HookKeys
{
    public const string ValidateTerms = "lc.validate_terms";
    public const string RecordIssuance = "lc.record_issuance";
    public const string ApplyAmendment = "lc.apply_amendment";
    public const string IssueProforma = "lc.issue_proforma";
    public const string EarmarkSalesOrder = "lc.earmark_sales_order";
    public const string ConvertEarmark = "lc.convert_earmark";
    public const string CheckAvailability = "fac.check_availability";
    public const string ReserveLimit = "fac.reserve_limit";
    public const string ReleaseReservation = "fac.release_reservation";
    public const string AdjustReservation = "fac.adjust_reservation";
    public const string ConvertReservation = "fac.convert_reservation";
    public const string AdjustUtilization = "fac.adjust_utilization";
    public const string Emit = "ntf.emit";

    public static readonly IReadOnlySet<string> All = new HashSet<string>(StringComparer.Ordinal)
    {
        ValidateTerms, RecordIssuance, ApplyAmendment, CheckAvailability, ReserveLimit, ReleaseReservation, AdjustReservation, ConvertReservation,
        AdjustUtilization, Emit, IssueProforma, EarmarkSalesOrder, ConvertEarmark,
    };
}
