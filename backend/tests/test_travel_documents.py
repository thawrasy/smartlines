"""International trips: a passport is required by default, and the platform can approve exceptions that accept other
documents (national ID, residence permit…) for a destination and nationality, drafted and approved by two officers."""
import secrets
import time
import uuid
from datetime import date, timedelta

import pytest

from test_e2e import OWNER_URL, day, login, new_passenger, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def officer():
    return login("security@masslak.test", "PLATFORM")


@pytest.fixture(scope="module", autouse=True)
def international_on(admin):
    on = {m["key"]: m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"]}["international"]
    if not on:
        assert admin.put("/api/admin/modules/international", json={"enabled": True, "reason": "document tests"}).status_code == 200
        time.sleep(6)
    # tests start from the platform default: no active rule for Lebanon
    owner_sql("UPDATE sales.entry_rule SET status = 'RETIRED' WHERE country_code = 'LB' AND status = 'ACTIVE'")
    yield
    owner_sql("UPDATE sales.entry_rule SET status = 'RETIRED' WHERE country_code = 'LB' AND status = 'ACTIVE'")


@pytest.fixture(scope="module")
def beirut_trip(admin):
    """Damascus to Beirut, published through the carrier API like any other trip."""
    stations = admin.get("/api/stations", params={"city": "BEY"}).json()["stations"]
    if not stations:
        r = admin.post("/api/admin/stations", json={"city_code": "BEY", "number": 1, "name": "Beirut Charles Helou Station",
                                                    "lat": 33.8990, "lng": 35.5140})
        assert r.status_code == 201, r.text
        stations = admin.get("/api/stations", params={"city": "BEY"}).json()["stations"]
    bey = stations[0]["uid"]
    dam = next(s for s in admin.get("/api/stations", params={"city": "DAM"}).json()["stations"] if s["station_class"] == "CENTRAL")["uid"]
    o = login("owner@carrier.test", "OPERATOR")
    code = f"DAM-BEY-{secrets.randbelow(9000) + 1000}"
    r = o.post("/api/carrier/routes", json={"code": code, "stops": [
        {"station_uid": dam, "arr_offset_min": 0, "dep_offset_min": 0, "fare_from_origin": 0},
        {"station_uid": bey, "arr_offset_min": 180, "dep_offset_min": 180, "fare_from_origin": 5500000}]})
    assert r.status_code == 201, r.text
    route = next(x for x in o.get("/api/carrier/routes").json()["routes"] if x["code"] == code)
    layout = next(x for x in o.get("/api/carrier/seat-layouts").json()["layouts"] if x["total_seats"] == 44)
    plate = str(100000 + secrets.randbelow(900000))
    r = o.post("/api/carrier/vehicles", json={
        "plate_no": plate, "chassis_no": f"CHS-I{plate}", "vehicle_type": "COACH", "seat_layout_uid": layout["uid"],
        "insurance_no": f"POL-I{plate}", "insurer": "Test", "insurance_issue": "2026-01-01", "insurance_expiry": "2030-01-01"})
    assert r.status_code == 201, r.text
    vehicle = r.json()["uid"]
    for _ in range(10):
        r = o.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": vehicle,
                                               "departure_local": f"{day(3)}T{6 + secrets.randbelow(12):02d}:{secrets.randbelow(60):02d}:00"})
        if r.status_code != 409:
            break
    assert r.status_code == 201, r.text
    pax = new_passenger()
    trips = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "BEY", "on": day(3), "passengers": 1}).json()["trips"]
    return next(t for t in trips if t["bookable"])


def passenger(seat, **doc):
    return {"nationality": "SY", "first_name": "Rami", "father_name": "Khaled", "grandfather_name": "Omar",
            "last_name": "Haddad", "seat_no": seat, **doc}


def try_book(c, trip, **doc):
    seats = c.get(f"/api/trips/{trip['uid']}", params={"from_seq": trip["from_seq"], "to_seq": trip["to_seq"]}).json()["seats"]
    seat = next(s["seat_no"] for s in seats if s["free"])
    h = c.post("/api/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "seat_nos": [seat]})
    assert h.status_code == 201, h.text
    r = c.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": trip["uid"], "from_seq": trip["from_seq"],
                                      "to_seq": trip["to_seq"], "idempotency_key": uuid.uuid4().hex, "passengers": [passenger(seat, **doc)]})
    if r.status_code != 201:
        c.delete(f"/api/holds/{h.json()['hold_token']}")
    return r


def docs(c, trip, nationality="SY"):
    return c.get(f"/api/trips/{trip['uid']}/documents", params={"from_seq": trip["from_seq"], "to_seq": trip["to_seq"],
                                                                "nationality": nationality}).json()


def test_international_trips_need_a_valid_passport(beirut_trip):
    pax = new_passenger()
    assert pax.post("/api/wallet/topup", json={"amount": 50_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    need = docs(pax, beirut_trip)
    assert need["international"] and need["destination"] == "LB"
    assert need["docs"] == ["PASSPORT"] and need["passport_min_days"] == 180 and not need["exception"]
    r = try_book(pax, beirut_trip, id_type="NATIONAL_ID", id_no="010203040506")
    assert r.status_code == 422 and r.json()["error"]["code"] == "DOCUMENT_NOT_ACCEPTED"
    r = try_book(pax, beirut_trip)
    assert r.status_code == 422 and r.json()["error"]["code"] == "DOCUMENT_REQUIRED"
    r = try_book(pax, beirut_trip, id_type="PASSPORT", id_no="N0123456")
    assert r.status_code == 422 and r.json()["error"]["code"] == "PASSPORT_EXPIRY_REQUIRED"
    soon = (date.today() + timedelta(days=60)).isoformat()
    r = try_book(pax, beirut_trip, id_type="PASSPORT", id_no="N0123456", passport_expiry=soon)
    assert r.status_code == 422 and r.json()["error"]["code"] == "PASSPORT_EXPIRES_TOO_SOON"
    good = (date.today() + timedelta(days=900)).isoformat()
    r = try_book(pax, beirut_trip, id_type="PASSPORT", id_no="N0123456", passport_expiry=good)
    assert r.status_code == 201, r.text
    row = owner_sql("""SELECT d.doc_type, d.dest_country, d.exception, p.passport_expiry::text AS expiry FROM sales.ticket_doc d
                         JOIN sales.ticket t ON t.id = d.ticket_id JOIN sales.booking b ON b.id = t.booking_id
                         JOIN sales.passenger p ON p.id = t.passenger_id WHERE b.booking_ref = $1""", r.json()["booking_ref"], fetch=True)
    assert row["doc_type"] == "PASSPORT" and row["dest_country"].strip() == "LB" and not row["exception"] and row["expiry"] == good


def test_domestic_trips_keep_any_document():
    pax = new_passenger()
    trips = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(2), "passengers": 1}).json()["trips"]
    if trips:
        assert docs(pax, trips[0])["international"] is False


def test_exception_needs_legal_basis_two_officers_and_then_applies(admin, officer, beirut_trip):
    base = {"country_code": "LB", "nationality": "SY", "doc_required": ["PASSPORT", "NATIONAL_ID"], "label": "Syrians to Lebanon with ID"}
    r = admin.post("/api/w/travel-rules", json=base)
    assert r.status_code == 422 and r.json()["error"]["code"] == "LEGAL_BASIS_REQUIRED"
    r = admin.post("/api/w/travel-rules", json=base | {"legal_basis": "Bilateral agreement, test circular 12/2026", "note": "Bring the original ID card"})
    assert r.status_code == 201, r.text
    rid = r.json()["id"]
    assert r.json()["exception"] and r.json()["status"] == "DRAFT"
    pax = new_passenger()
    assert docs(pax, beirut_trip)["docs"] == ["PASSPORT"]                    # drafts do not apply
    r = admin.post(f"/api/w/travel-rules/{rid}/approve")
    assert r.status_code == 409 and r.json()["error"]["code"] == "FOUR_EYES"
    assert officer.post(f"/api/w/travel-rules/{rid}/approve").json()["status"] == "ACTIVE"
    need = docs(pax, beirut_trip)
    assert need["exception"] and set(need["docs"]) == {"PASSPORT", "NATIONAL_ID"} and "Bring the original ID card" in need["notes"]
    assert docs(pax, beirut_trip, "JO")["docs"] == ["PASSPORT"]               # other nationalities keep the default
    check = admin.get("/api/w/travel-rules/check", params={"destination": "LB", "nationality": "SY"}).json()
    assert "NATIONAL_ID" in check["docs"]
    assert pax.post("/api/wallet/topup", json={"amount": 50_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    r = try_book(pax, beirut_trip, id_type="NATIONAL_ID", id_no="010203040506")
    assert r.status_code == 201, r.text
    row = owner_sql("""SELECT d.doc_type, d.exception, d.entry_rule_id FROM sales.ticket_doc d JOIN sales.ticket t ON t.id = d.ticket_id
                         JOIN sales.booking b ON b.id = t.booking_id WHERE b.booking_ref = $1""", r.json()["booking_ref"], fetch=True)
    assert row["doc_type"] == "NATIONAL_ID" and row["exception"] and row["entry_rule_id"] == rid
    assert officer.post(f"/api/w/travel-rules/{rid}/retire").json()["status"] == "RETIRED"
    assert docs(pax, beirut_trip)["docs"] == ["PASSPORT"]


def test_time_limited_exception_only_applies_in_its_period(admin, officer, beirut_trip):
    later = date.today() + timedelta(days=30)
    r = admin.post("/api/w/travel-rules", json={"country_code": "LB", "nationality": "SY", "doc_required": ["NATIONAL_ID"],
                                                "valid_from": later.isoformat(), "valid_to": (later + timedelta(days=10)).isoformat(),
                                                "legal_basis": "Seasonal arrangement, test", "label": "Seasonal ID crossing"})
    assert r.status_code == 201, r.text
    assert officer.post(f"/api/w/travel-rules/{r.json()['id']}/approve").status_code == 200
    pax = new_passenger()
    assert docs(pax, beirut_trip)["docs"] == ["PASSPORT"]                     # the trip is before the period
    check = admin.get("/api/w/travel-rules/check", params={"destination": "LB", "nationality": "SY", "on": (later + timedelta(days=2)).isoformat()}).json()
    assert check["docs"] == ["NATIONAL_ID"]
    officer.post(f"/api/w/travel-rules/{r.json()['id']}/retire")


def test_only_platform_officers_manage_rules():
    carrier = login("owner@carrier.test", "OPERATOR")
    assert carrier.post("/api/w/travel-rules", json={"country_code": "LB", "doc_required": ["PASSPORT"], "label": "nope"}).status_code == 403
    assert carrier.get("/api/w/travel-rules").status_code == 403
