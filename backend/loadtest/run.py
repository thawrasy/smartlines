"""Load test of the booking spine (third-party audit R-12, architecture report R1): search, seat map, seat hold and its
release, at rising concurrency, with p50, p95 and p99 per step; and the race of many users for one seat.

With --mix full (audit T3-09) the run is end to end: each passenger books and pays from the wallet, then cancels for a
refund (so the inventory stays available); drivers send positions every second; carrier staff run reports. With
--owner-dsn it also records what the database went through: transactions, deadlocks, WAL written, sessions waiting on
locks (sampled), temporary files and cache hit ratio, plus the host load.

    python -m loadtest.run --base http://localhost:8000 --levels 10,50,100 --seconds 30 [--accounts 30] [--json out.json]
    python -m loadtest.run --base http://localhost:8000 --levels 10,25,50 --mix full --owner-dsn postgresql://... --json out.json
    python -m loadtest.run --base http://localhost:8000 --same-seat 100

Run it against staging with production-like hardware and data; numbers from a laptop or a CI runner are a smoke test,
not capacity evidence. The API's sign-in rate limits must allow the accounts it creates (MASSLAK_RATE_AUTH_PER_MINUTE).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import secrets
import statistics
import sys
import time
import uuid
from datetime import datetime, timedelta

import httpx

PASSWORD = "load-test-password-2026"
DEMO_PASSWORD = "Masslak-Demo-2026"
DRIVERS = ["driver@carrier.test", "driver2@carrier.test"]
STAFF = ["owner@carrier.test"]
ROUTES = [("DAM", "HMA"), ("DAM", "HMS"), ("DAM", "ALP")]


def day(offset: int) -> str:
    return (datetime.utcnow() + timedelta(hours=3) + timedelta(days=offset)).date().isoformat()


def headers() -> dict:
    # each run speaks from its own benchmarking address (RFC 2544), so the per-address sign-in counters stay independent
    return {"X-Masslak-Client": "web", "X-Forwarded-For": f"198.19.{secrets.randbelow(256)}.{1 + secrets.randbelow(254)}"}


async def account(base: str) -> httpx.AsyncClient:
    c = httpx.AsyncClient(base_url=base, headers=headers(), timeout=30)
    email = f"load{uuid.uuid4().hex[:10]}@example.com"
    r = await c.post("/api/auth/register", json={"full_name": "Load Test", "email": email, "password": PASSWORD})
    r.raise_for_status()
    r = await c.post("/api/auth/login", json={"identifier": email, "password": PASSWORD, "portal": "PASSENGER"})
    r.raise_for_status()
    return c


class Stats:
    def __init__(self):
        self.times: dict[str, list[float]] = {}
        self.errors: dict[str, int] = {}

    def add(self, step: str, ms: float, ok: bool):
        self.times.setdefault(step, []).append(ms)
        if not ok:
            self.errors[step] = self.errors.get(step, 0) + 1

    def table(self, seconds: float) -> list[dict]:
        out = []
        for step, xs in self.times.items():
            xs = sorted(xs)
            q = statistics.quantiles(xs, n=100, method="inclusive") if len(xs) > 1 else [xs[0]] * 99
            out.append({"step": step, "requests": len(xs), "per_second": round(len(xs) / seconds, 1),
                        "p50_ms": round(q[49], 1), "p95_ms": round(q[94], 1), "p99_ms": round(q[98], 1),
                        "max_ms": round(xs[-1], 1), "errors": self.errors.get(step, 0)})
        return out


async def timed(stats: Stats, step: str, call):
    t0 = time.perf_counter()
    try:
        r = await call
        ok = r.status_code < 500 and r.status_code != 429
    except httpx.HTTPError:
        r, ok = None, False
    stats.add(step, (time.perf_counter() - t0) * 1000, ok)
    return r


async def user_loop(c: httpx.AsyncClient, stats: Stats, until: float):
    while time.perf_counter() < until:
        o, d = ROUTES[secrets.randbelow(len(ROUTES))]
        r = await timed(stats, "search", c.get("/api/trips/search", params={"origin": o, "destination": d, "on": day(1 + secrets.randbelow(5)),
                                                                            "passengers": 1}))
        trips = [t for t in (r.json().get("trips", []) if r is not None and r.status_code == 200 else []) if t.get("bookable")]
        if not trips:
            continue
        t = trips[secrets.randbelow(len(trips))]
        r = await timed(stats, "seat_map", c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]}))
        free = [s["seat_no"] for s in (r.json().get("seats", []) if r is not None and r.status_code == 200 else []) if s.get("free")]
        if not free:
            continue
        seat = free[secrets.randbelow(len(free))]
        r = await timed(stats, "hold", c.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
                                                                  "seat_nos": [seat]}))
        if r is not None and r.status_code in (200, 201):
            token = r.json().get("hold_token")
            await timed(stats, "release", c.delete(f"/api/holds/{token}"))


async def buyer_loop(c: httpx.AsyncClient, stats: Stats, until: float):
    """Book and pay from the wallet, then cancel for a refund: the money path end to end."""
    while time.perf_counter() < until:
        o, d = ROUTES[secrets.randbelow(len(ROUTES))]
        r = await timed(stats, "search", c.get("/api/trips/search", params={"origin": o, "destination": d, "on": day(1 + secrets.randbelow(5)),
                                                                            "passengers": 1}))
        trips = [t for t in (r.json().get("trips", []) if r is not None and r.status_code == 200 else []) if t.get("bookable")]
        if not trips:
            continue
        t = trips[secrets.randbelow(len(trips))]
        r = await timed(stats, "seat_map", c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]}))
        free = [s["seat_no"] for s in (r.json().get("seats", []) if r is not None and r.status_code == 200 else []) if s.get("free")]
        if not free:
            continue
        seat = free[secrets.randbelow(len(free))]
        r = await timed(stats, "hold", c.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
                                                                  "seat_nos": [seat]}))
        if r is None or r.status_code not in (200, 201):
            continue
        r = await timed(stats, "book_pay", c.post("/api/bookings", json={
            "hold_token": r.json()["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
            "fare_brand": "STANDARD", "idempotency_key": uuid.uuid4().hex,
            "passengers": [{"nationality": "SY", "first_name": "Load", "father_name": "Test", "grandfather_name": "Run",
                            "last_name": "User", "seat_no": seat, "id_type": "NATIONAL_ID", "id_last4": "1234"}]}))
        if r is not None and r.status_code == 201:
            await timed(stats, "cancel_refund", c.post(f"/api/bookings/{r.json()['booking_ref']}/cancel"))


async def driver_loop(c: httpx.AsyncClient, stats: Stats, until: float):
    trips = (await c.get("/api/driver/trips")).json().get("trips", [])
    if not trips:
        return
    trip, seq = trips[0]["uid"], 0
    while time.perf_counter() < until:
        seq += 1
        await timed(stats, "position", c.post("/api/driver/location", json={
            "trip_uid": trip, "lat": 33.5 + seq * 1e-4, "lng": 36.3 + seq * 1e-4, "accuracy_m": 8, "speed_kmh": 60,
            "event_id": str(uuid.uuid4()), "seq": seq, "provider": "GPS"}))
        await asyncio.sleep(1)


async def staff_loop(c: httpx.AsyncClient, stats: Stats, until: float):
    while time.perf_counter() < until:
        await timed(stats, "report", c.post("/api/reports/run", json={"code": "sales.daily", "params": {
            "from": day(-30), "to": day(0)}}))
        await asyncio.sleep(2)


async def demo_login(base: str, email: str, portal: str) -> httpx.AsyncClient:
    c = httpx.AsyncClient(base_url=base, headers=headers(), timeout=30)
    (await c.post("/api/auth/login", json={"identifier": email, "password": DEMO_PASSWORD, "portal": portal})).raise_for_status()
    return c


class DbProbe:
    """Database counters before and after a level, and lock waits sampled while it runs (needs the owner's DSN)."""

    def __init__(self, dsn: str | None):
        self.dsn, self.samples, self.conn = dsn, [], None

    async def snapshot(self) -> dict:
        r = await self.conn.fetchrow(
            """SELECT sum(xact_commit) AS commits, sum(xact_rollback) AS rollbacks, sum(deadlocks) AS deadlocks,
                      sum(temp_bytes) AS temp_bytes, sum(blks_hit) AS hit, sum(blks_read) AS read,
                      pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0') AS wal FROM pg_stat_database""")
        return dict(r)

    async def sample(self, until: float):
        while time.perf_counter() < until:
            r = await self.conn.fetchrow(
                """SELECT count(*) FILTER (WHERE wait_event_type = 'Lock') AS waiting,
                          coalesce(max(extract(epoch FROM now() - query_start)) FILTER (WHERE wait_event_type = 'Lock'), 0) AS longest,
                          count(*) FILTER (WHERE state = 'active') AS active FROM pg_stat_activity WHERE backend_type = 'client backend'""")
            self.samples.append(dict(r))
            await asyncio.sleep(0.5)

    @staticmethod
    def diff(a: dict, b: dict, seconds: float, samples: list) -> dict:
        hit, read = float(b["hit"] - a["hit"]), float(b["read"] - a["read"])
        return {"commits_per_second": round(float(b["commits"] - a["commits"]) / seconds, 1),
                "rollbacks": int(b["rollbacks"] - a["rollbacks"]), "deadlocks": int(b["deadlocks"] - a["deadlocks"]),
                "wal_mb": round(float(b["wal"] - a["wal"]) / 1e6, 2), "temp_mb": round(float(b["temp_bytes"] - a["temp_bytes"]) / 1e6, 2),
                "cache_hit_pct": round(100.0 * hit / (hit + read), 2) if hit + read else None,
                "lock_waiters_max": max((s["waiting"] for s in samples), default=0),
                "lock_wait_longest_s": round(max((float(s["longest"]) for s in samples), default=0.0), 3),
                "active_sessions_max": max((s["active"] for s in samples), default=0),
                "host_load_1m": round(__import__("os").getloadavg()[0], 2)}


async def level(base: str, clients: list[httpx.AsyncClient], users: int, seconds: int, mix: str = "booking",
                extra: dict | None = None, probe: DbProbe | None = None) -> dict:
    stats = Stats()
    until = time.perf_counter() + seconds
    t0 = time.perf_counter()
    loop = buyer_loop if mix == "full" else user_loop
    tasks = [loop(clients[i % len(clients)], stats, until) for i in range(users)]
    if mix == "full" and extra:
        tasks += [driver_loop(c, stats, until) for c in extra["drivers"]]
        tasks += [staff_loop(c, stats, until) for c in extra["staff"]]
    before = None
    if probe and probe.conn:
        probe.samples = []
        before = await probe.snapshot()
        tasks.append(probe.sample(until))
    await asyncio.gather(*tasks)
    elapsed = time.perf_counter() - t0
    out = {"users": users, "seconds": seconds, "mix": mix, "steps": stats.table(elapsed)}
    if before is not None:
        out["database"] = DbProbe.diff(before, await probe.snapshot(), elapsed, probe.samples)
    return out


async def same_seat(base: str, n: int) -> dict:
    """n users ask for the same seat at the same instant: exactly one hold may succeed (architecture report, gate C)."""
    clients = [await account(base) for _ in range(min(n, 30))]
    c0 = clients[0]
    trip = None
    for offset in range(1, 7):
        r = await c0.get("/api/trips/search", params={"origin": "DAM", "destination": "HMA", "on": day(offset), "passengers": 1})
        trips = [t for t in r.json().get("trips", []) if t.get("bookable") and t.get("seats_left", 0) > 0]
        if trips:
            trip = trips[0]
            break
    if trip is None:
        return {"error": "no bookable trip; reseed the demo data"}
    seats = (await c0.get(f"/api/trips/{trip['uid']}", params={"from_seq": trip["from_seq"], "to_seq": trip["to_seq"]})).json()["seats"]
    seat = next(s["seat_no"] for s in seats if s["free"])
    body = {"trip_uid": trip["uid"], "from_seq": trip["from_seq"], "to_seq": trip["to_seq"], "seat_nos": [seat]}
    results = await asyncio.gather(*(clients[i % len(clients)].post("/api/holds", json=body) for i in range(n)), return_exceptions=True)
    won = [r for r in results if isinstance(r, httpx.Response) and r.status_code in (200, 201)]
    refused = [r for r in results if isinstance(r, httpx.Response) and r.status_code == 409]
    for r, c in zip(results, [clients[i % len(clients)] for i in range(n)]):
        if isinstance(r, httpx.Response) and r.status_code in (200, 201):
            await c.delete(f"/api/holds/{r.json()['hold_token']}")
    for c in clients:
        await c.aclose()
    return {"users": n, "seat": seat, "holds_granted": len(won), "refused_seat_taken": len(refused),
            "other": n - len(won) - len(refused), "exactly_one": len(won) == 1}


async def main(args) -> int:
    if args.same_seat:
        out = await same_seat(args.base, args.same_seat)
        print(json.dumps(out, indent=1))
        return 0 if out.get("exactly_one") else 1
    clients = [await account(args.base) for _ in range(args.accounts)]
    extra = None
    if args.mix == "full":
        for c in clients:          # sandbox top-up so every passenger can pay from the wallet
            (await c.post("/api/wallet/topup", json={"amount": 500000000, "idempotency_key": uuid.uuid4().hex})).raise_for_status()
        extra = {"drivers": [await demo_login(args.base, e, "DRIVER") for e in DRIVERS],
                 "staff": [await demo_login(args.base, e, "OPERATOR") for e in STAFF]}
    probe = DbProbe(args.owner_dsn)
    if args.owner_dsn:
        import asyncpg
        probe.conn = await asyncpg.connect(args.owner_dsn)
    report = []
    try:
        for users in [int(x) for x in args.levels.split(",")]:
            res = await level(args.base, clients, users, args.seconds, args.mix, extra, probe)
            report.append(res)
            print(f"\n{users} concurrent users, {args.seconds}s, mix {args.mix}")
            print(f"{'step':14} {'req':>7} {'req/s':>7} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8} {'err':>5}")
            for s in res["steps"]:
                print(f"{s['step']:14} {s['requests']:7} {s['per_second']:7} {s['p50_ms']:8} {s['p95_ms']:8} {s['p99_ms']:8} {s['max_ms']:8} {s['errors']:5}")
            if "database" in res:
                print("database:", json.dumps(res["database"]))
    finally:
        for c in clients + (extra["drivers"] + extra["staff"] if extra else []):
            await c.aclose()
        if probe.conn:
            await probe.conn.close()
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=1)
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser(prog="python -m loadtest.run")
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--levels", default="10,50,100")
    ap.add_argument("--seconds", type=int, default=30)
    ap.add_argument("--accounts", type=int, default=30)
    ap.add_argument("--same-seat", type=int, default=0)
    ap.add_argument("--mix", choices=["booking", "full"], default="booking")
    ap.add_argument("--owner-dsn", help="owner connection for database counters (pg_stat_database, locks, WAL)")
    ap.add_argument("--json")
    sys.exit(asyncio.run(main(ap.parse_args())))
