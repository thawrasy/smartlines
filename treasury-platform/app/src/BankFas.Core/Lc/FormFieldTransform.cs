using System.Globalization;
using BankFas.Core.Calendar;

namespace BankFas.Core.Lc;

/// <summary>
/// The transforms of a bank-form field map (FR-LCT-027, BR-LCT-020): pure functions of the source value, with no code
/// in the template. NONE, UPPER, DATE_DMY (dd/MM/yyyy), DATE_HIJRI, CHECKBOX_EQ ("X" when the value equals the
/// argument, else empty); the amount in words and the summaries take their text from the caller, which knows the
/// currency and the documents.
/// </summary>
public static class FormFieldTransform
{
    public static string Apply(string transform, object? value, string? arg)
    {
        ArgumentNullException.ThrowIfNull(transform);
        string? text = value switch
        {
            null => null,
            DateTime d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            DateOnly d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            decimal m => m.ToString("0.##", CultureInfo.InvariantCulture),
            bool b => b ? "true" : "false",
            _ => Convert.ToString(value, CultureInfo.InvariantCulture),
        };
        if (text is null) return "";
        static DateOnly? Date(string s) => DateOnly.TryParseExact(s.Length >= 10 ? s[..10] : s, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d) ? d : null;
        return transform switch
        {
            "UPPER" => text.ToUpperInvariant(),
            "DATE_DMY" => Date(text) is { } d ? d.ToString("dd/MM/yyyy", CultureInfo.InvariantCulture) : text,
            "DATE_HIJRI" => Date(text) is { } h ? HijriDates.FromGregorian(h) : text,
            "CHECKBOX_EQ" => string.Equals(text, arg, StringComparison.OrdinalIgnoreCase) ? "X" : "",
            _ => text,
        };
    }
}
