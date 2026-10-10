"""A request context the API's database login cannot forge (1080; reviews of October 2026, finding C-01).

The reviewers showed that one set_config call slipped into a statement raised the scope to the platform and showed
every company's rows. These tests act as the API's own login (masslak_api, not a superuser) against the running
database: the context is set only with the API's ticket, and no statement can rewrite it.
"""
import asyncio
import os
import time

import asyncpg
import pytest

from app import db, readiness, security
from context import SET_CONTEXT, context_args
from test_e2e import owner_sql

APP_URL = os.environ.get("MASSLAK_DATABASE_URL")
needs_db = pytest.mark.skipif(not APP_URL, reason="needs MASSLAK_DATABASE_URL")


def _two_companies() -> tuple[int, int]:
    rows = owner_sql("SELECT array_agg(company_id ORDER BY company_id) FROM (SELECT DISTINCT company_id FROM iam.company_member) v")
    assert rows and len(rows) >= 2, "the demo data has members of two companies"
    return rows[0], rows[1]


def _as_api(check):
    async def run():
        conn = await asyncpg.connect(APP_URL)
        await db.prepare_connection(conn)
        try:
            return await check(conn)
        finally:
            await conn.close()
    return asyncio.run(run())


@needs_db
def test_the_login_cannot_rewrite_the_context():
    a, b = _two_companies()

    async def check(conn):
        async with conn.transaction():
            await conn.execute(SET_CONTEXT, *context_args(None, a, "COMPANY"))
            assert {r[0] for r in await conn.fetch("SELECT DISTINCT company_id FROM iam.company_member")} == {a}
            # the reproduction of the review: SQL slipped into a statement raises the scope to the platform
            with pytest.raises(asyncpg.InsufficientPrivilegeError, match="set_config"):
                await conn.fetch("SELECT DISTINCT company_id FROM iam.company_member WHERE set_config('app.scope', 'PLATFORM', true) IS NOT NULL")
        async with conn.transaction():
            with pytest.raises(asyncpg.InsufficientPrivilegeError, match="CONTEXT_TICKET_REQUIRED"):
                await conn.execute("SELECT sys.set_context(NULL, $1, 'PLATFORM')", a)
        async with conn.transaction():
            with pytest.raises(asyncpg.InsufficientPrivilegeError, match="set_config"):
                await conn.execute("SELECT set_config('app.company_id', $1, true)", str(b))
    _as_api(check)


@needs_db
def test_a_ticket_opens_only_its_own_context():
    a, b = _two_companies()

    async def check(conn):
        user, company, scope, issued, ticket = context_args(None, a, "COMPANY")
        for other in ((None, b, "COMPANY"), (None, a, "PLATFORM"), (None, a, "SYSTEM"), (7, a, "COMPANY")):
            async with conn.transaction():
                with pytest.raises(asyncpg.InsufficientPrivilegeError, match="CONTEXT_TICKET_INVALID"):
                    await conn.execute(SET_CONTEXT, *other, issued, ticket)
        stale = int(time.time()) - 900
        async with conn.transaction():
            with pytest.raises(asyncpg.InsufficientPrivilegeError, match="CONTEXT_TICKET_STALE"):
                await conn.execute(SET_CONTEXT, None, a, "COMPANY", stale,
                                   security.context_ticket((None, a, "COMPANY", None, None, None, None), stale))
        async with conn.transaction():
            with pytest.raises(asyncpg.InsufficientPrivilegeError, match="CONTEXT_KEY_UNKNOWN"):
                await conn.execute(SET_CONTEXT, user, company, scope, issued, "0" * 16 + "." + ticket.split(".")[1])
        with pytest.raises(asyncpg.InsufficientPrivilegeError):
            await conn.fetch("SELECT secret FROM sys.context_key")
    _as_api(check)


@needs_db
def test_readiness_shows_a_key_the_database_does_not_hold(monkeypatch):
    monkeypatch.setattr(security, "context_key_fingerprint", lambda key=None: "0123456789abcdef")

    async def run():
        await db.open_pools()
        try:
            readiness._cache = None
            return await readiness.readiness()
        finally:
            readiness._cache = None
            await db.close_pools()
    out = asyncio.run(run())
    assert out["ready"] is False and out["checks"]["context"] is False and out["checks"]["database"] is True
