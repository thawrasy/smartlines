"""Prometheus metrics (audit T3-16): request counts and latency per route, the database pool, and the operational
metrics the database computes (sys.ops_metrics: outbox, deliveries, partitions, scans, jobs, WAL archiving, locks,
long transactions, deadlocks, vacuum). Alert rules and the dashboard are in deploy/monitoring; the SLOs they serve are
in docs/operations/SLO.md.

GET /api/metrics answers only with the bearer token MASSLAK_METRICS_TOKEN; without the setting the endpoint does not
exist (404). Prometheus scrapes every instance. An instance runs several processes (WEB_CONCURRENCY) and a scrape
reaches one of them, so each process writes its counters to a file every few seconds and the one that answers sums
them: counters of every process that ran in the instance (totals never go back when a worker is replaced), gauges of
the live ones. Before, a scrape got one process's figures at random and the counters jumped between two series
(code review of October 2026).
"""
from __future__ import annotations

import asyncio
import glob
import hmac
import json
import os
import tempfile
import time
import uuid
from collections import defaultdict

from fastapi import APIRouter, Request
from fastapi.responses import PlainTextResponse, Response

from . import db

BUCKETS = (0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0)
_count: dict[tuple, int] = defaultdict(int)
_hist: dict[tuple, list] = {}
_events: dict[tuple, int] = defaultdict(int)     # (metric, sorted label items) -> count, e.g. provider calls
_gauges: dict[tuple, float] = {}                 # (metric, sorted label items) -> value of this process
_started = time.time()
PUBLISH_SECONDS = 5.0


def event(metric: str, **labels) -> None:
    """Counts one occurrence of a labelled event (a counter named *_total)."""
    _events[(metric, tuple(sorted((k, str(v)) for k, v in labels.items())))] += 1


def gauge(metric: str, value: float, **labels) -> None:
    """Sets a labelled gauge of this process; the instance reports the highest value among its live processes."""
    _gauges[(metric, tuple(sorted((k, str(v)) for k, v in labels.items())))] = value


def _processes() -> int:
    from .ratelimit import processes
    return processes()


def _instance_dir() -> str:
    """Where the processes of this instance leave their figures: one directory per uvicorn supervisor, so two API
    instances on one machine (as in CI) never add up each other's counters."""
    base = os.environ.get("MASSLAK_METRICS_DIR") or os.path.join(tempfile.gettempdir(), "masslak-metrics")
    return os.path.join(base, str(os.getppid()))


def snapshot() -> dict:
    """This process's own figures."""
    return {"pid": os.getpid(), "started": _started, "written": time.time(),
            "count": [list(k) + [n] for k, n in _count.items()],
            "hist": [list(k) + [h] for k, h in _hist.items()],
            "scope": dict(db.SCOPE_USES), "acquire": list(db.ACQUIRE_WAITS),
            "pool_timeouts": db.POOL_TIMEOUTS[0], "audit_write_failures": db.AUDIT_WRITE_FAILURES[0],
            "events": [[m, [list(x) for x in lb], n] for (m, lb), n in _events.items()],
            "gauges": [[m, [list(x) for x in lb], v] for (m, lb), v in _gauges.items()],
            "pool": db.pool_stats()}


def publish() -> None:
    """Writes this process's figures for the others to sum (atomically: a reader never sees half a file)."""
    if _processes() < 2:
        return
    try:
        d = _instance_dir()
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, f"{os.getpid()}-{int(_started * 1000)}.json")
        with open(path + ".tmp", "w") as f:
            json.dump(snapshot(), f)
        os.replace(path + ".tmp", path)
    except OSError:
        pass


async def publisher() -> None:
    """Background task of each process (started in the application's lifespan when there are several processes)."""
    while True:
        publish()
        await asyncio.sleep(PUBLISH_SECONDS)


def _alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def gathered() -> dict:
    """The instance's process figures: summed counters of every process, gauges of the live ones."""
    snaps = [snapshot()]
    if _processes() > 1:
        publish()
        snaps = []
        for path in glob.glob(os.path.join(_instance_dir(), "*.json")):
            try:
                with open(path) as f:
                    snaps.append(json.load(f))
            except (OSError, ValueError):
                continue
        if not any(x.get("pid") == os.getpid() and x.get("started") == _started for x in snaps):
            snaps.append(snapshot())                    # the directory could not be written: this process alone
    out = {"count": defaultdict(int), "hist": {}, "scope": defaultdict(int), "acquire": [0] * len(db.ACQUIRE_WAITS),
           "pool_timeouts": 0, "audit_write_failures": 0, "pool": None, "processes": 0, "uptime": None,
           "events": defaultdict(int), "gauges": {}}
    now = time.time()
    for x in snaps:
        for *k, n in x["count"]:
            out["count"][tuple(k)] += n
        for *k, h in x["hist"]:
            acc = out["hist"].setdefault(tuple(k), [0] * len(h))
            for i, value in enumerate(h):
                acc[i] += value
        for site, n in x["scope"].items():
            out["scope"][site] += n
        for i, value in enumerate(x["acquire"][:len(out["acquire"])]):
            out["acquire"][i] += value
        out["pool_timeouts"] += x["pool_timeouts"]
        out["audit_write_failures"] += x.get("audit_write_failures", 0)
        for m, lb, n in x.get("events", []):
            out["events"][(m, tuple(tuple(i) for i in lb))] += n
        live = x["pid"] == os.getpid() or (_alive(x["pid"]) and now - x["written"] < 60)
        for m, lb, v in x.get("gauges", []) if live else []:
            key = (m, tuple(tuple(i) for i in lb))
            out["gauges"][key] = max(out["gauges"].get(key, v), v)
        if live:
            out["processes"] += 1
            age = now - x["started"]
            out["uptime"] = age if out["uptime"] is None else min(out["uptime"], age)
            if x["pool"]:
                pool = out["pool"] or {"size": 0, "idle": 0}
                out["pool"] = {"size": pool["size"] + x["pool"]["size"], "idle": pool["idle"] + x["pool"]["idle"]}
    return out

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


def render_requests(g: dict | None = None) -> list[str]:
    g = g or gathered()
    out = ["# HELP masslak_http_requests_total API requests by route and status class",
           "# TYPE masslak_http_requests_total counter"]
    for (method, path, grp, cls), n in sorted(g["count"].items()):
        out.append(f"masslak_http_requests_total{_labels({'method': method, 'route': path, 'group': grp, 'status': cls})} {n}")
    out += ["# HELP masslak_http_request_duration_seconds API latency by route",
            "# TYPE masslak_http_request_duration_seconds histogram"]
    for (method, path, grp), h in sorted(g["hist"].items()):
        base = {"method": method, "route": path, "group": grp}
        for i, b in enumerate(BUCKETS):
            out.append(f"masslak_http_request_duration_seconds_bucket{_labels({**base, 'le': b})} {h[i]}")
        out.append(f"masslak_http_request_duration_seconds_bucket{_labels({**base, 'le': '+Inf'})} {h[len(BUCKETS)]}")
        out.append(f"masslak_http_request_duration_seconds_count{_labels(base)} {h[len(BUCKETS)]}")
        out.append(f"masslak_http_request_duration_seconds_sum{_labels(base)} {h[-1]:.6f}")
    out += ["# HELP masslak_process_uptime_seconds Uptime of the youngest live process of the instance",
            "# TYPE masslak_process_uptime_seconds gauge", f"masslak_process_uptime_seconds {g['uptime'] or 0:.0f}",
            "# HELP masslak_api_processes Live API processes of the instance", "# TYPE masslak_api_processes gauge",
            f"masslak_api_processes {g['processes']}"]
    out += ["# HELP masslak_system_scope_total Uses of the system scope by calling function (reviewed in governance_registry.py)",
            "# TYPE masslak_system_scope_total counter"]
    out += [f"masslak_system_scope_total{_labels({'site': site})} {n}" for site, n in sorted(g["scope"].items())]
    out += ["# HELP masslak_db_pool_timeouts_total Requests answered busy because no database connection became free in time",
            "# TYPE masslak_db_pool_timeouts_total counter", f"masslak_db_pool_timeouts_total {g['pool_timeouts']}"]
    out += ["# HELP masslak_audit_write_failures_total Requests whose activity log record could not be written",
            "# TYPE masslak_audit_write_failures_total counter", f"masslak_audit_write_failures_total {g['audit_write_failures']}"]
    seen: set[str] = set()
    for kind, table in (("counter", g["events"]), ("gauge", g["gauges"])):
        for (m, lb), v in sorted(table.items()):
            if m not in seen:
                out.append(f"# TYPE {m} {kind}")
                seen.add(m)
            out.append(f"{m}{_labels(dict(lb))} {v}")
    return out


async def render_database(g: dict | None = None) -> list[str]:
    g = g or gathered()
    out, seen = [], set()
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        rows = await conn.fetch("SELECT metric, labels, value FROM sys.ops_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.capacity_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.scale_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.finance_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.lock_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.partition_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.replication_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM sys.ha_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM audit.archive_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM fin.payment_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM fin.money_boundary_metrics() "
                                "UNION ALL SELECT metric, labels, value FROM ops.position_backlog_metrics()")
    pool = g["pool"]
    for r in rows:
        name = r["metric"]
        if name not in seen:
            kind = "counter" if name.endswith("_total") else "gauge"
            out.append(f"# TYPE {name} {kind}")
            seen.add(name)
        labels = r["labels"] if isinstance(r["labels"], dict) else __import__("json").loads(r["labels"] or "{}")
        out.append(f"{name}{_labels(labels)} {r['value']}")
    from . import release
    rel = await release.current()
    if rel:
        out += ["# HELP masslak_release_info The release the database is at (release manifest, 1058)",
                "# TYPE masslak_release_info gauge",
                f"masslak_release_info{_labels({'version': rel['version'], 'commit': rel['commit_sha'][:12], 'schema_hash': rel['schema_hash'][:12]})} 1",
                "# TYPE masslak_release_hash_matches gauge", f"masslak_release_hash_matches {int(bool(rel['hash_matches']))}"]
    if pool:
        out += ["# TYPE masslak_db_pool_size gauge", f"masslak_db_pool_size {pool['size']}",
                "# TYPE masslak_db_pool_idle gauge", f"masslak_db_pool_idle {pool['idle']}"]
        waits = g["acquire"]
        out += ["# HELP masslak_db_pool_acquire_seconds Time a request waited for a database connection (all processes of the instance)",
                "# TYPE masslak_db_pool_acquire_seconds histogram"]
        out += [f'masslak_db_pool_acquire_seconds_bucket{{le="{b}"}} {waits[i]}' for i, b in enumerate(db.ACQUIRE_BUCKETS)]
        out += [f'masslak_db_pool_acquire_seconds_bucket{{le="+Inf"}} {waits[-2]}',
                f"masslak_db_pool_acquire_seconds_count {waits[-2]}", f"masslak_db_pool_acquire_seconds_sum {waits[-1]:.6f}"]
    # the telemetry database, when positions are kept there (review stage D2)
    from . import telemetry
    for name, labels, value in await telemetry.metrics():
        if name not in seen:
            out.append(f"# TYPE {name} gauge")
            seen.add(name)
        out.append(f"{name}{_labels(labels)} {value}")
    return out


@router.get("/api/metrics", include_in_schema=False)
async def metrics(request: Request):
    token = os.environ.get("MASSLAK_METRICS_TOKEN", "")
    if not token:
        return Response(status_code=404)
    given = request.headers.get("authorization", "").removeprefix("Bearer ").strip()
    if not hmac.compare_digest(given.encode(), token.encode()):
        return Response(status_code=401, headers={"WWW-Authenticate": "Bearer"})
    g = gathered()
    lines = render_requests(g)
    try:
        lines += await render_database(g)
        lines += ["# TYPE masslak_db_up gauge", "masslak_db_up 1"]
    except Exception:                    # the scrape itself reports the database as down instead of failing
        lines += ["# TYPE masslak_db_up gauge", "masslak_db_up 0"]
    return PlainTextResponse("\n".join(lines) + "\n", media_type="text/plain; version=0.0.4")
