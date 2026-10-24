using System.Globalization;
using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Proformas (S4 batch B; AC-LCE-1, FR-LCE-001 to 008, BR-LCE-001 to 006): the sales prepare, review and approve a proforma
/// request; the treasury issues it with the company's number {seq:000}-{erp}-{yy}, the totals of BR-LCE-001 at the tax rate in
/// force, a locked copy of the terms and the printed proforma stored as a document; a copy of the request issues the next
/// number and supersedes the first; the treasury manager voids with a fresh proof and the number stays used; a company
/// without an ERP code is refused before any number is taken.
/// </summary>
[Collection("database")]
public sealed class ProformaTests(PlatformFixture f)
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

    private static async Task<(int, string)> RefusedAsync(HttpClient c, string id, string action, object? body = null)
    {
        var (_, etag) = await c.GetWithETagAsync($"/api/v1/requests/{id}");
        return await c.ProblemAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/{action}", body ?? new { }, etag);
    }

    internal static string? LastProblem;

    internal sealed record SalesBed(TestTenant T, HttpClient Tm, byte[] TmSecret, HttpClient Fo, HttpClient Slp, HttpClient Slr, HttpClient Sla, string Bank, string Customer);

    internal static async Task<SalesBed> BedAsync(PlatformFixture f)
    {
        var t = await f.CreateTenantAsync();
        var (tm, tmSecret, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (slp, _, _) = await f.UserWithRoleAsync(t, "SLP");
        var (slr, _, _) = await f.UserWithRoleAsync(t, "SLR");
        var (sla, _, _) = await f.UserWithRoleAsync(t, "SLA");
        await t.Portal.OkAsync(HttpMethod.Post, "/api/v1/tax-rates", new { taxCode = "VAT", ratePercent = 15m, effectiveFrom = "2026-01-01" });
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNKS", refCode = "BNS", nameAr = "بنك المبيعات", nameEn = "Sales Bank", type = "BANK", country = "SA" }));
        var customer = PlatformFixture.Id(await slp.PostOkAsync("/api/v1/counterparties", new { kind = "CUSTOMER", nameEn = "Gulf Contracting", nameAr = "الخليج للمقاولات", country = "SA", erpCode = "C-501" }));
        return new SalesBed(t, tm, tmSecret, fo, slp, slr, sla, bank, customer);
    }

    internal static async Task<string> CompanyAsync(SalesBed b, string code, string? erp)
    {
        var company = PlatformFixture.Id(await b.Tm.PostOkAsync("/api/v1/companies", new
        {
            companyCode = code, nameAr = "شركة " + code, nameEn = "Company " + code, legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12, erpCompanyCode = erp, crNumber = "10" + code.GetHashCode(StringComparison.Ordinal).ToString("D8", CultureInfo.InvariantCulture)[^8..],
        }));
        return company;
    }

    internal static async Task<string> CollectionAccountAsync(SalesBed b, string company, string number) =>
        PlatformFixture.Id(await b.Tm.PostOkAsync("/api/v1/accounts", new
        {
            company, institution = b.Bank, type = "LC_COLLECTION", currency = "SAR", accountNumber = number, iban = Iban(number), openedOn = "2024-01-01", createRelationship = true,
        }));

    /// <summary>A valid Saudi IBAN for an account number (ISO 13616: the check digits make the number mod 97 equal 1).</summary>
    internal static string Iban(string number)
    {
        var bban = "80" + new string([.. number.Where(char.IsAsciiDigit)]).PadLeft(18, '0');
        var digits = bban + "2810" + "00";   // S = 28, A = 10
        var mod = digits.Aggregate(0, (m, ch) => (m * 10 + (ch - '0')) % 97);
        return "SA" + (98 - mod).ToString("00", CultureInfo.InvariantCulture) + bban;
    }

    private static object ProformaForm(string customer) => new
    {
        customer, branchCode = "RUH", branchName = "Riyadh branch", projectCode = "P-77", projectName = "Ring road", projectSite = "Riyadh", offerValidityDays = 30, lcPaymentPct = 100,
        placeOfReceipt = "Riyadh", placeOfDelivery = "Site P-77",
        lines = new object[]
        {
            new { description = "Supply and installation", qty = 1, unitCode = "LOT", unitPrice = 3_000_000 },
            new { description = "Cable", qty = 2_400, unitCode = "M", unitPrice = 222.80m },
        },
    };

    private static Dictionary<string, object?> Terms() => new()
    {
        ["lcType"] = "SIGHT", ["confirmation"] = "WITHOUT", ["currencyId"] = "SAR", ["toleranceMode"] = "NONE", ["expiryRule"] = "DAYS_AFTER_ISSUE", ["expiryDaysAfterIssue"] = 120,
        ["expiryPlace"] = "Riyadh", ["latestShipmentRule"] = "DAYS_AFTER_ISSUE", ["latestShipmentDaysAfterIssue"] = 90, ["presentationDays"] = 21,
        ["presentationBasis"] = "DELIVERY_NOTE_DATE", ["partialShipments"] = "ALLOWED", ["transhipment"] = "ALLOWED", ["transportMode"] = "DOMESTIC_DELIVERY",
        ["incotermId"] = "EXW", ["incotermPlace"] = "Riyadh", ["goodsDescription"] = "Supply and installation as per proforma", ["insuranceResponsibility"] = "APPLICANT",
        ["lcTextLanguage"] = "EN",
    };

    /// <summary>A proforma request of the company, prepared and submitted by the sales preparer: the form, the terms and the documents.</summary>
    internal static async Task<string> SubmittedAsync(SalesBed b, string company, string title)
    {
        var id = (await b.Slp.PostOkAsync("/api/v1/requests", new
        {
            type = "PROFORMA_REQUEST", company, data = new { title, customerName = "Gulf Contracting", customerCode = "C-501", proforma = ProformaForm(b.Customer) },
        })).GetProperty("id").GetString()!;
        await b.Slp.GetJsonAsync($"/api/v1/requests/{id}/terms");
        await b.Slp.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms", new { fields = Terms() });
        await b.Slp.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/terms/documents", new object[]
        {
            new { clause = "COMMERCIAL_INVOICE", originals = 1, copies = 2 }, new { clause = "DELIVERY_NOTE", originals = 1, copies = 2 },
        });
        await ActAsync(b.Slp, id, "submit");
        return id;
    }

    /// <summary>The review, the approval, the treasury's claim and choices, and the issue; returns the issue's refusal or null.</summary>
    internal static async Task<(int, string)?> IssueAsync(SalesBed b, string id, string account)
    {
        await ActAsync(b.Slr, id, "approve");
        await ActAsync(b.Sla, id, "approve");
        await ActAsync(b.Tm, id, "claim");   // the claim of the queue moves the request to the claimer's issue stage
        await b.Tm.OkAsync(HttpMethod.Put, $"/api/v1/requests/{id}/proforma-issue", new { proceedsAccount = account, printLanguage = "both" });
        var (_, etag) = await b.Tm.GetWithETagAsync($"/api/v1/requests/{id}");
        var response = await b.Tm.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/actions/complete", new { }, etag);
        if (response.IsSuccessStatusCode) return null;
        var text = await response.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        LastProblem = text;
        var problem = JsonDocument.Parse(text).RootElement;
        return ((int)response.StatusCode, problem.GetProperty("code").GetString()!);
    }

    internal static async Task<JsonElement> ProformaOfAsync(HttpClient c, string requestId) =>
        (await c.GetJsonAsync("/api/v1/sales/proformas")).GetProperty("items").EnumerateArray().Single(p => p.GetProperty("requestId").GetString() == requestId);

    [Fact]
    public async Task AC_LCE_1_the_proforma_totals_numbers_supersedes_and_voids()
    {
        var b = await BedAsync(f);
        var yy = (Today.Year % 100).ToString("00", CultureInfo.InvariantCulture);
        var a = await CompanyAsync(b, "XX05", "xx05 ");
        var a2 = await CompanyAsync(b, "XX02", "XX02");
        var accA = await CollectionAccountAsync(b, a, "880-1");
        var accA2 = await CollectionAccountAsync(b, a2, "880-2");

        // A submission without a line is refused (V-LCE-03); without a customer too.
        var empty = (await b.Slp.PostOkAsync("/api/v1/requests", new { type = "PROFORMA_REQUEST", company = a, data = new { title = "Empty", customerName = "Gulf Contracting", proforma = new { customer = b.Customer, lines = Array.Empty<object>() } } }))
            .GetProperty("id").GetString()!;
        await b.Slp.GetJsonAsync($"/api/v1/requests/{empty}/terms");
        await b.Slp.OkAsync(HttpMethod.Put, $"/api/v1/requests/{empty}/terms", new { fields = Terms() });
        Assert.Equal((422, "V-LCE-03"), await RefusedAsync(b.Slp, empty, "submit"));

        // The first proforma: the preparer cannot review it; the reviewer and the approver pass it; the treasury issues it.
        var r1 = await SubmittedAsync(b, a, "Ring road supply");
        var totals = await b.Slp.GetJsonAsync($"/api/v1/requests/{r1}/proforma-totals");
        Assert.Equal((3_534_720m, 530_208m, 4_064_928m), (totals.GetProperty("subtotal").GetDecimal(), totals.GetProperty("vatAmount").GetDecimal(), totals.GetProperty("total").GetDecimal()));
        Assert.Equal(403, (await RefusedAsync(b.Slp, r1, "approve")).Item1);
        if (await IssueAsync(b, r1, accA) is not null) Assert.Fail(LastProblem);
        var p1 = await ProformaOfAsync(b.Slp, r1);
        Assert.Equal(($"001-XX05-{yy}", "ISSUED", 4_064_928m), (p1.GetProperty("proformaNo").GetString(), p1.GetProperty("status").GetString(), p1.GetProperty("total").GetDecimal()));
        var card = await b.Slp.GetJsonAsync($"/api/v1/sales/proformas/{p1.GetProperty("id").GetString()}");
        Assert.Equal(2, card.GetProperty("lines").GetArrayLength());
        Assert.Equal(534_720m, card.GetProperty("lines")[1].GetProperty("lineTotal").GetDecimal());
        Assert.Equal((530_208m, 4_064_928m), (card.GetProperty("proforma").GetProperty("vatAmount").GetDecimal(), card.GetProperty("proforma").GetProperty("lcAmount").GetDecimal()));

        // The printed proforma is a stored document of the company, with its number and the proceeds IBAN in clear.
        var doc = card.GetProperty("proforma").GetProperty("documentId").GetString()!;
        var print = await b.Tm.GetAsync($"/api/v1/documents/{doc}/content", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.OK, print.StatusCode);
        var html = await print.Content.ReadAsStringAsync(TestContext.Current.CancellationToken);
        Assert.Contains($"001-XX05-{yy}", html, StringComparison.Ordinal);
        Assert.Contains(Iban("880-1"), html, StringComparison.Ordinal);
        Assert.Contains("4,064,928.00", html, StringComparison.Ordinal);
        Assert.DoesNotContain("<script", html, StringComparison.OrdinalIgnoreCase);

        // A copy of the request is a draft without the treasury's choices; its issue takes 002 and supersedes 001.
        var copy = PlatformFixture.Id(await b.Slp.PostOkAsync($"/api/v1/requests/{r1}/copy", new { }));
        var copied = await b.Slp.GetJsonAsync($"/api/v1/requests/{copy}");
        Assert.Equal("DRAFT", copied.GetProperty("request").GetProperty("head").GetProperty("phase").GetString());
        await ActAsync(b.Slp, copy, "submit");
        Assert.Null(await IssueAsync(b, copy, accA));
        var p2 = await ProformaOfAsync(b.Slp, copy);
        Assert.Equal($"002-XX05-{yy}", p2.GetProperty("proformaNo").GetString());
        Assert.Equal("SUPERSEDED", (await ProformaOfAsync(b.Slp, r1)).GetProperty("status").GetString());

        // Another company has its own sequence.
        var r3 = await SubmittedAsync(b, a2, "Second company");
        Assert.Null(await IssueAsync(b, r3, accA2));
        Assert.Equal($"001-XX02-{yy}", (await ProformaOfAsync(b.Slp, r3)).GetProperty("proformaNo").GetString());

        // The void: the preparer may not; the treasury manager does with a fresh proof; the number stays and a second void is refused.
        var p2Id = p2.GetProperty("id").GetString()!;
        Assert.Equal(403, (await b.Slp.ProblemAsync(HttpMethod.Post, $"/api/v1/sales/proformas/{p2Id}/void", new { reason = "x" })).Item1);
        await b.Tm.OkAsync(HttpMethod.Post, $"/api/v1/sales/proformas/{p2Id}/void", new { reason = "Customer changed the scope", stepUpCode = f.NextCode(b.TmSecret) });
        var voided = await ProformaOfAsync(b.Slp, copy);
        Assert.Equal(("VOID", $"002-XX05-{yy}"), (voided.GetProperty("status").GetString(), voided.GetProperty("proformaNo").GetString()));
        Assert.Equal(409, (await b.Tm.ProblemAsync(HttpMethod.Post, $"/api/v1/sales/proformas/{p2Id}/void", new { reason = "again", stepUpCode = f.NextCode(b.TmSecret) })).Item1);

        // A company without an ERP code: the issue is refused V-LCE-01 and takes no number; with the code it takes 001.
        var c = await CompanyAsync(b, "XX09", null);
        var accC = await CollectionAccountAsync(b, c, "880-3");
        var r4 = await SubmittedAsync(b, c, "No ERP code");
        Assert.Equal((422, "V-LCE-01"), await IssueAsync(b, r4, accC));
        var (_, tag) = await b.Tm.GetWithETagAsync($"/api/v1/companies/{c}");
        await b.Tm.OkAsync(HttpMethod.Patch, $"/api/v1/companies/{c}", new { erpCompanyCode = "XX09" }, tag);
        var (_, etag) = await b.Tm.GetWithETagAsync($"/api/v1/requests/{r4}");
        await b.Tm.OkAsync(HttpMethod.Post, $"/api/v1/requests/{r4}/actions/complete", new { }, etag);
        Assert.Equal($"001-XX09-{yy}", (await ProformaOfAsync(b.Tm, r4)).GetProperty("proformaNo").GetString());

        // A sales preparer sees the proformas of their own requests only; the reviewer, who raised none, sees none.
        Assert.Empty((await b.Slr.GetJsonAsync("/api/v1/sales/proformas")).GetProperty("items").EnumerateArray());
        Assert.Equal(4, (await b.Tm.GetJsonAsync("/api/v1/sales/proformas")).GetProperty("items").GetArrayLength());
    }
}
