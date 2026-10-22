using System.Collections.Frozen;
using System.Security.Cryptography;
using System.Text;

namespace BankFas.Core.Banking;

/// <summary>
/// Bank account numbers and IBANs (FR-ACC-002 to 005, FR-ACC-009; BR-ACC-001, BR-ACC-002, BR-ACC-016). The normal form
/// drops spaces, dashes and every other separator and is upper case, so "1234-567" and "1234 567" are one number. An
/// IBAN has the length of its country (ISO 13616 registry) and passes mod 97: the first four characters move to the
/// end, letters become 10 to 35, and the remainder by 97 is 1. A country outside the table is held to 15 to 34
/// characters. The blind index is HMAC-SHA256 with the tenant's BLIND_INDEX key over the kind and the normal form,
/// so uniqueness and search need no decryption.
/// </summary>
public static class BankAccountNumbers
{
    private const char Dot = '•';

    /// <summary>IBAN lengths per country, from the ISO 13616 registry.</summary>
    private static readonly FrozenDictionary<string, int> IbanLengths = new Dictionary<string, int>(StringComparer.Ordinal)
    {
        ["AD"] = 24, ["AE"] = 23, ["AL"] = 28, ["AT"] = 20, ["AZ"] = 28, ["BA"] = 20, ["BE"] = 16, ["BG"] = 22, ["BH"] = 22, ["BR"] = 29,
        ["BY"] = 28, ["CH"] = 21, ["CR"] = 22, ["CY"] = 28, ["CZ"] = 24, ["DE"] = 22, ["DK"] = 18, ["DO"] = 28, ["EE"] = 20, ["EG"] = 29,
        ["ES"] = 24, ["FI"] = 18, ["FO"] = 18, ["FR"] = 27, ["GB"] = 22, ["GE"] = 22, ["GI"] = 23, ["GL"] = 18, ["GR"] = 27, ["GT"] = 28,
        ["HR"] = 21, ["HU"] = 28, ["IE"] = 22, ["IL"] = 23, ["IQ"] = 23, ["IS"] = 26, ["IT"] = 27, ["JO"] = 30, ["KW"] = 30, ["KZ"] = 20,
        ["LB"] = 28, ["LC"] = 32, ["LI"] = 21, ["LT"] = 20, ["LU"] = 20, ["LV"] = 21, ["LY"] = 25, ["MC"] = 27, ["MD"] = 24, ["ME"] = 22,
        ["MK"] = 19, ["MR"] = 27, ["MT"] = 31, ["MU"] = 30, ["NL"] = 18, ["NO"] = 15, ["OM"] = 23, ["PK"] = 24, ["PL"] = 28, ["PS"] = 29,
        ["PT"] = 25, ["QA"] = 29, ["RO"] = 24, ["RS"] = 22, ["SA"] = 24, ["SC"] = 31, ["SD"] = 18, ["SE"] = 24, ["SI"] = 19, ["SK"] = 24,
        ["SM"] = 27, ["ST"] = 25, ["SV"] = 28, ["TL"] = 23, ["TN"] = 24, ["TR"] = 26, ["UA"] = 29, ["VA"] = 22, ["VG"] = 24, ["XK"] = 20,
    }.ToFrozenDictionary(StringComparer.Ordinal);

    /// <summary>Letters and digits only, upper case; Arabic-Indic digits become ASCII.</summary>
    public static string Normalize(string? number)
    {
        if (number is null) return "";
        var b = new StringBuilder(number.Length);
        foreach (var ch in number.Normalize(NormalizationForm.FormKC))
        {
            if (ch is >= '٠' and <= '٩') b.Append((char)('0' + (ch - '٠')));
            else if (ch is >= '۰' and <= '۹') b.Append((char)('0' + (ch - '۰')));
            else if (char.IsAsciiLetterOrDigit(ch)) b.Append(char.ToUpperInvariant(ch));
        }
        return b.ToString();
    }

    /// <summary>Why a normalised IBAN is not valid, or null when it is.</summary>
    public static string? IbanProblem(string iban)
    {
        ArgumentNullException.ThrowIfNull(iban);
        if (iban.Length < 5 || !char.IsAsciiLetterUpper(iban[0]) || !char.IsAsciiLetterUpper(iban[1]) || !char.IsAsciiDigit(iban[2]) || !char.IsAsciiDigit(iban[3]))
            return "FORMAT";
        if (IbanLengths.TryGetValue(iban[..2], out var length) ? iban.Length != length : iban.Length is < 15 or > 34) return "LENGTH";
        var remainder = 0;
        foreach (var ch in iban[4..] + iban[..4])
        {
            if (char.IsAsciiDigit(ch)) remainder = (remainder * 10 + (ch - '0')) % 97;
            else if (char.IsAsciiLetterUpper(ch)) remainder = (remainder * 100 + (ch - 'A' + 10)) % 97;
            else return "FORMAT";
        }
        return remainder == 1 ? null : "CHECKSUM";
    }

    /// <summary>BR-ACC-016: the country code and the last four shown, the rest as dots, in groups of four; at most 32 characters.</summary>
    public static string MaskIban(string iban)
    {
        ArgumentNullException.ThrowIfNull(iban);
        var chars = iban.Select((ch, i) => i < 2 || i >= iban.Length - 4 ? ch : Dot).ToArray();
        var grouped = string.Join(' ', Enumerable.Range(0, (chars.Length + 3) / 4).Select(g => new string(chars, g * 4, Math.Min(4, chars.Length - g * 4))));
        return grouped.Length <= 32 ? grouped : $"{iban[..2]}{Dot}{Dot} … {iban[^4..]}";
    }

    /// <summary>The last four shown after four dots: "•••• 4567".</summary>
    public static string MaskNumber(string normalized)
    {
        ArgumentNullException.ThrowIfNull(normalized);
        return normalized.Length <= 4 ? new string(Dot, normalized.Length) : $"{Dot}{Dot}{Dot}{Dot} {normalized[^4..]}";
    }

    public static string Last4(string normalized) => normalized.Length <= 4 ? normalized : normalized[^4..];

    /// <summary>The blind index of an account number (kind ACCOUNT) or an IBAN (kind IBAN).</summary>
    public static byte[] BlindIndex(ReadOnlySpan<byte> key, string kind, string normalized) =>
        HMACSHA256.HashData(key, Encoding.UTF8.GetBytes($"{kind}|{normalized}"));
}
