using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using BankFas.Data;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record LoginRequest(string? Email, string? Password);
public sealed record MfaRequest(string? Code, string? RecoveryCode);
public sealed record EnrolmentStartRequest(string? ReenrolmentToken);
public sealed record EnrolmentCompleteRequest(string? Code, string? ReenrolmentToken);
public sealed record InvitationRequest(string? Token, string? Password);

/// <summary>
/// Sign-in on the tenant portal (DOC-F03, brief section 2): tenant page, password, MFA check or enrolment, the
/// invitation link, logout. Every step but the last runs on an unbound tp_app connection with the session token.
/// </summary>
public static class TenantAuthEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/tenant", (HttpContext http) =>
        {
            var t = RequestContext.Of(http).RequireTenant();
            return Results.Ok(new { code = RequestContext.Of(http).TenantCode, nameEn = t.NameEn, nameAr = t.NameAr, defaultLanguage = t.DefaultLanguage, status = t.Status });
        });

        var auth = api.MapGroup("/auth");
        auth.MapPost("/login", LoginAsync).RequireRateLimiting("login");
        auth.MapPost("/mfa", MfaAsync).RequireRateLimiting("mfa");
        auth.MapPost("/mfa/enrolment", StartEnrolmentAsync);
        auth.MapPost("/mfa/enrolment/complete", CompleteEnrolmentAsync).RequireRateLimiting("mfa");
        auth.MapPost("/invitation", AcceptInvitationAsync).RequireRateLimiting("login");
        auth.MapPost("/logout", LogoutAsync);
    }

    private static async Task<IResult> LoginAsync(LoginRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        if (string.IsNullOrWhiteSpace(body.Email) || string.IsNullOrEmpty(body.Password) || body.Password.Length > 1024)
            throw new ApiProblemException(401, "INVALID_CREDENTIALS", "Invalid email or password.");
        var email = body.Email.Trim();
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        var stored = await TenantAuthProcedures.GetPasswordParamsAsync(c, tenant.TenantId, email, http.RequestAborted);
        var hash = (stored is null ? null : PasswordHasher.HashWithStoredParameters(body.Password, stored))
                   ?? PasswordHasher.HashForUnknownUser(body.Password);
        var token = SecureTokens.NewToken();
        var started = await TenantAuthProcedures.StartSessionAsync(c, tenant.TenantId, email, hash, token, rc.ClientIp,
            http.Request.Headers.UserAgent.ToString(), http.RequestAborted);
        Cookies.SetSession(http.Response, token);
        string next;
        if (!started.MfaEnrolmentRequired) next = "MFA_REQUIRED";
        else
        {
            var challenge = await TenantAuthProcedures.GetMfaChallengeAsync(c, tenant.TenantId, token, false, http.RequestAborted);
            next = challenge.ReenrolmentRequired ? "MFA_REENROLMENT_REQUIRED" : "MFA_ENROLMENT_REQUIRED";
        }
        return Results.Ok(new { nextStep = next });
    }

    private static async Task<IResult> MfaAsync(MfaRequest body, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        var ch = await ChallengeOrUnauthorizedAsync(c, tenant.TenantId, token, http);
        if (ch.EnrolmentRequired) throw new ApiProblemException(409, "MFA_ENROLMENT_REQUIRED", "Set up your authenticator first.");

        if (!string.IsNullOrWhiteSpace(body.RecoveryCode))
        {
            var normalised = RecoveryCodes.Normalise(body.RecoveryCode) ?? throw new ApiProblemException(401, "MFA_INVALID", "The code is not valid.");
            var remaining = await TenantAuthProcedures.UseRecoveryCodeAsync(c, tenant.TenantId, token, RecoveryCodes.Hash(normalised), rc.ClientIp, http.RequestAborted);
            return Results.Ok(new { nextStep = "DONE", recoveryCodesRemaining = remaining });
        }
        var secret = OpenSecret(keys, tenant.TenantId, ch);
        var step = Totp.Verify(secret, body.Code, clock.GetUtcNow(), ch.LastUsedStep);
        var accepted = await TenantAuthProcedures.ConfirmMfaAsync(c, tenant.TenantId, token, step, rc.ClientIp, http.RequestAborted);
        if (!accepted) throw new ApiProblemException(401, "MFA_INVALID", "The code is not valid.");
        return Results.Ok(new { nextStep = "DONE" });
    }

    private static async Task<IResult> StartEnrolmentAsync(EnrolmentStartRequest body, HttpContext http, SqlConnectionFactory db, PendingSecretProtector pending)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        var ch = await ChallengeOrUnauthorizedAsync(c, tenant.TenantId, token, http);
        if (!ch.EnrolmentRequired) throw new ApiProblemException(409, "MFA_ALREADY_ENROLLED", "Your authenticator is already set up.");
        if (ch.ReenrolmentRequired && SecureTokens.Parse(body.ReenrolmentToken) is null)
            throw ApiProblemException.Invalid("LINK_REQUIRED", "Open the link from your e-mail to set up your authenticator again.");
        var secret = Totp.NewSecret();
        pending.Store(http.Response, secret, token);
        // The label names the account (sub-domain); the e-mail is not readable before binding.
        return Results.Ok(new { secret = Base32.Encode(secret), otpauthUri = Totp.EnrolmentUri(secret, "BankFas", rc.TenantCode).ToString() });
    }

    private static async Task<IResult> CompleteEnrolmentAsync(EnrolmentCompleteRequest body, HttpContext http, SqlConnectionFactory db,
        PendingSecretProtector pending, TenantKeyRing keys, TimeProvider clock)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        var secret = pending.Take(http.Request, token) ?? throw ApiProblemException.Invalid("ENROLMENT_EXPIRED", "Start the set-up again.");
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        var ch = await ChallengeOrUnauthorizedAsync(c, tenant.TenantId, token, http);
        if (!ch.EnrolmentRequired) throw new ApiProblemException(409, "MFA_ALREADY_ENROLLED", "Your authenticator is already set up.");
        if (ch.MfaKeyId is null || ch.WrappedKey is null || ch.MasterKeyRef is null || ch.KeyVersion is null || ch.UserPublicId is null)
            throw new ApiProblemException(409, "NOT_READY", "The account is still being prepared.");
        var step = Totp.Verify(secret, body.Code, clock.GetUtcNow(), null)
                   ?? throw new ApiProblemException(401, "MFA_INVALID", "The code is not valid.");
        var key = keys.DataKey(tenant.TenantId, ch.MfaKeyId.Value, ch.KeyVersion.Value, ch.WrappedKey, ch.MasterKeyRef);
        var enc = Envelope.Seal(key, secret, EnvelopeAad.ForColumn(tenant.TenantId, "sec.AppUser", "MfaSecretEnc", ch.UserPublicId.Value));
        var codes = RecoveryCodes.Generate();
        await TenantAuthProcedures.CompleteMfaEnrolmentAsync(c, tenant.TenantId, token, enc, ch.MfaKeyId.Value, step,
            RecoveryCodes.HashesJson(codes), SecureTokens.Parse(body.ReenrolmentToken), http.RequestAborted);
        PendingSecretProtector.Clear(http.Response);
        return Results.Ok(new { nextStep = "DONE", recoveryCodes = codes });
    }

    private static async Task<IResult> AcceptInvitationAsync(InvitationRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var tenant = RequestContext.Of(http).RequireTenant();
        var link = SecureTokens.Parse(body.Token) ?? throw ApiProblemException.Invalid("LINK_INVALID", "This link has expired or has been used.");
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        var policy = await TenantAuthProcedures.GetPasswordPolicyAsync(c, tenant.TenantId, http.RequestAborted);
        PasswordRules.Check(body.Password, policy.MinLength, RequestContext.Of(http).TenantCode, tenant.NameEn);
        await TenantAuthProcedures.CompleteInvitationAsync(c, tenant.TenantId, link, PasswordHasher.HashNew(body.Password!), http.RequestAborted);
        return Results.Ok(new { nextStep = "LOGIN" });
    }

    private static async Task<IResult> LogoutAsync(HttpContext http, SqlConnectionFactory db)
    {
        var tenant = RequestContext.Of(http).RequireTenant();
        if (Cookies.SessionToken(http.Request) is { } token)
        {
            await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
            await TenantAuthProcedures.EndSessionAsync(c, tenant.TenantId, token, null, http.RequestAborted);
        }
        Cookies.ClearSession(http.Response);
        return Results.NoContent();
    }

    private static async Task<MfaChallenge> ChallengeOrUnauthorizedAsync(SqlConnection c, int tenantId, byte[] token, HttpContext http)
    {
        try
        {
            return await TenantAuthProcedures.GetMfaChallengeAsync(c, tenantId, token, false, http.RequestAborted);
        }
        catch (SqlException ex) when (ex.Number == DbErrors.NoValidSession)
        {
            throw ApiProblemException.Unauthorized();
        }
    }

    internal static byte[] OpenSecret(TenantKeyRing keys, int tenantId, MfaChallenge ch)
    {
        if (ch.MfaSecretEnc is null || ch.MfaKeyId is null || ch.WrappedKey is null || ch.MasterKeyRef is null || ch.KeyVersion is null || ch.UserPublicId is null)
            throw new ApiProblemException(409, "MFA_UNAVAILABLE", "Your authenticator cannot be checked. Ask your administrator to reset it.");
        var key = keys.DataKey(tenantId, ch.MfaKeyId.Value, ch.KeyVersion.Value, ch.WrappedKey, ch.MasterKeyRef);
        return Envelope.Open(key, ch.MfaSecretEnc, EnvelopeAad.ForColumn(tenantId, "sec.AppUser", "MfaSecretEnc", ch.UserPublicId.Value));
    }
}
