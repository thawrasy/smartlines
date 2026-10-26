"""Fuel stations (owner's note of 25 October 2026, 1180): the platform adds a fuel company and its station; the carrier
opens an account with it and gives its vehicle a card with a daily budget; the fuel company records the sum it received;
the attendant identifies the vehicle by the driver's code, binds an NFC card, fills with the meter's photo; a fill off
the price is held, the carrier decides it, the fuel company gives it back; the owner is told of each fill."""
import uuid

import pytest

from test_boarding_photo import JPEG
from test_boarding_stations import ADMIN, CARRIER
from test_e2e import OWNER_URL, client, login, owner_sql, settle_password

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def fuel_session(company: dict):
    """Sign in to the FUEL portal with the second factor the owner's account requires (as the station portal's tests)."""
    from app import mfa
    c = client()
    r = c.post("/api/auth/login", json={"identifier": company["email"], "password": company["password"], "portal": "FUEL"})
    assert r.status_code == 200, r.text
    if "secret" not in company:
        start = c.post("/api/auth/mfa/enroll")
        assert start.status_code == 200, start.text
        company["secret"], company["step"] = start.json()["secret"], mfa.current_step()
        done = c.post("/api/auth/mfa/confirm", json={"code": mfa.code_at(company["secret"], company["step"])})
    else:
        company["step"] = max(mfa.current_step(), company["step"] + 1)
        done = c.post("/api/auth/mfa/verify", json={"code": mfa.code_at(company["secret"], company["step"])})
    assert done.status_code == 200, done.text
    return c


def module(admin, on: bool) -> None:
    r = admin.put("/api/admin/modules/service_partners", json={"enabled": on, "reason": "automated test of fuel stations (1180)"})
    assert r.status_code == 200, r.text


def fill(staff, station, card, by, litres, amount, odometer, photo=True):
    data = {"station_uid": station, "card_uid": card, "identified_by": by, "fuel_type": "DIESEL",
            "litres": str(litres), "amount": str(amount), "odometer_km": str(odometer), "pump": "P2"}
    files = {"photo_file": ("meter.jpg", JPEG, "image/jpeg")} if photo else None
    return staff.post("/api/fuel/pump/fill", data=data, files=files)


def test_a_vehicle_fills_from_its_prepaid_account_within_its_budget_and_the_owner_is_told():
    admin = login(*ADMIN)
    carrier = login(*CARRIER)
    module(admin, True)
    tag = "04:A2:" + uuid.uuid4().hex[:8].upper()
    try:
        # the platform adds a fuel company with its owner, and one station
        company = {"email": f"fuel-{uuid.uuid4().hex[:8]}@example.com", "password": f"Pump-{uuid.uuid4().hex[:10]}-26!q"}
        r = admin.post("/api/admin/fuel/companies", json={"legal_name": "Test Fuel " + uuid.uuid4().hex[:4], "owner_name": "Fuel Owner",
                                                           "owner_email": company["email"], "owner_password": company["password"]})
        assert r.status_code == 201, r.text
        fuel_uid = r.json()["uid"]
        settle_password(company["email"])
        code = "FT-" + uuid.uuid4().hex[:6].upper()
        r = admin.post(f"/api/admin/fuel/companies/{fuel_uid}/stations", json={"name": "Test Station North", "code": code, "pumps": 4})
        assert r.status_code == 201, r.text
        station = r.json()["uid"]
        assert carrier.post("/api/fuel/pump/identify", json={"station_uid": station, "card_no": "ABCDEFGH"}).status_code == 403

        staff = fuel_session(company)
        me = staff.get("/api/auth/me")
        assert me.status_code == 200 and me.json()["portal"] == "FUEL", me.text
        assert staff.post(f"/api/fuel/stations/{station}/prices", json={"fuel_type": "DIESEL", "unit_price": 50000}).status_code == 201
        people = staff.get("/api/fuel/staff").json()["people"]
        assert staff.post(f"/api/fuel/stations/{station}/attendants", json={"user_uid": people[0]["uid"]}).status_code == 201

        # the carrier opens an account and gives a vehicle a card with a daily budget of 60 000 (6 000 000 in minor units)
        view = carrier.get("/api/carrier/fuel").json()
        assert view["enabled"] and any(c["uid"] == fuel_uid for c in view["fuel_companies"])
        r = carrier.post("/api/carrier/fuel/accounts", json={"fuel_company_uid": fuel_uid, "low_balance": 5000000})
        assert r.status_code == 201, r.text
        account = r.json()["uid"]
        vehicle = next(v for v in view["vehicles"] if not any(c["vehicle_uid"] == v["uid"] and c["status"] == "ACTIVE" for c in view["cards"]))
        r = carrier.post("/api/carrier/fuel/cards", json={"vehicle_uid": vehicle["uid"], "account_uid": account, "fuel_types": ["DIESEL"],
                                                          "budget_period": "DAY", "budget_amount": 6000000})
        assert r.status_code == 201, r.text
        card = r.json()["uid"]
        assert carrier.post("/api/carrier/fuel/cards", json={"vehicle_uid": vehicle["uid"], "account_uid": account,
                                                             "fuel_types": ["DIESEL"]}).json()["error"]["code"] == "FUEL_CARD_EXISTS"
        assert carrier.post("/api/carrier/fuel/cards", json={"vehicle_uid": vehicle["uid"], "account_uid": account, "fuel_types": ["DIESEL"],
                                                             "budget_period": "DAY"}).status_code == 422

        # the fuel company records the sum it received; the carrier cannot
        assert staff.post(f"/api/fuel/accounts/{account}/topup", json={"amount": 10000000, "reference": "receipt 9"}).json()["balance"] == 10000000
        assert carrier.post(f"/api/fuel/accounts/{account}/topup", json={"amount": 1}).status_code == 403

        # the driver's app code identifies the vehicle; an altered code is refused; a new NFC card is bound with it
        pump_code = carrier.get(f"/api/carrier/fuel/cards/{card}/code").json()["code"]
        bad = pump_code[:-2] + ("AA" if pump_code[-2:] != "AA" else "BB")
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "code": bad}).json()["error"]["code"] == "FUEL_CODE_INVALID"
        seen = staff.post("/api/fuel/pump/identify", json={"station_uid": station, "code": pump_code}).json()
        assert seen["can_fill"] and seen["budget"]["left_amount"] == 6000000 and seen["prices"]["DIESEL"] == 50000
        assert seen["identified_by"] == "APP" and seen["plate_no"] == vehicle["plate_no"]
        assert staff.post("/api/fuel/pump/bind", json={"station_uid": station, "code": pump_code, "tag": tag}).status_code == 200
        by_tag = staff.post("/api/fuel/pump/identify", json={"station_uid": station, "tag": tag}).json()
        assert by_tag["card_uid"] == card and by_tag["tag_bound"]

        # a fill without the meter's photo is refused; one that matches completes and is paid from the account
        last = owner_sql("""SELECT max(r.value_km) FROM ptn.odometer_reading r JOIN fleet.vehicle v ON v.id = r.vehicle_id
                             WHERE v.uid = $1::uuid""", vehicle["uid"])
        start_km = (last or 200000) + 1000          # above the vehicle's last reading, so a rerun is not an odometer going back
        assert fill(staff, station, card, "NFC", 40, 2000000, start_km, photo=False).json()["error"]["code"] == "FUEL_PHOTO_REQUIRED"
        r = fill(staff, station, card, "NFC", 40, 2000000, start_km)
        assert r.status_code == 201, r.text
        ok = r.json()
        assert ok["status"] == "COMPLETED" and ok["balance"] == 8000000 and ok["left_amount"] == 4000000
        assert fill(staff, station, card, "NFC", 100, 5000000, start_km + 400).json()["error"]["code"] == "FUEL_BUDGET"

        # the meter shows more than litres x price: the fill is held for review
        r = fill(staff, station, card, "NFC", 20, 1200000, start_km + 400)
        held = r.json()
        assert held["status"] == "HELD" and [a["type"] for a in held["anomalies"]] == ["AMOUNT_MISMATCH"], held

        # the owner is told of every fill
        n = owner_sql("""SELECT count(*) FROM sys.outbox_event WHERE event_type = 'fuel.filled'
                          AND payload ->> 'sale_uid' IN ($1, $2)""", ok["sale_uid"], held["sale_uid"])
        assert n == 2
        assert owner_sql("SELECT (payload ->> 'held')::boolean FROM sys.outbox_event WHERE event_type = 'fuel.filled' AND payload ->> 'sale_uid' = $1",
                         held["sale_uid"]) is True

        # both sides see the fill and its photo; the carrier decides the anomaly, the fuel company gives the fill back
        fills = carrier.get("/api/carrier/fuel/fills", params={"vehicle_uid": vehicle["uid"]}).json()["fills"]
        assert {f["uid"] for f in fills} >= {ok["sale_uid"], held["sale_uid"]}
        photo = carrier.get(f"/api/carrier/fuel/fills/{ok['sale_uid']}/photo")
        assert photo.status_code == 200 and photo.content == JPEG
        assert staff.get(f"/api/fuel/fills/{held['sale_uid']}/photo").status_code == 200
        anomaly = next(f for f in fills if f["uid"] == held["sale_uid"])["anomalies"][0]
        r = carrier.post(f"/api/carrier/fuel/anomalies/{anomaly['uid']}", json={"outcome": "CONFIRMED", "note": "the driver paid less"})
        assert r.json()["sale_status"] == "DISPUTED", r.text
        assert staff.post(f"/api/fuel/fills/{held['sale_uid']}/reverse", json={"reason": "meter misread, refunded"}).json()["balance"] == 8000000
        acc = staff.get(f"/api/fuel/accounts/{account}").json()
        assert [e["kind"] for e in acc["entries"]][:4] == ["REVERSAL", "FILL", "FILL", "TOPUP"]

        # consumption per vehicle; a lost card is blocked and its tag unbound by the owner
        cons = carrier.get("/api/carrier/fuel/consumption").json()["vehicles"]
        mine = next(v for v in cons if v["vehicle_uid"] == vehicle["uid"])
        assert mine["fills"] >= 1 and mine["litres"] >= 40     # earlier runs may have filled the same vehicle
        assert carrier.post(f"/api/carrier/fuel/cards/{card}/block", json={"reason": "card lost"}).status_code == 200
        assert carrier.post(f"/api/carrier/fuel/cards/{card}/unbind").status_code == 200
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "tag": tag}).json()["error"]["code"] == "FUEL_CARD_UNKNOWN"
        overview = staff.get("/api/fuel/overview").json()
        assert overview["stations"][0]["today"]["fills"] == 1 and overview["accounts"][0]["balance"] == 8000000
        assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action LIKE 'fuel.%'") >= 8
    finally:
        owner_sql("UPDATE ptn.fuel_card SET status = 'RETIRED' WHERE company_id = (SELECT company_id FROM iam.company_member m "
                  "JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = $1 LIMIT 1) AND status <> 'RETIRED'", CARRIER[0])
        module(admin, False)
