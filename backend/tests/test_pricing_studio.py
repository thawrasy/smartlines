"""Pricing and tax studio (owner's note of 25 October 2026): a tax scheme is recorded with its rules in one step, put in
force by a second officer, replaced by a new version that ends the old one, and tried in the price preview before it is
approved; the preview's receipt always adds up to what the traveller pays."""
import uuid
from datetime import date, timedelta

import pytest

from test_e2e import OWNER_URL, login, owner_sql
from test_users_and_roles import NEW_PASSWORD, add_staff, role_uid

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def second(admin):
    email, _ = add_staff(admin, [role_uid(admin, "PLATFORM_ADMIN")])
    return login(email, "PLATFORM", NEW_PASSWORD)


@pytest.fixture(scope="module")
def country():
    """A country of its own, so the taxes of other tests do not mix in."""
    cc = owner_sql("""SELECT code FROM ref.country c WHERE NOT EXISTS (SELECT 1 FROM pricing.jurisdiction j WHERE j.country_code = c.code)
                      ORDER BY code LIMIT 1""")
    jid = owner_sql("INSERT INTO pricing.jurisdiction (country_code, level, name) VALUES ($1, 'COUNTRY', $2) RETURNING id",
                    cc, f"Studio {uuid.uuid4().hex[:4]}")
    return {"code": cc, "jurisdiction_id": jid}


def scheme(country, code, **kw):
    return {"code": code, "name": f"{code} test", "jurisdiction_id": country["jurisdiction_id"], "tax_type": "VAT",
            "valid_from": date.today().isoformat(), "rules": [{"calc_method": "PERCENT", "rate": 10}], **kw}


def preview(admin, country, **kw):
    r = admin.post("/api/admin/pricing/preview", json={"fare": 1_100_000, "country": country["code"], **kw})
    assert r.status_code == 200, r.text
    p = r.json()
    assert sum(s["amount"] for s in p["shares"]) == p["total_paid"]      # every unit paid goes somewhere
    return p


def test_a_tax_is_recorded_tried_approved_by_another_officer_and_versioned(admin, second, country):
    code = "VAT" + uuid.uuid4().hex[:5].upper()
    r = admin.post("/api/admin/pricing/taxes", json=scheme(country, code, valid_from=(date.today() - timedelta(days=1)).isoformat()))
    assert r.status_code == 422 and r.json()["error"]["code"] == "SCHEME_IN_PAST"
    r = admin.post("/api/admin/pricing/taxes", json={**scheme(country, code), "rules": []})
    assert r.status_code == 422                                                   # a standard tax needs a rule
    r = admin.post("/api/admin/pricing/taxes", json=scheme(country, code))
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    sid = r.json()["id"]
    assert admin.post("/api/admin/pricing/taxes", json=scheme(country, code)).json()["error"]["code"] == "SCHEME_EXISTS"

    # not in force yet: the preview carries no tax unless the officer tries the waiting scheme
    assert preview(admin, country)["total_tax"] == 0
    tried = preview(admin, country, try_ids=[sid])
    assert tried["ticket_taxes"][0]["amount"] == 100_000 and tried["ticket_net"] == 1_000_000 and tried["tried"] == [code]

    r = admin.post(f"/api/admin/pricing/taxes/{sid}/approve")
    assert r.status_code == 403 and r.json()["error"]["code"] == "SAME_OFFICER"
    assert second.post(f"/api/admin/pricing/taxes/{sid}/approve").json()["status"] == "ACTIVE"
    p = preview(admin, country, passengers=3)
    assert p["ticket_taxes"][0]["amount"] == 300_000 and p["ticket_net"] == 3_000_000

    # version 2 at 5 %, from tomorrow; approving it ends version 1 when it starts
    r = admin.post("/api/admin/pricing/taxes", json={**scheme(country, code), "from_id": sid, "valid_from": (date.today() + timedelta(days=1)).isoformat(),
                                                     "rules": [{"calc_method": "PERCENT", "rate": 5}]})
    assert r.status_code == 201 and r.json()["version"] == 2, r.text
    v2 = r.json()["id"]
    assert second.post(f"/api/admin/pricing/taxes/{v2}/approve").status_code == 200
    rows = {s["id"]: s for s in admin.get("/api/admin/pricing/taxes").json()["schemes"] if s["code"] == code}
    assert rows[sid]["in_force"] and rows[sid]["valid_to"] == rows[v2]["valid_from"] and rows[v2]["scheduled"]
    assert rows[v2]["summary"] == "5%" and rows[v2]["approved_by"] != rows[v2]["created_by"]
    later = preview(admin, country, at=(date.today() + timedelta(days=2)).isoformat())
    assert later["ticket_taxes"][0]["rate"] == 5.0
    # the rules of a scheme in force never change
    assert owner_sql("SELECT count(*) FROM pricing.tax_rule WHERE scheme_id = $1", sid) == 1
    for s in (sid, v2):
        assert admin.post(f"/api/admin/pricing/taxes/{s}/retire").json()["status"] == "RETIRED"


def test_a_levy_on_the_vat_and_a_stamp_per_booking_add_up(admin, second, country):
    tag = uuid.uuid4().hex[:4].upper()
    vat = admin.post("/api/admin/pricing/taxes", json=scheme(country, f"V{tag}")).json()["id"]
    levy = admin.post("/api/admin/pricing/taxes", json=scheme(country, f"L{tag}", tax_type="LEVY", rules=[
        {"calc_method": "PERCENT", "rate": 2, "base_type": "TAXES", "base_include": [f"V{tag}"]}])).json()["id"]
    stamp = admin.post("/api/admin/pricing/taxes", json=scheme(country, f"S{tag}", tax_type="STAMP", products=["TICKET"], rules=[
        {"calc_method": "FIXED", "amount": 5_000, "applies_per": "BOOKING"}])).json()["id"]
    bad = admin.post("/api/admin/pricing/taxes", json=scheme(country, f"X{tag}", rules=[
        {"calc_method": "PERCENT", "rate": 1, "base_type": "TAXES", "base_include": ["NOPE"]}]))
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "BASE_UNKNOWN"
    p = preview(admin, country, passengers=2, try_ids=[vat, levy, stamp], agency_commission_bp=500)
    by = {t["code"]: t for t in p["ticket_taxes"]}
    assert by[f"S{tag}"]["amount"] == 5_000                                       # once per booking, not per ticket
    assert abs(by[f"L{tag}"]["amount"] - by[f"V{tag}"]["amount"] * 0.02) <= 2      # 2 % of the VAT, rounded on each ticket
    assert p["agency_commission"] == 110_000 and p["ticket_net"] + sum(t["amount"] for t in p["ticket_taxes"]) == p["fares_total"]
    for s in (vat, levy, stamp):
        assert second.post(f"/api/admin/pricing/taxes/{s}/withdraw").json()["status"] == "RETIRED"
    assert admin.post(f"/api/admin/pricing/taxes/{vat}/approve").json()["error"]["code"] == "SCHEME_NOT_PENDING"


def test_the_preview_offers_methods_and_cities(admin):
    o = admin.get("/api/admin/pricing/preview-options")
    assert o.status_code == 200, o.text
    assert {"methods", "countries", "cities", "platform_fee"} <= set(o.json())


def test_only_platform_officers_open_the_studio():
    carrier = login("owner@carrier.test", "OPERATOR")
    assert carrier.get("/api/admin/pricing/taxes").status_code in (401, 403)
    assert carrier.post("/api/admin/pricing/preview", json={"fare": 1000}).status_code in (401, 403)


def commission_body(code, **kw):
    return {"code": code, "name": f"{code} test", "type": "INTERMEDIARY", "funded_by": "CARRIER", "base_type": "FARE",
            "channels": ["AGENCY"], "valid_from": date.today().isoformat(), "rules": [{"calc_method": "PERCENT", "rate": 4}], **kw}


def test_a_commission_is_recorded_tried_approved_and_frozen(admin, second, country):
    code = "AG" + uuid.uuid4().hex[:5].upper()
    bad = admin.post("/api/admin/pricing/commissions", json=commission_body(code, type="PLATFORM", funded_by="PLATFORM"))
    assert bad.status_code == 422                                                 # nobody pays themselves
    r = admin.post("/api/admin/pricing/commissions", json=commission_body(code))
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    cid = r.json()["id"]
    assert admin.post("/api/admin/pricing/commissions", json=commission_body(code)).json()["error"]["code"] == "SCHEME_EXISTS"
    # tried in the preview from an agency: 4 % of the fares, paid by the carrier to the agency; a web sale is untouched
    p = preview(admin, country, passengers=2, channel="AGENCY", try_commission_ids=[cid])
    line = next(x for x in p["commissions"] if x["code"] == code)
    assert line["amount"] == 88_000 and line["payer"] == "CARRIER" and line["receiver"] == "AGENCY" and line["tried"]
    assert not any(x["code"] == code for x in preview(admin, country, channel="WEB", try_commission_ids=[cid])["commissions"])
    assert admin.post(f"/api/admin/pricing/commissions/{cid}/approve").json()["error"]["code"] == "SAME_OFFICER"
    assert second.post(f"/api/admin/pricing/commissions/{cid}/approve").json()["status"] == "ACTIVE"
    row = next(s for s in admin.get("/api/admin/pricing/commissions").json()["schemes"] if s["id"] == cid)
    assert row["in_force"] and row["receiver"] == "AGENCY" and row["payer"] == "CARRIER" and row["rules"][0]["rate"] == 4.0
    frozen = owner_sql("SELECT count(*) FROM pricing.commission_rule WHERE scheme_id = $1", cid)
    assert frozen == 1
    v2 = admin.post("/api/admin/pricing/commissions", json=commission_body(code, from_id=cid, rules=[{"calc_method": "FIXED", "amount": 15_000}],
                                                                           valid_from=(date.today() + timedelta(days=1)).isoformat()))
    assert v2.status_code == 201 and v2.json()["version"] == 2, v2.text
    assert second.post(f"/api/admin/pricing/commissions/{v2.json()['id']}/withdraw").json()["status"] == "RETIRED"
    assert admin.post(f"/api/admin/pricing/commissions/{cid}/retire").json()["status"] == "RETIRED"


def test_a_commission_the_customer_pays_is_added_to_the_price(admin, country):
    code = "RF" + uuid.uuid4().hex[:5].upper()
    cid = admin.post("/api/admin/pricing/commissions", json=commission_body(code, type="REFERRAL", funded_by="CUSTOMER", channels=[],
                                                                            rules=[{"calc_method": "FIXED", "amount": 5_000}])).json()["id"]
    plain = preview(admin, country)
    tried = preview(admin, country, try_commission_ids=[cid])
    assert tried["total_paid"] == plain["total_paid"] + 5_000 and tried["traveller_commission"] == 5_000
    assert any(s["who"] == "REFERRER" and s["amount"] == 5_000 for s in tried["shares"])
    admin.post(f"/api/admin/pricing/commissions/{cid}/withdraw")
