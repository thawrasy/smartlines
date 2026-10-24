using System.Globalization;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// The received letters of credit (S4 batches C to E; AC-LCE-2, AC-LCE-3): the treasury records a customer's credit of
/// 1,000,000 USD; the sales earmark orders on it through SALES_ORDER_APPROVAL; the collection documents of
/// COLLECTION_DOCS_REQUEST convert earmarks into drawings, the customer's bank refuses one and everything comes back; an
/// amendment may not lower the credit below what is earmarked and drawn; the search finds it by number, ERP reference and
/// customer code, and hides it from the active list once nothing is available. At each step
/// LCAmount = EarmarkedRemaining + Drawn + Available.
/// </summary>
[Collection("database")]
public sealed class SalesLcTests(PlatformFixture f)
{
    private DateTime Today => f.Env.Clock.GetUtcNow().UtcDateTime.Date;
    private static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static async Task ActAsync(HttpClient c, string id, string action, object? body = null)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        var response = await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        Assert.True(response.IsSuccessStatusCode, $"{action}: {(int)response.StatusCode} {text}");
    }

    private static async Task<(int, string)> RefusedAsync(HttpClient c, string id, string action)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        return await c.ProblemAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", new { }, etag);
    }

    private static async Task<string> DocumentAsync(HttpClient c, string company, string type, string title)
    {
        var up = await CompanyDocumentTests.UploadAsync(c, "/api/v1/documents", CompanyDocumentTests.Pdf(title), title + ".pdf",
            new Dictionary<string, string> { ["documentType"] = type, ["title"] = title, ["company"] = company });
        var text = await up.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        Assert.True(up.IsSuccessStatusCode, text);
        return JsonDocument.Parse(text).RootElement.GetProperty("id").GetString()!;
    }

    private Dictionary<string, object?> Received(decimal amount) => new()
    {
        ["lcType"] = "SIGHT", ["availableWith"] = "ADVISING_BANK", ["confirmation"] = "WITHOUT", ["advisingBankName"] = "Sales Bank", ["advisingBankAddress"] = "Riyadh",
        ["advisingBankBic"] = "SALBSARI", ["currencyId"] = "USD", ["amount"] = amount, ["toleranceMode"] = "NONE", ["expiryRule"] = "ABSOLUTE", ["expiryDate"] = D(Today.AddDays(150)),
        ["expiryPlace"] = "Riyadh", ["latestShipmentRule"] = "ABSOLUTE", ["latestShipmentDate"] = D(Today.AddDays(120)), ["presentationDays"] = 21,
        ["presentationBasis"] = "SHIPMENT_DATE", ["partialShipments"] = "ALLOWED", ["transhipment"] = "ALLOWED", ["transportMode"] = "SEA", ["incotermId"] = "FOB",
        ["incotermPlace"] = "Dammam", ["goodsDescription"] = "Steel structures", ["insuranceResponsibility"] = "APPLICANT", ["lcTextLanguage"] = "EN",
    };

    private static readonly object[] Documents = [new { clause = "COMMERCIAL_INVOICE", originals = 1, copies = 2 }, new { clause = "BL_SEA", originals = 3, copies = 3 }];

    private sealed record Ctx(ProformaTests.SalesBed B, HttpClient Fo, string Company, string Lc);

    private static async Task<JsonElement> CardAsync(HttpClient c, string lc) => (await c.GetJsonAsync($"/api/v1/sales/lcs/{lc}")).GetProperty("lc");

    private static (decimal Earmarked, decimal Drawn, decimal Available) Balance(JsonElement lc)
    {
        var b = (lc.GetProperty("earmarked").GetDecimal(), lc.GetProperty("drawn").GetDecimal(), lc.GetProperty("available").GetDecimal());
        Assert.Equal(lc.GetProperty("amount").GetDecimal(), b.Item1 + b.Item2 + b.Item3);
        return b;
    }

    /// <summary>A sales order on the credit, approved by the manager (the treasury manager by fallback) and earmarked by the treasury.</summary>
    private static async Task<string> EarmarkedAsync(Ctx x, string orderRef, decimal amount)
    {
        var id = PlatformFixture.Id(await x.B.Slp.PostOkAsync($"/api/v1/sales/lcs/{x.Lc}/sales-orders", new { orderRef, orderDate = D(DateTime.UtcNow.Date), amount }));
        var copy = await DocumentAsync(x.B.Tm, x.Company, "SALES_ORDER_COPY", "Order " + orderRef);
        await x.B.Tm.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = copy, slot = "SALES_ORDER_COPY" });
        await ActAsync(x.B.Slp, id, "submit");
        await ActAsync(x.B.Tm, id, "approve");
        await ActAsync(x.Fo, id, "claim");
        await ActAsync(x.Fo, id, "complete");
        return id;
    }

    private static async Task<string> OrderIdAsync(HttpClient c, string lc, string orderRef) =>
        (await c.GetJsonAsync($"/api/v1/sales/lcs/{lc}")).GetProperty("orders").EnumerateArray().Single(o => o.GetProperty("orderRef").GetString() == orderRef).GetProperty("id").GetString()!;

    /// <summary>Collection documents on the credit, approved and handed over by the treasury with the package.</summary>
    private static async Task CollectedAsync(Ctx x, decimal amount, object[] allocations)
    {
        var id = PlatformFixture.Id(await x.B.Slp.PostOkAsync($"/api/v1/sales/lcs/{x.Lc}/collections", new { amount, invoiceRefs = "INV-1, DN-1", allocations }));
        await ActAsync(x.B.Slp, id, "submit");
        await ActAsync(x.B.Tm, id, "approve");
        await ActAsync(x.Fo, id, "claim");
        await ActAsync(x.Fo, id, "complete");
        Assert.Equal((422, "V-WFL-ATTACHMENT"), await RefusedAsync(x.Fo, id, "complete"));
        var package = await DocumentAsync(x.Fo, x.Company, "COLLECTION_DOCS_PACKAGE", "Package " + amount.ToString(CultureInfo.InvariantCulture));
        await x.Fo.PostOkAsync($"/api/v1/requests/{id}/attachments", new { document = package, slot = "COLLECTION_DOCS_PACKAGE" });
        await ActAsync(x.Fo, id, "complete");
    }

    [Fact]
    public async Task AC_LCE_2_and_3_earmarks_conversions_refusal_amendment_and_search()
    {
        var b = await ProformaTests.BedAsync(f);
        var (fo, _, _) = await f.UserWithRoleAsync(b.T, "FO");
        var company = await ProformaTests.CompanyAsync(b, "EXP", "EXP");

        // The treasury records the credit; the same number again for the same customer is a warning to acknowledge.
        var body = new
        {
            company, lcNumber = "ilc 7781/26", customer = b.Customer, institution = b.Bank, otherBankText = "Customer Bank, Doha", otherBankBic = "CUSBQAQA",
            receivedDate = D(Today), terms = Received(1_000_000), documents = Documents, bankReference = "ADV-77", erpReference = "so-contract 77",
        };
        Assert.Equal(403, (await b.Slp.ProblemAsync(HttpMethod.Post, "/api/v1/sales/lcs", body)).Item1);
        var lc = PlatformFixture.Id(await b.Tm.PostOkAsync("/api/v1/sales/lcs", body));
        Assert.Equal((409, "V-LCE-12"), await b.Tm.PostProblemAsync("/api/v1/sales/lcs", body));
        var x = new Ctx(b, fo, company, lc);
        var card = await CardAsync(b.Tm, lc);
        Assert.Equal(("ACTIVE", 1_000_000m), (card.GetProperty("status").GetString(), card.GetProperty("amount").GetDecimal()));
        Assert.Equal((0m, 0m, 1_000_000m), Balance(card));

        // The sales see the balance and not the banks or the references (BR-LCE-015).
        var seen = (await b.Slp.GetJsonAsync("/api/v1/sales/lcs?q=ILC7781/26")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal(1_000_000m, seen.GetProperty("available").GetDecimal());
        Assert.False(seen.TryGetProperty("bankNameEn", out _));
        Assert.False(seen.TryGetProperty("erpReference", out _));
        Assert.False((await CardAsync(b.Slp, lc)).TryGetProperty("customerBank", out _));

        // O1 400,000 and O2 300,000 earmarked: 300,000 available; O3 for 400,000 is refused at once.
        await EarmarkedAsync(x, "O1", 400_000);
        await EarmarkedAsync(x, "O2", 300_000);
        Assert.Equal((700_000m, 0m, 300_000m), Balance(await CardAsync(b.Tm, lc)));
        Assert.Equal((422, "INSUFFICIENT_LC_BALANCE"), await b.Slp.PostProblemAsync($"/api/v1/sales/lcs/{lc}/sales-orders", new { orderRef = "O3", orderDate = D(DateTime.UtcNow.Date), amount = 400_000 }));
        var o1 = await OrderIdAsync(b.Tm, lc, "O1");
        var o2 = await OrderIdAsync(b.Tm, lc, "O2");

        // D = 350,000 all on O1: O1 keeps 50,000; earmarked 350,000, drawn 350,000, available 300,000.
        await CollectedAsync(x, 350_000, [new { order = o1, amount = 350_000 }]);
        var after = await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}");
        var order1 = after.GetProperty("orders").EnumerateArray().Single(o => o.GetProperty("orderRef").GetString() == "O1");
        Assert.Equal(("PARTIALLY_CONVERTED", 50_000m), (order1.GetProperty("status").GetString(), order1.GetProperty("remaining").GetDecimal()));
        Assert.Equal((350_000m, 350_000m, 300_000m), Balance(after.GetProperty("lc")));

        // The customer's bank refuses D: everything comes back.
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/1/decision", new { status = "REFUSED" });
        Assert.Equal((700_000m, 0m, 300_000m), Balance(await CardAsync(b.Tm, lc)));

        // D' = 350,000: 250,000 on O2 and 100,000 earmarked to no order; a part above O2's remaining is refused first.
        await CollectedAsync(x, 350_000, [new { order = o2, amount = 250_000 }]);
        Assert.Equal((450_000m, 350_000m, 200_000m), Balance(await CardAsync(b.Tm, lc)));

        // AC-LCE-3: lowering by 300,000 gives 700,000 below the 800,000 committed (V-LCE-11); by 200,000 it is accepted and nothing is left.
        Assert.Equal((422, "V-LCE-11"), await fo.PostProblemAsync($"/api/v1/sales/lcs/{lc}/amendments",
            new { origin = "RECEIVED_FROM_CUSTOMER", newAmount = 700_000, bankIssuedOn = D(Today), decision = "ACCEPT", bankAmendmentRef = "AM-1" }));
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/amendments",
            new { origin = "RECEIVED_FROM_CUSTOMER", newAmount = 800_000, bankIssuedOn = D(Today), decision = "ACCEPT", bankAmendmentRef = "AM-1" });
        var amended = await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}");
        Assert.Equal((800_000m, 1), (amended.GetProperty("lc").GetProperty("amount").GetDecimal(), amended.GetProperty("lc").GetProperty("amendmentNo").GetInt32()));
        Assert.Equal((450_000m, 350_000m, 0m), Balance(amended.GetProperty("lc")));
        Assert.Equal("APPLIED", amended.GetProperty("amendments")[0].GetProperty("status").GetString());

        // The search: by the normalised ERP reference and by the customer's code with all=true; not among the active with something available.
        Assert.Empty((await b.Slp.GetJsonAsync("/api/v1/sales/lcs?q=ILC 7781/26")).GetProperty("items").EnumerateArray());
        Assert.Single((await b.Tm.GetJsonAsync("/api/v1/sales/lcs?q=SO-CONTRACT77&all=true")).GetProperty("items").EnumerateArray());
        Assert.Single((await b.Tm.GetJsonAsync("/api/v1/sales/lcs?q=c-501&all=true")).GetProperty("items").EnumerateArray());

        // The documents are accepted and paid; the close of O1 frees its earmark (BR-LCE-012), and the credit closes.
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/2/decision", new { status = "ACCEPTED" });
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/2/settlements", new { amount = 350_000, settledOn = D(Today) });
        Assert.Equal(403, (await b.Slp.ProblemAsync(HttpMethod.Post, $"/api/v1/sales/orders/{o1}/close", new { reason = "x" })).Item1);
        await b.Tm.OkAsync(HttpMethod.Post, $"/api/v1/sales/orders/{o1}/close", new { reason = "Order delivered short" });
        Assert.Equal((50_000m, 350_000m, 400_000m), Balance(await CardAsync(b.Tm, lc)));
        await b.Tm.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/close", new { reason = "Contract completed" });
        var closed = await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}");
        Assert.Equal("CLOSED", closed.GetProperty("lc").GetProperty("status").GetString());
        Assert.All(closed.GetProperty("orders").EnumerateArray(), o => Assert.Equal("RELEASED", o.GetProperty("status").GetString()));
    }
}
