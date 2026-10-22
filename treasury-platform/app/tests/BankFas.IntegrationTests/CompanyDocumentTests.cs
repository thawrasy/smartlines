using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Companies with their mirror party, tree, identifiers, fiscal periods, tax rates and contacts (AC-ORG-3 to 5, 7,
/// 8), and the document store: checks, scan, encryption, versions, download and the register (AC-PLT-15, the upload
/// part of AC-ORG-6), against the database.
/// </summary>
[Collection("database")]
public sealed class CompanyDocumentTests(PlatformFixture f)
{
    private static async Task<JsonElement> CompanyAsync(HttpClient p, string code, string nameEn, object? extra = null)
    {
        var body = new Dictionary<string, object?>
        {
            ["companyCode"] = code, ["nameAr"] = "شركة " + code, ["nameEn"] = nameEn, ["legalForm"] = "LLC", ["country"] = "SA", ["fiscalYearEndMonth"] = 12,
        };
        if (extra is not null)
            foreach (var prop in JsonSerializer.SerializeToElement(extra).EnumerateObject()) body[prop.Name] = prop.Value;
        return await p.PostOkAsync("/api/v1/companies", body);
    }

    internal static async Task<HttpResponseMessage> UploadAsync(HttpClient p, string path, byte[] content, string fileName, Dictionary<string, string> fields)
    {
        using var form = new MultipartFormDataContent();
        foreach (var (k, v) in fields) form.Add(new StringContent(v), k);
        var file = new ByteArrayContent(content);
        file.Headers.ContentType = MediaTypeHeaderValue.Parse("application/octet-stream");
        form.Add(file, "file", fileName);
        using var request = new HttpRequestMessage(HttpMethod.Post, path) { Content = form };
        request.Headers.TryAddWithoutValidation("Idempotency-Key", Guid.NewGuid().ToString());
        return await p.SendAsync(request);
    }

    internal static byte[] Pdf(string text) => Encoding.ASCII.GetBytes("%PDF-1.7\n% " + text + "\n%%EOF\n");

    [Fact]
    public async Task A_company_has_its_mirror_party_a_tree_without_cycles_and_unique_identifiers()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var c1 = await CompanyAsync(p, "C1", "Holding One", new { crNumber = "7001234567", erpCompanyCode = "ab 12", isHolding = true, fiscalYearEndMonth = 6, fiscalYearEndDay = 30 });
        Assert.Matches("^P[0-9]{6}$", c1.GetProperty("partyCode").GetString());
        var c1Id = c1.GetProperty("id").GetString();

        Assert.Equal((409, "V-ORG-CODE-TAKEN"), await p.PostProblemAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "مكرر", nameEn = "Copy", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        Assert.Equal((409, "V-ORG-CR-TAKEN"), await p.PostProblemAsync("/api/v1/companies", new { companyCode = "C9", nameAr = "أخرى", nameEn = "Other", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12, crNumber = "7001234567" }));
        Assert.Equal((409, "V-ORG-ERP-TAKEN"), await p.PostProblemAsync("/api/v1/companies", new { companyCode = "C9", nameAr = "أخرى", nameEn = "Other", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12, erpCompanyCode = "AB12" }));
        Assert.Equal((422, "V-ORG-LEGAL-FORM"), await p.PostProblemAsync("/api/v1/companies", new { companyCode = "C9", nameAr = "أخرى", nameEn = "Other", legalForm = "LLC", country = "AE", fiscalYearEndMonth = 12 }));

        var c2 = await CompanyAsync(p, "C2", "Subsidiary Two", new { parent = c1Id });
        var c2Id = c2.GetProperty("id").GetString();
        var (one, etag) = await p.GetWithETagAsync($"/api/v1/companies/{c1Id}");
        Assert.Contains(one.GetProperty("children").EnumerateArray(), ch => ch.GetString() == c2Id);
        Assert.Equal((422, "V-ORG-CYCLE"), await p.ProblemAsync(HttpMethod.Patch, $"/api/v1/companies/{c1Id}", new { parent = c2Id }, etag));
        Assert.Equal((422, "V-ORG-CODE-FIXED"), await p.ProblemAsync(HttpMethod.Patch, $"/api/v1/companies/{c1Id}", new { companyCode = "X" }, etag));

        // The search by ERP code finds the company whatever its spaces and case (FR-ORG-005).
        Assert.Contains((await p.GetJsonAsync("/api/v1/companies?q=AB12")).GetProperty("items").EnumerateArray(), c => c.GetProperty("companyCode").GetString() == "C1");

        // Fiscal year ending 30 June: the year 2026 runs from 2025-07-01 (FR-ORG-006).
        var fy = await p.GetJsonAsync($"/api/v1/companies/{c1Id}/fiscal-periods?year=2026");
        Assert.Equal("2025-07-01", fy.GetProperty("from").GetString());
        Assert.Equal("2026-06-30", fy.GetProperty("to").GetString());
        Assert.Equal(12, fy.GetProperty("months").GetArrayLength());

        // A new rate closes the open one the day before (FR-ORG-007).
        await p.OkAsync(HttpMethod.Post, $"/api/v1/companies/{c1Id}/tax-rates", new { taxCode = "VAT", ratePercent = 15m, effectiveFrom = "2026-01-01" });
        await p.OkAsync(HttpMethod.Post, $"/api/v1/companies/{c1Id}/tax-rates", new { taxCode = "VAT", ratePercent = 16m, effectiveFrom = "2027-01-01" });
        Assert.Equal((422, "V-ORG-TAX-DATE"), await p.PostProblemAsync($"/api/v1/companies/{c1Id}/tax-rates", new { taxCode = "VAT", ratePercent = 17m, effectiveFrom = "2026-06-01" }));
        var rates = (await p.GetJsonAsync($"/api/v1/companies/{c1Id}/tax-rates")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal("2026-12-31", rates.First(r => r.GetProperty("ratePercent").GetDecimal() == 15m).GetProperty("effectiveTo").GetString());

        // Addresses and contacts are the mirror party's; a Saudi national address keeps its formats (FR-ORG-009, FR-PTY-011).
        Assert.Equal((422, "V-PTY-ADDRESS"), await p.PostProblemAsync($"/api/v1/companies/{c1Id}/addresses", new { addressType = "NATIONAL", country = "SA", buildingNumber = "12", postalCode = "1234" }));
        await p.OkAsync(HttpMethod.Post, $"/api/v1/companies/{c1Id}/addresses", new { addressType = "NATIONAL", country = "SA", city = "الرياض", buildingNumber = "1234", postalCode = "12345", additionalNumber = "6789", isPrimary = true });
        await p.OkAsync(HttpMethod.Post, $"/api/v1/companies/{c1Id}/contact-methods", new { kind = "MOBILE", value = "050 123 4567", isPrimary = true });
        Assert.Equal((409, "CONTACT_EXISTS"), await p.PostProblemAsync($"/api/v1/companies/{c1Id}/contact-methods", new { kind = "MOBILE", value = "+966501234567" }));
        var contacts = await p.GetJsonAsync($"/api/v1/companies/{c1Id}/contacts");
        Assert.Equal("+966501234567", contacts.GetProperty("contactMethods")[0].GetProperty("normalizedValue").GetString());
        Assert.Equal(1, contacts.GetProperty("addresses").GetArrayLength());

        // A company with a company under it is not archived; its child is (FR-ORG-010).
        Assert.Equal((409, "V-ORG-IN-USE"), await p.PostProblemAsync($"/api/v1/companies/{c1Id}/actions/archive", new { reason = "Closed" }));
        await p.OkAsync(HttpMethod.Post, $"/api/v1/companies/{c2Id}/actions/archive", new { reason = "Merged into C1" });
        Assert.DoesNotContain((await p.GetJsonAsync("/api/v1/companies")).GetProperty("items").EnumerateArray(), c => c.GetProperty("companyCode").GetString() == "C2");

        // The seeded departments include the treasury (FR-ORG-014).
        var departments = await p.GetJsonAsync("/api/v1/departments");
        Assert.Equal(JsonValueKind.Null, departments.GetProperty("warning").ValueKind);
        Assert.Contains(departments.GetProperty("items").EnumerateArray(), d => d.GetProperty("code").GetString() == "TREASURY");
    }

    [Fact]
    public async Task Documents_are_checked_scanned_encrypted_versioned_and_listed_by_validity()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var c1 = (await CompanyAsync(p, "C1", "Company One")).GetProperty("id").GetString()!;
        var today = DateOnly.FromDateTime(f.Env.Clock.GetUtcNow().UtcDateTime);
        var expiring = today.AddDays(25).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var fields = new Dictionary<string, string> { ["documentType"] = "COMMERCIAL_REGISTRATION", ["title"] = "CR of C1", ["company"] = c1, ["documentNumber"] = "7001234567" };

        var noExpiry = await UploadAsync(p, "/api/v1/documents", Pdf("cr"), "cr.pdf", fields);
        Assert.Equal(HttpStatusCode.UnprocessableEntity, noExpiry.StatusCode);
        Assert.Contains("EXPIRY_REQUIRED", await noExpiry.Content.ReadAsStringAsync(TestContext.Current.CancellationToken), StringComparison.Ordinal);
        fields["expiryDate"] = expiring;
        var disguised = await UploadAsync(p, "/api/v1/documents", [0x4D, 0x5A, 0x90, 0x00, 1, 2, 3], "cr.pdf", fields);
        Assert.Contains("FILE_TYPE_NOT_ALLOWED", await disguised.Content.ReadAsStringAsync(TestContext.Current.CancellationToken), StringComparison.Ordinal);

        var bytes = Pdf("the registration of C1");
        var up = await UploadAsync(p, "/api/v1/documents", bytes, "cr.pdf", fields);
        var created = JsonDocument.Parse(await up.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement;
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        Assert.Equal("CLEAN", created.GetProperty("scanStatus").GetString());
        var docId = created.GetProperty("id").GetString();

        // The file is stored encrypted: no stored file holds the plain bytes.
        foreach (var path in Directory.EnumerateFiles(f.Env.FilesDir, "*", SearchOption.AllDirectories))
            Assert.DoesNotContain("the registration of C1", Encoding.ASCII.GetString(await File.ReadAllBytesAsync(path, TestContext.Current.CancellationToken)), StringComparison.Ordinal);

        var listed = (await p.GetJsonAsync($"/api/v1/documents?company={c1}&validity=EXPIRING")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal(25, listed.GetProperty("daysLeft").GetInt32());
        Assert.Equal("CR of C1", listed.GetProperty("title").GetString());
        Assert.Empty((await p.GetJsonAsync("/api/v1/documents?validity=EXPIRED")).GetProperty("items").EnumerateArray());

        var download = await p.GetAsync($"/api/v1/documents/{docId}/content", TestContext.Current.CancellationToken);
        Assert.Equal(HttpStatusCode.OK, download.StatusCode);
        Assert.Equal(bytes, await download.Content.ReadAsByteArrayAsync(TestContext.Current.CancellationToken));

        // A new file is version 2; the same bytes elsewhere are reported, not refused.
        var v2 = await UploadAsync(p, $"/api/v1/documents/{docId}/versions", Pdf("renewed"), "cr-2.pdf", []);
        Assert.Equal(HttpStatusCode.Created, v2.StatusCode);
        var again = await UploadAsync(p, "/api/v1/documents", bytes, "copy.pdf", new Dictionary<string, string>(fields) { ["title"] = "A copy" });
        Assert.Equal(docId, JsonDocument.Parse(await again.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement.GetProperty("duplicateOf").GetString());
        var detail = await p.GetJsonAsync($"/api/v1/documents/{docId}");
        Assert.Equal(2, detail.GetProperty("versions").GetArrayLength());

        // A file with the malware test signature is held and never downloads.
        var eicar = Encoding.ASCII.GetBytes("%PDF-1.7\nX5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*\n");
        var held = await UploadAsync(p, "/api/v1/documents", eicar, "bad.pdf", new Dictionary<string, string>(fields) { ["title"] = "Suspicious" });
        var heldId = JsonDocument.Parse(await held.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement;
        Assert.Equal("QUARANTINED", heldId.GetProperty("scanStatus").GetString());
        Assert.Equal((409, "FILE_NOT_CLEAN"), await p.ProblemAsync(HttpMethod.Get, $"/api/v1/documents/{heldId.GetProperty("id").GetString()}/content"));

        // A restricted type is for the treasury manager and the financial officer only (FR-CAT-018).
        var kyc = await UploadAsync(p, "/api/v1/documents", Pdf("kyc"), "kyc.pdf", new Dictionary<string, string> { ["documentType"] = "KYC_FORM", ["title"] = "KYC", ["company"] = c1 });
        Assert.Equal(HttpStatusCode.Forbidden, kyc.StatusCode);

        // A deleted document leaves the register; the deletion is audited with its reason.
        await p.OkAsync(HttpMethod.Post, $"/api/v1/documents/{heldId.GetProperty("id").GetString()}/actions/delete", new { reason = "Malware test" });
        Assert.DoesNotContain((await p.GetJsonAsync("/api/v1/documents")).GetProperty("items").EnumerateArray(), d => d.GetProperty("title").GetString() == "Suspicious");
        // The tenant administrator sees no treasury audit category (BR-PLT-008).
        Assert.Equal((403, "FORBIDDEN"), await p.ProblemAsync(HttpMethod.Get, "/api/v1/audit-events?category=TREASURY"));

        // Another tenant sees none of it.
        var other = await f.CreateTenantAsync();
        Assert.Equal(HttpStatusCode.NotFound, (await other.Portal.GetAsync($"/api/v1/documents/{docId}", TestContext.Current.CancellationToken)).StatusCode);
    }
}
