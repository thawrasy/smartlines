"""Booking burst test (expert review of October 2026, stage B; launch gate 3).

Bookings arrive at a fixed rate, whether the server keeps up or not (an open loop: a closed loop of N users slows
down with the server and hides the overload). The capacity model sizes the launch peak at 240 bookings a second
(CAPACITY_MODEL.md, burst of three times the peak-hour average), so that is the default target. Each arrival is one
traveller on one of a few busy trips:

    seat map -> hold a seat (another seat if it was just taken) -> book and pay from the wallet -> some cancel for a refund

and the run checks what must stay true under the burst, through the owner's connection:

* no seat sold twice on overlapping segments, every ledger transaction of the run balanced, wallets reconciled;
* deadlocks, lock waits and WAL written (the probe of loadtest.run);
* latency per step against the SLOs (booking p95 <= 0.8 s, p99 <= 1.5 s), errors (5xx, 429, timeouts) within the
  99.9 % budget, and the rate actually achieved.

The verdict is PASS, FAIL or INCONCLUSIVE; the last when the load generator itself fell behind its schedule, which
means the machine running this script, not the platform, was the limit (run several generators then).

    python -m loadtest.burst --base http://localhost:8000 --owner-dsn postgresql://... --rate 240 --seconds 60 --json out.json

Needs a sandbox build (accounts are funded by sandbox top-ups) with sign-in limits raised for the accounts it creates
(MASSLAK_RATE_AUTH_PER_MINUTE, MASSLAK_RATE_API_PER_MINUTE). Numbers from a laptop or a CI runner are a smoke test; the
gate needs staging hardware with production-size data (LAUNCH_GATES.md, gate 3).
"""
from __future__ import annotations

import argparse
import asyncio
import json
import os
import platform
import random
import statistics
import sys
import time
import uuid
from datetime import datetime, timezone

import httpx

from .run import ROUTES, DbProbe, Stats, account, day

SLO = {"p95_ms": 800.0, "p99_ms": 1500.0, "error_budget": 0.001}
BOOKING_STEPS = ("hold", "book_pay")


class Burst:
    def __init__(self, args):
        self.args = args
        self.stats = Stats()
        self.outcomes = {"booked": 0, "refunded": 0, "seat_taken": 0, "sold_out": 0, "failed": 0, "dropped": 0}
        self.lateness: list[float] = []
        self.inflight = 0
        self.trips: list[dict] = []
        self.idle: asyncio.Queue = asyncio.Queue()           # travellers with no booking in progress
        self.started_at = datetime.now(timezone.utc)

    async def timed(self, step: str, call) -> httpx.Response | None:
        t0 = time.perf_counter()
        try:
            r = await call
            ok = r.status_code < 500 and r.status_code != 429
        except httpx.HTTPError:
            r, ok = None, False
        self.stats.add(step, (time.perf_counter() - t0) * 1000, ok)
        return r

    async def find_trips(self, c: httpx.AsyncClient) -> None:
        """The busiest trips: a few trips with the most free seats, so that travellers compete for seats."""
        found = []
        for offset in range(1, 8):
            for o, d in ROUTES:
                r = await c.get("/api/trips/search", params={"origin": o, "destination": d, "on": day(offset), "passengers": 1})
                if r.status_code == 200:
                    found += [t for t in r.json().get("trips", []) if t.get("bookable") and t.get("seats_left", 0) >= 10]
        found.sort(key=lambda t: -t["seats_left"])
        self.trips = found[: self.args.hot_trips]
        if not self.trips:
            raise SystemExit("no bookable trip with free seats: seed the demo data or generate volume first")

    async def arrival(self, c: httpx.AsyncClient) -> None:
        """One traveller's attempt; a traveller books one thing at a time, so it returns to the idle queue after."""
        self.inflight += 1
        try:
            t = random.choice(self.trips)
            span = {"from_seq": t["from_seq"], "to_seq": t["to_seq"]}
            seat = None
            for attempt in range(2):                         # a traveller whose seat was just taken picks another once
                r = await self.timed("seat_map", c.get(f"/api/trips/{t['uid']}", params=span))
                free = [s["seat_no"] for s in (r.json().get("seats", []) if r is not None and r.status_code == 200 else []) if s.get("free")]
                if not free:
                    self.outcomes["sold_out" if r is not None and r.status_code == 200 else "failed"] += 1
                    return
                seat = random.choice(free)
                r = await self.timed("hold", c.post("/api/holds", json={"trip_uid": t["uid"], **span, "seat_nos": [seat]}))
                if r is not None and r.status_code in (200, 201):
                    break
                if r is not None and r.status_code == 409 and attempt == 0:
                    self.outcomes["seat_taken"] += 1
                    continue
                self.outcomes["seat_taken" if r is not None and r.status_code == 409 else "failed"] += 1
                return
            r = await self.timed("book_pay", c.post("/api/bookings", json={
                "hold_token": r.json()["hold_token"], "trip_uid": t["uid"], **span, "fare_brand": "STANDARD",
                "idempotency_key": uuid.uuid4().hex,
                "passengers": [{"nationality": "SY", "first_name": "Burst", "father_name": "Test", "grandfather_name": "Run",
                                "last_name": "Traveller", "seat_no": seat, "id_type": "NATIONAL_ID", "id_last4": "1234"}]}))
            if r is None or r.status_code != 201:
                self.outcomes["failed"] += 1
                return
            self.outcomes["booked"] += 1
            if random.random() < self.args.cancel_ratio:
                r = await self.timed("cancel_refund", c.post(f"/api/bookings/{r.json()['booking_ref']}/cancel"))
                if r is not None and r.status_code == 200:
                    self.outcomes["refunded"] += 1
        finally:
            self.inflight -= 1
            self.idle.put_nowait(c)

    async def generate(self, clients: list[httpx.AsyncClient]) -> float:
        """Starts arrivals on schedule; returns the seconds the burst took, waiting for the last arrival to finish."""
        for c in clients:
            self.idle.put_nowait(c)
        loop = asyncio.get_running_loop()
        rate, total = self.args.rate, int(self.args.rate * self.args.seconds)
        t0 = loop.time()
        tasks = []
        for i in range(total):
            due = t0 + i / rate
            wait = due - loop.time()
            if wait > 0:
                await asyncio.sleep(wait)
            self.lateness.append(max(0.0, loop.time() - due) * 1000)
            if self.inflight >= self.args.max_inflight or self.idle.empty():
                self.outcomes["dropped"] += 1                 # the server is so far behind that waiting work piles up
                continue
            tasks.append(asyncio.create_task(self.arrival(self.idle.get_nowait())))
        await asyncio.gather(*tasks)
        return loop.time() - t0


async def integrity(dsn: str, since: datetime, trip_uids: list[str]) -> dict:
    """What must hold after the burst, read as the owner."""
    import asyncpg
    conn = await asyncpg.connect(dsn)
    try:
        double = await conn.fetchval(
            """SELECT count(*) FROM sales.ticket a JOIN sales.ticket b ON b.trip_id = a.trip_id AND b.seat_no = a.seat_no AND b.id > a.id
                 JOIN ops.trip t ON t.id = a.trip_id
                WHERE t.uid = ANY($1::uuid[]) AND a.status IN ('ISSUED','BOARDED','HOLD') AND b.status IN ('ISSUED','BOARDED','HOLD')
                  AND int4range(a.from_seq, a.to_seq) && int4range(b.from_seq, b.to_seq)""", trip_uids)
        unbalanced = await conn.fetchval(
            """SELECT count(*) FROM (SELECT txn_id FROM fin.ledger_entry WHERE created_at >= $1 GROUP BY txn_id
                                     HAVING sum(CASE direction WHEN 'DR' THEN amount ELSE -amount END) <> 0) x""", since)
        txns = await conn.fetchval("SELECT count(DISTINCT txn_id) FROM fin.ledger_entry WHERE created_at >= $1", since)
        recon = await conn.fetchrow("SELECT wallets, mismatches FROM fin.reconcile_wallets()")
        return {"double_sold_seats": int(double), "ledger_transactions": int(txns), "unbalanced_transactions": int(unbalanced),
                "wallets_reconciled": int(recon["wallets"]), "wallet_mismatches": int(recon["mismatches"])}
    finally:
        await conn.close()


def percentile(xs: list[float], q: int) -> float:
    if not xs:
        return 0.0
    if len(xs) == 1:
        return xs[0]
    return statistics.quantiles(sorted(xs), n=100, method="inclusive")[q - 1]


def verdict(report: dict) -> dict:
    reasons, inconclusive = [], []
    target, achieved = report["target_per_second"], report["achieved"]["arrivals_per_second"]
    if report["generator"]["start_lateness_p95_ms"] > 100 or report["outcomes"]["dropped"]:
        inconclusive.append("the load generator fell behind its schedule or dropped arrivals: run more generators")
    if achieved < 0.95 * target:
        reasons.append(f"arrivals reached {achieved}/s of the {target}/s target")
    for s in report["steps"]:
        if s["step"] in BOOKING_STEPS and (s["p95_ms"] > SLO["p95_ms"] or s["p99_ms"] > SLO["p99_ms"]):
            reasons.append(f"{s['step']} p95 {s['p95_ms']} ms / p99 {s['p99_ms']} ms over the SLO (800 / 1500 ms)")
    requests = sum(s["requests"] for s in report["steps"])
    errors = sum(s["errors"] for s in report["steps"])
    if requests and errors / requests > SLO["error_budget"]:
        reasons.append(f"{errors} of {requests} requests failed (5xx, 429 or timeout), over the 0.1 % budget")
    integ = report.get("integrity")
    if not integ:
        inconclusive.append("no owner connection: seat, ledger and wallet checks were not made")
    else:
        if integ["double_sold_seats"]:
            reasons.append(f"{integ['double_sold_seats']} seats sold twice")
        if integ["unbalanced_transactions"] or integ["wallet_mismatches"]:
            reasons.append("ledger or wallets out of balance")
    db = report.get("database") or {}
    if db.get("deadlocks"):
        reasons.append(f"{db['deadlocks']} deadlocks")
    status = "FAIL" if reasons else ("INCONCLUSIVE" if inconclusive else "PASS")
    return {"status": status, "reasons": reasons, "notes": inconclusive}


async def main(args) -> int:
    n = args.accounts or max(200, int(args.rate * 4))     # enough travellers that none has two bookings at once
    gate = asyncio.Semaphore(16)                         # sign-ups hash passwords (Argon2, 64 MiB each): a few at a time

    async def traveller() -> httpx.AsyncClient:
        async with gate:
            c = await account(args.base)
            (await c.post("/api/wallet/topup", json={"amount": 500_000_000, "idempotency_key": uuid.uuid4().hex})).raise_for_status()
            return c
    clients = list(await asyncio.gather(*(traveller() for _ in range(n))))
    burst = Burst(args)
    probe = DbProbe(args.owner_dsn)
    try:
        await burst.find_trips(clients[0])
        before = None
        if args.owner_dsn:
            import asyncpg
            probe.conn = await asyncpg.connect(args.owner_dsn)
            before = await probe.snapshot()
        since = datetime.now(timezone.utc)
        # lock waits are sampled over the scheduled burst (the sampler stops on its own; cancelling it mid-query would
        # leave its connection unusable for the final snapshot)
        sampler = asyncio.create_task(probe.sample(time.perf_counter() + args.seconds)) if probe.conn else None
        elapsed = await burst.generate(clients)
        if sampler:
            await sampler
        report = {
            "environment": args.environment, "tool": "backend/loadtest/burst.py", "date": since.date().isoformat(), "base": args.base,
            "host": {"name": platform.node(), "cpus": os.cpu_count(), "python": platform.python_version()},
            "target_per_second": args.rate, "seconds": args.seconds, "hot_trips": len(burst.trips),
            "cancel_ratio": args.cancel_ratio, "accounts": n,
            "achieved": {"arrivals_per_second": round(int(args.rate * args.seconds) / max(elapsed, 1e-9), 1),
                         "bookings_per_second": round(burst.outcomes["booked"] / max(elapsed, 1e-9), 1),
                         "elapsed_s": round(elapsed, 1)},
            "outcomes": burst.outcomes,
            "generator": {"start_lateness_p95_ms": round(percentile(burst.lateness, 95), 1),
                          "start_lateness_max_ms": round(max(burst.lateness, default=0.0), 1)},
            "steps": burst.stats.table(elapsed),
            "slo": SLO,
        }
        if before is not None:
            report["database"] = DbProbe.diff(before, await probe.snapshot(), elapsed, probe.samples)
            report["integrity"] = await integrity(args.owner_dsn, since, [t["uid"] for t in burst.trips])
        report["verdict"] = verdict(report)
    finally:
        for c in clients:
            await c.aclose()
        if probe.conn:
            await probe.conn.close()
    print(json.dumps({k: report[k] for k in ("achieved", "outcomes", "generator", "verdict")}, indent=1))
    for s in report["steps"]:
        print(f"{s['step']:14} {s['requests']:7} {s['per_second']:7}/s  p95 {s['p95_ms']:8} ms  p99 {s['p99_ms']:8} ms  errors {s['errors']}")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(report, fh, indent=1, default=str)
    return {"PASS": 0, "INCONCLUSIVE": 2}.get(report["verdict"]["status"], 1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(prog="python -m loadtest.burst")
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--rate", type=float, default=240.0, help="bookings started per second (launch peak burst: 240)")
    ap.add_argument("--seconds", type=int, default=60)
    ap.add_argument("--accounts", type=int, default=0, help="travellers (default: four seconds of arrivals, at least 200)")
    ap.add_argument("--hot-trips", type=int, default=4, help="trips the travellers compete for")
    ap.add_argument("--cancel-ratio", type=float, default=1.0,
                    help="share of bookings cancelled for a refund at once (1.0 keeps the seats available on small data)")
    ap.add_argument("--max-inflight", type=int, default=5000)
    ap.add_argument("--owner-dsn", help="owner connection: database counters and the seat, ledger and wallet checks")
    ap.add_argument("--environment", choices=["development", "staging", "production"], default="development",
                    help="where it ran; only staging evidence counts for launch gate 3 (db/tools/launch_gates.py)")
    ap.add_argument("--json")
    sys.exit(asyncio.run(main(ap.parse_args())))
