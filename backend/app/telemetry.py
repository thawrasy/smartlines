"""Vehicle positions in a telemetry database (expert review of October 2026, stage D2; db/telemetry/schema.sql).

With MASSLAK_TELEMETRY_DATABASE_URL set, a driver's positions are graded on the primary (ops.accept_positions, which
also keeps the vehicle's latest position and closes the trip's signal alerts) and their history is appended here.
Without it, positions go to ops.geo_event on the primary as before. The primary is written first: it checks that the
trip is the driver's, so nothing reaches the telemetry database for someone else's trip. If the append fails, the
request fails with 503 and the app sends the positions again; the latest position is not moved back, and the copies
already stored are skipped as duplicates (same event id and time).
"""
import json
import logging
from typing import Optional

from . import db
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


async def store(trip_id: int, graded: list[dict], points: list[dict]) -> list[str]:
    """Appends graded positions; returns the trust grade of each one stored (duplicates are skipped)."""
    pool = db.telemetry_pool()
    assert pool is not None
    full = [{**p, **g, "trip_id": trip_id} for g, p in zip(graded, points)]
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


async def upkeep(keep_days: int, held: bool) -> Optional[dict]:
    """Daily: partitions ahead, and positions older than the retention dropped unless a legal hold stands."""
    pool = db.telemetry_pool()
    if pool is None:
        return None
    async with pool.acquire() as conn:
        return json.loads(await conn.fetchval("SELECT tel.upkeep($1, $2)::text", keep_days, held))


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
