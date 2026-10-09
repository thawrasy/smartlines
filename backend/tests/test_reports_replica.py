"""Reports read a streaming replica in production (architecture review of design 3.9): the API and the worker refuse to
start without one, or when the configured address is a primary."""
import asyncio

import pytest

from app import db


class _Conn:
    def __init__(self, in_recovery):
        self.in_recovery = in_recovery

    async def fetchval(self, sql):
        assert "pg_is_in_recovery" in sql
        return self.in_recovery


class _Pool:
    """The two calls of asyncpg's pool that db.acquire makes (it waits at most db_acquire_timeout)."""
    def __init__(self, in_recovery):
        self.conn = _Conn(in_recovery)

    async def acquire(self, timeout=None):
        assert timeout
        return self.conn

    async def release(self, conn):
        assert conn is self.conn


def _settings(sandbox):
    return lambda: type("S", (), {"sandbox": sandbox, "db_acquire_timeout": 5.0})()


def test_production_needs_a_reports_replica(monkeypatch):
    monkeypatch.setattr(db, "get_settings", _settings(False))
    monkeypatch.setattr(db, "_reports_pool", None)
    with pytest.raises(RuntimeError, match="MASSLAK_REPORTS_DATABASE_URL is required"):
        asyncio.run(db.require_reports_replica())


def test_a_primary_is_not_accepted_as_the_reports_replica(monkeypatch):
    monkeypatch.setattr(db, "get_settings", _settings(False))
    monkeypatch.setattr(db, "_reports_pool", _Pool(False))
    with pytest.raises(RuntimeError, match="points at a primary"):
        asyncio.run(db.require_reports_replica())
    monkeypatch.setattr(db, "_reports_pool", _Pool(True))
    asyncio.run(db.require_reports_replica())


def test_the_sandbox_may_report_from_the_main_pool(monkeypatch):
    monkeypatch.setattr(db, "get_settings", _settings(True))
    monkeypatch.setattr(db, "_reports_pool", None)
    asyncio.run(db.require_reports_replica())
