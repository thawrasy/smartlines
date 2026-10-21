using System.Text;
using BankFas.Core.Security;

namespace BankFas.Core.Tests.Security;

public class TotpTests
{
    private static readonly byte[] Rfc6238Secret = Encoding.ASCII.GetBytes("12345678901234567890");

    // RFC 6238 appendix B (SHA-1), the last six of the eight digits
    [Theory]
    [InlineData(59L, "287082")]
    [InlineData(1111111109L, "081804")]
    [InlineData(1111111111L, "050471")]
    [InlineData(1234567890L, "005924")]
    [InlineData(2000000000L, "279037")]
    [InlineData(20000000000L, "353130")]
    public void Codes_match_the_rfc_vectors(long unixSeconds, string code)
    {
        Assert.Equal(code, Totp.Code(Rfc6238Secret, Totp.StepAt(DateTimeOffset.FromUnixTimeSeconds(unixSeconds))));
    }

    [Fact]
    public void Verify_accepts_one_step_either_side_and_never_a_step_already_used()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var step = Totp.StepAt(now);
        var secret = Totp.NewSecret();
        Assert.Equal(step, Totp.Verify(secret, Totp.Code(secret, step), now, null));
        Assert.Equal(step - 1, Totp.Verify(secret, Totp.Code(secret, step - 1), now, null));
        Assert.Equal(step + 1, Totp.Verify(secret, Totp.Code(secret, step + 1), now, step));
        Assert.Null(Totp.Verify(secret, Totp.Code(secret, step - 2), now, null));
        Assert.Null(Totp.Verify(secret, Totp.Code(secret, step), now, step));         // a replay
        Assert.Null(Totp.Verify(secret, "12345", now, null));
        Assert.Null(Totp.Verify(secret, "abcdef", now, null));
    }

    [Fact]
    public void Base32_follows_rfc_4648_without_padding()
    {
        Assert.Equal("MZXW6YTBOI", Base32.Encode("foobar"u8));
        Assert.Equal("MY", Base32.Encode("f"u8));
    }

    [Fact]
    public void The_enrolment_uri_names_issuer_account_and_parameters()
    {
        var uri = Totp.EnrolmentUri("foobar"u8, "BankFas", "acme:user@example.com").ToString();
        Assert.StartsWith("otpauth://totp/BankFas:acme%3Auser%40example.com?secret=MZXW6YTBOI&issuer=BankFas", uri, StringComparison.Ordinal);
        Assert.EndsWith("&algorithm=SHA1&digits=6&period=30", uri, StringComparison.Ordinal);
    }
}
