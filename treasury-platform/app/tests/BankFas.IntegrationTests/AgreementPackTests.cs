using System.Globalization;
using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// AC-FAC-11, the four agreements (S2 brief S2-GAP-1; DOC-B06 section 6.5): each synthetic pack DS-AGR A to D loads
/// through the API as a facility revision, its integrity check has no error, another user approves it, the approval
/// projects its terms and generates its agenda, and every row of the pack's summary is found on the facility: A's
/// shared caps and agenda, B's renewal chain and children equal to the parent, C's limit outside the total, its
/// revenue covenant and the bank's unilateral extension, D's children at 95% and its empty covenant values, still not
/// specified. Then the expiry warning on the packs' facilities with an injected clock: the alert of each facility once
/// per threshold, and a second run of the day sends nothing.
/// </summary>
[Collection("database")]
public sealed class AgreementPackTests(PlatformFixture f)
{
    private sealed class DayClock(DateTime day) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => new(day, TimeSpan.Zero);
    }

    internal static string PackDir(string pack) => Path.Combine(AppContext.BaseDirectory, "DS-AGR", pack, "v1");

    internal sealed record Loaded(string Facility, string? Predecessor, Dictionary<string, string> Limits);

    /// <summary>Loads a pack: the bank, the facility (or the predecessor and its renewal), lenders, the agreement document, limits, lines, pricing, obligations and terms; then submit and approve.</summary>
    private static void Shift(JsonNode node, int months)
    {
        switch (node)
        {
            case JsonObject o:
                foreach (var key in o.Select(p => p.Key).ToList())
                    if (o[key] is JsonValue v && v.TryGetValue<string>(out var text) && text.Length == 10
                        && DateTime.TryParseExact(text, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d))
                        o[key] = d.AddMonths(months).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                    else if (o[key] is { } child) Shift(child, months);
                break;
            case JsonArray arr:
                foreach (var child in arr) if (child is not null) Shift(child, months);
                break;
        }
    }

    internal static async Task<Loaded> LoadAsync(PlatformFixture f, HttpClient fo, HttpClient tm, string company, string pack, int shiftMonths = 0)
    {
        // The manifest fingerprints bind the pack to what its reviewer signs (DOC-B06 section 6.2).
        var manifest = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(PackDir(pack), "manifest.json")))!["fingerprints"]!.AsObject();
        foreach (var (file, print) in manifest)
        {
            var hash = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(await File.ReadAllBytesAsync(Path.Combine(PackDir(pack), file))));
            Assert.Equal(print!.GetValue<string>(), "sha256:" + hash);
        }
        var a = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(PackDir(pack), "agreement.json")))!.AsObject();
        // A later stage's exit test needs the facility in force on the run date: every date of the pack moves by whole months.
        if (shiftMonths != 0) Shift(a, shiftMonths);
        var today = f.Env.Clock.GetUtcNow().UtcDateTime.Date;
        var bank = a["bank"]!.AsObject();
        var bankId = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = (string)bank["code"]!, refCode = "BK" + ((string)bank["code"]!)[^1..], nameAr = (string)bank["nameAr"]!, nameEn = (string)bank["nameEn"]!, type = "BANK", country = "SA" }));
        var fac = a["facility"]!.AsObject();
        fac["borrower"] = company;
        // BR-FAC-021: the class of the platform reference is the platform's, not the agreement's; the packs are working capital facilities.
        fac["facilityClass"] ??= "CAP";
        string? predecessor = null;
        string id;
        async Task ApproveAsync(string facility)
        {
            var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{facility}")).GetProperty("draft").GetProperty("revision").GetString()!;
            var check = await fo.GetJsonAsync($"/api/v1/facilities/{facility}/revisions/{rev}/check");
            Assert.True(check.GetProperty("errors").GetArrayLength() == 0, $"{pack}: {check.GetProperty("errors")}");
            await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{facility}/revisions/{rev}/actions/submit", new { });
            // The approver reads the warnings and acknowledges them.
            var warnings = check.GetProperty("warnings").EnumerateArray().Select(w => w.GetProperty("code").GetString()).Distinct().ToArray();
            await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{facility}/revisions/{rev}/actions/approve", new { acknowledge = warnings });
        }
        if (a["predecessor"] is JsonObject p)
        {
            predecessor = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new
            {
                facilityClass = "CAP", borrower = company, facilityType = (string)fac["facilityType"]!, currency = (string)fac["currency"]!, totalAmount = (decimal)p["totalAmount"]!,
                effectiveFrom = (string)p["effectiveFrom"]!, expiryDate = (string)p["expiryDate"]!, bankReferenceNo = (string)fac["bankReferenceNo"]! + "-P",
            }));
            await fo.PostOkAsync($"/api/v1/facilities/{predecessor}/lenders", new { institution = bankId, sharePct = 100, roles = new[] { "SOLE" } });
            await ApproveAsync(predecessor);
            id = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/facilities/{predecessor}/actions/renew", new
            {
                effectiveFrom = (string)fac["effectiveFrom"]!, expiryDate = (string)fac["expiryDate"]!, totalAmount = (decimal)fac["totalAmount"]!, bankReferenceNo = (string)fac["bankReferenceNo"]!,
            }));
        }
        else
        {
            id = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", fac));
            foreach (var l in a["lenders"]!.AsArray())
                await fo.PostOkAsync($"/api/v1/facilities/{id}/lenders", new { institution = bankId, sharePct = (decimal)l!["sharePct"]!, roles = l["roles"]!.AsArray().Select(r => (string)r!).ToArray() });
        }
        // The agreement itself, the source of every value that names its page.
        var up = await CompanyDocumentTests.UploadAsync(fo, "/api/v1/documents", CompanyDocumentTests.Pdf("Agreement " + pack), $"agreement-{pack}.pdf", new Dictionary<string, string>
        {
            ["documentType"] = "FACILITY_AGREEMENT", ["title"] = "Synthetic agreement " + pack, ["company"] = company,
        });
        Assert.Equal(HttpStatusCode.Created, up.StatusCode);
        var doc = JsonDocument.Parse(await up.Content.ReadAsStringAsync()).RootElement.GetProperty("id").GetString()!;
        await fo.PostOkAsync($"/api/v1/facilities/{id}/documents", new { document = doc, precedenceRank = 1, language = "AR" });
        void Source(JsonObject o)
        {
            if (o["page"] is { } page) { o["sourceDocument"] = doc; o["sourcePage"] = (string)page!; o.Remove("page"); }
            else o["noSourceReason"] = "Not in the agreement's text";
        }
        // A predecessor's tree comes with its renewal; the renewal replaces it with the pack's.
        var existing = predecessor is null ? [] : (await fo.GetJsonAsync($"/api/v1/facilities/{id}/limits?view=draft")).GetProperty("limits").EnumerateArray().ToList();
        if (existing.Count > 0) throw new InvalidOperationException("The predecessor of a pack has no tree.");
        var limits = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var n in a["limits"]!.AsArray())
        {
            var l = n!.AsObject().DeepClone().AsObject();
            if (l["parent"] is { } parent) l["parent"] = limits[(string)parent!];
            Source(l);
            limits[(string)l["code"]!] = (await fo.PostOkAsync($"/api/v1/facilities/{id}/limits", l)).GetProperty("id").GetString()!;
        }
        foreach (var n in a["lines"]!.AsArray())
        {
            var l = n!.AsObject().DeepClone().AsObject();
            var limit = limits[(string)l["limit"]!];
            l.Remove("limit");
            Source(l);
            await fo.PostOkAsync($"/api/v1/facilities/{id}/limits/{limit}/lines", l);
        }
        foreach (var n in a["pricing"]!.AsArray())
        {
            var r = n!.AsObject().DeepClone().AsObject();
            if (r["scopeLimit"] is { } sl) r["scopeLimit"] = limits[(string)sl!];
            if (DateTime.Parse((string)r["effectiveFrom"]!, CultureInfo.InvariantCulture) < today) r["retroactiveReason"] = "Entered from the signed agreement";
            Source(r);
            await fo.PostOkAsync($"/api/v1/facilities/{id}/pricing-rules", r);
        }
        foreach (var n in a["obligations"]!.AsArray())
        {
            var o = n!.AsObject().DeepClone().AsObject();
            Source(o);
            await fo.PostOkAsync($"/api/v1/facilities/{id}/obligations", o);
        }
        foreach (var n in a["terms"]!.AsArray())
        {
            var t = n!.AsObject().DeepClone().AsObject();
            Source(t);
            await fo.PostOkAsync($"/api/v1/facilities/{id}/terms", t);
        }
        await ApproveAsync(id);
        return new Loaded(id, predecessor, limits);
    }

    private static async Task CheckAsync(HttpClient tm, string pack, Loaded x, List<string> failures)
    {
        var card = await tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}");
        var tree = await tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/limits");
        var limits = tree.GetProperty("limits").EnumerateArray().ToDictionary(l => l.GetProperty("limit").GetProperty("code").GetString()!);
        var agenda = (await tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/agenda")).GetProperty("items").EnumerateArray().ToList();
        var terms = (await tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/terms")).GetProperty("items").EnumerateArray().ToList();
        var obligations = (await tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/obligations")).GetProperty("items").EnumerateArray().ToList();
        foreach (var line in (await File.ReadAllLinesAsync(Path.Combine(PackDir(pack), "summary.csv"))).Skip(1).Where(l => l.Length > 0))
        {
            var c = line.Split(',');
            var (check, target, expected) = (c[0], c[1], c[2]);
            string? actual = check switch
            {
                "LIMIT_CAP" => limits[target].GetProperty("limit").GetProperty("cap").GetDecimal().ToString("0.####", CultureInfo.InvariantCulture),
                "DISTRIBUTION" => limits[target].GetProperty("limit").GetProperty("distributionMode").GetString(),
                "LINES" => limits.Values.Sum(l => l.GetProperty("lines").GetArrayLength()).ToString(CultureInfo.InvariantCulture),
                "OUTSIDE_TOTAL" => tree.GetProperty("outsideTotal").GetDecimal().ToString("0.####", CultureInfo.InvariantCulture),
                "SCAN" => limits[target].GetProperty("limit").GetProperty("source").GetProperty("readFromScan").GetBoolean() ? "true" : "false",
                "AGENDA_DUE" => agenda.Any(i => i.GetProperty("titleAr").GetString() == target && i.GetProperty("dueDate").GetString() == expected) ? expected : "missing",
                "AGENDA_COUNT" => agenda.Count(i => i.GetProperty("titleAr").GetString() == target).ToString(CultureInfo.InvariantCulture),
                "TERM" => terms.FirstOrDefault(t => t.GetProperty("key").GetString() == target) is { ValueKind: JsonValueKind.Object } t
                    ? t.GetProperty("value").ValueKind == JsonValueKind.Number ? t.GetProperty("value").GetDecimal().ToString("0.####", CultureInfo.InvariantCulture) : t.GetProperty("valueState").GetString()
                    : "missing",
                "COVENANT_STATE" => obligations.FirstOrDefault(o => o.GetProperty("titleAr").GetString() == target) is { ValueKind: JsonValueKind.Object } o
                    ? o.GetProperty("covenant").GetProperty("thresholdState").GetString() : "missing",
                "CHAIN" => (await tm.GetJsonAsync($"/api/v1/facilities/{x.Facility}/chain")).GetProperty("items").GetArrayLength().ToString(CultureInfo.InvariantCulture),
                "PREDECESSOR_STATUS" => (await tm.GetJsonAsync($"/api/v1/facilities/{x.Predecessor}")).GetProperty("status").GetString(),
                "UNILATERAL" => card.GetProperty("header").GetProperty("bankUnilateralRights").EnumerateArray().Any(r => r.GetString() == expected) ? expected : "missing",
                "ALERT_ON" => expected,   // checked by the expiry run below
                _ => "unknown check",
            };
            if (actual != expected) failures.Add($"{pack} {check} {target}: expected {expected}, found {actual}");
        }
    }

    [Fact]
    public async Task AC_FAC_11_the_four_agreements_load_with_no_constraint_outside_the_model()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "SYN", nameAr = "الشركة المقترضة", nameEn = "Borrower Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        await tm.PostOkAsync("/api/v1/base-rates/SAIBOR_3M/values", new { effectiveDate = "2025-01-01", valuePct = 5.40m });
        var failures = new List<string>();
        var loaded = new Dictionary<string, Loaded>(StringComparer.Ordinal);
        foreach (var pack in new[] { "A", "B", "C", "D" })
        {
            loaded[pack] = await LoadAsync(f, fo, tm, company, pack);
            await CheckAsync(tm, pack, loaded[pack], failures);
        }
        Assert.True(failures.Count == 0, string.Join(Environment.NewLine, failures));

        // The expiry warning on 2028-10-10: A expires in 51 days (FAC.EXPIRY_DUE at 60), B and C ran out with no successor (FAC.VALIDITY_UNCONFIRMED); once per threshold.
        var outbox = new OutboxJob(f.Env.Db, f.Env.Mail);
        async Task<List<JsonElement>> AlertsAsync() =>
            [.. (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray().Where(n => n.GetProperty("eventCode").GetString() is "FAC.EXPIRY_DUE" or "FAC.VALIDITY_UNCONFIRMED")];
        for (var i = 0; i < 2; i++)
        {
            await new ExpiryAlertJob(f.Env.Db, new DayClock(new DateTime(2028, 10, 10))).RunOnceAsync(ct);
            while (await outbox.RunOnceAsync(ct) > 0) { }
        }
        var alerts = await AlertsAsync();
        Assert.Single(alerts, a => a.GetProperty("eventCode").GetString() == "FAC.EXPIRY_DUE");
        Assert.Equal(2, alerts.Count(a => a.GetProperty("eventCode").GetString() == "FAC.VALIDITY_UNCONFIRMED"));
    }
}
