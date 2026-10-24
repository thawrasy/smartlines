"""Request context and authentication dependencies."""
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import AsyncIterator, Optional

import asyncpg
from fastapi import Depends, Request

from . import db, mfa_policy
from .config import get_settings
from .errors import ApiError, forbidden
from .security import token_hash

SESSION_COOKIE = "msk_session"
REPLACED = "replaced by a new sign-in"   # revoke_reason of a session a later sign-in ended (1142)
IDLE = "idle"                             # revoke_reason of a session left without activity past its portal's period (1146)

# Portal -> RLS scope
PORTAL_SCOPE = {
    "PASSENGER": "PASSENGER",
    "OPERATOR": "COMPANY",
    "DRIVER": "COMPANY",
    "AGENCY": "AGENCY",
    "PLATFORM": "PLATFORM",
    "INSPECTOR": "PLATFORM",
    "STATION": "COMPANY",           # a station's operating company: its own rows, and the grants given to it (1098, 1099)
}


@dataclass
class Principal:
    user_id: int
    user_uid: str
    party_id: int
    session_id: int
    portal: str
    company_id: Optional[int]
    display_name: str
    email: Optional[str]
    locale: str
    permissions: set[str] = field(default_factory=set)
    roles: set[str] = field(default_factory=set)
    is_owner: bool = False
    mfa_pending: bool = False       # staff session that still owes its second factor
    password_must_change: bool = False   # a temporary password set by an administrator, not yet replaced (N16, 1150)
    mfa_enrolled: bool = False      # holds a second factor of a method open on this server
    mfa_required: bool = False
    mfa_factors: list[str] = field(default_factory=list)
    mfa_at: Optional[datetime] = None     # when this session last passed its second factor (1136)
    step_up_minutes: int = 10


def base_context(request: Request) -> db.Context:
    return db.Context(request_id=request.state.request_id, ip=request.state.client_ip)


async def load_principal(conn: asyncpg.Connection, token: str) -> Optional[Principal]:
    row = await conn.fetchrow(
        """
        SELECT s.id AS session_id, s.portal, s.company_id, u.id AS user_id, u.uid, u.party_id, u.email,
               u.preferred_locale, p.legal_name, s.mfa_passed, s.mfa_at, u.mfa_required, u.password_must_change,
               ARRAY(SELECT f.factor_type FROM iam.mfa_factor f WHERE f.user_id = u.id AND f.verified_at IS NOT NULL
                        AND f.disabled_at IS NULL AND f.factor_type IN ('TOTP','SMS','WHATSAPP')) AS mfa_factors
          FROM iam.user_session s
          JOIN iam.app_user u ON u.id = s.user_id
          JOIN iam.party p ON p.id = u.party_id
         WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now() AND u.status = 'ACTIVE'
           AND (s.access_expires_at IS NULL OR s.access_expires_at > now())
           AND s.last_seen_at > now() - make_interval(mins => iam.idle_minutes(s.portal))
        """,
        token_hash(token),
    )
    if row is None:
        return None
    pr = Principal(
        user_id=row["user_id"], user_uid=str(row["uid"]), party_id=row["party_id"], session_id=row["session_id"],
        portal=row["portal"], company_id=row["company_id"], display_name=row["legal_name"], email=row["email"],
        locale=row["preferred_locale"],
    )
    policy = await mfa_policy.current(conn)
    pr.mfa_factors = list(row["mfa_factors"])
    pr.mfa_enrolled = mfa_policy.enrolled(pr.mfa_factors, policy)
    pr.mfa_required = mfa_required_for(pr.portal, row["mfa_required"], bool(pr.mfa_factors), policy)
    pr.mfa_pending = pr.mfa_required and not row["mfa_passed"]
    pr.mfa_at, pr.step_up_minutes = row["mfa_at"], policy.step_up_minutes
    pr.password_must_change = row["password_must_change"]
    await load_permissions(conn, pr)
    return pr


async def load_permissions(conn: asyncpg.Connection, pr: Principal) -> None:
    """Roles and permissions of the user in the portal (and company) of the principal."""
    if pr.portal in ("PLATFORM", "INSPECTOR"):
        rows = await conn.fetch(
            """SELECT r.code, rp.permission_code FROM iam.user_role ur JOIN iam.role r ON r.id = ur.role_id
               LEFT JOIN iam.role_permission rp ON rp.role_id = r.id
               WHERE ur.user_id = $1 AND (ur.valid_to IS NULL OR ur.valid_to > now())""",
            pr.user_id,
        )
    else:
        rows = await conn.fetch(
            """SELECT r.code, rp.permission_code, m.is_owner FROM iam.company_member m
               LEFT JOIN iam.role r ON r.id = m.role_id
               LEFT JOIN iam.role_permission rp ON rp.role_id = r.id
               WHERE m.user_id = $1 AND m.company_id = $2 AND m.status = 'ACTIVE'""",
            pr.user_id, pr.company_id,
        ) if pr.company_id else []
    for r in rows:
        if r["code"]:
            pr.roles.add(r["code"])
        if r["permission_code"]:
            pr.permissions.add(r["permission_code"])
        if "is_owner" in r.keys() and r["is_owner"]:
            pr.is_owner = True
    if pr.is_owner:
        # the owner of a station operating company holds the station permissions only, never a carrier's (1099)
        perms = await conn.fetch(
            "SELECT code FROM iam.permission WHERE scope IN ('COMPANY','BOTH') AND ($1 <> 'STATION' OR module = 'station')",
            pr.portal)
        pr.permissions |= {p["code"] for p in perms}


def _presented_token(request: Request) -> Optional[str]:
    """The web uses the HttpOnly session cookie; mobile apps send their access token as a bearer token."""
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer ") and request.headers.get("x-masslak-client") in ("android", "ios"):
        return auth[7:].strip() or None
    return request.cookies.get(SESSION_COOKIE)


def sales_channel(request: Request) -> str:
    """The sales channel of a passenger request (sales.channel): the apps sign in with a bearer token and their client
    header, as _presented_token reads it; anything else is the website. Which ways of paying are open is set per
    channel (fin.payment_method.channels), so an app booking is checked against the app's switches."""
    client = request.headers.get("x-masslak-client")
    if client in ("android", "ios") and request.headers.get("authorization", "").lower().startswith("bearer "):
        return "APP_ANDROID" if client == "android" else "APP_IOS"
    return "WEB"


async def optional_principal(request: Request) -> Optional[Principal]:
    token = _presented_token(request)
    if not token:
        return None
    ctx = base_context(request)
    async with db.transaction(db.Context(request_id=ctx.request_id, ip=ctx.ip, scope="SYSTEM")) as conn:
        pr = await load_principal(conn, token)
        if pr:
            # a request a screen sends by itself (the notification bell) is not the user's activity (1146)
            if request.headers.get("x-masslak-background") != "1":
                await conn.execute("UPDATE iam.user_session SET last_seen_at = now() WHERE id = $1", pr.session_id)
        else:
            # a session idle past its portal's period ends here (1146), and says so
            await conn.execute(
                """UPDATE iam.user_session SET revoked_at = now(), revoke_reason = $2
                    WHERE token_hash = $1 AND revoked_at IS NULL
                      AND last_seen_at <= now() - make_interval(mins => iam.idle_minutes(portal))""", token_hash(token), IDLE)
            # ended by a sign-in on another device (one session per portal, 1142): said so, not just "sign in"
            reason = await conn.fetchval("SELECT revoke_reason FROM iam.user_session WHERE token_hash = $1", token_hash(token))
            request.state.session_replaced = reason == REPLACED
            request.state.session_idle = reason == IDLE
    if pr:
        request.state.principal = pr
    return pr


STAFF_PORTALS = {"OPERATOR", "AGENCY", "PLATFORM", "INSPECTOR", "DRIVER", "STATION"}


def mfa_required_for(portal: str, account_requires: bool, has_factor: bool, policy: mfa_policy.Policy) -> bool:
    """Anyone who enrolled a second factor always uses it (passengers may opt in). Staff portals, drivers included,
    also need one when the account requires it or when the platform's policy requires one for the portal
    (sys.setting auth.mfa, owner's decision 2); platform staff always outside the sandbox."""
    if has_factor:
        return True
    if portal not in STAFF_PORTALS:
        return policy.requires(portal)
    return account_requires or policy.requires(portal)


async def require_session(request: Request, principal: Optional[Principal] = Depends(optional_principal)) -> Principal:
    """A valid session, even one that still owes its second factor (used by the MFA endpoints)."""
    if principal is None:
        if getattr(request.state, "session_replaced", False):
            raise ApiError(401, "SESSION_REPLACED", "this account signed in on another device; sign in again to continue here")
        if getattr(request.state, "session_idle", False):
            raise ApiError(401, "SESSION_IDLE", "you were signed out after a time without activity; sign in again")
        raise ApiError(401, "AUTH_REQUIRED", "login required")
    return principal


async def require_user(principal: Principal = Depends(require_session)) -> Principal:
    if principal.password_must_change:     # the temporary password is replaced before anything else (N16, 1150)
        raise ApiError(403, "PASSWORD_CHANGE_REQUIRED", "choose your own password before you continue", next="FIRST_PASSWORD")
    if principal.mfa_pending:
        raise ApiError(401, "MFA_REQUIRED", "enter the code from your authenticator app",
                       next="VERIFY" if principal.mfa_enrolled else "ENROLL")
    return principal


def require_step_up(principal: Principal) -> None:
    """A sensitive operation (1136): someone who uses a second factor must have passed it on this session within the
    last auth.mfa.step_up_minutes; otherwise 403 STEP_UP_REQUIRED, and POST /api/auth/mfa/step-up with a code."""
    if not principal.mfa_required:
        return
    recent = principal.mfa_at is not None and datetime.now(timezone.utc) - principal.mfa_at < timedelta(minutes=principal.step_up_minutes)
    if not recent:
        raise ApiError(403, "STEP_UP_REQUIRED", "confirm with a code from your second factor to continue",
                       next="STEP_UP", minutes=principal.step_up_minutes)


async def step_up_user(principal: Principal = Depends(require_user)) -> Principal:
    require_step_up(principal)
    return principal


def require_portal(*portals: str):
    async def dep(principal: Principal = Depends(require_user)) -> Principal:
        if principal.portal not in portals:
            raise forbidden("wrong portal for this operation")
        return principal
    return dep


def require_permission(*codes: str):
    """Any one of the listed permissions grants access."""
    async def dep(principal: Principal = Depends(require_user)) -> Principal:
        if not principal.permissions.intersection(codes):
            raise forbidden("missing permission: " + " | ".join(codes))
        return principal
    return dep


def public_base(request: Request) -> str:
    """The address a payer is sent back to after a provider's page: the platform's own (MASSLAK_PUBLIC_URL), never the
    Host header a client sent (reviews of October 2026, M-01). The sandbox, often reached as localhost, keeps the
    address it was called on."""
    s = get_settings()
    return (str(request.base_url) if s.sandbox else s.public_url).rstrip("/")


def context_for(request: Request, principal: Optional[Principal]) -> db.Context:
    ctx = base_context(request)
    if principal:
        ctx.user_id, ctx.party_id, ctx.session_id = principal.user_id, principal.party_id, principal.session_id
        ctx.company_id = principal.company_id
        ctx.scope = PORTAL_SCOPE.get(principal.portal, "PASSENGER")
    ctx.api_client_id = getattr(request.state, "api_client_id", None)
    return ctx


async def tx_for(request: Request, principal: Optional[Principal]) -> AsyncIterator[asyncpg.Connection]:
    async with db.transaction(context_for(request, principal)) as conn:
        yield conn
