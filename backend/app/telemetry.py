"""Vehicle positions in a telemetry database (expert review of October 2026, stage D2; db/telemetry/schema.sql).

With MASSLAK_TELEMETRY_DATABASE_URL set, a driver's positions are graded on the primary (ops.accept_positions, which
also keeps the vehicle's latest position and closes the trip's signal alerts) and their history is appended here.
Without it, positions go to ops.geo_event on the primary as before. The primary is written first: it checks that the
trip is the driver's, so nothing reaches the telemetry database for someone else's trip.

If the append fails, the graded positions are kept on the primary (ops.position_backlog) and the request succeeds:
the driver's history no longer depends on the app sending them again (review of release 1.47.0, R-03). The worker
delivers the backlog in order once the telemetry database answers; copies already stored are skipped as duplicates
(same event id and time). Only when the primary cannot keep them either does the request fail with 503.
"""
import json
import logging
import time
import uuid
from datetime import datetime
from typing import Optional

import asyncpg

from . import db
from .config import get_settings
from .errors import ApiError

log = logging.getLogger("masslak.telemetry")

_COLUMNS = ("ts", "received_at", "company_id", "trip_id", "vehicle_id", "driver_user_id", "device_id", "lat", "lng",
            "accuracy_m", "speed_kmh", "event_id", "seq", "device_ts", "provider", "is_mock", "trust", "trust_flags")
_TYPES = ("timestamptz", "timestamptz", "bigint", "bigint", "bigint", "bigint", "bigint", "numeric", "numeric", "real",
          "real", "uuid", "bigint", "timestamptz", "text", "boolean", "text", "text")
# the trust flags travel as array literals (unnest would flatten an array of arrays) and are cast back here
_INSERT = f"""
INSERT INTO tel.position ({", ".join(_COLUMNS)})
SELECT {", ".join(f"u.{c}::text[]" if c == "trust_flags" else f"u.{c}" for c in _COLUMNS)}
  FROM unnest({", ".join(f"${i}::{t}[]" for i, t in enumerate(_TYPES, 1))}) AS u({", ".join(_COLUMNS)})
ON CONFLICT (event_id, ts) DO NOTHING
RETURNING trust"""


def enabled() -> bool:
    return db.telemetry_pool() is not None


async def accept(conn, trip_id: int, points: list[dict]) -> list[dict]:
    """Grades the positions on the primary, within the request's transaction, for the signed-in driver's trip."""
    rows = await conn.fetch("SELECT * FROM ops.accept_positions($1, $2::jsonb) ORDER BY idx",
                            trip_id, json.dumps(points, default=str))
    return [dict(r) for r in rows]


def rows_of(trip_id: int, graded: list[dict], points: list[dict]) -> list[dict]:
    """The rows the telemetry database stores: each position as sent, with its grade from the primary."""
    return [{**p, **g, "trip_id": trip_id} for g, p in zip(graded, points)]


async def store(trip_id: int, graded: list[dict], points: list[dict]) -> list[str]:
    """Appends graded positions; returns the trust grade of each one stored (duplicates are skipped)."""
    return await store_rows(rows_of(trip_id, graded, points))


async def store_rows(full: list[dict]) -> list[str]:
    pool = db.telemetry_pool()
    assert pool is not None
    cols = {c: [r.get(c) for r in full] for c in _COLUMNS}
    cols["trust_flags"] = ["{" + ",".join(r["trust_flags"]) + "}" for r in full]
    try:
        async with pool.acquire() as conn:
            rows = await conn.fetch(_INSERT, *[cols[c] for c in _COLUMNS])
    except (OSError, TimeoutError) as exc:
        log.error("telemetry database unreachable: %s", exc)
        raise ApiError(503, "TELEMETRY_UNAVAILABLE", "positions were not stored; send them again") from exc
    except Exception as exc:                                          # noqa: BLE001 - any database failure: retry later
        if exc.__class__.__module__.startswith("asyncpg"):
            log.error("telemetry insert failed: %s", exc)
            raise ApiError(503, "TELEMETRY_UNAVAILABLE", "positions were not stored; send them again") from exc
        raise
    return [r["trust"] for r in rows]


_TIMES = ("ts", "received_at", "device_ts")


async def queue(conn, trip_id: int, company_id: int, graded: list[dict], points: list[dict]) -> None:
    """Keeps positions the telemetry database could not take, on the primary, for the worker to deliver (R-03)."""
    await conn.execute("INSERT INTO ops.position_backlog (trip_id, company_id, positions) VALUES ($1, $2, $3::jsonb)",
                       trip_id, company_id, json.dumps(rows_of(trip_id, graded, points), default=str))


def _revive(row: dict) -> dict:
    out = dict(row)
    for k in _TIMES:
        if out.get(k):
            out[k] = datetime.fromisoformat(out[k])
    if out.get("event_id"):
        out["event_id"] = uuid.UUID(out["event_id"])
    return out


async def drain_backlog(batch: int = 100, budget_seconds: float = 20.0) -> int:
    """Worker: delivers waiting positions in the order they arrived, many batches per insert, for up to budget_seconds
    a pass; stops at the first failure and tries again on its next pass. Returns the batches delivered."""
    if db.telemetry_pool() is None:
        return 0
    from .errors import ApiError
    done, started = 0, time.monotonic()
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    while time.monotonic() - started < budget_seconds:
        async with db.transaction(ctx) as conn:
            waiting = await conn.fetch("""SELECT id, positions::text AS positions FROM ops.position_backlog
                                           WHERE delivered_at IS NULL ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED""", batch)
            if not waiting:
                break
            ids = [w["id"] for w in waiting]
            try:
                await store_rows([_revive(r) for w in waiting for r in json.loads(w["positions"])])
            except ApiError as exc:
                await conn.execute("UPDATE ops.position_backlog SET attempts = attempts + 1, last_error = $2 WHERE id = ANY($1)",
                                   ids, exc.message[:300])
                break
            await conn.execute("UPDATE ops.position_backlog SET delivered_at = now(), attempts = attempts + 1 WHERE id = ANY($1)",
                               ids)
            done += len(ids)
        if len(waiting) < batch:
            break
    if done:
        log.info("telemetry backlog: %s batch(es) delivered", done)
    return done


async def upkeep(keep_days: int, held: bool) -> Optional[dict]:
    """Daily: partitions ahead, and positions older than the retention dropped unless a legal hold stands. The drop runs
    through the worker's own login (MASSLAK_TELEMETRY_UPKEEP_URL); the API's login only creates the days ahead (C-02)."""
    pool = db.telemetry_pool()
    if pool is None:
        return None
    url = get_settings().telemetry_upkeep_url
    if not url:
        async with pool.acquire() as conn:
            created = await conn.fetchval("SELECT tel.ensure_ahead()")
        log.error("telemetry retention not applied: MASSLAK_TELEMETRY_UPKEEP_URL is not set (RUNBOOKS.md, section 22)")
        return {"partitions_created": created, "partitions_dropped": 0, "retention": "not applied"}
    conn = await asyncpg.connect(url, timeout=10)
    try:
        return json.loads(await conn.fetchval("SELECT tel.upkeep($1, $2)::text", keep_days, held))
    finally:
        await conn.close()


async def metrics() -> list[tuple[str, dict, float]]:
    pool = db.telemetry_pool()
    if pool is None:
        return []
    try:
        async with pool.acquire() as conn:
            rows = await conn.fetch("SELECT metric, labels::text AS labels, value FROM tel.metrics()")
    except Exception as exc:                                          # noqa: BLE001 - reported as down, not raised
        log.warning("telemetry metrics unavailable: %s", exc)
        return [("masslak_telemetry_up", {}, 0.0)]
    return [("masslak_telemetry_up", {}, 1.0)] + [(r["metric"], json.loads(r["labels"]), r["value"]) for r in rows]
