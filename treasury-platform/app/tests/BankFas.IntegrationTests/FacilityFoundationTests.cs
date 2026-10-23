using System.Net;
using Microsoft.Data.SqlClient;

namespace BankFas.IntegrationTests;

/// <summary>
/// The foundation of S2 (S2 brief, batch S2-A): the new packs (comparable terms, formula templates, the FACILITY number,
/// the S2 expiry rules and notification events), the S2 settings, the working-day calendar with the platform's holidays
/// and the tenant's own days (FR-PLT-035, BR-OBL-004), the Hijri service (FR-PLT-033), and the guards of 062.
/// </summary>
[Collection("database")]
public sealed class FacilityFoundationTests(PlatformFixture f)
{
    private static async Task<T> InTenantAsync<T>(PlatformFixture f, int tenantId, Func<SqlConnection, Task<T>> work)
    {
        var ct = TestContext.Current.CancellationToken;
        await using var c = await f.Env.Db.OpenAsync(BankFas.Data.DbLogin.Jobs, ct);
        await BankFas.Data.JobProcedures.BindAsync(c, tenantId, "JOB-NTF-EXPIRY", Guid.NewGuid(), ct);
        return await work(c);
    }

    [Fact]
    public async Task A_new_account_has_the_S2_packs_and_settings()
    {
        var t = await f.CreateTenantAsync();
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        var counts = await InTenantAsync(f, tenantId, c => Dapper.SqlMapper.QuerySingleAsync<(int, int, int, int, int, int)>(c,
            """
            SELECT (SELECT COUNT(*) FROM cmp.TermType WHERE IsSystem = 1),
                   (SELECT COUNT(*) FROM fin.MeasureFormula AS m JOIN sec.AppUser AS u ON u.AppUserId = m.ApprovedBy AND u.IsSystemUser = 1
                     WHERE m.Scope = 'TEMPLATE' AND m.Status = 'APPROVED'),
                   (SELECT COUNT(*) FROM cfg.NumberSequenceDefinition WHERE SequenceKey = 'FACILITY' AND Pattern = 'FAC-{yy}-{seq:000}'),
                   (SELECT COUNT(*) FROM cfg.ExpiryAlertRule WHERE ItemType NOT IN ('LC_EXPIRY', 'LC_LATEST_SHIPMENT', 'RESERVATION', 'LC_DRAWING_DUE')),
                   (SELECT COUNT(*) FROM ntf.NotificationEventType WHERE (OwnerModule IN ('FAC', 'COL', 'OBL') OR Code = 'ACC.FACILITY_ACCOUNT_FROZEN') AND Code <> 'CMP.WARNING'),
                   (SELECT COUNT(*) FROM ntf.NotificationRule AS r JOIN ntf.NotificationEventType AS e ON e.NotificationEventTypeId = r.EventTypeId WHERE e.Code = 'FAC.RESERVATION_ALERT');
            """));
        Assert.Equal((35, 8, 1, 12, 10, 3), counts);
        var settings = (await t.Portal.GetJsonAsync("/api/v1/settings")).GetProperty("items").EnumerateArray()
            .ToDictionary(s => s.GetProperty("key").GetString()!, s => s.GetProperty("effective").GetRawText());
        Assert.Equal("90", settings["fac.validity.expiring_days"]);
        Assert.Equal("false", settings["wf.sod.allow_same_person"]);
    }

    [Fact]
    public async Task Working_days_skip_the_weekend_the_platform_holidays_and_the_tenants_own_days()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        async Task<string> AddAsync(string from, int days) =>
            (await tm.GetJsonAsync($"/api/v1/services/working-days?country=SA&from={from}&days={days}")).GetProperty("date").GetString()!;
        // FR-PLT-035 and BR-OBL-004: three working days after a Thursday; thirty before an event (AC-FAC-6).
        Assert.Equal("2026-10-13", await AddAsync("2026-10-08", 3));
        Assert.Equal("2026-11-08", await AddAsync("2026-12-20", -30));

        // An operator's holiday counts for every account; a tenant's own day for that account only.
        // A year far ahead, so the platform row does not move the dates of other tests; a rerun on the same database finds it there.
        var date = $"{2030 + Random.Shared.Next(0, 60)}-03-0{Random.Shared.Next(1, 9)}";
        var year = date[..4];
        Assert.Contains((await f.Panel.SendAsync(HttpMethod.Post, "/api/v1/operator/non-working-days",
            new { country = "SA", onDate = date, nameEn = "Platform holiday", kind = "HOLIDAY" })).StatusCode, new[] { HttpStatusCode.Created, HttpStatusCode.Conflict });
        Assert.Contains((await tm.GetJsonAsync($"/api/v1/non-working-days?year={year}&country=SA")).GetProperty("items").EnumerateArray(),
            d => d.GetProperty("onDate").GetString() == date && d.GetProperty("platform").GetBoolean());
        Assert.Equal((409, "V-PLT-DAY-EXISTS"), await t.Portal.PostProblemAsync("/api/v1/non-working-days", new { country = "SA", onDate = date, nameEn = "Again" }));
        var own = PlatformFixture.Id(await t.Portal.PostOkAsync("/api/v1/non-working-days", new { country = "SA", onDate = "2026-10-11", nameEn = "Company day", kind = "OTHER" }));
        Assert.Equal("2026-10-14", await AddAsync("2026-10-08", 3));
        var other = await f.CreateTenantAsync();
        var (otherTm, _, _) = await f.UserWithRoleAsync(other, "TM");
        Assert.Equal("2026-10-13", (await otherTm.GetJsonAsync("/api/v1/services/working-days?country=SA&from=2026-10-08&days=3")).GetProperty("date").GetString());
        // A reader does not enter days; the tenant removes its own, never the platform's.
        var (au, _, _) = await f.UserWithRoleAsync(t, "AU");
        Assert.Equal((403, "FORBIDDEN"), await au.PostProblemAsync("/api/v1/non-working-days", new { country = "SA", onDate = "2026-10-12", nameEn = "No" }));
        Assert.Equal(HttpStatusCode.NoContent, (await t.Portal.DeleteAsync($"/api/v1/non-working-days/{own}", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal("2026-10-13", await AddAsync("2026-10-08", 3));
    }

    [Fact]
    public async Task The_Hijri_service_converts_both_ways_and_refuses_a_date_that_does_not_exist()
    {
        var t = await f.CreateTenantAsync();
        var h = (await t.Portal.GetJsonAsync("/api/v1/services/hijri?gregorian=2026-10-22")).GetProperty("hijri").GetString()!;
        Assert.Equal("2026-10-22", (await t.Portal.GetJsonAsync($"/api/v1/services/hijri?hijri={h}")).GetProperty("gregorian").GetString());
        Assert.Equal((422, "V-PLT-HIJRI"), await t.Portal.ProblemAsync(HttpMethod.Get, "/api/v1/services/hijri?hijri=1448-02-31"));
    }

    [Fact]
    public async Task The_062_guards_keep_system_terms_approved_tariffs_and_final_utilisations()
    {
        var t = await f.CreateTenantAsync();
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        var bank = PlatformFixture.Id(await t.Portal.PostOkAsync("/api/v1/institutions", new { code = "BNK1", refCode = "BNA", nameAr = "البنك الأول", type = "BANK", country = "SA" }));
        var errors = await InTenantAsync(f, tenantId, async c =>
        {
            async Task<int> Try(string sql, object? p = null)
            {
                try { await Dapper.SqlMapper.ExecuteAsync(c, sql, p); return 0; }
                catch (SqlException e) { return e.Number; }
            }
            var unit = await Try("UPDATE cmp.TermType SET Unit = 'BPS' WHERE Code = 'PRC.MARGIN_PCT';");
            var system = await Try("INSERT cmp.TermType (TenantId, Code, NameAr, Category, ValueKind, Unit, ScopeKinds, IsSystem) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'X.MINE', N'مفتاح', 'OTHER', 'TEXT', 'TXT', 'FACILITY', 1);");
            var mine = await Try("INSERT cmp.TermType (TenantId, Code, NameAr, Category, ValueKind, Unit, ScopeKinds) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), 'X.MINE', N'مفتاح', 'OTHER', 'TEXT', 'TXT', 'FACILITY');");
            var svc = await Dapper.SqlMapper.ExecuteScalarAsync<long>(c, "SELECT AppUserId FROM sec.AppUser WHERE IsSystemUser = 1;");
            var schedule = await Dapper.SqlMapper.ExecuteScalarAsync<long>(c,
                """
                DECLARE @o TABLE (Id BIGINT);
                INSERT prc.TariffSchedule (TenantId, InstitutionId, NameAr, VersionNo, EffectiveFrom, Status) OUTPUT inserted.TariffScheduleId INTO @o
                SELECT CAST(SESSION_CONTEXT(N'TenantId') AS INT), InstitutionId, N'تعرفة', 1, '2026-01-01', 'DRAFT' FROM ins.Institution WHERE PublicId = @b;
                SELECT Id FROM @o;
                """, new { b = Guid.Parse(bank) });
            var fee = await Dapper.SqlMapper.ExecuteScalarAsync<int>(c, "SELECT TOP (1) FeeTypeId FROM cat.FeeType ORDER BY FeeTypeId;");
            var itemSql = "INSERT prc.TariffItem (TenantId, ScheduleId, FeeTypeId, ItemCode, NameAr, ChargeKind, Rate, Confidence, NoSourceReason) VALUES (CAST(SESSION_CONTEXT(N'TenantId') AS INT), @s, @f, @code, N'بند', 'PERCENT', 1.0, 'ENTERED_NO_DOCUMENT', N'Test');";
            var draftItem = await Try(itemSql, new { s = schedule, f = fee, code = "I1" });
            var approve = await Try("UPDATE prc.TariffSchedule SET Status = 'APPROVED', ApprovedBy = @u, ApprovedOn = SYSUTCDATETIME() WHERE TariffScheduleId = @s;", new { s = schedule, u = svc });
            var approvedItem = await Try(itemSql, new { s = schedule, f = fee, code = "I2" });
            var rename = await Try("UPDATE prc.TariffSchedule SET NameAr = N'أخرى' WHERE TariffScheduleId = @s;", new { s = schedule });
            var close = await Try("UPDATE prc.TariffSchedule SET EffectiveTo = '2026-12-31' WHERE TariffScheduleId = @s;", new { s = schedule });
            var reopen = await Try("UPDATE prc.TariffSchedule SET EffectiveTo = '2027-12-31' WHERE TariffScheduleId = @s;", new { s = schedule });
            return (unit, system, mine, draftItem, approve, approvedItem, rename, close, reopen);
        });
        Assert.Equal((230, 50174, 0, 0, 0, 50176, 50176, 0, 50176), errors);
    }
}
