"""Concurrent users (evaluation reports of October 2026, GIMI; owner's approval): N people using the platform at the same
time, the way people do, measured against the service targets (docs/operations/SLO.md).

What a concurrent user is here: a person with the site or the app open who acts, then reads, then acts again. Each one
waits a random think time between actions (exponential, mean --think seconds, 10 by default) and follows a journey:

    70 %  browse:        search, then the seat map of one trip
    20 %  hold:          search, seat map, hold a seat, release it
     7 %  book:          search, seat map, hold, book and pay from the wallet, cancel for a refund (the money path)
     3 %  my bookings:   the list of one's own bookings

So 10,000 concurrent users with a 10-second think time make about 1,000 requests a second at the API. Browsing users
are anonymous; the others share a pool of signed-in accounts (--accounts), topped up in the sandbox. Users are added
over --ramp seconds, then held for --seconds; only the held period is measured. A single Python process drives about
1,500 users, so --workers splits them across processes on the load generator.

    python -m loadtest.users --base https://staging.masslak.com --users 10000 --workers 8 --ramp 300 --seconds 900 --json users.json

The verdict compares p95 and p99 per step group with the targets (search p95 <= 300 ms; booking p95 <= 800 ms and p99
<= 1.5 s) and the error rate (5xx and timeouts) with 0.1 % (99.9 % in SLO.md). Run it on staging with production-sized data; a laptop
or CI runner gives a smoke test, not capacity evidence.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import multiprocessing as mp
import random
import statistics
import sys
import time
import uuid

import httpx

from .run import ROUTES, account, day, headers

JOURNEYS = (("browse", 0.70), ("hold", 0.20), ("book", 0.07), ("mine", 0.03))
# step -> service target group (docs/operations/SLO.md)
GROUP = {"search": "search", "seat_map": "search", "hold": "booking", "release": "booking", "book_pay": "booking",
         "cancel_refund": "booking", "my_bookings": "booking"}
TARGETS = {"search": {"p95_ms": 300}, "booking": {"p95_ms": 800, "p99_ms": 1500}}
MAX_ERROR_RATE = 0.001          # 99.9 % answered without a 5xx (SLO.md); timeouts count as errors
MAX_RATE_LIMITED = 0.01         # a 429 is the generator sharing too few addresses, not the platform failing


def pick_journey(rng: random.Random) -> str:
    x, acc = rng.random(), 0.0
    for name, share in JOURNEYS:
        acc += share
        if x < acc:
            return name
    return JOURNEYS[-1][0]


class Recorder:
    def __init__(self, measure_from: float):
        self.measure_from = measure_from
        self.times: dict[str, list[float]] = {}
        self.errors: dict[str, int] = {}
        self.limited: dict[str, int] = {}

    async def call(self, step: str, request):
        t0 = time.perf_counter()
        try:
            r = await request
            ok, limited = r.status_code < 500, r.status_code == 429
        except httpx.HTTPError:
            r, ok, limited = None, False, False
        if t0 >= self.measure_from:
            self.times.setdefault(step, []).append((time.perf_counter() - t0) * 1000)
            if not ok:
                self.errors[step] = self.errors.get(step, 0) + 1
            if limited:
                self.limited[step] = self.limited.get(step, 0) + 1
        return r


async def _search_and_seat(rec: Recorder, c: httpx.AsyncClient, rng: random.Random):
    o, d = ROUTES[rng.randrange(len(ROUTES))]
    r = await rec.call("search", c.get("/api/trips/search", params={"origin": o, "destination": d, "on": day(1 + rng.randrange(5)),
                                                                      "passengers": 1}))
    trips = [t for t in (r.json().get("trips", []) if r is not None and r.status_code == 200 else []) if t.get("bookable")]
    if not trips:
        return None, None
    t = trips[rng.randrange(len(trips))]
    r = await rec.call("seat_map", c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]}))
    free = [s["seat_no"] for s in (r.json().get("seats", []) if r is not None and r.status_code == 200 else []) if s.get("free")]
    return t, (free[rng.randrange(len(free))] if free else None)


async def journey(name: str, rec: Recorder, anon: httpx.AsyncClient, signed: httpx.AsyncClient, rng: random.Random):
    if name == "mine":
        await rec.call("my_bookings", signed.get("/api/bookings"))
        return
    c = anon if name == "browse" else signed
    t, seat = await _search_and_seat(rec, c, rng)
    if name == "browse" or t is None or seat is None:
        return
    r = await rec.call("hold", c.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
                                                         "seat_nos": [seat]}))
    if r is None or r.status_code not in (200, 201):
        return
    token = r.json().get("hold_token")
    if name == "hold":
        await rec.call("release", c.delete(f"/api/holds/{token}"))
        return
    r = await rec.call("book_pay", c.post("/api/bookings", json={
        "hold_token": token, "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "fare_brand": "STANDARD",
        "idempotency_key": uuid.uuid4().hex,
        "passengers": [{"nationality": "SY", "first_name": "Load", "father_name": "Test", "grandfather_name": "Run",
                        "last_name": "User", "seat_no": seat, "id_type": "NATIONAL_ID", "id_last4": "1234"}]}))
    if r is not None and r.status_code == 201:
        await rec.call("cancel_refund", c.post(f"/api/bookings/{r.json()['booking_ref']}/cancel"))


async def person(i: int, rec: Recorder, anon: list, signed: list, start_at: float, until: float, think: float, seed: int):
    rng = random.Random(seed * 1_000_003 + i)
    await asyncio.sleep(max(0.0, start_at - time.perf_counter()))
    while time.perf_counter() < until:
        await journey(pick_journey(rng), rec, anon[i % len(anon)], signed[i % len(signed)], rng)
        await asyncio.sleep(min(rng.expovariate(1 / think), until - time.perf_counter()) if think > 0 else 0)


async def drive(base: str, users: int, accounts: int, ramp: float, seconds: float, think: float, seed: int) -> dict:
    limits = httpx.Limits(max_connections=200, max_keepalive_connections=200)
    anon = [httpx.AsyncClient(base_url=base, headers=headers(), timeout=30, limits=limits) for _ in range(max(1, users // 500))]
    signed = [await account(base) for _ in range(max(1, accounts))]
    for c in signed:     # sandbox top-up so the booking journey can pay from the wallet
        await c.post("/api/wallet/topup", json={"amount": 500000000, "idempotency_key": uuid.uuid4().hex})
    t0 = time.perf_counter()
    measure_from, until = t0 + ramp, t0 + ramp + seconds
    rec = Recorder(measure_from)
    try:
        await asyncio.gather(*(person(i, rec, anon, signed, t0 + ramp * i / max(1, users), until, think, seed)
                               for i in range(users)))
    finally:
        for c in anon + signed:
            await c.aclose()
    return {"times": rec.times, "errors": rec.errors, "limited": rec.limited}


def _worker(args: tuple) -> dict:
    return asyncio.run(drive(*args))


def summarise(parts: list[dict], users: int, seconds: float, think: float) -> dict:
    times: dict[str, list[float]] = {}
    errors: dict[str, int] = {}
    limited = 0
    for p in parts:
        limited += sum(p.get("limited", {}).values())
        for k, v in p["times"].items():
            times.setdefault(k, []).extend(v)
        for k, v in p["errors"].items():
            errors[k] = errors.get(k, 0) + v
    steps, total, failed = [], 0, 0
    for step, xs in sorted(times.items()):
        xs.sort()
        q = statistics.quantiles(xs, n=100, method="inclusive") if len(xs) > 1 else [xs[0]] * 99
        total += len(xs)
        failed += errors.get(step, 0)
        steps.append({"step": step, "group": GROUP.get(step, "other"), "requests": len(xs), "per_second": round(len(xs) / seconds, 1),
                      "p50_ms": round(q[49], 1), "p95_ms": round(q[94], 1), "p99_ms": round(q[98], 1), "errors": errors.get(step, 0)})
    breaches = []
    for s in steps:
        for metric, limit in TARGETS.get(s["group"], {}).items():
            if s[metric] > limit:
                breaches.append(f"{s['step']}: {metric} {s[metric]} ms > {limit} ms")
    error_rate = failed / total if total else 1.0
    if error_rate > MAX_ERROR_RATE:
        breaches.append(f"error rate {error_rate:.2%} > {MAX_ERROR_RATE:.0%}")
    if total and limited / total > MAX_RATE_LIMITED:
        breaches.append(f"rate limited {limited / total:.2%} > {MAX_RATE_LIMITED:.0%}: spread the generator over more addresses")
    if not total:
        breaches.append("no request measured")
    return {"users": users, "seconds_measured": seconds, "think_seconds": think, "requests": total,
            "requests_per_second": round(total / seconds, 1) if seconds else 0, "error_rate": round(error_rate, 5),
            "rate_limited": limited,
            "steps": steps, "targets": TARGETS, "breaches": breaches, "verdict": "PASS" if not breaches else "FAIL"}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="python -m loadtest.users")
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--users", type=int, default=10000)
    ap.add_argument("--workers", type=int, default=1)
    ap.add_argument("--accounts", type=int, default=200, help="signed-in accounts shared by the users who hold and book")
    ap.add_argument("--ramp", type=float, default=300)
    ap.add_argument("--seconds", type=float, default=900)
    ap.add_argument("--think", type=float, default=10)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    w = max(1, a.workers)
    shares = [a.users // w + (1 if k < a.users % w else 0) for k in range(w)]
    jobs = [(a.base, n, max(1, a.accounts // w), a.ramp, a.seconds, a.think, a.seed + k) for k, n in enumerate(shares) if n]
    if len(jobs) == 1:
        parts = [_worker(jobs[0])]
    else:
        with mp.get_context("spawn").Pool(len(jobs)) as pool:
            parts = pool.map(_worker, jobs)
    out = summarise(parts, a.users, a.seconds, a.think)
    print(f"{a.users} concurrent users, think {a.think}s, measured {a.seconds}s: {out['requests_per_second']} req/s, "
          f"errors {out['error_rate']:.3%}, verdict {out['verdict']}")
    print(f"{'step':14} {'group':8} {'req':>8} {'req/s':>8} {'p50':>8} {'p95':>8} {'p99':>8} {'err':>6}")
    for s in out["steps"]:
        print(f"{s['step']:14} {s['group']:8} {s['requests']:8} {s['per_second']:8} {s['p50_ms']:8} {s['p95_ms']:8} {s['p99_ms']:8} {s['errors']:6}")
    for b in out["breaches"]:
        print("breach:", b)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(out, fh, indent=1)
    return 0 if out["verdict"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
