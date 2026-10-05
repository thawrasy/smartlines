"""Request context and authentication dependencies."""
from dataclasses import dataclass, field
from typing import AsyncIterator, Optional

import asyncpg
from fastapi import Depends, Request

from . import db
from .config import get_settings
from .errors import ApiError, forbidden
from .security import token_hash

SESSION_COOKIE = "msk_session"

# Portal -> RLS scope
PORTAL_SCOPE = {
    "PASSENGER": "PASSENGER",
    "OPERATOR": "COMPANY",
    "DRIVER": "COMPANY",
    "AGENCY": "AGENCY",
    "PLATFORM": "PLATFORM",
    "INSPECTOR": "PLATFORM",
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
    mfa_enrolled: bool = False
    mfa_required: bool = False


def base_context(request: Request) -> db.Context:
    return db.Context(request_id=request.state.request_id, ip=request.state.client_ip)


async def load_principal(conn: asyncpg.Connection, token: str) -> Optional[Principal]:
    row = await conn.fetchrow(
        """
        SELECT s.id AS session_id, s.portal, s.company_id, u.id AS user_id, u.uid, u.party_id, u.email,
               u.preferred_locale, p.legal_name, s.mfa_passed, u.mfa_required,
               EXISTS (SELECT 1 FROM iam.mfa_factor f WHERE f.user_id = u.id AND f.factor_type = 'TOTP'
                          AND f.verified_at IS NOT NULL AND f.disabled_at IS NULL) AS mfa_enrolled
          FROM iam.user_session s
          JOIN iam.app_user u ON u.id = s.user_id
          JOIN iam.party p ON p.id = u.party_id
         WHERE s.token_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now() AND u.status = 'ACTIVE'
           AND (s.access_expires_at IS NULL OR s.access_expires_at > now())
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
    pr.mfa_enrolled = row["mfa_enrolled"]
    pr.mfa_required = mfa_required_for(pr.portal, row["mfa_required"], pr.mfa_enrolled)
    pr.mfa_pending = pr.mfa_required and not row["mfa_passed"]
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
        perms = await conn.fetch("SELECT code FROM iam.permission WHERE scope IN ('COMPANY','BOTH')")
        pr.permissions |= {p["code"] for p in perms}


def _presented_token(request: Request) -> Optional[str]:
    """The web uses the HttpOnly session cookie; mobile apps send their access token as a bearer token."""
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer ") and request.headers.get("x-masslak-client") in ("android", "ios"):
        return auth[7:].strip() or None
    return request.cookies.get(SESSION_COOKIE)


async def optional_principal(request: Request) -> Optional[Principal]:
    token = _presented_token(request)
    if not token:
        return None
    ctx = base_context(request)
    async with db.transaction(db.Context(request_id=ctx.request_id, ip=ctx.ip, scope="SYSTEM")) as conn:
        pr = await load_principal(conn, token)
        if pr:
            await conn.execute("UPDATE iam.user_session SET last_seen_at = now() WHERE id = $1", pr.session_id)
    if pr:
        request.state.principal = pr
    return pr


STAFF_PORTALS = {"OPERATOR", "AGENCY", "PLATFORM", "INSPECTOR"}


def mfa_required_for(portal: str, account_requires: bool, enrolled: bool) -> bool:
    """Anyone who enrolled a second factor always uses it (passengers may opt in). Staff portals also need one when
    the account requires it, and platform staff always outside the sandbox."""
    if enrolled:
        return True
    if portal not in STAFF_PORTALS:
        return False
    return account_requires or (portal == "PLATFORM" and not get_settings().sandbox)


async def require_session(principal: Optional[Principal] = Depends(optional_principal)) -> Principal:
    """A valid session, even one that still owes its second factor (used by the MFA endpoints)."""
    if principal is None:
        raise ApiError(401, "AUTH_REQUIRED", "login required")
    return principal


async def require_user(principal: Principal = Depends(require_session)) -> Principal:
    if principal.mfa_pending:
        raise ApiError(401, "MFA_REQUIRED", "enter the code from your authenticator app",
                       next="VERIFY" if principal.mfa_enrolled else "ENROLL")
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
