"""A scanner outage never uses up a file's scan attempts (found while preparing launch gate 7).

The worker retries quarantined files once a minute, at most MAX_ATTEMPTS times. Before the fix every retry during a
ClamAV outage counted, so a file uploaded during an outage longer than about five minutes stayed in quarantine for
good, even after ClamAV came back. Now only a file that makes the scan itself fail uses up an attempt.
"""
import asyncio
import hashlib
import os
import uuid

import pytest

from test_e2e import OWNER_URL, owner_sql

pytestmark = pytest.mark.skipif(not (OWNER_URL and os.environ.get("MASSLAK_DATABASE_URL")),
                                reason="needs MASSLAK_OWNER_URL and MASSLAK_DATABASE_URL")


def scan_once(monkeypatch, file_id: int, failure: Exception, store_down: bool = False) -> str:
    from app import db
    from app.modules.documents import scanner, storage

    def failing_scan(data, mime):
        raise failure

    async def stored(*args, **kwargs):
        if store_down:          # the object store for files cannot be reached (code review of October 2026, 3.2)
            raise storage.StoreUnavailable("FILE_STORE_UNAVAILABLE: GET failed (ConnectionRefusedError)")
        return b"%PDF-1.4 outage test"
    monkeypatch.setattr(storage, "get", stored)
    monkeypatch.setattr(scanner, "scan", failing_scan)

    async def run() -> str:
        await db.open_pools()
        try:
            ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
            async with db.transaction(ctx) as conn:
                return await scanner.scan_file(conn, ctx, file_id)
        finally:
            await db.close_pools()
    return asyncio.run(run())


def test_an_outage_uses_no_attempt_and_a_file_that_breaks_the_scan_does(monkeypatch):
    from app.modules.documents import scanner
    file_id = owner_sql("""INSERT INTO ref.file_object (storage_key, file_name, mime_type, size_bytes, sha256, scan_status)
                           VALUES ($1, 'outage.pdf', 'application/pdf', 20, $2, 'PENDING') RETURNING id""",
                        f"test/{uuid.uuid4().hex}", hashlib.sha256(b"outage").digest())
    try:
        for _ in range(scanner.MAX_ATTEMPTS + 2):
            assert scan_once(monkeypatch, file_id, scanner.Unavailable("clamd: connection refused")) == "PENDING"
        for _ in range(scanner.MAX_ATTEMPTS + 2):         # nor does the file store being down
            assert scan_once(monkeypatch, file_id, RuntimeError("not reached"), store_down=True) == "PENDING"
        assert owner_sql("SELECT scan_attempts FROM ref.file_object WHERE id = $1", file_id) == 0
        assert owner_sql("SELECT scan_status FROM ref.file_object WHERE id = $1", file_id) == "PENDING"
        # still picked up by the worker once the engine is back
        assert owner_sql("""SELECT count(*) FROM ref.file_object WHERE id = $1 AND scan_status IN ('PENDING','SCANNING')
                            AND scan_attempts < $2""", file_id, scanner.MAX_ATTEMPTS) == 1
        assert scan_once(monkeypatch, file_id, RuntimeError("the file broke the scan")) == "PENDING"
        assert owner_sql("SELECT scan_attempts FROM ref.file_object WHERE id = $1", file_id) == 1
    finally:
        # the row has no stored file: the worker must not keep trying it after the test
        owner_sql("DELETE FROM ref.file_object WHERE id = $1", file_id)
