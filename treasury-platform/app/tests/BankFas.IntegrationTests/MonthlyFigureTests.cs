using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Monthly figures and flows (S2-b brief batch S2B-C): V-FIN-02 (a month that ended, inside the account's opening and
/// closing; the missing months of the grid), BR-FIN-048 (entered by one user and confirmed as entered by another
/// holder of fin.stats.confirm; a confirmed figure is frozen and reopened with a reason by someone other than its
/// author, and the reopener neither edits nor confirms it next), OQ-12 (a treasury employee enters and sees the
/// figures), BR-FIN-016 (one level a month: the bank or its facilities), BR-FIN-017 (12,000,000 a year with 3,000,000
/// confirmed over the four months that ended: BEHIND, 9,000,000 remaining, 1,125,000 a month) and BR-FIN-050 (closed
/// through 2025-12-31, a November 2025 flow is refused and a May 2026 flow accepted; the close is reopened by another).
/// </summary>
[Collection("database")]
public sealed class MonthlyFigureTests(PlatformFixture f)
{
    private static readonly string[] Ack = ["V-FAC-NO-AGREEMENT", "V-FAC-01", "V-COL-KYC", "V-COL-NOT-APPROVED", "V-FAC-08"];

    [Fact]
    public async Task Monthly_balances_are_entered_confirmed_and_reopened_by_different_users()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (tm2, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));
        var bank = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/institutions", new { code = "BNK1", nameAr = "البنك الأول", nameEn = "Bank One", type = "BANK", country = "SA" }));
        var account = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new
        {
            company, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "900-1", openedOn = "2026-03-15", createRelationship = true,
        }));

        // V-FIN-02: not before the month of opening, not a month that has not ended.
        Assert.Equal((422, "V-FIN-02"), await te.ProblemAsync(HttpMethod.Put, "/api/v1/account-stats", new { items = new[] { new { account, month = "2026-02", avgDailyBalance = 1 } } }));
        Assert.Equal((422, "V-FIN-02"), await te.ProblemAsync(HttpMethod.Put, "/api/v1/account-stats", new { items = new[] { new { account, month = "2099-01", avgDailyBalance = 1 } } }));
        var saved = await te.OkAsync(HttpMethod.Put, "/api/v1/account-stats", new
        {
            items = new object[]
            {
                new { account, month = "2026-03", avgDailyBalance = 5_000_000, minBalance = 4_000_000, endBalance = 5_500_000, sourceKind = "BANK_STATEMENT" },
                new { account, month = "2026-05-31", avgDailyBalance = -10_000, sourceKind = "BANK_NOTICE" },
            },
        });
        Assert.Single(saved.GetProperty("warnings").EnumerateArray());

        // The grid (R-FIN-02): March and May held, April missing, January before the opening not expected; the employee sees it.
        var grid = await te.GetJsonAsync($"/api/v1/account-stats?company={company}&from=2026-01&to=2026-06");
        var cells = grid.GetProperty("accounts")[0].GetProperty("cells").EnumerateArray().ToDictionary(c => c.GetProperty("month").GetString()!);
        Assert.Equal((false, false, true), (cells["2026-01-31"].GetProperty("expected").GetBoolean(), cells["2026-03-31"].GetProperty("missing").GetBoolean(),
            cells["2026-04-30"].GetProperty("missing").GetBoolean()));
        var march = cells["2026-03-31"].GetProperty("id").GetString()!;
        var may = cells["2026-05-31"].GetProperty("id").GetString()!;

        // BR-FIN-048: the employee does not confirm; the manager does, as entered; a confirmed figure is frozen.
        Assert.Equal((403, "FORBIDDEN"), await te.PostProblemAsync("/api/v1/account-stats/actions/confirm", new { ids = new[] { march } }));
        await tm.OkAsync(HttpMethod.Put, "/api/v1/account-stats", new { items = new[] { new { account, month = "2026-06", avgDailyBalance = 1_000 } } });
        var june = (await tm.GetJsonAsync($"/api/v1/account-stats?company={company}&from=2026-06&to=2026-06")).GetProperty("accounts")[0].GetProperty("cells")[0].GetProperty("id").GetString()!;
        Assert.Equal((403, "V-FIN-SOD"), await tm.PostProblemAsync("/api/v1/account-stats/actions/confirm", new { ids = new[] { june } }));
        Assert.Equal(2, (await tm.PostOkAsync("/api/v1/account-stats/actions/confirm", new { ids = new[] { march, may } })).GetProperty("confirmed").GetInt32());
        Assert.Equal((409, "FIGURE_CONFIRMED"), await te.ProblemAsync(HttpMethod.Put, "/api/v1/account-stats", new { items = new[] { new { account, month = "2026-03", avgDailyBalance = 1 } } }));

        // Reopened with a reason by a confirmer who is not the author; the reopener neither edits it nor confirms it next.
        Assert.Equal((422, "VALIDATION_FAILED"), await tm.PostProblemAsync($"/api/v1/account-stats/{march}/actions/reopen", new { }));
        await tm.PostOkAsync($"/api/v1/account-stats/{march}/actions/reopen", new { reason = "The bank corrected its statement" });
        Assert.Equal((403, "V-FIN-SOD"), await tm.ProblemAsync(HttpMethod.Put, "/api/v1/account-stats", new { items = new[] { new { account, month = "2026-03", avgDailyBalance = 5_100_000 } } }));
        await te.OkAsync(HttpMethod.Put, "/api/v1/account-stats", new { items = new[] { new { account, month = "2026-03", avgDailyBalance = 5_100_000 } } });
        Assert.Equal((403, "V-FIN-SOD"), await tm.PostProblemAsync("/api/v1/account-stats/actions/confirm", new { ids = new[] { march } }));
        await tm2.PostOkAsync("/api/v1/account-stats/actions/confirm", new { ids = new[] { march } });
        var after = (await te.GetJsonAsync($"/api/v1/account-stats?company={company}&from=2026-03&to=2026-03")).GetProperty("accounts")[0].GetProperty("cells")[0];
        Assert.Equal(("CONFIRMED", 5_100_000m, "The bank corrected its statement"),
            (after.GetProperty("status").GetString(), after.GetProperty("avgDailyBalance").GetDecimal(), after.GetProperty("reopenReason").GetString()));
    }

    [Fact]
    public async Task Bank_flows_one_level_performance_and_period_close()
    {
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
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/limits", new { code = "L0", limitType = "TOTAL_FACILITY", nameAr = "الحد الكلي", amount = 40_000_000, noSourceReason = "Clause 1" });
        await fo.PostOkAsync($"/api/v1/facilities/{fac}/obligations", new
        {
            obligationType = "MIN_INFLOW", titleAr = "تحويل التدفقات", noSourceReason = "Clause 9",
            covenant = new { measureKind = "FLOW_VOLUME", thresholdState = "SET", @operator = "GE", thresholdValue = 12_000_000, thresholdUnit = "AMOUNT", currency = "SAR", testFrequency = "ANNUAL" },
        });
        var rev = (await fo.GetJsonAsync($"/api/v1/facilities/{fac}")).GetProperty("draft").GetProperty("revision").GetString()!;
        await fo.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/submit", new { });
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/facilities/{fac}/revisions/{rev}/actions/approve", new { acknowledge = Ack });

        // BR-FIN-016: a month's flows to a bank at its level or per facility, never both.
        var flows = new List<string>();
        foreach (var m in new[] { "2026-01", "2026-02", "2026-03" })
            flows.Add(PlatformFixture.Id(await te.PostOkAsync("/api/v1/bank-flows", new { company, institution = bank, facility = fac, month = m, amount = 1_000_000, currency = "SAR" })));
        Assert.Equal((409, "FLOW_LEVEL"), await te.PostProblemAsync("/api/v1/bank-flows", new { company, institution = bank, month = "2026-01", amount = 5, currency = "SAR" }));
        Assert.Equal((409, "V-FIN-DUPLICATE"), await te.PostProblemAsync("/api/v1/bank-flows", new { company, institution = bank, facility = fac, month = "2026-01", amount = 5, currency = "SAR" }));
        var april = PlatformFixture.Id(await te.PostOkAsync("/api/v1/bank-flows", new { company, institution = bank, facility = fac, month = "2026-04", amount = 0, currency = "SAR" }));

        // Only confirmed flows count: before the confirmation there is no data.
        JsonElement Perf(JsonElement r) => r.GetProperty("items").EnumerateArray().Single();
        Assert.Equal("NO_DATA", Perf(await te.GetJsonAsync($"/api/v1/bank-flows/performance?asOf=2026-05-15&facility={fac}")).GetProperty("state").GetString());
        await tm.PostOkAsync("/api/v1/bank-flows/actions/confirm", new { ids = flows.Append(april).ToArray() });
        var p = Perf(await te.GetJsonAsync($"/api/v1/bank-flows/performance?asOf=2026-05-15&facility={fac}"));
        Assert.Equal(("BEHIND", 3_000_000m, 9_000_000m, 1_125_000m), (p.GetProperty("state").GetString(), p.GetProperty("achieved").GetDecimal(),
            p.GetProperty("remaining").GetDecimal(), p.GetProperty("requiredPerRemainingMonth").GetDecimal()));
        var year = await te.GetJsonAsync($"/api/v1/bank-flows?company={company}&year=2026");
        Assert.Equal(3_000_000m, year.GetProperty("totals")[0].GetProperty("confirmed").GetDecimal());
        Assert.Equal((409, "FIGURE_CONFIRMED"), await te.ProblemAsync(HttpMethod.Patch, $"/api/v1/bank-flows/{flows[0]}", new { amount = 2 }));

        // BR-FIN-050: closed through 2025-12-31 once its figures are confirmed; a flow of a closed month is refused, a later one accepted.
        var nov = PlatformFixture.Id(await te.PostOkAsync("/api/v1/bank-flows", new { company, institution = bank, facility = fac, month = "2025-11", amount = 700_000, currency = "SAR" }));
        Assert.Equal((409, "CLOSE_REFUSED"), await tm.PostProblemAsync($"/api/v1/reporting-periods/{company}/actions/lock", new { lockedThrough = "2025-12-31", reason = "Year end 2025" }));
        await tm.PostOkAsync("/api/v1/bank-flows/actions/confirm", new { ids = new[] { nov } });
        await tm.PostOkAsync($"/api/v1/reporting-periods/{company}/actions/lock", new { lockedThrough = "2025-12-31", reason = "Year end 2025" });
        Assert.Equal((409, "PERIOD_CLOSED"), await te.PostProblemAsync("/api/v1/bank-flows", new { company, institution = bank, month = "2025-10", amount = 1, currency = "SAR" }));
        Assert.Equal((409, "PERIOD_CLOSED"), await tm.PostProblemAsync($"/api/v1/bank-flows/{nov}/actions/reopen", new { reason = "Correction" }));
        await te.PostOkAsync("/api/v1/bank-flows", new { company, institution = bank, facility = fac, month = "2026-05", amount = 1_000_000, currency = "SAR" });
        Assert.Equal((409, "CLOSE_REFUSED"), await tm.PostProblemAsync($"/api/v1/reporting-periods/{company}/actions/reopen", new { reason = "Audit adjustment" }));
        await fo.PostOkAsync($"/api/v1/reporting-periods/{company}/actions/reopen", new { reason = "Audit adjustment" });
        var periods = (await te.GetJsonAsync($"/api/v1/reporting-periods?company={company}")).GetProperty("items")[0];
        Assert.Equal(("2025-12-31", "REOPENED"), (periods.GetProperty("lockedThrough").GetString()![..10], periods.GetProperty("status").GetString()));
    }
}
