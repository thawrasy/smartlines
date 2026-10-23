using System.Net;
using System.Text.Json;
using BankFas.Data.Finance;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// The covenant tests and the verification engine (S2-b brief batch S2B-E): the quarterly calendar from a December year
/// end (31/3, 30/6, 30/9, 31/12); PENDING_DATA before the due date and MISSING_DATA with FIN.DATA_MISSING after it
/// (OQ-15); BR-FIN-011 (1.1996 against 1.20 is a breach, stored as 1.1996) with its breach opened from the
/// statement.approved consumer; a restated statement re-evaluates as a new row and marks the open breach NeedsReview,
/// never closing it (BR-OBL-011, FR-FIN-014); BR-FIN-007 (18,700,000 against 20,000,000 is a breach with 1,300,000 to
/// go); BR-FIN-005 (each month 620, 480 and 700 thousand against 500 thousand: 480 thousand, a breach of 4%); a value
/// entered by hand with its evidence; the review of an evaluation; the snapshot names the formula version and its inputs.
/// </summary>
[Collection("database")]
public sealed class CovenantEngineTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];

    [Fact]
    public async Task Tests_are_scheduled_evaluated_and_breaches_follow_the_results()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        var account = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new
        {
            company, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "900-1", openedOn = "2025-01-01", createRelationship = true,
        }));
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 40_000_000, effectiveFrom = "2025-01-01", expiryDate = "2027-12-31",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 40_000_000, noSourceReason = "Clause 1" });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "CURRENT_RATIO", titleAr = "نسبة التداول", noSourceReason = "Clause 15",
            covenant = new { measureKind = "RATIO", formula = "CURRENT_RATIO", thresholdState = "SET", @operator = "GE", thresholdValue = 1.20, testFrequency = "QUARTERLY" },
        });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "MIN_INFLOW", titleAr = "تحويل التدفقات", noSourceReason = "Clause 9",
            covenant = new { measureKind = "FLOW_VOLUME", thresholdState = "SET", @operator = "GE", thresholdValue = 20_000_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "ANNUAL" },
        });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "MIN_AVG_BALANCE", titleAr = "متوسط الرصيد", noSourceReason = "Clause 10",
            covenant = new
            {
                measureKind = "AVERAGE_BALANCE", thresholdState = "SET", @operator = "GE", thresholdValue = 500_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "QUARTERLY",
                aggregationMode = "EACH_MONTH_MIN",
            },
        });
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });

        async Task<List<JsonElement>> TestsAsync(string title) => [.. (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/covenant-tests")).GetProperty("items").EnumerateArray()
            .Where(x => x.GetProperty("obligationTitleAr").GetString() == title)];
        JsonElement Period(List<JsonElement> tests, string end) => tests.Single(x => x.GetProperty("periodEnd").GetString() == end);

        // The quarterly calendar from a December year end, to the facility's expiry; the due date 30 days after the period.
        var ratio = await TestsAsync("نسبة التداول");
        Assert.Equal(["2025-03-31", "2025-06-30", "2025-09-30", "2025-12-31"], ratio.Take(4).Select(x => x.GetProperty("periodEnd").GetString()));
        Assert.Equal(12, ratio.Count);
        Assert.Equal("2025-04-30", ratio[0].GetProperty("dueDate").GetString());
        Assert.Equal(3, (await TestsAsync("تحويل التدفقات")).Count);

        // OQ-15: PENDING_DATA before the due date, MISSING_DATA with FIN.DATA_MISSING the day after it.
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        async Task DrainAsync() { while (await outbox.RunOnceAsync(ct) > 0) { } }
        await new FinanceEvaluationJob(f.Env.Db, new DayClock(new DateTime(2025, 4, 15))).RunOnceAsync(ct);
        Assert.Equal("PENDING_DATA", Period(await TestsAsync("نسبة التداول"), "2025-03-31").GetProperty("state").GetString());
        await new FinanceEvaluationJob(f.Env.Db, new DayClock(new DateTime(2025, 5, 1))).RunOnceAsync(ct);
        var q1 = Period(await TestsAsync("نسبة التداول"), "2025-03-31");
        Assert.Equal(("EVALUATED", "MISSING_DATA"), (q1.GetProperty("state").GetString(), q1.GetProperty("result").GetString()));
        await DrainAsync();
        Assert.Contains((await fo.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(), n => n.GetProperty("eventCode").GetString() == "FIN.DATA_MISSING");

        // BR-FIN-011: 11,996 / 10,000 = 1.1996 against 1.20 is a breach; the statement's approval evaluates the test.
        var lines = new Dictionary<string, decimal>(StatementTests.Balanced) { ["CASH"] = 5_996, ["AR"] = 4_000, ["INVENTORY"] = 2_000, ["ST_LOANS"] = 6_000, ["CURRENT_PORTION_LTD"] = 2_000, ["AP"] = 2_000 };
        var st = await StatementTests.StatementAsync(fo, company, new { periodType = "QUARTERLY", periodEnd = "2025-12-31" });
        await StatementTests.SaveAsync(fo, st, lines);
        await fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { balanceReason = "Quarterly figures" });
        await tm.PostOkAsync($"/api/v1/financial-statements/{st}/actions/approve", new { });
        await DrainAsync();
        var q4 = Period(await TestsAsync("نسبة التداول"), "2025-12-31");
        Assert.Equal(("BREACH", 1.1996m, 1.20m), (q4.GetProperty("result").GetString(), q4.GetProperty("actualValue").GetDecimal(), q4.GetProperty("threshold").GetDecimal()));
        var detail = await tm.GetJsonAsync($"/api/v1/covenant-tests/{q4.GetProperty("id").GetString()}");
        var inputs = detail.GetProperty("test").GetProperty("inputs");
        Assert.Equal(("CURRENT_RATIO", 1), (inputs.GetProperty("formula").GetProperty("code").GetString(), inputs.GetProperty("statements").GetArrayLength()));
        Assert.Equal(11_996_000m, inputs.GetProperty("inputs").GetProperty("TOTAL_CA").GetDecimal());
        Assert.Equal(("OPEN", false), (detail.GetProperty("breach").GetProperty("status").GetString(), detail.GetProperty("breach").GetProperty("needsReview").GetBoolean()));

        // FR-FIN-014: the restated statement re-evaluates as a new row; the open breach is marked for review, not closed.
        var v2 = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/new-version", new { reason = "RESTATED" }));
        await StatementTests.SaveAsync(fo, v2, new Dictionary<string, decimal> { ["CASH"] = 6_500 });
        await fo.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/submit", new { balanceReason = "Quarterly figures" });
        await tm.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/approve", new { });
        await DrainAsync();
        q4 = Period(await TestsAsync("نسبة التداول"), "2025-12-31");
        Assert.Equal((2, "WARNING"), (q4.GetProperty("evaluationNo").GetInt32(), q4.GetProperty("result").GetString()));
        detail = await tm.GetJsonAsync($"/api/v1/covenant-tests/{q4.GetProperty("id").GetString()}");
        Assert.Equal(("OPEN", true), (detail.GetProperty("breach").GetProperty("status").GetString(), detail.GetProperty("breach").GetProperty("needsReview").GetBoolean()));
        Assert.Equal(["BREACH", "WARNING"], detail.GetProperty("history").EnumerateArray().Select(h => h.GetProperty("result").GetString()));
        // R-FIN-05: the latest evaluation on the statements, an early warning on the restated version, its breach marked for review.
        var report = (await tm.GetJsonAsync($"/api/v1/reports/statement-breaches?company={company}")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal(("EARLY_WARNING", 2, true), (report.GetProperty("severity").GetString(), report.GetProperty("statementVersion").GetInt32(), report.GetProperty("needsReview").GetBoolean()));

        // BR-FIN-007: 18,700,000 routed in 2025 against 20,000,000 is a breach with 1,300,000 to go.
        var flow = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/bank-flows", new { company, institution = bank, facility = fac, month = "2025-06", amount = 18_700_000, currency = "SAR" }));
        await tm.PostOkAsync("/api/v1/bank-flows/actions/confirm", new { ids = new[] { flow } });
        var annual = Period(await TestsAsync("تحويل التدفقات"), "2025-12-31").GetProperty("id").GetString()!;
        Assert.Equal((403, "FORBIDDEN"), await (await f.UserWithRoleAsync(t, "TE")).Client.PostProblemAsync($"/api/v1/covenant-tests/{annual}/actions/evaluate", new { }));
        var flowTest = (await tm.PostOkAsync($"/api/v1/covenant-tests/{annual}/actions/evaluate", new { })).GetProperty("test");
        Assert.Equal(("BREACH", 18_700_000m, -1_300_000m), (flowTest.GetProperty("result").GetString(), flowTest.GetProperty("actualValue").GetDecimal(), flowTest.GetProperty("headroom").GetDecimal()));
        Assert.Equal(1, flowTest.GetProperty("inputs").GetProperty("flows").GetArrayLength());
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/covenant-tests/{annual}/actions/review", new { note = "The bank was told of the shortfall." })).StatusCode);
        Assert.Equal((409, "TEST_STATE"), await fo.PostProblemAsync($"/api/v1/covenant-tests/{annual}/actions/review", new { note = "Again" }));

        // BR-FIN-005: each month of the third quarter (620, 480 and 700 thousand) against 500 thousand: 480 thousand, a breach of 4%.
        await fo.OkAsync(HttpMethod.Put, "/api/v1/account-stats", new
        {
            items = new[]
            {
                new { account, month = "2025-07", avgDailyBalance = 620_000 }, new { account, month = "2025-08", avgDailyBalance = 480_000 }, new { account, month = "2025-09", avgDailyBalance = 700_000 },
            },
        });
        var cells = (await tm.GetJsonAsync($"/api/v1/account-stats?company={company}&from=2025-07&to=2025-09")).GetProperty("accounts")[0].GetProperty("cells").EnumerateArray()
            .Select(c => c.GetProperty("id").GetString()!).ToArray();
        await tm.PostOkAsync("/api/v1/account-stats/actions/confirm", new { ids = cells });
        var q3 = Period(await TestsAsync("متوسط الرصيد"), "2025-09-30").GetProperty("id").GetString()!;
        var balance = (await tm.PostOkAsync($"/api/v1/covenant-tests/{q3}/actions/evaluate", new { })).GetProperty("test");
        Assert.Equal(("BREACH", 480_000m, -4m), (balance.GetProperty("result").GetString(), balance.GetProperty("actualValue").GetDecimal(), balance.GetProperty("headroomPct").GetDecimal()));
        Assert.Equal(3, balance.GetProperty("inputs").GetProperty("accounts").GetArrayLength());

        // A value entered by hand with its evidence document, judged on the covenant's threshold.
        var up = await CompanyDocumentTests.UploadAsync(fo, "/api/v1/documents", CompanyDocumentTests.Pdf("Q2 ratio"), "q2.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "FACILITY_ADDENDUM", ["title"] = "Q2 ratio", ["company"] = company,
        });
        var evidence = JsonDocument.Parse(await up.Content.ReadAsStringAsync(ct)).RootElement.GetProperty("id").GetString()!;
        var q2 = Period(await TestsAsync("نسبة التداول"), "2025-06-30").GetProperty("id").GetString()!;
        Assert.Equal((422, "VALIDATION_FAILED"), await tm.PostProblemAsync($"/api/v1/covenant-tests/{q2}/actions/manual-value", new { value = 1.5 }));
        var manual = (await tm.PostOkAsync($"/api/v1/covenant-tests/{q2}/actions/manual-value", new { value = 1.5, evidence })).GetProperty("test");
        Assert.Equal(("COMPLIANT", "MANUAL_VALUE"), (manual.GetProperty("result").GetString(), manual.GetProperty("method").GetString()));
    }
}
