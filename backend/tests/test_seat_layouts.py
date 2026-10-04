"""Seat layouts end to end: a carrier defines the real arrangement, vehicles carry it, trips snapshot it and the
passenger sees it; tickets print the seat label."""
import secrets
import uuid

import pytest

from test_e2e import OWNER_URL, client, login, owner_sql


@pytest.fixture(scope="module")
def owner():
    return login("owner@carrier.test", "OPERATOR")


def test_preview_and_refusals(owner):
    r = owner.post("/api/carrier/seat-layouts/preset", json={"pattern": "2+1", "rows": 11, "door_row": 11})
    assert r.status_code == 200 and r.json()["total_seats"] == 32
    r = owner.post("/api/carrier/seat-layouts/preview", json={"decks": [["SS_SS", "SS_DD", "SSSSS"]]})
    assert r.json()["seats_per_row"] == [[4, 2, 5]] and r.json()["seats"][2]["label"] == "1D"
    r = owner.post("/api/carrier/seat-layouts/preview", json={"decks": [["SS_SS", "SS_S"]]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "LAYOUT_RAGGED"


def test_layout_vehicle_and_trip_snapshot(owner):
    name = f"Minibus 2+1 test {uuid.uuid4().hex[:6]}"
    grid = [["SS_S"] * 7 + ["SS_D", "SSSS"]]                   # 7 x 3 + 2 by the door + 4 at the back = 27
    r = owner.post("/api/carrier/seat-layouts", json={"name": name, "decks": grid})
    assert r.status_code == 201, r.text
    lay = r.json()["uid"]
    listed = next(x for x in owner.get("/api/carrier/seat-layouts").json()["layouts"] if x["uid"] == lay)
    assert listed["total_seats"] == 27 and listed["seats_per_row"][0][-2:] == [2, 4]

    plate = str(uuid.uuid4().int)[:6]
    base = {"plate_no": plate, "chassis_no": f"CHS-{plate}", "vehicle_type": "MINIBUS", "insurance_no": "POL-L",
            "insurer": "Test", "insurance_issue": "2026-01-01", "insurance_expiry": "2030-01-01"}
    r = owner.post("/api/carrier/vehicles", json=base)
    assert r.status_code == 422 and r.json()["error"]["code"] == "SEAT_LAYOUT_REQUIRED"
    r = owner.post("/api/carrier/vehicles", json={**base, "seat_layout_uid": lay, "passenger_seats": 30})
    assert r.status_code == 422 and r.json()["error"]["code"] == "SEAT_COUNT_MISMATCH"
    r = owner.post("/api/carrier/vehicles", json={**base, "seat_layout_uid": lay})
    assert r.status_code == 201, r.text
    vehicle = r.json()["uid"]
    v = next(x for x in owner.get("/api/carrier/vehicles").json()["vehicles"] if x["uid"] == vehicle)
    assert v["passenger_seats"] == 27 and v["seat_layout_name"] == name

    # A trip on this vehicle shows passengers the real layout
    route = next(x for x in owner.get("/api/carrier/routes").json()["routes"] if x["code"] == "DAM-DRA")
    r = owner.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": vehicle,
                                               "departure_local": f"2027-{1 + secrets.randbelow(12):02d}-{1 + secrets.randbelow(28):02d}"
                                                                  f"T{6 + secrets.randbelow(12):02d}:{secrets.randbelow(60):02d}"})
    assert r.status_code == 201, r.text
    detail = client().get(f"/api/trips/{r.json()['uid']}", params={"from_seq": 0, "to_seq": 1}).json()
    assert detail["seat_map"]["decks"] == grid and len(detail["seat_map"]["seats"]) == 27
    assert len(detail["seats"]) == 27 and detail["seat_map"]["seats"][-1]["label"] == "9D"

    # Changing the vehicle's layout later never moves seats on that trip
    other = owner.post("/api/carrier/seat-layouts", json={"name": name + " v2", "decks": [["SS_SS"] * 5]}).json()["uid"]
    r = owner.post(f"/api/carrier/vehicles/{vehicle}/layout", json={"layout_uid": other})
    assert r.status_code == 200 and r.json()["passenger_seats"] == 20
    again = client().get(f"/api/trips/{r.json() and detail['trip']['uid']}", params={"from_seq": 0, "to_seq": 1}).json()
    assert len(again["seat_map"]["seats"]) == 27
    assert owner.post(f"/api/carrier/seat-layouts/{lay}/archive").status_code == 200


def test_layouts_are_private_to_the_carrier(owner):
    r = owner.post("/api/carrier/seat-layouts", json={"name": f"Private {uuid.uuid4().hex[:6]}", "decks": [["S_S"] * 4]})
    lay = r.json()["uid"]
    admin = login("admin@masslak.test", "PLATFORM")
    assert admin.get(f"/api/carrier/seat-layouts/{lay}").status_code == 403      # wrong portal
    assert login("passenger@masslak.test", "PASSENGER").get("/api/carrier/seat-layouts").status_code == 403


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_database_keeps_vehicle_seats_equal_to_the_layout():
    import asyncpg
    with pytest.raises(asyncpg.RaiseError) as e:
        owner_sql("""UPDATE fleet.vehicle SET passenger_seats = passenger_seats + 1
                      WHERE id = (SELECT id FROM fleet.vehicle WHERE seat_layout_id IS NOT NULL LIMIT 1)""")
    assert "SEAT_COUNT_MISMATCH" in str(e.value)
