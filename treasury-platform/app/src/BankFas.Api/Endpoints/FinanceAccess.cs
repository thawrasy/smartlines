using BankFas.Api.Infrastructure;
using BankFas.Data;

namespace BankFas.Api.Endpoints;

/// <summary>
/// The gate of the financial data (S2-b brief S2B-GAP-16, OQ-10 and OQ-12): every fin.* endpoint needs the COVENANTS
/// module; a statement or a revenue estimate is seen with fin.view and one of the actions on statements, so a treasury
/// employee (fin.view and fin.stats.enter only) sees the balances and flows he enters, not the statements (spec 12
/// section 3, note 1 of the matrix).
/// </summary>
public static class FinanceAccess
{
    internal const string Module = "COVENANTS";
    internal const string View = "fin.view";
    internal const string Enter = "fin.stmt.enter";
    internal const string Approve = "fin.stmt.approve";

    private static readonly string[] StatementReaders =
        ["fin.stmt.enter", "fin.stmt.approve", "fin.verify.run", "fin.credit.assess", "fin.credit.approve", "fin.credit.endorse"];

    /// <summary>The bound user with the permission and the module; with <paramref name="statements"/>, one who may see statements.</summary>
    internal static async Task<(BoundUser U, CompanyScope Scope)> OpenAsync(HttpContext http, SqlConnectionFactory db, string permission, bool statements)
    {
        var u = await BoundUser.OpenAsync(http, db, permission);
        try
        {
            var ct = http.RequestAborted;
            await u.RequireModuleAsync(Module, ct);
            if (statements)
            {
                var held = await u.PermissionsAsync(ct);
                if (!held.Contains(View) || !StatementReaders.Any(held.Contains))
                    throw ApiProblemException.Forbidden("FORBIDDEN", "The statements are seen by those who enter, approve, verify or assess them.");
            }
            return (u, await CompanyScope.OfAsync(u, ct));
        }
        catch
        {
            await u.DisposeAsync();
            throw;
        }
    }
}
