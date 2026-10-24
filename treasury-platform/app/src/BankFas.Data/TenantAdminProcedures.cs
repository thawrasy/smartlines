using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data;

/// <summary>
/// The account procedures of db/static/035 that the tenant portal calls for an administrator (on a connection bound
/// to the administrator) or for the user's own password (unbound, with the session or link token). The database
/// checks the binding and the target's tenant; the application checks the permission code (sec.user.manage).
/// </summary>
public static class TenantAdminProcedures
{
    /// <summary>A new link (INVITATION, PASSWORD_RESET, MFA_REENROLMENT); returns the address to send it to.</summary>
    public static async Task<string> IssueUserTokenAsync(SqlConnection c, SqlTransaction? tx, int tenantId, long userId, string purpose,
        byte[] token, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_IssueUserToken").In("@TenantId", tenantId, DbType.Int32).In("@UserId", userId, DbType.Int64)
            .In("@Purpose", purpose, DbType.AnsiString, 15).In("@Token", token, DbType.Binary, 64).Out("@SentTo", DbType.String, 254);
        await p.ExecAsync(c, ct, tx).ConfigureAwait(false);
        return p.Get<string>("@SentTo");
    }

    public static Task UnlockUserAsync(SqlConnection c, int tenantId, long userId, CancellationToken ct) =>
        Proc.Named("sec.usp_UnlockUser").In("@TenantId", tenantId, DbType.Int32).In("@UserId", userId, DbType.Int64).ExecAsync(c, ct);

    public static Task ResetMfaAsync(SqlConnection c, SqlTransaction? tx, int tenantId, long userId, CancellationToken ct) =>
        Proc.Named("sec.usp_ResetMfa").In("@TenantId", tenantId, DbType.Int32).In("@UserId", userId, DbType.Int64).ExecAsync(c, ct, tx);

    /// <summary>A temporary password the administrator hands over; changed at the first sign-in (ADR 0048).</summary>
    public static Task SetTemporaryPasswordAsync(SqlConnection c, SqlTransaction? tx, int tenantId, long userId, string passwordHash, CancellationToken ct) =>
        Proc.Named("sec.usp_SetTemporaryPassword").In("@TenantId", tenantId, DbType.Int32).In("@UserId", userId, DbType.Int64)
            .In("@PasswordHash", passwordHash, DbType.AnsiString, 255).ExecAsync(c, ct, tx);

    public static Task SetUserStatusAsync(SqlConnection c, int tenantId, long userId, string status, CancellationToken ct) =>
        Proc.Named("sec.usp_SetUserStatus").In("@TenantId", tenantId, DbType.Int32).In("@UserId", userId, DbType.Int64)
            .In("@Status", status, DbType.AnsiString, 10).ExecAsync(c, ct);

    /// <summary>The address to send the link to, or null when nothing is sent (the caller answers the same either way).</summary>
    public static async Task<string?> RequestPasswordResetAsync(SqlConnection c, int tenantId, string login, byte[] token, string? clientIp, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_RequestPasswordReset").In("@TenantId", tenantId, DbType.Int32).In("@Login", login, DbType.String, 254)
            .In("@Token", token, DbType.Binary, 64).In("@ClientIp", clientIp, DbType.AnsiString, 45).Out("@SentTo", DbType.String, 254);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<string?>("@SentTo");
    }

    /// <summary>The PHC parameter sets the new password must be hashed under, for the reuse check (BR-PLT-004).</summary>
    public static async Task<IReadOnlyList<string>> GetPasswordHistoryParamsAsync(SqlConnection c, int tenantId, byte[]? sessionToken,
        byte[]? linkToken, CancellationToken ct) =>
        [.. await Proc.Named("sec.usp_GetPasswordHistoryParams").In("@TenantId", tenantId, DbType.Int32)
            .In("@SessionToken", sessionToken, DbType.Binary, 64).In("@LinkToken", linkToken, DbType.Binary, 64)
            .QueryAsync<string>(c, ct).ConfigureAwait(false)];

    public static Task ResetPasswordAsync(SqlConnection c, int tenantId, byte[] token, string newHash, string candidatesJson, CancellationToken ct) =>
        Proc.Named("sec.usp_ResetPassword").In("@TenantId", tenantId, DbType.Int32).In("@Token", token, DbType.Binary, 64)
            .In("@NewPasswordHash", newHash, DbType.AnsiString, 255).In("@Candidates", candidatesJson, DbType.String, -1).ExecAsync(c, ct);

    public static Task ChangePasswordAsync(SqlConnection c, int tenantId, byte[] sessionToken, string currentHash, string newHash,
        string candidatesJson, string? clientIp, CancellationToken ct) =>
        Proc.Named("sec.usp_ChangePassword").In("@TenantId", tenantId, DbType.Int32).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@CurrentPasswordHash", currentHash, DbType.AnsiString, 255).In("@NewPasswordHash", newHash, DbType.AnsiString, 255)
            .In("@Candidates", candidatesJson, DbType.String, -1).In("@ClientIp", clientIp, DbType.AnsiString, 45).ExecAsync(c, ct);

    /// <summary>
    /// An audit row the application writes itself, on its bound connection (029, ADR 0007): the actor is the bound
    /// user, by PublicId. Restricted values never go into the JSON (FR-PLT-023).
    /// </summary>
    public static Task WriteAuditAsync(SqlConnection c, SqlTransaction? tx, AuditEntry e, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId,
                                 BeforeJson, AfterJson, CorrelationId, IpAddress, UserAgent, Result)
            SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), SYSUTCDATETIME(), 'USER', u.PublicId, @Action, @Category, @Severity,
                   @EntityType, @EntityId, @BeforeJson, @AfterJson, CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER),
                   CAST(SESSION_CONTEXT(N'ClientIp') AS VARCHAR(45)), @UserAgent, @Result
            FROM sec.AppUser AS u WHERE u.AppUserId = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
            """, e, tx, cancellationToken: ct));
}

/// <summary>
/// Audit rows with their id, and the sensitive-access log that points at them (BR-PTY-009, DR-12): every access to a
/// restricted value, granted or denied, has its audit event and its row in aud.SensitiveAccessLog.
/// </summary>
public static class AuditWriter
{
    public static Task<long> WriteAsync(SqlConnection c, SqlTransaction? tx, AuditEntry e, long? companyId, CancellationToken ct) =>
        c.ExecuteScalarAsync<long>(new CommandDefinition(
            """
            DECLARE @o TABLE (Id BIGINT);
            INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId, CompanyId,
                                 BeforeJson, AfterJson, CorrelationId, IpAddress, UserAgent, Result)
            OUTPUT inserted.AuditLogId INTO @o
            SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), SYSUTCDATETIME(), 'USER', u.PublicId, @Action, @Category, @Severity,
                   @EntityType, @EntityId, @companyId, @BeforeJson, @AfterJson, CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER),
                   CAST(SESSION_CONTEXT(N'ClientIp') AS VARCHAR(45)), @UserAgent, @Result
            FROM sec.AppUser AS u WHERE u.AppUserId = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
            SELECT Id FROM @o;
            """,
            new { e.Action, e.Category, e.Severity, e.EntityType, e.EntityId, companyId, e.BeforeJson, e.AfterJson, e.UserAgent, e.Result }, tx,
            cancellationToken: ct));

    /// <summary>An access to a restricted value: the audit row (HIGH when denied) and its sensitive-access row.</summary>
    public static async Task SensitiveAccessAsync(SqlConnection c, SqlTransaction? tx, string accessKind, string action, string entityType, long entityId,
        long? partyId, long? companyId, bool granted, string? denyReason, string? reason, string? userAgent, CancellationToken ct)
    {
        var auditId = await WriteAsync(c, tx, new AuditEntry(action, "IDENTITY_ACCESS", entityType, entityId,
            AfterJson: System.Text.Json.JsonSerializer.Serialize(new { accessKind, granted, denyReason }), Severity: granted ? "INFO" : "HIGH",
            Result: granted ? "SUCCESS" : "DENIED", UserAgent: userAgent), companyId, ct).ConfigureAwait(false);
        await c.ExecuteAsync(new CommandDefinition(
            """
            INSERT aud.SensitiveAccessLog (TenantId, OccurredAt, AccessKind, ActorType, ActorUserId, SubjectEntityType, SubjectEntityId, SubjectPartyId,
                                           CompanyId, Result, DenyReason, Reason, IpAddress, UserAgent, CorrelationId, AuditLogId)
            VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), SYSUTCDATETIME(), @accessKind, 'USER', CAST(SESSION_CONTEXT(N'UserId') AS BIGINT),
                    @entityType, @entityId, @partyId, @companyId, @result, @denyReason, @reason, CAST(SESSION_CONTEXT(N'ClientIp') AS VARCHAR(45)),
                    @userAgent, CAST(SESSION_CONTEXT(N'CorrelationId') AS UNIQUEIDENTIFIER), @auditId);
            """,
            new { accessKind, entityType, entityId, partyId, companyId, result = granted ? "GRANTED" : "DENIED", denyReason, reason, userAgent, auditId }, tx,
            cancellationToken: ct)).ConfigureAwait(false);
        if (granted) await RevealAnomalyAsync(c, tx, ct).ConfigureAwait(false);
    }

    /// <summary>The reveals above which an hour is unusual (BR-PTY-009).</summary>
    public const int RevealsPerHour = 20;

    /// <summary>
    /// SEC.REVEAL_ANOMALY (spec 13 section 9.2): the signed-in user's 21st reveal within an hour, of an identity number or
    /// image, a custom field or a bank account, tells the account administrators and the treasury manager, once an hour.
    /// </summary>
    public static async Task RevealAnomalyAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct)
    {
        var (count, name, userId) = await c.QuerySingleAsync<(int Count, string Name, long UserId)>(new CommandDefinition(
            """
            DECLARE @u BIGINT = CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);
            DECLARE @since DATETIME2(3) = DATEADD(HOUR, -1, SYSUTCDATETIME());
            SELECT (SELECT COUNT(*) FROM aud.SensitiveAccessLog WHERE ActorUserId = @u AND Result = 'GRANTED' AND OccurredAt >= @since)
                 + (SELECT COUNT(*) FROM aud.AuditLog AS a JOIN sec.AppUser AS x ON x.PublicId = a.ActorId
                     WHERE x.AppUserId = @u AND a.Action = 'ACCOUNT_REVEALED' AND a.OccurredAt >= @since),
                   ISNULL(u.DisplayNameAr, u.Email), u.AppUserId
              FROM sec.AppUser AS u WHERE u.AppUserId = @u;
            """, transaction: tx, cancellationToken: ct)).ConfigureAwait(false);
        if (count != RevealsPerHour + 1) return;
        await Notifications.Notifier.RequestAsync(c, tx, new Notifications.NotificationRequest("SEC.REVEAL_ANOMALY", "sec.AppUser", userId,
            $"SEC.REVEAL_ANOMALY:{userId}:{DateTime.UtcNow:yyyyMMddHH}", Values: new Dictionary<string, object?> { ["userName"] = name, ["count"] = count }), ct)
            .ConfigureAwait(false);
    }
}

public sealed record AuditEntry(string Action, string Category, string EntityType, long? EntityId, string? BeforeJson = null,
    string? AfterJson = null, string Severity = "INFO", string Result = "SUCCESS", string? UserAgent = null);
