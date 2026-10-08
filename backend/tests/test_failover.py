"""Automatic failover, as the API sees it (review stage D6, docs/operations/HIGH_AVAILABILITY.md).

While the primary goes away and a standby is promoted, a request fails on a broken connection, on a server shutting
down or not yet accepting connections, on a standby that cannot write, or because no listed server is the primary.
None of these is an error of the request: the API answers 503 with Retry-After, so clients repeat it (bookings and
payments carry idempotency keys). The full drill with two servers is db/tools/failover_drill.py.
"""
import asyncio
import json

import asyncpg
import pytest

from app.errors import db_error_handler, unreachable_handler


@pytest.mark.parametrize("exc", [
    asyncpg.exceptions.ConnectionDoesNotExistError("connection was closed in the middle of operation"),
    asyncpg.exceptions.AdminShutdownError("terminating connection due to administrator command"),
    asyncpg.exceptions.CannotConnectNowError("the database system is starting up"),
    asyncpg.exceptions.CrashShutdownError("terminating connection because of crash of another server process"),
    asyncpg.exceptions.ReadOnlySQLTransactionError("cannot execute INSERT in a read-only transaction"),
])
def test_a_failover_is_answered_with_try_again_not_an_error(exc):
    r = asyncio.run(db_error_handler(None, exc))
    assert r.status_code == 503 and r.headers["Retry-After"] == "2"
    assert json.loads(r.body)["error"]["code"] == "SERVICE_BUSY"


@pytest.mark.parametrize("exc", [ConnectionRefusedError(111, "Connect call failed"),
                                 asyncpg.exceptions.TargetServerAttributeNotMatched("none of the hosts is read-write")])
def test_no_reachable_primary_is_answered_with_try_again(exc):
    r = asyncio.run(unreachable_handler(None, exc))
    assert r.status_code == 503 and json.loads(r.body)["error"]["code"] == "SERVICE_BUSY"


def test_a_real_database_error_is_still_an_error():
    r = asyncio.run(db_error_handler(None, asyncpg.exceptions.UndefinedTableError("relation does not exist")))
    assert r.status_code == 500
