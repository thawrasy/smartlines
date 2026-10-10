"""Readiness (review of October 2026, stage A6).

GET /api/health is liveness: the process answers, nothing else is checked. The container health check and the proxy
use it, so a database restart never takes the web interface offline with it.

GET /api/ready says whether this instance can serve bookings now: the primary (not a standby) answers through the
application pool, every schema file shipped with this code is applied (the migrate service has finished), the audit
connection answers, and the reports replica answers and is in recovery when one is configured. It answers 200 when every check
passes and 503 otherwise, naming only the checks, never an error text. deploy/update.sh waits for it after a
deployment, and a load balancer with several API instances routes only to instances that are ready.

Each check has a short time limit, and the answer is kept for two seconds so that the endpoint cannot be used to load
the database.
"""
from __future__ import annotations

import asyncio
import json
import time
from pathlib import Path
from typing import Awaitable, Callable

from . import db, security

SCHEMA_DIR = Path(__file__).resolve().parents[2] / "db" / "schema"
CHECK_SECONDS = 2.0
CACHE_SECONDS = 2.0
_cache: tuple[float, dict] | None = None


def shipped_schema_files(directory: Path | None = None) -> set[str]:
    """Numbered schema files that came with this code (empty when the directory is not deployed next to it)."""
    directory = directory or SCHEMA_DIR
    if not directory.is_dir():
        return set()
    return {p.name for p in directory.glob("[0-9]*_*.sql")}


async def _database() -> bool:
    # the primary itself: during a failover the main connection may briefly reach a standby (review stage D6)
    async with db.raw_connection() as conn:
        return await conn.fetchval("SELECT NOT pg_is_in_recovery()") is True


async def _schema() -> bool:
    shipped = shipped_schema_files()
    if not shipped:
        return True                     # a build without db/ (a test runner): nothing to compare
    async with db.raw_connection() as conn:
        applied = {r["file"] for r in await conn.fetch("SELECT file FROM sys.schema_file")}
    return shipped <= applied


async def _audit() -> bool:
    async with db.audit_reader() as conn:
        return await conn.fetchval("SELECT 1") == 1


async def _replica() -> bool:
    if db._reports_pool is None:
        return True
    async with db.acquire(db._reports_pool) as conn:
        return bool(await conn.fetchval("SELECT pg_is_in_recovery()"))


async def _context() -> bool:
    """The database holds the key this API signs request contexts with, and set_config and temporary objects are still
    withdrawn from the application (1080): otherwise every request would fail, or the context could be rewritten."""
    async with db.raw_connection() as conn:
        status = await conn.fetchval("SELECT sys.context_status($1)::text", security.context_key_fingerprint())
    return all(json.loads(status).values())


CHECKS: dict[str, Callable[[], Awaitable[bool]]] = {
    "database": _database, "schema": _schema, "audit_database": _audit, "reports_replica": _replica, "context": _context}


async def _run(check: Callable[[], Awaitable[bool]]) -> bool:
    try:
        return bool(await asyncio.wait_for(check(), CHECK_SECONDS))
    except Exception:  # noqa: BLE001  (any failure, a timeout included, means "not ready")
        return False


async def readiness() -> dict:
    global _cache
    now = time.monotonic()
    if _cache is not None and now - _cache[0] < CACHE_SECONDS:
        return _cache[1]
    names = list(CHECKS)
    results = await asyncio.gather(*(_run(CHECKS[n]) for n in names))
    out = {"ready": all(results), "checks": dict(zip(names, results))}
    _cache = (now, out)
    return out
