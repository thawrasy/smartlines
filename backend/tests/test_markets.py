"""Markets (schema file 1061, expert review stage D): a second market keeps its own time zone and currency.

The test opens Jordan for a moment, onboards a carrier there, and checks that its money is in dinars, its days in
Amman's time and that platform reports read one market at a time; it puts the market back as it was.
"""
import json
import secrets

import pytest

from test_e2e import OWNER_URL, client, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to open a market")
PERIOD = {"from": "2026-01-01", "to": "2026-12-31"}


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture
def jordan():
    owner_sql("UPDATE ref.market SET status = 'ACTIVE' WHERE country_code = 'JO'")
    try:
        yield
    finally:
        owner_sql("UPDATE ref.market SET status = 'PLANNED', opened_at = NULL WHERE country_code = 'JO'")


def test_the_default_market_is_named_to_visitors_and_users():
    m = client().get("/api/markets").json()
    assert m["default"] == {"country": "SY", "time_zone": "Asia/Damascus", "currency": "SYP", "locale": "ar", "minor_unit": 2}
    assert [x["country"] for x in m["markets"]] == ["SY"]
    assert login("passenger@masslak.test", "PASSENGER").get("/api/auth/me").json()["market"]["currency"] == "SYP"


def test_a_carrier_of_a_second_market_works_in_its_currency_and_time(admin, jordan):
    assert [x["country"] for x in client().get("/api/markets").json()["markets"]] == ["SY", "JO"]
    # opening the market gave the platform its wallets in dinars
    assert owner_sql("""SELECT count(*) FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
                         WHERE p.legal_name = 'Masslak Platform' AND w.currency = 'JOD'""") == 7
    code = "J" + "".join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ") for _ in range(2))
    r = admin.post("/api/admin/companies", json={
        "legal_name": f"Amman Lines {code}", "code3": code, "owner_name": "Amman Owner", "market": "JO",
        "owner_email": f"{code.lower()}{secrets.token_hex(2)}@example.com", "owner_password": "Jordan-Valley-2026!x"})
    assert r.status_code == 201, r.text
    cid = owner_sql("SELECT id FROM iam.party WHERE uid = $1::uuid", r.json()["uid"])
    assert owner_sql("SELECT country_code FROM iam.party WHERE id = $1", cid) == "JO"
    assert owner_sql("SELECT currency FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = 'COMPANY'", cid) == "JOD"
    assert owner_sql("SELECT ref.company_tz($1)", cid) == "Asia/Amman"
    # the default cash limit is in Syrian pounds: a carrier of another market sells for cash only once given its own
    assert owner_sql("SELECT fin.cash_limit($1)", cid) == 0
    # a market that is not open takes no company
    r = admin.post("/api/admin/companies", json={
        "legal_name": "Beirut Lines", "code3": "BXQ", "owner_name": "Beirut Owner", "market": "LB",
        "owner_email": f"bxq{secrets.token_hex(2)}@example.com", "owner_password": "Cedar-Coast-2026!x"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "MARKET_NOT_OPEN", r.text


def test_platform_reports_read_one_market_at_a_time(admin, jordan):
    syria = admin.post("/api/reports/run", json={"code": "ops.load_factor", "params": PERIOD})
    assert syria.status_code == 200 and syria.json()["rows"], syria.text
    amman = admin.post("/api/reports/run", json={"code": "ops.load_factor", "params": {**PERIOD, "market": "JO"}})
    assert amman.status_code == 200 and amman.json()["rows"] == [], amman.text      # no Jordanian trips yet
    doc = json.loads(admin.post("/api/reports/export", json={"code": "ops.load_factor", "format": "JSON",
                                                              "params": {**PERIOD, "market": "JO"}}).content)
    assert doc["timezone"] == "Asia/Amman" and doc["currency"] == "JOD"
    doc = json.loads(admin.post("/api/reports/export", json={"code": "ops.load_factor", "format": "JSON", "params": PERIOD}).content)
    assert doc["timezone"] == "Asia/Damascus" and doc["currency"] == "SYP"


def test_cash_owed_is_measured_per_currency(jordan):
    import os
    r = client().get("/api/metrics", headers={"Authorization": f"Bearer {os.environ.get('MASSLAK_METRICS_TOKEN', '')}"})
    if r.status_code != 200:
        pytest.skip("needs MASSLAK_METRICS_TOKEN")
    assert 'masslak_cash_owed_minor{currency="SYP"}' in r.text and 'masslak_cash_owed_minor{currency="JOD"}' in r.text
