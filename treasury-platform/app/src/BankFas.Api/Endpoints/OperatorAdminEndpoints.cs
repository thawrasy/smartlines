using System.Data;
using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record ModulesRequest(string[]? Modules);
public sealed record InviteOperatorRequest(string? Email, string? DisplayName, string? Role, string? MfaCode);
public sealed record OperatorActionRequest(string? MfaCode);
/// <summary>PLATFORM (the platform setting security.mfa.required), REQUIRED or OFF (docs/31 row 46, ADR 0048).</summary>
public sealed record MfaPolicyRequest(string? Policy, string? MfaCode);

/// <summary>
/// The rest of the operator panel (SCR-PLT-52 to 56, DOC-B07 section 3): a tenant's details with counters but no
/// business data (FR-PLT-005), its modules, the first administrator's invitation sent again, the operator accounts,
/// the references the forms need, the key reference counts, and support: the operator's live grants and the pages
/// it opens through the support connection (tp_support), each recorded in the tenant's log (AC-PLT-8). Changes need
/// an OPERATOR_ADMIN; changes to operators also take a fresh code.
/// </summary>
public static class OperatorAdminEndpoints
{
    private static readonly string[] AllModules = ["CORE", "INSTITUTIONS", "FACILITIES", "COVENANTS", "WORKFLOW", "LC_PURCHASE", "LC_SALES", "REQUESTS", "REPORTS"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/tenants/{id:guid}", TenantAsync);
        api.MapPut("/tenants/{id:guid}/modules", ModulesAsync);
        api.MapPut("/tenants/{id:guid}/mfa-policy", MfaPolicyAsync);
        api.MapPost("/tenants/{id:guid}/actions/resend-invitation", ResendAsync);
        api.MapGet("/operators", OperatorsAsync);
        api.MapPost("/operators", InviteAsync);
        api.MapPost("/operators/{id:guid}/actions/{action}", OperatorActionAsync);
        api.MapGet("/plans", PlansAsync);
        api.MapGet("/countries", CountriesAsync);
        api.MapGet("/keys/reference-counts", KeyCountsAsync);
        api.MapGet("/support/grants", SupportGrantsAsync);
        api.MapGet("/support/{grant}/users", SupportUsersAsync);
    }

    private static async Task<int> TenantIdAsync(SqlConnection c, Guid id, CancellationToken ct, SqlTransaction? tx = null) =>
        await c.ExecuteScalarAsync<int?>(new CommandDefinition("SELECT TenantId FROM plat.Tenant WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.NotFound();

    internal static Task<int> WritePlatformAuditAsync(SqlConnection c, SqlTransaction? tx, int operatorId, string action, string entityType, long? entityId,
        object? after, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(
            """
            INSERT aud.AuditLog (TenantId, OccurredAt, ActorType, ActorId, Action, Category, Severity, EntityType, EntityId, AfterJson, Result)
            SELECT NULL, SYSUTCDATETIME(), 'OPERATOR', PublicId, @action, 'PLATFORM', 'HIGH', @type, @id, @after, 'SUCCESS'
            FROM plat.PlatformOperator WHERE PlatformOperatorId = @op;
            """, new { action, type = entityType, id = entityId, after = after is null ? null : JsonSerializer.Serialize(after), op = operatorId }, tx, cancellationToken: ct));

    private static async Task<IResult> TenantAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            var tenantId = await TenantIdAsync(c, id, http.RequestAborted);
            var t = await c.QuerySingleAsync(new CommandDefinition(
                """
                SELECT t.PublicId AS id, t.Code AS code, t.NameEn AS nameEn, t.NameAr AS nameAr, t.Status AS status, t.TrialEndsOn AS trialEndsOn,
                       t.TimeZone AS timeZone, t.DefaultLanguage AS defaultLanguage, t.SuspendedReason AS suspendedReason, t.ActivatedAt AS activatedAt,
                       t.ClosedAt AS closedAt, p.Code AS planCode, c.Iso2 AS homeCountryIso2, t.MfaPolicy AS mfaPolicy
                FROM plat.Tenant AS t JOIN plat.[Plan] AS p ON p.PlanId = t.PlanId JOIN ref.Country AS c ON c.CountryId = t.HomeCountryId
                WHERE t.TenantId = @t;
                """, new { t = tenantId }, cancellationToken: http.RequestAborted));
            var counters = await c.QuerySingleAsync(new CommandDefinition("plat.usp_GetTenantCounters",
                new { SessionToken = Cookies.RequireSessionToken(http.Request), TenantId = tenantId }, commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
            var modules = await c.QueryAsync(new CommandDefinition(
                "SELECT ModuleCode AS module, IsEnabled AS enabled, EnabledAt AS enabledAt FROM plat.TenantModule WHERE TenantId = @t ORDER BY ModuleCode;",
                new { t = tenantId }, cancellationToken: http.RequestAborted));
            return Results.Ok(new { tenant = t, counters, modules });
        }
    }

    /// <summary>Two-step verification for one tenant: the platform setting, required, or off (ADR 0048). Admin, fresh code.</summary>
    private static async Task<IResult> MfaPolicyAsync(Guid id, MfaPolicyRequest body, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock)
    {
        if (body.Policy is not ("PLATFORM" or "REQUIRED" or "OFF")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose PLATFORM, REQUIRED or OFF.");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await OperatorEndpoints.StepUpAsync(c, body.MfaCode, keys, clock, http);
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(http.RequestAborted);
            var tenantId = await TenantIdAsync(c, id, http.RequestAborted, tx);
            var before = await c.ExecuteScalarAsync<string>(new CommandDefinition(
                "SELECT MfaPolicy FROM plat.Tenant WITH (UPDLOCK) WHERE TenantId = @t; UPDATE plat.Tenant SET MfaPolicy = @p, UpdatedAt = SYSUTCDATETIME() WHERE TenantId = @t;",
                new { t = tenantId, p = body.Policy }, tx, cancellationToken: http.RequestAborted));
            await WritePlatformAuditAsync(c, tx, s.OperatorId, "TENANT_MFA_POLICY_CHANGED", "plat.Tenant", tenantId, new { from = before, to = body.Policy }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.NoContent();
        }
    }

    private static async Task<IResult> ModulesAsync(Guid id, ModulesRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var wanted = (body.Modules ?? []).Distinct(StringComparer.Ordinal).ToList();
        if (wanted.Any(m => !AllModules.Contains(m))) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A module code is not known.");
        if (!wanted.Contains("CORE")) throw ApiProblemException.Invalid("V-PLT-03", "CORE stays enabled.");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            var tenantId = await TenantIdAsync(c, id, http.RequestAborted);
            await using var tx = (SqlTransaction)await c.BeginTransactionAsync(http.RequestAborted);
            var before = (await c.QueryAsync<string>(new CommandDefinition(
                "SELECT ModuleCode FROM plat.TenantModule WITH (UPDLOCK, HOLDLOCK) WHERE TenantId = @t AND IsEnabled = 1;", new { t = tenantId }, tx,
                cancellationToken: http.RequestAborted))).ToList();
            foreach (var m in AllModules)
            {
                var on = wanted.Contains(m);
                await c.ExecuteAsync(new CommandDefinition(
                    """
                    UPDATE plat.TenantModule SET IsEnabled = @on, EnabledAt = CASE WHEN @on = 1 AND IsEnabled = 0 THEN SYSUTCDATETIME() ELSE EnabledAt END,
                           EnabledBy = CASE WHEN @on = 1 AND IsEnabled = 0 THEN @op ELSE EnabledBy END
                     WHERE TenantId = @t AND ModuleCode = @m AND IsEnabled <> @on;
                    IF @on = 1 AND NOT EXISTS (SELECT 1 FROM plat.TenantModule WHERE TenantId = @t AND ModuleCode = @m)
                        INSERT plat.TenantModule (TenantId, ModuleCode, IsEnabled, EnabledAt, EnabledBy) VALUES (@t, @m, 1, SYSUTCDATETIME(), @op);
                    """, new { t = tenantId, m, on, op = s.OperatorId }, tx, cancellationToken: http.RequestAborted));
            }
            await WritePlatformAuditAsync(c, tx, s.OperatorId, "TENANT_MODULES_CHANGED", "plat.Tenant", tenantId,
                new { before, after = wanted.Order(StringComparer.Ordinal) }, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            return Results.NoContent();
        }
    }

    private static async Task<IResult> ResendAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            var tenantId = await TenantIdAsync(c, id, http.RequestAborted);
            await c.ExecuteAsync(new CommandDefinition("plat.usp_ResendFirstAdminInvitation",
                new { SessionToken = Cookies.RequireSessionToken(http.Request), TenantId = tenantId }, commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
            return Results.Accepted(value: new { message = "The onboarding job sends a new invitation within a minute." });
        }
    }

    private static async Task<IResult> OperatorsAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            var rows = await c.QueryAsync(new CommandDefinition(
                """
                SELECT PublicId AS id, Email AS email, DisplayName AS displayName, Role AS role, Status AS status, MfaEnabled AS mfaEnabled,
                       LastLoginAt AS lastLoginAt
                FROM plat.PlatformOperator ORDER BY Email;
                """, cancellationToken: http.RequestAborted));
            return Results.Ok(new { items = rows });
        }
    }

    private static async Task<IResult> InviteAsync(InviteOperatorRequest body, HttpContext http, SqlConnectionFactory db, IKeyWrapper keys, TimeProvider clock, AccountMail mail)
    {
        if (string.IsNullOrWhiteSpace(body.Email) || string.IsNullOrWhiteSpace(body.DisplayName) || body.Role is not ("OPERATOR_ADMIN" or "OPERATOR_SUPPORT"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter the e-mail, the name and the role.");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            await OperatorEndpoints.StepUpAsync(c, body.MfaCode, keys, clock, http);
            var token = SecureTokens.NewToken();
            var p = new DynamicParameters(new { SessionToken = Cookies.RequireSessionToken(http.Request), Email = body.Email.Trim(), DisplayName = body.DisplayName.Trim(), body.Role, Token = token });
            p.Add("OperatorId", dbType: DbType.Int32, direction: ParameterDirection.Output);
            try
            {
                await c.ExecuteAsync(new CommandDefinition("plat.usp_InviteOperator", p, commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
            }
            catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
            {
                throw new ApiProblemException(409, "DUPLICATE", "An operator with this e-mail already exists.");
            }
            var sent = await mail.SendOperatorSetupAsync(body.Email.Trim(), token, reset: false, http.RequestAborted) is null;
            var publicId = await c.ExecuteScalarAsync<Guid>(new CommandDefinition("SELECT PublicId FROM plat.PlatformOperator WHERE PlatformOperatorId = @id;",
                new { id = p.Get<int>("OperatorId") }, cancellationToken: http.RequestAborted));
            return Results.Created($"/api/v1/operator/operators/{publicId}", new { id = publicId, invitationSent = sent });
        }
    }

    private static async Task<IResult> OperatorActionAsync(Guid id, string action, OperatorActionRequest? body, HttpContext http, SqlConnectionFactory db,
        IKeyWrapper keys, TimeProvider clock, AccountMail mail)
    {
        if (action is not ("disable" or "enable" or "archive" or "unlock" or "reset")) throw ApiProblemException.NotFound();
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            var (target, email) = await c.QuerySingleOrDefaultAsync<(int, string)>(new CommandDefinition(
                "SELECT PlatformOperatorId, Email FROM plat.PlatformOperator WHERE PublicId = @id;", new { id }, cancellationToken: http.RequestAborted));
            if (target == 0) throw ApiProblemException.NotFound();
            await OperatorEndpoints.StepUpAsync(c, body?.MfaCode, keys, clock, http);
            var session = Cookies.RequireSessionToken(http.Request);
            switch (action)
            {
                case "unlock":
                    await c.ExecuteAsync(new CommandDefinition("plat.usp_UnlockOperator", new { SessionToken = session, OperatorId = target },
                        commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
                    break;
                case "reset":
                    var token = SecureTokens.NewToken();
                    var p = new DynamicParameters(new { SessionToken = session, OperatorId = target, Token = token });
                    p.Add("SentTo", dbType: DbType.String, size: 254, direction: ParameterDirection.Output);
                    await c.ExecuteAsync(new CommandDefinition("plat.usp_ResetOperator", p, commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
                    await mail.SendOperatorSetupAsync(p.Get<string>("SentTo") ?? email, token, reset: true, http.RequestAborted);
                    break;
                default:
                    await c.ExecuteAsync(new CommandDefinition("plat.usp_SetOperatorStatus",
                        new { SessionToken = session, OperatorId = target, Status = action switch { "disable" => "DISABLED", "enable" => "ACTIVE", _ => "ARCHIVED" } },
                        commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
                    break;
            }
            var status = await c.ExecuteScalarAsync<string>(new CommandDefinition("SELECT Status FROM plat.PlatformOperator WHERE PlatformOperatorId = @id;",
                new { id = target }, cancellationToken: http.RequestAborted));
            return Results.Ok(new { id, status });
        }
    }

    private static async Task<IResult> PlansAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
            return Results.Ok(new { items = await c.QueryAsync(new CommandDefinition(
                "SELECT Code AS code, NameEn AS nameEn, NameAr AS nameAr FROM plat.[Plan] WHERE IsActive = 1 ORDER BY Code;", cancellationToken: http.RequestAborted)) });
    }

    private static async Task<IResult> CountriesAsync(HttpContext http, SqlConnectionFactory db)
    {
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
            return Results.Ok(new { items = await c.QueryAsync(new CommandDefinition(
                "SELECT Iso2 AS iso2, NameEn AS nameEn, NameAr AS nameAr FROM ref.Country ORDER BY NameEn;", cancellationToken: http.RequestAborted)) });
    }

    private static async Task<IResult> KeyCountsAsync(HttpContext http, SqlConnectionFactory db)
    {
        Query.Allow(http.Request, "status");
        var (c, s) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            if (!s.IsAdmin) throw ApiProblemException.Forbidden();
            var status = http.Request.Query["status"].ToString() is { Length: > 0 } st ? st : null;
            var rows = await c.QueryAsync(new CommandDefinition("sec.usp_KeyReferenceCounts", new { Status = status },
                commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
            return Results.Ok(new { items = rows });
        }
    }

    // ---------- support ----------

    private sealed record GrantRow(long SupportAccessGrantId, int TenantId, Guid TenantPublicId, string Code, string NameEn, string NameAr,
        string TenantStatus, DateTime StartsAt, DateTime EndsAt, string Reason);

    private static async Task<List<GrantRow>> GrantsAsync(SqlConnection c, HttpContext http) =>
        [.. await c.QueryAsync<GrantRow>(new CommandDefinition("plat.usp_ListOperatorSupportGrants",
            new { SessionToken = Cookies.RequireSessionToken(http.Request) }, commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted))];

    private static async Task<IResult> SupportGrantsAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
        {
            var grants = await GrantsAsync(c, http);
            return Results.Ok(new
            {
                items = grants.Select(g => new { id = refs.Cursor("support-grant", g.SupportAccessGrantId), tenantId = g.TenantPublicId, code = g.Code,
                    nameEn = g.NameEn, nameAr = g.NameAr, tenantStatus = g.TenantStatus, startsAt = g.StartsAt, endsAt = g.EndsAt, reason = g.Reason }),
            });
        }
    }

    /// <summary>One page of support: the tenant's users, read through the support connection and recorded in the tenant's log.</summary>
    private static async Task<IResult> SupportUsersAsync(string grant, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var grantId = refs.AfterId("support-grant", grant) ?? throw ApiProblemException.NotFound();
        GrantRow g;
        var (c, _) = await OperatorEndpoints.OpenSessionAsync(http, db);
        await using (c)
            g = (await GrantsAsync(c, http)).FirstOrDefault(x => x.SupportAccessGrantId == grantId) ?? throw ApiProblemException.NotFound();
        var rc = RequestContext.Of(http);
        await using var support = await db.OpenAsync(DbLogin.Support, http.RequestAborted);
        await support.ExecuteAsync(new CommandDefinition("sec.usp_SetSupportContext", new
        {
            TenantId = g.TenantId, SupportAccessGrantId = grantId, OperatorSessionToken = Cookies.RequireSessionToken(http.Request),
            ClientIp = rc.ClientIp, CorrelationId = rc.CorrelationId,
        }, commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
        await support.ExecuteAsync(new CommandDefinition("sec.usp_WriteSupportPageView", new { Page = "users", Refused = false },
            commandType: CommandType.StoredProcedure, cancellationToken: http.RequestAborted));
        var users = await support.QueryAsync(new CommandDefinition(
            "SELECT PublicId AS id, Email AS email, DisplayNameEn AS displayNameEn, Status AS status, MfaEnabled AS mfaEnabled FROM sec.AppUser WHERE IsSystemUser = 0 ORDER BY Email;",
            cancellationToken: http.RequestAborted));
        return Results.Ok(new { tenant = g.Code, items = users });
    }
}
