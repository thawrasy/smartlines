using System.Data;
using Microsoft.Data.SqlClient;

namespace BankFas.Data;

public sealed record OperatorMfaChallenge(byte[] MfaSecretEnc, string MfaKeyRef, long? LastUsedStep, DateTime? MfaVerifiedAt, Guid OperatorPublicId);

/// <summary>The operator's session on each request (GAP-7): who it is and whether its MFA check is done.</summary>
public sealed record OperatorSessionState(int OperatorId, string Role, DateTime? MfaVerifiedAt)
{
    public bool IsAdmin => Role == "OPERATOR_ADMIN";
}

public sealed record CreatedTenant(int TenantId, long AdminUserId);

/// <summary>The operator panel's procedures (db/static/036, 038), as tp_platform. No binding: the session token is passed.</summary>
public static class OperatorProcedures
{
    public static async Task<string?> GetPasswordParamsAsync(SqlConnection c, string email, CancellationToken ct)
    {
        var p = Proc.Named("plat.usp_GetOperatorPasswordParams").In("@Email", email, DbType.String, 254).Out("@Params", DbType.AnsiString, 255);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<string?>("@Params");
    }

    public static async Task<int> StartSessionAsync(SqlConnection c, string email, string passwordHash, byte[] sessionToken,
        string? clientIp, string? userAgent, CancellationToken ct)
    {
        var p = Proc.Named("plat.usp_StartOperatorSession").In("@Email", email, DbType.String, 254)
            .In("@PasswordHash", passwordHash, DbType.AnsiString, 255).In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@ClientIp", clientIp, DbType.AnsiString, 45).In("@UserAgent", TenantAuthProcedures.Truncate(userAgent, 400), DbType.String, 400)
            .Out("@OperatorId", DbType.Int32);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<int>("@OperatorId");
    }

    public static async Task<OperatorMfaChallenge> GetMfaChallengeAsync(SqlConnection c, byte[] sessionToken, CancellationToken ct)
    {
        var p = Proc.Named("plat.usp_GetOperatorMfaChallenge").In("@SessionToken", sessionToken, DbType.Binary, 64)
            .Out("@MfaSecretEnc", DbType.Binary, 256).Out("@MfaKeyRef", DbType.AnsiString, 200).Out("@LastUsedStep", DbType.Int64)
            .Out("@MfaVerifiedAt", DbType.DateTime2).Out("@OperatorPublicId", DbType.Guid);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return new OperatorMfaChallenge(p.Get<byte[]>("@MfaSecretEnc"), p.Get<string>("@MfaKeyRef"), p.Get<long?>("@LastUsedStep"),
            p.Get<DateTime?>("@MfaVerifiedAt"), p.Get<Guid>("@OperatorPublicId"));
    }

    public static async Task<bool> ConfirmMfaAsync(SqlConnection c, byte[] sessionToken, long? step, CancellationToken ct)
    {
        var p = Proc.Named("plat.usp_ConfirmOperatorMfa").In("@SessionToken", sessionToken, DbType.Binary, 64)
            .In("@Passed", step is not null, DbType.Boolean).In("@Step", step, DbType.Int64).Out("@Accepted", DbType.Boolean);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return p.Get<bool>("@Accepted");
    }

    public static async Task<OperatorSessionState> TouchSessionAsync(SqlConnection c, byte[] sessionToken, CancellationToken ct)
    {
        var p = Proc.Named("plat.usp_TouchOperatorSession").In("@SessionToken", sessionToken, DbType.Binary, 64)
            .Out("@OperatorId", DbType.Int32).Out("@Role", DbType.AnsiString, 20).Out("@MfaVerifiedAt", DbType.DateTime2);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return new OperatorSessionState(p.Get<int>("@OperatorId"), p.Get<string>("@Role"), p.Get<DateTime?>("@MfaVerifiedAt"));
    }

    public static Task EndSessionAsync(SqlConnection c, byte[] sessionToken, CancellationToken ct) =>
        Proc.Named("plat.usp_EndOperatorSession").In("@SessionToken", sessionToken, DbType.Binary, 64).ExecAsync(c, ct);

    public static Task CompleteSetupAsync(SqlConnection c, byte[] linkToken, string newPasswordHash, byte[] mfaSecretEnc, string mfaKeyRef,
        long step, CancellationToken ct) =>
        Proc.Named("plat.usp_CompleteOperatorSetup").In("@Token", linkToken, DbType.Binary, 64)
            .In("@NewPasswordHash", newPasswordHash, DbType.AnsiString, 255).In("@MfaSecretEnc", mfaSecretEnc, DbType.Binary, 256)
            .In("@MfaKeyRef", mfaKeyRef, DbType.AnsiString, 200).In("@Step", step, DbType.Int64).ExecAsync(c, ct);

    /// <summary>Needs an operator administrator with an MFA check in the last 5 minutes (50021).</summary>
    public static async Task<CreatedTenant> CreateTenantAsync(SqlConnection c, byte[] sessionToken, string code, string nameAr, string nameEn,
        int planId, int homeCountryId, string timeZone, string defaultLanguage, string adminEmail, string adminDisplayName, CancellationToken ct)
    {
        var p = Proc.Named("plat.usp_CreateTenant").In("@OperatorSessionToken", sessionToken, DbType.Binary, 64)
            .In("@Code", code, DbType.AnsiString, 30).In("@NameAr", nameAr, DbType.String, 200).In("@NameEn", nameEn, DbType.String, 200)
            .In("@PlanId", planId, DbType.Int32).In("@HomeCountryId", homeCountryId, DbType.Int32).In("@TimeZone", timeZone, DbType.AnsiString, 64)
            .In("@DefaultLanguage", defaultLanguage, DbType.AnsiString, 2).In("@AdminEmail", adminEmail, DbType.String, 254)
            .In("@AdminDisplayName", adminDisplayName, DbType.String, 200).Out("@TenantId", DbType.Int32).Out("@AdminUserId", DbType.Int64);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return new CreatedTenant(p.Get<int>("@TenantId"), p.Get<long>("@AdminUserId"));
    }

    public static Task SetTenantStatusAsync(SqlConnection c, byte[] sessionToken, int tenantId, string status, string? reason,
        DateOnly? trialEndsOn, CancellationToken ct) =>
        Proc.Named("plat.usp_SetTenantStatus").In("@OperatorSessionToken", sessionToken, DbType.Binary, 64).In("@TenantId", tenantId, DbType.Int32)
            .In("@Status", status, DbType.AnsiString, 18).In("@Reason", reason, DbType.String, 500)
            .In("@TrialEndsOn", trialEndsOn?.ToDateTime(TimeOnly.MinValue), DbType.Date).ExecAsync(c, ct);
}
