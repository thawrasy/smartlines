"""How stale a report may be when it reads the replica (review stage B).

Reports read a streaming replica so that heavy queries never slow bookings (architecture review, 1051). A replica can
fall behind: under a burst of writes, during maintenance, or when replay stops. Each report has a freshness class,
with a limit set in sys.setting 'reports.replica_lag':

* financial  (datasets of the finance category: wallets, payments, settlements, withdrawals, invoices, counter cash)
             60 s by default. Past it the report is refused with REPORT_DATA_STALE: a balance or a settlement must not
             be read from data that misses recent postings. A scheduled one is retried five minutes later.
* analytical (grouped reports of other areas: totals by day, route, carrier) 1 hour; served with a warning past it.
* operational (lists of other areas: bookings, trips, incidents) 5 minutes; served with a warning past it.

Reports read through the audit connection read the primary and are never stale. Every answer carries the lag it was
read with, next to data_as_of.
"""
from __future__ import annotations

import json
import time
from typing import Optional

from ... import db
from ...errors import ApiError
from .datasets import DATASETS

DEFAULTS = {"financial_max_seconds": 60, "operational_max_seconds": 300, "analytical_max_seconds": 3600}
_limits: Optional[tuple[float, dict]] = None


def freshness_class(dataset: str, spec: dict) -> str:
    ds = DATASETS.get(dataset)
    if ds is not None and ds.category == "finance":
        return "financial"
    return "analytical" if (spec or {}).get("group_by") else "operational"


async def limits() -> dict:
    """The limits from sys.setting, read at most once a minute."""
    global _limits
    now = time.monotonic()
    if _limits is not None and now - _limits[0] < 60:
        return _limits[1]
    out = dict(DEFAULTS)
    try:
        async with db.raw_connection() as conn:
            raw = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'reports.replica_lag'")
        if raw is not None:
            out.update({k: float(v) for k, v in (json.loads(raw) if isinstance(raw, str) else raw).items() if k in DEFAULTS})
    except Exception:  # noqa: BLE001  (the defaults hold when the setting cannot be read)
        pass
    _limits = (now, out)
    return out


async def check(dataset: str, spec: dict, conn) -> dict:
    """Measures the lag for a report read on `conn`; refuses a financial report past its limit, marks the others stale."""
    ds = DATASETS.get(dataset)
    cls = freshness_class(dataset, spec)
    lag = None if ds is not None and ds.reader == "audit" else await db.replica_lag_seconds(conn)
    limit = (await limits())[f"{cls}_max_seconds"]
    out = {"class": cls, "lag_seconds": None if lag is None else round(lag, 1), "limit_seconds": limit,
           "stale": lag is not None and lag > limit}
    if out["stale"] and cls == "financial":
        raise ApiError(503, "REPORT_DATA_STALE", "the reports replica is behind; financial reports wait until it catches up",
                       lag_seconds=out["lag_seconds"], limit_seconds=limit)
    return out
