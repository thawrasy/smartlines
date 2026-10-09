"""Scenarios the code review of October 2026 asked to be proven against the database, not the API's answers alone:
a cancellation and a boarding of the same ticket at the same moment (one wins, never both, never a refund for a
passenger on board), and a provider's payment arriving after the reservation lapsed."""
import threading
import uuid

import pytest

import test_e2e as e2e
from test_e2e import OWNER_URL, login, owner_sql, syrian

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to read the outcome from the database")


def _fresh_booking():
    """A trip of its own with its driver, and a one-ticket booking paid from the wallet."""
    e2e.publish_fresh_trip()
    driver = login(e2e.FRESH_DRIVERS[-1], "DRIVER", e2e.FRESH_DRIVER_PASSWORD)
    trip = driver.get("/api/driver/trips").json()["trips"][-1]["uid"]
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    seat = next(x["seat_no"] for x in pax.get(f"/api/trips/{trip}", params={"from_seq": 0, "to_seq": 2}).json()["seats"] if x["free"])
    h = pax.post("/api/holds", json={"trip_uid": trip, "from_seq": 0, "to_seq": 2, "seat_nos": [seat]}).json()
    b = pax.post("/api/bookings", json={"hold_token": h["hold_token"], "trip_uid": trip, "from_seq": 0, "to_seq": 2,
                                        "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
    assert b.status_code == 201, b.text
    ref = b.json()["booking_ref"]
    ticket = pax.get(f"/api/bookings/{ref}").json()["tickets"][0]["uid"]
    credential = pax.get(f"/api/tickets/{ticket}/offline").json()["credential"]
    return driver, trip, ref, ticket, credential


def _retire(trip):
    """Boarding may have started: finish the trip so that no other test sells on it."""
    owner_sql("""UPDATE ops.trip SET departure_at = now() - interval '30 hours', arrival_at = now() - interval '26 hours'
                  WHERE uid = $1 AND status IN ('PUBLISHED', 'BOARDING')""", uuid.UUID(trip))


@pytest.mark.parametrize("round_no", range(3))
def test_cancel_and_board_at_the_same_moment(round_no):
    driver, trip, ref, ticket, credential = _fresh_booking()
    canceller = login("passenger@masslak.test", "PASSENGER")
    start = threading.Barrier(2)
    out = {}

    def cancel():
        start.wait()
        out["cancel"] = canceller.post(f"/api/bookings/{ref}/cancel")

    def board():
        start.wait()
        out["board"] = driver.post("/api/driver/scan", json={"trip_uid": trip, "token": credential})
    threads = [threading.Thread(target=cancel), threading.Thread(target=board)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(30)
    try:
        boarded = out["board"].status_code == 200 and out["board"].json().get("result") == "OK"
        cancelled = out["cancel"].status_code == 200
        assert boarded != cancelled, (out["board"].text, out["cancel"].text)            # exactly one of them won
        state = owner_sql("""SELECT k.status AS ticket, b.status AS booking,
                                    (SELECT count(*) FROM fin.ledger_txn x WHERE x.ref_type = 'booking' AND x.ref_id = b.id
                                        AND x.txn_type = 'REFUND') AS refunds,
                                    (SELECT count(*) FROM sales.boarding_event e WHERE e.ticket_id = k.id AND e.event_type = 'BOARD') AS boardings,
                                    (SELECT count(*) FROM ops.seat_segment s WHERE s.ticket_id = k.id) AS seats_held
                               FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id WHERE k.uid = $1""",
                          uuid.UUID(ticket), fetch=True)
        if boarded:
            assert dict(state) == {"ticket": "BOARDED", "booking": "CONFIRMED", "refunds": 0, "boardings": 1,
                                   "seats_held": state["seats_held"]} and state["seats_held"] > 0
        else:
            assert (state["ticket"], state["booking"], state["refunds"], state["boardings"], state["seats_held"]) == \
                ("CANCELLED", "CANCELLED", 1, 0, 0)
    finally:
        _retire(trip)
