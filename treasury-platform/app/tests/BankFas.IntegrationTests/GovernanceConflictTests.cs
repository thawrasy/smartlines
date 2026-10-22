using System.Net;
using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// The exit of S1-b (owner default OQ-12): AC-ACC-3, the governance conflict of a bank authority, through its whole
/// life (opened with a warning and a notice to TM and FO, acknowledged with a reason, resolved by a higher grant, a
/// grant in another currency, a grant restricted to another bank and then to the same one), and AC-ACC-7, the report
/// R-ACC-04 that the auditor reads and cannot act on; the nightly comparison run twice adds nothing.
/// </summary>
[Collection("database")]
public sealed class GovernanceConflictTests(PlatformFixture f)
{
    [Fact]
    public async Task AC_ACC_3_and_AC_ACC_7_a_conflict_is_opened_acknowledged_resolved_and_reported()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (saver, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (au, _, _) = await f.UserWithRoleAsync(t, "AU");
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);

        var co = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bnk1 = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        var bnk2 = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK2", nameAr = "البنك الثاني", nameEn = "Bank Two", type = "BANK", country = "SA" }));
        var rel = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/relationships", new { company = co, institution = bnk1 }));
        var sg1 = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new { kind = "INDIVIDUAL", nameAr = "المفوض الأول", nameEn = "SG1", country = "SA", residencyStatus = "CITIZEN" }));
        var up = await CompanyDocumentTests.UploadAsync(tm, "/api/v1/documents", CompanyDocumentTests.Pdf("resolution"), "resolution.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "BOARD_RESOLUTION", ["title"] = "Board resolution", ["company"] = co,
        });
        var doc = JsonDocument.Parse(await up.Content.ReadAsStringAsync(ct)).RootElement.GetProperty("id").GetString()!;
        var sig = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/relationships/{rel}/signatories", new { party = sg1, signatureClass = "A", validFrom = "2024-01-01", authorizationDocument = doc }));

        // The grant: TRADE_INSTRUMENTS for SG1, 2,000,000 SAR, any bank.
        var grant = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/companies/{co}/grants", new
        {
            granteeKind = "PARTY", party = sg1, powerType = "TRADE_INSTRUMENTS", ceilingAmount = 2_000_000, ceilingCurrency = "SAR", validFrom = "2024-01-01", sourceDocument = doc,
        }));
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/grants/{grant}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/grants/{grant}/actions/approve", new { });
        await outbox.RunOnceAsync(ct);

        async Task<List<JsonElement>> ConflictsAsync(HttpClient c, string q = "status=ALL") =>
            [.. (await c.GetJsonAsync($"/api/v1/authority-conflicts?company={co}&{q}")).GetProperty("items").EnumerateArray()];
        async Task<string> SupersedeAsync(object change)
        {
            var next = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/grants/{grant}/actions/supersede", change));
            await fo.OkAsync(HttpMethod.Post, $"/api/v1/grants/{next}/actions/submit", new { });
            await tm.OkAsync(HttpMethod.Post, $"/api/v1/grants/{next}/actions/approve", new { });
            await outbox.RunOnceAsync(ct);
            await outbox.RunOnceAsync(ct);
            return next;
        }

        // 1. The LC authority of 3,000,000 SAR at BNK1 is saved with a warning, and one OPEN CEILING_EXCEEDS (BR-ACC-015).
        var saved = await saver.PostOkAsync($"/api/v1/signatories/{sig}/authorities", new { operationType = "LC", ceilingMode = "LIMITED", maxPerTransaction = 3_000_000, currency = "SAR", validFrom = "2024-01-01" });
        Assert.Contains("V-ACC-07", saved.GetProperty("warnings").EnumerateArray().Select(w => w.GetString()));
        Assert.Equal(["CEILING_EXCEEDS"], saved.GetProperty("conflicts").EnumerateArray().Select(w => w.GetString()!).ToArray());
        var open = Assert.Single(await ConflictsAsync(tm));
        Assert.Equal(("CEILING_EXCEEDS", "OPEN"), (open.GetProperty("code").GetString(), open.GetProperty("status").GetString()));
        Assert.Equal(grant, open.GetProperty("grant").GetString());
        await outbox.RunOnceAsync(ct);
        foreach (var who in new[] { tm, fo })
            Assert.Single((await who.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(), n => n.GetProperty("eventCode").GetString() == "ACC.GOV_CONFLICT");

        // 2. The auditor reads it and cannot act; TM acknowledges with a reason.
        var reference = open.GetProperty("id").GetString()!;
        Assert.False((await au.GetJsonAsync($"/api/v1/authority-conflicts?company={co}")).GetProperty("canAcknowledge").GetBoolean());
        Assert.Equal(HttpStatusCode.Forbidden, (await au.SendAsync(HttpMethod.Post, $"/api/v1/authority-conflicts/{reference}/actions/acknowledge", new { reason = "Seen" })).StatusCode);
        Assert.Equal((422, "VALIDATION_FAILED"), await tm.PostProblemAsync($"/api/v1/authority-conflicts/{reference}/actions/acknowledge", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Post, $"/api/v1/authority-conflicts/{reference}/actions/acknowledge",
            new { reason = "The board raises the ceiling next week" })).StatusCode);
        Assert.Equal("ACKNOWLEDGED", Assert.Single(await ConflictsAsync(tm)).GetProperty("status").GetString());

        // 3. The grant rises to 3,500,000 SAR (a new grant approved by another user, OQ-6): the conflict is RESOLVED.
        grant = await SupersedeAsync(new { ceilingAmount = 3_500_000 });
        Assert.Equal("RESOLVED", Assert.Single(await ConflictsAsync(tm)).GetProperty("status").GetString());
        Assert.Empty(await ConflictsAsync(tm, "status="));

        // 4. In dollars, the ceilings are not compared.
        grant = await SupersedeAsync(new { ceilingCurrency = "USD" });
        Assert.Equal("NOT_COMPARABLE_CURRENCY", Assert.Single(await ConflictsAsync(tm, "status=OPEN")).GetProperty("code").GetString());

        // 5. Restricted to BNK2 the grant does not count at BNK1: a new NO_GRANT with its own fingerprint; restricted to BNK1, the ceiling applies again.
        grant = await SupersedeAsync(new { ceilingCurrency = "SAR", institution = bnk2 });
        Assert.Equal("NO_GRANT", Assert.Single(await ConflictsAsync(tm, "status=OPEN")).GetProperty("code").GetString());
        grant = await SupersedeAsync(new { institution = bnk1 });
        Assert.Empty(await ConflictsAsync(tm, "status="));

        // 6. R-ACC-04 lists exactly these rows, by company and by code; printing it is audited.
        var all = await ConflictsAsync(au);
        Assert.Equal(["CEILING_EXCEEDS", "NOT_COMPARABLE_CURRENCY", "NO_GRANT"], all.Select(x => x.GetProperty("code").GetString()!).Order(StringComparer.Ordinal).ToArray());
        Assert.All(all, x => Assert.Equal("RESOLVED", x.GetProperty("status").GetString()));
        Assert.Single(await ConflictsAsync(au, "status=ALL&code=NO_GRANT"));
        await tm.GetJsonAsync($"/api/v1/authority-conflicts?company={co}&status=ALL&print=true");
        Assert.Single((await tm.GetJsonAsync("/api/v1/audit-events?action=REPORT_PRINTED")).GetProperty("items").EnumerateArray());

        // 7. The nightly comparison, run twice, creates nothing.
        var nightly = new GovernanceJob(f.Env.Db, f.Env.Clock);
        await nightly.RunOnceAsync(ct);
        await nightly.RunOnceAsync(ct);
        Assert.Equal(3, (await ConflictsAsync(tm)).Count);
    }
}
