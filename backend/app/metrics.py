"""Prometheus metrics (audit T3-16): request counts and latency per route, the database pool, and the operational
metrics the database computes (sys.ops_metrics: outbox, deliveries, partitions, scans, jobs, WAL archiving, locks,
long transactions, deadlocks, vacuum). Alert rules and the dashboard are in deploy/monitoring; the SLOs they serve are
in docs/operations/SLO.md.

GET /api/metrics answers only with the bearer token MASSLAK_METRICS_TOKEN; without the setting the endpoint does not
exist (404). Each API process keeps its own request counters; Prometheus scrapes every instance.
"""
from __future__ import annotations

import hmac
import os
import time
import uuid
from collections import defaultdict

from fastapi import APIRouter, Request
from fastapi.responses import PlainTextResponse, Response

from . import db

BUCKETS = (0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
_count: dict[tuple, int] = defaultdict(int)
_hist: dict[tuple, list] = {}
_started = time.time()

router = APIRouter()


def group(path: str) -> str:
    """The SLO group of a route: the path patterns the SLOs name (docs/operations/SLO.md)."""
    if path.startswith("/api/trips/search"):
        return "search"
    if path.startswith("/api/holds") or path == "/api/bookings" or path.startswith("/api/bookings/{"):
        return "booking"
    if path.startswith("/api/wallet") or path.startswith("/api/payments"):
        return "payment"
    if path.startswith("/api/driver/location") or path.startswith("/api/tracking"):
        return "tracking"
    if path.startswith("/api/reports"):
        return "reports"
    if path.startswith("/api/auth"):
        return "auth"
    return "other"


class MetricsMiddleware:
    """Pure ASGI middleware: times every API request and counts it by route template and status class."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not scope.get("path", "").startswith("/api/") or scope["path"] == "/api/metrics":
            return await self.app(scope, receive, send)
        t0 = time.perf_counter()
        status = {"code": 500}

        async def wrapped(message):
            if message["type"] == "http.response.start":
                status["code"] = message["status"]
            await send(message)
        try:
            await self.app(scope, receive, wrapped)
        finally:
            route = scope.get("route")
            path = getattr(route, "path", None) or "unmatched"
            key = (scope["method"], path, group(path))
            _count[key + (f"{status['code'] // 100}xx",)] += 1
            h = _hist.setdefault(key, [0] * (len(BUCKETS) + 1) + [0.0])
            took = time.perf_counter() - t0
            for i, b in enumerate(BUCKETS):
                if took <= b:
                    h[i] += 1
            h[len(BUCKETS)] += 1          # +Inf, also the count
            h[-1] += took                 # sum


def _labels(d: dict) -> str:
    return "{" + ",".join(f'{k}="{str(v).replace(chr(92), "").replace(chr(34), "")}"' for k, v in d.items()) + "}" if d else ""


def render_requests() -> list[str]:
    out = ["# HELP masslak_http_requests_total API requests by route and status class",
           "# TYPE masslak_http_requests_total counter"]
    for (method, path, grp, cls), n in sorted(_count.items()):
        out.append(f"masslak_http_requests_total{_labels({'method': method, 'route': path, 'group': grp, 'status': cls})} {n}")
    out += ["# HELP masslak_http_request_duration_seconds API latency by route",
            "# TYPE masslak_http_request_duration_seconds histogram"]
    for (method, path, grp), h in sorted(_hist.items()):
        base = {"method": method, "route": path, "group": grp}
        for i, b in enumerate(BUCKETS):
            out.append(f"masslak_http_request_duration_seconds_bucket{_labels({**base, 'le': b})} {h[i]}")
        out.append(f"masslak_http_request_duration_seconds_bucket{_labels({**base, 'le': '+Inf'})} {h[len(BUCKETS)]}")
        out.append(f"masslak_http_request_duration_seconds_count{_labels(base)} {h[len(BUCKETS)]}")
        out.append(f"masslak_http_request_duration_seconds_sum{_labels(base)} {h[-1]:.6f}")
    out += ["# TYPE masslak_process_uptime_seconds gauge", f"masslak_process_uptime_seconds {time.time() - _started:.0f}"]
    return out


async def render_database() -> list[str]:
    out, seen = [], set()
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        rows = await conn.fetch("SELECT metric, labels, value FROM sys.ops_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.capacity_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.scale_metrics()")
        pool = db.pool_stats()
    for r in rows:
        name = r["metric"]
        if name not in seen:
            kind = "counter" if name.endswith("_total") else "gauge"
            out.append(f"# TYPE {name} {kind}")
            seen.add(name)
        labels = r["labels"] if isinstance(r["labels"], dict) else __import__("json").loads(r["labels"] or "{}")
        out.append(f"{name}{_labels(labels)} {r['value']}")
    if pool:
        out += ["# TYPE masslak_db_pool_size gauge", f"masslak_db_pool_size {pool['size']}",
                "# TYPE masslak_db_pool_idle gauge", f"masslak_db_pool_idle {pool['idle']}"]
    return out


@router.get("/api/metrics", include_in_schema=False)
async def metrics(request: Request):
    token = os.environ.get("MASSLAK_METRICS_TOKEN", "")
    if not token:
        return Response(status_code=404)
    given = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
    if not hmac.compare_digest(given.encode(), token.encode()):
        return Response(status_code=401, headers={"WWW-Authenticate": "Bearer"})
    lines = render_requests()
    try:
        lines += await render_database()
        lines += ["# TYPE masslak_db_up gauge", "masslak_db_up 1"]
    except Exception:                    # the scrape itself reports the database as down instead of failing
        lines += ["# TYPE masslak_db_up gauge", "masslak_db_up 0"]
    return PlainTextResponse("\n".join(lines) + "\n", media_type="text/plain; version=0.0.4")
