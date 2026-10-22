using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace BankFas.Core.Text;

/// <summary>
/// The normal forms the database keeps for search and uniqueness (FR-PTY-002, FR-PTY-012, BR-PTY-004, BR-PTY-015):
/// names with Arabic letters unified and marks removed, phone numbers in E.164, e-mail addresses in lower case.
/// </summary>
public static partial class Normalizer
{
    /// <summary>
    /// A name for search: NFKC, Arabic diacritics and tatweel removed, alef forms as alef, alef maqsura as ya, ta
    /// marbuta as ha, Arabic-Indic digits as ASCII, Latin letters in lower case, one space between words.
    /// </summary>
    public static string Name(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        var s = text.Normalize(NormalizationForm.FormKC);
        var b = new StringBuilder(s.Length);
        foreach (var ch in s)
        {
            switch (ch)
            {
                case 'ـ': continue;                                   // tatweel
                case >= 'ً' and <= 'ٟ': continue;                // harakat
                case 'ٰ': continue;                                   // superscript alef
                case 'آ' or 'أ' or 'إ' or 'ٱ': b.Append('ا'); break;   // alef forms
                case 'ى': b.Append('ي'); break;                  // alef maqsura -> ya
                case 'ة': b.Append('ه'); break;                  // ta marbuta -> ha
                case >= '٠' and <= '٩': b.Append((char)('0' + (ch - '٠'))); break;
                case >= '۰' and <= '۹': b.Append((char)('0' + (ch - '۰'))); break;
                default: b.Append(char.IsWhiteSpace(ch) || char.IsPunctuation(ch) ? ' ' : char.ToLowerInvariant(ch)); break;
            }
        }
        return Spaces().Replace(b.ToString(), " ").Trim();
    }

    /// <summary>
    /// A phone number in E.164 (+ and up to 15 digits), with the dial code of the given country for a national number
    /// (a leading 0 is the trunk prefix); null when it cannot be one.
    /// </summary>
    public static string? Phone(string? text, string? countryDialCode)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var digits = new StringBuilder();
        foreach (var ch in text.Normalize(NormalizationForm.FormKC))
        {
            if (ch is >= '0' and <= '9') digits.Append(ch);
            else if (ch is >= '٠' and <= '٩') digits.Append((char)('0' + (ch - '٠')));
        }
        var d = digits.ToString();
        var plus = text.TrimStart().StartsWith('+');
        string full;
        if (plus) full = d;
        else if (d.StartsWith("00", StringComparison.Ordinal)) full = d[2..];
        else
        {
            var dial = (countryDialCode ?? "").TrimStart('+');
            if (dial.Length == 0) return null;
            full = dial + (d.StartsWith('0') ? d[1..] : d);
        }
        return full.Length is >= 8 and <= 15 && full[0] != '0' ? "+" + full : null;
    }

    /// <summary>An e-mail address trimmed and in lower case; null when it is not one.</summary>
    public static string? Email(string? text)
    {
        var e = text?.Trim().ToLowerInvariant();
        return e is not null && EmailPattern().IsMatch(e) ? e : null;
    }

    /// <summary>A code without spaces, in upper case (the ERP code, BR-ORG-001 and DR-47).</summary>
    public static string Code(string text) => (text ?? "").Replace(" ", "", StringComparison.Ordinal).ToUpper(CultureInfo.InvariantCulture);

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();

    [GeneratedRegex(@"^[^@\s]{1,64}@[^@\s]+\.[^@\s]{2,}$", RegexOptions.CultureInvariant)]
    private static partial Regex EmailPattern();
}
