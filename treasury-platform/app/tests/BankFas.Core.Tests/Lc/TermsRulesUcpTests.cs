using BankFas.Core.Lc;

namespace BankFas.Core.Tests.Lc;

// The UCP 600 checks of the letter-of-credit terms (docs/60): articles 28, 29, 32 and 19 to 24.
public sealed class TermsRulesUcpTests
{
    private static readonly DateOnly Today = new(2026, 10, 25);

    private static IReadOnlyList<TermsFinding> Run(TermsFacts f) => TermsRules.Check(f with
    {
        Amount = 100_000, ChargeCategories = TermsRules.ChargeCategories.ToHashSet(), DocumentCount = 1,
    }, [], Today, 10, 21);

    private static string[] Codes(TermsFacts f) => Run(f).Select(x => $"{x.Code}:{x.Severity}:{x.Field}").ToArray();

    [Fact]
    public void Insurance_below_110_percent_is_a_warning() =>
        Assert.Contains("V-LCT-UCP28:W:insuranceMinPct", Codes(new TermsFacts { InsuranceResponsibility = "APPLICANT", InsuranceMinPct = 100 }));

    [Fact]
    public void Insurance_at_110_percent_or_not_required_passes()
    {
        Assert.DoesNotContain(Run(new TermsFacts { InsuranceResponsibility = "APPLICANT", InsuranceMinPct = 110 }), x => x.Code == "V-LCT-UCP28");
        Assert.DoesNotContain(Run(new TermsFacts { InsuranceResponsibility = "NOT_REQUIRED_BY_TERMS", InsuranceMinPct = 50 }), x => x.Code == "V-LCT-UCP28");
    }

    [Fact]
    public void A_cif_credit_asks_for_an_insurance_document_from_the_beneficiary()
    {
        var c = Codes(new TermsFacts { IncotermCode = "CIF", InsuranceResponsibility = "APPLICANT" });
        Assert.Contains("V-LCT-UCP28:W:documents", c);
        Assert.Contains("V-LCT-UCP28:W:insuranceResponsibility", c);
        Assert.DoesNotContain(Run(new TermsFacts { IncotermCode = "CIP", InsuranceResponsibility = "BENEFICIARY", HasInsuranceDocument = true }), x => x.Code == "V-LCT-UCP28");
    }

    [Fact]
    public void Instalments_with_partial_shipments_forbidden_is_an_error()
    {
        Assert.Contains("V-LCT-UCP32:E:partialShipments", Codes(new TermsFacts { InstallmentShipments = "Three monthly lots", PartialShipments = "NOT_ALLOWED" }));
        Assert.DoesNotContain(Run(new TermsFacts { InstallmentShipments = "Three monthly lots", PartialShipments = "ALLOWED" }), x => x.Code == "V-LCT-UCP32");
    }

    [Fact]
    public void An_expiry_on_a_non_working_day_is_a_warning() =>
        Assert.Contains("V-LCT-UCP29:W:expiryDate", Codes(new TermsFacts { ExpiryOnNonWorkingDay = true }));

    [Fact]
    public void Transhipment_forbidden_by_sea_is_a_warning_and_by_courier_is_not()
    {
        Assert.Contains("V-LCT-UCP20:W:transhipment", Codes(new TermsFacts { Transhipment = "NOT_ALLOWED", TransportMode = "SEA" }));
        Assert.DoesNotContain(Run(new TermsFacts { Transhipment = "NOT_ALLOWED", TransportMode = "COURIER" }), x => x.Code == "V-LCT-UCP20");
    }
}
