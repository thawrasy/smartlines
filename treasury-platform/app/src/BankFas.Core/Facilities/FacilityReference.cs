using System.Globalization;
using System.Text.RegularExpressions;

namespace BankFas.Core.Facilities;

/// <summary>
/// The platform reference of a facility (BR-FAC-021, the owner's request of 2026-10-23): COMPANY-BANK-CLASS-YY, such
/// as IMP-SNB-CAP-26 for a working capital facility of the company IMP with the bank SNB in force from 2026. The
/// company's code has two or three characters (a letter first), the bank's and the class's three capital letters, and
/// YY is the year the facility is in force from. A renewal keeps the stem of the facility it renews and takes its own
/// year (IMP-SNB-CAP-27). A second facility with the same stem and year takes a serial: IMP-SNB-CAP-26-2.
/// </summary>
public static partial class FacilityReference
{
    [GeneratedRegex("^[A-Z][A-Z0-9]{1,2}$")]
    private static partial Regex CompanyPattern();

    [GeneratedRegex("^[A-Z]{3}$")]
    private static partial Regex ThreeLetters();

    [GeneratedRegex("^([A-Z][A-Z0-9]{1,2}-[A-Z]{3}-[A-Z]{3})-[0-9]{2}(-[0-9]+)?$")]
    private static partial Regex ReferencePattern();

    public static bool IsCompanyCode(string? code) => code is not null && CompanyPattern().IsMatch(code);

    public static bool IsBankCode(string? code) => code is not null && ThreeLetters().IsMatch(code);

    public static bool IsClassCode(string? code) => code is not null && ThreeLetters().IsMatch(code);

    /// <summary>The reference code a company or a bank gets from its own code when that code already has the shape.</summary>
    public static string? CompanyDefault(string? companyCode) => IsCompanyCode(companyCode) ? companyCode : null;

    public static string? BankDefault(string? institutionCode) => IsBankCode(institutionCode) ? institutionCode : null;

    public static string Stem(string company, string bank, string facilityClass)
    {
        if (!IsCompanyCode(company)) throw new ArgumentException("The company's reference code is two or three characters, a letter first.", nameof(company));
        if (!IsBankCode(bank)) throw new ArgumentException("The bank's reference code is three capital letters.", nameof(bank));
        if (!IsClassCode(facilityClass)) throw new ArgumentException("The facility class is three capital letters.", nameof(facilityClass));
        return $"{company}-{bank}-{facilityClass}";
    }

    /// <summary>The stem of a reference (without its year and serial), or null when the text is not a reference.</summary>
    public static string? StemOf(string? reference) =>
        reference is not null && ReferencePattern().Match(reference) is { Success: true } m ? m.Groups[1].Value : null;

    /// <summary>The reference for a stem in a year; serial 1 is the first one and is not written.</summary>
    public static string Compose(string stem, int year, int serial = 1)
    {
        ArgumentNullException.ThrowIfNull(stem);
        if (year is < 2000 or > 2099) throw new ArgumentOutOfRangeException(nameof(year), "The year is between 2000 and 2099.");
        ArgumentOutOfRangeException.ThrowIfLessThan(serial, 1);
        var yy = (year % 100).ToString("00", CultureInfo.InvariantCulture);
        return serial == 1 ? $"{stem}-{yy}" : $"{stem}-{yy}-{serial.ToString(CultureInfo.InvariantCulture)}";
    }

    /// <summary>The first reference of the stem and year that no other facility holds.</summary>
    public static string Next(string stem, int year, IEnumerable<string> taken)
    {
        var set = new HashSet<string>(taken ?? [], StringComparer.Ordinal);
        for (var serial = 1; ; serial++)
            if (Compose(stem, year, serial) is var candidate && !set.Contains(candidate)) return candidate;
    }
}
