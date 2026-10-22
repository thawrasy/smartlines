using System.Text.Json;
using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Api.Endpoints;

public sealed record CreateRoleRequest(string? Code, string? NameEn, string? NameAr, string? Description, string[]? Permissions);
public sealed record PatchRoleRequest(string? NameEn, string? NameAr, string? Description, bool? IsActive);
public sealed record RolePermissionsRequest(string[]? Permissions);
public sealed record CopyRoleRequest(string? Code, string? NameEn, string? NameAr);

/// <summary>
/// Roles and their permissions (SCR-PLT-09, FR-PLT-017/018), with sec.role.manage. A tenant adds roles but never
/// permissions; a role's code is fixed once made, and system roles cannot be removed. A permission locked to some
/// system roles (LockedToRoleCodes, BR-PLT-019) is refused before the write with 403 PERMISSION_LOCKED and a HIGH audit
/// row, since the database trigger would end the transaction (50043). A permission change moves the role's ETag.
/// </summary>
public static class RoleEndpoints
{
    private const string Manage = "sec.role.manage";

    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/permissions", PermissionsAsync);
        api.MapGet("/roles", ListAsync);
        api.MapPost("/roles", CreateAsync);
        api.MapGet("/roles/{id:guid}", GetAsync);
        api.MapPatch("/roles/{id:guid}", PatchAsync);
        api.MapPut("/roles/{id:guid}/permissions", SetPermissionsAsync);
        api.MapPost("/roles/{id:guid}/actions/copy", CopyAsync);
    }

    private sealed record RoleRow(long RoleId, Guid PublicId, string Code, string NameEn, string NameAr, string? Description, bool IsSystem,
        bool IsActive, byte[] RowVersion);

    private const string RoleColumns = "RoleId, PublicId, Code, NameEn, NameAr, Description, IsSystem, IsActive, RowVersion";

    private static async Task<IResult> PermissionsAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var rows = await u.Connection.QueryAsync(new CommandDefinition(
            """
            SELECT Code AS code, ModuleCode AS module, NameEn AS nameEn, NameAr AS nameAr, Description AS description,
                   IsSensitive AS isSensitive, LockedToRoleCodes AS lockedToRoleCodes
            FROM sec.Permission WHERE IsActive = 1 ORDER BY ModuleCode, Code;
            """, cancellationToken: http.RequestAborted));
        return Results.Ok(new { items = rows });
    }

    private static async Task<IResult> ListAsync(HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var rows = await u.Connection.QueryAsync<(Guid PublicId, string Code, string NameEn, string NameAr, bool IsSystem, bool IsActive, int Users, int Permissions)>(
            new CommandDefinition(
                """
                SELECT r.PublicId, r.Code, r.NameEn, r.NameAr, r.IsSystem, r.IsActive,
                       (SELECT COUNT(ur.UserId) FROM sec.UserRole AS ur WHERE ur.RoleId = r.RoleId),
                       (SELECT COUNT(rp.PermissionId) FROM sec.RolePermission AS rp WHERE rp.RoleId = r.RoleId)
                FROM sec.Role AS r ORDER BY r.IsSystem DESC, r.Code;
                """, cancellationToken: http.RequestAborted));
        return Results.Ok(new
        {
            items = rows.Select(r => new { id = r.PublicId, code = r.Code, nameEn = r.NameEn, nameAr = r.NameAr, isSystem = r.IsSystem,
                isActive = r.IsActive, users = r.Users, permissions = r.Permissions }),
        });
    }

    private static async Task<IResult> GetAsync(Guid id, HttpContext http, SqlConnectionFactory db)
    {
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var role = await FindAsync(u.Connection, null, id, http.RequestAborted);
        var perms = await PermissionCodesAsync(u.Connection, null, role.RoleId, http.RequestAborted);
        ETags.Set(http.Response, role.RowVersion);
        return Results.Ok(new { id = role.PublicId, code = role.Code, nameEn = role.NameEn, nameAr = role.NameAr, description = role.Description,
            isSystem = role.IsSystem, isActive = role.IsActive, permissions = perms });
    }

    private static async Task<IResult> CreateAsync(CreateRoleRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var code = body.Code?.Trim().ToUpperInvariant();
        if (string.IsNullOrEmpty(code) || code.Length > 50 || !code.All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '_' or '-')
            || string.IsNullOrWhiteSpace(body.NameEn) || string.IsNullOrWhiteSpace(body.NameAr))
            throw ApiProblemException.Invalid("VALIDATION_FAILED", "Enter a code (letters, digits, - and _) and both names.");
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var perms = await ResolvePermissionsAsync(u, body.Permissions ?? [], code, isSystem: false, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        (long RoleId, Guid PublicId) created;
        try
        {
            created = await u.Connection.QuerySingleAsync<(long, Guid)>(new CommandDefinition(
                """
                DECLARE @o TABLE (RoleId BIGINT, PublicId UNIQUEIDENTIFIER);
                INSERT sec.Role (TenantId, Code, NameEn, NameAr, Description, IsSystem, IsActive)
                OUTPUT inserted.RoleId, inserted.PublicId INTO @o
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @code, @en, @ar, @d, 0, 1);
                SELECT RoleId, PublicId FROM @o;
                """, new { code, en = body.NameEn.Trim(), ar = body.NameAr.Trim(), d = body.Description }, tx, cancellationToken: http.RequestAborted));
        }
        catch (SqlException ex) when (ex.Number is DbErrors.UniqueViolation or DbErrors.UniqueIndexViolation)
        {
            throw new ApiProblemException(409, "DUPLICATE", "A role with this code already exists.");
        }
        await InsertPermissionsAsync(u, tx, created.RoleId, perms.Select(p => p.Id), http.RequestAborted);
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("ROLE_CREATED", "IDENTITY_ACCESS", "sec.Role", created.RoleId,
            AfterJson: JsonSerializer.Serialize(new { code, permissions = perms.Select(p => p.Code) }),
            Severity: perms.Any(p => p.Sensitive) ? "HIGH" : "INFO"), http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        return Results.Created($"/api/v1/roles/{created.PublicId}", new { id = created.PublicId, code });
    }

    private static async Task<IResult> PatchAsync(Guid id, PatchRoleRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var role = await FindAsync(u.Connection, null, id, http.RequestAborted);
        if (role.IsSystem && body.IsActive == false) throw new ApiProblemException(409, "IN_USE", "A system role stays active.");
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            """
            DECLARE @o TABLE (RowVersion BINARY(8));
            UPDATE sec.Role SET NameEn = COALESCE(@en, NameEn), NameAr = COALESCE(@ar, NameAr), Description = COALESCE(@d, Description),
                   IsActive = COALESCE(@active, IsActive)
            OUTPUT inserted.RowVersion INTO @o WHERE RoleId = @id AND RowVersion = @rv;
            SELECT RowVersion FROM @o;
            """, new { en = body.NameEn?.Trim(), ar = body.NameAr?.Trim(), d = body.Description, active = body.IsActive, id = role.RoleId, rv = expected },
            cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("ROLE_UPDATED", "IDENTITY_ACCESS", "sec.Role", role.RoleId,
            BeforeJson: JsonSerializer.Serialize(new { nameEn = role.NameEn, nameAr = role.NameAr, isActive = role.IsActive }),
            AfterJson: JsonSerializer.Serialize(body)), http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static async Task<IResult> SetPermissionsAsync(Guid id, RolePermissionsRequest body, HttpContext http, SqlConnectionFactory db)
    {
        var expected = ETags.Required(http.Request);
        await using var u = await BoundUser.OpenAsync(http, db, Manage);
        var role = await FindAsync(u.Connection, null, id, http.RequestAborted);
        var perms = await ResolvePermissionsAsync(u, body.Permissions ?? [], role.Code, role.IsSystem, http.RequestAborted);
        await using var tx = (SqlTransaction)await u.Connection.BeginTransactionAsync(http.RequestAborted);
        var rv = await u.Connection.QuerySingleOrDefaultAsync<byte[]>(new CommandDefinition(
            "DECLARE @o TABLE (RowVersion BINARY(8)); UPDATE sec.Role SET NameEn = NameEn OUTPUT inserted.RowVersion INTO @o WHERE RoleId = @id AND RowVersion = @rv; SELECT RowVersion FROM @o;",
            new { id = role.RoleId, rv = expected }, tx, cancellationToken: http.RequestAborted)) ?? throw ETags.Conflict();
        var before = await PermissionCodesAsync(u.Connection, tx, role.RoleId, http.RequestAborted);
        await u.Connection.ExecuteAsync(new CommandDefinition(
            "DELETE FROM sec.RolePermission WHERE RoleId = @r AND PermissionId NOT IN @keep;",
            new { r = role.RoleId, keep = perms.Select(p => p.Id).DefaultIfEmpty(-1).ToArray() }, tx, cancellationToken: http.RequestAborted));
        await InsertPermissionsAsync(u, tx, role.RoleId, perms.Select(p => p.Id), http.RequestAborted);
        var after = perms.Select(p => p.Code).Order(StringComparer.Ordinal).ToList();
        var sensitiveChanged = perms.Where(p => p.Sensitive).Select(p => p.Code).Except(before).Any()
                               || before.Except(after).Any();
        await TenantAdminProcedures.WriteAuditAsync(u.Connection, tx, new AuditEntry("ROLE_PERMISSIONS_CHANGED", "IDENTITY_ACCESS", "sec.Role", role.RoleId,
            BeforeJson: JsonSerializer.Serialize(new { permissions = before }), AfterJson: JsonSerializer.Serialize(new { permissions = after }),
            Severity: sensitiveChanged ? "HIGH" : "INFO"), http.RequestAborted);
        await SensitiveChangedAsync(u, tx, role.RoleId, role.Code, before, after, http.RequestAborted);
        await tx.CommitAsync(http.RequestAborted);
        ETags.Set(http.Response, rv);
        return Results.NoContent();
    }

    private static async Task<IResult> CopyAsync(Guid id, CopyRoleRequest body, HttpContext http, SqlConnectionFactory db)
    {
        List<string> perms;
        await using (var u = await BoundUser.OpenAsync(http, db, Manage))
        {
            var role = await FindAsync(u.Connection, null, id, http.RequestAborted);
            perms = await PermissionCodesAsync(u.Connection, null, role.RoleId, http.RequestAborted);
        }
        // A copy is a tenant role: permissions locked to system roles do not come with it.
        await using (var u = await BoundUser.OpenAsync(http, db, Manage))
        {
            var locked = await u.Connection.QueryAsync<string>(new CommandDefinition(
                "SELECT Code FROM sec.Permission WHERE LockedToRoleCodes IS NOT NULL;", cancellationToken: http.RequestAborted));
            perms = perms.Except(locked).ToList();
        }
        return await CreateAsync(new CreateRoleRequest(body.Code, body.NameEn, body.NameAr, null, [.. perms]), http, db);
    }

    private static async Task<RoleRow> FindAsync(SqlConnection c, SqlTransaction? tx, Guid id, CancellationToken ct) =>
        await c.QuerySingleOrDefaultAsync<RoleRow>(new CommandDefinition(
            $"SELECT {RoleColumns} FROM sec.Role WHERE PublicId = @id;", new { id }, tx, cancellationToken: ct)) ?? throw ApiProblemException.NotFound();

    private static async Task<List<string>> PermissionCodesAsync(SqlConnection c, SqlTransaction? tx, long roleId, CancellationToken ct) =>
        [.. await c.QueryAsync<string>(new CommandDefinition(
            "SELECT p.Code FROM sec.RolePermission AS rp JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId WHERE rp.RoleId = @r ORDER BY p.Code;",
            new { r = roleId }, tx, cancellationToken: ct))];

    private sealed record Perm(int Id, string Code, bool Sensitive, string? Locked);

    /// <summary>SEC.SENSITIVE_PERMISSION_CHANGED (spec 10 section 9.3, spec 13 section 9.2): one request per sensitive permission given or taken.</summary>
    private static async Task SensitiveChangedAsync(BoundUser u, SqlTransaction tx, long roleId, string roleCode, IReadOnlyCollection<string> before,
        IReadOnlyCollection<string> after, CancellationToken ct)
    {
        var added = after.Except(before).ToList();
        var removed = before.Except(after).ToList();
        if (added.Count + removed.Count == 0) return;
        var sensitive = await u.Connection.QueryAsync<(string Code, string NameAr, string NameEn)>(new CommandDefinition(
            "SELECT Code, NameAr, NameEn FROM sec.Permission WHERE IsSensitive = 1 AND Code IN @codes;", new { codes = added.Concat(removed).ToArray() }, tx,
            cancellationToken: ct));
        var actor = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT ISNULL(DisplayNameAr, Email) FROM sec.AppUser WHERE AppUserId = @u;", new { u = u.UserId }, tx, cancellationToken: ct));
        var stamp = DateTime.UtcNow.ToString("yyyyMMddHHmmss", System.Globalization.CultureInfo.InvariantCulture);
        foreach (var p in sensitive)
        {
            var given = added.Contains(p.Code);
            await BankFas.Data.Notifications.Notifier.RequestAsync(u.Connection, tx, new BankFas.Data.Notifications.NotificationRequest(
                "SEC.SENSITIVE_PERMISSION_CHANGED", "sec.Role", roleId, $"SEC.SENSITIVE_PERMISSION_CHANGED:{roleId}:{p.Code}:{stamp}",
                Values: new Dictionary<string, object?>
                {
                    ["roleName"] = roleCode, ["permissionName"] = new Dictionary<string, string> { ["ar"] = p.NameAr, ["en"] = p.NameEn },
                    ["change"] = new Dictionary<string, string> { ["ar"] = given ? "أُسندت" : "سُحبت", ["en"] = given ? "gave" : "took away" }, ["actorName"] = actor,
                }, ActorUserId: u.UserId), ct);
        }
    }

    /// <summary>The permissions by code; unknown codes are 422, a locked one for this role is 403 PERMISSION_LOCKED, audited HIGH.</summary>
    private static async Task<List<Perm>> ResolvePermissionsAsync(BoundUser u, string[] codes, string roleCode, bool isSystem, CancellationToken ct)
    {
        var distinct = codes.Distinct(StringComparer.Ordinal).ToArray();
        if (distinct.Length == 0) return [];
        var rows = (await u.Connection.QueryAsync<Perm>(new CommandDefinition(
            "SELECT PermissionId AS Id, Code, IsSensitive AS Sensitive, LockedToRoleCodes AS Locked FROM sec.Permission WHERE Code IN @c AND IsActive = 1;",
            new { c = distinct }, cancellationToken: ct))).ToList();
        if (rows.Count != distinct.Length) throw ApiProblemException.Invalid("REFERENCE_INVALID", "A permission code does not exist.");
        var refused = rows.Where(p => p.Locked is not null
            && (!isSystem || !(JsonSerializer.Deserialize<string[]>(p.Locked) ?? []).Contains(roleCode, StringComparer.Ordinal))).ToList();
        if (refused.Count > 0)
        {
            await TenantAdminProcedures.WriteAuditAsync(u.Connection, null, new AuditEntry("PERMISSION_LOCKED_REFUSED", "IDENTITY_ACCESS", "sec.Role", null,
                AfterJson: JsonSerializer.Serialize(new { role = roleCode, permissions = refused.Select(p => p.Code) }), Severity: "HIGH", Result: "DENIED"), ct);
            throw new ApiProblemException(403, "PERMISSION_LOCKED", "Locked by the platform to TM and FO.");
        }
        return rows;
    }

    private static async Task InsertPermissionsAsync(BoundUser u, SqlTransaction tx, long roleId, IEnumerable<int> permissionIds, CancellationToken ct)
    {
        foreach (var pid in permissionIds)
            await u.Connection.ExecuteAsync(new CommandDefinition(
                """
                IF NOT EXISTS (SELECT 1 FROM sec.RolePermission WHERE RoleId = @r AND PermissionId = @p)
                    INSERT sec.RolePermission (TenantId, RoleId, PermissionId, AssignedBy) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @r, @p, @by);
                """, new { r = roleId, p = pid, by = u.UserId }, tx, cancellationToken: ct));
    }
}
