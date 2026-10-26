using BankFas.Core.Facilities;

namespace BankFas.Core.Tests.Facilities;

public sealed class FacilityReferenceTests
{
    [Fact]
    public void A_working_capital_facility_of_2026_and_its_renewal()
    {
        var stem = FacilityReference.Stem("SA05", "ANB", "CAP");
        Assert.Equal("CAP-SA05-ANB-26", FacilityReference.Compose(stem, 2026));
        Assert.Equal("CAP-SA05-ANB", FacilityReference.StemOf("CAP-SA05-ANB-26"));
        Assert.Equal("CAP-SA05-ANB-27", FacilityReference.Compose(FacilityReference.StemOf("CAP-SA05-ANB-26")!, 2027));
        Assert.Equal("LTL-C1-ANB-30", FacilityReference.Compose(FacilityReference.Stem("C1", "ANB", "LTL"), 2030));
        // A facility approved in the earlier order keeps its stem for its renewals.
        Assert.Equal("IMP-SNB-CAP", FacilityReference.StemOf("IMP-SNB-CAP-26"));
    }

    [Fact]
    public void A_second_facility_of_the_same_stem_and_year_takes_a_serial()
    {
        Assert.Equal("IMP-SNB-CAP-26-2", FacilityReference.Next("IMP-SNB-CAP", 2026, ["IMP-SNB-CAP-26"]));
        Assert.Equal("IMP-SNB-CAP-26-3", FacilityReference.Next("IMP-SNB-CAP", 2026, ["IMP-SNB-CAP-26", "IMP-SNB-CAP-26-2"]));
        Assert.Equal("IMP-SNB-CAP-27", FacilityReference.Next("IMP-SNB-CAP", 2027, ["IMP-SNB-CAP-26"]));
        Assert.Equal("IMP-SNB-CAP", FacilityReference.StemOf("IMP-SNB-CAP-26-2"));
    }

    [Theory]
    [InlineData("I", false)]
    [InlineData("IM", true)]
    [InlineData("IMP", true)]
    [InlineData("C1", true)]
    [InlineData("1C", false)]
    [InlineData("SA05", true)]
    [InlineData("ABCDEF", true)]
    [InlineData("ABCDEFG", false)]
    [InlineData("imp", false)]
    public void The_company_code_is_two_to_six_characters_a_letter_first(string code, bool ok) => Assert.Equal(ok, FacilityReference.IsCompanyCode(code));

    [Theory]
    [InlineData("SNB", true)]
    [InlineData("SN", false)]
    [InlineData("SNB1", false)]
    [InlineData("SN1", false)]
    public void The_bank_code_is_three_capital_letters(string code, bool ok) => Assert.Equal(ok, FacilityReference.IsBankCode(code));

    [Fact]
    public void Codes_of_another_shape_do_not_make_a_reference()
    {
        Assert.Throws<ArgumentException>(() => FacilityReference.Stem("IMP", "BNK1", "CAP"));
        Assert.Throws<ArgumentException>(() => FacilityReference.Stem("IMP", "SNB", "WC"));
        Assert.Null(FacilityReference.StemOf("FAC-26-001"));
        Assert.Null(FacilityReference.BankDefault("BNKC"));
        Assert.Equal("SNB", FacilityReference.BankDefault("SNB"));
        Assert.Null(FacilityReference.CompanyDefault("HOLDING"));
        Assert.Equal("SA05", FacilityReference.CompanyDefault("SA05"));
    }

    [Fact]
    public void The_facility_file_and_its_contracts()
    {
        var file = FacilityReference.FileRef("SA05", "ANB", 1);
        Assert.Equal("SA05-ANB-0001", file);
        Assert.Equal("CAP-SA05-ANB-0001", FacilityReference.ContractRef("CAP", file, 1));
        Assert.Equal("CAP-SA05-ANB-0001-02", FacilityReference.ContractRef("CAP", file, 2));
        Assert.Equal("LTL-SA05-ANB-0001", FacilityReference.ContractRef("LTL", file, 1));
        Assert.Throws<ArgumentOutOfRangeException>(() => FacilityReference.FileRef("SA05", "ANB", 10000));
        Assert.Throws<ArgumentException>(() => FacilityReference.ContractRef("CA", file, 1));
    }
}
