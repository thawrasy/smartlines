using System.Globalization;
using BankFas.Data.Calendar;
using BankFas.Data.Jobs;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Workflow;

/// <summary>
/// JOB-WFL-SLA (FR-WFL-017 to 019, BR-WFL-012, AC-WFL-5), every 5 minutes: the SLA state of every open stage with a due
/// time and not paused. OVERDUE from the due time; AT_RISK when what is left to it is at most a fifth of the stage's
/// hours (80%), in business hours of the tenant's calendar, or calendar hours for a CALENDAR stage; ON_TRACK before.
/// Entering AT_RISK records SLA_AT_RISK and sends REQ.SLA_AT_RISK once; entering OVERDUE records SLA_BREACHED and sends
/// REQ.SLA_BREACHED, which the rules also send to the treasury manager (the escalation). An overdue stage is escalated
/// again once a working day, from the opening of the day, while it stays open (ESCALATED). The assignee and the holders
/// of the pending slots hear it.
/// </summary>
public sealed class WorkflowSlaJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-WFL-SLA";

    private sealed record Open(long RequestStageInstanceId, long RequestId, Guid PublicId, int CycleNo, DateTime EnteredAt, DateTime DueAt, string SlaState,
        long? AssigneeUserId, decimal SlaHours, string SlaMode, string StageKey, long CompanyId, string? RequestNo, string DraftRef, string TypeCode);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var now = clock.GetUtcNow();
        var open = (await c.QueryAsync<Open>(new CommandDefinition(
            """
            SELECT i.RequestStageInstanceId, i.RequestId, r.PublicId, i.CycleNo, i.EnteredAt, i.DueAt, i.SlaState, i.AssigneeUserId, s.SlaHours, s.SlaMode, s.StageKey,
                   r.CompanyId, r.RequestNo, r.DraftRef, rt.Code AS TypeCode
              FROM wfl.RequestStageInstance AS i JOIN wfl.WorkflowStage AS s ON s.WorkflowStageId = i.StageId
              JOIN wfl.Request AS r ON r.RequestId = i.RequestId JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
             WHERE i.ExitedAt IS NULL AND i.DueAt IS NOT NULL AND s.SlaHours IS NOT NULL AND i.SlaState IN ('ON_TRACK', 'AT_RISK', 'OVERDUE');
            """, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (open.Count == 0) return null;
        var tt = await RequestEngine.TimeAsync(c, null, ct).ConfigureAwait(false);
        var local = TimeZoneInfo.ConvertTime(now, tt.Zone).DateTime;
        var today = DateOnly.FromDateTime(local);
        var cal = await WorkingCalendar.LoadAsync(c, null, tt.CountryId, today.AddDays(-1), today.AddDays(400), ct).ConfigureAwait(false);
        var inHours = cal.IsWorkingDay(today) && TimeOnly.FromDateTime(local) >= tt.Start && TimeOnly.FromDateTime(local) < tt.End;
        int risk = 0, breached = 0, escalated = 0;
        foreach (var o in open)
        {
            var due = DateTime.SpecifyKind(o.DueAt, DateTimeKind.Utc);
            var left = o.SlaMode == "CALENDAR" ? (due - now.UtcDateTime).TotalHours
                : cal.BusinessHoursBetween(local, TimeZoneInfo.ConvertTimeFromUtc(due, tt.Zone), tt.Start, tt.End);
            var state = now.UtcDateTime >= due ? "OVERDUE" : left <= (double)(o.SlaHours * 0.2m) ? "AT_RISK" : "ON_TRACK";
            if (state == o.SlaState && (state != "OVERDUE" || !inHours)) continue;
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            await c.ExecuteAsync(new CommandDefinition("EXEC sys.sp_set_session_context @key = N'EngineNow', @value = @now;", new { now = now.UtcDateTime }, tx, cancellationToken: ct))
                .ConfigureAwait(false);
            if (state != o.SlaState)
            {
                var n = await c.ExecuteAsync(new CommandDefinition(
                    "UPDATE wfl.RequestStageInstance SET SlaState = @state, UpdatedAt = SYSUTCDATETIME() WHERE RequestStageInstanceId = @i AND ExitedAt IS NULL AND SlaState = @was;",
                    new { state, i = o.RequestStageInstanceId, was = o.SlaState }, tx, cancellationToken: ct)).ConfigureAwait(false);
                if (n == 0) { await tx.RollbackAsync(ct).ConfigureAwait(false); continue; }
            }
            string? action = null, code = null, key = null;
            if (state == "AT_RISK" && o.SlaState == "ON_TRACK") (action, code, key) = ("SLA_AT_RISK", "REQ.SLA_AT_RISK", "risk");
            else if (state == "OVERDUE" && o.SlaState != "OVERDUE") (action, code, key) = ("SLA_BREACHED", "REQ.SLA_BREACHED", today.ToString("yyyyMMdd", CultureInfo.InvariantCulture));
            else if (state == "OVERDUE" && inHours && await c.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
                         "SELECT MAX(OccurredAt) FROM wfl.RequestAction WHERE StageInstanceId = @i AND ActionType IN ('SLA_BREACHED', 'ESCALATED');",
                         new { i = o.RequestStageInstanceId }, tx, cancellationToken: ct)).ConfigureAwait(false) is { } last
                     && DateOnly.FromDateTime(TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(last, DateTimeKind.Utc), tt.Zone)) < today)
                (action, code, key) = ("ESCALATED", "REQ.SLA_BREACHED", today.ToString("yyyyMMdd", CultureInfo.InvariantCulture));
            if (action is null && state == o.SlaState)
            {
                await tx.RollbackAsync(ct).ConfigureAwait(false);
                continue;
            }
            if (action is not null)
            {
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, FromStageKey, ActorType, OccurredAt, Visibility, MetaJson, CorrelationId, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, @action, @stage, 'SYSTEM', @now, 'INTERNAL', @meta, @corr, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
                    """,
                    new
                    {
                        r = o.RequestId, i = o.RequestStageInstanceId, cycle = o.CycleNo, action, stage = o.StageKey, now = now.UtcDateTime, corr = correlation,
                        meta = System.Text.Json.JsonSerializer.Serialize(new { dueAt = due, slaHours = o.SlaHours }),
                    }, tx, cancellationToken: ct)).ConfigureAwait(false);
                var slots = (await c.QueryAsync<(long? UserId, int? RoleId)>(new CommandDefinition(
                    "SELECT AssignedUserId, AssignedRoleId FROM wfl.RequestApproval WHERE StageInstanceId = @i AND Decision = 'PENDING';", new { i = o.RequestStageInstanceId }, tx,
                    cancellationToken: ct)).ConfigureAwait(false)).ToList();
                var users = slots.Where(s => s.UserId is not null).Select(s => s.UserId!.Value).ToList();
                if (o.AssigneeUserId is { } a) users.Add(a);
                await Notifier.RequestAsync(c, tx, new NotificationRequest(code!, "wfl.Request", o.RequestId, $"{code}:{o.RequestStageInstanceId}:{key}", o.CompanyId,
                    new Dictionary<string, object?>
                    {
                        ["requestNo"] = o.RequestNo ?? o.DraftRef, ["typeName"] = o.TypeCode, ["stageLabel"] = o.StageKey,
                        ["dueAt"] = TimeZoneInfo.ConvertTimeFromUtc(due, tt.Zone).ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture),
                    }, $"/requests/{o.PublicId}", null, [.. users.Distinct()], [.. slots.Where(s => s.UserId is null && s.RoleId is not null).Select(s => (long)s.RoleId!.Value).Distinct()]),
                    ct).ConfigureAwait(false);
                if (action == "SLA_AT_RISK") risk++; else if (action == "SLA_BREACHED") breached++; else escalated++;
            }
            if (state != o.SlaState)
                await Outbox.EmitAsync(c, tx, "request.sla.changed", "wfl.Request", o.RequestId, new { requestId = o.RequestId, state }, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        return risk + breached + escalated == 0 ? null : $"at risk {risk}, breached {breached}, escalated {escalated}";
    }
}

/// <summary>JOB-WFL-DELEGATION (FR-WFL-020), hourly: delegations whose start has come are ACTIVE and those past their end ENDED, on the tenant's date.</summary>
public sealed class WorkflowDelegationJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-WFL-DELEGATION";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var (started, ended) = await Delegations.AdvanceAsync(c, DateOnly.FromDateTime(tenant.LocalDate(clock.GetUtcNow())), ct).ConfigureAwait(false);
        return started + ended == 0 ? null : $"started {started}, ended {ended}";
    }
}

/// <summary>
/// JOB-NTF-REMIND (FR-NTF-015, BR-NTF-006, AC-WFL-10), hourly: an open action-required notice is reminded 24, 48 and 72
/// business hours after it was made (at most three), counted with the same AddBusinessHours as the SLA in the tenant's
/// calendar and window; a reminder marks it unread again and counts it. It stops as soon as the notice is resolved (the
/// request moved on, FR-NTF-007). Never outside working hours: a reminder due then waits for the opening.
/// </summary>
public sealed class NotificationReminderJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-NTF-REMIND";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var open = (await c.QueryAsync<(long Id, DateTime CreatedAt, int ReminderCount)>(new CommandDefinition(
            "SELECT NotificationId, CreatedAt, ReminderCount FROM ntf.Notification WHERE ActionState = 'OPEN' AND ReminderCount < 3;", cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (open.Count == 0) return null;
        var now = clock.GetUtcNow();
        var tt = await RequestEngine.TimeAsync(c, null, ct).ConfigureAwait(false);
        var local = TimeZoneInfo.ConvertTime(now, tt.Zone).DateTime;
        var today = DateOnly.FromDateTime(local);
        var earliest = DateOnly.FromDateTime(TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(open.Min(o => o.CreatedAt), DateTimeKind.Utc), tt.Zone));
        var cal = await WorkingCalendar.LoadAsync(c, null, tt.CountryId, earliest.AddDays(-1), today.AddDays(60), ct).ConfigureAwait(false);
        if (!cal.IsWorkingDay(today) || TimeOnly.FromDateTime(local) < tt.Start || TimeOnly.FromDateTime(local) >= tt.End) return null;
        var reminded = 0;
        foreach (var (id, createdAt, count) in open)
        {
            var made = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(createdAt, DateTimeKind.Utc), tt.Zone);
            var due = cal.AddBusinessHours(made, 24 * (count + 1), tt.Start, tt.End);
            if (local < due) continue;
            var next = count + 1 < 3
                ? TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(cal.AddBusinessHours(made, 24 * (count + 2), tt.Start, tt.End), DateTimeKind.Unspecified), tt.Zone)
                : (DateTime?)null;
            reminded += await c.ExecuteAsync(new CommandDefinition(
                """
                UPDATE ntf.Notification SET ReminderCount = ReminderCount + 1, NextReminderAt = @next, ReadAt = NULL, UpdatedAt = SYSUTCDATETIME()
                 WHERE NotificationId = @id AND ActionState = 'OPEN' AND ReminderCount = @count;
                """, new { id, next, count }, cancellationToken: ct)).ConfigureAwait(false);
        }
        return reminded == 0 ? null : $"reminded {reminded}";
    }
}

/// <summary>
/// JOB-FAC-RESERVATION (FR-FAC-018, BR-WFL-017; S3 batch D), hourly: an active reservation whose expiry date has passed
/// (in the tenant's date) is released as EXPIRED in one transaction with its movement; the request's reservation then
/// reads LOST (the copy of 044), the request records RESERVATION_LOST and REQ.RESERVATION_LOST goes to its holders. The
/// approval that reserved it must be taken again. The T-7 and T-1 alerts are the expiry job's (the RESERVATION rule).
/// </summary>
public sealed class FacilityReservationJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-FAC-RESERVATION";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var today = tenant.LocalDate(clock.GetUtcNow());
        var due = (await c.QueryAsync<(long Id, long RequestId)>(new CommandDefinition(
            "SELECT LimitReservationId, RequestId FROM fac.LimitReservation WHERE Status = 'ACTIVE' AND ExpiresOn IS NOT NULL AND ExpiresOn < @today;", new { today },
            cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (due.Count == 0) return null;
        var me = await c.ExecuteScalarAsync<long>(new CommandDefinition("SELECT CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);", cancellationToken: ct)).ConfigureAwait(false);
        var lost = 0;
        foreach (var (id, requestId) in due)
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            if (!await Facilities.ReservationService.ReleaseAsync(c, tx, id, "EXPIRED", me, today, ct).ConfigureAwait(false))
            {
                await tx.RollbackAsync(ct).ConfigureAwait(false);
                continue;
            }
            var r = await c.QuerySingleAsync<(Guid PublicId, int CycleNo, long? Instance, long CompanyId, string? RequestNo, string DraftRef, string TypeCode)>(new CommandDefinition(
                """
                SELECT r.PublicId, r.CycleNo, r.CurrentStageInstanceId, r.CompanyId, r.RequestNo, r.DraftRef, rt.Code
                  FROM wfl.Request AS r JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId WHERE r.RequestId = @r;
                """, new { r = requestId }, tx, cancellationToken: ct)).ConfigureAwait(false);
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT wfl.RequestAction (TenantId, RequestId, StageInstanceId, CycleNo, ActionType, ActorType, OccurredAt, Visibility, MetaJson, CorrelationId, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @cycle, 'RESERVATION_LOST', 'SYSTEM', SYSUTCDATETIME(), 'INTERNAL', @meta, @corr, @me);
                """, new { r = requestId, i = r.Instance, cycle = r.CycleNo, meta = System.Text.Json.JsonSerializer.Serialize(new { reservation = id, reason = "EXPIRED" }), corr = correlation, me },
                tx, cancellationToken: ct)).ConfigureAwait(false);
            await Notifier.RequestAsync(c, tx, new NotificationRequest("REQ.RESERVATION_LOST", "wfl.Request", requestId, $"REQ.RESERVATION_LOST:{requestId}:{id}", r.CompanyId,
                new Dictionary<string, object?> { ["requestNo"] = r.RequestNo ?? r.DraftRef, ["typeName"] = r.TypeCode }, $"/requests/{r.PublicId}"), ct).ConfigureAwait(false);
            await Outbox.EmitAsync(c, tx, "reservation.expired", "fac.LimitReservation", id, new { reservation = id, requestId }, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
            lost++;
        }
        return lost == 0 ? null : $"expired {lost}";
    }
}

/// <summary>
/// JOB-WFL-STALE (BR-REQ-012; 13m section 7), daily: a draft idle req.draft.stale_days reminds its requester once
/// (REQ.DRAFT_STALE), and one idle req.draft.archive_days is archived (it stays DRAFT, DRAFT_ARCHIVED); a reservation
/// waiting longer than wfl.reservation.aging_days is reported once a week (REQ.RESERVATION_AGING).
/// </summary>
public sealed class WorkflowStaleJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-WFL-STALE";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var now = clock.GetUtcNow().UtcDateTime;
        var s = await FacilityHooks.SettingsAsync(c, null, ct, "req.draft.stale_days", "req.draft.archive_days", "wfl.reservation.aging_days").ConfigureAwait(false);
        int Days(string key, int d) => int.TryParse(s.GetValueOrDefault(key), out var v) ? v : d;
        var (stale, archive, aging) = (Days("req.draft.stale_days", 30), Days("req.draft.archive_days", 90), Days("wfl.reservation.aging_days", 14));
        var me = await c.ExecuteScalarAsync<long>(new CommandDefinition("SELECT CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);", cancellationToken: ct)).ConfigureAwait(false);
        var drafts = (await c.QueryAsync<(long Id, Guid PublicId, DateTime Idle, long RequesterUserId, long CompanyId, string DraftRef, string TypeCode)>(new CommandDefinition(
            """
            SELECT r.RequestId, r.PublicId, ISNULL(r.UpdatedAt, r.CreatedAt), r.RequesterUserId, r.CompanyId, r.DraftRef, rt.Code
              FROM wfl.Request AS r JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
             WHERE r.Status = 'DRAFT' AND r.ArchivedAt IS NULL AND ISNULL(r.UpdatedAt, r.CreatedAt) < @before;
            """, new { before = now.AddDays(-stale) }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        int reminded = 0, archived = 0, aged = 0;
        foreach (var d in drafts)
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            if (d.Idle < now.AddDays(-archive))
            {
                await c.ExecuteAsync(new CommandDefinition("UPDATE wfl.Request SET ArchivedAt = SYSUTCDATETIME() WHERE RequestId = @r AND Status = 'DRAFT' AND ArchivedAt IS NULL;",
                    new { r = d.Id }, tx, cancellationToken: ct)).ConfigureAwait(false);
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    INSERT wfl.RequestAction (TenantId, RequestId, ActionType, ActorType, OccurredAt, Visibility, CorrelationId, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, 'DRAFT_ARCHIVED', 'SYSTEM', SYSUTCDATETIME(), 'REQUESTER_VISIBLE', @corr, @me);
                    """, new { r = d.Id, corr = correlation, me }, tx, cancellationToken: ct)).ConfigureAwait(false);
                archived++;
            }
            else
            {
                await Notifier.RequestAsync(c, tx, new NotificationRequest("REQ.DRAFT_STALE", "wfl.Request", d.Id, $"REQ.DRAFT_STALE:{d.Id}:{d.Idle:yyyyMMddHHmmss}", d.CompanyId,
                    new Dictionary<string, object?> { ["requestNo"] = d.DraftRef, ["typeName"] = d.TypeCode }, $"/requests/{d.PublicId}", null, [d.RequesterUserId]), ct).ConfigureAwait(false);
                reminded++;
            }
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        var week = System.Globalization.ISOWeek.GetYear(now) * 100 + System.Globalization.ISOWeek.GetWeekOfYear(now);
        foreach (var a in await c.QueryAsync<(long RequestId, Guid PublicId, long CompanyId, string? RequestNo, string DraftRef, string TypeCode)>(new CommandDefinition(
                     """
                     SELECT r.RequestId, r.PublicId, r.CompanyId, r.RequestNo, r.DraftRef, rt.Code
                       FROM fac.LimitReservation AS lr JOIN wfl.Request AS r ON r.RequestId = lr.RequestId JOIN wfl.RequestType AS rt ON rt.RequestTypeId = r.RequestTypeId
                      WHERE lr.Status = 'ACTIVE' AND lr.CreatedAt < @before;
                     """, new { before = now.AddDays(-aging) }, cancellationToken: ct)).ConfigureAwait(false))
        {
            await Notifier.RequestAsync(c, null, new NotificationRequest("REQ.RESERVATION_AGING", "wfl.Request", a.RequestId, $"REQ.RESERVATION_AGING:{a.RequestId}:{week}", a.CompanyId,
                new Dictionary<string, object?> { ["requestNo"] = a.RequestNo ?? a.DraftRef, ["typeName"] = a.TypeCode }, $"/requests/{a.PublicId}"), ct).ConfigureAwait(false);
            aged++;
        }
        return reminded + archived + aged == 0 ? null : $"reminded {reminded}, archived {archived}, aging {aged}";
    }
}
