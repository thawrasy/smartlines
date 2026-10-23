using BankFas.Data.Calendar;
using BankFas.Data.Notifications;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Lc;

/// <summary>A presentation of documents under a purchase credit (FR-LCI-023): its amount, date, the bank's advice and the basis date of a deferred tenor.</summary>
public sealed record NewDrawing(decimal Amount, DateTime PresentationDate, string? BankAdviceRef, DateTime? MaturityBasisDate, string? Notes, string? OverrideReason);

/// <summary>
/// The life of an issued purchase letter of credit after its issuance (spec 14 section 5.4; S3 batches F and G): the
/// drawings and their settlement against the credit's utilisation, the manual close and the expiry. The utilisation
/// (fac.Utilization, created by the conversion) is the credit's outstanding exposure: a settlement lowers it by the
/// amount paid, and the close or the expiry releases what is not drawn (BR-LCI-009), each with its LimitMovement in the
/// same transaction. The facility row is locked first, as for every writer of reservations and utilisations (DQ-F11-1).
/// </summary>
public static class LcStore
{
    private sealed class Lc
    {
        public long LetterOfCreditId { get; init; }
        public long CompanyId { get; init; }
        public string Status { get; init; } = "";
        public string LcNumber { get; init; } = "";
        public int CurrencyId { get; init; }
        public decimal Amount { get; init; }
        public decimal? ExposureAmount { get; init; }
        public decimal DrawnAmount { get; init; }
        public decimal SettledAmount { get; init; }
        public DateTime ExpiryDate { get; init; }
        public long? FacilityId { get; init; }
        public long? UtilizationId { get; init; }
        public long? RequestId { get; init; }
        public long CurrentTermsId { get; init; }
    }

    private static async Task<Lc> LockAsync(SqlConnection c, SqlTransaction tx, long lcId, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<Lc>(new CommandDefinition(
            """
            SELECT LetterOfCreditId, CompanyId, Status, LcNumber, CurrencyId, Amount, ExposureAmount, DrawnAmount, SettledAmount, ExpiryDate, FacilityId, UtilizationId,
                   RequestId, CurrentTermsId
              FROM lc.LetterOfCredit WITH (UPDLOCK, HOLDLOCK) WHERE LetterOfCreditId = @id AND LcClass = 'PURCHASE';
            """, new { id = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false)
        ?? throw new WorkflowRefusalException(404, "NOT_FOUND", "The letter of credit does not exist or is not visible to you.");

    private static async Task LockFacilityAsync(SqlConnection c, SqlTransaction tx, long? facility, CancellationToken ct)
    {
        if (facility is { } f)
            await c.ExecuteAsync(new CommandDefinition("SELECT FacilityId FROM fac.Facility WITH (UPDLOCK, HOLDLOCK) WHERE FacilityId = @f;", new { f }, tx, cancellationToken: ct))
                .ConfigureAwait(false);
    }

    /// <summary>
    /// Records a presentation (FR-LCI-023, BR-LCI-013): on an ACTIVE credit, or an EXPIRED one with the treasury manager's
    /// written override (V-LCI-06); the drawn total stays within the exposure (V-LCI-05). The examination deadline is the
    /// presentation date plus lc.drawing.exam_banking_days working days of the tenant's calendar; a deferred or acceptance
    /// tenor gives the maturity from its basis date (BR-LCT-009). LC.DRAWING_RECORDED goes to the company's holders.
    /// </summary>
    public static async Task<(long Id, int DrawingNo)> RecordDrawingAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, NewDrawing d, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        ArgumentNullException.ThrowIfNull(d);
        if (!actor.Permissions.Contains("lc.drawing.record")) throw WorkflowRefusalException.Forbidden("You may not record drawings.");
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        if (lc.Status == "EXPIRED")
        {
            if (!actor.Permissions.Contains("req.treasury.approve") || string.IsNullOrWhiteSpace(d.OverrideReason))
                throw WorkflowRefusalException.Missing("V-LCI-06", "A presentation after the expiry needs the treasury manager's written reason.");
        }
        else if (lc.Status != "ACTIVE") throw WorkflowRefusalException.State("The letter of credit is closed.");
        if (d.Amount <= 0) throw WorkflowRefusalException.Missing("V-LCI-05", "The drawing is above zero.");
        var cap = lc.ExposureAmount ?? lc.Amount;
        if (lc.DrawnAmount + d.Amount > cap)
            throw WorkflowRefusalException.Missing("V-LCI-05", $"The drawings would exceed the credit's exposure ({lc.DrawnAmount + d.Amount:N2} above {cap:N2}).");
        var terms = await c.QuerySingleAsync<(string? LcType, int? DeferralDays)>(new CommandDefinition(
            "SELECT LcType, DeferralDays FROM lc.LcTerms WHERE LcTermsId = @t;", new { t = lc.CurrentTermsId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        DateTime? maturity = null;
        if (terms.LcType is "DEFERRED_PAYMENT" or "ACCEPTANCE" && terms.DeferralDays is { } days)
            maturity = (d.MaturityBasisDate ?? throw WorkflowRefusalException.Missing("V-LCI-05", "A deferred credit's drawing gives the date its tenor runs from.")).AddDays(days);
        var settings = await FacilityHooks.SettingsAsync(c, tx, ct, "lc.drawing.exam_banking_days").ConfigureAwait(false);
        var exam = int.TryParse(settings.GetValueOrDefault("lc.drawing.exam_banking_days"), out var e) ? e : 5;
        var tt = await RequestEngine.TimeAsync(c, tx, ct).ConfigureAwait(false);
        var from = DateOnly.FromDateTime(d.PresentationDate);
        var cal = await WorkingCalendar.LoadAsync(c, tx, tt.CountryId, from, from.AddDays(exam * 3 + 30), ct).ConfigureAwait(false);
        var deadline = cal.AddWorkingDays(from, exam).ToDateTime(TimeOnly.MinValue);
        var no = await c.ExecuteScalarAsync<int>(new CommandDefinition("SELECT ISNULL(MAX(DrawingNo), 0) + 1 FROM lc.LcDrawing WHERE LcId = @lc;", new { lc = lcId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        var id = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT lc.LcDrawing (TenantId, CompanyId, LcId, DrawingNo, Amount, CurrencyId, PresentationDate, BankAdviceRef, Status, MaturityBasisDate, MaturityDate,
                                 ExaminationDeadline, OverrideReason, Notes, CreatedBy)
            OUTPUT inserted.LcDrawingId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @co, @lc, @no, @a, @cur, @p, @adv, 'PRESENTED', @basis, @mat, @exam, @ovr, @notes, @u);
            UPDATE lc.LetterOfCredit SET DrawnAmount = DrawnAmount + @a, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LetterOfCreditId = @lc;
            SELECT Id FROM @o;
            """,
            new
            {
                co = lc.CompanyId, lc = lcId, no, a = d.Amount, cur = lc.CurrencyId, p = d.PresentationDate.Date, adv = d.BankAdviceRef, basis = d.MaturityBasisDate?.Date, mat = maturity,
                exam = deadline, ovr = lc.Status == "EXPIRED" ? d.OverrideReason : null, notes = d.Notes, u = actor.UserId,
            }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Notifier.RequestAsync(c, tx, new NotificationRequest("LC.DRAWING_RECORDED", "lc.LetterOfCredit", lcId, $"LC.DRAWING_RECORDED:{lcId}:{no}", lc.CompanyId,
            new Dictionary<string, object?> { ["lcNo"] = lc.LcNumber, ["drawingNo"] = no }, $"/lcs/{lcId}", actor.UserId), ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "lc.drawing.recorded", "lc.LetterOfCredit", lcId, new { lc = lcId, drawing = id }, ct).ConfigureAwait(false);
        return (id, no);
    }

    /// <summary>The bank's decision on a presentation (BR-LCI-013): ACCEPTED, DISCREPANT, REFUSED or CANCELLED; a refused or cancelled one leaves the drawn total.</summary>
    public static async Task DecideDrawingAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, int drawingNo, string status, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.drawing.record")) throw WorkflowRefusalException.Forbidden("You may not record drawings.");
        if (status is not ("ACCEPTED" or "DISCREPANT" or "REFUSED" or "CANCELLED")) throw WorkflowRefusalException.Missing("V-LCI-05", "The status is ACCEPTED, DISCREPANT, REFUSED or CANCELLED.");
        await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        var dr = await c.QuerySingleOrDefaultAsync<(long Id, string Status, decimal Amount, decimal Settled)?>(new CommandDefinition(
            "SELECT LcDrawingId, Status, Amount, SettledAmount FROM lc.LcDrawing WITH (UPDLOCK) WHERE LcId = @lc AND DrawingNo = @no;", new { lc = lcId, no = drawingNo }, tx,
            cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (dr.Status is not ("PRESENTED" or "DISCREPANT" or "ACCEPTED")) throw WorkflowRefusalException.State("The drawing is settled, refused or cancelled.");
        if (status is "REFUSED" or "CANCELLED" && dr.Settled > 0) throw WorkflowRefusalException.State("A drawing with a payment is not refused.");
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcDrawing SET Status = @s, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LcDrawingId = @id;
            IF @s IN ('REFUSED', 'CANCELLED')
                UPDATE lc.LetterOfCredit SET DrawnAmount = DrawnAmount - @a, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LetterOfCreditId = @lc;
            """, new { s = status, u = actor.UserId, id = dr.Id, a = dr.Amount, lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
    }

    /// <summary>
    /// A payment of an accepted presentation (FR-LCI-023): the settled amount within the drawing; SETTLED when paid in
    /// full. The utilisation falls by the payment (an ADJUST movement), and is RELEASED at zero.
    /// </summary>
    public static async Task SettleDrawingAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, int drawingNo, decimal amount, DateTime on, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.drawing.record")) throw WorkflowRefusalException.Forbidden("You may not record drawings.");
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        await LockFacilityAsync(c, tx, lc.FacilityId, ct).ConfigureAwait(false);
        var dr = await c.QuerySingleOrDefaultAsync<(long Id, string Status, decimal Amount, decimal Settled)?>(new CommandDefinition(
            "SELECT LcDrawingId, Status, Amount, SettledAmount FROM lc.LcDrawing WITH (UPDLOCK) WHERE LcId = @lc AND DrawingNo = @no;", new { lc = lcId, no = drawingNo }, tx,
            cancellationToken: ct)).ConfigureAwait(false) ?? throw WorkflowRefusalException.NotFound();
        if (dr.Status != "ACCEPTED") throw WorkflowRefusalException.State("Only an accepted presentation is paid.");
        if (amount <= 0 || dr.Settled + amount > dr.Amount) throw WorkflowRefusalException.Missing("V-LCI-05", "The payment is above zero and within the drawing.");
        var full = dr.Settled + amount == dr.Amount;
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LcDrawing SET SettledAmount = SettledAmount + @a, LastSettledOn = @on, Status = CASE WHEN @full = 1 THEN 'SETTLED' ELSE Status END,
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LcDrawingId = @id;
            UPDATE lc.LetterOfCredit SET SettledAmount = SettledAmount + @a, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE LetterOfCreditId = @lc;
            """, new { a = amount, on = on.Date, full, u = actor.UserId, id = dr.Id, lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await ReduceUtilizationAsync(c, tx, lc, amount, "SETTLEMENT", $"lc:{lcId}:draw:{drawingNo}:settle:{dr.Settled + amount}", actor.UserId, on, ct).ConfigureAwait(false);
    }

    /// <summary>The manual close (BR-LCI-009, lc.close): no presentation waiting for payment; the undrawn exposure is released with the utilisation.</summary>
    public static async Task CloseAsync(SqlConnection c, SqlTransaction tx, Actor actor, long lcId, string reason, DateTime on, CancellationToken ct)
    {
        ArgumentNullException.ThrowIfNull(actor);
        if (!actor.Permissions.Contains("lc.close")) throw WorkflowRefusalException.Forbidden("You may not close letters of credit.");
        if (string.IsNullOrWhiteSpace(reason)) throw WorkflowRefusalException.Missing("V-WFL-REASON", "A close gives its reason.");
        var lc = await LockAsync(c, tx, lcId, ct).ConfigureAwait(false);
        if (lc.Status is "CLOSED" or "CANCELLED") throw WorkflowRefusalException.State("The letter of credit is closed.");
        await LockFacilityAsync(c, tx, lc.FacilityId, ct).ConfigureAwait(false);
        var open = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM lc.LcDrawing WHERE LcId = @lc AND Status IN ('PRESENTED', 'DISCREPANT', 'ACCEPTED');", new { lc = lcId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        if (open > 0) throw WorkflowRefusalException.State("A presentation of the credit waits for its payment or decision.");
        await ReleaseUtilizationAsync(c, tx, lc, "CLOSED: " + reason.Trim(), actor.UserId, on, ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE lc.LetterOfCredit SET Status = 'CLOSED', ClosedOn = @on, ClosedReason = @reason, UndrawnReleasedOn = ISNULL(UndrawnReleasedOn, @on),
                   UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u
             WHERE LetterOfCreditId = @lc;
            """, new { on = on.Date, reason = reason.Trim().Length > 500 ? reason.Trim()[..500] : reason.Trim(), u = actor.UserId, lc = lcId }, tx, cancellationToken: ct))
            .ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "lc.closed", "lc.LetterOfCredit", lcId, new { lc = lcId }, ct).ConfigureAwait(false);
    }

    /// <summary>
    /// JOB-LC-EXPIRY (BR-LCI-009, 015): an ACTIVE credit past its expiry date is EXPIRED; when lc.auto_release_on_expiry
    /// holds, its utilisation keeps only what is drawn and not yet paid (the rest is released, all of it when nothing is
    /// pending); an expired credit not closed is reminded every lc.expired.reminder_days (LC.EXPIRED_UNCLOSED).
    /// </summary>
    public static async Task<(int Expired, int Reminded)> ExpireAsync(SqlConnection c, DateTime today, long actor, CancellationToken ct)
    {
        var s = await FacilityHooks.SettingsAsync(c, null, ct, "lc.auto_release_on_expiry", "lc.expired.reminder_days").ConfigureAwait(false);
        var release = s.GetValueOrDefault("lc.auto_release_on_expiry") != "false";
        var every = int.TryParse(s.GetValueOrDefault("lc.expired.reminder_days"), out var r) ? r : 7;
        var due = (await c.QueryAsync<long>(new CommandDefinition(
            "SELECT LetterOfCreditId FROM lc.LetterOfCredit WHERE LcClass = 'PURCHASE' AND Status = 'ACTIVE' AND ExpiryDate < @today;", new { today }, cancellationToken: ct))
            .ConfigureAwait(false)).ToList();
        var expired = 0;
        foreach (var id in due)
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            var lc = await LockAsync(c, tx, id, ct).ConfigureAwait(false);
            if (lc.Status != "ACTIVE") { await tx.RollbackAsync(ct).ConfigureAwait(false); continue; }
            await LockFacilityAsync(c, tx, lc.FacilityId, ct).ConfigureAwait(false);
            if (release)
            {
                var pending = lc.DrawnAmount - lc.SettledAmount;
                if (pending <= 0) await ReleaseUtilizationAsync(c, tx, lc, "EXPIRED", actor, today, ct).ConfigureAwait(false);
                else await ReduceToAsync(c, tx, lc, pending, $"lc:{id}:expiry", actor, today, ct).ConfigureAwait(false);
            }
            await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE lc.LetterOfCredit SET Status = 'EXPIRED', UndrawnReleasedOn = CASE WHEN @release = 1 THEN @today ELSE UndrawnReleasedOn END, UpdatedAt = SYSUTCDATETIME()
                 WHERE LetterOfCreditId = @id;
                """, new { release, today, id }, tx, cancellationToken: ct)).ConfigureAwait(false);
            await Outbox.EmitAsync(c, tx, "lc.expired", "lc.LetterOfCredit", id, new { lc = id }, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
            expired++;
        }
        var reminded = 0;
        foreach (var x in await c.QueryAsync<(long Id, long CompanyId, string LcNumber, DateTime ExpiryDate)>(new CommandDefinition(
                     "SELECT LetterOfCreditId, CompanyId, LcNumber, ExpiryDate FROM lc.LetterOfCredit WHERE LcClass = 'PURCHASE' AND Status = 'EXPIRED';", cancellationToken: ct))
                     .ConfigureAwait(false))
        {
            var since = (today - x.ExpiryDate.Date).Days;
            if (since <= 0 || (since - 1) % every != 0) continue;
            await Notifier.RequestAsync(c, null, new NotificationRequest("LC.EXPIRED_UNCLOSED", "lc.LetterOfCredit", x.Id, $"LC.EXPIRED_UNCLOSED:{x.Id}:{today:yyyyMMdd}", x.CompanyId,
                new Dictionary<string, object?> { ["lcNo"] = x.LcNumber }, $"/lcs/{x.Id}"), ct).ConfigureAwait(false);
            reminded++;
        }
        return (expired, reminded);
    }

    /// <summary>
    /// JOB-LC-RECONCILE (FR-LCI-031, 14m section 9), nightly: the cached drawn and settled totals of each purchase credit
    /// against its drawings, and the utilisation of an ACTIVE credit against its exposure less what is paid. A mismatch is
    /// reported once a day (LC.RECONCILE_MISMATCH and lc.reconcile.mismatch); nothing is corrected silently.
    /// </summary>
    public static async Task<int> ReconcileAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        var rows = await c.QueryAsync<(long Id, long CompanyId, string LcNumber, decimal Drawn, decimal Settled, decimal SumDrawn, decimal SumSettled, bool Active, decimal Expected,
            decimal? Utilized)>(new CommandDefinition(
            """
            SELECT l.LetterOfCreditId, l.CompanyId, l.LcNumber, l.DrawnAmount, l.SettledAmount,
                   ISNULL((SELECT SUM(d.Amount) FROM lc.LcDrawing AS d WHERE d.LcId = l.LetterOfCreditId AND d.Status NOT IN ('REFUSED', 'CANCELLED')), 0),
                   ISNULL((SELECT SUM(d.SettledAmount) FROM lc.LcDrawing AS d WHERE d.LcId = l.LetterOfCreditId), 0),
                   CAST(CASE WHEN l.Status = 'ACTIVE' THEN 1 ELSE 0 END AS BIT), ISNULL(l.ExposureAmount, l.Amount) - l.SettledAmount,
                   (SELECT u.Amount FROM fac.Utilization AS u WHERE u.UtilizationId = l.UtilizationId AND u.Status = 'ACTIVE')
              FROM lc.LetterOfCredit AS l WHERE l.LcClass = 'PURCHASE' AND l.Status IN ('ACTIVE', 'EXPIRED');
            """, cancellationToken: ct)).ConfigureAwait(false);
        var found = 0;
        foreach (var r in rows)
        {
            var issues = new List<string>();
            if (r.Drawn != r.SumDrawn) issues.Add("DRAWN");
            if (r.Settled != r.SumSettled) issues.Add("SETTLED");
            if (r.Active && (r.Utilized ?? 0) != Math.Max(0, r.Expected)) issues.Add("UTILIZATION");
            if (issues.Count == 0) continue;
            found++;
            await Notifier.RequestAsync(c, null, new NotificationRequest("LC.RECONCILE_MISMATCH", "lc.LetterOfCredit", r.Id, $"LC.RECONCILE_MISMATCH:{r.Id}:{today:yyyyMMdd}", r.CompanyId,
                new Dictionary<string, object?> { ["lcNo"] = r.LcNumber, ["issues"] = string.Join(", ", issues) }, $"/lcs/{r.Id}"), ct).ConfigureAwait(false);
            await Outbox.EmitAsync(c, null, "lc.reconcile.mismatch", "lc.LetterOfCredit", r.Id, new { lc = r.Id, issues }, ct).ConfigureAwait(false);
        }
        return found;
    }

    private static async Task<(long Id, decimal Amount)?> UtilizationAsync(SqlConnection c, SqlTransaction tx, Lc lc, CancellationToken ct) =>
        lc.UtilizationId is { } u
            ? await c.QuerySingleOrDefaultAsync<(long, decimal)?>(new CommandDefinition(
                "SELECT UtilizationId, Amount FROM fac.Utilization WITH (UPDLOCK) WHERE UtilizationId = @u AND Status = 'ACTIVE';", new { u }, tx, cancellationToken: ct))
                .ConfigureAwait(false)
            : null;

    private static async Task ReduceUtilizationAsync(SqlConnection c, SqlTransaction tx, Lc lc, decimal by, string reason, string key, long actor, DateTime on, CancellationToken ct)
    {
        if (await UtilizationAsync(c, tx, lc, ct).ConfigureAwait(false) is not { } u) return;
        var after = Math.Max(0, u.Amount - by);
        if (after == 0) { await ReleaseUtilizationAsync(c, tx, lc, reason, actor, on, ct).ConfigureAwait(false); return; }
        await AdjustAsync(c, tx, lc.FacilityId!.Value, u.Id, lc.CurrencyId, u.Amount, after, reason, key, actor, ct).ConfigureAwait(false);
    }

    private static async Task ReduceToAsync(SqlConnection c, SqlTransaction tx, Lc lc, decimal to, string key, long actor, DateTime on, CancellationToken ct)
    {
        if (await UtilizationAsync(c, tx, lc, ct).ConfigureAwait(false) is not { } u || u.Amount <= to) return;
        await AdjustAsync(c, tx, lc.FacilityId!.Value, u.Id, lc.CurrencyId, u.Amount, to, "EXPIRED: drawn and unpaid kept", key, actor, ct).ConfigureAwait(false);
    }

    private static async Task AdjustAsync(SqlConnection c, SqlTransaction tx, long facility, long utilization, int currency, decimal before, decimal after, string reason, string key, long actor,
        CancellationToken ct)
    {
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fac.Utilization SET Amount = @after, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE UtilizationId = @id;
            INSERT fac.LimitMovement (TenantId, FacilityId, TargetKind, UtilizationId, OpKind, CurrencyId, RequestedDelta, AppliedDelta, AmountBefore, AmountAfter, Reason,
                                      IdempotencyKey, ActorUserId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, 'UTILIZATION', @id, 'ADJUST', @cur, @d, @d, @before, @after, @reason, @key, @u);
            """, new { after, u = actor, id = utilization, f = facility, cur = currency, d = after - before, before, reason, key }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "utilization.adjusted", "fac.Utilization", utilization, new { utilization }, ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "limit.availability.changed", "fac.Facility", facility, new { facility }, ct).ConfigureAwait(false);
    }

    private static async Task ReleaseUtilizationAsync(SqlConnection c, SqlTransaction tx, Lc lc, string reason, long actor, DateTime on, CancellationToken ct)
    {
        if (await UtilizationAsync(c, tx, lc, ct).ConfigureAwait(false) is not { } u) return;
        await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE fac.Utilization SET Status = 'RELEASED', ReleasedOn = @on, ReleaseReason = @reason, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @a WHERE UtilizationId = @id;
            INSERT fac.LimitMovement (TenantId, FacilityId, TargetKind, UtilizationId, OpKind, CurrencyId, RequestedDelta, AppliedDelta, AmountBefore, AmountAfter, Reason,
                                      IdempotencyKey, ActorUserId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @f, 'UTILIZATION', @id, 'RELEASE', @cur, -@amount, -@amount, @amount, 0, @reason, @key, @a);
            """,
            new
            {
                on = on.Date, reason = reason.Length > 500 ? reason[..500] : reason, a = actor, id = u.Id, f = lc.FacilityId, cur = lc.CurrencyId, amount = u.Amount,
                key = $"util:{u.Id}:release",
            }, tx, cancellationToken: ct)).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "utilization.released", "fac.Utilization", u.Id, new { utilization = u.Id }, ct).ConfigureAwait(false);
        await Outbox.EmitAsync(c, tx, "limit.availability.changed", "fac.Facility", lc.FacilityId!.Value, new { facility = lc.FacilityId }, ct).ConfigureAwait(false);
    }
}
