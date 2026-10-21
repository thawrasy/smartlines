using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record OperatorSetupStartRequest(string? Token);
public sealed record OperatorSetupCompleteRequest(string? Token, string? Password, string? Code);
public sealed record CreateTenantRequest(string? Code, string? NameEn, string? NameAr, string? PlanCode, string? HomeCountryIso2,
    string? TimeZone, string? DefaultLanguage, string? AdminEmail, string? AdminDisplayName, string? MfaCode);
public sealed record TenantStatusRequest(string? Status, string? Reason, DateOnly? TrialEndsOn, string? MfaCode);

/// <summary>
/// The operator panel on its own host (DOC-F05, brief section 2.11): set-up through the link, login with TOTP, the
/// tenant list, tenant creation and status changes. Creating a tenant and changing its status take a fresh TOTP code
/// in the same request (step-up within 5 minutes, DQ-F05-2). The panel shows statuses, never business data (FR-PLT-005).
/// </summary>
public static class OperatorEndpoints
{
    // Operators are created and changed only through the database procedures, so no row can take another operator's
    // secret; the associated data names the column without a row id, which is not known before set-up (ADR 0040).
    private static byte[] SecretAad => EnvelopeAad.ForColumn(0, "plat.PlatformOperator", "MfaSecretEnc", Guid.Empty);

    public static void Map(RouteGroupBuilder api)
    {
        var auth = api.MapGroup("/auth");
        auth.MapPost("/login", LoginAsync).RequireRateLimiting("login");
        auth.MapPost("/mfa", MfaAsync).RequireRateLimiting("mfa");
        auth.MapPost("/setup", StartSetup);
        auth.MapPost("/setup/complete", CompleteSetupAsync).RequireRateLimiting("mfa");
        auth.MapPost("/logout", LogoutAsync);

        api.MapGet("/me", async (HttpContext http, SqlConnectionFactory db) =>
        {
            var (c, s) = await OpenSessionAsync(http, db);
            await using (c)
            {
                var me = await c.QuerySingleAsync<(Guid PublicId, string Email, string? DisplayName)>(new CommandDefinition(
                    "SELECT PublicId, Email, DisplayName FROM plat.PlatformOperator WHERE PlatformOperatorId = @id;", new { id = s.OperatorId },
                    cancellationToken: http.RequestAborted));
                return Results.Ok(new { id = me.PublicId, email = me.Email, displayName = me.DisplayName, role = s.Role });
            }
        });
        api.MapGet("/tenants", ListTenantsAsync);
        api.MapPost("/tenants", CreateTenantAsync);
        api.MapPost("/tenants/{id:guid}/status", SetStatusAsync);
    }

    private static async Task<IResult> LoginAsync(LoginRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var rc = RequestContext.Of(http);
        if (string.IsNullOrWhiteSpace(body.Email) || string.IsNullOrEmpty(body.Password) || body.Password.Length > 1024)
            throw new ApiProblemException(401, "INVALID_CREDENTIALS", "Invalid email or password.");
        var email = body.Email.Trim();
        await using var c = await db.OpenAsync(DbLogin.Platform, http.RequestAborted);
        var stored = await OperatorProcedures.GetPasswordParamsAsync(c, email, http.RequestAborted);
        var hash = (stored is null ? null : PasswordHasher.HashWithStoredParameters(body.Password, stored)) ?? PasswordHasher.HashForUnknownUser(body.Password);
        var token = SecureTokens.NewToken();
        await OperatorProcedures.StartSessionAsync(c, email, hash, token, rc.ClientIp, http.Request.Headers.UserAgent.ToString(), http.RequestAborted);
        Cookies.SetSession(http.Response, token);
        return Results.Ok(new { nextStep = "MFA_REQUIRED" });
    }

    private static async Task<IResult> MfaAsync(MfaRequest body, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock)
    {
        var token = Cookies.RequireSessionToken(http.Request);
        await using var c = await db.OpenAsync(DbLogin.Platform, http.RequestAborted);
        if (!await CheckCodeAsync(c, token, body.Code, keys, clock, http)) throw new ApiProblemException(401, "MFA_INVALID", "The code is not valid.");
        return Results.Ok(new { nextStep = "DONE" });
    }

    private static IResult StartSetup(OperatorSetupStartRequest body, HttpContext http, PendingSecretProtector pending)
    {
        var link = SecureTokens.Parse(body.Token) ?? throw ApiProblemException.Invalid("LINK_INVALID", "This link has expired or has been used.");
        var secret = Totp.NewSecret();
        pending.Store(http.Response, secret, link);
        return Results.Ok(new { secret = Base32.Encode(secret), otpauthUri = Totp.EnrolmentUri(secret, "BankFas", "operator").ToString() });
    }

    private static async Task<IResult> CompleteSetupAsync(OperatorSetupCompleteRequest body, HttpContext http, SqlConnectionFactory db,
        PendingSecretProtector pending, IKeyWrapper keys, TimeProvider clock, BreachedPasswords breached)
    {
        var link = SecureTokens.Parse(body.Token) ?? throw ApiProblemException.Invalid("LINK_INVALID", "This link has expired or has been used.");
        var secret = pending.Take(http.Request, link) ?? throw ApiProblemException.Invalid("ENROLMENT_EXPIRED", "Start the set-up again.");
        PasswordRules.Check(breached, body.Password, PasswordRules.OperatorMinLength);
        var step = Totp.Verify(secret, body.Code, clock.GetUtcNow(), null) ?? throw new ApiProblemException(401, "MFA_INVALID", "The code is not valid.");
        var keyRef = keys.CurrentMasterKeyRef;
        var enc = keys.Wrap(keyRef, secret, SecretAad);
        await using var c = await db.OpenAsync(DbLogin.Platform, http.RequestAborted);
        await OperatorProcedures.CompleteSetupAsync(c, link, PasswordHasher.HashNew(body.Password!), enc, keyRef, step, http.RequestAborted);
        PendingSecretProtector.Clear(http.Response);
        return Results.Ok(new { nextStep = "LOGIN" });
    }

    private static async Task<IResult> LogoutAsync(HttpContext http, SqlConnectionFactory db)
    {
        if (Cookies.SessionToken(http.Request) is { } token)
        {
            await using var c = await db.OpenAsync(DbLogin.Platform, http.RequestAborted);
            await OperatorProcedures.EndSessionAsync(c, token, http.RequestAborted);
        }
        Cookies.ClearSession(http.Response);
        return Results.NoContent();
    }

    private static async Task<IResult> ListTenantsAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (c, _) = await OpenSessionAsync(http, db);
        await using (c)
        {
            var rows = await c.QueryAsync(new CommandDefinition(
                """
                SELECT t.PublicId AS id, t.Code AS code, t.NameEn AS nameEn, t.NameAr AS nameAr, t.Status AS status,
                       t.TrialEndsOn AS trialEndsOn, p.Code AS planCode
                FROM plat.Tenant AS t JOIN plat.[Plan] AS p ON p.PlanId = t.PlanId
                ORDER BY t.Code;
                """, cancellationToken: http.RequestAborted));
            return Results.Ok(new { items = rows });
        }
    }

    private static async Task<IResult> CreateTenantAsync(CreateTenantRequest body, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock)
    {
        var (c, s) = await OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            if (string.IsNullOrWhiteSpace(body.Code) || string.IsNullOrWhiteSpace(body.NameEn) || string.IsNullOrWhiteSpace(body.NameAr)
                || string.IsNullOrWhiteSpace(body.AdminEmail) || string.IsNullOrWhiteSpace(body.AdminDisplayName) || string.IsNullOrWhiteSpace(body.TimeZone))
                throw ApiProblemException.Invalid("VALIDATION_FAILED", "Fill in every field.");
            if (!TimeZoneInfo.TryFindSystemTimeZoneById(body.TimeZone, out _))
                throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a time zone from the list.");
            var ids = await c.QuerySingleOrDefaultAsync<(int? PlanId, int? CountryId)>(new CommandDefinition(
                "SELECT (SELECT PlanId FROM plat.[Plan] WHERE Code = @p AND IsActive = 1), (SELECT CountryId FROM ref.Country WHERE Iso2 = @c);",
                new { p = body.PlanCode ?? "STANDARD", c = body.HomeCountryIso2?.ToUpperInvariant() }, cancellationToken: http.RequestAborted));
            if (ids.PlanId is null || ids.CountryId is null) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a plan and a country from the lists.");
            await StepUpAsync(c, body.MfaCode, keys, clock, http);
            var created = await OperatorProcedures.CreateTenantAsync(c, Cookies.RequireSessionToken(http.Request), body.Code.Trim().ToLowerInvariant(),
                body.NameAr.Trim(), body.NameEn.Trim(), ids.PlanId.Value, ids.CountryId.Value, body.TimeZone, body.DefaultLanguage ?? "en",
                body.AdminEmail.Trim(), body.AdminDisplayName.Trim(), http.RequestAborted);
            var publicId = await c.ExecuteScalarAsync<Guid>(new CommandDefinition(
                "SELECT PublicId FROM plat.Tenant WHERE TenantId = @t;", new { t = created.TenantId }, cancellationToken: http.RequestAborted));
            return Results.Created($"/api/v1/tenants/{publicId}", new { id = publicId, status = "TRIAL" });
        }
    }

    private static async Task<IResult> SetStatusAsync(Guid id, TenantStatusRequest body, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock)
    {
        var (c, s) = await OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            var tenantId = await c.ExecuteScalarAsync<int?>(new CommandDefinition(
                "SELECT TenantId FROM plat.Tenant WHERE PublicId = @id;", new { id }, cancellationToken: http.RequestAborted)) ?? throw ApiProblemException.NotFound();
            if (body.Status is not ("TRIAL" or "ACTIVE" or "SUSPENDED" or "CLOSED")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a status.");
            await StepUpAsync(c, body.MfaCode, keys, clock, http);
            await OperatorProcedures.SetTenantStatusAsync(c, Cookies.RequireSessionToken(http.Request), tenantId, body.Status, body.Reason, body.TrialEndsOn, http.RequestAborted);
            return Results.NoContent();
        }
    }

    /// <summary>The panel's session for this request, with its MFA check done; a connection as tp_platform.</summary>
    internal static async Task<(SqlConnection, OperatorSessionState)> OpenSessionAsync(HttpContext http, SqlConnectionFactory db)
    {
        var token = Cookies.RequireSessionToken(http.Request);
        var c = await db.OpenAsync(DbLogin.Platform, http.RequestAborted);
        try
        {
            var state = await OperatorProcedures.TouchSessionAsync(c, token, http.RequestAborted);
            if (state.MfaVerifiedAt is null) throw new ApiProblemException(401, "MFA_REQUIRED", "Enter the code from your authenticator.");
            return (c, state);
        }
        catch (SqlException ex) when (ex.Number == DbErrors.NoValidSession)
        {
            await c.DisposeAsync();
            Cookies.ClearSession(http.Response);
            throw ApiProblemException.Unauthorized();
        }
        catch
        {
            await c.DisposeAsync();
            throw;
        }
    }

    internal static async Task StepUpAsync(SqlConnection c, string? code, IKeyWrapper keys, TimeProvider clock, HttpContext http)
    {
        if (!await CheckCodeAsync(c, Cookies.RequireSessionToken(http.Request), code, keys, clock, http))
            throw new ApiProblemException(403, "STEP_UP_REQUIRED", "Confirm with a fresh authenticator code.");
    }

    private static async Task<bool> CheckCodeAsync(SqlConnection c, byte[] token, string? code, IKeyWrapper keys, TimeProvider clock, HttpContext http)
    {
        OperatorMfaChallenge ch;
        try { ch = await OperatorProcedures.GetMfaChallengeAsync(c, token, http.RequestAborted); }
        catch (SqlException ex) when (ex.Number == DbErrors.NoValidSession)
        {
            Cookies.ClearSession(http.Response);
            throw ApiProblemException.Unauthorized();
        }
        var secret = keys.Unwrap(ch.MfaKeyRef, ch.MfaSecretEnc, SecretAad);
        var step = Totp.Verify(secret, code, clock.GetUtcNow(), ch.LastUsedStep);
        return await OperatorProcedures.ConfirmMfaAsync(c, token, step, http.RequestAborted);
    }
}
