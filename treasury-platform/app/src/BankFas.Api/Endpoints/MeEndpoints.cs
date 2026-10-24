using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using BankFas.Data;
using Dapper;

namespace BankFas.Api.Endpoints;

public sealed record PreferencesRequest(string? PreferredLanguage, string? DigitsPreference);
public sealed record ChangePasswordRequest(string? CurrentPassword, string? NewPassword, string? StepUpCode);
/// <summary>Login is the e-mail, employee code or mobile number; the link goes to the account's e-mail (ADR 0048).</summary>
public sealed record ResetRequest(string? Login, string? Email);
public sealed record ResetCompleteRequest(string? Token, string? NewPassword);

/// <summary>
/// The user's own account (SCR-PLT-15) and the password reset by e-mail (SCR-PLT-03, UC-PLT-10). A password change takes
/// the current password and a fresh code (DOC-S04 section 9); the new password is checked against the tenant's rules
/// and the last passwords (BR-PLT-004) by hashing it under each stored parameter set. A reset request answers 202 with
/// the same body whether or not the e-mail exists (AC-PLT-11).
/// </summary>
public static class MeEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapPatch("/me/preferences", PreferencesAsync);
        api.MapPost("/me/password", ChangePasswordAsync).RequireRateLimiting("login");
        api.MapGet("/me/sessions", SessionsAsync);
        api.MapDelete("/me/sessions/{reference}", EndSessionAsync);
        api.MapPost("/auth/password-reset-requests", RequestResetAsync).RequireRateLimiting("reset");
        api.MapPost("/auth/password-resets", ResetAsync).RequireRateLimiting("login");
    }

    private static async Task<IResult> PreferencesAsync(PreferencesRequest body, HttpContext http, SqlConnectionFactory db)
    {
        if (body.PreferredLanguage is not (null or "ar" or "en") || body.DigitsPreference is not (null or "WESTERN" or "ARABIC_INDIC"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a language and a digit style from the list.");
        await using var u = await BoundUser.OpenAsync(http, db);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "UPDATE sec.AppUser SET PreferredLanguage = COALESCE(@l, PreferredLanguage), DigitsPreference = COALESCE(@d, DigitsPreference) WHERE AppUserId = @id;",
            new { l = body.PreferredLanguage, d = body.DigitsPreference, id = u.UserId }, cancellationToken: http.RequestAborted));
        return Results.NoContent();
    }

    private static async Task<IResult> ChangePasswordAsync(ChangePasswordRequest body, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock, BreachedPasswords breached)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        if (string.IsNullOrEmpty(body.CurrentPassword)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter your current password.");
        string email;
        await using (var u = await BoundUser.OpenAsync(http, db))
            email = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
                "SELECT Email FROM sec.AppUser WHERE AppUserId = @id;", new { id = u.UserId }, cancellationToken: http.RequestAborted)) ?? "";
        await StepUp.RequireAsync(http, db, keys, clock, body.StepUpCode);
        // The change revokes the user's bindings, so it runs on an unbound connection (035).
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        await ApplyPasswordChangeAsync(c, http, breached, body.CurrentPassword, body.NewPassword, email);
        return Results.NoContent();
    }

    /// <summary>
    /// The current password proven and the new one set, through the session token (035): the tenant's rules, the
    /// breached list and the last passwords (BR-PLT-004). Used by the account page and the first sign-in (ADR 0048).
    /// </summary>
    internal static async Task ApplyPasswordChangeAsync(Microsoft.Data.SqlClient.SqlConnection c, HttpContext http, BreachedPasswords breached,
        string currentPassword, string? newPassword, string? email)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var token = Cookies.RequireSessionToken(http.Request);
        var policy = await TenantAuthProcedures.GetPasswordPolicyAsync(c, tenant.TenantId, http.RequestAborted);
        if (email is null) PasswordRules.Check(breached, newPassword, policy.MinLength, rc.TenantCode, tenant.NameEn);
        else PasswordRules.Check(breached, newPassword, policy.MinLength, rc.TenantCode, email.Split('@')[0], tenant.NameEn);
        var (stored, _) = await TenantAuthProcedures.GetSessionPasswordParamsAsync(c, tenant.TenantId, token, http.RequestAborted);
        var currentHash = (stored is null ? null : PasswordHasher.HashWithStoredParameters(currentPassword, stored))
                          ?? PasswordHasher.HashForUnknownUser(currentPassword);
        var history = await TenantAdminProcedures.GetPasswordHistoryParamsAsync(c, tenant.TenantId, token, null, http.RequestAborted);
        await TenantAdminProcedures.ChangePasswordAsync(c, tenant.TenantId, token, currentHash, PasswordHasher.HashNew(newPassword!),
            Candidates(newPassword!, history), rc.ClientIp, http.RequestAborted);
    }

    private static async Task<IResult> SessionsAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db);
        var current = SecureTokens.Sha256(Cookies.RequireSessionToken(http.Request));
        var currentId = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT UserSessionId FROM sec.UserSession WHERE TokenHash = @h;", new { h = current }, cancellationToken: http.RequestAborted));
        var items = await UserEndpoints.LiveSessionsAsync(u, refs, u.UserId, http.RequestAborted);
        return Results.Ok(new { items, current = currentId is null ? null : refs.SessionRef(u.TenantId, currentId.Value) });
    }

    private static async Task<IResult> EndSessionAsync(string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db);
        var sid = refs.SessionId(u.TenantId, reference) ?? throw ApiProblemException.NotFound();
        var owner = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT UserId FROM sec.UserSession WHERE UserSessionId = @s;", new { s = sid }, cancellationToken: http.RequestAborted));
        if (owner != u.UserId) throw ApiProblemException.NotFound();
        await TenantAuthProcedures.EndSessionAsync(u.Connection, u.TenantId, null, sid, http.RequestAborted);
        return Results.NoContent();
    }

    private static async Task<IResult> RequestResetAsync(ResetRequest body, HttpContext http, SqlConnectionFactory db, AccountMail mail)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var login = (body.Login ?? body.Email)?.Trim();
        if (!string.IsNullOrEmpty(login) && login.Length <= 254)
        {
            var token = SecureTokens.NewToken();
            await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
            var to = await TenantAdminProcedures.RequestPasswordResetAsync(c, tenant.TenantId, login, token, rc.ClientIp, http.RequestAborted);
            // A send failure cannot be recorded before binding (GAP-16); the application log has it.
            if (to is not null) await mail.SendAsync(rc.TenantCode, to, "PASSWORD_RESET", token, http.RequestAborted);
        }
        return Results.Accepted(value: new { message = "If this belongs to an account, a link is on its way to its e-mail." });
    }

    private static async Task<IResult> ResetAsync(ResetCompleteRequest body, HttpContext http, SqlConnectionFactory db, BreachedPasswords breached)
    {
        var rc = RequestContext.Of(http);
        var tenant = rc.RequireTenant();
        var link = SecureTokens.Parse(body.Token) ?? throw ApiProblemException.Invalid("LINK_INVALID", "This link has expired or has been used.");
        await using var c = await db.OpenAsync(DbLogin.App, http.RequestAborted);
        var policy = await TenantAuthProcedures.GetPasswordPolicyAsync(c, tenant.TenantId, http.RequestAborted);
        PasswordRules.Check(breached, body.NewPassword, policy.MinLength, rc.TenantCode, tenant.NameEn);
        IReadOnlyList<string> history;
        try { history = await TenantAdminProcedures.GetPasswordHistoryParamsAsync(c, tenant.TenantId, null, link, http.RequestAborted); }
        catch (Microsoft.Data.SqlClient.SqlException ex) when (ex.Number == DbErrors.NoValidSession)
        {
            throw ApiProblemException.Invalid("LINK_INVALID", "This link has expired or has been used.");
        }
        await TenantAdminProcedures.ResetPasswordAsync(c, tenant.TenantId, link, PasswordHasher.HashNew(body.NewPassword!),
            Candidates(body.NewPassword!, history), http.RequestAborted);
        return Results.Ok(new { nextStep = "LOGIN" });
    }

    private static string Candidates(string password, IEnumerable<string> parameterSets) =>
        System.Text.Json.JsonSerializer.Serialize(parameterSets.Select(p => PasswordHasher.HashWithStoredParameters(password, p)).Where(h => h is not null));
}
