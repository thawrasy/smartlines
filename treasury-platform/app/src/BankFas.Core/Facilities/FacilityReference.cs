using System.Globalization;
using System.Text.RegularExpressions;

namespace BankFas.Core.Facilities;

/// <summary>
/// The facility file and the contract references (docs/31 row 75): a company's file with a bank is COMPANY-BANK-NNNN
/// (<see cref="FileRef"/>), and each contract in it CLASS-FILE, its renewals CLASS-FILE-NN (<see cref="ContractRef"/>).
/// The stems below are of the earlier references, which a facility approved before keeps:
/// the platform reference of a facility (BR-FAC-021; the owner's requests of 2026-10-23 and 2026-10-26):
/// CLASS-COMPANY-BANK-YY, such as CAP-SA05-ANB-26 for a working capital facility of the company SA05 with the bank ANB
/// in force from 2026. The class and the bank's code are three capital letters, the company's code two to six
/// characters (a letter first), and YY is the year the facility is in force from, the year of its contract. A renewal
/// keeps the stem of the facility it renews and takes its own year (CAP-SA05-ANB-27). A second facility with the same
/// stem and year takes a serial: CAP-SA05-ANB-26-2. A reference written in the earlier order COMPANY-BANK-CLASS-YY
/// keeps its stem, so the renewals of a facility approved before stay in its chain.
/// </summary>
public static partial class FacilityReference
{
    [GeneratedRegex("^[A-Z][A-Z0-9]{1,5}$")]
    private static partial Regex CompanyPattern();

    [GeneratedRegex("^[A-Z]{3}$")]
    private static partial Regex ThreeLetters();

    [GeneratedRegex("^([A-Z]{3}-[A-Z][A-Z0-9]{1,5}-[A-Z]{3}|[A-Z][A-Z0-9]{1,2}-[A-Z]{3}-[A-Z]{3})-[0-9]{2}(-[0-9]+)?$")]
    private static partial Regex ReferencePattern();

    public static bool IsCompanyCode(string? code) => code is not null && CompanyPattern().IsMatch(code);

    public static bool IsBankCode(string? code) => code is not null && ThreeLetters().IsMatch(code);

    public static bool IsClassCode(string? code) => code is not null && ThreeLetters().IsMatch(code);

    /// <summary>The reference code a company or a bank gets from its own code when that code already has the shape.</summary>
    public static string? CompanyDefault(string? companyCode) => IsCompanyCode(companyCode) ? companyCode : null;

    public static string? BankDefault(string? institutionCode) => IsBankCode(institutionCode) ? institutionCode : null;

    public static string Stem(string company, string bank, string facilityClass)
    {
        if (!IsCompanyCode(company)) throw new ArgumentException("The company's reference code is two to six characters, a letter first.", nameof(company));
        if (!IsBankCode(bank)) throw new ArgumentException("The bank's reference code is three capital letters.", nameof(bank));
        if (!IsClassCode(facilityClass)) throw new ArgumentException("The facility class is three capital letters.", nameof(facilityClass));
        return $"{facilityClass}-{company}-{bank}";
    }

    /// <summary>The reference of a facility file (docs/31 row 75): COMPANY-BANK-NNNN, such as SA05-ANB-0001.</summary>
    public static string FileRef(string company, string bank, int serial)
    {
        if (!IsCompanyCode(company)) throw new ArgumentException("The company's reference code is two to six characters, a letter first.", nameof(company));
        if (!IsBankCode(bank)) throw new ArgumentException("The bank's reference code is three capital letters.", nameof(bank));
        if (serial is < 1 or > 9999) throw new ArgumentOutOfRangeException(nameof(serial), "The file's serial is 1 to 9999.");
        return $"{company}-{bank}-{serial.ToString("0000", CultureInfo.InvariantCulture)}";
    }

    /// <summary>The reference of a contract in its file: CLASS-FILE for the first of its class (CAP-SA05-ANB-0001), CLASS-FILE-NN for each renewal (CAP-SA05-ANB-0001-02).</summary>
    public static string ContractRef(string facilityClass, string fileRef, int seqInClass)
    {
        ArgumentNullException.ThrowIfNull(fileRef);
        if (!IsClassCode(facilityClass)) throw new ArgumentException("The facility class is three capital letters.", nameof(facilityClass));
        if (seqInClass is < 1 or > 99) throw new ArgumentOutOfRangeException(nameof(seqInClass), "The order in the file is 1 to 99.");
        return seqInClass == 1 ? $"{facilityClass}-{fileRef}" : $"{facilityClass}-{fileRef}-{seqInClass.ToString("00", CultureInfo.InvariantCulture)}";
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
