using System.Security.Cryptography;
using BankFas.Core.Security;

namespace BankFas.Core.Tests.Security;

public class FileMasterKeysTests
{
    private static string Dir()
    {
        var d = Path.Combine(Path.GetTempPath(), "bankfas-mk-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(d);
        return d;
    }

    private static void Write(string dir, string name, byte[] key, UnixFileMode mode = UnixFileMode.UserRead)
    {
        var path = Path.Combine(dir, name);
        File.WriteAllText(path, Convert.ToBase64String(key));
        if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(path, mode);
    }

    [Fact]
    public void Keys_from_owner_only_files_wrap_and_unwrap_under_their_file_reference()
    {
        var dir = Dir();
        Write(dir, "2026-10.key", RandomNumberGenerator.GetBytes(32));
        Write(dir, "2027-01.key", RandomNumberGenerator.GetBytes(32));
        var keys = FileMasterKeys.Load(dir);
        Assert.Equal(["file:2026-10", "file:2027-01"], keys.Keys.Order(StringComparer.Ordinal));
        var wrapper = LocalKeyWrapper.FromFiles("file:2027-01", keys);
        var aad = EnvelopeAad.ForColumn(1, "sec.TenantKey", "WrappedKey", Guid.NewGuid());
        var wrapped = wrapper.Wrap(wrapper.CurrentMasterKeyRef, [1, 2, 3], aad);
        Assert.Equal([1, 2, 3], wrapper.Unwrap("file:2027-01", wrapped, aad));
        Assert.ThrowsAny<CryptographicException>(() => wrapper.Unwrap("file:2026-10", wrapped, aad));
        Assert.Throws<ArgumentException>(() => LocalKeyWrapper.FromFiles("file:missing", keys));
        Directory.Delete(dir, true);
    }

    [Fact]
    public void A_loose_file_a_wrong_length_or_an_empty_directory_is_refused()
    {
        var dir = Dir();
        Assert.Throws<InvalidOperationException>(() => FileMasterKeys.Load(dir));
        Assert.Throws<InvalidOperationException>(() => FileMasterKeys.Load(Path.Combine(dir, "none")));
        Write(dir, "short.key", new byte[16]);
        Assert.Throws<InvalidOperationException>(() => FileMasterKeys.Load(dir));
        File.Delete(Path.Combine(dir, "short.key"));
        if (!OperatingSystem.IsWindows())
        {
            Write(dir, "loose.key", RandomNumberGenerator.GetBytes(32), UnixFileMode.UserRead | UnixFileMode.GroupRead);
            Assert.Throws<InvalidOperationException>(() => FileMasterKeys.Load(dir));
        }
        Directory.Delete(dir, true);
    }
}
