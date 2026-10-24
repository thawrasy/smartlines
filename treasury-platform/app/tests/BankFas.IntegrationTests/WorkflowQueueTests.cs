using System.Net;
using System.Text.Json;
using BankFas.Data;
using BankFas.Data.Workflow;
using Dapper;
using Microsoft.Data.SqlClient;

namespace BankFas.IntegrationTests;

/// <summary>
/// The queue, the delegations and the SLA (S3 batch C): AC-WFL-2 (the claim race, a user out of the company's scope, a
/// release that keeps the queue age, a reassignment with its reason heard by the new assignee and not by the requester),
/// the sub-status that pauses the SLA (BR-WFL-010), the inbox and its counters (FR-WFL-036), AC-WFL-1's delegation half
/// (the delegate sees and approves the manager's slot, ActedBy the delegate and OnBehalfOf the manager; the rules of
/// BR-WFL-021; a revoked delegation shows nothing), and AC-WFL-5 on JOB-WFL-SLA (AT_RISK once at 80% of the business
/// hours, BREACHED once at the due time, escalated again only at the next working day's opening).
/// </summary>
[Collection("database")]
public sealed class WorkflowQueueTests(PlatformFixture f)
{
    private sealed record People(TestTenant T, HttpClient Rq, HttpClient Mgr, HttpClient Te, HttpClient Te2, HttpClient Te3, HttpClient Tm, HttpClient D, string Company,
        Func<string, string> UserId);

    private async Task<People> SetUpAsync()
    {
        var t = await f.CreateTenantAsync();
        var admin = t.Portal;
        var (rq, _, rqEmail) = await f.UserWithRoleAsync(t, "RQ");
        var (mgr, _, mgrEmail) = await f.UserWithRoleAsync(t, "RQ");
        var (d, _, dEmail) = await f.UserWithRoleAsync(t, "RQ");
        var (te, _, teEmail) = await f.UserWithRoleAsync(t, "TE");
        var (te2, _, te2Email) = await f.UserWithRoleAsync(t, "TE");
        var (te3, _, _) = await f.UserWithRoleAsync(t, "TE", allCompanies: false);
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var users = (await admin.GetJsonAsync("/api/v1/users")).GetProperty("items").EnumerateArray().ToList();
        string IdOf(string email) => users.First(u => u.GetProperty("email").GetString() == email).GetProperty("id").GetString()!;
        var (_, tag) = await admin.GetWithETagAsync($"/api/v1/users/{IdOf(rqEmail)}");
        await admin.OkAsync(HttpMethod.Patch, $"/api/v1/users/{IdOf(rqEmail)}", new { lineManager = IdOf(mgrEmail) }, tag);
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "WQ1", nameAr = "شركة الطابور", nameEn = "Queue Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var emails = new Dictionary<string, string> { ["rq"] = rqEmail, ["mgr"] = mgrEmail, ["d"] = dEmail, ["te"] = teEmail, ["te2"] = te2Email };
        return new People(t, rq, mgr, te, te2, te3, tm, d, company, who => IdOf(emails[who]));
    }

    private static async Task<string> ActAsync(HttpClient c, string id, string action, object? body = null)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        var response = await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        Assert.True(response.IsSuccessStatusCode, $"{action}: {(int)response.StatusCode} {text}");
        return response.Headers.ETag!.ToString();
    }

    private static async Task<(int, string)> RefusedAsync(HttpClient c, string id, string action, object? body = null)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        return await c.ProblemAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);
    }

    private async Task<SqlConnection> BoundAsync(TestTenant t)
    {
        var ct = TestContext.Current.CancellationToken;
        var c = await f.Env.Db.OpenAsync(DbLogin.Jobs, ct);
        await JobProcedures.BindAsync(c, await TestEnvironment.TenantIdAsync(t.Code), "JOB-WFL-SLA", Guid.NewGuid(), ct);
        return c;
    }

    private static bool Has(JsonElement list, string id) => list.EnumerateArray().Any(x => x.GetProperty("id").GetString() == id);

    /// <summary>
    /// docs/31 row 44: each request is timed from its own arrival and worked on its own. Two requests reaching the same
    /// stage two hours apart each take their due time from their own entry; what happens to one leaves the other's clock
    /// as it was.
    /// </summary>
    [Fact]
    public async Task Each_request_is_timed_from_its_own_arrival_and_on_its_own()
    {
        var p = await SetUpAsync();
        var a = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company = p.Company, data = new { title = "First" } })).GetProperty("id").GetString()!;
        await ActAsync(p.Rq, a, "submit");
        f.Env.Clock.Now = f.Env.Clock.Now.AddHours(2);
        var b = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company = p.Company, data = new { title = "Second" } })).GetProperty("id").GetString()!;
        await ActAsync(p.Rq, b, "submit");

        await using var c = await BoundAsync(p.T);
        async Task<(DateTime EnteredAt, DateTime? QueuedAt, DateTime? DueAt, DateTime? ClaimDueAt, string SlaState)> Inst(string id) =>
            await c.QuerySingleAsync<(DateTime, DateTime?, DateTime?, DateTime?, string)>(
                """
                SELECT i.EnteredAt, i.QueuedAt, i.DueAt, i.ClaimDueAt, i.SlaState
                FROM wfl.RequestStageInstance AS i JOIN wfl.Request AS r ON r.RequestId = i.RequestId
                WHERE r.PublicId = @id AND i.ExitedAt IS NULL;
                """, new { id = Guid.Parse(id) });
        var first = await Inst(a);
        var second = await Inst(b);
        Assert.InRange((second.EnteredAt - first.EnteredAt).TotalMinutes, 119, 121);
        Assert.Equal(first.EnteredAt, first.QueuedAt);
        Assert.Equal(second.EnteredAt, second.QueuedAt);
        Assert.True(second.ClaimDueAt > first.ClaimDueAt, "the second request's claim time runs from its own arrival");
        Assert.True(second.DueAt >= first.DueAt, "the second request's due time runs from its own arrival");

        // Working on the first request leaves the second's clock untouched.
        await ActAsync(p.Te, a, "claim");
        await ActAsync(p.Te, a, "release", new { comment = "Back to the queue" });
        Assert.Equal(second, await Inst(b));
    }

    [Fact]
    public async Task AC_WFL_2_the_claim_race_release_and_reassignment_and_the_sub_status_that_pauses_the_SLA()
    {
        var p = await SetUpAsync();
        var id = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company = p.Company, data = new { title = "Bank statement" } }))
            .GetProperty("id").GetString()!;
        await ActAsync(p.Rq, id, "submit");
        Assert.True(Has((await p.Te.GetJsonAsync("/api/v1/inbox")).GetProperty("queue"), id));
        Assert.Equal((404, "NOT_FOUND"), await p.Te3.ProblemAsync(HttpMethod.Get, $"/api/v1/requests/{id}"));
        Assert.False(Has((await p.Te3.GetJsonAsync("/api/v1/inbox")).GetProperty("queue"), id));

        // The race: one claim wins, the other is 409.
        var (_, etag) = await p.Te.GetWithETagAsync($"/api/v1/requests/{id}");
        async Task<(HttpClient C, HttpStatusCode S)> Claim(HttpClient c) => (c, (await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/claim", new { }, etag)).StatusCode);
        var race = await Task.WhenAll(Claim(p.Te), Claim(p.Te2));
        Assert.Equal([HttpStatusCode.OK, HttpStatusCode.Conflict], race.Select(r => r.S).Order());
        var winner = race.Single(r => r.S == HttpStatusCode.OK).C;
        var ct = TestContext.Current.CancellationToken;
        await using var c = await BoundAsync(p.T);
        var requestId = await c.ExecuteScalarAsync<long>("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id = Guid.Parse(id) });
        async Task<(string Status, DateTime? QueuedAt, int Releases, int Reassigns, string SlaState, DateTime? DueAt, int Paused)> Inst() =>
            await c.QuerySingleAsync<(string, DateTime?, int, int, string, DateTime?, int)>(
                "SELECT Status, QueuedAt, ReleaseCount, ReassignCount, SlaState, DueAt, SlaPausedSeconds FROM wfl.RequestStageInstance WHERE RequestId = @r AND ExitedAt IS NULL;",
                new { r = requestId });
        var claimed = await Inst();
        Assert.Equal(("CLAIMED", "ON_TRACK"), (claimed.Status, claimed.SlaState));
        Assert.True(Has((await winner.GetJsonAsync("/api/v1/inbox")).GetProperty("tasks"), id));

        // The release returns the stage to the queue with ReleaseCount 1; its queue time then stays through the reassignment.
        await ActAsync(winner, id, "release", new { comment = "Out today" });
        var released = await Inst();
        Assert.Equal(("QUEUED", 1), (released.Status, released.Releases));
        Assert.NotNull(released.QueuedAt);

        // The reassignment: a reason, a user who takes the queue and is not the requester, by a holder of req.reassign.
        Assert.Equal((403, "FORBIDDEN"), await RefusedAsync(p.Te, id, "reassign", new { assignTo = p.UserId("te2"), comment = "Cover" }));
        Assert.Equal((422, "V-WFL-REASON"), await RefusedAsync(p.Tm, id, "reassign", new { assignTo = p.UserId("te2") }));
        Assert.Equal((422, "V-WFL-ASSIGNEE"), await RefusedAsync(p.Tm, id, "reassign", new { assignTo = p.UserId("rq"), comment = "Cover" }));
        Assert.Equal((422, "V-WFL-ASSIGNEE"), await RefusedAsync(p.Tm, id, "reassign", new { assignTo = p.UserId("mgr"), comment = "Cover" }));
        await ActAsync(p.Tm, id, "reassign", new { assignTo = p.UserId("te2"), comment = "Balance the load" });
        var reassigned = await Inst();
        Assert.Equal(("CLAIMED", 1, released.QueuedAt), (reassigned.Status, reassigned.Reassigns, reassigned.QueuedAt));
        Assert.True(Has((await p.Te2.GetJsonAsync("/api/v1/inbox")).GetProperty("tasks"), id));
        var te2Id = await c.ExecuteScalarAsync<long>("SELECT AppUserId FROM sec.AppUser WHERE PublicId = @u;", new { u = Guid.Parse(p.UserId("te2")) });
        var rqId = await c.ExecuteScalarAsync<long>("SELECT AppUserId FROM sec.AppUser WHERE PublicId = @u;", new { u = Guid.Parse(p.UserId("rq")) });
        var heard = (await c.QueryAsync<string>(
            """
            SELECT JSON_QUERY(PayloadJson, '$.recipientUserIds') FROM cfg.OutboxEvent
             WHERE AggregateType = 'ntf.wfl.Request' AND AggregateId = @r AND JSON_VALUE(PayloadJson, '$.eventCode') = 'REQ.REASSIGNED';
            """, new { r = requestId })).Single();
        Assert.Equal([te2Id], JsonSerializer.Deserialize<long[]>(heard)!);
        // Nothing of the queue reaches the requester: none of the internal events names them.
        var toRequester = await c.ExecuteScalarAsync<int>(
            """
            SELECT COUNT(*) FROM cfg.OutboxEvent AS e CROSS APPLY OPENJSON(e.PayloadJson, '$.recipientUserIds') AS u
             WHERE e.AggregateType = 'ntf.wfl.Request' AND e.AggregateId = @r AND u.[value] = @rq
               AND JSON_VALUE(e.PayloadJson, '$.eventCode') IN ('REQ.REASSIGNED', 'REQ.CLAIMED', 'REQ.RELEASED', 'REQ.QUEUED');
            """, new { r = requestId, rq = rqId });
        Assert.Equal(0, toRequester);

        // The sub-statuses (BR-WFL-010): only the assignee; AT_BANK pauses the SLA, leaving it carries the due time on.
        Assert.Equal((403, "FORBIDDEN"), await RefusedAsync(p.Tm, id, "substatus", new { subStatus = "SIGNING" }));
        Assert.Equal((422, "V-WFL-SUBSTATUS"), await RefusedAsync(p.Te2, id, "substatus", new { subStatus = "NOWHERE" }));
        await ActAsync(p.Te2, id, "substatus", new { subStatus = "AT_BANK" });
        Assert.Equal("PAUSED", (await Inst()).SlaState);
        Assert.DoesNotContain("AT_BANK", (await p.Rq.GetJsonAsync($"/api/v1/requests/{id}")).GetRawText(), StringComparison.Ordinal);
        await ActAsync(p.Te2, id, "substatus", new { subStatus = "FOLLOW_UP" });
        var resumed = await Inst();
        Assert.NotEqual("PAUSED", resumed.SlaState);
        Assert.True(resumed.DueAt >= claimed.DueAt && resumed.Paused >= 0);
        Assert.Equal(2, await c.ExecuteScalarAsync<int>("SELECT COUNT(*) FROM wfl.RequestAction WHERE RequestId = @r AND ActionType = 'SUBSTATUS_CHANGED';", new { r = requestId }));

        // The priority: a holder of req.reassign; URGENT gives its reason; the queue puts it first.
        Assert.Equal((422, "V-REQ-06"), await RefusedAsync(p.Tm, id, "priority", new { priority = "URGENT" }));
        await ActAsync(p.Tm, id, "priority", new { priority = "URGENT", comment = "Bank deadline" });
        Assert.Equal(("URGENT", "Bank deadline"), await c.QuerySingleAsync<(string, string)>("SELECT Priority, UrgentReason FROM wfl.Request WHERE RequestId = @r;", new { r = requestId }));
        _ = ct;
    }

    [Fact]
    public async Task AC_WFL_1_a_delegate_approves_for_the_manager_and_a_revoked_delegation_shows_nothing()
    {
        var p = await SetUpAsync();
        // The tenant's own date (the server's "today" of a delegation), not the UTC date: the test clock runs ahead and may cross midnight in Riyadh.
        string? zoneId;
        await using (var bound = await BoundAsync(p.T)) zoneId = await bound.ExecuteScalarAsync<string>("SELECT TimeZone FROM plat.v_CurrentTenant;");
        var today = DateOnly.FromDateTime(TimeZoneInfo.ConvertTimeFromUtc(f.Env.Clock.GetUtcNow().UtcDateTime, TimeZoneInfo.FindSystemTimeZoneById(zoneId!)));
        string D(DateOnly d) => d.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);

        // BR-WFL-021 and V-WFL-06.
        Assert.Equal((422, "V-WFL-06"), await p.Mgr.PostProblemAsync("/api/v1/delegations", new { to = p.UserId("mgr"), startsOn = D(today), endsOn = D(today.AddDays(3)) }));
        Assert.Equal((422, "V-WFL-06"), await p.Mgr.PostProblemAsync("/api/v1/delegations", new { to = p.UserId("d"), startsOn = D(today), endsOn = D(today.AddDays(90)) }));
        Assert.Equal((422, "V-WFL-06"), await p.Mgr.PostProblemAsync("/api/v1/delegations", new { to = p.UserId("d"), startsOn = D(today.AddDays(-1)), endsOn = D(today.AddDays(3)) }));
        Assert.Equal((403, "FORBIDDEN"), await p.Rq.PostProblemAsync("/api/v1/delegations", new { from = p.UserId("mgr"), to = p.UserId("d"), startsOn = D(today), endsOn = D(today.AddDays(3)) }));
        var delegation = PlatformFixture.Id(await p.Mgr.PostOkAsync("/api/v1/delegations",
            new { to = p.UserId("d"), startsOn = D(today), endsOn = D(today.AddDays(3)), scope = "APPROVALS_ONLY", reason = "Annual leave" }));
        Assert.Equal((422, "V-WFL-06"), await p.Mgr.PostProblemAsync("/api/v1/delegations", new { to = p.UserId("te"), startsOn = D(today.AddDays(2)), endsOn = D(today.AddDays(5)) }));
        Assert.Equal((422, "V-WFL-06"), await p.D.PostProblemAsync("/api/v1/delegations", new { to = p.UserId("te"), startsOn = D(today), endsOn = D(today.AddDays(1)) }));
        var listed = (await p.D.GetJsonAsync("/api/v1/delegations")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal(("ACTIVE", "APPROVALS_ONLY"), (listed.GetProperty("status").GetString(), listed.GetProperty("scope").GetString()));

        // The delegate sees the manager's slot, in the inbox marked on behalf of the manager, and approves it.
        var id = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_APPROVAL", company = p.Company, data = new { title = "Bank letter", notes = "Letter" } }))
            .GetProperty("id").GetString()!;
        await ActAsync(p.Rq, id, "submit");
        var inbox = await p.D.GetJsonAsync("/api/v1/inbox");
        var item = inbox.GetProperty("approvals").EnumerateArray().Single(x => x.GetProperty("id").GetString() == id);
        Assert.Equal(p.UserId("mgr"), item.GetProperty("onBehalfOf").GetProperty("id").GetString());
        Assert.Contains("approve", (await p.D.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("request").GetProperty("actions").EnumerateArray().Select(a => a.GetString()));
        await ActAsync(p.D, id, "approve");
        await using var c = await BoundAsync(p.T);
        var slot = await c.QuerySingleAsync<(string Source, Guid ActedBy, Guid OnBehalfOf, bool HasDelegation)>(
            """
            SELECT a.Source, b.PublicId, o.PublicId, CAST(CASE WHEN a.DelegationId IS NULL THEN 0 ELSE 1 END AS BIT)
              FROM wfl.RequestApproval AS a JOIN wfl.Request AS r ON r.RequestId = a.RequestId
              JOIN sec.AppUser AS b ON b.AppUserId = a.ActedByUserId JOIN sec.AppUser AS o ON o.AppUserId = a.OnBehalfOfUserId
             WHERE r.PublicId = @id AND a.Decision = 'APPROVED' AND a.Source = 'DELEGATE';
            """, new { id = Guid.Parse(id) });
        Assert.Equal(("DELEGATE", Guid.Parse(p.UserId("d")), Guid.Parse(p.UserId("mgr")), true), slot);
        Assert.Equal(1, await c.ExecuteScalarAsync<int>(
            """
            SELECT COUNT(*) FROM wfl.RequestAction AS a JOIN wfl.Request AS r ON r.RequestId = a.RequestId JOIN sec.AppUser AS o ON o.AppUserId = a.OnBehalfOfUserId
             WHERE r.PublicId = @id AND a.ActionType = 'APPROVED' AND o.PublicId = @m;
            """, new { id = Guid.Parse(id), m = Guid.Parse(p.UserId("mgr")) }));

        // Revoked: the next request's slot no longer shows to the delegate.
        Assert.Equal(HttpStatusCode.NoContent, (await p.Mgr.SendAsync(HttpMethod.Post, $"/api/v1/delegations/{delegation}/revoke", new { })).StatusCode);
        Assert.Equal((409, "INVALID_STATE"), await p.Mgr.ProblemAsync(HttpMethod.Post, $"/api/v1/delegations/{delegation}/revoke", new { }));
        var next = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_APPROVAL", company = p.Company, data = new { title = "Second letter", notes = "Letter" } }))
            .GetProperty("id").GetString()!;
        await ActAsync(p.Rq, next, "submit");
        Assert.False(Has((await p.D.GetJsonAsync("/api/v1/inbox")).GetProperty("approvals"), next));
        Assert.Equal((404, "NOT_FOUND"), await p.D.ProblemAsync(HttpMethod.Get, $"/api/v1/requests/{next}"));
    }

    [Fact]
    public async Task AC_WFL_5_the_SLA_job_marks_at_risk_once_breached_once_and_escalates_at_the_next_opening()
    {
        var p = await SetUpAsync();
        var id = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company = p.Company, data = new { title = "Confirmation" } }))
            .GetProperty("id").GetString()!;
        await ActAsync(p.Rq, id, "submit");
        await ActAsync(p.Te, id, "claim");
        var ct = TestContext.Current.CancellationToken;
        var tenantId = await TestEnvironment.TenantIdAsync(p.T.Code);
        await using var c = await BoundAsync(p.T);
        var zoneId = await c.ExecuteScalarAsync<string>("SELECT TimeZone FROM plat.v_CurrentTenant;");
        var zone = TimeZoneInfo.FindSystemTimeZoneById(zoneId!);
        DateTime Utc(int day, int hour, int minute = 0) => TimeZoneInfo.ConvertTimeToUtc(new DateTime(2026, 10, day, hour, minute, 0, DateTimeKind.Unspecified), zone);
        var requestId = await c.ExecuteScalarAsync<long>("SELECT RequestId FROM wfl.Request WHERE PublicId = @id;", new { id = Guid.Parse(id) });
        // EXECUTION has 24 business hours. Entered Thursday 2026-10-08 15:00: 2 + 9 (Sunday) + 9 (Monday) + 4 = Tuesday 12:00;
        // AT_RISK at 80% (19.2 hours) = Monday 16:12.
        await c.ExecuteAsync(
            """
            UPDATE wfl.RequestStageInstance SET EnteredAt = @entered, QueuedAt = @entered, ClaimedAt = @entered, DueAt = @due, SlaState = 'ON_TRACK'
             WHERE RequestId = @r AND ExitedAt IS NULL;
            """, new { entered = Utc(8, 15), due = Utc(13, 12), r = requestId });
        var tenant = new JobTenant(tenantId, "ACTIVE", zoneId!);
        async Task RunAt(DateTime utc) => await new WorkflowSlaJob(f.Env.Db, new FixedClock(utc)).RunTenantAsync(tenant, ct);
        async Task<(string State, int Risk, int Breach, int Escalated)> Seen() => await c.QuerySingleAsync<(string, int, int, int)>(
            """
            SELECT i.SlaState,
                   (SELECT COUNT(*) FROM wfl.RequestAction WHERE StageInstanceId = i.RequestStageInstanceId AND ActionType = 'SLA_AT_RISK'),
                   (SELECT COUNT(*) FROM wfl.RequestAction WHERE StageInstanceId = i.RequestStageInstanceId AND ActionType = 'SLA_BREACHED'),
                   (SELECT COUNT(*) FROM wfl.RequestAction WHERE StageInstanceId = i.RequestStageInstanceId AND ActionType = 'ESCALATED')
              FROM wfl.RequestStageInstance AS i WHERE i.RequestId = @r AND i.ExitedAt IS NULL;
            """, new { r = requestId });
        await RunAt(Utc(12, 16));
        Assert.Equal(("ON_TRACK", 0, 0, 0), await Seen());
        await RunAt(Utc(12, 16, 12));
        Assert.Equal(("AT_RISK", 1, 0, 0), await Seen());
        await RunAt(Utc(12, 16, 40));
        Assert.Equal(("AT_RISK", 1, 0, 0), await Seen());
        await RunAt(Utc(13, 12));
        Assert.Equal(("OVERDUE", 1, 1, 0), await Seen());
        await RunAt(Utc(13, 15));
        await RunAt(Utc(13, 20));
        await RunAt(Utc(14, 7, 59));
        Assert.Equal(("OVERDUE", 1, 1, 0), await Seen());
        await RunAt(Utc(14, 8));
        await RunAt(Utc(14, 9));
        Assert.Equal(("OVERDUE", 1, 1, 1), await Seen());
        Assert.Equal("OVERDUE", (await p.Tm.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("staff").GetProperty("slaState").GetString());
        var notices = (await c.QueryAsync<string>(
            "SELECT JSON_VALUE(PayloadJson, '$.eventCode') FROM cfg.OutboxEvent WHERE AggregateType = 'ntf.wfl.Request' AND AggregateId = @r AND JSON_VALUE(PayloadJson, '$.eventCode') LIKE 'REQ.SLA%';",
            new { r = requestId })).ToList();
        Assert.Equal(1, notices.Count(n => n == "REQ.SLA_AT_RISK"));
        Assert.Equal(2, notices.Count(n => n == "REQ.SLA_BREACHED"));
    }

    [Fact]
    public async Task AC_WFL_10_an_open_action_is_reminded_after_24_48_and_72_business_hours_and_an_approval_resolves_it()
    {
        var p = await SetUpAsync();
        var ct = TestContext.Current.CancellationToken;
        var tenantId = await TestEnvironment.TenantIdAsync(p.T.Code);
        await using var c = await BoundAsync(p.T);
        var zoneId = await c.ExecuteScalarAsync<string>("SELECT TimeZone FROM plat.v_CurrentTenant;");
        var zone = TimeZoneInfo.FindSystemTimeZoneById(zoneId!);
        DateTime Utc(int day, int hour, int minute = 0) => TimeZoneInfo.ConvertTimeToUtc(new DateTime(2026, 10, day, hour, minute, 0, DateTimeKind.Unspecified), zone);
        var tenant = new JobTenant(tenantId, "ACTIVE", zoneId!);
        async Task<string> SubmittedAsync(string title)
        {
            var id = (await p.Rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_APPROVAL", company = p.Company, data = new { title, notes = "Letter" } })).GetProperty("id").GetString()!;
            await ActAsync(p.Rq, id, "submit");
            return id;
        }
        var waiting = await SubmittedAsync("Waiting");
        var answered = await SubmittedAsync("Answered");
        var outbox = new BankFas.Data.Jobs.OutboxJob(f.Env.Db, f.Env.Mail);
        while (await outbox.RunTenantAsync(tenant, ct)) { }
        const string Notice = """
            SELECT n.NotificationId FROM ntf.Notification AS n JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = n.EventTypeId
              JOIN wfl.Request AS r ON r.RequestId = n.TargetEntityId AND n.TargetEntityType = 'wfl.Request'
              JOIN sec.AppUser AS u ON u.AppUserId = n.UserId
             WHERE e.Code = 'REQ.APPROVAL_NEEDED' AND r.PublicId = @id AND u.PublicId = @m;
            """;
        var first = await c.ExecuteScalarAsync<long>(Notice, new { id = Guid.Parse(waiting), m = Guid.Parse(p.UserId("mgr")) });
        var second = await c.ExecuteScalarAsync<long>(Notice, new { id = Guid.Parse(answered), m = Guid.Parse(p.UserId("mgr")) });
        Assert.True(first > 0 && second > 0);
        // Made Monday 2026-10-12 09:00: reminders Wednesday 14 15:00, Monday 19 12:00, Thursday 22 09:00, and none after.
        await c.ExecuteAsync("UPDATE ntf.Notification SET CreatedAt = @at WHERE NotificationId IN (@first, @second);", new { at = Utc(12, 9), first, second });
        await ActAsync(p.Mgr, answered, "approve");
        Assert.Equal("RESOLVED", await c.ExecuteScalarAsync<string>("SELECT ActionState FROM ntf.Notification WHERE NotificationId = @second;", new { second }));
        async Task<int> At(DateTime utc)
        {
            await new NotificationReminderJob(f.Env.Db, new FixedClock(utc)).RunTenantAsync(tenant, ct);
            return await c.ExecuteScalarAsync<int>("SELECT ReminderCount FROM ntf.Notification WHERE NotificationId = @first;", new { first });
        }
        Assert.Equal(0, await At(Utc(14, 14, 59)));
        Assert.Equal(1, await At(Utc(14, 15)));
        Assert.Equal(1, await At(Utc(16, 12)));   // Friday: no reminder outside working days
        Assert.Equal(1, await At(Utc(19, 11, 59)));
        Assert.Equal(2, await At(Utc(19, 12)));
        Assert.Equal(2, await At(Utc(22, 8, 59)));
        Assert.Equal(3, await At(Utc(22, 9)));
        Assert.Equal(3, await At(Utc(29, 10)));
        Assert.Equal(0, await c.ExecuteScalarAsync<int>("SELECT ReminderCount FROM ntf.Notification WHERE NotificationId = @second;", new { second }));
    }

    private sealed class FixedClock(DateTime utc) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(DateTime.SpecifyKind(utc, DateTimeKind.Utc));
    }
}
