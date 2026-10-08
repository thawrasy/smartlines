"""Database access.

Every request runs in one transaction on the masslak_app role. The transaction starts with
sys.set_context() so that row-level security and the audit triggers know who is acting.
"""
import os
import sys
import time
from collections import Counter
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import AsyncIterator, Optional
import uuid

import asyncpg

from .config import get_settings

_pool: Optional[asyncpg.Pool] = None
_audit_pool: Optional[asyncpg.Pool] = None
_reports_pool: Optional[asyncpg.Pool] = None


# How long requests wait for a connection of the main pool (review stage C7): upper bounds in seconds, then the count
# per bound, the total count and the sum. A pool that is too small shows here before requests time out.
ACQUIRE_BUCKETS = (0.001, 0.01, 0.05, 0.25, 1.0, 5.0)
ACQUIRE_WAITS = [0] * len(ACQUIRE_BUCKETS) + [0, 0.0]


def _acquired(seconds: float) -> None:
    for i, bound in enumerate(ACQUIRE_BUCKETS):
        if seconds <= bound:
            ACQUIRE_WAITS[i] += 1
    ACQUIRE_WAITS[-2] += 1
    ACQUIRE_WAITS[-1] += seconds


def pool_stats() -> Optional[dict]:
    """Size and idle connections of the main pool, for the metrics endpoint."""
    if _pool is None:
        return None
    return {"size": _pool.get_size(), "idle": _pool.get_idle_size()}


async def open_pools() -> None:
    global _pool, _audit_pool, _reports_pool
    s = get_settings()
    _pool = await asyncpg.create_pool(s.database_url, min_size=1, max_size=20, command_timeout=30)
    _audit_pool = await asyncpg.create_pool(s.audit_database_url, min_size=1, max_size=4, command_timeout=30)
    if s.reports_database_url:
        # the role's own limit is 30 s (db/create_login_roles.sql); reports on the replica may run for two minutes
        _reports_pool = await asyncpg.create_pool(s.reports_database_url, min_size=1, max_size=4, command_timeout=120,
                                                  server_settings={"statement_timeout": "120s"})


async def close_pools() -> None:
    for p in (_pool, _audit_pool, _reports_pool):
        if p is not None:
            await p.close()


@dataclass
class Context:
    """Who is acting, passed to sys.set_context()."""
    request_id: uuid.UUID
    ip: str
    user_id: Optional[int] = None
    company_id: Optional[int] = None
    party_id: Optional[int] = None
    scope: str = "PASSENGER"          # PLATFORM | COMPANY | AGENCY | PASSENGER | API | SYSTEM | AUTH (sign-in only)
    session_id: Optional[int] = None
    api_client_id: Optional[int] = None   # set for calls made with an integration API key


async def apply_context(conn: asyncpg.Connection, ctx: Context, scope: Optional[str] = None) -> None:
    await conn.execute(
        "SELECT sys.set_context($1, $2, $3, $8, $4, $5::inet, $6, $7)",
        ctx.user_id, ctx.company_id, scope or ctx.scope, ctx.request_id, ctx.ip, ctx.session_id, ctx.party_id, ctx.api_client_id,
    )


@asynccontextmanager
async def transaction(ctx: Context) -> AsyncIterator[asyncpg.Connection]:
    assert _pool is not None, "database pool not initialised"
    asked = time.monotonic()
    async with _pool.acquire() as conn:
        _acquired(time.monotonic() - asked)
        async with conn.transaction():
            await apply_context(conn, ctx)
            yield conn


# Uses of the system scope per calling function, scraped as masslak_system_scope_total (review stage C): every site is
# listed with its reason in backend/tests/governance_registry.py, and this counter shows how often each one runs.
SCOPE_USES: Counter = Counter()
_APP_DIR = os.path.dirname(os.path.abspath(__file__))


def _scope_site() -> str:
    """'modules/sales/service.py:create_booking' for the function that entered the system scope."""
    frame = sys._getframe(1)
    while frame is not None and (frame.f_code.co_filename == __file__ or "contextlib" in frame.f_code.co_filename):
        frame = frame.f_back
    if frame is None:
        return "unknown"
    path = os.path.relpath(frame.f_code.co_filename, _APP_DIR)
    return f"{path}:{getattr(frame.f_code, 'co_qualname', frame.f_code.co_name)}"


@asynccontextmanager
async def system_scope(conn: asyncpg.Connection, ctx: Context) -> AsyncIterator[asyncpg.Connection]:
    """Temporarily act as the platform inside the current transaction.

    Used for platform-side bookkeeping that the caller may not see directly (escrow and platform
    wallets, inventory rows). The acting user stays recorded in the context and the audit logs. Every calling function
    is reviewed with its reason (backend/tests/governance_registry.py) and counted (SCOPE_USES).
    """
    SCOPE_USES[_scope_site()] += 1
    await apply_context(conn, ctx, scope="SYSTEM")
    try:
        yield conn
    except BaseException:
        # the transaction is failing: restoring the context would only hide the real error behind "transaction aborted"
        raise
    await apply_context(conn, ctx)


async def require_reports_replica() -> None:
    """Production reads reports from a streaming replica only (architecture review of design 3.9): heavy queries must
    never slow bookings and payments. The sandbox may use the main pool."""
    if get_settings().sandbox:
        return
    if _reports_pool is None:
        raise RuntimeError("MASSLAK_REPORTS_DATABASE_URL is required outside the sandbox: reports read the replica, "
                           "never the primary (docker-compose.yml, service db-replica)")
    async with _reports_pool.acquire() as conn:
        if not await conn.fetchval("SELECT pg_is_in_recovery()"):
            raise RuntimeError("MASSLAK_REPORTS_DATABASE_URL points at a primary: it must be a read replica (hot standby)")


@asynccontextmanager
async def reports_transaction(ctx: Context) -> AsyncIterator[asyncpg.Connection]:
    """Reports run on the read replica when one is configured (same roles, same row-level security), otherwise on the
    main pool. On a replica the transaction is read-only."""
    pool = _reports_pool or _pool
    assert pool is not None, "database pool not initialised"
    async with pool.acquire() as conn:
        async with conn.transaction(readonly=_reports_pool is not None):
            await apply_context(conn, ctx)
            yield conn


_lag: Optional[tuple[float, Optional[float]]] = None


async def replica_lag_seconds(replica: asyncpg.Connection) -> Optional[float]:
    """How far the reports replica is behind the primary, in seconds; None without a replica (reports then read the
    primary). Zero when the replica has replayed everything the primary had written when asked; otherwise the age of
    the last transaction it replayed, an upper bound. Measured at most every 2 seconds (review stage B).

    `replica` is the report's own connection: taking a second one from the small reports pool while holding the first
    could leave concurrent reports waiting on each other."""
    global _lag
    import time
    if _reports_pool is None or _pool is None:
        return None
    now = time.monotonic()
    if _lag is not None and now - _lag[0] < 2:
        return _lag[1]
    async with _pool.acquire() as p:
        written = await p.fetchval("SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')::numeric")
    row = await replica.fetchrow("""SELECT pg_is_in_recovery() AS standby,
                                           pg_wal_lsn_diff(pg_last_wal_replay_lsn(), '0/0')::numeric AS replayed,
                                           extract(epoch FROM now() - pg_last_xact_replay_timestamp())::float8 AS age""")
    if not row["standby"] or row["replayed"] is None:
        lag = None                                     # not a standby: require_reports_replica refuses this at start
    elif row["replayed"] >= written:
        lag = 0.0
    else:
        lag = max(0.0, float(row["age"] or 0.0))
    _lag = (now, lag)
    return lag


async def data_as_of(conn: asyncpg.Connection):
    """The moment the data reflects: the last replayed transaction on a replica, now on the primary."""
    return await conn.fetchval("SELECT coalesce(pg_last_xact_replay_timestamp(), now())")


@asynccontextmanager
async def audit_reader() -> AsyncIterator[asyncpg.Connection]:
    assert _audit_pool is not None, "audit pool not initialised"
    async with _audit_pool.acquire() as conn:
        async with conn.transaction(readonly=True):
            yield conn


@asynccontextmanager
async def audit_writer() -> AsyncIterator[asyncpg.Connection]:
    """The audit role in a writable transaction: only for audit.record_archive, which the role may execute."""
    assert _audit_pool is not None, "audit pool not initialised"
    async with _audit_pool.acquire() as conn:
        async with conn.transaction():
            yield conn


@asynccontextmanager
async def raw_connection() -> AsyncIterator[asyncpg.Connection]:
    assert _pool is not None
    async with _pool.acquire() as conn:
        yield conn
