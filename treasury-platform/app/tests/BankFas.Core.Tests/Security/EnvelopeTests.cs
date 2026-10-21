using System.Security.Cryptography;
using BankFas.Core.Security;

namespace BankFas.Core.Tests.Security;

public class EnvelopeTests
{
    [Fact]
    public void An_envelope_opens_with_its_key_and_associated_data_only()
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var row = Guid.NewGuid();
        var aad = EnvelopeAad.ForColumn(7, "sec.AppUser", "MfaSecretEnc", row);
        var secret = Totp.NewSecret();
        var sealedValue = Envelope.Seal(key, secret, aad);

        Assert.Equal(Envelope.Overhead + secret.Length, sealedValue.Length);
        Assert.True(sealedValue.Length >= 29);                     // the column check of an encrypted column
        Assert.Equal(0x01, sealedValue[0]);
        Assert.Equal(secret, Envelope.Open(key, sealedValue, aad));
        Assert.ThrowsAny<CryptographicException>(() => Envelope.Open(key, sealedValue, EnvelopeAad.ForColumn(8, "sec.AppUser", "MfaSecretEnc", row)));
        Assert.ThrowsAny<CryptographicException>(() => Envelope.Open(key, sealedValue, EnvelopeAad.ForColumn(7, "sec.AppUser", "MfaSecretEnc", Guid.NewGuid())));
        Assert.ThrowsAny<CryptographicException>(() => Envelope.Open(RandomNumberGenerator.GetBytes(32), sealedValue, aad));
        sealedValue[^1] ^= 1;
        Assert.ThrowsAny<CryptographicException>(() => Envelope.Open(key, sealedValue, aad));
    }

    [Fact]
    public void Two_envelopes_of_one_value_differ()
    {
        var key = RandomNumberGenerator.GetBytes(32);
        var aad = EnvelopeAad.ForTenantKey(1, "DATA", 1);
        Assert.NotEqual(Envelope.Seal(key, [1, 2, 3], aad), Envelope.Seal(key, [1, 2, 3], aad));
    }

    [Fact]
    public void Associated_data_is_length_prefixed()
    {
        var row = Guid.Parse("00112233-4455-6677-8899-aabbccddeeff");
        var aad = EnvelopeAad.ForColumn(0x01020304, "ab", "c", row);
        Assert.Equal(Convert.FromHexString("01020304" + "0002" + "6162" + "0001" + "63" + "00112233445566778899aabbccddeeff"), aad);
    }

    [Fact]
    public void The_local_wrapper_wraps_under_its_current_key_and_refuses_unknown_ones()
    {
        var wrapper = new LocalKeyWrapper("local:test/2", new Dictionary<string, byte[]>
        {
            ["local:test/1"] = RandomNumberGenerator.GetBytes(32),
            ["local:test/2"] = RandomNumberGenerator.GetBytes(32),
        });
        var tenantKey = RandomNumberGenerator.GetBytes(32);
        var aad = EnvelopeAad.ForTenantKey(5, "DATA", 1);
        var wrapped = wrapper.Wrap(wrapper.CurrentMasterKeyRef, tenantKey, aad);
        Assert.Equal(tenantKey, wrapper.Unwrap("local:test/2", wrapped, aad));
        Assert.ThrowsAny<CryptographicException>(() => wrapper.Unwrap("local:test/1", wrapped, aad));
        Assert.ThrowsAny<CryptographicException>(() => wrapper.Unwrap("kms:other/1", wrapped, aad));
        Assert.Throws<ArgumentException>(() => new LocalKeyWrapper("kms:x", new Dictionary<string, byte[]> { ["kms:x"] = new byte[32] }));
    }
}
