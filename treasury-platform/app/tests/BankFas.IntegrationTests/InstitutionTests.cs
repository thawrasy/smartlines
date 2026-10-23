using System.Globalization;
using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Institutions, relationships, accounts and base rates (AC-INS-1 to 3, AC-ACC-1, AC-CAT-2, AC-CAT-3): the bank set-up
/// wizard and its channels, the "reports to" tree and the replacement of a default contact, the promotion of a contact
/// to a party, IBAN, virtual accounts, masking and the audited reveal, and base-rate values on a date, against the
/// database.
/// </summary>
[Collection("database")]
public sealed class InstitutionTests(PlatformFixture f)
{
    private static async Task<string> CompanyAsync(HttpClient p, string code) =>
        PlatformFixture.Id(await p.PostOkAsync("/api/v1/companies", new
        {
            companyCode = code, nameAr = "شركة " + code, nameEn = "Company " + code, legalForm = "LLC", country = "SA", fiscalYearEndMonth = 12,
        }));

    private static object Phone(string number) => new { kind = "MOBILE", value = number };

    private static async Task<string> InstitutionAsync(HttpClient p, string code, string type = "BANK", string? party = null) =>
        PlatformFixture.Id(await p.PostOkAsync("/api/v1/institutions", new { code, nameAr = "بنك " + code, nameEn = "Bank " + code, type, country = "AE", party }));

    private static async Task<string> ContactAsync(HttpClient p, string institution, string name, string? reportsTo = null) =>
        PlatformFixture.Id(await p.PostOkAsync($"/api/v1/institutions/{institution}/contacts", new
        {
            fullNameAr = name, fullNameEn = name, reportsTo, contactMethods = new[] { new { kind = "EMAIL", value = name.ToLowerInvariant() + "@bank.example" } },
        }));

    [Fact]
    public async Task The_bank_wizard_creates_everything_or_nothing_and_resolves_contacts_and_channels()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var c1 = await CompanyAsync(t.Portal, "C1");
        var c2 = await CompanyAsync(t.Portal, "C2");
        var c3 = await CompanyAsync(t.Portal, "C3");
        string[] all = ["LC_PURCHASE_CONV", "LG_PERFORMANCE", "POS_COLLECTION", "PAYROLL_SERVICE"];
        string[] two = ["LC_PURCHASE_CONV", "LG_PERFORMANCE"];
        object Setup(bool dryRun) => new
        {
            dryRun,
            institution = new { code = "bnk1", nameAr = "البنك الأول", nameEn = "First Bank", type = "BANK", country = "AE", swiftBic = "aaaaaeaa" },
            contacts = new[]
            {
                new { key = "rm1", fullNameAr = "مدير علاقة 1", fullNameEn = "RM One", contactMethods = new[] { Phone("0501234567") } },
                new { key = "rm2", fullNameAr = "مدير علاقة 2", fullNameEn = "RM Two", contactMethods = new[] { Phone("0501234568") } },
                new { key = "lc", fullNameAr = "جهة الاعتمادات", fullNameEn = "LC desk", contactMethods = new[] { Phone("0501234569") } },
            },
            companies = new[]
            {
                new { company = c1, customerNo = "10001", coverage = new[] { new { contactKey = "rm1", role = "RM" } } },
                new { company = c2, customerNo = "10002", coverage = new[] { new { contactKey = "rm1", role = "RM" } } },
                new { company = c3, customerNo = "10003", coverage = new[] { new { contactKey = "rm2", role = "RM" } } },
            },
            products = all.Select(p => (Company: c1, Product: p)).Concat(two.Select(p => (Company: c2, Product: p))).Concat(two.Select(p => (Company: c3, Product: p)))
                .Select(x => new
                {
                    company = x.Company, product = x.Product, channel = x.Product == "LC_PURCHASE_CONV" ? "BANK_PORTAL" : null,
                    defaultContactKey = x.Product == "LC_PURCHASE_CONV" ? "lc" : null,
                }).ToArray(),
        };

        // The review: what "create" will make, and five products without a default contact; nothing is kept (AC-INS-1).
        var review = await tm.PostOkAsync("/api/v1/bank-setup", Setup(true));
        Assert.True(review.GetProperty("dryRun").GetBoolean());
        Assert.Equal(8, review.GetProperty("summary").GetProperty("relationshipProducts").GetInt32());
        Assert.Contains(review.GetProperty("warnings").EnumerateArray(), w => w.GetProperty("code").GetString() == "W-INS-NO-DEFAULT-CONTACT" && w.GetProperty("count").GetInt32() == 5);
        Assert.Empty((await tm.GetJsonAsync("/api/v1/institutions?q=BNK1")).GetProperty("items").EnumerateArray());

        var created = await tm.PostOkAsync("/api/v1/bank-setup", Setup(false));
        var summary = created.GetProperty("summary");
        Assert.Equal((1, 3, 8, 3), (summary.GetProperty("institutions").GetInt32(), summary.GetProperty("relationships").GetInt32(),
            summary.GetProperty("relationshipProducts").GetInt32(), summary.GetProperty("coverage").GetInt32()));
        var bank = PlatformFixture.Id(created);
        var detail = await tm.GetJsonAsync($"/api/v1/institutions/{bank}");
        Assert.Equal("BNK1", detail.GetProperty("institution").GetProperty("code").GetString());
        Assert.Equal("ACTIVE", detail.GetProperty("institution").GetProperty("status").GetString());
        Assert.Equal("LOCAL", detail.GetProperty("institution").GetProperty("locality").GetString());   // the test tenant's home country is AE
        Assert.Equal("AAAAAEAA", detail.GetProperty("institution").GetProperty("swiftBic").GetString());
        Assert.All(detail.GetProperty("relationships").EnumerateArray(), r => Assert.Equal("ACTIVE", r.GetProperty("status").GetString()));

        // SVC-02: BANK_PORTAL for LC, MANUAL_FORM for the rest; SVC-01: the LC desk for LC, the RM otherwise (BR-INS-009).
        var q = $"company={c2}&institution={bank}";
        Assert.Equal("BANK_PORTAL", (await tm.GetJsonAsync($"/api/v1/services/preferred-channel?{q}&product=LC_PURCHASE_CONV")).GetProperty("channel").GetString());
        var lg = await tm.GetJsonAsync($"/api/v1/services/preferred-channel?{q}&product=LG_PERFORMANCE");
        Assert.Equal(("MANUAL_FORM", "CONFIGURED"), (lg.GetProperty("channel").GetString(), lg.GetProperty("source").GetString()));
        Assert.Equal("DEFAULT", (await tm.GetJsonAsync($"/api/v1/services/preferred-channel?{q}&product=POS_COLLECTION")).GetProperty("source").GetString());
        var lcContact = await tm.GetJsonAsync($"/api/v1/services/resolve-contact?{q}&product=LC_PURCHASE_CONV");
        Assert.Equal(("DEFAULT", "جهة الاعتمادات"), (lcContact.GetProperty("source").GetString(), lcContact.GetProperty("name").GetString()));
        var lgContact = await tm.GetJsonAsync($"/api/v1/services/resolve-contact?{q}&product=LG_PERFORMANCE");
        Assert.Equal(("RM", "مدير علاقة 1"), (lgContact.GetProperty("source").GetString(), lgContact.GetProperty("name").GetString()));

        // Direct integration is refused (BR-INS-010); the same code again creates nothing (BR-INS-013).
        var rel = created.GetProperty("relationships").EnumerateArray().First(r => r.GetProperty("company").GetString() == c1).GetProperty("relationship").GetString();
        Assert.Equal((422, "V-INS-06"), await tm.ProblemAsync(HttpMethod.Put, $"/api/v1/relationships/{rel}/products/LG_PERFORMANCE", new { channel = "DIRECT_INTEGRATION" }));
        Assert.Equal((409, "V-INS-01"), await tm.PostProblemAsync("/api/v1/bank-setup", Setup(false)));
        Assert.Single((await tm.GetJsonAsync("/api/v1/institutions?q=BNK1")).GetProperty("items").EnumerateArray());
        Assert.Equal(3, (await tm.GetJsonAsync($"/api/v1/relationships?institution={bank}")).GetProperty("items").GetArrayLength());

        // One relationship per company and institution (BR-INS-007); a repeated customer number is a warning only.
        Assert.Equal((409, "V-INS-05"), await tm.PostProblemAsync("/api/v1/relationships", new { company = c1, institution = bank }));
        var c4 = await CompanyAsync(t.Portal, "C4");
        var dup = await tm.PostOkAsync("/api/v1/relationships", new { company = c4, institution = bank, customerNo = "10001" });
        Assert.Equal("V-INS-05-CUSTOMER-NO", dup.GetProperty("warnings")[0].GetProperty("code").GetString());

        // The BIC is 8 or 11 characters (BR-INS-001); a relationship with an open account does not close (BR-INS-011).
        Assert.Equal((422, "V-INS-01"), await tm.PostProblemAsync("/api/v1/institutions", new { code = "BNK9", refCode = "BNI", nameAr = "بنك", type = "BANK", country = "AE", swiftBic = "AAAASA" }));
        await tm.PostOkAsync("/api/v1/accounts", new { company = c1, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "900-1" });
        Assert.Equal((409, "V-INS-OPEN-ACCOUNTS"), await tm.PostProblemAsync($"/api/v1/relationships/{rel}/actions/close", new { reason = "Moved" }));
        Assert.Equal((409, "V-INS-OPEN-RELATIONSHIPS"), await tm.PostProblemAsync($"/api/v1/institutions/{bank}/actions/deactivate", new { }));
    }

    [Fact]
    public async Task Reports_to_has_no_circle_and_a_default_contact_leaves_with_a_replacement()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var c1 = await CompanyAsync(t.Portal, "C1");
        var bank = await InstitutionAsync(tm, "BNK1");
        // A contact needs a way to reach it (BR-INS-006).
        Assert.Equal((422, "V-INS-04"), await tm.PostProblemAsync($"/api/v1/institutions/{bank}/contacts", new { fullNameAr = "بلا وسيلة" }));
        var z = await ContactAsync(tm, bank, "Z");
        var y = await ContactAsync(tm, bank, "Y", z);
        var x = await ContactAsync(tm, bank, "X", y);
        var w = await ContactAsync(tm, bank, "W");

        // X reports to Y, Y to Z: Z to X makes a circle (AC-INS-2, V-INS-03); a contact of another bank is refused too.
        var (zDetail, zTag) = await tm.GetWithETagAsync($"/api/v1/contacts/{z}");
        Assert.Equal((422, "V-INS-03"), await tm.ProblemAsync(HttpMethod.Patch, $"/api/v1/contacts/{z}", new { reportsTo = x }, zTag));
        var other = await InstitutionAsync(tm, "BNK2");
        var stranger = await ContactAsync(tm, other, "S");
        Assert.Equal((422, "V-INS-03"), await tm.ProblemAsync(HttpMethod.Patch, $"/api/v1/contacts/{z}", new { reportsTo = stranger }, zTag));
        Assert.Equal("Z", zDetail.GetProperty("contact").GetProperty("fullNameAr").GetString());

        // Y is the default contact of two products; deactivating it asks for a replacement for both and for X (FR-INS-016).
        var rel = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/relationships", new { company = c1, institution = bank, customerNo = "555" }));
        await tm.PostOkAsync($"/api/v1/relationships/{rel}/coverage", new { contact = z, role = "RM" });
        foreach (var p in new[] { "LC_PURCHASE_CONV", "LG_PERFORMANCE" })
            Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Put, $"/api/v1/relationships/{rel}/products/{p}", new { defaultContact = y })).StatusCode);
        var refusal = await tm.SendAsync(HttpMethod.Post, $"/api/v1/contacts/{y}/actions/deactivate", new { reason = "LEFT_BANK" });
        Assert.Equal(HttpStatusCode.Conflict, refusal.StatusCode);
        var body = JsonDocument.Parse(await refusal.Content.ReadAsStringAsync(TestContext.Current.CancellationToken)).RootElement;
        Assert.Equal("V-INS-REPLACEMENT-REQUIRED", body.GetProperty("code").GetString());
        var rows = body.GetProperty("products").EnumerateArray().Select(PlatformFixture.Id).ToList();
        Assert.Equal(2, rows.Count);
        Assert.Equal(x, PlatformFixture.Id(body.GetProperty("reports")[0]));

        await tm.PostOkAsync($"/api/v1/contacts/{y}/actions/deactivate", new
        {
            reason = "LEFT_BANK", productReplacements = rows.ToDictionary(r => r, _ => (string?)w), subordinatesReportTo = z,
        });
        foreach (var p in new[] { "LC_PURCHASE_CONV", "LG_PERFORMANCE" })
        {
            var resolved = await tm.GetJsonAsync($"/api/v1/services/resolve-contact?relationship={rel}&product={p}");
            Assert.Equal(("DEFAULT", "W"), (resolved.GetProperty("source").GetString(), resolved.GetProperty("name").GetString()));
        }
        Assert.Equal(z, (await tm.GetJsonAsync($"/api/v1/contacts/{x}")).GetProperty("contact").GetProperty("reportsTo").GetString());

        // Coverage: the next RM takes rank 1 from its date and the old row ends the day before (F-INS-2).
        var coverage = (await tm.GetJsonAsync($"/api/v1/relationships/{rel}")).GetProperty("coverage")[0];
        Assert.Equal(1, coverage.GetProperty("rank").GetInt32());
        var from = DateOnly.FromDateTime(f.Env.Clock.GetUtcNow().UtcDateTime).AddDays(10).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
        await tm.PostOkAsync($"/api/v1/relationships/{rel}/coverage/{PlatformFixture.Id(coverage)}/actions/replace", new { contact = w, validFrom = from });
        var after = (await tm.GetJsonAsync($"/api/v1/relationships/{rel}")).GetProperty("coverage").EnumerateArray().ToList();
        Assert.Equal(2, after.Count);
        Assert.Equal(DateOnly.Parse(from, CultureInfo.InvariantCulture).AddDays(-1).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture), after.Single(c => c.GetProperty("contact").GetString() == z).GetProperty("validTo").GetString());
        Assert.Equal(1, after.Single(c => c.GetProperty("validTo").ValueKind == JsonValueKind.Null).GetProperty("rank").GetInt32());

        // Units: a section under a section is refused, four levels at most (BR-INS-004).
        var branch = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/institutions/{bank}/units", new { unitType = "BRANCH", nameAr = "فرع الرياض" }));
        var dept = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/institutions/{bank}/units", new { unitType = "DEPARTMENT", nameAr = "إدارة الشركات", parent = branch }));
        var section = PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/institutions/{bank}/units", new { unitType = "SECTION", nameAr = "قسم الاعتمادات", parent = dept }));
        Assert.Equal((422, "V-INS-03"), await tm.PostProblemAsync($"/api/v1/institutions/{bank}/units", new { unitType = "SECTION", nameAr = "قسم فرعي", parent = section }));
    }

    [Fact]
    public async Task A_contact_is_promoted_to_a_party_once_per_institution_and_follows_a_merge()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        async Task<string> PartyAsync(string name, string birth) => PlatformFixture.Id(await tm.PostOkAsync("/api/v1/parties", new
        {
            kind = "INDIVIDUAL", nameAr = name, nameEn = name, country = "SA", residencyStatus = "CITIZEN", birthDate = birth,
        }));
        var p1 = await PartyAsync("ممول فرد", "1970-01-01");
        // An individual lender is linked to its party (BR-INS-003); a bank is not.
        Assert.Equal((422, "V-INS-PARTY"), await tm.PostProblemAsync("/api/v1/institutions", new { code = "IND0", refCode = "IND", nameAr = "فرد", type = "INDIVIDUAL", country = "AE" }));
        await InstitutionAsync(tm, "IND1", "INDIVIDUAL", p1);
        var bank = await InstitutionAsync(tm, "BNK1");
        var k1 = await ContactAsync(tm, bank, "K1");
        var k2 = await ContactAsync(tm, bank, "K2");

        var roles = (await tm.GetJsonAsync($"/api/v1/parties/{p1}")).GetProperty("roles").EnumerateArray().ToList();
        Assert.Equal(("INSTITUTION", 1), (roles.Single().GetProperty("role").GetString(), roles.Single().GetProperty("count").GetInt32()));

        // K1 linked to P2: P2 shows the contact as a use, and nothing of the identity is copied to K1 (BR-INS-014).
        var p2 = await PartyAsync("جهة مرقّاة", "1980-02-02");
        Assert.Empty((await tm.GetJsonAsync($"/api/v1/parties/{p2}")).GetProperty("roles").EnumerateArray());
        Assert.Equal(HttpStatusCode.NoContent, (await tm.SendAsync(HttpMethod.Post, $"/api/v1/contacts/{k1}/actions/link-party", new { party = p2 })).StatusCode);
        Assert.Equal("CONTACT", (await tm.GetJsonAsync($"/api/v1/parties/{p2}")).GetProperty("roles")[0].GetProperty("role").GetString());
        Assert.Equal("K1", (await tm.GetJsonAsync($"/api/v1/contacts/{k1}")).GetProperty("contact").GetProperty("fullNameAr").GetString());
        // K2 to the same party in the same institution is refused (V-INS-07).
        Assert.Equal((409, "V-INS-07"), await tm.PostProblemAsync($"/api/v1/contacts/{k2}/actions/link-party", new { party = p2 }));

        // P2 merged into P3: K1 now points at P3 (FR-INS-021, FR-PTY-016).
        var p3 = await PartyAsync("جهة مرقّاة", "1980-02-03");
        await tm.PostOkAsync($"/api/v1/parties/{p2}/actions/merge", new { into = p3, reason = "Same person" });
        Assert.Equal(p3, (await tm.GetJsonAsync($"/api/v1/contacts/{k1}")).GetProperty("contact").GetProperty("party").GetString());
    }

    [Fact]
    public async Task Accounts_check_the_iban_nest_virtual_accounts_mask_and_audit_the_reveal()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        var c1 = await CompanyAsync(t.Portal, "C1");
        var bank = await InstitutionAsync(tm, "BNK1");

        // No relationship yet: the account asks, then creates it on confirmation (BR-ACC-003).
        var master = new { company = c1, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "0012-3456", iban = "SA50 9900 0000 0000 0012 3456" };
        Assert.Equal((409, "V-ACC-RELATIONSHIP-REQUIRED"), await tm.PostProblemAsync("/api/v1/accounts", master));
        Assert.Equal((422, "V-ACC-01"), await tm.PostProblemAsync("/api/v1/accounts", new
        {
            company = c1, institution = bank, type = "CURRENT", currency = "SAR", accountNumber = "7777", iban = "SA50 9900 0000 0000 0012 7518", createRelationship = true,
        }));
        var created = await tm.PostOkAsync("/api/v1/accounts", new
        {
            master.company, master.institution, master.type, master.currency, master.accountNumber, master.iban, createRelationship = true,
        });
        Assert.True(created.GetProperty("relationshipCreated").GetBoolean());
        var masterId = PlatformFixture.Id(created);
        // The same number with other separators is the same number (BR-ACC-001).
        Assert.Equal((409, "V-ACC-01"), await tm.PostProblemAsync("/api/v1/accounts", new { company = c1, institution = bank, type = "CURRENT", currency = "USD", accountNumber = "00 12 34 56" }));

        // A virtual account in USD under a SAR master is refused; in SAR it is accepted; the master closes after it (BR-ACC-004).
        Assert.Equal((422, "V-ACC-02"), await tm.PostProblemAsync("/api/v1/accounts", new { company = c1, institution = bank, type = "VIRTUAL", currency = "USD", accountNumber = "V-0001", master = masterId }));
        var virt = PlatformFixture.Id(await tm.PostOkAsync("/api/v1/accounts", new { company = c1, institution = bank, type = "VIRTUAL", currency = "SAR", accountNumber = "V-0001", master = masterId }));
        Assert.Equal((409, "V-ACC-02"), await tm.PostProblemAsync($"/api/v1/accounts/{masterId}/actions/close", new { reason = "Not used" }));
        await tm.OkAsync(HttpMethod.Post, $"/api/v1/accounts/{virt}/actions/close", new { reason = "Not used" });
        Assert.Equal((409, "V-ACC-CLOSED"), await tm.PostProblemAsync($"/api/v1/accounts/{virt}/actions/status", new { status = "ACTIVE" }));

        // The tenant administrator sees the mask; the treasury manager reveals the full number, and the reveal is audited (BR-ACC-016).
        var seen = (await t.Portal.GetJsonAsync($"/api/v1/accounts/{masterId}")).GetProperty("account");
        Assert.Equal("SA•• •••• •••• •••• •••• 3456", seen.GetProperty("iban").GetString());
        Assert.Equal("•••• 3456", seen.GetProperty("accountNumber").GetString());
        Assert.DoesNotContain("123456", (await t.Portal.GetJsonAsync("/api/v1/accounts")).GetRawText(), StringComparison.Ordinal);
        Assert.Equal((403, "FORBIDDEN"), await t.Portal.PostProblemAsync($"/api/v1/accounts/{masterId}/actions/reveal", new { }));
        var revealed = await tm.PostOkAsync($"/api/v1/accounts/{masterId}/actions/reveal", new { reason = "Bank letter" });
        Assert.Equal(("00123456", "SA5099000000000000123456"), (revealed.GetProperty("accountNumber").GetString(), revealed.GetProperty("iban").GetString()));
        var log = (await t.Portal.GetJsonAsync("/api/v1/audit-events?category=IDENTITY_ACCESS&limit=200")).GetProperty("items").EnumerateArray()
            .Select(e => e.GetProperty("action").GetString()).ToList();
        Assert.Contains("ACCOUNT_REVEALED", log);
        Assert.Contains("ACCOUNT_REVEAL_DENIED", log);
    }

    [Fact]
    public async Task Base_rates_give_the_value_on_a_date_keep_corrections_and_are_unique_per_scope()
    {
        var t = await f.CreateTenantAsync();
        var (tm, _, _) = await f.UserWithRoleAsync(t, "TM");
        // Illustrative values, not market data (AC-CAT-2).
        async Task<string> ValueAsync(string code, string date, decimal value) =>
            PlatformFixture.Id(await tm.PostOkAsync($"/api/v1/base-rates/{code}/values", new { effectiveDate = date, valuePct = value }));
        async Task<JsonElement> AsOfAsync(string query) => await tm.GetJsonAsync("/api/v1/services/base-rate?" + query);

        await ValueAsync("SAIBOR_3M", "2026-01-01", 5.40m);
        var april = await ValueAsync("SAIBOR_3M", "2026-04-01", 5.55m);
        Assert.Equal(5.40m, (await AsOfAsync("rate=SAIBOR_3M&asOf=2026-03-31")).GetProperty("valuePct").GetDecimal());
        Assert.Equal(5.55m, (await AsOfAsync("rate=SAIBOR_3M&asOf=2026-04-01")).GetProperty("valuePct").GetDecimal());
        Assert.Equal("NO_VALUE", (await AsOfAsync("rate=SAIBOR_3M&asOf=2025-12-31")).GetProperty("status").GetString());
        await ValueAsync("SAIBOR_3M", "2026-02-01", 5.45m);
        Assert.Equal(5.45m, (await AsOfAsync("rate=SAIBOR_3M&asOf=2026-03-31")).GetProperty("valuePct").GetDecimal());
        Assert.Equal((409, "V-CAT-03"), await tm.PostProblemAsync("/api/v1/base-rates/SAIBOR_3M/values", new { effectiveDate = "2026-04-01", valuePct = 5.6m }));
        await tm.PostOkAsync($"/api/v1/base-rates/SAIBOR_3M/values/{april}/actions/correct", new { valuePct = 5.60m, reason = "Entry error" });
        var byAlias = await AsOfAsync("name=sibor&tenor=3M&asOf=2026-04-01");
        Assert.Equal(("SAIBOR_3M", 5.60m), (byAlias.GetProperty("rate").GetString(), byAlias.GetProperty("valuePct").GetDecimal()));
        var history = (await tm.GetJsonAsync("/api/v1/base-rates/SAIBOR_3M")).GetProperty("values").EnumerateArray().ToList();
        Assert.Equal(4, history.Count);
        var aprilRows = history.Where(v => v.GetProperty("effectiveDate").GetString() == "2026-04-01").ToList();
        Assert.Equal(["SUPERSEDED", "VALID"], aprilRows.Select(v => v.GetProperty("status").GetString()!).Order(StringComparer.Ordinal));
        await ValueAsync("SAIBOR_3M", "2026-05-01", 0m);
        await ValueAsync("SAIBOR_3M", "2026-06-01", -0.25m);
        Assert.Single((await tm.GetJsonAsync("/api/v1/base-rates?q=Sibor&tenor=3M")).GetProperty("items").EnumerateArray());

        // Internal rates of two banks share family and tenor; a second one for the same bank, or a second market rate, is refused (AC-CAT-3).
        var bnk1 = await InstitutionAsync(tm, "BNK1");
        var bnk2 = await InstitutionAsync(tm, "BNK2");
        object Internal(string? institution, string kind = "BANK_INTERNAL") => new { kind, institution, familyCode = "BANK_BASE", tenor = "3M", currency = "SAR", nameAr = "السعر الأساسي للبنك" };
        var first = (await t.Portal.PostOkAsync("/api/v1/base-rates", Internal(bnk1))).GetProperty("code").GetString()!;
        var second = (await t.Portal.PostOkAsync("/api/v1/base-rates", Internal(bnk2))).GetProperty("code").GetString()!;
        Assert.Equal((409, "V-CAT-03"), await t.Portal.PostProblemAsync("/api/v1/base-rates", Internal(bnk1)));
        Assert.Equal((409, "V-CAT-03"), await t.Portal.PostProblemAsync("/api/v1/base-rates", new { kind = "MARKET", familyCode = "SAIBOR", tenor = "3M", currency = "SAR", nameAr = "مكرر" }));
        Assert.Equal((422, "V-CAT-03"), await t.Portal.PostProblemAsync("/api/v1/base-rates", Internal(bnk1, "MARKET")));
        Assert.Equal((422, "V-CAT-03"), await t.Portal.PostProblemAsync("/api/v1/base-rates", Internal(null)));
        await ValueAsync(first, "2026-01-01", 6.00m);
        await ValueAsync(second, "2026-01-01", 6.25m);
        Assert.Equal(6.00m, (await AsOfAsync($"name=BANK_BASE&tenor=3M&institution={bnk1}&asOf=2026-02-01")).GetProperty("valuePct").GetDecimal());
        Assert.Equal(6.25m, (await AsOfAsync($"name=BANK_BASE&tenor=3M&institution={bnk2}&asOf=2026-02-01")).GetProperty("valuePct").GetDecimal());
    }
}
