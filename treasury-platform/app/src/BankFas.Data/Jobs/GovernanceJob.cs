using Microsoft.Data.SqlClient;

namespace BankFas.Data.Jobs;

/// <summary>
/// JOB-ACC-GOV (FR-ACC-018), nightly: the governance comparison of every open bank authority of the tenant, so that a
/// grant that expires or a member who leaves opens or resolves its conflicts without a save. Running it twice creates
/// nothing: a finding already recorded keeps its row.
/// </summary>
public sealed class GovernanceJob(SqlConnectionFactory db, TimeProvider clock) : TenantJob(db)
{
    public override string JobKey => "JOB-ACC-GOV";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        await using var tx = (SqlTransaction)await c.BeginTransactionAsync(ct).ConfigureAwait(false);
        var (opened, resolved, _) = await Governance.GovernanceComparer.ReconcileAsync(c, tx, null, null, clock.GetUtcNow().UtcDateTime.Date, null, ct).ConfigureAwait(false);
        await tx.CommitAsync(ct).ConfigureAwait(false);
        return opened + resolved == 0 ? null : $"opened {opened}, resolved {resolved}";
    }
}
