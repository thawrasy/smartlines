using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Financial statements (S2-b brief batch S2B-B): BR-FIN-002 (12,000 entered in thousands is 12,000,000; an optional
/// line left empty is an explicit 0 at submission and an "of which" line stays absent), V-FIN-01 (required lines, an
/// imbalance needs a reason, an audited statement has its auditor), FR-FIN-006 (the preparer does not approve, AC-FAC-7
/// last sentence), BR-FIN-004 (approving a restated v2 supersedes v1 in the same transaction), BR-FIN-013 (a company that
/// is not a holding has no consolidated statement; units by role and method), OQ-12 (a treasury employee sees no
/// statement), FR-FIN-019 (revenue estimates), FR-FIN-001 (locked lines, the tenant's own line) and FR-FIN-003 (paste:
/// 30 rows, 2 unknown, 28 matched, nothing written before the save).
/// </summary>
[Collection("database")]
public sealed class StatementTests(PlatformFixture f)
{
    /// <summary>A balanced statement in thousands: assets 50,000 = liabilities 25,000 + equity 25,000.</summary>
    internal static readonly Dictionary<string, decimal> Balanced = new()
    {
        ["CASH"] = 12_000, ["AR"] = 8_000, ["INVENTORY"] = 5_000, ["PPE"] = 25_000,
        ["ST_LOANS"] = 6_000, ["CURRENT_PORTION_LTD"] = 2_000, ["AP"] = 4_000, ["LT_LOANS"] = 10_000, ["LEASE_LIABS"] = 3_000,
        ["SHARE_CAPITAL"] = 20_000, ["RETAINED_EARNINGS"] = 4_000, ["OTHER_EQUITY"] = 1_000, ["MINORITY_INTEREST"] = 0,
        ["REVENUE"] = 100_000, ["COGS"] = 70_000, ["GROSS_PROFIT"] = 30_000, ["OPEX"] = 15_000, ["OPERATING_PROFIT"] = 15_000, ["DEPR_AMORT"] = 3_000,
        ["EBITDA"] = 18_000, ["FINANCE_COSTS"] = 2_000, ["OTHER_INCOME"] = 500, ["ZAKAT_TAX"] = 1_000, ["NET_PROFIT"] = 12_500,
    };

    internal static async Task<JsonElement> SaveAsync(HttpClient c, string id, IReadOnlyDictionary<string, decimal> lines) =>
        await c.OkAsync(HttpMethod.Put, $"/api/v1/financial-statements/{id}/lines", new { lines = lines.Select(l => new { code = l.Key, amount = (decimal?)l.Value }) });

    internal static async Task<string> StatementAsync(HttpClient c, string company, object? extra = null)
    {
        var body = new Dictionary<string, object?>
        {
            ["company"] = company, ["periodType"] = "ANNUAL", ["periodEnd"] = "2025-12-31", ["assurance"] = "MANAGEMENT", ["currency"] = "SAR", ["unitScale"] = 1000,
        };
        if (extra is not null)
            foreach (var p in JsonSerializer.SerializeToElement(extra).EnumerateObject()) body[p.Name] = p.Value;
        return PlatformFixture.Id(await c.PostOkAsync("/api/v1/financial-statements", body));
    }

    private static JsonElement Line(JsonElement statement, string code) =>
        statement.GetProperty("lines").EnumerateArray().Single(l => l.GetProperty("code").GetString() == code);

    private static decimal? Amount(JsonElement line) => line.GetProperty("amount").ValueKind == JsonValueKind.Null ? null : line.GetProperty("amount").GetDecimal();

    private async Task<HttpClient> MakerCheckerAsync(TestTenant t)
    {
        await t.Portal.PostOkAsync("/api/v1/roles", new { code = "finboth", nameEn = "Prepares and approves", nameAr = "يعد ويعتمد", permissions = new[] { "fin.view", "fin.stmt.enter", "fin.stmt.approve" } });
        return (await f.UserWithRoleAsync(t, "FINBOTH")).Client;
    }

    [Fact]
    public async Task Statement_entry_checks_approval_and_versions()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var (te, _, _) = await f.UserWithRoleAsync(t, "TE");
        var both = await MakerCheckerAsync(t);
        var company = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "C1", nameAr = "شركة الأولى", nameEn = "First", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));

        var id = await StatementAsync(fo, company, new { assurance = "AUDITED" });
        Assert.Equal((409, "V-FIN-DUPLICATE"), await fo.PostProblemAsync("/api/v1/financial-statements", new
        {
            company, periodType = "ANNUAL", periodEnd = "2025-12-31", assurance = "AUDITED", currency = "SAR", unitScale = 1000,
        }));
        Assert.Equal((422, "V-FIN-CONSOLIDATION"), await fo.PostProblemAsync("/api/v1/financial-statements", new
        {
            company, periodType = "ANNUAL", periodEnd = "2025-12-31", basis = "CONSOLIDATED", assurance = "AUDITED", currency = "SAR",
        }));

        // BR-FIN-002: 12,000 entered in thousands is stored as 12,000,000; the totals show live.
        var saved = await SaveAsync(fo, id, new Dictionary<string, decimal> { ["CASH"] = 12_000 });
        Assert.False(saved.GetProperty("check").GetProperty("canSubmit").GetBoolean());
        var (s, etag) = await fo.GetWithETagAsync($"/api/v1/financial-statements/{id}");
        Assert.Equal((12_000_000m, 12_000m), (Amount(Line(s, "CASH"))!.Value, Line(s, "CASH").GetProperty("entered").GetDecimal()));
        Assert.Equal(12_000m, Line(s, "TOTAL_CA").GetProperty("computed").GetDecimal());

        // V-FIN-01: an audited statement has its auditor; required lines are filled; an imbalance needs a reason.
        Assert.Equal((422, "V-FIN-AUDIT"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/actions/submit", new { }));
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Patch, $"/api/v1/financial-statements/{id}",
            new { auditorName = "مراجع حسابات", auditOpinion = "UNQUALIFIED" }, etag)).StatusCode);
        Assert.Equal((422, "V-FIN-01"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/actions/submit", new { }));
        var unbalanced = new Dictionary<string, decimal>(Balanced) { ["RETAINED_EARNINGS"] = 3_000 };
        var check = (await SaveAsync(fo, id, unbalanced)).GetProperty("check");
        Assert.Equal((true, false, 1_000m), (check.GetProperty("canSubmit").GetBoolean(), check.GetProperty("balanced").GetBoolean(), check.GetProperty("balanceDifference").GetDecimal()));
        Assert.Equal((422, "V-FIN-01-BALANCE"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/actions/submit", new { }));
        await fo.PostOkAsync($"/api/v1/financial-statements/{id}/actions/submit", new { balanceReason = "Rounding of the audited figures" });

        // At submission an optional line left empty is an explicit 0, an "of which" line stays absent, a total has its computed amount.
        s = await tm.GetJsonAsync($"/api/v1/financial-statements/{id}");
        Assert.Equal(0m, Amount(Line(s, "OTHER_CA")));
        var ofWhich = s.GetProperty("lines").EnumerateArray().First(l => l.GetProperty("kind").GetString() == "OF_WHICH");
        Assert.Null(Amount(ofWhich));
        Assert.Equal(50_000m, Line(s, "TOTAL_ASSETS").GetProperty("computed").GetDecimal());
        Assert.Equal(("SUBMITTED", "Rounding of the audited figures"),
            (s.GetProperty("statement").GetProperty("status").GetString(), s.GetProperty("statement").GetProperty("balanceReason").GetString()));
        Assert.Equal((409, "STATEMENT_FINAL"), await fo.ProblemAsync(HttpMethod.Put, $"/api/v1/financial-statements/{id}/lines", new { lines = new[] { new { code = "CASH", amount = 1 } } }));

        // OQ-12: a treasury employee sees no statement; the preparer has no fin.stmt.approve.
        Assert.Equal(403, (await te.ProblemAsync(HttpMethod.Get, "/api/v1/financial-statements")).Status);
        Assert.Equal((403, "FORBIDDEN"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/actions/approve", new { }));
        var approved = await tm.PostOkAsync($"/api/v1/financial-statements/{id}/actions/approve", new { });
        Assert.Equal(("APPROVED", "PENDING"), (approved.GetProperty("status").GetString(), approved.GetProperty("reevaluation").GetString()));

        // FR-FIN-005: an approved statement changes by a new version, a draft copy that supersedes it once approved.
        var (_, approvedTag) = await fo.GetWithETagAsync($"/api/v1/financial-statements/{id}");
        Assert.Equal((409, "STATEMENT_FINAL"), await fo.ProblemAsync(HttpMethod.Patch, $"/api/v1/financial-statements/{id}", new { accountingStandard = "IFRS" }, approvedTag));
        var v2 = PlatformFixture.Id(await fo.PostOkAsync($"/api/v1/financial-statements/{id}/actions/new-version", new { reason = "RESTATED" }));
        Assert.Equal((409, "V-FIN-VERSION-OPEN"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/actions/new-version", new { reason = "CORRECTION" }));
        var copy = await fo.GetJsonAsync($"/api/v1/financial-statements/{v2}");
        Assert.Equal((2, "RESTATED", "DRAFT", 12_000_000m), (copy.GetProperty("statement").GetProperty("versionNo").GetInt32(),
            copy.GetProperty("statement").GetProperty("versionReason").GetString(), copy.GetProperty("statement").GetProperty("status").GetString(), Amount(Line(copy, "CASH"))!.Value));
        Assert.True((await SaveAsync(fo, v2, new Dictionary<string, decimal> { ["RETAINED_EARNINGS"] = 4_000 })).GetProperty("check").GetProperty("balanced").GetBoolean());
        await fo.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/submit", new { });
        Assert.Equal(1, (await tm.PostOkAsync($"/api/v1/financial-statements/{v2}/actions/approve", new { })).GetProperty("superseded").GetInt32());
        var versions = (await tm.GetJsonAsync($"/api/v1/financial-statements/{v2}")).GetProperty("versions").EnumerateArray()
            .Select(v => (v.GetProperty("versionNo").GetInt32(), v.GetProperty("status").GetString())).ToList();
        Assert.Equal([(1, "SUPERSEDED"), (2, "APPROVED")], versions);

        // FR-FIN-006: who prepared a statement does not approve it, even holding both permissions; a return goes back to a draft.
        var own = await StatementAsync(both, company, new { periodEnd = "2024-12-31" });
        await SaveAsync(both, own, Balanced);
        await both.PostOkAsync($"/api/v1/financial-statements/{own}/actions/submit", new { });
        Assert.Equal((403, "V-FIN-SOD"), await both.PostProblemAsync($"/api/v1/financial-statements/{own}/actions/approve", new { }));
        Assert.Equal((422, "VALIDATION_FAILED"), await tm.PostProblemAsync($"/api/v1/financial-statements/{own}/actions/reject", new { }));
        await tm.PostOkAsync($"/api/v1/financial-statements/{own}/actions/reject", new { reason = "Inventory to be checked" });
        Assert.Equal((409, "STATEMENT_FINAL"), await both.ProblemAsync(HttpMethod.Put, $"/api/v1/financial-statements/{own}/lines", new { lines = new[] { new { code = "CASH", amount = 1 } } }));
        await both.PostOkAsync($"/api/v1/financial-statements/{own}/actions/reopen", new { });
        await SaveAsync(both, own, new Dictionary<string, decimal> { ["INVENTORY"] = 5_000 });

        var list = await tm.GetJsonAsync($"/api/v1/financial-statements?company={company}");
        Assert.Equal(3, list.GetProperty("items").GetArrayLength());
    }

    [Fact]
    public async Task Consolidation_revenue_estimates_catalogue_and_paste()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var (fo, _, _) = await f.UserWithRoleAsync(t, "FO");
        var holding = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "H1", nameAr = "القابضة", nameEn = "Holding", legalForm = "LLC", isHolding = true, country = "SA", fiscalYearEndMonth = 12 }));
        var sub = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/companies", new { companyCode = "S1", nameAr = "التابعة", nameEn = "Subsidiary", legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12 }));

        // BR-FIN-013: the units of a holding's consolidated statement, by role and method.
        var id = await StatementAsync(fo, holding, new { basis = "CONSOLIDATED" });
        await SaveAsync(fo, id, Balanced);
        Assert.Equal((422, "V-FIN-CONSOLIDATION"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/units", new { company = sub, role = "PARENT" }));
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/financial-statements/{id}/units", new { company = holding, role = "PARENT" })).StatusCode);
        Assert.Equal((422, "V-FIN-CONSOLIDATION"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/actions/submit", new { }));
        Assert.Equal((422, "V-FIN-UNIT"), await fo.PostProblemAsync($"/api/v1/financial-statements/{id}/units", new { company = sub, role = "SUBSIDIARY", method = "EQUITY", ownershipPct = 80 }));
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, $"/api/v1/financial-statements/{id}/units",
            new { company = sub, role = "SUBSIDIARY", method = "FULL", ownershipPct = 80 })).StatusCode);
        var units = (await fo.GetJsonAsync($"/api/v1/financial-statements/{id}/units")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal(["PARENT", "SUBSIDIARY"], units.Select(u => u.GetProperty("role").GetString()));
        await fo.PostOkAsync($"/api/v1/financial-statements/{id}/actions/submit", new { });
        Assert.Equal((409, "STATEMENT_FINAL"), await fo.ProblemAsync(HttpMethod.Delete, $"/api/v1/financial-statements/{id}/units/{sub}"));
        await tm.PostOkAsync($"/api/v1/financial-statements/{id}/actions/approve", new { });

        // FR-FIN-019: one approved estimate per company, year and basis, approved by another user.
        var e1 = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/revenue-estimates", new { company = sub, fiscalYear = 2026, amount = 100_000_000, currency = "SAR", basisNote = "Approved budget 2026" }));
        Assert.Equal((403, "FORBIDDEN"), await fo.PostProblemAsync($"/api/v1/revenue-estimates/{e1}/actions/approve", new { }));
        await tm.PostOkAsync($"/api/v1/revenue-estimates/{e1}/actions/approve", new { });
        Assert.Equal((409, "APPROVED_FINAL"), await fo.ProblemAsync(HttpMethod.Patch, $"/api/v1/revenue-estimates/{e1}", new { amount = 1 }));
        var e2 = PlatformFixture.Id(await fo.PostOkAsync("/api/v1/revenue-estimates", new { company = sub, fiscalYear = 2026, amount = 110_000_000, currency = "SAR", basisNote = "Revised forecast" }));
        Assert.True((await tm.PostOkAsync($"/api/v1/revenue-estimates/{e2}/actions/approve", new { })).GetProperty("superseded").GetBoolean());
        var estimates = (await tm.GetJsonAsync($"/api/v1/revenue-estimates?company={sub}")).GetProperty("items").EnumerateArray()
            .ToDictionary(e => e.GetProperty("id").GetString()!, e => e.GetProperty("status").GetString());
        Assert.Equal(("SUPERSEDED", "APPROVED"), (estimates[e1], estimates[e2]));

        // FR-FIN-001: the 157 standard lines; a locked line stays active; the tenant adds its own line and an alias.
        var catalogue = (await fo.GetJsonAsync("/api/v1/line-catalogue")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal(157, catalogue.Count);
        Assert.Equal(51, catalogue.Count(l => l.GetProperty("isMain").GetBoolean()));
        Assert.Equal((422, "V-FIN-LOCKED"), await fo.ProblemAsync(HttpMethod.Patch, "/api/v1/line-catalogue/CASH", new { isActive = false }));
        await fo.PostOkAsync("/api/v1/line-catalogue", new { code = "SUKUK_ISSUED", nameAr = "صكوك مصدرة", nameEn = "Sukuk issued", section = "BS_LIABILITY" });
        Assert.Equal(HttpStatusCode.NoContent, (await fo.SendAsync(HttpMethod.Post, "/api/v1/line-catalogue/CASH/aliases", new { alias = "Cash at bank and in hand" })).StatusCode);
        Assert.Equal((409, "V-FIN-ALIAS"), await fo.PostProblemAsync("/api/v1/line-catalogue/AR/aliases", new { alias = "Cash at bank and in hand" }));

        // FR-FIN-003: 30 pasted rows, 2 unknown: 28 matched by code, name or alias, and nothing written before the save.
        var draft = await StatementAsync(fo, sub);
        var rows = catalogue.Where(l => !l.GetProperty("isTotal").GetBoolean() && l.GetProperty("code").GetString() != "CASH").Take(26)
            .Select(l => new { label = l.GetProperty("nameEn").GetString()!, amount = 10m }).ToList();
        rows.Add(new { label = "  cash at bank AND in hand ", amount = 12m });
        rows.Add(new { label = "SUKUK_ISSUED", amount = 5m });
        rows.Add(new { label = "Goodwill on a planet", amount = 1m });
        rows.Add(new { label = "Unknown row", amount = 2m });
        var preview = await fo.PostOkAsync($"/api/v1/financial-statements/{draft}/paste-preview", new { rows });
        Assert.Equal((28, 2), (preview.GetProperty("matched").GetArrayLength(), preview.GetProperty("unmatched").GetArrayLength()));
        Assert.Contains(preview.GetProperty("matched").EnumerateArray(), m => m.GetProperty("code").GetString() == "CASH");
        Assert.All((await fo.GetJsonAsync($"/api/v1/financial-statements/{draft}")).GetProperty("lines").EnumerateArray(), l => Assert.Null(Amount(l)));
        await fo.OkAsync(HttpMethod.Put, $"/api/v1/financial-statements/{draft}/lines", new
        {
            entryMethod = "PASTE",
            lines = preview.GetProperty("matched").EnumerateArray().Select(m => new { code = m.GetProperty("code").GetString(), amount = m.GetProperty("amount").GetDecimal() }),
        });
        var pasted = await fo.GetJsonAsync($"/api/v1/financial-statements/{draft}");
        Assert.Equal(("PASTE", 28), (pasted.GetProperty("statement").GetProperty("entryMethod").GetString(),
            pasted.GetProperty("lines").EnumerateArray().Count(l => Amount(l) is not null && !l.GetProperty("isTotal").GetBoolean())));
    }
}
