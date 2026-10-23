using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// The formula library and the covenant fields of the engine (S2-b brief batch S2B-D): BR-FIN-009 at save (a forbidden
/// character, an unknown code, a depth above ten and a division by a constant zero are refused, with their positions),
/// FR-FIN-011 (a draft approved by another holder of fin.formula.approve, the approved one fixed, a new version keeping
/// its unit), OQ-3 (a template an approved covenant uses is copied to the facility instead of versioned), BR-FIN-014
/// (DSO = AR ÷ REVENUE × 365 on an approved statement; what cannot be computed carries its reason), the preview on a
/// statement, and S2B-GAP-9 (an average balance covenant states its aggregation; selected accounts; the first test
/// period from the company's fiscal year end).
/// </summary>
[Collection("database")]
public sealed class FormulaTests(PlatformFixture f)
{
    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];

    [Fact]
    public async Task Formulas_are_checked_versioned_approved_and_computed()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");

        // BR-FIN-009 at save, with the position of each error.
        async Task<string[]> Errors(string expression) => [.. (await fo.PostOkAsync("/api/v1/formulas/actions/validate", new { expression })).GetProperty("errors").EnumerateArray()
            .Select(e => e.GetProperty("code").GetString()!)];
        Assert.Contains("CHARACTER", await Errors("TOTAL_CA ; TOTAL_CL"));
        Assert.Contains("UNKNOWN_CODE", await Errors("TOTAL_CA / NOT_A_LINE"));
        Assert.Contains("DEPTH", await Errors("((((((((((TOTAL_CA))))))))))"));
        Assert.Contains("DIVIDE_BY_ZERO", await Errors("TOTAL_CA / (3 - 3)"));
        var ok = await fo.PostOkAsync("/api/v1/formulas/actions/validate", new { expression = "MIN(AVG_BAL, 3) / TOTAL_CL" });
        Assert.True(ok.GetProperty("valid").GetBoolean());
        Assert.Equal(["STATEMENT", "ACCOUNT_STATS"], ok.GetProperty("inputKinds").EnumerateArray().Select(x => x.GetString()!));
        Assert.Equal((422, "V-FIN-FORMULA"), await fo.PostProblemAsync("/api/v1/formulas", new { code = "BAD", nameAr = "خطأ", expression = "TOTAL_CA / 0", resultUnit = "RATIO" }));
        Assert.Equal((422, "V-FIN-FORMULA"), await fo.PostProblemAsync("/api/v1/formulas", new { code = "DAYS_T", nameAr = "أيام", expression = "AR / REVENUE * 365", resultUnit = "DAYS" }));

        // FR-FIN-011: approved by another holder of fin.formula.approve; fixed once approved; a new version keeps its unit.
        var mine = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/formulas", new { code = "CASH_COVER", nameAr = "تغطية النقد", expression = "CASH / TOTAL_CL", resultUnit = "RATIO" }));
        Assert.Equal((403, "FORBIDDEN"), await fo.PostProblemAsync($"/api/v1/formulas/{mine}/actions/approve", new { }));
        await tm.PostOkAsync($"/api/v1/formulas/{mine}/actions/approve", new { });
        Assert.Equal((409, "APPROVED_FINAL"), await fo.ProblemAsync(HttpMethod.Patch, $"/api/v1/formulas/{mine}", new { expression = "CASH / TOTAL_CA" }));
        var v2 = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/formulas/{mine}/actions/new-version", new { }));
        Assert.Equal((422, "V-FIN-FORMULA"), await fo.ProblemAsync(HttpMethod.Patch, $"/api/v1/formulas/{v2}", new { resultUnit = "AMOUNT" }));
        Assert.Equal(System.Net.HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Patch, $"/api/v1/formulas/{v2}", new { expression = "(CASH + AR) / TOTAL_CL" })).StatusCode);
        Assert.Equal((403, "V-FIN-SOD"), await tm.PostProblemAsync($"/api/v1/formulas/{v2}/actions/approve", new { }));
        var versions = (await te.GetJsonAsync($"/api/v1/formulas/{v2}")).GetProperty("versions").EnumerateArray().Select(v => v.GetProperty("status").GetString()).ToList();
        Assert.Equal(["APPROVED", "DRAFT"], versions);

        // OQ-3: a template that an approved covenant uses is copied to the facility, not versioned.
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        var account = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new { company, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "900-1", createRelationship = true }));
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 40_000_000, effectiveFrom = "2026-01-01", expiryDate = "2027-12-31",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 40_000_000, noSourceReason = "Clause 1" });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "DEBT_TO_EQUITY", titleAr = "الدين إلى حقوق الملكية", noSourceReason = "Clause 15",
            covenant = new { measureKind = "RATIO", formula = "DEBT_TO_EQUITY", thresholdState = "SET", @operator = "LE", thresholdValue = 2.5, testFrequency = "QUARTERLY" },
        });
        // S2B-GAP-9: an average balance covenant says how the months are taken; selected accounts come with their scope.
        Assert.Equal((422, "V-OBL-01"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "MIN_AVG_BALANCE", titleAr = "متوسط الرصيد", noSourceReason = "Clause 10",
            covenant = new { measureKind = "AVERAGE_BALANCE", thresholdState = "SET", @operator = "GE", thresholdValue = 500_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "QUARTERLY" },
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "MIN_AVG_BALANCE", titleAr = "متوسط الرصيد", noSourceReason = "Clause 10",
            covenant = new
            {
                measureKind = "AVERAGE_BALANCE", thresholdState = "SET", @operator = "GE", thresholdValue = 500_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "QUARTERLY",
                aggregationMode = "EACH_MONTH_MIN", accountScope = "SELECTED_ACCOUNTS", accounts = new[] { account }, earlyWarningPct = 5,
            },
        });
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });
        var covenants = (await te.GetJsonAsync($"/api/v1/facilities/{fac}/obligations")).GetProperty("items").EnumerateArray().Select(o => o.GetProperty("covenant")).ToList();
        var balance = covenants.Single(c => c.GetProperty("measureKind").GetString() == "AVERAGE_BALANCE");
        Assert.Equal(("EACH_MONTH_MIN", "SELECTED_ACCOUNTS", "2026-03-31", 5m), (balance.GetProperty("aggregationMode").GetString(), balance.GetProperty("accountScope").GetString(),
            balance.GetProperty("firstTestPeriodEnd").GetString(), balance.GetProperty("earlyWarningPct").GetDecimal()));
        var template = (await te.GetJsonAsync("/api/v1/formulas?code=DEBT_TO_EQUITY")).GetProperty("items")[0].GetProperty("id").GetString()!;
        Assert.Equal((409, "FORMULA_IN_USE"), await fo.PostProblemAsync($"/api/v1/formulas/{template}/actions/new-version", new { }));
        var copy = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/formulas/{template}/actions/copy", new { facility = fac }));
        await tm.PostOkAsync($"/api/v1/formulas/{copy}/actions/approve", new { });
        var copied = (await te.GetJsonAsync($"/api/v1/formulas/{copy}")).GetProperty("formula");
        Assert.Equal(("FACILITY_COPY", "DEBT_TO_EQUITY", "APPROVED"), (copied.GetProperty("scope").GetString(), copied.GetProperty("baseTemplate").GetString(), copied.GetProperty("status").GetString()));

        // BR-FIN-014 on an approved statement; the preview of a formula on it.
        var st = await StatementTests.StatementAsync(fo, company);
        await StatementTests.SaveAsync(fo, st, StatementTests.Balanced);
        await fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { });
        await tm.PostOkAsync($"/api/v1/financial-statements/{st}/actions/approve", new { });
        Assert.True((await fo.PostOkAsync($"/api/v1/financial-statements/{st}/ratios/actions/compute", new { })).GetProperty("computed").GetInt32() >= 8);
        var ratios = (await fo.GetJsonAsync($"/api/v1/financial-statements/{st}/ratios")).GetProperty("items").EnumerateArray().ToDictionary(r => r.GetProperty("code").GetString()!);
        Assert.Equal((29.2m, "DAYS"), (ratios["DSO"].GetProperty("value").GetDecimal(), ratios["DSO"].GetProperty("unit").GetString()));
        Assert.Equal("NOT_COMPUTABLE", ratios["DSCR"].GetProperty("status").GetString());
        Assert.Contains("division by zero", ratios["DSCR"].GetProperty("reason").GetString());
        var preview = (await fo.PostOkAsync("/api/v1/formulas/actions/validate", new { expression = "TOTAL_CA / TOTAL_CL", statement = st })).GetProperty("preview");
        Assert.Equal(25m / 12m, Math.Round(preview.GetProperty("value").GetDecimal(), 10), 8);
        Assert.Equal(403, (await te.ProblemAsync(HttpMethod.Get, $"/api/v1/financial-statements/{st}/ratios")).Status);
    }
}
