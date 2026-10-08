"""Soak test (expert review of October 2026, stage B; launch gate 3): a steady, realistic load for hours, to find what
only time shows: memory that grows, vacuum that falls behind, dead rows and bloat, a replica that drifts, an outbox
or webhook backlog that creeps up, connections that leak, latency that worsens.

Travellers search, open a seat map, hold, book and pay, and cancel for a refund, with think time between steps;
drivers send a position every few seconds; carrier staff run a report now and then. Every --sample seconds the run
records, through the owner's connection and /proc:

    API memory (resident set of the API processes on this host), database size, dead rows and autovacuum runs on the
    busy tables, transaction-id age, outbox events waiting and the oldest one's age, webhook deliveries waiting,
    replica lag, client connections, sessions waiting on locks, deadlocks, and per window the requests, errors and
    p95 latency per step.

The verdict compares the trend of the second half of the run (after warm-up) with limits: API memory growth, a
backlog that keeps growing, dead-row ratio on busy tables, replica lag, deadlocks, error budget and booking latency.

    python -m loadtest.soak --base http://localhost:8000 --owner-dsn postgresql://... --hours 8 --users 40 --json out.json
    python -m loadtest.soak ... --minutes 10      a short smoke run (proves the tool, not the system)

The gate needs 8 to 24 hours on staging hardware with production-size data (LAUNCH_GATES.md, gate 3). Needs a sandbox
build (sandbox top-ups fund the travellers) with the sign-in limits raised for the accounts it creates.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import random
import statistics
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone

import httpx

from .run import DRIVERS, ROUTES, STAFF, Stats, account, day, demo_login

BUSY_TABLES = ("ops.seat_segment", "sales.booking", "sales.ticket", "fin.wallet", "sys.webhook_delivery", "ops.trip")
LIMITS = {"memory_growth_mb_per_hour": 50.0, "dead_ratio": 0.2, "replica_lag_s": 30.0, "outbox_oldest_s": 300.0,
          "error_budget": 0.001, "booking_p95_ms": 800.0, "slow_window_share": 0.01}


class Window(Stats):
    """Request counters for one sampling window."""


class Soak:
    def __init__(self, args):
        self.args = args
        self.window = Window()
        self.total = Stats()
        self.samples: list[dict] = []
        self.stop = asyncio.Event()

    async def timed(self, step: str, call):
        t0 = time.perf_counter()
        try:
            r = await call
            ok = r.status_code < 500 and r.status_code != 429
        except httpx.HTTPError:
            r, ok = None, False
        ms = (time.perf_counter() - t0) * 1000
        self.window.add(step, ms, ok)
        self.total.add(step, ms, ok)
        return r

    async def think(self):
        try:
            await asyncio.wait_for(self.stop.wait(), timeout=random.uniform(*self.args.think))
        except asyncio.TimeoutError:
            pass

    async def traveller(self, c: httpx.AsyncClient):
        while not self.stop.is_set():
            o, d = random.choice(ROUTES)
            r = await self.timed("search", c.get("/api/trips/search", params={"origin": o, "destination": d,
                                                                               "on": day(random.randint(1, 5)), "passengers": 1}))
            trips = [t for t in (r.json().get("trips", []) if r is not None and r.status_code == 200 else []) if t.get("bookable")]
            await self.think()
            if not trips:
                continue
            t = random.choice(trips)
            span = {"from_seq": t["from_seq"], "to_seq": t["to_seq"]}
            r = await self.timed("seat_map", c.get(f"/api/trips/{t['uid']}", params=span))
            free = [s["seat_no"] for s in (r.json().get("seats", []) if r is not None and r.status_code == 200 else []) if s.get("free")]
            if not free:
                continue
            seat = random.choice(free)
            r = await self.timed("hold", c.post("/api/holds", json={"trip_uid": t["uid"], **span, "seat_nos": [seat]}))
            if r is None or r.status_code not in (200, 201):
                continue
            await self.think()
            r = await self.timed("book_pay", c.post("/api/bookings", json={
                "hold_token": r.json()["hold_token"], "trip_uid": t["uid"], **span, "fare_brand": "STANDARD",
                "idempotency_key": uuid.uuid4().hex,
                "passengers": [{"nationality": "SY", "first_name": "Soak", "father_name": "Test", "grandfather_name": "Run",
                                "last_name": "Traveller", "seat_no": seat, "id_type": "NATIONAL_ID", "id_last4": "1234"}]}))
            if r is not None and r.status_code == 201:
                await self.think()
                await self.timed("cancel_refund", c.post(f"/api/bookings/{r.json()['booking_ref']}/cancel"))

    async def driver(self, c: httpx.AsyncClient):
        trips = (await c.get("/api/driver/trips")).json().get("trips", [])
        if not trips:
            return
        seq = 0
        while not self.stop.is_set():
            seq += 1
            await self.timed("position", c.post("/api/driver/location", json={
                "trip_uid": trips[0]["uid"], "lat": 33.5 + (seq % 500) * 1e-4, "lng": 36.3 + (seq % 500) * 1e-4, "accuracy_m": 8,
                "speed_kmh": 60, "event_id": str(uuid.uuid4()), "seq": seq, "provider": "GPS"}))
            try:
                await asyncio.wait_for(self.stop.wait(), timeout=5)
            except asyncio.TimeoutError:
                pass

    async def staff(self, c: httpx.AsyncClient):
        while not self.stop.is_set():
            await self.timed("report", c.post("/api/reports/run", json={"code": "sales.daily", "params": {"from": day(-30), "to": day(0)}}))
            try:
                await asyncio.wait_for(self.stop.wait(), timeout=60)
            except asyncio.TimeoutError:
                pass

    async def sampler(self, conn, pids: list[int], t0: float):
        while not self.stop.is_set():
            try:
                await asyncio.wait_for(self.stop.wait(), timeout=self.args.sample)
            except asyncio.TimeoutError:
                pass
            sample = {"t_s": round(time.monotonic() - t0), "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                      "api_rss_mb": api_rss_mb(pids), **(await database_sample(conn))}
            win = self.window.table(self.args.sample)
            self.window = Window()
            sample["requests"] = sum(s["requests"] for s in win)
            sample["errors"] = sum(s["errors"] for s in win)
            sample["p95_ms"] = {s["step"]: s["p95_ms"] for s in win}
            self.samples.append(sample)
            print(json.dumps({k: sample[k] for k in ("t_s", "api_rss_mb", "outbox_pending", "outbox_oldest_s", "dead_ratio_max",
                                                      "replica_lag_s", "lock_waiters", "requests", "errors")}), flush=True)


def api_pids(spec: str, base: str = "") -> list[int]:
    """The API processes on this host: given, or found by the port of --base (and their worker children)."""
    if spec == "none":
        return []
    if spec != "auto":
        return [int(p) for p in spec.split(",") if p]
    from urllib.parse import urlparse
    port = urlparse(base).port
    pattern = f"uvicorn app.main:app.*--port {port}" if port else "uvicorn app.main:app"
    try:
        out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    found, todo = set(), [int(p) for p in out.split()]
    while todo:                       # uvicorn --workers: the workers are children of the manager, with another command line
        pid = todo.pop()
        if pid in found:
            continue
        found.add(pid)
        try:
            kids = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True, timeout=5).stdout
        except (OSError, subprocess.SubprocessError):
            kids = ""
        todo += [int(k) for k in kids.split()]
    return sorted(found)


def api_rss_mb(pids: list[int]) -> float | None:
    if not pids:
        return None
    total = 0
    for pid in pids:
        try:
            with open(f"/proc/{pid}/status") as fh:
                for line in fh:
                    if line.startswith("VmRSS:"):
                        total += int(line.split()[1])
        except OSError:
            pass
    return round(total / 1024, 1)


async def database_sample(conn) -> dict:
    r = await conn.fetchrow(
        """SELECT pg_database_size(current_database()) / 1048576.0 AS db_mb,
                  (SELECT age(datfrozenxid) FROM pg_database WHERE datname = current_database()) AS xid_age,
                  (SELECT count(*) FROM pg_stat_activity WHERE backend_type = 'client backend') AS connections,
                  (SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock') AS lock_waiters,
                  (SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()) AS deadlocks,
                  (SELECT coalesce(max(extract(epoch FROM replay_lag)), 0) FROM pg_stat_replication) AS replica_lag_s,
                  (SELECT count(*) FROM sys.outbox_event WHERE status = 'PENDING') AS outbox_pending,
                  (SELECT coalesce(extract(epoch FROM now() - min(created_at)), 0) FROM sys.outbox_event WHERE status = 'PENDING') AS outbox_oldest_s,
                  (SELECT count(*) FROM sys.webhook_delivery WHERE status = 'PENDING') AS webhooks_pending""")
    tables = await conn.fetch(
        """SELECT schemaname || '.' || relname AS t, n_live_tup, n_dead_tup, autovacuum_count, autoanalyze_count
             FROM pg_stat_user_tables WHERE schemaname || '.' || relname = ANY($1::text[])""", list(BUSY_TABLES))
    # a ratio only means something on a table of some size: a few dead rows in a table of three are nothing
    ratios = {x["t"]: round(x["n_dead_tup"] / max(1, x["n_live_tup"] + x["n_dead_tup"]), 3) for x in tables
              if x["n_live_tup"] + x["n_dead_tup"] >= 10_000}
    return {"db_mb": round(float(r["db_mb"]), 1), "xid_age": int(r["xid_age"]), "connections": int(r["connections"]),
            "lock_waiters": int(r["lock_waiters"]), "deadlocks": int(r["deadlocks"]), "replica_lag_s": round(float(r["replica_lag_s"]), 1),
            "outbox_pending": int(r["outbox_pending"]), "outbox_oldest_s": round(float(r["outbox_oldest_s"]), 1),
            "webhooks_pending": int(r["webhooks_pending"]), "dead_ratio": ratios, "dead_ratio_max": max(ratios.values(), default=0.0),
            "autovacuum_runs": sum(int(x["autovacuum_count"]) for x in tables)}


def slope_per_hour(points: list[tuple[float, float]]) -> float:
    """Least-squares slope of (seconds, value) points, per hour."""
    if len(points) < 3:
        return 0.0
    xs, ys = [p[0] for p in points], [p[1] for p in points]
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return 0.0 if den == 0 else sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den * 3600


def verdict(samples: list[dict], totals: list[dict], duration_s: float, limits: dict) -> dict:
    reasons, notes = [], []
    if len(samples) < 4:
        return {"status": "INCONCLUSIVE", "reasons": [], "notes": ["fewer than four samples"]}
    late = samples[len(samples) // 2:]                       # after warm-up
    mem = [(s["t_s"], s["api_rss_mb"]) for s in late if s["api_rss_mb"] is not None]
    growth = slope_per_hour(mem) if mem else None
    if growth is None:
        notes.append("API memory not measured (the API runs on another host): read it from the container platform")
    elif growth > limits["memory_growth_mb_per_hour"]:
        reasons.append(f"API memory grows {growth:.0f} MB an hour after warm-up")
    backlog = slope_per_hour([(s["t_s"], s["outbox_pending"]) for s in late])
    if max(s["outbox_oldest_s"] for s in samples) > limits["outbox_oldest_s"]:
        reasons.append("an outbox event waited more than 5 minutes")
    if backlog > 0 and late[-1]["outbox_pending"] > max(100, 2 * statistics.median(s["outbox_pending"] for s in late)):
        reasons.append("the outbox backlog keeps growing")
    if late[-1]["dead_ratio_max"] > limits["dead_ratio"]:
        reasons.append(f"dead rows reach {late[-1]['dead_ratio_max']:.0%} of a busy table (vacuum behind)")
    lags = sorted(s["replica_lag_s"] for s in samples)
    if lags and lags[min(len(lags) - 1, int(0.99 * len(lags)))] > limits["replica_lag_s"]:
        reasons.append("the replica lags more than 30 s")
    if samples[-1]["deadlocks"] > samples[0]["deadlocks"]:
        reasons.append(f"{samples[-1]['deadlocks'] - samples[0]['deadlocks']} deadlocks")
    requests, errors = sum(s["requests"] for s in totals), sum(s["errors"] for s in totals)
    if requests and errors / requests > limits["error_budget"]:
        reasons.append(f"{errors} of {requests} requests failed")
    slow = [s for s in samples if max(s["p95_ms"].get("hold", 0), s["p95_ms"].get("book_pay", 0)) > limits["booking_p95_ms"]]
    if len(slow) > limits["slow_window_share"] * len(samples):
        reasons.append(f"booking p95 over 800 ms in {len(slow)} of {len(samples)} windows")
    if duration_s < 8 * 3600:
        notes.append(f"a {duration_s / 3600:.1f} h run: the gate needs 8 to 24 hours")
    status = "FAIL" if reasons else ("INCONCLUSIVE" if duration_s < 8 * 3600 else "PASS")
    return {"status": status, "reasons": reasons, "notes": notes,
            "trends": {"api_memory_mb_per_hour": None if growth is None else round(growth, 1),
                       "outbox_pending_per_hour": round(backlog, 1),
                       "db_mb_per_hour": round(slope_per_hour([(s["t_s"], s["db_mb"]) for s in late]), 1),
                       "xid_age_per_hour": round(slope_per_hour([(s["t_s"], s["xid_age"]) for s in late])),
                       "autovacuum_runs": samples[-1]["autovacuum_runs"] - samples[0]["autovacuum_runs"]}}


async def main(args) -> int:
    import asyncpg
    seconds = int(args.minutes * 60) if args.minutes else int(args.hours * 3600)
    soak = Soak(args)
    gate = asyncio.Semaphore(16)

    async def traveller_client():
        async with gate:
            c = await account(args.base)
            (await c.post("/api/wallet/topup", json={"amount": 500_000_000, "idempotency_key": uuid.uuid4().hex})).raise_for_status()
            return c
    travellers = list(await asyncio.gather(*(traveller_client() for _ in range(args.users))))
    drivers = [await demo_login(args.base, e, "DRIVER") for e in DRIVERS]
    staff = [await demo_login(args.base, e, "OPERATOR") for e in STAFF]
    conn = await asyncpg.connect(args.owner_dsn)
    pids = api_pids(args.api_pids, args.base)
    t0 = time.monotonic()
    started = datetime.now(timezone.utc)
    tasks = [asyncio.create_task(soak.traveller(c)) for c in travellers]
    tasks += [asyncio.create_task(soak.driver(c)) for c in drivers]
    tasks += [asyncio.create_task(soak.staff(c)) for c in staff]
    sampler = asyncio.create_task(soak.sampler(conn, pids, t0))
    try:
        await asyncio.sleep(seconds)
    finally:
        soak.stop.set()
        await asyncio.gather(*tasks, return_exceptions=True)
        await sampler
        await conn.close()
        for c in travellers + drivers + staff:
            await c.aclose()
    duration = time.monotonic() - t0
    totals = soak.total.table(duration)
    report = {"environment": args.environment, "tool": "backend/loadtest/soak.py", "date": started.date().isoformat(), "base": args.base,
              "host": {"name": platform.node(), "cpus": os.cpu_count(), "api_pids": pids},
              "duration_s": round(duration), "users": args.users, "think_s": list(args.think), "sample_s": args.sample,
              "limits": LIMITS, "steps": totals, "samples": soak.samples,
              "verdict": verdict(soak.samples, totals, duration, LIMITS)}
    print(json.dumps(report["verdict"], indent=1))
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=1, default=str)
    return {"PASS": 0, "INCONCLUSIVE": 2}.get(report["verdict"]["status"], 1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(prog="python -m loadtest.soak")
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--owner-dsn", required=True, help="owner connection for the database samples")
    ap.add_argument("--hours", type=float, default=8.0)
    ap.add_argument("--minutes", type=float, default=0.0, help="a short run instead of --hours")
    ap.add_argument("--users", type=int, default=40, help="travellers, each with think time between steps")
    ap.add_argument("--think", type=float, nargs=2, default=(1.0, 3.0), metavar=("MIN", "MAX"))
    ap.add_argument("--sample", type=int, default=60, help="seconds between samples")
    ap.add_argument("--api-pids", default="auto", help="API process ids for memory, 'auto' (this host) or 'none'")
    ap.add_argument("--environment", choices=["development", "staging", "production"], default="development",
                    help="where it ran; only staging evidence counts for launch gate 3 (db/tools/launch_gates.py)")
    ap.add_argument("--json")
    sys.exit(asyncio.run(main(ap.parse_args())))
