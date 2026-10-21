using BankFas.Data;
using BankFas.Data.Jobs;
using Microsoft.Data.SqlClient;

namespace BankFas.Worker;

/// <summary>
/// The S0 jobs (brief section 6): JOB-PLT-ONBOARD every 10 seconds, and the daily tenant transitions
/// JOB-PLT-TRIAL-EXPIRE and JOB-PLT-ARCHIVE once a day (UTC, docs 038). A failed pass is logged and tried again on
/// the next one; the database keeps every job safe to run twice.
/// </summary>
public sealed partial class JobLoop(OnboardingJob onboarding, SqlConnectionFactory db, TimeProvider clock, ILogger<JobLoop> logger) : BackgroundService
{
    private readonly TimeProvider _clock = clock;
    private DateOnly _transitionsDoneOn;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10), _clock);
        do
        {
            try
            {
                var delivered = await onboarding.RunOnceAsync(stoppingToken);
                if (delivered > 0) LogOnboarded(logger, delivered);
                var today = DateOnly.FromDateTime(_clock.GetUtcNow().UtcDateTime);
                if (today != _transitionsDoneOn)
                {
                    await using var c = await db.OpenAsync(DbLogin.Jobs, stoppingToken);
                    foreach (var job in new[] { "JOB-PLT-TRIAL-EXPIRE", "JOB-PLT-ARCHIVE" })
                    {
                        var (changed, failed) = await JobProcedures.RunTenantTransitionsAsync(c, job, stoppingToken);
                        LogTransitions(logger, job, changed, failed);
                    }
                    _transitionsDoneOn = today;
                }
            }
            catch (Exception ex) when (ex is SqlException or System.Security.Cryptography.CryptographicException or IOException or InvalidOperationException)
            {
                LogFailed(logger, ex);
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "Onboarded {Count} tenant(s)")]
    private static partial void LogOnboarded(ILogger logger, int count);

    [LoggerMessage(Level = LogLevel.Information, Message = "{Job}: {Changed} changed, {Failed} failed")]
    private static partial void LogTransitions(ILogger logger, string job, int changed, int failed);

    [LoggerMessage(Level = LogLevel.Error, Message = "A job pass failed; it runs again on the next tick")]
    private static partial void LogFailed(ILogger logger, Exception ex);
}
