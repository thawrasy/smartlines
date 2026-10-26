"""Fuel stations (owner's notes of 25 and 26 October 2026, 1180, 1181): the platform adds a fuel company and its station,
registers secure NFC tags and issues them to a carrier, and records the carrier's advance payment for its vehicle's
subscription; the carrier opens an account with the fuel company, gives its vehicle a card with a daily budget and binds a
tag to it; the fuel company records the sum it received; the attendant identifies the vehicle (the driver's code, the
tag's signed tap), answers the challenge the risk asks for (the pump's QR sticker, the odometer's photo) with live
photos only; a reused photo or a meter off the price holds the fill; the pump controller confirms a fill; the platform
counts its commissions; the owner pauses the card, reports the tag lost, and is told of each fill."""
import io
import uuid
from datetime import datetime, timezone

import pytest
from PIL import Image

from app.modules.fuel import assurance
from test_boarding_stations import ADMIN, CARRIER
from test_e2e import OWNER_URL, client, login, owner_sql, settle_password

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def frame(exif: bool = False) -> bytes:
    """A camera frame as the pump app sends it: a JPEG with no metadata (or, to be refused, one a camera app wrote)."""
    img = Image.effect_noise((320, 240), 80).convert("RGB")
    buf = io.BytesIO()
    if exif:
        tags = Image.Exif()
        tags[0x010F] = "PhoneMaker"
        img.save(buf, "JPEG", exif=tags.tobytes())
    else:
        img.save(buf, "JPEG")
    return buf.getvalue()


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


def fill(staff, seen: dict, codes: dict, litres, amount, odometer, photo=b"auto", odo_photo=None, by_qr=False):
    """Fills answering the identification's challenge: the pump's sticker and the odometer's photo when it asks for them."""
    ch = seen["challenge"]
    pump = seen["pumps"][0]
    data = {"challenge_uid": ch["uid"], "fuel_type": "DIESEL", "litres": str(litres), "amount": str(amount),
            "odometer_km": str(odometer)}
    if ch["need_pump_qr"] or by_qr:
        data["pump_code"] = codes[pump["uid"]]
    else:
        data["pump_uid"] = pump["uid"]
    files = {}
    if photo is not None:
        files["photo_file"] = ("meter.jpg", frame() if photo == b"auto" else photo, "image/jpeg")
    if ch["need_odometer_photo"] or odo_photo:
        files["odometer_photo"] = ("odometer.jpg", odo_photo or frame(), "image/jpeg")
    return staff.post("/api/fuel/pump/fill", data=data, files=files or None)


def test_a_vehicle_fills_from_its_prepaid_account_within_its_budget_and_the_owner_is_told():
    admin = login(*ADMIN)
    carrier = login(*CARRIER)
    module(admin, True)
    serial = "04" + uuid.uuid4().hex[:12].upper()
    label = "T-" + uuid.uuid4().hex[:6].upper()
    try:
        # the platform adds a fuel company with its owner, and one station with four pumps
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
        assert admin.post(f"/api/admin/fuel/companies/{fuel_uid}/terms",
                          json={"commission_pct": "2", "valid_from": datetime.now(timezone.utc).date().replace(day=1).isoformat()}).status_code == 201

        # the platform registers a secure tag from its programming bench and issues it to the carrier
        carrier_uid = owner_sql("""SELECT p.uid::text FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id
                                    JOIN iam.party p ON p.id = m.company_id WHERE u.email = $1 LIMIT 1""", CARRIER[0])
        assert admin.post("/api/admin/fuel/tags", json={"kind": "SECURE", "batch": "test", "tags": [{"serial": serial, "label": label}]}).status_code == 201
        assert admin.post("/api/admin/fuel/tags/issue", json={"company_uid": carrier_uid, "labels": [label]}).json()["issued"] == 1

        staff = fuel_session(company)
        assert staff.get("/api/auth/me").json()["portal"] == "FUEL"
        assert staff.post(f"/api/fuel/stations/{station}/prices", json={"fuel_type": "DIESEL", "unit_price": 50000}).status_code == 201
        people = staff.get("/api/fuel/staff").json()["people"]
        assert staff.post(f"/api/fuel/stations/{station}/attendants", json={"user_uid": people[0]["uid"]}).status_code == 201
        pumps = staff.get(f"/api/fuel/stations/{station}/pumps").json()["pumps"]
        assert len(pumps) == 4 and all(p["code"].startswith("FP1") for p in pumps)
        codes = {p["uid"]: p["code"] for p in pumps}

        # the carrier subscribes its vehicle for a month; the platform records the advance payment
        view = carrier.get("/api/carrier/fuel").json()
        assert view["enabled"] and any(c["uid"] == fuel_uid for c in view["fuel_companies"])
        assert any(t["label"] == label and not t["bound"] for t in view["tags"])
        vehicle = next(v for v in view["vehicles"]
                       if not any(c["vehicle_uid"] == v["uid"] and c["status"] in ("ACTIVE", "PAUSED") for c in view["cards"]))
        today = owner_sql("SELECT ptn.company_today(id)::text FROM iam.company WHERE id = (SELECT id FROM iam.party WHERE uid = $1::uuid)", carrier_uid)
        r = carrier.post("/api/carrier/fuel/subscriptions", json={"period": "MONTH", "starts_on": today, "vehicle_uids": [vehicle["uid"]]})
        assert r.status_code == 201, r.text
        sub = r.json()["uid"]
        assert carrier.post(f"/api/admin/fuel/subscriptions/{sub}/confirm", json={"reference": "x"}).status_code == 403
        r = admin.post(f"/api/admin/fuel/subscriptions/{sub}/confirm", json={"price_per_vehicle": 2500000, "commission_pct": "1",
                                                                              "reference": "bank transfer 55"})
        assert r.status_code == 200 and r.json()["amount"] == 2500000, r.text

        # an account with the fuel company, and a card with a daily budget of 6 000 000 minor units
        r = carrier.post("/api/carrier/fuel/accounts", json={"fuel_company_uid": fuel_uid, "low_balance": 5000000})
        assert r.status_code == 201, r.text
        account = r.json()["uid"]
        r = carrier.post("/api/carrier/fuel/cards", json={"vehicle_uid": vehicle["uid"], "account_uid": account, "fuel_types": ["DIESEL"],
                                                          "budget_period": "DAY", "budget_amount": 6000000})
        assert r.status_code == 201, r.text
        card = r.json()["uid"]
        assert carrier.post("/api/carrier/fuel/cards", json={"vehicle_uid": vehicle["uid"], "account_uid": account,
                                                             "fuel_types": ["DIESEL"]}).json()["error"]["code"] == "FUEL_CARD_EXISTS"
        assert carrier.post("/api/carrier/fuel/cards", json={"vehicle_uid": vehicle["uid"], "account_uid": account, "fuel_types": ["DIESEL"],
                                                             "budget_period": "DAY"}).status_code == 422
        # the carrier binds the tag by reading it with its phone (the tag's signed message), then sticks it on
        r = carrier.post(f"/api/carrier/fuel/cards/{card}/tag", json={"sun": "https://masslak.com/t?" + assurance.sun_message(serial, 1)})
        assert r.status_code == 200 and r.json()["label"] == label, r.text

        # the fuel company records the sum it received; the carrier cannot
        assert staff.post(f"/api/fuel/accounts/{account}/topup", json={"amount": 10000000, "reference": "receipt 9"}).json()["balance"] == 10000000
        assert carrier.post(f"/api/fuel/accounts/{account}/topup", json={"amount": 1}).status_code == 403

        # the driver's app code identifies the vehicle; an altered code is refused
        pump_code = carrier.get(f"/api/carrier/fuel/cards/{card}/code").json()["code"]
        bad = pump_code[:-2] + ("AA" if pump_code[-2:] != "AA" else "BB")
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "code": bad}).json()["error"]["code"] == "FUEL_CODE_INVALID"
        seen = staff.post("/api/fuel/pump/identify", json={"station_uid": station, "code": pump_code}).json()
        assert seen["can_fill"] and seen["budget"]["left_amount"] == 6000000 and seen["prices"]["DIESEL"] == 50000
        assert seen["identified_by"] == "APP" and seen["plate_no"] == vehicle["plate_no"] and "app_code" in seen["challenge"]["factors"]
        # the secure tag: its signed tap identifies the vehicle; a replayed tap or a forged one is refused
        tap = staff.post("/api/fuel/pump/identify", json={"station_uid": station, "sun": assurance.sun_message(serial, 2)}).json()
        assert tap["card_uid"] == card and tap["tag_kind"] == "SECURE" and "plain_tag" not in tap["challenge"]["factors"], tap
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "sun": assurance.sun_message(serial, 2)}).json()["error"]["code"] == "FUEL_TAG_REPLAY"
        forged = assurance.sun_message(serial, 3)[:-4] + "0000"
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "sun": forged}).json()["error"]["code"] == "FUEL_TAG_FORGED"
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "tag": serial}).json()["error"]["code"] == "FUEL_TAG_SECURE"

        # a fill without the meter's photo, or with a saved picture, is refused; a live one that matches completes
        last = owner_sql("""SELECT max(r.value_km) FROM ptn.odometer_reading r JOIN fleet.vehicle v ON v.id = r.vehicle_id
                             WHERE v.uid = $1::uuid""", vehicle["uid"])
        start_km = (last or 200000) + 1000          # above the vehicle's last reading, so a rerun is not an odometer going back
        assert fill(staff, tap, codes, 40, 2000000, start_km, photo=None).json()["error"]["code"] == "FUEL_PHOTO_REQUIRED"
        assert fill(staff, tap, codes, 40, 2000000, start_km, photo=frame(exif=True)).json()["error"]["code"] == "FUEL_PHOTO_NOT_LIVE"
        meter = frame()
        r = fill(staff, tap, codes, 40, 2000000, start_km, photo=meter)
        assert r.status_code == 201, r.text
        ok = r.json()
        assert ok["status"] == "COMPLETED" and ok["balance"] == 8000000 and ok["left_amount"] == 4000000, ok
        assert fill(staff, tap, codes, 10, 500000, start_km + 10).json()["error"]["code"] == "FUEL_CHALLENGE_USED"

        # soon after a fill the risk asks for more: the pump's sticker and the odometer's photo
        seen = staff.post("/api/fuel/pump/identify", json={"station_uid": station, "code": pump_code}).json()
        assert seen["challenge"]["need_pump_qr"] and seen["challenge"]["need_odometer_photo"] and "recent_fill" in seen["challenge"]["factors"]
        data = {"challenge_uid": seen["challenge"]["uid"], "fuel_type": "DIESEL", "litres": "20", "amount": "1000000",
                "odometer_km": str(start_km + 400), "pump_uid": pumps[0]["uid"]}
        assert staff.post("/api/fuel/pump/fill", data=data, files={"photo_file": ("m.jpg", frame(), "image/jpeg"),
                                                                     "odometer_photo": ("o.jpg", frame(), "image/jpeg")}).json()["error"]["code"] == "FUEL_PUMP_QR"
        assert fill(staff, seen, codes, 100, 5000000, start_km + 400).json()["error"]["code"] == "FUEL_BUDGET"
        # the meter shows more than litres x price, and the photo is the earlier one again: held for review
        r = fill(staff, seen, codes, 20, 1200000, start_km + 400, photo=meter)
        held = r.json()
        assert held["status"] == "HELD" and sorted(a["type"] for a in held["anomalies"]) == ["AMOUNT_MISMATCH", "PHOTO_REUSED"], held

        # the owner is told of every fill
        n = owner_sql("""SELECT count(*) FROM sys.outbox_event WHERE event_type = 'fuel.filled'
                          AND payload ->> 'sale_uid' IN ($1, $2)""", ok["sale_uid"], held["sale_uid"])
        assert n == 2
        assert owner_sql("SELECT (payload ->> 'held')::boolean FROM sys.outbox_event WHERE event_type = 'fuel.filled' AND payload ->> 'sale_uid' = $1",
                         held["sale_uid"]) is True

        # both sides see the fill and its photos; the carrier decides the anomalies, the fuel company gives the fill back
        fills = carrier.get("/api/carrier/fuel/fills", params={"vehicle_uid": vehicle["uid"]}).json()["fills"]
        assert {f["uid"] for f in fills} >= {ok["sale_uid"], held["sale_uid"]}
        photo = carrier.get(f"/api/carrier/fuel/fills/{ok['sale_uid']}/photo")
        assert photo.status_code == 200 and photo.content == meter
        assert carrier.get(f"/api/carrier/fuel/fills/{held['sale_uid']}/photo", params={"kind": "odometer"}).status_code == 200
        assert staff.get(f"/api/fuel/fills/{held['sale_uid']}/photo").status_code == 200
        for a in next(f for f in fills if f["uid"] == held["sale_uid"])["anomalies"]:
            outcome = "CONFIRMED" if a["type"] == "AMOUNT_MISMATCH" else "EXPLAINED"
            r = carrier.post(f"/api/carrier/fuel/anomalies/{a['uid']}", json={"outcome": outcome, "note": "the driver paid less"})
            assert r.status_code == 200, r.text
        assert r.json()["sale_status"] == "DISPUTED", r.text
        assert staff.post(f"/api/fuel/fills/{held['sale_uid']}/reverse", json={"reason": "meter misread, refunded"}).json()["balance"] == 8000000
        acc = staff.get(f"/api/fuel/accounts/{account}").json()
        assert [e["kind"] for e in acc["entries"]][:4] == ["REVERSAL", "FILL", "FILL", "TOPUP"]
        assert carrier.post(f"/api/carrier/fuel/fills/{ok['sale_uid']}/query", json={"note": "the odometer looks wrong"}).status_code == 201

        # with the station's pump controller: the fill waits for the pump's own figures, which confirm it
        key = staff.post(f"/api/fuel/stations/{station}/controller").json()["key"]
        seen = staff.post("/api/fuel/pump/identify", json={"station_uid": station, "code": pump_code}).json()
        assert "no_pump_controller" not in seen["challenge"]["factors"]
        r = fill(staff, seen, codes, 10, 500000, start_km + 800, by_qr=True)
        pending = r.json()
        assert pending["status"] == "HELD" and [a["type"] for a in pending["anomalies"]] == ["PUMP_UNCONFIRMED"], pending
        delivery = {"pump_no": pending["pump_no"], "ref": "DLV-" + uuid.uuid4().hex[:8], "fuel_type": "DIESEL", "litres": "10",
                    "amount": 500000, "ended_at": datetime.now(timezone.utc).isoformat()}
        assert client().post("/api/pump/deliveries", json=delivery, headers={"X-Pump-Key": "fpk_wrong"}).status_code == 401
        r = client().post("/api/pump/deliveries", json=delivery, headers={"X-Pump-Key": key})
        assert r.status_code == 200 and r.json()["agrees"] and r.json()["sale_status"] == "COMPLETED", r.text

        # the platform's commissions: from the carrier (its subscription) and from the fuel company (its terms)
        month = datetime.now(timezone.utc).strftime("%Y-%m")
        rows = admin.get("/api/admin/fuel/commissions", params={"month": month}).json()["rows"]
        assert any(x["company_uid"] == carrier_uid and x["side"] == "CARRIER" for x in rows)
        assert any(x["company_uid"] == fuel_uid and x["side"] == "FUEL_COMPANY" for x in rows)

        # consumption per vehicle; the owner pauses the card, then reports the tag lost
        cons = carrier.get("/api/carrier/fuel/consumption").json()["vehicles"]
        mine = next(v for v in cons if v["vehicle_uid"] == vehicle["uid"])
        assert mine["fills"] >= 1 and mine["litres"] >= 40     # earlier runs may have filled the same vehicle
        assert carrier.post(f"/api/carrier/fuel/cards/{card}/pause", json={"reason": "vehicle in the garage"}).status_code == 200
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "code": pump_code}).json()["reason"] == "CARD_PAUSED"
        assert carrier.post(f"/api/carrier/fuel/cards/{card}/resume").status_code == 200
        assert carrier.post(f"/api/carrier/fuel/cards/{card}/tag-lost").status_code == 200
        assert staff.post("/api/fuel/pump/identify", json={"station_uid": station, "sun": assurance.sun_message(serial, 9)}).json()["error"]["code"] == "FUEL_TAG_STOPPED"
        overview = staff.get("/api/fuel/overview").json()
        assert overview["stations"][0]["today"]["fills"] == 2 and overview["accounts"][0]["balance"] == 7500000
        assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action LIKE 'fuel.%'") >= 12
    finally:
        owner_sql("UPDATE ptn.fuel_card SET status = 'RETIRED', paused_reason = NULL WHERE company_id = (SELECT company_id FROM iam.company_member m "
                  "JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = $1 LIMIT 1) AND status <> 'RETIRED'", CARRIER[0])
        module(admin, False)
