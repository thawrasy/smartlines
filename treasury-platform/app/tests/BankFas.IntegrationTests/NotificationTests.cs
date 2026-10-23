using System.Globalization;
using System.Net;
using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// The notification pipeline of S1 against the database (FR-NTF-002 to 006, 010, 012; FR-PLT-038; AC-NTF-3; S1 brief
/// S1-GAP-2, 3, 9): the expiry alerts and their thresholds, the outbox consumer, the bell, the preferences, the
/// tenant's text overrides, the security events, the e-mail dispatch, and an event without a consumer.
/// </summary>
[Collection("database")]
public sealed class NotificationTests(PlatformFixture f)
{
    private async Task DrainAsync()
    {
        var ct = TestContext.Current.CancellationToken;
        await new OutboxJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
    }

    private static async Task<List<JsonElement>> BellAsync(HttpClient c) =>
        [.. (await c.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray()];

    [Fact]
    public async Task Expiry_alerts_go_once_per_threshold_to_the_rule_roles_without_the_number()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var company = PlatformFixture.Id(await t.Portal.PostOkAsync("/api/v1/companies", new
        {
            companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First Company", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12,
        }));
        var today = DateOnly.FromDateTime(f.Env.Clock.GetUtcNow().UtcDateTime);
        var up = await CompanyDocumentTests.UploadAsync(t.Portal, "/api/v1/documents", CompanyDocumentTests.Pdf("cr"), "cr.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "COMMERCIAL_REGISTRATION", ["title"] = "CR of C1", ["company"] = company, ["documentNumber"] = "7001234567",
            ["expiryDate"] = today.AddDays(20).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        });
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        var party = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new { kind = "INDIVIDUAL", nameAr = "مفوض", nameEn = "Signatory", country = "SA", residencyStatus = "CITIZEN" }));
        await tm.PostOkAsync($"/api/v1/parties/{party}/identity-documents", new
        {
            docKind = "NATIONAL_ID", issuingCountry = "SA", number = "1098765432", expiryDate = today.AddDays(5).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
        });

        var expiry = new ExpiryAlertJob(f.Env.Db, f.Env.Clock);
        await expiry.RunOnceAsync(ct);
        await DrainAsync();
        // 20 days left crosses 90, 60 and 30: one alert, at 30 (BR-PLT-013); the identity card at 7, without its number (BR-NTF-008).
        var bell = await BellAsync(tm);
        var doc = bell.Single(n => n.GetProperty("eventCode").GetString() == "DOC.EXPIRY");
        Assert.Contains("30", doc.GetProperty("title").GetString(), StringComparison.Ordinal);
        Assert.Contains("CR of C1", doc.GetProperty("body").GetString(), StringComparison.Ordinal);
        var id = bell.Single(n => n.GetProperty("eventCode").GetString() == "IDDOC.EXPIRY");
        Assert.DoesNotContain("1098765432", id.GetRawText(), StringComparison.Ordinal);
        Assert.DoesNotContain("5432", id.GetRawText(), StringComparison.Ordinal);
        Assert.Contains((await BellAsync(fo)), n => n.GetProperty("eventCode").GetString() == "DOC.EXPIRY");
        Assert.Empty(await BellAsync(te));   // TE is not among the rule's roles

        // Again: nothing new, neither from the job nor from a second delivery of the outbox.
        await expiry.RunOnceAsync(ct);
        await DrainAsync();
        Assert.Equal(2, (await BellAsync(tm)).Count);
        var counters = await tm.GetJsonAsync("/api/v1/notifications");
        Assert.Equal(2, counters.GetProperty("unreadCount").GetInt32());
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/notifications/{PlatformFixture.Id(doc)}/actions/read", new { });
        Assert.Equal(1, (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("unreadCount").GetInt32());
        await tm.OkAsync(HttpMethod.Post, "/api/v1/notifications/actions/read-all", new { });
        Assert.Equal(0, (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("unreadCount").GetInt32());
        // Another user's notification is not found.
        Assert.Equal((404, "NOT_FOUND"), await fo.PostProblemAsync($"/api/v1/notifications/{PlatformFixture.Id(doc)}/actions/read", new { }));

        // The e-mails of the mandatory expiry events go out from the dispatch job.
        var mails = f.Env.MailsTo(t.AdminEmail);
        await new NotificationDispatchJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
        var deliveries = (await t.Portal.GetJsonAsync("/api/v1/notification-deliveries?status=SENT")).GetProperty("items").EnumerateArray()
            .Where(d => d.GetProperty("channel").GetString() == "EMAIL").ToList();
        Assert.Equal(4, deliveries.Count);   // two events, to TM and FO
        Assert.Equal(mails, f.Env.MailsTo(t.AdminEmail));
    }

    [Fact]
    public async Task Preferences_keep_mandatory_events_in_the_application_and_overrides_use_listed_placeholders()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var prefs = (await tm.GetJsonAsync("/api/v1/notification-preferences")).GetProperty("items").EnumerateArray().ToList();
        Assert.Contains(prefs, p => p.GetProperty("groupKey").GetString() == "EXPIRY" && p.GetProperty("mandatoryInApp").GetBoolean());
        Assert.Equal((422, "V-NTF-MANDATORY"), await tm.ProblemAsync(HttpMethod.Put, "/api/v1/notification-preferences",
            new { items = new[] { new { groupKey = "EXPIRY", channel = "IN_APP", mode = "OFF" } } }));
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Put, "/api/v1/notification-preferences",
            new { items = new[] { new { groupKey = "EXPIRY", channel = "EMAIL", mode = "OFF" } } })).StatusCode);
        Assert.Equal("OFF", (await tm.GetJsonAsync("/api/v1/notification-preferences")).GetProperty("items").EnumerateArray()
            .Single(p => p.GetProperty("groupKey").GetString() == "EXPIRY").GetProperty("email").GetString());

        // V-NTF-01: only the event's placeholders; the override is used, and removing it brings the default back.
        Assert.Equal((422, "V-NTF-01"), await t.Portal.ProblemAsync(HttpMethod.Put, "/api/v1/notification-events/SEC.LOCKOUT/templates/IN_APP/en",
            new { subject = "Locked: {userName}", body = "Number {accountNumber}" }));
        Assert.Equal(HttpStatusCode.NoContent, (await t.Portal.SendAsync(HttpMethod.Put, "/api/v1/notification-events/SEC.LOCKOUT/templates/IN_APP/en",
            new { subject = "Locked account: {userName}", body = "{userName} is locked since {occurredAt}." })).StatusCode);
        var events = (await t.Portal.GetJsonAsync("/api/v1/notification-events")).GetProperty("items").EnumerateArray().ToList();
        Assert.True(events.Count >= 15);
        var lockout = events.Single(e => e.GetProperty("code").GetString() == "SEC.LOCKOUT");
        Assert.Contains(lockout.GetProperty("templates").EnumerateArray(), x => x.GetProperty("isTenantOverride").GetBoolean());
        // A mandatory recipient stays (V-NTF-02).
        var rule = lockout.GetProperty("rules")[0];
        Assert.Equal((422, "V-NTF-02"), await t.Portal.ProblemAsync(HttpMethod.Patch, $"/api/v1/notification-events/SEC.LOCKOUT/rules/{PlatformFixture.Id(rule)}",
            new { isActive = false }));

        // SEC.LOCKOUT (AC-NTF-3, S1-GAP-9): five wrong passwords lock the user, and the administrator hears with the overridden text.
        var (_, _, email) = await f.UserWithRoleAsync(t, "TE");
        var stranger = await f.Env.BrowserAsync($"{t.Code}.{TestEnvironment.Domain}");
        for (var i = 0; i < 5; i++) await stranger.PostProblemAsync("/api/v1/auth/login", new { email, password = "not the passphrase " + i });
        await DrainAsync();
        var locked = (await BellAsync(t.Portal)).Single(n => n.GetProperty("eventCode").GetString() == "SEC.LOCKOUT");
        Assert.StartsWith("Locked account: ", locked.GetProperty("title").GetString(), StringComparison.Ordinal);
        Assert.Equal("HIGH", locked.GetProperty("severity").GetString());
        Assert.Equal(HttpStatusCode.NoContent, (await t.Portal.SendAsync(HttpMethod.Delete, "/api/v1/notification-events/SEC.LOCKOUT/templates/IN_APP/en")).StatusCode);
    }

    [Fact]
    public async Task Security_and_relationship_events_reach_their_recipients_and_an_unknown_event_is_never_delivered_silently()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var company = PlatformFixture.Id(await t.Portal.PostOkAsync("/api/v1/companies", new
        {
            companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First Company", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12,
        }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", type = "BANK", country = "AE" }));
        var rm = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/institutions/{bank}/contacts", new
        {
            fullNameAr = "مدير العلاقة", contactMethods = new[] { new { kind = "EMAIL", value = "rm@bank.example" } },
        }));
        var rel = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/relationships", new { company, institution = bank }));
        await tm.PostOkAsync($"/api/v1/relationships/{rel}/coverage", new { contact = rm, role = "RM" });

        // The RM leaves the bank: TM (the actor) is not told, FO of the company is (INS.RELATIONSHIP_NO_RM).
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        await tm.PostOkAsync($"/api/v1/contacts/{rm}/actions/deactivate", new { reason = "LEFT_BANK" });
        await DrainAsync();
        var noRm = (await BellAsync(fo)).Single(n => n.GetProperty("eventCode").GetString() == "INS.RELATIONSHIP_NO_RM");
        Assert.Contains("BNK1", noRm.GetProperty("title").GetString(), StringComparison.Ordinal);
        Assert.DoesNotContain(await BellAsync(tm), n => n.GetProperty("eventCode").GetString() == "INS.RELATIONSHIP_NO_RM");

        // A sensitive permission given to a role tells the administrators other than the actor (SEC.SENSITIVE_PERMISSION_CHANGED).
        var (ta2, _, _) = await f.UserWithRoleAsync(t, "TA");
        var custom = PlatformFixture.Id(await t.Portal.PostOkAsync("/api/v1/roles", new { code = "VIEWER", nameEn = "Viewer", nameAr = "مطّلع", permissions = new[] { "acc.view" } }));
        var (_, etag) = await t.Portal.GetWithETagAsync($"/api/v1/roles/{custom}");
        Assert.Equal(HttpStatusCode.NoContent, (await t.Portal.SendAsync(HttpMethod.Put, $"/api/v1/roles/{custom}/permissions",
            new { permissions = new[] { "acc.view", "acc.reveal" } }, etag)).StatusCode);
        await DrainAsync();
        var changed = (await BellAsync(ta2)).Single(n => n.GetProperty("eventCode").GetString() == "SEC.SENSITIVE_PERMISSION_CHANGED");
        Assert.Equal("HIGH", changed.GetProperty("severity").GetString());
        Assert.DoesNotContain(await BellAsync(t.Portal), n => n.GetProperty("eventCode").GetString() == "SEC.SENSITIVE_PERMISSION_CHANGED");

        // An event no module consumes is not marked delivered: it fails and waits, to be seen (S1-GAP-3).
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        await using (var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct))
        {
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-PLT-OUTBOX", Guid.NewGuid(), ct);
            await Dapper.SqlMapper.ExecuteAsync(c, "INSERT cfg.OutboxEvent (TenantId, EventName, AggregateType, AggregateId, PayloadJson) VALUES (@t, 'mystery.happened', 'test.Thing', 1, '{}');",
                new { t = tenantId });
        }
        await DrainAsync();
        await using (var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct))
        {
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-PLT-OUTBOX", Guid.NewGuid(), ct);
            var (status, error) = await Dapper.SqlMapper.QuerySingleAsync<(string, string?)>(c,
                "SELECT Status, LastError FROM cfg.OutboxEvent WHERE EventName = 'mystery.happened';");
            Assert.Equal("FAILED", status);
            Assert.Contains("No consumer", error, StringComparison.Ordinal);
        }
        _ = ct;
    }
}
