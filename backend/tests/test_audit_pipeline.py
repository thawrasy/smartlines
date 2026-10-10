"""The audit pipeline after the reviews of October 2026: a request record the activity log cannot take is counted
and logged instead of vanishing, the signed archive's lag is measured per log, and personal data and secrets are
redacted from every log line whoever writes it."""
import asyncio
import json
import logging
import os
import sys
import time
from contextlib import asynccontextmanager

import asyncpg
import pytest
from starlette.requests import Request

from app import db, logredact
from app.middleware import RequestContextMiddleware

APP_URL = os.environ.get("MASSLAK_DATABASE_URL")


def test_log_lines_carry_no_personal_data_or_secrets():
    logredact.install()
    logredact.install()                                   # installing twice wraps once
    make = logging.getLogRecordFactory()
    rec = make("masslak.db", logging.WARNING, __file__, 1,
               "unexpected database error %s: %s", ("23505", "Key (email)=(rami@example.com) already exists"), None)
    assert rec.getMessage() == "unexpected database error 23505: Key (email)=([email]) already exists"
    # uvicorn's access formatter reads its arguments as a 5-tuple: the shape stays, the text is redacted
    access = make("uvicorn.access", logging.INFO, __file__, 1, '%s - "%s %s HTTP/%s" %d',
                  ("10.1.2.3:5000", "GET", "/api/x?token=s3cret&phone=0944123456", "1.1", 200), None)
    assert isinstance(access.args, tuple) and len(access.args) == 5 and access.args[4] == 200
    assert access.getMessage() == '10.1.2.3:5000 - "GET /api/x?token=[redacted]&phone=[number] HTTP/1.1" 200'
    line = logredact.redact("ticket 550e8400-e29b-41d4-a716-446655440000 for 01234567890 on 2026-10-09, Bearer abc.def.ghi1")
    assert line == "ticket 550e8400-e29b-41d4-a716-446655440000 for [number] on 2026-10-09, Bearer [redacted]"


def test_an_exception_in_a_log_line_is_redacted_too():
    """M-06: the traceback a log line carries quotes what failed (a database error names the value); it is redacted
    like the message, in the JSON lines and in the sandbox's text lines."""
    from app import logs
    try:
        raise ValueError('Key (email)=(rami@example.com) already exists; retry with token=s3cret-value phone 0944123456')
    except ValueError:
        record = logging.LogRecord("masslak.db", logging.ERROR, __file__, 1, "insert failed", None, sys.exc_info())
    record.route = "/api/x?token=abc123secret"
    for text in (logs.JsonFormatter("api").format(record), logs.RedactingFormatter("%(message)s").format(record)):
        assert "rami@example.com" not in text and "s3cret-value" not in text and "0944123456" not in text, text
        assert "[email]" in text and "ValueError" in text
    assert json.loads(logs.JsonFormatter("api").format(record))["route"] == "/api/x?token=[redacted]"


def test_a_lost_activity_record_is_counted_and_logged(monkeypatch, caplog):
    @asynccontextmanager
    async def broken():
        raise asyncpg.exceptions.DiskFullError("could not extend file")
        yield
    monkeypatch.setattr(db, "raw_connection", broken)
    request = Request({"type": "http", "method": "POST", "path": "/api/bookings", "headers": [], "query_string": b""})
    for name, value in (("principal", None), ("audit", None), ("request_id", None), ("client_ip", "10.0.0.1"),
                        ("api_client_id", None)):
        setattr(request.state, name, value)
    before = db.AUDIT_WRITE_FAILURES[0]
    with caplog.at_level(logging.WARNING, logger="masslak.audit"):
        asyncio.run(RequestContextMiddleware._log(None, request, "PASSENGER", "booking.create", "SUCCESS", 201, time.monotonic()))
    assert db.AUDIT_WRITE_FAILURES[0] == before + 1                      # the request itself was not broken
    assert any("activity log not written for POST /api/bookings" in r.getMessage() for r in caplog.records)


@pytest.mark.skipif(not APP_URL, reason="needs MASSLAK_DATABASE_URL")
def test_the_archive_lag_is_measured_per_log():
    async def run():
        conn = await asyncpg.connect(APP_URL)                             # as the application role, like the metrics endpoint
        try:
            rows = await conn.fetch("SELECT metric, labels, value FROM audit.archive_metrics()")
        finally:
            await conn.close()
        lag = {r["labels"]: r["value"] for r in rows if r["metric"] == "masslak_audit_unarchived_seconds"}
        assert len(lag) == 6 and all(v >= 0 for v in lag.values())
        recorded = [r["value"] for r in rows if r["metric"] == "masslak_audit_archive_recorded_age_seconds"]
        assert len(recorded) == 1
    asyncio.run(run())
