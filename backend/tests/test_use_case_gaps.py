"""The gaps found by the review of the use cases (October 2026), end to end: the platform opens tracking alerts on its
own (1100); the driver and the passengers raise an SOS and the driver reports incidents from the apps (1101)."""
import uuid

import pytest

from test_e2e import (FRESH_DRIVER_PASSWORD, FRESH_DRIVERS, OWNER_URL, day, free_seats, login, owner_sql, publish_fresh_trip,
                      syrian)
from test_notifications import run_worker


def fresh_trip():
    """A trip of its own (vehicle, driver) for the carrier owner@carrier.test, still PUBLISHED, with no tickets."""
    publish_fresh_trip()
    return owner_sql("""SELECT t.id, t.uid, t.trip_no, t.vehicle_id FROM ops.trip t JOIN iam.company_member m ON m.company_id = t.company_id
                         JOIN iam.app_user u ON u.id = m.user_id
                        WHERE u.email = 'owner@carrier.test' AND t.status = 'PUBLISHED'
                          AND NOT EXISTS (SELECT 1 FROM sales.ticket k WHERE k.trip_id = t.id)
                        ORDER BY t.id DESC LIMIT 1""", fetch=True)


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_silent_departed_trip_alerts_the_carrier():
    trip = fresh_trip()
    o = login("owner@carrier.test", "OPERATOR")
    owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '10 minutes',
                 arrival_at = now() + interval '3 hours' WHERE id = $1""", trip["id"])
    try:
        run_worker()
        alert = owner_sql("""SELECT kind, severity FROM ops.tracking_alert WHERE trip_id = $1 AND status = 'OPEN'""", trip["id"], fetch=True)
        assert alert and alert["kind"] == "SIGNAL_LOST" and alert["severity"] == "MEDIUM"
        board = o.get("/api/carrier/dashboard").json()
        assert any(a["kind"] == "TRACKING_SIGNAL_LOST" and a["subject"] == trip["trip_no"] for a in board["alerts"])
        run_worker()                    # the next pass sends the notice and does not open a second alert
        assert owner_sql("SELECT count(*) FROM ops.tracking_alert WHERE trip_id = $1", trip["id"]) == 1
        told = o.get("/api/notifications").json()["notifications"]
        assert any(n["template_code"] == "tracking.signal_lost" and n["payload"].get("trip_no") == trip["trip_no"] for n in told)
    finally:
        owner_sql("UPDATE ops.tracking_alert SET status = 'RESOLVED', resolved_at = now() WHERE trip_id = $1 AND status = 'OPEN'", trip["id"])
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_sos_and_incident_from_the_apps():
    trip = fresh_trip()
    driver = login(FRESH_DRIVERS[-1], "DRIVER", FRESH_DRIVER_PASSWORD)
    pax = login("passenger@masslak.test", "PASSENGER")
    # the passenger books a seat while the trip is on sale
    found = pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
    t = next(x for x in found if x["uid"] == str(trip["uid"]))
    seat = free_seats(pax, t, 1)[0]
    h = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
    assert h.status_code == 201, h.text
    r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                        "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    ticket = pax.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"][0]["uid"]
    # two days before departure the trip is not under way: no SOS yet
    r = pax.post(f"/api/tickets/{ticket}/sos", json={})
    assert r.status_code == 409 and r.json()["error"]["code"] == "SOS_TRIP_NOT_ACTIVE"
    owner_sql("""UPDATE ops.trip SET status = 'DEPARTED', departure_at = now() - interval '1 hour', arrival_at = now() + interval '3 hours'
                  WHERE id = $1""", trip["id"])
    try:
        r = pax.post(f"/api/tickets/{ticket}/sos", json={"lat": 34.73, "lng": 36.71})
        assert r.status_code == 201 and r.json()["role"] == "PASSENGER" and not r.json()["repeated"], r.text
        pax_sos = r.json()["sos_id"]
        again = pax.post(f"/api/tickets/{ticket}/sos", json={})
        assert again.json()["repeated"] and again.json()["sos_id"] == r.json()["sos_id"]
        other = login("owner@carrier.test", "OPERATOR")
        assert other.post(f"/api/tickets/{ticket}/sos", json={}).status_code == 403          # not a passenger session
        r = driver.post("/api/driver/sos", json={"trip_uid": str(trip["uid"])})
        assert r.status_code == 201 and r.json()["role"] == "DRIVER", r.text
        driver_sos = r.json()["sos_id"]
        r = driver.post("/api/driver/incidents", json={"trip_uid": str(trip["uid"]), "type": "COLLISION", "severity": "SEVERE",
                                                       "injuries": True, "description": "Rear-ended at the toll gate"})
        assert r.status_code == 201, r.text
        assert r.json()["sos_id"] == driver_sos and r.json()["vehicle_out_of_service"]
        incident = r.json()["incident_id"]
        # the carrier sees the incident and the alarms, and reviews the incident
        o = login("owner@carrier.test", "OPERATOR")
        rows = o.get("/api/r/incident", params={"f_status": "OPEN"}).json()["rows"]
        mine = next(x for x in rows if str(x["_key"]) == str(incident))
        assert mine["severity"] == "SEVERE" and mine["reported_via"] == "DRIVER_APP"
        assert o.post(f"/api/r/incident/{incident}/do/review").status_code == 200
        alarms = o.get("/api/r/sos-event", params={"f_status": "OPEN"}).json()["rows"]
        assert {str(driver_sos), str(pax_sos)} <= {str(a["_key"]) for a in alarms}
        assert o.post(f"/api/r/sos-event/{driver_sos}/do/acknowledge").status_code == 200
        # the owners and the platform's security staff are told
        run_worker()
        told = o.get("/api/notifications").json()["notifications"]
        assert any(n["template_code"] == "sos.raised" and n["payload"]["trip_no"] == trip["trip_no"] for n in told)
        assert any(n["template_code"] == "incident.reported" and n["payload"]["trip_no"] == trip["trip_no"] for n in told)
        assert owner_sql("""SELECT count(*) FROM crm.notification n JOIN iam.app_user u ON u.id = n.user_id
                             WHERE u.email = 'security@masslak.test' AND n.template_code = 'sos.raised'
                               AND n.payload ->> 'trip_no' = $1""", trip["trip_no"]) >= 1
        # the vehicle is out of service: it cannot take another trip until released
        assert owner_sql("""SELECT count(*) FROM fleet.vehicle_service_status WHERE vehicle_id = $1 AND status = 'OUT_OF_SERVICE'
                             AND period @> now()""", trip["vehicle_id"]) == 1
        # someone who is not on the trip cannot raise an SOS on it
        stranger_ticket = owner_sql("""SELECT k.uid FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                                        JOIN iam.app_user u ON u.party_id = b.booker_party_id
                                       WHERE u.email <> 'passenger@masslak.test' AND k.trip_id = $1 LIMIT 1""", trip["id"])
        assert stranger_ticket is None or pax.post(f"/api/tickets/{stranger_ticket}/sos", json={}).status_code == 404
    finally:
        owner_sql("UPDATE sec.sos_event SET status = 'CLOSED' WHERE trip_id = $1", trip["id"])
        owner_sql("UPDATE ops.trip SET status = 'CANCELLED' WHERE id = $1", trip["id"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_carrier_cancels_a_trip_with_full_refunds():
    trip = fresh_trip()
    admin = login("admin@masslak.test", "PLATFORM")
    owner = login("owner@carrier.test", "OPERATOR")
    counter = login("counter@carrier.test", "OPERATOR")
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    company = owner_sql("SELECT company_id FROM ops.trip WHERE id = $1", trip["id"])
    assert admin.put(f"/api/admin/cash/limits/{company}", json={"limit_amount": 10_000_000_000, "reason": "test run"}).status_code == 200
    t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(2), "passengers": 1}).json()["trips"]
             if x["uid"] == str(trip["uid"]))
    wallet_before = pax.get("/api/wallet").json()["balance"]
    owed_before = counter.get("/api/carrier/counter/dashboard").json()["owed"]

    def sell(c, base, **extra):
        seat = free_seats(c, t, 1)[0]
        h = c.post(f"{base}/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]})
        assert h.status_code == 201, h.text
        r = c.post(f"{base}/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"],
                                             "to_seq": t["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex, **extra})
        assert r.status_code == 201, r.text
        return r.json()

    online = sell(pax, "/api")
    cash = sell(counter, "/api/carrier/counter", contact_mobile="+963944000333")
    assert pax.get("/api/wallet").json()["balance"] == wallet_before - online["total"]
    # a reason is required, and the counter clerk may not cancel trips
    assert owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "x"}).status_code == 422
    assert counter.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "Vehicle failed inspection"}).status_code == 403
    r = owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "Vehicle failed inspection"})
    assert r.status_code == 200, r.text
    out = r.json()
    assert out["bookings_refunded"] == 2 and out["refund_total"] == online["total"] + cash["total"]
    # everything paid comes back to where it came from: the wallet in full (fee included), the counter's cash account
    assert pax.get("/api/wallet").json()["balance"] == wallet_before
    assert counter.get("/api/carrier/counter/dashboard").json()["owed"] == owed_before
    assert pax.get(f"/api/bookings/{online['booking_ref']}").json()["booking"]["status"] == "CANCELLED"
    assert owner_sql("""SELECT count(*) FROM fin.price_allocation_line l JOIN sales.booking b ON b.price_allocation_id = l.allocation_id
                         WHERE b.trip_id = $1 AND l.status <> 'REFUNDED'""", trip["id"]) == 0
    assert owner_sql("SELECT status FROM ops.trip WHERE id = $1", trip["id"]) == "CANCELLED"
    assert owner_sql("SELECT reason FROM ops.trip_disruption WHERE trip_id = $1 AND decision = 'CANCEL'", trip["id"]) == "Vehicle failed inspection"
    assert owner_sql("SELECT count(*) FROM ops.crew_assignment WHERE trip_id = $1 AND status <> 'RELEASED'", trip["id"]) == 0
    again = owner.post(f"/api/carrier/trips/{trip['uid']}/cancel", json={"reason": "Vehicle failed inspection"})
    assert again.status_code == 409 and again.json()["error"]["code"] == "TRIP_NOT_CANCELLABLE"
    # the travellers are told: in the app for the passenger, by text for the counter's customer
    run_worker()
    told = pax.get("/api/notifications").json()["notifications"]
    n = next(x for x in told if x["template_code"] == "booking.cancelled_by_carrier" and x["payload"]["booking_ref"] == online["booking_ref"])
    assert n["payload"]["refund_to"] == "WALLET" and n["payload"]["refund_amount"] == online["total"]
    assert owner_sql("""SELECT payload ->> 'refund_to' FROM sys.outbox_event WHERE event_type = 'booking.cancelled_by_carrier'
                         AND payload ->> 'booking_ref' = $1""", cash["booking_ref"]) == "COUNTER"
