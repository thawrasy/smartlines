"""API key authentication for /api/v1 (study 14, 16.10, 16.18).

* A key is 32 random bytes behind a prefix that names its environment (msk_test_ / msk_live_). Only its SHA-256 is
  stored; the key itself is shown once. At most two keys are active per client, so a key can be rotated without
  downtime, and every key expires (security.api_key_rotation_days).
* Keys arrive in the X-Api-Key header or as "Authorization: Bearer <key>"; cookies are never read on /api/v1, so
  the API cannot be driven from a browser session (and needs no CSRF header).
* A client acts for its company within its scopes. Scopes that read or change company data run as the client's
  acting staff account, whose current permissions cap them: removing that person's rights also cuts the API.
* Checked on every call: key and client status, expiry, the sandbox flag, the client's IP allowlist, the client
  certificate fingerprint when mTLS is required (forwarded by the TLS-terminating proxy), and the client's own
  rate limit, on top of the per-address limit of the middleware. The client's bucket is in the database, shared by
  every process and server (1068).
"""
from __future__ import annotations

import hashlib
import ipaddress
import re
import secrets
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Optional

from fastapi import Request

from ... import db, ratelimit
from ...config import get_settings
from ...deps import PORTAL_SCOPE, Principal, base_context, load_permissions
from ...errors import ApiError
from ...middleware import _is_trusted, _trusted_networks
from .scopes import KIND_SCOPES, SCOPE_PERMISSIONS

KEY_PREFIX = {"SANDBOX": "msk_test_", "PRODUCTION": "msk_live_"}
KEY_RE = re.compile(r"^msk_(test|live)_[A-Za-z0-9_-]{40,64}$")
CERT_HEADER = "x-client-cert-sha256"


def new_key(environment: str) -> tuple[str, str, bytes]:
    """(key shown once, prefix kept for identification, hash stored)."""
    raw = KEY_PREFIX[environment] + secrets.token_urlsafe(32)
    return raw, raw[:17], key_hash(raw)


def key_hash(raw: str) -> bytes:
    return hashlib.sha256(raw.encode()).digest()


@dataclass
class Caller:
    client_id: int
    client_uid: str
    name: str
    kind: str
    environment: str
    company_id: Optional[int]
    company_type: Optional[str]
    scopes: set[str]
    key_id: int
    provider_id: Optional[int]
    principal: Optional[Principal] = None
    rate_limit: int = 600
    authority_id: Optional[int] = None
    extra: dict = field(default_factory=dict)

    def need(self, scope: str) -> None:
        if scope not in self.scopes:
            raise ApiError(403, "SCOPE_MISSING", f"this key does not have the {scope} scope", scope=scope)
        perms = SCOPE_PERMISSIONS.get(scope)
        if perms:
            if self.principal is None:
                raise ApiError(403, "ACTING_ACCOUNT_REQUIRED", "this client has no active staff account to act for")
            if not self.principal.permissions.intersection(perms):
                raise ApiError(403, "ACTING_ACCOUNT_LACKS_PERMISSION",
                               "the client's staff account no longer holds a permission this scope needs", scope=scope)

    def acting(self, scope: str) -> Principal:
        self.need(scope)
        assert self.principal is not None
        return self.principal


def context(request: Request, caller: Caller) -> db.Context:
    ctx = base_context(request)
    ctx.api_client_id = caller.client_id
    ctx.company_id = caller.company_id
    if caller.principal:
        ctx.user_id, ctx.party_id = caller.principal.user_id, caller.principal.party_id
        ctx.scope = PORTAL_SCOPE.get(caller.principal.portal, "API")
    else:
        ctx.scope = "API"
    return ctx


def _presented(request: Request) -> Optional[str]:
    key = request.headers.get("x-api-key")
    if key:
        return key.strip()
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() or None
    return None


def _deny(request: Request, status: int, code: str, message: str, **details) -> ApiError:
    request.state.audit = {"action": "api.denied", "reason": code}
    return ApiError(status, code, message, **details)


async def api_caller(request: Request) -> Caller:
    raw = _presented(request)
    if not raw:
        raise ApiError(401, "API_KEY_REQUIRED", "send the API key in the X-Api-Key header")
    if not KEY_RE.match(raw):
        raise _deny(request, 401, "API_KEY_INVALID", "unknown or revoked API key")
    base = base_context(request)
    ctx = db.Context(request_id=base.request_id, ip=base.ip, scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        row = await conn.fetchrow(
            """SELECT k.id AS key_id, k.expires_at, k.last_used_at, c.*, co.company_type, co.approval_status AS company_status
                 FROM iam.api_key k JOIN iam.api_client c ON c.id = k.api_client_id
                 LEFT JOIN iam.company co ON co.id = c.company_id
                WHERE k.key_hash = $1 AND k.status = 'ACTIVE'""", key_hash(raw))
        if row is None:
            raise _deny(request, 401, "API_KEY_INVALID", "unknown or revoked API key")
        if row["expires_at"] <= datetime.now(timezone.utc):
            raise _deny(request, 401, "API_KEY_EXPIRED", "this API key has expired; issue a new one")
        if row["status"] != "ACTIVE":
            raise _deny(request, 403, "API_CLIENT_INACTIVE", "this API client is not active", client_status=row["status"])
        if row["environment"] == "SANDBOX" and not get_settings().sandbox:
            raise _deny(request, 403, "API_KEY_SANDBOX_ONLY", "test keys work only in the test environment")
        if row["environment"] == "PRODUCTION" and get_settings().sandbox:
            # a live key never drives simulated payments or demo data (review of 1.47.0, R-30)
            raise _deny(request, 403, "API_KEY_LIVE_ONLY", "live keys work only on the production platform")
        if row["company_id"] and row["company_status"] != "APPROVED":
            raise _deny(request, 403, "COMPANY_NOT_APPROVED", "the client's company is not approved")
        if row["ip_allowlist"]:
            addr = ipaddress.ip_address(request.state.client_ip)
            if not any(addr in ipaddress.ip_network(str(n)) for n in row["ip_allowlist"]):
                raise _deny(request, 403, "API_IP_NOT_ALLOWED", "calls from this address are not allowed for this client")
        if row["require_mtls"]:
            peer = request.client.host if request.client else ""
            presented = (request.headers.get(CERT_HEADER) or "").lower().replace(":", "")
            if not _is_trusted(peer, _trusted_networks()) or not row["mtls_cert_sha256"] \
                    or not secrets.compare_digest(presented, row["mtls_cert_sha256"].hex()):
                raise _deny(request, 403, "API_CLIENT_CERT_REQUIRED", "this client must call with its registered certificate")
        principal = None
        if row["acting_user_id"]:
            u = await conn.fetchrow(
                """SELECT u.id, u.uid, u.party_id, u.email, u.preferred_locale, p.legal_name FROM iam.app_user u
                     JOIN iam.party p ON p.id = u.party_id WHERE u.id = $1 AND u.status = 'ACTIVE'""", row["acting_user_id"])
            if u:
                portal = ("AGENCY" if row["company_type"] == "AGENCY" else "OPERATOR") if row["company_id"] else "PLATFORM"
                pr = Principal(user_id=u["id"], user_uid=str(u["uid"]), party_id=u["party_id"], session_id=None,  # type: ignore[arg-type]
                               portal=portal, company_id=row["company_id"], display_name=row["name"], email=u["email"],
                               locale=u["preferred_locale"] or "en")
                await load_permissions(conn, pr)
                principal = pr if pr.permissions else None
        if row["last_used_at"] is None or (datetime.now(timezone.utc) - row["last_used_at"]).total_seconds() > 60:
            await conn.execute("UPDATE iam.api_key SET last_used_at = now(), last_used_ip = $2::inet WHERE id = $1",
                               row["key_id"], request.state.client_ip)
        # the client's bucket is shared by every process and server (1068; reviews of October 2026, M-03)
        wait = await ratelimit.check_api_client(conn, row["id"], row["rate_limit_per_min"])
    if wait:
        raise ApiError(429, "RATE_LIMITED", "this client is over its rate limit", retry_after=max(1, round(wait)))
    request.state.api_client_id = row["id"]
    request.state.principal = principal      # the activity log records the acting account next to the client
    return Caller(client_id=row["id"], client_uid=str(row["uid"]), name=row["name"], kind=row["kind"],
                  environment=row["environment"], company_id=row["company_id"], company_type=row["company_type"],
                  scopes=set(row["scopes"]) & KIND_SCOPES.get(row["kind"], set()), key_id=row["key_id"],
                  provider_id=row["payment_provider_id"], principal=principal, rate_limit=row["rate_limit_per_min"],
                  authority_id=row["authority_id"])


async def record_usage(client_id: int, error: bool) -> None:
    """Counts the call; never breaks the response."""
    try:
        ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
        async with db.transaction(ctx) as conn:
            await conn.execute(
                """INSERT INTO iam.api_usage_daily (api_client_id, day, requests, errors) VALUES ($1, current_date, 1, $2::int)
                   ON CONFLICT (api_client_id, day) DO UPDATE SET requests = iam.api_usage_daily.requests + 1,
                          errors = iam.api_usage_daily.errors + $2::int, last_at = now()""", client_id, error)
    except Exception:  # pragma: no cover - usage counters are best effort
        pass
