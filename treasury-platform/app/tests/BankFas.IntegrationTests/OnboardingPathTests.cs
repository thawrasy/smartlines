using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using BankFas.Core.Security;

namespace BankFas.IntegrationTests;

/// <summary>
/// The exit check of S0 (AC-PLT-5, DOC-F05 section 7): an operator sets up the account from the deployment's link,
/// signs in with TOTP and creates a tenant; the onboarding job creates its keys and roles and invites the first
/// administrator; the administrator accepts, enrols MFA, signs in, and sees the account. Then the refusals.
/// </summary>
public sealed class OnboardingPathTests
{
    [Fact]
    public async Task Operator_creates_a_tenant_whose_first_administrator_signs_in_with_mfa()
    {
        TestEnvironment.SkipUnlessConfigured();
        using var env = new TestEnvironment();
        var ct = TestContext.Current.CancellationToken;
        const string operatorEmail = "it-operator@test.invalid";
        var setupLink = await TestEnvironment.BootstrapOperatorAsync(operatorEmail);
        if (setupLink is null)
        {
            if (Environment.GetEnvironmentVariable("BANKFAS_IT_REQUIRED") == "1") Assert.Fail("The database already has operators: deploy a fresh one.");
            Assert.Skip("The database already has operators: deploy a fresh one (tools/ci/app_ci.sh).");
        }

        // The operator sets up password and authenticator through the link, then signs in.
        var panel = await env.BrowserAsync(TestEnvironment.OperatorHost);
        var setup = await panel.PostOkAsync("/api/v1/operator/auth/setup", new { token = setupLink });
        var opSecret = Base32Decode(setup.GetProperty("secret").GetString()!);
        const string opPassword = "a sturdy operator passphrase";
        await panel.PostOkAsync("/api/v1/operator/auth/setup/complete", new { token = setupLink, password = opPassword, code = CodeNow(env, opSecret) });
        Assert.Equal(HttpStatusCode.Unauthorized, (await panel.GetAsync("/api/v1/operator/me", ct)).StatusCode);
        await panel.PostOkAsync("/api/v1/operator/auth/login", new { email = operatorEmail, password = opPassword });
        Assert.Equal(401, (await panel.PostProblemAsync("/api/v1/operator/auth/mfa", new { code = "000000" })).Status);
        env.Clock.NextStep();
        await panel.PostOkAsync("/api/v1/operator/auth/mfa", new { code = CodeNow(env, opSecret) });
        var me = await panel.GetFromJsonAsync<JsonElement>("/api/v1/operator/me", ct);
        Assert.Equal("OPERATOR_ADMIN", me.GetProperty("role").GetString());

        // Creating a tenant takes a fresh code (step-up); without one it is refused.
        var code = "it" + Guid.NewGuid().ToString("N")[..8];
        var adminEmail = $"admin@{code}.test.invalid";
        var tenantBody = new
        {
            code, nameEn = "Integration Trading", nameAr = "شركة الاختبار", planCode = "STANDARD", homeCountryIso2 = "AE",
            timeZone = "Asia/Dubai", defaultLanguage = "en", adminEmail, adminDisplayName = "First Admin", mfaCode = "000000",
        };
        Assert.Equal((403, "STEP_UP_REQUIRED"), await panel.PostProblemAsync("/api/v1/operator/tenants", tenantBody));
        env.Clock.NextStep();
        var created = await panel.PostOkAsync("/api/v1/operator/tenants", tenantBody with { mfaCode = CodeNow(env, opSecret) });
        Assert.Equal("TRIAL", created.GetProperty("status").GetString());
        var list = await panel.GetFromJsonAsync<JsonElement>("/api/v1/operator/tenants", ct);
        Assert.Contains(list.GetProperty("items").EnumerateArray(), t => t.GetProperty("code").GetString() == code);

        // The worker onboards it: keys, roles, the first administrator's invitation by e-mail. Running again adds nothing.
        var job = env.OnboardingJob();
        Assert.True(await job.RunOnceAsync(ct) >= 1);
        Assert.Equal(0, await job.RunOnceAsync(ct));
        var invitation = env.LinkTokenSentTo(adminEmail);

        // The tenant's login page knows its name; an unknown sub-domain is a neutral 404.
        var portal = await env.BrowserAsync($"{code}.{TestEnvironment.Domain}");
        var page = await portal.GetFromJsonAsync<JsonElement>("/api/v1/tenant", ct);
        Assert.Equal("Integration Trading", page.GetProperty("nameEn").GetString());
        var nowhere = env.CreateClient(new() { BaseAddress = new Uri($"https://no-such-tenant.{TestEnvironment.Domain}") });
        Assert.Equal(HttpStatusCode.NotFound, (await nowhere.GetAsync("/api/v1/tenant", ct)).StatusCode);

        // The administrator accepts the invitation: a short password is refused, then the link sets the password once.
        Assert.Equal((422, "PASSWORD_WEAK"), await portal.PostProblemAsync("/api/v1/auth/invitation", new { token = invitation, password = "short" }));
        const string password = "correct horse battery staple";
        await portal.PostOkAsync("/api/v1/auth/invitation", new { token = invitation, password });
        Assert.Equal((422, "LINK_INVALID"), await portal.PostProblemAsync("/api/v1/auth/invitation", new { token = invitation, password }));

        // First login: MFA enrolment, then the account.
        Assert.Equal((401, "INVALID_CREDENTIALS"), await portal.PostProblemAsync("/api/v1/auth/login", new { email = adminEmail, password = "wrong password here" }));
        var login = await portal.PostOkAsync("/api/v1/auth/login", new { email = adminEmail, password });
        Assert.Equal("MFA_ENROLMENT_REQUIRED", login.GetProperty("nextStep").GetString());
        Assert.Equal(HttpStatusCode.Unauthorized, (await portal.GetAsync("/api/v1/me", ct)).StatusCode);
        var enrol = await portal.PostOkAsync("/api/v1/auth/mfa/enrolment", new { });
        var secret = Base32Decode(enrol.GetProperty("secret").GetString()!);
        var done = await portal.PostOkAsync("/api/v1/auth/mfa/enrolment/complete", new { code = CodeNow(env, secret) });
        var recovery = done.GetProperty("recoveryCodes").EnumerateArray().Select(e => e.GetString()!).ToList();
        Assert.Equal(10, recovery.Count);
        var account = await portal.GetFromJsonAsync<JsonElement>("/api/v1/me", ct);
        Assert.Equal(adminEmail, account.GetProperty("user").GetProperty("email").GetString());
        Assert.Equal("TRIAL", account.GetProperty("user").GetProperty("tenantStatus").GetString());
        Assert.Equal("ALL", account.GetProperty("user").GetProperty("companyScopeMode").GetString());
        Assert.Contains(account.GetProperty("permissions").EnumerateArray(), p => p.GetString() == "sec.user.manage");
        Assert.Contains(account.GetProperty("modules").EnumerateArray(), m => m.GetString() == "CORE");

        // Logout ends the session; the next login checks TOTP (a replayed step is refused), and a recovery code works once.
        Assert.Equal(HttpStatusCode.NoContent, (await portal.PostAsJsonAsync("/api/v1/auth/logout", new { }, ct)).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await portal.GetAsync("/api/v1/me", ct)).StatusCode);
        await portal.PostOkAsync("/api/v1/auth/login", new { email = adminEmail, password });
        Assert.Equal((401, "MFA_INVALID"), await portal.PostProblemAsync("/api/v1/auth/mfa", new { code = CodeNow(env, secret) }));
        env.Clock.NextStep();
        await portal.PostOkAsync("/api/v1/auth/mfa", new { code = CodeNow(env, secret) });
        Assert.Equal(HttpStatusCode.OK, (await portal.GetAsync("/api/v1/me", ct)).StatusCode);
        await portal.PostAsJsonAsync("/api/v1/auth/logout", new { }, ct);
        await portal.PostOkAsync("/api/v1/auth/login", new { email = adminEmail, password });
        var byCode = await portal.PostOkAsync("/api/v1/auth/mfa", new { recoveryCode = recovery[0].ToLowerInvariant() });
        Assert.Equal(9, byCode.GetProperty("recoveryCodesRemaining").GetInt32());

        // Unsafe requests without the CSRF token, and portal endpoints on the operator host, are refused.
        var bare = env.CreateClient(new() { BaseAddress = new Uri($"https://{code}.{TestEnvironment.Domain}") });
        Assert.Equal((403, "CSRF_FAILED"), await bare.PostProblemAsync("/api/v1/auth/login", new { email = adminEmail, password }));
        Assert.Equal(HttpStatusCode.NotFound, (await panel.GetAsync("/api/v1/me", ct)).StatusCode);
    }

    private static string CodeNow(TestEnvironment env, byte[] secret) => Totp.Code(secret, Totp.StepAt(env.Clock.Now));

    private static byte[] Base32Decode(string text)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
        var bytes = new List<byte>();
        int buffer = 0, bits = 0;
        foreach (var c in text)
        {
            buffer = (buffer << 5) | alphabet.IndexOf(c, StringComparison.Ordinal);
            bits += 5;
            if (bits >= 8) { bytes.Add((byte)(buffer >> (bits - 8))); bits -= 8; }
        }
        return [.. bytes];
    }
}
