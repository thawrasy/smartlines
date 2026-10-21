using BankFas.Core.Security;

namespace BankFas.Core.Tests.Security;

public class PasswordHasherTests
{
    // Vectors from the reference implementation of Argon2 (argon2-cffi 25.1, low_level.hash_secret, type ID).
    [Theory]
    [InlineData("correct horse battery staple", "$argon2id$v=19$m=65536,t=3,p=4$QmFua0Zhc1NhbHQxNmJ5dA",
        "$argon2id$v=19$m=65536,t=3,p=4$QmFua0Zhc1NhbHQxNmJ5dA$31OipoMzfLRmvcjEUobOQIiP61De1846lYqYbaT8gEY")]
    // The password is hashed in NFKC: "ﬁ" (U+FB01) becomes "fi" (DOC-S04 section 4)
    [InlineData("Pässwörd ﬁ", "$argon2id$v=19$m=65536,t=3,p=4$AAECAwQFBgcICQoLDA0ODw",
        "$argon2id$v=19$m=65536,t=3,p=4$AAECAwQFBgcICQoLDA0ODw$9wD3EeA+2lwG7DNTA2C/x+7xHvG3sTS2EQRaL549HpY")]
    public void Hash_with_stored_parameters_matches_the_reference_implementation(string password, string stored, string expected)
    {
        Assert.Equal(expected, PasswordHasher.HashWithStoredParameters(password, stored));
    }

    [Fact]
    public void A_new_hash_follows_the_policy_and_verifies_with_its_own_parameters()
    {
        var phc = PasswordHasher.HashNew("a long enough passphrase");
        Assert.StartsWith("$argon2id$v=19$m=65536,t=3,p=4$", phc, StringComparison.Ordinal);
        Assert.DoesNotContain("=", phc[phc.IndexOf("$m", StringComparison.Ordinal)..].Replace("m=", "").Replace("t=", "").Replace("p=", ""), StringComparison.Ordinal);
        var stored = phc[..phc.LastIndexOf('$')];
        Assert.Equal(phc, PasswordHasher.HashWithStoredParameters("a long enough passphrase", stored));
        Assert.NotEqual(phc, PasswordHasher.HashWithStoredParameters("another passphrase", stored));
        Assert.NotEqual(phc, PasswordHasher.HashNew("a long enough passphrase"));   // a fresh salt each time
    }

    [Theory]
    [InlineData("$argon2i$v=19$m=65536,t=3,p=4$QmFua0Zhc1NhbHQxNmJ5dA")]
    [InlineData("$argon2id$v=19$m=1024,t=3,p=4$QmFua0Zhc1NhbHQxNmJ5dA")]       // too little memory
    [InlineData("$argon2id$v=19$m=65536,t=99,p=4$QmFua0Zhc1NhbHQxNmJ5dA")]
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4,x=1$QmFua0Zhc1NhbHQxNmJ5dA")]
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$QmFua0Zhc1NhbHQxNmJ5dA==")]
    [InlineData("$argon2id$v=19$m=65536,t=3,p=4$QmFua0Zhc1NhbHQxNmJ5dA$extra")]
    public void Parameters_this_application_did_not_write_are_refused(string stored)
    {
        Assert.Null(PasswordHasher.HashWithStoredParameters("x", stored));
    }

    [Fact]
    public void An_unknown_user_costs_a_full_hash()
    {
        Assert.StartsWith("$argon2id$v=19$m=65536,t=3,p=4$", PasswordHasher.HashForUnknownUser("guess"), StringComparison.Ordinal);
    }
}
