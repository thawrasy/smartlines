using System.Text.Json;
using BankFas.Data.Jobs;

namespace BankFas.IntegrationTests;

/// <summary>
/// Ownership (S1-b brief, batch S1B-B; FR-ORG-015 to 018, BR-ORG-006 to 008): the wizard and its 100% check (AC-ORG-1),
/// the view on a date, a retroactive correction, the effective ownership through the account's own companies, the
/// mismatch report and its notification, and what an ownership does to a party: its usage and its merge (S1B-GAP-8, 17).
/// </summary>
[Collection("database")]
public sealed class OwnershipTests(PlatformFixture f)
{
    private static async Task<(string Id, string Party)> CompanyAsync(HttpClient c, string code, string en)
    {
        var r = await c.PostOkAsync("/api/v1/companies", new { companyCode = code, nameAr = "شركة " + code, nameEn = en, legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 });
        var id = PlatformFixture.Id(r);
        var detail = await c.GetJsonAsync($"/api/v1/companies/{id}");
        return (id, detail.GetProperty("company").GetProperty("party").GetString()!);
    }

    private static async Task<string> PersonAsync(HttpClient c, string en) =>
        PlatformFixture.Id(await c.PostOkAsync("/api/v1/parties", new { kind = "INDIVIDUAL", nameAr = "شخص " + en, nameEn = en, country = "SA", residencyStatus = "CITIZEN" }));

    private static object H(string holder, decimal pct) => new { holder, sharePercent = pct };

    private static Dictionary<string, decimal> View(JsonElement e, string list = "current") =>
        e.GetProperty(list).EnumerateArray().ToDictionary(r => r.GetProperty("holder").GetProperty("id").GetString()!, r => r.GetProperty("sharePercent").GetDecimal());

    [Fact]
    public async Task AC_ORG_1_the_change_totals_100_percent_and_closes_the_old_rows_the_day_before()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (co, _) = await CompanyAsync(tm, "C1", "First");
        var (a, b, c) = (await PersonAsync(tm, "A"), await PersonAsync(tm, "B"), await PersonAsync(tm, "C"));
        var url = $"/api/v1/companies/{co}/ownership";

        var first = await tm.PostOkAsync(url + "/changes", new { effectiveFrom = "2024-01-01", holdings = new[] { H(a, 60), H(b, 40) } });
        Assert.Equal("COMPLETE", first.GetProperty("ownershipStatus").GetString());

        // 55 + 35 + 8 = 98: refused with the difference (BR-ORG-006).
        var refused = await tm.SendAsync(HttpMethod.Post, url + "/changes", new { effectiveFrom = "2027-01-01", holdings = new[] { H(a, 55), H(b, 35), H(c, 8) } });
        var problem = JsonDocument.Parse(await refused.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement;
        Assert.Equal("V-ORG-OWN-TOTAL", problem.GetProperty("code").GetString());
        Assert.Contains("98%", problem.GetProperty("title").GetString(), StringComparison.Ordinal);
        Assert.Contains("difference of 2%", problem.GetProperty("title").GetString(), StringComparison.Ordinal);

        // A dry run writes nothing; the change itself closes the old rows on 2026-12-31 (BR-ORG-007).
        var dry = await tm.PostOkAsync(url + "/changes", new { effectiveFrom = "2027-01-01", holdings = new[] { H(a, 55), H(b, 35), H(c, 10) }, dryRun = true });
        Assert.Equal("2026-12-31", dry.GetProperty("plan").GetProperty("closes")[0].GetProperty("closesOn").GetString());
        Assert.Empty((await tm.GetJsonAsync(url)).GetProperty("planned").EnumerateArray());
        await tm.PostOkAsync(url + "/changes", new { effectiveFrom = "2027-01-01", holdings = new[] { H(a, 55), H(b, 35), H(c, 10) } });

        Assert.Equal(new Dictionary<string, decimal> { [a] = 60, [b] = 40 }, View(await tm.GetJsonAsync(url + "?asOf=2026-12-31")));
        Assert.Equal(new Dictionary<string, decimal> { [a] = 55, [b] = 35, [c] = 10 }, View(await tm.GetJsonAsync(url + "?asOf=2027-01-01")));
        // Today the 2027 change is planned.
        Assert.Equal(3, (await tm.GetJsonAsync(url)).GetProperty("planned").GetArrayLength());

        // One audit event per save.
        var audit = (await tm.GetJsonAsync("/api/v1/audit-events?action=OWNERSHIP_CHANGED")).GetProperty("items").GetArrayLength();
        Assert.Equal(2, audit);

        // A date before the last change is a correction: refused unless marked, then audited HIGH and confined to its period.
        Assert.Equal((422, "V-ORG-OWN-DATE"), await tm.PostProblemAsync(url + "/changes", new { effectiveFrom = "2025-07-01", holdings = new[] { H(a, 70), H(b, 30) } }));
        var fix = await tm.PostOkAsync(url + "/changes", new { effectiveFrom = "2025-07-01", holdings = new[] { H(a, 70), H(b, 30) }, retroactive = true, reason = "Register corrected" });
        Assert.Equal("RETROACTIVE", fix.GetProperty("flags")[0].GetString());
        Assert.Equal(new Dictionary<string, decimal> { [a] = 60, [b] = 40 }, View(await tm.GetJsonAsync(url + "?asOf=2025-06-30")));
        Assert.Equal(new Dictionary<string, decimal> { [a] = 70, [b] = 30 }, View(await tm.GetJsonAsync(url + "?asOf=2026-12-31")));
        Assert.Equal(new Dictionary<string, decimal> { [a] = 55, [b] = 35, [c] = 10 }, View(await tm.GetJsonAsync(url + "?asOf=2027-01-01")));
        var high = (await tm.GetJsonAsync("/api/v1/audit-events?action=OWNERSHIP_CORRECTED")).GetProperty("items")[0];
        Assert.Equal("HIGH", high.GetProperty("severity").GetString());

        // Shares give the percentages, the remainder on the largest (BR-ORG-006); the same date twice is refused.
        Assert.Equal((409, "V-ORG-OWN-SAME-DATE"), await tm.PostProblemAsync(url + "/changes", new { effectiveFrom = "2027-01-01", holdings = new[] { H(a, 100) } }));
        await tm.PostOkAsync(url + "/changes", new { effectiveFrom = "2028-01-01", holdings = new object[] { new { holder = a, sharesCount = 2 }, new { holder = b, sharesCount = 1 } } });
        var thirds = View(await tm.GetJsonAsync(url + "?asOf=2028-01-01"));
        Assert.Equal(66.666667m, thirds[a]);
        Assert.Equal(33.333333m, thirds[b]);
        Assert.Equal((422, "V-ORG-OWN-SELF"), await tm.PostProblemAsync(url + "/changes", new
        {
            effectiveFrom = "2029-01-01", holdings = new[] { H((await tm.GetJsonAsync($"/api/v1/companies/{co}")).GetProperty("company").GetProperty("party").GetString()!, 100) },
        }));
    }

    [Fact]
    public async Task Effective_ownership_follows_the_accounts_companies_and_the_report_lists_the_others()
    {
        var t = await f.CreateTenantAsync();
        var ct = TestContext.Current.CancellationToken;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (ca, pa) = await CompanyAsync(tm, "CA", "Alpha");
        var (cb, pb) = await CompanyAsync(tm, "CB", "Beta");
        var (cc, _) = await CompanyAsync(tm, "CC", "Gamma");
        var x = await PersonAsync(tm, "X");
        var y = await PersonAsync(tm, "Y");
        var fund = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new { kind = "ORGANIZATION", nameAr = "صندوق", nameEn = "Fund", country = "SA" }));

        // A holds 60% of B, B 50% of C, and A 10% of C directly: A's effective share of C is 10 + 30 = 40% (BR-ORG-008, FR-ORG-018).
        await tm.PostOkAsync($"/api/v1/companies/{ca}/ownership/changes", new { effectiveFrom = "2024-01-01", holdings = new[] { H(x, 100) } });
        await tm.PostOkAsync($"/api/v1/companies/{cb}/ownership/changes", new { effectiveFrom = "2024-01-01", holdings = new[] { H(pa, 60), H(y, 40) } });
        await tm.PostOkAsync($"/api/v1/companies/{cc}/ownership/changes", new
        {
            effectiveFrom = "2024-01-01",
            holdings = new object[] { H(pb, 50), H(pa, 10), H(fund, 40), new { holder = y, sharePercent = 12, layer = 2, intermediate = fund } },
        });
        var eff = (await tm.GetJsonAsync($"/api/v1/companies/{cc}/ownership/effective")).GetProperty("items").EnumerateArray()
            .ToDictionary(r => r.GetProperty("holder").GetProperty("id").GetString()!, r => r.GetProperty("effectivePercent").GetDecimal());
        Assert.Equal(40m, eff[pa]);
        Assert.Equal(50m, eff[pb]);
        Assert.Equal(40m, eff[x]);            // through A
        Assert.Equal(20m + 12m, eff[y]);       // 40% of B's 50%, and 12% through the fund
        // A path through a company of the account is refused: it follows from that company's holdings (DR-22).
        Assert.Equal((422, "V-ORG-OWN-PATH"), await tm.PostProblemAsync($"/api/v1/companies/{cc}/ownership/changes", new
        {
            effectiveFrom = "2025-01-01", holdings = new object[] { H(pb, 60), H(fund, 40), new { holder = x, sharePercent = 30, layer = 2, intermediate = pb } },
        }));

        // The report lists the companies that do not total 100% (FR-ORG-016); the daily pass notifies only recorded ones.
        var (cd, _) = await CompanyAsync(tm, "CD", "Delta");
        var report = (await tm.GetJsonAsync("/api/v1/reports/ownership-mismatch")).GetProperty("items").EnumerateArray().ToList();
        Assert.Contains(report, r => r.GetProperty("company").GetString() == cd && !r.GetProperty("recorded").GetBoolean());
        Assert.DoesNotContain(report, r => r.GetProperty("company").GetString() == cc);
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        await using (var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct))
        {
            await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-NTF-EXPIRY", Guid.NewGuid(), ct);
            // A holding closed in the past leaves the company short today (rows are never deleted; a test closes one directly).
            await Dapper.SqlMapper.ExecuteAsync(c, "UPDATE s SET EffectiveTo = '2025-12-31' FROM org.Shareholding AS s JOIN pty.Party AS p ON p.PartyId = s.HolderPartyId WHERE p.PublicId = @y AND s.Layer = 1;",
                new { y = Guid.Parse(y) });
        }
        await new ExpiryAlertJob(f.Env.Db, f.Env.Clock).RunOnceAsync(ct);
        await new OutboxJob(f.Env.Db, f.Env.Mail).RunOnceAsync(ct);
        var notices = (await tm.GetJsonAsync("/api/v1/notifications")).GetProperty("items").EnumerateArray()
            .Where(n => n.GetProperty("eventCode").GetString() == "OWN.TOTAL_MISMATCH").ToList();
        var notice = Assert.Single(notices);
        Assert.Contains("60%", notice.GetProperty("body").GetString(), StringComparison.Ordinal);
    }

    [Fact]
    public async Task A_holding_is_an_active_usage_and_blocks_a_colliding_merge()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (co, _) = await CompanyAsync(tm, "C1", "First");
        var a = await PersonAsync(tm, "A");
        var b = await PersonAsync(tm, "B");
        await tm.PostOkAsync($"/api/v1/companies/{co}/ownership/changes", new { effectiveFrom = "2024-01-01", holdings = new[] { H(a, 50), H(b, 50) } });

        // Both hold the same company: the merge is refused until one holding is closed (S1B-GAP-8).
        Assert.Equal((409, "V-PTY-MERGE-COLLISION"), await tm.PostProblemAsync($"/api/v1/parties/{b}/actions/merge", new { into = a, reason = "Same person" }));

        // The usage counts the active holding, and an active usage blocks the deactivation (FR-PTY-017, 018).
        var roles = (await tm.GetJsonAsync($"/api/v1/parties/{b}")).GetProperty("roles").EnumerateArray().Single();
        Assert.Equal(("SHAREHOLDER", 1, 1), (roles.GetProperty("role").GetString(), roles.GetProperty("count").GetInt32(), roles.GetProperty("active").GetInt32()));
        Assert.Equal((409, "V-PTY-IN-USE"), await tm.PostProblemAsync($"/api/v1/parties/{b}/actions/deactivate", new { }));

        // Once B's holding is closed (A takes it), the history counts but no longer blocks the deactivation (S1B-GAP-17).
        await tm.PostOkAsync($"/api/v1/companies/{co}/ownership/changes", new { effectiveFrom = "2025-01-01", holdings = new[] { H(a, 100) } });
        roles = (await tm.GetJsonAsync($"/api/v1/parties/{b}")).GetProperty("roles").EnumerateArray().Single();
        Assert.Equal((1, 0), (roles.GetProperty("count").GetInt32(), roles.GetProperty("active").GetInt32()));
        // The two closed rows of the same period still collide, so the merge stays refused; the history is never rewritten.
        Assert.Equal((409, "V-PTY-MERGE-COLLISION"), await tm.PostProblemAsync($"/api/v1/parties/{b}/actions/merge", new { into = a, reason = "Same person" }));
        Assert.True((await tm.SendAsync(HttpMethod.Post, $"/api/v1/parties/{b}/actions/deactivate", new { })).IsSuccessStatusCode);
    }
}
