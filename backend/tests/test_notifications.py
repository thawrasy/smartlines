"""Notifications end to end: the booking writes an outbox event in its own transaction, the worker turns it into an
in-app notification and an email (or an SMS for an agency traveller), failures back off, and wording follows the
reader's language without any text stored in the database."""
import json
import os
import subprocess
import sys
import uuid
from pathlib import Path

import pytest

from app.modules.notify.render import mask, render
from test_e2e import OWNER_URL, bookable_trip, client, free_seats, login, owner_sql, publish_fresh_trip, syrian

BACKEND = Path(__file__).resolve().parents[1]
MESSAGES = BACKEND.parent / "data" / "messages"


def run_worker():
    r = subprocess.run([sys.executable, "-m", "app.modules.notify.worker", "--once"], cwd=BACKEND, env=os.environ,
                       capture_output=True, text=True, timeout=120)
    assert r.returncode == 0, r.stderr[-2000:]


def logged(channel: str) -> list[dict]:
    path = MESSAGES / f"{channel}.jsonl"
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []


def test_rendering_follows_the_reader_language():
    values = {"booking_ref": "AB12CD", "from_city": "DAM", "to_city": "ALP", "departs_local": "2026-10-10 07:30",
              "passengers": 2, "total_amount": 5700000}
    subject, body = render("booking.confirmed", "EMAIL", "en", values)
    assert subject == "Booking AB12CD confirmed" and "Damascus to Aleppo" in body and "SYP 57,000" in body
    _, sms = render("booking.confirmed", "SMS", "ar", values)
    assert "AB12CD" in sms and "\u062f\u0645\u0634\u0642" in sms            # Damascus in Arabic script
    assert mask("owner@carrier.test") == "o***@carrier.test" and mask("+963944000111") == "+9639******11"


@pytest.fixture(scope="module")
def trip():
    c = client()
    t = bookable_trip(c)
    if t is None:
        publish_fresh_trip()
        t = bookable_trip(c)
    return t


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_booking_notifies_in_app_and_by_email(trip):
    pax = login("passenger@masslak.test", "PASSENGER")
    seat = free_seats(pax, trip, 1)[0]
    h = pax.post("/api/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "seat_nos": [seat]})
    assert h.status_code == 201, h.text
    r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": trip["uid"], "from_seq": trip["from_seq"],
                                        "to_seq": trip["to_seq"], "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    ref = r.json()["booking_ref"]
    assert owner_sql("""SELECT count(*) FROM sys.outbox_event WHERE event_type = 'booking.confirmed'
                         AND payload ->> 'booking_ref' = $1""", ref) == 1
    run_worker()
    mine = pax.get("/api/notifications").json()
    n = next(x for x in mine["notifications"] if x["payload"].get("booking_ref") == ref)
    assert n["template_code"] == "booking.confirmed" and "booker_user_id" not in n["payload"] and mine["unread"] >= 1
    assert any(ref in m["subject"] for m in logged("email"))
    stored = owner_sql("SELECT to_address FROM crm.notification WHERE channel = 'EMAIL' AND payload ->> 'booking_ref' = $1", ref)
    assert stored == "p***@masslak.test"
    assert pax.post("/api/notifications/read", json={"ids": [n["id"]]}).json()["updated"] == 1
    other = login("owner@carrier.test", "OPERATOR")
    assert all(x["id"] != n["id"] for x in other.get("/api/notifications").json()["notifications"])


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_failed_delivery_backs_off_and_retries():
    owner_sql("""INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload)
                 VALUES ('booking.confirmed', 'booking', 0, '{"booking_ref": "BROKEN"}')""")    # no recipient: fails
    run_worker()
    row = owner_sql("""SELECT status, attempts, last_error IS NOT NULL AS err, next_attempt_at > now() AS later
                        FROM sys.outbox_event WHERE payload ->> 'booking_ref' = 'BROKEN' ORDER BY id DESC LIMIT 1""", fetch=True)
    assert row["status"] == "PENDING" and row["attempts"] == 1 and row["err"] and row["later"]
    owner_sql("UPDATE sys.outbox_event SET status = 'FAILED' WHERE payload ->> 'booking_ref' = 'BROKEN'")


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_agency_sale_texts_the_traveller(trip):
    from test_agency import sell
    agency = login("agency@agency.test", "AGENCY")
    r = sell(agency, trip, free_seats(agency, trip, 1))
    assert r.status_code == 201, r.text
    ref = r.json()["booking_ref"]
    run_worker()
    sms = [m for m in logged("sms") if ref in m["body"]]
    assert sms and sms[-1]["to"] == "+963944000111"
