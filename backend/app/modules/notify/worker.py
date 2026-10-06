"""Outbox worker: python -m app.modules.notify.worker [--once]

Also sends scheduled reports (app.modules.reports.scheduler) and expires unpaid payment requests once a minute when no
event is waiting.

Claims one pending event at a time (FOR UPDATE SKIP LOCKED, so several workers can run), records an in-app
notification per recipient and sends email or SMS. A failure rolls the event back and retries it later with
exponential backoff; after MAX_ATTEMPTS it is marked FAILED for operators to inspect.
"""
import asyncio
import json
import logging
import sys
import uuid

from ... import db
from . import catalog, providers
from .render import mask, render

log = logging.getLogger("masslak.notify")
MAX_ATTEMPTS = 8


def _ctx() -> db.Context:
    return db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")


async def _deliver(conn, event, payload) -> int:
    sent = 0
    for d in await catalog.deliveries(conn, event, payload):
        for channel in d.channels:
            address = d.email if channel == "EMAIL" else d.mobile if channel == "SMS" else None
            if channel != "IN_APP" and not address:
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


async def run_once() -> bool:
    """Processes one event. Returns False when nothing is waiting."""
    event_id = None
    try:
        async with db.transaction(_ctx()) as conn:
            event = await conn.fetchrow(
                """SELECT * FROM sys.outbox_event WHERE status = 'PENDING' AND next_attempt_at <= now()
                    ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED""")
            if event is None:
                return False
            event_id = event["id"]
            payload = json.loads(event["payload"]) if isinstance(event["payload"], str) else event["payload"]
            n = await _deliver(conn, event, payload)
            from ..integration.webhooks import fanout
            n += await fanout(conn, event, payload)
            await conn.execute("UPDATE sys.outbox_event SET status = 'PUBLISHED', published_at = now(), attempts = attempts + 1 WHERE id = $1",
                               event_id)
            log.info("notify.published event=%s type=%s deliveries=%s", event["event_uid"], event["event_type"], n)
            return True
    except Exception as exc:
        if event_id is None:
            raise
        # The event's transaction rolled back (including any in-app rows); record the failure and back off
        log.warning("notify.failed event_id=%s: %s", event_id, exc)
        async with db.transaction(_ctx()) as conn:
            await conn.execute(
                """UPDATE sys.outbox_event SET attempts = attempts + 1, last_error = left($2, 500),
                     status = CASE WHEN attempts + 1 >= $3 THEN 'FAILED' ELSE 'PENDING' END,
                     next_attempt_at = now() + make_interval(mins => power(2, least(attempts, 10))::int)
                    WHERE id = $1""", event_id, str(exc), MAX_ATTEMPTS)
        return True


async def main(once: bool) -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    await db.open_pools()
    last_reports = 0.0
    try:
        while True:
            busy = await run_once()
            if not busy:
                from ..integration.webhooks import deliver_due
                # a single pass (--once, used by cron and tests) sends everything due, not just one batch
                while await deliver_due() >= 20 and once:
                    pass
                # scheduled reports are checked once a minute, between events
                if once or asyncio.get_running_loop().time() - last_reports > 60:
                    from ..reports.scheduler import run_due
                    await run_due()
                    from ..payments.service import expire_stale
                    async with db.transaction(_ctx()) as conn:
                        await expire_stale(conn)
                    last_reports = asyncio.get_running_loop().time()
                if once:
                    return
                await asyncio.sleep(2)
    finally:
        await db.close_pools()


if __name__ == "__main__":
    asyncio.run(main("--once" in sys.argv))
