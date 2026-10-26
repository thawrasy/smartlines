namespace BankFas.IntegrationTests;

/// <summary>
/// The request types the tenant's administrator defines (docs/31 row 73): a type of the tenant's own on the general
/// requests screen, refused activation until it has a workflow, an audience and its sequence; its workflow drawn from
/// steps (an approval by the treasury manager, the queue held by the treasury executive role) drafted by the
/// administrator and published by another user; its audience; and a request raised on it that is approved, numbered
/// with the type's prefix on entering the queue, claimed only by the role named and completed. A seeded credit type
/// keeps its workflow and its screen, and a user without the template permissions sees no definitions.
/// </summary>
[Collection("database")]
public sealed class RequestTypeTests(PlatformFixture f)
{
    private static async Task ActAsync(HttpClient c, string id, string action)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        await c.OkAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", new { }, etag);
    }

    [Fact]
    public async Task The_administrator_defines_a_type_its_workflow_and_audience_and_a_request_runs_on_it()
    {
        var t = await f.CreateTenantAsync();
        var admin = t.Portal;   // TA: wfl.template.view, manage and publish
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (rq, _, _) = await f.UserWithRoleAsync(t, "RQ");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "RT1", nameAr = "شركة الأنواع", nameEn = "Types Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));

        // The seeded types are listed with their screens; a credit type keeps its workflow and its screen.
        var list = (await admin.GetJsonAsync("/api/v1/request-type-definitions")).GetProperty("items").EnumerateArray().ToList();
        var lc = list.Single(x => x.GetProperty("code").GetString() == "PURCHASE_LC");
        Assert.Equal(("PURCHASE", false, true), (lc.GetProperty("category").GetString(), lc.GetProperty("buildable").GetBoolean(), lc.GetProperty("isActive").GetBoolean()));
        Assert.Equal((422, "V-REQ-01"), await admin.ProblemAsync(HttpMethod.Patch, "/api/v1/request-type-definitions/PURCHASE_LC", new { category = "GENERAL" }));
        Assert.Equal((422, "V-WFL-01"), await admin.PostProblemAsync("/api/v1/request-type-definitions/PURCHASE_LC/workflow", new { }));
        Assert.Equal((403, "FORBIDDEN"), await rq.ProblemAsync(HttpMethod.Get, "/api/v1/request-type-definitions"));

        // A type of the tenant's own: checked, created inactive with its sequence, and refused activation while incomplete.
        Assert.Equal((422, "V-REQ-01"), await admin.PostProblemAsync("/api/v1/request-type-definitions", new { code = "x", nameAr = "أ", nameEn = "A", category = "GENERAL", numberPrefix = "GT" }));
        Assert.Equal((422, "V-PLT-10"), await admin.PostProblemAsync("/api/v1/request-type-definitions", new { code = "GUARANTEE_REQUEST", nameAr = "طلب ضمان", nameEn = "Guarantee request", category = "GENERAL", numberPrefix = "G1" }));
        await admin.PostOkAsync("/api/v1/request-type-definitions", new { code = "GUARANTEE_REQUEST", nameAr = "طلب ضمان بنكي", nameEn = "Bank guarantee request", category = "GENERAL", numberPrefix = "BGR" });
        Assert.Equal((409, "DUPLICATE"), await admin.PostProblemAsync("/api/v1/request-type-definitions", new { code = "GUARANTEE_REQUEST", nameAr = "ب", nameEn = "B", category = "GENERAL", numberPrefix = "BGR" }));
        Assert.Contains((await admin.GetJsonAsync("/api/v1/number-sequences")).GetProperty("items").EnumerateArray(),
            s => s.GetProperty("sequenceKey").GetString() == "req:GUARANTEE_REQUEST" && s.GetProperty("pattern").GetString() == "BGR-{yy}-{seq:0000}");
        Assert.Equal((422, "BR-REQ-001"), await admin.PostProblemAsync("/api/v1/request-type-definitions/GUARANTEE_REQUEST/actions/activate", new { }));
        await admin.OkAsync(HttpMethod.Patch, "/api/v1/request-type-definitions/GUARANTEE_REQUEST", new { nameAr = "طلب ضمان", description = "A guarantee from a bank." });

        // The workflow from steps: a wrong step is refused; the good one is drafted, and its author may not publish it.
        Assert.Equal((422, "V-WFL-01"), await admin.PostProblemAsync("/api/v1/request-type-definitions/GUARANTEE_REQUEST/workflow", new { approvals = new[] { new { subject = "ROLE" } } }));
        var draft = await admin.PostOkAsync("/api/v1/request-type-definitions/GUARANTEE_REQUEST/workflow",
            new { approvals = new[] { new { subject = "ROLE", role = "TM", slaHours = 8 } }, treasuryRole = "TE", claimSlaHours = 4, executionSlaHours = 48, changeNote = "First version" });
        var draftId = draft.GetProperty("id").GetString()!;
        Assert.Equal((403, "SAME_PERSON"), await admin.PostProblemAsync($"/api/v1/templates/{draftId}/actions/publish", new { }));
        await tm.PostOkAsync($"/api/v1/templates/{draftId}/actions/publish", new { });
        var stages = (await admin.GetJsonAsync($"/api/v1/templates/{draftId}")).GetProperty("stages").EnumerateArray().Select(s => s.GetProperty("stageKey").GetString()).ToList();
        Assert.Equal(["DRAFT", "APPROVAL_1", "RETURNED", "TREASURY_QUEUE", "EXECUTION", "COMPLETED", "REJECTED", "CANCELLED"], stages);

        // The audience, then the activation; the requester now sees the type on the general screen.
        Assert.Equal((422, "V-REQ-01"), await admin.ProblemAsync(HttpMethod.Put, "/api/v1/request-type-definitions/GUARANTEE_REQUEST/audience", new { roles = new[] { "NOPE" } }));
        await admin.OkAsync(HttpMethod.Put, "/api/v1/request-type-definitions/GUARANTEE_REQUEST/audience", new { roles = new[] { "RQ", "TM" } });
        await admin.PostOkAsync("/api/v1/request-type-definitions/GUARANTEE_REQUEST/actions/activate", new { });
        Assert.Equal((422, "BR-REQ-001"), await admin.ProblemAsync(HttpMethod.Put, "/api/v1/request-type-definitions/GUARANTEE_REQUEST/audience", new { roles = Array.Empty<string>() }));
        var mine = (await rq.GetJsonAsync("/api/v1/request-types")).GetProperty("items").EnumerateArray()
            .Single(x => x.GetProperty("code").GetString() == "GUARANTEE_REQUEST");
        Assert.Equal(("GENERAL", "Bank guarantee request"), (mine.GetProperty("category").GetString(), mine.GetProperty("nameEn").GetString()));
        var row = (await admin.GetJsonAsync("/api/v1/request-type-definitions")).GetProperty("items").EnumerateArray().Single(x => x.GetProperty("code").GetString() == "GUARANTEE_REQUEST");
        Assert.Equal((true, true, 1), (row.GetProperty("isCustom").GetBoolean(), row.GetProperty("isActive").GetBoolean(), row.GetProperty("current").GetProperty("versionNo").GetInt32()));

        // A request on it: the manager approves, the queue numbers it BGR-, only the treasury executive role claims it, then it completes.
        var id = PlatformFixture.Id(await rq.PostOkAsync("/api/v1/requests", new { type = "GUARANTEE_REQUEST", company, data = new { title = "Bid bond", amount = new { value = 250_000, currency = "SAR" } } }));
        // The reference registry (row 72): an ERP reference, changed once; the current one is searchable, the first kept as history.
        await rq.PostOkAsync($"/api/v1/requests/{id}/external-refs", new { systemCode = "ERP", refType = "ERP_REFERENCE", value = "po-7781" });
        await rq.PostOkAsync($"/api/v1/requests/{id}/external-refs", new { systemCode = "ERP", refType = "ERP_REFERENCE", value = "PO 7782" });
        var refs = (await rq.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("request").GetProperty("references").EnumerateArray()
            .Select(x => (x.GetProperty("value").GetString(), x.GetProperty("isCurrent").GetBoolean())).ToList();
        Assert.Equal([("PO 7782", true), ("po-7781", false)], refs);
        Assert.Contains((await rq.GetJsonAsync("/api/v1/requests?view=mine&q=po7782")).GetProperty("items").EnumerateArray(), x => x.GetProperty("id").GetString() == id);
        await ActAsync(rq, id, "submit");
        // The screens of the category (row 73): pending approval on the general screen, not on the import credits one.
        static bool Has(System.Text.Json.JsonElement list, string id) => list.GetProperty("items").EnumerateArray().Any(x => x.GetProperty("id").GetString() == id);
        Assert.True(Has(await tm.GetJsonAsync("/api/v1/requests?view=pending&category=GENERAL"), id));
        Assert.False(Has(await tm.GetJsonAsync("/api/v1/requests?view=pending&category=PURCHASE"), id));
        Assert.Equal((422, "VALIDATION_FAILED"), await tm.ProblemAsync(HttpMethod.Get, "/api/v1/requests?view=pending&category=NOPE"));
        Assert.Equal("APPROVAL_1", (await tm.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("staff").GetProperty("stage").GetString());
        await ActAsync(tm, id, "approve");
        var queued = await te.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal("TREASURY_QUEUE", queued.GetProperty("staff").GetProperty("stage").GetString());
        Assert.StartsWith("BGR-", queued.GetProperty("request").GetProperty("requestNo").GetString());
        var (_, etag) = await te.GetWithETagAsync($"/api/v1/requests/{id}");
        Assert.Equal(403, (await fo.ProblemAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/claim", new { }, etag)).Status);
        Assert.True(Has(await te.GetJsonAsync("/api/v1/requests?view=incoming&category=GENERAL"), id));
        Assert.False(Has(await te.GetJsonAsync("/api/v1/requests?view=execution&category=GENERAL"), id));
        await ActAsync(te, id, "claim");
        Assert.False(Has(await te.GetJsonAsync("/api/v1/requests?view=incoming&category=GENERAL"), id));
        Assert.True(Has(await te.GetJsonAsync("/api/v1/requests?view=execution&category=GENERAL&assignee=me"), id));
        Assert.False(Has(await tm.GetJsonAsync("/api/v1/requests?view=execution&category=GENERAL&assignee=me"), id));
        Assert.True(Has(await tm.GetJsonAsync("/api/v1/requests?view=execution&category=GENERAL"), id));
        Assert.Equal("EXECUTION", (await te.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("staff").GetProperty("stage").GetString());
        await ActAsync(te, id, "complete");
        Assert.Equal("COMPLETED", (await te.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("staff").GetProperty("stage").GetString());

        // Deactivated, it leaves the requester's list and keeps its requests.
        await admin.PostOkAsync("/api/v1/request-type-definitions/GUARANTEE_REQUEST/actions/deactivate", new { });
        Assert.DoesNotContain((await rq.GetJsonAsync("/api/v1/request-types")).GetProperty("items").EnumerateArray(), x => x.GetProperty("code").GetString() == "GUARANTEE_REQUEST");
        Assert.Equal("COMPLETED", (await te.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("staff").GetProperty("stage").GetString());
    }
}
