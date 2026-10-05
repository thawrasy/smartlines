"""Signed webhooks (study 13.10, 14): outbox events delivered to partner endpoints.

* The notify worker fans each published outbox event out to the ACTIVE endpoints whose client may see it
  (receives): a company's own rows, an agency's own sales, a partner's own wallet credits, border events for
  authorities. Personal fields are removed unless the endpoint was approved for personal data.
* Each delivery is POSTed as JSON with
      X-Masslak-Event: <type>     X-Masslak-Delivery: <uuid>
      X-Masslak-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>." + body)>
  Receivers check the signature and reject timestamps older than five minutes (replay).
* Retries back off 1, 2, 4 ... 64 minutes; after eight failures the delivery is DEAD (kept for the console).
* Only https URLs. The address is resolved once, checked against private, loopback and link-local ranges (SSRF),
  and the connection goes to that checked address with the hostname kept for TLS verification.
* Endpoint secrets are encrypted at rest (AES-GCM, key kms://masslak/webhook/v1) and shown once when created.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import http.client
import ipaddress
import json
import logging
import os
import secrets
import socket
import ssl
import time
import uuid
from typing import Optional
from urllib.parse import urlparse

import asyncpg

from ... import db
from ...config import get_settings
from ...crypto import cipher
from ...errors import ApiError
from .scopes import EVENTS, PERSONAL_FIELDS

log = logging.getLogger("masslak.webhooks")
SECRET_COLUMN = "sys.webhook_endpoint.secret"
KEY_REF = "kms://masslak/webhook/v1"
MAX_ATTEMPTS = 8
TIMEOUT = 10


def new_secret() -> str:
    return "whsec_" + secrets.token_urlsafe(32)


async def seal(conn: asyncpg.Connection, secret: str) -> tuple[bytes, int]:
    s = (await cipher(conn)).encrypt(secret, SECRET_COLUMN, key_ref=KEY_REF)
    return s.ciphertext, s.key_id


async def unseal(conn: asyncpg.Connection, blob: bytes, key_id: int) -> str:
    return (await cipher(conn)).decrypt(blob, key_id, SECRET_COLUMN)


def sign(secret: str, body: bytes, t: Optional[int] = None) -> str:
    t = int(time.time()) if t is None else t
    mac = hmac.new(secret.encode(), f"{t}.".encode() + body, hashlib.sha256).hexdigest()
    return f"t={t},v1={mac}"


def _allow_private() -> bool:
    return get_settings().sandbox and os.environ.get("MASSLAK_WEBHOOK_ALLOW_PRIVATE", "").lower() == "true"


def _public(addr: str) -> bool:
    a = ipaddress.ip_address(addr)
    return not (a.is_private or a.is_loopback or a.is_link_local or a.is_reserved or a.is_multicast or a.is_unspecified)


def check_url(url: str) -> str:
    """Registration check; the delivery repeats the address check on every attempt (DNS can change)."""
    u = urlparse(url.strip())
    if u.scheme != "https" or not u.hostname or u.username or u.password or len(url) > 500:
        raise ApiError(422, "WEBHOOK_URL_INVALID", "the endpoint must be an https URL without credentials")
    try:
        literal = ipaddress.ip_address(u.hostname)
    except ValueError:
        literal = None
    if literal is not None and not _public(str(literal)) and not _allow_private():
        raise ApiError(422, "WEBHOOK_URL_NOT_PUBLIC", "the endpoint must be reachable on the public internet")
    return url.strip()


# ------------------------------------------------------------------ who receives what
def receives(client, endpoint_events: list[str], event, payload: dict) -> bool:
    et = event["event_type"]
    if et not in endpoint_events:
        return False
    if client["kind"] not in EVENTS.get(et, set()):
        return False
    if client["kind"] == "INTERNAL":
        return True
    if client["kind"] == "PARTNER":
        return payload.get("api_client_id") == client["client_id"]
    if client["kind"] == "AUTHORITY":
        return True
    cid = client["company_id"]
    return cid is not None and (event["company_id"] == cid or payload.get("agency_id") == cid)


def envelope(event_uid, event_type: str, created_at, payload: dict, include_pii: bool) -> dict:
    data = {k: v for k, v in payload.items() if (include_pii or k not in PERSONAL_FIELDS) and k != "api_client_id"}
    return {"id": str(event_uid), "type": event_type, "created_at": created_at.isoformat() if created_at else None,
            "api_version": "v1", "data": data}


async def fanout(conn: asyncpg.Connection, event, payload: dict) -> int:
    """Called by the notify worker inside the event's transaction: one delivery row per receiving endpoint."""
    rows = await conn.fetch(
        """SELECT e.id, e.events, c.id AS client_id, c.kind, c.company_id FROM sys.webhook_endpoint e
             JOIN iam.api_client c ON c.id = e.api_client_id
            WHERE e.status = 'ACTIVE' AND c.status = 'ACTIVE' AND $1 = ANY(e.events)""", event["event_type"])
    n = 0
    for r in rows:
        if receives(r, list(r["events"]), event, payload):
            n += await conn.fetchval(
                """INSERT INTO sys.webhook_delivery (endpoint_id, outbox_event_id, event_type) VALUES ($1, $2, $3)
                   ON CONFLICT DO NOTHING RETURNING 1""", r["id"], event["id"], event["event_type"]) or 0
    return n


# ------------------------------------------------------------------ sending
class DeliveryError(Exception):
    pass


def post(url: str, body: bytes, headers: dict) -> int:
    """POSTs to the checked address of the URL's host; returns the HTTP status."""
    u = urlparse(url)
    host, port = u.hostname or "", u.port or 443
    if u.scheme != "https":
        raise DeliveryError("URL_NOT_HTTPS")
    try:
        infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as exc:
        raise DeliveryError(f"DNS: {exc}") from exc
    addrs = [i[4][0] for i in infos]
    if not addrs or (not _allow_private() and not all(_public(a) for a in addrs)):
        raise DeliveryError("URL_NOT_PUBLIC")
    ctx = ssl.create_default_context()
    extra_ca = os.environ.get("MASSLAK_WEBHOOK_CA_FILE")
    if extra_ca and get_settings().sandbox:
        ctx.load_verify_locations(extra_ca)
    raw = socket.create_connection((addrs[0], port), timeout=TIMEOUT)
    conn = http.client.HTTPSConnection(host, port, timeout=TIMEOUT, context=ctx)
    try:
        conn.sock = ctx.wrap_socket(raw, server_hostname=host)
        conn.request("POST", (u.path or "/") + (f"?{u.query}" if u.query else ""), body=body, headers=headers)
        r = conn.getresponse()
        r.read(4096)
        return r.status
    finally:
        conn.close()


def _ctx() -> db.Context:
    return db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")


async def deliver_due(limit: int = 20) -> int:
    """Sends due deliveries. Rows are claimed first (moved five minutes ahead), so a slow endpoint holds no lock."""
    async with db.transaction(_ctx()) as conn:
        rows = await conn.fetch(
            """UPDATE sys.webhook_delivery d SET next_attempt_at = now() + interval '5 minutes'
                WHERE d.id IN (SELECT d2.id FROM sys.webhook_delivery d2 JOIN sys.webhook_endpoint e ON e.id = d2.endpoint_id
                                WHERE d2.status = 'PENDING' AND d2.next_attempt_at <= now() AND e.status = 'ACTIVE'
                                ORDER BY d2.id LIMIT $1 FOR UPDATE OF d2 SKIP LOCKED)
            RETURNING d.id, d.delivery_uid, d.attempts, d.endpoint_id, d.outbox_event_id""", limit)
        jobs = []
        for d in rows:
            x = await conn.fetchrow(
                """SELECT e.url, e.secret_enc, e.enc_key_id, e.include_pii, o.event_uid, o.event_type, o.payload, o.created_at
                     FROM sys.webhook_endpoint e, sys.outbox_event o WHERE e.id = $1 AND o.id = $2""", d["endpoint_id"], d["outbox_event_id"])
            payload = json.loads(x["payload"]) if isinstance(x["payload"], str) else dict(x["payload"])
            body = json.dumps(envelope(x["event_uid"], x["event_type"], x["created_at"], payload, x["include_pii"]),
                              default=str, separators=(",", ":")).encode()
            jobs.append((d, x["url"], x["event_type"], body, await unseal(conn, x["secret_enc"], x["enc_key_id"])))
    for d, url, event_type, body, secret in jobs:
        headers = {"Content-Type": "application/json", "User-Agent": "Masslak-Webhooks/1",
                   "X-Masslak-Event": event_type, "X-Masslak-Delivery": str(d["delivery_uid"]),
                   "X-Masslak-Signature": sign(secret, body)}
        started = time.monotonic()
        status, error = None, None
        try:
            status = await asyncio.to_thread(post, url, body, headers)
            if not 200 <= status < 300:
                error = f"HTTP {status}"
        except (DeliveryError, OSError, http.client.HTTPException, ssl.SSLError) as exc:
            error = str(exc)[:300] or exc.__class__.__name__
        ms = int((time.monotonic() - started) * 1000)
        async with db.transaction(_ctx()) as conn:
            if error is None:
                await conn.execute("""UPDATE sys.webhook_delivery SET status = 'DELIVERED', attempts = attempts + 1, http_status = $2,
                                        delivered_at = now(), response_ms = $3, last_error = NULL WHERE id = $1""", d["id"], status, ms)
                await conn.execute("UPDATE sys.webhook_endpoint SET last_success_at = now() WHERE id = $1", d["endpoint_id"])
            else:
                await conn.execute(
                    """UPDATE sys.webhook_delivery SET attempts = attempts + 1, http_status = $2, last_error = $3, response_ms = $4,
                              status = CASE WHEN attempts + 1 >= $5 THEN 'DEAD' ELSE 'PENDING' END,
                              next_attempt_at = now() + make_interval(mins => power(2, least(attempts, 6))::int)
                        WHERE id = $1""", d["id"], status, error, ms, MAX_ATTEMPTS)
                log.warning("webhook.failed delivery=%s attempt=%s: %s", d["delivery_uid"], d["attempts"] + 1, error)
    return len(jobs)
