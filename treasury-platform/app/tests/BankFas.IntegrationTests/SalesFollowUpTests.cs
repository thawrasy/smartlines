using System.Globalization;
using BankFas.Data.Jobs;
using BankFas.Data.Workflow;

namespace BankFas.IntegrationTests;

/// <summary>
/// The rest of the sales (S4 batches C to F): a credit recorded against an issued proforma takes the proforma's terms and
/// is a warning when it exceeds the proforma's total (V-LCE-13), LC.RECEIVED reaches the proforma's requester, the
/// register counts the credit; the comparison with the proforma (FR-LCE-023) gives its verdicts and the treasury decides
/// each difference; a discrepancy on our documents is waived or refuses them (FR-LCE-021); and the nightly jobs: the
/// proforma without a credit reminds its requester once (JOB-LCE-NOLC), the received credits reconcile (JOB-LC-RECONCILE)
/// and expire (JOB-LC-EXPIRY).
/// </summary>
[Collection("database")]
public sealed class SalesFollowUpTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private DateTime Today => f.Env.Clock.GetUtcNow().UtcDateTime.Date;
    private static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private static async Task ActAsync(HttpClient c, string id, string action)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        var response = await c.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", new { }, etag);
        Assert.True(response.IsSuccessStatusCode, $"{action}: {(int)response.StatusCode} {await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)}");
    }

    [Fact]
    public async Task A_credit_against_a_proforma_its_comparison_discrepancies_and_the_nightly_jobs()
    {
        var ct = TestContext.Current.CancellationToken;
        var b = await ProformaTests.BedAsync(f);
        var (fo, _, _) = await f.UserWithRoleAsync(b.T, "FO");
        var company = await ProformaTests.CompanyAsync(b, "XF1", "XF1");
        var account = await ProformaTests.CollectionAccountAsync(b, company, "990-1");
        var r = await ProformaTests.SubmittedAsync(b, company, "Follow-up");
        Assert.Null(await ProformaTests.IssueAsync(b, r, account));
        var proforma = (await ProformaTests.ProformaOfAsync(b.Tm, r)).GetProperty("id").GetString()!;

        // The credit takes the proforma's terms; its amount above the proforma's total is a warning to acknowledge.
        var body = new Dictionary<string, object?>
        {
            ["company"] = company, ["lcNumber"] = "RCV-501", ["customer"] = b.Customer, ["institution"] = b.Bank, ["receivedDate"] = D(Today), ["proforma"] = proforma,
            ["terms"] = new Dictionary<string, object?>
            {
                ["amount"] = 4_100_000, ["expiryRule"] = "ABSOLUTE", ["expiryDate"] = D(Today.AddDays(90)), ["expiryDaysAfterIssue"] = null, ["latestShipmentRule"] = "ABSOLUTE",
                ["latestShipmentDate"] = D(Today.AddDays(60)), ["latestShipmentDaysAfterIssue"] = null, ["availableWith"] = "ADVISING_BANK", ["confirmation"] = "CONFIRMED",
                ["advisingBankName"] = "Sales Bank", ["advisingBankAddress"] = "Riyadh", ["advisingBankBic"] = "SALBSARI",
            },
        };
        Assert.Equal((409, "V-LCE-13"), await b.Tm.PostProblemAsync("/api/v1/sales/lcs", body));
        body["acknowledge"] = new[] { "V-LCE-13" };
        body["warningReason"] = "The customer added the transport cost";
        var lc = PlatformFixture.Id(await b.Tm.PostOkAsync("/api/v1/sales/lcs", body));
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        while (await outbox.RunOnceAsync(ct) > 0) { }
        Assert.Contains((await b.Slp.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(), n => n.GetProperty("eventCode").GetString() == "LC.RECEIVED");
        var listed = (await b.Tm.GetJsonAsync("/api/v1/sales/proformas?hasLc=true")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal((proforma, 1), (listed.GetProperty("id").GetString(), listed.GetProperty("credits").GetInt32()));

        // The comparison: the credit's 90 days against the proforma's 120 are less favourable, a confirmation more, a larger amount more.
        var lines = (await b.Tm.PostOkAsync($"/api/v1/sales/lcs/{lc}/compare", new { })).GetProperty("lines").EnumerateArray()
            .ToDictionary(l => l.GetProperty("field").GetString()!, l => l.GetProperty("verdict").GetString());
        Assert.Equal(("LESS_FAVOURABLE", "MORE_FAVOURABLE", "MORE_FAVOURABLE"), (lines["expiryDays"], lines["confirmation"], lines["amount"]));
        var differences = lines.Where(l => l.Value != "MATCH").Select(l => l.Key).ToList();
        foreach (var k in differences.Skip(1)) await b.Tm.OkAsync(HttpMethod.Put, $"/api/v1/sales/lcs/{lc}/comparison/lines/{k}", new { decision = "ACCEPT" });
        Assert.Equal("OPEN", (await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}/comparison")).GetProperty("comparison").GetProperty("status").GetString());
        await b.Tm.OkAsync(HttpMethod.Put, $"/api/v1/sales/lcs/{lc}/comparison/lines/{differences[0]}", new { decision = "REQUEST_AMENDMENT", note = "Ask for 120 days" });
        Assert.Equal("REVIEWED", (await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}/comparison")).GetProperty("comparison").GetProperty("status").GetString());

        // Collection documents of 100,000 earmarked to no order; the customer's bank finds a discrepancy, the treasury waives it,
        // then a second one is refused, which refuses the documents and gives the 100,000 back.
        var cdr = PlatformFixture.Id(await b.Slp.PostOkAsync($"/api/v1/sales/lcs/{lc}/collections", new { amount = 100_000, invoiceRefs = "INV-9" }));
        await ActAsync(b.Slp, cdr, "submit");
        await ActAsync(b.Tm, cdr, "approve");
        await ActAsync(fo, cdr, "claim");
        await ActAsync(fo, cdr, "complete");
        var up = await CompanyDocumentTests.UploadAsync(fo, "/api/v1/documents", CompanyDocumentTests.Pdf("pkg"), "pkg.pdf",
            new Dictionary<string, string> { ["documentType"] = "COLLECTION_DOCS_PACKAGE", ["title"] = "Package", ["company"] = company });
        var package = PlatformFixture.Id(System.Text.Json.JsonDocument.Parse(await up.Content.ReadAsStringAsync(ct)).RootElement);
        await fo.PostOkAsync($"/api/v1/requests/{cdr}/attachments", new { document = package, slot = "COLLECTION_DOCS_PACKAGE" });
        await ActAsync(fo, cdr, "complete");
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/1/discrepancies", new { description = "Invoice date after the delivery note" });
        Assert.Equal("DISCREPANT", (await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}")).GetProperty("drawings")[0].GetProperty("status").GetString());
        Assert.Equal(403, (await b.Slp.ProblemAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/1/discrepancy-decision", new { status = "WAIVED", note = "x" })).Item1);
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/1/discrepancy-decision", new { status = "WAIVED", note = "The customer accepts the dates" });
        Assert.Equal("PRESENTED", (await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}")).GetProperty("drawings")[0].GetProperty("status").GetString());
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/1/discrepancies", new { description = "Packing list missing" });
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/sales/lcs/{lc}/drawings/1/discrepancy-decision", new { status = "REFUSED", note = "The bank returns the documents" });
        var card = await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}");
        Assert.Equal(("REFUSED", 0m, 4_100_000m), (card.GetProperty("drawings")[0].GetProperty("status").GetString(), card.GetProperty("lc").GetProperty("drawn").GetDecimal(),
            card.GetProperty("lc").GetProperty("available").GetDecimal()));

        // The nightly jobs: the credit reconciles; another proforma without a credit reminds its requester once, 30 days after its issue.
        var r2 = await ProformaTests.SubmittedAsync(b, company, "No credit yet");
        Assert.Null(await ProformaTests.IssueAsync(b, r2, account));
        await new LcReconcileJob(f.Env.Db, new DayClock(Today)).RunOnceAsync(ct);
        await new ProformaNoLcJob(f.Env.Db, new DayClock(Today.AddDays(29))).RunOnceAsync(ct);
        while (await outbox.RunOnceAsync(ct) > 0) { }
        int Reminders(System.Text.Json.JsonElement n) => n.GetProperty("items").EnumerateArray().Count(x => x.GetProperty("eventCode").GetString() == "LC.PROFORMA_NO_LC");
        Assert.Equal(0, Reminders(await b.Slp.GetJsonAsync("/api/v1/notifications")));
        await new ProformaNoLcJob(f.Env.Db, new DayClock(Today.AddDays(30))).RunOnceAsync(ct);
        await new ProformaNoLcJob(f.Env.Db, new DayClock(Today.AddDays(31))).RunOnceAsync(ct);
        while (await outbox.RunOnceAsync(ct) > 0) { }
        Assert.Equal(1, Reminders(await b.Slp.GetJsonAsync("/api/v1/notifications")));
        Assert.DoesNotContain((await b.Tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(),
            n => n.GetProperty("eventCode").GetString() == "LC.RECONCILE_MISMATCH");

        // The expiry: past its date the credit is EXPIRED and takes no new sales order.
        await new LcExpiryJob(f.Env.Db, new DayClock(Today.AddDays(91))).RunOnceAsync(ct);
        Assert.Equal("EXPIRED", (await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}")).GetProperty("lc").GetProperty("status").GetString());
        Assert.Equal((409, "LC_NOT_ACTIVE"), await b.Slp.PostProblemAsync($"/api/v1/sales/lcs/{lc}/sales-orders", new { orderRef = "LATE", orderDate = D(Today), amount = 10 }));
    }
}
