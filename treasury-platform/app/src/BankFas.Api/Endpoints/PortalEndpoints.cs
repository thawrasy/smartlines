using BankFas.Api.Infrastructure;
using BankFas.Data;
using Dapper;

namespace BankFas.Api.Endpoints;

/// <summary>The signed-in user of the tenant portal: profile, tenant, modules (enabled and in the user's product scope, ADR 0048) and permissions (DOC-B07 section 2).</summary>
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
                       u.ProductScopeMode AS productScopeMode, u.EmployeeCode AS employeeCode, u.Mobile AS mobile, u.MfaEnabled AS mfaEnabled,
                       t.Code AS tenantCode, t.NameEn AS tenantNameEn, t.NameAr AS tenantNameAr, t.Status AS tenantStatus,
                       t.MfaRequired AS mfaRequired
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
                """
                SELECT m.ModuleCode FROM plat.v_TenantModule AS m JOIN sec.AppUser AS u ON u.AppUserId = @id
                WHERE m.IsEnabled = 1
                  AND (u.ProductScopeMode = 'ALL' OR m.ModuleCode = 'CORE'
                       OR EXISTS (SELECT 1 FROM sec.UserProductScope AS s WHERE s.UserId = u.AppUserId AND s.ModuleCode = m.ModuleCode))
                ORDER BY m.ModuleCode;
                """, new { id = u.UserId }, cancellationToken: http.RequestAborted));
            // The idle timeout of the account, so the screen signs an idle user out at the same time as the server.
            var idleMinutes = await u.Connection.ExecuteScalarAsync<int?>(new CommandDefinition(
                """
                SELECT TRY_CAST(ISNULL(JSON_VALUE(N'[' + t.ValueJson + N']', '$[0]'), JSON_VALUE(N'[' + d.DefaultValueJson + N']', '$[0]')) AS INT)
                FROM cfg.SettingDefinition AS d LEFT JOIN cfg.TenantSetting AS t ON t.[Key] = d.[Key]
                WHERE d.[Key] = 'security.session.idle_minutes';
                """, cancellationToken: http.RequestAborted)) ?? 30;
            return Results.Ok(new { user = me, permissions, modules, sessionIdleMinutes = Math.Clamp(idleMinutes, 5, 30) });
        });
    }
}
