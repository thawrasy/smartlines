"""Finer monitoring (expert review of October 2026, stage C7): lock waits name their table, partitions report how far
ahead they go, and the time requests wait for a database connection is measured."""
import asyncio
import os

import httpx
import pytest

from test_e2e import BASE

TOKEN = os.environ.get("MASSLAK_METRICS_TOKEN")


def scrape() -> str:
    r = httpx.get(f"{BASE}/api/metrics", headers={"Authorization": f"Bearer {TOKEN}"}, timeout=30)
    assert r.status_code == 200
    return r.text


@pytest.mark.skipif(not TOKEN or not os.environ.get("MASSLAK_OWNER_URL"), reason="needs MASSLAK_METRICS_TOKEN and MASSLAK_OWNER_URL")
def test_a_lock_wait_is_reported_on_its_table():
    import asyncpg

    async def run() -> str:
        holder = await asyncpg.connect(os.environ["MASSLAK_OWNER_URL"])
        waiter = await asyncpg.connect(os.environ["MASSLAK_OWNER_URL"])
        try:
            trip = await holder.fetchval("SELECT min(id) FROM ops.trip")
            tx = holder.transaction()
            await tx.start()
            await holder.execute("SELECT 1 FROM ops.trip WHERE id = $1 FOR UPDATE", trip)
            # the second session waits for the row; the scrape runs while it does
            waiting = asyncio.create_task(waiter.execute(
                "BEGIN; SET LOCAL lock_timeout = '20s'; SELECT 1 FROM ops.trip WHERE id = %d FOR UPDATE; ROLLBACK" % trip))
            await asyncio.sleep(1.5)
            body = await asyncio.to_thread(scrape)
            await tx.rollback()
            await waiting
            return body
        finally:
            await holder.close()
            await waiter.close()
    body = asyncio.run(run())
    assert 'masslak_lock_waiting{table="ops.trip"} 1' in body
    line = next(x for x in body.splitlines() if x.startswith('masslak_lock_wait_seconds_max{table="ops.trip"}'))
    assert 1.0 <= float(line.split()[-1]) < 20
    # once the lock is released nothing waits on the table
    assert 'masslak_lock_waiting{table="ops.trip"}' not in scrape()


@pytest.mark.skipif(not TOKEN, reason="needs MASSLAK_METRICS_TOKEN")
def test_partitions_and_pool_waits_are_reported():
    body = scrape()
    assert 'masslak_partition_ahead_seconds{table="fin.ledger_entry",period="month"}' in body
    assert 'masslak_partition_default_rows{table="fin.ledger_entry"} 0' in body
    assert 'masslak_partition_ahead_seconds{table="sys.outbox_event",period="day"}' in body
    assert 'masslak_db_pool_acquire_seconds_bucket{le="+Inf"}' in body and "masslak_db_pool_acquire_seconds_count" in body
