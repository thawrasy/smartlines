using System.Net;
using System.Text.Json;
using BankFas.Data.Finance;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// AC-FAC-7 (spec 12:762; S2-b brief batch S2B-H), one test per Given, through the API on a facility built in the test:
/// the current ratio on audited standalone statements, its waiver, its restatement; the average balance by each month
/// and by the period average; the share of revenue; a covenant with no threshold; the data due after the period's lag;
/// the preparer who does not approve their own statement.
/// </summary>
[Collection("database")]
public sealed class AcFac7Tests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];

    private sealed record Fx(TestTenant Tenant, HttpClient Tm, HttpClient Fo, string Company, string Bank, string Account, string Facility);

    /// <summary>A company with an account at one bank, and its approved facility with the given covenants.</summary>
    private async Task<Fx> SetupAsync(string from, string to, params object[] covenants)
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C7", nameAr = "شركة الاختبار", nameEn = "Test Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK7", refCode = "BNG", nameAr = "بنك الاختبار", nameEn = "Test Bank", type = "BANK", country = "SA" }));
        var account = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new { company, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "700-1", openedOn = "2024-01-01", createRelationship = true }));
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new { facilityClass = "CAP", borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 40_000_000, effectiveFrom = from, expiryDate = to }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 40_000_000, noSourceReason = "Clause 1" });
        foreach (var c in covenants) await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", c);
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });
        return new Fx(t, tm, fo, company, bank, account, fac);
    }

    private static object Covenant(string type, string title, object covenant) => new { obligationType = type, titleAr = title, noSourceReason = "Clause 15", covenant };

    private static async Task<JsonElement> TestAsync(Fx x, string title, string periodEnd) =>
        (await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/covenant-tests")).GetProperty("items").EnumerateArray()
            .Single(t => t.GetProperty("obligationTitleAr").GetString() == title && t.GetProperty("periodEnd").GetString() == periodEnd);

    private static async Task<JsonElement> EvaluateAsync(Fx x, string title, string periodEnd) =>
        (await x.Tm.PostOkAsync($"/api/v1/covenant-tests/{(await TestAsync(x, title, periodEnd)).GetProperty("id").GetString()}/actions/evaluate", new { })).GetProperty("test");

    /// <summary>The result, the value and the headroom at full precision, its percentage shown with two decimals.</summary>
    private static (string?, decimal, decimal, decimal) Judged(JsonElement t) =>
        (t.GetProperty("result").GetString(), t.GetProperty("actualValue").GetDecimal(), t.GetProperty("headroom").GetDecimal(), Math.Round(t.GetProperty("headroomPct").GetDecimal(), 2));

    private async Task DrainAsync()
    {
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        while (await outbox.RunOnceAsync(TestContext.Current.CancellationToken) > 0) { }
    }

    private const string Ratio = "نسبة التداول";

    /// <summary>CA 12,000,000 over CL 10,500,000 on the audited standalone statement of 2025.</summary>
    private async Task<(Fx X, string Statement)> RatioBreachAsync()
    {
        var x = await SetupAsync("2025-01-01", "2027-12-31", Covenant("CURRENT_RATIO", Ratio,
            new { measureKind = "RATIO", formula = "CURRENT_RATIO", thresholdState = "SET", @operator = "GE", thresholdValue = 1.20, testFrequency = "ANNUAL", requiredAssurance = "AUDITED_ONLY" }));
        var st = await StatementTests.StatementAsync(x.Fo, x.Company, new { assurance = "AUDITED", auditorName = "Auditor (test)", auditOpinion = "UNQUALIFIED" });
        await StatementTests.SaveAsync(x.Fo, st, new Dictionary<string, decimal>(StatementTests.Balanced)
        {
            ["CASH"] = 6_000, ["AR"] = 4_000, ["INVENTORY"] = 2_000, ["ST_LOANS"] = 6_500, ["CURRENT_PORTION_LTD"] = 2_000, ["AP"] = 2_000,
        });
        await x.Fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { balanceReason = "Only the current items matter to this test" });
        await x.Tm.PostOkAsync($"/api/v1/financial-statements/{st}/actions/approve", new { });
        await DrainAsync();
        return (x, st);
    }

    [Fact]
    public async Task Given_a_current_ratio_below_its_threshold_the_test_is_a_breach_and_opens_one()
    {
        var (x, _) = await RatioBreachAsync();
        var t = await EvaluateAsync(x, Ratio, "2025-12-31");
        Assert.Equal(("BREACH", 1.142857m, -0.057143m, -4.76m), Judged(t));
        var detail = await x.Tm.GetJsonAsync($"/api/v1/covenant-tests/{t.GetProperty("id").GetString()}");
        Assert.Contains(detail.GetProperty("breach").GetProperty("status").GetString(), new[] { "OPEN", "IN_CURE" });
        Assert.Equal("RED", (await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/compliance?asOf=2026-02-15")).GetProperty("colour").GetString());
    }

    [Fact]
    public async Task Given_a_waiver_the_breach_is_waived_and_the_test_stays_a_breach()
    {
        var (x, _) = await RatioBreachAsync();
        var t = await EvaluateAsync(x, Ratio, "2025-12-31");
        var id = t.GetProperty("id").GetString();
        var breach = (await x.Tm.GetJsonAsync($"/api/v1/covenant-tests/{id}")).GetProperty("breach").GetProperty("id").GetString();
        // Recorded by the officer with the bank's reference, contact and letter; approved by the manager.
        var contact = PlatformFixture.Id(await x.Tm.PostOkAsync($"/api/v1/institutions/{x.Bank}/contacts", new
        {
            fullNameAr = "مدير العلاقة", fullNameEn = "Relationship manager", contactMethods = new[] { new { kind = "EMAIL", value = "rm@bank.example" } },
        }));
        var up = await CompanyDocumentTests.UploadAsync(x.Fo, "/api/v1/documents", CompanyDocumentTests.Pdf("Waiver"), "waiver.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "FACILITY_ADDENDUM", ["title"] = "Waiver", ["company"] = x.Company,
        });
        var letter = JsonDocument.Parse(await up.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement.GetProperty("id").GetString()!;
        // The tenant's date on the platform's clock (the breach is detected on it; the fixture's tenants are in Asia/Dubai).
        var today = TimeZoneInfo.ConvertTime(f.Env.Clock.Now, TimeZoneInfo.FindSystemTimeZoneById("Asia/Dubai")).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal(HttpStatusCode.NoContent, (await x.Fo.SendAsync(HttpMethod.Post, $"/api/v1/breaches/{breach}/actions/record-waiver",
            new { waiverRef = "W-1", waiverDate = today, bankContact = contact, document = letter })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await x.Tm.SendAsync(HttpMethod.Post, $"/api/v1/breaches/{breach}/actions/approve-waiver", new { })).StatusCode);
        var detail = await x.Tm.GetJsonAsync($"/api/v1/covenant-tests/{id}");
        Assert.Equal(("BREACH", "WAIVED"), (detail.GetProperty("test").GetProperty("result").GetString(), detail.GetProperty("breach").GetProperty("status").GetString()));
        var reasons = (await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/compliance")).GetProperty("reasons").EnumerateArray().Select(r => r.GetProperty("code").GetString()).ToList();
        Assert.DoesNotContain("BREACH_NOT_WAIVED", reasons);
        Assert.DoesNotContain("OPEN_BREACH", reasons);
    }

    [Fact]
    public async Task Given_a_restatement_the_test_is_evaluated_again_and_the_breach_is_marked_for_review()
    {
        // The approval of the first version evaluated the test (statement.approved): a BREACH with its breach.
        var (x, st) = await RatioBreachAsync();
        Assert.Equal((1, "BREACH"), ((await TestAsync(x, Ratio, "2025-12-31")).GetProperty("evaluationNo").GetInt32(), (await TestAsync(x, Ratio, "2025-12-31")).GetProperty("result").GetString()));
        var v2 = PlatformFixture.Id(await x.Fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/new-version", new { reason = "RESTATED" }));
        await StatementTests.SaveAsync(x.Fo, v2, new Dictionary<string, decimal> { ["CASH"] = 6_800 });
        await x.Fo.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/submit", new { balanceReason = "Only the current items matter to this test" });
        await x.Tm.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/approve", new { });
        await DrainAsync();
        var t = await TestAsync(x, Ratio, "2025-12-31");
        Assert.Equal((2, "WARNING", 1.219048m, 1.59m),
            (t.GetProperty("evaluationNo").GetInt32(), t.GetProperty("result").GetString(), t.GetProperty("actualValue").GetDecimal(), Math.Round(t.GetProperty("headroomPct").GetDecimal(), 2)));
        var breach = (await x.Tm.GetJsonAsync($"/api/v1/covenant-tests/{t.GetProperty("id").GetString()}")).GetProperty("breach");
        Assert.True(breach.GetProperty("needsReview").GetBoolean());
        Assert.Contains(breach.GetProperty("status").GetString(), new[] { "OPEN", "IN_CURE" });
        var measure = (await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/compliance?asOf=2026-02-15")).GetProperty("measures").EnumerateArray().Single();
        Assert.Equal(["BREACH", "WARNING"], measure.GetProperty("trend").EnumerateArray().Select(e => e.GetProperty("result").GetString()));
        Assert.Equal(2, measure.GetProperty("statements")[0].GetProperty("versionNo").GetInt32());
    }

    [Fact]
    public async Task Given_monthly_balances_each_month_and_the_period_average_judge_differently()
    {
        var x = await SetupAsync("2025-01-01", "2027-12-31",
            Covenant("MIN_AVG_BALANCE", "كل شهر", new { measureKind = "AVERAGE_BALANCE", thresholdState = "SET", @operator = "GE", thresholdValue = 500_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "QUARTERLY", aggregationMode = "EACH_MONTH_MIN" }),
            Covenant("MIN_AVG_BALANCE", "متوسط الفترة", new { measureKind = "AVERAGE_BALANCE", thresholdState = "SET", @operator = "GE", thresholdValue = 500_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "QUARTERLY", aggregationMode = "PERIOD_AVERAGE" }));
        await x.Fo.OkAsync(HttpMethod.Put, "/api/v1/account-stats", new
        {
            items = new[]
            {
                new { account = x.Account, month = "2025-07", avgDailyBalance = 620_000 }, new { account = x.Account, month = "2025-08", avgDailyBalance = 480_000 },
                new { account = x.Account, month = "2025-09", avgDailyBalance = 700_000 },
            },
        });
        var cells = (await x.Tm.GetJsonAsync($"/api/v1/account-stats?company={x.Company}&from=2025-07&to=2025-09")).GetProperty("accounts")[0].GetProperty("cells").EnumerateArray()
            .Select(c => c.GetProperty("id").GetString()!).ToArray();
        await x.Tm.PostOkAsync("/api/v1/account-stats/actions/confirm", new { ids = cells });
        Assert.Equal(("BREACH", 480_000m, -20_000m, -4m), Judged(await EvaluateAsync(x, "كل شهر", "2025-09-30")));
        Assert.Equal(("COMPLIANT", 600_000m, 100_000m, 20m), Judged(await EvaluateAsync(x, "متوسط الفترة", "2025-09-30")));
    }

    [Fact]
    public async Task Given_a_share_of_revenue_the_flows_are_judged_with_what_remains()
    {
        const string share = "حصة الإيرادات";
        var x = await SetupAsync("2025-01-01", "2027-12-31", Covenant("REVENUE_CHANNELLING_PCT", share,
            new { measureKind = "PERCENT_OF_REVENUE", formula = "FLOW_TO_REVENUE_PCT", thresholdState = "SET", @operator = "GE", thresholdValue = 15, thresholdUnit = "PERCENT", testFrequency = "ANNUAL" }));
        var st = await StatementTests.StatementAsync(x.Fo, x.Company);
        await StatementTests.SaveAsync(x.Fo, st, StatementTests.Balanced);   // revenue 100,000 thousand
        await x.Fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { });
        await x.Tm.PostOkAsync($"/api/v1/financial-statements/{st}/actions/approve", new { });
        var flow = PlatformFixture.Id(await x.Fo.PostOkAsync("/api/v1/bank-flows", new { company = x.Company, institution = x.Bank, facility = x.Facility, month = "2025-06", amount = 14_200_000, currency = "SAR" }));
        await x.Tm.PostOkAsync("/api/v1/bank-flows/actions/confirm", new { ids = new[] { flow } });
        var t = await EvaluateAsync(x, share, "2025-12-31");
        Assert.Equal(("BREACH", 14.2m), (t.GetProperty("result").GetString(), t.GetProperty("actualValue").GetDecimal()));
        var inputs = t.GetProperty("inputs").GetProperty("inputs");
        Assert.Equal(800_000m, 15m / 100 * inputs.GetProperty("REVENUE").GetDecimal() - inputs.GetProperty("FLOW_TO_BANK").GetDecimal());
        var more = PlatformFixture.Id(await x.Fo.PostOkAsync("/api/v1/bank-flows", new { company = x.Company, institution = x.Bank, facility = x.Facility, month = "2025-09", amount = 1_700_000, currency = "SAR" }));
        await x.Tm.PostOkAsync("/api/v1/bank-flows/actions/confirm", new { ids = new[] { more } });
        Assert.Equal(("WARNING", 15.9m, 0.9m, 6m), Judged(await EvaluateAsync(x, share, "2025-12-31")));
    }

    /// <summary>
    /// Deviation 4 of docs/46 (044 relaxed): a share of revenue read against the approved manual estimate is judged with no
    /// statement, and its snapshot names the estimate; without an approved estimate the data is missing.
    /// </summary>
    [Fact]
    public async Task A_share_of_revenue_on_the_manual_estimate_needs_no_statement()
    {
        const string share = "حصة الإيراد التقديرية";
        var x = await SetupAsync("2025-01-01", "2027-12-31", Covenant("REVENUE_CHANNELLING_PCT", share,
            new { measureKind = "PERCENT_OF_REVENUE", formula = "FLOW_TO_REVENUE_PCT", thresholdState = "SET", @operator = "GE", thresholdValue = 15, thresholdUnit = "PERCENT", testFrequency = "ANNUAL", revenueBasisRule = "MANUAL_ESTIMATE" }));
        var flow = PlatformFixture.Id(await x.Fo.PostOkAsync("/api/v1/bank-flows", new { company = x.Company, institution = x.Bank, facility = x.Facility, month = "2025-06", amount = 14_200_000, currency = "SAR" }));
        await x.Tm.PostOkAsync("/api/v1/bank-flows/actions/confirm", new { ids = new[] { flow } });
        Assert.Equal("MISSING_DATA", (await EvaluateAsync(x, share, "2025-12-31")).GetProperty("result").GetString());
        var estimate = PlatformFixture.Id(await x.Fo.PostOkAsync("/api/v1/revenue-estimates", new
        {
            company = x.Company, fiscalYear = 2025, basis = "STANDALONE", amount = 100_000_000, currency = "SAR", basisNote = "The budget of 2025",
        }));
        await x.Tm.PostOkAsync($"/api/v1/revenue-estimates/{estimate}/actions/approve", new { });
        var t = await EvaluateAsync(x, share, "2025-12-31");
        Assert.Equal(("BREACH", 14.2m), (t.GetProperty("result").GetString(), t.GetProperty("actualValue").GetDecimal()));
        var inputs = t.GetProperty("inputs");
        Assert.Equal(("MANUAL_ESTIMATE", true, 0), (inputs.GetProperty("revenue").GetProperty("source").GetString(), inputs.GetProperty("revenue").GetProperty("estimated").GetBoolean(),
            inputs.GetProperty("statements").GetArrayLength()));
    }

    [Fact]
    public async Task Given_no_threshold_the_value_is_not_assessed_and_leaves_the_colour()
    {
        const string de = "الدين إلى حقوق الملكية";
        var x = await SetupAsync("2025-01-01", "2027-12-31", Covenant("DEBT_TO_EQUITY", de,
            new { measureKind = "RATIO", formula = "DEBT_TO_EQUITY", thresholdState = "NOT_SPECIFIED_IN_AGREEMENT", testFrequency = "ANNUAL" }));
        var before = (await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/compliance?asOf=2025-06-30")).GetProperty("colour").GetString();
        var st = await StatementTests.StatementAsync(x.Fo, x.Company);
        await StatementTests.SaveAsync(x.Fo, st, new Dictionary<string, decimal>(StatementTests.Balanced) { ["CASH"] = 41_000, ["LT_LOANS"] = 39_000 });
        await x.Fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { });
        await x.Tm.PostOkAsync($"/api/v1/financial-statements/{st}/actions/approve", new { });
        var t = await EvaluateAsync(x, de, "2025-12-31");
        Assert.Equal(("NOT_ASSESSED_NO_THRESHOLD", 2.0m), (t.GetProperty("result").GetString(), t.GetProperty("actualValue").GetDecimal()));
        var after = await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/compliance?asOf=2025-06-30");
        Assert.Equal(before, after.GetProperty("colour").GetString());
        Assert.NotEqual("COMPLIANT", t.GetProperty("result").GetString());
        Assert.Equal(1, (await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/compliance?asOf=2026-02-15")).GetProperty("notAssessed").GetInt32());
    }

    [Fact]
    public async Task Given_no_balances_after_the_lag_the_test_is_missing_data_and_warns()
    {
        var ct = TestContext.Current.CancellationToken;
        const string avg = "متوسط الرصيد";
        var x = await SetupAsync("2026-01-01", "2027-12-31", Covenant("MIN_AVG_BALANCE", avg,
            new { measureKind = "AVERAGE_BALANCE", thresholdState = "SET", @operator = "GE", thresholdValue = 500_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "QUARTERLY", aggregationMode = "PERIOD_AVERAGE", submissionLagDays = 30 }));
        Assert.Equal("2026-10-30", (await TestAsync(x, avg, "2026-09-30")).GetProperty("dueDate").GetString());
        await new FinanceEvaluationJob(f.Env.Db, new DayClock(new DateTime(2026, 10, 30))).RunOnceAsync(ct);
        Assert.Equal("PENDING_DATA", (await TestAsync(x, avg, "2026-09-30")).GetProperty("state").GetString());
        await new FinanceEvaluationJob(f.Env.Db, new DayClock(new DateTime(2026, 10, 31))).RunOnceAsync(ct);
        var t = await TestAsync(x, avg, "2026-09-30");
        Assert.Equal(("EVALUATED", "MISSING_DATA"), (t.GetProperty("state").GetString(), t.GetProperty("result").GetString()));
        await DrainAsync();
        Assert.Contains((await x.Fo.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(), n => n.GetProperty("eventCode").GetString() == "FIN.DATA_MISSING");
        Assert.Contains((await x.Tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/compliance?asOf=2026-10-31")).GetProperty("reasons").EnumerateArray(),
            r => r.GetProperty("code").GetString() == "MISSING_DATA");
    }

    [Fact]
    public async Task Given_one_user_with_both_permissions_the_preparer_does_not_approve()
    {
        var t = await f.CreateTenantAsync();
        await t.Portal.PostOkAsync("/api/v1/roles", new { code = "finboth7", nameEn = "Prepares and approves", nameAr = "يعد ويعتمد", permissions = new[] { "fin.view", "fin.stmt.enter", "fin.stmt.approve" } });
        var both = (await f.UserWithRoleAsync(t, "FINBOTH7")).Client;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C8", nameAr = "شركة", nameEn = "Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var st = await StatementTests.StatementAsync(both, company);
        await StatementTests.SaveAsync(both, st, StatementTests.Balanced);
        await both.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { });
        Assert.Equal((403, "V-FIN-SOD"), await both.PostProblemAsync($"/api/v1/financial-statements/{st}/actions/approve", new { }));
        Assert.Equal("SUBMITTED", (await tm.GetJsonAsync($"/api/v1/financial-statements/{st}")).GetProperty("statement").GetProperty("status").GetString());
    }
}
