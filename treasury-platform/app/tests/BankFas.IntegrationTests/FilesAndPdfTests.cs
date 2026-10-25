using System.Globalization;
using System.Net;
using System.Text;

namespace BankFas.IntegrationTests;

/// <summary>
/// Files and PDF (docs/31 row 52): a requester uploads a file straight onto their request (an approval of an authorised
/// person), sees and downloads it, and a type that is not for requests is refused; the request prints as HTML with its
/// watermark, as PDF, and its PDF is saved with it; the treasury files a SWIFT copy on a received credit and the sales
/// may not; the issued proforma's current version is its PDF and version 1 its sealed HTML; the terms and a report come
/// as PDF. Without Chromium the PDF answers are 503 PDF_UNAVAILABLE, and the PDF checks are skipped.
/// </summary>
[Collection("database")]
public sealed class FilesAndPdfTests(PlatformFixture f)
{
    private static async Task<bool> IsPdfAsync(HttpResponseMessage response)
    {
        if (response.StatusCode == HttpStatusCode.ServiceUnavailable) return false;
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal("application/pdf", response.Content.Headers.ContentType?.MediaType);
        var bytes = await response.Content.ReadAsByteArrayAsync(TestContext.Current.CancellationToken);
        Assert.Equal("%PDF", Encoding.ASCII.GetString(bytes, 0, 4));
        return true;
    }

    private static bool PdfExpected => !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("Pdf__Chromium")) || File.Exists("/opt/pw-browsers/chromium");

    [Fact]
    public async Task A_requester_attaches_files_and_the_request_prints_and_saves_as_pdf()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (rq, _, _) = await f.UserWithRoleAsync(t, "RQ");
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "FP1", nameAr = "شركة الملفات", nameEn = "Files Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var id = PlatformFixture.Id(await rq.PostOkAsync("/api/v1/requests", new { type = "GENERIC_SIMPLE", company, data = new { title = "Bank letter", notes = "With the approval" } }));

        var bytes = CompanyDocumentTests.Pdf("approval of the CFO");
        var up = await CompanyDocumentTests.UploadAsync(rq, $"/api/v1/requests/{id}/attachments/upload", bytes, "approval.pdf",
            new Dictionary<string, string> { ["documentType"] = "AUTHORITY_APPROVAL", ["title"] = "Approval of the CFO" });
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        var wrong = await CompanyDocumentTests.UploadAsync(rq, $"/api/v1/requests/{id}/attachments/upload", bytes, "cr.pdf",
            new Dictionary<string, string> { ["documentType"] = "COMMERCIAL_REGISTRATION", ["title"] = "CR" });
        Assert.Equal(HttpStatusCode.UnprocessableEntity, wrong.StatusCode);

        var detail = (await rq.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("request");
        var file = detail.GetProperty("attachments").EnumerateArray().Single();
        Assert.Equal(("AUTHORITY_APPROVAL", "REQUESTER_VISIBLE"), (file.GetProperty("documentType").GetString(), file.GetProperty("visibility").GetString()));
        var content = await rq.GetAsync($"/api/v1/documents/{file.GetProperty("document").GetString()}/content", ct);
        Assert.Equal(bytes, await content.Content.ReadAsByteArrayAsync(ct));
        Assert.True(detail.GetProperty("canAttach").GetBoolean());

        // The print: the request's reference and the watermark; then the PDF, and the PDF saved with the request.
        var draftRef = detail.GetProperty("draftRef").GetString()!;
        var html = await (await rq.GetAsync($"/api/v1/requests/{id}/print?lang=en", ct)).Content.ReadAsStringAsync(ct);
        Assert.Contains(draftRef, html, StringComparison.Ordinal);
        Assert.Contains("Printed copy", html, StringComparison.Ordinal);
        Assert.Contains("Approval of the CFO", html, StringComparison.Ordinal);
        Assert.Equal((422, "VALIDATION_FAILED"), await rq.ProblemAsync(HttpMethod.Get, $"/api/v1/requests/{id}/print?format=docx"));
        var pdf = await IsPdfAsync(await rq.GetAsync($"/api/v1/requests/{id}/print?format=pdf", ct));
        Assert.Equal(PdfExpected, pdf);
        if (pdf)
        {
            var saved = await rq.SendAsync(HttpMethod.Post, $"/api/v1/requests/{id}/print/save", new { });
            Assert.Equal(HttpStatusCode.Created, saved.StatusCode);
            var files = (await tm.GetJsonAsync($"/api/v1/requests/{id}")).GetProperty("request").GetProperty("attachments").EnumerateArray().ToList();
            Assert.Equal(2, files.Count);
            Assert.Contains(files, x => x.GetProperty("documentType").GetString() == "REQUEST_PRINT");
        }
    }

    [Fact]
    public async Task The_credit_keeps_its_swift_and_the_proforma_terms_and_reports_come_as_pdf()
    {
        var ct = TestContext.Current.CancellationToken;
        var b = await ProformaTests.BedAsync(f);
        var company = await ProformaTests.CompanyAsync(b, "FP2", "FP02");
        var account = await ProformaTests.CollectionAccountAsync(b, company, "770-1");
        var r = await ProformaTests.SubmittedAsync(b, company, "Files");
        Assert.Null(await ProformaTests.IssueAsync(b, r, account));
        var proforma = await ProformaTests.ProformaOfAsync(b.Tm, r);
        var card = (await b.Tm.GetJsonAsync($"/api/v1/sales/proformas/{proforma.GetProperty("id").GetString()}")).GetProperty("proforma");
        var doc = card.GetProperty("documentId").GetString()!;
        if (PdfExpected) Assert.True(await IsPdfAsync(await b.Tm.GetAsync($"/api/v1/documents/{doc}/content", ct)));
        Assert.Contains("<html", await (await b.Tm.GetAsync($"/api/v1/documents/{doc}/content?version=1", ct)).Content.ReadAsStringAsync(ct), StringComparison.OrdinalIgnoreCase);
        if (PdfExpected)
        {
            Assert.True(await IsPdfAsync(await b.Tm.GetAsync($"/api/v1/requests/{r}/terms/print?format=pdf", ct)));
            Assert.True(await IsPdfAsync(await b.Tm.GetAsync("/api/v1/reports/R-LCE-03/export?format=pdf", ct)));
        }

        // A credit received against the proforma; the treasury files its SWIFT copy, the sales may not.
        var today = f.Env.Clock.GetUtcNow().UtcDateTime.Date;
        string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var lc = PlatformFixture.Id(await b.Tm.PostOkAsync("/api/v1/sales/lcs", new Dictionary<string, object?>
        {
            ["company"] = company, ["lcNumber"] = "SWF-1", ["customer"] = b.Customer, ["institution"] = b.Bank, ["receivedDate"] = D(today),
            ["proforma"] = proforma.GetProperty("id").GetString(),
            ["terms"] = new Dictionary<string, object?>
            {
                ["amount"] = 4_000_000, ["expiryRule"] = "ABSOLUTE", ["expiryDate"] = D(today.AddDays(90)), ["expiryDaysAfterIssue"] = null, ["latestShipmentRule"] = "ABSOLUTE",
                ["latestShipmentDate"] = D(today.AddDays(60)), ["latestShipmentDaysAfterIssue"] = null, ["availableWith"] = "ADVISING_BANK", ["confirmation"] = "CONFIRMED",
                ["advisingBankName"] = "Sales Bank", ["advisingBankAddress"] = "Riyadh", ["advisingBankBic"] = "SALBSARI",
            },
        }));
        var swift = CompanyDocumentTests.Pdf("MT700");
        var filed = await CompanyDocumentTests.UploadAsync(b.Tm, $"/api/v1/sales/lcs/{lc}/documents/upload", swift, "mt700.pdf",
            new Dictionary<string, string> { ["documentType"] = "LC_SWIFT_COPY", ["title"] = "MT700 of SWF-1" });
        Assert.Equal(HttpStatusCode.Created, filed.StatusCode);
        var refused = await CompanyDocumentTests.UploadAsync(b.Slp, $"/api/v1/sales/lcs/{lc}/documents/upload", swift, "mt700.pdf",
            new Dictionary<string, string> { ["documentType"] = "LC_SWIFT_COPY", ["title"] = "x" });
        Assert.Equal(HttpStatusCode.Forbidden, refused.StatusCode);
        var notLc = await CompanyDocumentTests.UploadAsync(b.Tm, $"/api/v1/sales/lcs/{lc}/documents/upload", swift, "x.pdf",
            new Dictionary<string, string> { ["documentType"] = "COMMERCIAL_REGISTRATION", ["title"] = "x" });
        Assert.Equal(HttpStatusCode.UnprocessableEntity, notLc.StatusCode);
        var docs = (await b.Tm.GetJsonAsync($"/api/v1/sales/lcs/{lc}")).GetProperty("documents").EnumerateArray().ToList();
        Assert.Contains(docs, x => x.GetProperty("type").GetString() == "LC_SWIFT_COPY" && x.GetProperty("source").GetString() == "LC");
    }
}
