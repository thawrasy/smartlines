using System.Net;
using System.Text.Json;
using BankFas.Data;
using BankFas.Data.Jobs;
using BankFas.Data.Seeding;
using Microsoft.Extensions.DependencyInjection;

namespace BankFas.IntegrationTests;

/// <summary>
/// The tenant catalogues seeded at onboarding and edited by the administrator (AC-CAT-1, AC-CAT-4 to 7; FR-CAT-001 to
/// 023), against the database.
/// </summary>
[Collection("database")]
public sealed class CatalogTests(PlatformFixture f)
{
    private static async Task<List<JsonElement>> ItemsAsync(HttpClient p, string kind) =>
        [.. (await p.GetJsonAsync($"/api/v1/catalogs/{kind}?includeInactive=true")).GetProperty("items").EnumerateArray()];

    private static JsonElement Item(IEnumerable<JsonElement> items, string code) => items.First(i => i.GetProperty("code").GetString() == code);

    [Fact]
    public async Task Onboarding_seeds_the_default_catalogues_once()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        foreach (var (kind, count) in new[]
        {
            ("products", 35), ("fee-types", 19), ("collateral-types", 9), ("obligation-types", 30), ("document-types", 46), ("legal-entity-types", 7),
            ("positions", 12), ("power-types", 10), ("operation-types", 11), ("institution-types", 5), ("account-types", 8), ("financing-types", 6),
            ("facility-types", 6), ("limit-types", 9), ("product-categories", 10),
        })
            Assert.True((await ItemsAsync(p, kind)).Count == count, $"{kind}: expected {count}");

        Assert.True(Item(await ItemsAsync(p, "positions"), "CHAIRMAN").GetProperty("fields").GetProperty("isSingleHolder").GetBoolean());
        var sign = Item(await ItemsAsync(p, "power-types"), "SIGN_CONTRACTS").GetProperty("fields");
        Assert.Equal("CONTRACTS", sign.GetProperty("category").GetString());
        Assert.True(sign.GetProperty("allowsCeiling").GetBoolean());
        Assert.True(Item(await ItemsAsync(p, "account-types"), "VIRTUAL").GetProperty("isLocked").GetBoolean());

        var countries = (await p.GetJsonAsync("/api/v1/countries")).GetProperty("items").EnumerateArray().ToList();
        var sa = countries.First(c => c.GetProperty("iso2").GetString() == "SA");
        Assert.True(sa.GetProperty("isGcc").GetBoolean());
        Assert.Equal("FRI,SAT", sa.GetProperty("weekendDays").GetString());
        Assert.Equal("+966", sa.GetProperty("dialCode").GetString());
        Assert.True(countries.First(c => c.GetProperty("iso2").GetString() == "AE").GetProperty("isGcc").GetBoolean());
        Assert.False(countries.First(c => c.GetProperty("iso2").GetString() == "EG").GetProperty("isGcc").GetBoolean());
        Assert.Equal(["AED", "EUR", "GBP", "SAR", "USD"], (await p.GetJsonAsync("/api/v1/tenant-currencies")).GetProperty("codes").EnumerateArray().Select(c => c.GetString()));

        // The upgrade run finds every pack already run: nothing is added.
        var upgrade = new SeedUpgradeJob(f.Env.Services.GetRequiredService<SqlConnectionFactory>(), new SeedPacks(TenantSeeder.PacksDirectory(null)));
        var tenantId = await TestEnvironment.TenantIdAsync(t.Code);
        Assert.False(await upgrade.RunTenantAsync(new JobTenant(tenantId, "ACTIVE", "Asia/Dubai"), TestContext.Current.CancellationToken));
        Assert.Equal(35, (await ItemsAsync(p, "products")).Count);
    }

    [Fact]
    public async Task System_and_locked_items_keep_their_code_and_flags_and_tenants_see_only_their_own()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var products = await ItemsAsync(p, "products");
        var lc = Item(products, "LC_PURCHASE_CONV");
        var lcPath = $"/api/v1/catalogs/products/items/{lc.GetProperty("id").GetString()}";
        Assert.Equal((422, "CODE_FIXED"), await p.ProblemAsync(HttpMethod.Patch, lcPath, new { code = "LC_OTHER" }, lc.GetProperty("etag").GetString()));
        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Patch, lcPath, new { nameEn = "Import letter of credit" }, lc.GetProperty("etag").GetString())).StatusCode);
        Assert.Equal((409, "VERSION_CONFLICT"), await p.ProblemAsync(HttpMethod.Patch, lcPath, new { nameEn = "Again" }, lc.GetProperty("etag").GetString()));

        var virt = Item(await ItemsAsync(p, "account-types"), "VIRTUAL");
        Assert.Equal((409, "ITEM_LOCKED"), await p.ProblemAsync(HttpMethod.Patch, $"/api/v1/catalogs/account-types/items/{virt.GetProperty("id").GetString()}",
            new { isActive = false }, virt.GetProperty("etag").GetString()));

        // The tenant's own product: a code of its own, a category by code; a third variant of one compliance is refused.
        var group = lc.GetProperty("fields").GetProperty("variantGroupCode").GetString();
        Assert.Equal((422, "VARIANT_TAKEN"), await p.PostProblemAsync("/api/v1/catalogs/products/items", new
        {
            code = "LC_PURCHASE_COPY", nameAr = "اعتماد", nameEn = "Copy",
            fields = new Dictionary<string, object?> { ["category"] = "TRADE_FINANCE", ["variantGroupCode"] = group, ["compliance"] = lc.GetProperty("fields").GetProperty("compliance").GetString() },
        }));
        Assert.Equal((409, "CODE_TAKEN"), await p.PostProblemAsync("/api/v1/catalogs/products/items", new { code = "LC_PURCHASE_CONV", nameAr = "مكرر" }));
        Assert.Equal((422, "REQUIRED_FIELD"), await p.PostProblemAsync("/api/v1/catalogs/products/items", new
        {
            code = "SUPPLY_CHAIN_FINANCE", nameAr = "تمويل سلسلة الإمداد", fields = new Dictionary<string, object?> { ["category"] = "FINANCING" },
        }));
        var own = await p.PostOkAsync("/api/v1/catalogs/products/items", new
        {
            code = "SUPPLY_CHAIN_FINANCE", nameAr = "تمويل سلسلة الإمداد", nameEn = "Supply chain finance",
            fields = new Dictionary<string, object?> { ["category"] = "FINANCING", ["productFamily"] = "FINANCING", ["compliance"] = "CONVENTIONAL", ["consumesCreditLimit"] = true },
        });
        var mine = Item(await ItemsAsync(p, "products"), "SUPPLY_CHAIN_FINANCE");
        Assert.False(mine.GetProperty("isSystem").GetBoolean());
        Assert.Equal("FINANCING", mine.GetProperty("fields").GetProperty("category").GetString());
        Assert.Equal("SUPPLY_CHAIN_FINANCE", own.GetProperty("code").GetString());

        var other = await f.CreateTenantAsync();
        Assert.DoesNotContain(await ItemsAsync(other.Portal, "products"), i => i.GetProperty("code").GetString() == "SUPPLY_CHAIN_FINANCE");
        Assert.Equal(HttpStatusCode.NotFound, (await other.Portal.SendAsync(HttpMethod.Patch, $"/api/v1/catalogs/products/items/{mine.GetProperty("id").GetString()}",
            new { nameEn = "Taken" }, mine.GetProperty("etag").GetString())).StatusCode);

        // Lookup lists: a closed system list takes no item of the tenant's; an open one does.
        var lists = await ItemsAsync(p, "lookup-lists");
        var closed = lists.First(l => l.GetProperty("isSystem").GetBoolean() && !l.GetProperty("fields").GetProperty("allowTenantItems").GetBoolean());
        Assert.Equal((409, "LIST_CLOSED"), await p.PostProblemAsync($"/api/v1/lookups/{closed.GetProperty("code").GetString()}/items", new { code = "MY_ITEM", nameAr = "بندي" }));
        var open = lists.FirstOrDefault(l => l.GetProperty("fields").GetProperty("allowTenantItems").GetBoolean());
        if (open.ValueKind != JsonValueKind.Undefined)
        {
            await p.PostOkAsync($"/api/v1/lookups/{open.GetProperty("code").GetString()}/items", new { code = "MY_ITEM", nameAr = "بندي" });
            Assert.Contains((await p.GetJsonAsync($"/api/v1/lookups/{open.GetProperty("code").GetString()}")).GetProperty("items").EnumerateArray(),
                i => i.GetProperty("code").GetString() == "MY_ITEM");
        }
    }

    [Fact]
    public async Task A_used_item_shows_where_it_is_used_and_is_deactivated_not_deleted()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var advising = Item(await ItemsAsync(p, "fee-types"), "ADVISING");
        var product = Item(await ItemsAsync(p, "products"), "LC_PURCHASE_CONV");
        var productPath = $"/api/v1/catalogs/products/items/{product.GetProperty("id").GetString()}";
        var fees = (await p.GetJsonAsync(productPath + "/fee-types")).GetProperty("items").EnumerateArray().Select(i => i.GetProperty("code").GetString()!).ToList();
        if (!fees.Contains("ADVISING")) fees.Add("ADVISING");
        Assert.Equal((422, "DUPLICATE_LINK"), await p.ProblemAsync(HttpMethod.Put, productPath + "/fee-types", new { codes = fees.Append("ADVISING") }));
        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Put, productPath + "/fee-types", new { codes = fees })).StatusCode);

        var advisingPath = $"/api/v1/catalogs/fee-types/items/{advising.GetProperty("id").GetString()}";
        var usage = await p.GetJsonAsync(advisingPath + "/usage");
        Assert.True(usage.GetProperty("total").GetInt32() >= 1);
        Assert.Contains(usage.GetProperty("items").EnumerateArray(), u => u.GetProperty("table").GetString() == "cat.ProductFeeType");

        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Patch, advisingPath, new { isActive = false }, advising.GetProperty("etag").GetString())).StatusCode);
        var active = (await p.GetJsonAsync("/api/v1/catalogs/fee-types")).GetProperty("items").EnumerateArray();
        Assert.DoesNotContain(active, i => i.GetProperty("code").GetString() == "ADVISING");
        Assert.Contains((await p.GetJsonAsync(productPath + "/fee-types")).GetProperty("items").EnumerateArray(), i => i.GetProperty("code").GetString() == "ADVISING");
        Assert.Equal(HttpStatusCode.MethodNotAllowed, (await p.SendAsync(HttpMethod.Delete, advisingPath)).StatusCode);

        // A flag with effect on a used product changes only when the treasury manager confirms it (FR-CAT-022).
        var limitType = Item(await ItemsAsync(p, "limit-types"), "DOCUMENTARY_CREDITS");
        var limitPath = $"/api/v1/catalogs/limit-types/items/{limitType.GetProperty("id").GetString()}/products";
        var allowed = (await p.GetJsonAsync(limitPath)).GetProperty("items").EnumerateArray().Select(i => i.GetProperty("code").GetString()!).ToHashSet();
        allowed.Add("LC_PURCHASE_CONV");
        await p.OkAsync(HttpMethod.Put, limitPath, new { codes = allowed });
        var fresh = Item(await ItemsAsync(p, "products"), "LC_PURCHASE_CONV");
        Assert.Equal((409, "IMPACT_CONFIRMATION_REQUIRED"), await p.ProblemAsync(HttpMethod.Patch, productPath,
            new { fields = new Dictionary<string, object> { ["consumesCreditLimit"] = !fresh.GetProperty("fields").GetProperty("consumesCreditLimit").GetBoolean() }, confirmImpact = true },
            fresh.GetProperty("etag").GetString()));

        var audit = (await p.GetJsonAsync("/api/v1/audit-events?action=CATALOG_ITEM_UPDATED")).GetProperty("items").EnumerateArray().ToList();
        var row = audit.First(a => a.GetProperty("before").GetProperty("Code").GetString() == "ADVISING");
        Assert.True(row.GetProperty("before").GetProperty("IsActive").GetBoolean());
        Assert.False(row.GetProperty("after").GetProperty("IsActive").GetBoolean());
    }
}
