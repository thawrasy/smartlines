"""Tests of the strategic database review and its relationship audit register that need the running API or the
API's own database role. The database-only rows are in db/tests/run_tests.sql (section 1040)."""
import asyncio
import os
import random
import uuid
from concurrent.futures import ThreadPoolExecutor

import asyncpg

from test_e2e import book, free_seats, hold, new_passenger, owner_sql, pax, trip  # noqa: F401, F811  (pax and trip are fixtures)


def test_a_pooled_connection_never_carries_a_company_into_the_next_request():
    """C-04: the request context is local to its transaction. One physical connection serves company A, then a
    request without a context, then company B, then a request that fails half way: nothing of A is ever seen after
    A's transaction ends."""
    a = owner_sql("SELECT company_id FROM fleet.vehicle GROUP BY company_id ORDER BY count(*) DESC LIMIT 1")
    b = owner_sql("SELECT id FROM iam.company WHERE id <> $1 ORDER BY id LIMIT 1", a)

    async def run():
        pool = await asyncpg.create_pool(os.environ["MASSLAK_DATABASE_URL"], min_size=1, max_size=1)
        try:
            async def request(company, fail=False):
                async with pool.acquire() as conn:
                    pid = await conn.fetchval("SELECT pg_backend_pid()")
                    try:
                        async with conn.transaction():
                            if company is not None:
                                await conn.execute("SELECT sys.set_context(NULL, $1, 'COMPANY')", company)
                            seen = {r[0] for r in await conn.fetch("SELECT DISTINCT company_id FROM fleet.vehicle")}
                            ctx = await conn.fetchval("SELECT current_setting('app.company_id', true)")
                            if fail:
                                await conn.execute("SELECT 1 / 0")
                            return pid, seen, ctx
                    except asyncpg.DivisionByZeroError:
                        return pid, None, None

            pid_a, seen_a, ctx_a = await request(a)
            pid_0, seen_0, ctx_0 = await request(None)
            pid_b, seen_b, _ = await request(b)
            pid_f, _, _ = await request(a, fail=True)
            pid_1, seen_1, ctx_1 = await request(None)
            assert len({pid_a, pid_0, pid_b, pid_f, pid_1}) == 1, "the test must reuse one physical connection"
            assert seen_a == {a} and ctx_a == str(a)
            assert seen_0 == set() and ctx_0 in ("", None)
            assert seen_b <= {b}
            assert seen_1 == set() and ctx_1 in ("", None)

            # many interleaved requests of both companies on two shared connections
            pool2 = await asyncpg.create_pool(os.environ["MASSLAK_DATABASE_URL"], min_size=2, max_size=2)
            try:
                async def one(company):
                    async with pool2.acquire() as conn:
                        async with conn.transaction():
                            await conn.execute("SELECT sys.set_context(NULL, $1, 'COMPANY')", company)
                            await asyncio.sleep(random.random() / 100)
                            return company, {r[0] for r in await conn.fetch("SELECT DISTINCT company_id FROM fleet.vehicle")}
                results = await asyncio.gather(*(one(random.choice((a, b))) for _ in range(200)))
                assert all(seen <= {company} for company, seen in results)
                assert any(seen == {a} for company, seen in results if company == a)
            finally:
                await pool2.close()
        finally:
            await pool.close()
    asyncio.run(run())


def _segments(t, a, b):
    return {"trip_uid": t["uid"], "from_seq": a, "to_seq": b}


def test_overlapping_segments_under_contention(trip):
    """M-04: many people want the same seat on overlapping parts of the trip at the same moment. Whatever wins,
    no segment is ever held twice, a whole-trip request never gets half a seat, and nothing fails with an error."""
    people = [new_passenger() for _ in range(36)]
    seat = free_seats(people[0], trip, 1)[0]
    pairs = [(0, 1), (1, 2), (0, 2)] * 12
    random.shuffle(pairs)

    def press(args):
        c, (a, b) = args
        return c, (a, b), c.post("/api/holds", json={**_segments(trip, a, b), "seat_nos": [seat]})

    with ThreadPoolExecutor(max_workers=36) as pool:
        results = list(pool.map(press, zip(people, pairs)))
    assert all(r.status_code in (201, 409) for _, _, r in results), [r.text for _, _, r in results if r.status_code not in (201, 409)]
    won = [(a, b) for _, (a, b), r in results if r.status_code == 201]
    held = [seg for a, b in won for seg in range(a, b)]
    assert won and len(held) == len(set(held)), won            # no segment held twice
    assert sorted(held) in ([0, 1], [0], [1]), won              # never more than the seat has
    locked = owner_sql("SELECT count(*) FROM ops.seat_segment s JOIN ops.trip t ON t.id = s.trip_id "
                       "WHERE t.uid = $1 AND s.seat_no = $2 AND s.status = 'LOCKED'", uuid.UUID(trip["uid"]), seat)
    assert locked == len(held)
    for c, _, r in results:
        if r.status_code == 201:
            c.delete(f"/api/holds/{r.json()['hold_token']}")


def test_multi_seat_holds_in_any_order_never_deadlock(trip):
    """Deadlock testing: people ask for the same seats in opposite orders. Rows are locked in one fixed order, so
    they queue instead of deadlocking; each seat ends with at most one holder."""
    people = [new_passenger() for _ in range(24)]
    seats = free_seats(people[0], trip, 3)
    asks = [random.sample(seats, 2) for _ in people]

    def press(args):
        c, wanted = args
        return c, wanted, c.post("/api/holds", json={**_segments(trip, trip["from_seq"], trip["to_seq"]), "seat_nos": wanted})

    with ThreadPoolExecutor(max_workers=24) as pool:
        results = list(pool.map(press, zip(people, asks)))
    assert all(r.status_code in (201, 409) for _, _, r in results), [r.text for _, _, r in results if r.status_code not in (201, 409)]
    won = [s for _, wanted, r in results if r.status_code == 201 for s in wanted]
    assert len(won) == len(set(won))
    for c, _, r in results:
        if r.status_code == 201:
            c.delete(f"/api/holds/{r.json()['hold_token']}")


def test_concurrent_wallet_bookings_stay_balanced(pax, trip):
    """Deadlock testing on the money path: one passenger books four times at once from one wallet. Every booking
    either succeeds or is refused cleanly, the wallet moves by exactly the confirmed totals, and the ledger
    reconciles."""
    before = pax.get("/api/wallet").json()["balance"]
    seats = free_seats(pax, trip, 4)
    tokens = [hold(pax, trip, [s]).json()["hold_token"] for s in seats]

    def pay(args):
        token, seat = args
        return book(pax, trip, token, [seat])

    with ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(pay, zip(tokens, seats)))
    assert all(r.status_code in (201, 402, 409) for r in results), [r.text for r in results]
    spent = sum(r.json()["total"] for r in results if r.status_code == 201)
    assert pax.get("/api/wallet").json()["balance"] == before - spent
    assert owner_sql("SELECT mismatches FROM fin.reconcile_wallets()") == 0
