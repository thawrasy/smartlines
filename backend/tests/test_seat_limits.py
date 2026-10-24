"""Seats booked at once (owner's decision, October 2026; migration 1122): nine by default since N34 (1144), with four
adults and six children at most, the platform's to change as a regulator may require; a family head books up to the family's size when it is larger, within a ceiling the platform
sets. Every channel holds and books within the limit; the screens read it."""
import uuid

import pytest

from test_e2e import OWNER_URL, client, day, login, new_passenger, owner_sql, syrian
from test_families import make_family, years_ago

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _trip(seats: int) -> dict:
    for offset in range(1, 9):
        r = client().get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(offset), "passengers": seats})
        trips = [t for t in r.json()["trips"] if t["bookable"]]
        if trips:
            return trips[0]
    pytest.skip("no trip with enough free seats")


def _free(c, t, n) -> list[int]:
    seats = c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]}).json()["seats"]
    return [x["seat_no"] for x in seats if x["free"]][:n]


def _hold(c, t, seats):
    return c.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": seats})


def test_nine_seats_by_default_and_more_for_a_larger_family():
    assert {k: client().get("/api/ref").json()["booking"][k] for k in ("max_seats", "max_adults", "max_children")} == {
        "max_seats": 9, "max_adults": 4, "max_children": 6}
    t = _trip(11)
    pax = new_passenger()
    assert pax.get("/api/bookings/limits").json() == {"max_seats": 9, "default_seats": 9, "family": False}
    r = _hold(pax, t, _free(pax, t, 10))
    assert r.status_code == 422 and r.json()["error"]["code"] == "TOO_MANY_SEATS" and r.json()["error"]["max_seats"] == 9, r.text
    # a booking of ten seats is refused by the server whatever the form sent
    r = pax.post("/api/bookings", json={"hold_token": str(uuid.uuid4()), "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
                                        "idempotency_key": uuid.uuid4().hex, "passengers": [syrian(i) for i in range(1, 11)]})
    assert r.status_code == 422 and r.json()["error"]["code"] == "TOO_MANY_SEATS", r.text
    # the head of a family of ten books ten seats
    head = new_passenger()
    make_family(head, *[(rel, name, years_ago(age), {}) for rel, name, age in
                        [("SPOUSE", "Lina", 35), ("SON", "Sami", 15), ("DAUGHTER", "Rana", 14), ("SON", "Fadi", 12),
                         ("DAUGHTER", "Mona", 10), ("SON", "Omar", 9), ("DAUGHTER", "Huda", 7), ("SON", "Ziad", 5),
                         ("DAUGHTER", "Salma", 3)]])
    assert head.get("/api/bookings/limits").json() == {"max_seats": 10, "default_seats": 9, "family": True}
    r = _hold(head, t, _free(head, t, 10))
    assert r.status_code == 201, r.text
    assert head.delete(f"/api/holds/{r.json()['hold_token']}").json()["released_seats"] == 10
    assert _hold(head, t, _free(head, t, 11)).status_code == 422


def test_the_platform_changes_the_limits_with_the_decision_behind_them():
    admin = login("admin@masslak.test", "PLATFORM")
    before = admin.get("/api/admin/booking/seat-limits").json()
    assert (before["max_seats"], before["family_max_seats"], before["agency_group"]) == (9, 10, 50)
    try:
        r = admin.put("/api/admin/booking/seat-limits", json={"max_seats": 3, "family_max_seats": 8, "agency_group": 40,
                                                               "basis": "Transport authority decision 12/2026"})
        assert r.status_code == 200, r.text
        assert r.json()["max_seats"] == 3 and r.json()["basis"] == "Transport authority decision 12/2026"
        assert client().get("/api/ref").json()["booking"]["max_seats"] == 3
        pax = new_passenger()
        t = _trip(4)
        assert _hold(pax, t, _free(pax, t, 4)).status_code == 422
        assert login("agency@agency.test", "AGENCY").get("/api/agency/journeys/options").json() == {
            "max_passengers": 40, "seats_per_booking": 3, "max_legs": 6}
        # a family is never held below anyone; an agency's group is at least one booking
        r = admin.put("/api/admin/booking/seat-limits", json={"max_seats": 5, "family_max_seats": 4, "agency_group": 40, "basis": "test"})
        assert r.status_code == 409 and r.json()["error"]["code"] == "INVALID_SETTING", r.text
        # the platform alone sets them
        r = login("owner@carrier.test", "OPERATOR").put("/api/admin/booking/seat-limits", json={
            "max_seats": 9, "family_max_seats": 9, "agency_group": 40, "basis": "a carrier tries"})
        assert r.status_code == 403
    finally:
        assert admin.put("/api/admin/booking/seat-limits", json={"max_seats": 9, "family_max_seats": 10, "agency_group": 50,
                                                                 "basis": "back to the approved default"}).status_code == 200
    assert owner_sql("SELECT sales.seat_limit(NULL)") == 9
