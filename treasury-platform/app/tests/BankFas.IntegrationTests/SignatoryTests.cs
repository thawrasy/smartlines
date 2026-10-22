using System.Net;
using System.Text.Json;
using BankFas.Data.Jobs;
using Microsoft.Data.SqlClient;

namespace BankFas.IntegrationTests;

/// <summary>
/// Bank signatories (S1-b brief, batch S1B-D; FR-ACC-012 to 017, 019, 022, 023): a natural person per relationship,
/// activated by a clean authorisation document; authorities on the bank or an account, superseded rather than edited
/// (061 denies the update); SVC-03 with its account, master and bank levels (AC-ACC-2); the expiry alerts of the earliest
/// date, the EXPIRED status the day after and the account left without a signatory (AC-ACC-4); the specimen image
/// (AC-ACC-6); and the closing of a relationship that revokes its signatories (owner default OQ-16).
/// </summary>
[Collection("database")]
public sealed class SignatoryTests(PlatformFixture f)
{
    private sealed class DayClock(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    private sealed record Setup(string Company, string Bank, string Relationship, string X, string Y, string V, string Doc);

    private static async Task<Setup> SetupAsync(HttpClient tm, string suffix = "")
    {
        var ct = TestContext.Current.CancellationToken;
        var co = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1" + suffix, nameAr = "شركة " + suffix, nameEn = "Company " + suffix, legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1" + suffix, nameAr = "البنك الأول", nameEn = "First Bank", type = "BANK", country = "SA" }));
        var rel = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/relationships", new { company = co, institution = bank }));
        var x = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new { company = co, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "1000-0001" }));
        var y = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new { company = co, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "1000-0002" }));
        var v = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new { company = co, institution = bank, type = "VIRTUAL", currency = "SAR", accountNumber = "V-0001", master = x }));
        var up = await CompanyDocumentTests.UploadAsync(tm, "/api/v1/documents", CompanyDocumentTests.Pdf("resolution"), "resolution.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "BOARD_RESOLUTION", ["title"] = "Signing resolution", ["company"] = co,
        });
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        var doc = JsonDocument.Parse(await up.Content.ReadAsStringAsync(ct)).RootElement.GetProperty("id").GetString()!;
        return new Setup(co, bank, rel, x, y, v, doc);
    }

    private static async Task<string> PersonAsync(HttpClient c, string en) =>
        PlatformFixture.Id(await c.PostOkAsync("/api/v1/parties", new { kind = "INDIVIDUAL", nameAr = "مفوض " + en, nameEn = en, country = "SA", residencyStatus = "CITIZEN" }));

    private static async Task<JsonElement> EffectiveAsync(HttpClient c, string signatory, string account, string date) =>
        await c.GetJsonAsync($"/api/v1/services/effective-authority?signatory={signatory}&account={account}&operation=TRANSFERS&date={date}");

    [Fact]
    public async Task AC_ACC_2_the_effective_authority_by_account_master_and_bank()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var s = await SetupAsync(tm);
        var sg1 = await PersonAsync(tm, "SG1");

        // BR-ACC-008: an entity is not a signatory.
        var entity = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new { kind = "ORGANIZATION", nameAr = "جهة", nameEn = "Entity", country = "SA" }));
        Assert.Equal((422, "V-ACC-SIGNATORY-PERSON"), await tm.PostProblemAsync($"/api/v1/relationships/{s.Relationship}/signatories",
            new { party = entity, signatureClass = "A", validFrom = "2024-01-01" }));
        // BR-ACC-009: PENDING without the document, ACTIVE once a clean one is attached.
        var created = await tm.PostOkAsync($"/api/v1/relationships/{s.Relationship}/signatories", new { party = sg1, signatureClass = "A", validFrom = "2024-01-01" });
        Assert.Equal("PENDING", created.GetProperty("status").GetString());
        var sig = PlatformFixture.Id(created);
        var (_, etag) = await tm.GetWithETagAsync($"/api/v1/signatories/{sig}");
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Patch, $"/api/v1/signatories/{sig}", new { authorizationDocument = s.Doc }, etag)).StatusCode);
        Assert.Equal("ACTIVE", (await tm.GetJsonAsync($"/api/v1/signatories/{sig}")).GetProperty("status").GetString());
        Assert.Equal((422, "V-ACC-SIGNATORY-OVERLAP"), await tm.PostProblemAsync($"/api/v1/relationships/{s.Relationship}/signatories",
            new { party = sg1, signatureClass = "A", validFrom = "2025-01-01" }));

        // TRANSFERS on the bank at 1,000,000 and on X at 250,000.
        var url = $"/api/v1/signatories/{sig}/authorities";
        await tm.PostOkAsync(url, new { operationType = "TRANSFERS", ceilingMode = "LIMITED", maxPerTransaction = 1_000_000, currency = "SAR", validFrom = "2024-01-01" });
        await tm.PostOkAsync(url, new { account = s.X, operationType = "TRANSFERS", ceilingMode = "LIMITED", maxPerTransaction = 250_000, currency = "SAR", validFrom = "2024-01-01" });
        var onX = await EffectiveAsync(tm, sig, s.X, "2026-10-10");
        Assert.Equal(("ACCOUNT", 250_000m), (onX.GetProperty("level").GetString(), onX.GetProperty("authority").GetProperty("maxPerTransaction").GetDecimal()));
        var onY = await EffectiveAsync(tm, sig, s.Y, "2026-10-10");
        Assert.Equal(("BANK", 1_000_000m), (onY.GetProperty("level").GetString(), onY.GetProperty("authority").GetProperty("maxPerTransaction").GetDecimal()));
        var onV = await EffectiveAsync(tm, sig, s.V, "2026-10-10");
        Assert.Equal(("MASTER", 250_000m), (onV.GetProperty("level").GetString(), onV.GetProperty("authority").GetProperty("maxPerTransaction").GetDecimal()));

        // V-ACC-05: a daily limit below the ceiling, an operation that takes no ceiling, an account of another relationship.
        Assert.Equal((422, "V-ACC-05"), await tm.PostProblemAsync(url, new { operationType = "WITHDRAW", ceilingMode = "LIMITED", maxPerTransaction = 500, dailyLimit = 100, currency = "SAR", validFrom = "2024-01-01" }));
        Assert.Equal((422, "V-ACC-05"), await tm.PostProblemAsync(url, new { operationType = "DEPOSIT", ceilingMode = "LIMITED", maxPerTransaction = 500, currency = "SAR", validFrom = "2024-01-01" }));
        var other = await SetupAsync(tm, "B");
        Assert.Equal((422, "V-ACC-05"), await tm.PostProblemAsync(url, new { account = other.X, operationType = "WITHDRAW", ceilingMode = "UNLIMITED", validFrom = "2024-01-01" }));

        // FR-ACC-017: a change closes the old row the day before; the history answers for its own dates.
        await tm.PostOkAsync(url, new { operationType = "TRANSFERS", ceilingMode = "LIMITED", maxPerTransaction = 1_200_000, currency = "SAR", validFrom = "2026-01-01" });
        Assert.Equal(1_000_000m, (await EffectiveAsync(tm, sig, s.Y, "2025-06-01")).GetProperty("authority").GetProperty("maxPerTransaction").GetDecimal());
        Assert.Equal(1_200_000m, (await EffectiveAsync(tm, sig, s.Y, "2026-10-10")).GetProperty("authority").GetProperty("maxPerTransaction").GetDecimal());
        var history = (await tm.GetJsonAsync(url + "?includeHistory=true")).GetProperty("items").EnumerateArray().Select(a => a.GetProperty("state").GetString()).ToList();
        Assert.Contains("SUPERSEDED", history);

        // The terms of an authority are not updated in place in the database either (061).
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        await using (var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct))
        {
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-ACC-EXPIRY", Guid.NewGuid(), ct);
            var e = await Assert.ThrowsAsync<SqlException>(() => Dapper.SqlMapper.ExecuteAsync(c, "UPDATE acc.SignatoryAuthority SET MaxPerTransaction = 1 WHERE MaxPerTransaction = 250000;"));
            Assert.Equal(230, e.Number);
        }

        // FR-ACC-023: the party card counts the signatory's relationships.
        await tm.PostOkAsync($"/api/v1/relationships/{other.Relationship}/signatories", new { party = sg1, signatureClass = "B", validFrom = "2024-01-01", authorizationDocument = other.Doc });
        var role = (await tm.GetJsonAsync($"/api/v1/parties/{sg1}")).GetProperty("roles").EnumerateArray().Single(r => r.GetProperty("role").GetString() == "SIGNATORY");
        Assert.Equal(2, role.GetProperty("active").GetInt32());
    }

    [Fact]
    public async Task AC_ACC_4_the_expiry_alerts_the_expired_state_and_the_account_left_without_a_signatory()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var s = await SetupAsync(tm);
        var sig = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/relationships/{s.Relationship}/signatories", new
        {
            party = await PersonAsync(tm, "SG1"), signatureClass = "A", validFrom = "2024-01-01", validTo = "2026-12-15", authorizationDocument = s.Doc,
        }));
        await tm.PostOkAsync($"/api/v1/signatories/{sig}/authorities", new { operationType = "WITHDRAW", ceilingMode = "UNLIMITED", validFrom = "2024-01-01", validTo = "2026-12-15" });

        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        async Task<List<JsonElement>> AlertsOn(string day, int runs = 1)
        {
            var clock = new DayClock(DateTimeOffset.Parse(day + "T06:00:00Z", System.Globalization.CultureInfo.InvariantCulture));
            for (var i = 0; i < runs; i++) await new ExpiryAlertJob(f.Env.Db, clock).RunOnceAsync(ct);
            await outbox.RunOnceAsync(ct);
            return [.. (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Where(n => n.GetProperty("eventCode").GetString() == "ACC.SIGNATORY_EXPIRY")];
        }
        Assert.Empty(await AlertsOn("2026-11-14"));
        Assert.Single(await AlertsOn("2026-11-15", runs: 2));
        Assert.Equal(2, (await AlertsOn("2026-11-30")).Count);
        Assert.Equal(3, (await AlertsOn("2026-12-08")).Count);
        var last = await AlertsOn("2026-12-15", runs: 2);
        Assert.Equal(4, last.Count);

        // The day after, the signatory is EXPIRED and the account has no signatory: R-ACC-05 lists it, TM and FO hear once.
        var job = new SignatoryExpiryJob(f.Env.Db, new DayClock(new DateTimeOffset(2026, 12, 16, 6, 0, 0, TimeSpan.Zero)));
        await job.RunOnceAsync(ct);
        await job.RunOnceAsync(ct);
        await outbox.RunOnceAsync(ct);
        Assert.Equal("EXPIRED", (await tm.GetJsonAsync($"/api/v1/signatories/{sig}")).GetProperty("status").GetString());
        var bare = (await tm.GetJsonAsync("/api/v1/reports/accounts-without-signatory")).GetProperty("items").EnumerateArray().Select(a => a.GetProperty("account").GetString()).ToList();
        Assert.Contains(s.X, bare);
        var notices = (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Where(n => n.GetProperty("eventCode").GetString() == "ACC.NO_SIGNATORY").ToList();
        Assert.Equal(3, notices.Count);    // one per account (X, Y and the virtual V), once on the day
        Assert.DoesNotContain(notices, n => n.GetRawText().Contains("1000-0001", StringComparison.Ordinal));
        // An expired signatory is final (043).
        Assert.Equal((409, "V-ACC-SIGNATORY-STATE"), await tm.PostProblemAsync($"/api/v1/signatories/{sig}/actions/resume", new { }));
    }

    [Fact]
    public async Task AC_ACC_6_the_specimen_is_for_TM_and_FO_and_a_closing_revokes_the_signatories()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var s = await SetupAsync(tm);
        var sig = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/relationships/{s.Relationship}/signatories", new
        {
            party = await PersonAsync(tm, "SG1"), signatureClass = "A", validFrom = "2024-01-01", authorizationDocument = s.Doc,
        }));
        var up = await CompanyDocumentTests.UploadAsync(fo, "/api/v1/documents", CompanyDocumentTests.Pdf("specimen"), "specimen.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "SIGNATURE_SPECIMEN", ["title"] = "Specimen of SG1", ["company"] = s.Company,
        });
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        var specimen = JsonDocument.Parse(await up.Content.ReadAsStringAsync(ct)).RootElement.GetProperty("id").GetString()!;
        var (_, etag) = await fo.GetWithETagAsync($"/api/v1/signatories/{sig}");
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Patch, $"/api/v1/signatories/{sig}", new { specimenDocument = specimen }, etag)).StatusCode);

        // TE sees that there is a specimen, not its id, and is refused the image; FO opens it and the access is logged.
        var seen = await te.GetJsonAsync($"/api/v1/signatories/{sig}");
        Assert.True(seen.GetProperty("hasSpecimen").GetBoolean());
        Assert.Equal(JsonValueKind.Null, seen.GetProperty("specimenDocument").ValueKind);
        Assert.Equal(HttpStatusCode.Forbidden, (await te.GetAsync($"/api/v1/documents/{specimen}/content", ct)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await fo.GetAsync($"/api/v1/documents/{specimen}/content", ct)).StatusCode);
        var log = (await t.Portal.GetJsonAsync("/api/v1/audit-events?category=IDENTITY_ACCESS")).GetProperty("items").EnumerateArray().Select(a => a.GetProperty("action").GetString()).ToList();
        Assert.Contains("DOCUMENT_DOWNLOADED", log);
        Assert.Contains("DOCUMENT_DOWNLOAD_DENIED", log);

        // OQ-16: a relationship with signatories in force closes only on confirmation, and revokes them.
        var bank2 = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK2", nameAr = "البنك الثاني", type = "BANK", country = "SA" }));
        var rel2 = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/relationships", new { company = s.Company, institution = bank2 }));
        var sig2 = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/relationships/{rel2}/signatories", new { party = await PersonAsync(tm, "SG2"), signatureClass = "A", validFrom = "2024-01-01" }));
        Assert.Equal((409, "V-INS-OPEN-SIGNATORIES"), await tm.PostProblemAsync($"/api/v1/relationships/{rel2}/actions/close", new { reason = "Moved" }));
        Assert.True((await tm.SendAsync(HttpMethod.Post, $"/api/v1/relationships/{rel2}/actions/close", new { reason = "Moved", revokeSignatories = true })).IsSuccessStatusCode);
        Assert.Equal("REVOKED", (await tm.GetJsonAsync($"/api/v1/signatories/{sig2}")).GetProperty("status").GetString());
    }
}
