"""Travellers by type and the class (owner's decision N34; migration 1144): adults 1 to 4, children 0 to 6, infants on a
lap up to the adults and nine seats at most, all platform settings; the search field and every booking apply them, and
the class keeps the trips with free seats of that cabin."""
import uuid

import pytest

from test_e2e import OWNER_URL, client, day, login, new_passenger, syrian

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _search(**params):
    return client().get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(3), **params})


def test_the_search_field_counts_travellers_by_type_within_the_limits():
    refused = {
        "TOO_MANY_ADULTS": {"adults": 5},
        "TOO_MANY_CHILDREN": {"adults": 1, "children": 7},
        "TOO_MANY_LAP_INFANTS": {"adults": 2, "infants_lap": 3},
        "TOO_MANY_SEATS": {"adults": 4, "children": 5, "infants_seat": 1},
        "ADULT_REQUIRED": {"adults": 0, "children": 2},
    }
    for code, params in refused.items():
        r = _search(**params)
        assert r.status_code == 422 and r.json()["error"]["code"] == code, (code, r.text)
        assert (r.json()["error"]["max_adults"], r.json()["error"]["max_children"], r.json()["error"]["max_seats"]) == (4, 6, 9)
    # two adults, a child, a lap infant and an infant on a seat need four seats
    r = _search(adults=2, children=1, infants_lap=1, infants_seat=1)
    assert r.status_code == 200, r.text
    assert all(t["bookable"] == (t["seats_left"] >= 4) for t in r.json()["trips"])
    assert all("cabin_seats_left" not in t for t in r.json()["trips"])      # any class: no class count


def test_the_class_keeps_trips_with_free_seats_of_that_cabin():
    anyclass = _search(adults=1).json()["trips"]
    economy = _search(adults=1, cabin="ECONOMY").json()["trips"]
    assert economy and all(0 < t["cabin_seats_left"] <= t["seats_left"] for t in economy)
    assert {t["uid"] for t in economy} <= {t["uid"] for t in anyclass}
    # the demo fleet has no VIP seats: no trip offers that class
    assert _search(adults=1, cabin="VIP").json()["trips"] == []
    assert _search(adults=1, cabin="FIRST").status_code == 422


def test_a_booking_carries_four_adults_and_six_children_at_most():
    t = next(x for x in _search(adults=1).json()["trips"] if x["bookable"])
    pax = new_passenger()
    body = {"hold_token": str(uuid.uuid4()), "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
            "idempotency_key": uuid.uuid4().hex, "passengers": [syrian(i) | {"category": "ADULT"} for i in range(1, 6)]}
    r = pax.post("/api/bookings", json=body)
    assert r.status_code == 422 and r.json()["error"]["code"] == "TOO_MANY_ADULTS" and r.json()["error"]["max_adults"] == 4, r.text


def test_the_platform_changes_the_adults_and_children_with_the_decision_behind_them():
    admin = login("admin@masslak.test", "PLATFORM")
    try:
        r = admin.put("/api/admin/booking/passenger-mix", json={"max_adults": 3, "max_children": 5,
                                                                "basis": "Transport authority decision 14/2026"})
        assert r.status_code == 200, r.text
        assert (r.json()["max_adults"], r.json()["max_children"], r.json()["basis"]) == (3, 5, "Transport authority decision 14/2026")
        assert client().get("/api/ref").json()["booking"]["max_adults"] == 3
        assert _search(adults=4).json()["error"]["code"] == "TOO_MANY_ADULTS"
        r = admin.put("/api/admin/booking/passenger-mix", json={"max_adults": 12, "max_children": 0, "basis": "more adults than seats"})
        assert r.status_code == 409 and r.json()["error"]["code"] == "INVALID_SETTING", r.text
        r = login("owner@carrier.test", "OPERATOR").put("/api/admin/booking/passenger-mix", json={
            "max_adults": 4, "max_children": 6, "basis": "a carrier tries"})
        assert r.status_code == 403
    finally:
        assert admin.put("/api/admin/booking/passenger-mix", json={"max_adults": 4, "max_children": 6,
                                                                   "basis": "back to the approved default"}).status_code == 200
