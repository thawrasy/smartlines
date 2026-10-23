using BankFas.Data;

namespace BankFas.Core.Tests.Jobs;

/// <summary>The tenant's local date of a daily job (S2-b brief S2B-GAP-13): JOB-FIN-READINESS runs on it (db/static/051).</summary>
public sealed class JobTenantTests
{
    [Fact]
    public void The_local_date_follows_the_tenants_time_zone()
    {
        var late = new DateTimeOffset(2026, 10, 22, 22, 30, 0, TimeSpan.Zero);
        Assert.Equal(new DateTime(2026, 10, 23), new JobTenant(1, "ACTIVE", "Asia/Riyadh").LocalDate(late));
        Assert.Equal(new DateTime(2026, 10, 22), new JobTenant(1, "ACTIVE", "UTC").LocalDate(late));
        Assert.Equal(new DateTime(2026, 10, 22), new JobTenant(1, "ACTIVE", "Nowhere/Unknown").LocalDate(late));
    }
}
