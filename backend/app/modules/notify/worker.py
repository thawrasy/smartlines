"""Outbox worker: python -m app.modules.notify.worker [--once]

Also sends scheduled reports (app.modules.reports.scheduler) and expires unpaid payment requests once a minute when no
event is waiting.

Claims up to MASSLAK_OUTBOX_BATCH pending events at a time (FOR UPDATE SKIP LOCKED, so several workers can run; the
capacity model plans for about eight million events a day), records an in-app notification per recipient and sends
email or SMS. Each event runs in its own savepoint: a failure rolls back that event only and retries it later with
exponential backoff; after MAX_ATTEMPTS it is marked FAILED for operators to inspect. Events are addressed by their
identity in the daily partitions, (id, created_at).
"""
import asyncio
import json
import logging
import os
import sys
import uuid

from ... import db, logredact, logs
from . import catalog, providers
from .render import mask, render

log = logging.getLogger("masslak.notify")
MAX_ATTEMPTS = 8
BATCH = int(os.environ.get("MASSLAK_OUTBOX_BATCH", "50"))


def _ctx() -> db.Context:
    return db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")


async def _deliver(conn, event, payload) -> int:
    sent = 0
    for d in await catalog.deliveries(conn, event, payload):
        for channel in d.channels:
            address = d.email if channel == "EMAIL" else d.mobile if channel == "SMS" else None
            if channel != "IN_APP" and (not address or not providers.enabled(channel)):
                continue
            row = await conn.fetchval(
                """INSERT INTO crm.notification (user_id, party_id, template_code, channel, to_address, payload, booking_id,
                     status, event_uid, sent_at)
                   VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, CASE WHEN $4 = 'IN_APP' THEN now() END)
                   ON CONFLICT DO NOTHING RETURNING id""",
                d.user_id, d.party_id, d.template, channel, mask(address) if address else None,
                json.dumps(d.values, default=str), d.booking_id, "SENT" if channel == "IN_APP" else "QUEUED", event["event_uid"])
            if row is None or channel == "IN_APP":
                sent += row is not None
                continue
            subject, body = render(d.template, channel, d.locale, d.values)
            if channel == "EMAIL":
                await asyncio.to_thread(providers.send_email, address, subject, body)
            else:
                await asyncio.to_thread(providers.send_sms, address, body)
            await conn.execute("UPDATE crm.notification SET status = 'SENT', sent_at = now(), attempts = attempts + 1 WHERE id = $1", row)
            sent += 1
    return sent


async def run_once(batch: int = BATCH) -> bool:
    """Processes a batch of due events in one transaction. Returns False when nothing is waiting."""
    from ..integration.webhooks import fanout
    async with db.transaction(_ctx()) as conn:
        events = await conn.fetch(
            """SELECT * FROM sys.outbox_event WHERE status = 'PENDING' AND next_attempt_at <= now()
                ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED""", batch)
        if not events:
            return False
        for event in events:
            payload = json.loads(event["payload"]) if isinstance(event["payload"], str) else event["payload"]
            # the event's logs and deliveries carry the trace of the request that wrote it (app/logs.py)
            logs.trace_id.set(event["correlation_id"].hex if event["correlation_id"] else None)
            try:
                async with conn.transaction():          # a savepoint: one event's failure leaves the others
                    n = await _deliver(conn, event, payload)
                    n += await fanout(conn, event, payload)
                    await conn.execute(
                        "UPDATE sys.outbox_event SET status = 'PUBLISHED', published_at = now(), attempts = attempts + 1 "
                        "WHERE id = $1 AND created_at = $2", event["id"], event["created_at"])
                log.info("notify.published event=%s type=%s deliveries=%s", event["event_uid"], event["event_type"], n)
            except Exception as exc:
                # the event's work rolled back (including any in-app rows); record the failure and back off
                log.warning("notify.failed event_id=%s: %s", event["id"], exc)
                await conn.execute(
                    """UPDATE sys.outbox_event SET attempts = attempts + 1, last_error = left($3, 500),
                         status = CASE WHEN attempts + 1 >= $4 THEN 'FAILED' ELSE 'PENDING' END,
                         next_attempt_at = now() + make_interval(mins => power(2, least(attempts, 10))::int)
                        WHERE id = $1 AND created_at = $2""", event["id"], event["created_at"], str(exc), MAX_ATTEMPTS)
    return True


async def maintenance() -> dict:
    """Daily database upkeep (sys.run_maintenance): partitions ahead, tracking retention, expired seat holds and the
    reconciliation of every wallet balance with its ledger entries."""
    async with db.transaction(_ctx()) as conn:
        out = json.loads(await conn.fetchval("SELECT sys.run_maintenance()::text"))
        keep = await conn.fetchrow("SELECT * FROM ops.position_retention()")
    # positions in the telemetry database (review stage D2): partitions ahead, the primary's retention and legal holds
    from ... import telemetry
    if telemetry.enabled():
        out["telemetry"] = await telemetry.upkeep(keep["keep_days"], keep["held"])
    if out.get("wallet_mismatches"):
        log.error("ledger reconciliation found %s wallet(s) out of balance", out["wallet_mismatches"])
    else:
        log.info("maintenance done: %s", out)
    return out


async def main(once: bool) -> None:
    logredact.install()                   # the worker's logs lose personal data and secrets too, like the API's
    logs.configure("worker")
    from ... import egress
    from ... import profile
    from ...security import require_keys_in_production
    egress.require_in_production()
    require_keys_in_production()
    profile.require_in_production()       # the production profile, as for the API (package 2, H-05, H-06)
    providers.require_in_production()     # no personal data in plain message logs outside the sandbox (R-27)
    for channel in ("EMAIL", "SMS", "WHATSAPP"):
        if not providers.enabled(channel):
            log.warning("%s delivery is off on this server: only in-app notifications are kept", channel.lower())
    await db.open_pools()
    await db.require_reports_replica()       # scheduled reports read the replica, never the booking database
    last_reports = 0.0
    last_rollup = 0.0
    last_maintenance = None if not once else 0.0     # a long-running worker maintains at start, then daily
    try:
        while True:
            busy = await run_once()
            # entries of shared (DEFERRED) wallets are folded into their stored balances (CAPACITY_MODEL.md)
            if once or asyncio.get_running_loop().time() - last_rollup > 5:
                async with db.transaction(_ctx()) as conn:
                    await conn.execute("SELECT fin.roll_up_balances()")
                last_rollup = asyncio.get_running_loop().time()
            if not busy:
                # manifests waiting for a push become webhook notices (outbox events), sent on the next pass
                from ..manifests.service import push_due
                async with db.transaction(_ctx()) as conn:
                    if await push_due(conn):
                        continue
                from ..integration.webhooks import deliver_due
                # a single pass (--once, used by cron and tests) sends everything due, not just one batch
                while await deliver_due() >= 20 and once:
                    pass
                # scheduled reports are checked once a minute, between events
                if once or asyncio.get_running_loop().time() - last_reports > 60:
                    from ..reports.scheduler import run_due
                    await run_due()
                    from ..payments.service import expire_stale, resend_refunds
                    async with db.transaction(_ctx()) as conn:
                        await expire_stale(conn)
                        # reservations not paid by their time give their seats back (1056)
                        await conn.execute("SELECT sales.expire_reservations()")
                        # parcel prices offered and not taken in time lapse (1078)
                        await conn.execute("SELECT ship.expire_parcel_offers()")
                    # refunds whose provider outcome is unknown are asked again, with the same reference (R-17)
                    await resend_refunds()
                    # positions the telemetry database could not take when they arrived (R-03)
                    from ... import telemetry
                    await telemetry.drain_backlog()
                    # files still in quarantine get another scan; expired break-glass access is closed (audit T3)
                    from ..documents.scanner import scan_pending
                    await scan_pending()
                    async with db.transaction(_ctx()) as conn:
                        await conn.execute("SELECT sec.break_glass_upkeep()")
                        # the proxy's allowlist follows the partner endpoints and providers (T3-02)
                        if os.environ.get("MASSLAK_EGRESS_LISTS"):
                            await egress.write_allowlists(conn, os.environ["MASSLAK_EGRESS_LISTS"])
                    last_reports = asyncio.get_running_loop().time()
                now = asyncio.get_running_loop().time()
                if not once and (last_maintenance is None or now - last_maintenance > 24 * 3600):
                    await maintenance()
                    last_maintenance = now
                if once:
                    return
                await asyncio.sleep(2)
    finally:
        await db.close_pools()


async def maintenance_once() -> None:
    logredact.install()
    logs.configure("worker")
    await db.open_pools()
    try:
        await maintenance()
    finally:
        await db.close_pools()


if __name__ == "__main__":
    # --maintenance: run the daily upkeep once and exit (for cron); --once: one pass of events and jobs
    asyncio.run(maintenance_once() if "--maintenance" in sys.argv else main("--once" in sys.argv))
