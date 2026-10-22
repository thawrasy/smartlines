using System.Net;
using System.Text.Json;
using BankFas.Data.Jobs;
using Microsoft.Data.SqlClient;

namespace BankFas.IntegrationTests;

/// <summary>
/// Governing bodies, members and authority grants (S1-b brief, batch S1B-C; FR-ORG-019 to 029, BR-ORG-009 to 014):
/// one active body per type and its replacement, the single holder, the grant lifecycle with segregation of duties and
/// supersession, the authority query of AC-ORG-2, the holder query, the matrix, the integrity report, the expiry alerts,
/// the source document kept while a grant is in force (S1B-GAP-9) and the database guard of grants (061, S1B-GAP-11).
/// </summary>
[Collection("database")]
public sealed class GovernanceTests(PlatformFixture f)
{
    private static async Task<string> CompanyAsync(HttpClient c, string code) =>
        PlatformFixture.Id(await c.PostOkAsync("/api/v1/companies", new { companyCode = code, nameAr = "شركة " + code, nameEn = "Company " + code, legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));

    private static async Task<string> PersonAsync(HttpClient c, string en) =>
        PlatformFixture.Id(await c.PostOkAsync("/api/v1/parties", new { kind = "INDIVIDUAL", nameAr = "شخص " + en, nameEn = en, country = "SA", residencyStatus = "CITIZEN" }));

    private static async Task<string> GrantAsync(HttpClient creator, HttpClient approver, string company, object body)
    {
        var id = PlatformFixture.Id(await creator.PostOkAsync($"/api/v1/companies/{company}/grants", body));
        Assert.Equal(HttpStatusCode.NoContent, (await creator.SendAsync(HttpMethod.Post, $"/api/v1/grants/{id}/actions/submit", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await approver.SendAsync(HttpMethod.Post, $"/api/v1/grants/{id}/actions/approve", new { })).StatusCode);
        return id;
    }

    private static async Task<List<(string Id, string[] Flags)>> QueryAsync(HttpClient c, string company, string q)
    {
        var r = await c.GetJsonAsync($"/api/v1/companies/{company}/grants/query?powerType=BORROW_FACILITIES&{q}");
        return [.. r.GetProperty("items").EnumerateArray().Select(i => (i.GetProperty("grant").GetProperty("id").GetString()!,
            i.GetProperty("flags").EnumerateArray().Select(x => x.GetString()!).ToArray()))];
    }

    [Fact]
    public async Task Bodies_have_one_active_per_type_and_a_single_holder_hands_over_the_day_before()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var co = await CompanyAsync(tm, "C1");
        var (a, b) = (await PersonAsync(tm, "A"), await PersonAsync(tm, "B"));
        var board = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/companies/{co}/bodies", new { bodyType = "BOARD_OF_DIRECTORS", termStart = "2024-01-01", termEnd = "2027-12-31" }));
        // FR-ORG-019: no two active bodies of a type.
        Assert.Equal((409, "V-ORG-BODY-ACTIVE"), await tm.PostProblemAsync($"/api/v1/companies/{co}/bodies", new { bodyType = "BOARD_OF_DIRECTORS", termStart = "2025-01-01" }));

        await tm.PostOkAsync($"/api/v1/bodies/{board}/members", new { party = a, position = "CHAIRMAN", termStart = "2024-01-01" });
        // A position of another kind of body is refused; a term outside the body's is refused.
        Assert.Equal((422, "V-ORG-POSITION"), await tm.PostProblemAsync($"/api/v1/bodies/{board}/members", new { party = b, position = "MANAGERS_BOARD_CHAIR", termStart = "2024-01-01" }));
        Assert.Equal((422, "V-ORG-MEMBER-TERM"), await tm.PostProblemAsync($"/api/v1/bodies/{board}/members", new { party = b, position = "BOARD_MEMBER", termStart = "2023-06-01" }));
        // BR-ORG-010: a new chairman from 2027-03-01 ends the previous term on 2027-02-28.
        var handed = await tm.PostOkAsync($"/api/v1/bodies/{board}/members", new { party = b, position = "CHAIRMAN", termStart = "2027-03-01" });
        Assert.Equal(1, handed.GetProperty("closedPrevious").GetInt32());
        var members = (await tm.GetJsonAsync($"/api/v1/companies/{co}/bodies")).GetProperty("items")[0].GetProperty("members").EnumerateArray().ToList();
        Assert.Equal("2027-02-28", members.Single(m => m.GetProperty("party").GetProperty("id").GetString() == a).GetProperty("termEnd").GetString());
        // The default end of a term is the end of the body's term.
        Assert.Equal("2027-12-31", members.Single(m => m.GetProperty("party").GetProperty("id").GetString() == b).GetProperty("termEnd").GetString());
        Assert.Equal("UPCOMING", members.Single(m => m.GetProperty("party").GetProperty("id").GetString() == b).GetProperty("state").GetString());
        // An earlier start than the current holder's is a conflict.
        Assert.Equal((422, "V-ORG-SINGLE-HOLDER"), await tm.PostProblemAsync($"/api/v1/bodies/{board}/members",
            new { party = await PersonAsync(tm, "C"), position = "CHAIRMAN", termStart = "2027-02-01" }));

        // BR-ORG-009, OQ-4: the replacement closes the board and carries the members whose term it ended.
        var next = await tm.PostOkAsync($"/api/v1/companies/{co}/bodies", new
        {
            bodyType = "BOARD_OF_DIRECTORS", termStart = "2026-01-01", termEnd = "2028-12-31", replace = true, carryMembers = true,
        });
        Assert.Equal(1, next.GetProperty("carriedMembers").GetInt32());
        var bodies = (await tm.GetJsonAsync($"/api/v1/companies/{co}/bodies?includeClosed=true")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal(["ACTIVE", "CLOSED"], bodies.Select(x => x.GetProperty("status").GetString()!).Order(StringComparer.Ordinal).ToArray());
    }

    [Fact]
    public async Task AC_ORG_2_the_authority_query_with_segregation_of_duties_and_supersession()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var co = await CompanyAsync(tm, "C1");
        var (x, y, z) = (await PersonAsync(tm, "X"), await PersonAsync(tm, "Y"), await PersonAsync(tm, "Z"));
        var poa = await CompanyDocumentTests.UploadAsync(fo, "/api/v1/documents", CompanyDocumentTests.Pdf("poa"), "poa.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "POWER_OF_ATTORNEY", ["title"] = "POA of X", ["company"] = co, ["expiryDate"] = "2026-12-31",
        });
        Assert.Equal(HttpStatusCode.Created, poa.StatusCode);
        var poaId = JsonDocument.Parse(await poa.Content.ReadAsStringAsync(ct)).RootElement.GetProperty("id").GetString()!;

        // BR-ORG-011: a zero ceiling is refused; a draft without its source is not sent for approval (BR-ORG-013).
        Assert.Equal((422, "V-ORG-CEILING"), await fo.PostProblemAsync($"/api/v1/companies/{co}/grants", new
        {
            granteeKind = "PARTY", party = x, powerType = "BORROW_FACILITIES", ceilingAmount = 0, ceilingCurrency = "SAR", validFrom = "2024-01-01",
        }));
        var g1 = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/companies/{co}/grants", new
        {
            granteeKind = "PARTY", party = x, powerType = "BORROW_FACILITIES", ceilingAmount = 5_000_000, ceilingCurrency = "SAR", validFrom = "2024-01-01", validTo = "2026-12-31",
        }));
        Assert.Equal((422, "V-ORG-GRANT-SOURCE"), await fo.PostProblemAsync($"/api/v1/grants/{g1}/actions/submit", new { }));
        var (_, etag) = await fo.GetWithETagAsync($"/api/v1/grants/{g1}");
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Patch, $"/api/v1/grants/{g1}", new { sourceDocument = poaId, sourcePage = "2" }, etag)).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/grants/{g1}/actions/submit", new { })).StatusCode);
        // FR-ORG-026: the creator does not approve; another user does.
        Assert.True((await fo.GetJsonAsync($"/api/v1/grants/{g1}")).GetProperty("createdByYou").GetBoolean());
        Assert.Equal((403, "V-ORG-SOD"), await fo.PostProblemAsync($"/api/v1/grants/{g1}/actions/approve", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Post, $"/api/v1/grants/{g1}/actions/approve", new { })).StatusCode);

        // G2 rests on a documented exception, which only a treasury manager approves (OQ-15).
        var g2Body = new
        {
            granteeKind = "PARTY", party = y, powerType = "BORROW_FACILITIES", ceilingAmount = 4_500_000, ceilingCurrency = "SAR", requiresJoint = true,
            jointNote = "With the chairman", validFrom = "2024-01-01", exceptionReason = "Resolution being signed",
        };
        var pending = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/companies/{co}/grants", g2Body));
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/grants/{pending}/actions/submit", new { });
        var (other, _, _) = await f.UserWithRoleAsync(t, "FO");
        Assert.Equal((403, "V-ORG-EXCEPTION"), await other.PostProblemAsync($"/api/v1/grants/{pending}/actions/approve", new { }));
        Assert.Equal((422, "VALIDATION_FAILED"), await other.PostProblemAsync($"/api/v1/grants/{pending}/actions/reject", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await other.SendAsync(HttpMethod.Post, $"/api/v1/grants/{pending}/actions/reject", new { reason = "Ask a TM" })).StatusCode);
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/grants/{pending}/actions/submit", new { });
        var (tm2, _, _) = await f.UserWithRoleAsync(t, "TM");
        Assert.Equal(HttpStatusCode.NoContent, (await tm2.SendAsync(HttpMethod.Post, $"/api/v1/grants/{pending}/actions/approve", new { })).StatusCode);
        var g2 = pending;
        var g3 = await GrantAsync(fo, tm, co, new { granteeKind = "PARTY", party = z, powerType = "BORROW_FACILITIES", validFrom = "2024-01-01", sourceDocument = poaId });
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Post, $"/api/v1/grants/{g3}/actions/revoke", new { reason = "Left the company", on = "2026-09-01" })).StatusCode);

        // The four questions of AC-ORG-2; G3 never answers.
        var q1 = await QueryAsync(tm, co, "amount=4000000&currency=SAR&date=2026-10-10");
        Assert.Equal([g1, g2], q1.Select(r => r.Id).ToArray());
        Assert.Contains("JOINT", q1[1].Flags);
        var none = await tm.GetJsonAsync($"/api/v1/companies/{co}/grants/query?powerType=BORROW_FACILITIES&amount=7000000&currency=SAR&date=2026-10-10");
        Assert.Empty(none.GetProperty("items").EnumerateArray());
        Assert.Equal("REVIEW_JOINT_COMBINATION_MANUALLY", none.GetProperty("suggestion").GetString());
        Assert.Equal([g2], (await QueryAsync(tm, co, "amount=4000000&currency=SAR&date=2027-01-05")).Select(r => r.Id).ToArray());
        var usd = await QueryAsync(tm, co, "amount=4000000&currency=USD&date=2026-10-10");
        Assert.Equal([g1, g2], usd.Select(r => r.Id).ToArray());
        Assert.All(usd, r => Assert.Contains("MANUAL_CURRENCY_REVIEW", r.Flags));

        // FR-ORG-025, bank filter: a grant restricted to bank A answers for A and without a filter, not for B.
        var bankA = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BKA", nameAr = "بنك أ", type = "BANK", country = "SA" }));
        var bankB = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BKB", nameAr = "بنك ب", type = "BANK", country = "SA" }));
        var g4 = await GrantAsync(fo, tm, co, new
        {
            granteeKind = "PARTY", party = z, powerType = "BORROW_FACILITIES", institution = bankA, ceilingAmount = 1_000_000, ceilingCurrency = "SAR", validFrom = "2024-01-01", sourceDocument = poaId,
        });
        Assert.Contains(g4, (await QueryAsync(tm, co, $"amount=500000&currency=SAR&date=2026-10-10&institution={bankA}")).Select(r => r.Id));
        Assert.Contains(g4, (await QueryAsync(tm, co, "amount=500000&currency=SAR&date=2026-10-10")).Select(r => r.Id));
        Assert.DoesNotContain(g4, (await QueryAsync(tm, co, $"amount=500000&currency=SAR&date=2026-10-10&institution={bankB}")).Select(r => r.Id));

        // BR-ORG-014: raising G1's ceiling is a new grant that waits for approval and supersedes G1 on approval.
        var g5 = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/grants/{g1}/actions/supersede", new { ceilingAmount = 8_000_000 }));
        Assert.Equal("ACTIVE", (await tm.GetJsonAsync($"/api/v1/grants/{g1}")).GetProperty("status").GetString());
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/grants/{g5}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/grants/{g5}/actions/approve", new { });
        Assert.Equal("SUPERSEDED", (await tm.GetJsonAsync($"/api/v1/grants/{g1}")).GetProperty("status").GetString());
        Assert.Equal(g1, (await tm.GetJsonAsync($"/api/v1/grants/{g5}")).GetProperty("supersedes").GetString());
        Assert.Equal((409, "V-ORG-GRANT-STATE"), await tm.PostProblemAsync($"/api/v1/grants/{g1}/actions/revoke", new { reason = "Again" }));

        // The holder query keeps the superseded and revoked grants of a person, with whether each is effective on the date.
        var holder = (await tm.GetJsonAsync($"/api/v1/parties/{x}/grants?powerTypes=BORROW_FACILITIES&date=2026-10-10")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal(2, holder.Count);
        Assert.Single(holder, h => h.GetProperty("effective").GetBoolean());

        // The matrix on a date has the effective grants only.
        var matrix = await tm.GetJsonAsync($"/api/v1/companies/{co}/authority-matrix?asOf=2026-10-10");
        Assert.Equal(3, matrix.GetProperty("rows").GetArrayLength());

        // The source of a grant in force is not deleted (BR-ORG-013, S1B-GAP-9).
        Assert.Equal((409, "DOCUMENT_IN_USE"), await tm.PostProblemAsync($"/api/v1/documents/{poaId}/actions/delete", new { reason = "Tidy up" }));

        // The database keeps a superseded grant final and an active grant's substance (061, 50175).
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-NTF-EXPIRY", Guid.NewGuid(), ct);
        foreach (var (grant, sql) in new[] { (g1, "Status = 'ACTIVE'"), (g5, "CeilingAmount = 9000000") })
        {
            var e = await Assert.ThrowsAsync<SqlException>(() => Dapper.SqlMapper.ExecuteAsync(c, $"UPDATE org.AuthorityGrant SET {sql} WHERE PublicId = @g;", new { g = Guid.Parse(grant) }));
            Assert.Equal(50175, e.Number);
        }
    }

    [Fact]
    public async Task Terms_and_grants_raise_their_expiry_alerts_and_the_integrity_report_lists_the_gaps()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var co = await CompanyAsync(tm, "C1");
        var a = await PersonAsync(tm, "A");
        var today = DateOnly.FromDateTime(f.Env.Clock.GetUtcNow().UtcDateTime);
        string D(DateOnly d) => d.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var board = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/companies/{co}/bodies", new { bodyType = "BOARD_OF_DIRECTORS", termStart = "2024-01-01" }));
        var member = (await tm.PostOkAsync($"/api/v1/bodies/{board}/members", new { party = a, position = "CHAIRMAN", termStart = "2024-01-01", termEnd = D(today.AddDays(28)) }))
            .GetProperty("id").GetString()!;
        var grant = await GrantAsync(fo, tm, co, new
        {
            granteeKind = "BODY_MEMBER", member, powerType = "SIGN_CONTRACTS", validFrom = "2024-01-01", validTo = D(today.AddDays(28)), exceptionReason = "Articles of association",
        });
        var mgmt = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/companies/{co}/bodies", new { bodyType = "MANAGEMENT", termStart = "2024-01-01" }));
        _ = mgmt;

        // FR-ORG-022: a term ending in 28 days gives the 30-day alert, once however often the job runs.
        var job = new ExpiryAlertJob(f.Env.Db, f.Env.Clock);
        await job.RunOnceAsync(ct);
        await job.RunOnceAsync(ct);
        await new OutboxJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
        var bell = (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().ToList();
        var term = Assert.Single(bell, n => n.GetProperty("eventCode").GetString() == "BODY.TERM_EXPIRY");
        Assert.Contains("30", term.GetProperty("title").GetString() + term.GetProperty("body").GetString(), StringComparison.Ordinal);
        var expiring = Assert.Single(bell, n => n.GetProperty("eventCode").GetString() == "GRANT.EXPIRY");
        Assert.Contains("30", expiring.GetProperty("title").GetString() + expiring.GetProperty("body").GetString(), StringComparison.Ordinal);

        // The chairman resigns: the grant to the membership is flagged, the chair is vacant, and both are told once.
        var resigned = await tm.PostOkAsync($"/api/v1/bodies/{board}/members/{member}/actions/resign", new { on = D(today.AddDays(-1)) });
        Assert.Equal(1, resigned.GetProperty("grantsToReview").GetInt32());
        Assert.Equal("HOLDER_LEFT", (await tm.GetJsonAsync($"/api/v1/grants/{grant}")).GetProperty("state").GetString());
        await job.RunOnceAsync(ct);
        await job.RunOnceAsync(ct);
        await new OutboxJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
        bell = [.. (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray()];
        Assert.Equal(2, bell.Count(n => n.GetProperty("eventCode").GetString() == "BODY.TERM_EXPIRY"));
        Assert.Equal(2, bell.Count(n => n.GetProperty("eventCode").GetString() == "GRANT.EXPIRY"));

        // FR-ORG-029: the report counts each gap and lists it.
        var report = (await tm.GetJsonAsync("/api/v1/reports/structure-integrity")).GetProperty("items").EnumerateArray()
            .ToDictionary(i => i.GetProperty("item").GetString()!, i => i.GetProperty("count").GetInt32());
        Assert.Equal(1, report["OWNERSHIP_NOT_100"]);
        Assert.Equal(2, report["MISSING_BASIC_DOCUMENTS"]);
        Assert.Equal(2, report["BODY_WITHOUT_MEMBERS"]);
        Assert.Equal(1, report["GRANT_TO_FORMER_MEMBER"]);
    }
}
