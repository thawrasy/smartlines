"""Request limits shared by every API process (1068, code review of October 2026, H-01; reviews of October 2026, M-03).

The sign-in, public search and partner API buckets live in the database, so two processes (two connections here)
draw from the same bucket; a per-address bucket sized for carrier-grade NAT lets many users sign in from one address,
while the per-account bucket stops guessing one account. The in-memory buckets of the signed-in API are split
between the processes.
"""
import asyncio
import os
import uuid

import asyncpg
import pytest

from app import ratelimit
from context import SET_CONTEXT, context_args

APP_URL = os.environ.get("MASSLAK_DATABASE_URL")
needs_db = pytest.mark.skipif(not APP_URL, reason="needs MASSLAK_DATABASE_URL")


def _key() -> str:
    return "test-" + uuid.uuid4().hex[:12]


@needs_db
@pytest.mark.parametrize("bucket", ["auth_ip", "public_ip", "api_client"])
def test_two_processes_share_one_bucket(bucket):
    async def run():
        first, second = await asyncpg.connect(APP_URL), await asyncpg.connect(APP_URL)    # as the application role
        try:
            key = _key()
            waits = [await (first if i % 2 else second).fetchval("SELECT sec.rate_take($1, $2, 4)", bucket, key) for i in range(5)]
            assert waits[:4] == [0, 0, 0, 0]
            assert 14 < waits[4] <= 15                    # one token every 15 s at 4 a minute
            # a refused request costs nothing: the next one waits no longer than the last
            assert await first.fetchval("SELECT sec.rate_take($1, $2, 4)", bucket, key) <= waits[4]
        finally:
            await first.close()
            await second.close()
    asyncio.run(run())


@needs_db
def test_many_users_behind_one_address_but_not_one_account_guessed():
    async def run():
        conn = await asyncpg.connect(APP_URL)
        try:
            address, account = _key(), _key()
            # a hundred subscribers of one mobile network sign in within the minute through one public address
            assert all([await conn.fetchval("SELECT sec.rate_take('auth_ip', $1, 300)", address) == 0 for _ in range(100)])
            # ten attempts on one account pass; the eleventh waits, from whatever address it comes
            on_account = [await conn.fetchval("SELECT sec.rate_take('auth_id', $1, 10)", account) for _ in range(11)]
            assert on_account[:10] == [0] * 10 and on_account[10] > 0
        finally:
            await conn.close()
    asyncio.run(run())


@needs_db
def test_the_application_cannot_read_the_buckets():
    async def run():
        conn = await asyncpg.connect(APP_URL)
        try:
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                await conn.fetch("SELECT * FROM sec.rate_bucket")
            with pytest.raises(asyncpg.RaiseError, match="RATE_LIMIT_INVALID"):
                await conn.fetchval("SELECT sec.rate_take('auth_ip', 'x', 0)")
            # sign-in calls it from the AUTH scope; the function's platform scope does not leak into the caller's transaction
            async with conn.transaction():
                await conn.execute(SET_CONTEXT, *context_args(None, None, "AUTH"))
                assert await conn.fetchval("SELECT sec.rate_take('auth_id', $1, 10)", _key()) == 0
                assert await conn.fetchval("SELECT current_setting('app.scope')") == "AUTH"
        finally:
            await conn.close()
    asyncio.run(run())


def test_each_process_enforces_its_share(monkeypatch):
    monkeypatch.setenv("WEB_CONCURRENCY", "2")
    monkeypatch.setattr(ratelimit, "_limiter", None)
    try:
        rl = ratelimit.limiter()
        s = ratelimit.get_settings()
        # public search and the partner API are shared in the database (M-03); only the signed-in API is per process
        assert rl.per_minute == {"api": s.rate_api_per_minute // 2}
    finally:
        monkeypatch.setattr(ratelimit, "_limiter", None)


def test_public_and_partner_requests_draw_from_the_shared_buckets():
    """The middleware takes public search from the database bucket; the partner API takes the client's own."""
    import inspect

    from app import middleware
    from app.modules.integration import auth
    assert ratelimit.bucket_for("/api/trips/search") == "public" and ratelimit.bucket_for("/api/public/stations") == "public"
    assert "check_public" in inspect.getsource(middleware.RequestContextMiddleware._api)
    assert "check_api_client" in inspect.getsource(auth.api_caller)
    assert not hasattr(auth, "_buckets")                 # no bucket left in process memory for partner clients
