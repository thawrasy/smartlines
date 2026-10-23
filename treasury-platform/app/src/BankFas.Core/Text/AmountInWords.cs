using System.Globalization;
using System.Text;

namespace BankFas.Core.Text;

/// <summary>
/// The amount of a letter of credit in words, Arabic and English, generated from the amount and the currency and never
/// edited (FR-LCT-008, BR-LCT-003; S3-GAP-23). The English form is the bank form's (docs/02 B11): the currency name,
/// the whole units, the minor units as a fraction of the currency's decimals, then ONLY, e.g. 4,064,928.00 SAR gives
/// "SAUDI RIYAL FOUR MILLION SIXTY-FOUR THOUSAND NINE HUNDRED AND TWENTY-EIGHT ONLY". The Arabic form is the invoice
/// form: «فقط … ريال سعودي لا غير». The minor units are written as a fraction (50/100) rather than by a unit name,
/// which the currency reference does not carry.
/// </summary>
public static class AmountInWords
{
    private static readonly string[] EnOnes =
    [
        "", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN", "ELEVEN", "TWELVE", "THIRTEEN",
        "FOURTEEN", "FIFTEEN", "SIXTEEN", "SEVENTEEN", "EIGHTEEN", "NINETEEN",
    ];
    private static readonly string[] EnTens = ["", "", "TWENTY", "THIRTY", "FORTY", "FIFTY", "SIXTY", "SEVENTY", "EIGHTY", "NINETY"];
    private static readonly string[] EnScales = ["", "THOUSAND", "MILLION", "BILLION", "TRILLION"];

    private static readonly string[] ArOnes = ["", "واحد", "اثنان", "ثلاثة", "أربعة", "خمسة", "ستة", "سبعة", "ثمانية", "تسعة"];
    private static readonly string[] ArTeens =
    [
        "عشرة", "أحد عشر", "اثنا عشر", "ثلاثة عشر", "أربعة عشر", "خمسة عشر", "ستة عشر", "سبعة عشر", "ثمانية عشر", "تسعة عشر",
    ];
    private static readonly string[] ArTens = ["", "", "عشرون", "ثلاثون", "أربعون", "خمسون", "ستون", "سبعون", "ثمانون", "تسعون"];
    private static readonly string[] ArHundreds = ["", "مائة", "مائتان", "ثلاثمائة", "أربعمائة", "خمسمائة", "ستمائة", "سبعمائة", "ثمانمائة", "تسعمائة"];
    // Per scale: one, two, three to ten (plural), and the singular after eleven to ninety-nine (accusative).
    private static readonly string[][] ArScales =
    [
        ["", "", "", ""],
        ["ألف", "ألفان", "آلاف", "ألفًا"],
        ["مليون", "مليونان", "ملايين", "مليونًا"],
        ["مليار", "ملياران", "مليارات", "مليارًا"],
        ["تريليون", "تريليونان", "تريليونات", "تريليونًا"],
    ];

    /// <summary>The English words: the currency name in capitals, the amount, ONLY.</summary>
    public static string English(decimal amount, string currencyNameEn, int decimals)
    {
        var (whole, minor, scale) = Split(amount, decimals);
        var b = new StringBuilder(currencyNameEn.Trim().ToUpperInvariant()).Append(' ').Append(EnglishNumber(whole));
        if (minor > 0) b.Append(" AND ").Append(minor.ToString(CultureInfo.InvariantCulture)).Append('/').Append(scale.ToString(CultureInfo.InvariantCulture));
        return b.Append(" ONLY").ToString();
    }

    /// <summary>The Arabic words: «فقط», the amount, the currency name, «لا غير».</summary>
    public static string Arabic(decimal amount, string currencyNameAr, int decimals)
    {
        var (whole, minor, scale) = Split(amount, decimals);
        var b = new StringBuilder("فقط ").Append(ArabicNumber(whole)).Append(' ').Append(currencyNameAr.Trim());
        if (minor > 0) b.Append(" و").Append(minor.ToString(CultureInfo.InvariantCulture)).Append('/').Append(scale.ToString(CultureInfo.InvariantCulture));
        return b.Append(" لا غير").ToString();
    }

    private static (long Whole, long Minor, long Scale) Split(decimal amount, int decimals)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(amount);
        if (decimals is < 0 or > 3) throw new ArgumentOutOfRangeException(nameof(decimals));
        ArgumentOutOfRangeException.ThrowIfGreaterThanOrEqual(amount, 1_000_000_000_000_000m);
        var scale = (long)Math.Pow(10, decimals);
        var rounded = Math.Round(amount, decimals, MidpointRounding.AwayFromZero);
        if (rounded != amount) throw new ArgumentException("The amount has more decimals than its currency.", nameof(amount));
        var whole = (long)decimal.Truncate(rounded);
        return (whole, (long)((rounded - whole) * scale), scale);
    }

    private static string EnglishNumber(long n)
    {
        if (n == 0) return "ZERO";
        var groups = new List<string>();
        for (var i = 0; n > 0; i++, n /= 1000)
        {
            var g = (int)(n % 1000);
            if (g == 0) continue;
            groups.Insert(0, EnScales[i].Length == 0 ? EnglishGroup(g) : EnglishGroup(g) + " " + EnScales[i]);
        }
        return string.Join(' ', groups);
    }

    private static string EnglishGroup(int g)
    {
        var parts = new List<string>();
        if (g >= 100) parts.Add(EnOnes[g / 100] + " HUNDRED");
        var r = g % 100;
        if (r > 0)
        {
            if (parts.Count > 0) parts.Add("AND");
            parts.Add(r < 20 ? EnOnes[r] : EnTens[r / 10] + (r % 10 > 0 ? "-" + EnOnes[r % 10] : ""));
        }
        return string.Join(' ', parts);
    }

    private static string ArabicNumber(long n)
    {
        if (n == 0) return "صفر";
        var groups = new List<string>();
        for (var i = 0; n > 0; i++, n /= 1000)
        {
            var g = (int)(n % 1000);
            if (g == 0) continue;
            groups.Insert(0, i == 0 ? ArabicGroup(g) : ArabicScaled(g, ArScales[i]));
        }
        return string.Join(" و", groups);
    }

    // A group of a scale: the counted noun follows the last two digits (Arabic number agreement): 100 thousand is
    // «مائة ألف», 1 and 2 are the noun itself and its dual, 3 to 10 take the plural, 11 to 99 the accusative singular.
    private static string ArabicScaled(int g, string[] noun)
    {
        var r = g % 100;
        var hundreds = g >= 100 ? ArHundreds[g / 100] : "";
        string tail = r switch
        {
            0 => noun[0],
            1 => noun[0],
            2 => noun[1],
            <= 10 => ArabicGroup(r) + " " + noun[2],
            _ => ArabicGroup(r) + " " + noun[3],
        };
        if (hundreds.Length == 0) return tail;
        return r == 0 ? hundreds + " " + tail : hundreds + " و" + tail;
    }

    private static string ArabicGroup(int g)
    {
        var parts = new List<string>();
        if (g >= 100) parts.Add(ArHundreds[g / 100]);
        var r = g % 100;
        if (r is >= 10 and < 20) parts.Add(ArTeens[r - 10]);
        else if (r > 0)
        {
            var ones = r % 10;
            var tens = r / 10;
            parts.Add(tens == 0 ? ArOnes[ones] : ones == 0 ? ArTens[tens] : ArOnes[ones] + " و" + ArTens[tens]);
        }
        return string.Join(" و", parts);
    }
}
