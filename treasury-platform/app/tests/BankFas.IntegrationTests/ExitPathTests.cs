using System.Globalization;
using System.Net;
using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// The exit path of S1 (DOC-B02 section 4: "a company onboarded with its documents", AC-ORG-6; the bank wizard,
/// AC-INS-1, is InstitutionTests): the company's documents from its own tab and from the register, a document type the
/// tenant adds to its catalogue and uses at once, the expiry alert at its nearest threshold once however often the
/// job runs, and the renewal that starts the thresholds again.
/// </summary>
[Collection("database")]
public sealed class ExitPathTests(PlatformFixture f)
{
    /// <summary>A clock of its own for the expiry job, so the shared one (TOTP codes) never moves.</summary>
    private sealed class DayClock(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    [Fact]
    public async Task A_company_is_onboarded_with_its_documents_and_their_expiry_alert()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var p = t.Portal;
        var company = PlatformFixture.Id(await p.PostOkAsync("/api/v1/companies", new
        {
            companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First Company", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12, crNumber = "7001234567",
        }));
        var today = DateOnly.FromDateTime(f.Env.Clock.GetUtcNow().UtcDateTime);
        string D(DateOnly d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        var crExpiry = today.AddDays(25);

        // The commercial registration from the company's tab, the Zakat certificate from the register (FR-ORG-011, 012).
        var cr = await CompanyDocumentTests.UploadAsync(p, $"/api/v1/documents", CompanyDocumentTests.Pdf("cr"), "cr.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "COMMERCIAL_REGISTRATION", ["title"] = "CR of C1", ["company"] = company, ["documentNumber"] = "7001234567", ["expiryDate"] = D(crExpiry),
        });
        Assert.Equal(HttpStatusCode.Created, cr.StatusCode);
        var crId = JsonDocument.Parse(await cr.Content.ReadAsStringAsync(ct)).RootElement.GetProperty("id").GetString()!;
        var zakat = await CompanyDocumentTests.UploadAsync(p, "/api/v1/documents", CompanyDocumentTests.Pdf("zakat"), "zakat.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "ZAKAT_CERTIFICATE", ["title"] = "Zakat 2026", ["company"] = company, ["expiryDate"] = D(today.AddDays(200)),
        });
        Assert.Equal(HttpStatusCode.Created, zakat.StatusCode);

        // A type the tenant adds is usable at once, without a release (FR-CAT-002).
        await p.PostOkAsync("/api/v1/catalogs/document-types/items", new
        {
            code = "MUNICIPAL_LICENCE", nameAr = "رخصة البلدية", nameEn = "Municipal licence",
            fields = new Dictionary<string, object?> { ["appliesTo"] = "COMPANY", ["requiresExpiry"] = true, ["isSensitive"] = false },
        });
        var licence = await CompanyDocumentTests.UploadAsync(p, "/api/v1/documents", CompanyDocumentTests.Pdf("licence"), "licence.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "MUNICIPAL_LICENCE", ["title"] = "Licence", ["company"] = company, ["expiryDate"] = D(today.AddDays(300)),
        });
        Assert.Equal(HttpStatusCode.Created, licence.StatusCode);

        // Both screens show them; the CR expires soon, 25 days left.
        var register = (await tm.GetJsonAsync("/api/v1/documents")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal(3, register.Count);
        var crRow = register.Single(d => d.GetProperty("id").GetString() == crId);
        Assert.Equal(25, crRow.GetProperty("daysLeft").GetInt32());
        Assert.Equal("EXPIRING", crRow.GetProperty("validity").GetString());
        Assert.Equal(3, (await tm.GetJsonAsync($"/api/v1/documents?company={company}")).GetProperty("items").GetArrayLength());

        // Twice on the same day: one alert, at 30 (BR-PLT-013, FR-PLT-038).
        var job = new ExpiryAlertJob(f.Env.Db, new DayClock(f.Env.Clock.GetUtcNow()));
        await job.RunOnceAsync(ct);
        await job.RunOnceAsync(ct);
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        await outbox.RunOnceAsync(ct);
        await outbox.RunOnceAsync(ct);
        var alerts = (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray()
            .Where(n => n.GetProperty("eventCode").GetString() == "DOC.EXPIRY").ToList();
        Assert.Single(alerts);
        Assert.Contains("30", alerts[0].GetProperty("title").GetString(), StringComparison.Ordinal);

        // Renewed for a year: no alert now, and 25 days before the new date the thresholds start again.
        var (_, etag) = await p.GetWithETagAsync($"/api/v1/documents/{crId}");
        var renewedTo = crExpiry.AddYears(1);
        Assert.True((await p.SendAsync(HttpMethod.Patch, $"/api/v1/documents/{crId}", new { expiryDate = D(renewedTo) }, etag)).IsSuccessStatusCode);
        await job.RunOnceAsync(ct);
        await outbox.RunOnceAsync(ct);
        Assert.Single((await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(), n => n.GetProperty("eventCode").GetString() == "DOC.EXPIRY");
        // (The Zakat certificate and the licence expire before the renewed date; only the CR's alerts are counted below.)
        var later = new ExpiryAlertJob(f.Env.Db, new DayClock(new DateTimeOffset(renewedTo.AddDays(-25).ToDateTime(TimeOnly.MinValue), TimeSpan.Zero)));
        await later.RunOnceAsync(ct);
        await outbox.RunOnceAsync(ct);
        var all = (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray()
            .Where(n => n.GetProperty("eventCode").GetString() == "DOC.EXPIRY" && n.GetProperty("body").GetString()!.Contains("CR of C1", StringComparison.Ordinal)).ToList();
        Assert.Equal(2, all.Count);
        Assert.Contains(all, n => n.GetProperty("body").GetString()!.Contains(D(renewedTo), StringComparison.Ordinal));
    }
}
