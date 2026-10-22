using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Persons and entities (AC-PTY-1, AC-PTY-2, AC-PTY-4 to 9): the encrypted, masked and blind-indexed identity numbers,
/// the reveal and its log, renewal, the verified flag, images, custom fields, the duplicate check and the merge,
/// against the database.
/// </summary>
[Collection("database")]
public sealed class PartyTests(PlatformFixture f)
{
    private static async Task<string> PartyAsync(HttpClient p, string nameAr, string nameEn, string birthDate, bool confirm = false) =>
        PlatformFixture.Id(await p.PostOkAsync("/api/v1/parties", new
        {
            kind = "INDIVIDUAL", nameAr, nameEn, country = "SA", residencyStatus = "CITIZEN", birthDate, confirmDuplicate = confirm,
        }));

    private static async Task<JsonElement> DetailAsync(HttpClient p, string id) => await p.GetJsonAsync($"/api/v1/parties/{id}");

    [Fact]
    public async Task Identity_numbers_are_masked_found_by_blind_index_revealed_with_a_log_and_renewed()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");

        var a = await PartyAsync(tm, "أحمد عبدالله", "Ahmad Abdullah", "1985-03-02");
        // The same normalised name and birth date asks for a confirmation (BR-PTY-004).
        Assert.Equal((409, "V-PTY-POSSIBLE-DUPLICATE"), await tm.PostProblemAsync("/api/v1/parties",
            new { kind = "INDIVIDUAL", nameAr = "احمد عبدالله", country = "SA", birthDate = "1985-03-02" }));

        // The national ID becomes the primary document of a Saudi citizen (FR-PTY-005); shown masked to the last four.
        var added = await tm.PostOkAsync($"/api/v1/parties/{a}/identity-documents", new { docKind = "NATIONAL_ID", issuingCountry = "SA", number = "1012345678", expiryDate = "2030-01-01" });
        Assert.Empty(added.GetProperty("warnings").EnumerateArray());
        var doc = PlatformFixture.Id(added);
        var detail = await DetailAsync(tm, a);
        var nid = detail.GetProperty("identityDocuments")[0];
        Assert.Equal("******5678", nid.GetProperty("number").GetString());
        Assert.True(nid.GetProperty("isPrimary").GetBoolean());
        Assert.DoesNotContain("1012345678", detail.GetRawText(), StringComparison.Ordinal);

        // Found by the exact number (Arabic digits too) and by the name in another spelling, without decrypting (FR-PTY-002).
        Assert.Single((await te.GetJsonAsync("/api/v1/parties?number=١٠١٢٣٤٥٦٧٨&docKind=NATIONAL_ID&country=SA")).GetProperty("items").EnumerateArray());
        Assert.Single((await te.GetJsonAsync("/api/v1/parties?number=1012345678&country=SA")).GetProperty("items").EnumerateArray());
        Assert.Contains((await te.GetJsonAsync("/api/v1/parties?q=" + Uri.EscapeDataString("احمد"))).GetProperty("items").EnumerateArray(), x => PlatformFixture.Id(x) == a);

        // The same number on another party is refused (BR-PTY-003); a number outside the format is a warning (FR-PTY-010).
        var b = await PartyAsync(tm, "سارة محمد", "Sara Mohammed", "1990-07-07");
        Assert.Equal((409, "V-PTY-DUPLICATE-NUMBER"), await tm.PostProblemAsync($"/api/v1/parties/{b}/identity-documents", new { docKind = "NATIONAL_ID", issuingCountry = "SA", number = "1012345678" }));
        var odd = await tm.PostOkAsync($"/api/v1/parties/{b}/identity-documents", new { docKind = "NATIONAL_ID", issuingCountry = "SA", number = "9988" });
        Assert.Equal("NUMBER_FORMAT", odd.GetProperty("warnings")[0].GetString());
        // A passport as the primary document of a citizen needs a reason.
        Assert.Equal((422, "V-PTY-PRIMARY-REASON"), await tm.PostProblemAsync($"/api/v1/parties/{a}/identity-documents", new { docKind = "PASSPORT", issuingCountry = "SA", number = "A1234567", isPrimary = true }));

        // The reveal: the treasury manager sees the number, the treasury employee is refused; both are logged (FR-PTY-007, 008).
        var revealed = await tm.PostOkAsync($"/api/v1/parties/{a}/identity-documents/{doc}/actions/reveal", new { reason = "Bank form" });
        Assert.Equal("1012345678", revealed.GetProperty("number").GetString());
        Assert.Equal(60, revealed.GetProperty("remaskSeconds").GetInt32());
        Assert.Equal((403, "FORBIDDEN"), await te.PostProblemAsync($"/api/v1/parties/{a}/identity-documents/{doc}/actions/reveal", new { }));
        var log = (await t.Portal.GetJsonAsync("/api/v1/audit-events?category=IDENTITY_ACCESS&limit=200")).GetProperty("items").EnumerateArray().Select(e => e.GetProperty("action").GetString()).ToList();
        Assert.Contains("IDENTITY_REVEALED", log);
        Assert.Contains("IDENTITY_REVEAL_DENIED", log);

        // Verified, then a new expiry date clears the flag (FR-PTY-020).
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/parties/{a}/identity-documents/{doc}/actions/verify", new { });
        var etag = (await DetailAsync(tm, a)).GetProperty("identityDocuments")[0].GetProperty("etag").GetString();
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Patch, $"/api/v1/parties/{a}/identity-documents/{doc}", new { expiryDate = "2031-01-01" }, etag)).StatusCode);
        Assert.False((await DetailAsync(tm, a)).GetProperty("identityDocuments")[0].GetProperty("verified").GetBoolean());

        // The renewal: the same number again, a new document that is primary; the old one stays, superseded (FR-PTY-022).
        var renewed = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/parties/{a}/identity-documents/{doc}/actions/renew", new { number = "1012345678", expiryDate = "2036-01-01" }));
        var docs = (await DetailAsync(tm, a)).GetProperty("identityDocuments").EnumerateArray().ToList();
        Assert.Equal(2, docs.Count);
        var old = docs.First(d => PlatformFixture.Id(d) == doc);
        Assert.True(old.GetProperty("isSuperseded").GetBoolean());
        Assert.Equal(renewed, old.GetProperty("supersededBy").GetString());
        Assert.True(docs.First(d => PlatformFixture.Id(d) == renewed).GetProperty("isPrimary").GetBoolean());

        // An image is a restricted document: the treasury manager sees it, the employee sees only that there is one (FR-PTY-009).
        var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4 };
        var image = await CompanyDocumentTests.UploadAsync(tm, $"/api/v1/parties/{a}/identity-documents/{renewed}/images", png, "front.png", new Dictionary<string, string> { ["side"] = "FRONT" });
        Assert.Equal(HttpStatusCode.Created, image.StatusCode);
        var tmView = (await DetailAsync(tm, a)).GetProperty("identityDocuments").EnumerateArray().First(d => PlatformFixture.Id(d) == renewed);
        Assert.Equal("IMAGE_FRONT", tmView.GetProperty("images")[0].GetProperty("side").GetString());
        var teView = (await DetailAsync(te, a)).GetProperty("identityDocuments").EnumerateArray().First(d => PlatformFixture.Id(d) == renewed);
        Assert.Equal(JsonValueKind.Null, teView.GetProperty("images").ValueKind);
        Assert.Equal(1, teView.GetProperty("imageCount").GetInt32());
        var imageId = tmView.GetProperty("images")[0].GetProperty("document").GetString();
        Assert.Equal(HttpStatusCode.OK, (await tm.GetAsync($"/api/v1/documents/{imageId}/content", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await te.GetAsync($"/api/v1/documents/{imageId}/content", TestContext.Current.CancellationToken)).StatusCode);
    }

    [Fact]
    public async Task Custom_fields_duplicates_merge_and_the_mirror_party()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");

        // A restricted custom field is encrypted and masked; its reveal is logged (FR-PTY-013, 014).
        await tm.PostOkAsync("/api/v1/custom-field-definitions", new { fieldKey = "monthly_salary", labelAr = "الراتب الشهري", labelEn = "Monthly salary", dataType = "NUMBER", sensitivity = "RESTRICTED", appliesToKind = "INDIVIDUAL" });
        await tm.PostOkAsync("/api/v1/custom-field-definitions", new { fieldKey = "segment", labelAr = "الشريحة", labelEn = "Segment", dataType = "LIST", listValues = new[] { "VIP", "STANDARD" } });
        var a = await PartyAsync(tm, "خالد سعيد", "Khalid Saeed", "1980-01-01");
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Put, $"/api/v1/parties/{a}/custom-fields/monthly_salary", new { value = 15250 })).StatusCode);
        Assert.Equal((422, "V-PTY-FIELD-VALUE"), await tm.ProblemAsync(HttpMethod.Put, $"/api/v1/parties/{a}/custom-fields/segment", new { value = "GOLD" }));
        await tm.OkAsync(HttpMethod.Put, $"/api/v1/parties/{a}/custom-fields/segment", new { value = "VIP" });
        var fields = (await DetailAsync(tm, a)).GetProperty("customFields").EnumerateArray().ToList();
        Assert.Equal("*5250", fields.First(x => x.GetProperty("key").GetString() == "monthly_salary").GetProperty("value").GetString());
        Assert.Equal("VIP", fields.First(x => x.GetProperty("key").GetString() == "segment").GetProperty("value").GetString());
        Assert.Equal("15250", (await tm.PostOkAsync($"/api/v1/parties/{a}/custom-fields/monthly_salary/actions/reveal", new { })).GetProperty("value").GetString());

        // A duplicate created on purpose is listed, then merged: its document and contacts move, it never comes back (FR-PTY-015, 016).
        var dup = await PartyAsync(tm, "خالد سعيد", "Khalid Saeed", "1980-01-01", confirm: true);
        await tm.PostOkAsync($"/api/v1/parties/{dup}/identity-documents", new { docKind = "NATIONAL_ID", issuingCountry = "SA", number = "1099887766" });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/parties/{dup}/contact-methods", new { kind = "EMAIL", value = "Khalid@Example.com" });
        Assert.Contains((await tm.GetJsonAsync("/api/v1/parties/duplicates")).GetProperty("items").EnumerateArray(),
            p => new[] { p.GetProperty("a").GetProperty("id").GetString(), p.GetProperty("b").GetProperty("id").GetString() }.Order().SequenceEqual(new[] { a, dup }.Order()));
        var merged = await tm.PostOkAsync($"/api/v1/parties/{dup}/actions/merge", new { into = a, reason = "Same person" });
        Assert.Equal(a, merged.GetProperty("into").GetString());
        var survivor = await DetailAsync(tm, a);
        Assert.Single(survivor.GetProperty("identityDocuments").EnumerateArray());
        Assert.Equal("khalid@example.com", survivor.GetProperty("contacts").GetProperty("contactMethods")[0].GetProperty("normalizedValue").GetString());
        var gone = (await DetailAsync(tm, dup)).GetProperty("party");
        Assert.False(gone.GetProperty("isActive").GetBoolean());
        Assert.Equal(a, gone.GetProperty("mergedInto").GetString());

        // A company's mirror party: read-only, never merged, and in use, so it stays active (FR-PTY-003, 018).
        var company = await tm.PostOkAsync("/api/v1/companies", new { companyCode = "M1", nameAr = "شركة المرآة", nameEn = "Mirror Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 });
        var mirror = PlatformFixture.Id((await tm.GetJsonAsync("/api/v1/parties?q=Mirror&kind=ORGANIZATION")).GetProperty("items")[0]);
        var (mirrorDetail, mirrorEtag) = await tm.GetWithETagAsync($"/api/v1/parties/{mirror}");
        Assert.Equal(company.GetProperty("id").GetString(), mirrorDetail.GetProperty("party").GetProperty("mirrorOfCompany").GetString());
        Assert.Contains(mirrorDetail.GetProperty("roles").EnumerateArray(), r => r.GetProperty("role").GetString() == "COMPANY");
        Assert.Equal((409, "V-PTY-MIRROR"), await tm.ProblemAsync(HttpMethod.Patch, $"/api/v1/parties/{mirror}", new { nameEn = "Other" }, mirrorEtag));
        Assert.Equal((409, "V-PTY-IN-USE"), await tm.PostProblemAsync($"/api/v1/parties/{mirror}/actions/deactivate", new { }));
        var org = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new { kind = "ORGANIZATION", nameEn = "Mirror Co Copy", country = "SA" }));
        Assert.Equal((409, "V-PTY-MIRROR"), await tm.PostProblemAsync($"/api/v1/parties/{org}/actions/merge", new { into = mirror, reason = "Same" }));
    }
}
