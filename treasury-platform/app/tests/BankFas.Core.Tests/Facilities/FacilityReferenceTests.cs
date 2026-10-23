using BankFas.Core.Facilities;

namespace BankFas.Core.Tests.Facilities;

public sealed class FacilityReferenceTests
{
    [Fact]
    public void A_working_capital_facility_of_2026_and_its_renewal()
    {
        var stem = FacilityReference.Stem("IMP", "SNB", "CAP");
        Assert.Equal("IMP-SNB-CAP-26", FacilityReference.Compose(stem, 2026));
        Assert.Equal("IMP-SNB-CAP", FacilityReference.StemOf("IMP-SNB-CAP-26"));
        Assert.Equal("IMP-SNB-CAP-27", FacilityReference.Compose(FacilityReference.StemOf("IMP-SNB-CAP-26")!, 2027));
        Assert.Equal("C1-ANB-LTL-30", FacilityReference.Compose(FacilityReference.Stem("C1", "ANB", "LTL"), 2030));
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
    [InlineData("IMPO", false)]
    [InlineData("imp", false)]
    public void The_company_code_is_two_or_three_characters_a_letter_first(string code, bool ok) => Assert.Equal(ok, FacilityReference.IsCompanyCode(code));

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
        Assert.Null(FacilityReference.CompanyDefault("HOLD"));
    }
}
