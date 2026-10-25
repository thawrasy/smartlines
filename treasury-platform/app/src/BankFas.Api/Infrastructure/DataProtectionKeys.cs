using System.Text;
using System.Xml.Linq;
using BankFas.Core.Security;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.DataProtection.KeyManagement;
using Microsoft.AspNetCore.DataProtection.XmlEncryption;
using Microsoft.Extensions.Options;

namespace BankFas.Api.Infrastructure;

/// <summary>
/// The keys of ASP.NET data protection (the opaque references, the list cursors and the pending enrolment secrets)
/// outlive a restart (docs/53): they are kept in <c>DataProtection:KeysDirectory</c> on the host, each wrapped with the
/// platform master key (<see cref="IKeyWrapper"/>), so the directory alone opens nothing. Without the setting they stay
/// in memory, which development and the tests accept and a production host refuses.
/// </summary>
public static class DataProtectionKeys
{
    private static readonly byte[] Aad = Encoding.UTF8.GetBytes("BankFas.DataProtection.Key");

    public static void Configure(IDataProtectionBuilder builder, IConfiguration config, IHostEnvironment env)
    {
        ArgumentNullException.ThrowIfNull(builder);
        ArgumentNullException.ThrowIfNull(config);
        ArgumentNullException.ThrowIfNull(env);
        var dir = config["DataProtection:KeysDirectory"];
        if (string.IsNullOrWhiteSpace(dir))
        {
            if (!env.IsDevelopment() && !env.IsEnvironment("Testing"))
                throw new InvalidOperationException("Set DataProtection:KeysDirectory: the data protection keys must outlive a restart (docs/53).");
            return;
        }
        builder.PersistKeysToFileSystem(new DirectoryInfo(dir));
        builder.Services.AddSingleton<IConfigureOptions<KeyManagementOptions>>(sp =>
            new ConfigureOptions<KeyManagementOptions>(o => o.XmlEncryptor = new Encryptor(sp.GetRequiredService<IKeyWrapper>())));
    }

    private sealed class Encryptor(IKeyWrapper wrapper) : IXmlEncryptor
    {
        public EncryptedXmlInfo Encrypt(XElement plaintextElement)
        {
            ArgumentNullException.ThrowIfNull(plaintextElement);
            var reference = wrapper.CurrentMasterKeyRef;
            var wrapped = wrapper.Wrap(reference, Encoding.UTF8.GetBytes(plaintextElement.ToString(SaveOptions.DisableFormatting)), Aad);
            return new EncryptedXmlInfo(new XElement("masterKeyWrapped", new XAttribute("ref", reference), Convert.ToBase64String(wrapped)), typeof(Decryptor));
        }
    }

    /// <summary>Activated by data protection with the service provider when a stored key is read.</summary>
    private sealed class Decryptor(IServiceProvider services) : IXmlDecryptor
    {
        public XElement Decrypt(XElement encryptedElement)
        {
            ArgumentNullException.ThrowIfNull(encryptedElement);
            var wrapper = services.GetRequiredService<IKeyWrapper>();
            var reference = (string?)encryptedElement.Attribute("ref") ?? throw new InvalidOperationException("A stored data protection key names no master key.");
            return XElement.Parse(Encoding.UTF8.GetString(wrapper.Unwrap(reference, Convert.FromBase64String(encryptedElement.Value), Aad)));
        }
    }
}
