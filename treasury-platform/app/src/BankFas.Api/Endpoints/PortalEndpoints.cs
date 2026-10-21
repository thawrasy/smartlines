using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;

namespace BankFas.Api.Endpoints;

/// <summary>The signed-in user of the tenant portal: profile, tenant, modules and permissions (DOC-B07 section 2).</summary>
public static class PortalEndpoints
{
    public static void Map(RouteGroupBuilder api)
    {
        api.MapGet("/me", async (HttpContext http, SqlConnectionFactory db) =>
        {
            await using var u = await BoundUser.OpenAsync(http, db);
            var me = await u.Connection.QuerySingleAsync(new CommandDefinition(
                """
                SELECT u.PublicId AS id, u.Email AS email, u.DisplayNameEn AS displayNameEn, u.DisplayNameAr AS displayNameAr,
                       u.PreferredLanguage AS preferredLanguage, u.CompanyScopeMode AS companyScopeMode,
                       t.Code AS tenantCode, t.NameEn AS tenantNameEn, t.NameAr AS tenantNameAr, t.Status AS tenantStatus
                FROM sec.AppUser AS u CROSS JOIN plat.v_CurrentTenant AS t
                WHERE u.AppUserId = @id;
                """, new { id = u.UserId }, cancellationToken: http.RequestAborted));
            var permissions = await u.Connection.QueryAsync<string>(new CommandDefinition(
                """
                SELECT DISTINCT p.Code
                FROM sec.UserRole AS ur
                JOIN sec.Role AS r ON r.RoleId = ur.RoleId AND r.IsActive = 1
                JOIN sec.RolePermission AS rp ON rp.RoleId = r.RoleId
                JOIN sec.Permission AS p ON p.PermissionId = rp.PermissionId AND p.IsActive = 1
                WHERE ur.UserId = @id
                ORDER BY p.Code;
                """, new { id = u.UserId }, cancellationToken: http.RequestAborted));
            var modules = await u.Connection.QueryAsync<string>(new CommandDefinition(
                "SELECT ModuleCode FROM plat.v_TenantModule WHERE IsEnabled = 1 ORDER BY ModuleCode;", cancellationToken: http.RequestAborted));
            return Results.Ok(new { user = me, permissions, modules });
        });
    }
}
