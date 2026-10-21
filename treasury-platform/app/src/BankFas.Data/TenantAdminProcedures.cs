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

    public static Task SetUserStatusAsync(SqlConnection c, int tenantId, long userId, string status, CancellationToken ct) =>
        Proc.Named("sec.usp_SetUserStatus").In("@TenantId", tenantId, DbType.Int32).In("@UserId", userId, DbType.Int64)
            .In("@Status", status, DbType.AnsiString, 10).ExecAsync(c, ct);

    /// <summary>The address to send the link to, or null when nothing is sent (the caller answers the same either way).</summary>
    public static async Task<string?> RequestPasswordResetAsync(SqlConnection c, int tenantId, string email, byte[] token, string? clientIp, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_RequestPasswordReset").In("@TenantId", tenantId, DbType.Int32).In("@Email", email, DbType.String, 254)
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

public sealed record AuditEntry(string Action, string Category, string EntityType, long? EntityId, string? BeforeJson = null,
    string? AfterJson = null, string Severity = "INFO", string Result = "SUCCESS", string? UserAgent = null);
