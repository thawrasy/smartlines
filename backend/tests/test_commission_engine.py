"""The commission engine (1175) on its own: percentages, fixed amounts, bands, limits, scope and who pays whom."""
from decimal import Decimal

from app.modules.pricing import commission as c


def scheme(rules, type_="INTERMEDIARY", funded="CARRIER", base="FARE", scope=None):
    return c.CScheme(1, "C1", type_, funded, "agency", base, scope or {}, list(rules))


def rule(method="PERCENT", rate=None, amount=None, lo=None, hi=None, bands=()):
    return c.CRule(method, None if rate is None else Decimal(str(rate)), amount, lo, hi, list(bands))


def test_a_percentage_and_a_fixed_amount_add_up():
    assert c.amount(scheme([rule(rate=5)]), 1_000_000) == 50_000
    assert c.amount(scheme([rule(rate=2.5), rule("FIXED", amount=10_000)]), 1_000_000) == 35_000


def test_minimum_and_maximum_hold():
    assert c.amount(scheme([rule(rate=1, lo=20_000)]), 1_000_000) == 20_000
    assert c.amount(scheme([rule(rate=10, hi=50_000)]), 1_000_000) == 50_000


def test_bands_whole_and_marginal():
    whole = [c.CBand(Decimal(0), Decimal(500_000), Decimal(3), None, "WHOLE"), c.CBand(Decimal(500_000), None, Decimal(5), None, "WHOLE")]
    assert c.amount(scheme([rule("TIERED", bands=whole)]), 1_000_000) == 50_000          # all of it at 5 %
    marginal = [c.CBand(Decimal(0), Decimal(500_000), Decimal(3), None, "MARGINAL"), c.CBand(Decimal(500_000), None, Decimal(5), None, "MARGINAL")]
    assert c.amount(scheme([rule("TIERED", bands=marginal)]), 1_000_000) == 15_000 + 25_000


def test_scope_by_channel():
    s = scheme([rule(rate=5)], scope={"channels": ["AGENCY"]})
    assert c.applies(s, "AGENCY", None) and not c.applies(s, "WEB", None) and c.applies(scheme([rule(rate=1)]), "WEB", None)


def test_who_receives_and_who_pays():
    assert c.RECEIVER["OVERRIDE"] == "AGENCY" and c.RECEIVER["REFERRAL"] == "REFERRER" and c.PAYER["CHANNEL"] == "AGENCY"
    assert c.PAYER["CUSTOMER"] == "TRAVELLER"
