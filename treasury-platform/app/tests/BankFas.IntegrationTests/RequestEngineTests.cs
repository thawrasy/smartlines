using System.Net;
using System.Net.Http.Json;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// The workflow engine on the seeded GENERIC_APPROVAL template (S3 batch B): a draft and its form, submission with the
/// required fields, the manager's approval resolved from the requester's line manager (BR-WFL-005), the number on
/// entering the treasury queue (BR-WFL-013), the atomic claim (BR-WFL-007), the completion, AWAITING_CLOSE seen by the
/// requester as "in progress" and the close by the treasury (BR-WFL-027); a return and a resubmission in a new cycle
/// (BR-WFL-008); the separation of duties (BR-WFL-006); and the two projections (BR-WFL-024).
/// </summary>
[Collection("database")]
public sealed class RequestEngineTests(PlatformFixture f)
{
    private sealed record People(HttpClient Rq, HttpClient Mgr, HttpClient Te, HttpClient Te2, HttpClient Tm, string Company);

    private static async Task<People> SetUpAsync(PlatformFixture f)
    {
        var t = await f.CreateTenantAsync();
        var admin = t.Portal;
        var (rq, _, rqEmail) = await f.UserWithRoleAsync(t, "RQ");
        var (mgr, _, mgrEmail) = await f.UserWithRoleAsync(t, "RQ");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var (te2, _, _) = await f.UserWithRoleAsync(t, "TE");
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var users = (await admin.GetJsonAsync("/api/v1/users")).GetProperty("items").EnumerateArray().ToList();
        string IdOf(string email) => users.First(u => u.GetProperty("email").GetString() == email).GetProperty("id").GetString()!;
        var (_, tag) = await admin.GetWithETagAsync($"/api/v1/users/{IdOf(rqEmail)}");
        await admin.OkAsync(HttpMethod.Patch, $"/api/v1/users/{IdOf(rqEmail)}", new { lineManager = IdOf(mgrEmail) }, tag);
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "RQ1", nameAr = "شركة الطلبات", nameEn = "Requests Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        return new People(rq, mgr, te, te2, tm, company);
    }

    private static async Task<(JsonElement Body, string ETag)> ActAsync(HttpClient c, string id, string action, string etag, object? body = null)
    {
        var response = await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        Assert.True(response.IsSuccessStatusCode, $"{action}: {(int)response.StatusCode} {text}");
        return (JsonDocument.Parse(text).RootElement.Clone(), response.Headers.ETag!.ToString());
    }

    private static async Task<(int, string)> RefusedAsync(HttpClient c, string id, string action, string etag, object? body = null) =>
        await c.ProblemAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);

    [Fact]
    public async Task A_general_request_goes_from_draft_to_close()
    {
        var p = await SetUpAsync(f);
        var types = (await p.Rq.GetJsonAsync("/api/v1/request-types")).GetProperty("items").EnumerateArray().Select(x => x.GetProperty("code").GetString()).ToList();
        Assert.Contains("GENERIC_APPROVAL", types);
        Assert.Contains("PURCHASE_LC", types);
        Assert.DoesNotContain("LC_AMENDMENT", types);   // a child type is raised from its letter of credit

        var created = await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_APPROVAL", company = p.Company, data = new { notes = "Need a bank letter" } });
        var id = created.GetProperty("id").GetString()!;
        Assert.StartsWith("D-", created.GetProperty("draftRef").GetString(), StringComparison.Ordinal);
        var (draft, etag) = await p.Rq.GetWithETagAsync($"/api/v1/requests/{id}");
        Assert.Equal(("REQUESTER", "DRAFT"), (draft.GetProperty("view").GetString(), draft.GetProperty("request").GetProperty("head").GetProperty("phase").GetString()));

        // The title is required at submission (BR-WFL-014); then the form is saved with its ETag.
        Assert.Equal((422, "V-REQ-REQUIRED"), await RefusedAsync(p.Rq, id, "submit", etag));
        var patch = await p.Rq.SendAsync(HttpMethod.Patch, $"/api/v1/requests/{id}",
            new { data = new { title = "Bank confirmation letter", amount = new { value = 250000, currency = "SAR" }, notes = "For the auditors" } }, etag);
        Assert.Equal(HttpStatusCode.NoContent, patch.StatusCode);
        var stale = etag;
        etag = patch.Headers.ETag!.ToString();
        Assert.Equal((409, "VERSION_CONFLICT"), await p.Rq.ProblemAsync(HttpMethod.Patch, $"/api/v1/requests/{id}", new { data = new { title = "x" } }, stale));
        (_, etag) = await ActAsync(p.Rq, id, "submit", etag);
        var submitted = await p.Rq.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal("IN_APPROVAL", submitted.GetProperty("request").GetProperty("head").GetProperty("phase").GetString());

        // The manager approves; the requester holds no slot of this stage; the treasury does not see a request it has no part in yet.
        Assert.Equal((403, "FORBIDDEN"), await RefusedAsync(p.Rq, id, "approve", etag));
        var tasks = (await p.Mgr.GetJsonAsync("/api/v1/requests?view=tasks")).GetProperty("items").EnumerateArray().Select(x => x.GetProperty("id").GetString()).ToList();
        Assert.Contains(id, tasks);
        (_, etag) = await ActAsync(p.Mgr, id, "approve", etag);
        var queued = await p.Te.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(("STAFF", "TREASURY_QUEUE"), (queued.GetProperty("view").GetString(), queued.GetProperty("staff").GetProperty("stage").GetString()));
        var number = queued.GetProperty("request").GetProperty("requestNo").GetString()!;
        Assert.Matches(@"^GNA-\d{2}-0001$", number);

        // The claim of a pure queue takes it into execution, assigned to the claimer (OQ-7); the requester sees "in progress".
        (_, etag) = await ActAsync(p.Te, id, "claim", etag);
        var executing = await p.Te.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(("EXECUTION", "PREPARATION"), (executing.GetProperty("staff").GetProperty("stage").GetString(), executing.GetProperty("staff").GetProperty("subStatus").GetString()));
        Assert.Equal((403, "FORBIDDEN"), await RefusedAsync(p.Te2, id, "complete", etag));
        (_, etag) = await ActAsync(p.Te, id, "complete", etag);

        // AWAITING_CLOSE: the requester still sees "in progress"; the executor may not close; the TM closes.
        var waiting = await p.Rq.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(("ACTIVE", "IN_PROGRESS"), (waiting.GetProperty("request").GetProperty("status").GetString(),
            waiting.GetProperty("request").GetProperty("head").GetProperty("phase").GetString()));
        Assert.Equal((403, "FORBIDDEN"), await RefusedAsync(p.Te, id, "close", etag));
        Assert.Equal((409, "INVALID_STATE"), await RefusedAsync(p.Rq, id, "cancel", etag));
        (_, etag) = await ActAsync(p.Tm, id, "close", etag);
        var done = await p.Rq.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(("COMPLETED", "COMPLETED"), (done.GetProperty("request").GetProperty("status").GetString(), done.GetProperty("request").GetProperty("head").GetProperty("phase").GetString()));

        // The requester's view carries no internal stage, assignee or internal timeline entry (BR-WFL-024).
        var raw = done.GetRawText();
        Assert.DoesNotContain("TREASURY_QUEUE", raw, StringComparison.Ordinal);
        Assert.DoesNotContain("\"staff\"", raw, StringComparison.Ordinal);
        Assert.DoesNotContain("CLAIMED", raw, StringComparison.Ordinal);
        Assert.Contains(done.GetProperty("request").GetProperty("timeline").EnumerateArray(), a => a.GetProperty("action").GetString() == "NUMBER_ASSIGNED");
        Assert.DoesNotContain(done.GetProperty("request").GetProperty("timeline").EnumerateArray(), a => a.GetProperty("action").GetString() == "STAGE_CHANGED");
        Assert.Equal((409, "INVALID_STATE"), await RefusedAsync(p.Tm, id, "close", etag));
    }

    [Fact]
    public async Task A_return_starts_a_new_cycle_and_internal_comments_stay_internal()
    {
        var p = await SetUpAsync(f);
        var id = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_APPROVAL", company = p.Company, data = new { title = "Letter" } })).GetProperty("id").GetString()!;
        var (_, etag) = await p.Rq.GetWithETagAsync($"/api/v1/requests/{id}");
        (_, etag) = await ActAsync(p.Rq, id, "submit", etag);
        Assert.Equal((422, "V-WFL-REASON"), await RefusedAsync(p.Mgr, id, "return", etag));
        (_, etag) = await ActAsync(p.Mgr, id, "return", etag, new { comment = "Add the purpose" });
        var returned = await p.Rq.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(("RETURNED", true), (returned.GetProperty("request").GetProperty("head").GetProperty("phase").GetString(),
            returned.GetProperty("request").GetProperty("head").GetProperty("awaitingYou").GetBoolean()));
        Assert.Contains(returned.GetProperty("request").GetProperty("timeline").EnumerateArray(), a => a.GetProperty("comment").GetString() == "Add the purpose");
        (_, etag) = await ActAsync(p.Rq, id, "resubmit", etag);
        var again = await p.Mgr.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(2, again.GetProperty("request").GetProperty("head").GetProperty("cycleNo").GetInt32());
        Assert.Equal("PENDING", again.GetProperty("request").GetProperty("myApprovals")[0].GetProperty("decision").GetString());
        (_, etag) = await ActAsync(p.Mgr, id, "approve", etag);

        // A comment the treasury keeps internal never reaches the requester.
        var internalNote = await p.Te.PostOkAsync($"/api/v1/requests/{id}/comments", new { body = "Check the signature", visibility = "INTERNAL" });
        Assert.Equal("INTERNAL", internalNote.GetProperty("visibility").GetString());
        await p.Rq.PostOkAsync($"/api/v1/requests/{id}/comments", new { body = "Thank you" });
        Assert.Equal((403, "FORBIDDEN"), await p.Rq.PostProblemAsync($"/api/v1/requests/{id}/comments", new { body = "Sneaky", visibility = "INTERNAL" }));
        var rqView = await p.Rq.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(["Thank you"], rqView.GetProperty("request").GetProperty("comments").EnumerateArray().Select(c => c.GetProperty("body").GetString()));
        Assert.Equal(2, (await p.Te.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("request").GetProperty("comments").GetArrayLength());
    }

    [Fact]
    public async Task Of_two_claims_at_once_one_wins_and_a_replay_changes_nothing()
    {
        var p = await SetUpAsync(f);
        var id = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company = p.Company, data = new { title = "Statement" } })).GetProperty("id").GetString()!;
        var (_, etag) = await p.Rq.GetWithETagAsync($"/api/v1/requests/{id}");
        (_, etag) = await ActAsync(p.Rq, id, "submit", etag);
        var ct = TestContext.Current.CancellationToken;
        async Task<HttpStatusCode> Claim(HttpClient c) => (await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/claim", new { }, etag)).StatusCode;
        var results = await Task.WhenAll(Claim(p.Te), Claim(p.Te2));
        Assert.Equal(1, results.Count(s => s == HttpStatusCode.OK));
        Assert.Equal(1, results.Count(s => s == HttpStatusCode.Conflict));
        var staff = await p.Tm.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal("EXECUTION", staff.GetProperty("staff").GetProperty("stage").GetString());
        var (_, now) = await p.Tm.GetWithETagAsync($"/api/v1/requests/{id}");

        // The same Idempotency-Key replays: one CANCELLED action, one audit row.
        using var first = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/requests/{id}/actions/cancel") { Content = JsonContent.Create(new { comment = "Not needed" }) };
        first.Headers.TryAddWithoutValidation("If-Match", now);
        first.Headers.TryAddWithoutValidation("Idempotency-Key", "cancel-once");
        Assert.Equal(HttpStatusCode.OK, (await p.Tm.SendAsync(first, ct)).StatusCode);
        using var second = new HttpRequestMessage(HttpMethod.Post, $"/api/v1/requests/{id}/actions/cancel") { Content = JsonContent.Create(new { comment = "Not needed" }) };
        second.Headers.TryAddWithoutValidation("If-Match", now);
        second.Headers.TryAddWithoutValidation("Idempotency-Key", "cancel-once");
        Assert.Equal(HttpStatusCode.OK, (await p.Tm.SendAsync(second, ct)).StatusCode);
        var timeline = (await p.Tm.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("request").GetProperty("timeline").EnumerateArray();
        Assert.Single(timeline, a => a.GetProperty("action").GetString() == "CANCELLED");
        Assert.Equal("CANCELLED", (await p.Rq.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("request").GetProperty("status").GetString());
    }

    [Fact]
    public async Task A_draft_is_cancelled_by_its_requester_and_unseen_by_others()
    {
        var p = await SetUpAsync(f);
        var id = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company = p.Company, data = new { title = "Draft" } })).GetProperty("id").GetString()!;
        Assert.Equal((404, "NOT_FOUND"), await p.Mgr.ProblemAsync(HttpMethod.Get, $"/api/v1/requests/{id}"));
        var (_, etag) = await p.Rq.GetWithETagAsync($"/api/v1/requests/{id}");
        Assert.Equal((403, "FORBIDDEN"), await RefusedAsync(p.Te, id, "cancel", etag));
        await ActAsync(p.Rq, id, "cancel", etag);
        var cancelled = await p.Rq.GetJsonAsync($"/api/v1/requests/{id}");
        Assert.Equal(("CANCELLED", "CANCELLED"), (cancelled.GetProperty("request").GetProperty("status").GetString(),
            cancelled.GetProperty("request").GetProperty("head").GetProperty("phase").GetString()));
        Assert.Equal(JsonValueKind.Null, cancelled.GetProperty("request").GetProperty("requestNo").ValueKind);
    }
}
