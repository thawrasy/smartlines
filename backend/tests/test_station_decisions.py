"""The owner's decisions on the station screens (October 2026; migrations 1114 and 1115):

* the trip number passengers read is short, the carrier's designator and a service number ("DC 1101"), the same for the
  same departure every day and never twice in a carrier's day; the long number stays the trip's reference;
* a company's logo, added by the platform to a specification, shown next to the carrier's name wherever it is shown
  (search, the trip and the booking, the ticket check, the station's screens, the platform's lists; 1116);
* the departure board shows its languages in turn;
* the station's administration assigns the bays: a permanent bay per carrier, or a bay per trip, the trip's own first;
* the driver boards a ticket typed in by its number and booking reference, the identity document checked (decision O1).
"""
import hashlib
import io
import secrets
import uuid
from datetime import datetime

import pytest
from PIL import Image

from test_boarding_stations import ADMIN, CARRIER, set_setting, station_session, stations_module
from test_e2e import FRESH_DRIVER_PASSWORD, FRESH_DRIVERS, OWNER_URL, client, day, login, owner_sql
from test_station_checkin import book
from test_station_sales import _company
from test_use_case_gaps import fresh_trip

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


def _png(width: int, height: int, fmt: str = "PNG") -> bytes:
    out = io.BytesIO()
    Image.new("RGBA" if fmt == "PNG" else "RGB", (width, height), (200, 30, 40, 255) if fmt == "PNG" else (200, 30, 40)).save(out, fmt)
    return out.getvalue()


def _carrier_uid() -> str:
    return str(owner_sql("""SELECT p.uid FROM iam.party p JOIN iam.company_member m ON m.company_id = p.id
                             JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = 'owner@carrier.test'"""))


# ------------------------------------------------------------------ trip numbers (1114)
def test_a_trip_made_by_hand_keeps_its_number_on_the_same_route_and_time_and_a_day_never_repeats_one():
    carrier = login(*CARRIER)
    trip = fresh_trip()
    code, number = trip["trip_code"].split(" ")
    assert code == owner_sql("SELECT ops.trip_designator(company_id) FROM ops.trip WHERE id = $1", trip["id"])
    assert int(number) >= 1 and trip["trip_no"] != trip["trip_code"]            # the long number stays the reference
    route = next(r for r in carrier.get("/api/carrier/routes").json()["routes"] if r["code"] == "DAM-ALP")
    vehicle = str(owner_sql("SELECT v.uid FROM fleet.vehicle v JOIN ops.trip t ON t.vehicle_id = v.id WHERE t.id = $1", trip["id"]))
    hhmm = f"{4 + secrets.randbelow(2):02d}:{secrets.randbelow(60):02d}"       # far days, early: no other trip of the route then
    made = []

    def make(on: str, at: str, **extra):
        r = carrier.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": vehicle,
                                                     "departure_local": f"{on}T{at}:00", **extra})
        if r.status_code == 201:
            made.append(r.json()["uid"])
        return r
    try:
        first = make(day(40), hhmm)
        assert first.status_code == 201, first.text
        # the same route at the same time the next day: the same number
        nxt = make(day(41), hhmm)
        assert nxt.status_code == 201 and nxt.json()["trip_code"] == first.json()["trip_code"], nxt.text
        # another trip of the same day takes another number
        other = make(day(40), "20:15")
        assert other.status_code == 201 and other.json()["trip_code"] != first.json()["trip_code"], other.text
        # a service number the carrier has not defined is refused
        bad = make(day(42), hhmm, service_number=9991)
        assert bad.status_code == 422 and bad.json()["error"]["code"] == "SERVICE_NUMBER_UNKNOWN", bad.text
        # nowhere does a carrier run two trips under one number on one day
        dup = owner_sql("""SELECT count(*) FROM ops.trip a JOIN ops.trip b ON b.company_id = a.company_id AND b.service_date = a.service_date
                            AND b.service_no = a.service_no AND b.id <> a.id AND b.status <> 'CANCELLED' WHERE a.status <> 'CANCELLED'""")
        assert dup == 0
    finally:
        for uid in made:
            owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE uid = $1::uuid", uid)
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


def test_the_platform_sets_the_designator_of_a_carriers_trip_numbers(admin):
    carrier_uid = _carrier_uid()
    before = owner_sql("SELECT code2 FROM net.carrier_code WHERE company_id = (SELECT id FROM iam.party WHERE uid = $1::uuid) AND status = 'ACTIVE'",
                       carrier_uid)
    owner_sql("INSERT INTO net.code_reservation (code, reason) VALUES ('ZZ', 'RESERVED') ON CONFLICT DO NOTHING")
    try:
        assert admin.put(f"/api/admin/companies/{carrier_uid}/designator", json={"code2": "ZZ"}).json()["error"]["code"] == "CODE_TAKEN"
        assert admin.put(f"/api/admin/companies/{carrier_uid}/designator", json={"code2": "Z"}).status_code == 422
        assert admin.put(f"/api/admin/companies/{carrier_uid}/designator", json={"code2": "11"}).status_code == 422   # a letter at least
        r = admin.put(f"/api/admin/companies/{carrier_uid}/designator", json={"code2": "Q7"})
        assert r.status_code == 200, r.text
        trip = fresh_trip()                       # trips made from now on carry it
        assert trip["trip_code"].startswith("Q7 ")
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])
        listed = next(c for c in admin.get("/api/admin/companies").json()["companies"] if c["uid"] == carrier_uid)
        assert listed["code2"] == "Q7"
        assert login(*CARRIER).put(f"/api/admin/companies/{carrier_uid}/designator", json={"code2": "Q8"}).status_code in (401, 403)
    finally:
        admin.put(f"/api/admin/companies/{carrier_uid}/designator", json={"code2": before})
        owner_sql("DELETE FROM net.code_reservation WHERE code = 'ZZ'")


# ------------------------------------------------------------------ logos (1115)
def test_a_logo_is_kept_to_its_specification_and_shown_next_to_the_name(admin):
    carrier_uid = _carrier_uid()
    url = f"/api/admin/companies/{carrier_uid}/logo"
    for data, code in ((b"not an image at all", "LOGO_FORMAT"), (_png(300, 100), "LOGO_TOO_SMALL"),
                       (_png(130, 200), "LOGO_SHAPE"), (_png(1000, 200), "LOGO_SHAPE")):
        r = admin.put(url, files={"file": ("logo.png", data, "image/png")})
        assert r.status_code == 422 and r.json()["error"]["code"] == code, (code, r.text)
    try:
        r = admin.put(url, files={"file": ("logo.jpg", _png(1200, 400, "JPEG"), "image/jpeg")})
        assert r.status_code == 200, r.text
        kept = r.json()
        assert (kept["width"], kept["height"]) == (720, 240) and len(kept["logo"]) == 12   # re-encoded to 240 pixels high
        anyone = client()
        got = anyone.get(f"/api/public/companies/{carrier_uid}/logo", params={"v": kept["logo"]})
        assert got.status_code == 200 and got.headers["content-type"] == "image/png" and "immutable" in got.headers["cache-control"]
        assert Image.open(io.BytesIO(got.content)).size == (720, 240)
        assert "immutable" not in anyone.get(f"/api/public/companies/{carrier_uid}/logo").headers["cache-control"]
        found = anyone.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
        assert any(t["carrier_uid"] == carrier_uid and t["carrier_logo"] == kept["logo"] for t in found)
        assert login(*CARRIER).put(url, files={"file": ("logo.png", _png(400, 200), "image/png")}).status_code in (401, 403)
    finally:
        assert admin.delete(url).status_code == 200
    assert client().get(f"/api/public/companies/{carrier_uid}/logo").status_code == 404
    assert admin.delete(url).status_code == 404


def test_the_carriers_logo_is_shown_next_to_its_name_wherever_the_name_is(admin):
    """The logo belongs to the carrier, added once by the platform; every answer that names the carrier carries it (1116)."""
    carrier_uid = _carrier_uid()
    url = f"/api/admin/companies/{carrier_uid}/logo"
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    ref, _ = book(pax, fresh_trip())
    try:
        version = admin.put(url, files={"file": ("logo.png", _png(480, 160), "image/png")}).json()["logo"]

        def named(d: dict, uid: str = "carrier_uid", logo: str = "carrier_logo") -> bool:
            return str(d.get(uid)) == carrier_uid and d.get(logo) == version

        # the passenger: the trips they booked, the booking with its short number, and anyone checking the printout
        assert any(named(b) for b in pax.get("/api/bookings").json()["bookings"])
        booking = pax.get(f"/api/bookings/{ref}").json()["booking"]
        assert named(booking) and booking["trip_code"], booking
        checked = client().get("/api/verify", params={"token": booking["verify_token"]}).json()
        assert checked["valid"] and named(checked) and checked["carrier"], checked
        # the carrier's own portal shows its logo by its name
        assert login(*CARRIER).get("/api/auth/me").json()["company"]["logo"] == version
        # the platform's lists that name companies
        assert any(named(c, "company_uid", "company_logo") for c in admin.get("/api/admin/cash/positions").json()["positions"])
        assert any(c["uid"] == carrier_uid and c["logo"] == version for c in admin.get("/api/admin/companies").json()["companies"])
        # the station's screens and the boarding pass read it in the database
        assert owner_sql("SELECT iam.logo_version(id) FROM iam.party WHERE uid = $1", uuid.UUID(carrier_uid)) == version
    finally:
        assert admin.delete(url).status_code == 200
    booking = pax.get(f"/api/bookings/{ref}").json()["booking"]
    assert booking["carrier_logo"] is None and booking["carrier_name"]          # without a logo the name stands alone


def test_the_public_route_pages_show_the_carriers_logo_by_its_name():
    from datetime import timezone

    from app.modules.seo import data, pages
    trip = data.Trip(datetime.now(timezone.utc), None, 150000, "Damascus Coaches", "Central", "SY-DAM-C001", "North", "SY-ALP-N001",
                     "Asia/Damascus", "SYP")
    assert pages._carrier(trip) == "Damascus Coaches"
    trip.carrier_uid, trip.carrier_logo = str(uuid.uuid4()), "0a1b2c3d4e5f"
    cell = pages._carrier(trip)
    assert f"/api/public/companies/{trip.carrier_uid}/logo?v=0a1b2c3d4e5f" in cell and "alt=''" in cell and "Damascus Coaches" in cell


def test_the_logo_specification_in_the_process():
    from app import company_logo
    from app.errors import ApiError
    small = company_logo.prepare(_png(480, 160))
    assert (small.width, small.height) == (480, 160) and small.png.startswith(b"\x89PNG")
    assert company_logo.prepare(_png(240, 240)).height == 240 and company_logo.prepare(_png(960, 240)).width == 960
    with pytest.raises(ApiError) as e:
        company_logo.prepare(b"x" * (company_logo.MAX_BYTES + 1))
    assert e.value.code == "LOGO_TOO_LARGE"
    assert hashlib.sha256(small.png).digest() == small.sha256 and small.version == small.sha256[:6].hex()


# ------------------------------------------------------------------ the board's languages (1115)
@pytest.mark.parametrize("key, value", [
    ("boarding.board.languages", ["fr"]), ("boarding.board.languages", ["ar", "ar"]), ("boarding.board.languages", []),
    ("boarding.board.languages", "ar"), ("boarding.board.rotate_seconds", 3), ("boarding.board.rotate_seconds", 61),
    ("boarding.board.rotate_seconds", "10"),
])
def test_an_invalid_board_language_setting_is_refused(admin, key, value):
    r = admin.put("/api/admin/boarding/settings", json={"key": key, "value": value})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SETTING", r.text


def test_the_platform_sets_the_board_languages(admin):
    try:
        assert set_setting(admin, "boarding.board.languages", ["en", "ar"])["value"] == ["en", "ar"]
        assert set_setting(admin, "boarding.board.rotate_seconds", 15)["value"] == 15
        settings = admin.get("/api/admin/boarding/settings").json()["settings"]
        assert settings["boarding.board.languages"] == ["en", "ar"] and settings["boarding.board.rotate_seconds"] == 15
    finally:
        set_setting(admin, "boarding.board.languages", ["ar", "en"])
        set_setting(admin, "boarding.board.rotate_seconds", 10)


# ------------------------------------------------------------------ bays by the station's administration (1115)
def test_the_station_administration_assigns_a_permanent_bay_per_carrier_or_a_bay_per_trip(admin):
    carrier = login(*CARRIER)
    carrier_uid = _carrier_uid()
    trip = fresh_trip()
    station = owner_sql("""SELECT s.uid FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                            WHERE ts.trip_id = $1 AND ts.seq = 0""", trip["id"])
    manager = _company(admin, "Central Station Administration")
    stranger = _company(admin, "Another Station Company")
    grants = []
    stations_module(admin, True)
    try:
        set_setting(admin, "boarding.stations.enabled", True)
        set_setting(admin, "boarding.mode.carrier_contracted", True)
        # the platform names the administration: a station operating company, not a carrier
        r = admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": True, "manager_company_uid": carrier_uid})
        assert r.status_code == 422 and r.json()["error"]["code"] == "NOT_STATION_OPERATOR"
        r = admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": True, "manager_company_uid": manager["uid"]})
        assert r.status_code == 200 and r.json()["boarding"]["manager_company_uid"] == manager["uid"], r.text
        bays = [admin.post(f"/api/admin/boarding/stations/{station}/gates", json={"gate_type": "BAY"}).json()["code"] for _ in range(2)]
        counter = admin.post(f"/api/admin/boarding/stations/{station}/gates",
                             json={"gate_type": "COUNTER", "operator_company_uid": manager["uid"]}).json()["code"]
        staff = station_session(manager)
        assert any(a["station_uid"] == str(station) for a in staff.get("/api/station/overview").json()["administered"])
        view = staff.get("/api/station/bays", params={"station_uid": str(station)})
        assert view.status_code == 200, view.text
        assert view.json()["mode"] == "TRIP" and {b["code"] for b in view.json()["bays"]} >= set(bays)
        assert any(c["carrier_uid"] == carrier_uid for c in view.json()["carriers"])
        # another operating company is not this station's administration
        other = station_session(stranger)
        r = other.get("/api/station/bays", params={"station_uid": str(station)})
        assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_STATION_ADMIN"
        assert other.put("/api/station/bays/mode", json={"station_uid": str(station), "mode": "CARRIER"}).status_code == 403
        # a permanent bay for the carrier applies once the station assigns per carrier
        assert staff.put("/api/station/bays/carriers", json={"station_uid": str(station), "carrier_uid": carrier_uid,
                                                             "bay": bays[0]}).json()["bay"] == bays[0]
        unknown = staff.put("/api/station/bays/carriers", json={"station_uid": str(station), "carrier_uid": carrier_uid, "bay": counter})
        assert unknown.status_code == 422 and unknown.json()["error"]["code"] == "BAY_UNKNOWN"     # a counter is no bay

        def bay_now():
            row = next(x for x in staff.get("/api/station/bays", params={"station_uid": str(station)}).json()["trips"]
                       if x["trip_uid"] == str(trip["uid"]))
            return row["bay"], row["bay_source"]
        assert bay_now() == (None, None)                                # per trip, and the trip has none yet
        assert staff.put("/api/station/bays/mode", json={"station_uid": str(station), "mode": "CARRIER"}).status_code == 200
        assert bay_now() == (bays[0], "CARRIER")
        # a bay set on the trip comes first; cleared, the carrier's applies again
        r = staff.put("/api/station/bays/trips", json={"trip_uid": str(trip["uid"]), "stop_seq": 0, "bay": bays[1]})
        assert r.status_code == 200 and r.json()["bay"] == bays[1], r.text
        assert bay_now() == (bays[1], "TRIP")
        # the counter's trips and the boarding pass show the bay in force
        g = carrier.post("/api/carrier/station-operators/grants",
                         json={"operator_company_uid": manager["uid"], "station_uid": str(station), "permission": "BOARDING_PASS"})
        grants.append(g.json()["uid"])
        listed = next(x for x in staff.get("/api/station/trips", params={"station_uid": str(station)}).json()["trips"]
                      if x["trip_uid"] == str(trip["uid"]))
        assert listed["bay"] == bays[1] and listed["trip_code"] == trip["trip_code"]
        assert staff.put("/api/station/bays/trips", json={"trip_uid": str(trip["uid"]), "stop_seq": 0, "bay": None}).json()["bay"] is None
        assert bay_now() == (bays[0], "CARRIER")
        pax = login("passenger@masslak.test", "PASSENGER")
        assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
        _, ticket = book(pax, trip)
        token = pax.get(f"/api/tickets/{ticket['uid']}/qr").json()["token"]
        bp = staff.post("/api/station/checkin", json={"station_uid": str(station), "counter_code": counter, "token": token,
                                                      "document_checked": True})
        assert bp.status_code == 201 and bp.json()["bay"] == bays[0] and bp.json()["trip_code"] == trip["trip_code"], bp.text
        # back to a bay per trip: the carrier's permanent bay no longer applies
        assert admin.put(f"/api/admin/boarding/stations/{station}/bays/mode", json={"mode": "TRIP"}).status_code == 200
        assert bay_now() == (None, None)
        # the platform does the same where needed, and the departure must still be open
        assert admin.get(f"/api/admin/boarding/stations/{station}/bays").json()["mode"] == "TRIP"
        assert staff.put("/api/station/bays/trips", json={"trip_uid": str(uuid.uuid4()), "stop_seq": 0, "bay": bays[0]}).json()["error"]["code"] == "TRIP_NOT_OPEN"
        assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action IN ('boarding.bay_mode', 'boarding.carrier_bay', 'boarding.trip_bay')") >= 4
    finally:
        for uid in grants:
            carrier.post(f"/api/carrier/station-operators/grants/{uid}/revoke")
        admin.put(f"/api/admin/boarding/stations/{station}", json={"enabled": False})
        owner_sql("DELETE FROM net.station_carrier_bay WHERE station_id = (SELECT id FROM net.station WHERE uid = $1)", station)
        set_setting(admin, "boarding.mode.carrier_contracted", False)
        set_setting(admin, "boarding.stations.enabled", False)
        stations_module(admin, False)
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


# ------------------------------------------------------------------ the driver boards a typed ticket (decision O1)
def test_the_driver_boards_a_ticket_typed_in_with_the_identity_checked():
    trip = fresh_trip()
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    ref, ticket = book(pax, trip)
    ref2, other = book(pax, trip)
    driver = login(FRESH_DRIVERS[-1], "DRIVER", FRESH_DRIVER_PASSWORD)
    body = {"trip_uid": str(trip["uid"]), "ticket_no": ticket["ticket_no"], "booking_ref": ref}
    try:
        # the pack holds the ticket number and a hash to match the typed reference, never the reference itself
        pack = driver.get(f"/api/driver/trips/{trip['uid']}/offline").json()
        row = next(k for k in pack["tickets"] if k["uid"] == ticket["uid"])
        assert row["ticket_no"] == ticket["ticket_no"] and pack["trip_code"] == trip["trip_code"]
        assert row["ref_hash"] == hashlib.sha256(f"{ticket['ticket_no']}:{ref}".upper().encode()).hexdigest()
        assert ref not in str({k: v for k, v in row.items() if k != "ticket_no"})
        r = driver.post("/api/driver/scan", json=body)
        assert r.status_code == 422 and r.json()["error"]["code"] == "IDENTITY_CHECK_REQUIRED"
        assert driver.post("/api/driver/scan", json={"trip_uid": str(trip["uid"])}).json()["error"]["code"] == "TICKET_NOT_VALID"
        assert driver.post("/api/driver/scan", json={**body, "booking_ref": "WRONG1", "identity_checked": True}).json()["result"] == "NOT_FOUND"
        ok = driver.post("/api/driver/scan", json={**body, "identity_checked": True}).json()
        assert ok["result"] == "OK" and ok["seat_no"] == ticket["seat_no"] and ok["passenger"], ok
        assert driver.post("/api/driver/scan", json={**body, "identity_checked": True}).json()["result"] == "DUPLICATE"
        assert owner_sql("""SELECT method FROM sales.boarding_event e JOIN sales.ticket k ON k.id = e.ticket_id
                             WHERE k.uid = $1::uuid AND e.result = 'OK'""", ticket["uid"]) == "MANUAL"
        # typed in offline and uploaded later: boarded the same way, once
        scan = {"scan_id": f"typed-{uuid.uuid4().hex[:10]}", "ticket_no": other["ticket_no"], "booking_ref": ref2,
                "identity_checked": True, "scanned_at": datetime.utcnow().isoformat() + "Z"}
        res = driver.post("/api/driver/scans/batch", json={"trip_uid": str(trip["uid"]), "scans": [
            scan, {**scan, "scan_id": f"typed-{uuid.uuid4().hex[:10]}", "booking_ref": "WRONG1"}]}).json()["results"]
        assert [x["result"] for x in res] == ["OK", "NOT_FOUND"], res
        again = driver.post("/api/driver/scans/batch", json={"trip_uid": str(trip["uid"]), "scans": [scan]}).json()["results"]
        assert again[0]["result"] == "OK" and again[0].get("replayed")
        assert owner_sql("SELECT status FROM sales.ticket WHERE uid = $1::uuid", other["uid"]) == "BOARDED"
        bad = driver.post("/api/driver/scans/batch", json={"trip_uid": str(trip["uid"]), "scans": [{**scan, "identity_checked": False}]})
        assert bad.status_code == 422
    finally:
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])
