using System.Globalization;
using System.Text.Json;
using BankFas.Data.Finance;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// The company's side before its lenders (S2-b brief batch S2B-G): CA23 through the worker, the facility of the
/// assessed company expiring in 90 days is a renewal in the lead time that warns once at LEAD on the eve, again at D90
/// today, and never twice on a re-run, with a notification that carries no amount; the readiness file lists it; a
/// lender rating sits beside the assessment with its gap; an endorsement by TM (inside the line) is refused (50093) and
/// by AU succeeds; the evidence pack of the endorsed assessment has the same SHA-256 on two builds; a loss rate is
/// approved by another user than its preparer.
/// </summary>
[Collection("database")]
public sealed class ReadinessTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];
    private static string D(DateTime d) => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    [Fact]
    public async Task Warnings_readiness_ratings_endorsement_and_the_evidence_pack()
    {
        var ct = TestContext.Current.CancellationToken;
        var today = DateTime.UtcNow.Date;
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fa, _, _) = await f.UserWithRoleAsync(t, "FA");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (au, _, _) = await f.UserWithRoleAsync(t, "AU");
        var ind = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "IND", nameAr = "صناعية", nameEn = "Industrial", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        await tm.PostOkAsync("/api/v1/accounts", new { company = ind, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "900-1", openedOn = "2024-01-01", createRelationship = true });

        // A facility of the company that expires in 90 days: a renewal within the lead time (six months).
        var expiry = today.AddDays(90);
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
        {
            facilityClass = "CAP", borrower = ind, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 150_000_000, effectiveFrom = D(today.AddYears(-1)), expiryDate = D(expiry),
        }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 150_000_000, noSourceReason = "Clause 1" });
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });

        // The assessment of today on the worked example of docs/35, its statement ten months old (CA23).
        var periodEnd = new DateTime(today.Year, today.Month, 1).AddMonths(-9).AddDays(-1);
        await CreditTests.StatementAsync(fa, tm, ind, D(new DateTime(periodEnd.Year, periodEnd.Month, 1).AddMonths(-11).AddDays(-1)),
            new Dictionary<string, decimal>(CreditTests.Base) { ["TOTAL_ASSETS"] = 940, ["REVENUE"] = 850, ["GROSS_PROFIT"] = 245, ["CURRENT_PORTION_LTD"] = 55, ["OP_CASH_FLOW"] = 85 });
        var st = await CreditTests.StatementAsync(fa, tm, ind, D(periodEnd), CreditTests.Base);
        var a = PlatformFixture.Id(await fa.PostOkAsync("/api/v1/fin/assessments", new { statement = st, scorecard = "GENERAL_CORPORATE", assessmentDate = D(today) }));
        const string why = "test fixture: the worked example of docs/35";
        await fa.OkAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "BUSINESS_PROFILE", grade = "Ba1", justification = why });
        await fa.OkAsync(HttpMethod.Post, $"/api/v1/fin/assessments/{a}/inputs", new { kind = "QUALITATIVE", metric = "FINANCIAL_POLICY", grade = "Baa3", justification = why });
        await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/compute", new { });
        await fa.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/submit", new { });
        await tm.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/approve", new { });

        // The readiness file: the renewal within the lead time, not ready.
        var file = await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/readiness");
        var renewal = file.GetProperty("events").EnumerateArray().Single(e => e.GetProperty("EventKind").GetString() == "RENEWAL");
        var readiness = renewal.GetProperty("Readiness").GetString();
        Assert.Equal("RED", readiness);
        Assert.True(file.GetProperty("requests").GetArrayLength() > 0);

        // CA23 through the worker: LEAD on the eve (91 days), D90 today, nothing on a second run of the day.
        await new FinanceReadinessJob(f.Env.Db, new DayClock(today.AddDays(-1).AddHours(12))).RunOnceAsync(ct);
        await new FinanceReadinessJob(f.Env.Db, TimeProvider.System).RunOnceAsync(ct);
        await new FinanceReadinessJob(f.Env.Db, TimeProvider.System).RunOnceAsync(ct);
        var warnings = (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/readiness")).GetProperty("warnings").EnumerateArray()
            .Where(w => w.GetProperty("EventKind").GetString() == "RENEWAL").Select(w => $"{w.GetProperty("Stage").GetString()}:{w.GetProperty("Readiness").GetString()}").ToList();
        Assert.Equal([$"D90:{readiness}", $"LEAD:{readiness}"], warnings);

        // The notification of the warning: the company's name and the date, never an amount (FR-NTF-021, CA24).
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        while (await outbox.RunOnceAsync(ct) > 0) { }
        var code = $"FIN.READINESS_{readiness}";
        var sent = (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Where(n => n.GetProperty("eventCode").GetString() == code).ToList();
        Assert.Equal(2, sent.Count);
        Assert.All(sent, n =>
        {
            var text = n.GetProperty("title").GetString() + " " + n.GetProperty("body").GetString();
            Assert.True(text.Contains("Industrial", StringComparison.Ordinal) || text.Contains("صناعية", StringComparison.Ordinal), text);
            Assert.DoesNotContain("150", text, StringComparison.Ordinal);
            Assert.Contains($"/fin/assessments/{a}/readiness", n.GetProperty("deepLink").GetString(), StringComparison.OrdinalIgnoreCase);
        });

        // A lender's rating beside the assessment of its date (FR-FIN-039); fewer than three ratings give no bias yet.
        var rating = PlatformFixture.Id(await fa.PostOkAsync("/api/v1/fin/lender-ratings", new
        {
            company = ind, lender = bank, ratingDate = D(today), lenderGradeLabel = "Grade 6", grade = "B1", mappingKind = "MAPPED_BY_TREASURY", noSourceReason = "Told at the annual review",
        }));
        var compared = (await fa.GetJsonAsync($"/api/v1/fin/lender-ratings?company={ind}")).GetProperty("items").EnumerateArray().Single();
        Assert.Equal(("B1", "LENDER_MORE_SEVERE", a), (compared.GetProperty("lenderGrade").GetString(), compared.GetProperty("direction").GetString(), compared.GetProperty("assessment").GetString()));
        Assert.True(compared.GetProperty("gapNotches").GetInt32() > 0);
        Assert.True((await fa.GetJsonAsync($"/api/v1/fin/lender-ratings/{rating}/gap-drivers")).GetProperty("items").GetArrayLength() > 0);
        Assert.Equal("INSUFFICIENT", (await fa.GetJsonAsync($"/api/v1/fin/calibration?company={ind}")).GetProperty("items")[0].GetProperty("bias").GetString());

        // BR-FIN-043: TM prepares and approves assessments, so it does not endorse (50093); AU does.
        var mine = await tm.GetJsonAsync($"/api/v1/fin/assessments/{a}/endorsement");
        Assert.False(mine.GetProperty("canEndorse").GetBoolean());
        Assert.Equal((409, "ENDORSEMENT_REFUSED"), await tm.PostProblemAsync($"/api/v1/fin/assessments/{a}/actions/endorse", new { note = "For the lender's renewal file" }));
        Assert.True((await au.GetJsonAsync($"/api/v1/fin/assessments/{a}/endorsement")).GetProperty("canEndorse").GetBoolean());
        Assert.Equal((409, "EVIDENCE_PACK_REFUSED"), await au.PostProblemAsync($"/api/v1/fin/assessments/{a}/actions/evidence-pack", new { purpose = "Before the endorsement" }));
        await au.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/endorse", new { note = "For the lender's renewal file" });
        Assert.Equal("ENDORSED", (await fa.GetJsonAsync($"/api/v1/fin/assessments/{a}/endorsement")).GetProperty("useScope").GetString());

        // BR-FIN-049: the same content gives the same hash.
        var p1 = await au.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/evidence-pack", new { purpose = "Renewal file of Bank One" });
        var p2 = await au.PostOkAsync($"/api/v1/fin/assessments/{a}/actions/evidence-pack", new { purpose = "Renewal file of Bank One" });
        Assert.Equal(64, p1.GetProperty("sha256").GetString()!.Length);
        Assert.Equal(p1.GetProperty("sha256").GetString(), p2.GetProperty("sha256").GetString());
        Assert.Equal("BankFas assessment evidence pack v1", p1.GetProperty("pack").GetProperty("format").GetString());

        // A loss rate is prepared by one holder and approved by another (058).
        var rate = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/fin/loss-rates", new { bucket = "AR_AGE_OVER_365", lossRatePct = 60, effectiveFrom = D(today.AddYears(-2)) }));
        Assert.Equal((403, "FORBIDDEN"), await fa.PostProblemAsync($"/api/v1/fin/loss-rates/{rate}/actions/approve", new { }));
        await tm.PostOkAsync($"/api/v1/fin/loss-rates/{rate}/actions/approve", new { });
        Assert.Contains((await fa.GetJsonAsync("/api/v1/fin/loss-rates")).GetProperty("items").EnumerateArray(),
            r => r.GetProperty("bucket").GetString() == "AR_AGE_OVER_365" && r.GetProperty("status").GetString() == "APPROVED" && r.GetProperty("lossRatePct").GetDecimal() == 60m);
        Assert.Equal(JsonValueKind.Array, (await fa.GetJsonAsync($"/api/v1/fin/provision-check?statement={st}")).GetProperty("items").ValueKind);
    }
}
