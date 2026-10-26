using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// docs/31 row 76: the business of a company with a bank, product by product. The catalogue carries the new products
/// (deposits, swaps, funds, wealth management ...); the charges of a product follow its nature (POS: mada, Visa and
/// Mastercard, GCC network; payroll: within the bank, to other banks, to payroll cards); a rate is a percent with a cap
/// or a fixed amount, and a new rate of a charge ends the one before it; the volumes of a period carry the commissions,
/// the bank's profit and the balance; the cross-sale view of the bank sums them.
/// </summary>
[Collection("database")]
public sealed class RelationshipBusinessTests(PlatformFixture f)
{
    [Fact]
    public async Task Products_rates_volumes_and_the_cross_sale_view_of_a_bank()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var co = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "RB1", nameAr = "شركة", nameEn = "Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "RBK", nameAr = "البنك", nameEn = "The Bank", type = "BANK", country = "SA" }));
        var rel = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/relationships", new { company = co, institution = bank }));
        foreach (var p in new[] { "POS_COLLECTION", "PAYROLL_SERVICE", "WEALTH_MANAGEMENT" })
            Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Put, $"/api/v1/relationships/{rel}/products/{p}", new { })).StatusCode);

        // The charges follow the product's nature.
        var pos = (await tm.GetJsonAsync("/api/v1/product-charges?product=POS_COLLECTION")).GetProperty("items").EnumerateArray().Select(i => i.GetProperty("code").GetString()!).ToArray();
        Assert.Equal(["POS_MADA", "POS_VISA_MC", "POS_GCC", "POS_OTHER", "POS_TERMINAL", "OTHER_CHARGE"], pos);
        var payroll = (await tm.GetJsonAsync("/api/v1/product-charges?product=PAYROLL_SERVICE")).GetProperty("items").EnumerateArray().Select(i => i.GetProperty("code").GetString()!).ToArray();
        Assert.Equal(["PAYROLL_SAME_BANK", "PAYROLL_OTHER_BANK", "PAYROLL_TO_CARDS", "OTHER_CHARGE"], payroll);
        Assert.Contains("WEALTH_FEE", (await tm.GetJsonAsync("/api/v1/product-charges?product=WEALTH_MANAGEMENT")).GetProperty("items").EnumerateArray().Select(i => i.GetProperty("code").GetString()));

        // mada 0.4% capped at 20; Visa and Mastercard 1.25% without a cap; a payroll charge is not a POS charge.
        var posUrl = $"/api/v1/relationships/{rel}/products/POS_COLLECTION";
        await tm.PostOkAsync($"{posUrl}/rates", new { charge = "POS_MADA", basis = "PERCENT", ratePct = 0.4m, maxAmount = 20m, currency = "SAR", validFrom = "2026-01-01" });
        await tm.PostOkAsync($"{posUrl}/rates", new { charge = "POS_VISA_MC", basis = "PERCENT", ratePct = 1.25m, currency = "SAR", validFrom = "2026-01-01" });
        Assert.Equal((422, "V-INS-CHARGE"), await tm.PostProblemAsync($"{posUrl}/rates", new { charge = "PAYROLL_SAME_BANK", basis = "FIXED", fixedAmount = 1m, validFrom = "2026-01-01" }));
        Assert.Equal((422, "VALIDATION_FAILED"), await tm.PostProblemAsync($"{posUrl}/rates", new { charge = "POS_GCC", basis = "PERCENT", validFrom = "2026-01-01" }));
        Assert.Equal((409, "V-INS-RATE-TAKEN"), await tm.PostProblemAsync($"{posUrl}/rates", new { charge = "POS_MADA", basis = "PERCENT", ratePct = 0.3m, validFrom = "2026-01-01" }));
        // A new mada rate ends the one before it.
        await tm.PostOkAsync($"{posUrl}/rates", new { charge = "POS_MADA", basis = "PERCENT", ratePct = 0.35m, maxAmount = 15m, validFrom = "2026-07-01" });
        var business = await tm.GetJsonAsync($"{posUrl}/business");
        var mada = business.GetProperty("rates").EnumerateArray().Where(r => r.GetProperty("charge").GetString() == "POS_MADA").ToArray();
        Assert.Equal([("2026-07-01", JsonValueKind.Null), ("2026-01-01", JsonValueKind.String)], mada.Select(r => (r.GetProperty("validFrom").GetString()!, r.GetProperty("validTo").ValueKind)).ToArray());
        Assert.Equal("2026-06-30", mada[1].GetProperty("validTo").GetString());

        // Volumes by period, with the commissions and the balance.
        var today = DateTime.UtcNow.Date;
        string D(DateTime d) => d.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var m1 = new DateTime(today.Year, today.Month, 1).AddMonths(-2);
        await tm.PostOkAsync($"{posUrl}/volumes", new { periodStart = D(m1), periodEnd = D(m1.AddMonths(1).AddDays(-1)), volume = 1_000_000m, txnCount = 5000, feesPaid = 4_200m });
        await tm.PostOkAsync($"{posUrl}/volumes", new { periodStart = D(m1.AddMonths(1)), periodEnd = D(m1.AddMonths(2).AddDays(-1)), volume = 1_500_000m, txnCount = 7000, feesPaid = 6_000m });
        Assert.Equal((409, "V-INS-VOLUME-TAKEN"), await tm.PostProblemAsync($"{posUrl}/volumes", new { periodStart = D(m1), periodEnd = D(m1.AddDays(5)), volume = 1m }));
        await tm.PostOkAsync($"/api/v1/relationships/{rel}/products/WEALTH_MANAGEMENT/volumes", new
        {
            periodStart = D(m1), periodEnd = D(m1.AddMonths(2).AddDays(-1)), volume = 0m, feesPaid = 10_000m, companyReturn = 150_000m, endBalance = 20_000_000m,
        });
        Assert.Equal(2, (await tm.GetJsonAsync($"{posUrl}/business")).GetProperty("volumes").GetArrayLength());

        // The cross-sale view of the bank.
        var view = await tm.GetJsonAsync($"/api/v1/institutions/{bank}/business");
        Assert.Equal(3, view.GetProperty("productCount").GetInt32());
        var posRow = view.GetProperty("products").EnumerateArray().Single(p => p.GetProperty("product").GetString() == "POS_COLLECTION");
        Assert.Equal((2_500_000m, 10_200m, 2), (posRow.GetProperty("volume").GetDecimal(), posRow.GetProperty("feesPaid").GetDecimal(), posRow.GetProperty("ratesInForce").GetInt32()));
        var sar = view.GetProperty("totals").EnumerateArray().Single();
        Assert.Equal(("SAR", 20_200m, 20_000_000m), (sar.GetProperty("currency").GetString(), sar.GetProperty("feesPaid").GetDecimal(), sar.GetProperty("endBalance").GetDecimal()));
        Assert.Equal(3, (await tm.GetJsonAsync($"/api/v1/relationships/{rel}/business")).GetProperty("productCount").GetInt32());
    }
}
