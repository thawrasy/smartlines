"""Release 1.48.0, package F (review of release 1.47.0): structured logs with a trace that follows a request into its
outbox events and outbound calls (R-49), and report files built away from the request loop (R-46)."""
import asyncio
import json
import logging
import threading
import uuid

import pytest

from app import logs
from app.errors import ApiError
from app.modules.reports import export
from test_e2e import OWNER_URL, bookable_trip, client, free_seats, login, owner_sql, publish_fresh_trip, syrian

TRACE = "4bf92f3577b34da6a3ce929d0e0e4736"


def test_an_incoming_trace_is_kept_and_a_bad_one_replaced():
    assert logs.trace_from_header(f"00-{TRACE}-00f067aa0ba902b7-01") == TRACE
    for bad in (None, "", "garbage", f"00-{'0' * 32}-00f067aa0ba902b7-01", f"00-{TRACE}-short-01"):
        new = logs.trace_from_header(bad)
        assert len(new) == 32 and new != "0" * 32 and new != TRACE
    header = logs.traceparent(TRACE)
    assert header.startswith(f"00-{TRACE}-") and header.endswith("-01") and len(header) == 55


def test_a_log_line_is_one_json_object_with_the_request_and_trace():
    record = logging.LogRecord("masslak.access", logging.INFO, __file__, 1, "request", None, None)
    record.method, record.route, record.status, record.duration_ms, record.error_code = \
        "GET", "/api/bookings/{ref}", 404, 7, "NOT_FOUND"
    rid, tid = logs.request_id.set("r-1"), logs.trace_id.set(TRACE)
    try:
        line = json.loads(logs.JsonFormatter("api").format(record))
    finally:
        logs.request_id.reset(rid)
        logs.trace_id.reset(tid)
    assert {"ts", "severity", "service", "version", "environment", "logger", "message"} <= line.keys()
    assert line["request_id"] == "r-1" and line["trace_id"] == TRACE and line["route"] == "/api/bookings/{ref}"
    assert line["service"] == "api" and line["status"] == 404 and line["error_code"] == "NOT_FOUND"
    assert logs.correlation() is None                       # outside a request nothing is invented


def test_report_files_are_built_in_a_thread_and_a_burst_waits_or_is_refused(monkeypatch):
    seen = []
    monkeypatch.setattr(export, "render", lambda fmt, res, meta: seen.append(threading.current_thread()) or (b"x", "text/csv"))
    monkeypatch.setattr(export, "_slots", None)
    assert asyncio.run(export.render_async("csv", None, None)) == (b"x", "text/csv")
    assert seen and seen[0] is not threading.main_thread()  # the event loop kept answering meanwhile

    async def burst():
        export._slots = asyncio.Semaphore(1)
        await export._slots.acquire()                       # every slot busy with another file
        with pytest.raises(ApiError) as err:
            await export.render_async("csv", None, None)
        return err.value

    monkeypatch.setattr(export, "RENDER_WAIT", 0.05)
    err = asyncio.run(burst())
    assert err.status == 503 and err.code == "EXPORT_BUSY" and err.details["retry_after"] == 10
    monkeypatch.setattr(export, "_slots", None)


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_a_booking_carries_its_trace_into_the_response_and_its_outbox_event():
    c = client()
    trip = bookable_trip(c)
    if trip is None:
        publish_fresh_trip()
        trip = bookable_trip(c)
    pax = login("passenger@masslak.test", "PASSENGER")
    pax.headers["traceparent"] = f"00-{TRACE}-00f067aa0ba902b7-01"
    seat = free_seats(pax, trip, 1)[0]
    h = pax.post("/api/holds", json={"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"],
                                     "seat_nos": [seat]})
    assert h.status_code == 201, h.text
    assert h.headers["traceparent"].startswith(f"00-{TRACE}-")
    r = pax.post("/api/bookings", json={"hold_token": h.json()["hold_token"], "trip_uid": trip["uid"],
                                        "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "passengers": [syrian(seat)],
                                        "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    stored = owner_sql("""SELECT correlation_id::text FROM sys.outbox_event WHERE event_type = 'booking.confirmed'
                           AND payload ->> 'booking_ref' = $1""", r.json()["booking_ref"])
    assert stored == str(uuid.UUID(TRACE))
    del pax.headers["traceparent"]
    other = pax.get("/api/health")
    assert TRACE not in other.headers["traceparent"]       # a request without the header starts its own trace


def test_a_request_line_says_where_its_time_went():
    token = logs.phases.set({})
    try:
        logs.timed("pool_wait", 0.002)
        logs.timed("db", 0.010)
        logs.timed("db", 0.005)
        logs.timed("egress", 0.120)
        fields = logs.phase_fields(logs.phases.get())
    finally:
        logs.phases.reset(token)
    assert fields == {"pool_wait_ms": 2.0, "db_ms": 15.0, "db_transactions": 2, "egress_ms": 120.0, "egress_calls": 1}
    logs.timed("db", 1.0)                                   # outside a request: nothing to add to, nothing fails
    assert logs.phase_fields(None) == {}


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_the_security_console_reads_statement_statistics_without_values():
    sec = login("security@masslak.test", "PLATFORM")
    r = sec.get("/api/security/statements", params={"order": "MEAN", "limit": 5})
    assert r.status_code == 200, r.text
    body = r.json()
    on = owner_sql("SELECT sys.statement_stats_enabled()")
    assert body["enabled"] == on and len(body["statements"]) <= 5
    if on:
        means = [s["mean_ms"] for s in body["statements"]]
        assert means == sorted(means, reverse=True) and all("'" not in s["query"].replace("'?'", "") for s in body["statements"])
        assert sec.post("/api/security/statements/reset").status_code == 200
    else:
        assert body["statements"] == [] and sec.post("/api/security/statements/reset").status_code == 409
    assert sec.get("/api/security/statements", params={"order": "SLOW"}).status_code == 422
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get("/api/security/statements").status_code in (401, 403)
    metrics = owner_sql("SELECT string_agg(metric, ',') FROM sys.statement_metrics()")
    assert "masslak_db_statement_stats_enabled" in metrics
