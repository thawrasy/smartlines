using BankFas.Core.Security;
using BankFas.Data;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// A fresh TOTP code before a sensitive action of the tenant portal (DOC-S04 section 9: MFA reset, TM or FO
/// assignment, password change, sensitive exports). The code comes in the request as stepUpCode; it is checked
/// against the session's secret (sec.usp_GetMfaChallenge @StepUp = 1, GAP-3) and recorded by sec.usp_ConfirmMfa, so
/// a code works once and a wrong one counts toward the lockout. Missing or wrong: 401 REAUTH_REQUIRED.
/// </summary>
public static class StepUp
{
    public static async Task RequireAsync(HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock, string? code)
    {
        if (string.IsNullOrWhiteSpace(code)) throw new ApiProblemException(401, "REAUTH_REQUIRED", "Confirm with a code from your authenticator.");
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        MfaChallenge ch;
        try { ch = await TenantAuthProcedures.GetMfaChallengeAsync(c, tenant.TenantId, token, true, http.RequestAborted); }
        catch (SqlException ex) when (ex.Number == DbErrors.NoValidSession) { throw ApiProblemException.Unauthorized(); }
        var secret = Endpoints.TenantAuthEndpoints.OpenSecret(keys, tenant.TenantId, ch);
        var step = Totp.Verify(secret, code, clock.GetUtcNow(), ch.LastUsedStep);
        if (!await TenantAuthProcedures.ConfirmMfaAsync(c, tenant.TenantId, token, step, rc.ClientIp, http.RequestAborted))
            throw new ApiProblemException(401, "REAUTH_REQUIRED", "The code is not valid. Enter a new code from your authenticator.");
    }
}
