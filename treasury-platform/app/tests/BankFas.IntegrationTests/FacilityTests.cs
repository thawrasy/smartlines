using System.Globalization;
using System.Net;
using System.Text.Json;
using BankFas.Data.Facilities;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// The facility package and its revisions (S2 brief batch S2-B): FR-FAC-001 and 003 (the number, the shares
/// 40/35/25 accepted and 40/35/20 refused, one agent), BR-FAC-004 (the approver did not take part), FR-FAC-006 (an
/// amendment carries its addendum), the approval order of S2-GAP-2 (rows of two revisions, the history kept), a
/// discarded draft, the header written through the revision after the first approval, and the first part of
/// AC-FAC-6: the validity indicator, the alerts before the expiry and NOT_CONFIRMED after it, its resolution, the
/// extension and the renewal that supersedes its predecessor.
/// </summary>
[Collection("database")]
public sealed class FacilityTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    private DateTime Today => f.Env.Clock.GetUtcNow().UtcDateTime.Date;

    private sealed record Setup(HttpClient Tm, HttpClient Fo, string Company, string[] Banks, string TenantCode);

    private async Task<Setup> SetupAsync(int banks = 3)
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var co = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var ids = new string[banks];
        for (var i = 0; i < banks; i++)
            ids[i] = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = $"BNK{i + 1}", refCode = $"BN{(char)('A' + i)}", nameAr = $"البنك {i + 1}", nameEn = $"Bank {i + 1}", type = "BANK", country = "SA" }));
        return new Setup(tm, fo, co, ids, t.Code);
    }

    private static async Task<string> CreateAsync(HttpClient c, string company, DateTime from, DateTime to, bool syndicated = false, decimal total = 45_000_000) =>
        PlatformFixture.Id(await c.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = total, isSyndicated = syndicated, precedenceLanguage = "AR",
            effectiveFrom = D(from), expiryDate = D(to), bankReferenceNo = "REF-1",
        }));

    private static async Task<JsonElement> CardAsync(HttpClient c, string id) => await c.GetJsonAsync($"/api/v1/facilities/{id}");

    private static string Open(JsonElement card) => card.GetProperty("draft").GetProperty("revision").GetString()!;

    private static async Task<string> LenderAsync(HttpClient c, string facility, string bank, decimal share, params string[] roles) =>
        (await c.PostOkAsync($"/api/v1/facilities/{facility}/lenders", new { institution = bank, sharePct = share, roles })).GetProperty("id").GetString()!;

    private static Task<(int, string)> ActProblemAsync(HttpClient c, string facility, string rev, string action, object? body = null) =>
        c.PostProblemAsync($"/api/v1/facilities/{facility}/revisions/{rev}/actions/{action}", body ?? new { });

    private static Task<JsonElement> ActAsync(HttpClient c, string facility, string rev, string action, object? body = null) =>
        c.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{facility}/revisions/{rev}/actions/{action}", body ?? new { });

    // No agreement attached, and other facilities of the same bank with the same reference (BR-FAC-001).
    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01"];

    /// <summary>A facility with one sole lender, approved by TM (the warning that no agreement is attached acknowledged).</summary>
    private static async Task<string> ApprovedAsync(Setup s, DateTime from, DateTime to)
    {
        var id = await CreateAsync(s.Fo, s.Company, from, to);
        await LenderAsync(s.Fo, id, s.Banks[0], 100, "SOLE");
        var rev = Open(await CardAsync(s.Fo, id));
        await ActAsync(s.Fo, id, rev, "submit");
        await ActAsync(s.Tm, id, rev, "approve", new { acknowledge = Ack });
        return id;
    }

    private static async Task<string> UploadAsync(HttpClient c, string company, string type, string title)
    {
        var up = await CompanyDocumentTests.UploadAsync(c, "/api/v1/documents", CompanyDocumentTests.Pdf(title), title + ".pdf", new Dictionary<string, string>
        {
            ["documentType"] = type, ["title"] = title, ["company"] = company,
        });
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        return JsonDocument.Parse(await up.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement.GetProperty("id").GetString()!;
    }

    [Fact]
    public async Task FR_FAC_003_and_BR_FAC_004_shares_one_agent_and_an_approver_who_did_not_take_part()
    {
        var s = await SetupAsync();
        var id = await CreateAsync(s.Fo, s.Company, Today.AddMonths(-1), Today.AddMonths(11), syndicated: true);
        var card = await CardAsync(s.Fo, id);
        Assert.Matches(@"^FAC-\d{2}-\d{3}$", card.GetProperty("facilityNo").GetString());
        Assert.Equal(("DRAFT", 0), (card.GetProperty("status").GetString(), card.GetProperty("approvedRevision").GetInt32()));
        var rev = Open(card);

        await LenderAsync(s.Fo, id, s.Banks[0], 40, "LEAD", "AGENT");
        var second = await LenderAsync(s.Fo, id, s.Banks[1], 35, "PARTICIPANT", "AGENT");
        var third = await LenderAsync(s.Fo, id, s.Banks[2], 20, "PARTICIPANT");
        Assert.Equal((409, "V-FAC-LENDER-EXISTS"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{id}/lenders", new { institution = s.Banks[2], sharePct = 5, roles = new[] { "PARTICIPANT" } }));
        Assert.Equal((422, "V-FAC-02"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{id}/lenders", new { institution = s.Banks[2], sharePct = 50, roles = new[] { "SOLE" } }));

        // 40/35/20 with two agents: the dry run lists both, the submit refuses.
        var check = await s.Fo.GetJsonAsync($"/api/v1/facilities/{id}/revisions/{rev}/check");
        Assert.Equal(2, check.GetProperty("errors").EnumerateArray().Count(e => e.GetProperty("code").GetString() == "V-FAC-02"));
        Assert.Equal((422, "V-FAC-INTEGRITY"), await ActProblemAsync(s.Fo, id, rev, "submit"));
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}/lenders/{third}", new { sharePct = 25 })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}/lenders/{second}", new { roles = new[] { "PARTICIPANT" } })).StatusCode);
        Assert.Empty((await s.Fo.GetJsonAsync($"/api/v1/facilities/{id}/revisions/{rev}/check")).GetProperty("errors").EnumerateArray());
        var submitted = await ActAsync(s.Fo, id, rev, "submit");
        Assert.Contains(submitted.GetProperty("warnings").EnumerateArray(), w => w.GetProperty("code").GetString() == "V-FAC-NO-AGREEMENT");

        // A submitted draft is not edited; its preparer does not approve it; the approver acknowledges the warnings.
        Assert.Equal((409, "V-FAC-NO-DRAFT"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{id}/lenders", new { institution = s.Banks[1], sharePct = 1, roles = new[] { "PARTICIPANT" } }));
        Assert.Equal((403, "FORBIDDEN"), await ActProblemAsync(s.Fo, id, rev, "approve"));
        Assert.Equal((422, "V-FAC-ACK"), await ActProblemAsync(s.Tm, id, rev, "approve"));
        var approved = await ActAsync(s.Tm, id, rev, "approve", new { acknowledge = new[] { "V-FAC-NO-AGREEMENT" } });
        Assert.Equal("ACTIVE", approved.GetProperty("status").GetString());
        card = await CardAsync(s.Fo, id);
        Assert.Equal((1, "VALID"), (card.GetProperty("approvedRevision").GetInt32(), card.GetProperty("validity").GetString()));
        Assert.Equal([40m, 35m, 25m], card.GetProperty("lenders").EnumerateArray().Select(l => l.GetProperty("sharePct").GetDecimal()).ToArray());
        Assert.Equal(JsonValueKind.Null, card.GetProperty("draft").ValueKind);
        Assert.Equal((409, "V-FAC-NO-DRAFT"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{id}/lenders", new { institution = s.Banks[1], sharePct = 1, roles = new[] { "PARTICIPANT" } }));

        // A treasury manager who opens a revision does not approve it either; without the setting of one person.
        var correction = (await s.Tm.PostOkAsync($"/api/v1/facilities/{id}/revisions", new { reasonKind = "CORRECTION", changeSummary = "Reference" })).GetProperty("id").GetString()!;
        Assert.Equal((409, "OPEN_REVISION_EXISTS"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{id}/revisions", new { reasonKind = "AMENDMENT" }));
        var (_, etag) = await s.Tm.GetWithETagAsync($"/api/v1/facilities/{id}");
        Assert.Equal(HttpStatusCode.NoContent, (await s.Tm.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}", new { bankReferenceNo = "REF-2" }, etag)).StatusCode);
        Assert.Equal("REF-1", (await CardAsync(s.Fo, id)).GetProperty("header").GetProperty("bankReferenceNo").GetString());
        Assert.Equal("REF-2", (await CardAsync(s.Fo, id)).GetProperty("draft").GetProperty("header").GetProperty("bankReferenceNo").GetString());
        await ActAsync(s.Tm, id, correction, "submit");
        Assert.Equal((403, "V-FAC-SOD"), await ActProblemAsync(s.Tm, id, correction, "approve", new { acknowledge = new[] { "V-FAC-NO-AGREEMENT" } }));
        Assert.Equal((422, "VALIDATION_FAILED"), await ActProblemAsync(s.Tm, id, correction, "reject"));
        await s.Tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{id}/revisions/{correction}/actions/reject", new { reason = "Wrong reference" });
        await ActAsync(s.Fo, id, correction, "discard");
        card = await CardAsync(s.Fo, id);
        Assert.Equal(("REF-1", JsonValueKind.Null), (card.GetProperty("header").GetProperty("bankReferenceNo").GetString(), card.GetProperty("draft").ValueKind));
        Assert.Equal(["DISCARDED", "APPROVED"], card.GetProperty("revisions").EnumerateArray().Select(r => r.GetProperty("status").GetString()!).ToArray());
    }

    [Fact]
    public async Task An_amendment_needs_its_addendum_writes_a_new_revision_and_keeps_the_old_one()
    {
        var s = await SetupAsync();
        var ct = TestContext.Current.CancellationToken;
        var id = await CreateAsync(s.Fo, s.Company, Today.AddMonths(-2), Today.AddMonths(10), syndicated: true);
        var lead = await LenderAsync(s.Fo, id, s.Banks[0], 40, "LEAD", "AGENT");
        var b2 = await LenderAsync(s.Fo, id, s.Banks[1], 35, "PARTICIPANT");
        var b3 = await LenderAsync(s.Fo, id, s.Banks[2], 25, "PARTICIPANT");
        var agreement = await UploadAsync(s.Fo, s.Company, "FACILITY_AGREEMENT", "Agreement");
        await s.Fo.PostOkAsync($"/api/v1/facilities/{id}/documents", new { document = agreement, precedenceRank = 1, language = "AR" });
        var rev1 = Open(await CardAsync(s.Fo, id));
        await ActAsync(s.Fo, id, rev1, "submit");
        await ActAsync(s.Tm, id, rev1, "approve");

        // Revision 2: shares 40/30/30 and a larger total; without the addendum it is refused.
        var rev2 = (await s.Fo.PostOkAsync($"/api/v1/facilities/{id}/revisions", new { reasonKind = "AMENDMENT", changeSummary = "New shares" })).GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}/lenders/{b2}", new { sharePct = 30 })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}/lenders/{b3}", new { sharePct = 30 })).StatusCode);
        var (_, etag) = await s.Fo.GetWithETagAsync($"/api/v1/facilities/{id}");
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}", new { totalAmount = 50_000_000 }, etag)).StatusCode);
        Assert.Equal((422, "V-FAC-INTEGRITY"), await ActProblemAsync(s.Fo, id, rev2, "submit"));
        var addendum = await UploadAsync(s.Fo, s.Company, "FACILITY_ADDENDUM", "Addendum 1");
        await s.Fo.PostOkAsync($"/api/v1/facilities/{id}/documents", new { document = addendum, precedenceRank = 2, language = "AR" });
        Assert.Equal((409, "V-FAC-DOC-EXISTS"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{id}/documents", new { document = agreement, precedenceRank = 3 }));
        var annex = await UploadAsync(s.Fo, s.Company, "TARIFF_ANNEX", "Annex");
        Assert.Equal((409, "V-FAC-DOC-RANK"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{id}/documents", new { document = annex, precedenceRank = 2 }));
        // The approved card still shows revision 1 while the draft is edited.
        var card = await CardAsync(s.Fo, id);
        Assert.Equal(45_000_000m, card.GetProperty("header").GetProperty("totalAmount").GetDecimal());
        Assert.Equal([40m, 35m, 25m], card.GetProperty("lenders").EnumerateArray().Select(l => l.GetProperty("sharePct").GetDecimal()).ToArray());
        Assert.Equal([40m, 30m, 30m], card.GetProperty("draft").GetProperty("lenders").EnumerateArray().Select(l => l.GetProperty("sharePct").GetDecimal()).ToArray());
        await ActAsync(s.Fo, id, rev2, "submit");
        await ActAsync(s.Tm, id, rev2, "approve");
        card = await CardAsync(s.Fo, id);
        Assert.Equal((2, 50_000_000m), (card.GetProperty("approvedRevision").GetInt32(), card.GetProperty("header").GetProperty("totalAmount").GetDecimal()));
        Assert.Equal([40m, 30m, 30m], card.GetProperty("lenders").EnumerateArray().Select(l => l.GetProperty("sharePct").GetDecimal()).ToArray());
        Assert.Equal(2, card.GetProperty("documents").GetArrayLength());
        // A lender keeps its reference across revisions (its root): the reference of revision 1 changes it in revision 3.
        var rev3 = (await s.Fo.PostOkAsync($"/api/v1/facilities/{id}/revisions", new { reasonKind = "CORRECTION" })).GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}/lenders/{lead}", new { roles = new[] { "LEAD" } })).StatusCode);
        await ActAsync(s.Fo, id, rev3, "discard");

        // The rows of revision 1 are kept, closed at 2; the discarded revision 3 left one void row; the database refuses to change an approved row.
        var tenantId = await TestEnvironment.TenantIdAsync(s.TenantCode);
        await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-FAC-VALIDITY", Guid.NewGuid(), ct);
        var rows = (await Dapper.SqlMapper.QueryAsync<(decimal Share, int From, int? To)>(c,
            "SELECT l.SharePct, l.FromRevision, l.ToRevision FROM fac.FacilityLender AS l JOIN fac.Facility AS x ON x.FacilityId = l.FacilityId WHERE x.PublicId = @f ORDER BY l.FacilityLenderId;",
            new { f = Guid.Parse(id) })).ToList();
        Assert.Equal([(40m, 1, null), (35m, 1, 2), (25m, 1, 2), (30m, 2, null), (30m, 2, null), (40m, 3, 3)], rows.Select(r => (r.Share, r.From, r.To)).ToArray());
        var error = await Assert.ThrowsAsync<Microsoft.Data.SqlClient.SqlException>(() => Dapper.SqlMapper.ExecuteAsync(c,
            "UPDATE l SET SharePct = 41 FROM fac.FacilityLender AS l JOIN fac.Facility AS x ON x.FacilityId = l.FacilityId WHERE x.PublicId = @f AND l.ToRevision IS NULL AND l.FromRevision = 1;",
            new { f = Guid.Parse(id) }));
        Assert.Equal(50049, error.Number);
    }

    [Fact]
    public async Task AC_FAC_6_validity_alerts_resolution_extension_and_renewal()
    {
        var s = await SetupAsync(banks: 1);
        var ct = TestContext.Current.CancellationToken;
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        async Task<List<JsonElement>> AlertsAsync(string code) =>
            [.. (await s.Tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Where(n => n.GetProperty("eventCode").GetString() == code)];
        async Task RunAsync(DateTime day)
        {
            await new FacilityValidityJob(f.Env.Db, new DayClock(day)).RunOnceAsync(ct);
            await new ExpiryAlertJob(f.Env.Db, new DayClock(day)).RunOnceAsync(ct);
            // The outbox delivers one event of an aggregate per pass, in order.
            while (await outbox.RunOnceAsync(ct) > 0) { }
        }

        // X expires in 51 days: EXPIRING; one alert at 60 (90 recorded with it), then at 30 when 30 days are left.
        var x = await ApprovedAsync(s, Today.AddMonths(-10), Today.AddDays(51));
        var card = await CardAsync(s.Tm, x);
        Assert.Equal(("EXPIRING", 51), (card.GetProperty("validity").GetString(), card.GetProperty("daysToExpiry").GetInt32()));
        await RunAsync(Today);
        await RunAsync(Today);
        var lead = await AlertsAsync("FAC.EXPIRY_DUE");
        Assert.Single(lead);
        Assert.Contains("60", lead[0].GetProperty("title").GetString(), StringComparison.Ordinal);
        await RunAsync(Today.AddDays(21));
        Assert.Equal(2, (await AlertsAsync("FAC.EXPIRY_DUE")).Count);

        // Y expired ten days ago: NOT_CONFIRMED, its alert, and a weekly reminder.
        var y = await ApprovedAsync(s, Today.AddMonths(-13), Today.AddDays(-10));
        Assert.Equal("NOT_CONFIRMED", (await CardAsync(s.Tm, y)).GetProperty("validity").GetString());
        Assert.Contains((await s.Tm.GetJsonAsync("/api/v1/facilities?validity=NOT_CONFIRMED")).GetProperty("items").EnumerateArray(), i => i.GetProperty("id").GetString() == y);
        await RunAsync(Today);
        Assert.Single(await AlertsAsync("FAC.VALIDITY_UNCONFIRMED"));
        await RunAsync(Today.AddDays(11));
        Assert.Equal(2, (await AlertsAsync("FAC.VALIDITY_UNCONFIRMED")).Count);

        // The user records the expiry; then an approved extension of 82 days brings it back, EXPIRING.
        Assert.Equal((422, "VALIDATION_FAILED"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{y}/actions/expire", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await s.Fo.SendAsync(HttpMethod.Post, $"/api/v1/facilities/{y}/actions/expire", new { reason = "Not renewed by the bank" })).StatusCode);
        card = await CardAsync(s.Tm, y);
        Assert.Equal(("EXPIRED", JsonValueKind.Null), (card.GetProperty("status").GetString(), card.GetProperty("validity").ValueKind));
        Assert.Equal((409, "V-FAC-LIFECYCLE"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{y}/revisions", new { reasonKind = "AMENDMENT" }));
        var ext = (await s.Fo.PostOkAsync($"/api/v1/facilities/{y}/revisions", new { reasonKind = "EXTENSION", expiryDate = D(Today.AddDays(82)) })).GetProperty("id").GetString()!;
        var (_, etag) = await s.Fo.GetWithETagAsync($"/api/v1/facilities/{y}");
        Assert.Equal((422, "V-FAC-EXTENSION"), await s.Fo.ProblemAsync(HttpMethod.Patch, $"/api/v1/facilities/{y}", new { totalAmount = 1_000_000 }, etag));
        await ActAsync(s.Fo, y, ext, "submit");
        await ActAsync(s.Tm, y, ext, "approve", new { acknowledge = Ack });
        card = await CardAsync(s.Tm, y);
        Assert.Equal(("ACTIVE", "EXPIRING", 82), (card.GetProperty("status").GetString(), card.GetProperty("validity").GetString(), card.GetProperty("daysToExpiry").GetInt32()));

        // X is renewed by F2 from the day after its expiry: X stays valid until then, and is SUPERSEDED from that day.
        var renewal = await s.Fo.PostOkAsync($"/api/v1/facilities/{x}/actions/renew", new { });
        var f2 = renewal.GetProperty("id").GetString()!;
        Assert.Equal((409, "V-FAC-RENEW"), await s.Fo.PostProblemAsync($"/api/v1/facilities/{x}/actions/renew", new { }));
        card = await CardAsync(s.Fo, f2);
        Assert.Equal((D(Today.AddDays(52)), x), (card.GetProperty("header").GetProperty("effectiveFrom").GetString(), card.GetProperty("previous").GetString()));
        Assert.Single(card.GetProperty("draft").GetProperty("lenders").EnumerateArray());
        var rev = Open(card);
        await ActAsync(s.Fo, f2, rev, "submit");
        await ActAsync(s.Tm, f2, rev, "approve", new { acknowledge = Ack });
        Assert.Equal("SCHEDULED", (await CardAsync(s.Tm, f2)).GetProperty("validity").GetString());
        await RunAsync(Today.AddDays(51));
        Assert.Equal("ACTIVE", (await CardAsync(s.Tm, x)).GetProperty("status").GetString());
        await RunAsync(Today.AddDays(52));
        Assert.Equal("SUPERSEDED", (await CardAsync(s.Tm, x)).GetProperty("status").GetString());
        Assert.Equal([x, f2], (await s.Tm.GetJsonAsync($"/api/v1/facilities/{f2}/chain")).GetProperty("items").EnumerateArray().Select(i => i.GetProperty("id").GetString()!).ToArray());
    }

    /// <summary>
    /// BR-FAC-021 (the owner's request of 2026-10-23): the platform reference COMPANY-BANK-CLASS-YY. The company IMP and
    /// the bank SNB take their codes as reference codes; a code of another shape is refused. A facility without a class
    /// does not pass the check (V-FAC-REF); with CAP its first approval writes IMP-SNB-CAP-yy, the year it is in force
    /// from, and its class no longer changes. A second one of the same stem and year is IMP-SNB-CAP-yy-2; the list finds
    /// it by its reference; the renewal keeps the stem with its own year.
    /// </summary>
    [Fact]
    public async Task BR_FAC_021_the_platform_reference_of_a_facility_and_its_renewal()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        Assert.Equal((422, "V-ORG-REF"), await tm.PostProblemAsync("/api/v1/companies", new { companyCode = "IMPX", refCode = "1MP", nameAr = "شركة", nameEn = "Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var co = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "IMP", nameAr = "شركة الاستيراد", nameEn = "Importer", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        Assert.Equal("IMP", (await tm.GetJsonAsync($"/api/v1/companies/{co}")).GetProperty("company").GetProperty("refCode").GetString());
        Assert.Equal((422, "V-INS-REF"), await tm.PostProblemAsync("/api/v1/institutions", new { code = "SNB1", refCode = "SN1", nameAr = "بنك", type = "BANK", country = "SA" }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "SNB", nameAr = "البنك", nameEn = "The Bank", type = "BANK", country = "SA" }));
        Assert.Equal("SNB", (await tm.GetJsonAsync($"/api/v1/institutions/{bank}")).GetProperty("institution").GetProperty("refCode").GetString());
        Assert.Equal((409, "V-INS-REF-TAKEN"), await tm.PostProblemAsync("/api/v1/institutions", new { code = "SNB-2", refCode = "SNB", nameAr = "بنك آخر", type = "BANK", country = "SA" }));

        var from = Today.AddMonths(-1);
        var yy = (from.Year % 100).ToString("00", CultureInfo.InvariantCulture);
        var id = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            borrower = co, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 10_000_000, effectiveFrom = D(from), expiryDate = D(from.AddYears(1).AddDays(-1)),
        }));
        await LenderAsync(fo, id, bank, 100, "SOLE");
        var card = await CardAsync(fo, id);
        Assert.Equal(JsonValueKind.Null, card.GetProperty("platformRef").ValueKind);
        Assert.Equal("The facility has no class (CAP, STL, MTL, LTL ...): choose it on the facility.",
            card.GetProperty("referenceParts").GetProperty("missing").EnumerateArray().Single().GetString());
        var rev = Open(card);
        Assert.Contains((await fo.GetJsonAsync($"/api/v1/facilities/{id}/revisions/{rev}/check")).GetProperty("errors").EnumerateArray(), e => e.GetProperty("code").GetString() == "V-FAC-REF");
        var (_, etag) = await fo.GetWithETagAsync($"/api/v1/facilities/{id}");
        Assert.Equal((422, "V-FAC-CLASS"), await fo.ProblemAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}", new { facilityClass = "WC" }, etag));
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}", new { facilityClass = "cap" }, etag)).StatusCode);
        Assert.Equal($"IMP-SNB-CAP-{yy}", (await CardAsync(fo, id)).GetProperty("referenceParts").GetProperty("preview").GetString());
        await ActAsync(fo, id, rev, "submit");
        Assert.Equal($"IMP-SNB-CAP-{yy}", (await ActAsync(tm, id, rev, "approve", new { acknowledge = Ack })).GetProperty("platformRef").GetString());
        card = await CardAsync(fo, id);
        Assert.Equal(($"IMP-SNB-CAP-{yy}", "CAP"), (card.GetProperty("platformRef").GetString(), card.GetProperty("facilityClass").GetString()));

        // The class is fixed once the reference is written; a later code of the company does not move it.
        await fo.PostOkAsync($"/api/v1/facilities/{id}/revisions", new { reasonKind = "CORRECTION", changeSummary = "A correction" });
        (_, etag) = await fo.GetWithETagAsync($"/api/v1/facilities/{id}");
        Assert.Equal((422, "V-FAC-REF-FIXED"), await fo.ProblemAsync(HttpMethod.Patch, $"/api/v1/facilities/{id}", new { facilityClass = "STL" }, etag));
        var (_, coTag) = await tm.GetWithETagAsync($"/api/v1/companies/{co}");
        await tm.OkAsync(HttpMethod.Patch, $"/api/v1/companies/{co}", new { refCode = "IM" }, coTag);
        Assert.Equal($"IMP-SNB-CAP-{yy}", (await CardAsync(fo, id)).GetProperty("platformRef").GetString());
        (_, coTag) = await tm.GetWithETagAsync($"/api/v1/companies/{co}");
        await tm.OkAsync(HttpMethod.Patch, $"/api/v1/companies/{co}", new { refCode = "IMP" }, coTag);

        // A second working capital facility of the same year takes a serial.
        var second = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = co, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 5_000_000, effectiveFrom = D(from), expiryDate = D(from.AddMonths(6)),
        }));
        await LenderAsync(fo, second, bank, 100, "SOLE");
        var rev2 = Open(await CardAsync(fo, second));
        await ActAsync(fo, second, rev2, "submit");
        Assert.Equal($"IMP-SNB-CAP-{yy}-2", (await ActAsync(tm, second, rev2, "approve", new { acknowledge = Ack })).GetProperty("platformRef").GetString());
        Assert.Single((await fo.GetJsonAsync($"/api/v1/facilities?q=IMP-SNB-CAP-{yy}-2")).GetProperty("items").EnumerateArray());

        // The renewal of the first keeps the stem and takes the year it starts.
        var next = (await fo.PostOkAsync($"/api/v1/facilities/{id}/actions/renew", new { })).GetProperty("id").GetString()!;
        var nextCard = await CardAsync(fo, next);
        var start = DateTime.ParseExact(nextCard.GetProperty("header").GetProperty("effectiveFrom").GetString()!, "yyyy-MM-dd", CultureInfo.InvariantCulture);
        var expected = $"IMP-SNB-CAP-{(start.Year % 100).ToString("00", CultureInfo.InvariantCulture)}";
        Assert.Equal(("CAP", expected), (nextCard.GetProperty("facilityClass").GetString(), nextCard.GetProperty("referenceParts").GetProperty("preview").GetString()));
        var rev3 = Open(nextCard);
        await ActAsync(fo, next, rev3, "submit");
        Assert.Equal(expected, (await ActAsync(tm, next, rev3, "approve", new { acknowledge = Ack })).GetProperty("platformRef").GetString());
    }
}
