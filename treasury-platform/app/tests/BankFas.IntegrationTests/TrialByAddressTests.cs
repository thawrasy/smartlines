namespace BankFas.IntegrationTests;

/// <summary>
/// The private trial without a domain (docs/62): the server's address serves one tenant's portal. Its invitation link
/// points at the address, its first administrator signs in there, and the same tenant answers on its sub-domain too;
/// the address does not open another tenant, and the operator panel stays on its own host.
/// </summary>
[Collection("database")]
public sealed class TrialByAddressTests(PlatformFixture f)
{
    [Fact]
    public async Task The_address_serves_its_tenant_and_its_links_point_there()
    {
        var t = await f.CreateTenantAsync(code: TestEnvironment.AddressTenant, host: TestEnvironment.Address);
        var mail = Directory.EnumerateFiles(f.Env.MailDir, "*.eml").Select(File.ReadAllText).Last(x => x.Contains("To: " + t.AdminEmail, StringComparison.Ordinal));
        Assert.Contains($"https://{TestEnvironment.Address}/invitation#token=", mail);

        // Signed in on the address: the portal is the tenant's.
        var me = (await t.Portal.GetJsonAsync("/api/v1/me")).GetRawText();
        Assert.Contains($"\"{TestEnvironment.AddressTenant}\"", me);

        // Another tenant still answers on its sub-domain only; an unknown address is nobody's.
        var other = await f.CreateTenantAsync();
        Assert.Equal(200, (int)(await other.Portal.GetAsync("/api/v1/me", TestContext.Current.CancellationToken)).StatusCode);
        var stranger = f.Env.CreateClient(new Microsoft.AspNetCore.Mvc.Testing.WebApplicationFactoryClientOptions { BaseAddress = new Uri("https://127.0.0.10") });
        Assert.Equal(404, (int)(await stranger.GetAsync("/api/v1/csrf", TestContext.Current.CancellationToken)).StatusCode);
    }
}
