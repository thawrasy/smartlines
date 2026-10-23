using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Tariff and pricing (S2 brief batch S2-D) through the API: a tariff schedule approved by a treasury manager who did
/// not prepare it, fixed once approved; AC-FAC-4 (the most specific rule: 20,000 / 15,000 / 25,000 / 40,000 /
/// minimum 500 / NO_RULE / VAT 3,000; a new version from 2026-07-01 ends the old one on 2026-06-30), AC-FAC-5 (SAIBOR
/// 3M plus 1.75 fixed for the contract: 7.15% and 35,750.00, 7.30% and 36,500.00, INCOMPLETE before the first value;
/// a late penalty of 4,444.44 that is not income) and AC-FAC-10 (an arrangement fee the agreement left blank is
/// INCOMPLETE, never zero; zero is refused; a later SET version gives 50,000).
/// </summary>
[Collection("database")]
public sealed class PricingTests(PlatformFixture f)
{
    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-FAC-05", "V-FAC-08", "V-PRC-02"];
    private const string Retro = "Entered from the signed agreement";

    private static async Task<string> RuleAsync(HttpClient c, string fac, object body) =>
        (await c.PostOkAsync($"/api/v1/facilities/{fac}/pricing-rules", body)).GetProperty("id").GetString()!;

    private static async Task<JsonElement> ResolveAsync(HttpClient c, object body) => await c.PostOkAsync("/api/v1/pricing/resolve", body);

    private static async Task ApproveOpenAsync(HttpClient fo, HttpClient tm, string fac)
    {
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });
    }

    [Fact]
    public async Task Tariff_AC_FAC_4_AC_FAC_5_and_AC_FAC_10()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var a = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "CA", nameAr = "الشركة أ", nameEn = "Company A", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var b = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "CB", nameAr = "الشركة ب", nameEn = "Company B", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        await t.Portal.OkAsync(HttpMethod.Post, $"/api/v1/companies/{a}/tax-rates", new { taxCode = "VAT", ratePercent = 15m, effectiveFrom = "2026-01-01" });
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));

        // The tariff: issuance 0.25% for each 90 days or part, at least 500; the preparer does not approve; approved is fixed.
        var schedule = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/tariff-schedules", new { institution = bank, nameAr = "تعرفة البنك", effectiveFrom = "2026-01-01" }));
        Assert.Equal((422, "V-PRC-02"), await fo.PostProblemAsync($"/api/v1/tariff-schedules/{schedule}/items", new
        {
            feeType = "ISSUANCE", itemCode = "ISS", nameAr = "عمولة إصدار", chargeKind = "PERCENT", rate = 0.25, fixedAmount = 10, noSourceReason = "Tariff annex",
        }));
        var item = (await fo.PostOkAsync($"/api/v1/tariff-schedules/{schedule}/items", new
        {
            feeType = "ISSUANCE", itemCode = "ISS", nameAr = "عمولة إصدار", chargeKind = "PERCENT", rate = 0.25, periodBasis = "PER_PERIOD_OR_PART", periodDays = 90, minAmount = 500,
            noSourceReason = "Tariff annex",
        })).GetProperty("id").GetString()!;
        Assert.Equal((403, "FORBIDDEN"), await fo.PostProblemAsync($"/api/v1/tariff-schedules/{schedule}/actions/approve", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Post, $"/api/v1/tariff-schedules/{schedule}/actions/approve", new { })).StatusCode);
        Assert.Equal((409, "APPROVED_FINAL"), await fo.PostProblemAsync($"/api/v1/tariff-schedules/{schedule}/items", new
        {
            feeType = "ADVISING", itemCode = "ADV", nameAr = "تبليغ", chargeKind = "FIXED", fixedAmount = 300, noSourceReason = "Tariff annex",
        }));
        var own = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/tariff-schedules", new { institution = bank, nameAr = "تعرفة 2", effectiveFrom = "2027-01-01" }));
        await tm.PostOkAsync($"/api/v1/tariff-schedules/{own}/items", new { feeType = "ADVISING", itemCode = "ADV", nameAr = "تبليغ", chargeKind = "FIXED", fixedAmount = 300, noSourceReason = "Tariff annex" });
        Assert.Equal((403, "V-PRC-SOD"), await tm.PostProblemAsync($"/api/v1/tariff-schedules/{own}/actions/approve", new { }));

        // The facility: L0 (inherit) with L1 (own), L2 (inherit) and L3 (own); SAIBOR 3M values for AC-FAC-5.
        await tm.PostOkAsync("/api/v1/base-rates/SAIBOR_3M/values", new { effectiveDate = "2026-01-01", valuePct = 5.40m });
        await tm.PostOkAsync("/api/v1/base-rates/SAIBOR_3M/values", new { effectiveDate = "2026-04-01", valuePct = 5.55m });
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = a, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 45_000_000, effectiveFrom = "2026-01-01", expiryDate = "2026-12-31",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        async Task<string> LimitAsync(string code, string type, string? parent, string pricing) =>
            (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new
            {
                code, limitType = type, nameAr = code, parent, amount = parent is null ? 45_000_000 : 10_000_000, pricingMode = pricing, noSourceReason = "Agreement",
            })).GetProperty("id").GetString()!;
        var l0 = await LimitAsync("L0", "TOTAL_FACILITY", null, "INHERIT");
        var l1 = await LimitAsync("L1", "DOCUMENTARY_CREDITS", l0, "OWN");
        var l2 = await LimitAsync("L2", "GUARANTEES", l0, "INHERIT");
        var l3 = await LimitAsync("L3", "DIRECT_CREDIT_SUBSTITUTES", l0, "OWN");
        object AddOn(string? limit, decimal addOn, string? company = null, string from = "2026-01-01") => new
        {
            scopeLimit = limit, scopeCompany = company, feeType = "ISSUANCE", method = "TARIFF_PLUS_ADDON", tariffItem = item, addOnPct = addOn, effectiveFrom = from,
            retroactiveReason = Retro, noSourceReason = "Agreement clause 5",
        };
        await RuleAsync(fo, fac, AddOn(null, 1.00m));
        await RuleAsync(fo, fac, AddOn(l1, 0.75m));
        await RuleAsync(fo, fac, AddOn(l1, 0.50m, b));
        Assert.Equal((422, "V-PRC-RETRO"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/pricing-rules", new
        {
            scopeLimit = l2, feeType = "COMMISSION", method = "PERCENT_OF_AMOUNT", ratePct = 1, periodBasis = "FLAT", effectiveFrom = "2026-01-01", noSourceReason = "x",
        }));
        await RuleAsync(fo, fac, new
        {
            financingType = "MURABAHA", method = "BASE_PLUS_MARGIN", baseRate = "SAIBOR_3M", marginPct = 1.75, baseFloorPct = 0, rateFixing = "FIXED_FOR_CONTRACT", dayCount = "ACT_360",
            periodBasis = "PER_ANNUM", effectiveFrom = "2026-01-01", retroactiveReason = Retro, noSourceReason = "Agreement clause 7",
        });
        await RuleAsync(fo, fac, new
        {
            feeType = "LATE_PENALTY", triggerEvent = "LATE_PAYMENT", method = "PERCENT_OF_AMOUNT", ratePct = 16, periodBasis = "PER_ANNUM", dayCount = "ACT_360",
            effectiveFrom = "2026-01-01", retroactiveReason = Retro, noSourceReason = "Agreement clause 9",
        });
        // AC-FAC-10: a blank arrangement fee is saved as not specified; zero with it, and SET without a rate, are refused.
        object Arrangement(string state, decimal? rate, string from = "2026-01-01") => new
        {
            feeType = "ARRANGEMENT", method = "PERCENT_OF_AMOUNT", rateState = state, ratePct = rate, periodBasis = "FLAT", effectiveFrom = from, retroactiveReason = Retro,
            noSourceReason = "Signed copy shows _%",
        };
        Assert.Equal((422, "V-PRC-02"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/pricing-rules", Arrangement("NOT_SPECIFIED_IN_AGREEMENT", 0)));
        Assert.Equal((422, "V-PRC-02"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/pricing-rules", Arrangement("SET", null)));
        await RuleAsync(fo, fac, Arrangement("NOT_SPECIFIED_IN_AGREEMENT", null));
        await ApproveOpenAsync(fo, tm, fac);

        async Task<JsonElement> Lc(string limit, string company, decimal amount = 2_000_000, int days = 90, string asOf = "2026-05-01") =>
            await ResolveAsync(tm, new { facility = fac, limit, company, feeType = "ISSUANCE", amount, days, asOf });
        var a1 = await Lc(l1, a);
        Assert.Equal((1.00m, 20_000m, 3_000m), (a1.GetProperty("ratePct").GetDecimal(), a1.GetProperty("amount").GetDecimal(), a1.GetProperty("vatAmount").GetDecimal()));
        Assert.Contains(a1.GetProperty("losers").EnumerateArray(), l => l.GetProperty("reason").GetString() == "OUT_OF_CHAIN");
        Assert.Equal(15_000m, (await Lc(l1, b)).GetProperty("amount").GetDecimal());
        var a2 = await Lc(l2, a);
        Assert.Equal((1.25m, 25_000m, "FACILITY"), (a2.GetProperty("ratePct").GetDecimal(), a2.GetProperty("amount").GetDecimal(), a2.GetProperty("node").GetString()));
        Assert.Equal(40_000m, (await Lc(l1, a, days: 91)).GetProperty("amount").GetDecimal());
        Assert.Equal(500m, (await Lc(l2, a, amount: 30_000)).GetProperty("amount").GetDecimal());
        Assert.Equal("NO_RULE", (await Lc(l3, a)).GetProperty("status").GetString());

        async Task<JsonElement> Murabaha(string contract) =>
            await ResolveAsync(tm, new { facility = fac, limit = l2, company = a, financingType = "MURABAHA", amount = 1_000_000, days = 180, asOf = "2026-06-01", contractDate = contract });
        var march = await Murabaha("2026-03-15");
        Assert.Equal((7.15m, 35_750.00m), (march.GetProperty("ratePct").GetDecimal(), march.GetProperty("amount").GetDecimal()));
        var april = await Murabaha("2026-04-15");
        Assert.Equal((7.30m, 36_500.00m), (april.GetProperty("ratePct").GetDecimal(), april.GetProperty("amount").GetDecimal()));
        var before = await Murabaha("2025-12-31");
        Assert.Equal(("INCOMPLETE", "NO_BASE_VALUE"), (before.GetProperty("status").GetString(), before.GetProperty("reason").GetString()));
        var late = await ResolveAsync(tm, new { facility = fac, limit = l2, company = a, feeType = "LATE_PENALTY", amount = 500_000, days = 20, asOf = "2026-06-01" });
        Assert.Equal((4_444.44m, true, JsonValueKind.Null), (late.GetProperty("amount").GetDecimal(), late.GetProperty("notIncome").GetBoolean(), late.GetProperty("vatAmount").ValueKind));

        var blank = await ResolveAsync(tm, new { facility = fac, limit = l2, company = a, feeType = "ARRANGEMENT", amount = 10_000_000, days = 365, asOf = "2026-05-01" });
        Assert.Equal(("INCOMPLETE", "RATE_NOT_SPECIFIED", JsonValueKind.Null), (blank.GetProperty("status").GetString(), blank.GetProperty("reason").GetString(), blank.GetProperty("amount").ValueKind));
        Assert.Contains(blank.GetProperty("losers").EnumerateArray(), l => l.GetProperty("reason").GetString() == "RATE_NOT_SPECIFIED");
        Assert.Contains((await tm.GetJsonAsync($"/api/v1/facilities/{fac}/pricing-rules")).GetProperty("notSpecified").EnumerateArray(), x => x.GetProperty("feeType").GetString() == "ARRANGEMENT");
        // AC-FAC-10: the approval projected the arrangement fee as not specified; it stays out of the ranking.
        var fee = (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/terms")).GetProperty("items").EnumerateArray().Single(x => x.GetProperty("key").GetString() == "PRC.ARRANGEMENT_FEE_PCT");
        Assert.Equal(("NOT_SPECIFIED_IN_AGREEMENT", "PROJECTED", JsonValueKind.Null), (fee.GetProperty("valueState").GetString(), fee.GetProperty("origin").GetString(), fee.GetProperty("value").ValueKind));
        var ranking = await tm.GetJsonAsync("/api/v1/terms/compare?key=PRC.ARRANGEMENT_FEE_PCT&asOf=2026-05-01");
        Assert.Equal((0, 1), (ranking.GetProperty("ranked").GetArrayLength(), ranking.GetProperty("unranked").GetArrayLength()));

        // A correction: R1 at +0.90 from 2026-07-01 ends the old version on 2026-06-30; the addendum sets the arrangement fee at 0.50% from 2026-09-01.
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/revisions", new { reasonKind = "CORRECTION", changeSummary = "New issuance pricing; arrangement fee" });
        await RuleAsync(fo, fac, AddOn(l1, 0.90m, from: "2026-07-01"));
        Assert.Contains((await fo.GetJsonAsync($"/api/v1/facilities/{fac}/pricing-rules?view=draft")).GetProperty("items").EnumerateArray(),
            r => r.GetProperty("addOnPct").ValueKind == JsonValueKind.Number && r.GetProperty("addOnPct").GetDecimal() == 0.75m && r.GetProperty("effectiveTo").GetString() == "2026-06-30");
        await RuleAsync(fo, fac, Arrangement("SET", 0.50m, "2026-09-01"));
        await ApproveOpenAsync(fo, tm, fac);
        Assert.Equal(1.00m, (await Lc(l1, a, asOf: "2026-06-30")).GetProperty("ratePct").GetDecimal());
        var july = await Lc(l1, a, asOf: "2026-07-01");
        Assert.Equal((1.15m, 23_000m), (july.GetProperty("ratePct").GetDecimal(), july.GetProperty("amount").GetDecimal()));
        var set = await ResolveAsync(tm, new { facility = fac, limit = l2, company = a, feeType = "ARRANGEMENT", amount = 10_000_000, days = 365, asOf = "2026-09-01" });
        Assert.Equal(("PRICED", 50_000m), (set.GetProperty("status").GetString(), set.GetProperty("amount").GetDecimal()));
        Assert.Equal(0.50m, (await tm.GetJsonAsync("/api/v1/terms/compare?key=PRC.ARRANGEMENT_FEE_PCT&asOf=2026-09-15")).GetProperty("best").GetProperty("value").GetDecimal());
        Assert.Equal("INCOMPLETE", (await ResolveAsync(tm, new { facility = fac, limit = l2, company = a, feeType = "ARRANGEMENT", amount = 10_000_000, days = 365, asOf = "2026-08-31" })).GetProperty("status").GetString());
    }
}
