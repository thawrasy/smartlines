using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Nodes;
using BankFas.Data.Finance;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// AC-FAC-13, the exit of S2-b (S2-b brief batch S2B-H, OQ-17): DS-AGR C and D loaded through the API on one borrower,
/// with DS-FIN-C (the audited statement of 2027 and its restatement, twelve months of confirmed flows to the bank, an
/// approved revenue estimate, and twelve months of balances for an average balance covenant added by a revision).
/// The dashboard of C on 2028-02-15 shows every measured covenant with its latest result and headroom, RED for the
/// unwaived breach of the revenue share with the reasons that set it, the restated net worth evaluated again with its
/// breach marked for review, the counters per family, and the drill-down to the test's inputs; D's covenants with no
/// threshold are counted as not assessed and move no colour; a facility with no obligation is GREY; the group report
/// (R-OBL-05) gives the same row as the facility's dashboard (R-OBL-04), within two seconds.
/// </summary>
[Collection("database")]
public sealed class S2bExitTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private static string FinDir => Path.Combine(AppContext.BaseDirectory, "DS-FIN-C", "v1");

    [Fact]
    public async Task AC_FAC_13_the_compliance_dashboard_of_agreement_C()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "SYN", nameAr = "الشركة المقترضة", nameEn = "Borrower Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        await tm.PostOkAsync("/api/v1/base-rates/SAIBOR_3M/values", new { effectiveDate = "2025-01-01", valuePct = 5.40m });
        var c = await AgreementPackTests.LoadAsync(f, fo, tm, company, "C");
        var d = await AgreementPackTests.LoadAsync(f, fo, tm, company, "D");

        // DS-FIN-C, bound to its reviewer's fingerprint like DS-AGR.
        foreach (var (file, print) in JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(FinDir, "manifest.json"), ct))!["fingerprints"]!.AsObject())
            Assert.Equal(print!.GetValue<string>(), "sha256:" + Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(await File.ReadAllBytesAsync(Path.Combine(FinDir, file), ct))));
        var fin = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(FinDir, "finance.json"), ct))!.AsObject();
        var bank = (await tm.GetJsonAsync("/api/v1/institutions")).GetProperty("items").EnumerateArray().Single(i => i.GetProperty("code").GetString() == "BNK-C").GetProperty("id").GetString()!;

        // The average balance covenant comes with a revision of C (a side letter), on an account at C's bank.
        var acc = fin["account"]!;
        var account = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new
        {
            company, institution = bank, type = (string)acc["type"]!, currency = (string)acc["currency"]!, accountNumber = (string)acc["accountNumber"]!, openedOn = (string)acc["openedOn"]!,
            createRelationship = true,
        }));
        var rev = (await fo.PostOkAsync($"/api/v1/facilities/{c.Facility}/revisions", new { reasonKind = "CORRECTION", changeSummary = "Side letter: minimum monthly balance" })).GetProperty("id").GetString()!;
        var added = fin["addedCovenant"]!.DeepClone().AsObject();
        added["noSourceReason"] = "A side letter (synthetic)";
        await fo.PostOkAsync($"/api/v1/facilities/{c.Facility}/obligations", added);
        var check = await fo.GetJsonAsync($"/api/v1/facilities/{c.Facility}/revisions/{rev}/check");
        Assert.True(check.GetProperty("errors").GetArrayLength() == 0, check.GetProperty("errors").ToString());
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{c.Facility}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{c.Facility}/revisions/{rev}/actions/approve",
            new { acknowledge = check.GetProperty("warnings").EnumerateArray().Select(w => w.GetProperty("code").GetString()).Distinct().ToArray() });

        // The figures: the audited statement of 2027, the flows, the balances and the estimate.
        var statements = fin["statements"]!.AsArray();
        var s1 = statements[0]!;
        var st = await StatementTests.StatementAsync(fo, company, new
        {
            periodType = (string)s1["periodType"]!, periodEnd = (string)s1["periodEnd"]!, assurance = (string)s1["assurance"]!, auditorName = (string)s1["auditorName"]!,
            auditOpinion = (string)s1["auditOpinion"]!, unitScale = (int)s1["unitScale"]!,
        });
        Dictionary<string, decimal> Lines(JsonNode n) => n["lines"]!.AsObject().ToDictionary(x => x.Key, x => (decimal)x.Value!);
        await StatementTests.SaveAsync(fo, st, Lines(s1));
        await fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { });
        await tm.PostOkAsync($"/api/v1/financial-statements/{st}/actions/approve", new { });
        // A month is entered once it has ended (V-FIN-02): the figures of 2027 are entered on the application's clock moved to 2028.
        var saved = f.Env.Clock.Now;
        f.Env.Clock.Now = new DateTimeOffset(2028, 2, 16, 8, 0, 0, TimeSpan.Zero);
        try
        {
            var flows = new List<string>();
            foreach (var x in fin["flows"]!.AsArray())
                flows.Add(PlatformFixture.Id(await fo.PostOkAsync("/api/v1/bank-flows", new { company, institution = bank, facility = c.Facility, month = (string)x!["month"]!, amount = (decimal)x["amount"]!, currency = "SAR" })));
            await tm.PostOkAsync("/api/v1/bank-flows/actions/confirm", new { ids = flows });
            await fo.OkAsync(HttpMethod.Put, "/api/v1/account-stats", new
            {
                items = fin["balances"]!.AsArray().Select(x => new { account, month = (string)x!["month"]!, avgDailyBalance = (decimal)x["avgDailyBalance"]! }).ToArray(),
            });
            var cells = (await tm.GetJsonAsync($"/api/v1/account-stats?company={company}&from=2027-01&to=2027-12")).GetProperty("accounts").EnumerateArray()
                .SelectMany(a => a.GetProperty("cells").EnumerateArray()).Select(x => x.GetProperty("id").GetString()!).ToArray();
            Assert.Equal(12, cells.Length);
            await tm.PostOkAsync("/api/v1/account-stats/actions/confirm", new { ids = cells });
        }
        finally
        {
            f.Env.Clock.Now = saved;
        }
        var e = fin["revenueEstimate"]!;
        var estimate = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/revenue-estimates", new
        {
            company, fiscalYear = (int)e["fiscalYear"]!, basis = (string)e["basis"]!, amount = (decimal)e["amount"]!, currency = (string)e["currency"]!, basisNote = (string)e["basisNote"]!,
        }));
        await tm.PostOkAsync($"/api/v1/revenue-estimates/{estimate}/actions/approve", new { });
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        while (await outbox.RunOnceAsync(ct) > 0) { }

        // The nightly evaluation on 2028-02-15, after the due date of the year's tests; then the restatement of the net worth.
        await new FinanceEvaluationJob(f.Env.Db, new DayClock(new DateTime(2028, 2, 15))).RunOnceAsync(ct);
        var s2 = statements[1]!;
        var v2 = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/new-version", new { reason = (string)s2["reason"]! }));
        await StatementTests.SaveAsync(fo, v2, Lines(s2));
        await fo.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/submit", new { });
        await tm.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/approve", new { });
        while (await outbox.RunOnceAsync(ct) > 0) { }

        var asOf = (string)fin["expected"]!["asOf"]!;
        var clock = Stopwatch.StartNew();
        var dash = await tm.GetJsonAsync($"/api/v1/facilities/{c.Facility}/compliance?asOf={asOf}");
        clock.Stop();
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(2), $"the dashboard took {clock.Elapsed}");   // NFR-PERF-01
        Assert.Equal((string)fin["expected"]!["colour"]!, dash.GetProperty("colour").GetString());
        var reasons = dash.GetProperty("reasons").EnumerateArray().Select(r => r.GetProperty("code").GetString()).ToList();
        Assert.Contains("BREACH_NOT_WAIVED", reasons);
        Assert.Contains("OPEN_BREACH", reasons);
        Assert.Contains("NOT_CONFIRMED", reasons);   // C ran out on 2028-01-07 with no successor

        // Every measured covenant with its latest result and headroom.
        var measures = dash.GetProperty("measures").EnumerateArray().ToList();
        Assert.Equal(3, measures.Count);
        JsonElement M(string title) => measures.Single(m => m.GetProperty("obligationTitleAr").GetString() == title);
        var share = M("إيداع نسبة من الإيرادات السنوية لدى البنك");
        Assert.Equal(("BREACH", 14.2m, -0.8m), (share.GetProperty("result").GetString(), share.GetProperty("actualValue").GetDecimal(), share.GetProperty("headroom").GetDecimal()));
        var tnw = M("عدم سحب رأس المال الإضافي");
        Assert.Equal(("COMPLIANT", 2, 330_000_000m), (tnw.GetProperty("result").GetString(), tnw.GetProperty("evaluationNo").GetInt32(), tnw.GetProperty("actualValue").GetDecimal()));
        Assert.Equal(["BREACH", "COMPLIANT"], tnw.GetProperty("trend").EnumerateArray().Select(x => x.GetProperty("result").GetString()));
        Assert.True(tnw.GetProperty("breach").GetProperty("needsReview").GetBoolean());
        var balance = M("الحد الأدنى لمتوسط الرصيد الشهري");
        Assert.Equal(("COMPLIANT", "2027-12-31", 630_000m), (balance.GetProperty("result").GetString(), balance.GetProperty("periodEnd").GetString(), balance.GetProperty("actualValue").GetDecimal()));
        Assert.All(measures, m => Assert.NotEqual(JsonValueKind.Null, m.GetProperty("headroom").ValueKind));

        // The counters per family, and the drill-down to the inputs of a test.
        var covenants = dash.GetProperty("families").EnumerateArray().Single(x => x.GetProperty("family").GetString() == "COVENANT");
        Assert.Equal((3, 1), (covenants.GetProperty("measured").GetInt32(), covenants.GetProperty("breaches").GetInt32()));
        Assert.Contains(dash.GetProperty("families").EnumerateArray(), x => x.GetProperty("family").GetString() == "REPORTING");
        var why = await tm.GetJsonAsync($"/api/v1/covenant-tests/{share.GetProperty("test").GetString()}");
        Assert.Equal(12, why.GetProperty("test").GetProperty("inputs").GetProperty("flows").GetArrayLength());

        // D's covenants have no threshold: counted, never a colour.
        var dd = await tm.GetJsonAsync($"/api/v1/facilities/{d.Facility}/compliance?asOf={asOf}");
        Assert.Equal(3, dd.GetProperty("notAssessed").GetInt32());
        Assert.DoesNotContain(dd.GetProperty("reasons").EnumerateArray(), r => r.GetProperty("code").GetString() is "BREACH_NOT_WAIVED" or "WARNING" or "MISSING_DATA");

        // A facility with no obligation is GREY.
        var bare = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 5_000_000, effectiveFrom = "2027-01-01", expiryDate = "2029-12-31", bankReferenceNo = "BARE-1",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{bare}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        var bareRev = (await fo.GetJsonAsync($"/api/v1/facilities/{bare}")).GetProperty("draft").GetProperty("revision").GetString()!;
        var bareCheck = await fo.GetJsonAsync($"/api/v1/facilities/{bare}/revisions/{bareRev}/check");
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{bare}/revisions/{bareRev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{bare}/revisions/{bareRev}/actions/approve",
            new { acknowledge = bareCheck.GetProperty("warnings").EnumerateArray().Select(w => w.GetProperty("code").GetString()).Distinct().ToArray() });
        Assert.Equal("GREY", (await tm.GetJsonAsync($"/api/v1/facilities/{bare}/compliance?asOf={asOf}")).GetProperty("colour").GetString());

        // R-OBL-05 gives C's row as R-OBL-04 gives it.
        var group = (await tm.GetJsonAsync($"/api/v1/reports/compliance?asOf={asOf}&company={company}")).GetProperty("items").EnumerateArray().ToList();
        var row = group.Single(r => r.GetProperty("compliance").GetProperty("facility").GetString() == c.Facility).GetProperty("compliance");
        Assert.Equal(dash.ToString(), row.ToString());
        Assert.Contains(group, r => r.GetProperty("compliance").GetProperty("colour").GetString() == "GREY");
        Assert.Single((await tm.GetJsonAsync($"/api/v1/reports/compliance?asOf={asOf}&company={company}&colour=GREY")).GetProperty("items").EnumerateArray());
    }
}
