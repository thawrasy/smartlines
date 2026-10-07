"""Load test of the booking spine (third-party audit R-12, architecture report R1): search, seat map, seat hold and its
release, at rising concurrency, with p50, p95 and p99 per step; and the race of many users for one seat.

    python -m loadtest.run --base http://localhost:8000 --levels 10,50,100 --seconds 30 [--accounts 30] [--json out.json]
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


async def level(base: str, clients: list[httpx.AsyncClient], users: int, seconds: int) -> dict:
    stats = Stats()
    until = time.perf_counter() + seconds
    t0 = time.perf_counter()
    await asyncio.gather(*(user_loop(clients[i % len(clients)], stats, until) for i in range(users)))
    return {"users": users, "seconds": seconds, "steps": stats.table(time.perf_counter() - t0)}


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
    report = []
    try:
        for users in [int(x) for x in args.levels.split(",")]:
            res = await level(args.base, clients, users, args.seconds)
            report.append(res)
            print(f"\n{users} concurrent users, {args.seconds}s")
            print(f"{'step':10} {'req':>7} {'req/s':>7} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8} {'err':>5}")
            for s in res["steps"]:
                print(f"{s['step']:10} {s['requests']:7} {s['per_second']:7} {s['p50_ms']:8} {s['p95_ms']:8} {s['p99_ms']:8} {s['max_ms']:8} {s['errors']:5}")
    finally:
        for c in clients:
            await c.aclose()
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
    ap.add_argument("--json")
    sys.exit(asyncio.run(main(ap.parse_args())))
