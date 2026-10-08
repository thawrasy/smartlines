"""Signed webhooks (study 13.10, 14): outbox events delivered to partner endpoints.

* The notify worker fans each published outbox event out to the ACTIVE endpoints whose client may see it
  (receives): a company's own rows, an agency's own sales, a partner's own wallet credits, border events for
  authorities. Personal fields are removed unless the endpoint was approved for personal data.
* Each delivery is POSTed as JSON with
      X-Masslak-Event: <type>     X-Masslak-Delivery: <uuid>
      X-Masslak-Signature: t=<unix seconds>,v1=<hex HMAC-SHA256(secret, "<t>." + body)>
  Receivers check the signature and reject timestamps older than five minutes (replay).
* Retries back off 1, 2, 4 ... 64 minutes; after eight failures the delivery is DEAD (kept for the console).
* Only https URLs on port 443 with a public name or address. The address is resolved once per attempt, checked against
  every range that is not globally reachable (private, loopback, link-local, shared 100.64.0.0/10, documentation,
  benchmarking, reserved; IPv4 inside IPv6 is checked as IPv4, NAT64 included), and the connection goes to that checked
  address with the hostname kept for TLS verification (SSRF and DNS rebinding, review stage B).
* A delivery has a total deadline (DEADLINE) on top of the per-read timeout, so an endpoint that answers one byte at a
  time cannot hold a worker thread.
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
import re
import secrets
import socket
import ssl
import threading
import time
import uuid
from typing import Optional
from urllib.parse import urlparse

import asyncpg

from ... import db, egress
from ...config import get_settings
from ...crypto import cipher
from ...errors import ApiError
from .scopes import EVENTS, PERSONAL_FIELDS

log = logging.getLogger("masslak.webhooks")
SECRET_COLUMN = "sys.webhook_endpoint.secret"
KEY_REF = "kms://masslak/webhook/v1"
MAX_ATTEMPTS = 8
TIMEOUT = 10
DEADLINE = 30                     # seconds for a whole delivery: connect, TLS, request and response
# names that never belong to a partner on the public internet (RFC 6761, RFC 8375 and common internal suffixes)
INTERNAL_SUFFIXES = (".localhost", ".local", ".internal", ".intranet", ".lan", ".home.arpa", ".corp", ".localdomain",
                     ".private", ".test", ".invalid", ".example")
NAT64 = (ipaddress.ip_network("64:ff9b::/96"), ipaddress.ip_network("64:ff9b:1::/48"))


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
    """Globally reachable only: is_global leaves out the shared range 100.64.0.0/10 that is_private keeps in (cloud
    metadata services live there too), and an IPv4 address carried inside IPv6 is judged as that IPv4 address."""
    a = ipaddress.ip_address(addr.split("%", 1)[0])
    if isinstance(a, ipaddress.IPv6Address):
        if a.ipv4_mapped is not None:
            return _public(str(a.ipv4_mapped))
        if any(a in n for n in NAT64):
            return _public(str(ipaddress.IPv4Address(int(a) & 0xFFFFFFFF)))
    return a.is_global and not (a.is_multicast or a.is_reserved or a.is_unspecified or a.is_loopback or a.is_link_local)


def _literal(host: str):
    """The address a host names by itself, in any spelling the resolver accepts (127.1, 2130706433, 0x7f.0.0.1)."""
    try:
        return ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        pass
    if re.fullmatch(r"[0-9a-fA-FxX.]+", host) and not re.search(r"[g-wyzG-WYZ]", host):
        try:
            return ipaddress.IPv4Address(socket.inet_aton(host))
        except OSError:
            return None
    return None


def check_url(url: str) -> str:
    """Registration check; the delivery repeats the address check on every attempt (DNS can change)."""
    u = urlparse(url.strip())
    try:
        port = u.port
    except ValueError:
        port = -1
    if u.scheme != "https" or not u.hostname or u.username or u.password or len(url) > 500 or port == -1:
        raise ApiError(422, "WEBHOOK_URL_INVALID", "the endpoint must be an https URL without credentials")
    if _allow_private():
        return url.strip()
    host = u.hostname.rstrip(".").lower()
    literal = _literal(host)
    if literal is not None and not _public(str(literal)):
        raise ApiError(422, "WEBHOOK_URL_NOT_PUBLIC", "the endpoint must be reachable on the public internet")
    if get_settings().sandbox:
        return url.strip()            # test servers register local receivers by name; delivery still checks the address
    if port not in (None, 443):
        raise ApiError(422, "WEBHOOK_URL_PORT", "the endpoint must use the standard HTTPS port (443)")
    if literal is None and ("." not in host or host == "localhost" or host.endswith(INTERNAL_SUFFIXES)):
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
        # a notice addressed to one authority reaches that authority only
        return "authority_id" not in payload or payload["authority_id"] == client.get("authority_id")
    cid = client["company_id"]
    return cid is not None and (event["company_id"] == cid or payload.get("agency_id") == cid)


def envelope(event_uid, event_type: str, created_at, payload: dict, include_pii: bool, *, schema_version: int = 1,
             correlation_id=None, aggregate: Optional[str] = None, sequence: Optional[int] = None) -> dict:
    """The event contract (docs/integration/EVENTS.md): delivery is at least once, so a receiver keeps the ids it has
    applied and ignores a repeat; sequence orders the events of one aggregate."""
    data = {k: v for k, v in payload.items() if (include_pii or k not in PERSONAL_FIELDS) and k not in ("api_client_id", "authority_id")}
    return {"id": str(event_uid), "type": event_type, "created_at": created_at.isoformat() if created_at else None,
            "api_version": "v1", "schema_version": schema_version,
            "correlation_id": str(correlation_id) if correlation_id else None,
            "aggregate": aggregate, "sequence": sequence, "data": data}


async def fanout(conn: asyncpg.Connection, event, payload: dict) -> int:
    """Called by the notify worker inside the event's transaction: one delivery row per receiving endpoint."""
    rows = await conn.fetch(
        """SELECT e.id, e.events, c.id AS client_id, c.kind, c.company_id, c.authority_id FROM sys.webhook_endpoint e
             JOIN iam.api_client c ON c.id = e.api_client_id
            WHERE e.status = 'ACTIVE' AND c.status = 'ACTIVE' AND $1 = ANY(e.events)""", event["event_type"])
    n = 0
    for r in rows:
        if receives(r, list(r["events"]), event, payload):
            n += await conn.fetchval(
                """INSERT INTO sys.webhook_delivery (endpoint_id, outbox_event_id, outbox_created_at, event_type)
                   VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING RETURNING 1""",
                r["id"], event["id"], event["created_at"], event["event_type"]) or 0
    return n


# ------------------------------------------------------------------ sending
class DeliveryError(Exception):
    pass


class _Deadline:
    """Shuts the delivery's socket down when the total deadline passes, which ends any read in progress."""

    def __init__(self, seconds: float):
        self.sock, self.fired = None, threading.Event()
        self.timer = threading.Timer(seconds, self._fire)
        self.timer.daemon = True

    def _fire(self):
        self.fired.set()
        try:
            if self.sock is not None:
                self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def __enter__(self):
        self.timer.start()
        return self

    def __exit__(self, *exc):
        self.timer.cancel()
        return False


def post(url: str, body: bytes, headers: dict) -> int:
    """POSTs to the checked address of the URL's host; returns the HTTP status."""
    with _Deadline(DEADLINE) as deadline:
        try:
            return _post(url, body, headers, deadline)
        except (OSError, http.client.HTTPException) as exc:
            if deadline.fired.is_set():
                raise DeliveryError(f"DEADLINE: no complete answer within {DEADLINE} s") from exc
            raise


def _post(url: str, body: bytes, headers: dict, deadline: _Deadline) -> int:
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
    raw = None
    if egress.proxy() is not None:
        # production: through the egress proxy, which repeats the address check after its own lookup (T3-02)
        raw = egress.tunnel(host, port, timeout=TIMEOUT)
    for addr in ([] if raw is not None else dict.fromkeys(addrs)):   # every checked address in DNS order
        try:
            raw = socket.create_connection((addr, port), timeout=TIMEOUT)
            break
        except OSError as exc:
            last = exc
    if raw is None:
        raise last
    deadline.sock = raw
    conn = http.client.HTTPSConnection(host, port, timeout=TIMEOUT, context=ctx)
    try:
        conn.sock = ctx.wrap_socket(raw, server_hostname=host)
        deadline.sock = conn.sock
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
            RETURNING d.id, d.delivery_uid, d.attempts, d.endpoint_id, d.outbox_event_id, d.outbox_created_at""", limit)
        jobs = []
        for d in rows:
            x = await conn.fetchrow(
                """SELECT e.url, e.secret_enc, e.enc_key_id, e.include_pii, o.event_uid, o.event_type, o.payload, o.created_at,
                          o.schema_version, o.correlation_id, o.aggregate_type, o.aggregate_seq
                     FROM sys.webhook_endpoint e, sys.outbox_event o WHERE e.id = $1 AND o.id = $2 AND o.created_at = $3""",
                d["endpoint_id"], d["outbox_event_id"], d["outbox_created_at"])
            payload = json.loads(x["payload"]) if isinstance(x["payload"], str) else dict(x["payload"])
            body = json.dumps(envelope(x["event_uid"], x["event_type"], x["created_at"], payload, x["include_pii"],
                                       schema_version=x["schema_version"], correlation_id=x["correlation_id"],
                                       aggregate=x["aggregate_type"], sequence=x["aggregate_seq"]),
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
