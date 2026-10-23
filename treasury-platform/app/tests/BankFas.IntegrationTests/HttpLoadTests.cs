using System.Diagnostics;
using System.Globalization;
using System.Net;

namespace BankFas.IntegrationTests;

/// <summary>
/// A load on the HTTP routes (the external review 9.0, R3 and P1-2; docs/47 §4): twenty clients at once, each
/// signed in as its own user, read the facility card, its limits, its compliance dashboard and covenant tests, the
/// statements, the assessments and the group report, 400 requests in all, through the whole pipeline of the API
/// (authentication, the session binding, row-level security, the database). No request fails, and the 95th
/// percentile of each route stays within NFR-PERF-01 (2 s). The figures are written to the test output; they are
/// measured on the in-process test server against the local database, not on a production network.
/// </summary>
[Collection("database")]
public sealed class HttpLoadTests(PlatformFixture f)
{
    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];

    [Fact]
    public async Task Twenty_clients_read_the_main_routes_within_two_seconds_at_the_95th_percentile()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "L1", nameAr = "شركة الحمل", nameEn = "Load Co", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNKL", nameAr = "بنك الحمل", nameEn = "Load Bank", type = "BANK", country = "SA" }));
        await tm.PostOkAsync("/api/v1/accounts", new { company, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "800-1", openedOn = "2024-01-01", createRelationship = true });
        var fac = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/facilities", new { borrower = company, facilityType = "CREDIT_FACILITIES", currency = "SAR", totalAmount = 90_000_000, effectiveFrom = "2025-01-01", expiryDate = "2027-12-31" }));
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/lenders", new { institution = bank, sharePct = 100, roles = new[] { "SOLE" } });
        var root = (await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 90_000_000, noSourceReason = "Clause 1" })).GetProperty("id").GetString()!;
        for (var i = 1; i <= 10; i++)
            await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = $"L{i}", limitType = "GUARANTEES", parent = root, nameAr = $"حد {i}", amount = 5_000_000, noSourceReason = "Clause 2" });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "CURRENT_RATIO", titleAr = "نسبة التداول", noSourceReason = "Clause 15",
            covenant = new { measureKind = "RATIO", formula = "CURRENT_RATIO", thresholdState = "SET", @operator = "GE", thresholdValue = 1.20, testFrequency = "QUARTERLY" },
        });
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        var check = await fo.GetJsonAsync($"/api/v1/facilities/{fac}/revisions/{rev}/check");
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve",
            new { acknowledge = check.GetProperty("warnings").EnumerateArray().Select(w => w.GetProperty("code").GetString()).Concat(Ack).Distinct().ToArray() });
        var st = await StatementTests.StatementAsync(fo, company);
        await StatementTests.SaveAsync(fo, st, StatementTests.Balanced);
        await fo.PostOkAsync($"/api/v1/financial-statements/{st}/actions/submit", new { });
        await tm.PostOkAsync($"/api/v1/financial-statements/{st}/actions/approve", new { });

        string[] routes =
        [
            $"/api/v1/facilities/{fac}", $"/api/v1/facilities/{fac}/limits", $"/api/v1/facilities/{fac}/compliance", $"/api/v1/facilities/{fac}/covenant-tests",
            "/api/v1/financial-statements", $"/api/v1/financial-statements/{st}", "/api/v1/fin/assessments", "/api/v1/reports/compliance",
        ];
        // Twenty users of the tenant, each with its own session, as twenty people would be.
        var clients = new List<HttpClient>();
        for (var i = 0; i < 20; i++) clients.Add((await f.UserWithRoleAsync(t, "TM")).Client);
        foreach (var r in routes) Assert.Equal(HttpStatusCode.OK, (await clients[0].GetAsync(r, ct)).StatusCode);   // warm

        var times = routes.ToDictionary(r => r, _ => new System.Collections.Concurrent.ConcurrentBag<double>());
        var failures = new System.Collections.Concurrent.ConcurrentBag<string>();
        var wall = Stopwatch.StartNew();
        await Task.WhenAll(clients.Select(async (c, n) =>
        {
            for (var k = 0; k < 20; k++)
            {
                var route = routes[(n + k) % routes.Length];
                var watch = Stopwatch.StartNew();
                using var response = await c.GetAsync(route, ct);
                watch.Stop();
                if (response.StatusCode != HttpStatusCode.OK) failures.Add($"{route}: {(int)response.StatusCode}");
                times[route].Add(watch.Elapsed.TotalMilliseconds);
            }
        }));
        wall.Stop();
        Assert.Empty(failures);
        static double P(IEnumerable<double> xs, double p)
        {
            var s = xs.OrderBy(x => x).ToArray();
            return s[Math.Min(s.Length - 1, (int)Math.Ceiling(p * s.Length) - 1)];
        }
        var lines = routes.Select(r => string.Create(CultureInfo.InvariantCulture,
            $"{r.Replace(fac, "{facility}", StringComparison.Ordinal).Replace(st, "{statement}", StringComparison.Ordinal)}  n={times[r].Count}  p50={P(times[r], 0.5):0}ms  p95={P(times[r], 0.95):0}ms  max={times[r].Max():0}ms")).ToList();
        TestContext.Current.SendDiagnosticMessage(string.Join(Environment.NewLine, lines.Prepend(string.Create(CultureInfo.InvariantCulture,
            $"400 requests from 20 clients in {wall.Elapsed.TotalSeconds:0.0} s ({400 / wall.Elapsed.TotalSeconds:0} per second)"))));
        // Kept for the report of the run (docs/47): BANKFAS_IT_LOAD_REPORT names the file, else the temporary folder.
        await File.WriteAllLinesAsync(Environment.GetEnvironmentVariable("BANKFAS_IT_LOAD_REPORT") ?? Path.Combine(Path.GetTempPath(), "bankfas-http-load.txt"),
            lines.Prepend(string.Create(CultureInfo.InvariantCulture, $"400 requests from 20 clients in {wall.Elapsed.TotalSeconds:0.0} s")), ct);
        Assert.All(routes, r => Assert.True(P(times[r], 0.95) < 2000, $"{r}: p95 {P(times[r], 0.95):0} ms"));
    }
}
