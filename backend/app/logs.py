"""Structured logs and trace identifiers (review of release 1.47.0, report 3).

With MASSLAK_LOG_FORMAT=json (the default outside the sandbox) every log line is one JSON object with fixed fields:
ts (UTC), severity, service, version, environment, logger, message, and, inside a request or an outbox event,
request_id and trace_id; request lines add method, route (the route template, never the raw path), status,
duration_ms, error_code and where the time went (pool_wait_ms, db_ms with db_transactions, egress_ms with egress_calls). Personal data and secrets are removed before any of this (app.logredact).

The trace identifier follows the W3C Trace Context header: a request that brings `traceparent` keeps its trace, any
other gets a new one, and the response returns it. It travels on: into the outbox events a request writes
(sys.outbox_event.correlation_id), the worker's logs for them and their webhook deliveries, and every outbound call
through the egress proxy, so one booking can be followed from the browser to the provider and back.
"""
from __future__ import annotations

import contextvars
import json
import logging
import os
import re
import secrets
import sys
import uuid
from datetime import datetime, timezone
from typing import Optional

request_id: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar("request_id", default=None)
trace_id: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar("trace_id", default=None)
# where a request's time went, in seconds: waiting for a database connection, holding one (statements and the code
# between them), and outbound calls. The middleware gives each request its own dict and logs it with the request.
phases: contextvars.ContextVar[Optional[dict]] = contextvars.ContextVar("phases", default=None)

_version = "unknown"            # the release the database is at, set once the process knows it (set_version)
_TRACEPARENT = re.compile(r"^00-([0-9a-f]{32})-([0-9a-f]{16})-[0-9a-f]{2}$")
_FIELDS = ("method", "route", "status", "duration_ms", "error_code", "event", "event_type",
           "pool_wait_ms", "db_ms", "db_transactions", "egress_ms", "egress_calls")


def trace_from_header(value: Optional[str]) -> str:
    """The trace of an incoming traceparent header, or a new one (an all-zero trace is invalid by the standard)."""
    m = _TRACEPARENT.match((value or "").strip().lower())
    if m and m.group(1) != "0" * 32:
        return m.group(1)
    return secrets.token_hex(16)


def traceparent(trace: Optional[str] = None) -> Optional[str]:
    """A traceparent header for an outgoing call or a response, with a new span of this service."""
    trace = trace or trace_id.get()
    return f"00-{trace}-{secrets.token_hex(8)}-01" if trace else None


def timed(phase: str, seconds: float) -> None:
    """Adds time to a phase of the current request (no-op outside one)."""
    p = phases.get()
    if p is not None:
        p[phase] = p.get(phase, 0.0) + seconds
        p[phase + "_n"] = p.get(phase + "_n", 0) + 1


def phase_fields(p: Optional[dict]) -> dict:
    """The phases of a request as log fields: pool_wait_ms, db_ms, db_transactions, egress_ms, egress_calls."""
    if not p:
        return {}
    out = {}
    if "db" in p:
        out.update(pool_wait_ms=round(p.get("pool_wait", 0.0) * 1000, 1), db_ms=round(p["db"] * 1000, 1),
                   db_transactions=p["db_n"])
    if "egress" in p:
        out.update(egress_ms=round(p["egress"] * 1000, 1), egress_calls=p["egress_n"])
    return out


def correlation() -> Optional[uuid.UUID]:
    """The current trace as the UUID an outbox event keeps."""
    trace = trace_id.get()
    return uuid.UUID(trace) if trace else None


class JsonFormatter(logging.Formatter):
    def __init__(self, service: str):
        super().__init__()
        from .config import get_settings
        s = get_settings()
        self.base = {"service": service, "environment": s.environment or ("sandbox" if s.sandbox else "production")}

    def format(self, record: logging.LogRecord) -> str:
        out = {"ts": datetime.fromtimestamp(record.created, timezone.utc).isoformat(timespec="milliseconds"),
               "severity": record.levelname, **self.base, "version": _version, "logger": record.name,
               "message": record.getMessage()}
        rid, tid = request_id.get(), trace_id.get()
        if rid:
            out["request_id"] = rid
        if tid:
            out["trace_id"] = tid
        for key in _FIELDS:
            if hasattr(record, key):
                out[key] = getattr(record, key)
        if record.exc_info:
            out["error"] = self.formatException(record.exc_info)
        return json.dumps(out, ensure_ascii=False, default=str)


def set_version(version: str) -> None:
    global _version
    _version = version


def json_logs() -> bool:
    from .config import get_settings
    return os.environ.get("MASSLAK_LOG_FORMAT", "text" if get_settings().sandbox else "json").lower() == "json"


def configure(service: str, level: int = logging.INFO) -> None:
    """JSON lines on standard output for the API, the worker and the tools; the classic text format otherwise."""
    if not json_logs():
        logging.basicConfig(level=level, format="%(asctime)s %(levelname)s %(message)s")
        logging.getLogger("masslak.access").setLevel(logging.WARNING)   # uvicorn prints its own access lines here
        return
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter(service))
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)
    for name in ("uvicorn", "uvicorn.error"):
        lg = logging.getLogger(name)
        lg.handlers, lg.propagate = [handler], False
    # the middleware writes one structured line per API request; uvicorn's own access line would repeat it as text
    logging.getLogger("uvicorn.access").disabled = True
