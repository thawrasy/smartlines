"""The tax engine of e-invoices (1108), on its own: every kind of tax the owner listed (out of scope, exempt, zero
rated, a rate per band or per product, compound sales tax and VAT, local taxes, a tax levied on the VAT for another
authority), always summing back to the price paid."""
from decimal import Decimal

import pytest

from app.modules.einvoice import taxes
from app.modules.einvoice.taxes import Band, Rule, Sale, Scheme

SALE = Sale(country="SY", seller="CARRIER", product="TICKET", company_id=7, origin_city="DAM")


def rule(method="PERCENT", rate=None, amount=None, base_type="FARE", include=(), mode="ADD", per="TICKET", bands=(), **kw):
    return Rule(seq=1, calc_method=method, rate=None if rate is None else Decimal(str(rate)), amount=amount, base_type=base_type,
                base_include=list(include), compound_mode=mode, min_amount=kw.get("min"), max_amount=kw.get("max"),
                rounding=kw.get("rounding", "HALF_UP"), applies_per=per, priority=100, bands=list(bands))


def scheme(code, treatment="STANDARD", rules=(), tax_type="VAT", scope=None, payable=None):
    return Scheme(id=hash(code) % 1000, code=code, tax_type=tax_type, treatment=treatment, payable_to_party_id=payable,
                  scope=scope or {}, rules=list(rules))


def total(t):
    return sum(x.amount for x in t)


def test_no_tax_scheme_means_out_of_scope():
    net, t = taxes.split_inclusive(110_000, [], SALE)
    assert net == 110_000 and t == [] and taxes.line_treatment(t) == "OUT_OF_SCOPE"


@pytest.mark.parametrize("treatment", ["EXEMPT", "ZERO", "OUT_OF_SCOPE"])
def test_exempt_zero_and_out_of_scope_charge_nothing_but_are_shown(treatment):
    net, t = taxes.split_inclusive(110_000, [scheme("VAT", treatment)], SALE)
    assert net == 110_000 and t[0].amount == 0 and t[0].treatment == treatment and taxes.line_treatment(t) == treatment


def test_a_single_rate_is_taken_out_of_the_price():
    net, t = taxes.split_inclusive(110_000, [scheme("VAT", rules=[rule(rate=10)])], SALE)
    assert (net, total(t), t[0].rate) == (100_000, 10_000, Decimal("10.000000"))


def test_sales_tax_and_vat_compound():
    # VAT is levied on the price including the sales tax: 100,000 + 5 % sales = 105,000; VAT 10 % of that = 10,500
    sales = scheme("SALES", rules=[rule(rate=5)], tax_type="SALES")
    vat = scheme("VAT", rules=[rule(rate=10, include=["SALES"])])
    net, t = taxes.split_inclusive(115_500, [vat, sales], SALE)
    by = {x.code: x for x in t}
    assert net == 100_000 and by["SALES"].amount == 5_000 and by["VAT"].amount == 10_500 and by["VAT"].base == 105_000
    assert [x.code for x in taxes._ordered([vat, sales])] == ["SALES", "VAT"]       # a tax on another tax comes after it


def test_a_levy_on_the_vat_for_another_authority():
    vat = scheme("VAT", rules=[rule(rate=10)])
    levy = scheme("RECON", rules=[rule(rate=2, base_type="TAXES", include=["VAT"])], tax_type="LEVY", payable=42)
    net, t = taxes.split_inclusive(110_200, [levy, vat], SALE)
    by = {x.code: x for x in t}
    assert net == 100_000 and by["VAT"].amount == 10_000 and by["RECON"].amount == 200 and by["RECON"].base == 10_000
    assert by["RECON"].payable_to_party_id == 42


def test_a_local_tax_applies_only_in_its_cities_and_a_product_tax_only_to_its_products():
    local = scheme("DAM-LEVY", rules=[rule(method="FIXED", amount=500)], tax_type="LEVY", scope={"origin_cities": ["DAM"]})
    fee_only = scheme("FEE-VAT", rules=[rule(rate=10)], scope={"products": ["BOOKING_FEE"]})
    assert taxes._applies(local, SALE) and not taxes._applies(local, Sale("SY", "CARRIER", "TICKET", origin_city="ALP"))
    assert not taxes._applies(fee_only, SALE) and taxes._applies(fee_only, Sale("SY", "PLATFORM", "BOOKING_FEE"))


def test_a_fixed_amount_per_booking_is_charged_once():
    stamp = scheme("STAMP", rules=[rule(method="FIXED", amount=1_000, per="BOOKING")], tax_type="STAMP")
    first = taxes.split_inclusive(50_000, [stamp], SALE, first_line=True)
    second = taxes.split_inclusive(50_000, [stamp], SALE, first_line=False)
    assert first == (49_000, first[1]) and total(first[1]) == 1_000 and total(second[1]) == 0 and second[0] == 50_000


def test_bands_whole_and_marginal():
    whole = scheme("BAND", rules=[rule(method="TIERED", bands=[
        Band("AMOUNT", Decimal(0), Decimal(100_000), Decimal(5), None, "WHOLE"),
        Band("AMOUNT", Decimal(100_000), None, Decimal(10), None, "WHOLE")])])
    assert total(taxes.taxes_on(80_000, [whole], SALE)) == 4_000 and total(taxes.taxes_on(200_000, [whole], SALE)) == 20_000
    marginal = scheme("PROG", rules=[rule(method="TIERED", bands=[
        Band("AMOUNT", Decimal(0), Decimal(100_000), Decimal(5), None, "MARGINAL"),
        Band("AMOUNT", Decimal(100_000), None, Decimal(10), None, "MARGINAL")])])
    assert total(taxes.taxes_on(200_000, [marginal], SALE)) == 5_000 + 10_000
    by_distance = scheme("KM", rules=[rule(method="TIERED", bands=[
        Band("DISTANCE", Decimal(0), Decimal(100), None, 500, "WHOLE"), Band("DISTANCE", Decimal(100), None, None, 1_500, "WHOLE")])])
    far = Sale("SY", "CARRIER", "TICKET", distance_km=Decimal(350))
    assert total(taxes.taxes_on(100_000, [by_distance], far)) == 1_500


def test_minimum_maximum_and_rounding():
    capped = scheme("CAP", rules=[rule(rate=10, max=3_000, min=200)])
    assert total(taxes.taxes_on(100_000, [capped], SALE)) == 3_000 and total(taxes.taxes_on(1_000, [capped], SALE)) == 200
    assert total(taxes.taxes_on(1_005, [scheme("D", rules=[rule(rate=10, rounding="DOWN")])], SALE)) == 100
    assert total(taxes.taxes_on(1_005, [scheme("U", rules=[rule(rate=10, rounding="UP")])], SALE)) == 101


def test_rules_of_one_scheme_combine():
    two = [rule(rate=5), Rule(2, "FIXED", None, 1_000, "FARE", [], "MAX", None, None, "HALF_UP", "TICKET", 100)]
    assert total(taxes.taxes_on(10_000, [scheme("M", rules=two)], SALE)) == 1_000          # the larger of 500 and 1,000
    cascade = [rule(rate=10), Rule(2, "PERCENT", Decimal(10), None, "FARE", [], "CASCADE", None, None, "HALF_UP", "TICKET", 100)]
    assert total(taxes.taxes_on(10_000, [scheme("C", rules=cascade)], SALE)) == 1_000 + 1_100


@pytest.mark.parametrize("gross", [1, 99, 1_105, 57_333, 999_999, 12_345_678])
def test_net_and_taxes_always_add_up_to_the_price(gross):
    sales = scheme("SALES", rules=[rule(rate=5)], tax_type="SALES")
    vat = scheme("VAT", rules=[rule(rate=11, include=["SALES"])])
    levy = scheme("RECON", rules=[rule(rate=2, base_type="TAXES", include=["VAT"])], tax_type="LEVY")
    stamp = scheme("STAMP", rules=[rule(method="FIXED", amount=50, per="BOOKING")], tax_type="STAMP")
    net, t = taxes.split_inclusive(gross, taxes._ordered([levy, vat, sales, stamp]), SALE)
    assert net + total(t) == gross and net >= 0


def test_a_credit_note_takes_back_each_tax_in_proportion():
    vat = taxes.LineTax(1, "VAT", "VAT", "STANDARD", Decimal(10), 100_000, 10_000, None)
    levy = taxes.LineTax(2, "RECON", "LEVY", "STANDARD", Decimal(2), 10_000, 200, 42)
    back = taxes.proportion([vat, levy], 55_100, 110_200)
    assert [(x.code, x.amount, x.base) for x in back] == [("VAT", 5_000, 50_000), ("RECON", 100, 5_000)]


def test_taxes_levied_on_each_other_in_a_loop_are_refused():
    a = scheme("A", rules=[rule(rate=1, include=["B"])])
    b = scheme("B", rules=[rule(rate=1, include=["A"])])
    with pytest.raises(Exception) as e:
        taxes._ordered([a, b])
    assert "TAX_SCHEME_LOOP" in str(e.value.__dict__) or "loop" in str(e.value)
