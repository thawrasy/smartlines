using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Notifications;

/// <summary>
/// A request for a notification (spec 13 section 9.2): the event code, its target, the key that keeps it from being
/// sent twice to one user (BR-NTF-002), the company it belongs to (or none), and the values of the template's
/// placeholders. A value is a text or { "ar": ..., "en": ... }; none is ever a restricted value (BR-NTF-008).
/// </summary>
public sealed record NotificationRequest(string EventCode, string TargetType, long TargetId, string DedupKey, long? CompanyId = null,
    IReadOnlyDictionary<string, object?>? Values = null, string? DeepLink = null, long? ActorUserId = null, IReadOnlyList<long>? RecipientUserIds = null,
    IReadOnlyList<long>? RecipientRoleIds = null);

/// <summary>
/// The notification pipeline of S1 (FR-NTF-002 to 007, FR-NTF-021; BR-NTF-001 to 003, 008, 014; S1 brief S1-GAP-3): a
/// request is an outbox event notification.requested written in the transaction of the change; JOB-PLT-OUTBOX turns
/// it into one ntf.Notification per recipient with its deliveries. Recipients come from the event's active rules (a
/// role, a permission or a user) and from the request itself (the roles of an expiry rule, the user concerned); then
/// only active users, within the company scope when the event has a company and the rule asks for it, never the
/// actor, each once. The text is the template of the recipient's language, the tenant's override first; in-app is
/// always delivered (a mandatory event cannot be switched off, BR-NTF-003), e-mail when the event's channels have it
/// and the user's preference is not OFF. A second delivery of the same request makes nothing new: (user, DedupKey)
/// is unique.
/// </summary>
public static partial class Notifier
{
    public const string EventName = "notification.requested";

    [GeneratedRegex(@"\{(\w+)\}", RegexOptions.CultureInvariant)]
    private static partial Regex Placeholder();

    /// <summary>
    /// Writes the request into the outbox, in the caller's transaction when it has one. Its aggregate is "ntf." and the
    /// target type, so the request is not held behind the target's own domain events (the outbox delivers an
    /// aggregate's events in order).
    /// </summary>
    public static Task RequestAsync(SqlConnection c, SqlTransaction? tx, NotificationRequest r, CancellationToken ct) =>
        Outbox.EmitAsync(c, tx, EventName, ("ntf." + r.TargetType) is { Length: > 60 } a ? a[..60] : "ntf." + r.TargetType, r.TargetId, new
        {
            eventCode = r.EventCode, targetType = r.TargetType, targetId = r.TargetId, dedupKey = r.DedupKey, companyId = r.CompanyId, deepLink = r.DeepLink,
            actorUserId = r.ActorUserId, recipientUserIds = r.RecipientUserIds, recipientRoleIds = r.RecipientRoleIds, values = r.Values,
        }, ct);

    private sealed record EventType(int NotificationEventTypeId, string Code, string GroupKey, string DefaultSeverity, bool IsMandatory, bool IsActionRequired,
        string? DefaultChannels, string? NameAr, string? NameEn);

    private sealed record Recipient(long AppUserId, string Email, string? PreferredLanguage, string CompanyScopeMode, int NeedsScope);

    /// <summary>BR-NTF-001 (3): the company is one of the user's, or under one chosen with its descendants.</summary>
    private static async Task<bool> InScopeAsync(SqlConnection c, long userId, long companyId, CancellationToken ct) =>
        await c.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            WITH tree AS (
                SELECT co.CompanyId, s.IncludeDescendants FROM sec.UserCompanyScope AS s JOIN org.Company AS co ON co.CompanyId = s.CompanyId WHERE s.UserId = @u
                UNION ALL
                SELECT ch.CompanyId, t.IncludeDescendants FROM org.Company AS ch JOIN tree AS t ON ch.ParentCompanyId = t.CompanyId WHERE t.IncludeDescendants = 1)
            SELECT COUNT(*) FROM tree WHERE CompanyId = @c OPTION (MAXRECURSION 20);
            """, new { u = userId, c = companyId }, cancellationToken: ct)).ConfigureAwait(false) > 0;

    /// <summary>The consumer of one notification.requested event; returns the number of notifications created.</summary>
    public static async Task<int> ConsumeAsync(SqlConnection c, Guid messageId, string payloadJson, CancellationToken ct)
    {
        using var doc = JsonDocument.Parse(payloadJson);
        var p = doc.RootElement;
        var code = p.GetProperty("eventCode").GetString() ?? throw new InvalidOperationException("A notification request names its event.");
        var ev = await c.QuerySingleOrDefaultAsync<EventType>(new CommandDefinition(
            """
            SELECT NotificationEventTypeId, Code, GroupKey, DefaultSeverity, IsMandatory, IsActionRequired, DefaultChannels, NameAr, NameEn
              FROM ntf.NotificationEventType WHERE Code = @code;
            """, new { code }, cancellationToken: ct)).ConfigureAwait(false)
            ?? throw new InvalidOperationException($"The event {code} is not in the tenant's catalogue (pack NTF.BASE).");
        long? companyId = Long(p, "companyId");
        var targetType = p.GetProperty("targetType").GetString()!;
        var targetId = p.GetProperty("targetId").GetInt64();
        var dedup = p.TryGetProperty("dedupKey", out var dk) && dk.GetString() is { Length: > 0 } d ? d : $"{code}:{messageId}";
        if (dedup.Length > 200) dedup = dedup[..200];
        var actor = Long(p, "actorUserId");
        var extraUsers = Longs(p, "recipientUserIds");
        var extraRoles = Longs(p, "recipientRoleIds");

        // BR-NTF-001 (1) to (3) and (5): candidates from the rules and the request, active, in the company scope when asked, not the actor.
        var recipients = (await c.QueryAsync<Recipient>(new CommandDefinition(
            """
            WITH cand AS (
                SELECT ur.UserId, r.RequireCompanyScope FROM ntf.NotificationRule AS r JOIN sec.UserRole AS ur ON ur.RoleId = r.RoleId
                 WHERE r.EventTypeId = @ev AND r.IsActive = 1 AND r.RecipientKind = 'ROLE'
                UNION ALL
                SELECT ur.UserId, r.RequireCompanyScope FROM ntf.NotificationRule AS r JOIN sec.RolePermission AS rp ON rp.PermissionId = r.PermissionId
                  JOIN sec.Role AS ro ON ro.RoleId = rp.RoleId AND ro.IsActive = 1 JOIN sec.UserRole AS ur ON ur.RoleId = ro.RoleId
                 WHERE r.EventTypeId = @ev AND r.IsActive = 1 AND r.RecipientKind = 'PERMISSION'
                UNION ALL
                SELECT r.UserId, r.RequireCompanyScope FROM ntf.NotificationRule AS r WHERE r.EventTypeId = @ev AND r.IsActive = 1 AND r.RecipientKind = 'USER'
                UNION ALL
                SELECT ur.UserId, CAST(1 AS BIT) FROM sec.UserRole AS ur WHERE ur.RoleId IN @roles
                UNION ALL
                SELECT u.AppUserId, CAST(0 AS BIT) FROM sec.AppUser AS u WHERE u.AppUserId IN @users)
            SELECT u.AppUserId, u.Email, ISNULL(u.PreferredLanguage, (SELECT DefaultLanguage FROM plat.v_CurrentTenant)) AS PreferredLanguage, u.CompanyScopeMode,
                   MIN(CAST(cand.RequireCompanyScope AS INT)) AS NeedsScope
              FROM sec.AppUser AS u JOIN cand ON cand.UserId = u.AppUserId
             WHERE u.Status = 'ACTIVE' AND u.IsSystemUser = 0 AND u.ArchivedAt IS NULL AND u.AppUserId <> ISNULL(@actor, -1)
             GROUP BY u.AppUserId, u.Email, u.PreferredLanguage, u.CompanyScopeMode;
            """,
            new
            {
                ev = ev.NotificationEventTypeId, roles = extraRoles.DefaultIfEmpty(-1).ToArray(), users = extraUsers.DefaultIfEmpty(-1).ToArray(), actor,
            }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (companyId is { } company)
        {
            var kept = new List<Recipient>();
            foreach (var r in recipients)
                if (r.NeedsScope == 0 || r.CompanyScopeMode == "ALL" || await InScopeAsync(c, r.AppUserId, company, ct).ConfigureAwait(false)) kept.Add(r);
            recipients = kept;
        }
        if (recipients.Count == 0) return 0;

        var templates = (await c.QueryAsync<(string Channel, string Lang, string Subject, string Body, bool IsTenantOverride)>(new CommandDefinition(
            "SELECT Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride FROM ntf.NotificationTemplate WHERE EventTypeId = @ev;",
            new { ev = ev.NotificationEventTypeId }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        var values = await ValuesAsync(c, code, messageId, p, ct).ConfigureAwait(false);
        var emailChannel = ev.DefaultChannels?.Contains("EMAIL", StringComparison.Ordinal) == true;
        var prefs = (await c.QueryAsync<(long UserId, string Channel, string Mode)>(new CommandDefinition(
            "SELECT UserId, Channel, Mode FROM ntf.NotificationPreference WHERE GroupKey = @g AND UserId IN @ids;",
            new { g = ev.GroupKey, ids = recipients.Select(r => r.AppUserId).ToArray() }, cancellationToken: ct)).ConfigureAwait(false))
            .ToDictionary(x => (x.UserId, x.Channel), x => x.Mode);
        var severity = p.TryGetProperty("severity", out var sv) && sv.GetString() is { } s && s is "INFO" or "WARNING" or "HIGH" ? s : ev.DefaultSeverity;
        var deepLink = p.TryGetProperty("deepLink", out var dl) && dl.ValueKind == JsonValueKind.String ? dl.GetString() : values.GetValueOrDefault("deepLink")?.Invoke("en");
        var created = 0;
        foreach (var r in recipients)
        {
            var lang = r.PreferredLanguage == "en" ? "en" : "ar";
            var (subject, body) = Render(templates, "IN_APP", lang, values, ev);
            // In-app always for a mandatory event; otherwise unless the user switched the group off (BR-NTF-003).
            var inApp = ev.IsMandatory || prefs.GetValueOrDefault((r.AppUserId, "IN_APP")) != "OFF";
            var emailMode = prefs.GetValueOrDefault((r.AppUserId, "EMAIL"));
            var email = emailChannel && emailMode != "OFF";
            // A digest holds the e-mail without a send time for JOB-NTF-DIGEST; a mandatory event is never held (FR-NTF-014).
            var digest = email && !ev.IsMandatory && emailMode is "DIGEST_DAILY" or "DIGEST_WEEKLY";
            if (!inApp && !email) continue;
            var id = await c.ExecuteScalarAsync<long?>(new CommandDefinition(
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT ntf.Notification (TenantId, UserId, EventTypeId, CompanyId, Severity, Title, Body, TargetEntityType, TargetEntityId, DeepLink, ActionRequired,
                                         ActionState, DedupKey, PayloadJson, SourceEventId)
                OUTPUT inserted.NotificationId INTO @o
                SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), @user, @ev, @company, @severity, @title, @body, @type, @target, @link, @action,
                       CASE WHEN @action = 1 THEN 'OPEN' ELSE 'NONE' END, @dedup, @payload, @source
                 WHERE NOT EXISTS (SELECT 1 FROM ntf.Notification WHERE UserId = @user AND DedupKey = @dedup);
                SELECT Id FROM @o;
                """,
                new
                {
                    user = r.AppUserId, ev = ev.NotificationEventTypeId, company = companyId, severity, title = Cut(subject, 300), body = Cut(body, 2000), type = targetType,
                    target = targetId, link = deepLink is null ? null : Cut(deepLink, 300), action = ev.IsActionRequired, dedup, payload = payloadJson, source = messageId,
                }, cancellationToken: ct)).ConfigureAwait(false);
            if (id is null) continue;
            await c.ExecuteAsync(new CommandDefinition(
                """
                INSERT ntf.NotificationDelivery (TenantId, NotificationId, Channel, Status, SentAt)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @n, 'IN_APP', CASE WHEN @inApp = 1 THEN 'SENT' ELSE 'SUPPRESSED' END,
                        CASE WHEN @inApp = 1 THEN SYSUTCDATETIME() END);
                IF @email = 1
                    INSERT ntf.NotificationDelivery (TenantId, NotificationId, Channel, Status, NextAttemptAt)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @n, 'EMAIL', 'PENDING', CASE WHEN @digest = 1 THEN NULL ELSE SYSUTCDATETIME() END);
                """, new { n = id, inApp, email, digest }, cancellationToken: ct)).ConfigureAwait(false);
            created++;
        }
        return created;
    }

    /// <summary>The value of each placeholder in each language: from the request, or for the early warnings from fin.v_EarlyWarningMessageValues.</summary>
    private static async Task<Dictionary<string, Func<string, string>>> ValuesAsync(SqlConnection c, string code, Guid messageId, JsonElement p, CancellationToken ct)
    {
        var values = new Dictionary<string, Func<string, string>>(StringComparer.Ordinal);
        if (p.TryGetProperty("values", out var v) && v.ValueKind == JsonValueKind.Object)
        {
            foreach (var x in v.EnumerateObject())
            {
                var e = x.Value.Clone();
                values[x.Name] = e.ValueKind switch
                {
                    JsonValueKind.Object => lang => (e.TryGetProperty(lang, out var t) ? t : e.TryGetProperty("en", out var en) ? en : default).ToString(),
                    JsonValueKind.Null or JsonValueKind.Undefined => _ => "",
                    _ => _ => e.ToString(),
                };
            }
        }
        if (code.StartsWith("FIN.READINESS_", StringComparison.Ordinal))
        {
            var row = (IDictionary<string, object?>?)await c.QuerySingleOrDefaultAsync(new CommandDefinition(
                "SELECT * FROM fin.v_EarlyWarningMessageValues WHERE MessageId = @m;", new { m = messageId }, cancellationToken: ct)).ConfigureAwait(false);
            if (row is not null)
            {
                foreach (var (key, column) in FinMap)
                {
                    values[key] = lang => Text(row.TryGetValue(column + (lang == "ar" ? "Ar" : "En"), out var l) ? l : row.TryGetValue(column, out var plain) ? plain : null);
                }
                values["deepLink"] = _ => Text(row.TryGetValue("DeepLink", out var link) ? link : null);
            }
        }
        return values;
    }

    /// <summary>The placeholders of the early warnings and their columns (the manifest of NTF.BASE).</summary>
    private static readonly (string Key, string Column)[] FinMap =
    [
        ("companyName", "CompanyName"), ("eventLabel", "EventLabel"), ("reference", "Reference"), ("eventDate", "EventDate"), ("daysLeft", "DaysLeft"),
        ("stageLabel", "StageLabel"), ("reason", "Reason"), ("grade", "Grade"), ("liquidity", "Liquidity"), ("leadMonths", "LeadMonths"),
    ];

    private static string Text(object? o) => o switch
    {
        null => "",
        IFormattable f => f.ToString(null, CultureInfo.InvariantCulture),
        _ => o.ToString() ?? "",
    };

    /// <summary>The subject and body of a channel in a language: the tenant's override, else the seed, else the other language, else the event's name.</summary>
    internal static (string Subject, string Body) Render(IReadOnlyList<(string Channel, string Lang, string Subject, string Body, bool IsTenantOverride)> templates, string channel,
        string lang, IReadOnlyDictionary<string, Func<string, string>> values, object ev)
    {
        var t = templates.Where(x => x.Channel == channel && x.Lang == lang).OrderByDescending(x => x.IsTenantOverride).FirstOrDefault();
        if (t.Subject is null) t = templates.Where(x => x.Channel == channel).OrderByDescending(x => x.IsTenantOverride).FirstOrDefault();
        if (t.Subject is null)
        {
            var name = ev is EventType e ? (lang == "ar" ? e.NameAr ?? e.NameEn : e.NameEn ?? e.NameAr) ?? e.Code : "";
            return (name, name);
        }
        string Fill(string text) => Placeholder().Replace(text, m => values.TryGetValue(m.Groups[1].Value, out var f) ? f(lang) : "");
        return (Fill(t.Subject), Fill(t.Body));
    }

    private static string Cut(string s, int max) => s.Length <= max ? s : s[..(max - 1)] + "…";

    private static long? Long(JsonElement p, string name) =>
        p.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : null;

    private static long[] Longs(JsonElement p, string name) =>
        p.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Array ? [.. v.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.Number).Select(x => x.GetInt64())] : [];

    /// <summary>The text of a stored notification's e-mail, rendered at sending from its event's EMAIL template and its request.</summary>
    public static async Task<(string Subject, string Body)> EmailAsync(SqlConnection c, long notificationId, string lang, CancellationToken ct)
    {
        var n = await c.QuerySingleAsync<(int EventTypeId, string Code, string? PayloadJson, Guid? Source, string Title, string Body)>(new CommandDefinition(
            """
            SELECT n.EventTypeId, e.Code, n.PayloadJson, n.SourceEventId, n.Title, n.Body FROM ntf.Notification AS n
              JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId WHERE n.NotificationId = @n;
            """, new { n = notificationId }, cancellationToken: ct)).ConfigureAwait(false);
        var templates = (await c.QueryAsync<(string Channel, string Lang, string Subject, string Body, bool IsTenantOverride)>(new CommandDefinition(
            "SELECT Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride FROM ntf.NotificationTemplate WHERE EventTypeId = @ev AND Channel = 'EMAIL';",
            new { ev = n.EventTypeId }, cancellationToken: ct)).ConfigureAwait(false)).ToList();
        if (templates.Count == 0 || n.PayloadJson is null) return (n.Title, n.Body);
        using var doc = JsonDocument.Parse(n.PayloadJson);
        var values = await ValuesAsync(c, n.Code, n.Source ?? Guid.Empty, doc.RootElement, ct).ConfigureAwait(false);
        var (subject, body) = Render(templates, "EMAIL", lang, values, new object());
        var sb = new StringBuilder(body.Replace("\n", "\r\n", StringComparison.Ordinal)).Append("\r\n");
        return (subject, sb.ToString());
    }
}
