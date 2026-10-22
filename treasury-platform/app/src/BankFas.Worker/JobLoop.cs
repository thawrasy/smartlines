using BankFas.Data;
using BankFas.Data.Jobs;
using Microsoft.Data.SqlClient;

namespace BankFas.Worker;

/// <summary>
/// The schedule (S0 brief section 6, S1): every 10 seconds JOB-PLT-ONBOARD, JOB-PLT-OUTBOX (which also makes the
/// notifications) and JOB-NTF-DISPATCH (their e-mails); once a day (UTC) the expiry alerts JOB-NTF-EXPIRY, the tenant
/// transitions JOB-PLT-TRIAL-EXPIRE and JOB-PLT-ARCHIVE, the trial reminders, and the two purges, which themselves run
/// at most weekly per tenant, and the UPGRADE run of the tenant packs (S1). A failed pass is logged and taken up again on the next one; every job is safe to run twice.
/// One worker process in S0 (DOC-F17 section 3).
/// </summary>
public sealed partial class JobLoop(OnboardingJob onboarding, OutboxJob outbox, NotificationDispatchJob dispatch, ExpiryAlertJob expiry, TrialReminderJob reminders,
    OutboxPurgeJob outboxPurge, JobRunPurgeJob runPurge, SeedUpgradeJob seedUpgrade, SqlConnectionFactory db, TimeProvider clock, ILogger<JobLoop> logger) : BackgroundService
{
    private DateOnly _dailyDoneOn;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(10), clock);
        do
        {
            await RunAsync("JOB-PLT-ONBOARD", () => onboarding.RunOnceAsync(stoppingToken));
            await RunAsync("JOB-PLT-OUTBOX", () => outbox.RunOnceAsync(stoppingToken));
            await RunAsync(dispatch.JobKey, () => dispatch.RunOnceAsync(stoppingToken));
            var today = DateOnly.FromDateTime(clock.GetUtcNow().UtcDateTime);
            if (today != _dailyDoneOn)
            {
                foreach (var job in new[] { "JOB-PLT-TRIAL-EXPIRE", "JOB-PLT-ARCHIVE" })
                    await RunAsync(job, async () =>
                    {
                        await using var c = await db.OpenAsync(DbLogin.Jobs, stoppingToken);
                        var (changed, failed) = await JobProcedures.RunTenantTransitionsAsync(c, job, stoppingToken);
                        return changed + failed;
                    });
                await RunAsync(reminders.JobKey, () => reminders.RunOnceAsync(stoppingToken));
                await RunAsync(outboxPurge.JobKey, () => outboxPurge.RunOnceAsync(stoppingToken));
                await RunAsync(runPurge.JobKey, () => runPurge.RunOnceAsync(stoppingToken));
                await RunAsync("seed upgrade", () => seedUpgrade.RunOnceAsync(stoppingToken));
                await RunAsync(expiry.JobKey, () => expiry.RunOnceAsync(stoppingToken));
                _dailyDoneOn = today;
            }
        }
        while (await timer.WaitForNextTickAsync(stoppingToken));
    }

    private async Task RunAsync(string job, Func<Task<int>> pass)
    {
        try
        {
            var n = await pass();
            if (n > 0) LogPass(logger, job, n);
        }
        catch (Exception ex) when (ex is SqlException or System.Security.Cryptography.CryptographicException or IOException or InvalidOperationException)
        {
            LogFailed(logger, job, ex);
        }
    }

    [LoggerMessage(Level = LogLevel.Information, Message = "{Job}: {Count} tenant(s) or item(s) handled")]
    private static partial void LogPass(ILogger logger, string job, int count);

    [LoggerMessage(Level = LogLevel.Error, Message = "{Job}: the pass failed; it runs again on the next tick")]
    private static partial void LogFailed(ILogger logger, string job, Exception ex);
}
