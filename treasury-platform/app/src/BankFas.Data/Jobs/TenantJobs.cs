using System.Text.Json;
using BankFas.Core.Mail;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>
/// The pattern of every tenant job (DOC-F17 section 5): for each tenant the job may bind to (plat.usp_ListTenantsForJobs),
/// one connection bound as the tenant's service account (sec.usp_SetJobContext, audited once per bind), a cfg.JobRun row
/// RUNNING then SUCCEEDED or FAILED with a summary, and the next tenant even when one fails.
/// </summary>
public abstract class TenantJob(SqlConnectionFactory db)
{
    public abstract string JobKey { get; }

    /// <summary>How long after its last success the job runs again for a tenant; null runs on every pass.</summary>
    protected virtual TimeSpan? Interval => null;

    /// <summary>The work for one tenant, on the bound connection; returns the summary for cfg.JobRun, or null when there was nothing to do.</summary>
    protected abstract Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct);

    /// <summary>One pass over the tenants; returns the number of tenants that had something to do.</summary>
    public async Task<int> RunOnceAsync(CancellationToken ct)
    {
        IReadOnlyList<JobTenant> tenants;
        await using (var list = await db.OpenAsync(DbLogin.Jobs, ct).ConfigureAwait(false))
            tenants = await JobProcedures.ListTenantsAsync(list, JobKey, ct).ConfigureAwait(false);
        var worked = 0;
        foreach (var t in tenants)
        {
            if (await RunTenantAsync(t, ct).ConfigureAwait(false)) worked++;
        }
        return worked;
    }

    public async Task<bool> RunTenantAsync(JobTenant tenant, CancellationToken ct)
    {
        var correlation = Guid.NewGuid();
        await using var c = await db.OpenAsync(DbLogin.Jobs, ct).ConfigureAwait(false);
        await JobProcedures.BindAsync(c, tenant.TenantId, JobKey, correlation, ct).ConfigureAwait(false);
        if (Interval is { } every)
        {
            var last = await c.ExecuteScalarAsync<DateTime?>(new CommandDefinition(
                "SELECT MAX(FinishedAt) FROM cfg.JobRun WHERE JobKey = @k AND Status = 'SUCCEEDED';", new { k = JobKey }, cancellationToken: ct)).ConfigureAwait(false);
            if (last is not null && last.Value.Add(every) > DateTime.UtcNow) return false;
        }
        var run = await c.ExecuteScalarAsync<long>(new CommandDefinition(
            "INSERT cfg.JobRun (TenantId, JobKey, TriggerKind, AttemptNo) OUTPUT inserted.JobRunId VALUES (@t, @k, 'SCHEDULED', 1);",
            new { t = tenant.TenantId, k = JobKey }, cancellationToken: ct)).ConfigureAwait(false);
        try
        {
            var summary = await RunForTenantAsync(c, tenant, correlation, ct).ConfigureAwait(false);
            await FinishAsync(c, run, "SUCCEEDED", summary ?? "nothing to do", null, ct).ConfigureAwait(false);
            return summary is not null;
        }
        catch (Exception ex) when (ex is SqlException or IOException or InvalidOperationException or JsonException)
        {
            await FinishAsync(c, run, "FAILED", null, ex.Message, ct).ConfigureAwait(false);
            await JobFailedAsync(c, run, ct).ConfigureAwait(false);
            return false;
        }
    }

    /// <summary>JOB.FAILED to the account administrators (spec 13 section 9.2), once a day per job; a failure here never hides the job's own.</summary>
    private async Task JobFailedAsync(SqlConnection c, long run, CancellationToken ct)
    {
        try
        {
            var now = DateTime.UtcNow;
            await Notifications.Notifier.RequestAsync(c, null, new Notifications.NotificationRequest("JOB.FAILED", "cfg.JobRun", run,
                $"JOB.FAILED:{JobKey}:{now:yyyyMMdd}", Values: new Dictionary<string, object?>
                {
                    ["jobKey"] = JobKey, ["occurredAt"] = now.ToString("yyyy-MM-dd HH:mm 'UTC'", System.Globalization.CultureInfo.InvariantCulture),
                }), ct).ConfigureAwait(false);
        }
        catch (SqlException)
        {
            // The job's run already says FAILED; the notification is best effort.
        }
    }

    private static Task<int> FinishAsync(SqlConnection c, long run, string status, string? summary, string? error, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE cfg.JobRun SET Status = @s, FinishedAt = SYSUTCDATETIME(), DurationMs = DATEDIFF(MILLISECOND, StartedAt, SYSUTCDATETIME()),
                   ResultSummary = @summary, ErrorMessage = @error,
                   NextRetryAt = CASE WHEN @s = 'FAILED' THEN DATEADD(MINUTE, 15, SYSUTCDATETIME()) END
             WHERE JobRunId = @run;
            """, new { s = status, summary = Truncate(summary, 1000), error = Truncate(error, 2000), run }, cancellationToken: ct));

    private static string? Truncate(string? s, int max) => s is null || s.Length <= max ? s : s[..max];

    /// <summary>The e-mail addresses of the tenant's active account administrators (role TA).</summary>
    protected static async Task<IReadOnlyList<string>> AdministratorEmailsAsync(SqlConnection bound, CancellationToken ct) =>
        [.. await bound.QueryAsync<string>(new CommandDefinition(
            """
            SELECT DISTINCT u.Email FROM sec.AppUser AS u
            JOIN sec.UserRole AS ur ON ur.UserId = u.AppUserId JOIN sec.Role AS r ON r.RoleId = ur.RoleId AND r.Code = 'TA'
            WHERE u.Status = 'ACTIVE' AND u.IsSystemUser = 0;
            """, cancellationToken: ct)).ConfigureAwait(false)];
}

/// <summary>
/// JOB-PLT-OUTBOX (DOC-F17 4.3 to 4.7): at-least-once delivery of cfg.OutboxEvent. A batch of 50 is claimed with
/// UPDLOCK and READPAST, oldest first, skipping an event whose aggregate has an older undelivered one; each is leased
/// for 60 seconds, delivered in its own step, and marked DELIVERED only while this worker still holds it. A failure
/// waits 1 minute, 5, 30, 2 hours and 12 hours; after the fifth it is DEAD with its error, never deleted. tenant.created
/// belongs to the onboarding job. The consumers: the account administrators' e-mail about a status change, and the
/// notifications (notification.requested, Notifier). The domain events of S1 that no module consumes yet are listed and
/// delivered as they are; any other name fails, then is DEAD, so an event without a consumer is seen, never lost
/// silently (S1 brief S1-GAP-3).
/// </summary>
public sealed class OutboxJob(SqlConnectionFactory db, IMailSender mail) : TenantJob(db)
{
    public override string JobKey => "JOB-PLT-OUTBOX";
    private readonly string _worker = "outbox-" + Environment.MachineName;

    private sealed record Claimed(long OutboxEventId, Guid MessageId, string EventName, string PayloadJson, int AttemptCount);

    /// <summary>The domain events that have no consumer in S1; the later slices subscribe to them.</summary>
    private static readonly HashSet<string> NoConsumerYet = new(StringComparer.Ordinal)
    {
        "company.created", "party.created", "party.merged", "identity_document.renewed", "document.uploaded", "document.version_added",
        "institution.created", "relationship.created", "relationship.closed", "account.created", "account.closed",
        // S1-b: the structure and the signatories; the governance comparison consumes authority.granted and authority.revoked below
        "ownership.changed", "body.changed", "signatory.activated",
        "signatory.authority.changed", "authority.conflict.opened", "authority.conflict.resolved",
    };

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var batch = (await c.QueryAsync<Claimed>(new CommandDefinition(
            """
            DECLARE @o TABLE (OutboxEventId BIGINT, MessageId UNIQUEIDENTIFIER, EventName VARCHAR(100), PayloadJson NVARCHAR(MAX), AttemptCount INT);
            WITH due AS (
                SELECT TOP (50) e.OutboxEventId FROM cfg.OutboxEvent AS e WITH (UPDLOCK, READPAST, ROWLOCK)
                WHERE e.EventName <> 'tenant.created'
                  AND (e.Status = 'PENDING' OR (e.Status = 'FAILED' AND e.NextAttemptAt <= SYSUTCDATETIME())
                       OR (e.Status = 'PROCESSING' AND e.LockedUntil < SYSUTCDATETIME()))
                  AND NOT EXISTS (SELECT 1 FROM cfg.OutboxEvent AS o
                                  WHERE o.AggregateType = e.AggregateType AND o.AggregateId = e.AggregateId AND o.OutboxEventId < e.OutboxEventId
                                    AND o.EventName <> 'tenant.created' AND o.Status IN ('PENDING', 'PROCESSING', 'FAILED'))
                ORDER BY e.OutboxEventId)
            UPDATE e SET Status = 'PROCESSING', LockedBy = @me, LockedUntil = DATEADD(SECOND, 60, SYSUTCDATETIME()), AttemptCount = AttemptCount + 1
            OUTPUT inserted.OutboxEventId, inserted.MessageId, inserted.EventName, inserted.PayloadJson, inserted.AttemptCount INTO @o
            FROM cfg.OutboxEvent AS e JOIN due ON due.OutboxEventId = e.OutboxEventId;
            SELECT OutboxEventId, MessageId, EventName, PayloadJson, AttemptCount FROM @o ORDER BY OutboxEventId;
            """, new { me = _worker }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (batch.Count == 0) return null;
        int delivered = 0, failed = 0;
        foreach (var ev in batch)
        {
            try
            {
                await DeliverAsync(c, tenant, ev, ct).ConfigureAwait(false);
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE cfg.OutboxEvent SET Status = 'DELIVERED', DeliveredAt = SYSUTCDATETIME(), LockedBy = NULL, LockedUntil = NULL, LastError = NULL
                     WHERE OutboxEventId = @id AND Status = 'PROCESSING' AND LockedBy = @me;
                    """, new { id = ev.OutboxEventId, me = _worker }, cancellationToken: ct)).ConfigureAwait(false);
                delivered++;
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or JsonException or System.Net.Mail.SmtpException or SqlException)
            {
                failed++;
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE cfg.OutboxEvent
                       SET Status = CASE WHEN AttemptCount >= 5 THEN 'DEAD' ELSE 'FAILED' END, LastError = @err, LockedBy = NULL, LockedUntil = NULL,
                           NextAttemptAt = CASE WHEN AttemptCount >= 5 THEN NULL
                                                ELSE DATEADD(MINUTE, CASE AttemptCount WHEN 1 THEN 1 WHEN 2 THEN 5 WHEN 3 THEN 30 ELSE 120 END, SYSUTCDATETIME()) END
                     WHERE OutboxEventId = @id AND Status = 'PROCESSING' AND LockedBy = @me;
                    """, new { id = ev.OutboxEventId, me = _worker, err = ex.Message.Length > 1000 ? ex.Message[..1000] : ex.Message }, cancellationToken: ct))
                    .ConfigureAwait(false);
            }
        }
        return $"delivered {delivered}, failed {failed}";
    }

    private async Task DeliverAsync(SqlConnection c, JobTenant tenant, Claimed ev, CancellationToken ct)
    {
        if (ev.EventName == Notifications.Notifier.EventName)
        {
            await Notifications.Notifier.ConsumeAsync(c, ev.MessageId, ev.PayloadJson, ct).ConfigureAwait(false);
            return;
        }
        if (NoConsumerYet.Contains(ev.EventName)) return;
        if (ev.EventName is "authority.granted" or "authority.revoked")
        {
            // A grant that starts, ends or is replaced changes the comparison of its company's bank authorities (BR-ACC-015).
            using var granted = JsonDocument.Parse(ev.PayloadJson);
            if (!granted.RootElement.TryGetProperty("grant", out var g) || !g.TryGetGuid(out var grantId)) return;
            var company = await c.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT CompanyId FROM org.AuthorityGrant WHERE PublicId = @g;",
                new { g = grantId }, cancellationToken: ct)).ConfigureAwait(false);
            if (company is null) return;
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            await Governance.GovernanceComparer.ReconcileAsync(c, tx, company, null, DateTime.UtcNow.Date, null, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
            return;
        }
        if (ev.EventName != "tenant.status_changed") throw new InvalidOperationException($"No consumer for the event {ev.EventName}.");
        using var payload = JsonDocument.Parse(ev.PayloadJson);
        var to = payload.RootElement.GetProperty("to").GetString();
        var name = await c.ExecuteScalarAsync<string>(new CommandDefinition("SELECT NameEn FROM plat.v_CurrentTenant;", cancellationToken: ct)).ConfigureAwait(false);
        var text = to switch
        {
            "ACTIVE" => $"The BankFas account of {name} is active.",
            "SUSPENDED" => $"The BankFas account of {name} is suspended. Account administrators can still sign in and export data.",
            "TRIAL" => $"The trial of the BankFas account of {name} has been extended.",
            "CLOSED" => $"The BankFas account of {name} is closed. Account administrators can export the data for 30 days.",
            _ => $"The status of the BankFas account of {name} changed to {to}.",
        };
        foreach (var email in await AdministratorEmailsAsync(c, ct).ConfigureAwait(false))
            await mail.SendAsync(new OutgoingMail(email, "Your BankFas account status", text + "\r\n"), ct).ConfigureAwait(false);
    }
}

/// <summary>JOB-PLT-OUTBOX-PURGE: delivered outbox events older than 30 days, weekly (DOC-F17 4.8; others are kept, 50041).</summary>
public sealed class OutboxPurgeJob(SqlConnectionFactory db) : TenantJob(db)
{
    public override string JobKey => "JOB-PLT-OUTBOX-PURGE";
    protected override TimeSpan? Interval => TimeSpan.FromDays(7);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var n = await c.ExecuteAsync(new CommandDefinition(
            "DELETE FROM cfg.OutboxEvent WHERE Status = 'DELIVERED' AND DeliveredAt < DATEADD(DAY, -30, SYSUTCDATETIME());", cancellationToken: ct)).ConfigureAwait(false);
        return $"deleted {n}";
    }
}

/// <summary>JOB-PLT-JOBRUN-PURGE: job runs older than 90 days, weekly (DOC-F17 7).</summary>
public sealed class JobRunPurgeJob(SqlConnectionFactory db) : TenantJob(db)
{
    public override string JobKey => "JOB-PLT-JOBRUN-PURGE";
    protected override TimeSpan? Interval => TimeSpan.FromDays(7);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var n = await c.ExecuteAsync(new CommandDefinition(
            "DELETE FROM cfg.JobRun WHERE StartedAt < DATEADD(DAY, -90, SYSUTCDATETIME()) AND Status <> 'RUNNING';", cancellationToken: ct)).ConfigureAwait(false);
        return $"deleted {n}";
    }
}

/// <summary>
/// JOB-PLT-TRIAL-REMIND (DOC-F05 6.3): the account administrators of a TRIAL tenant hear 7, 3 and 1 days before the
/// trial ends, once each: a reminder is recorded in the run's DetailJson with the end date it was for, so an
/// extended trial reminds again. The same reminder is a PLT.TRIAL_ENDING notification in the application.
/// </summary>
public sealed class TrialReminderJob(SqlConnectionFactory db, IMailSender mail, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-PLT-TRIAL-REMIND";
    private static readonly int[] Days = [7, 3, 1];

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var (ends, name) = await c.QuerySingleAsync<(DateTime? TrialEndsOn, string NameEn)>(new CommandDefinition(
            "SELECT t.TrialEndsOn, t.NameEn FROM plat.v_CurrentTenant AS t;", cancellationToken: ct)).ConfigureAwait(false);
        if (ends is null) return null;
        var today = DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime);
        var left = DateOnly.FromDateTime(ends.Value).DayNumber - today.DayNumber;
        var due = Days.Where(d => left <= d && left >= 0).Select(d => (int?)d).Min();
        if (due is null) return null;
        var endText = DateOnly.FromDateTime(ends.Value).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var sent = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            SELECT COUNT(JobRunId) FROM cfg.JobRun
            WHERE JobKey = 'JOB-PLT-TRIAL-REMIND' AND Status = 'SUCCEEDED'
              AND JSON_VALUE(DetailJson, '$.days') = @d AND JSON_VALUE(DetailJson, '$.trialEndsOn') = @e;
            """, new { d = due.Value.ToString(System.Globalization.CultureInfo.InvariantCulture), e = endText }, cancellationToken: ct)).ConfigureAwait(false);
        if (sent > 0) return null;
        foreach (var email in await AdministratorEmailsAsync(c, ct).ConfigureAwait(false))
            await mail.SendAsync(new OutgoingMail(email, "Your BankFas trial ends soon",
                $"The trial of the BankFas account of {name} ends on {endText} ({left} day(s) left). Contact us to continue without interruption.\r\n"), ct).ConfigureAwait(false);
        await Notifications.Notifier.RequestAsync(c, null, new Notifications.NotificationRequest("PLT.TRIAL_ENDING", "plat.Tenant", tenant.TenantId,
            $"PLT.TRIAL_ENDING:{endText}:{due.Value}", Values: new Dictionary<string, object?> { ["trialEndsOn"] = endText, ["daysLeft"] = left }), ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            "UPDATE cfg.JobRun SET DetailJson = @j WHERE JobRunId = (SELECT MAX(JobRunId) FROM cfg.JobRun WHERE JobKey = 'JOB-PLT-TRIAL-REMIND' AND Status = 'RUNNING');",
            new { j = JsonSerializer.Serialize(new { days = due.Value, trialEndsOn = endText }) }, cancellationToken: ct)).ConfigureAwait(false);
        return $"reminded {due.Value} day(s) before {endText}";
    }
}

/// <summary>
/// The UPGRADE run of the tenant packs (DOC-B05 section 5.1, DQ-F05-9): a tenant onboarded before a pack existed gets
/// it here, insert only, bound as the onboarding job. A tenant whose onboarding has not seeded CORE.ROLES yet is left
/// to the onboarding job. Daily, and at the start of the worker.
/// </summary>
public sealed class SeedUpgradeJob(SqlConnectionFactory db, Seeding.SeedPacks packs) : TenantJob(db)
{
    public override string JobKey => OnboardingJob.JobKey;

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var onboarded = await c.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM cfg.SeedRun WHERE PackKey = 'CORE.ROLES' AND Status = 'SUCCEEDED';", cancellationToken: ct)).ConfigureAwait(false);
        if (onboarded == 0) return null;
        IReadOnlyList<Seeding.SeedResult> results;
        await using (var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false))
        {
            try { results = await Seeding.TenantSeeder.ApplyAsync(c, tx, packs.S1, ct).ConfigureAwait(false); }
            catch (InvalidDataException ex) { throw new InvalidOperationException(ex.Message, ex); }
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        var ran = results.Where(r => !r.AlreadyRun).ToList();
        return ran.Count == 0 ? null : string.Join("; ", ran.Select(r => $"{r.PackKey} v{r.SeedVersion}: {r.Created} created, {r.Skipped} present"));
    }
}
