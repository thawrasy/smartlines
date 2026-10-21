using System.Net;

namespace BankFas.IntegrationTests;

/// <summary>
/// The exit check of S0 (AC-PLT-5, DOC-F05 section 7). The fixture already set up the first operator from the
/// deployment's link and signed in with TOTP. Here the operator creates a tenant with a fresh code; the onboarding
/// job creates its keys and roles and invites the first administrator; the administrator accepts, enrols MFA, signs
/// in, and sees the account. Then the refusals.
/// </summary>
[Collection("database")]
public sealed class OnboardingPathTests(PlatformFixture f)
{
    [Fact]
    public async Task Operator_creates_a_tenant_whose_first_administrator_signs_in_with_mfa()
    {
        f.RequireDatabase();
        var env = f.Env;
        var ct = TestContext.Current.CancellationToken;
        var panel = f.Panel;
        var me = await panel.GetJsonAsync("/api/v1/operator/me");
        Assert.Equal("OPERATOR_ADMIN", me.GetProperty("role").GetString());

        // A second panel session needs its own TOTP check before anything else.
        var other = await env.BrowserAsync(TestEnvironment.OperatorHost);
        await other.PostOkAsync("/api/v1/operator/auth/login", new { email = PlatformFixture.OperatorEmail, password = PlatformFixture.OperatorPassword });
        Assert.Equal(HttpStatusCode.Unauthorized, (await other.GetAsync("/api/v1/operator/me", ct)).StatusCode);
        Assert.Equal(401, (await other.PostProblemAsync("/api/v1/operator/auth/mfa", new { code = "000000" })).Status);

        // Creating a tenant takes a fresh code (step-up); without one it is refused.
        var code = "ci-" + Guid.NewGuid().ToString("N")[..8];
        var adminEmail = $"admin@{code}.test.invalid";
        var tenantBody = new
        {
            code, nameEn = "Integration Trading", nameAr = "شركة الاختبار", planCode = "STANDARD", homeCountryIso2 = "AE",
            timeZone = "Asia/Dubai", defaultLanguage = "en", adminEmail, adminDisplayName = "First Admin", mfaCode = "000000",
        };
        Assert.Equal((403, "STEP_UP_REQUIRED"), await panel.PostProblemAsync("/api/v1/operator/tenants", tenantBody));
        var created = await panel.PostOkAsync("/api/v1/operator/tenants", tenantBody with { mfaCode = f.NextCode(f.OperatorSecret) });
        Assert.Equal("TRIAL", created.GetProperty("status").GetString());
        var list = await panel.GetJsonAsync("/api/v1/operator/tenants");
        Assert.Contains(list.GetProperty("items").EnumerateArray(), t => t.GetProperty("code").GetString() == code);

        // The worker onboards it: keys, roles, the first administrator's invitation by e-mail. Running again adds nothing.
        var job = env.OnboardingJob();
        Assert.True(await job.RunOnceAsync(ct) >= 1);
        Assert.Equal(0, await job.RunOnceAsync(ct));
        var invitation = env.LinkTokenSentTo(adminEmail);

        // The tenant's login page knows its name; an unknown sub-domain is a neutral 404.
        var portal = await env.BrowserAsync($"{code}.{TestEnvironment.Domain}");
        var page = await portal.GetJsonAsync("/api/v1/tenant");
        Assert.Equal("Integration Trading", page.GetProperty("nameEn").GetString());
        var nowhere = env.CreateClient(new() { BaseAddress = new Uri($"https://no-such-tenant.{TestEnvironment.Domain}") });
        Assert.Equal(HttpStatusCode.NotFound, (await nowhere.GetAsync("/api/v1/tenant", ct)).StatusCode);

        // The administrator accepts the invitation: a short password is refused, then the link sets the password once.
        Assert.Equal((422, "PASSWORD_WEAK"), await portal.PostProblemAsync("/api/v1/auth/invitation", new { token = invitation, password = "short" }));
        const string password = "a first administrator passphrase";
        await portal.PostOkAsync("/api/v1/auth/invitation", new { token = invitation, password });
        Assert.Equal((422, "LINK_INVALID"), await portal.PostProblemAsync("/api/v1/auth/invitation", new { token = invitation, password }));

        // First login: MFA enrolment, then the account.
        Assert.Equal((401, "INVALID_CREDENTIALS"), await portal.PostProblemAsync("/api/v1/auth/login", new { email = adminEmail, password = "wrong password here" }));
        var login = await portal.PostOkAsync("/api/v1/auth/login", new { email = adminEmail, password });
        Assert.Equal("MFA_ENROLMENT_REQUIRED", login.GetProperty("nextStep").GetString());
        Assert.Equal(HttpStatusCode.Unauthorized, (await portal.GetAsync("/api/v1/me", ct)).StatusCode);
        var enrol = await portal.PostOkAsync("/api/v1/auth/mfa/enrolment", new { });
        var secret = PlatformFixture.Base32Decode(enrol.GetProperty("secret").GetString()!);
        var done = await portal.PostOkAsync("/api/v1/auth/mfa/enrolment/complete", new { code = f.Code(secret) });
        var recovery = done.GetProperty("recoveryCodes").EnumerateArray().Select(e => e.GetString()!).ToList();
        Assert.Equal(10, recovery.Count);
        var account = await portal.GetJsonAsync("/api/v1/me");
        Assert.Equal(adminEmail, account.GetProperty("user").GetProperty("email").GetString());
        Assert.Equal("TRIAL", account.GetProperty("user").GetProperty("tenantStatus").GetString());
        Assert.Equal("ALL", account.GetProperty("user").GetProperty("companyScopeMode").GetString());
        Assert.Contains(account.GetProperty("permissions").EnumerateArray(), p => p.GetString() == "sec.user.manage");
        Assert.Contains(account.GetProperty("modules").EnumerateArray(), m => m.GetString() == "CORE");

        // Logout ends the session; the next login checks TOTP (a replayed step is refused), and a recovery code works once.
        Assert.Equal(HttpStatusCode.NoContent, (await portal.SendAsync(HttpMethod.Post, "/api/v1/auth/logout", new { })).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await portal.GetAsync("/api/v1/me", ct)).StatusCode);
        await portal.PostOkAsync("/api/v1/auth/login", new { email = adminEmail, password });
        Assert.Equal((401, "MFA_INVALID"), await portal.PostProblemAsync("/api/v1/auth/mfa", new { code = f.Code(secret) }));
        await portal.PostOkAsync("/api/v1/auth/mfa", new { code = f.NextCode(secret) });
        Assert.Equal(HttpStatusCode.OK, (await portal.GetAsync("/api/v1/me", ct)).StatusCode);
        await portal.SendAsync(HttpMethod.Post, "/api/v1/auth/logout", new { });
        await portal.PostOkAsync("/api/v1/auth/login", new { email = adminEmail, password });
        var byCode = await portal.PostOkAsync("/api/v1/auth/mfa", new { recoveryCode = recovery[0].ToLowerInvariant() });
        Assert.Equal(9, byCode.GetProperty("recoveryCodesRemaining").GetInt32());

        // Unsafe requests without the CSRF token, and portal endpoints on the operator host, are refused.
        var bare = env.CreateClient(new() { BaseAddress = new Uri($"https://{code}.{TestEnvironment.Domain}") });
        Assert.Equal((403, "CSRF_FAILED"), await bare.PostProblemAsync("/api/v1/auth/login", new { email = adminEmail, password }));
        Assert.Equal(HttpStatusCode.NotFound, (await panel.GetAsync("/api/v1/me", ct)).StatusCode);

    }
}
