using System.Net;
using System.Text.Json;
using System.Text.Json.Nodes;
using BankFas.Data;
using BankFas.Data.Jobs;
using BankFas.Data.Seeding;
using Microsoft.Extensions.DependencyInjection;

namespace BankFas.IntegrationTests;

/// <summary>
/// The rest of S5: the account's default notification preferences, which a user without their own choice follows and
/// which keep a mandatory group in the application (FR-NTF-011); the template preview and the test e-mail to the
/// administrator (FR-NTF-025); the catalogue export as CSV and its import, previewed row by row before it saves, the
/// code being the key that never changes (FR-CAT-024).
/// </summary>
[Collection("database")]
public sealed class S5RestTests(PlatformFixture f)
{
    [Fact]
    public async Task The_account_sets_default_preferences_and_previews_and_tests_a_template()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var defaults = (await p.GetJsonAsync("/api/v1/notification-preferences/defaults")).GetProperty("items").EnumerateArray().ToList();
        var open = defaults.First(g => !g.GetProperty("mandatoryInApp").GetBoolean() && g.GetProperty("emailAvailable").GetBoolean()).GetProperty("groupKey").GetString()!;
        var mandatory = defaults.First(g => g.GetProperty("mandatoryInApp").GetBoolean()).GetProperty("groupKey").GetString()!;

        Assert.Equal((422, "V-NTF-MANDATORY"), await p.ProblemAsync(HttpMethod.Put, "/api/v1/notification-preferences/defaults",
            new { items = new[] { new { groupKey = mandatory, channel = "IN_APP", mode = "OFF" } } }));
        Assert.Equal(403, (await tm.ProblemAsync(HttpMethod.Put, "/api/v1/notification-preferences/defaults",
            new { items = new[] { new { groupKey = open, channel = "EMAIL", mode = "DIGEST_DAILY" } } })).Status);
        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Put, "/api/v1/notification-preferences/defaults",
            new { items = new[] { new { groupKey = open, channel = "EMAIL", mode = "DIGEST_DAILY" } } })).StatusCode);
        string Email(JsonElement body, string g) => body.GetProperty("items").EnumerateArray().Single(x => x.GetProperty("groupKey").GetString() == g).GetProperty("email").GetString()!;
        Assert.Equal("DIGEST_DAILY", Email(await p.GetJsonAsync("/api/v1/notification-preferences/defaults"), open));
        Assert.Equal("DIGEST_DAILY", Email(await tm.GetJsonAsync("/api/v1/notification-preferences"), open));
        await tm.OkAsync(HttpMethod.Put, "/api/v1/notification-preferences", new { items = new[] { new { groupKey = open, channel = "EMAIL", mode = "IMMEDIATE" } } });
        Assert.Equal("IMMEDIATE", Email(await tm.GetJsonAsync("/api/v1/notification-preferences"), open));
        // The generic settings screen does not take the defaults.
        Assert.Equal((422, "V-PLT-08"), await p.ProblemAsync(HttpMethod.Patch, "/api/v1/settings", new { values = new Dictionary<string, object> { ["ntf.prefs.defaults"] = new { } } }));

        var preview = await p.PostOkAsync("/api/v1/notification-events/SEC.LOCKOUT/templates/EMAIL/en/preview",
            new { subject = "Locked: {userName}", body = "Since {occurredAt}." });
        Assert.Equal(("Locked: [userName]", "Since [occurredAt]."), (preview.GetProperty("subject").GetString(), preview.GetProperty("body").GetString()));
        Assert.Equal((422, "V-NTF-01"), await p.PostProblemAsync("/api/v1/notification-events/SEC.LOCKOUT/templates/EMAIL/en/preview", new { subject = "{accountNumber}" }));
        var seeded = await p.PostOkAsync("/api/v1/notification-events/SEC.LOCKOUT/templates/IN_APP/ar/preview", new { });
        Assert.False(string.IsNullOrEmpty(seeded.GetProperty("subject").GetString()));
        var before = f.Env.MailsTo(t.AdminEmail);
        var sent = await p.SendAsync(HttpMethod.Post, "/api/v1/notification-events/SEC.LOCKOUT/templates/EMAIL/en/test", new { });
        Assert.Equal(HttpStatusCode.Accepted, sent.StatusCode);
        Assert.Equal(before + 1, f.Env.MailsTo(t.AdminEmail));
    }

    [Fact]
    public async Task A_catalogue_is_exported_and_imported_with_a_preview()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var res = await p.GetAsync("/api/v1/catalogs/account-types/export", ct);
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var csv = (await res.Content.ReadAsStringAsync(ct)).TrimStart('﻿');
        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("code,nameAr,nameEn,description,sortOrder,isActive,externalCode,isVirtual", lines[0]);
        Assert.True(lines.Length > 2);

        // The unchanged export imports as unchanged; a new row and a renamed one show in the preview, nothing saved.
        var same = await p.PostOkAsync("/api/v1/catalogs/account-types/import", new { csv, apply = false });
        Assert.Equal(0, same.GetProperty("errors").GetInt32());
        Assert.All(same.GetProperty("rows").EnumerateArray(), r => Assert.Equal("UNCHANGED", r.GetProperty("action").GetString()));
        var firstCode = lines[1].Split(',')[0].Trim('"');
        var edited = "code,nameAr,nameEn,isVirtual\r\n" +
                     $"\"{firstCode}\",\"اسم معدّل\",\"Renamed, by import\",false\r\n" +
                     "ESCROW_IMPORT,\"حساب ضمان\",Escrow,false\r\n";
        var preview = await p.PostOkAsync("/api/v1/catalogs/account-types/import", new { csv = edited, apply = false });
        Assert.True(preview.GetProperty("errors").GetInt32() == 0, preview.ToString());
        Assert.Equal((0, 1, 1), (preview.GetProperty("errors").GetInt32(), preview.GetProperty("creates").GetInt32(), preview.GetProperty("updates").GetInt32()));
        Assert.False(preview.GetProperty("applied").GetBoolean());
        var items = (await p.GetJsonAsync("/api/v1/catalogs/account-types?includeInactive=true")).GetProperty("items").EnumerateArray().ToList();
        Assert.DoesNotContain(items, i => i.GetProperty("code").GetString() == "ESCROW_IMPORT");

        // An error in any row keeps the whole file from saving.
        var bad = edited + "bad code,x,y,maybe\r\n";
        var refused = await p.PostOkAsync("/api/v1/catalogs/account-types/import", new { csv = bad, apply = true });
        Assert.False(refused.GetProperty("applied").GetBoolean());
        Assert.Equal("ERROR", refused.GetProperty("rows").EnumerateArray().Last().GetProperty("action").GetString());
        Assert.Equal((422, "UNKNOWN_FIELD"), await p.PostProblemAsync("/api/v1/catalogs/account-types/import", new { csv = "code,colour\r\nX1,red\r\n", apply = false }));

        var saved = await p.PostOkAsync("/api/v1/catalogs/account-types/import", new { csv = edited, apply = true });
        Assert.True(saved.GetProperty("applied").GetBoolean());
        items = (await p.GetJsonAsync("/api/v1/catalogs/account-types?includeInactive=true")).GetProperty("items").EnumerateArray().ToList();
        Assert.Equal("Renamed, by import", items.Single(i => i.GetProperty("code").GetString() == firstCode).GetProperty("nameEn").GetString());
        Assert.Equal("Escrow", items.Single(i => i.GetProperty("code").GetString() == "ESCROW_IMPORT").GetProperty("nameEn").GetString());
    }

    [Fact]
    public async Task A_lookup_list_is_exported_and_imported_and_a_closed_list_takes_no_new_item()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var res = await p.GetAsync("/api/v1/lookups/CONTACT_ROLE/export", ct);
        Assert.Equal(HttpStatusCode.OK, res.StatusCode);
        var lines = (await res.Content.ReadAsStringAsync(ct)).TrimStart('\uFEFF').Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("code,nameAr,nameEn,description,sortOrder,isActive,externalCode,status,attributes", lines[0]);

        var added = await p.PostOkAsync("/api/v1/lookups/CONTACT_ROLE/import", new { csv = "code,nameAr,nameEn\r\nLEGAL_ADVISOR,مستشار قانوني,Legal advisor\r\n", apply = true });
        Assert.True(added.GetProperty("applied").GetBoolean(), added.ToString());
        Assert.Contains((await p.GetJsonAsync("/api/v1/lookups/CONTACT_ROLE")).GetProperty("items").EnumerateArray(), i => i.GetProperty("code").GetString() == "LEGAL_ADVISOR");
        // The item belongs to its own list only.
        Assert.DoesNotContain((await p.GetJsonAsync("/api/v1/lookups/UNIT_TYPE")).GetProperty("items").EnumerateArray(), i => i.GetProperty("code").GetString() == "LEGAL_ADVISOR");

        // A closed list: a new code is refused, a known one may be renamed.
        var closed = await p.PostOkAsync("/api/v1/lookups/UNIT_TYPE/import", new { csv = "code,nameAr\r\nMY_UNIT,وحدتي\r\n", apply = true });
        Assert.False(closed.GetProperty("applied").GetBoolean());
        Assert.Equal("LIST_CLOSED", closed.GetProperty("rows").EnumerateArray().Single().GetProperty("error").GetString());
        var unit = (await p.GetJsonAsync("/api/v1/lookups/UNIT_TYPE")).GetProperty("items").EnumerateArray().First();
        var renamed = await p.PostOkAsync("/api/v1/lookups/UNIT_TYPE/import",
            new { csv = $"code,nameAr,nameEn\r\n{unit.GetProperty("code").GetString()},اسم جديد,New name\r\n", apply = true });
        Assert.True(renamed.GetProperty("applied").GetBoolean(), renamed.ToString());
        Assert.Equal(1, renamed.GetProperty("updates").GetInt32());
    }

    [Fact]
    public async Task A_new_release_adds_what_the_platform_needs_and_offers_the_optional_defaults()
    {
        var ct = TestContext.Current.CancellationToken;
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        // The release: a newer version of CAT.DOCTYPES with a type the platform needs and an optional one.
        var packs = TenantSeeder.PacksDirectory(null);
        var latest = Directory.GetDirectories(Path.Combine(packs, "CAT.DOCTYPES"), "v*").Max(d => int.Parse(Path.GetFileName(d)[1..], System.Globalization.CultureInfo.InvariantCulture));
        var next = Path.Combine(packs, "CAT.DOCTYPES", $"v{latest + 1}");
        Directory.CreateDirectory(next);
        try
        {
            var src = Path.Combine(packs, "CAT.DOCTYPES", $"v{latest}");
            var manifest = JsonNode.Parse(await File.ReadAllTextAsync(Path.Combine(src, "manifest.json"), ct))!;
            manifest["SeedVersion"] = latest + 1;
            await File.WriteAllTextAsync(Path.Combine(next, "manifest.json"), manifest.ToJsonString(), ct);
            var csv = await File.ReadAllTextAsync(Path.Combine(src, "cat.DocumentType.csv"), ct);
            csv = csv.TrimEnd('\r', '\n') + "\r\n" +
                  "RELEASE_SYSTEM_DOC,مستند النظام,System document,,1,1,0,90,CAT.DOCTYPES.RELEASE_SYSTEM_DOC,REQUEST,0,0,,\r\n" +
                  "RELEASE_OPTIONAL_DOC,مستند اختياري,Optional document,,1,0,0,91,CAT.DOCTYPES.RELEASE_OPTIONAL_DOC,COMPANY,0,0,,\r\n";
            await File.WriteAllTextAsync(Path.Combine(next, "cat.DocumentType.csv"), csv, ct);

            // A name the tenant changed stays as it is.
            var cr = (await p.GetJsonAsync("/api/v1/catalogs/document-types?includeInactive=true")).GetProperty("items").EnumerateArray()
                .Single(i => i.GetProperty("code").GetString() == "COMMERCIAL_REGISTRATION");
            await p.OkAsync(HttpMethod.Patch, $"/api/v1/catalogs/document-types/items/{cr.GetProperty("id").GetString()}", new { nameEn = "Our CR" }, cr.GetProperty("etag").GetString());

            var upgrade = new SeedUpgradeJob(f.Env.Services.GetRequiredService<SqlConnectionFactory>(), new SeedPacks(packs));
            Assert.True(await upgrade.RunTenantAsync(new JobTenant(await TestEnvironment.TenantIdAsync(t.Code), "ACTIVE", "Asia/Dubai"), ct));
            List<string?> Codes(JsonElement list) => [.. list.GetProperty("items").EnumerateArray().Select(i => i.GetProperty("code").GetString())];
            var types = Codes(await p.GetJsonAsync("/api/v1/catalogs/document-types?includeInactive=true"));
            Assert.Contains("RELEASE_SYSTEM_DOC", types);
            Assert.DoesNotContain("RELEASE_OPTIONAL_DOC", types);

            var offered = (await p.GetJsonAsync("/api/v1/catalogs/defaults")).GetProperty("items").EnumerateArray().ToList();
            var item = offered.Single(i => i.GetProperty("code").GetString() == "RELEASE_OPTIONAL_DOC");
            Assert.Equal("document-types", item.GetProperty("kind").GetString());
            Assert.Equal((422, "VALIDATION_FAILED"), await p.PostProblemAsync("/api/v1/catalogs/defaults/apply", new { keys = new[] { "CAT.DOCTYPES.NOT_THERE" } }));
            var (tm, _, _) = await f.UserWithRoleAsync(t, "RQ");
            Assert.Empty((await tm.GetJsonAsync("/api/v1/catalogs/defaults")).GetProperty("items").EnumerateArray());

            var applied = await p.PostOkAsync("/api/v1/catalogs/defaults/apply", new { keys = new[] { item.GetProperty("key").GetString() } });
            Assert.Equal(1, applied.GetProperty("added").GetInt32());
            var after = (await p.GetJsonAsync("/api/v1/catalogs/document-types?includeInactive=true")).GetProperty("items").EnumerateArray().ToList();
            Assert.Contains(after, i => i.GetProperty("code").GetString() == "RELEASE_OPTIONAL_DOC");
            Assert.Equal("Our CR", after.Single(i => i.GetProperty("code").GetString() == "COMMERCIAL_REGISTRATION").GetProperty("nameEn").GetString());
            Assert.DoesNotContain((await p.GetJsonAsync("/api/v1/catalogs/defaults")).GetProperty("items").EnumerateArray(),
                i => i.GetProperty("code").GetString() == "RELEASE_OPTIONAL_DOC");
        }
        finally
        {
            Directory.Delete(next, true);
        }
    }
}
