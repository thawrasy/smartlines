using System.Text.Json;
using BankFas.Data.Notifications;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>
/// The issuance of a purchase letter of credit (spec 13 BR-WFL-018; spec 14 FR-LCI-011, 012; S3 batch F). On leaving the
/// ISSUANCE stage, in the transaction of the action and in this order: fac.convert_reservation turns the request's
/// reservation into a utilisation of the same line (SourceType LC) for the issued exposure, which may not exceed the
/// reservation (V-LCI-02, OQ-3); lc.record_issuance writes the ISSUED terms as a locked copy of the application, the
/// LetterOfCredit with that utilisation as its only link to the limit, and the request's pointer to it. A failure of
/// either rolls both back; a replay finds the conversion and the credit already there (one per request, M16).
/// The issuance details (number, date, bank) come from the lc.issuance form, held in the request's form data.
/// </summary>
public static class IssuanceHooks
{
    public sealed record Issuance(string LcNumber, DateTime IssueDate, long InstitutionId, string? BankReference, string? IssuingBranch, decimal? IssuedAmount);

    public static async Task<Issuance> IssuanceAsync(SqlConnection c, SqlTransaction tx, RequestEngine.RequestRow r, CancellationToken ct)
    {
        using var doc = JsonDocument.Parse(r.FormDataJson ?? "{}");
        if (!doc.RootElement.TryGetProperty("issuance", out var i) || i.ValueKind != JsonValueKind.Object)
            throw WorkflowRefusalException.Missing("V-LCI-ISSUANCE", "Record the issuance first: the bank's letter of credit number and the issue date.");
        string? S(string k) => i.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;
        var number = S("lcNumber") ?? throw WorkflowRefusalException.Missing("V-LCI-ISSUANCE", "The letter of credit number is required.");
        var date = DateTime.TryParse(S("issueDate"), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var d) ? d.Date
            : throw WorkflowRefusalException.Missing("V-LCI-ISSUANCE", "The issue date is required.");
        var institution = i.TryGetProperty("institutionId", out var inst) && inst.ValueKind == JsonValueKind.Number ? inst.GetInt64()
            : throw WorkflowRefusalException.Missing("V-LCI-ISSUANCE", "The issuing bank is required.");
        decimal? issued = i.TryGetProperty("issuedAmount", out var ia) && ia.ValueKind == JsonValueKind.Number ? ia.GetDecimal() : null;
        await Task.CompletedTask.ConfigureAwait(false);
        return new Issuance(number.Trim(), date, institution, S("bankReference"), S("issuingBranch"), issued);
    }

    /// <summary>BR-LCI-016: the bank's number trimmed, in capital Latin letters, without spaces; dashes are kept.</summary>
    public static string Normalise(string number)
    {
        var b = new System.Text.StringBuilder(number.Length);
        foreach (var ch in number.Normalize(System.Text.NormalizationForm.FormKC))
        {
            if (ch is >= '٠' and <= '٩') b.Append((char)('0' + (ch - '٠')));
            else if (!char.IsWhiteSpace(ch)) b.Append(char.ToUpperInvariant(ch));
        }
        return b.ToString();
    }

    /// <summary>fac.convert_reservation: the active reservation becomes CONVERTED into a new utilisation of the issued exposure.</summary>
    public static async Task<object?> ConvertAsync(RequestEngine.HookContext h)
    {
        var res = await h.C.QuerySingleOrDefaultAsync<(long Id, long FacilityId, long LimitId, long? LineId, long CompanyId, decimal Amount, int CurrencyId, decimal? Rate)?>(
            new CommandDefinition(
                """
                SELECT LimitReservationId, FacilityId, LimitId, LimitProductLineId, CompanyId, Amount, CurrencyId, RateToFacilityCcy
                  FROM fac.LimitReservation WITH (UPDLOCK, HOLDLOCK) WHERE RequestId = @r AND Status = 'ACTIVE';
                """, new { r = h.Request.RequestId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        if (res is not { } rv)
        {
            var done = await h.C.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT ConvertedUtilizationId FROM fac.LimitReservation WHERE RequestId = @r AND Status = 'CONVERTED';", new { r = h.Request.RequestId }, h.Tx, cancellationToken: h.Ct))
                .ConfigureAwait(false);
            return done is { } u ? new { utilizationId = u, replay = true }
                : throw new WorkflowRefusalException(409, "RESERVATION_NOT_ACTIVE", "The request has no active reservation to convert (BR-WFL-018).");
        }
        // Lock the facility first, as every writer of reservations and utilisations does (DQ-F11-1).
        await h.C.ExecuteAsync(new CommandDefinition("SELECT FacilityId FROM fac.Facility WITH (UPDLOCK, HOLDLOCK) WHERE FacilityId = @f;", new { f = rv.FacilityId }, h.Tx,
            cancellationToken: h.Ct)).ConfigureAwait(false);
        var issuance = await IssuanceAsync(h.C, h.Tx, h.Request, h.Ct).ConfigureAwait(false);
        var amount = issuance.IssuedAmount ?? rv.Amount;
        if (amount > rv.Amount)
            throw new WorkflowRefusalException(422, "V-LCI-02", "The issued exposure is above the reserved one; return the request to the treasury manager's approval (BR-LCI-007).");
        if (amount <= 0) throw WorkflowRefusalException.Missing("V-LCI-02", "The issued exposure is above zero.");
        // FR-LCI-010: the bank's receipt of the execution comes before the issuance while the tenant requires it.
        if ((await Workflow.FacilityHooks.SettingsAsync(h.C, h.Tx, h.Ct, "lc.execution.require_receipt").ConfigureAwait(false)).GetValueOrDefault("lc.execution.require_receipt") != "false")
        {
            using var form = JsonDocument.Parse(h.Request.FormDataJson ?? "{}");
            if (!form.RootElement.TryGetProperty("execution", out var ex) || !ex.TryGetProperty("receiptDocument", out var rd) || rd.ValueKind != JsonValueKind.String)
                throw WorkflowRefusalException.Missing("V-LCI-RECEIPT", "Record the bank's receipt of the execution first (FR-LCI-010).");
        }
        var maturity = await h.C.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
            "SELECT ExpiryDate FROM lc.LcTerms WHERE OwnerType = 'REQUEST' AND OwnerId = @r AND Purpose = 'APPLICATION' AND Status = 'LOCKED';", new { r = h.Request.RequestId }, h.Tx,
            cancellationToken: h.Ct)).ConfigureAwait(false);
        var util = await h.C.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT fac.Utilization (TenantId, FacilityId, LimitId, LimitProductLineId, CompanyId, Reference, Description, Amount, CurrencyId, RateToFacilityCcy, StartDate,
                                    MaturityDate, SourceType, CreatedBy)
            OUTPUT inserted.UtilizationId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, @l, @ln, @co, @ref, @desc, @a, @cur, @rate, @start, @mat, 'LC', @u);
            DECLARE @id BIGINT = (SELECT Id FROM @o);
            UPDATE fac.LimitReservation SET Status = 'CONVERTED', ConvertedUtilizationId = @id WHERE LimitReservationId = @res AND Status = 'ACTIVE';
            INSERT fac.LimitMovement (TenantId, FacilityId, TargetKind, LimitReservationId, OpKind, CurrencyId, RequestedDelta, AppliedDelta, AmountBefore, AmountAfter, Reason,
                                      IdempotencyKey, ActorUserId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, 'RESERVATION', @res, 'CONVERT', @cur, -@resAmount, -@resAmount, @resAmount, 0, @ref, @key + ':res', @u);
            INSERT fac.LimitMovement (TenantId, FacilityId, TargetKind, UtilizationId, OpKind, CurrencyId, RequestedDelta, AppliedDelta, AmountBefore, AmountAfter, Reason,
                                      IdempotencyKey, ActorUserId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, 'UTILIZATION', @id, 'CREATE', @cur, @a, @a, 0, @a, @ref, @key + ':util', @u);
            SELECT @id;
            """,
            new
            {
                f = rv.FacilityId, l = rv.LimitId, ln = rv.LineId, co = rv.CompanyId, @ref = issuance.LcNumber, desc = h.Request.RequestNo, a = amount, cur = rv.CurrencyId,
                rate = rv.Rate, start = issuance.IssueDate, mat = maturity is { } m && m >= issuance.IssueDate ? m : (DateTime?)null, res = rv.Id, resAmount = rv.Amount,
                key = $"res:{rv.Id}:convert", u = h.Actor.UserId,
            }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "reservation.converted", "fac.LimitReservation", rv.Id, new { reservation = rv.Id, utilization = util }, h.Ct).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "limit.availability.changed", "fac.Facility", rv.FacilityId, new { facility = rv.FacilityId }, h.Ct).ConfigureAwait(false);
        return new { utilizationId = util, amount };
    }

    /// <summary>lc.record_issuance: the ISSUED terms, the LetterOfCredit on the converted utilisation, and the request's pointer to it; LC.ISSUED to the requester.</summary>
    public static async Task<object?> RecordAsync(RequestEngine.HookContext h)
    {
        if (await h.C.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT LetterOfCreditId FROM lc.LetterOfCredit WHERE RequestId = @r;", new { r = h.Request.RequestId }, h.Tx,
                cancellationToken: h.Ct)).ConfigureAwait(false) is { } existing)
            return new { lcId = existing, replay = true };
        var issuance = await IssuanceAsync(h.C, h.Tx, h.Request, h.Ct).ConfigureAwait(false);
        var app = await TermsStore.CurrentAsync(h.C, h.Tx, h.Request.RequestId, h.Ct).ConfigureAwait(false);
        if (app is not { Status: "LOCKED" }) throw WorkflowRefusalException.State("The request's terms are not locked.");
        var util = await h.C.QuerySingleOrDefaultAsync<(long Id, long FacilityId, long LimitId, long? LineId, decimal Amount)?>(new CommandDefinition(
            """
            SELECT u.UtilizationId, u.FacilityId, u.LimitId, u.LimitProductLineId, u.Amount FROM fac.LimitReservation AS r
              JOIN fac.Utilization AS u ON u.UtilizationId = r.ConvertedUtilizationId WHERE r.RequestId = @r AND r.Status = 'CONVERTED';
            """, new { r = h.Request.RequestId }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false)
            ?? throw WorkflowRefusalException.State("The reservation is not converted (BR-WFL-018).");
        var normalised = Normalise(issuance.LcNumber);
        if (await h.C.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM lc.LetterOfCredit WHERE LcClass = 'PURCHASE' AND InstitutionId = @i AND LcNumberNormalized = @n;", new { i = issuance.InstitutionId, n = normalised },
                h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false) > 0)
            throw new WorkflowRefusalException(409, "V-LCI-01", "This bank already has a letter of credit with this number (BR-LCI-016).");
        var cols = (await h.C.QueryAsync<string>(new CommandDefinition(
            """
            SELECT name FROM sys.columns WHERE object_id = OBJECT_ID(N'lc.LcTerms') AND is_computed = 0 AND system_type_id <> 189
               AND name NOT IN ('LcTermsId', 'PublicId', 'OwnerType', 'OwnerId', 'Purpose', 'VersionNo', 'Status', 'SnapshotHash', 'TreasuryHash', 'LockedAt', 'LockedBy',
                                'SupersedesTermsId', 'CopiedFromTermsId', 'CreatedAt', 'CreatedBy', 'UpdatedAt', 'UpdatedBy', 'ChangeReason');
            """, transaction: h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false)).Select(n => $"[{n}]").ToList();
        var lc = await h.C.ExecuteScalarAsync<long>(new CommandDefinition(
            $"""
            DECLARE @t TABLE (Id BIGINT);
            INSERT lc.LcTerms ({string.Join(", ", cols)}, OwnerType, Purpose, VersionNo, Status, CopiedFromTermsId, CreatedBy)
            OUTPUT inserted.LcTermsId INTO @t
            SELECT {string.Join(", ", cols)}, 'LETTER_OF_CREDIT', 'ISSUED', 1, 'DRAFT', LcTermsId, @u FROM lc.LcTerms WHERE LcTermsId = @app;
            DECLARE @issued BIGINT = (SELECT Id FROM @t);
            INSERT lc.LcTermsDocument (TenantId, LcTermsId, SeqNo, ClauseId, ClauseVersion, Originals, Copies, ParamsJson, RenderedTextEn, RenderedTextAr, IsFreeText, [FreeText], CreatedBy)
            SELECT TenantId, @issued, SeqNo, ClauseId, ClauseVersion, Originals, Copies, ParamsJson, RenderedTextEn, RenderedTextAr, IsFreeText, [FreeText], @u
              FROM lc.LcTermsDocument WHERE LcTermsId = @app;
            INSERT lc.LcChargesMatrix (TenantId, LcTermsId, ChargeCategory, Payer, ApplicantSharePct, PresetCode, Note, CreatedBy)
            SELECT TenantId, @issued, ChargeCategory, Payer, ApplicantSharePct, PresetCode, Note, @u FROM lc.LcChargesMatrix WHERE LcTermsId = @app;
            UPDATE lc.LcTerms SET Status = 'LOCKED', SnapshotHash = (SELECT SnapshotHash FROM lc.LcTerms WHERE LcTermsId = @app), LockedAt = SYSUTCDATETIME(), LockedBy = @u
             WHERE LcTermsId = @issued;
            DECLARE @l TABLE (Id BIGINT);
            INSERT lc.LetterOfCredit (TenantId, LcClass, Scope, CompanyId, LcNumber, LcNumberNormalized, InternalRef, Status, CounterpartyId, InstitutionId, IssuingBranch,
                                      BankReference, Channel, ProductId, FacilityId, LimitId, LimitProductLineId, UtilizationId, RequestId, CurrentTermsId, CurrencyId, Amount,
                                      OriginalAmount, TolerancePlusPct, ToleranceMinusPct, ExposureAmount, MarginPct, IssueDate, ExpiryDate, LatestShipmentDate, CreatedBy)
            OUTPUT inserted.LetterOfCreditId INTO @l
            SELECT t.TenantId, 'PURCHASE', t.Scope, r.CompanyId, @no, @norm, r.RequestNo, 'ACTIVE', t.BeneficiaryCounterpartyId, @inst, @branch, @bankRef, r.ExecutionChannel,
                   pl.ProductId, @f, @lim, @line, @util, r.RequestId, @issued, t.CurrencyId, t.Amount, t.Amount, t.TolerancePlusPct, t.ToleranceMinusPct,
                   CASE WHEN @exposure < t.Amount THEN t.Amount ELSE @exposure END, t.MarginPct, @issueDate,
                   ISNULL(t.ExpiryDate, DATEADD(DAY, t.ExpiryDaysAfterIssue, @issueDate)), ISNULL(t.LatestShipmentDate, DATEADD(DAY, t.LatestShipmentDaysAfterIssue, @issueDate)), @u
              FROM lc.LcTerms AS t JOIN wfl.Request AS r ON r.RequestId = @r LEFT JOIN fac.LimitProductLine AS pl ON pl.LimitProductLineId = @line
             WHERE t.LcTermsId = @issued;
            DECLARE @lcId BIGINT = (SELECT Id FROM @l);
            UPDATE lc.LcTerms SET OwnerId = @lcId WHERE LcTermsId = @issued AND OwnerId IS NULL;
            UPDATE wfl.Request SET LcId = @lcId WHERE RequestId = @r;
            SELECT @lcId;
            """,
            new
            {
                u = h.Actor.UserId, app = app.LcTermsId, no = issuance.LcNumber, norm = normalised, inst = issuance.InstitutionId, branch = issuance.IssuingBranch,
                bankRef = issuance.BankReference, f = util.FacilityId, lim = util.LimitId, line = util.LineId, util = util.Id, r = h.Request.RequestId,
                exposure = util.Amount, issueDate = issuance.IssueDate,
            }, h.Tx, cancellationToken: h.Ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(h.C, h.Tx, "lc.issued", "lc.LetterOfCredit", lc, new { lcId = lc, requestId = h.Request.RequestId }, h.Ct).ConfigureAwait(false);
        await Notifier.RequestAsync(h.C, h.Tx, new NotificationRequest("LC.ISSUED", "lc.LetterOfCredit", lc, $"LC.ISSUED:{lc}", h.Request.CompanyId,
            new Dictionary<string, object?>
            {
                ["lcNo"] = issuance.LcNumber, ["requestNo"] = h.Request.RequestNo, ["amount"] = h.Request.Amount?.ToString("N2", System.Globalization.CultureInfo.InvariantCulture),
                ["currency"] = h.Request.CurrencyCode,
            }, $"/requests/{h.Request.PublicId}", h.Actor.UserId, [h.Request.RequesterUserId]), h.Ct).ConfigureAwait(false);
        return new { lcId = lc };
    }
}
