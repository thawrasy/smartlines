using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// S5 (docs/50): the letter of credit reports and their CSV export (FR-LCI-033, FR-LCE-028), the export of the request
/// list (FR-REQ-026), the copy of any top-level request (FR-REQ-025), the five example request types kept inactive
/// (FR-REQ-022), the e-mail digest (FR-NTF-014) and the archive of read notifications (FR-NTF-020).
/// </summary>
[Collection("database")]
public sealed class S5Tests(PlatformFixture f)
{
    private sealed class FixedClock(DateTimeOffset at) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => at;
    }

    private static async Task ActAsync(HttpClient c, string id, string action)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        var response = await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", new { }, etag);
        Assert.True(response.IsSuccessStatusCode, $"{action}: {(int)response.StatusCode} {await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)}");
    }

    private static async Task<string> TextAsync(HttpClient c, string path)
    {
        var response = await c.SendAsync(HttpMethod.Get, path);
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        Assert.True(response.IsSuccessStatusCode, $"{path}: {(int)response.StatusCode} {text}");
        Assert.StartsWith("text/csv", response.Content.Headers.ContentType?.MediaType, StringComparison.Ordinal);
        return text.TrimStart('﻿');
    }

    [Fact]
    public async Task Reports_run_in_scope_and_export_as_csv()
    {
        var b = await ProformaTests.BedAsync(f);
        var company = await ProformaTests.CompanyAsync(b, "RP1", "RP01");
        var account = await ProformaTests.CollectionAccountAsync(b, company, "880-1");
        var r = await ProformaTests.SubmittedAsync(b, company, "Report");
        Assert.Null(await ProformaTests.IssueAsync(b, r, account));
        var number = (await ProformaTests.ProformaOfAsync(b.Tm, r)).GetProperty("proformaNo").GetString()!;

        // The treasury manager reads every report of both sides; each one runs.
        var codes = (await b.Tm.GetJsonAsync("/api/v1/reports")).GetProperty("items").EnumerateArray().Select(x => x.GetProperty("code").GetString()!).ToList();
        Assert.Contains("R-LCI-01", codes);
        Assert.Contains("R-LCE-08", codes);
        foreach (var code in codes)
        {
            var run = await b.Tm.GetJsonAsync($"/api/v1/reports/{code}");
            Assert.Equal(code, run.GetProperty("code").GetString());
        }
        var register = (await b.Tm.GetJsonAsync("/api/v1/reports/R-LCE-03")).GetProperty("items").EnumerateArray().ToList();
        Assert.Contains(register, x => x.GetProperty("proformaNo").GetString() == number);
        // The invariant holds, so R-LCE-08 is empty.
        Assert.Empty((await b.Tm.GetJsonAsync("/api/v1/reports/R-LCE-08")).GetProperty("items").EnumerateArray());

        // A sales preparer has the sales reports only; a purchase report is refused.
        var sales = (await b.Slp.GetJsonAsync("/api/v1/reports")).GetProperty("items").EnumerateArray().Select(x => x.GetProperty("code").GetString()!).ToList();
        Assert.All(sales, c => Assert.StartsWith("R-LCE-", c, StringComparison.Ordinal));
        Assert.Equal(403, (await b.Slp.ProblemAsync(HttpMethod.Get, "/api/v1/reports/R-LCI-01")).Item1);
        Assert.Equal(404, (await b.Tm.ProblemAsync(HttpMethod.Get, "/api/v1/reports/R-XXX-01")).Item1);
        Assert.Equal((422, "VALIDATION_FAILED"), await b.Tm.ProblemAsync(HttpMethod.Get, "/api/v1/reports/R-LCE-03?from=31-12-2026"));

        // The export: a header and one row per proforma, audited.
        var csv = await TextAsync(b.Tm, "/api/v1/reports/R-LCE-03/export");
        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.StartsWith("proformaNo,company,customer", lines[0], StringComparison.Ordinal);
        Assert.Contains(lines, l => l.StartsWith($"\"{number}\"", StringComparison.Ordinal));
        Assert.NotEmpty((await b.Tm.GetJsonAsync("/api/v1/audit-events?action=REPORT_EXPORTED")).GetProperty("items").EnumerateArray());
    }

    [Fact]
    public async Task Requests_are_copied_exported_and_the_example_types_stay_inactive()
    {
        var t = await f.CreateTenantAsync();
        var (rq, _, _) = await f.UserWithRoleAsync(t, "RQ");
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "S5C", nameAr = "شركة النسخ", nameEn = "Copy Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var id = PlatformFixture.Id(await rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company, data = new { title = "Bank letter", notes = "For the auditor" } }));

        // FR-REQ-025: the copy is a new draft of the user with the same fields.
        var copy = PlatformFixture.Id(await rq.PostOkAsync($"/api/v1/requests/{id}/copy", new { }));
        Assert.NotEqual(id, copy);
        var copied = (await rq.GetJsonAsync($"/api/v1/requests/{copy}")).GetProperty("request");
        Assert.Equal(("DRAFT", "For the auditor"), (copied.GetProperty("status").GetString(), copied.GetProperty("form").GetProperty("notes").GetString()));

        // FR-REQ-026: the list as CSV, without the treasury's columns for a requester.
        var csv = await TextAsync(rq, "/api/v1/requests?view=mine&format=csv");
        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("requestNo,draftRef,type,title,companyNameEn,amount,currency,phase,createdAt,updatedAt", lines[0]);
        Assert.Equal(3, lines.Length);
        Assert.Equal((422, "VALIDATION_FAILED"), await rq.ProblemAsync(HttpMethod.Get, "/api/v1/requests?format=xlsx"));

        // FR-REQ-022: the five example types are seeded but not offered.
        var types = (await rq.GetJsonAsync("/api/v1/request-types")).GetProperty("items").EnumerateArray().Select(x => x.GetProperty("code").GetString()).ToList();
        foreach (var code in new[] { "BANK_GUARANTEE", "FX_REQUEST", "PAYMENT_APPROVAL", "BANK_LETTER_REQUEST", "FACILITY_DRAWDOWN" })
            Assert.DoesNotContain(code, types);
        var (refused, _) = await rq.ProblemAsync(HttpMethod.Post, "/api/v1/requests", new { type = "FX_REQUEST", company, data = new { title = "x" } });
        Assert.True(refused is 403 or 404 or 422, $"an inactive type is refused, got {refused}");
    }

    [Fact]
    public async Task A_digest_gathers_the_held_emails_once_and_read_notifications_are_archived()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (rq, _, rqEmail) = await f.UserWithRoleAsync(t, "RQ");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "S5D", nameAr = "شركة الملخص", nameEn = "Digest Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        Assert.Equal((422, "VALIDATION_FAILED"), await rq.ProblemAsync(HttpMethod.Put, "/api/v1/notification-preferences",
            new { items = new[] { new { groupKey = "REQUESTS", channel = "IN_APP", mode = "DIGEST_DAILY" } } }));
        await rq.SendAsync(HttpMethod.Put, "/api/v1/notification-preferences", new { items = new[] { new { groupKey = "REQUESTS", channel = "EMAIL", mode = "DIGEST_DAILY" } } });

        // Two requests completed: REQ.COMPLETED twice, held for the digest.
        foreach (var title in new[] { "First", "Second" })
        {
            var id = PlatformFixture.Id(await rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company, data = new { title } }));
            await ActAsync(rq, id, "submit");
            await ActAsync(te, id, "claim");
            await ActAsync(te, id, "complete");
            await ActAsync(tm, id, "close");
        }
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        while (await outbox.RunOnceAsync(ct) > 0) { }
        var bell = (await rq.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Where(n => n.GetProperty("eventCode").GetString() == "REQ.COMPLETED").ToList();
        Assert.Equal(2, bell.Count);
        var before = f.Env.MailsTo(rqEmail);
        await new NotificationDispatchJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
        Assert.Equal(before, f.Env.MailsTo(rqEmail));

        // The next morning one digest goes; the same period again sends nothing.
        var tomorrow = new FixedClock(DateTimeOffset.UtcNow.AddDays(2));
        var digest = new NotificationDigestJob(f.Env.Db, f.Env.Mail, tomorrow);
        await digest.RunOnceAsync(ct);
        Assert.Equal(before + 1, f.Env.MailsTo(rqEmail));
        await digest.RunOnceAsync(ct);
        await new NotificationDispatchJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
        Assert.Equal(before + 1, f.Env.MailsTo(rqEmail));

        // Read today, archived after 180 days; the unread one stays.
        await rq.OkAsync(HttpMethod.Post, $"/api/v1/notifications/{PlatformFixture.Id(bell[0])}/actions/read", new { });
        await new NotificationRetentionJob(f.Env.Db, new FixedClock(DateTimeOffset.UtcNow.AddDays(179))).RunOnceAsync(ct);
        Assert.Equal(2, (await rq.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Count(n => n.GetProperty("eventCode").GetString() == "REQ.COMPLETED"));
        await new NotificationRetentionJob(f.Env.Db, new FixedClock(DateTimeOffset.UtcNow.AddDays(181))).RunOnceAsync(ct);
        var left = (await rq.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Where(n => n.GetProperty("eventCode").GetString() == "REQ.COMPLETED").ToList();
        Assert.Equal(PlatformFixture.Id(bell[1]), PlatformFixture.Id(left.Single()));
    }
}
