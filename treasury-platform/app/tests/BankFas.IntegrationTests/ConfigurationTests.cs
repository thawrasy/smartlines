using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Settings within the platform bounds (AC-PLT-19), numbering definitions (AC-PLT-3 for the definitions), the audit log
/// and its export (AC-PLT-14) and the job runs (AC-PLT-20), against the database.
/// </summary>
[Collection("database")]
public sealed class ConfigurationTests(PlatformFixture f)
{
    [Fact]
    public async Task Settings_stay_within_the_platform_bounds_and_each_change_is_audited()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var settings = await p.GetJsonAsync("/api/v1/settings");
        var remask = settings.GetProperty("items").EnumerateArray().First(s => s.GetProperty("key").GetString() == "security.reveal.remask_seconds");
        Assert.Equal(15, remask.GetProperty("min").GetInt32());

        Assert.Equal((422, "V-PLT-08"), await p.ProblemAsync(HttpMethod.Patch, "/api/v1/settings", new { values = new Dictionary<string, object> { ["security.reveal.remask_seconds"] = 5 } }));
        Assert.Equal((422, "V-PLT-08"), await p.ProblemAsync(HttpMethod.Patch, "/api/v1/settings", new { values = new Dictionary<string, object> { ["no.such.key"] = 1 } }));
        Assert.Equal((422, "V-PLT-09"), await p.ProblemAsync(HttpMethod.Patch, "/api/v1/settings",
            new { values = new Dictionary<string, object> { ["work.start"] = "08:00", ["work.end"] = "10:00" } }));
        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Patch, "/api/v1/settings",
            new { values = new Dictionary<string, object> { ["work.start"] = "07:00", ["work.end"] = "18:00", ["security.reveal.remask_seconds"] = 15 } })).StatusCode);

        var after = await p.GetJsonAsync("/api/v1/settings");
        string? Effective(string key) => after.GetProperty("items").EnumerateArray().First(s => s.GetProperty("key").GetString() == key).GetProperty("effective").ToString();
        Assert.Equal("07:00", Effective("work.start"));
        Assert.Equal("15", Effective("security.reveal.remask_seconds"));

        var audit = await p.GetJsonAsync("/api/v1/audit-events?action=SETTING_CHANGED");
        var rows = audit.GetProperty("items").EnumerateArray().ToList();
        Assert.Equal(3, rows.Count);
        var work = rows.First(r => r.GetProperty("before").GetProperty("key").GetString() == "work.start");
        Assert.Equal("08:00", work.GetProperty("before").GetProperty("value").GetString());
        Assert.Equal("07:00", work.GetProperty("after").GetProperty("value").GetString());
        Assert.Contains(rows, r => r.GetProperty("severity").GetString() == "HIGH");   // the security setting

        // null goes back to the platform default
        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Patch, "/api/v1/settings",
            new { values = new Dictionary<string, object?> { ["security.reveal.remask_seconds"] = null } })).StatusCode);
        Assert.Equal("60", (await p.GetJsonAsync("/api/v1/settings")).GetProperty("items").EnumerateArray()
            .First(s => s.GetProperty("key").GetString() == "security.reveal.remask_seconds").GetProperty("effective").ToString());
    }

    [Fact]
    public async Task Numbering_definitions_follow_the_pattern_rules()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var preview = await p.PostOkAsync("/api/v1/number-sequences/preview", new { pattern = "INV-{yy}-{seq:0000}" });
        Assert.Equal("INV-26-0001", preview.GetProperty("examples")[0].GetString());
        Assert.Equal("INV-27-12345", preview.GetProperty("examples")[2].GetString());
        Assert.Equal((422, "V-PLT-10"), await p.PostProblemAsync("/api/v1/number-sequences/preview", new { pattern = "{seq}-{seq}" }));
        Assert.Equal((422, "V-PLT-10"), await p.PostProblemAsync("/api/v1/number-sequences", new { sequenceKey = "X", pattern = "{erp}-{seq}" }));
        Assert.Equal((422, "V-PLT-10"), await p.PostProblemAsync("/api/v1/number-sequences", new { sequenceKey = "PROFORMA", pattern = "P-{seq}", gapPolicy = "ALLOW_GAPS" }));

        await p.PostOkAsync("/api/v1/number-sequences", new { sequenceKey = "INV", pattern = "INV-{yy}-{seq:0000}" });
        Assert.Equal((409, "DUPLICATE"), await p.PostProblemAsync("/api/v1/number-sequences", new { sequenceKey = "INV", pattern = "INV-{seq}" }));
        var list = await p.GetJsonAsync("/api/v1/number-sequences");
        var inv = list.GetProperty("items").EnumerateArray().First(s => s.GetProperty("sequenceKey").GetString() == "INV");
        Assert.Equal("GAP_FREE", inv.GetProperty("gapPolicy").GetString());
        var etag = inv.GetProperty("etag").GetString()!;
        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Patch, "/api/v1/number-sequences/INV", new { pattern = "INV/{yyyy}/{seq:000}" }, etag)).StatusCode);
        Assert.Equal((409, "VERSION_CONFLICT"), await p.ProblemAsync(HttpMethod.Patch, "/api/v1/number-sequences/INV", new { isActive = false }, etag));
        Assert.Empty((await p.GetJsonAsync("/api/v1/number-sequences/INV/issues")).GetProperty("items").EnumerateArray());
        Assert.Equal((400, "INVALID_CURSOR"), await p.PostProblemAsync("/api/v1/number-issues/not-a-reference/actions/void", new { reason = "x" }));
    }

    [Fact]
    public async Task The_audit_log_is_read_by_category_and_exported_with_a_fresh_code()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var ct = TestContext.Current.CancellationToken;
        var all = await p.GetJsonAsync("/api/v1/audit-events?limit=200");
        var actions = all.GetProperty("items").EnumerateArray().Select(r => r.GetProperty("action").GetString()).ToHashSet();
        Assert.Contains("MFA_ENROLLED", actions);
        Assert.Contains("FIRST_ADMIN_INVITED", actions);
        Assert.Equal((403, "FORBIDDEN"), await p.ProblemAsync(HttpMethod.Get, "/api/v1/audit-events?category=TREASURY"));   // TA lacks audit.view.treasury
        Assert.Equal((400, "MALFORMED_REQUEST"), await p.ProblemAsync(HttpMethod.Get, "/api/v1/audit-events?from=yesterday"));

        Assert.Equal((401, "REAUTH_REQUIRED"), await p.PostProblemAsync("/api/v1/audit-events/exports", new { from = "2026-01-01" }));
        var export = await p.SendAsync(HttpMethod.Post, "/api/v1/audit-events/exports", new { from = "2026-01-01", stepUpCode = f.NextCode(t.AdminSecret) });
        Assert.Equal(HttpStatusCode.OK, export.StatusCode);
        Assert.Equal("text/csv", export.Content.Headers.ContentType?.MediaType);
        var csv = await export.Content.ReadAsStringAsync(ct);
        Assert.StartsWith("occurredAt,actorType", csv.TrimStart('﻿'), StringComparison.Ordinal);
        Assert.Contains("MFA_ENROLLED", csv, StringComparison.Ordinal);
        var exported = await p.GetJsonAsync("/api/v1/audit-events?action=AUDIT_EXPORTED");
        Assert.Equal("HIGH", exported.GetProperty("items")[0].GetProperty("severity").GetString());
        Assert.NotEmpty((await p.GetJsonAsync("/api/v1/audit-events?action=AUDIT_VIEWED")).GetProperty("items").EnumerateArray());
    }

    [Fact]
    public async Task The_jobs_screen_shows_the_runs_of_the_tenant()
    {
        var t = await f.CreateTenantAsync();
        var jobs = await t.Portal.GetJsonAsync("/api/v1/jobs");
        var onboard = jobs.GetProperty("items").EnumerateArray().First(j => j.GetProperty("jobKey").GetString() == "JOB-PLT-ONBOARD");
        Assert.Equal("SUCCEEDED", onboard.GetProperty("lastStatus").GetString());
        var runs = await t.Portal.GetJsonAsync("/api/v1/jobs/JOB-PLT-ONBOARD/runs");
        Assert.Contains("invitation sent", runs.GetProperty("items")[0].GetProperty("result").GetString(), StringComparison.Ordinal);
        Assert.Equal(JsonValueKind.Null, runs.GetProperty("nextCursor").ValueKind);
    }
}
