"""Journeys booked together (owner's request, October 2026; migration 1121): one way, a round trip, or several places one
after the other, the same travellers on every trip, paid at once; nothing is booked unless every trip is. An agency books
a tourism group as one journey, split into bookings of at most four seats. The search offers direct trips and trips
with stops."""
import uuid

import pytest

from test_e2e import OWNER_URL, client, day, login, new_passenger, owner_sql, syrian

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _traveller(i: int) -> dict:
    p = syrian(i)
    p.pop("seat_no")
    return p


def _first(origin: str, destination: str, offsets=range(2, 9), after: str | None = None, seats: int = 1) -> dict:
    """The first trip on sale between two cities with enough seats, leaving after a time where one is given."""
    for offset in offsets:
        r = client().get("/api/trips/search", params={"origin": origin, "destination": destination, "on": day(offset), "passengers": 1})
        assert r.status_code == 200, r.text
        trips = [t for t in r.json()["trips"] if t["bookable"] and t["seats_left"] >= seats and (after is None or t["departs_at"] > after)]
        if trips:
            return trips[0]
    pytest.skip(f"no trip on sale from {origin} to {destination}")


def _leg(t: dict) -> dict:
    return {"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"]}


def test_a_round_trip_is_booked_in_one_go_and_paid_at_once():
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 20_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    out = _first("DAM", "ALP")
    back = _first("ALP", "DAM", after=out["arrives_at"])
    key = uuid.uuid4().hex
    body = {"kind": "ROUND_TRIP", "legs": [_leg(out), _leg(back)], "passengers": [_traveller(1), _traveller(2)], "idempotency_key": key}
    r = pax.post("/api/journeys", json=body)
    assert r.status_code == 201, r.text
    j = r.json()
    assert j["kind"] == "ROUND_TRIP" and j["status"] == "CONFIRMED" and [b["leg"] for b in j["bookings"]] == [1, 2]
    assert all(b["status"] == "CONFIRMED" for b in j["bookings"]) and j["totals"][0]["total"] == sum(b["total"] for b in j["bookings"])
    # the same journey sent again answers with it; nothing is booked twice
    again = pax.post("/api/journeys", json=body)
    assert again.status_code == 201 and again.json()["journey_uid"] == j["journey_uid"] and again.json()["bookings"] == j["bookings"]
    seen = pax.get(f"/api/journeys/{j['journey_uid']}")
    assert seen.status_code == 200 and [b["booking_ref"] for b in seen.json()["bookings"]] == [b["booking_ref"] for b in j["bookings"]]
    assert seen.json()["bookings"][1]["journey"]["from_city"] == "ALP"
    # each trip is its own booking, which shows the journey it belongs to
    detail = pax.get(f"/api/bookings/{j['bookings'][0]['booking_ref']}").json()
    assert detail["journey"]["uid"] == j["journey_uid"] and detail["journey"]["leg"] == 1 and len(detail["journey"]["bookings"]) == 2
    assert len(detail["tickets"]) == 2
    assert owner_sql("SELECT count(*) FROM sales.booking WHERE journey_uid = $1::uuid AND journey_kind = 'ROUND_TRIP'", j["journey_uid"]) == 2
    # another passenger does not see it
    assert new_passenger().get(f"/api/journeys/{j['journey_uid']}").status_code == 404


def test_a_journey_follows_the_order_of_travel_and_books_all_or_nothing():
    out = _first("DAM", "ALP")
    back = _first("ALP", "DAM", after=out["arrives_at"])
    pax = login("passenger@masslak.test", "PASSENGER")
    r = pax.post("/api/journeys", json={"kind": "ROUND_TRIP", "legs": [_leg(back), _leg(out)], "passengers": [_traveller(1)],
                                        "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 422 and r.json()["error"]["code"] == "JOURNEY_ORDER", r.text
    r = pax.post("/api/journeys", json={"kind": "ROUND_TRIP", "legs": [_leg(out)], "passengers": [_traveller(1)],
                                        "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 422                                              # a round trip has two trips
    # without the money for the second trip, the first is not booked either
    poor = new_passenger()
    key = uuid.uuid4().hex
    r = poor.post("/api/journeys", json={"kind": "MULTI_CITY", "legs": [_leg(out), _leg(back)], "passengers": [_traveller(1)],
                                         "idempotency_key": key})
    assert r.status_code in (402, 409, 422), r.text
    assert owner_sql("SELECT count(*) FROM sales.booking WHERE idempotency_key LIKE $1", f"{key}:%") == 0
    # a passenger books at most four seats at once; a larger group goes through an agency
    r = pax.post("/api/journeys", json={"kind": "ONE_WAY", "legs": [_leg(out)], "passengers": [_traveller(i) for i in range(5)],
                                        "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 422 and r.json()["error"]["code"] == "GROUP_THROUGH_AGENCY", r.text


def test_an_agency_books_a_tourism_group_on_a_journey_in_bookings_of_four():
    admin = login("admin@masslak.test", "PLATFORM")
    a = next(a for a in admin.get("/api/admin/agencies").json()["agencies"] if a["legal_name"] == "Demo Travel Agency")
    assert admin.post(f"/api/admin/agencies/{a['uid']}/agreement", json={
        "commission_bp": 500, "daily_limit": 10_000_000_000, "status": "ACTIVE", "reason": "journey test"}).status_code == 200
    assert admin.post(f"/api/admin/agencies/{a['uid']}/deposit", json={
        "amount": 60_000_000, "bank_reference": "TEST-JOURNEY", "idempotency_key": uuid.uuid4().hex}).status_code == 200
    agency = login("agency@agency.test", "AGENCY")
    first = _first("DAM", "HMA", seats=6)
    group = [_traveller(i) for i in range(6)]
    r = agency.post("/api/agency/journeys", json={"kind": "ONE_WAY", "legs": [_leg(first)], "passengers": group,
                                                  "idempotency_key": uuid.uuid4().hex, "contact_mobile": "+963944000111"})
    assert r.status_code == 201, r.text
    j = r.json()
    assert len(j["bookings"]) == 2 and all(b["leg"] == 1 for b in j["bookings"])
    tickets = owner_sql("""SELECT count(*) FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                            WHERE b.journey_uid = $1::uuid""", j["journey_uid"])
    assert tickets == 6
    assert agency.get(f"/api/agency/journeys/{j['journey_uid']}").json()["kind"] == "ONE_WAY"
    assert agency.get("/api/agency/journeys/options").json()["max_passengers"] == 50
    r = agency.post("/api/agency/journeys", json={"kind": "ONE_WAY", "legs": [_leg(first)], "passengers": [_traveller(i) for i in range(51)],
                                                  "idempotency_key": uuid.uuid4().hex, "contact_mobile": "+963944000111"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "GROUP_TOO_LARGE", r.text


def test_the_search_offers_direct_trips_or_trips_with_stops():
    c = client()
    for offset in range(1, 8):
        every = c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(offset)}).json()["trips"]
        if every:
            break
    direct = c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(offset), "stops": "direct"}).json()["trips"]
    stops = c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(offset), "stops": "stops"}).json()["trips"]
    assert all(t["stops_between"] == 0 for t in direct) and all(t["stops_between"] > 0 for t in stops)
    assert len(direct) + len(stops) == len(every)
    assert c.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(1), "stops": "maybe"}).status_code == 422


def test_a_baby_on_a_lap_travels_with_the_adult_on_every_trip():
    """A baby on an adult's lap takes no seat and is in the adult's booking on every leg of the journey (1121)."""
    import datetime as dt
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 20_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    out = _first("DAM", "ALP", seats=2)
    back = _first("ALP", "DAM", after=out["arrives_at"], seats=2)
    baby = _traveller(3) | {"birth_date": (dt.date.today() - dt.timedelta(days=300)).isoformat(), "with_adult": 2}
    for bad in ({**baby, "with_adult": 3}, {**baby, "birth_date": None}):
        r = pax.post("/api/journeys", json={"kind": "ROUND_TRIP", "legs": [_leg(out), _leg(back)], "passengers": [_traveller(1), _traveller(2), bad],
                                            "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 422, r.text
    r = pax.post("/api/journeys", json={"kind": "ROUND_TRIP", "legs": [_leg(out), _leg(back)], "passengers": [_traveller(1), _traveller(2), baby],
                                        "idempotency_key": uuid.uuid4().hex})
    if r.status_code == 422 and r.json()["error"]["code"] in ("SEAT_REQUIRED", "INFANT_SEAT_REQUIRED"):
        pytest.skip("the carrier seats every infant")
    assert r.status_code == 201, r.text
    j = r.json()
    legs = owner_sql("""SELECT string_agg(format('%s:%s:%s', leg, laps, n), ',' ORDER BY leg) FROM (
                          SELECT b.journey_leg AS leg, count(*) FILTER (WHERE k.seat_no IS NULL) AS laps, count(*) AS n FROM sales.ticket k
                            JOIN sales.booking b ON b.id = k.booking_id WHERE b.journey_uid = $1::uuid GROUP BY 1) x""", j["journey_uid"])
    assert legs == "1:1:3,2:1:3"                                                         # on both trips: two seats and a lap


def test_travellers_choose_their_seats_on_each_trip():
    """Seats chosen trip by trip: each traveller gets the seat chosen for them; a seat already taken, or a choice that does
    not give each traveller one seat, is refused and nothing is booked."""
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 20_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    out = _first("DAM", "ALP", seats=2)
    back = _first("ALP", "DAM", after=out["arrives_at"], seats=2)
    free = [s["seat_no"] for s in client().get(f"/api/trips/{out['uid']}", params={"from_seq": out["from_seq"], "to_seq": out["to_seq"]}).json()["seats"]
            if s["free"]]
    chosen = [free[-1], free[-2]]                                        # from the back of the vehicle, in the travellers' order
    people = [_traveller(1), _traveller(2)]
    body = {"kind": "ROUND_TRIP", "legs": [_leg(out) | {"seats": chosen}, _leg(back)], "passengers": people, "idempotency_key": uuid.uuid4().hex}
    r = pax.post("/api/journeys", json=body | {"legs": [_leg(out) | {"seats": chosen[:1]}, _leg(back)]})
    assert r.status_code == 422, r.text                                  # one seat for two travellers
    r = pax.post("/api/journeys", json=body)
    assert r.status_code == 201, r.text
    first = pax.get(f"/api/bookings/{r.json()['bookings'][0]['booking_ref']}").json()
    assert [t["seat_no"] for t in sorted(first["tickets"], key=lambda t: t["ticket_no"])] == chosen
    # the same seats again are taken now: refused, and nothing of the new journey is booked
    key = uuid.uuid4().hex
    r = pax.post("/api/journeys", json=body | {"idempotency_key": key})
    assert r.status_code == 409 and r.json()["error"]["code"] == "SEAT_TAKEN" and r.json()["error"]["leg"] == 1, r.text
    assert owner_sql("SELECT count(*) FROM sales.booking WHERE idempotency_key LIKE $1", f"{key}:%") == 0
