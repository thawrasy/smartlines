using System.Data;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data;

public sealed record JobTenant(int TenantId, string Status, string TimeZone)
{
    /// <summary>
    /// The tenant's calendar date at an instant, in its time zone (S2-b brief S2B-GAP-13): what a daily job counts days
    /// from, and the @AsOf that fin.usp_RunEarlyWarnings accepts (within a day of UTC, db/static/051). An unknown zone
    /// falls back to UTC.
    /// </summary>
    public DateTime LocalDate(DateTimeOffset now) =>
        (TimeZoneInfo.TryFindSystemTimeZoneById(TimeZone, out var zone) ? TimeZoneInfo.ConvertTime(now, zone) : now.ToUniversalTime()).Date;
}

/// <summary>The job worker's procedures (db/static/037, 038, 057), as tp_jobs.</summary>
public static class JobProcedures
{
    /// <summary>The tenants whose status the job allows and that have an active service account.</summary>
    public static async Task<IReadOnlyList<JobTenant>> ListTenantsAsync(SqlConnection c, string jobKey, CancellationToken ct) =>
        [.. await Proc.Named("plat.usp_ListTenantsForJobs").In("@JobKey", jobKey, DbType.AnsiString, 80).QueryAsync<JobTenant>(c, ct).ConfigureAwait(false)];

    /// <summary>Binds the connection as the tenant's service account for one job (BindingKind JOB); audited once per bind.</summary>
    public static Task BindAsync(SqlConnection c, int tenantId, string jobKey, Guid correlationId, CancellationToken ct) =>
        Proc.Named("sec.usp_SetJobContext").In("@TenantId", tenantId, DbType.Int32).In("@JobKey", jobKey, DbType.AnsiString, 80)
            .In("@CorrelationId", correlationId, DbType.Guid).ExecAsync(c, ct);

    public static async Task<(int Created, int Skipped)> SeedCoreRolesAsync(SqlConnection c, SqlTransaction? tx, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_SeedCoreRoles").Out("@Created", DbType.Int32).Out("@Skipped", DbType.Int32);
        await p.ExecAsync(c, ct, tx).ConfigureAwait(false);
        return (p.Get<int>("@Created"), p.Get<int>("@Skipped"));
    }

    /// <summary>The e-mail to send the link to.</summary>
    public static async Task<string> InviteFirstAdministratorAsync(SqlConnection c, SqlTransaction? tx, long userId, byte[] token, CancellationToken ct)
    {
        var p = Proc.Named("sec.usp_InviteFirstAdministrator").In("@UserId", userId, DbType.Int64).In("@Token", token, DbType.Binary, 64)
            .Out("@SentTo", DbType.String, 254);
        await p.ExecAsync(c, ct, tx).ConfigureAwait(false);
        return p.Get<string>("@SentTo");
    }

    public static async Task<(int Changed, int Failed)> RunTenantTransitionsAsync(SqlConnection c, string jobKey, CancellationToken ct)
    {
        var p = Proc.Named("plat.usp_RunTenantTransitions").In("@JobKey", jobKey, DbType.AnsiString, 80)
            .Out("@Changed", DbType.Int32).Out("@Failed", DbType.Int32);
        await p.ExecAsync(c, ct).ConfigureAwait(false);
        return (p.Get<int>("@Changed"), p.Get<int>("@Failed"));
    }

    internal static Task<int> ExecTextAsync(SqlConnection c, SqlTransaction? tx, string sql, object? args, CancellationToken ct) =>
        c.ExecuteAsync(new CommandDefinition(sql, args, tx, cancellationToken: ct));
}
