"""Database access.

Every request runs in one transaction on the masslak_app role. The transaction starts with
sys.set_context() so that row-level security and the audit triggers know who is acting.
"""
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import AsyncIterator, Optional
import uuid

import asyncpg

from .config import get_settings

_pool: Optional[asyncpg.Pool] = None
_audit_pool: Optional[asyncpg.Pool] = None
_reports_pool: Optional[asyncpg.Pool] = None


async def open_pools() -> None:
    global _pool, _audit_pool, _reports_pool
    s = get_settings()
    _pool = await asyncpg.create_pool(s.database_url, min_size=1, max_size=20, command_timeout=30)
    _audit_pool = await asyncpg.create_pool(s.audit_database_url, min_size=1, max_size=4, command_timeout=30)
    if s.reports_database_url:
        _reports_pool = await asyncpg.create_pool(s.reports_database_url, min_size=1, max_size=4, command_timeout=120)


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
    async with _pool.acquire() as conn:
        async with conn.transaction():
            await apply_context(conn, ctx)
            yield conn


@asynccontextmanager
async def system_scope(conn: asyncpg.Connection, ctx: Context) -> AsyncIterator[asyncpg.Connection]:
    """Temporarily act as the platform inside the current transaction.

    Used for platform-side bookkeeping that the caller may not see directly (escrow and platform
    wallets, inventory rows). The acting user stays recorded in the context and the audit logs.
    """
    await apply_context(conn, ctx, scope="SYSTEM")
    try:
        yield conn
    except BaseException:
        # the transaction is failing: restoring the context would only hide the real error behind "transaction aborted"
        raise
    await apply_context(conn, ctx)


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
async def raw_connection() -> AsyncIterator[asyncpg.Connection]:
    assert _pool is not None
    async with _pool.acquire() as conn:
        yield conn
