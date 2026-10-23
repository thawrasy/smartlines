using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text.Json;
using BankFas.Data.Facilities;

namespace BankFas.IntegrationTests;

/// <summary>
/// The limit tree, the availability and the reservation core (S2 brief batch S2-C): AC-FAC-1 through the API (shared
/// caps of 95%, a limit outside the total, fifteen lines, a sub-limit above its parent refused, partitions 30/10 with a
/// warning and 30/20 refused), the approval of a revision that changes the tree with a utilisation on it (S2-GAP-2: the
/// tree copied into the draft and the utilisation moved to the new rows), the S2 part of AC-FAC-2 (4M, 3M reserved
/// leaves 1M, 2M refused, P/C1/C2 with the binding node, two concurrent 3M on 4M, the same request twice), AC-FAC-12
/// (100 concurrent reservations of 100,000 on 4,000,000: 40 made, 60 refused), and FR-FAC-009 (87.82%, flagged).
/// </summary>
[Collection("database")]
public sealed class LimitTests(PlatformFixture f)
{
    private static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private DateTime Today => f.Env.Clock.GetUtcNow().UtcDateTime.Date;

    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-FAC-05", "V-FAC-08"];

    /// <summary>A query in the tenant on a bound connection of the job login (the row filters apply to every login, sa included).</summary>
    private async Task<List<T>> QueryAsync<T>(int tenantId, string sql, object? args = null)
    {
        var ct = TestContext.Current.CancellationToken;
        await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-FAC-VALIDITY", Guid.NewGuid(), ct);
        return [.. await Dapper.SqlMapper.QueryAsync<T>(c, sql, args)];
    }

    private sealed record Setup(HttpClient Tm, HttpClient Fo, string Company, string Company2, string Bank, string Tenant, string Facility);

    private async Task<Setup> SetupAsync(decimal total)
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var co = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var co2 = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C2", nameAr = "شركة الثانية", nameEn = "Second", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = co, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = total, effectiveFrom = D(Today.AddMonths(-1)), expiryDate = D(Today.AddMonths(11)),
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        return new Setup(tm, fo, co, co2, bank, t.Code, fac);
    }

    private static async Task<string> LimitAsync(HttpClient c, string fac, string code, string type, object amount, string? parent = null, string? mode = null) =>
        (await c.PostOkAsync($"/api/v1/facilities/{fac}/limits", amount switch
        {
            decimal a => (object)new { code, limitType = type, nameAr = code, parent, amount = a, distributionMode = mode, noSourceReason = "Entered from the agreement" },
            _ => new { code, limitType = type, nameAr = code, parent, pctOfParent = (int)amount, distributionMode = mode, noSourceReason = "Entered from the agreement" },
        })).GetProperty("id").GetString()!;

    private static async Task<string> OpenRevisionAsync(HttpClient c, string fac) =>
        (await c.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;

    private static async Task ApproveAsync(Setup s, string rev)
    {
        await s.Fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{s.Facility}/revisions/{rev}/actions/submit", new { });
        await s.Tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{s.Facility}/revisions/{rev}/actions/approve", new { acknowledge = Ack });
    }

    private static Dictionary<string, JsonElement> ByCode(JsonElement tree) =>
        tree.GetProperty("limits").EnumerateArray().ToDictionary(l => l.GetProperty("limit").GetProperty("code").GetString()!, l => l);

    private static async Task<List<string>> ErrorsAsync(HttpClient c, string fac, string rev) =>
        [.. (await c.GetJsonAsync($"/api/v1/facilities/{fac}/revisions/{rev}/check")).GetProperty("errors").EnumerateArray().Select(e => e.GetProperty("code").GetString()!)];

    [Fact]
    public async Task AC_FAC_1_the_tree_by_distribution_mode_and_an_approval_that_moves_a_utilisation()
    {
        var s = await SetupAsync(45_000_000);
        var ct = TestContext.Current.CancellationToken;
        var l0 = await LimitAsync(s.Fo, s.Facility, "L0", "TOTAL_FACILITY", 45_000_000m);
        var l1 = await LimitAsync(s.Fo, s.Facility, "L1", "DOCUMENTARY_CREDITS", 95, l0);
        var l2 = await LimitAsync(s.Fo, s.Facility, "L2", "GUARANTEES", 95, l0);
        await LimitAsync(s.Fo, s.Facility, "L3", "FX_LIMIT", 1_500_000m, l0, "OUTSIDE_TOTAL");
        Assert.Equal((422, "V-FAC-SOURCE"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{s.Facility}/limits", new { code = "L9", limitType = "GUARANTEES", nameAr = "L9", parent = l0, amount = 1 }));
        string? firstLine = null;
        for (var i = 1; i <= 15; i++)
        {
            var id = (await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/limits/{l1}/lines", new
            {
                product = "LC_PURCHASE_CONV", bankProductCode = $"P{i}", amount = 40_000_000, noSourceReason = "Entered from the agreement",
            })).GetProperty("id").GetString()!;
            firstLine ??= id;
        }
        var rev = await OpenRevisionAsync(s.Fo, s.Facility);
        var draft = await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits?view=draft");
        var codes = ByCode(draft);
        Assert.Equal(42_750_000m, codes["L1"].GetProperty("limit").GetProperty("cap").GetDecimal());
        Assert.Equal(42_750_000m, codes["L2"].GetProperty("limit").GetProperty("cap").GetDecimal());
        Assert.Equal((45_000_000m, 1_500_000m), (draft.GetProperty("total").GetDecimal(), draft.GetProperty("outsideTotal").GetDecimal()));
        Assert.Equal(15, codes["L1"].GetProperty("lines").GetArrayLength());
        Assert.Empty(await ErrorsAsync(s.Fo, s.Facility, rev));
        await ApproveAsync(s, rev);

        // A manual utilisation of 5M on the first line; the approved tree shows it.
        var util = (await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/utilizations", new
        {
            line = firstLine, company = s.Company, reference = "LC-001", amount = 5_000_000,
        })).GetProperty("id").GetString()!;
        var tree = ByCode(await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits"));
        Assert.Equal(5_000_000m, tree["L1"].GetProperty("use").GetProperty("used").GetDecimal());
        Assert.Equal(37_750_000m, tree["L1"].GetProperty("use").GetProperty("avail").GetDecimal());
        Assert.Equal(5_000_000m, tree["L0"].GetProperty("use").GetProperty("used").GetDecimal());

        // A correction: L2 at an absolute 46M is refused (V-FAC-04); partitions 30/10 pass with a warning, 30/20 do not.
        var corr = (await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/revisions", new { reasonKind = "CORRECTION" })).GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{s.Facility}/limits/{l2}", new { amountBasis = "ABSOLUTE", amount = 46_000_000 })).StatusCode);
        Assert.Contains("V-FAC-04", await ErrorsAsync(s.Fo, s.Facility, corr));
        Assert.Equal((422, "V-FAC-INTEGRITY"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{s.Facility}/revisions/{corr}/actions/submit", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{s.Facility}/limits/{l1}", new { amountBasis = "ABSOLUTE", amount = 30_000_000, distributionMode = "PARTITION" })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{s.Facility}/limits/{l2}", new { amount = 20_000_000, distributionMode = "PARTITION" })).StatusCode);
        Assert.Contains("V-FAC-05", await ErrorsAsync(s.Fo, s.Facility, corr));
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{s.Facility}/limits/{l2}", new { amount = 10_000_000 })).StatusCode);
        // The 15 lines of 40M are now above L1's 30M.
        Assert.Contains("V-FAC-08", await ErrorsAsync(s.Fo, s.Facility, corr));
        foreach (var line in ByCode(await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits?view=draft"))["L1"].GetProperty("lines").EnumerateArray())
            Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{s.Facility}/lines/{line.GetProperty("id").GetString()}", new { amount = 30_000_000 })).StatusCode);
        var check = await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/revisions/{corr}/check");
        Assert.Empty(check.GetProperty("errors").EnumerateArray());
        Assert.Contains(check.GetProperty("warnings").EnumerateArray(), w => w.GetProperty("code").GetString() == "V-FAC-05" && w.GetProperty("message").GetString()!.StartsWith("5,000,000.00", StringComparison.Ordinal));
        // The approved tree is unchanged while the draft is edited; the approval moves the utilisation to the new rows.
        Assert.Equal(42_750_000m, ByCode(await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits"))["L1"].GetProperty("limit").GetProperty("cap").GetDecimal());
        await ApproveAsync(s, corr);
        tree = ByCode(await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits"));
        Assert.Equal((30_000_000m, 25_000_000m), (tree["L1"].GetProperty("limit").GetProperty("cap").GetDecimal(), tree["L1"].GetProperty("use").GetProperty("avail").GetDecimal()));
        var tenantId = await TestEnvironment.TenantIdAsync(s.Tenant);
        var link = (await QueryAsync<(int From, int? To)>(tenantId,
            "SELECT l.FromRevision, l.ToRevision FROM fac.Utilization AS u JOIN fac.Limit AS l ON l.LimitId = u.LimitId WHERE u.PublicId = @u;", new { u = Guid.Parse(util) })).Single();
        Assert.Equal((2, (int?)null), link);

        // A limit carrying a utilisation is not closed.
        var again = (await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/revisions", new { reasonKind = "CORRECTION" })).GetProperty("id").GetString()!;
        var lines = ByCode(await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits?view=draft"))["L1"].GetProperty("lines").EnumerateArray().ToList();
        foreach (var line in lines)
            Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Delete, $"/api/v1/facilities/{s.Facility}/lines/{line.GetProperty("id").GetString()}")).StatusCode);
        Assert.Contains("V-FAC-IN-USE", await ErrorsAsync(s.Fo, s.Facility, again));
        await s.Fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{s.Facility}/revisions/{again}/actions/discard", new { });
        Assert.Equal(15, ByCode(await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits"))["L1"].GetProperty("lines").GetArrayLength());
        _ = ct;
    }

    /// <summary>One limit of 10M with 6M used on an approved facility; returns the limit's reference and root.</summary>
    private async Task<(Setup S, string Limit, long Root)> TenMillionAsync()
    {
        var s = await SetupAsync(10_000_000);
        var lc = await LimitAsync(s.Fo, s.Facility, "LC", "TOTAL_FACILITY", 10_000_000m);
        await ApproveAsync(s, await OpenRevisionAsync(s.Fo, s.Facility));
        await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/utilizations", new { limit = lc, company = s.Company, reference = "MAN-1", amount = 6_000_000 });
        var tenantId = await TestEnvironment.TenantIdAsync(s.Tenant);
        var root = (await QueryAsync<long>(tenantId, "SELECT l.RootId FROM fac.Limit AS l JOIN fac.Facility AS x ON x.FacilityId = l.FacilityId WHERE x.PublicId = @f AND l.Code = 'LC';",
            new { f = Guid.Parse(s.Facility) })).Single();
        return (s, lc, root);
    }

    /// <summary>Requests to reserve for (S2-GAP-5): a request type, a template and a phase, and the requests themselves, as sa in the tenant.</summary>
    private async Task<(List<long> Requests, long Company, long User)> RequestsAsync(int tenantId, string company, int n) =>
        await QueryAsync<(long, long, long)>(tenantId,
            """
            DECLARE @co BIGINT = (SELECT CompanyId FROM org.Company WHERE PublicId = @c);
            DECLARE @u BIGINT = (SELECT TOP (1) AppUserId FROM sec.AppUser WHERE IsSystemUser = 0 ORDER BY AppUserId);
            IF NOT EXISTS (SELECT 1 FROM wfl.RequestType WHERE Code = 'IT_FIXTURE')
            BEGIN
                INSERT wfl.RequestType (TenantId, Code, NameAr, NameEn, Category, NumberSequenceKey, ConsumesCreditLimit, IsActive)
                VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'IT_FIXTURE', N'طلب اختبار', 'Test request', 'GENERAL', 'req:IT_FIXTURE', 1, 1);
                INSERT wfl.WorkflowTemplate (TenantId, RequestTypeId, TemplateKey, VersionNo, NameEn)
                SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), RequestTypeId, 'IT_FIXTURE', 1, 'Test template' FROM wfl.RequestType WHERE Code = 'IT_FIXTURE';
                INSERT wfl.ExternalPhase (TenantId, Code, NameAr) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'IT_FIXTURE', N'مرحلة الاختبار');
            END;
            DECLARE @o TABLE (Id BIGINT);
            INSERT wfl.Request (TenantId, DraftRef, RequestTypeId, TemplateId, CompanyId, RequesterUserId, CreatedByUserId, ExternalPhaseId, CurrencyId)
            OUTPUT inserted.RequestId INTO @o
            SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), LEFT(CONCAT('D-', REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', '')), 20), t.RequestTypeId, w.WorkflowTemplateId, @co, @u, @u, p.ExternalPhaseId, (SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR')
              FROM (SELECT TOP (@n) 1 AS x FROM sys.all_objects) AS k
              CROSS JOIN wfl.RequestType AS t JOIN wfl.WorkflowTemplate AS w ON w.RequestTypeId = t.RequestTypeId CROSS JOIN wfl.ExternalPhase AS p
             WHERE t.Code = 'IT_FIXTURE' AND p.Code = 'IT_FIXTURE';
            SELECT Id, @co, @u FROM @o ORDER BY Id;
            """, new { c = Guid.Parse(company), n }) is var rows ? (rows.Select(r => r.Item1).ToList(), rows[0].Item2, rows[0].Item3) : default;

    private async Task<ReserveResult> ReserveAsync(int tenantId, ReserveCommand cmd)
    {
        var ct = TestContext.Current.CancellationToken;
        for (var attempt = 0; ; attempt++)
        {
            await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-FAC-VALIDITY", Guid.NewGuid(), ct);
            await using var tx = (Microsoft.Data.SqlClient.SqlTransaction)await c.BeginTransactionAsync(System.Data.IsolationLevel.ReadCommitted, ct);
            var r = await ReservationService.ReserveAsync(c, tx, cmd, Today, ct);
            await tx.CommitAsync(ct);
            // A caller retries CONCURRENT_RETRY (DQ-F11-2).
            if (r.Outcome != "CONCURRENT_RETRY" || attempt >= 20) return r;
        }
    }

    private async Task<int> SarAsync(int tenantId) =>
        (await QueryAsync<int>(tenantId, "SELECT CurrencyId FROM ref.Currency WHERE Code = 'SAR';")).Single();

    [Fact]
    public async Task AC_FAC_2_availability_reservation_binding_node_and_two_concurrent_requests()
    {
        var (s, lc, root) = await TenMillionAsync();
        var tenantId = await TestEnvironment.TenantIdAsync(s.Tenant);
        async Task<JsonElement> AvailAsync(string limit) => await s.Tm.GetJsonAsync($"/api/v1/facilities/{s.Facility}/availability?limit={limit}&company={s.Company}");
        var a = await AvailAsync(lc);
        Assert.Equal((10_000_000m, 6_000_000m, 4_000_000m, "VALID"), (a.GetProperty("cap").GetDecimal(), a.GetProperty("used").GetDecimal(), a.GetProperty("avail").GetDecimal(),
            a.GetProperty("validityIndicator").GetString()));

        var (requests, company, user) = await RequestsAsync(tenantId, s.Company, 4);
        var sar = await SarAsync(tenantId);
        ReserveCommand Cmd(long request, decimal amount) => new(request, root, null, company, amount, sar, null, null, user);
        var r1 = await ReserveAsync(tenantId, Cmd(requests[0], 3_000_000));
        Assert.True(r1.Reserved);
        Assert.Equal(1_000_000m, (await AvailAsync(lc)).GetProperty("avail").GetDecimal());
        var r2 = await ReserveAsync(tenantId, Cmd(requests[1], 2_000_000));
        Assert.Equal(("INSUFFICIENT_AVAILABLE", 1_000_000m), (r2.Outcome, r2.Availability!.Avail));
        Assert.Equal("OVERRIDE_NOT_ALLOWED", (await ReserveAsync(tenantId, Cmd(requests[1], 2_000_000) with { OverrideRequested = true, OverrideReason = "Urgent" })).Outcome);

        // The same request again: the same reservation, no second one and no movement; a new amount adjusts it.
        var again = await ReserveAsync(tenantId, Cmd(requests[0], 3_000_000));
        Assert.Equal(r1.ReservationId, again.ReservationId);
        var adjusted = await ReserveAsync(tenantId, Cmd(requests[0], 2_500_000));
        Assert.Equal(r1.ReservationId, adjusted.ReservationId);
        var counts = (await QueryAsync<(int Active, int Movements, string State)>(tenantId,
            """
            SELECT (SELECT COUNT(*) FROM fac.LimitReservation WHERE RequestId = @q AND Status = 'ACTIVE'), (SELECT COUNT(*) FROM fac.LimitMovement WHERE LimitReservationId = @r),
                   (SELECT ReservationState FROM wfl.Request WHERE RequestId = @q);
            """, new { q = requests[0], r = r1.ReservationId })).Single();
        Assert.Equal((1, 2, "RESERVED"), counts);
        Assert.Equal(1_500_000m, (await AvailAsync(lc)).GetProperty("avail").GetDecimal());

        // Released, the room comes back; two requests of 1.5M at once on 1.5M after a second reservation of 0: exactly one succeeds.
        await using (var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, TestContext.Current.CancellationToken))
        {
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-FAC-VALIDITY", Guid.NewGuid(), TestContext.Current.CancellationToken);
            await using var tx = (Microsoft.Data.SqlClient.SqlTransaction)await c.BeginTransactionAsync(TestContext.Current.CancellationToken);
            Assert.True(await ReservationService.ReleaseAsync(c, tx, r1.ReservationId!.Value, "CANCELLED", user, Today, TestContext.Current.CancellationToken));
            Assert.False(await ReservationService.ReleaseAsync(c, tx, r1.ReservationId!.Value, "CANCELLED", user, Today, TestContext.Current.CancellationToken));
            await tx.CommitAsync(TestContext.Current.CancellationToken);
        }
        Assert.Equal(4_000_000m, (await AvailAsync(lc)).GetProperty("avail").GetDecimal());
        var both = await Task.WhenAll(ReserveAsync(tenantId, Cmd(requests[2], 3_000_000)), ReserveAsync(tenantId, Cmd(requests[3], 3_000_000)));
        Assert.Equal(1, both.Count(r => r.Reserved));
        Assert.Equal(1, both.Count(r => r.Outcome == "INSUFFICIENT_AVAILABLE"));
        // A request released then reserved again gets a new reservation with a derived key.
        var renewed = await ReserveAsync(tenantId, Cmd(requests[0], 500_000));
        Assert.True(renewed.Reserved);
        Assert.NotEqual(r1.ReservationId, renewed.ReservationId);
    }

    [Fact]
    public async Task AC_FAC_2_shared_caps_P_C1_C2_and_the_binding_node()
    {
        var s = await SetupAsync(10_000_000);
        var p = await LimitAsync(s.Fo, s.Facility, "P", "TOTAL_FACILITY", 10_000_000m);
        var c1 = await LimitAsync(s.Fo, s.Facility, "C1", "DOCUMENTARY_CREDITS", 8_000_000m, p);
        var c2 = await LimitAsync(s.Fo, s.Facility, "C2", "GUARANTEES", 6_000_000m, p);
        await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/limits/{c1}/company-rules", new { company = s.Company2, ruleKind = "EXCLUDED", noSourceReason = "Agreement clause 4" });
        await ApproveAsync(s, await OpenRevisionAsync(s.Fo, s.Facility));
        await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/utilizations", new { limit = c1, company = s.Company, reference = "U-1", amount = 2_000_000 });
        await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/utilizations", new { limit = c2, company = s.Company, reference = "U-2", amount = 5_000_000 });
        Assert.Equal((422, "COMPANY_EXCLUDED"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{s.Facility}/utilizations", new { limit = c1, company = s.Company2, reference = "U-3", amount = 1 }));
        async Task<(decimal, string, string?)> At(string limit, string company)
        {
            var a = await s.Tm.GetJsonAsync($"/api/v1/facilities/{s.Facility}/availability?limit={limit}&company={company}");
            return (a.GetProperty("avail").GetDecimal(), a.GetProperty("bindingNode").GetString()!, a.GetProperty("reason").GetString());
        }
        Assert.Equal((3_000_000m, "P", null), await At(c1, s.Company));
        Assert.Equal((1_000_000m, "C2", null), await At(c2, s.Company));
        Assert.Equal((0m, "C1", "COMPANY_EXCLUDED"), await At(c1, s.Company2));
        Assert.Equal(7_000_000m, ByCode(await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits"))["P"].GetProperty("use").GetProperty("used").GetDecimal());

        // An adjustment and a release, each with its reason; a released utilisation is final.
        var utils = (await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/utilizations")).GetProperty("items").EnumerateArray().ToList();
        var u2 = utils.Single(u => u.GetProperty("reference").GetString() == "U-2").GetProperty("id").GetString()!;
        Assert.Equal((422, "VALIDATION_FAILED"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{s.Facility}/utilizations/{u2}/actions/adjust", new { delta = -1_000_000 }));
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Post, $"/api/v1/facilities/{s.Facility}/utilizations/{u2}/actions/adjust", new { delta = -1_000_000, reason = "Partly repaid" })).StatusCode);
        Assert.Equal((2_000_000m, "C2", null), await At(c2, s.Company));
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Post, $"/api/v1/facilities/{s.Facility}/utilizations/{u2}/actions/release", new { reason = "Repaid" })).StatusCode);
        Assert.Equal((409, "V-FAC-UTIL-FINAL"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{s.Facility}/utilizations/{u2}/actions/adjust", new { delta = 1, reason = "x" }));
        Assert.Equal((6_000_000m, "C2", null), await At(c2, s.Company));
    }

    [Fact]
    public async Task AC_FAC_12_one_hundred_concurrent_reservations_on_four_million()
    {
        var (s, _, root) = await TenMillionAsync();
        var tenantId = await TestEnvironment.TenantIdAsync(s.Tenant);
        var (requests, company, user) = await RequestsAsync(tenantId, s.Company, 100);
        var sar = await SarAsync(tenantId);
        var watch = Stopwatch.StartNew();
        var results = await Task.WhenAll(requests.Select(q => Task.Run(() => ReserveAsync(tenantId, new ReserveCommand(q, root, null, company, 100_000, sar, null, null, user)))));
        watch.Stop();
        Assert.Equal(40, results.Count(r => r.Reserved));
        Assert.Equal(60, results.Count(r => r.Outcome == "INSUFFICIENT_AVAILABLE"));
        var totals = (await QueryAsync<(decimal Sum, int Count, int Movements)>(tenantId,
            """
            SELECT ISNULL(SUM(r.Amount), 0), COUNT(*), (SELECT COUNT(*) FROM fac.LimitMovement AS m JOIN fac.LimitReservation AS x ON x.LimitReservationId = m.LimitReservationId
                                                          WHERE x.FacilityId = (SELECT FacilityId FROM fac.Facility WHERE PublicId = @f))
              FROM fac.LimitReservation AS r WHERE r.Status = 'ACTIVE' AND r.FacilityId = (SELECT FacilityId FROM fac.Facility WHERE PublicId = @f);
            """, new { f = Guid.Parse(s.Facility) })).Single();
        Assert.Equal((4_000_000m, 40, 40), totals);
        // Run again with the same requests: nothing changes.
        var rerun = await Task.WhenAll(requests.Select(q => Task.Run(() => ReserveAsync(tenantId, new ReserveCommand(q, root, null, company, 100_000, sar, null, null, user)))));
        Assert.Equal(40, rerun.Count(r => r.Reserved));
        var after = (await QueryAsync<(decimal Sum, int Count)>(tenantId,
            "SELECT ISNULL(SUM(Amount), 0), COUNT(*) FROM fac.LimitReservation WHERE Status = 'ACTIVE' AND FacilityId = (SELECT FacilityId FROM fac.Facility WHERE PublicId = @f);",
            new { f = Guid.Parse(s.Facility) })).Single();
        Assert.Equal((4_000_000m, 40), after);
        Assert.True(watch.Elapsed < TimeSpan.FromSeconds(60), $"100 reservations took {watch.Elapsed}.");
    }

    [Fact]
    public async Task FR_FAC_009_a_recognised_balance_and_its_flag()
    {
        var s = await SetupAsync(45_000_000);
        var l0 = await LimitAsync(s.Fo, s.Facility, "L0", "TOTAL_FACILITY", 45_000_000m);
        await ApproveAsync(s, await OpenRevisionAsync(s.Fo, s.Facility));
        await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/snapshots", new
        {
            limit = l0, asOfDate = D(Today), acknowledgedAmount = 39_520_000, sourceKind = "RENEWAL_ACKNOWLEDGEMENT", statedPct = 87.83, noSourceReason = "Bank letter not yet scanned",
        });
        var snap = (await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/snapshots")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal((87.82m, true, 39_520_000m), (snap.GetProperty("ackPct").GetDecimal(), snap.GetProperty("flagged").GetBoolean(), snap.GetProperty("variance").GetDecimal()));
    }

    [Fact]
    public async Task NFR_PERF_01_the_card_of_a_facility_with_100_limits_and_lines()
    {
        // FR-FAC-028: twenty limits with four lines each under one total (101 nodes); each read of the card is timed ten times against 2 s.
        var s = await SetupAsync(100_000_000);
        var l0 = await LimitAsync(s.Fo, s.Facility, "L0", "TOTAL_FACILITY", 100_000_000m);
        for (var i = 1; i <= 20; i++)
        {
            var l = await LimitAsync(s.Fo, s.Facility, $"L{i}", "DOCUMENTARY_CREDITS", 95, l0);
            for (var j = 1; j <= 4; j++)
                await s.Fo.PostOkAsync($"/api/v1/facilities/{s.Facility}/limits/{l}/lines", new
                {
                    product = "LC_PURCHASE_CONV", bankProductCode = $"P{i}-{j}", amount = 50_000_000, noSourceReason = "Entered from the agreement",
                });
        }
        await ApproveAsync(s, await OpenRevisionAsync(s.Fo, s.Facility));
        var tree = await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}/limits");
        Assert.Equal(21, tree.GetProperty("limits").GetArrayLength());
        foreach (var path in new[] { "", "/limits", "/pricing-rules", "/obligations", "/agenda", "/terms", "/collateral-links", "/compliance" })
        {
            await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}{path}");
            var worst = TimeSpan.Zero;
            for (var k = 0; k < 10; k++)
            {
                var watch = Stopwatch.StartNew();
                await s.Fo.GetJsonAsync($"/api/v1/facilities/{s.Facility}{path}");
                worst = watch.Elapsed > worst ? watch.Elapsed : worst;
            }
            TestContext.Current.TestOutputHelper?.WriteLine($"NFR-PERF-01 /facilities/{{id}}{path}: worst of 10 {worst.TotalMilliseconds:F0} ms");
            Assert.True(worst < TimeSpan.FromSeconds(2), $"{path} took {worst}.");
        }
    }
}
