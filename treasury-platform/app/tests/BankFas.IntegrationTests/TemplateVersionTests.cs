using System.Text.Json;
using System.Text.Json.Nodes;

namespace BankFas.IntegrationTests;

/// <summary>
/// Template versions (AC-WFL-6, FR-WFL-001, FR-WFL-006; BR-WFL-001, 019): an administrator drafts version 2 of
/// GENERIC_SIMPLE with an extra approval for amounts above 5,000,000 SAR, which another user publishes. A request
/// submitted on version 1 stays on it; a draft written before the publication moves to version 2 at its submission;
/// 6,000,000 SAR takes the extra approval, 4,000,000 SAR does not, and 1,000,000 USD takes it as not comparable.
/// </summary>
[Collection("database")]
public sealed class TemplateVersionTests(PlatformFixture f)
{
    private static async Task<string> SubmitAsync(HttpClient c, string company, object data, bool submit = true)
    {
        var id = (await c.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company, data })).GetProperty("id").GetString()!;
        if (submit)
        {
            var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
            await c.OkAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/submit", new { }, etag);
        }
        return id;
    }

    private static async Task<(int Version, string? Stage)> WhereAsync(HttpClient staff, string id)
    {
        var s = (await staff.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("staff");
        return (s.GetProperty("templateVersion").GetInt32(), s.GetProperty("stage").GetString());
    }

    [Fact]
    public async Task A_new_version_applies_to_new_and_draft_requests_only()
    {
        var t = await f.CreateTenantAsync();
        var admin = t.Portal;   // TA: wfl.template.manage
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (rq, _, _) = await f.UserWithRoleAsync(t, "RQ");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "TV1", nameAr = "شركة القوالب", nameEn = "Templates Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));

        var onV1 = await SubmitAsync(rq, company, new { title = "Before", amount = new { value = 6_000_000, currency = "SAR" } });
        var draft = await SubmitAsync(rq, company, new { title = "Draft", amount = new { value = 6_000_000, currency = "SAR" } }, submit: false);
        Assert.Equal((1, "TREASURY_QUEUE"), await WhereAsync(tm, onV1));

        // Version 2: DRAFT -> EXTRA_APPROVAL (TM) when the amount is above 5,000,000 SAR, else the queue.
        var g = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(BankFas.Data.Seeding.TenantSeeder.PacksDirectory(null), "WFL.BASE", "v1", "templates", "GENERIC_SIMPLE.json"),
            TestContext.Current.CancellationToken))!.AsObject();
        g["changeNote"] = "Large amounts need the treasury manager first";
        g["stages"]!.AsArray().Add(JsonNode.Parse("""
            {"key": "EXTRA_APPROVAL", "kind": "APPROVAL", "nameAr": "موافقة إضافية", "nameEn": "Extra approval", "phase": "IN_APPROVAL", "seq": 2, "approvalMode": "ANY",
             "slaHours": 8, "slots": [{"key": "TM", "labelEn": "Treasury manager", "subject": "ROLE", "role": "TM"}]}
            """));
        var transitions = g["transitions"]!.AsArray();
        transitions.Insert(0, JsonNode.Parse("""{"from": "DRAFT", "action": "SUBMIT", "to": "EXTRA_APPROVAL", "priority": 1, "condition": {"field": "amount", "op": "gt", "value": 5000000, "currency": "SAR"}}"""));
        foreach (var tr in transitions) if (tr!["from"]!.GetValue<string>() == "DRAFT" && tr["to"]!.GetValue<string>() == "TREASURY_QUEUE") tr["priority"] = 2;
        transitions.Add(JsonNode.Parse("""{"from": "EXTRA_APPROVAL", "action": "APPROVE", "to": "TREASURY_QUEUE"}"""));
        transitions.Add(JsonNode.Parse("""{"from": "EXTRA_APPROVAL", "action": "REJECT", "to": "REJECTED"}"""));

        // A graph that would not publish is refused with its problems; the good one is drafted, and its author may not publish it.
        var broken = JsonNode.Parse(g.ToJsonString())!.AsObject();
        broken["transitions"]!.AsArray().Add(JsonNode.Parse("""{"from": "EXTRA_APPROVAL", "action": "APPROVE", "to": "NOWHERE"}"""));
        Assert.Equal((422, "V-WFL-01"), await admin.PostProblemAsync("/api/v1/templates", JsonDocument.Parse(broken.ToJsonString()).RootElement));
        var v2 = await admin.PostOkAsync("/api/v1/templates", JsonDocument.Parse(g.ToJsonString()).RootElement);
        Assert.Equal(2, v2.GetProperty("versionNo").GetInt32());
        var v2Id = v2.GetProperty("id").GetString()!;
        Assert.Equal((403, "SAME_PERSON"), await admin.PostProblemAsync($"/api/v1/templates/{v2Id}/actions/publish", new { }));
        await tm.PostOkAsync($"/api/v1/templates/{v2Id}/actions/publish", new { });
        var versions = (await tm.GetJsonAsync("/api/v1/templates")).GetProperty("items").EnumerateArray()
            .Where(x => x.GetProperty("templateKey").GetString() == "GENERIC_SIMPLE").Select(x => (x.GetProperty("versionNo").GetInt32(), x.GetProperty("status").GetString())).ToList();
        Assert.Equal([(2, "PUBLISHED"), (1, "RETIRED")], versions);

        // The request on version 1 stays there; the draft moves to version 2 at its submission.
        Assert.Equal((1, "TREASURY_QUEUE"), await WhereAsync(tm, onV1));
        var (_, etag) = await rq.GetWithETagAsync($"/api/v1/requests/{draft}");
        await rq.OkAsync(HttpMethod.Post, $"/api/v1/requests/{draft}/actions/submit", new { }, etag);
        Assert.Equal((2, "EXTRA_APPROVAL"), await WhereAsync(tm, draft));

        // FR-WFL-006: 6,000,000 SAR adds the approval, 4,000,000 does not, 1,000,000 USD is not comparable and takes it.
        Assert.Equal((2, "EXTRA_APPROVAL"), await WhereAsync(tm, await SubmitAsync(rq, company, new { title = "Six", amount = new { value = 6_000_000, currency = "SAR" } })));
        Assert.Equal((2, "TREASURY_QUEUE"), await WhereAsync(tm, await SubmitAsync(rq, company, new { title = "Four", amount = new { value = 4_000_000, currency = "SAR" } })));
        var usd = await SubmitAsync(rq, company, new { title = "Dollars", amount = new { value = 1_000_000, currency = "USD" } });
        Assert.Equal((2, "EXTRA_APPROVAL"), await WhereAsync(tm, usd));
        var meta = (await tm.GetJsonAsync($"/api/v1/requests/{usd}")).GetProperty("request").GetProperty("timeline").EnumerateArray().Select(a => a.GetProperty("action").GetString()).ToList();
        Assert.Contains("STAGE_CHANGED", meta);
    }
}
