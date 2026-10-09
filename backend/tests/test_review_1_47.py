"""Findings of the review of release 1.47.0 that need no server: production guards, statement amounts, the provider's
amount and currency (docs/operations/REVIEW_1_47_RESPONSE.md)."""
from decimal import Decimal
from types import SimpleNamespace

import pytest

from app import config
from app.errors import ApiError


@pytest.fixture()
def production(monkeypatch):
    """A production server: no sandbox, no environment declared."""
    monkeypatch.setenv("MASSLAK_SANDBOX", "false")
    monkeypatch.delenv("MASSLAK_ENVIRONMENT", raising=False)
    config.get_settings.cache_clear()
    yield monkeypatch
    config.get_settings.cache_clear()


# ------------------------------------------------------------------ R-27 message logs
def test_message_log_is_refused_outside_the_sandbox(production):
    from app.modules.notify import providers
    for channel in ("EMAIL", "SMS"):
        production.delenv(f"MASSLAK_NOTIFY_{channel}", raising=False)
    assert providers.mode("EMAIL") == "off" and providers.mode("SMS") == "off"      # unset is off, not a plain log
    providers.require_in_production()
    with pytest.raises(providers.ChannelOff):
        providers.send_email("a@example.test", "subject", "body")
    production.setenv("MASSLAK_NOTIFY_SMS", "log")
    with pytest.raises(providers.NotifyConfigError, match="sandbox only"):
        providers.require_in_production()
    with pytest.raises(providers.NotifyConfigError):
        providers.send_sms("+963944000111", "code 123456")
    production.setenv("MASSLAK_NOTIFY_SMS", "carrier-pigeon")
    with pytest.raises(providers.NotifyConfigError, match="not one of"):
        providers.require_in_production()
    production.setenv("MASSLAK_NOTIFY_SMS", "http")
    providers.require_in_production()
    production.setenv("MASSLAK_SANDBOX", "true")                  # the sandbox keeps its message log
    production.delenv("MASSLAK_NOTIFY_SMS")
    config.get_settings.cache_clear()
    assert providers.mode("SMS") == "log"


# ------------------------------------------------------------------ R-29 local key wrapper
def test_local_key_wrapper_is_for_test_servers_only(production):
    import base64
    import os

    from app import kms
    production.setenv("MASSLAK_KMS_PROVIDER", "local")
    production.setenv("MASSLAK_KEK", base64.b64encode(os.urandom(32)).decode())
    with pytest.raises(kms.KmsError, match="test servers only"):
        kms.provider()
    production.setenv("MASSLAK_ENVIRONMENT", "production")
    config.get_settings.cache_clear()
    with pytest.raises(kms.KmsError):
        kms.provider()
    production.setenv("MASSLAK_ENVIRONMENT", "staging")
    config.get_settings.cache_clear()
    assert kms.provider().name == "local"


# ------------------------------------------------------------------ R-25 documents
def test_document_access_needs_the_filing_or_review_permission():
    from app.modules.documents.service import _require_document_access
    allowed = [("OPERATOR", {"company.staff"}), ("OPERATOR", {"vehicle.manage"}), ("AGENCY", {"company.billing"}),
               ("PLATFORM", {"company.approve"})]
    refused = [("OPERATOR", {"booking.sell", "trip.board"}), ("AGENCY", {"booking.sell"}), ("PLATFORM", {"ledger.reconcile"}),
               ("PLATFORM", {"company.staff"})]
    for portal, perms in allowed:
        _require_document_access(SimpleNamespace(portal=portal, permissions=perms))
    for portal, perms in refused:
        with pytest.raises(ApiError) as e:
            _require_document_access(SimpleNamespace(portal=portal, permissions=perms))
        assert e.value.status == 403, (portal, perms)


# ------------------------------------------------------------------ R-19 the provider's amount and currency
def test_a_confirmation_matches_only_in_the_payment_currency():
    from app.modules.payments.adapters import Notice
    from app.modules.payments.service import notice_matches
    pay = {"amount": 500000, "currency": "SYP"}
    n = lambda amount, currency: Notice("e", "r", "SUCCESS", amount, currency)   # noqa: E731
    assert notice_matches(n(500000, "SYP"), pay) and notice_matches(n(500000, None), pay)
    assert not notice_matches(n(500000, "USD"), pay), "the same number in another currency is not the same payment"
    assert not notice_matches(n(499999, "SYP"), pay)


def test_partner_wallet_confirmation_takes_what_the_provider_reports(monkeypatch):
    from app.modules.payments import adapters
    provider = {"code": "EWALLET", "config": {"base_url": "https://psp.example"}, "adapter": "PARTNER_WALLET"}
    payment = {"provider_ref": "W1", "amount": 500000, "currency": "SYP"}
    monkeypatch.setattr(adapters, "simulated", lambda p: False)
    answers = iter([{"status": "SUCCESS", "amount": 500000, "currency": "USD", "event_id": "x"},
                    {"status": "SUCCESS"},
                    {"status": "SUCCESS", "amount": 500000}])
    monkeypatch.setattr(adapters, "_call", lambda *a, **k: next(answers))
    first = adapters.PartnerWallet().confirm(provider, payment, "123456")
    assert first.currency == "USD", "never the currency that was asked"
    assert adapters.PartnerWallet().confirm(provider, payment, "123456") is None, "no amount: wait for the signed notice"
    assert adapters.PartnerWallet().confirm(provider, payment, "123456").currency is None


# ------------------------------------------------------------------ R-24 statement amounts
@pytest.mark.parametrize("text,mark,expected", [
    ("2500.50", ".", "2500.50"), ("2,500.50", ".", "2500.50"), ("1,234,567", ".", "1234567"),
    ("1.234,50", ",", "1234.50"), ("2500,5", ",", "2500.5"), ("1 234,50", ",", "1234.50"),
    ("SYP 30,000", ".", "30000"), ("-125.00", ".", "-125.00"), ("(125.00)", ".", "-125.00"),
    ("\u0663\u0660\u0660\u0660\u066b\u0665", ".", "3000.5"),
])
def test_statement_amounts_read_with_the_file_decimal_mark(text, mark, expected):
    from app.modules.payments.service import parse_amount
    assert parse_amount(text, mark) == Decimal(expected)


@pytest.mark.parametrize("text,mark", [
    ("1.234,50", "."),          # was read as 1.23450 and then as 123 minor units
    ("1,234.50", ","), ("100,00", "."), ("1.2.3", ","), ("", "."), ("abc", "."), ("12,34,567", "."),
])
def test_statement_amounts_that_do_not_fit_the_mark_are_refused(text, mark):
    from app.modules.payments.service import parse_amount
    with pytest.raises(ApiError) as e:
        parse_amount(text, mark)
    assert e.value.code == "STATEMENT_BAD_AMOUNT"


def test_minor_units_follow_the_currency():
    from app.modules.payments.service import to_minor
    assert to_minor(Decimal("2500.50"), 2) == 250050
    assert to_minor(Decimal("1.234"), 3) == 1234                # Kuwaiti and Jordanian dinars have three decimals
    assert to_minor(Decimal("1500"), 0) == 1500                 # currencies without minor units
    with pytest.raises(ApiError):
        to_minor(Decimal("1500.5"), 0)                          # never rounded away
    with pytest.raises(ApiError):
        to_minor(Decimal("10.005"), 2)
