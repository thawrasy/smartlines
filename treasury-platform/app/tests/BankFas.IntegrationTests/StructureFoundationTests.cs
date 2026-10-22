using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// The foundation of S1-b (S1-b brief, batch S1B-A): the six new events with their recipients and texts (NTF.BASE v3,
/// S1B-GAP-2), the expiry rules of bodies, grants and signatories (CORE.EXPIRY v2, S1B-GAP-3), the setting of
/// segregation of duties (S1B-GAP-5), and the S1-b domain events that the outbox delivers before their consumers exist.
/// </summary>
[Collection("database")]
public sealed class StructureFoundationTests(PlatformFixture f)
{
    private static readonly string[] Events = ["BODY.TERM_EXPIRY", "GRANT.EXPIRY", "OWN.TOTAL_MISMATCH", "ACC.SIGNATORY_EXPIRY", "ACC.NO_SIGNATORY", "ACC.GOV_CONFLICT"];

    [Fact]
    public async Task A_new_account_has_the_S1b_events_expiry_rules_and_setting()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var events = (await t.Portal.GetJsonAsync("/api/v1/notification-events")).GetProperty("items").EnumerateArray().ToList();
        foreach (var code in Events)
        {
            var e = events.Single(x => x.GetProperty("code").GetString() == code);
            var roles = e.GetProperty("rules").EnumerateArray().Select(r => r.GetProperty("role").GetString()).Order(StringComparer.Ordinal).ToList();
            Assert.Equal(["FO", "TM"], roles);
            Assert.Equal(4, e.GetProperty("templates").GetArrayLength());
            // No amount is ever a placeholder: ceilings and limits are confidential (BR-NTF-008).
            Assert.DoesNotContain(e.GetProperty("placeholders").EnumerateArray(), p => p.GetString()!.Contains("amount", StringComparison.OrdinalIgnoreCase)
                || p.GetString()!.Contains("ceiling", StringComparison.OrdinalIgnoreCase) || p.GetString()!.Contains("limit", StringComparison.OrdinalIgnoreCase));
        }
        Assert.True(events.Single(x => x.GetProperty("code").GetString() == "ACC.NO_SIGNATORY").GetProperty("isMandatory").GetBoolean());

        var setting = (await t.Portal.GetJsonAsync("/api/v1/settings")).GetProperty("items").EnumerateArray()
            .Single(s => s.GetProperty("key").GetString() == "org.grant.segregation_of_duties");
        Assert.Equal("BOOL", setting.GetProperty("valueType").GetString());
        Assert.True(setting.GetProperty("effective").GetBoolean());

        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-NTF-EXPIRY", Guid.NewGuid(), ct);
        var rules = (await Dapper.SqlMapper.QueryAsync<(string, string, int)>(c,
            """
            SELECT r.ItemType, r.LeadDays, COUNT(rr.RoleId) FROM cfg.ExpiryAlertRule AS r LEFT JOIN cfg.ExpiryAlertRuleRole AS rr ON rr.ExpiryAlertRuleId = r.ExpiryAlertRuleId
             GROUP BY r.ItemType, r.LeadDays;
            """)).ToDictionary(x => x.Item1, x => (x.Item2, x.Item3));
        Assert.Equal(("[90,30]", 2), rules["BODY_TERM"]);
        Assert.Equal(("[60,30,7]", 2), rules["AUTHORITY_GRANT"]);
        Assert.Equal(("[30,15,7]", 2), rules["SIGNATORY"]);
        Assert.Equal(5, rules.Count);
    }

    [Fact]
    public async Task The_S1b_domain_events_are_delivered_before_their_consumers_exist()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        string[] names = ["ownership.changed", "body.changed", "authority.granted", "authority.revoked", "signatory.activated", "signatory.authority.changed",
            "authority.conflict.opened", "authority.conflict.resolved"];
        await using (var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct))
        {
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-PLT-OUTBOX", Guid.NewGuid(), ct);
            foreach (var (n, i) in names.Select((n, i) => (n, i)))
                await Dapper.SqlMapper.ExecuteAsync(c, "INSERT cfg.OutboxEvent (TenantId, EventName, AggregateType, AggregateId, PayloadJson) VALUES (@t, @n, 'test.Thing', @i, '{}');",
                    new { t = tenantId, n, i = i + 1 });
        }
        await new OutboxJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
        await using (var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct))
        {
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-PLT-OUTBOX", Guid.NewGuid(), ct);
            var status = (await Dapper.SqlMapper.QueryAsync<(string, string)>(c,
                "SELECT EventName, Status FROM cfg.OutboxEvent WHERE AggregateType = 'test.Thing';")).ToDictionary(x => x.Item1, x => x.Item2);
            Assert.All(names, n => Assert.Equal("DELIVERED", status[n]));
        }
    }
}
