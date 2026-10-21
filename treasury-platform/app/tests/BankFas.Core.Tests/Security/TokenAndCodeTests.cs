using System.Security.Cryptography;
using System.Text.Json;
using BankFas.Core.Security;

namespace BankFas.Core.Tests.Security;

public class TokenAndCodeTests
{
    [Fact]
    public void A_token_round_trips_in_43_base64url_characters()
    {
        var token = SecureTokens.NewToken();
        var text = Base64Url.Encode(token);
        Assert.Equal(43, text.Length);
        Assert.Equal(token, SecureTokens.Parse(text));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("short")]
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA+")]     // a base64 character outside base64url
    [InlineData("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")]   // 36 bytes
    public void Anything_but_32_bytes_of_base64url_is_not_a_token(string? text)
    {
        Assert.Null(SecureTokens.Parse(text));
    }

    [Fact]
    public void Ten_distinct_recovery_codes_in_four_groups()
    {
        var codes = RecoveryCodes.Generate();
        Assert.Equal(10, codes.Distinct().Count());
        Assert.All(codes, c => Assert.Matches("^[0-9A-HJKMNP-TV-Z]{4}(-[0-9A-HJKMNP-TV-Z]{4}){3}$", c));
    }

    [Fact]
    public void A_typed_recovery_code_is_normalised_before_it_is_hashed()
    {
        Assert.Equal("0123ABCD1111WXYZ", RecoveryCodes.Normalise(" o123-abcd-iIlL-wxyz "));
        Assert.Null(RecoveryCodes.Normalise("0123-ABCD-UUUU-WXYZ"));   // U is not in the alphabet
        Assert.Null(RecoveryCodes.Normalise("0123-ABCD"));
        Assert.Equal(SHA256.HashData("0123ABCD1111WXYZ"u8), RecoveryCodes.Hash("0123ABCD1111WXYZ"));
    }

    [Fact]
    public void The_hashes_json_is_what_the_enrolment_procedure_takes()
    {
        var codes = RecoveryCodes.Generate();
        var hashes = JsonSerializer.Deserialize<string[]>(RecoveryCodes.HashesJson(codes))!;
        Assert.Equal(10, hashes.Length);
        Assert.All(hashes, h => Assert.Matches("^[0-9a-f]{64}$", h));
        Assert.Equal(Convert.ToHexStringLower(RecoveryCodes.Hash(RecoveryCodes.Normalise(codes[0])!)), hashes[0]);
    }
}
