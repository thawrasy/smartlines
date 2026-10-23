using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using BankFas.Core.Text;
using BankFas.Data.Facilities;
using BankFas.Data.Notifications;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>An amendment asked for an issued purchase credit (FR-LCI-018): its kinds, the change of the credit's amount, the new dates and the reason.</summary>
public sealed record NewAmendment(IReadOnlyList<string> ChangeKinds, decimal? AmountDelta, DateTime? NewExpiryDate, DateTime? NewLatestShipmentDate, string? Reason);

/// <summary>The bank's result of an amendment (FR-LCI-019): its number and date, the bank's reference and the beneficiary's answer.</summary>
public sealed record AmendmentResult(int AmendmentNo, DateTime BankIssuedOn, string? BankAmendmentRef, string BeneficiaryResponse);

/// <summary>
/// Amendments of purchase letters of credit (FR-LCI-018 to 022; BR-LCI-011, 012; spec 14 section 5.4; AC-WFL-7) through
/// the child request LC_AMENDMENT (CHILD_AMENDMENT): one open amendment per credit (lc.amendment.max_open, V-LCI-07);
/// its terms are a copy of the credit's current ones with the changes (Purpose AMENDMENT), locked at the submission;
/// AmountDelta is the change of the credit's exposure (the amount change with the plus tolerance when the tenant
/// reserves it, BR-LCI-004), and an increase takes the treasury manager's approval, where fac.adjust_utilization
/// reserves it on the credit's own line (so an increase above the available is refused, AC-WFL-7). The bank's result is
/// recorded on the result stage; leaving it applies the amendment in one transaction (lc.apply_amendment): on the
/// beneficiary's acceptance the credit takes the new amount and dates, a new ISSUED terms version, the next amendment
/// number, and its utilisation moves by the delta (the increase's reservation is superseded into it); on a refusal the
/// amendment is REJECTED and its reservation released. A cancellation releases the credit's utilisation and cancels it.
/// </summary>
public static class AmendmentStore
{
    private sealed class Lc
    {
        public long LetterOfCreditId { get; init; }
        public long CompanyId { get; init; }
        public string Status { get; init; } = "";
        public string LcNumber { get; init; } = "";
        public decimal Amount { get; init; }
        public decimal? ExposureAmount { get; init; }
        public decimal TolerancePlusPct { get; init; }
        public int CurrencyId { get; init; }
        public long CurrentTermsId { get; init; }
        public long? RequestId { get; init; }
        public long? FacilityId { get; init; }
        public long? LimitId { get; init; }
        public long? LimitProductLineId { get; init; }
        public long? UtilizationId { get; init; }
        public int AmendmentNo { get; init; }
        public DateTime ExpiryDate { get; init; }
        public decimal DrawnAmount { get; init; }
    }

    private static async Task<Lc> LcAsync(SqlConnection c, SqlTransaction tx, long lcId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<Lc>(new CommandDefinition(
            """
            SELECT LetterOfCreditId, CompanyId, Status, LcNumber, Amount, ExposureAmount, TolerancePlusPct, CurrencyId, CurrentTermsId, RequestId, FacilityId, LimitId,
                   LimitProductLineId, UtilizationId, AmendmentNo, ExpiryDate, DrawnAmount
              FROM lc.LetterOfCredit WITH (UPDLOCK, HOLDLOCK) WHERE LetterOfCreditId = @id AND LcClass = 'PURCHASE';
            """, new { id = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false)
        ?? throw new WorkflowRefusalException(404, "NOT_FOUND", "The letter of credit does not exist or is not visible to you.");

    private static readonly string[] Kinds = ["INCREASE_AMOUNT", "DECREASE_AMOUNT", "EXTEND_EXPIRY", "CHANGE_SHIPMENT_DATE", "CHANGE_TERMS", "CANCEL"];

    /// <summary>Raises the amendment's child request on the credit and writes its draft amendment and terms.</summary>
    public static async Task<(long RequestId, Guid PublicId)> CreateAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, NewAmendment a, DateTimeOffset now,
        CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(a);
        if (!actor.Permissions.Contains("lc.child.create")) throw WorkflowRefusalException.Forbidden("You may not raise follow-up requests on letters of credit.");
        var lc = await LcAsync(c, tx, lcId, ct).ConfigureAwait(false);
        if (lc.Status != "ACTIVE") throw WorkflowRefusalException.State("Only an active letter of credit is amended.");
        var kinds = a.ChangeKinds.Select(k => k.Trim().ToUpperInvariant()).Distinct().ToList();
        if (kinds.Count == 0 || kinds.Any(k => !Kinds.Contains(k))) throw WorkflowRefusalException.Missing("V-LCI-07", "Choose what the amendment changes.");
        var delta = a.AmountDelta ?? 0;
        if (kinds.Contains("INCREASE_AMOUNT") && kinds.Contains("DECREASE_AMOUNT")) throw WorkflowRefusalException.Missing("V-LCI-07", "An amendment raises or lowers the amount, not both.");
        if (kinds.Contains("INCREASE_AMOUNT") != delta > 0 || kinds.Contains("DECREASE_AMOUNT") != delta < 0)
            throw WorkflowRefusalException.Missing("V-LCI-07", "The amount change matches the kind of the amendment.");
        if (lc.Amount + delta <= 0) throw WorkflowRefusalException.Missing("V-LCI-07", "The new amount is above zero.");
        if (delta < 0 && lc.Amount + delta < lc.DrawnAmount) throw WorkflowRefusalException.Missing("V-LCI-07", "The new amount is not below what is drawn.");
        if (kinds.Contains("EXTEND_EXPIRY") && (a.NewExpiryDate is not { } e || e.Date <= lc.ExpiryDate.Date))
            throw WorkflowRefusalException.Missing("V-LCI-07", "An extension gives a later expiry date.");
        var s = await FacilityHooks.SettingsAsync(c, tx, ct, "lc.amendment.max_open", "lc.reserve.include_tolerance").ConfigureAwait(false);
        var maxOpen = int.TryParse(s.GetValueOrDefault("lc.amendment.max_open"), out var m) ? m : 1;
        var open = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM lc.LcAmendment WHERE LcId = @lc AND Status IN ('DRAFT', 'REQUESTED', 'BANK_ISSUED');", new { lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (open >= maxOpen) throw WorkflowRefusalException.Missing("V-LCI-07", "The letter of credit already has an open amendment (FR-LCI-022).");
        var cur = await c.QuerySingleAsync<(string Code, int Decimals)>(new CommandDefinition("SELECT Code, Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = lc.CurrencyId },
            tx, cancellationToken: ct)).ConfigureAwait(false);
        var exposureDelta = delta == 0 ? 0 : Core.Lc.TermsRules.Exposure(delta, lc.TolerancePlusPct, s.GetValueOrDefault("lc.reserve.include_tolerance") != "false", cur.Decimals);
        var form = JsonSerializer.Serialize(new
        {
            title = $"Amendment of {lc.LcNumber}", kind = kinds.Contains("CANCEL") ? "CANCEL" : "AMEND", amountDelta = exposureDelta, notes = a.Reason,
        });
        var (requestId, publicId, _) = await RequestEngine.CreateDraftAsync(c, tx, actor, new NewRequest("LC_AMENDMENT", lc.CompanyId, null, form, ParentRequestId: lc.RequestId,
            ParentEntityType: "LETTER_OF_CREDIT", ParentEntityId: lcId), now, ct).ConfigureAwait(false);
        // The child carries the credit's allocation and the exposure it asks for, which the TM's approval reserves.
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE wfl.Request SET FacilityId = @f, LimitId = @l, LimitProductLineId = @ln, Amount = @amount, CurrencyId = @cur WHERE RequestId = @r;
            """, new { f = lc.FacilityId, l = lc.LimitId, ln = lc.LimitProductLineId, amount = Math.Abs(exposureDelta) > 0 ? Math.Abs(exposureDelta) : (decimal?)null, cur = lc.CurrencyId,
                r = requestId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var terms = await TermsStore.CopyAsync(c, tx, lc.CurrentTermsId, "REQUEST", requestId, "AMENDMENT", 1, "DRAFT", ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcTerms SET Amount = Amount + @delta, ExpiryDate = ISNULL(@exp, ExpiryDate), LatestShipmentDate = ISNULL(@ship, LatestShipmentDate),
                   AmountInWordsAr = NULL, AmountInWordsEn = NULL
             WHERE LcTermsId = @t;
            """, new { delta, exp = a.NewExpiryDate?.Date, ship = a.NewLatestShipmentDate?.Date, t = terms }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT lc.LcAmendment (TenantId, CompanyId, LcId, Origin, ChangeKinds, RequestId, TermsPurpose, TermsId, CurrencyId, AmountDelta, NewAmount, NewExpiryDate, Status,
                                   BeneficiaryResponse, Reason, CreatedBy)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @co, @lc, 'OUR_REQUEST', @kinds, @r, 'AMENDMENT', @t, @cur, @d, @new, @exp, 'DRAFT', 'PENDING', @reason, @u);
            """,
            new
            {
                co = lc.CompanyId, lc = lcId, kinds = string.Join(",", kinds), r = requestId, t = terms, cur = lc.CurrencyId, d = exposureDelta,
                @new = delta == 0 ? (decimal?)null : lc.Amount + delta, exp = a.NewExpiryDate?.Date, reason = a.Reason, u = actor.UserId,
            }, tx, cancellationToken: ct)).ConfigureAwait(false);
        return (requestId, publicId);
    }

    private sealed class Amendment
    {
        public long LcAmendmentId { get; init; }
        public long LcId { get; init; }
        public string ChangeKinds { get; init; } = "";
        public long TermsId { get; init; }
        public decimal AmountDelta { get; init; }
        public decimal? NewAmount { get; init; }
        public DateTime? NewExpiryDate { get; init; }
        public string Status { get; init; } = "";
        public string? BeneficiaryResponse { get; init; }
        public int? AmendmentNo { get; init; }
    }

    private static async Task<Amendment?> OfRequestAsync(SqlConnection c, SqlTransaction tx, long requestId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<Amendment>(new CommandDefinition(
            """
            SELECT LcAmendmentId, LcId, ChangeKinds, TermsId, AmountDelta, NewAmount, NewExpiryDate, Status, BeneficiaryResponse, AmendmentNo
              FROM lc.LcAmendment WITH (UPDLOCK) WHERE RequestId = @r;
            """, new { r = requestId }, tx, cancellationToken: ct)).ConfigureAwait(false);

    /// <summary>lc.validate_terms on an amendment's submission: its terms checked (the dates in order, the expiry ahead) and locked with their hash; the amendment is REQUESTED.</summary>
    public static async Task<object?> ValidateHookAsync(RequestEngine.HookContext h)
    {
        var a = await OfRequestAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "The amendment of the letter of credit is required.");
        var t = await h.C.QuerySingleAsync<(string Status, decimal? Amount, DateTime? Expiry, DateTime? Ship, int CurrencyId)>(new CommandDefinition(
            "SELECT Status, Amount, ExpiryDate, LatestShipmentDate, CurrencyId FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = a.TermsId }, h.Tx, cancellationToken: h.Ct))
            .ConfigureAwait(false);
        if (t.Status == "LOCKED") return new { termsId = a.TermsId, locked = true };
        var today = h.Now.UtcDateTime.Date;
        if (t.Amount is not > 0) throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "The amended amount is above zero.");
        if (t.Expiry is { } e && e.Date <= today) throw WorkflowRefusalException.Missing("V-LCT-01", "The expiry date is after today.");
        if (t.Expiry is { } e2 && t.Ship is { } s2 && e2 < s2) throw WorkflowRefusalException.Missing("V-LCT-01", "The credit does not expire before the latest shipment.");
        var cur = await h.C.QuerySingleAsync<(string NameAr, string NameEn, int Decimals)>(new CommandDefinition(
            "SELECT NameAr, NameEn, Decimals FROM ref.Currency WHERE CurrencyId = @c;", new { c = t.CurrencyId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        var fields = await TermsStore.ReadAsync(h.C, h.Tx, a.TermsId, false, h.Ct).ConfigureAwait(false);
        var b = new StringBuilder();
        using (var json = JsonDocument.Parse(JsonSerializer.Serialize(new { fields, a.ChangeKinds, a.AmountDelta }))) Core.Workflow.Snapshot.Canonical(json.RootElement, b);
        var n = await h.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcTerms SET AmountInWordsAr = @ar, AmountInWordsEn = @en, SnapshotHash = @hash, LockedAt = SYSUTCDATETIME(), LockedBy = @u, Status = 'LOCKED'
             WHERE LcTermsId = @t AND Status = 'DRAFT';
            UPDATE lc.LcAmendment SET Status = 'REQUESTED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LcAmendmentId = @a AND Status = 'DRAFT';
            """,
            new
            {
                ar = AmountInWords.Arabic(t.Amount.Value, cur.NameAr, cur.Decimals), en = AmountInWords.English(t.Amount.Value, cur.NameEn, cur.Decimals),
                hash = SHA256.HashData(Encoding.UTF8.GetBytes(b.ToString())), u = h.Actor.UserId, t = a.TermsId, a = a.LcAmendmentId,
            }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        if (n < 2) throw WorkflowRefusalException.Conflict();
        return new { termsId = a.TermsId, amendment = a.LcAmendmentId };
    }

    /// <summary>fac.adjust_utilization on the TM's approval: an increase of the exposure is reserved on the credit's line (refused when not available); a decrease waits for its application.</summary>
    public static async Task<object?> AdjustUtilizationHookAsync(RequestEngine.HookContext h)
    {
        var a = await OfRequestAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "The amendment of the letter of credit is required.");
        if (a.AmountDelta <= 0) return new { reserved = false, delta = a.AmountDelta };
        return await FacilityHooks.ReserveLimitAsync(h).ConfigureAwait(false);
    }

    /// <summary>The bank's result of the amendment, recorded by the assignee of its result stage (lc.amendment.record).</summary>
    public static async Task RecordResultAsync(SqlConnection c, SqlTransaction tx, Actor actor, long requestId, AmendmentResult r, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(r);
        if (!actor.Permissions.Contains("lc.amendment.record")) throw WorkflowRefusalException.Forbidden("You may not record amendments.");
        var inst = await RequestEngine.CurrentInstanceAsync(c, tx, requestId, ct).ConfigureAwait(false);
        if (inst is not { StageKey: "AMENDMENT_RESULT", Status: "CLAIMED" } || inst.AssigneeUserId != actor.UserId)
            throw WorkflowRefusalException.State("The result is recorded by the assignee of the amendment's result stage.");
        if (r.AmendmentNo < 1 || r.BeneficiaryResponse is not ("ACCEPTED" or "REJECTED"))
            throw WorkflowRefusalException.Missing("V-LCI-08", "Give the bank's amendment number, its date and the beneficiary's answer (ACCEPTED or REJECTED).");
        var a = await OfRequestAsync(c, tx, requestId, ct).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (a.Status is not ("REQUESTED" or "BANK_ISSUED")) throw WorkflowRefusalException.State("The amendment is not waiting for the bank.");
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcAmendment SET Status = 'BANK_ISSUED', AmendmentNo = @no, BankIssuedOn = @on, BankAmendmentRef = @ref, BeneficiaryResponse = @resp, RespondedOn = @on,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LcAmendmentId = @a;
            """, new { no = r.AmendmentNo, on = r.BankIssuedOn.Date, @ref = r.BankAmendmentRef, resp = r.BeneficiaryResponse, u = actor.UserId, a = a.LcAmendmentId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
    }

    /// <summary>lc.apply_amendment on leaving the result stage: the accepted amendment is applied to the credit, or the refused one closed with its reservation released.</summary>
    public static async Task<object?> ApplyHookAsync(RequestEngine.HookContext h)
    {
        var a = await OfRequestAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.Missing("V-LCT-REQUIRED", "The amendment of the letter of credit is required.");
        if (a.Status == "APPLIED") return new { applied = true, replay = true };
        if (a.Status != "BANK_ISSUED") throw WorkflowRefusalException.Missing("V-LCI-08", "Record the bank's result of the amendment first.");
        var lc = await LcAsync(h.C, h.Tx, a.LcId, h.Ct).ConfigureAwait(false);
        if (lc.FacilityId is { } f)
            await h.C.ExecuteAsync(new CommandDefinition("SELECT FacilityId FROM fac.Facility WITH (UPDLOCK, HOLDLOCK) WHERE FacilityId = @f;", new { f }, h.Tx, cancellationToken: h.Ct))
                .ConfigureAwait(false);
        var today = h.Now.UtcDateTime.Date;
        var reservation = await h.C.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT LimitReservationId FROM fac.LimitReservation WHERE RequestId = @r AND Status = 'ACTIVE';", new { r = h.Request.RequestId }, h.Tx, cancellationToken: h.Ct))
            .ConfigureAwait(false);
        if (a.BeneficiaryResponse == "REJECTED")
        {
            if (reservation is { } rid) await ReservationService.ReleaseAsync(h.C, h.Tx, rid, "REJECTED", h.Actor.UserId, today, h.Ct).ConfigureAwait(false);
            await h.C.ExecuteAsync(new CommandDefinition("UPDATE lc.LcAmendment SET Status = 'REJECTED', UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LcAmendmentId = @a;",
                new { u = h.Actor.UserId, a = a.LcAmendmentId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
            await Notifier.RequestAsync(h.C, h.Tx, new NotificationRequest("LC.AMENDMENT_RESPONSE", "lc.LetterOfCredit", lc.LetterOfCreditId, $"LC.AMENDMENT_RESPONSE:{a.LcAmendmentId}",
                lc.CompanyId, new Dictionary<string, object?> { ["lcNo"] = lc.LcNumber, ["requestNo"] = h.Request.RequestNo }, $"/lcs/{lc.LetterOfCreditId}", h.Actor.UserId), h.Ct)
                .ConfigureAwait(false);
            return new { applied = false, rejected = true };
        }
        if (a.ChangeKinds.Contains("CANCEL", StringComparison.Ordinal))
        {
            if (reservation is { } rid) await ReservationService.ReleaseAsync(h.C, h.Tx, rid, "SUPERSEDED", h.Actor.UserId, today, h.Ct).ConfigureAwait(false);
            await UtilizationAsync(h, lc, null, "CANCELLED by amendment", a.LcAmendmentId).ConfigureAwait(false);
            await h.C.ExecuteAsync(new CommandDefinition(
                """
                UPDATE lc.LetterOfCredit SET Status = 'CANCELLED', ClosedOn = @d, ClosedReason = 'Cancelled by amendment', UndrawnReleasedOn = ISNULL(UndrawnReleasedOn, @d),
                       AmendmentNo = @no, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
                 WHERE LetterOfCreditId = @lc;
                """, new { d = today, no = a.AmendmentNo, u = h.Actor.UserId, lc = lc.LetterOfCreditId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
            await Outbox.EmitAsync(h.C, h.Tx, "lc.cancelled", "lc.LetterOfCredit", lc.LetterOfCreditId, new { lc = lc.LetterOfCreditId }, h.Ct).ConfigureAwait(false);
        }
        else
        {
            // The credit's next ISSUED terms are the amendment's, and its header follows them.
            var version = await h.C.ExecuteScalarAsync<int>(new CommandDefinition("SELECT VersionNo FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = lc.CurrentTermsId }, h.Tx,
                cancellationToken: h.Ct)).ConfigureAwait(false);
            await h.C.ExecuteAsync(new CommandDefinition("UPDATE lc.LcTerms SET Status = 'SUPERSEDED' WHERE LcTermsId = @t;", new { t = lc.CurrentTermsId }, h.Tx,
                cancellationToken: h.Ct)).ConfigureAwait(false);
            var issued = await TermsStore.CopyAsync(h.C, h.Tx, a.TermsId, "LETTER_OF_CREDIT", lc.LetterOfCreditId, "ISSUED", version + 1, "LOCKED", h.Ct, lc.CurrentTermsId)
                .ConfigureAwait(false);
            var terms = await h.C.QuerySingleAsync<(decimal Amount, DateTime? Expiry, DateTime? Ship)>(new CommandDefinition(
                "SELECT Amount, ExpiryDate, LatestShipmentDate FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = issued }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
            if (reservation is { } rid) await ReservationService.ReleaseAsync(h.C, h.Tx, rid, "SUPERSEDED", h.Actor.UserId, today, h.Ct).ConfigureAwait(false);
            if (a.AmountDelta != 0) await UtilizationAsync(h, lc, a.AmountDelta, "AMENDMENT", a.LcAmendmentId).ConfigureAwait(false);
            await h.C.ExecuteAsync(new CommandDefinition(
                """
                UPDATE lc.LetterOfCredit SET CurrentTermsId = @t, Amount = @amount, ExposureAmount = ISNULL(ExposureAmount, Amount) + @delta, ExpiryDate = ISNULL(@exp, ExpiryDate),
                       LatestShipmentDate = @ship, AmendmentNo = @no, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
                 WHERE LetterOfCreditId = @lc;
                """, new { t = issued, amount = terms.Amount, delta = a.AmountDelta, exp = terms.Expiry, ship = terms.Ship, no = a.AmendmentNo, u = h.Actor.UserId, lc = lc.LetterOfCreditId },
                h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        }
        await h.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcAmendment SET Status = 'APPLIED', AppliedOn = SYSUTCDATETIME(), AppliedBy = @u, ReservationDeltaApplied = @d, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LcAmendmentId = @a;
            """, new { u = h.Actor.UserId, d = a.AmountDelta, a = a.LcAmendmentId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Notifier.RequestAsync(h.C, h.Tx, new NotificationRequest("LC.AMENDED", "lc.LetterOfCredit", lc.LetterOfCreditId, $"LC.AMENDED:{a.LcAmendmentId}", lc.CompanyId,
            new Dictionary<string, object?> { ["lcNo"] = lc.LcNumber, ["requestNo"] = h.Request.RequestNo }, $"/lcs/{lc.LetterOfCreditId}", h.Actor.UserId), h.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "lc.amended", "lc.LetterOfCredit", lc.LetterOfCreditId, new { lc = lc.LetterOfCreditId, amendment = a.LcAmendmentId }, h.Ct).ConfigureAwait(false);
        return new { applied = true, delta = a.AmountDelta };
    }

    /// <summary>The credit's utilisation moves by the delta (an ADJUST), or is released (a null delta), with its movement.</summary>
    private static async Task UtilizationAsync(RequestEngine.HookContext h, Lc lc, decimal? delta, string reason, long amendmentId)
    {
        if (lc.UtilizationId is not { } u) return;
        var amount = await h.C.ExecuteScalarAsync<decimal?>(new CommandDefinition(
            "SELECT Amount FROM fac.Utilization WITH (UPDLOCK) WHERE UtilizationId = @u AND Status = 'ACTIVE';", new { u }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        if (amount is not { } before) return;
        var after = delta is { } d ? Math.Max(0, before + d) : 0;
        await h.C.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fac.Utilization SET Amount = CASE WHEN @after = 0 THEN Amount ELSE @after END, Status = CASE WHEN @after = 0 THEN 'RELEASED' ELSE Status END,
                   ReleasedOn = CASE WHEN @after = 0 THEN @d ELSE NULL END, ReleaseReason = CASE WHEN @after = 0 THEN @reason END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @a
             WHERE UtilizationId = @u;
            INSERT fac.LimitMovement (TenantId, FacilityId, TargetKind, UtilizationId, OpKind, CurrencyId, RequestedDelta, AppliedDelta, AmountBefore, AmountAfter, Reason,
                                      IdempotencyKey, ActorUserId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, 'UTILIZATION', @u, CASE WHEN @after = 0 THEN 'RELEASE' ELSE 'ADJUST' END, @cur, @delta, @delta, @before, @after,
                    @reason, @key, @a);
            """,
            new
            {
                after, d = h.Now.UtcDateTime.Date, reason, a = h.Actor.UserId, u, f = lc.FacilityId, cur = lc.CurrencyId, delta = after - before, before,
                key = $"amd:{amendmentId}:util",
            }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, after == 0 ? "utilization.released" : "utilization.adjusted", "fac.Utilization", u, new { utilization = u }, h.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "limit.availability.changed", "fac.Facility", lc.FacilityId!.Value, new { facility = lc.FacilityId }, h.Ct).ConfigureAwait(false);
    }
}
