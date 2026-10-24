"""Points redeemed at partners under the agreements the platform records with each of them (1107), end to end: an
agreement written by one officer and activated by another, a voucher bought with points at the agreed rate, honoured
once by the partner's API client, the platform's share posted to the partner's wallet, the statement drafted, approved
and paid by three different people; an unused voucher gives its points back."""
import uuid
from datetime import date

import pytest

from test_e2e import OWNER_URL, client, login, owner_sql
from test_integration import make_client
from test_modules import switch
from test_notifications import run_worker

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _api(key):
    c = client()
    c.headers["X-Api-Key"] = key
    return c


def test_points_redeemed_at_a_partner_under_its_agreement():
    admin = login("admin@masslak.test", "PLATFORM")
    switch(admin, "loyalty_partners", True)
    marketing = owner_sql("SELECT id FROM iam.app_user WHERE email = 'treasury@masslak.test'")
    owner_sql("""INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = 'PLATFORM_MARKETING' AND company_id IS NULL
                 ON CONFLICT DO NOTHING""", marketing)
    try:
        program = owner_sql("SELECT id FROM pricing.loyalty_program WHERE status = 'ACTIVE' AND currency = 'SYP' ORDER BY id LIMIT 1")
        party = owner_sql("INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', $1) RETURNING id", f"Rest Stop {uuid.uuid4().hex[:6]}")
        partner = owner_sql("""INSERT INTO pricing.loyalty_partner (program_id, party_id, partner_type, status)
                               VALUES ($1, $2, 'REST_STOP', 'ACTIVE') RETURNING id""", program, party)
        pax = login("passenger@masslak.test", "PASSENGER")
        pax_party = owner_sql("SELECT party_id FROM iam.app_user WHERE email = 'passenger@masslak.test'")
        owner_sql("INSERT INTO pricing.points_account (program_id, party_id) VALUES ($1, $2) ON CONFLICT DO NOTHING", program, pax_party)
        account = owner_sql("SELECT id FROM pricing.points_account WHERE program_id = $1 AND party_id = $2", program, pax_party)
        owner_sql("""INSERT INTO pricing.points_ledger (account_id, txn_type, points, idempotency_key, expires_at)
                     VALUES ($1, 'EARN', 1000, $2, now() + interval '1 year')""", account, f"test-earn:{uuid.uuid4().hex}")
        owner_sql("UPDATE pricing.points_account SET balance = balance + 1000 WHERE id = $1", account)

        # the agreement: 100 points = SYP 10,000 at the partner, the platform pays it 80 %; a second officer activates it
        r = admin.post("/api/r/loyalty-agreement", json={"loyalty_partner_id": partner, "currency": "SYP", "points": 100, "amount": 1_000_000,
                                                         "platform_share_pct": 80, "min_points": 100, "step_points": 100,
                                                         "voucher_days": 30, "contract_ref": "RS-AGR-2026-01"})
        assert r.status_code == 201, r.text
        agreement = r.json()["_key"]
        assert admin.post(f"/api/r/loyalty-agreement/{agreement}/do/activate").json()["error"]["code"] == "FOUR_EYES"
        second = login("treasury@masslak.test", "PLATFORM")
        r = second.post(f"/api/r/loyalty-agreement/{agreement}/do/activate")
        assert r.status_code == 200, r.text
        frozen = admin.patch(f"/api/r/loyalty-agreement/{agreement}", json={"platform_share_pct": 100})
        assert frozen.status_code == 409 and frozen.json()["error"]["code"] == "AGREEMENT_FROZEN"

        # the member sees the partner and its rate (not what the platform pays it) and buys a voucher
        view = pax.get("/api/loyalty").json()
        offer = next(o for o in view["offers"] if o["points"] == 100 and o["amount"] == 1_000_000 and o["partner"].startswith("Rest Stop"))
        assert "platform_share_pct" not in offer
        before = view["account"]["balance"]
        bad = pax.post("/api/loyalty/vouchers", json={"agreement": offer["agreement"], "points": 150, "idempotency_key": uuid.uuid4().hex})
        assert bad.status_code == 409 and bad.json()["error"]["code"] == "POINTS_BAD_AMOUNT"
        key = uuid.uuid4().hex
        v = pax.post("/api/loyalty/vouchers", json={"agreement": offer["agreement"], "points": 300, "idempotency_key": key})
        assert v.status_code == 201, v.text
        voucher = v.json()
        assert voucher["value"] == 3_000_000 and voucher["code"].startswith("MV-") and voucher["balance"] == before - 300
        again = pax.post("/api/loyalty/vouchers", json={"agreement": offer["agreement"], "points": 300, "idempotency_key": key}).json()
        assert again["replayed"] and again["code"] == voucher["code"] and again["voucher"] == voucher["voucher"]
        assert any(x["code"] == voucher["code"] and x["status"] == "ISSUED" for x in pax.get("/api/loyalty").json()["vouchers"])

        # the partner's API client: checks the voucher, honours it once; another partner cannot see it
        client_uid, api_key = make_client(admin, login("security@masslak.test", "PLATFORM"), name="Rest stop till", kind="PARTNER",
                                          scopes=["vouchers:redeem"])
        client_id = owner_sql("SELECT id FROM iam.api_client WHERE uid = $1", uuid.UUID(client_uid))
        till = _api(api_key)
        assert till.post("/api/v1/loyalty/vouchers/check", json={"code": voucher["code"]}).json()["error"]["code"] == "PARTNER_NOT_CONFIGURED"
        owner_sql("UPDATE pricing.loyalty_partner SET api_client_id = $1 WHERE id = $2", client_id, partner)
        chk = till.post("/api/v1/loyalty/vouchers/check", json={"code": voucher["code"].lower().replace("-", " ")})
        assert chk.status_code == 200 and chk.json()["usable"] and chk.json()["value"] == 3_000_000, chk.text
        partner_wallet = owner_sql("SELECT fin.wallet_balance(id) FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = 'PARTNER'", party) or 0
        done = till.post("/api/v1/loyalty/vouchers/redeem", json={"code": voucher["code"], "reference": "TILL-7"})
        assert done.status_code == 201 and done.json()["payable"] == 2_400_000, done.text
        twice = till.post("/api/v1/loyalty/vouchers/redeem", json={"code": voucher["code"]})
        assert twice.status_code == 409 and twice.json()["error"]["code"] == "VOUCHER_USED"
        assert owner_sql("SELECT fin.wallet_balance(id) FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = 'PARTNER'", party) \
            == partner_wallet + 2_400_000
        assert owner_sql("""SELECT w.wallet_type FROM fin.ledger_txn x JOIN fin.ledger_entry e ON e.txn_id = x.id JOIN fin.wallet w ON w.id = e.wallet_id
                             WHERE x.idempotency_key = $1 AND e.direction = 'DR'""", f"partner-redemption:{done.json()['redemption']}") == "EXPENSE"
        today = date.today().isoformat()
        listed = till.get("/api/v1/loyalty/redemptions", params={"from": today})
        assert listed.status_code == 200 and any(x["reference"] == "TILL-7" for x in listed.json()["redemptions"])

        # an unused voucher is cancelled and its points come back
        other = pax.post("/api/loyalty/vouchers", json={"agreement": offer["agreement"], "points": 100, "idempotency_key": uuid.uuid4().hex}).json()
        assert pax.post(f"/api/loyalty/vouchers/{other['voucher']}/cancel").json()["points"] == 100
        assert pax.get("/api/loyalty").json()["account"]["balance"] == before - 300

        # the statement: drawn up by one officer, approved by another, paid by a third
        owed = next(p for p in admin.get("/api/admin/loyalty/partners").json()["partners"] if p["id"] == partner)
        assert owed["agreement"] and owed["unsettled_payable"] == 2_400_000
        st = admin.post("/api/admin/loyalty/settlements", json={"partner_id": partner, "date_from": today, "date_to": today})
        assert st.status_code == 201 and st.json()["payable"] == 2_400_000, st.text
        assert next(p for p in admin.get("/api/admin/loyalty/partners").json()["partners"] if p["id"] == partner)["unsettled"] == 0
        assert any(x["uid"] == st.json()["settlement"] and x["status"] == "DRAFT"
                   for x in admin.get("/api/admin/loyalty/settlements").json()["settlements"])
        sid = owner_sql("SELECT id FROM pricing.loyalty_settlement WHERE uid = $1", uuid.UUID(st.json()["settlement"]))
        assert admin.post(f"/api/r/loyalty-settlement/{sid}/do/approve").json()["error"]["code"] == "FOUR_EYES"
        assert second.post(f"/api/r/loyalty-settlement/{sid}/do/approve").status_code == 200
        finance = login("finance@masslak.test", "PLATFORM")
        early = admin.post(f"/api/admin/loyalty/settlements/{st.json()['settlement']}/pay", json={"bank_ref": "TRX-881"})
        assert early.status_code in (403, 409)
        paid = finance.post(f"/api/admin/loyalty/settlements/{st.json()['settlement']}/pay", json={"bank_ref": "TRX-881"})
        assert paid.status_code == 200 and paid.json()["status"] == "PAID", paid.text
        assert owner_sql("SELECT fin.wallet_balance(id) FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = 'PARTNER'", party) \
            == partner_wallet

        run_worker()
        told = [n["template_code"] for n in pax.get("/api/notifications").json()["notifications"]]
        assert "voucher.used" in told and "voucher.returned" in told
    finally:
        owner_sql("""DELETE FROM iam.user_role WHERE user_id = $1
                       AND role_id = (SELECT id FROM iam.role WHERE code = 'PLATFORM_MARKETING' AND company_id IS NULL)""", marketing)
        switch(admin, "loyalty_partners", False)
