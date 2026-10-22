using BankFas.Core.Calendar;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.Data.Calendar;

/// <summary>
/// The working days of a country for a tenant (FR-PLT-035): the country's weekend and the non-working days, the
/// platform's holidays (TenantId NULL, entered by an operator) and the tenant's own days, both read through RLS.
/// </summary>
public static class WorkingCalendar
{
    public static async Task<WorkingDays> LoadAsync(SqlConnection c, SqlTransaction? tx, int countryId, DateOnly from, DateOnly to, CancellationToken ct)
    {
        var weekend = await c.ExecuteScalarAsync<string?>(new CommandDefinition("SELECT WeekendDays FROM ref.Country WHERE CountryId = @c;",
            new { c = countryId }, tx, cancellationToken: ct)).ConfigureAwait(false);
        var days = await c.QueryAsync<DateTime>(new CommandDefinition(
            "SELECT OnDate FROM cfg.NonWorkingDay WHERE CountryId = @c AND OnDate BETWEEN @f AND @t;",
            new { c = countryId, f = from.ToDateTime(TimeOnly.MinValue), t = to.ToDateTime(TimeOnly.MinValue) }, tx, cancellationToken: ct)).ConfigureAwait(false);
        return new WorkingDays(WorkingDays.Weekend(weekend), days.Select(DateOnly.FromDateTime).ToHashSet());
    }

    /// <summary>N working days after or before a date in a country; the window read covers the span with room to spare.</summary>
    public static async Task<DateOnly> AddWorkingDaysAsync(SqlConnection c, SqlTransaction? tx, int countryId, DateOnly from, int n, CancellationToken ct)
    {
        var span = Math.Abs(n) * 3 + 30;
        var cal = await LoadAsync(c, tx, countryId, from.AddDays(-span), from.AddDays(span), ct).ConfigureAwait(false);
        return cal.AddWorkingDays(from, n);
    }
}
