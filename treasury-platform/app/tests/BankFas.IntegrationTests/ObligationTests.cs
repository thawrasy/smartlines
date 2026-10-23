using System.Net;
using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// Obligations, the agenda and breaches (S2 brief batch S2-F): the second part of AC-FAC-6 (a December fiscal year:
/// audited statements 210 days after the year end on 2026-07-29, internal half-year statements 45 days after the
/// period on 2026-08-14, a notice 30 working days before a change of ownership planned for 2026-12-20 on 2026-11-08
/// with Friday and Saturday off; the audited statements submitted on 2026-08-02 are 4 days late and open a LATE_REPORT
/// breach with CMP.BREACH; 210 changed to 180 regenerates the future items only), the waiver of an item and of a
/// breach by a treasury manager who did not record it, the OBL.DUE alert, and the compliance status.
/// </summary>
[Collection("database")]
public sealed class ObligationTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01"];

    private static async Task ApproveRevisionAsync(HttpClient fo, HttpClient tm, string fac)
    {
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });
    }

    private static object Audited(int days) => new
    {
        obligationType = "AUDITED_ANNUAL_FS", titleAr = "القوائم المدققة", titleEn = "Audited statements", noSourceReason = "Agreement clause 12",
        reporting = new { frequency = "ANNUAL", anchorKind = "AFTER_FISCAL_YEAR_END", offsetValue = days, documentBasis = "AUDITED", expectsEvidence = false },
    };

    [Fact]
    public async Task AC_FAC_6_second_part_the_agenda_lateness_regeneration_and_breaches()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        var contact = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/institutions/{bank}/contacts", new
        {
            fullNameAr = "مدير العلاقة", fullNameEn = "Relationship manager", contactMethods = new[] { new { kind = "EMAIL", value = "rm@bank.example" } },
        }));
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 10_000_000, effectiveFrom = "2026-01-01", expiryDate = "2027-12-31",
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });

        // V-OBL-01: a reporting obligation has its rule; a fixed date has no offset.
        Assert.Equal((422, "V-OBL-01"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/obligations", new { obligationType = "AUDITED_ANNUAL_FS", titleAr = "x", noSourceReason = "x" }));
        Assert.Equal((422, "V-OBL-01"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "AUDITED_ANNUAL_FS", titleAr = "x", noSourceReason = "x", reporting = new { frequency = "ONE_TIME", anchorKind = "FIXED_DATE", fixedDueDate = "2026-05-01", offsetValue = 3 },
        }));
        var audited = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", Audited(210))).GetProperty("id").GetString()!;
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "INTERNAL_SEMIANNUAL_FS", titleAr = "القوائم الداخلية", noSourceReason = "Agreement clause 12",
            reporting = new { frequency = "SEMIANNUAL", anchorKind = "AFTER_PERIOD_END", offsetValue = 45, documentBasis = "INTERNAL", expectsEvidence = false },
        });
        var notice = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "NOTICE_OWNERSHIP_CHANGE", titleAr = "إشعار تغيير الملكية", noSourceReason = "Agreement clause 14", cureDays = 30,
            reporting = new { frequency = "EVENT_BASED", anchorKind = "BEFORE_EVENT", offsetValue = 30, offsetUnit = "BUSINESS_DAYS", direction = "WE_SUBMIT", documentBasis = "NOT_APPLICABLE", expectsEvidence = false },
        })).GetProperty("id").GetString()!;
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "DEBT_TO_EQUITY", titleAr = "الدين إلى حقوق الملكية", noSourceReason = "Agreement clause 15",
            covenant = new { measureKind = "RATIO", formula = "DEBT_TO_EQUITY", thresholdState = "NOT_SPECIFIED_IN_AGREEMENT", testFrequency = "ANNUAL" },
        });
        var dividends = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "NO_DIVIDENDS", titleAr = "عدم توزيع الأرباح", noSourceReason = "Agreement clause 16", covenant = new { measureKind = "NONE" },
        })).GetProperty("id").GetString()!;
        var items = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}/obligations?view=draft")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal(5, items.Count);
        var ratio = items.Single(o => o.GetProperty("titleAr").GetString() == "الدين إلى حقوق الملكية").GetProperty("id").GetString()!;
        await ApproveRevisionAsync(fo, tm, fac);

        // The agenda: the audited statements of 2025 on 2026-07-29, the internal ones of the first half of 2026 on 2026-08-14.
        var agenda = (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/agenda")).GetProperty("items").EnumerateArray().ToList();
        JsonElement Due(string title, string due) => agenda.Single(i => i.GetProperty("titleAr").GetString() == title && i.GetProperty("dueDate").GetString() == due);
        var fy2025 = Due("القوائم المدققة", "2026-07-29");
        Assert.Equal(("2025-12-31", "OVERDUE"), (fy2025.GetProperty("periodEnd").GetString(), fy2025.GetProperty("status").GetString()));
        Assert.Equal("2026-06-30", Due("القوائم الداخلية", "2026-08-14").GetProperty("periodEnd").GetString());
        Due("القوائم المدققة", "2027-07-29");

        // The change of ownership planned for 2026-12-20: the notice is due 30 working days before, on 2026-11-08.
        var ev = await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations/{notice}/events", new { eventDate = "2026-12-20" });
        Assert.Equal("2026-11-08", ev.GetProperty("dueDate").GetString());
        Assert.Equal((409, "V-OBL-EVENT-EXISTS"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/obligations/{notice}/events", new { eventDate = "2026-12-20" }));

        // Submitted on 2026-08-02: four days late, a LATE_REPORT breach and CMP.BREACH.
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        var sub = await fo.PostOkAsync($"/api/v1/reporting-instances/{PlatformFixture.Id(fy2025)}/actions/submit", new { submittedOn = "2026-08-02" });
        Assert.Equal(4, sub.GetProperty("daysLate").GetInt32());
        Assert.Equal((409, "V-OBL-STATE"), await fo.PostProblemAsync($"/api/v1/reporting-instances/{PlatformFixture.Id(fy2025)}/actions/submit", new { submittedOn = "2026-08-02" }));
        var breach = (await tm.GetJsonAsync($"/api/v1/breaches?facility={fac}")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal(("LATE_REPORT", "OPEN", "2026-08-02"), (breach.GetProperty("kind").GetString(), breach.GetProperty("status").GetString(), breach.GetProperty("detectedOn").GetString()));
        while (await outbox.RunOnceAsync(ct) > 0) { }
        Assert.Contains((await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(), n => n.GetProperty("eventCode").GetString() == "CMP.BREACH");

        // A waiver of the breach: recorded by the officer with the bank's reference, contact and document; approved by the manager.
        var letter = await UploadAsync(fo, company, "Waiver letter");
        var b = breach.GetProperty("id").GetString()!;
        Assert.Equal((422, "V-OBL-WAIVER"), await fo.PostProblemAsync($"/api/v1/breaches/{b}/actions/record-waiver", new { waiverRef = "W-1", waiverDate = "2026-08-10" }));
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/breaches/{b}/actions/record-waiver",
            new { waiverRef = "W-1", waiverDate = "2026-08-10", bankContact = contact, document = letter })).StatusCode);
        Assert.Equal((403, "FORBIDDEN"), await fo.PostProblemAsync($"/api/v1/breaches/{b}/actions/approve-waiver", new { on = "2026-08-11" }));
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Post, $"/api/v1/breaches/{b}/actions/approve-waiver", new { on = "2026-08-11" })).StatusCode);
        Assert.Equal("WAIVED", (await tm.GetJsonAsync($"/api/v1/breaches?facility={fac}")).GetProperty("items")[0].GetProperty("status").GetString());

        // An item is waived only by obl.waiver.approve, with its reason and document; the H2 2025 internal statements.
        var h2 = Due("القوائم الداخلية", "2026-02-14");
        Assert.Equal((403, "FORBIDDEN"), await fo.PostProblemAsync($"/api/v1/reporting-instances/{PlatformFixture.Id(h2)}/actions/waive", new { reason = "Covered by the audited", document = letter }));
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Post, $"/api/v1/reporting-instances/{PlatformFixture.Id(h2)}/actions/waive", new { reason = "Covered by the audited", document = letter })).StatusCode);

        // 210 becomes 180: the 2026 item moves to 2027-06-29; the submitted 2025 item and its date stay.
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/revisions", new { reasonKind = "CORRECTION", changeSummary = "Audited statements in 180 days" });
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Put, $"/api/v1/facilities/{fac}/obligations/{audited}", Audited(180))).StatusCode);
        await ApproveRevisionAsync(fo, tm, fac);
        agenda = [.. (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/agenda")).GetProperty("items").EnumerateArray()];
        var kept = Due("القوائم المدققة", "2026-07-29");
        Assert.Equal(("SUBMITTED", 4), (kept.GetProperty("status").GetString(), kept.GetProperty("daysLate").GetInt32()));
        Due("القوائم المدققة", "2027-06-29");
        Assert.DoesNotContain(agenda, i => i.GetProperty("dueDate").GetString() == "2027-07-29");
        Assert.Equal("WAIVED", Due("القوائم الداخلية", "2026-02-14").GetProperty("status").GetString());

        // OBL.DUE seven days before the notice; the compliance status is RED while items are overdue.
        await new ExpiryAlertJob(f.Env.Db, new DayClock(new DateTime(2026, 11, 1))).RunOnceAsync(ct);
        while (await outbox.RunOnceAsync(ct) > 0) { }
        Assert.Contains((await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray(), n => n.GetProperty("eventCode").GetString() == "OBL.DUE");
        var compliance = await tm.GetJsonAsync($"/api/v1/facilities/{fac}/compliance");
        Assert.Equal("RED", compliance.GetProperty("status").GetString());
        Assert.True(compliance.GetProperty("overdue").GetInt32() >= 1);

        // FR-OBL-007: the descriptive covenant takes a manual status; a measured one does not. A review whose next date has
        // passed is overdue (amber in compliance), and the latest review is the covenant's status.
        var today = f.Env.Clock.GetUtcNow().UtcDateTime.Date;
        string Day(int d) => today.AddDays(d).ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        Assert.Equal((409, "V-OBL-NOT-DESCRIPTIVE"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/obligations/{ratio}/reviews", new { status = "COMPLIANT" }));
        Assert.Equal((422, "VALIDATION_FAILED"), await fo.PostProblemAsync($"/api/v1/facilities/{fac}/obligations/{dividends}/reviews", new { status = "FINE" }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations/{dividends}/reviews", new { status = "COMPLIANT", reviewDate = Day(-100), nextReviewOn = Day(-10), note = "No dividend declared" });
        var current = (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/obligations/{dividends}/reviews")).GetProperty("current");
        Assert.Equal(("COMPLIANT", true), (current.GetProperty("status").GetString(), current.GetProperty("reviewOverdue").GetBoolean()));
        Assert.Equal(1, (await tm.GetJsonAsync($"/api/v1/facilities/{fac}/compliance")).GetProperty("reviewsOverdue").GetInt32());
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations/{dividends}/reviews", new { status = "NON_COMPLIANT", nextReviewOn = Day(30), note = "A dividend was declared" });
        var reviews = await tm.GetJsonAsync($"/api/v1/facilities/{fac}/obligations/{dividends}/reviews");
        Assert.Equal(("NON_COMPLIANT", false), (reviews.GetProperty("current").GetProperty("status").GetString(), reviews.GetProperty("current").GetProperty("reviewOverdue").GetBoolean()));
        Assert.Equal(2, reviews.GetProperty("items").GetArrayLength());
        compliance = await tm.GetJsonAsync($"/api/v1/facilities/{fac}/compliance");
        Assert.Equal((1, 0), (compliance.GetProperty("nonCompliant").GetInt32(), compliance.GetProperty("reviewsOverdue").GetInt32()));
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
}
