"""Process figures summed across the worker processes of an instance, and requests answered busy when the pool is
exhausted (code review and third-party follow-up of October 2026).

A scrape reaches one of the instance's processes; each process leaves its figures in a file and the one that answers
sums them, so counters never jump between two processes' values. Counters of a process that ended stay in the totals;
gauges come from live processes only.
"""
import asyncio
import json
import os
import time
import uuid

import asyncpg
import pytest

from app import db, errors, metrics
from app.config import get_settings

APP_URL = os.environ.get("MASSLAK_DATABASE_URL")


def _write(directory, pid, started, count, pool):
    os.makedirs(directory, exist_ok=True)
    snap = {"pid": pid, "started": started, "written": time.time(),
            "count": [["GET", "/api/x", "other", "2xx", count]],
            "hist": [["GET", "/api/x", "other", [count] * (len(metrics.BUCKETS) + 1) + [0.5]]],
            "scope": {"site.py:f": 1}, "acquire": [count] * len(db.ACQUIRE_WAITS),
            "pool_timeouts": 2, "pool": pool}
    with open(os.path.join(directory, f"{pid}-{int(started * 1000)}.json"), "w") as f:
        json.dump(snap, f)


def test_figures_of_all_processes_are_summed(tmp_path, monkeypatch):
    monkeypatch.setenv("WEB_CONCURRENCY", "2")
    monkeypatch.setenv("MASSLAK_METRICS_DIR", str(tmp_path))
    directory = metrics._instance_dir()
    dead = 4_000_000 + os.getpid() % 1000                  # above the kernel's pid limit: never alive
    _write(directory, os.getppid(), time.time() - 30, 5, {"size": 20, "idle": 3})       # the sibling worker, alive
    _write(directory, dead, time.time() - 600, 7, {"size": 20, "idle": 20})            # a worker that was replaced
    g = metrics.gathered()
    assert g["count"][("GET", "/api/x", "other", "2xx")] == 12           # both processes' counters, the ended one too
    assert g["hist"][("GET", "/api/x", "other")][-1] == 1.0
    assert g["pool_timeouts"] >= 4 and g["scope"]["site.py:f"] == 2
    assert g["processes"] == 2                                           # this process and its live sibling
    assert g["pool"]["size"] >= 20 and g["pool"]["idle"] >= 3 and g["pool"]["size"] < 40
    lines = "\n".join(metrics.render_requests(g))
    assert 'masslak_http_requests_total{method="GET",route="/api/x",group="other",status="2xx"} 12' in lines
    assert "masslak_api_processes 2" in lines
    assert os.path.exists(os.path.join(directory, f"{os.getpid()}-{int(metrics._started * 1000)}.json"))  # published


def test_one_process_uses_no_files(tmp_path, monkeypatch):
    monkeypatch.delenv("WEB_CONCURRENCY", raising=False)
    monkeypatch.setenv("MASSLAK_METRICS_DIR", str(tmp_path))
    g = metrics.gathered()
    assert g["processes"] == 1 and not any(tmp_path.iterdir())


@pytest.mark.skipif(not APP_URL, reason="needs MASSLAK_DATABASE_URL")
def test_an_exhausted_pool_answers_busy_instead_of_queueing(monkeypatch):
    async def run():
        monkeypatch.setattr(get_settings(), "db_acquire_timeout", 0.3)
        pool = await asyncpg.create_pool(APP_URL, min_size=1, max_size=1)
        saved, before = db._pool, db.POOL_TIMEOUTS[0]
        db._pool = pool
        try:
            async with pool.acquire():                                    # every connection is busy
                started = time.monotonic()
                with pytest.raises(db.PoolBusy):
                    async with db.transaction(db.Context(request_id=uuid.uuid4(), ip="127.0.0.1")):
                        pass
                assert time.monotonic() - started < 2
            assert db.POOL_TIMEOUTS[0] == before + 1
            async with db.transaction(db.Context(request_id=uuid.uuid4(), ip="127.0.0.1")) as conn:   # free again
                assert await conn.fetchval("SELECT 1") == 1
        finally:
            db._pool = saved
            await pool.close()
        response = await errors.pool_busy_handler(None, db.PoolBusy())
        assert response.status_code == 503 and response.headers["retry-after"] == "2"
    asyncio.run(run())
