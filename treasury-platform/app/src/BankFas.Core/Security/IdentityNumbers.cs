using System.Security.Cryptography;
using System.Text;

namespace BankFas.Core.Security;

/// <summary>
/// Identity numbers (FR-PTY-006, BR-PTY-002, BR-PTY-008): the normal form (NFKC, Arabic-Indic digits as ASCII, only
/// letters and digits, upper case), the mask that shows the last four, and the blind index: HMAC-SHA256 with the
/// tenant's BLIND_INDEX key over the kind, the issuing country and the normal form, so an exact search finds a number
/// without decrypting any.
/// </summary>
public static class IdentityNumbers
{
    public static string Normalize(string number)
    {
        ArgumentNullException.ThrowIfNull(number);
        var b = new StringBuilder(number.Length);
        foreach (var ch in number.Normalize(NormalizationForm.FormKC))
        {
            if (ch is >= '٠' and <= '٩') b.Append((char)('0' + (ch - '٠')));
            else if (ch is >= '۰' and <= '۹') b.Append((char)('0' + (ch - '۰')));
            else if (char.IsAsciiLetterOrDigit(ch)) b.Append(char.ToUpperInvariant(ch));
        }
        return b.ToString();
    }

    /// <summary>The last four characters shown, the rest as asterisks; at most 32 characters (the column).</summary>
    public static string Mask(string normalized)
    {
        ArgumentNullException.ThrowIfNull(normalized);
        if (normalized.Length <= 4) return new string('*', normalized.Length);
        var hidden = Math.Min(normalized.Length - 4, 28);
        return new string('*', hidden) + normalized[^4..];
    }

    public static byte[] BlindIndex(ReadOnlySpan<byte> key, string kind, string countryIso2, string normalized) =>
        HMACSHA256.HashData(key, Encoding.UTF8.GetBytes($"{kind}|{countryIso2.ToUpperInvariant()}|{normalized}"));
}
