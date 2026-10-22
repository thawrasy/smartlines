using System.Security.Cryptography;
using BankFas.Core.Banking;

namespace BankFas.Core.Tests.Security;

public class BankAccountNumbersTests
{
    [Theory]
    [InlineData("SA50 9900 0000 0000 0012 3456", null)]   // AC-ACC-1
    [InlineData("SA50 9900 0000 0000 0012 7518", "CHECKSUM")]
    [InlineData("SA50 9900 0000 0000 0012 345", "LENGTH")]
    [InlineData("GB82 WEST 1234 5698 7654 32", null)]
    [InlineData("AE07 0331 2345 6789 0123 456", null)]
    [InlineData("5099 0000 0000 0012 3456", "FORMAT")]
    public void An_iban_has_its_country_length_and_passes_mod_97(string iban, string? problem) =>
        Assert.Equal(problem, BankAccountNumbers.IbanProblem(BankAccountNumbers.Normalize(iban)));

    [Fact]
    public void Separators_do_not_make_another_number()
    {
        Assert.Equal("1234567", BankAccountNumbers.Normalize("1234-567"));
        Assert.Equal("1234567", BankAccountNumbers.Normalize(" 12 34 567 "));
        Assert.Equal("SA5099000000000000123456", BankAccountNumbers.Normalize("sa50-9900 0000 0000 0012 3456"));
        var key = RandomNumberGenerator.GetBytes(32);
        Assert.Equal(BankAccountNumbers.BlindIndex(key, "ACCOUNT", BankAccountNumbers.Normalize("1234-567")),
            BankAccountNumbers.BlindIndex(key, "ACCOUNT", BankAccountNumbers.Normalize("1234 567")));
        Assert.NotEqual(BankAccountNumbers.BlindIndex(key, "ACCOUNT", "1234567"), BankAccountNumbers.BlindIndex(key, "IBAN", "1234567"));
    }

    [Fact]
    public void The_mask_shows_the_country_and_the_last_four()
    {
        Assert.Equal("SA•• •••• •••• •••• •••• 3456", BankAccountNumbers.MaskIban("SA5099000000000000123456"));   // BR-ACC-016
        Assert.Equal("•••• 4567", BankAccountNumbers.MaskNumber("1234567"));
        var longest = BankAccountNumbers.MaskIban("LC55HEMM000100010012001200023015");
        Assert.True(longest.Length <= 32);
        Assert.EndsWith("3015", longest, StringComparison.Ordinal);
    }
}
