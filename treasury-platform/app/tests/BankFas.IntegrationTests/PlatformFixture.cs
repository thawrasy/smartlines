using System.Text.Json;
using BankFas.Core.Security;

[assembly: AssemblyFixture(typeof(BankFas.IntegrationTests.PlatformFixture))]

namespace BankFas.IntegrationTests;

/// <summary>A tenant made for one test, with its first administrator signed in on <see cref="Portal"/>.</summary>
public sealed record TestTenant(string Code, HttpClient Portal, string AdminEmail, string AdminPassword, byte[] AdminSecret, IReadOnlyList<string> RecoveryCodes);

/// <summary>
/// One application and one operator for the whole test run, against the database tools/ci/app_ci.sh provides: the
/// first operator is invited the way the deployment does it (once per database), sets up through the link and signs
/// in. Tests ask it for fresh tenants. The tests run one at a time, since they share the clock of the TOTP codes.
/// </summary>
public sealed class PlatformFixture : IAsyncLifetime
{
    public const string OperatorEmail = "it-operator@test.invalid";
    public const string OperatorPassword = "a sturdy operator passphrase";
    public TestEnvironment Env { get; } = new();
    public HttpClient Panel { get; private set; } = null!;
    public byte[] OperatorSecret { get; private set; } = [];
    public string? Unavailable { get; private set; }

    public async ValueTask InitializeAsync()
    {
        if (string.IsNullOrEmpty(TestEnvironment.DbServer) || string.IsNullOrEmpty(TestEnvironment.Secrets))
        {
            Unavailable = "No test database: set BANKFAS_IT_SERVER and BANKFAS_IT_SECRETS (tools/ci/app_ci.sh).";
            return;
        }
        // After the browser tests (tools/ci/e2e.sh), their operator has invited this one; else this is the first.
        var handoff = Environment.GetEnvironmentVariable("BANKFAS_IT_OPERATOR_LINK_FILE");
        var link = !string.IsNullOrEmpty(handoff) && File.Exists(handoff)
            ? File.ReadAllText(handoff).Trim()
            : await TestEnvironment.BootstrapOperatorAsync(OperatorEmail);
        if (link is null)
        {
            Unavailable = "The database already has operators: deploy a fresh one (tools/ci/app_ci.sh).";
            return;
        }
        Panel = await Env.BrowserAsync(TestEnvironment.OperatorHost);
        var setup = await Panel.PostOkAsync("/api/v1/operator/auth/setup", new { token = link });
        OperatorSecret = Base32Decode(setup.GetProperty("secret").GetString()!);
        await Panel.PostOkAsync("/api/v1/operator/auth/setup/complete", new { token = link, password = OperatorPassword, code = Code(OperatorSecret) });
        await Panel.PostOkAsync("/api/v1/operator/auth/login", new { email = OperatorEmail, password = OperatorPassword });
        Env.Clock.NextStep();
        await Panel.PostOkAsync("/api/v1/operator/auth/mfa", new { code = Code(OperatorSecret) });
    }

    public ValueTask DisposeAsync()
    {
        Env.Dispose();
        return ValueTask.CompletedTask;
    }

    public void RequireDatabase()
    {
        if (Unavailable is null) return;
        if (Environment.GetEnvironmentVariable("BANKFAS_IT_REQUIRED") == "1") Assert.Fail(Unavailable);
        Assert.Skip(Unavailable);
    }

    /// <summary>The current TOTP code of a secret, a step after the last one used.</summary>
    public string NextCode(byte[] secret)
    {
        Env.Clock.NextStep();
        return Code(secret);
    }

    public string Code(byte[] secret) => Totp.Code(secret, Totp.StepAt(Env.Clock.Now));

    /// <summary>Creates a tenant through the panel, onboards it, and signs its first administrator in with MFA enrolled.</summary>
    public async Task<TestTenant> CreateTenantAsync(string? name = null)
    {
        RequireDatabase();
        var code = "ci-" + Guid.NewGuid().ToString("N")[..10];
        var adminEmail = $"admin@{code}.test.invalid";
        await Panel.PostOkAsync("/api/v1/operator/tenants", new
        {
            code, nameEn = name ?? "Integration Trading", nameAr = "شركة الاختبار", planCode = "STANDARD", homeCountryIso2 = "AE",
            timeZone = "Asia/Dubai", defaultLanguage = "en", adminEmail, adminDisplayName = "First Admin", mfaCode = NextCode(OperatorSecret),
        });
        var ct = TestContext.Current.CancellationToken;
        Assert.True(await Env.OnboardingJob().RunOnceAsync(ct) >= 1);
        var portal = await Env.BrowserAsync($"{code}.{TestEnvironment.Domain}");
        const string password = "a first administrator passphrase";
        await portal.PostOkAsync("/api/v1/auth/invitation", new { token = Env.LinkTokenSentTo(adminEmail), password });
        var secretAndCodes = await SignInFirstTimeAsync(portal, adminEmail, password);
        return new TestTenant(code, portal, adminEmail, password, secretAndCodes.Secret, secretAndCodes.Codes);
    }

    /// <summary>Signs a user in for the first time: password, then authenticator enrolment.</summary>
    public async Task<(byte[] Secret, IReadOnlyList<string> Codes)> SignInFirstTimeAsync(HttpClient portal, string email, string password, string? reenrolment = null)
    {
        await portal.PostOkAsync("/api/v1/auth/login", new { email, password });
        var enrol = await portal.PostOkAsync("/api/v1/auth/mfa/enrolment", new { reenrolmentToken = reenrolment });
        var secret = Base32Decode(enrol.GetProperty("secret").GetString()!);
        var done = await portal.PostOkAsync("/api/v1/auth/mfa/enrolment/complete", new { code = NextCode(secret), reenrolmentToken = reenrolment });
        return (secret, done.GetProperty("recoveryCodes").EnumerateArray().Select(e => e.GetString()!).ToList());
    }

    public async Task SignInAsync(HttpClient portal, string email, string password, byte[] secret)
    {
        await portal.PostOkAsync("/api/v1/auth/login", new { email, password });
        await portal.PostOkAsync("/api/v1/auth/mfa", new { code = NextCode(secret) });
    }

    public static byte[] Base32Decode(string text)
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

    public static string Id(JsonElement e) => e.GetProperty("id").GetString()!;
}

/// <summary>Every test class against the database is in this collection, so they run one at a time.</summary>
[CollectionDefinition("database")]
public sealed class DatabaseTests;
