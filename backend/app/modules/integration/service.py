"""API clients, keys and webhook endpoints: what the platform console and the company console share.

Lifecycle: a client is created PENDING (by a company owner for its own company, or by platform security for
banks, e-wallets and authorities), approved by platform security (someone other than its creator: four-eyes),
then keys are issued. Suspending a client stops its keys at once; revoking is final.
"""
from __future__ import annotations

import json
import uuid
from datetime import datetime, timedelta, timezone
from typing import Optional

import asyncpg

from ... import db
from ...deps import Principal
from ...errors import ApiError, not_found
from . import webhooks
from .auth import new_key
from .scopes import EVENTS, KIND_COMPANY, KIND_SCOPES


def _iso(v):
    return v.isoformat() if v else None


def client_out(r) -> dict:
    keys = r.keys()
    return {
        "uid": str(r["uid"]), "name": r["name"], "kind": r["kind"], "environment": r["environment"], "status": r["status"],
        "scopes": list(r["scopes"]), "rate_limit_per_min": r["rate_limit_per_min"],
        "ip_allowlist": [str(n) for n in (r["ip_allowlist"] or [])], "require_mtls": r["require_mtls"],
        "description": r["description"], "contact_email": r["contact_email"], "status_reason": r["status_reason"],
        "company": r["company_name"] if "company_name" in keys else None,
        "acting_user": r["acting_email"] if "acting_email" in keys else None,
        "provider": r["provider_code"] if "provider_code" in keys else None,
        "authority": r["authority_code"] if "authority_code" in keys else None,
        "created_at": _iso(r["created_at"]), "created_by": r["creator_email"] if "creator_email" in keys else None,
        "approved_by": r["approver_email"] if "approver_email" in keys else None,
        "active_keys": r["active_keys"] if "active_keys" in keys else None,
        "requests_today": r["requests_today"] if "requests_today" in keys else None,
    }


_SELECT = """SELECT c.*, p.legal_name AS company_name, au.email AS acting_email, pv.code AS provider_code, ap.code AS authority_code,
                    cu.email AS creator_email, apu.email AS approver_email,
                    (SELECT count(*) FROM iam.api_key k WHERE k.api_client_id = c.id AND k.status = 'ACTIVE' AND k.expires_at > now()) AS active_keys,
                    (SELECT requests FROM iam.api_usage_daily u WHERE u.api_client_id = c.id AND u.day = current_date) AS requests_today
               FROM iam.api_client c LEFT JOIN iam.party p ON p.id = c.company_id
               LEFT JOIN iam.app_user au ON au.id = c.acting_user_id LEFT JOIN fin.payment_provider pv ON pv.id = c.payment_provider_id
               LEFT JOIN sec.authority_profile ap ON ap.id = c.authority_id
               LEFT JOIN iam.app_user cu ON cu.id = c.created_by LEFT JOIN iam.app_user apu ON apu.id = c.approved_by"""


async def clients(conn: asyncpg.Connection, company_id: Optional[int]) -> list[dict]:
    rows = await conn.fetch(_SELECT + " WHERE ($1::bigint IS NULL OR c.company_id = $1) ORDER BY c.status = 'REVOKED', c.created_at DESC",
                            company_id)
    return [client_out(r) for r in rows]


async def client_row(conn: asyncpg.Connection, uid: uuid.UUID, company_id: Optional[int]):
    r = await conn.fetchrow(_SELECT + " WHERE c.uid = $1 AND ($2::bigint IS NULL OR c.company_id = $2)", uid, company_id)
    if r is None:
        raise not_found("API client")
    return r


def _scopes(kind: str, scopes: list[str]) -> list[str]:
    allowed = KIND_SCOPES[kind]
    bad = sorted(set(scopes) - allowed)
    if bad:
        raise ApiError(422, "SCOPE_NOT_ALLOWED", "these scopes are not available to this kind of client: " + ", ".join(bad),
                       allowed=sorted(allowed))
    if not scopes:
        raise ApiError(422, "SCOPE_REQUIRED", "choose at least one scope")
    return sorted(set(scopes))


def _networks(items: list[str]) -> list[str]:
    import ipaddress
    out = []
    for n in items:
        try:
            out.append(str(ipaddress.ip_network(n.strip(), strict=False)))
        except ValueError as exc:
            raise ApiError(422, "IP_RANGE_INVALID", f"not an address or range: {n}") from exc
    return out


async def create(conn: asyncpg.Connection, pr: Principal, *, platform: bool, name: str, kind: str, scopes: list[str],
                 environment: str, description: Optional[str], contact_email: Optional[str], ip_allowlist: list[str],
                 company_uid: Optional[uuid.UUID] = None, acting_email: Optional[str] = None,
                 provider_code: Optional[str] = None, authority_code: Optional[str] = None, rate_limit: int = 600) -> dict:
    company_id, company_type, acting, authority_id = None, None, None, None
    if platform:
        if company_uid:
            co = await conn.fetchrow("SELECT c.id, c.company_type FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1",
                                     company_uid)
            if co is None:
                raise not_found("company")
            company_id, company_type = co["id"], co["company_type"]
        if acting_email:
            acting = await conn.fetchval("SELECT id FROM iam.app_user WHERE lower(email) = lower($1) AND status = 'ACTIVE'", acting_email)
            if acting is None:
                raise ApiError(404, "ACTING_ACCOUNT_NOT_FOUND", "no active account with this email")
    else:
        company_id, acting = pr.company_id, pr.user_id
        company_type = await conn.fetchval("SELECT company_type FROM iam.company WHERE id = $1", company_id)
        if kind not in ("CARRIER", "CHANNEL", "INTEGRATION"):
            raise ApiError(422, "KIND_NOT_ALLOWED", "companies create carrier, sales channel or integration clients")
        rate_limit = min(rate_limit, 600)
    if company_type not in KIND_COMPANY[kind]:
        raise ApiError(422, "KIND_COMPANY_MISMATCH", "this kind of client does not fit the company", company_type=company_type)
    provider_id = None
    if kind == "PARTNER":
        provider_id = await conn.fetchval("SELECT id FROM fin.payment_provider WHERE code = $1", provider_code or "PARTNER_API")
        if provider_id is None:
            raise not_found("payment provider")
    if kind == "AUTHORITY" and authority_code:
        authority_id = await conn.fetchval("SELECT id FROM sec.authority_profile WHERE code = $1", authority_code)
        if authority_id is None:
            raise not_found("authority")
    owner = await conn.fetchval("SELECT party_id FROM iam.app_user WHERE id = $1", pr.user_id) if company_id is None else company_id
    r = await conn.fetchrow(
        """INSERT INTO iam.api_client (name, kind, owner_party_id, company_id, environment, scopes, rate_limit_per_min, ip_allowlist,
                                       description, contact_email, acting_user_id, payment_provider_id, authority_id, created_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8::cidr[], $9, $10, $11, $12, $13, $14) RETURNING uid""",
        name.strip(), kind, owner, company_id, environment, _scopes(kind, scopes), rate_limit, _networks(ip_allowlist) or None,
        description, contact_email, acting, provider_id, authority_id, pr.user_id)
    return client_out(await client_row(conn, r["uid"], None))


async def update(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, company_id: Optional[int], *, platform: bool, **f) -> dict:
    c = await client_row(conn, uid, company_id)
    if c["status"] == "REVOKED":
        raise ApiError(409, "API_CLIENT_REVOKED", "a revoked client cannot be changed")
    scopes = _scopes(c["kind"], f["scopes"]) if f.get("scopes") is not None else list(c["scopes"])
    if not platform and not set(scopes) <= set(c["scopes"]) and c["status"] == "ACTIVE":
        # a company may narrow an approved client; widening it goes back through platform approval
        raise ApiError(409, "SCOPE_WIDENING_NEEDS_APPROVAL", "adding scopes to an approved client needs platform approval")
    rate = f.get("rate_limit_per_min") if platform and f.get("rate_limit_per_min") else c["rate_limit_per_min"]
    mtls = f.get("require_mtls") if platform and f.get("require_mtls") is not None else c["require_mtls"]
    fp = bytes.fromhex(f["mtls_cert_sha256"].replace(":", "")) if platform and f.get("mtls_cert_sha256") else c["mtls_cert_sha256"]
    if mtls and not fp:
        raise ApiError(422, "CERT_FINGERPRINT_REQUIRED", "give the SHA-256 fingerprint of the client certificate")
    ips = _networks(f["ip_allowlist"]) if f.get("ip_allowlist") is not None else [str(n) for n in (c["ip_allowlist"] or [])]
    await conn.execute(
        """UPDATE iam.api_client SET scopes = $2, rate_limit_per_min = $3, ip_allowlist = $4::cidr[], require_mtls = $5, mtls_cert_sha256 = $6,
                  description = coalesce($7, description), contact_email = coalesce($8, contact_email) WHERE id = $1""",
        c["id"], scopes, rate, ips or None, mtls, fp, f.get("description"), f.get("contact_email"))
    return client_out(await client_row(conn, uid, company_id))


async def decide(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, action: str, reason: Optional[str]) -> dict:
    """Platform security: approve, suspend, reactivate or revoke."""
    c = await client_row(conn, uid, None)
    allowed = {"approve": ("PENDING",), "suspend": ("ACTIVE",), "reactivate": ("SUSPENDED",), "revoke": ("PENDING", "ACTIVE", "SUSPENDED")}
    if c["status"] not in allowed[action]:
        raise ApiError(409, "INVALID_TRANSITION", f"cannot {action} a {c['status'].lower()} client")
    if action == "approve" and c["created_by"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "someone other than the creator must approve this client")
    if action in ("suspend", "revoke") and len((reason or "").strip()) < 5:
        raise ApiError(422, "REASON_REQUIRED", "give the reason")
    status = {"approve": "ACTIVE", "suspend": "SUSPENDED", "reactivate": "ACTIVE", "revoke": "REVOKED"}[action]
    await conn.execute(
        """UPDATE iam.api_client SET status = $2, status_reason = $3, approved_by = CASE WHEN $4 THEN $5 ELSE approved_by END WHERE id = $1""",
        c["id"], status, (reason or "").strip() or None, action == "approve", pr.user_id)
    if action == "revoke":
        await conn.execute("""UPDATE iam.api_key SET status = 'REVOKED', revoked_at = now(), revoked_by = $2, revoke_reason = $3
                               WHERE api_client_id = $1 AND status = 'ACTIVE'""", c["id"], pr.user_id, reason)
        await conn.execute("UPDATE sys.webhook_endpoint SET status = 'DISABLED' WHERE api_client_id = $1", c["id"])
    return client_out(await client_row(conn, uid, None))


async def detail(conn: asyncpg.Connection, uid: uuid.UUID, company_id: Optional[int]) -> dict:
    c = await client_row(conn, uid, company_id)
    keys = await conn.fetch(
        """SELECT k.id, k.key_prefix, k.status, k.expires_at, k.last_used_at, host(k.last_used_ip) AS last_used_ip, k.created_at,
                  k.revoked_at, k.revoke_reason, u.email AS created_by
             FROM iam.api_key k LEFT JOIN iam.app_user u ON u.id = k.created_by WHERE k.api_client_id = $1 ORDER BY k.id DESC LIMIT 20""", c["id"])
    hooks = await conn.fetch(
        """SELECT e.uid, e.url, e.events, e.include_pii, e.status, e.created_at, e.last_success_at,
                  count(d.*) FILTER (WHERE d.status = 'PENDING') AS pending, count(d.*) FILTER (WHERE d.status = 'DEAD') AS dead
             FROM sys.webhook_endpoint e LEFT JOIN sys.webhook_delivery d ON d.endpoint_id = e.id
            WHERE e.api_client_id = $1 AND e.status <> 'DISABLED' GROUP BY e.id ORDER BY e.id""", c["id"])
    usage = await conn.fetch("SELECT day, requests, errors FROM iam.api_usage_daily WHERE api_client_id = $1 AND day > current_date - 30 ORDER BY day",
                             c["id"])
    deliveries = await conn.fetch(
        """SELECT d.delivery_uid, d.event_type, d.status, d.attempts, d.http_status, d.last_error, d.created_at, d.delivered_at, e.url
             FROM sys.webhook_delivery d JOIN sys.webhook_endpoint e ON e.id = d.endpoint_id
            WHERE e.api_client_id = $1 ORDER BY d.id DESC LIMIT 25""", c["id"])
    return {
        "client": client_out(c),
        "keys": [{**dict(k), "expires_at": _iso(k["expires_at"]), "last_used_at": _iso(k["last_used_at"]), "created_at": _iso(k["created_at"]),
                  "revoked_at": _iso(k["revoked_at"])} for k in keys],
        "webhooks": [{**dict(h), "uid": str(h["uid"]), "events": list(h["events"]), "created_at": _iso(h["created_at"]),
                      "last_success_at": _iso(h["last_success_at"])} for h in hooks],
        "usage": [{"day": u["day"].isoformat(), "requests": u["requests"], "errors": u["errors"]} for u in usage],
        "deliveries": [{**dict(d), "delivery_uid": str(d["delivery_uid"]), "created_at": _iso(d["created_at"]),
                        "delivered_at": _iso(d["delivered_at"])} for d in deliveries],
        "events": sorted(e for e, kinds in EVENTS.items() if c["kind"] in kinds),
        "allowed_scopes": sorted(KIND_SCOPES[c["kind"]]),
    }


async def issue_key(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, company_id: Optional[int]) -> dict:
    c = await client_row(conn, uid, company_id)
    if c["status"] != "ACTIVE":
        raise ApiError(409, "API_CLIENT_NOT_ACTIVE", "keys are issued only for an approved, active client")
    days = int(await conn.fetchval("SELECT value::text::int FROM sys.setting WHERE key = 'security.api_key_rotation_days'") or 90)
    raw, prefix, digest = new_key(c["environment"])
    expires = datetime.now(timezone.utc) + timedelta(days=days)
    kid = await conn.fetchval(
        "INSERT INTO iam.api_key (api_client_id, key_prefix, key_hash, expires_at, created_by) VALUES ($1, $2, $3, $4, $5) RETURNING id",
        c["id"], prefix, digest, expires, pr.user_id)
    return {"id": kid, "key": raw, "prefix": prefix, "expires_at": expires.isoformat()}


async def revoke_key(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, key_id: int, company_id: Optional[int], reason: str) -> dict:
    c = await client_row(conn, uid, company_id)
    n = await conn.execute("""UPDATE iam.api_key SET status = 'REVOKED', revoked_at = now(), revoked_by = $3, revoke_reason = $4
                               WHERE id = $1 AND api_client_id = $2 AND status = 'ACTIVE'""", key_id, c["id"], pr.user_id, reason)
    if n.endswith(" 0"):
        raise not_found("active key")
    return {"ok": True}


# ------------------------------------------------------------------ webhook endpoints
def _events(kind: str, events: list[str]) -> list[str]:
    allowed = {e for e, kinds in EVENTS.items() if kind in kinds}
    bad = sorted(set(events) - allowed)
    if bad or not events:
        raise ApiError(422, "WEBHOOK_EVENT_NOT_ALLOWED", "choose events this client may receive", allowed=sorted(allowed), rejected=bad)
    return sorted(set(events))


async def add_endpoint(conn: asyncpg.Connection, client_id: int, kind: str, url: str, events: list[str], include_pii: bool) -> dict:
    if include_pii and kind not in ("CARRIER", "CHANNEL", "INTERNAL"):
        raise ApiError(422, "WEBHOOK_PII_NOT_ALLOWED", "only a company's own clients can receive personal data")
    n = await conn.fetchval("SELECT count(*) FROM sys.webhook_endpoint WHERE api_client_id = $1 AND status <> 'DISABLED'", client_id)
    if n >= 5:
        raise ApiError(409, "WEBHOOK_LIMIT", "a client can have at most five endpoints")
    secret = webhooks.new_secret()
    blob, key_id = await webhooks.seal(conn, secret)
    uid = await conn.fetchval(
        """INSERT INTO sys.webhook_endpoint (owner_kind, api_client_id, kind, url, events, secret_enc, enc_key_id, include_pii)
           VALUES ('API_CLIENT', $1, 'PARTNER', $2, $3, $4, $5, $6) RETURNING uid""",
        client_id, webhooks.check_url(url), _events(kind, events), blob, key_id, include_pii)
    return {"uid": str(uid), "secret": secret, "url": url, "events": sorted(set(events))}


async def _endpoint(conn, client_id: int, uid: uuid.UUID):
    e = await conn.fetchrow("SELECT * FROM sys.webhook_endpoint WHERE uid = $1 AND api_client_id = $2 AND status <> 'DISABLED'", uid, client_id)
    if e is None:
        raise not_found("webhook endpoint")
    return e


async def remove_endpoint(conn: asyncpg.Connection, client_id: int, uid: uuid.UUID) -> dict:
    e = await _endpoint(conn, client_id, uid)
    await conn.execute("UPDATE sys.webhook_endpoint SET status = 'DISABLED' WHERE id = $1", e["id"])
    await conn.execute("UPDATE sys.webhook_delivery SET status = 'FAILED', last_error = 'endpoint removed' WHERE endpoint_id = $1 AND status = 'PENDING'",
                       e["id"])
    return {"ok": True}


async def rotate_secret(conn: asyncpg.Connection, client_id: int, uid: uuid.UUID) -> dict:
    e = await _endpoint(conn, client_id, uid)
    secret = webhooks.new_secret()
    blob, key_id = await webhooks.seal(conn, secret)
    await conn.execute("UPDATE sys.webhook_endpoint SET secret_enc = $2, enc_key_id = $3 WHERE id = $1", e["id"], blob, key_id)
    return {"uid": str(uid), "secret": secret}


async def ping(conn: asyncpg.Connection, ctx: db.Context, client_id: int, uid: uuid.UUID) -> dict:
    """A test event for one endpoint only: written already published, so the worker's fan-out never sees it."""
    e = await _endpoint(conn, client_id, uid)
    async with db.system_scope(conn, ctx):
        ev = await conn.fetchval(
            """INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, status, published_at)
               VALUES ('webhook.ping', 'webhook_endpoint', $1, $2::jsonb, 'PUBLISHED', now()) RETURNING id""",
            e["id"], json.dumps({"endpoint": str(uid), "message": "test delivery"}))
        d = await conn.fetchval("INSERT INTO sys.webhook_delivery (endpoint_id, outbox_event_id, event_type) VALUES ($1, $2, 'webhook.ping') "
                                "RETURNING delivery_uid", e["id"], ev)
    return {"delivery": str(d), "status": "PENDING"}


async def redeliver(conn: asyncpg.Connection, client_id: int, delivery_uid: uuid.UUID) -> dict:
    n = await conn.execute(
        """UPDATE sys.webhook_delivery d SET status = 'PENDING', next_attempt_at = now(), attempts = 0
             FROM sys.webhook_endpoint e WHERE e.id = d.endpoint_id AND e.api_client_id = $1 AND d.delivery_uid = $2
              AND d.status IN ('DEAD', 'FAILED') AND e.status = 'ACTIVE'""", client_id, delivery_uid)
    if n.endswith(" 0"):
        raise ApiError(409, "DELIVERY_NOT_RETRYABLE", "only failed deliveries of an active endpoint can be sent again")
    return {"ok": True}
