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

What the report separates (reviews of release 1.49.0): a warm-up at the same rate whose requests are not counted
(--warmup-seconds); the rate at which arrivals started and the rate at which bookings completed, the seconds the server
took to finish the last ones after the schedule ended (drain), and the most arrivals in progress at once. Arrivals go to
--trips trips, the busiest tenth of them taking --hot-share of the arrivals, the next three tenths half the rest, the
others what remains, as demand spreads over a timetable; --trips 4 keeps the contention test of the development runs.
Accounts are made and funded before the burst; --save-accounts keeps their sessions for the next run and
--accounts-file uses them, so repeated runs on one dataset do not sign up again. The report records the build (commit
and images from RELEASE and IMAGES), the release the database runs and whether its schema matches (with --owner-dsn),
the host, the dataset and the workload, so a result can be tied to what was measured.

    python -m loadtest.burst --base http://localhost:8000 --owner-dsn postgresql://... --rate 240 --seconds 60 --json out.json
    python -m loadtest.burst ... --environment staging --rate 240 --warmup-seconds 600 --seconds 3600 --trips 128 --cancel-ratio 0.1

Needs a sandbox build (accounts are funded by sandbox top-ups) with sign-in limits raised for the accounts it creates
(MASSLAK_RATE_AUTH_PER_MINUTE, MASSLAK_RATE_AUTH_IP_PER_MINUTE, MASSLAK_RATE_API_PER_MINUTE). Numbers from a laptop or a CI runner are a smoke test; the
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
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

import httpx

from .run import ROUTES, DbProbe, Stats, account, day, headers

ROOT = Path(__file__).resolve().parents[2]

SLO = {"p95_ms": 800.0, "p99_ms": 1500.0, "error_budget": 0.001}
BOOKING_STEPS = ("hold", "book_pay")


def trip_weights(n: int, hot_share: float) -> list[float]:
    """Each trip's share of the arrivals: the busiest tenth (at least one trip) takes hot_share, the next three tenths
    half of the rest, the others what remains; with fewer than three trips every trip takes the same share."""
    if n < 3:
        return [1.0] * n
    hot = max(1, round(n * 0.1))
    warm = max(1, round(n * 0.3))
    cold = max(0, n - hot - warm)
    rest = 1.0 - hot_share
    shares = [hot_share / hot] * hot + [(rest / 2 if cold else rest) / warm] * warm
    return shares + [rest / 2 / cold] * cold if cold else shares


class Burst:
    def __init__(self, args):
        self.args = args
        self.stats = Stats()
        self.outcomes = {"booked": 0, "refunded": 0, "seat_taken": 0, "sold_out": 0, "failed": 0, "dropped": 0}
        self.lateness: list[float] = []
        self.inflight = self.inflight_max = 0
        self.trips: list[dict] = []
        self.weights: list[float] = []
        self.idle: asyncio.Queue = asyncio.Queue()           # travellers with no booking in progress
        self.started_at = datetime.now(timezone.utc)
        self.window = {"from": 0.0, "to": 0.0, "first_start": None, "last_start": 0.0, "last_done": 0.0}

    async def timed(self, step: str, call, measured: bool = True) -> httpx.Response | None:
        t0 = time.perf_counter()
        try:
            r = await call
            ok = r.status_code < 500 and r.status_code != 429
        except httpx.HTTPError:
            r, ok = None, False
        if measured:                                          # the warm-up's requests are not counted
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
        self.trips = found[: self.args.trips]
        if not self.trips:
            raise SystemExit("no bookable trip with free seats: seed the demo data or generate volume first")
        self.weights = trip_weights(len(self.trips), self.args.hot_share)

    async def arrival(self, c: httpx.AsyncClient, measured: bool = True) -> None:
        """One traveller's attempt; a traveller books one thing at a time, so it returns to the idle queue after."""
        self.inflight += 1
        self.inflight_max = max(self.inflight_max, self.inflight)
        seen: list[str] = []                                  # outcomes of this attempt, counted when it is measured
        try:
            t = random.choices(self.trips, weights=self.weights)[0]
            span = {"from_seq": t["from_seq"], "to_seq": t["to_seq"]}
            seat = None
            for attempt in range(2):                         # a traveller whose seat was just taken picks another once
                r = await self.timed("seat_map", c.get(f"/api/trips/{t['uid']}", params=span), measured)
                free = [s["seat_no"] for s in (r.json().get("seats", []) if r is not None and r.status_code == 200 else []) if s.get("free")]
                if not free:
                    seen.append("sold_out" if r is not None and r.status_code == 200 else "failed")
                    return
                seat = random.choice(free)
                r = await self.timed("hold", c.post("/api/holds", json={"trip_uid": t["uid"], **span, "seat_nos": [seat]}), measured)
                if r is not None and r.status_code in (200, 201):
                    break
                if r is not None and r.status_code == 409 and attempt == 0:
                    seen.append("seat_taken")
                    continue
                seen.append("seat_taken" if r is not None and r.status_code == 409 else "failed")
                return
            r = await self.timed("book_pay", c.post("/api/bookings", json={
                "hold_token": r.json()["hold_token"], "trip_uid": t["uid"], **span, "fare_brand": "STANDARD",
                "idempotency_key": uuid.uuid4().hex,
                "passengers": [{"nationality": "SY", "first_name": "Burst", "father_name": "Test", "grandfather_name": "Run",
                                "last_name": "Traveller", "seat_no": seat, "id_type": "NATIONAL_ID", "id_last4": "1234"}]}), measured)
            if r is None or r.status_code != 201:
                seen.append("failed")
                return
            seen.append("booked")
            if random.random() < self.args.cancel_ratio:
                r = await self.timed("cancel_refund", c.post(f"/api/bookings/{r.json()['booking_ref']}/cancel"), measured)
                if r is not None and r.status_code == 200:
                    seen.append("refunded")
        finally:
            self.inflight -= 1
            self.idle.put_nowait(c)
            if measured:
                for o in seen:
                    self.outcomes[o] += 1
                self.window["last_done"] = asyncio.get_running_loop().time()

    async def generate(self, clients: list[httpx.AsyncClient]) -> float:
        """Starts arrivals on schedule, the warm-up first; returns the seconds the measured window took, waiting for
        its last arrival to finish."""
        for c in clients:
            self.idle.put_nowait(c)
        loop = asyncio.get_running_loop()
        rate = self.args.rate
        warm = int(rate * self.args.warmup_seconds)
        total = warm + int(rate * self.args.seconds)
        t0 = loop.time()
        self.window["from"], self.window["to"] = t0 + warm / rate, t0 + total / rate
        tasks = []
        for i in range(total):
            due = t0 + i / rate
            wait = due - loop.time()
            if wait > 0:
                await asyncio.sleep(wait)
            measured = i >= warm
            now = loop.time()
            if measured:
                self.lateness.append(max(0.0, now - due) * 1000)
            if self.inflight >= self.args.max_inflight or self.idle.empty():
                if measured:
                    self.outcomes["dropped"] += 1             # the server is so far behind that waiting work piles up
                continue
            if measured:
                self.window["first_start"] = self.window["first_start"] or now
                self.window["last_start"] = now
            tasks.append(asyncio.create_task(self.arrival(self.idle.get_nowait(), measured)))
        await asyncio.gather(*tasks)
        return loop.time() - self.window["from"]

    def rates(self, elapsed: float) -> dict:
        """Arrivals started against bookings completed in the measured window, and how long the server took to drain."""
        scheduled = int(self.args.rate * self.args.seconds)
        started = scheduled - self.outcomes["dropped"]
        w = self.window
        start_span = max((w["last_start"] - w["first_start"]) if w["first_start"] else 0.0, 1e-9)
        done_span = max(w["last_done"] - w["from"], 1e-9)
        start_rate = round(started / max(start_span + 1 / self.args.rate, 1e-9), 1) if started else 0.0
        return {"arrivals_scheduled": scheduled, "arrivals_started": started, "arrivals_dropped": self.outcomes["dropped"],
                "arrival_start_rate_per_second": start_rate, "arrivals_per_second": start_rate,
                "bookings_succeeded": self.outcomes["booked"],
                "bookings_completed_per_second": round(self.outcomes["booked"] / done_span, 1),
                "bookings_per_second": round(self.outcomes["booked"] / done_span, 1),
                "drain_seconds": round(max(0.0, w["last_done"] - w["to"]), 1), "inflight_max": self.inflight_max,
                "elapsed_s": round(elapsed, 1)}


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
    a = report["achieved"]                                 # reports before release 1.50.0 have arrivals_per_second only
    target, achieved = report["target_per_second"], a.get("arrival_start_rate_per_second", a.get("arrivals_per_second", 0.0))
    if report["generator"]["start_lateness_p95_ms"] > 100 or report["outcomes"]["dropped"]:
        inconclusive.append("the load generator fell behind its schedule or dropped arrivals: run more generators")
    if achieved < 0.95 * target:
        reasons.append(f"arrivals reached {achieved}/s of the {target}/s target")
    drain = report["achieved"].get("drain_seconds", 0.0)
    if drain > max(5.0, 0.05 * report.get("seconds", 0)):
        reasons.append(f"the server took {drain} s after the schedule ended to finish the arrivals it had started")
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
    release = report.get("release")
    if integ and release is not None and release.get("hash_matches") is False:
        inconclusive.append("the database schema does not match its release manifest: the build measured is unknown")
    status = "FAIL" if reasons else ("INCONCLUSIVE" if inconclusive else "PASS")
    return {"status": status, "reasons": reasons, "notes": inconclusive}


def build() -> dict:
    """The build that ran: the commit and images of an installed release (RELEASE and IMAGES at the root, written by
    the release build), else the working tree's commit."""
    out: dict = {"commit": None, "version": None, "images": None, "source": None}
    release = ROOT / "RELEASE"
    if release.is_file():
        for line in release.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition("=")
            if key.strip().lower() in ("commit", "version"):
                out[key.strip().lower()] = value.strip()
        out["source"] = "RELEASE"
    images = ROOT / "IMAGES"                              # commit=, version= and NAME=REGISTRY/NAME@sha256:...
    if images.is_file():
        pairs = dict(line.strip().partition("=")[::2] for line in images.read_text(encoding="utf-8").splitlines() if "=" in line)
        out["images"] = {k: v for k, v in pairs.items() if k not in ("commit", "version")}
        out["images_commit"] = pairs.get("commit")
    if not out["commit"]:
        try:
            out["commit"] = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True,
                                           check=True).stdout.strip()
            dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--untracked-files=no"],
                                   capture_output=True, text=True, check=True).stdout.strip()
            out["source"], out["uncommitted_changes"] = "git", bool(dirty)
        except (OSError, subprocess.CalledProcessError):
            pass
    return out


def host() -> dict:
    """The machine the generator ran on (the server's own is in the release's monitoring)."""
    memory = None
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                memory = round(int(line.split()[1]) / 1024 / 1024, 1)
    except (OSError, ValueError, IndexError):
        pass
    return {"name": platform.node(), "cpus": os.cpu_count(), "memory_gib": memory, "python": platform.python_version()}


async def database_facts(dsn: str) -> dict:
    """The release the database runs (sys.current_release, 1058: hash_matches says whether its schema is the release's) and the size of the data the burst ran on."""
    import asyncpg
    conn = await asyncpg.connect(dsn)
    try:
        release = await conn.fetchrow("SELECT * FROM sys.current_release()")
        counts = await conn.fetchrow(
            """SELECT (SELECT count(*) FROM ops.trip) AS trips, (SELECT count(*) FROM sales.ticket) AS tickets,
                      (SELECT count(*) FROM sales.booking) AS bookings, (SELECT count(*) FROM iam.app_user) AS accounts,
                      pg_database_size(current_database()) AS database_bytes""")
        return {"release": dict(release) if release else None, "dataset": dict(counts)}
    except asyncpg.PostgresError as e:                 # an older schema: the result says what could not be read
        return {"release": None, "dataset": None, "error": f"{type(e).__name__}: {e}"}
    finally:
        await conn.close()


async def travellers(args, n: int) -> tuple[list[httpx.AsyncClient], int]:
    """n signed-in, funded travellers: the sessions of --accounts-file that still work, then new accounts for the rest.
    Returns the clients and how many were reused."""
    gate = asyncio.Semaphore(16)                         # sign-ups hash passwords (Argon2, 64 MiB each): a few at a time
    reused: list[httpx.AsyncClient] = []
    if args.accounts_file and Path(args.accounts_file).is_file():
        saved = json.loads(Path(args.accounts_file).read_text(encoding="utf-8"))

        async def resume(entry: dict) -> httpx.AsyncClient | None:
            c = httpx.AsyncClient(base_url=args.base, headers={**headers(), "X-Forwarded-For": entry["address"]}, timeout=30)
            c.cookies.update(entry["cookies"])
            try:
                if (await c.get("/api/auth/me")).status_code == 200:
                    return c
            except httpx.HTTPError:
                pass
            await c.aclose()
            return None
        found = await asyncio.gather(*(resume(e) for e in saved.get("accounts", [])[:n]))
        reused = [c for c in found if c is not None]

    async def new() -> httpx.AsyncClient:
        async with gate:
            return await account(args.base)
    created = list(await asyncio.gather(*(new() for _ in range(n - len(reused)))))
    clients = reused + created

    async def fund(c: httpx.AsyncClient) -> None:
        async with gate:
            (await c.post("/api/wallet/topup", json={"amount": 500_000_000, "idempotency_key": uuid.uuid4().hex})).raise_for_status()
    await asyncio.gather(*(fund(c) for c in clients))
    if args.save_accounts:
        # session cookies of sandbox test accounts: readable by the owner only, and they expire with the sessions
        path = Path(args.save_accounts)
        path.touch(mode=0o600, exist_ok=True)
        path.chmod(0o600)
        path.write_text(json.dumps({"base": args.base, "saved_at": datetime.now(timezone.utc).isoformat(), "accounts": [
            {"address": c.headers["X-Forwarded-For"], "cookies": dict(c.cookies)} for c in clients]}), encoding="utf-8")
    return clients, len(reused)


async def main(args) -> int:
    if args.cancel_ratio is None:                        # small development data runs out of seats without refunds
        args.cancel_ratio = 1.0 if args.environment == "development" else 0.1
    n = args.accounts or max(200, int(args.rate * 4))     # enough travellers that none has two bookings at once
    clients, reused = await travellers(args, n)
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
        sampler = asyncio.create_task(probe.sample(time.perf_counter() + args.warmup_seconds + args.seconds)) if probe.conn else None
        elapsed = await burst.generate(clients)
        if sampler:
            await sampler
        report = {
            "environment": args.environment, "tool": "backend/loadtest/burst.py", "date": since.date().isoformat(), "base": args.base,
            "build": build(), "host": host(),
            "target_per_second": args.rate, "seconds": args.seconds, "warmup_seconds": args.warmup_seconds,
            "hot_trips": len(burst.trips),
            "workload": {"trips": len(burst.trips), "hot_share": args.hot_share if len(burst.trips) >= 3 else None,
                         "trip_weights": [round(w, 4) for w in burst.weights[:12]], "cancel_ratio": args.cancel_ratio,
                         "accounts": n, "accounts_reused": reused, "max_inflight": args.max_inflight},
            "cancel_ratio": args.cancel_ratio, "accounts": n,
            "achieved": burst.rates(elapsed),
            "outcomes": burst.outcomes,
            "generator": {"start_lateness_p95_ms": round(percentile(burst.lateness, 95), 1),
                          "start_lateness_max_ms": round(max(burst.lateness, default=0.0), 1)},
            "steps": burst.stats.table(elapsed),
            "slo": SLO,
        }
        if before is not None:
            report["database"] = DbProbe.diff(before, await probe.snapshot(), elapsed, probe.samples)
            report["integrity"] = await integrity(args.owner_dsn, since, [t["uid"] for t in burst.trips])
            report.update(await database_facts(args.owner_dsn))
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
    ap.add_argument("--seconds", type=int, default=60, help="the measured window")
    ap.add_argument("--warmup-seconds", type=int, default=0,
                    help="arrivals at the same rate before the measured window, not counted (caches, pools, plans)")
    ap.add_argument("--accounts", type=int, default=0, help="travellers (default: four seconds of arrivals, at least 200)")
    ap.add_argument("--trips", "--hot-trips", dest="trips", type=int, default=4,
                    help="trips the travellers book, the busiest first (4: the contention test; a timetable: 100 or more)")
    ap.add_argument("--hot-share", type=float, default=0.7,
                    help="share of the arrivals on the busiest tenth of the trips (with three trips or more)")
    ap.add_argument("--cancel-ratio", type=float, default=None,
                    help="share of bookings cancelled for a refund at once (default 1.0 in development, which keeps "
                         "the seats of small data available, else 0.1)")
    ap.add_argument("--accounts-file", help="sessions saved by an earlier run (--save-accounts): reused while they work")
    ap.add_argument("--save-accounts", help="file to keep the travellers' sessions in, for the next run (mode 0600)")
    ap.add_argument("--max-inflight", type=int, default=5000)
    ap.add_argument("--owner-dsn", help="owner connection: database counters and the seat, ledger and wallet checks")
    ap.add_argument("--environment", choices=["development", "staging", "production"], default="development",
                    help="where it ran; only staging evidence counts for launch gate 3 (db/tools/launch_gates.py)")
    ap.add_argument("--json")
    sys.exit(asyncio.run(main(ap.parse_args())))
