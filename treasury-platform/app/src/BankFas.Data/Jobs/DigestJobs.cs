using System.Globalization;
using System.Text;
using System.Text.Json;
using BankFas.Core.Mail;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>
/// JOB-NTF-DIGEST (FR-NTF-014, BR-NTF-004; S5): the e-mails a user chose to receive as a digest. The notifier holds such a
/// delivery PENDING without a send time; this job gathers them, at <c>ntf.digest.daily_at</c> in the tenant's time zone
/// for DIGEST_DAILY and on <c>ntf.digest.weekly_day</c> at the same time for DIGEST_WEEKLY, into one e-mail per user and
/// period: per group its count and its five latest titles. A digest is never sent empty, and its batch (unique per user,
/// kind and period end) makes a second run of the same period a no-op. A mandatory event is never held for a digest. A
/// delivery whose user went back to IMMEDIATE is released to JOB-NTF-DISPATCH.
/// </summary>
public sealed class NotificationDigestJob(SqlConnectionFactory db, IMailSender mail, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-NTF-DIGEST";

    private sealed record Held(long DeliveryId, long UserId, string Email, string? PreferredLanguage, string GroupKey, string? GroupNameAr, string? GroupNameEn,
        string Title, DateTime CreatedAt);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        // A delivery held for a digest whose user no longer wants one goes out now.
        var released = await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE d SET NextAttemptAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME()
              FROM ntf.NotificationDelivery AS d JOIN ntf.Notification AS n ON n.NotificationId = d.NotificationId
              JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId
             WHERE d.Channel = 'EMAIL' AND d.Status = 'PENDING' AND d.NextAttemptAt IS NULL
               AND NOT EXISTS (SELECT 1 FROM ntf.NotificationPreference AS p WHERE p.UserId = n.UserId AND p.GroupKey = e.GroupKey AND p.Channel = 'EMAIL'
                                  AND p.Mode IN ('DIGEST_DAILY', 'DIGEST_WEEKLY'));
            """, cancellationToken: ct)).ConfigureAwait(false);
        var s = await FacilityHooks.SettingsAsync(c, null, ct, "ntf.digest.daily_at", "ntf.digest.weekly_day").ConfigureAwait(false);
        var at = TimeOnly.TryParse(s.GetValueOrDefault("ntf.digest.daily_at")?.Trim('"'), CultureInfo.InvariantCulture, out var t) ? t : new TimeOnly(7, 30);
        var weekday = int.TryParse(s.GetValueOrDefault("ntf.digest.weekly_day"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var w) && w is >= 0 and <= 6 ? w : 0;
        var zoneId = await c.ExecuteScalarAsync<string>(new CommandDefinition("SELECT TimeZone FROM plat.v_CurrentTenant;", cancellationToken: ct)).ConfigureAwait(false);
        var zone = zoneId is not null && TimeZoneInfo.TryFindSystemTimeZoneById(zoneId, out var z) ? z : TimeZoneInfo.Utc;
        var now = clock.GetUtcNow();
        var local = TimeZoneInfo.ConvertTime(now, zone).DateTime;
        // The latest daily cut at or before now, and the latest weekly one, as UTC.
        var daily = local.Date.Add(at.ToTimeSpan());
        if (daily > local) daily = daily.AddDays(-1);
        var weekly = daily.AddDays(-(((int)daily.DayOfWeek - weekday + 7) % 7));
        var sent = 0;
        sent += await DigestAsync(c, "DIGEST_DAILY", "DAILY", TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(daily, DateTimeKind.Unspecified), zone), 1, ct).ConfigureAwait(false);
        sent += await DigestAsync(c, "DIGEST_WEEKLY", "WEEKLY", TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(weekly, DateTimeKind.Unspecified), zone), 7, ct).ConfigureAwait(false);
        return sent + released == 0 ? null : $"{sent} digest(s), {released} released";
    }

    private async Task<int> DigestAsync(SqlConnection c, string mode, string kind, DateTime cut, int days, CancellationToken ct)
    {
        var held = (await c.QueryAsync<Held>(new CommandDefinition(
            """
            SELECT d.NotificationDeliveryId AS DeliveryId, n.UserId, u.Email, ISNULL(u.PreferredLanguage, (SELECT DefaultLanguage FROM plat.v_CurrentTenant)) AS PreferredLanguage,
                   e.GroupKey, e.NameAr AS GroupNameAr, e.NameEn AS GroupNameEn, n.Title, n.CreatedAt
              FROM ntf.NotificationDelivery AS d JOIN ntf.Notification AS n ON n.NotificationId = d.NotificationId
              JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId JOIN sec.AppUser AS u ON u.AppUserId = n.UserId
              JOIN ntf.NotificationPreference AS p ON p.UserId = n.UserId AND p.GroupKey = e.GroupKey AND p.Channel = 'EMAIL' AND p.Mode = @mode
             WHERE d.Channel = 'EMAIL' AND d.Status = 'PENDING' AND d.NextAttemptAt IS NULL AND n.CreatedAt < @cut
               AND NOT EXISTS (SELECT 1 FROM ntf.DigestBatch AS b WHERE b.UserId = n.UserId AND b.Channel = 'EMAIL' AND b.Kind = @kind AND b.PeriodEnd = @cut)
             ORDER BY n.UserId, n.CreatedAt DESC;
            """, new { mode, kind, cut }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var sent = 0;
        foreach (var user in held.GroupBy(h => h.UserId))
        {
            var items = user.ToList();
            var first = items[0];
            var ar = first.PreferredLanguage != "en";
            // Per event: its name in the user's language, its count and its five latest titles (BR-NTF-004).
            var groups = items.GroupBy(i => (ar ? i.GroupNameAr : i.GroupNameEn) ?? i.GroupKey).OrderBy(g => g.Key, StringComparer.Ordinal)
                .Select(g => new { group = g.First().GroupKey, name = g.Key, count = g.Count(), latest = g.Take(5).Select(x => x.Title).ToList() })
                .ToList();
            var start = items.Min(i => i.CreatedAt);
            if (start >= cut.AddDays(-days)) start = cut.AddDays(-days);
            var batch = await c.ExecuteScalarAsync<long?>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT ntf.DigestBatch (TenantId, UserId, Channel, Kind, PeriodStart, PeriodEnd, Status, ItemCount, GroupSummaryJson, ScheduledFor)
                OUTPUT inserted.DigestBatchId INTO @o
                SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), @user, 'EMAIL', @kind, @start, @cut, 'PENDING', @count, @summary, @cut
                 WHERE NOT EXISTS (SELECT 1 FROM ntf.DigestBatch WHERE UserId = @user AND Channel = 'EMAIL' AND Kind = @kind AND PeriodEnd = @cut);
                SELECT Id FROM @o;
                """, new { user = user.Key, kind, start, cut, count = items.Count, summary = JsonSerializer.Serialize(groups) }, cancellationToken: ct)).ConfigureAwait(false);
            if (batch is null) continue;
            var body = new StringBuilder(ar ? "ملخص إشعاراتك في المنصة:" : "Your notifications on the platform:").Append("\r\n\r\n");
            foreach (var g in groups)
            {
                body.Append(CultureInfo.InvariantCulture, $"{g.name} ({g.count})").Append("\r\n");
                foreach (var title in g.latest) body.Append("  - ").Append(title).Append("\r\n");
                body.Append("\r\n");
            }
            body.Append(ar ? "سجّل الدخول لترى التفاصيل." : "Sign in to see the details.").Append("\r\n");
            var subject = ar ? $"ملخص الإشعارات: {items.Count}" : $"Notifications digest: {items.Count}";
            try
            {
                await mail.SendAsync(new OutgoingMail(first.Email, subject, body.ToString()), ct).ConfigureAwait(false);
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE ntf.NotificationDelivery SET Status = 'DIGESTED', DigestBatchId = @b, UpdatedAt = SYSUTCDATETIME() WHERE NotificationDeliveryId IN @ids;
                    UPDATE ntf.DigestBatch SET Status = 'SENT', SentAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME() WHERE DigestBatchId = @b;
                    """, new { b = batch, ids = items.Select(i => i.DeliveryId).ToArray() }, cancellationToken: ct)).ConfigureAwait(false);
                sent++;
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Net.Mail.SmtpException)
            {
                // The items stay held and go into the next period's digest.
                await c.ExecuteAsync(new CommandDefinition("UPDATE ntf.DigestBatch SET Status = 'FAILED', UpdatedAt = SYSUTCDATETIME() WHERE DigestBatchId = @b;",
                    new { b = batch }, cancellationToken: ct)).ConfigureAwait(false);
            }
        }
        return sent;
    }
}

/// <summary>
/// JOB-NTF-RETENTION (FR-NTF-020, BR-NTF-011; S5): a notification read more than <c>ntf.retention.archive_days</c> ago
/// (180 by default) is archived. Nothing is deleted, and an unread notification is never archived by the job.
/// </summary>
public sealed class NotificationRetentionJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-NTF-RETENTION";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var s = await FacilityHooks.SettingsAsync(c, null, ct, "ntf.retention.archive_days").ConfigureAwait(false);
        var days = int.TryParse(s.GetValueOrDefault("ntf.retention.archive_days"), NumberStyles.Integer, CultureInfo.InvariantCulture, out var d) && d > 0 ? d : 180;
        var n = await c.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ntf.Notification SET ArchivedAt = @now, UpdatedAt = SYSUTCDATETIME()
             WHERE ReadAt IS NOT NULL AND ArchivedAt IS NULL AND ReadAt < DATEADD(DAY, -@days, @now);
            """, new { now = clock.GetUtcNow().UtcDateTime, days }, cancellationToken: ct)).ConfigureAwait(false);
        return n == 0 ? null : $"{n} archived";
    }
}
