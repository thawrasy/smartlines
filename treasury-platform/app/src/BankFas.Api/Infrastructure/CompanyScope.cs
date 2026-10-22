using Dapper;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// The companies the signed-in user may see (FR-PLT-020, BR-PLT-007): every company of the tenant when the user's
/// CompanyScopeMode is ALL, else the companies of sec.UserCompanyScope and, for a row with IncludeDescendants, the
/// companies below it. The row filters isolate tenants only; this scope is the application's, in every list, read and
/// search of company data (S1 brief, pitfall 3).
/// </summary>
public sealed class CompanyScope(bool all, IReadOnlySet<long> ids)
{
    public bool All { get; } = all;
    public IReadOnlySet<long> Ids { get; } = ids;

    public bool Allows(long? companyId) => companyId is null || All || Ids.Contains(companyId.Value);

    /// <summary>The ids for an SQL "IN @ids", with -1 for an empty scope so the list is never empty.</summary>
    public long[] SqlIds => Ids.Count == 0 ? [-1] : [.. Ids];

    public static async Task<CompanyScope> OfAsync(BoundUser u, CancellationToken ct)
    {
        var mode = await u.Connection.ExecuteScalarAsync<string>(new CommandDefinition(
            "SELECT CompanyScopeMode FROM sec.AppUser WHERE AppUserId = @u;", new { u = u.UserId }, cancellationToken: ct)).ConfigureAwait(false);
        if (mode == "ALL") return new CompanyScope(true, new HashSet<long>());
        var ids = await u.Connection.QueryAsync<long>(new CommandDefinition(
            """
            WITH tree AS (
                SELECT c.CompanyId, s.IncludeDescendants FROM sec.UserCompanyScope AS s JOIN org.Company AS c ON c.CompanyId = s.CompanyId WHERE s.UserId = @u
                UNION ALL
                SELECT ch.CompanyId, t.IncludeDescendants FROM org.Company AS ch JOIN tree AS t ON ch.ParentCompanyId = t.CompanyId WHERE t.IncludeDescendants = 1)
            SELECT DISTINCT CompanyId FROM tree OPTION (MAXRECURSION 20);
            """, new { u = u.UserId }, cancellationToken: ct)).ConfigureAwait(false);
        return new CompanyScope(false, ids.ToHashSet());
    }
}
