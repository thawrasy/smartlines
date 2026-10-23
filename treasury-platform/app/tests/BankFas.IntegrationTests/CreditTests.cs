using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// The credit self-assessment through the API (S2-b brief batch S2B-F): CA2, the worked example of docs/35 section 14
/// entered as two statements of an industrial subsidiary, gives through the API the factors, grades, liquidity label,
/// completeness, outlook and remedies that tools/dbgen/credit_reference.py computes (the numbers of
/// db/tests/credit_assessment_tests.sql CA2); a submission after a change of what the computation read is refused and
/// succeeds once computed again; the preparer does not approve; a trial on a draft statement stays a draft.
/// </summary>
[Collection("database")]
public sealed class CreditTests(PlatformFixture f)
{
    /// <summary>The worked example's 2025 lines in SAR millions (docs/35 section 14).</summary>
    private static readonly Dictionary<string, decimal> Base = new()
    {
        ["CASH"] = 45, ["AR"] = 160, ["INVENTORY"] = 130, ["DUE_FROM_RELATED"] = 20, ["OTHER_CA"] = 25, ["TOTAL_CA"] = 380, ["PPE"] = 520, ["INTANGIBLES"] = 30, ["OTHER_NCA"] = 70,
        ["TOTAL_ASSETS"] = 1000, ["ST_LOANS"] = 120, ["CURRENT_PORTION_LTD"] = 60, ["AP"] = 110, ["DUE_TO_RELATED"] = 10, ["OTHER_CL"] = 50, ["TOTAL_CL"] = 350,
        ["LT_LOANS"] = 180, ["LEASE_LIABS"] = 20, ["SHAREHOLDER_LOANS_SUB"] = 0, ["EOSB"] = 18, ["OTHER_NCL"] = 12, ["TOTAL_LIABS"] = 580, ["SHARE_CAPITAL"] = 250,
        ["RETAINED_EARNINGS"] = 140, ["OTHER_EQUITY"] = 30, ["MINORITY_INTEREST"] = 0, ["TOTAL_EQUITY"] = 420, ["REVENUE"] = 900, ["COGS"] = 650, ["GROSS_PROFIT"] = 250,
        ["OPEX"] = 160, ["DEPR_AMORT"] = 40, ["EBITDA"] = 130, ["OPERATING_PROFIT"] = 90, ["FINANCE_COSTS"] = 22, ["OTHER_INCOME"] = 4, ["ZAKAT_TAX"] = 8, ["NET_PROFIT"] = 64,
        ["OP_CASH_FLOW"] = 95, ["CAPEX"] = 60, ["PRINCIPAL_REPAID"] = 55, ["INTEREST_PAID"] = 21, ["DIVIDENDS"] = 30, ["LC_OUTSTANDING"] = 90, ["LG_PERFORMANCE"] = 100,
        ["LG_FINANCIAL"] = 20, ["GUARANTEES_GIVEN"] = 0,
    };

    private static async Task<string> StatementAsync(HttpClient fa, HttpClient tm, string company, string periodEnd, IReadOnlyDictionary<string, decimal> lines, bool approve = true)
    {
        var id = await StatementTests.StatementAsync(fa, company, new { periodEnd, assurance = "AUDITED", auditorName = "Auditor (test)", auditOpinion = "UNQUALIFIED", unitScale = 1_000_000 });
        await StatementTests.SaveAsync(fa, id, lines);
        if (!approve) return id;
        await fa.PostOkAsync($"/api/v1/financial-statements/{id}/actions/submit", new { balanceReason = "As reported in the worked example" });
        await tm.PostOkAsync($"/api/v1/financial-statements/{id}/actions/approve", new { });
        return id;
    }

    [Fact]
    public async Task CA2_through_the_API_gives_the_reference_numbers_and_the_life_of_an_assessment()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fa, _, _) = await f.UserWithRoleAsync(t, "FA");
        var hold = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "HOLD", nameAr = "قابضة", nameEn = "Holding", legalForm = "LLC", isHolding = true, country = "SA", fiscalYearEndMonth = 12 }));
        var ind = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "IND", nameAr = "صناعية", nameEn = "Industrial", legalForm = "LLC", parent = hold, country = "SA", fiscalYearEndMonth = 12 }));
        await StatementAsync(fa, tm, ind, "2024-12-31", new Dictionary<string, decimal>(Base) { ["TOTAL_ASSETS"] = 940, ["REVENUE"] = 850, ["GROSS_PROFIT"] = 245, ["CURRENT_PORTION_LTD"] = 55, ["OP_CASH_FLOW"] = 85 });
        var st = await StatementAsync(fa, tm, ind, "2025-12-31", Base);

        var a = PlatformFixture.Id(await fa.PostOkAsync("/api/v1/fin/assessments", new { statement = st, scorecard = "GENERAL_CORPORATE", assessmentDate = "2026-04-30" }));
        const string why = "test fixture: the worked example of docs/35";
        await fa.OkAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "BUSINESS_PROFILE", grade = "Ba1", justification = why });
        await fa.OkAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "FINANCIAL_POLICY", grade = "Baa3", justification = why });
        Assert.Equal("Ba2", (await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/compute", new { })).GetProperty("finalGrade").GetString());

        string S(JsonElement e) => e.ValueKind == JsonValueKind.Null ? "-" : e.ValueKind == JsonValueKind.Number ? e.GetDecimal().ToString("0.0000", System.Globalization.CultureInfo.InvariantCulture) : e.GetString()!;
        var factors = (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/report/factors")).GetProperty("items").EnumerateArray().OrderBy(x => x.GetProperty("SortOrder").GetInt32())
            .Select(x => $"{x.GetProperty("MetricCode").GetString()}:{S(x.GetProperty("Score"))}");
        Assert.Equal("REVENUE_SIZE:12.5000 BUSINESS_PROFILE:11.0000 REV_TOP5_SHARE:- EBITDA_MARGIN:8.4333 BREAKEVEN_SAFETY_MARGIN:6.7673 DEBT_TO_EBITDA:9.4154 EBITDA_TO_INTEREST:8.5909 " +
            "RCF_TO_NET_DEBT:11.3149 TL_TO_TNW:9.7703 CONTINGENT_TO_TNW:8.3378 LIQUIDITY_COVERAGE:12.8228 CASH_CYCLE:9.1120 FUNDING_GAP:9.9444 RELATED_TO_TNW:8.4121 AR_OVER_180_SHARE:- " +
            "FINANCIAL_POLICY:10.0000 PARTNER_DRAWINGS_TO_CFO:10.5000", string.Join(' ', factors));
        var report = (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}")).GetProperty("report");
        Assert.Equal(("RATED", 92.68m, "Baa3", "Baa3", "Ba2", "Ba2", "SGL-3", 9.09m, "NEGATIVE"),
            (report.GetProperty("ResultState").GetString(), report.GetProperty("CoveragePct").GetDecimal(), report.GetProperty("FinancialGrade").GetString(), report.GetProperty("IndicatedGrade").GetString(),
             report.GetProperty("StandaloneGrade").GetString(), report.GetProperty("FinalGrade").GetString(), report.GetProperty("LiquidityLabel").GetString(),
             report.GetProperty("CompletenessPct").GetDecimal(), report.GetProperty("Outlook").GetString()));
        Assert.Equal((9.9901m, 10.1322m), (report.GetProperty("FinancialScore").GetDecimal(), report.GetProperty("WeightedScore").GetDecimal()));
        var remedies = (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/report/remedies")).GetProperty("items").EnumerateArray().OrderBy(x => x.GetProperty("SeqNo").GetInt32())
            .Select(x => $"{x.GetProperty("RemedyCode").GetString()}:{S(x.GetProperty("ProFormaGrade"))}");
        Assert.Equal("CONVERT_DUE_TO_RELATED_TO_SUB:Ba2 COMMITTED_FACILITY:- CREDIT_INSURANCE:- RETAIN_EARNINGS:Ba2 DISCLOSE_BREAKDOWNS:-", string.Join(' ', remedies));
        Assert.Equal(5, (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/report/reclass")).GetProperty("items").GetArrayLength());
        Assert.Equal(15, (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/report/triggers")).GetProperty("items").GetArrayLength());

        // BR-FIN-024: a change of what the computation read refuses the submission until it is computed again.
        await fa.OkAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "FINANCIAL_POLICY", grade = "Baa3", justification = why + " (reviewed)" });
        Assert.Equal((409, "ASSESSMENT_STATE"), await fa.PostProblemAsync($"/api/v1/fin/assessments/{a}/actions/submit", new { }));
        await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/compute", new { });
        await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/submit", new { });
        Assert.Equal((409, "ASSESSMENT_STATE"), await fa.ProblemAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "FINANCIAL_POLICY", grade = "Baa2", justification = why }));
        Assert.Equal((403, "FORBIDDEN"), await fa.PostProblemAsync($"/api/v1/fin/assessments/{a}/actions/approve", new { }));
        await tm.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/approve", new { });
        Assert.Equal("APPROVED", (await tm.GetJsonAsync($"/api/v1/fin/assessments/{a}")).GetProperty("status").GetString());

        // BR-FIN-036: a trial on a draft statement is computed and stays a draft.
        var draft = await StatementAsync(fa, tm, ind, "2026-06-30", Base, approve: false);
        Assert.Equal((422, "V-FIN-ASSESSMENT"), await fa.PostProblemAsync("/api/v1/fin/assessments", new { statement = draft, scorecard = "GENERAL_CORPORATE" }));
        var trial = PlatformFixture.Id(await fa.PostOkAsync("/api/v1/fin/assessments", new { statement = draft, scorecard = "GENERAL_CORPORATE", isTrial = true, assessmentDate = "2026-07-15" }));
        await fa.PostOkAsync($"/api/v1/fin/assessments/{trial}/actions/compute", new { });
        Assert.Equal((409, "ASSESSMENT_STATE"), await fa.PostProblemAsync($"/api/v1/fin/assessments/{trial}/actions/submit", new { }));
        Assert.True((await fa.GetJsonAsync($"/api/v1/financial-statements/{st}/item-analysis")).GetProperty("items").GetArrayLength() > 0);
    }
}
