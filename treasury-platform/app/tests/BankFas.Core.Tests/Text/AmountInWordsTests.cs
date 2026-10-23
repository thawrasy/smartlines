using BankFas.Core.Text;

namespace BankFas.Core.Tests.Text;

public sealed class AmountInWordsTests
{
    // BR-LCT-003's example (14m:235): the amount of the sample bank form (docs/02 B11).
    [Fact]
    public void The_sample_amount_in_english() =>
        Assert.Equal("SAUDI RIYAL FOUR MILLION SIXTY-FOUR THOUSAND NINE HUNDRED AND TWENTY-EIGHT ONLY", AmountInWords.English(4_064_928.00m, "Saudi Riyal", 2));

    [Fact]
    public void The_sample_amount_in_arabic() =>
        Assert.Equal("فقط أربعة ملايين وأربعة وستون ألفًا وتسعمائة وثمانية وعشرون ريال سعودي لا غير", AmountInWords.Arabic(4_064_928.00m, "ريال سعودي", 2));

    [Theory]
    [InlineData(1, "ONE")]
    [InlineData(15, "FIFTEEN")]
    [InlineData(100, "ONE HUNDRED")]
    [InlineData(1_000, "ONE THOUSAND")]
    [InlineData(1_000_005, "ONE MILLION FIVE")]
    [InlineData(2_100_000, "TWO MILLION ONE HUNDRED THOUSAND")]
    [InlineData(3_150_000, "THREE MILLION ONE HUNDRED AND FIFTY THOUSAND")]
    [InlineData(50_000_000_000, "FIFTY BILLION")]
    public void English_numbers(long n, string words) => Assert.Equal("US DOLLAR " + words + " ONLY", AmountInWords.English(n, "US Dollar", 2));

    [Theory]
    [InlineData(1, "واحد")]
    [InlineData(12, "اثنا عشر")]
    [InlineData(200, "مائتان")]
    [InlineData(1_000, "ألف")]
    [InlineData(2_000, "ألفان")]
    [InlineData(3_000, "ثلاثة آلاف")]
    [InlineData(10_000, "عشرة آلاف")]
    [InlineData(11_000, "أحد عشر ألفًا")]
    [InlineData(100_000, "مائة ألف")]
    [InlineData(101_000, "مائة وألف")]
    [InlineData(250_000, "مائتان وخمسون ألفًا")]
    [InlineData(3_150_000, "ثلاثة ملايين ومائة وخمسون ألفًا")]
    [InlineData(2_000_000, "مليونان")]
    public void Arabic_numbers(long n, string words) => Assert.Equal("فقط " + words + " دولار أمريكي لا غير", AmountInWords.Arabic(n, "دولار أمريكي", 2));

    [Fact]
    public void Minor_units_are_a_fraction_of_the_currency_decimals()
    {
        Assert.Equal("KUWAITI DINAR TEN AND 250/1000 ONLY", AmountInWords.English(10.250m, "Kuwaiti Dinar", 3));
        Assert.Equal("فقط عشرة ريال سعودي و50/100 لا غير", AmountInWords.Arabic(10.5m, "ريال سعودي", 2));
        Assert.Equal("JAPANESE YEN FIVE ONLY", AmountInWords.English(5m, "Japanese Yen", 0));
    }

    [Fact]
    public void A_zero_or_overprecise_amount_is_refused()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => AmountInWords.English(0m, "Saudi Riyal", 2));
        Assert.Throws<ArgumentException>(() => AmountInWords.English(1.005m, "Saudi Riyal", 2));
    }
}
