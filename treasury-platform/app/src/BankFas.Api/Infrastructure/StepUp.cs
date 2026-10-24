using BankFas.Core.Security;
using BankFas.Data;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// A fresh proof before a sensitive action of the tenant portal (DOC-S04 section 9: MFA reset, TM or FO assignment,
/// password change, sensitive exports). It comes in the request as stepUpCode. A user who enrolled MFA gives a TOTP
/// code, checked against the session's secret (sec.usp_GetMfaChallenge @StepUp = 1, GAP-3) and recorded by
/// sec.usp_ConfirmMfa, so a code works once. A user without MFA, where the tenant does not require it, gives the
/// password (sec.usp_ConfirmPasswordStepUp, ADR 0048). A wrong proof counts toward the lockout. Missing or wrong:
/// 401 REAUTH_REQUIRED.
/// </summary>
public static class StepUp
{
    public static async Task RequireAsync(HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock, string? code)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        (string? Params, bool MfaEnabled) who;
        try { who = await TenantAuthProcedures.GetSessionPasswordParamsAsync(c, tenant.TenantId, token, http.RequestAborted); }
        catch (SqlException ex) when (ex.Number == DbErrors.NoValidSession) { throw ApiProblemException.Unauthorized(); }
        if (!who.MfaEnabled)
        {
            if (string.IsNullOrEmpty(code) || code.Length > 1024) throw new ApiProblemException(401, "REAUTH_REQUIRED", "Confirm with your password.");
            var hash = (who.Params is null ? null : PasswordHasher.HashWithStoredParameters(code, who.Params)) ?? PasswordHasher.HashForUnknownUser(code);
            if (!await TenantAuthProcedures.ConfirmPasswordStepUpAsync(c, tenant.TenantId, token, hash, rc.ClientIp, http.RequestAborted))
                throw new ApiProblemException(401, "REAUTH_REQUIRED", "The password is not correct.");
            return;
        }
        if (string.IsNullOrWhiteSpace(code)) throw new ApiProblemException(401, "REAUTH_REQUIRED", "Confirm with a code from your authenticator.");
        MfaChallenge ch;
        try { ch = await TenantAuthProcedures.GetMfaChallengeAsync(c, tenant.TenantId, token, true, http.RequestAborted); }
        catch (SqlException ex) when (ex.Number == DbErrors.NoValidSession) { throw ApiProblemException.Unauthorized(); }
        var secret = Endpoints.TenantAuthEndpoints.OpenSecret(keys, tenant.TenantId, ch);
        var step = Totp.Verify(secret, code, clock.GetUtcNow(), ch.LastUsedStep);
        if (!await TenantAuthProcedures.ConfirmMfaAsync(c, tenant.TenantId, token, step, rc.ClientIp, http.RequestAborted))
            throw new ApiProblemException(401, "REAUTH_REQUIRED", "The code is not valid. Enter a new code from your authenticator.");
    }
}
