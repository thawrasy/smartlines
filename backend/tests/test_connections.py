"""Connections across carriers (owner's request, October 2026; migration 1130): from Daraa to Aleppo no trip runs direct,
so search offers Demo Carrier B's trip to Damascus with Demo Carrier A's trip from Damascus to Aleppo, leaving after the
change time the platform sets. The traveller accepts the risks before booking; the later trip is changeable (a flexible
fare, or a carrier that changes it free after a late first trip). A traveller who missed the second trip because the
first arrived late changes it under the carrier's policy; any booking may be changed before departure under its fare's
rules."""
import uuid

import pytest

from test_e2e import OWNER_URL, client, day, login, new_passenger, owner_sql, syrian

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _traveller(i: int) -> dict:
    p = syrian(i)
    p.pop("seat_no")
    return p


def _connections(offset: int) -> list[dict]:
    r = client().get("/api/trips/connections", params={"origin": "DRA", "destination": "ALP", "on": day(offset), "passengers": 1})
    assert r.status_code == 200, r.text
    return r.json()["connections"]


def _connection(offsets=range(2, 7), first_after: str | None = None) -> dict:
    for offset in offsets:
        found = [c for c in _connections(offset) if c["bookable"] and c["carriers"] == 2
                 and (first_after is None or c["legs"][0]["departs_at"][11:16] >= first_after)]
        if found:
            return found[0]
    pytest.skip("no connection from Daraa to Aleppo on sale")


def _legs(c: dict, brands=(None, None)) -> list[dict]:
    return [{"trip_uid": leg["trip_uid"], "from_seq": leg["from_seq"], "to_seq": leg["to_seq"]} | ({"fare_brand": b} if b else {})
            for leg, b in zip(c["legs"], brands)]


def _funded() -> object:
    pax = new_passenger()
    assert pax.post("/api/wallet/topup", json={"amount": 30_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    return pax


def _policy(owner, **body):
    r = owner.put("/api/carrier/connection-policy", json={"offer_in_connections": True, "missed_connection": "FARE_RULES",
                                                          "change_window_hours": 24} | body)
    assert r.status_code == 200, r.text
    return r.json()


@pytest.fixture
def carrier_a():
    owner = login("owner@carrier.test", "OPERATOR")
    yield owner
    owner_sql("DELETE FROM ops.carrier_connection_policy WHERE company_id = (SELECT id FROM iam.party WHERE legal_name = 'Demo Carrier A')")


def test_search_offers_a_connection_across_carriers_where_no_trip_runs_direct():
    direct = client().get("/api/trips/search", params={"origin": "DRA", "destination": "ALP", "on": day(2)}).json()["trips"]
    assert direct == []
    c = _connection()
    first, second = c["legs"]
    assert first["from_city"] == "DRA" and first["to_city"] == "DAM" and second["from_city"] == "DAM" and second["to_city"] == "ALP"
    assert first["carrier_name"] == "Demo Carrier B" and second["carrier_name"] == "Demo Carrier A" and c["carriers"] == 2
    assert c["change"]["city"] == "DAM" and c["change"]["same_station"] and 30 <= c["change"]["minutes"] <= 240
    assert first["policy"]["missed_connection"] == "FREE_CHANGE" and second["policy"]["missed_connection"] == "FARE_RULES"
    assert c["price"] == first["price"] + second["price"] and c["arrives_at"] == second["arrives_at"]
    r = client().get("/api/trips/connections", params={"origin": "DRA", "destination": "DRA", "on": day(2)})
    assert r.status_code == 422


def test_a_connection_is_booked_once_its_risks_are_accepted_with_a_changeable_second_trip():
    c = _connection()
    pax = _funded()
    body = {"kind": "CONNECTION", "legs": _legs(c), "passengers": [_traveller(1)], "idempotency_key": uuid.uuid4().hex}
    r = pax.post("/api/journeys", json=body)
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONNECTION_RISKS_NOT_ACCEPTED", r.text
    # the second carrier changes a missed trip under its fares' rules: a fare that cannot be changed is refused
    r = pax.post("/api/journeys", json=body | {"accept_risks": True, "legs": _legs(c, (None, "SAVER"))})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONNECTION_NEEDS_FLEX" and r.json()["error"]["leg"] == 2, r.text
    r = pax.post("/api/journeys", json=body | {"accept_risks": True, "legs": _legs(c, ("SAVER", "FLEX"))})
    assert r.status_code == 201, r.text
    j = r.json()
    assert j["kind"] == "CONNECTION" and j["status"] == "CONFIRMED" and [b["leg"] for b in j["bookings"]] == [1, 2]
    rows = owner_sql("""SELECT count(*) FILTER (WHERE risk_ack_at IS NOT NULL) AS acked, string_agg(DISTINCT k.fare_brand_code, ',' ORDER BY k.fare_brand_code) AS brands
                          FROM sales.booking b JOIN sales.ticket k ON k.booking_id = b.id WHERE b.journey_uid = $1::uuid""",
                     j["journey_uid"], fetch=True)
    assert rows["acked"] == 2 and rows["brands"] == "FLEX,SAVER"
    # two trips too far apart are not a connection: Daraa at the first light, Aleppo in the afternoon
    for offset in range(2, 7):
        firsts = [t for t in client().get("/api/trips/search", params={"origin": "DRA", "destination": "DAM", "on": day(offset)}).json()["trips"]
                  if t["bookable"]]
        seconds = [t for t in client().get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(offset)}).json()["trips"]
                   if t["bookable"]]
        if firsts and seconds:
            break
    f = min(firsts, key=lambda t: t["departs_at"])
    s = max(seconds, key=lambda t: t["departs_at"])
    legs = [{"trip_uid": f["uid"], "from_seq": f["from_seq"], "to_seq": f["to_seq"]},
            {"trip_uid": s["uid"], "from_seq": s["from_seq"], "to_seq": s["to_seq"], "fare_brand": "FLEX"}]
    r = pax.post("/api/journeys", json={"kind": "CONNECTION", "legs": legs, "passengers": [_traveller(2)], "accept_risks": True,
                                        "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONNECTION_TOO_LONG", r.text


def test_a_missed_connection_after_a_late_first_trip_is_changed_free_under_the_carriers_policy(carrier_a):
    assert carrier_a.put("/api/carrier/connection-policy", json={"missed_connection": "SOMETIMES"}).status_code == 422
    assert login("driver@carrier.test", "OPERATOR").put("/api/carrier/connection-policy", json={}).status_code == 403
    pol = _policy(carrier_a, missed_connection="FREE_CHANGE", change_window_hours=12, note="  We  carry you on our next trip. ")
    assert pol["missed_connection"] == "FREE_CHANGE" and pol["set"] and pol["note"] == "We carry you on our next trip."
    c = _connection(offsets=range(6, 1, -1))
    assert c["legs"][1]["policy"]["missed_connection"] == "FREE_CHANGE"
    pax = _funded()
    # with a carrier that changes a missed trip free, the second trip may take any fare
    r = pax.post("/api/journeys", json={"kind": "CONNECTION", "legs": _legs(c, ("STANDARD", "SAVER")), "passengers": [_traveller(3)],
                                        "accept_risks": True, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    first, second = r.json()["bookings"]
    before = pax.get("/api/wallet").json()["balance"]
    # before anything happened the saver fare cannot be changed
    opts = pax.get(f"/api/bookings/{second['booking_ref']}/change-options").json()
    assert not opts["change"]["allowed"] and opts["change"]["why"] == "NOT_CHANGEABLE" and opts["trips"] == []
    # the first trip arrives late in Damascus, and the second leaves without the traveller
    owner_sql("""UPDATE ops.trip_stop ts SET actual_arr = (SELECT sched_dep FROM ops.trip_stop x JOIN ops.trip t ON t.id = x.trip_id
                                                           WHERE t.uid = $2::uuid AND x.seq = $3) - interval '5 minutes'
                  FROM ops.trip t WHERE t.id = ts.trip_id AND t.uid = $1::uuid AND ts.seq = $4""",
              c["legs"][0]["trip_uid"], c["legs"][1]["trip_uid"], c["legs"][1]["from_seq"], c["legs"][0]["to_seq"])
    owner_sql("UPDATE ops.trip SET status = 'BOARDING' WHERE uid = $1::uuid", c["legs"][1]["trip_uid"])
    owner_sql("UPDATE ops.trip SET status = 'DEPARTED' WHERE uid = $1::uuid", c["legs"][1]["trip_uid"])
    opts = pax.get(f"/api/bookings/{second['booking_ref']}/change-options").json()
    st = opts["change"]
    assert st["allowed"] and st["missed"] and st["inbound_late"] and st["basis"] == "FREE_CHANGE" and st["fee"] == 0, st
    assert st["reason"] == "MISSED_CONNECTION" and st["refund"] == st["fares"] and st["policy"]["change_window_hours"] == 12
    later = [t for t in opts["trips"] if t["bookable"]]
    assert later and all(t["trip_uid"] != c["legs"][1]["trip_uid"] for t in later)
    key = uuid.uuid4().hex
    t = later[0]
    r = pax.post(f"/api/bookings/{second['booking_ref']}/change",
                 json={"trip_uid": t["trip_uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "idempotency_key": key})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["fee"] == 0 and out["basis"] == "FREE_CHANGE" and out["refunded"] == st["fares"] and out["booking_ref"] != second["booking_ref"]
    assert pax.get("/api/wallet").json()["balance"] == before + out["refunded"] - out["paid"]
    again = pax.post(f"/api/bookings/{second['booking_ref']}/change",
                     json={"trip_uid": t["trip_uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "idempotency_key": key})
    assert again.status_code == 200 and again.json()["replayed"] and again.json()["booking_ref"] == out["booking_ref"]
    old = owner_sql("SELECT status, cancel_reason FROM sales.booking WHERE booking_ref = $1", second["booking_ref"], fetch=True)
    assert old["status"] == "CANCELLED" and old["cancel_reason"] == "CHANGED"
    new = owner_sql("""SELECT b.journey_kind, b.journey_leg, b.risk_ack_at IS NOT NULL AS acked, o.booking_ref AS changed_from,
                              c.reason, c.basis, c.missed, c.inbound_late
                         FROM sales.booking b JOIN sales.booking o ON o.id = b.changed_from_id
                         JOIN sales.booking_change c ON c.to_booking_id = b.id WHERE b.booking_ref = $1""", out["booking_ref"], fetch=True)
    assert dict(new) == {"journey_kind": "CONNECTION", "journey_leg": 2, "acked": True, "changed_from": second["booking_ref"],
                         "reason": "MISSED_CONNECTION", "basis": "FREE_CHANGE", "missed": True, "inbound_late": True}
    seen = pax.get(f"/api/bookings/{out['booking_ref']}").json()
    assert seen["booking"]["status"] == "CONFIRMED" and seen["booking"]["changed_from"] == second["booking_ref"] and seen["journey"]["leg"] == 2
    assert pax.get(f"/api/bookings/{second['booking_ref']}").json()["booking"]["changed_to"] == out["booking_ref"]
    # a booking changed once is not changed again from the old reference
    r = pax.post(f"/api/bookings/{second['booking_ref']}/change",
                 json={"trip_uid": t["trip_uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 409
    # another passenger cannot change it
    assert new_passenger().get(f"/api/bookings/{out['booking_ref']}/change-options").status_code == 404
    # where the carrier does not change a missed trip, the ticket is lost
    _policy(carrier_a, missed_connection="NONE")
    r = pax.post("/api/journeys", json={"kind": "CONNECTION", "legs": _legs(c, (None, "FLEX")), "passengers": [_traveller(4)],
                                        "accept_risks": True, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code in (409, 422)                                  # the second trip has left: not on sale any more


def test_a_booking_is_changed_before_departure_under_its_fares_rules():
    pax = _funded()
    found = None
    for offset in range(2, 7):
        trips = [t for t in client().get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(offset)}).json()["trips"]
                 if t["bookable"]]
        if len(trips) >= 2:
            found = trips
            break
    if not found:
        pytest.skip("no two trips from Damascus to Aleppo on one day")
    t = found[0]
    leg = {"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"]}
    std = pax.post("/api/journeys", json={"kind": "ONE_WAY", "legs": [leg], "passengers": [_traveller(5)], "fare_brand": "STANDARD",
                                          "idempotency_key": uuid.uuid4().hex})
    assert std.status_code == 201, std.text
    ref = std.json()["bookings"][0]["booking_ref"]
    opts = pax.get(f"/api/bookings/{ref}/change-options").json()
    st = opts["change"]
    assert st["allowed"] and st["basis"] == "FARE_RULES" and not st["missed"] and st["reason"] == "CUSTOMER"
    assert st["fee"] == st["fares"] * 10 // 100 and st["refund"] == st["fares"] - st["fee"]
    target = next(x for x in opts["trips"] if x["bookable"])
    r = pax.post(f"/api/bookings/{ref}/change", json={"trip_uid": target["trip_uid"], "from_seq": target["from_seq"],
                                                      "to_seq": target["to_seq"], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 200 and r.json()["fee"] == st["fee"] and r.json()["basis"] == "FARE_RULES", r.text
    assert owner_sql("SELECT reason FROM sales.booking_change c JOIN sales.booking b ON b.id = c.from_booking_id WHERE b.booking_ref = $1", ref) == "CUSTOMER"
    # only another trip of the same carrier between the same cities
    r = pax.post(f"/api/bookings/{r.json()['booking_ref']}/change", json={"trip_uid": str(uuid.uuid4()), "from_seq": 0, "to_seq": 1,
                                                                          "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 409 and r.json()["error"]["code"] == "CHANGE_TRIP_INVALID", r.text
    saver = pax.post("/api/journeys", json={"kind": "ONE_WAY", "legs": [leg], "passengers": [_traveller(6)], "fare_brand": "SAVER",
                                            "idempotency_key": uuid.uuid4().hex})
    sref = saver.json()["bookings"][0]["booking_ref"]
    r = pax.post(f"/api/bookings/{sref}/change", json={"trip_uid": target["trip_uid"], "from_seq": target["from_seq"],
                                                       "to_seq": target["to_seq"], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NOT_CHANGEABLE", r.text


def test_the_platform_sets_whether_connections_are_offered_and_the_change_times():
    admin = login("admin@masslak.test", "PLATFORM")
    assert login("owner@carrier.test", "OPERATOR").get("/api/admin/connections/settings").status_code == 403
    now = admin.get("/api/admin/connections/settings").json()
    assert now["enabled"] and now["min_minutes"] == 30 and now["require_flexible"]
    r = admin.put("/api/admin/connections/settings", json=now | {"min_minutes_station_change": 20})
    assert r.status_code in (409, 422) and r.json()["error"]["code"] == "INVALID_SETTING", r.text
    try:
        r = admin.put("/api/admin/connections/settings", json=now | {"enabled": False})
        assert r.status_code == 200 and not r.json()["enabled"], r.text
        found = client().get("/api/trips/connections", params={"origin": "DRA", "destination": "ALP", "on": day(3)}).json()
        assert found == {"enabled": False, "settings": r.json(), "connections": []}
        # a change of an hour and a half at the same station takes the 05:30 and 08:00 trips out
        admin.put("/api/admin/connections/settings", json=now | {"min_minutes": 100, "min_minutes_station_change": 120})
        assert all(c["change"]["minutes"] >= 100 for c in _connections(3))
    finally:
        assert admin.put("/api/admin/connections/settings", json=now).status_code == 200
    # a carrier that keeps its trips out of connections is not offered in them
    owner_b = login("owner@carrierb.test", "OPERATOR")
    pol = owner_b.get("/api/carrier/connection-policy").json()
    assert pol["missed_connection"] == "FREE_CHANGE" and pol["set"]
    try:
        _policy(owner_b, offer_in_connections=False, missed_connection="FREE_CHANGE")
        assert _connections(3) == []
    finally:
        _policy(owner_b, missed_connection="FREE_CHANGE")
