using System.Text.Json;
using System.Text.RegularExpressions;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record NotificationPreferenceRequest(List<NotificationPreferenceItem>? Items);
public sealed record NotificationPreferenceItem(string? GroupKey, string? Channel, string? Mode);
public sealed record NotificationRuleRequest(string? RecipientKind, string? Role, string? Permission, bool? RequireCompanyScope, bool? IsActive);
public sealed record NotificationTemplateRequest(string? Subject, string? Body);

/// <summary>
/// The user's notifications and the tenant's notification settings (FR-NTF-003, 005, 006, 010, 012, 019; spec 13
/// section 6.3). Each user sees only their own notifications: the bell with its unread and action counters, read,
/// read all, archive. Preferences are per event group and channel; a mandatory event stays in the application
/// whatever the preference (BR-NTF-003). The e-mail of a group may also come as a daily or weekly digest (S5, FR-NTF-014);
/// the application channel is IMMEDIATE or OFF. The account
/// administrator adds or stops recipients (a mandatory one stays, V-NTF-02) and overrides a text with placeholders
/// from the event's list only (V-NTF-01); deleting the override brings back the default.
/// </summary>
public static partial class NotificationEndpoints
{
    private const string Prefs = "ntf.prefs";
    private const string Manage = "ntf.manage";
    private const string Log = "ntf.log.view";
    private static readonly string[] Modes = ["IMMEDIATE", "DIGEST_DAILY", "DIGEST_WEEKLY", "OFF"];
    private static readonly string[] Channels = ["IN_APP", "EMAIL"];

    [GeneratedRegex(@"\{(\w+)\}", RegexOptions.CultureInvariant)]
    private static partial Regex Placeholder();

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/notifications", ListAsync);
        api.MapPost("/notifications/actions/read-all", ReadAllAsync);
        api.MapPost("/notifications/{id:guid}/actions/read", (Guid id, HttpContext h, SqlConnectionFactory d) => MarkAsync(id, "read", h, d));
        api.MapPost("/notifications/{id:guid}/actions/archive", (Guid id, HttpContext h, SqlConnectionFactory d) => MarkAsync(id, "archive", h, d));
        api.MapGet("/notification-preferences", PreferencesAsync);
        api.MapPut("/notification-preferences", SetPreferencesAsync);
        api.MapGet("/notification-events", EventsAsync);
        api.MapPost("/notification-events/{code}/rules", AddRuleAsync);
        api.MapPatch("/notification-events/{code}/rules/{reference}", PatchRuleAsync);
        api.MapPut("/notification-events/{code}/templates/{channel}/{lang}", SetTemplateAsync);
        api.MapDelete("/notification-events/{code}/templates/{channel}/{lang}", ResetTemplateAsync);
        api.MapGet("/notification-deliveries", DeliveriesAsync);
    }

    // ---------- the bell ----------

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "unread", "archived", "limit");
        await using var u = await BoundUser.OpenAsync(http, db, Prefs);
        var q = http.Request.Query;
        var limit = int.TryParse(q["limit"], out var l) ? Math.Clamp(l, 1, 200) : 50;
        var rows = await u.Connection.QueryAsync<(Guid Id, string Event, string Severity, string Title, string Body, string? DeepLink, DateTime CreatedAt, DateTime? ReadAt,
            bool ActionRequired, string ActionState, string TargetType)>(new CommandDefinition(
            """
            SELECT TOP (@limit) n.PublicId, e.Code, n.Severity, n.Title, n.Body, n.DeepLink, n.CreatedAt, n.ReadAt, n.ActionRequired, n.ActionState, n.TargetEntityType
              FROM ntf.Notification AS n JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId
             WHERE n.UserId = @u AND (@archived = 1 OR n.ArchivedAt IS NULL) AND (@unread = 0 OR n.ReadAt IS NULL)
             ORDER BY n.CreatedAt DESC, n.NotificationId DESC;
            """,
            new
            {
                limit, u = u.UserId, archived = string.Equals(q["archived"], "true", StringComparison.OrdinalIgnoreCase),
                unread = string.Equals(q["unread"], "true", StringComparison.OrdinalIgnoreCase),
            }, cancellationToken: http.RequestAborted));
        var (unread, action) = await u.Connection.QuerySingleAsync<(int Unread, int Action)>(new CommandDefinition(
            """
            SELECT (SELECT COUNT(*) FROM ntf.Notification WHERE UserId = @u AND ReadAt IS NULL AND ArchivedAt IS NULL),
                   (SELECT COUNT(*) FROM ntf.Notification WHERE UserId = @u AND ActionState = 'OPEN');
            """, new { u = u.UserId }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            unreadCount = unread, actionCount = action,
            items = rows.Select(n => new
            {
                id = n.Id, eventCode = n.Event, severity = n.Severity, title = n.Title, body = n.Body, deepLink = n.DeepLink, createdAt = n.CreatedAt, readAt = n.ReadAt,
                actionRequired = n.ActionRequired, actionState = n.ActionState, targetType = n.TargetType,
            }),
        });
    }

    private static async Task<IResult> MarkAsync(Guid id, string action, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Prefs);
        // A mandatory notification is archived only once read (BR-NTF-011).
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(action == "read"
            ? "UPDATE ntf.Notification SET ReadAt = ISNULL(ReadAt, SYSUTCDATETIME()), UpdatedAt = SYSUTCDATETIME() WHERE PublicId = @id AND UserId = @u;"
            : "UPDATE ntf.Notification SET ReadAt = ISNULL(ReadAt, SYSUTCDATETIME()), ArchivedAt = ISNULL(ArchivedAt, SYSUTCDATETIME()), UpdatedAt = SYSUTCDATETIME() WHERE PublicId = @id AND UserId = @u;",
            new { id, u = u.UserId }, cancellationToken: http.RequestAborted));
        return n == 0 ? throw ApiProblemException.NotFound() : Results.NoContent();
    }

    private static async Task<IResult> ReadAllAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Prefs);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE ntf.Notification SET ReadAt = SYSUTCDATETIME(), UpdatedAt = SYSUTCDATETIME() WHERE UserId = @u AND ReadAt IS NULL;", new { u = u.UserId },
            cancellationToken: http.RequestAborted));
        return Results.Ok(new { read = n });
    }

    // ---------- preferences (FR-NTF-010) ----------

    private static async Task<IResult> PreferencesAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Prefs);
        var groups = await u.Connection.QueryAsync<(string GroupKey, bool Mandatory, bool Email)>(new CommandDefinition(
            """
            SELECT GroupKey, CAST(MAX(CAST(IsMandatory AS INT)) AS BIT), CAST(MAX(CASE WHEN DefaultChannels LIKE '%EMAIL%' THEN 1 ELSE 0 END) AS BIT)
              FROM ntf.NotificationEventType GROUP BY GroupKey ORDER BY GroupKey;
            """, cancellationToken: http.RequestAborted));
        var mine = (await u.Connection.QueryAsync<(string GroupKey, string Channel, string Mode)>(new CommandDefinition(
            "SELECT GroupKey, Channel, Mode FROM ntf.NotificationPreference WHERE UserId = @u;", new { u = u.UserId }, cancellationToken: http.RequestAborted)))
            .ToDictionary(x => (x.GroupKey, x.Channel), x => x.Mode);
        return Results.Ok(new
        {
            items = groups.Select(g => new
            {
                groupKey = g.GroupKey, mandatoryInApp = g.Mandatory, emailAvailable = g.Email,
                inApp = g.Mandatory ? "IMMEDIATE" : mine.GetValueOrDefault((g.GroupKey, "IN_APP"), "IMMEDIATE"),
                email = mine.GetValueOrDefault((g.GroupKey, "EMAIL"), "IMMEDIATE"),
            }),
        });
    }

    private static async Task<IResult> SetPreferencesAsync(NotificationPreferenceRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Prefs);
        var ct = http.RequestAborted;
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(ct);
        foreach (var item in b.Items ?? [])
        {
            var group = item.GroupKey?.Trim().ToUpperInvariant();
            var channel = item.Channel?.Trim().ToUpperInvariant();
            var mode = item.Mode?.Trim().ToUpperInvariant();
            if (channel is null || !Channels.Contains(channel)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The channel is IN_APP or EMAIL.");
            if (mode is null || !Modes.Contains(mode)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The mode is IMMEDIATE, DIGEST_DAILY, DIGEST_WEEKLY or OFF.");
            if (channel == "IN_APP" && mode.StartsWith("DIGEST", StringComparison.Ordinal))
                throw ApiProblemException.Invalid("VALIDATION_FAILED", "A digest is by e-mail; the application shows each notification.");
            var mandatory = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT MAX(CAST(IsMandatory AS INT)) FROM ntf.NotificationEventType WHERE GroupKey = @g;", new { g = group }, tx, cancellationToken: ct))
                ?? throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a notification group.");
            if (mandatory == 1 && channel == "IN_APP" && mode == "OFF")
                throw ApiProblemException.Invalid("V-NTF-MANDATORY", "This group has mandatory notifications: they stay in the application.");
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                UPDATE ntf.NotificationPreference SET Mode = @mode, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = @u WHERE UserId = @u AND GroupKey = @g AND Channel = @c;
                IF @@ROWCOUNT = 0
                    INSERT ntf.NotificationPreference (TenantId, UserId, GroupKey, Channel, Mode, CreatedBy)
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @u, @g, @c, @mode, @u);
                """, new { mode, u = u.UserId, g = group, c = channel }, tx, cancellationToken: ct));
        }
        await tx.CommitAsync(ct);
        return Results.NoContent();
    }

    // ---------- rules and templates (FR-NTF-003, FR-NTF-012) ----------

    private sealed record EventRow(int NotificationEventTypeId, string Code, string OwnerModule, string GroupKey, string? NameAr, string? NameEn, string DefaultSeverity,
        bool IsMandatory, string? DefaultChannels, string? AllowedPlaceholdersJson);

    private static async Task<EventRow> EventAsync(SqlConnection c, SqlTransaction? tx, string code, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<EventRow>(new CommandDefinition(
            """
            SELECT NotificationEventTypeId, Code, OwnerModule, GroupKey, NameAr, NameEn, DefaultSeverity, IsMandatory, DefaultChannels, AllowedPlaceholdersJson
              FROM ntf.NotificationEventType WHERE Code = @code;
            """, new { code = code.Trim().ToUpperInvariant() }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    private static async Task<IResult> EventsAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        var events = (await u.Connection.QueryAsync<EventRow>(new CommandDefinition(
            """
            SELECT NotificationEventTypeId, Code, OwnerModule, GroupKey, NameAr, NameEn, DefaultSeverity, IsMandatory, DefaultChannels, AllowedPlaceholdersJson
              FROM ntf.NotificationEventType ORDER BY OwnerModule, Code;
            """, cancellationToken: ct))).ToList();
        var rules = (await u.Connection.QueryAsync<(int Id, int EventId, string Kind, string? Role, string? Permission, bool Scope, bool Mandatory, bool Active)>(new CommandDefinition(
            """
            SELECT r.NotificationRuleId, r.EventTypeId, r.RecipientKind, ro.Code, p.Code, r.RequireCompanyScope, r.IsMandatory, r.IsActive
              FROM ntf.NotificationRule AS r LEFT JOIN sec.Role AS ro ON ro.RoleId = r.RoleId LEFT JOIN sec.Permission AS p ON p.PermissionId = r.PermissionId;
            """, cancellationToken: ct))).ToLookup(r => r.EventId);
        var templates = (await u.Connection.QueryAsync<(int EventId, string Channel, string Lang, string Subject, string Body, bool Override)>(new CommandDefinition(
            "SELECT EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride FROM ntf.NotificationTemplate;", cancellationToken: ct))).ToLookup(t => t.EventId);
        return Results.Ok(new
        {
            items = events.Select(e => new
            {
                code = e.Code, ownerModule = e.OwnerModule, groupKey = e.GroupKey, nameAr = e.NameAr, nameEn = e.NameEn, severity = e.DefaultSeverity, isMandatory = e.IsMandatory,
                channels = e.DefaultChannels is null ? null : JsonSerializer.Deserialize<string[]>(e.DefaultChannels),
                placeholders = e.AllowedPlaceholdersJson is null ? [] : JsonSerializer.Deserialize<string[]>(e.AllowedPlaceholdersJson),
                rules = rules[e.NotificationEventTypeId].Select(r => new
                {
                    id = refs.ItemRef(u.TenantId, "notification-rule", r.Id), recipientKind = r.Kind, role = r.Role, permission = r.Permission, requireCompanyScope = r.Scope,
                    isMandatory = r.Mandatory, isActive = r.Active,
                }),
                templates = templates[e.NotificationEventTypeId].Select(t => new { channel = t.Channel, lang = t.Lang, subject = t.Subject, body = t.Body, isTenantOverride = t.Override }),
            }),
        });
    }

    private static async Task<IResult> AddRuleAsync(string code, NotificationRuleRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        var e = await EventAsync(u.Connection, null, code, ct);
        var kind = b.RecipientKind?.Trim().ToUpperInvariant();
        long? roleId = null;
        int? permissionId = null;
        switch (kind)
        {
            case "ROLE":
                roleId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition("SELECT RoleId FROM sec.Role WHERE Code = @c AND IsActive = 1;",
                    new { c = b.Role?.Trim().ToUpperInvariant() }, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-NTF-02", "Choose an active role.");
                break;
            case "PERMISSION":
                permissionId = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT PermissionId FROM sec.Permission WHERE Code = @c AND IsActive = 1;",
                    new { c = b.Permission?.Trim() }, cancellationToken: ct)) ?? throw ApiProblemException.Invalid("V-NTF-02", "Choose a permission of the catalogue.");
                break;
            default:
                throw ApiProblemException.Invalid("V-NTF-02", "A recipient is a role or the holders of a permission.");
        }
        var exists = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            "SELECT COUNT(*) FROM ntf.NotificationRule WHERE EventTypeId = @e AND RecipientKind = @k AND (RoleId = @r OR PermissionId = @p);",
            new { e = e.NotificationEventTypeId, k = kind, r = roleId, p = permissionId }, cancellationToken: ct));
        if (exists > 0) throw new ApiProblemException(409, "V-NTF-02", "This recipient is already a rule of the event: activate it.");
        var id = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id INT);
            INSERT ntf.NotificationRule (TenantId, EventTypeId, RecipientKind, RoleId, PermissionId, RequireCompanyScope, IsMandatory, IsActive, CreatedBy)
            OUTPUT inserted.NotificationRuleId INTO @o
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @e, @k, @r, @p, @scope, 0, 1, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            SELECT Id FROM @o;
            """, new { e = e.NotificationEventTypeId, k = kind, r = roleId, p = permissionId, scope = b.RequireCompanyScope ?? true }, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("NOTIFICATION_RULE_ADDED", "CONFIG", "ntf.NotificationRule", id,
            AfterJson: JsonSerializer.Serialize(new { e.Code, kind, b.Role, b.Permission })), null, ct);
        return Results.Created((string?)null, new { id = refs.ItemRef(u.TenantId, "notification-rule", id) });
    }

    /// <summary>V-NTF-02: a mandatory recipient cannot be stopped.</summary>
    private static async Task<IResult> PatchRuleAsync(string code, string reference, NotificationRuleRequest b, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        var e = await EventAsync(u.Connection, null, code, ct);
        var id = refs.ItemId(u.TenantId, "notification-rule", reference) ?? throw ApiProblemException.NotFound();
        var mandatory = await u.Connection.ExecuteScalarAsync<bool?>(new CommandDefinition(
            "SELECT IsMandatory FROM ntf.NotificationRule WHERE NotificationRuleId = @id AND EventTypeId = @e;", new { id, e = e.NotificationEventTypeId }, cancellationToken: ct))
            ?? throw ApiProblemException.NotFound();
        if (mandatory && b.IsActive == false) throw ApiProblemException.Invalid("V-NTF-02", "A mandatory recipient stays.");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ntf.NotificationRule SET IsActive = ISNULL(@active, IsActive), RequireCompanyScope = ISNULL(@scope, RequireCompanyScope), UpdatedAt = SYSUTCDATETIME(),
                   UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT) WHERE NotificationRuleId = @id;
            """, new { active = b.IsActive, scope = b.RequireCompanyScope, id }, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("NOTIFICATION_RULE_UPDATED", "CONFIG", "ntf.NotificationRule", id,
            AfterJson: JsonSerializer.Serialize(new { e.Code, b.IsActive, b.RequireCompanyScope })), null, ct);
        return Results.NoContent();
    }

    /// <summary>V-NTF-01: placeholders from the event's list only; the override replaces the default for this tenant.</summary>
    private static async Task<IResult> SetTemplateAsync(string code, string channel, string lang, NotificationTemplateRequest b, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var ct = http.RequestAborted;
        var e = await EventAsync(u.Connection, null, code, ct);
        channel = channel.ToUpperInvariant();
        lang = lang.ToLowerInvariant();
        if (!Channels.Contains(channel) || lang is not ("ar" or "en")) throw ApiProblemException.NotFound();
        var subject = b.Subject?.Trim() is { Length: > 0 and <= 300 } s ? s : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The subject is 1 to 300 characters.");
        var body = b.Body?.Trim() is { Length: > 0 and <= 4000 } t ? t : throw ApiProblemException.Invalid("VALIDATION_FAILED", "The text is 1 to 4000 characters.");
        var allowed = e.AllowedPlaceholdersJson is null ? [] : JsonSerializer.Deserialize<string[]>(e.AllowedPlaceholdersJson) ?? [];
        var unknown = Placeholder().Matches(subject + body).Select(m => m.Groups[1].Value).Where(p => !allowed.Contains(p)).Distinct().ToList();
        if (unknown.Count > 0) throw ApiProblemException.Invalid("V-NTF-01", "Only these placeholders may be used: " + string.Join(", ", allowed.Select(a => "{" + a + "}")) + ".");
        await u.Connection.ExecuteAsync(new CommandDefinition(
            """
            UPDATE ntf.NotificationTemplate SET SubjectTemplate = @s, BodyTemplate = @b, UpdatedAt = SYSUTCDATETIME(), UpdatedBy = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT)
             WHERE EventTypeId = @e AND Channel = @c AND Lang = @l AND IsTenantOverride = 1;
            IF @@ROWCOUNT = 0
                INSERT ntf.NotificationTemplate (TenantId, EventTypeId, Channel, Lang, SubjectTemplate, BodyTemplate, IsTenantOverride, CreatedBy)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @e, @c, @l, @s, @b, 1, CAST(SESSION_CONTEXT(N'UserId') AS BIGINT));
            """, new { s = subject, b = body, e = e.NotificationEventTypeId, c = channel, l = lang }, cancellationToken: ct));
        await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("NOTIFICATION_TEMPLATE_OVERRIDDEN", "CONFIG", "ntf.NotificationEventType", e.NotificationEventTypeId,
            AfterJson: JsonSerializer.Serialize(new { e.Code, channel, lang, subject })), null, ct);
        return Results.NoContent();
    }

    private static async Task<IResult> ResetTemplateAsync(string code, string channel, string lang, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var e = await EventAsync(u.Connection, null, code, http.RequestAborted);
        var n = await u.Connection.ExecuteAsync(new CommandDefinition(
            "DELETE FROM ntf.NotificationTemplate WHERE EventTypeId = @e AND Channel = @c AND Lang = @l AND IsTenantOverride = 1;",
            new { e = e.NotificationEventTypeId, c = channel.ToUpperInvariant(), l = lang.ToLowerInvariant() }, cancellationToken: http.RequestAborted));
        if (n > 0)
            await AuditWriter.WriteAsync(u.Connection, null, new AuditEntry("NOTIFICATION_TEMPLATE_RESET", "CONFIG", "ntf.NotificationEventType", e.NotificationEventTypeId,
                AfterJson: JsonSerializer.Serialize(new { e.Code, channel, lang })), null, http.RequestAborted);
        return Results.NoContent();
    }

    /// <summary>R-NTF-01 and R-NTF-02 in part: the latest deliveries, the failed and dead first.</summary>
    private static async Task<IResult> DeliveriesAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "status");
        await using var u = await BoundUser.OpenAsync(http, db, Log);
        var status = http.Request.Query["status"].ToString() is { Length: > 0 } s ? s.ToUpperInvariant() : null;
        var rows = await u.Connection.QueryAsync<(string Event, string Channel, string Status, int Attempts, DateTime CreatedAt, DateTime? SentAt, string? LastError, string User)>(
            new CommandDefinition(
                """
                SELECT TOP (200) e.Code, d.Channel, d.Status, d.Attempts, d.CreatedAt, d.SentAt, d.LastError, ISNULL(us.DisplayNameAr, us.Email)
                  FROM ntf.NotificationDelivery AS d JOIN ntf.Notification AS n ON n.NotificationId = d.NotificationId
                  JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId JOIN sec.AppUser AS us ON us.AppUserId = n.UserId
                 WHERE @status IS NULL OR d.Status = @status
                 ORDER BY CASE d.Status WHEN 'DEAD' THEN 0 WHEN 'FAILED' THEN 1 ELSE 2 END, d.CreatedAt DESC;
                """, new { status }, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(r => new
            {
                eventCode = r.Event, channel = r.Channel, status = r.Status, attempts = r.Attempts, createdAt = r.CreatedAt, sentAt = r.SentAt, lastError = r.LastError, user = r.User,
            }),
        });
    }
}
