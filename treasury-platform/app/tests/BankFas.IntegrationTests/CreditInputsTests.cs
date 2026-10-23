using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// The inputs of a credit assessment beside its statement (FR-FIN-026 to 029, 034; docs/47 §4): a guarantor with its
/// dated figures and their document; the company's bureau report, after which the readiness file no longer asks for
/// it; the product lines of the year, whose revenue shares add up to 100 percent at most, frozen once an approved
/// assessment read them (058); and the lender's actual decision on a facility, which the computation reads as the
/// decision in force on the assessment date. The guarantors and the bureau report change only while the assessment
/// is a draft.
/// </summary>
[Collection("database")]
public sealed class CreditInputsTests(PlatformFixture f)
{
    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];

    private static async Task<string> DocumentAsync(HttpClient c, string company, string title)
    {
        var up = await CompanyDocumentTests.UploadAsync(c, "/api/v1/documents", CompanyDocumentTests.Pdf(title), title + ".pdf", new Dictionary<string, string>
        {
            ["documentType"] = "FACILITY_ADDENDUM", ["title"] = title, ["company"] = company,
        });
        return JsonDocument.Parse(await up.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement.GetProperty("id").GetString()!;
    }

    [Fact]
    public async Task Guarantors_bureau_product_lines_and_the_lender_decision_reach_the_assessment()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fa, _, _) = await f.UserWithRoleAsync(t, "FA");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var ind = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "IND", nameAr = "صناعية", nameEn = "Industrial", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        await tm.PostOkAsync("/api/v1/accounts", new { company = ind, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "900-1", openedOn = "2024-01-01", createRelationship = true });

        // A facility of the company and the lender's decision on it: the limit reduced to 30 million from 2026-03-01.
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = ind, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 50_000_000, effectiveFrom = "2025-01-01", expiryDate = "2028-12-31",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 50_000_000, noSourceReason = "Clause 1" });
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });
        Assert.Equal((422, "VALIDATION_FAILED"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/lender-decisions",
            new { decisionDate = "2026-02-15", limitAction = "LIMIT_REDUCED", noSourceReason = "Told by the relationship manager" }));
        var letter = await DocumentAsync(fo, ind, "Lender letter");
        var decision = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/facilities/{fac}/lender-decisions", new
        {
            lender = bank, decisionDate = "2026-02-15", effectiveDate = "2026-03-01", limitAction = "LIMIT_REDUCED", newLimitAmount = 30_000_000, marginChangeBp = 50,
            sourceDocument = letter, sourcePage = "p.1",
        }));
        Assert.Equal((403, "V-FAC-SOD"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/lender-decisions/{decision}/actions/verify", new { }));
        Assert.Equal("CONFIRMED_AGAINST_ORIGINAL", (await tm.PostOkAsync($"/api/v1/facilities/{fac}/lender-decisions/{decision}/actions/verify", new { })).GetProperty("confidence").GetString());
        var decisions = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}/lender-decisions")).GetProperty("items");
        Assert.Equal(("LIMIT_REDUCED", 30_000_000m, true), (decisions[0].GetProperty("limitAction").GetString(), decisions[0].GetProperty("newLimitAmount").GetDecimal(), decisions[0].GetProperty("inForce").GetBoolean()));

        // The statements of the worked example and an assessment of 2026-04-30.
        await CreditTests.StatementAsync(fa, tm, ind, "2024-12-31", new Dictionary<string, decimal>(CreditTests.Base) { ["TOTAL_ASSETS"] = 940, ["REVENUE"] = 850, ["GROSS_PROFIT"] = 245, ["CURRENT_PORTION_LTD"] = 55, ["OP_CASH_FLOW"] = 85 });
        var st = await CreditTests.StatementAsync(fa, tm, ind, "2025-12-31", CreditTests.Base);
        var a = PlatformFixture.Id(await fa.PostOkAsync("/api/v1/fin/assessments", new { statement = st, scorecard = "GENERAL_CORPORATE", assessmentDate = "2026-04-30" }));
        const string why = "test fixture: the worked example of docs/35";
        await fa.OkAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "BUSINESS_PROFILE", grade = "Ba1", justification = why });
        await fa.OkAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "FINANCIAL_POLICY", grade = "Baa3", justification = why });

        // A guarantor: liquid assets above the net worth are refused; with its document it is recorded once.
        var owner = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new { kind = "INDIVIDUAL", nameAr = "الكفيل", nameEn = "Guarantor", country = "SA", residencyStatus = "CITIZEN", birthDate = "1970-05-05" }));
        var statement = await DocumentAsync(tm, ind, "Guarantor net worth");
        Assert.Equal((422, "VALIDATION_FAILED"), await fa.PostProblemAsync($"/api/v1/fin/assessments/{a}/guarantors",
            new { party = owner, netWorth = 10_000_000, liquidAssets = 12_000_000, guaranteedAmount = 5_000_000, asOfDate = "2026-03-31", document = statement }));
        var g = PlatformFixture.Id(await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/guarantors",
            new { party = owner, netWorth = 80_000_000, liquidAssets = 20_000_000, guaranteesGiven = 10_000_000, guaranteedAmount = 50_000_000, asOfDate = "2026-03-31", document = statement }));
        Assert.Equal((409, "DUPLICATE"), await fa.PostProblemAsync($"/api/v1/fin/assessments/{a}/guarantors",
            new { party = owner, netWorth = 80_000_000, liquidAssets = 20_000_000, guaranteedAmount = 50_000_000, asOfDate = "2026-03-31", document = statement }));
        Assert.Single((await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/guarantors")).GetProperty("items").EnumerateArray());

        // The bureau report: before it the readiness file asks for it; after it, no longer.
        await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/compute", new { });
        bool AsksBureau(JsonElement file) => file.GetProperty("requests").EnumerateArray().Any(r => r.GetProperty("RequestKind").GetString() == "BUREAU");
        Assert.True(AsksBureau(await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/readiness")));
        var report = await DocumentAsync(tm, ind, "Bureau report");
        Assert.Equal((422, "VALIDATION_FAILED"), await fa.ProblemAsync(HttpMethod.Put, $"/api/v1/fin/assessments/{a}/bureau",
            new { reportDate = "2026-04-01", document = report, totalLimits = 300_000_000, totalOutstanding = 240_000_000, lenderCount = 4, worstDpd12m = 30, worstDpd24m = 10 }));
        await fa.OkAsync(HttpMethod.Put, $"/api/v1/fin/assessments/{a}/bureau",
            new { reportDate = "2026-04-01", document = report, totalLimits = 300_000_000, totalOutstanding = 240_000_000, lenderCount = 4 });
        Assert.Equal(4, (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/bureau")).GetProperty("report").GetProperty("lenderCount").GetInt32());

        // The product lines of 2025: shares of revenue add up to 100 percent at most.
        var categories = (await fa.GetJsonAsync("/api/v1/fin/product-categories")).GetProperty("items").EnumerateArray().Select(c => c.GetProperty("code").GetString()!).ToList();
        Assert.NotEmpty(categories);
        await fa.PostOkAsync("/api/v1/fin/product-lines", new { company = ind, fiscalYear = 2025, nameAr = "أنابيب", category = categories[0], revenueSharePct = 70, inventorySharePct = 60, cashSalesPct = 20, typicalCreditDays = 90 });
        Assert.Equal((422, "VALIDATION_FAILED"), await fa.PostProblemAsync("/api/v1/fin/product-lines", new { company = ind, fiscalYear = 2025, nameAr = "صمامات", category = categories[^1], revenueSharePct = 40 }));
        var second = PlatformFixture.Id(await fa.PostOkAsync("/api/v1/fin/product-lines", new { company = ind, fiscalYear = 2025, nameAr = "صمامات", category = categories[^1], revenueSharePct = 30 }));
        Assert.Equal(2, (await fa.GetJsonAsync($"/api/v1/fin/product-lines?company={ind}&year=2025")).GetProperty("items").GetArrayLength());

        // The computation reads the decision in force on the assessment date, the guarantor and the lines.
        await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/compute", new { });
        Assert.False(AsksBureau(await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/readiness")));
        var facility = (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/report/facilities")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal(("LIMIT_REDUCED", 30_000_000m), (facility.GetProperty("LimitAction").GetString(), facility.GetProperty("DecidedLimitAmount").GetDecimal()));

        // Once submitted, the guarantors and the bureau report do not change; once approved, the year's lines are frozen.
        await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/submit", new { });
        Assert.Equal((409, "ASSESSMENT_STATE"), await fa.ProblemAsync(HttpMethod.Delete, $"/api/v1/fin/assessments/{a}/guarantors/{g}", null));
        Assert.Equal((409, "ASSESSMENT_STATE"), await fa.ProblemAsync(HttpMethod.Delete, $"/api/v1/fin/assessments/{a}/bureau", null));
        await tm.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/approve", new { });
        Assert.Equal((409, "APPROVED_FINAL"), await fa.ProblemAsync(HttpMethod.Delete, $"/api/v1/fin/product-lines/{second}", null));
    }
}
