using BankFas.Core.Lc;

namespace BankFas.Core.Tests.Text;

public sealed class ClauseTextTests
{
    [Fact]
    public void A_clause_fills_its_counts_and_parameters_and_shows_a_missing_one()   // BR-LCT-012
    {
        var t = ClauseText.Render("Signed commercial invoice in {originals} originals and {copies} copies, showing {hsCode} and {origin}.",
            """{"hsCode":"7304.19","origin":true}""", 3, 2, arabic: false);
        Assert.Equal("Signed commercial invoice in 3 (three) originals and 2 (two) copies, showing 7304.19 and yes.", t);
        Assert.Equal("Copies: [copies]; {not a key}", ClauseText.Render("Copies: {copies}; {not a key}", null, null, null, arabic: false));
        Assert.Equal("فاتورة تجارية من 3 (ثلاثة) أصول", ClauseText.Render("فاتورة تجارية من {originals} أصول", null, 3, null, arabic: true));
    }

    [Fact]
    public void A_UCP_reference_prints_its_article_and_paragraph()   // FR-LCT-005
    {
        Assert.Equal("UCP 600 art. 14(b)", ClauseText.Reference("14", "b", arabic: false));
        Assert.Equal("UCP 600 art. 30", ClauseText.Reference("30", null, arabic: false));
    }
}
