using BankFas.Core.Lc;

namespace BankFas.Core.Tests.Workflow;

public sealed class SalesRulesTests
{
    // AC-LCE-1 and BR-LCE-001: 1 LOT × 3,000,000 and 2,400 M × 222.80 make 3,534,720; VAT 15% is 530,208; the total 4,064,928.
    [Fact]
    public void The_proforma_of_the_spec_totals_as_written()
    {
        var t = SalesRules.Totals([new("Supply and installation", 1, "LOT", 3_000_000m), new("Cable", 2_400, "M", 222.80m)], 15m, 100m, 2);
        Assert.Equal(3_000_000m, t.Lines[0].LineTotal);
        Assert.Equal(534_720m, t.Lines[1].LineTotal);
        Assert.Equal(3_534_720m, t.Subtotal);
        Assert.Equal(530_208m, t.VatAmount);
        Assert.Equal(4_064_928m, t.Total);
        Assert.Equal(4_064_928m, t.LcAmount);
    }

    // BR-LCE-001: 3 × 33.335 = 100.005 rounds away from zero to 100.01; VAT 15% of 100.01 is 15.0015, so 15.00. Zero VAT is explicit.
    [Fact]
    public void Lines_round_away_from_zero_and_zero_vat_is_a_rate()
    {
        var t = SalesRules.Totals([new("Item", 3, "PCS", 33.335m)], 15m, 50m, 2);
        Assert.Equal(100.01m, t.Subtotal);
        Assert.Equal(15.00m, t.VatAmount);
        Assert.Equal(115.01m, t.Total);
        Assert.Equal(57.51m, t.LcAmount);   // half of 115.01 = 57.505, away from zero
        Assert.Equal(0m, SalesRules.Totals([new("Item", 1, "PCS", 10m)], 0m, 100m, 2).VatAmount);
    }

    // V-LCE-03: no line, a quantity not above zero or a negative price is refused.
    [Fact]
    public void A_proforma_needs_valid_lines()
    {
        Assert.Throws<ArgumentException>(() => SalesRules.Totals([], 15m, 100m, 2));
        Assert.Throws<ArgumentException>(() => SalesRules.Totals([new("Item", 0, "PCS", 1m)], 15m, 100m, 2));
        Assert.Throws<ArgumentException>(() => SalesRules.Totals([new("Item", 1, "PCS", -1m)], 15m, 100m, 2));
        Assert.Throws<ArgumentException>(() => SalesRules.Totals([new(" ", 1, "PCS", 1m)], 15m, 100m, 2));
    }

    // BR-LCE-002: 001-XX05-26, the ERP code trimmed and upper case; past 999 the number widens.
    [Fact]
    public void The_proforma_number_follows_the_pattern()
    {
        Assert.Equal("001-XX05-26", SalesRules.ProformaNumber(1, "xx05 ", 2026));
        Assert.Equal("001-XX05-27", SalesRules.ProformaNumber(1, "XX05", 2027));
        Assert.Equal("1000-XX02-26", SalesRules.ProformaNumber(1000, "x x02", 2026));
    }

    // AC-LCE-2, step by step: the invariant LCAmount = EarmarkedRemaining + Drawn + Available holds at each stage.
    [Fact]
    public void The_earmarks_and_conversions_of_the_spec_keep_the_balance()
    {
        var b = new SalesBalance(1_000_000m, 0m, 0m);
        Assert.Null(SalesRules.EarmarkProblem("ACTIVE", new DateOnly(2027, 1, 1), new DateOnly(2026, 11, 1), true, 400_000m, b.Available));
        b = b with { EarmarkedRemaining = 400_000m };
        Assert.Null(SalesRules.EarmarkProblem("ACTIVE", new DateOnly(2027, 1, 1), new DateOnly(2026, 11, 1), true, 300_000m, b.Available));
        b = b with { EarmarkedRemaining = 700_000m };
        Assert.Equal(300_000m, b.Available);
        // O3 for 400,000 is refused: 300,000 available.
        Assert.Equal("V-LCE-05", SalesRules.EarmarkProblem("ACTIVE", new DateOnly(2027, 1, 1), new DateOnly(2026, 11, 1), true, 400_000m, b.Available));
        // D = 350,000 all on O1.
        Assert.Null(SalesRules.ConversionProblem(350_000m, [new ConversionPart(1, 350_000m, 400_000m)], b.Available));
        b = b with { EarmarkedRemaining = 350_000m, Drawn = 350_000m };
        Assert.Equal(300_000m, b.Available);
        // The bank refuses D: the drawn amount and O1's earmark come back.
        b = b with { EarmarkedRemaining = 700_000m, Drawn = 0m };
        Assert.Equal(300_000m, b.Available);
        // D' = 350,000: 250,000 on O2 and 100,000 earmarked to no order, within the 300,000 available.
        Assert.Null(SalesRules.ConversionProblem(350_000m, [new ConversionPart(2, 250_000m, 300_000m)], b.Available));
        b = b with { EarmarkedRemaining = 450_000m, Drawn = 350_000m };
        Assert.Equal(200_000m, b.Available);
        Assert.Equal(b.LcAmount, b.EarmarkedRemaining + b.Drawn + b.Available);
    }

    // V-LCE-06, 07, 09 and 10.
    [Fact]
    public void Earmarks_and_conversions_are_refused_outside_the_rules()
    {
        var today = new DateOnly(2026, 11, 1);
        Assert.Equal("V-LCE-07", SalesRules.EarmarkProblem("EXPIRED", new DateOnly(2027, 1, 1), today, true, 1m, 10m));
        Assert.Equal("V-LCE-07", SalesRules.EarmarkProblem("ACTIVE", new DateOnly(2026, 10, 31), today, true, 1m, 10m));
        Assert.Equal("V-LCE-06", SalesRules.EarmarkProblem("ACTIVE", new DateOnly(2027, 1, 1), today, false, 1m, 10m));
        Assert.Equal("V-LCE-09", SalesRules.ConversionProblem(100m, [new ConversionPart(1, 60m, 50m)], 1_000m));
        Assert.Equal("V-LCE-09", SalesRules.ConversionProblem(100m, [new ConversionPart(1, 60m, 60m), new ConversionPart(2, 50m, 50m)], 1_000m));
        Assert.Equal("V-LCE-10", SalesRules.ConversionProblem(100m, [new ConversionPart(1, 10m, 10m)], 50m));
    }

    // AC-LCE-3 and BR-LCE-014: with 800,000 earmarked and drawn, lowering 1,000,000 by 300,000 falls 100,000 short; by 200,000 it does not.
    [Fact]
    public void An_amendment_covers_what_is_committed()
    {
        Assert.Equal(100_000m, SalesRules.AmendmentShortfall(700_000m, 450_000m, 350_000m));
        Assert.Equal(0m, SalesRules.AmendmentShortfall(800_000m, 450_000m, 350_000m));
        Assert.Equal(1_100_000m, SalesRules.EarmarkCap(1_000_000m, 10m, true, 2));
        Assert.Equal(1_000_000m, SalesRules.EarmarkCap(1_000_000m, 10m, false, 2));
    }
}

public sealed class TermsComparisonTests
{
    // FR-LCT-031: a proforma's 120 days against 90 in the credit is less favourable; 1 original and 2 copies of the
    // invoice against 1 and 3 is less favourable; a document added is ADDED; a confirmation is more favourable.
    [Fact]
    public void The_examples_of_the_spec_read_from_the_beneficiary_side()
    {
        var proforma = new CompareFacts
        {
            Amount = 1_000_000m, Currency = "USD", ExpiryDays = 120, LatestShipmentDays = 90, PresentationDays = 21, LcType = "SIGHT", PartialShipments = "ALLOWED",
            Transhipment = "ALLOWED", Confirmation = "WITHOUT", Incoterm = "EXW", IncotermPlace = "Riyadh", GoodsDescription = "Steel",
            Documents = new Dictionary<string, (int, int)> { ["COMMERCIAL_INVOICE"] = (1, 2) }, Charges = new Dictionary<string, string> { ["ADVISING"] = "APPLICANT" },
        };
        var received = proforma with
        {
            ExpiryDays = 90, Confirmation = "CONFIRMED", PartialShipments = "NOT_ALLOWED", GoodsDescription = "steel ",
            Documents = new Dictionary<string, (int, int)> { ["COMMERCIAL_INVOICE"] = (1, 3), ["CERT_ORIGIN"] = (1, 0) },
            Charges = new Dictionary<string, string> { ["ADVISING"] = "BENEFICIARY" },
        };
        var v = TermsComparison.Compare(proforma, received).ToDictionary(l => l.FieldKey, l => l.Verdict);
        Assert.Equal(TermsComparison.Less, v["expiryDays"]);
        Assert.Equal(TermsComparison.Less, v["doc:COMMERCIAL_INVOICE"]);
        Assert.Equal(TermsComparison.Added, v["doc:CERT_ORIGIN"]);
        Assert.Equal(TermsComparison.More, v["confirmation"]);
        Assert.Equal(TermsComparison.Less, v["partialShipments"]);
        Assert.Equal(TermsComparison.Less, v["charge:ADVISING"]);
        Assert.Equal(TermsComparison.Match, v["amount"]);
        Assert.Equal(TermsComparison.Match, v["goodsDescription"]);
        Assert.Equal(TermsComparison.Missing, TermsComparison.Compare(received, proforma).Single(l => l.FieldKey == "doc:CERT_ORIGIN").Verdict);
    }
}
