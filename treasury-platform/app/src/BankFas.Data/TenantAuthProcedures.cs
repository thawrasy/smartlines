using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data;

public sealed record ResolvedTenant(int TenantId, string Status, string NameEn, string NameAr, string DefaultLanguage);

public sealed record StartedSession(long UserId, bool MfaRequired, bool MfaEnrolmentRequired, bool MustChangePassword);

/// <summary>What sec.usp_GetMfaChallenge returns (GAP-2, GAP-3): the secret and the wrapped tenant key that encrypts it.</summary>
public sealed record MfaChallenge(
    byte[]? MfaSecretEnc, long? MfaKeyId, long? LastUsedStep, bool EnrolmentRequired, bool ReenrolmentRequired,
    byte[]? WrappedKey, string? MasterKeyRef, int? KeyVersion, string? KeyAlgorithm, DateTime? MfaVerifiedAt, Guid? UserPublicId);

public sealed record PasswordPolicy(int MinLength, int HistoryCount);

/// <summary>
/// The tenant portal's account procedures (db/static/030, 035), as tp_app. The pre-binding ones run on an unbound
/// connection and outside any transaction of the caller: they commit their own failure records (lockout counts).
/// </summary>
public static class TenantAuthProcedures
{
    public static async Task<ResolvedTenant?> ResolveTenantAsync(SqlConnection c, string code, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_ResolveTenant").In("@Code", code, DbType.AnsiString, 30)
            .Out("@TenantId", DbType.Int32).Out("@Status", DbType.AnsiString, 18)
            .Out("@NameEn", DbType.String, 200).Out("@NameAr", DbType.String, 200).Out("@DefaultLanguage", DbType.AnsiString, 2);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        var id = p.Get<int?>("@TenantId");
        return id is null ? null : new ResolvedTenant(id.Value, p.Get<string>("@Status"), p.Get<string>("@NameEn"),
            p.Get<string>("@NameAr"), p.Get<string>("@DefaultLanguage"));
    }

    public static async Task<PasswordPolicy> GetPasswordPolicyAsync(SqlConnection c, int tenantId, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_GetPasswordPolicy").In("@TenantId", tenantId, DbType.Int32)
            .Out("@MinLength", DbType.Int32).Out("@HistoryCount", DbType.Int32);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return new PasswordPolicy(p.Get<int>("@MinLength"), p.Get<int>("@HistoryCount"));
    }

    /// <summary>
    /// The stored hash up to its last '$' (parameters and salt), or null for an unknown login. The login is the e-mail,
    /// employee code or mobile number the tenant allows (sec.fn_LoginUser, ADR 0048).
    /// </summary>
    public static async Task<string?> GetPasswordParamsAsync(SqlConnection c, int tenantId, string login, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_GetPasswordParams").In("@TenantId", tenantId, DbType.Int32)
            .In("@Login", login, DbType.String, 254).Out("@Params", DbType.AnsiString, 255);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<string?>("@Params");
    }

    /// <summary>Raises 50005 for every failure before the password is proven, 50006 for a tenant closed to the user.</summary>
    public static async Task<StartedSession> StartSessionAsync(SqlConnection c, int tenantId, string login, string passwordHash,
        byte[] sessionToken, string? clientIp, string? userAgent, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_StartSession").In("@TenantId", tenantId, DbType.Int32).In("@Login", login, DbType.String, 254)
            .In("@PasswordHash", passwordHash, DbType.AnsiString, 255).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@ClientIp", clientIp, DbType.AnsiString, 45).In("@UserAgent", Truncate(userAgent, 400), DbType.String, 400)
            .Out("@UserId", DbType.Int64).Out("@MfaRequired", DbType.Boolean).Out("@MfaEnrolmentRequired", DbType.Boolean)
            .Out("@MustChangePassword", DbType.Boolean);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return new StartedSession(p.Get<long>("@UserId"), p.Get<bool>("@MfaRequired"), p.Get<bool>("@MfaEnrolmentRequired"),
            p.Get<bool>("@MustChangePassword"));
    }

    /// <summary>What the session needs before it binds: MFA_ENROLMENT_REQUIRED, MFA_REQUIRED, PASSWORD_CHANGE_REQUIRED or DONE.</summary>
    public static async Task<string> GetSessionStepAsync(SqlConnection c, int tenantId, byte[] sessionToken, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_GetSessionStep").In("@TenantId", tenantId, DbType.Int32)
            .In("@SessionToken", sessionToken, DbType.Binary, 64).Out("@NextStep", DbType.AnsiString, 30);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<string>("@NextStep");
    }

    /// <summary>The parameters of the session user's stored password, and whether the user enrolled MFA (ADR 0048).</summary>
    public static async Task<(string? Params, bool MfaEnabled)> GetSessionPasswordParamsAsync(SqlConnection c, int tenantId, byte[] sessionToken, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_GetSessionPasswordParams").In("@TenantId", tenantId, DbType.Int32)
            .In("@SessionToken", sessionToken, DbType.Binary, 64).Out("@Params", DbType.AnsiString, 255).Out("@MfaEnabled", DbType.Boolean);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return (p.Get<string?>("@Params"), p.Get<bool?>("@MfaEnabled") ?? false);
    }

    /// <summary>A step-up by password; a wrong one counts toward the lockout.</summary>
    public static async Task<bool> ConfirmPasswordStepUpAsync(SqlConnection c, int tenantId, byte[] sessionToken, string passwordHash, string? clientIp, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_ConfirmPasswordStepUp").In("@TenantId", tenantId, DbType.Int32)
            .In("@SessionToken", sessionToken, DbType.Binary, 64).In("@PasswordHash", passwordHash, DbType.AnsiString, 255)
            .In("@ClientIp", clientIp, DbType.AnsiString, 45).Out("@Accepted", DbType.Boolean);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<bool>("@Accepted");
    }

    public static async Task<MfaChallenge> GetMfaChallengeAsync(SqlConnection c, int tenantId, byte[] sessionToken, bool stepUp, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_GetMfaChallenge").In("@TenantId", tenantId, DbType.Int32)
            .In("@SessionToken", sessionToken, DbType.Binary, 64).In("@StepUp", stepUp, DbType.Boolean)
            .Out("@MfaSecretEnc", DbType.Binary, 256).Out("@MfaKeyId", DbType.Int64).Out("@LastUsedStep", DbType.Int64)
            .Out("@EnrolmentRequired", DbType.Boolean).Out("@ReenrolmentRequired", DbType.Boolean)
            .Out("@WrappedKey", DbType.Binary, 512).Out("@MasterKeyRef", DbType.AnsiString, 200).Out("@KeyVersion", DbType.Int32)
            .Out("@KeyAlgorithm", DbType.AnsiString, 30).Out("@MfaVerifiedAt", DbType.DateTime2).Out("@UserPublicId", DbType.Guid);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return new MfaChallenge(p.Get<byte[]?>("@MfaSecretEnc"), p.Get<long?>("@MfaKeyId"), p.Get<long?>("@LastUsedStep"),
            p.Get<bool>("@EnrolmentRequired"), p.Get<bool>("@ReenrolmentRequired"), p.Get<byte[]?>("@WrappedKey"),
            p.Get<string?>("@MasterKeyRef"), p.Get<int?>("@KeyVersion"), p.Get<string?>("@KeyAlgorithm"),
            p.Get<DateTime?>("@MfaVerifiedAt"), p.Get<Guid?>("@UserPublicId"));
    }

    /// <summary>Records the TOTP check; true when it was accepted (GAP-4). A failure counts toward the lockout.</summary>
    public static async Task<bool> ConfirmMfaAsync(SqlConnection c, int tenantId, byte[] sessionToken, long? step, string? clientIp, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_ConfirmMfa").In("@TenantId", tenantId, DbType.Int32).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@Passed", step is not null, DbType.Boolean).In("@ClientIp", clientIp, DbType.AnsiString, 45).In("@Step", step, DbType.Int64)
            .Out("@Accepted", DbType.Boolean);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<bool>("@Accepted");
    }

    public static Task CompleteMfaEnrolmentAsync(SqlConnection c, int tenantId, byte[] sessionToken, byte[] secretEnc, long keyId,
        long step, string recoveryCodeHashesJson, byte[]? reenrolmentToken, CancellationToken ct) =>
        Proc.Named("sec.usp_CompleteMfaEnrolment").In("@TenantId", tenantId, DbType.Int32).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@MfaSecretEnc", secretEnc, DbType.Binary, 256).In("@MfaKeyId", keyId, DbType.Int64).In("@Step", step, DbType.Int64)
            .In("@RecoveryCodeHashes", recoveryCodeHashesJson, DbType.String, -1).In("@ReenrolmentToken", reenrolmentToken, DbType.Binary, 64)
            .ExecAsync(c, ct);

    /// <summary>The number of unused codes left; 50009 for a wrong code (counted toward the lockout).</summary>
    public static async Task<int> UseRecoveryCodeAsync(SqlConnection c, int tenantId, byte[] sessionToken, byte[] codeHash, string? clientIp, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_UseRecoveryCode").In("@TenantId", tenantId, DbType.Int32).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@CodeHash", codeHash, DbType.Binary, 32).In("@ClientIp", clientIp, DbType.AnsiString, 45).Out("@Remaining", DbType.Int32);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<int>("@Remaining");
    }

    public static Task TouchSessionAsync(SqlConnection c, int tenantId, byte[] sessionToken, CancellationToken ct) =>
        Proc.Named("sec.usp_TouchSession").In("@TenantId", tenantId, DbType.Int32).In("@SessionToken", sessionToken, DbType.Binary, 64).ExecAsync(c, ct);

    public static Task EndSessionAsync(SqlConnection c, int tenantId, byte[]? sessionToken, long? userSessionId, CancellationToken ct) =>
        Proc.Named("sec.usp_EndSession").In("@TenantId", tenantId, DbType.Int32).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@UserSessionId", userSessionId, DbType.Int64).ExecAsync(c, ct);

    public static Task CompleteInvitationAsync(SqlConnection c, int tenantId, byte[] token, string newPasswordHash, CancellationToken ct) =>
        Proc.Named("sec.usp_CompleteInvitation").In("@TenantId", tenantId, DbType.Int32).In("@Token", token, DbType.Binary, 64)
            .In("@NewPasswordHash", newPasswordHash, DbType.AnsiString, 255).ExecAsync(c, ct);

    /// <summary>
    /// Binds the connection to the user of the session (sec.usp_SetSessionContext), then extends the session's idle
    /// time (sec.usp_TouchSession). The first commands on the connection, outside any transaction (DOC-F04 section 5).
    /// Returns the bound user's id, read from the context the database set, never from the request.
    /// </summary>
    /// <summary>
    /// Binds the connection to the session's user. touch: false for a request the screen makes on its own (the bell's
    /// polling), which must not keep an idle user signed in (FR-PLT-014): the session is checked but not extended.
    /// </summary>
    public static async Task<long> BindUserAsync(SqlConnection c, int tenantId, byte[] sessionToken, string? clientIp, Guid correlationId, CancellationToken ct,
        bool touch = true)
    {
        await Proc.Named("sec.usp_SetSessionContext").In("@TenantId", tenantId, DbType.Int32).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@ClientIp", clientIp, DbType.AnsiString, 45).In("@CorrelationId", correlationId, DbType.Guid).ExecAsync(c, ct).ConfigureAwait(false);
        if (touch) await TouchSessionAsync(c, tenantId, sessionToken, ct).ConfigureAwait(false);
        var bound = await c.QuerySingleAsync<(int? TenantId, long? UserId)>(new CommandDefinition(
            "SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), CAST(SESSION_CONTEXT(N'UserId') AS BIGINT);", cancellationToken: ct)).ConfigureAwait(false);
        if (bound.TenantId != tenantId || bound.UserId is null)
            throw new InvalidOperationException("The binding does not name the tenant of the request.");
        return bound.UserId.Value;
    }

    internal static string? Truncate(string? s, int max) => s is null || s.Length <= max ? s : s[..max];
}
