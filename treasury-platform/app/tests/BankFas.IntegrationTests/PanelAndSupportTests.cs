using System.Net;
using System.Text.Json;

namespace BankFas.IntegrationTests;

/// <summary>
/// Support access granted by the tenant and used from the panel (AC-PLT-8), and the rest of the operator panel:
/// tenant details with counters only, modules, the invitation sent again, and operator accounts (AC-PLT-5, AC-PLT-7).
/// </summary>
[Collection("database")]
public sealed class PanelAndSupportTests(PlatformFixture f)
{
    [Fact]
    public async Task A_tenant_grants_support_and_every_page_the_operator_opens_is_in_its_log()
    {
        var t = await f.CreateTenantAsync();
        var p = t.Portal;
        var operators = await p.GetJsonAsync("/api/v1/support-operators");
        // The operator of these tests; the browser tests' operator is on the list too (tools/ci/e2e.sh).
        var op = operators.GetProperty("items").EnumerateArray().First(o => o.GetProperty("displayName").GetString() == "Integration operator");
        Assert.False(op.TryGetProperty("email", out _));
        Assert.Equal((422, "VALIDATION_FAILED"), await p.PostProblemAsync("/api/v1/support-grants", new { operatorId = PlatformFixture.Id(op), hours = 100, reason = "x" }));
        var grant = await p.PostOkAsync("/api/v1/support-grants", new { operatorId = PlatformFixture.Id(op), hours = 2, reason = "Help with the set-up" });
        var grants = await p.GetJsonAsync("/api/v1/support-grants");
        Assert.Equal("ACTIVE", grants.GetProperty("items")[0].GetProperty("status").GetString());

        var mine = await f.Panel.GetJsonAsync("/api/v1/operator/support/grants");
        var g = mine.GetProperty("items").EnumerateArray().First(x => x.GetProperty("code").GetString() == t.Code);
        var users = await f.Panel.GetJsonAsync($"/api/v1/operator/support/{PlatformFixture.Id(g)}/users");
        Assert.Contains(users.GetProperty("items").EnumerateArray(), u => u.GetProperty("email").GetString() == t.AdminEmail);

        var log = await p.GetJsonAsync("/api/v1/audit-events?category=SECURITY&limit=200");
        var actions = log.GetProperty("items").EnumerateArray().Select(r => r.GetProperty("action").GetString()).ToList();
        Assert.Contains("SUPPORT_ACCESS_GRANTED", actions);
        Assert.Contains("SUPPORT_ACCESS_BOUND", actions);
        Assert.Contains("SUPPORT_PAGE_VIEWED", actions);

        Assert.Equal(HttpStatusCode.NoContent, (await p.SendAsync(HttpMethod.Post, $"/api/v1/support-grants/{PlatformFixture.Id(grant)}/actions/revoke", new { })).StatusCode);
        Assert.Equal((409, "STATE_CONFLICT"), await p.PostProblemAsync($"/api/v1/support-grants/{PlatformFixture.Id(grant)}/actions/revoke", new { }));
        Assert.Equal(HttpStatusCode.NotFound, (await f.Panel.GetAsync($"/api/v1/operator/support/{PlatformFixture.Id(g)}/users", TestContext.Current.CancellationToken)).StatusCode);
    }

    [Fact]
    public async Task The_panel_shows_counters_sets_modules_and_sends_the_first_invitation_again()
    {
        var t = await f.CreateTenantAsync();
        var list = await f.Panel.GetJsonAsync("/api/v1/operator/tenants");
        var id = list.GetProperty("items").EnumerateArray().First(x => x.GetProperty("code").GetString() == t.Code).GetProperty("id").GetString()!;
        var details = await f.Panel.GetJsonAsync($"/api/v1/operator/tenants/{id}");
        Assert.Equal(1, details.GetProperty("counters").GetProperty("UsersActive").GetInt32());
        Assert.Equal("ACTIVE", details.GetProperty("counters").GetProperty("FirstAdminStatus").GetString());
        Assert.Equal("AE", details.GetProperty("tenant").GetProperty("homeCountryIso2").GetString());

        Assert.Equal((422, "V-PLT-03"), await f.Panel.ProblemAsync(HttpMethod.Put, $"/api/v1/operator/tenants/{id}/modules", new { modules = new[] { "REPORTS" } }));
        Assert.Equal(HttpStatusCode.NoContent, (await f.Panel.SendAsync(HttpMethod.Put, $"/api/v1/operator/tenants/{id}/modules", new { modules = new[] { "CORE", "REPORTS" } })).StatusCode);
        var me = await t.Portal.GetJsonAsync("/api/v1/me");
        Assert.Equal(["CORE", "REPORTS"], me.GetProperty("modules").EnumerateArray().Select(m => m.GetString()));
        Assert.Equal((409, "LINK_NOT_ISSUABLE"), await f.Panel.PostProblemAsync($"/api/v1/operator/tenants/{id}/actions/resend-invitation", new { }));

        // A tenant whose administrator has not accepted yet gets a new link.
        var code = "ci-" + Guid.NewGuid().ToString("N")[..10];
        var adminEmail = $"admin@{code}.test.invalid";
        var created = await f.Panel.PostOkAsync("/api/v1/operator/tenants", new
        {
            code, nameEn = "Late Trading", nameAr = "متأخر", homeCountryIso2 = "AE", timeZone = "Asia/Dubai", adminEmail, adminDisplayName = "Admin",
            mfaCode = f.NextCode(f.OperatorSecret),
        });
        var ct = TestContext.Current.CancellationToken;
        await f.Env.OnboardingJob().RunOnceAsync(ct);
        var first = f.Env.LinkTokenSentTo(adminEmail);
        var resend = await f.Panel.SendAsync(HttpMethod.Post, $"/api/v1/operator/tenants/{PlatformFixture.Id(created)}/actions/resend-invitation", new { });
        Assert.Equal(HttpStatusCode.Accepted, resend.StatusCode);
        Assert.True(await f.Env.OnboardingJob().RunOnceAsync(ct) >= 1);
        var second = f.Env.LinkTokenSentTo(adminEmail);
        Assert.NotEqual(first, second);
        var portal = await f.Env.BrowserAsync($"{code}.{TestEnvironment.Domain}");
        Assert.Equal((422, "LINK_INVALID"), await portal.PostProblemAsync("/api/v1/auth/invitation", new { token = first, password = "a long enough password" }));
        await portal.PostOkAsync("/api/v1/auth/invitation", new { token = second, password = "a long enough password" });
    }

    [Fact]
    public async Task An_operator_administrator_manages_operator_accounts()
    {
        f.RequireDatabase();
        var email = $"support-{Guid.NewGuid().ToString("N")[..10]}@test.invalid";
        Assert.Equal((403, "STEP_UP_REQUIRED"), await f.Panel.PostProblemAsync("/api/v1/operator/operators",
            new { email, displayName = "Support One", role = "OPERATOR_SUPPORT", mfaCode = "000000" }));
        var invited = await f.Panel.PostOkAsync("/api/v1/operator/operators",
            new { email, displayName = "Support One", role = "OPERATOR_SUPPORT", mfaCode = f.NextCode(f.OperatorSecret) });
        Assert.True(invited.GetProperty("invitationSent").GetBoolean());
        var link = f.Env.LinkTokenSentTo(email);

        var panel2 = await f.Env.BrowserAsync(TestEnvironment.OperatorHost);
        var setup = await panel2.PostOkAsync("/api/v1/operator/auth/setup", new { token = link });
        var secret = PlatformFixture.Base32Decode(setup.GetProperty("secret").GetString()!);
        const string password = "support operator passphrase";
        await panel2.PostOkAsync("/api/v1/operator/auth/setup/complete", new { token = link, password, code = f.NextCode(secret) });
        await panel2.PostOkAsync("/api/v1/operator/auth/login", new { email, password });
        await panel2.PostOkAsync("/api/v1/operator/auth/mfa", new { code = f.NextCode(secret) });
        Assert.Equal((403, "FORBIDDEN"), await panel2.ProblemAsync(HttpMethod.Get, "/api/v1/operator/operators"));
        Assert.Equal(HttpStatusCode.OK, (await panel2.GetAsync("/api/v1/operator/tenants", TestContext.Current.CancellationToken)).StatusCode);

        var operators = await f.Panel.GetJsonAsync("/api/v1/operator/operators");
        Assert.Contains(operators.GetProperty("items").EnumerateArray(), o => o.GetProperty("email").GetString() == email && o.GetProperty("status").GetString() == "ACTIVE");
        var id = PlatformFixture.Id(invited);
        var disabled = await f.Panel.PostOkAsync($"/api/v1/operator/operators/{id}/actions/disable", new { mfaCode = f.NextCode(f.OperatorSecret) });
        Assert.Equal("DISABLED", disabled.GetProperty("status").GetString());
        Assert.Equal(HttpStatusCode.Unauthorized, (await panel2.GetAsync("/api/v1/operator/tenants", TestContext.Current.CancellationToken)).StatusCode);
        Assert.Equal("ACTIVE", (await f.Panel.PostOkAsync($"/api/v1/operator/operators/{id}/actions/enable", new { mfaCode = f.NextCode(f.OperatorSecret) }))
            .GetProperty("status").GetString());

        Assert.NotEmpty((await f.Panel.GetJsonAsync("/api/v1/operator/plans")).GetProperty("items").EnumerateArray());
        Assert.Contains((await f.Panel.GetJsonAsync("/api/v1/operator/countries")).GetProperty("items").EnumerateArray(), c => c.GetProperty("iso2").GetString() == "AE");
        Assert.Equal(JsonValueKind.Array, (await f.Panel.GetJsonAsync("/api/v1/operator/keys/reference-counts?status=REVOKED")).GetProperty("items").ValueKind);
    }
}
