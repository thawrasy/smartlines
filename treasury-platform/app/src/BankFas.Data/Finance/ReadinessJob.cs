using System.Data;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Finance;

/// <summary>
/// JOB-FIN-READINESS (FR-FIN-040, BR-FIN-041, db/static/051): once a day after JOB-FIN-EVAL (S2-b OQ-5), the early
/// warnings of the lender dates within the lead time that are not ready, issued by fin.usp_RunEarlyWarnings on the
/// tenant's local date with their notification requests in the outbox; a second run of the day issues nothing.
/// </summary>
public sealed class FinanceReadinessJob(SqlConnectionFactory db, TimeProvider clock) : Jobs.TenantJob(db)
{
    public override string JobKey => "JOB-FIN-READINESS";

    protected override async Task<string?> RunForTenantAsync(SqlConnection c, JobTenant tenant, Guid correlation, CancellationToken ct)
    {
        var p = Proc.Named("fin.usp_RunEarlyWarnings").In("@AsOf", tenant.LocalDate(clock.GetUtcNow()), DbType.Date).Out("@Issued", DbType.Int32);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        var n = p.Get<int?>("@Issued") ?? 0;
        return n == 0 ? null : $"warnings {n}";
    }
}
