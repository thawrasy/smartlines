using Microsoft.Data.SqlClient;

namespace BankFas.IntegrationTests;

/// <summary>
/// The foundation of S2-b (S2-b brief, batch S2B-A): the statement line catalogue of 157 lines (owner default OQ-1), the
/// FLOW_KIND list, the analysis measures, the loss rates, the three S2-b events and the early warning, the two
/// settings, and the guards of 063 (an approved formula is fixed, a system line keeps its code and is the seeder's).
/// </summary>
[Collection("database")]
public sealed class FinanceFoundationTests(PlatformFixture f)
{
    private static async Task<T> InTenantAsync<T>(PlatformFixture f, int tenantId, Func<SqlConnection, Task<T>> work)
    {
        var ct = TestContext.Current.CancellationToken;
        await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-NTF-EXPIRY", Guid.NewGuid(), ct);
        return await work(c);
    }

    [Fact]
    public async Task A_new_account_has_the_S2b_packs_and_settings()
    {
        var t = await f.CreateTenantAsync();
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        var counts = await InTenantAsync(f, tenantId, c => Dapper.SqlMapper.QuerySingleAsync<(int, int, int, int, int, int, int, int)>(c,
            """
            SELECT (SELECT COUNT(*) FROM fin.LineCatalogItem WHERE IsSystem = 1 AND SeedKey LIKE 'FIN.LINES.%'),
                   (SELECT COUNT(*) FROM fin.LineCatalogItem WHERE IsTotal = 1),
                   (SELECT COUNT(*) FROM cat.LookupItem AS i JOIN cat.LookupList AS l ON l.LookupListId = i.LookupListId WHERE l.Code = 'FLOW_KIND' AND i.Code = 'TRANSFERRED_TO_BANK'),
                   (SELECT COUNT(*) FROM fin.MeasureFormula WHERE Scope = 'ANALYSIS' AND Status = 'APPROVED'),
                   (SELECT COUNT(*) FROM fin.MeasureFormula WHERE Scope = 'TEMPLATE' AND Status = 'APPROVED'),
                   (SELECT COUNT(*) FROM fin.ReceivableLossRate),
                   (SELECT COUNT(*) FROM ntf.NotificationEventType WHERE Code IN ('FIN.DATA_MISSING', 'FIN.BALANCES_MISSING', 'FIN.STATEMENT_PENDING', 'CMP.WARNING')),
                   (SELECT COUNT(*) FROM ntf.NotificationEventType WHERE Code = 'CMP.WARNING' AND IsMandatory = 0 AND DefaultChannels = '["IN_APP"]');
            """));
        Assert.Equal((157, 9, 1, 7, 8, 5, 4, 1), counts);
        var settings = (await t.Portal.GetJsonAsync("/api/v1/settings")).GetProperty("items").EnumerateArray()
            .ToDictionary(s => s.GetProperty("key").GetString()!, s => s.GetProperty("effective").GetRawText());
        Assert.Equal("30", settings["obl.submission_lag_days"]);
        Assert.Equal("10", settings["obl.early_warning_pct"]);
    }

    [Fact]
    public async Task The_063_guards_keep_approved_formulas_and_system_lines()
    {
        var t = await f.CreateTenantAsync();
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        var errors = await InTenantAsync(f, tenantId, async c =>
        {
            async Task<int> Try(string sql, object? p = null)
            {
                try { await Dapper.SqlMapper.ExecuteAsync(c, sql, p); return 0; }
                catch (SqlException e) { return e.Number; }
            }
            var edit = await Try("UPDATE fin.MeasureFormula SET Expression = 'TOTAL_CA / TOTAL_CL * 2' WHERE Code = 'CURRENT_RATIO' AND Scope = 'TEMPLATE';");
            var back = await Try("UPDATE fin.MeasureFormula SET Status = 'DRAFT' WHERE Code = 'QUICK_RATIO' AND Scope = 'TEMPLATE';");
            var supersede = await Try("UPDATE fin.MeasureFormula SET Status = 'SUPERSEDED' WHERE Code = 'QUICK_RATIO' AND Scope = 'TEMPLATE';");
            var revive = await Try("UPDATE fin.MeasureFormula SET Status = 'APPROVED' WHERE Code = 'QUICK_RATIO' AND Scope = 'TEMPLATE';");
            var code = await Try("UPDATE fin.LineCatalogItem SET Code = 'CASH2' WHERE Code = 'CASH';");
            var rename = await Try("UPDATE fin.LineCatalogItem SET NameEn = N'Cash at hand and in banks' WHERE Code = 'CASH';");
            var system = await Try("INSERT fin.LineCatalogItem (TenantId, Code, NameAr, NameEn, Section, IsSystem) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'MY_LINE', N'بند', N'Line', 'MEMO', 1);");
            var mine = await Try("INSERT fin.LineCatalogItem (TenantId, Code, NameAr, NameEn, Section) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'MY_LINE', N'بند', N'Line', 'MEMO');");
            return (edit, back, supersede, revive, code, rename, system, mine);
        });
        Assert.Equal((50176, 50176, 0, 50176, 230, 0, 50174, 0), errors);
    }
}
