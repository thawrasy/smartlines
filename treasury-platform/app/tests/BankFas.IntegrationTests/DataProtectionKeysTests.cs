using System.Security.Cryptography;
using BankFas.Api.Infrastructure;
using BankFas.Core.Security;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Hosting.Internal;

namespace BankFas.IntegrationTests;

/// <summary>
/// The data protection keys outlive a restart (docs/53): a value protected by one process opens in the next one that
/// reads the same directory with the same master key; the stored key is wrapped, so the directory alone or another
/// master key opens nothing; and a production host without the directory does not start. No database is needed.
/// </summary>
public sealed class DataProtectionKeysTests
{
    private static ServiceProvider Provider(string? dir, byte[] master, string environment = "Production")
    {
        var services = new ServiceCollection();
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["DataProtection:KeysDirectory"] = dir }).Build();
        services.AddSingleton<IKeyWrapper>(LocalKeyWrapper.FromFiles("file:k1", new Dictionary<string, byte[]> { ["file:k1"] = master }));
        DataProtectionKeys.Configure(services.AddDataProtection().SetApplicationName("BankFas"), config, new HostingEnvironment { EnvironmentName = environment });
        return services.BuildServiceProvider();
    }

    [Fact]
    public void A_protected_value_opens_after_a_restart_and_the_stored_key_is_wrapped()
    {
        var dir = Path.Combine(Path.GetTempPath(), "bankfas-dp-" + Guid.NewGuid().ToString("N"));
        var master = RandomNumberGenerator.GetBytes(32);
        string token;
        using (var first = Provider(dir, master))
            token = first.GetRequiredService<IDataProtectionProvider>().CreateProtector("BankFas.ItemRef").Protect("item 42");
        var stored = string.Concat(Directory.GetFiles(dir, "*.xml").Select(File.ReadAllText));
        Assert.Contains("masterKeyWrapped", stored, StringComparison.Ordinal);
        Assert.DoesNotContain("<value>", stored, StringComparison.Ordinal);          // the key itself, in the clear, is a <value>
        using (var second = Provider(dir, master))
            Assert.Equal("item 42", second.GetRequiredService<IDataProtectionProvider>().CreateProtector("BankFas.ItemRef").Unprotect(token));
        using (var other = Provider(dir, RandomNumberGenerator.GetBytes(32)))
            Assert.ThrowsAny<CryptographicException>(() => other.GetRequiredService<IDataProtectionProvider>().CreateProtector("BankFas.ItemRef").Unprotect(token));
        Directory.Delete(dir, true);
    }

    [Fact]
    public void A_production_host_needs_the_directory()
    {
        Assert.Throws<InvalidOperationException>(() => Provider(null, RandomNumberGenerator.GetBytes(32)));
        using var testing = Provider(null, RandomNumberGenerator.GetBytes(32), "Testing");
    }
}
