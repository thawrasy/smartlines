using BankFas.Core.Security;

namespace BankFas.Core.Tests.Security;

public sealed class BreachedPasswordsTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "bankfas-breached-" + Guid.NewGuid().ToString("N"));

    public BreachedPasswordsTests()
    {
        Directory.CreateDirectory(_dir);
        // The published SHA-1 of "password", in the downloader's layout: the five-digit prefix names the file.
        File.WriteAllText(Path.Combine(_dir, "5BAA6.txt"), "1E4C9B93F3F0682250B6CF8331B7EE68FD7:1\r\n1E4C9B93F3F0682250B6CF8331B7EE68FD8:9659365\r\n");
    }

    [Fact]
    public void The_hash_is_the_upper_case_sha1_of_the_utf8_bytes() =>
        Assert.Equal("5BAA61E4C9B93F3F0682250B6CF8331B7EE68FD8", BreachedPasswords.Sha1Hex("password"));

    [Fact]
    public void A_listed_password_is_found_and_a_neighbour_is_not()
    {
        var list = new BreachedPasswords(_dir, allowMissingRanges: true);
        Assert.True(list.Contains("password"));
        Assert.False(list.Contains("Password"));
    }

    [Fact]
    public void The_nfkc_form_is_checked_too()
    {
        // A full-width "password" normalises to the listed one.
        var list = new BreachedPasswords(_dir, allowMissingRanges: true);
        Assert.True(list.Contains("ｐａｓｓｗｏｒｄ"));
    }

    [Fact]
    public void A_missing_range_is_a_deployment_error_unless_allowed()
    {
        Assert.Throws<BreachedListUnavailableException>(() => new BreachedPasswords(_dir).Contains("a password of another range"));
        Assert.False(new BreachedPasswords(_dir, allowMissingRanges: true).Contains("a password of another range"));
    }

    [Fact]
    public void A_missing_directory_is_a_deployment_error()
    {
        Assert.Throws<BreachedListUnavailableException>(() => new BreachedPasswords(Path.Combine(_dir, "absent")));
        Assert.Throws<BreachedListUnavailableException>(() => new BreachedPasswords(""));
    }

    public void Dispose() => Directory.Delete(_dir, recursive: true);
}
