using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

/// <summary>Method: INVITATION (a link by e-mail, the default) or TEMP_PASSWORD (handed over, changed at the first sign-in), as the tenant allows (ADR 0048).</summary>
public sealed record InviteUserRequest(string? Email, string? DisplayNameEn, string? DisplayNameAr, Guid[]? RoleIds, string? StepUpCode,
    string? EmployeeCode = null, string? Mobile = null, string? Method = null);
/// <summary>Department: a department reference, or "" to clear. LineManager: a user's id; ClearLineManager removes it (S3 brief S3-GAP-9).</summary>
/// <summary>EmployeeCode and Mobile: the sign-in names besides the e-mail; "" clears one (ADR 0048).</summary>
public sealed record PatchUserRequest(string? DisplayNameEn, string? DisplayNameAr, string? PreferredLanguage, string? DigitsPreference, string? Department = null,
    Guid? LineManager = null, bool? ClearLineManager = null, string? EmployeeCode = null, string? Mobile = null);
public sealed record ProductScopeRequest(string? Mode, string[]? Modules);
public sealed record UserRolesRequest(Guid[]? RoleIds, string? StepUpCode);
public sealed record UserActionRequest(string? Reason, string? StepUpCode);
public sealed record CompanyScopeEntry(Guid Id, bool IncludeDescendants);
public sealed record CompanyScopeRequest(string? Mode, CompanyScopeEntry[]? Companies);

/// <summary>
/// Users of the tenant (SCR-PLT-07, 08, 10; DOC-F06): list, invite, details, roles, company scope, the account actions
/// and sessions. All need sec.user.manage (DQ-F06-3). The rules the database leaves to the application are here: the
/// last active account administrator (TA) is never disabled, archived or stripped of TA (FR-PLT-016, LAST_ACCOUNT_ADMIN);
/// an administrator does not reset or unlock their own account; the service account is never shown; assigning TM or FO,
/// and an MFA reset, take a fresh code (step-up) and a HIGH audit row.
/// </summary>
public static class UserEndpoints
{
    private const string Manage = "sec.user.manage";
    private static readonly string[] StepUpRoles = ["TM", "FO"];

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/users", ListAsync);
        api.MapPost("/users", InviteAsync);
        api.MapGet("/users/{id:guid}", GetAsync);
        api.MapPatch("/users/{id:guid}", PatchAsync);
        api.MapPut("/users/{id:guid}/roles", SetRolesAsync);
        api.MapPut("/users/{id:guid}/company-scope", SetScopeAsync);
        api.MapPut("/users/{id:guid}/product-scope", SetProductScopeAsync);
        api.MapPost("/users/{id:guid}/actions/{action}", ActAsync);
        api.MapGet("/users/{id:guid}/sessions", SessionsAsync);
        api.MapDelete("/users/{id:guid}/sessions", EndAllSessionsAsync);
        api.MapDelete("/users/{id:guid}/sessions/{reference}", EndSessionAsync);
    }

    private sealed record UserRow(long AppUserId, Guid PublicId, string Email, string? DisplayNameEn, string? DisplayNameAr, string Status,
        bool MfaEnabled, DateTime? LastLoginAt, string CompanyScopeMode, string? PreferredLanguage, string? DigitsPreference, byte[] RowVersion,
        DateTime CreatedAt, long? DepartmentId, long? LineManagerUserId, string? EmployeeCode, string? Mobile, string ProductScopeMode, bool MustChangePassword);

    private const string UserColumns =
        "AppUserId, PublicId, Email, DisplayNameEn, DisplayNameAr, Status, MfaEnabled, LastLoginAt, CompanyScopeMode, PreferredLanguage, DigitsPreference, RowVersion, CreatedAt, DepartmentId, LineManagerUserId, EmployeeCode, Mobile, ProductScopeMode, MustChangePassword";

    private static object View(UserRow u, IEnumerable<string>? roles = null) => new
    {
        id = u.PublicId, email = u.Email, displayNameEn = u.DisplayNameEn, displayNameAr = u.DisplayNameAr, status = u.Status,
        mfaEnabled = u.MfaEnabled, lastLoginAt = u.LastLoginAt, companyScopeMode = u.CompanyScopeMode,
        preferredLanguage = u.PreferredLanguage, digitsPreference = u.DigitsPreference, createdAt = u.CreatedAt, roles,
        employeeCode = u.EmployeeCode, mobile = u.Mobile, productScopeMode = u.ProductScopeMode, mustChangePassword = u.MustChangePassword,
    };

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        Query.Allow(http.Request, "status", "q", "limit", "cursor");
        var limit = Query.Limit(http.Request);
        var after = refs.AfterId("users", http.Request.Query["cursor"]);
        var status = http.Request.Query["status"].ToString() is { Length: > 0 } st ? st : null;
        var q = http.Request.Query["q"].ToString() is { Length: > 0 } qq ? "%" + qq.Replace("[", "[[]", StringComparison.Ordinal).Replace("%", "[%]", StringComparison.Ordinal).Replace("_", "[_]", StringComparison.Ordinal) + "%" : null;
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var rows = (await u.Connection.QueryAsync<UserRow>(new CommandDefinition(
            $"""
            SELECT TOP (@take) {UserColumns} FROM sec.AppUser
            WHERE IsSystemUser = 0 AND (@after IS NULL OR AppUserId > @after) AND (@status IS NULL OR Status = @status)
              AND (@q IS NULL OR Email LIKE @q OR DisplayNameEn LIKE @q OR DisplayNameAr LIKE @q OR EmployeeCode LIKE @q OR Mobile LIKE @q)
            ORDER BY AppUserId;
            """, new { take = limit + 1, after, status, q }, cancellationToken: http.RequestAborted))).ToList();
        var page = rows.Take(limit).ToList();
        var roles = await RolesOfAsync(u.Connection, page.Select(r => r.AppUserId), http.RequestAborted);
        return Results.Ok(new
        {
            items = page.Select(r => View(r, roles[r.AppUserId])),
            nextCursor = rows.Count > limit ? refs.Cursor("users", page[^1].AppUserId) : null,
        });
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var row = await FindAsync(u.Connection, null, id, http.RequestAborted);
        var roles = await RolesOfAsync(u.Connection, [row.AppUserId], http.RequestAborted);
        var scope = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT c.PublicId AS id, s.IncludeDescendants AS includeDescendants
            FROM sec.UserCompanyScope AS s JOIN org.Company AS c ON c.CompanyId = s.CompanyId
            WHERE s.UserId = @u;
            """, new { u = row.AppUserId }, cancellationToken: http.RequestAborted));
        var department = row.DepartmentId is null ? null : await u.Connection.QuerySingleOrDefaultAsync<(string Code, string NameAr, string NameEn)?>(new CommandDefinition(
            "SELECT Code, NameAr, NameEn FROM org.Department WHERE DepartmentId = @d;", new { d = row.DepartmentId }, cancellationToken: http.RequestAborted));
        var manager = row.LineManagerUserId is null ? null : await u.Connection.QuerySingleOrDefaultAsync<(Guid Id, string? NameEn, string? NameAr)?>(new CommandDefinition(
            "SELECT PublicId, DisplayNameEn, DisplayNameAr FROM sec.AppUser WHERE AppUserId = @m;", new { m = row.LineManagerUserId }, cancellationToken: http.RequestAborted));
        var products = await u.Connection.QueryAsync<string>(new CommandDefinition(
            "SELECT ModuleCode FROM sec.UserProductScope WHERE UserId = @u ORDER BY ModuleCode;", new { u = row.AppUserId }, cancellationToken: http.RequestAborted));
        ETags.Set(http.Response, row.RowVersion);
        return Results.Ok(new
        {
            user = View(row, roles[row.AppUserId]), companies = scope, products,
            department = row.DepartmentId is { } d && department is { } dp
                ? new { id = refs.ItemRef(u.TenantId, "department", d), code = dp.Code, nameAr = dp.NameAr, nameEn = dp.NameEn } : null,
            lineManager = manager is { } m ? new { id = m.Id, displayNameEn = m.NameEn, displayNameAr = m.NameAr } : null,
        });
    }

    private static async Task<IResult> InviteAsync(InviteUserRequest body, HttpContext http, SqlConnectionFactory db, AccountMail mail,
        TenantKeyRing keys, TimeProvider clock)
    {
        var email = body.Email?.Trim();
        if (string.IsNullOrEmpty(email) || email.Length > 254 || !email.Contains('@', StringComparison.Ordinal) || string.IsNullOrWhiteSpace(body.DisplayNameEn))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter an e-mail address and a name.");
        var method = body.Method ?? "INVITATION";
        if (!SignInIdentity.CreationMethods.Contains(method)) throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose an invitation or a temporary password.");
        var employeeCode = SignInIdentity.EmployeeCode(body.EmployeeCode);
        var mobile = SignInIdentity.Mobile(body.Mobile);
        var rc = RequestContext.Of(http);
        long userId;
        Guid publicId;
        string sentTo;
        var token = SecureTokens.NewToken();
        await using (var check = await BoundUser.OpenAsync(http, db, Manage))
        {
            if (!(await SignInIdentity.ListSettingAsync(check.Connection, null, "security.user.creation", SignInIdentity.CreationMethods, http.RequestAborted)).Contains(method))
                throw new ApiProblemException(409, "V-USR-CREATION", "The account does not create users this way (security.user.creation).");
            var roleRows = await ResolveRolesAsync(check.Connection, body.RoleIds ?? [], http.RequestAborted);
            // A temporary password hands over a working account, so it takes a fresh proof like a sensitive role.
            if (roleRows.Any(r => StepUpRoles.Contains(r.Code)) || method == "TEMP_PASSWORD") await StepUp.RequireAsync(http, db, keys, clock, body.StepUpCode);
        }
        await using (var u = await BoundUser.OpenAsync(http, db, Manage))
        {
            var roleRows = await ResolveRolesAsync(u.Connection, body.RoleIds ?? [], http.RequestAborted);
            var minLength = (await TenantAuthProcedures.GetPasswordPolicyAsync(u.Connection, u.TenantId, http.RequestAborted)).MinLength;
            await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
            try
            {
                (userId, publicId) = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
                    """
                    DECLARE @o TABLE (AppUserId BIGINT, PublicId UNIQUEIDENTIFIER);
                    INSERT sec.AppUser (TenantId, Email, DisplayNameEn, DisplayNameAr, Status, EmployeeCode, Mobile)
                    OUTPUT inserted.AppUserId, inserted.PublicId INTO @o
                    VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @email, @en, @ar, 'INVITED', @code, @mobile);
                    SELECT AppUserId, PublicId FROM @o;
                    """, new { email, en = body.DisplayNameEn.Trim(), ar = body.DisplayNameAr?.Trim(), code = employeeCode, mobile }, tx, cancellationToken: http.RequestAborted));
            }
            catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
            {
                throw ApiProblemException.Invalid("V-PLT-07", UniqueMessage(ex));
            }
            await AddRolesAsync(u, tx, userId, roleRows.Select(r => r.RoleId), http.RequestAborted);
            await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("USER_INVITED", "IDENTITY_ACCESS", "sec.AppUser", userId,
                AfterJson: JsonSerializer.Serialize(new { email, employeeCode, mobile, method, roles = roleRows.Select(r => r.Code) }),
                Severity: roleRows.Any(r => StepUpRoles.Contains(r.Code)) || method == "TEMP_PASSWORD" ? "HIGH" : "INFO"), http.RequestAborted);
            if (method == "TEMP_PASSWORD")
            {
                // Shown once to the administrator, never stored or sent by the platform (ADR 0048).
                var temporary = SignInIdentity.TemporaryPassword(minLength);
                await TenantAdminProcedures.SetTemporaryPasswordAsync(u.Connection, tx, u.TenantId, userId, PasswordHasher.HashNew(temporary), http.RequestAborted);
                await tx.CommitAsync(http.RequestAborted);
                return Results.Created($"/api/v1/users/{publicId}", new { id = publicId, status = "ACTIVE", temporaryPassword = temporary, invitationSent = false });
            }
            sentTo = await TenantAdminProcedures.IssueUserTokenAsync(u.Connection, tx, u.TenantId, userId, "INVITATION", token, http.RequestAborted);
            await tx.CommitAsync(http.RequestAborted);
            var sent = await mail.SendAndRecordAsync(u.Connection, rc.TenantCode, userId, sentTo, "INVITATION", token, http.RequestAborted);
            return Results.Created($"/api/v1/users/{publicId}", new { id = publicId, status = "INVITED", invitationSent = sent });
        }
    }

    private static async Task<IResult> PatchAsync(Guid id, PatchUserRequest body, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        var expected = ETags.Required(http.Request);
        if (body.PreferredLanguage is not (null or "ar" or "en") || body.DigitsPreference is not (null or "WESTERN" or "ARABIC_INDIC"))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Choose a language and a digit style from the list.");
        if (body.LineManager is not null && body.ClearLineManager == true)
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Set a line manager or clear it, not both.");
        var codeSet = body.EmployeeCode is not null;
        var employeeCode = SignInIdentity.EmployeeCode(body.EmployeeCode);
        var mobileSet = body.Mobile is not null;
        var mobile = SignInIdentity.Mobile(body.Mobile);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, http.RequestAborted);
        var row = await FindAsync(u.Connection, tx, id, http.RequestAborted);

        // The department: an active one of the account (FR-ORG-014); "" clears it.
        var departmentSet = body.Department is not null;
        long? department = null;
        if (body.Department is { Length: > 0 } dref)
        {
            department = refs.ItemId(u.TenantId, "department", dref) is { } d && await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                "SELECT COUNT(*) FROM org.Department WHERE DepartmentId = @d AND IsActive = 1;", new { d }, tx, cancellationToken: http.RequestAborted)) == 1
                ? d : throw ApiProblemException.Invalid("DEPARTMENT_NOT_FOUND", "Choose an active department.");
        }
        // The line manager: an active user of the account, not the user, and not someone the user manages (BR-WFL-005).
        long? manager = null;
        if (body.LineManager is { } mid)
        {
            var m = await u.Connection.QuerySingleOrDefaultAsync<(long Id, string Status)?>(new CommandDefinition(
                "SELECT AppUserId, Status FROM sec.AppUser WHERE PublicId = @mid AND IsSystemUser = 0 AND ArchivedAt IS NULL;", new { mid }, tx,
                cancellationToken: http.RequestAborted));
            if (m is not { } mm || mm.Status is "DISABLED") throw ApiProblemException.Invalid("MANAGER_NOT_FOUND", "Choose an active user as the line manager.");
            if (mm.Id == row.AppUserId) throw ApiProblemException.Invalid("V-USR-MANAGER-SELF", "A user is not their own line manager.");
            var cycle = await u.Connection.ExecuteScalarAsync<int>(new CommandDefinition(
                """
                WITH up AS (SELECT AppUserId, LineManagerUserId, 1 AS Depth FROM sec.AppUser WHERE AppUserId = @m
                            UNION ALL
                            SELECT a.AppUserId, a.LineManagerUserId, up.Depth + 1 FROM sec.AppUser AS a JOIN up ON a.AppUserId = up.LineManagerUserId WHERE up.Depth < 50)
                SELECT COUNT(*) FROM up WHERE AppUserId = @u OPTION (MAXRECURSION 50);
                """, new { m = mm.Id, u = row.AppUserId }, tx, cancellationToken: http.RequestAborted));
            if (cycle > 0) throw ApiProblemException.Invalid("V-USR-MANAGER-CYCLE", "This line manager reports to the user, directly or through others.");
            manager = mm.Id;
        }
        var managerSet = body.LineManager is not null || body.ClearLineManager == true;
        byte[]? changed;
        try
        {
        changed = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE sec.AppUser
               SET DisplayNameEn = COALESCE(@en, DisplayNameEn), DisplayNameAr = COALESCE(@ar, DisplayNameAr),
                   PreferredLanguage = COALESCE(@lang, PreferredLanguage), DigitsPreference = COALESCE(@digits, DigitsPreference),
                   DepartmentId = CASE WHEN @departmentSet = 1 THEN @department ELSE DepartmentId END,
                   LineManagerUserId = CASE WHEN @managerSet = 1 THEN @manager ELSE LineManagerUserId END,
                   EmployeeCode = CASE WHEN @codeSet = 1 THEN @code ELSE EmployeeCode END,
                   Mobile = CASE WHEN @mobileSet = 1 THEN @mobile ELSE Mobile END
            OUTPUT inserted.RowVersion INTO @o
             WHERE AppUserId = @id AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """, new { en = body.DisplayNameEn?.Trim(), ar = body.DisplayNameAr?.Trim(), lang = body.PreferredLanguage, digits = body.DigitsPreference,
                departmentSet, department, managerSet, manager, codeSet, code = employeeCode, mobileSet, mobile, id = row.AppUserId, rv = expected },
                tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw ApiProblemException.Invalid("V-PLT-07", UniqueMessage(ex));
        }
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("USER_UPDATED", "IDENTITY_ACCESS", "sec.AppUser", row.AppUserId,
            BeforeJson: JsonSerializer.Serialize(new { displayNameEn = row.DisplayNameEn, displayNameAr = row.DisplayNameAr, departmentId = row.DepartmentId,
                lineManagerUserId = row.LineManagerUserId, employeeCode = row.EmployeeCode, mobile = row.Mobile }),
            AfterJson: JsonSerializer.Serialize(new { body.DisplayNameEn, body.DisplayNameAr, body.PreferredLanguage, body.DigitsPreference,
                departmentId = departmentSet ? department : row.DepartmentId, lineManagerUserId = managerSet ? manager : row.LineManagerUserId,
                employeeCode = codeSet ? employeeCode : row.EmployeeCode, mobile = mobileSet ? mobile : row.Mobile })), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, changed);
        return Results.NoContent();
    }

    private static async Task<IResult> SetRolesAsync(Guid id, UserRolesRequest body, HttpContext http, SqlConnectionFactory db, TenantKeyRing keys, TimeProvider clock)
    {
        var expected = ETags.Required(http.Request);
        List<(long RoleId, string Code)> wanted;
        List<string> before;
        await using (var check = await BoundUser.OpenAsync(http, db, Manage))
        {
            var row = await FindAsync(check.Connection, null, id, http.RequestAborted);
            wanted = await ResolveRolesAsync(check.Connection, body.RoleIds ?? [], http.RequestAborted);
            before = (await RolesOfAsync(check.Connection, [row.AppUserId], http.RequestAborted))[row.AppUserId].ToList();
            if (wanted.Any(r => StepUpRoles.Contains(r.Code) && !before.Contains(r.Code)))
                await StepUp.RequireAsync(http, db, keys, clock, body.StepUpCode);
        }
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, http.RequestAborted);
        var target = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        if (!target.RowVersion.SequenceEqual(expected)) throw ETags.Conflict();
        if (before.Contains("TA") && !wanted.Any(r => r.Code == "TA"))
            await GuardLastAdminAsync(u.Connection, tx, target.AppUserId, http.RequestAborted);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "DELETE FROM sec.UserRole WHERE UserId = @u AND RoleId NOT IN @keep;",
            new { u = target.AppUserId, keep = wanted.Select(r => r.RoleId).DefaultIfEmpty(-1).ToArray() }, tx, cancellationToken: http.RequestAborted));
        await AddRolesAsync(u, tx, target.AppUserId, wanted.Select(r => r.RoleId), http.RequestAborted);
        var rv = await TouchRowAsync(u.Connection, tx, target.AppUserId, http.RequestAborted);
        var after = wanted.Select(r => r.Code).Order(StringComparer.Ordinal).ToList();
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("USER_ROLES_CHANGED", "IDENTITY_ACCESS", "sec.AppUser", target.AppUserId,
            BeforeJson: JsonSerializer.Serialize(new { roles = before }), AfterJson: JsonSerializer.Serialize(new { roles = after }),
            Severity: after.Concat(before).Any(StepUpRoles.Contains) ? "HIGH" : "INFO"), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static async Task<IResult> SetScopeAsync(Guid id, CompanyScopeRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        if (body.Mode is not ("ALL" or "SELECTED")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The scope is ALL or SELECTED.");
        var entries = body.Mode == "ALL" ? [] : body.Companies ?? [];
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var target = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        var companies = new List<(long CompanyId, bool Desc)>();
        foreach (var e in entries)
        {
            var cid = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
                "SELECT CompanyId FROM org.Company WHERE PublicId = @id;", new { id = e.Id }, tx, cancellationToken: http.RequestAborted))
                ?? throw ApiProblemException.Invalid("REFERENCE_INVALID", "A company of the scope does not exist.");
            companies.Add((cid, e.IncludeDescendants));
        }
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            "DECLARE @o TABLE (RowVersion BINARY(8)); UPDATE sec.AppUser SET CompanyScopeMode = @m OUTPUT inserted.RowVersion INTO @o WHERE AppUserId = @u AND RowVersion = @rv; SELECT RowVersion FROM @o;",
            new { m = body.Mode, u = target.AppUserId, rv = expected }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        await u.Connection.ExecuteAsync(new CommandDefinition("DELETE FROM sec.UserCompanyScope WHERE UserId = @u;",
            new { u = target.AppUserId }, tx, cancellationToken: http.RequestAborted));
        foreach (var (cid, desc) in companies)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "INSERT sec.UserCompanyScope (TenantId, UserId, CompanyId, IncludeDescendants) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @u, @c, @d);",
                new { u = target.AppUserId, c = cid, d = desc }, tx, cancellationToken: http.RequestAborted));
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("USER_SCOPE_CHANGED", "IDENTITY_ACCESS", "sec.AppUser", target.AppUserId,
            BeforeJson: JsonSerializer.Serialize(new { mode = target.CompanyScopeMode }),
            AfterJson: JsonSerializer.Serialize(new { mode = body.Mode, companies = entries.Select(e => e.Id) })), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static readonly string[] Products = ["CORE", "INSTITUTIONS", "FACILITIES", "COVENANTS", "WORKFLOW", "LC_PURCHASE", "LC_SALES", "REQUESTS", "REPORTS"];

    /// <summary>
    /// The products (modules) a user may use (docs/31 row 46, ADR 0048): ALL, or the SELECTED ones; CORE is always in.
    /// It narrows what the tenant has enabled and what the roles allow, never widens it.
    /// </summary>
    private static async Task<IResult> SetProductScopeAsync(Guid id, ProductScopeRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        if (body.Mode is not ("ALL" or "SELECTED")) throw ApiProblemException.Invalid("VALIDATION_FAILED", "The scope is ALL or SELECTED.");
        var modules = body.Mode == "ALL" ? [] : (body.Modules ?? []).Append("CORE").Distinct(StringComparer.Ordinal).ToArray();
        if (modules.Any(m => !Products.Contains(m))) throw ApiProblemException.Invalid("VALIDATION_FAILED", "A product code is not known.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var target = await FindAsync(u.Connection, tx, id, http.RequestAborted);
        var before = (await u.Connection.QueryAsync<string>(new CommandDefinition(
            "SELECT ModuleCode FROM sec.UserProductScope WHERE UserId = @u;", new { u = target.AppUserId }, tx, cancellationToken: http.RequestAborted))).ToList();
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            "DECLARE @o TABLE (RowVersion BINARY(8)); UPDATE sec.AppUser SET ProductScopeMode = @m OUTPUT inserted.RowVersion INTO @o WHERE AppUserId = @u AND RowVersion = @rv; SELECT RowVersion FROM @o;",
            new { m = body.Mode, u = target.AppUserId, rv = expected }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        await u.Connection.ExecuteAsync(new CommandDefinition("DELETE FROM sec.UserProductScope WHERE UserId = @u;",
            new { u = target.AppUserId }, tx, cancellationToken: http.RequestAborted));
        foreach (var m in modules)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                "INSERT sec.UserProductScope (TenantId, UserId, ModuleCode) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @u, @m);",
                new { u = target.AppUserId, m }, tx, cancellationToken: http.RequestAborted));
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("USER_PRODUCT_SCOPE_CHANGED", "IDENTITY_ACCESS", "sec.AppUser", target.AppUserId,
            BeforeJson: JsonSerializer.Serialize(new { mode = target.ProductScopeMode, modules = before }),
            AfterJson: JsonSerializer.Serialize(new { mode = body.Mode, modules })), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static string UniqueMessage(SqlException ex) =>
        ex.Message.Contains("EmployeeCode", StringComparison.Ordinal) ? "Another user has this employee code."
        : ex.Message.Contains("Mobile", StringComparison.Ordinal) ? "Another user has this mobile number."
        : "A user with this e-mail already exists.";

    private static async Task<IResult> ActAsync(Guid id, string action, UserActionRequest? body, HttpContext http, SqlConnectionFactory db,
        AccountMail mail, TenantKeyRing keys, TimeProvider clock)
    {
        var rc = RequestContext.Of(http);
        if (action is not ("disable" or "enable" or "archive" or "unlock" or "reset-mfa" or "resend-invitation" or "send-password-reset" or "send-mfa-reenrolment"
                or "temporary-password"))
            throw ApiProblemException.NotFound();
        if (action is "disable" or "reset-mfa" or "temporary-password" && string.IsNullOrWhiteSpace(body?.Reason))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Give a reason.");
        if (action is "reset-mfa" or "temporary-password") await StepUp.RequireAsync(http, db, keys, clock, body?.StepUpCode);
        string? temporary = null;

        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var target = await FindAsync(u.Connection, null, id, http.RequestAborted);
        var self = target.AppUserId == u.UserId;
        switch (action)
        {
            case "disable" or "archive":
                if (self) throw new ApiProblemException(409, "STATUS_CHANGE_NOT_ALLOWED", "You cannot change your own account.");
                await using (var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(System.Data.IsolationLevel.Serializable, http.RequestAborted))
                {
                    await GuardLastAdminAsync(u.Connection, tx, target.AppUserId, http.RequestAborted);
                    await tx.CommitAsync(http.RequestAborted);
                }
                await TenantAdminProcedures.SetUserStatusAsync(u.Connection, u.TenantId, target.AppUserId, action == "disable" ? "DISABLED" : "ARCHIVED", http.RequestAborted);
                break;
            case "enable":
                await TenantAdminProcedures.SetUserStatusAsync(u.Connection, u.TenantId, target.AppUserId, "ACTIVE", http.RequestAborted);
                break;
            case "unlock":
                if (self) throw new ApiProblemException(409, "STATUS_CHANGE_NOT_ALLOWED", "Another administrator unlocks your account.");
                await TenantAdminProcedures.UnlockUserAsync(u.Connection, u.TenantId, target.AppUserId, http.RequestAborted);
                break;
            case "reset-mfa":
                if (self) throw new ApiProblemException(409, "STATUS_CHANGE_NOT_ALLOWED", "Another administrator resets your authenticator.");
                await TenantAdminProcedures.ResetMfaAsync(u.Connection, null, u.TenantId, target.AppUserId, http.RequestAborted);
                await SendLinkAsync(u, mail, rc.TenantCode, target.AppUserId, "MFA_REENROLMENT", http.RequestAborted);
                await MfaResetNotifiedAsync(u, target.AppUserId, http.RequestAborted);
                break;
            case "resend-invitation":
                await SendLinkAsync(u, mail, rc.TenantCode, target.AppUserId, "INVITATION", http.RequestAborted);
                break;
            case "send-password-reset":
                await SendLinkAsync(u, mail, rc.TenantCode, target.AppUserId, "PASSWORD_RESET", http.RequestAborted);
                break;
            case "send-mfa-reenrolment":
                await SendLinkAsync(u, mail, rc.TenantCode, target.AppUserId, "MFA_REENROLMENT", http.RequestAborted);
                break;
            case "temporary-password":
                if (self) throw new ApiProblemException(409, "STATUS_CHANGE_NOT_ALLOWED", "Change your own password from your account page.");
                if (!(await SignInIdentity.ListSettingAsync(u.Connection, null, "security.user.creation", SignInIdentity.CreationMethods, http.RequestAborted)).Contains("TEMP_PASSWORD"))
                    throw new ApiProblemException(409, "V-USR-CREATION", "The account does not hand over temporary passwords (security.user.creation).");
                var policy = await TenantAuthProcedures.GetPasswordPolicyAsync(u.Connection, u.TenantId, http.RequestAborted);
                temporary = SignInIdentity.TemporaryPassword(policy.MinLength);
                await TenantAdminProcedures.SetTemporaryPasswordAsync(u.Connection, null, u.TenantId, target.AppUserId, PasswordHasher.HashNew(temporary), http.RequestAborted);
                break;
        }
        if (body?.Reason is { Length: > 0 } reason)
            await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("USER_ACTION_REASON", "IDENTITY_ACCESS", "sec.AppUser", target.AppUserId,
                AfterJson: JsonSerializer.Serialize(new { action, reason = reason.Length > 500 ? reason[..500] : reason }),
                Severity: action is "reset-mfa" or "temporary-password" ? "HIGH" : "INFO"), http.RequestAborted);
        var status = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT Status FROM sec.AppUser WHERE AppUserId = @id;", new { id = target.AppUserId }, cancellationToken: http.RequestAborted));
        return temporary is null ? Results.Ok(new { id, status }) : Results.Ok(new { id, status, temporaryPassword = temporary });
    }

    /// <summary>SEC.MFA_RESET (spec 13 section 9.2) to the other account administrators and to the user concerned.</summary>
    private static async Task MfaResetNotifiedAsync(BoundUser u, long target, CancellationToken ct)
    {
        var names = (await u.Connection.QueryAsync<(long Id, string Name)>(new CommandDefinition(
            "SELECT AppUserId, ISNULL(DisplayNameAr, Email) FROM sec.AppUser WHERE AppUserId IN (@t, @a);", new { t = target, a = u.UserId }, cancellationToken: ct)))
            .ToDictionary(x => x.Id, x => x.Name);
        await BankFas.Data.Notifications.Notifier.RequestAsync(u.Connection, null, new BankFas.Data.Notifications.NotificationRequest("SEC.MFA_RESET", "sec.AppUser", target,
            $"SEC.MFA_RESET:{target}:{DateTime.UtcNow:yyyyMMddHHmmss}",
            Values: new Dictionary<string, object?> { ["userName"] = names.GetValueOrDefault(target), ["actorName"] = names.GetValueOrDefault(u.UserId) },
            ActorUserId: u.UserId, RecipientUserIds: [target]), ct);
    }

    private static async Task<IResult> SessionsAsync(Guid id, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var target = await FindAsync(u.Connection, null, id, http.RequestAborted);
        return Results.Ok(new { items = await LiveSessionsAsync(u, refs, target.AppUserId, http.RequestAborted) });
    }

    private static async Task<IResult> EndAllSessionsAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var target = await FindAsync(u.Connection, null, id, http.RequestAborted);
        var ids = await u.Connection.QueryAsync<long>(new CommandDefinition(
            "SELECT UserSessionId FROM sec.UserSession WHERE UserId = @u AND EndedAt IS NULL AND AbsoluteExpiresAt > SYSUTCDATETIME();",
            new { u = target.AppUserId }, cancellationToken: http.RequestAborted));
        foreach (var sid in ids) await TenantAuthProcedures.EndSessionAsync(u.Connection, u.TenantId, null, sid, http.RequestAborted);
        return Results.NoContent();
    }

    private static async Task<IResult> EndSessionAsync(Guid id, string reference, HttpContext http, SqlConnectionFactory db, OpaqueRefs refs)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var target = await FindAsync(u.Connection, null, id, http.RequestAborted);
        var sid = refs.SessionId(u.TenantId, reference) ?? throw ApiProblemException.NotFound();
        var owner = await u.Connection.ExecuteScalarAsync<long?>(new CommandDefinition(
            "SELECT UserId FROM sec.UserSession WHERE UserSessionId = @s;", new { s = sid }, cancellationToken: http.RequestAborted));
        if (owner != target.AppUserId) throw ApiProblemException.NotFound();
        await TenantAuthProcedures.EndSessionAsync(u.Connection, u.TenantId, null, sid, http.RequestAborted);
        return Results.NoContent();
    }

    // ---------- shared ----------

    internal static async Task<IEnumerable<object>> LiveSessionsAsync(BoundUser u, OpaqueRefs refs, long userId, CancellationToken ct)
    {
        var rows = await u.Connection.QueryAsync<(long Id, DateTime Created, DateTime LastSeen, string? Ip, string? Agent, DateTime? Mfa)>(new CommandDefinition(
            """
            SELECT UserSessionId, CreatedAt, LastSeenAt, IpAddress, UserAgent, MfaVerifiedAt FROM sec.UserSession
            WHERE UserId = @u AND EndedAt IS NULL AND IdleExpiresAt > SYSUTCDATETIME() AND AbsoluteExpiresAt > SYSUTCDATETIME()
            ORDER BY LastSeenAt DESC;
            """, new { u = userId }, cancellationToken: ct));
        return rows.Select(r => (object)new
        {
            id = refs.SessionRef(u.TenantId, r.Id), createdAt = r.Created, lastSeenAt = r.LastSeen, ipAddress = r.Ip, userAgent = r.Agent,
            mfaVerified = r.Mfa is not null,
        });
    }

    private static async Task SendLinkAsync(BoundUser u, AccountMail mail, string tenantCode, long userId, string purpose, CancellationToken ct)
    {
        var token = SecureTokens.NewToken();
        var to = await TenantAdminProcedures.IssueUserTokenAsync(u.Connection, null, u.TenantId, userId, purpose, token, ct);
        await mail.SendAndRecordAsync(u.Connection, tenantCode, userId, to, purpose, token, ct);
    }

    private static async Task<UserRow> FindAsync(SqlConnection c, SqlTransaction? tx, Guid id, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<UserRow>(new CommandDefinition(
            $"SELECT {UserColumns} FROM sec.AppUser WHERE PublicId = @id AND IsSystemUser = 0;", new { id }, tx, cancellationToken: ct))
        ?? throw ApiProblemException.NotFound();

    private static async Task<Dictionary<long, IEnumerable<string>>> RolesOfAsync(SqlConnection c, IEnumerable<long> userIds, CancellationToken ct)
    {
        var ids = userIds.ToArray();
        var result = ids.ToDictionary(i => i, _ => Enumerable.Empty<string>());
        if (ids.Length == 0) return result;
        var rows = await c.QueryAsync<(long UserId, string Code)>(new CommandDefinition(
            "SELECT ur.UserId, r.Code FROM sec.UserRole AS ur JOIN sec.Role AS r ON r.RoleId = ur.RoleId WHERE ur.UserId IN @ids ORDER BY r.Code;",
            new { ids }, cancellationToken: ct));
        foreach (var g in rows.GroupBy(r => r.UserId)) result[g.Key] = g.Select(r => r.Code).ToList();
        return result;
    }

    private static async Task<List<(long RoleId, string Code)>> ResolveRolesAsync(SqlConnection c, Guid[] ids, CancellationToken ct)
    {
        if (ids.Length == 0) return [];
        var rows = (await c.QueryAsync<(long RoleId, string Code)>(new CommandDefinition(
            "SELECT RoleId, Code FROM sec.Role WHERE PublicId IN @ids AND IsActive = 1;", new { ids = ids.Distinct().ToArray() }, cancellationToken: ct))).ToList();
        if (rows.Count != ids.Distinct().Count()) throw ApiProblemException.Invalid("REFERENCE_INVALID", "A role does not exist or is not active.");
        return rows;
    }

    private static async Task AddRolesAsync(BoundUser u, SqlTransaction tx, long userId, IEnumerable<long> roleIds, CancellationToken ct)
    {
        foreach (var rid in roleIds)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                IF NOT EXISTS (SELECT 1 FROM sec.UserRole WHERE UserId = @u AND RoleId = @r)
                    INSERT sec.UserRole (TenantId, UserId, RoleId, AssignedBy) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @u, @r, @by);
                """, new { u = userId, r = rid, by = u.UserId }, tx, cancellationToken: ct));
    }

    /// <summary>A change on the user's row itself, so a role change moves the ETag of the user (DOC-B04 section 4).</summary>
    private static Task<byte[]> TouchRowAsync(SqlConnection c, SqlTransaction tx, long userId, CancellationToken ct) =>
        c.QuerySingleAsync<byte[]>(new CommandDefinition(
            "DECLARE @o TABLE (RowVersion BINARY(8)); UPDATE sec.AppUser SET DisplayNameEn = DisplayNameEn OUTPUT inserted.RowVersion INTO @o WHERE AppUserId = @u; SELECT RowVersion FROM @o;", new { u = userId }, tx, cancellationToken: ct));

    /// <summary>409 LAST_ACCOUNT_ADMIN when the user is the only ACTIVE holder of the TA role (FR-PLT-016, GAP-14).</summary>
    internal static async Task GuardLastAdminAsync(SqlConnection c, SqlTransaction tx, long userId, CancellationToken ct)
    {
        var (isActiveTa, others) = await c.QuerySingleAsync<(bool, int)>(new CommandDefinition(
            """
            SELECT CAST(CASE WHEN EXISTS (SELECT 1 FROM sec.UserRole AS ur JOIN sec.Role AS r ON r.RoleId = ur.RoleId
                                          JOIN sec.AppUser AS u ON u.AppUserId = ur.UserId
                                          WHERE ur.UserId = @u AND r.Code = 'TA' AND u.Status = 'ACTIVE') THEN 1 ELSE 0 END AS BIT),
                   (SELECT COUNT(u.AppUserId) FROM sec.AppUser AS u WITH (UPDLOCK, HOLDLOCK)
                    JOIN sec.UserRole AS ur ON ur.UserId = u.AppUserId JOIN sec.Role AS r ON r.RoleId = ur.RoleId AND r.Code = 'TA'
                    WHERE u.Status = 'ACTIVE' AND u.IsSystemUser = 0 AND u.AppUserId <> @u);
            """, new { u = userId }, tx, cancellationToken: ct));
        if (isActiveTa && others == 0)
            throw new ApiProblemException(409, "LAST_ACCOUNT_ADMIN", "The account needs at least one active administrator.");
    }
}
