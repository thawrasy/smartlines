using System.Security.Cryptography;
using System.Text;

namespace BankFas.Core.Security;

/// <summary>
/// The list of leaked passwords (DOC-S04 section 4, DQ-S04-1): the published SHA-1 hashes, split by their first five
/// hex digits as for k-anonymity, downloaded to the application server and searched there, so no part of a password
/// leaves it. A directory holds one file per prefix, <c>XXXXX.txt</c>, of lines <c>SUFFIX:COUNT</c> (the 35 other hex
/// digits, upper case), which is the layout of the published downloader. A missing directory or range file is a
/// deployment error: the password is refused, never let through unchecked.
/// </summary>
public sealed class BreachedPasswords
{
    private readonly string _directory;
    private readonly bool _allowMissingRanges;

    /// <param name="directory">The directory of range files.</param>
    /// <param name="allowMissingRanges">A missing range file reads as an empty range; for the small lists of tests only.</param>
    public BreachedPasswords(string directory, bool allowMissingRanges = false)
    {
        if (string.IsNullOrWhiteSpace(directory) || !Directory.Exists(directory))
            throw new BreachedListUnavailableException($"The leaked-password list is not at {directory} (DQ-S04-1).");
        _directory = directory;
        _allowMissingRanges = allowMissingRanges;
    }

    /// <summary>Whether the password, as typed or in its NFKC form, is on the list.</summary>
    public bool Contains(string password)
    {
        ArgumentNullException.ThrowIfNull(password);
        var normalised = PasswordHasher.Normalise(password);
        return InRange(Sha1Hex(password)) || (normalised != password && InRange(Sha1Hex(normalised)));
    }

    private bool InRange(string hash)
    {
        var path = Path.Combine(_directory, hash[..5] + ".txt");
        if (!File.Exists(path))
        {
            if (_allowMissingRanges) return false;
            throw new BreachedListUnavailableException($"The leaked-password list has no range {hash[..5]} (DQ-S04-1).");
        }
        var suffix = hash.AsSpan(5);
        foreach (var line in File.ReadLines(path))
        {
            var colon = line.IndexOf(':', StringComparison.Ordinal);
            var candidate = (colon < 0 ? line : line[..colon]).AsSpan().Trim();
            if (candidate.Equals(suffix, StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    /// <summary>The upper-case hex SHA-1 of the UTF-8 bytes, as the published list writes it.</summary>
    public static string Sha1Hex(string value)
    {
#pragma warning disable CA5350 // SHA-1 is the hash of the published list, used here for a lookup, not for security.
        return Convert.ToHexString(SHA1.HashData(Encoding.UTF8.GetBytes(value)));
#pragma warning restore CA5350
    }
}

/// <summary>The leaked-password list is missing or incomplete: a deployment error.</summary>
public sealed class BreachedListUnavailableException : Exception
{
    public BreachedListUnavailableException() { }
    public BreachedListUnavailableException(string message) : base(message) { }
    public BreachedListUnavailableException(string message, Exception innerException) : base(message, innerException) { }
}
