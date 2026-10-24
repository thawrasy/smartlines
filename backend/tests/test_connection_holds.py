"""A connection's missed trip stays changeable after the carrier completes it (owner's decision, October 2026; migration
1132): completing the trip holds the escrow of a connection's booking that all its travellers missed, keeps its tickets
issued, and lets the traveller change it until the carrier's change window ends. When the window ends, the worker
releases the escrow to the carrier, closes the tickets as no-show and completes the booking."""
import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

from test_connections import _connection, _funded, _legs, _policy, _traveller, carrier_a  # noqa: F401 - the fixture
from test_e2e import OWNER_URL, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
BACKEND = Path(__file__).resolve().parents[1]
# the trip left without its travellers: its window is moved far back so it overlaps none of its vehicle's other trips
_DEPARTED = """UPDATE ops.trip SET departure_at = timestamptz '2016-01-04 06:00+03', arrival_at = timestamptz '2016-01-04 08:00+03',
                      status = 'DEPARTED' WHERE uid = '{trip}'"""


def _without_triggers(sql: str, *args):
    """A test-only change the database's own rules forbid (a trip's departure, a hold's end), made as the owner."""
    owner_sql(f"DO $do$ BEGIN SET LOCAL session_replication_role = replica; {sql}; END $do$", *args)


def _book(c: dict, who: int) -> tuple[object, dict]:
    pax = _funded()
    r = pax.post("/api/journeys", json={"kind": "CONNECTION", "legs": _legs(c, ("STANDARD", "FLEX")), "passengers": [_traveller(who)],
                                        "accept_risks": True, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    return pax, r.json()["bookings"][1]


def test_a_missed_connection_is_held_after_the_trip_is_completed_then_released(carrier_a):  # noqa: F811
    _policy(carrier_a, missed_connection="FARE_RULES", change_window_hours=12)
    c = _connection(offsets=range(6, 1, -1))
    trip = c["legs"][1]["trip_uid"]
    (pax1, held1), (pax2, held2) = _book(c, 5), _book(c, 6)
    # the second trip leaves without either traveller and the carrier completes it
    _without_triggers(_DEPARTED.format(trip=trip))
    r = carrier_a.post(f"/api/carrier/trips/{trip}/complete")
    assert r.status_code == 200, r.text
    assert r.json()["connections_held"] >= 2
    for ref in (held1["booking_ref"], held2["booking_ref"]):
        row = owner_sql("""SELECT b.status, h.status AS hold, h.basis, bool_and(k.status = 'ISSUED') AS issued,
                                  bool_and(l.status IN ('HELD', 'PARTIAL_REFUND')) AS escrow
                             FROM sales.booking b JOIN sales.connection_hold h ON h.booking_id = b.id
                             JOIN sales.ticket k ON k.booking_id = b.id
                             JOIN fin.price_allocation a ON a.booking_id = b.id JOIN fin.price_allocation_line l ON l.allocation_id = a.id AND l.is_leaf
                            WHERE b.booking_ref = $1 GROUP BY b.status, h.status, h.basis""", ref, fetch=True)
        assert dict(row) == {"status": "CONFIRMED", "hold": "HELD", "basis": "FARE_RULES", "issued": True, "escrow": True}

    # the first traveller changes the missed trip under the fare's rules, after the carrier closed it
    opts = pax1.get(f"/api/bookings/{held1['booking_ref']}/change-options").json()
    st = opts["change"]
    assert st["allowed"] and st["missed"] and st["basis"] == "FARE_RULES", st
    t = next(x for x in opts["trips"] if x["bookable"])
    r = pax1.post(f"/api/bookings/{held1['booking_ref']}/change",
                  json={"trip_uid": t["trip_uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 200, r.text
    assert owner_sql("SELECT h.status FROM sales.connection_hold h JOIN sales.booking b ON b.id = h.booking_id WHERE b.booking_ref = $1",
                     held1["booking_ref"]) == "CHANGED"

    # the second does nothing: when the window ends the worker gives the carrier its money and closes the tickets
    _without_triggers(f"""UPDATE sales.connection_hold SET hold_until = now() - interval '1 minute'
                           WHERE booking_id = (SELECT id FROM sales.booking WHERE booking_ref = '{held2["booking_ref"]}')""")
    run = subprocess.run([sys.executable, "-m", "app.modules.notify.worker", "--once"], cwd=BACKEND, env=os.environ,
                         capture_output=True, text=True, timeout=300)
    assert run.returncode == 0, run.stderr[-2000:]
    row = owner_sql("""SELECT b.status, h.status AS hold, h.closed_at IS NOT NULL AS closed, bool_and(k.status = 'NO_SHOW') AS no_show,
                              (SELECT count(*) FROM fin.ledger_txn x WHERE x.idempotency_key = 'hold:' || b.id || ':release') AS released
                         FROM sales.booking b JOIN sales.connection_hold h ON h.booking_id = b.id JOIN sales.ticket k ON k.booking_id = b.id
                        WHERE b.booking_ref = $1 GROUP BY b.id, b.status, h.status, h.closed_at""", held2["booking_ref"], fetch=True)
    assert dict(row) == {"status": "COMPLETED", "hold": "RELEASED", "closed": True, "no_show": True, "released": 1}
    opts = pax2.get(f"/api/bookings/{held2['booking_ref']}/change-options").json()
    assert not opts["change"]["allowed"]


def test_nothing_is_held_where_the_carrier_does_not_change_a_missed_trip(carrier_a):  # noqa: F811
    _policy(carrier_a, missed_connection="NONE")
    c = _connection(offsets=range(6, 1, -1))
    trip = c["legs"][1]["trip_uid"]
    _, missed = _book(c, 7)
    _without_triggers(_DEPARTED.format(trip=trip))
    r = carrier_a.post(f"/api/carrier/trips/{trip}/complete")
    assert r.status_code == 200, r.text
    assert owner_sql("SELECT status FROM sales.booking WHERE booking_ref = $1", missed["booking_ref"]) == "COMPLETED"
    assert owner_sql("SELECT count(*) FROM sales.connection_hold h JOIN sales.booking b ON b.id = h.booking_id WHERE b.booking_ref = $1",
                     missed["booking_ref"]) == 0
