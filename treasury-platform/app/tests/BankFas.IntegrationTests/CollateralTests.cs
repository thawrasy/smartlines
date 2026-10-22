using System.Net;
using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// Collateral, guarantors and completeness (S2 brief batch S2-E): AC-FAC-8 (the coverage of a facility of 40,000,000:
/// the note at 110% due for renewal on 2027-03-01, specified guarantees of 80,000,000 and one unspecified not added,
/// insurance at 75% with a shortfall of 10,000,000 and its T-60 alert on 2026-10-16, set-off and negative pledge as
/// flags, no single total; a release leaves the coverage from its date and stays in the register; the employee sees the
/// identity masked), FR-COL-014 (a new version, in force once approved), the links through the facility revision
/// (OQ-11), AC-PTY-3's completeness (83.3%, not ready, then 100%) and the pack (masked draft or full, audited), and
/// FR-COL-015 (three derived badges and the merge).
/// </summary>
[Collection("database")]
public sealed class CollateralTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];
    private const string Src = "Agreement clause 4";

    private static async Task<string> PartyAsync(HttpClient c, string kind, string nameAr, string nameEn) =>
        PlatformFixture.Id(await c.PostOkAsync("/api/v1/parties", kind == "INDIVIDUAL"
            ? new { kind, nameAr, nameEn, country = "SA", residencyStatus = "CITIZEN", birthDate = "1980-01-0" + (nameEn.Length % 9 + 1) }
            : (object)new { kind, nameAr, nameEn, country = "SA" }));

    private static async Task<string> CollateralAsync(HttpClient c, object body) => PlatformFixture.Id(await c.PostOkAsync("/api/v1/collaterals", body));

    private static async Task ApproveAsync(HttpClient c, string id) =>
        Assert.Equal(HttpStatusCode.NoContent, (await c.SendAsync(HttpMethod.Post, $"/api/v1/collaterals/{id}/actions/approve", new { })).StatusCode);

    private static async Task ApproveRevisionAsync(HttpClient fo, HttpClient tm, string fac)
    {
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });
    }

    private static async Task<string> UploadAsync(HttpClient c, string company, string title)
    {
        var up = await CompanyDocumentTests.UploadAsync(c, "/api/v1/documents", CompanyDocumentTests.Pdf(title), title + ".pdf", new Dictionary<string, string>
        {
            ["documentType"] = "FACILITY_ADDENDUM", ["title"] = title, ["company"] = company,
        });
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        return JsonDocument.Parse(await up.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement.GetProperty("id").GetString()!;
    }

    private static decimal Specified(JsonElement cov) =>
        cov.GetProperty("guarantees").GetProperty("specified").EnumerateArray().Where(s => s.GetProperty("currency").GetString() == "SAR").Sum(s => s.GetProperty("total").GetDecimal());

    [Fact]
    public async Task AC_FAC_8_coverage_release_versions_links_and_alerts()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 40_000_000, effectiveFrom = "2026-01-01", expiryDate = "2027-12-31",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        var l0 = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 40_000_000, noSourceReason = Src }))
            .GetProperty("id").GetString()!;

        var g1 = await PartyAsync(tm, "INDIVIDUAL", "كفيل أول", "First Guarantor");
        var g2 = await PartyAsync(tm, "INDIVIDUAL", "كفيل ثان", "Second Guarantor");
        var corp = await PartyAsync(tm, "ORGANIZATION", "شركة كافلة", "Guarantor Co");
        var idDoc = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/parties/{g1}/identity-documents", new { docKind = "NATIONAL_ID", issuingCountry = "SA", number = "1012345678", expiryDate = "2030-01-01" }));

        // V-COL-01: a specified guarantee has its amount, an unspecified one has none.
        Assert.Equal((422, "V-COL-01"), await fo.PostProblemAsync("/api/v1/collaterals", new
        {
            collateralType = "PERSONAL_GUARANTEE", titleAr = "كفالة", noSourceReason = Src, guarantee = new { guarantor = g1, amountMode = "SPECIFIED" },
        }));
        Assert.Equal((422, "V-COL-01"), await fo.PostProblemAsync("/api/v1/collaterals", new
        {
            collateralType = "PERSONAL_GUARANTEE", titleAr = "كفالة", noSourceReason = Src, guarantee = new { guarantor = g2, amountMode = "UNSPECIFIED", amount = 5, currency = "SAR" },
        }));
        var pn = await CollateralAsync(fo, new
        {
            collateralType = "PROMISSORY_NOTE", titleAr = "سند لأمر", owner = g1, noSourceReason = Src,
            note = new { amount = 44_000_000, currency = "SAR", issuedOn = "2025-03-01", renewalCycle = "ANNUAL", lastRenewedOn = "2026-03-01", custodyKind = "BANK", signers = new[] { g1 } },
        });
        var gu1 = await CollateralAsync(fo, new
        {
            collateralType = "PERSONAL_GUARANTEE", titleAr = "كفالة الكفيل الأول", noSourceReason = Src,
            guarantee = new { guarantor = g1, identityDocument = idDoc, amountMode = "SPECIFIED", amount = 40_000_000, currency = "SAR", signedOn = "2026-01-01" },
        });
        var gu2 = await CollateralAsync(fo, new { collateralType = "PERSONAL_GUARANTEE", titleAr = "كفالة الكفيل الثاني", noSourceReason = Src, guarantee = new { guarantor = g2, amountMode = "UNSPECIFIED" } });
        var guc = await CollateralAsync(fo, new
        {
            collateralType = "CORPORATE_GUARANTEE", titleAr = "كفالة الشركة", noSourceReason = Src, guarantee = new { guarantor = corp, amountMode = "SPECIFIED", amount = 40_000_000, currency = "SAR" },
        });
        var ins = await CollateralAsync(fo, new
        {
            collateralType = "INSURANCE_ASSIGNMENT", titleAr = "تجيير التأمين", noSourceReason = Src,
            insurance = new { policyNo = "POL-1", insurerName = "شركة التأمين", assignedTo = bank, coverageBasis = "FULL_LIMITS", sumInsured = 30_000_000, currency = "SAR", policyStart = "2026-01-01", policyExpiry = "2026-12-15" },
        });
        var so = await CollateralAsync(fo, new { collateralType = "SET_OFF", titleAr = "حق المقاصة", noSourceReason = Src, originalText = "للبنك حق المقاصة" });
        var np = await CollateralAsync(fo, new { collateralType = "NEGATIVE_PLEDGE", titleAr = "التعهد بعدم الرهن", noSourceReason = Src });
        // A property misses the required deed number of its template: refused at approval, approved once given (FR-COL-001).
        var re = await CollateralAsync(fo, new { collateralType = "REAL_ESTATE", titleAr = "عقار", noSourceReason = Src, attributes = new { CITY = "الرياض" } });
        Assert.Equal((422, "V-COL-01"), await tm.PostProblemAsync($"/api/v1/collaterals/{re}/actions/approve", new { }));
        Assert.Equal((422, "V-COL-01"), await fo.ProblemAsync(HttpMethod.Put, $"/api/v1/collaterals/{re}", new { titleAr = "عقار", noSourceReason = Src, attributes = new { ROOMS = 3 } }));
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Put, $"/api/v1/collaterals/{re}", new { titleAr = "عقار", noSourceReason = Src, attributes = new { DEED_NO = "D-1", CITY = "الرياض" } })).StatusCode);

        // FR-COL-014: col.approve, and not the preparer.
        Assert.Equal((403, "FORBIDDEN"), await fo.PostProblemAsync($"/api/v1/collaterals/{pn}/actions/approve", new { }));
        foreach (var id in new[] { pn, gu1, gu2, guc, ins, so, np, re }) await ApproveAsync(tm, id);
        var own = await CollateralAsync(tm, new { collateralType = "NEGATIVE_PLEDGE", titleAr = "تعهد", noSourceReason = Src });
        Assert.Equal((403, "V-COL-SOD"), await tm.PostProblemAsync($"/api/v1/collaterals/{own}/actions/approve", new { }));

        // OQ-11: the links are rows of the facility's draft, approved with it; the insurance covers the limit L0.
        foreach (var id in new[] { pn, gu1, gu2, guc, so, np }) await fo.PostOkAsync($"/api/v1/facilities/{fac}/collateral-links", new { collateral = id });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/collateral-links", new { collateral = ins, limit = l0 });
        Assert.Equal((409, "V-COL-LINKED"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/collateral-links", new { collateral = pn }));
        await ApproveRevisionAsync(fo, tm, fac);
        Assert.Equal(7, (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/collateral-links")).GetProperty("items").GetArrayLength());

        // On approval the terms are projected (AC-FAC-8): the note at 110% of the limit and two individual guarantors, with their origin; a projected key is not entered by hand.
        var terms = (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/terms")).GetProperty("items").EnumerateArray().ToList();
        JsonElement Term(string key) => terms.Single(x => x.GetProperty("key").GetString() == key);
        Assert.Equal((110m, "PROJECTED"), (Term("COL.PN_PCT_OF_LIMIT").GetProperty("value").GetDecimal(), Term("COL.PN_PCT_OF_LIMIT").GetProperty("origin").GetString()));
        Assert.Equal(2m, Term("COL.GUARANTORS_INDIVIDUAL").GetProperty("value").GetDecimal());
        Assert.Equal((true, true), (Term("COL.SET_OFF").GetProperty("value").GetBoolean(), Term("COL.NEGATIVE_PLEDGE").GetProperty("value").GetBoolean()));
        Assert.Equal(24m, Term("DUR.FACILITY_TERM_MONTHS").GetProperty("value").GetDecimal());
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/revisions", new { reasonKind = "CORRECTION", changeSummary = "Statement objection days" });
        Assert.Equal((409, "V-CMP-01"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/terms", new { termType = "COL.PN_PCT_OF_LIMIT", valueNumber = 100, noSourceReason = Src }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/terms", new { termType = "DUR.STATEMENT_OBJECTION_DAYS", valueNumber = 30, noSourceReason = Src });
        await ApproveRevisionAsync(fo, tm, fac);

        // A second facility: its note is 100% of its limit and its statement objection days are not in the agreement.
        var fac2 = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 20_000_000, effectiveFrom = "2026-01-01", expiryDate = "2026-12-31",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac2}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        var pn2 = await CollateralAsync(fo, new
        {
            collateralType = "PROMISSORY_NOTE", titleAr = "سند ثان", noSourceReason = Src, note = new { amount = 20_000_000, currency = "SAR", issuedOn = "2026-01-01", custodyKind = "BANK" },
        });
        await ApproveAsync(tm, pn2);
        await fo.PostOkAsync($"/api/v1/facilities/{fac2}/collateral-links", new { collateral = pn2 });
        await fo.PostOkAsync($"/api/v1/facilities/{fac2}/terms", new { termType = "DUR.STATEMENT_OBJECTION_DAYS", valueState = "NOT_SPECIFIED_IN_AGREEMENT", noSourceReason = Src });
        Assert.Equal((422, "V-CMP-01"), await fo.PostProblemAsync($"/api/v1/facilities/{fac2}/terms", new { termType = "DUR.LATE_GRACE_DAYS", valueState = "NOT_SPECIFIED_IN_AGREEMENT", valueNumber = 0, noSourceReason = Src }));
        await ApproveRevisionAsync(fo, tm, fac2);
        var cmp = await tm.GetJsonAsync("/api/v1/terms/compare?key=COL.PN_PCT_OF_LIMIT&asOf=2026-06-01");
        Assert.Equal((fac2, 100m), (cmp.GetProperty("best").GetProperty("facility").GetString(), cmp.GetProperty("best").GetProperty("value").GetDecimal()));
        Assert.Equal([100m, 110m], cmp.GetProperty("ranked").EnumerateArray().Select(r => r.GetProperty("term").GetProperty("value").GetDecimal()));
        var objection = await tm.GetJsonAsync("/api/v1/terms/compare?key=DUR.STATEMENT_OBJECTION_DAYS&asOf=2026-06-01");
        Assert.Equal(fac, objection.GetProperty("ranked")[0].GetProperty("term").GetProperty("facility").GetString());
        Assert.Equal(("NOT_SPECIFIED_IN_AGREEMENT", fac2), (objection.GetProperty("unranked")[0].GetProperty("valueState").GetString(), objection.GetProperty("unranked")[0].GetProperty("facility").GetString()));

        // R-COL-01 on 2026-10-20.
        var cov = await tm.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-10-20");
        var note = cov.GetProperty("notes")[0];
        Assert.Equal((110m, "2027-03-01"), (note.GetProperty("pctOfLimit").GetDecimal(), note.GetProperty("nextRenewalDue").GetString()));
        Assert.Equal(80_000_000m, Specified(cov));
        Assert.Equal((1, 2), (cov.GetProperty("guarantees").GetProperty("unspecifiedCount").GetInt32(), cov.GetProperty("guarantees").GetProperty("individualCount").GetInt32()));
        var policy = cov.GetProperty("insurance")[0];
        Assert.Equal((40_000_000m, 75m, 10_000_000m), (policy.GetProperty("required").GetDecimal(), policy.GetProperty("coveragePct").GetDecimal(), policy.GetProperty("shortfall").GetDecimal()));
        Assert.Equal((true, true), (cov.GetProperty("flags").GetProperty("setOff").GetBoolean(), cov.GetProperty("flags").GetProperty("negativePledge").GetBoolean()));
        Assert.False(cov.TryGetProperty("total", out _));
        Assert.False(cov.TryGetProperty("collateralTotal", out _));
        // FR-COL-004: the employee sees the guarantor's document badge and the number masked; revealing it is refused.
        var teCov = await te.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-10-20");
        var g1Item = teCov.GetProperty("guarantees").GetProperty("items").EnumerateArray().Single(i => i.GetProperty("guarantor").GetProperty("id").GetString() == g1);
        Assert.Equal("VALID", g1Item.GetProperty("documents").GetString());
        Assert.DoesNotContain("1012345678", g1Item.GetProperty("identity").GetString(), StringComparison.Ordinal);
        Assert.EndsWith("5678", g1Item.GetProperty("identity").GetString(), StringComparison.Ordinal);
        Assert.Equal((403, "FORBIDDEN"), await te.PostProblemAsync($"/api/v1/parties/{g1}/identity-documents/{idDoc}/actions/reveal", new { reason = "Check" }));

        // NTF-COL-01: the insurance expiring on 2026-12-15 alerts at T-60, on 2026-10-16, once.
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        async Task<int> AlertsAsync() =>
            (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Count(n => n.GetProperty("eventCode").GetString() == "COL.RENEWAL_DUE");
        async Task RunAsync(DateTime day)
        {
            await new ExpiryAlertJob(f.Env.Db, new DayClock(day)).RunOnceAsync(ct);
            while (await outbox.RunOnceAsync(ct) > 0) { }
        }
        await RunAsync(new DateTime(2026, 10, 15));
        Assert.Equal(0, await AlertsAsync());
        await RunAsync(new DateTime(2026, 10, 16));
        await RunAsync(new DateTime(2026, 10, 16));
        Assert.Equal(1, await AlertsAsync());

        // FR-COL-010: the corporate guarantee is released on 2026-11-01 with its reason and document; it stays in the register.
        Assert.Equal((422, "V-COL-RELEASE"), await fo.PostProblemAsync($"/api/v1/collaterals/{guc}/actions/release", new { releasedOn = "2026-11-01", reason = "Settled" }));
        var letter = await UploadAsync(fo, company, "Release letter");
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/collaterals/{guc}/actions/release", new { releasedOn = "2026-11-01", reason = "Bank letter", document = letter })).StatusCode);
        Assert.Equal(80_000_000m, Specified(await tm.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-10-31")));
        var after = await tm.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-11-01");
        Assert.Equal(40_000_000m, Specified(after));
        Assert.Contains(after.GetProperty("released").EnumerateArray(), r => r.GetProperty("collateral").GetString() == guc);
        Assert.Equal("RELEASED", (await tm.GetJsonAsync($"/api/v1/collaterals/{guc}")).GetProperty("collateral").GetProperty("status").GetString());

        // FR-COL-014: a new version of the first guarantee at 45,000,000 is a draft; the approved one counts until it is approved.
        var v2 = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/collaterals/{gu1}/versions", new
        {
            titleAr = "كفالة الكفيل الأول", noSourceReason = "Addendum 1", guarantee = new { guarantor = g1, identityDocument = idDoc, amountMode = "SPECIFIED", amount = 45_000_000, currency = "SAR" },
        }));
        Assert.Equal((409, "V-COL-DRAFT-EXISTS"), await fo.PostProblemAsync($"/api/v1/collaterals/{gu1}/versions", new { titleAr = "x", noSourceReason = "x", guarantee = new { guarantor = g1, amountMode = "UNSPECIFIED" } }));
        Assert.Equal(40_000_000m, Specified(await tm.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-11-02")));
        await ApproveAsync(tm, v2);
        Assert.Equal(45_000_000m, Specified(await tm.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-11-02")));
        Assert.Equal("SUPERSEDED", (await tm.GetJsonAsync($"/api/v1/collaterals/{gu1}")).GetProperty("collateral").GetProperty("status").GetString());

        // A correction unlinks the set-off from 2026-12-01; the copied links keep the insurance on the copy of L0.
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/revisions", new { reasonKind = "CORRECTION", changeSummary = "Set-off ends" });
        var draftLinks = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}/collateral-links?view=draft")).GetProperty("items");
        Assert.Equal(7, draftLinks.GetArrayLength());   // the draft reads the open rows: the approved ones until it changes them
        var link = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}/collateral-links")).GetProperty("items").EnumerateArray().Single(l => l.GetProperty("collateral").GetString() == so)
            .GetProperty("id").GetString()!;
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/collateral-links/{link}/actions/unlink", new { unlinkedOn = "2026-12-01" })).StatusCode);
        Assert.Equal((409, "V-COL-LINK-APPROVED"), await fo.ProblemAsync(HttpMethod.Delete, $"/api/v1/facilities/{fac}/collateral-links/{link}", null));
        await ApproveRevisionAsync(fo, tm, fac);
        var december = await tm.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-12-01");
        Assert.Equal((false, true), (december.GetProperty("flags").GetProperty("setOff").GetBoolean(), december.GetProperty("flags").GetProperty("negativePledge").GetBoolean()));
        Assert.Equal(75m, december.GetProperty("insurance")[0].GetProperty("coveragePct").GetDecimal());
        Assert.True((await tm.GetJsonAsync($"/api/v1/facilities/{fac}/coverage?asOf=2026-12-16")).GetProperty("insurance")[0].GetProperty("expired").GetBoolean());

        // SVC-FAC-08 and FR-COL-015: the guarantees of a party with their facility, and three derived badges.
        var given = (await tm.GetJsonAsync($"/api/v1/parties/{g1}/guarantees")).GetProperty("items");
        Assert.Equal(fac, given.EnumerateArray().Single().GetProperty("facilities")[0].GetProperty("id").GetString());
        var roles = (await tm.GetJsonAsync($"/api/v1/parties/{g1}")).GetProperty("roles").EnumerateArray().Select(r => r.GetProperty("role").GetString()).ToHashSet();
        Assert.Superset(new HashSet<string?> { "COLLATERAL_OWNER", "GUARANTOR", "NOTE_SIGNER" }, roles);
    }

    [Fact]
    public async Task AC_PTY_3_completeness_against_a_profile_and_the_pack()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var today = f.Env.Clock.GetUtcNow().UtcDateTime.Date;
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        // A resident guarantor whose residence permit expires in 26 days, below the 90 days the profile asks.
        var g = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new
        {
            kind = "INDIVIDUAL", nameAr = "كفيل مقيم", nameEn = "Resident Guarantor", country = "EG", residencyStatus = "RESIDENT", birthDate = "1979-05-05", birthPlace = "القاهرة",
            maritalStatus = "MARRIED",
        }));
        var permit = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/parties/{g}/identity-documents", new
        {
            docKind = "RESIDENCE", issuingCountry = "SA", number = "2123456789", expiryDate = today.AddDays(26).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture), isPrimary = true,
        }));
        var png = new byte[] { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4 };
        Assert.Equal(HttpStatusCode.Created, (await CompanyDocumentTests.UploadAsync(tm, $"/api/v1/parties/{g}/identity-documents/{permit}/images", png, "front.png",
            new Dictionary<string, string> { ["side"] = "FRONT" })).StatusCode);
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/parties/{g}/addresses", new { addressType = "NATIONAL", country = "SA", city = "الرياض", buildingNumber = "1234", postalCode = "12345", additionalNumber = "6789" });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/parties/{g}/contact-methods", new { kind = "MOBILE", value = "+966501234567" });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/parties/{g}/contact-methods", new { kind = "EMAIL", value = "guarantor@example.com" });

        // The baseline profile (PTY.KYC): 12 of 13 items apply (the passport is a GCC national's); 9 complete, 1 expiring soon, 2 missing.
        var c = await te.GetJsonAsync($"/api/v1/parties/{g}/completeness?bank={bank}");
        Assert.True(c.GetProperty("profile").GetProperty("baseline").GetBoolean());
        Assert.Equal((12, 10, 83.3m, false), (c.GetProperty("applicable").GetInt32(), c.GetProperty("done").GetInt32(), c.GetProperty("pct").GetDecimal(), c.GetProperty("ready").GetBoolean()));
        Assert.Equal(["EMPLOYER", "OCCUPATION"], c.GetProperty("items").EnumerateArray().Where(i => i.GetProperty("status").GetString() == "MISSING").Select(i => i.GetProperty("refCode").GetString()));
        await tm.OkAsync(HttpMethod.Put, $"/api/v1/parties/{g}/custom-fields/EMPLOYER", new { value = "شركة المقاولات" });
        await tm.OkAsync(HttpMethod.Put, $"/api/v1/parties/{g}/custom-fields/OCCUPATION", new { value = "مهندس" });
        c = await te.GetJsonAsync($"/api/v1/parties/{g}/completeness?bank={bank}");
        Assert.Equal((100m, true), (c.GetProperty("pct").GetDecimal(), c.GetProperty("ready").GetBoolean()));
        Assert.Equal("PRIMARY", c.GetProperty("warnings")[0].GetProperty("refCode").GetString());

        // FR-PTY-023: the bank's own profile replaces the baseline for that bank once active; its items are fixed then.
        var profile = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/kyc-profiles", new { institution = bank, nameAr = "ملف البنك", nameEn = "Bank profile", appliesToRole = "GUARANTOR", appliesToKind = "INDIVIDUAL" }));
        Assert.Equal((422, "V-KYC-EMPTY"), await fo.PostProblemAsync($"/api/v1/kyc-profiles/{profile}/actions/activate", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/kyc-profiles/{profile}/items", new { itemKind = "PARTY_FIELD", refCode = "NAME_AR", sortOrder = 1 })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/kyc-profiles/{profile}/items", new { itemKind = "IDENTITY_DOC", refCode = "PASSPORT", sortOrder = 2 })).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/kyc-profiles/{profile}/actions/activate", new { })).StatusCode);
        Assert.Equal((409, "APPROVED_FINAL"), await fo.PostProblemAsync($"/api/v1/kyc-profiles/{profile}/items", new { itemKind = "PARTY_FIELD", refCode = "NAME_EN" }));
        var own = await te.GetJsonAsync($"/api/v1/parties/{g}/completeness?bank={bank}");
        Assert.Equal((false, 2, 50m), (own.GetProperty("profile").GetProperty("baseline").GetBoolean(), own.GetProperty("applicable").GetInt32(), own.GetProperty("pct").GetDecimal()));
        Assert.True((await te.GetJsonAsync($"/api/v1/parties/{g}/completeness")).GetProperty("profile").GetProperty("baseline").GetBoolean());

        // FR-PTY-026: the employee gets the masked draft even when asking for the full pack; the officer gets the full numbers; both audited.
        var draft = await te.PostOkAsync($"/api/v1/parties/{g}/pack", new { full = true, includeImages = true });
        Assert.Equal(("DRAFT", "DRAFT_MASKED"), (draft.GetProperty("pack").GetProperty("kind").GetString(), draft.GetProperty("pack").GetProperty("watermark").GetString()));
        var masked = draft.GetProperty("pack").GetProperty("identityDocuments")[0];
        Assert.NotEqual("2123456789", masked.GetProperty("number").GetString());
        Assert.Equal(JsonValueKind.Null, masked.GetProperty("images").ValueKind);
        var full = await fo.PostOkAsync($"/api/v1/parties/{g}/pack", new { full = true, includeImages = true });
        Assert.Equal(("FULL", "2123456789"), (full.GetProperty("pack").GetProperty("kind").GetString(), full.GetProperty("pack").GetProperty("identityDocuments")[0].GetProperty("number").GetString()));
        Assert.Equal(1, full.GetProperty("pack").GetProperty("identityDocuments")[0].GetProperty("images").GetArrayLength());
        Assert.Matches("^[0-9a-f]{64}$", full.GetProperty("fingerprint").GetString());
        var ct = TestContext.Current.CancellationToken;
        await using var db = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(db, await TestEnvironment.TenantIdAsync(t.Code), "JOB-NTF-EXPIRY", Guid.NewGuid(), ct);
        Assert.Equal(2, await Dapper.SqlMapper.ExecuteScalarAsync<int>(db,
            "SELECT COUNT(*) FROM aud.SensitiveAccessLog AS s JOIN aud.AuditLog AS a ON a.AuditLogId = s.AuditLogId WHERE s.AccessKind = 'PACK_EXPORT' AND a.Action = 'PARTY_PACK_GENERATED';"));
    }

    [Fact]
    public async Task FR_COL_015_a_merge_moves_the_guarantee_with_its_document_and_refuses_a_shared_note()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var a = await PartyAsync(tm, "INDIVIDUAL", "شخص مكرر", "Duplicate Person");
        var b = await PartyAsync(tm, "INDIVIDUAL", "شخص باق", "Remaining Person");
        var doc = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/parties/{a}/identity-documents", new { docKind = "NATIONAL_ID", issuingCountry = "SA", number = "1098765432", expiryDate = "2031-01-01" }));
        var gu = await CollateralAsync(fo, new
        {
            collateralType = "PERSONAL_GUARANTEE", titleAr = "كفالة", noSourceReason = Src,
            guarantee = new { guarantor = a, identityDocument = doc, amountMode = "SPECIFIED", amount = 1_000_000, currency = "SAR" },
        });
        var note = await CollateralAsync(fo, new
        {
            collateralType = "PROMISSORY_NOTE", titleAr = "سند", noSourceReason = Src, note = new { amount = 1_000_000, currency = "SAR", issuedOn = "2026-01-01", signers = new[] { a } },
        });
        await ApproveAsync(tm, gu);
        await ApproveAsync(tm, note);

        await tm.PostOkAsync($"/api/v1/parties/{a}/actions/merge", new { into = b, reason = "Same person" });
        var g = (await tm.GetJsonAsync($"/api/v1/collaterals/{gu}")).GetProperty("guarantee");
        Assert.Equal((b, "******5432"), (g.GetProperty("guarantor").GetProperty("id").GetString(), g.GetProperty("identity").GetString()));
        Assert.Equal([b], (await tm.GetJsonAsync($"/api/v1/collaterals/{note}")).GetProperty("note").GetProperty("signers").EnumerateArray().Select(s => s.GetProperty("id").GetString()));

        // Two persons signing one note collide: the merge is refused (S2-GAP-11).
        var c = await PartyAsync(tm, "INDIVIDUAL", "موقع أول", "Signer One");
        var d = await PartyAsync(tm, "INDIVIDUAL", "موقع ثان", "Signer Two");
        var shared = await CollateralAsync(fo, new
        {
            collateralType = "PROMISSORY_NOTE", titleAr = "سند مشترك", noSourceReason = Src, note = new { amount = 2_000_000, currency = "SAR", issuedOn = "2026-01-01", signers = new[] { c, d } },
        });
        await ApproveAsync(tm, shared);
        Assert.Equal((409, "V-PTY-MERGE-COLLISION"), await tm.PostProblemAsync($"/api/v1/parties/{c}/actions/merge", new { into = d, reason = "Same person" }));
    }
}
