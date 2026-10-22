using System.Globalization;

namespace BankFas.Core.Calendar;

/// <summary>
/// The dual calendar (FR-PLT-033, BR-PLT-012; owner default OQ-14 of S2): the Gregorian date is stored, the Hijri date is
/// the Umm al-Qura calendar, and the text the user typed is kept as written. A Hijri date that does not exist (the 30th
/// of a month of 29 days) is refused, never moved to the next day.
/// </summary>
public static class HijriDates
{
    private static readonly UmAlQuraCalendar Calendar = new();

    /// <summary>The Gregorian date of a Hijri date written yyyy-MM-dd (Western or Arabic-Indic digits, / or -), or null when it does not exist.</summary>
    public static DateOnly? ToGregorian(string? hijri)
    {
        if (string.IsNullOrWhiteSpace(hijri)) return null;
        var text = new string([.. hijri.Trim().Select(ch => ch is >= '٠' and <= '٩' ? (char)('0' + (ch - '٠')) : ch == '/' ? '-' : ch)]);
        var parts = text.Split('-');
        if (parts.Length != 3 || !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var y)
            || !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var m)
            || !int.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out var d)) return null;
        if (y < Calendar.GetYear(Calendar.MinSupportedDateTime) || y > Calendar.GetYear(Calendar.MaxSupportedDateTime) || m is < 1 or > 12) return null;
        if (d < 1 || d > Calendar.GetDaysInMonth(y, m)) return null;
        return DateOnly.FromDateTime(Calendar.ToDateTime(y, m, d, 0, 0, 0, 0));
    }

    /// <summary>The Hijri date (yyyy-MM-dd) of a Gregorian date.</summary>
    public static string FromGregorian(DateOnly date)
    {
        var dt = date.ToDateTime(TimeOnly.MinValue);
        return string.Create(CultureInfo.InvariantCulture, $"{Calendar.GetYear(dt):0000}-{Calendar.GetMonth(dt):00}-{Calendar.GetDayOfMonth(dt):00}");
    }
}
