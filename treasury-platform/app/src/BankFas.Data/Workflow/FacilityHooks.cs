using System.Globalization;
using BankFas.Core.Lc;
using BankFas.Data.Facilities;
using BankFas.Data.Lc;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Workflow;

/// <summary>
/// The facility hooks of the engine (spec 13 section 5.4; S3 batch D): fac.check_availability on leaving FACILITY_SELECTION
/// asks for the allocation and records what the panel showed; fac.reserve_limit on the TM's approval reserves the
/// exposure on the allocated limit or line through the one reservation service (BR-WFL-016, BR-FAC-015), with the
/// override only where the tenant allows it and the approver holds fac.override_limit with a reason (FR-FAC-020). A
/// refusal of the service refuses the approval, so no approval row is written (AC-WFL-3).
/// </summary>
public static class FacilityHooks
{
    public sealed record Allocation(long FacilityId, long LimitRoot, long? LineRoot);

    public static async Task<Allocation?> AllocationAsync(SqlConnection c, SqlTransaction tx, long requestId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<Allocation>(new CommandDefinition(
            """
            SELECT r.FacilityId, l.RootId AS LimitRoot, pl.RootId AS LineRoot
              FROM wfl.Request AS r JOIN fac.Limit AS l ON l.LimitId = r.LimitId LEFT JOIN fac.LimitProductLine AS pl ON pl.LimitProductLineId = r.LimitProductLineId
             WHERE r.RequestId = @r AND r.FacilityId IS NOT NULL;
            """, new { r = requestId }, tx, cancellationToken: ct)).ConfigureAwait(false);

    /// <summary>fac.check_availability: the facility selection is complete only with a limit allocated (FR-REQ-013).</summary>
    public static async Task<object?> CheckAvailabilityAsync(RequestEngine.HookContext h)
    {
        var a = await AllocationAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-REQ-ALLOCATION", "Choose the facility and the limit first.");
        return new { a.FacilityId, a.LimitRoot, a.LineRoot };
    }

    private static async Task<Dictionary<string, string?>> SettingsAsync(SqlConnection c, SqlTransaction tx, CancellationToken ct, params string[] keys) =>
        (await c.QueryAsync<(string Key, string? Value)>(new CommandDefinition(
            """
            SELECT d.[Key], ISNULL(s.ValueJson, d.DefaultValueJson) FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS s ON s.[Key] = d.[Key]
             WHERE d.[Key] IN @keys;
            """, new { keys }, tx, cancellationToken: ct)).ConfigureAwait(false)).ToDictionary(x => x.Key, x => x.Value?.Trim('"'));

    /// <summary>The exposure of the request (BR-LCI-004): the locked terms' amount with its plus tolerance, else the request's amount.</summary>
    public static async Task<(decimal Amount, int CurrencyId, DateTime? ExpiresOn)> ExposureAsync(SqlConnection c, SqlTransaction tx, RequestEngine.RequestRow r, DateTime today,
        CancellationToken ct)
    {
        var s = await SettingsAsync(c, tx, ct, "lc.reserve.include_tolerance", "lc.reserve.buffer_days", "lc.expected_issue_days").ConfigureAwait(false);
        var buffer = int.TryParse(s.GetValueOrDefault("lc.reserve.buffer_days"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var b) ? b : 30;
        var issueDays = int.TryParse(s.GetValueOrDefault("lc.expected_issue_days"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var e) ? e : 7;
        var t = await TermsStore.CurrentAsync(c, tx, r.RequestId, ct).ConfigureAwait(false);
        if (t is { Amount: { } amount, CurrencyId: { } cur })
        {
            var decimals = await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = cur }, tx, cancellationToken: ct))
                .ConfigureAwait(false);
            var dates = await c.QuerySingleAsync<(DateTime? Expiry, int? DaysAfterIssue, DateTime? Expected)>(new CommandDefinition(
                "SELECT ExpiryDate, ExpiryDaysAfterIssue, ExpectedIssueDate FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = t.LcTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
            // BR-LCI-005: the reservation lasts the credit's validity from its expected issue, plus the buffer.
            var issue = dates.Expected ?? today.AddDays(issueDays);
            var expiry = dates.Expiry ?? (dates.DaysAfterIssue is { } d ? issue.AddDays(d) : (DateTime?)null);
            return (TermsRules.Exposure(amount, t.TolerancePlusPct, s.GetValueOrDefault("lc.reserve.include_tolerance") != "false", decimals), cur,
                expiry?.AddDays(buffer));
        }
        if (r.Amount is { } a && r.CurrencyId is { } c2) return (a, c2, today.AddDays(issueDays + buffer));
        throw WorkflowRefusalException.Missing("V-REQ-02", "The request has no amount to reserve.");
    }

    /// <summary>fac.reserve_limit (BR-WFL-016): reserve, or refuse the approval with the service's code and the amounts that decided it.</summary>
    public static async Task<object?> ReserveLimitAsync(RequestEngine.HookContext h)
    {
        var a = await AllocationAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-REQ-ALLOCATION", "The request has no facility allocated.");
        var today = h.Now.UtcDateTime.Date;
        var (amount, currency, expires) = await ExposureAsync(h.C, h.Tx, h.Request, today, h.Ct).ConfigureAwait(false);
        var authorised = false;
        if (h.Command.OverrideRequested)
        {
            var s = await SettingsAsync(h.C, h.Tx, h.Ct, "fac.override_limit.enabled").ConfigureAwait(false);
            authorised = s.GetValueOrDefault("fac.override_limit.enabled") == "true" && h.Actor.Permissions.Contains("fac.override_limit");
        }
        var result = await ReservationService.ReserveAsync(h.C, h.Tx, new ReserveCommand(h.Request.RequestId, a.LimitRoot, a.LineRoot, h.Request.CompanyId, amount, currency, null,
            expires, h.Actor.UserId, h.Command.OverrideRequested, h.Command.OverrideReason, authorised), today, h.Ct).ConfigureAwait(false);
        if (!result.Reserved)
        {
            var detail = result.Availability is { } av ? string.Create(CultureInfo.InvariantCulture, $" Requested {amount:N2}, available {Math.Max(0, av.Avail):N2}.") : "";
            throw new WorkflowRefusalException(409, result.Outcome, result.Outcome switch
            {
                "INSUFFICIENT_AVAILABLE" => "The limit does not have the amount available (BR-FAC-015)." + detail,
                "OVERRIDE_NOT_ALLOWED" => "Reserving above the available amount is not allowed for you or for the account (FR-FAC-020).",
                "OVERRIDE_REASON_REQUIRED" => "An override gives its reason (FR-FAC-020).",
                "COMPANY_EXCLUDED" => "The company may not use this limit (BR-FAC-012).",
                "LIMIT_NOT_ACTIVE" => "The limit is not active on this date.",
                "VALIDITY_UNCONFIRMED" => "The facility's validity is not confirmed and its use is blocked.",
                "CURRENCY_NO_RATE" => "The request's currency differs from the facility's and no rate is given.",
                "CONCURRENT_RETRY" => "The limit is busy; try again.",
                _ => "The reservation was refused.",
            });
        }
        var over = await h.C.ExecuteScalarAsync<bool>(new CommandDefinition("SELECT OverLimit FROM fac.LimitReservation WHERE LimitReservationId = @id;",
            new { id = result.ReservationId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        if (over)
            await Notifier.RequestAsync(h.C, h.Tx, new NotificationRequest("FAC.RESERVATION_ALERT", "fac.LimitReservation", result.ReservationId!.Value,
                $"FAC.RESERVATION_ALERT:{result.ReservationId}:over", h.Request.CompanyId, new Dictionary<string, object?> { ["reasonLabel"] = new { ar = "حجز فوق المتاح", en = "Reserved above the available amount" } },
                null, h.Actor.UserId), h.Ct).ConfigureAwait(false);
        return new { reservationId = result.ReservationId, amount, currency, overLimit = over };
    }
}
