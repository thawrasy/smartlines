"""One fleet for every vehicle (owner's notes, 1173): what a company may define follows the lines its contract opened;
a tractor head pulls a trailer with its own plate, licence and insurance; insurance names the insurer from the registry;
a vehicle in the workshop takes no trip until it is back, and its service plan moves on; the rental desk hands a car
over and takes it back with the odometer, charging the kilometres over the allowance, with a driver when hired with one."""
import secrets
import time
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from test_e2e import OWNER_URL, login, new_passenger, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module", autouse=True)
def modules_on(admin):
    """Trucks and car rental keep their tables in the cargo and car rental modules, which the platform switches on."""
    before = {m["key"]: m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"]}
    turned = [k for k in ("cargo", "car_rental") if not before[k]]
    for key in turned:
        assert admin.put(f"/api/admin/modules/{key}", json={"enabled": True, "reason": "fleet tests"}).status_code == 200
    if turned:
        time.sleep(6)
    yield
    for key in turned:
        admin.put(f"/api/admin/modules/{key}", json={"enabled": False, "reason": "fleet tests"})


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def company_uid():
    return str(owner_sql("""SELECT p.uid FROM iam.party p JOIN iam.company_member m ON m.company_id = p.id
                              JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = 'owner@carrier.test' LIMIT 1"""))


@pytest.fixture(scope="module")
def insurer(carrier):
    found = carrier.get("/api/registry/insurers").json()["insurers"]
    assert found, "the insurers registry needs a reviewed entry"
    return found[0]["uid"]


def plate() -> str:
    return "F" + str(100000 + secrets.randbelow(899999))


def cover(insurer: str) -> dict:
    return {"insurer_uid": insurer, "policy_no": "POL-" + uuid.uuid4().hex[:8].upper(), "coverage_type": "COMPREHENSIVE",
            "issue_date": "2026-01-01", "expiry_date": "2028-01-01"}


def open_line(admin, company_uid, line):
    lines = admin.get(f"/api/admin/companies/{company_uid}/fleet-lines").json()["lines"]
    if not any(x["line"] == line and x["open"] for x in lines):
        r = admin.post(f"/api/admin/companies/{company_uid}/fleet-lines", json={"line": line, "contract_ref": "TEST-1173"})
        assert r.status_code == 201, r.text


def test_the_contract_decides_what_the_company_defines(admin, carrier, company_uid, insurer):
    lines = admin.get(f"/api/admin/companies/{company_uid}/fleet-lines").json()["lines"]
    for x in lines:
        if x["line"] == "TAXI" and x["open"]:
            admin.post(f"/api/admin/fleet-lines/{x['id']}/end")
    assert "TAXI" not in carrier.get("/api/fleet/options").json()["lines"]
    r = carrier.post("/api/fleet/vehicles", json={"fleet_use": "TAXI", "plate_no": plate(), "chassis_no": "CHS" + plate(),
                                                   "passenger_seats": 4, "taxi_licence_no": "TX-1", "taxi_licence_expiry": "2028-01-01",
                                                   "insurance": cover(insurer)})
    assert r.status_code == 403 and r.json()["error"]["code"] == "FLEET_LINE_CLOSED"
    open_line(admin, company_uid, "TAXI")
    opts = carrier.get("/api/fleet/options").json()
    assert "TAXI" in opts["lines"] and "TAXI" in opts["uses"]
    r = carrier.post("/api/fleet/vehicles", json={"fleet_use": "TAXI", "plate_no": plate(), "chassis_no": "CHS" + plate(),
                                                   "passenger_seats": 4, "colour_code": "YELLOW", "fuel_type": "GAS", "odometer_km": 120000,
                                                   "insurance": cover(insurer)})
    assert r.status_code == 422 and r.json()["error"]["code"] == "TAXI_LICENCE_REQUIRED"
    r = carrier.post("/api/fleet/vehicles", json={"fleet_use": "TAXI", "plate_no": plate(), "chassis_no": "CHS" + plate(),
                                                   "passenger_seats": 4, "colour_code": "YELLOW", "fuel_type": "GAS", "odometer_km": 120000,
                                                   "taxi_licence_no": "TX-" + plate(), "taxi_licence_expiry": "2028-01-01",
                                                   "insurance": cover(insurer)})
    assert r.status_code == 201, r.text
    d = carrier.get(f"/api/fleet/vehicles/{r.json()['uid']}").json()
    assert d["vehicle"]["fleet_use"] == "TAXI" and d["vehicle"]["vehicle_class"] == "CAR" and d["vehicle"]["odometer_km"] == 120000
    assert {x["license_type"] for x in d["licences"]} == {"TAXI", "INSURANCE"}
    pol = d["insurance"][0]
    assert pol["coverage_type"] == "COMPREHENSIVE" and pol["insurer"] and pol["source"] == "MANUAL" and pol["verified_at"] is None
    assert carrier.get("/api/admin/companies/" + company_uid + "/fleet-lines").status_code in (401, 403)


def test_a_tractor_head_pulls_a_trailer_each_with_plate_licence_and_insurance(admin, carrier, company_uid, insurer):
    open_line(admin, company_uid, "TRUCK")
    opts = carrier.get("/api/fleet/options").json()
    assert {"4x2", "6x4", "8x4"} <= {a["code"] for a in opts["axle_configs"]} and {"T1", "T2", "T3"} <= {a["code"] for a in opts["trailer_axles"]}
    assert {"WHITE", "BLACK", "SILVER", "GREY", "BEIGE", "BROWN"} <= {c["code"] for c in opts["colours"]}
    head = {"fleet_use": "TRACTOR", "chassis_no": "CHS" + plate(), "gvw_kg": 40000, "tare_kg": 8500, "fuel_type": "DIESEL", "insurance": cover(insurer)}
    for bad, code in (({"axle_config": "7x4"}, "AXLE_UNKNOWN"), ({"axle_config": "6x4", "colour_code": "WHYTE"}, "COLOUR_UNKNOWN"), ({}, "TRUCK_DETAILS_REQUIRED")):
        r = carrier.post("/api/fleet/vehicles", json={**head, "plate_no": plate(), **bad})
        assert r.status_code == 422 and r.json()["error"]["code"] == code, r.text
    r = carrier.post("/api/fleet/vehicles", json={**head, "plate_no": plate(), "axle_config": "6x4", "colour_code": "WHITE"})
    assert r.status_code == 201, r.text
    head = r.json()["uid"]
    tp = plate()
    r = carrier.post("/api/fleet/trailers", json={"plate_no": tp, "trailer_type": "CURTAIN", "payload_kg": 26000, "axle_config": "6x4",
                                                   "licence_no": "TL-" + tp, "licence_issue": "2026-01-01", "licence_expiry": "2027-06-01"})
    assert r.status_code == 422, r.text      # a powered vehicle's wheel formula is not a trailer's axle group
    r = carrier.post("/api/fleet/trailers", json={"plate_no": tp, "trailer_type": "CURTAIN", "payload_kg": 26000, "axle_config": "T9",
                                                   "licence_no": "TL-" + tp, "licence_issue": "2026-01-01", "licence_expiry": "2027-06-01"})
    assert r.status_code == 422, r.text
    r = carrier.post("/api/fleet/trailers", json={"plate_no": tp, "trailer_type": "CURTAIN", "payload_kg": 26000, "axle_config": "T3",
                                                   "colour_code": "WHITE",
                                                   "licence_no": "TL-" + tp, "licence_issue": "2026-01-01", "licence_expiry": "2027-06-01",
                                                   "insurance": cover(insurer)})
    assert r.status_code == 201, r.text
    trailer = r.json()["uid"]
    t = carrier.get(f"/api/fleet/trailers/{trailer}").json()
    assert {x["license_type"] for x in t["licences"]} == {"TRANSPORT", "INSURANCE"} and len(t["insurance"]) == 1
    assert t["trailer"]["axles"] == 3 and t["trailer"]["axle_config"] == "T3" and t["trailer"]["colour_code"] == "WHITE"
    assert carrier.patch(f"/api/fleet/trailers/{trailer}", json={"axle_config": "T2"}).status_code == 200
    assert carrier.get(f"/api/fleet/trailers/{trailer}").json()["trailer"]["axles"] == 2      # the axles follow the arrangement
    r = carrier.patch(f"/api/fleet/trailers/{trailer}", json={"plate_no": tp + "B"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "TRAILER_CHANGE_REASON"
    assert carrier.patch(f"/api/fleet/trailers/{trailer}", json={"plate_no": tp + "B", "reason": "new trailer plates"}).status_code == 200
    assert carrier.get(f"/api/fleet/trailers/{trailer}").json()["history"][0]["reason"] == "new trailer plates"
    c = carrier.post("/api/fleet/couplings", json={"tractor_uid": head, "trailer_uid": trailer})
    assert c.status_code == 201, c.text
    again = carrier.post("/api/fleet/couplings", json={"tractor_uid": head, "trailer_uid": trailer})
    assert again.status_code == 409 and again.json()["error"]["code"] == "ALREADY_COUPLED"
    units = carrier.get("/api/fleet/units").json()
    assert next(v for v in units["vehicles"] if v["uid"] == head)["trailer_plate"] == tp + "B"
    assert next(x for x in units["trailers"] if x["uid"] == trailer)["head_plate"]
    assert carrier.post(f"/api/fleet/couplings/{c.json()['id']}/end").json()["ended"] is True


def test_a_vehicle_in_the_workshop_takes_no_trip_and_its_plan_moves_on(carrier, insurer):
    layout = carrier.get("/api/carrier/seat-layouts").json()["layouts"][0]
    r = carrier.post("/api/fleet/vehicles", json={"fleet_use": "MINIBUS", "plate_no": plate(), "chassis_no": "CHS" + plate(),
                                                   "seat_layout_uid": layout["uid"], "odometer_km": 80000, "insurance": cover(insurer)})
    assert r.status_code == 201, r.text
    bus = r.json()["uid"]
    assert carrier.post(f"/api/fleet/vehicles/{bus}/service-plans", json={"kind": "OIL_CHANGE"}).json()["error"]["code"] == "PLAN_INTERVAL"
    assert carrier.post(f"/api/fleet/vehicles/{bus}/service-plans", json={"kind": "CONTRACT"}).json()["error"]["code"] == "PLAN_CONTRACT"
    plan = carrier.post(f"/api/fleet/vehicles/{bus}/service-plans", json={"kind": "OIL_CHANGE", "every_km": 10000, "every_months": 6,
                                                                          "last_km": 71000})
    assert plan.status_code == 201, plan.text
    carrier.post(f"/api/fleet/vehicles/{bus}/service-plans", json={"kind": "CONTRACT", "provider": "Main dealer",
                                                                  "contract_no": "MC-" + plate(), "contract_until": "2027-12-31"})
    d = carrier.get(f"/api/fleet/vehicles/{bus}").json()
    oil = next(p for p in d["service_plans"] if p["kind"] == "OIL_CHANGE")
    assert oil["next_km"] == 81000 and oil["due"] is False
    assert carrier.post(f"/api/fleet/vehicles/{bus}/odometer", json={"odometer_km": 79000}).json()["error"]["code"] == "ODOMETER_BACKWARDS"
    carrier.post(f"/api/fleet/vehicles/{bus}/odometer", json={"odometer_km": 81200})
    assert next(v for v in carrier.get("/api/fleet/units").json()["vehicles"] if v["uid"] == bus)["service_due"] is True
    sent = carrier.post(f"/api/fleet/vehicles/{bus}/maintenance", json={"kind": "OIL_CHANGE", "plan_uid": plan.json()["uid"],
                                                                        "workshop": "Main workshop", "odometer_km": 81250})
    assert sent.status_code == 201 and sent.json()["status"] == "IN_MAINTENANCE", sent.text
    assert carrier.get(f"/api/fleet/vehicles/{bus}").json()["vehicle"]["status"] == "IN_MAINTENANCE"
    again = carrier.post(f"/api/fleet/vehicles/{bus}/maintenance", json={"kind": "REPAIR"})
    assert again.status_code == 409 and again.json()["error"]["code"] == "VEHICLE_NOT_AVAILABLE"
    back = carrier.post(f"/api/fleet/maintenance/{sent.json()['uid']}/return", json={"odometer_km": 81260, "cost": 450000, "currency": "SYP"})
    assert back.status_code == 200, back.text
    d = carrier.get(f"/api/fleet/vehicles/{bus}").json()
    assert d["vehicle"]["status"] == "ACTIVE" and d["maintenance"][0]["returned_at"]
    oil = next(p for p in d["service_plans"] if p["kind"] == "OIL_CHANGE")
    assert oil["last_km"] == 81260 and oil["next_km"] == 91260 and oil["due"] is False
    assert carrier.post(f"/api/fleet/maintenance/{sent.json()['uid']}/return", json={}).json()["error"]["code"] == "VISIT_CLOSED"




def test_the_rental_desk_charges_the_kilometres_over_the_allowance_and_sends_a_driver(admin, carrier, company_uid, insurer):
    open_line(admin, company_uid, "RENTAL")
    company = owner_sql("SELECT id FROM iam.party WHERE uid = $1", uuid.UUID(company_uid))
    owner_sql("INSERT INTO rent.rental_company (company_id, brand) VALUES ($1, 'Carrier Rent') ON CONFLICT DO NOTHING", company)
    klass = owner_sql("SELECT code FROM rent.rental_vehicle_class ORDER BY sort LIMIT 1")
    branch = owner_sql("""INSERT INTO rent.rental_branch (company_id, station_id, branch_type, hours, status)
                          VALUES ($1, (SELECT min(id) FROM net.station), 'BRANCH', '{}', 'ACTIVE')
                          ON CONFLICT (company_id, station_id) DO UPDATE SET status = 'ACTIVE' RETURNING id""", company)
    rate = owner_sql("""INSERT INTO rent.rental_rate (company_id, rental_class, branch_id, unit, price, km_included_per_day, extra_km_price,
                          driver_price_per_day, currency, valid, status)
                        VALUES ($1, $2, $3, 'DAY', 2000000, 200, 10000, 500000, 'SYP', daterange(CURRENT_DATE, NULL), 'ACTIVE') RETURNING id""",
                     company, klass, branch)
    r = carrier.post("/api/fleet/vehicles", json={"fleet_use": "RENTAL_CAR", "plate_no": plate(), "chassis_no": "CHS" + plate(),
                                                   "passenger_seats": 5, "rental_class": klass, "home_branch_id": branch,
                                                   "odometer_km": 30000, "insurance": cover(insurer)})
    assert r.status_code == 201, r.text
    car = r.json()["uid"]
    driver = carrier.post("/api/carrier/crew", json={"full_name": "Rental Driver", "email": f"rent{uuid.uuid4().hex[:8]}@example.com",
                                                     "password": "fresh-crew-long-passphrase"}).json()["uid"]
    renter = new_passenger()
    start = (datetime.now(timezone.utc) + timedelta(days=40 + secrets.randbelow(100))).replace(microsecond=0)
    b = renter.post("/api/w/rental/bookings", json={"rate_id": rate, "pickup_branch_id": branch, "starts_at": start.isoformat(),
                                                    "ends_at": (start + timedelta(days=2)).isoformat(), "with_driver": True})
    assert b.status_code == 201 and b.json()["quoted_total"] == 2 * 2000000 + 2 * 500000, b.text
    uid = b.json()["uid"]
    r = carrier.post(f"/api/fleet/rentals/{uid}/confirm", json={"vehicle_uid": car})
    assert r.status_code == 422 and r.json()["error"]["code"] == "DRIVER_REQUIRED"
    assert carrier.post(f"/api/fleet/rentals/{uid}/confirm", json={"vehicle_uid": car, "driver_uid": driver}).json()["status"] == "CONFIRMED"
    r = carrier.post(f"/api/fleet/rentals/{uid}/pickup", json={"odometer_km": 29000, "fuel_level_pct": 100})
    assert r.status_code == 422 and r.json()["error"]["code"] == "ODOMETER_BACKWARDS"
    assert carrier.post(f"/api/fleet/rentals/{uid}/pickup", json={"odometer_km": 30010, "fuel_level_pct": 100}).json()["status"] == "PICKED_UP"
    sent = carrier.post(f"/api/fleet/vehicles/{car}/maintenance", json={"kind": "REPAIR"})
    assert sent.status_code == 409 and sent.json()["error"]["code"] == "VEHICLE_ON_HIRE"
    r = carrier.post(f"/api/fleet/rentals/{uid}/return", json={"odometer_km": 30560, "fuel_level_pct": 70})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["driven"] == 550 and out["allowed"] == 400 and out["extra_km"] == 150 and out["extra_charge"] == 1500000
    assert out["final_amount"] == 5000000 + 1500000
    row = next(x for x in carrier.get("/api/fleet/rentals").json()["rentals"] if x["uid"] == uid)
    assert row["status"] == "RETURNED" and row["driver"] == "Rental Driver" and row["contract_status"] == "CLOSED"
    assert carrier.get(f"/api/fleet/vehicles/{car}").json()["vehicle"]["odometer_km"] == 30560


def test_colours_and_axles_are_kept_by_the_platform_and_chosen_not_typed(admin, carrier):
    lists = admin.get("/api/admin/reference-lists").json()
    assert any(c["code"] == "BEIGE" and c["hex"] for c in lists["colours"])
    assert any(a["code"] == "6x4" and a["axles"] == 3 and a["driven_axles"] == 2 for a in lists["axles"])
    code = "TEST_" + uuid.uuid4().hex[:6].upper()
    r = admin.post("/api/admin/reference-lists/colours", json={"code": code, "name_en": "Sand " + code[-6:], "name_ar": "\u0631\u0645\u0644\u064a " + code[-6:],
                                                               "hex": "#c2b280"})
    assert r.status_code == 201, r.text
    again = admin.post("/api/admin/reference-lists/colours", json={"code": code + "X", "name_en": "white", "name_ar": "x" + code})
    assert again.status_code == 409 and again.json()["error"]["code"] == "ENTRY_EXISTS"      # one colour, one spelling
    r = admin.patch(f"/api/admin/reference-lists/colours/{code}", json={"name_en": "Desert sand " + code[-6:]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "COLOUR_CHANGE_REASON"
    assert admin.patch(f"/api/admin/reference-lists/colours/{code}", json={"name_en": "Desert sand " + code[-6:], "reason": "the maker's name"}).status_code == 200
    assert admin.patch(f"/api/admin/reference-lists/colours/{code}", json={"status": "RETIRED"}).status_code == 200
    e = admin.get(f"/api/admin/reference-lists/colours/{code}").json()
    assert e["entry"]["status"] == "RETIRED" and {h["field"] for h in e["history"]} == {"name_en", "status"}
    assert code not in {c["code"] for c in carrier.get("/api/fleet/options").json()["colours"]}
    r = admin.post("/api/admin/reference-lists/axles", json={"code": "5x2", "name_en": "odd", "name_ar": "odd"})
    assert r.status_code == 422
    assert carrier.post("/api/admin/reference-lists/colours", json={"code": "NOPE", "name_en": "Nope", "name_ar": "Nope"}).status_code in (401, 403)
