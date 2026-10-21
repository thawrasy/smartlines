using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>The background jobs of S0 against the database: the outbox, the trial reminders and the purges (DOC-F17, DOC-F05 6.3).</summary>
[Collection("database")]
public sealed class JobTests(PlatformFixture f)
{
    private static async Task<string> TenantIdAsync(PlatformFixture f, string code) =>
        (await f.Panel.GetJsonAsync("/api/v1/operator/tenants")).GetProperty("items").EnumerateArray()
            .First(x => x.GetProperty("code").GetString() == code).GetProperty("id").GetString()!;

    [Fact]
    public async Task The_outbox_tells_the_administrators_of_a_status_change_once()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var id = await TenantIdAsync(f, t.Code);
        await f.Panel.OkAsync(HttpMethod.Post, $"/api/v1/operator/tenants/{id}/status", new { status = "ACTIVE", mfaCode = f.NextCode(f.OperatorSecret) });
        var before = f.Env.MailsTo(t.AdminEmail);
        var job = new OutboxJob(f.Env.Db, f.Env.Mail);
        Assert.True(await job.RunOnceAsync(ct) >= 1);
        Assert.Equal(before + 1, f.Env.MailsTo(t.AdminEmail));
        await job.RunOnceAsync(ct);
        Assert.Equal(before + 1, f.Env.MailsTo(t.AdminEmail));
        var runs = await t.Portal.GetJsonAsync("/api/v1/jobs/JOB-PLT-OUTBOX/runs");
        Assert.Contains(runs.GetProperty("items").EnumerateArray(), r => r.GetProperty("result").GetString() == "delivered 1, failed 0");
    }

    [Fact]
    public async Task A_trial_ending_in_three_days_is_reminded_once()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        await TestEnvironment.SaExecuteAsync("UPDATE plat.Tenant SET TrialEndsOn = DATEADD(DAY, 3, CAST(SYSUTCDATETIME() AS DATE)) WHERE Code = @c;", new { c = t.Code });
        var job = new TrialReminderJob(f.Env.Db, f.Env.Mail, TimeProvider.System);
        var before = f.Env.MailsTo(t.AdminEmail);
        await job.RunOnceAsync(ct);
        Assert.Equal(before + 1, f.Env.MailsTo(t.AdminEmail));
        await job.RunOnceAsync(ct);
        Assert.Equal(before + 1, f.Env.MailsTo(t.AdminEmail));
        var runs = await t.Portal.GetJsonAsync("/api/v1/jobs/JOB-PLT-TRIAL-REMIND/runs");
        Assert.Contains(runs.GetProperty("items").EnumerateArray(), r => r.GetProperty("result").GetString()!.StartsWith("reminded 3 day(s)", StringComparison.Ordinal));
    }

    [Fact]
    public async Task The_purges_run_at_most_weekly()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var outbox = new OutboxPurgeJob(f.Env.Db);
        var runs = new JobRunPurgeJob(f.Env.Db);
        await outbox.RunOnceAsync(ct);
        await runs.RunOnceAsync(ct);
        await outbox.RunOnceAsync(ct);
        var purges = await t.Portal.GetJsonAsync("/api/v1/jobs/JOB-PLT-OUTBOX-PURGE/runs");
        Assert.Single(purges.GetProperty("items").EnumerateArray());
        Assert.Equal("deleted 0", purges.GetProperty("items")[0].GetProperty("result").GetString());
    }
}
