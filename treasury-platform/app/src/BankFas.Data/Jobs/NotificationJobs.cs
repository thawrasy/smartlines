using System.Globalization;
using BankFas.Core.Mail;
using BankFas.Data.Notifications;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>
/// JOB-NTF-DISPATCH (spec 13 section 9.3, BR-NTF-009): the e-mail deliveries that are due, in the recipient's language
/// from the event's EMAIL template. A failure waits 1 minute, then 5, 30, 2 hours and 12 hours; after the fifth the
/// delivery is DEAD and the account administrators hear once (NTF.DELIVERY_DEAD). The in-app notification is never
/// touched by an e-mail failure.
/// </summary>
public sealed class NotificationDispatchJob(SqlConnectionFactory db, IMailSender mail) : TenantJob(db)
{
    public override string JobKey => "JOB-NTF-DISPATCH";

    private sealed record Due(long NotificationDeliveryId, long NotificationId, int Attempts, string Email, string? PreferredLanguage, long UserId, string? UserName,
        string EventName);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var due = (await c.QueryAsync<Due>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            UPDATE TOP (50) d SET Attempts = Attempts + 1, NextAttemptAt = DATEADD(MINUTE, 10, SYSUTCDATETIME()), Status = 'FAILED', UpdatedAt = SYSUTCDATETIME()
            OUTPUT inserted.NotificationDeliveryId INTO @o
              FROM ntf.NotificationDelivery AS d WITH (UPDLOCK, READPAST, ROWLOCK)
             WHERE d.Channel = 'EMAIL' AND d.Status IN ('PENDING', 'FAILED') AND d.NextAttemptAt <= SYSUTCDATETIME();
            SELECT d.NotificationDeliveryId, d.NotificationId, d.Attempts, u.Email,
                   ISNULL(u.PreferredLanguage, (SELECT DefaultLanguage FROM plat.v_CurrentTenant)) AS PreferredLanguage, u.AppUserId AS UserId,
                   ISNULL(u.DisplayNameAr, u.Email) AS UserName, ISNULL(e.NameEn, e.Code) AS EventName
              FROM @o AS o JOIN ntf.NotificationDelivery AS d ON d.NotificationDeliveryId = o.Id
              JOIN ntf.Notification AS n ON n.NotificationId = d.NotificationId JOIN sec.AppUser AS u ON u.AppUserId = n.UserId
              JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId;
            """, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (due.Count == 0) return null;
        int sent = 0, failed = 0, dead = 0;
        foreach (var d in due)
        {
            try
            {
                var (subject, body) = await Notifier.EmailAsync(c, d.NotificationId, d.PreferredLanguage == "en" ? "en" : "ar", ct).ConfigureAwait(false);
                await mail.SendAsync(new OutgoingMail(d.Email, subject, body), ct).ConfigureAwait(false);
                await c.ExecuteAsync(new CommandDefinition(
                    "UPDATE ntf.NotificationDelivery SET Status = 'SENT', SentAt = SYSUTCDATETIME(), NextAttemptAt = NULL, LastError = NULL WHERE NotificationDeliveryId = @id;",
                    new { id = d.NotificationDeliveryId }, cancellationToken: ct)).ConfigureAwait(false);
                sent++;
            }
            catch (Exception ex) when (ex is IOException or InvalidOperationException or System.Net.Mail.SmtpException)
            {
                var isDead = d.Attempts >= 5;
                // LastError without personal data: the kind of failure only.
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE ntf.NotificationDelivery SET Status = CASE WHEN @dead = 1 THEN 'DEAD' ELSE 'FAILED' END, LastError = @err,
                           NextAttemptAt = CASE WHEN @dead = 1 THEN NULL ELSE DATEADD(MINUTE, @wait, SYSUTCDATETIME()) END
                     WHERE NotificationDeliveryId = @id;
                    """, new { dead = isDead, err = ex.GetType().Name, wait = Wait(d.Attempts), id = d.NotificationDeliveryId }, cancellationToken: ct)).ConfigureAwait(false);
                if (isDead)
                {
                    dead++;
                    await Notifier.RequestAsync(c, null, new NotificationRequest("NTF.DELIVERY_DEAD", "ntf.NotificationDelivery", d.NotificationDeliveryId,
                        $"NTF.DELIVERY_DEAD:{d.NotificationDeliveryId}", Values: new Dictionary<string, object?>
                        {
                            ["channel"] = new Dictionary<string, string> { ["ar"] = "البريد الإلكتروني", ["en"] = "e-mail" }, ["eventName"] = d.EventName, ["userName"] = d.UserName,
                        }), ct).ConfigureAwait(false);
                }
                else failed++;
            }
        }
        return $"sent {sent}, failed {failed}, dead {dead}";
    }

    /// <summary>BR-NTF-009: 1 minute after the first failure, 5 after the second, 30, 2 hours, 12 hours.</summary>
    private static int Wait(int attempts) => attempts switch { 1 => 1, 2 => 5, 3 => 30, 4 => 120, _ => 720 };
}

/// <summary>
/// JOB-NTF-EXPIRY (FR-PLT-038, BR-PLT-013, BR-NTF-002): daily, for each active expiry rule that has a provider, every
/// item with an expiry date: when a lead threshold is crossed the nearest one is sent once (several crossed at the
/// first look give one alert, and the farther ones are recorded so they never come later); on and after the expiry
/// date one EXPIRED alert, then a reminder every ReminderAfterExpiryDays. Each alert is a row of cfg.ExpiryAlertLog
/// keyed by the item's expiry date, so a renewal (a new date) starts again. The recipients are the rule's roles and the
/// event's rules, within the company of the item. What an item is, its event and its values come from its provider
/// (<see cref="ExpiryItemProviders"/>); no provider puts a restricted value in a message.
/// </summary>
public sealed class ExpiryAlertJob(SqlConnectionFactory db, TimeProvider clock, IReadOnlyList<IExpiryItemProvider>? providers = null) : TenantJob(db)
{
    public override string JobKey => "JOB-NTF-EXPIRY";

    private readonly Dictionary<string, IExpiryItemProvider> byType = (providers ?? ExpiryItemProviders.All).ToDictionary(p => p.ItemType, StringComparer.Ordinal);

    private sealed record Rule(long ExpiryAlertRuleId, string ItemType, string LeadDays, bool ScopeByCompany, int? ReminderAfterExpiryDays);

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var today = clock.GetUtcNow().UtcDateTime.Date;
        var rules = (await c.QueryAsync<Rule>(new CommandDefinition(
            "SELECT ExpiryAlertRuleId, ItemType, LeadDays, ScopeByCompany, ReminderAfterExpiryDays FROM cfg.ExpiryAlertRule WHERE IsActive = 1;",
            cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var sent = 0;
        foreach (var rule in rules)
        {
            if (!byType.TryGetValue(rule.ItemType, out var provider)) continue;
            var lead = System.Text.Json.JsonSerializer.Deserialize<int[]>(rule.LeadDays) ?? [];
            var roles = (await c.QueryAsync<long>(new CommandDefinition("SELECT RoleId FROM cfg.ExpiryAlertRuleRole WHERE ExpiryAlertRuleId = @r;",
                new { r = rule.ExpiryAlertRuleId }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
            // An item may carry its own lead days, so the window looks a year ahead at least.
            var horizon = today.AddDays(Math.Max(lead.DefaultIfEmpty(0).Max(), 366));
            var ruleLead = lead;
            foreach (var item in await provider.ItemsAsync(c, today, horizon, ct).ConfigureAwait(false))
            {
                lead = item.LeadDays is { Count: > 0 } own ? [.. own] : ruleLead;
                var days = (item.ExpiryDate.Date - today).Days;
                var logged = (await c.QueryAsync<(string Kind, int Threshold)>(new CommandDefinition(
                    "SELECT AlertKind, Threshold FROM cfg.ExpiryAlertLog WHERE ExpiryAlertRuleId = @r AND ItemId = @i AND ExpiryDate = @e;",
                    new { r = rule.ExpiryAlertRuleId, i = item.Id, e = item.ExpiryDate }, cancellationToken: ct)).ConfigureAwait(false)).ToHashSet();
                string kind;
                int threshold;
                (string Kind, int Threshold)[] alsoRecord = [];
                if (days > 0 || (days == 0 && provider.ExpiredFromNextDay))
                {
                    var crossed = lead.Where(l => days <= l).ToArray();
                    if (crossed.Length == 0 && days > 0) continue;
                    threshold = days == 0 ? 0 : crossed.Min();
                    kind = "LEAD";
                    alsoRecord = [.. crossed.Where(l => l != threshold && !logged.Contains(("LEAD", l))).Select(l => ("LEAD", l))];
                }
                else if (!logged.Contains(("EXPIRED", 0)))
                {
                    kind = "EXPIRED";
                    threshold = 0;
                    // A first notice that arrives late stands for the reminders already due, so a catch-up sends one message.
                    if (rule.ReminderAfterExpiryDays is { } due && -days / due >= 1) alsoRecord = [("REMINDER", -days / due)];
                }
                else if (rule.ReminderAfterExpiryDays is { } every && -days / every >= 1)
                {
                    kind = "REMINDER";
                    threshold = -days / every;
                }
                else continue;
                if (logged.Contains((kind, threshold))) continue;

                await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
                foreach (var (k, th) in alsoRecord.Append((kind, threshold)))
                    await c.ExecuteAsync(new CommandDefinition(
                        """
                        INSERT cfg.ExpiryAlertLog (TenantId, ExpiryAlertRuleId, ItemId, ExpiryDate, AlertKind, Threshold)
                        VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @i, @e, @k, @t);
                        """, new { r = rule.ExpiryAlertRuleId, i = item.Id, e = item.ExpiryDate, k, t = th }, tx, cancellationToken: ct)).ConfigureAwait(false);
                await Notifier.RequestAsync(c, tx, Request(provider, rule, item, kind, threshold, days, roles), ct).ConfigureAwait(false);
                await tx.CommitAsync(ct).ConfigureAwait(false);
                sent++;
            }
        }
        sent += await OwnershipMismatchAsync(c, today, ct).ConfigureAwait(false);
        sent += await StructureChecksAsync(c, today, ct).ConfigureAwait(false);
        return sent == 0 ? null : $"alerts {sent}";
    }

    private sealed class StructureRow
    {
        public string Kind { get; init; } = "";
        public long TargetId { get; init; }
        public long PositionId { get; init; }
        public DateTime Since { get; init; }
        public long CompanyId { get; init; }
        public string? CompanyNameAr { get; init; }
        public string? CompanyNameEn { get; init; }
        public string? BodyNameAr { get; init; }
        public string? BodyNameEn { get; init; }
        public string BodyType { get; init; } = "";
        public string? PartyNameAr { get; init; }
        public string? PartyNameEn { get; init; }
        public string? LabelAr { get; init; }
        public string? LabelEn { get; init; }
    }

    /// <summary>
    /// Two daily checks of the structure, each told once: a single-holder position of an active body that had a holder
    /// and has none today (BODY.TERM_EXPIRY "vacant", FR-ORG-022, owner default OQ-3), and an active grant to a member who
    /// has left the position (GRANT.EXPIRY, FR-ORG-028).
    /// </summary>
    private static async Task<int> StructureChecksAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        var rows = (await c.QueryAsync<StructureRow>(new CommandDefinition(
            """
            SELECT 'VACANT' AS Kind, b.GoverningBodyId AS TargetId, v.PositionId, v.Since, b.CompanyId, co.NameAr AS CompanyNameAr, co.NameEn AS CompanyNameEn,
                   b.NameAr AS BodyNameAr, b.NameEn AS BodyNameEn, b.BodyType, p.NameAr AS PartyNameAr, p.NameEn AS PartyNameEn, pos.NameAr AS LabelAr, pos.NameEn AS LabelEn
              FROM org.GoverningBody AS b JOIN org.Company AS co ON co.CompanyId = b.CompanyId AND co.Status = 'ACTIVE'
             CROSS APPLY (SELECT DISTINCT m.PositionId FROM org.BodyMember AS m JOIN cat.Position AS sp ON sp.PositionId = m.PositionId AND sp.IsSingleHolder = 1
                           WHERE m.BodyId = b.GoverningBodyId) AS sh
             CROSS APPLY (SELECT TOP (1) m.PositionId, m.PartyId, DATEADD(DAY, 1, COALESCE(DATEADD(DAY, -1, m.ResignedOn), m.TermEnd)) AS Since
                            FROM org.BodyMember AS m
                           WHERE m.BodyId = b.GoverningBodyId AND m.PositionId = sh.PositionId AND m.TermStart <= @d
                           ORDER BY m.TermStart DESC) AS v
              JOIN pty.Party AS p ON p.PartyId = v.PartyId JOIN cat.Position AS pos ON pos.PositionId = v.PositionId
             WHERE b.Status = 'ACTIVE' AND v.Since <= @d
            UNION ALL
            SELECT 'HOLDER_LEFT', g.AuthorityGrantId, 0, DATEADD(DAY, 1, COALESCE(DATEADD(DAY, -1, m.ResignedOn), m.TermEnd)), g.CompanyId, co.NameAr, co.NameEn,
                   NULL, NULL, '', hp.NameAr, hp.NameEn, pt.NameAr, pt.NameEn
              FROM org.AuthorityGrant AS g JOIN org.Company AS co ON co.CompanyId = g.CompanyId AND co.Status = 'ACTIVE'
              JOIN org.BodyMember AS m ON m.BodyMemberId = g.BodyMemberId JOIN pty.Party AS hp ON hp.PartyId = m.PartyId
              JOIN cat.PowerType AS pt ON pt.PowerTypeId = g.PowerTypeId
             WHERE g.Status = 'ACTIVE' AND g.GranteeKind = 'BODY_MEMBER' AND COALESCE(DATEADD(DAY, -1, m.ResignedOn), m.TermEnd) < @d;
            """, new { d = today }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        foreach (var r in rows)
        {
            var since = r.Since.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            NotificationRequest request;
            if (r.Kind == "VACANT")
            {
                var type = BodyTermExpiry.BodyTypes.TryGetValue(r.BodyType, out var known) ? known : (Ar: r.BodyType, En: r.BodyType);
                request = new NotificationRequest("BODY.TERM_EXPIRY", "org.GoverningBody", r.TargetId, $"BODY.VACANT:{r.TargetId}:{r.PositionId}:{r.Since:yyyyMMdd}", r.CompanyId,
                    new Dictionary<string, object?>
                    {
                        ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                        ["bodyName"] = ExpiryItemProviders.Text(r.BodyNameAr ?? type.Ar, r.BodyNameEn ?? type.En),
                        ["partyName"] = ExpiryItemProviders.Text(r.PartyNameAr, r.PartyNameEn), ["positionLabel"] = ExpiryItemProviders.Text(r.LabelAr, r.LabelEn),
                        ["expiryDate"] = since, ["daysLeft"] = 0,
                        ["stageLabel"] = new Dictionary<string, string> { ["ar"] = "المنصب شاغر", ["en"] = "the position is vacant" },
                    });
            }
            else
                request = new NotificationRequest("GRANT.EXPIRY", "org.AuthorityGrant", r.TargetId, $"GRANT.HOLDER_LEFT:{r.TargetId}:{r.Since:yyyyMMdd}", r.CompanyId,
                    new Dictionary<string, object?>
                    {
                        ["companyName"] = ExpiryItemProviders.Text(r.CompanyNameAr, r.CompanyNameEn),
                        ["partyName"] = ExpiryItemProviders.Text(r.PartyNameAr, r.PartyNameEn), ["powerTypeLabel"] = ExpiryItemProviders.Text(r.LabelAr, r.LabelEn),
                        ["expiryDate"] = since, ["daysLeft"] = 0,
                        ["stageLabel"] = new Dictionary<string, string> { ["ar"] = "غادر الحامل منصبه", ["en"] = "the holder left the position" },
                    });
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            await Notifier.RequestAsync(c, tx, request, ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        return rows.Count;
    }

    /// <summary>
    /// The daily part of OWN.TOTAL_MISMATCH (spec 13 section 9.2, S1B-GAP-12): an active company whose ownership is
    /// recorded but whose direct holdings do not total 100% today; once a day per company. A company with no holding
    /// recorded yet is listed by the report, not notified every day.
    /// </summary>
    private static async Task<int> OwnershipMismatchAsync(SqlConnection c, DateTime today, CancellationToken ct)
    {
        var rows = (await c.QueryAsync<(long CompanyId, string NameAr, string? NameEn, decimal Total)>(new CommandDefinition(
            """
            SELECT co.CompanyId, co.NameAr, co.NameEn,
                   ISNULL(SUM(CASE WHEN s.Layer = 1 AND s.EffectiveFrom <= @d AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @d) THEN s.SharePercent END), 0)
              FROM org.Company AS co JOIN org.Shareholding AS s ON s.CompanyId = co.CompanyId
             WHERE co.Status = 'ACTIVE'
             GROUP BY co.CompanyId, co.NameAr, co.NameEn
            HAVING ISNULL(SUM(CASE WHEN s.Layer = 1 AND s.EffectiveFrom <= @d AND (s.EffectiveTo IS NULL OR s.EffectiveTo >= @d) THEN s.SharePercent END), 0) <> 100;
            """, new { d = today }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        foreach (var r in rows)
        {
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
            await Notifier.RequestAsync(c, tx, new NotificationRequest("OWN.TOTAL_MISMATCH", "org.Company", r.CompanyId, $"OWN.TOTAL_MISMATCH:{r.CompanyId}:{today:yyyyMMdd}",
                r.CompanyId, new Dictionary<string, object?>
                {
                    ["companyName"] = ExpiryItemProviders.Text(r.NameAr, r.NameEn),
                    ["totalPercent"] = r.Total.ToString("0.######", CultureInfo.InvariantCulture),
                }), ct).ConfigureAwait(false);
            await tx.CommitAsync(ct).ConfigureAwait(false);
        }
        return rows.Count;
    }

    private static NotificationRequest Request(IExpiryItemProvider provider, Rule rule, ExpiryItem item, string kind, int threshold, int days, IReadOnlyList<long> roles)
    {
        var stage = kind switch
        {
            "LEAD" when threshold == 0 => new Dictionary<string, string> { ["ar"] = "ينتهي اليوم", ["en"] = "expires today" },
            "LEAD" => new Dictionary<string, string> { ["ar"] = $"بقي {threshold} يومًا أو أقل", ["en"] = $"{threshold} days or fewer left" },
            // An item valid through its date (a signatory, BR-ACC-017) ends at the close of that day.
            "EXPIRED" when days == 0 && provider.ValidThroughExpiryDate => new Dictionary<string, string> { ["ar"] = "ينتهي اليوم", ["en"] = "expires today" },
            "EXPIRED" => new Dictionary<string, string> { ["ar"] = "انتهى", ["en"] = "expired" },
            _ => new Dictionary<string, string> { ["ar"] = $"منتهٍ، التذكير {threshold}", ["en"] = $"expired, reminder {threshold}" },
        };
        var values = new Dictionary<string, object?>(item.Values, StringComparer.Ordinal)
        {
            ["expiryDate"] = item.ExpiryDate.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            ["daysLeft"] = Math.Max(days, 0),
            ["stageLabel"] = stage,
        };
        var code = provider.EventCodeFor(kind);
        var target = item.TargetType ?? provider.TargetType;
        return new NotificationRequest(code, target, Math.Abs(item.Id), $"{code}:{target}:{Math.Abs(item.Id)}:{kind}{threshold}:{item.ExpiryDate:yyyyMMdd}",
            rule.ScopeByCompany ? item.CompanyId : null, values, RecipientRoleIds: roles);
    }
}
