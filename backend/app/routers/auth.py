"""Registration, login, logout and the current user."""
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, EmailStr, Field

from .. import db
from ..config import get_settings
from ..deps import SESSION_COOKIE, Principal, base_context, require_user
from ..errors import ApiError
from ..security import hash_password, identifier_hash, new_token, password_problem, verify_password

router = APIRouter(prefix="/api/auth", tags=["auth"])

Portal = Literal["PASSENGER", "OPERATOR", "DRIVER", "AGENCY", "PLATFORM", "INSPECTOR"]
PORTALS_BY_KIND = {
    "CUSTOMER": {"PASSENGER"},
    "COMPANY": {"OPERATOR", "DRIVER"},
    "AGENCY": {"AGENCY"},
    "PLATFORM": {"PLATFORM", "INSPECTOR"},
}
MAX_FAILS, LOCK_MIN = 5, 15


class RegisterIn(BaseModel):
    full_name: str = Field(min_length=3, max_length=120)
    email: EmailStr
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")
    password: str = Field(min_length=1, max_length=200)
    locale: str = "ar"


class LoginIn(BaseModel):
    identifier: str = Field(min_length=3, max_length=200)
    password: str = Field(min_length=1, max_length=200)
    portal: Portal = "PASSENGER"


async def _auth_event(conn, request: Request, event: str, result: str, *, user_id=None, portal=None,
                      company_id=None, session_id=None, identifier=None, reason=None):
    await conn.execute(
        """INSERT INTO audit.auth_event (event, actor_type, user_id, identifier_hash, portal, company_id, session_id,
             ip, user_agent, result, reason, request_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8::inet, $9, $10, $11, $12)""",
        event, "USER" if user_id else "ANONYMOUS", user_id,
        identifier_hash(identifier) if identifier and not user_id else None, portal, company_id, session_id,
        request.state.client_ip, request.headers.get("user-agent", "")[:300], result, reason, request.state.request_id,
    )


@router.post("/register", status_code=201)
async def register(body: RegisterIn, request: Request):
    problem = password_problem(body.password)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    async with db.transaction(ctx) as conn:
        if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = $1 OR ($2::text IS NOT NULL AND mobile = $2)",
                               body.email, body.mobile):
            raise ApiError(409, "ALREADY_REGISTERED", "an account already exists for this email or mobile")
        locale = body.locale if await conn.fetchval("SELECT 1 FROM ref.locale WHERE code = $1 AND is_enabled",
                                                     body.locale) else "en"
        party_id = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name, email, mobile) VALUES ('PERSON', $1, $2, $3) RETURNING id",
            body.full_name.strip(), body.email, body.mobile)
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'PASSENGER')", party_id)
        user_id = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, mobile, password_hash, password_changed_at,
                 status, preferred_locale)
               VALUES ($1, 'CUSTOMER', $2, $3, $4, now(), 'ACTIVE', $5) RETURNING id""",
            party_id, body.email, body.mobile, hash_password(body.password), locale)
        await conn.execute(
            "INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency) VALUES ($1, 'USER', 'Passenger wallet', 'SYP')",
            party_id)
    request.state.audit = {"action": "auth.register", "object_type": "app_user", "object_id": user_id}
    return {"ok": True}


@router.post("/login")
async def login(body: LoginIn, request: Request, response: Response):
    s = get_settings()
    ident = body.identifier.strip()
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    async with db.transaction(ctx) as conn:
        user = await conn.fetchrow(
            """SELECT id, account_kind, password_hash, status, locked_until, failed_attempts
                 FROM iam.app_user WHERE email = $1 OR mobile = $1""", ident)
        if user is None:
            verify_password(None, body.password)
            await _auth_event(conn, request, "LOGIN_FAILED", "FAILURE", portal=body.portal, identifier=ident,
                              reason="unknown_identifier")
            raise_invalid = True
        else:
            raise_invalid = False
            if user["locked_until"] and user["locked_until"] > datetime.now(timezone.utc):
                await _auth_event(conn, request, "LOGIN_FAILED", "BLOCKED", user_id=user["id"], portal=body.portal,
                                  reason="account_locked")
                raise ApiError(423, "ACCOUNT_LOCKED", "account temporarily locked after failed attempts")
            if not verify_password(user["password_hash"], body.password) or user["status"] != "ACTIVE":
                fails = user["failed_attempts"] + 1
                locked = fails >= MAX_FAILS
                await conn.execute(
                    """UPDATE iam.app_user SET failed_attempts = $2,
                         locked_until = CASE WHEN $3 THEN now() + make_interval(mins => $4) ELSE locked_until END
                       WHERE id = $1""", user["id"], 0 if locked else fails, locked, LOCK_MIN)
                await _auth_event(conn, request, "ACCOUNT_LOCKED" if locked else "LOGIN_FAILED", "FAILURE",
                                  user_id=user["id"], portal=body.portal,
                                  reason="bad_password" if user["status"] == "ACTIVE" else "inactive")
                raise_invalid = True
    if raise_invalid:
        raise ApiError(401, "INVALID_CREDENTIALS", "invalid login details")

    if body.portal not in PORTALS_BY_KIND.get(user["account_kind"], set()):
        raise ApiError(403, "PORTAL_NOT_ALLOWED", "this account cannot open the requested portal")

    async with db.transaction(ctx) as conn:
        company_id = None
        if body.portal in ("OPERATOR", "DRIVER"):
            company_id = await conn.fetchval(
                """SELECT m.company_id FROM iam.company_member m JOIN iam.company c ON c.id = m.company_id
                    WHERE m.user_id = $1 AND m.status = 'ACTIVE' AND c.approval_status = 'APPROVED'
                    ORDER BY m.is_owner DESC LIMIT 1""", user["id"])
            if company_id is None:
                raise ApiError(403, "COMPANY_NOT_ACTIVE", "no approved company for this account")
            if body.portal == "DRIVER" and not await conn.fetchval(
                    "SELECT 1 FROM fleet.crew_profile cp JOIN iam.app_user u ON u.party_id = cp.party_id "
                    "WHERE u.id = $1 AND cp.company_id = $2 AND cp.status = 'ACTIVE'", user["id"], company_id):
                raise ApiError(403, "NOT_A_DRIVER", "the account is not registered as crew")
        token, thash = new_token()
        expires = datetime.now(timezone.utc) + timedelta(hours=s.session_hours)
        session_id = await conn.fetchval(
            """INSERT INTO iam.user_session (user_id, portal, company_id, token_hash, ip, user_agent, expires_at)
               VALUES ($1, $2, $3, $4, $5::inet, $6, $7) RETURNING id""",
            user["id"], body.portal, company_id, thash, request.state.client_ip,
            request.headers.get("user-agent", "")[:300], expires)
        await conn.execute(
            "UPDATE iam.app_user SET failed_attempts = 0, locked_until = NULL, last_login_at = now(), "
            "last_login_ip = $2::inet WHERE id = $1", user["id"], request.state.client_ip)
        await _auth_event(conn, request, "LOGIN_SUCCESS", "SUCCESS", user_id=user["id"], portal=body.portal,
                          company_id=company_id, session_id=session_id)
    response.set_cookie(SESSION_COOKIE, token, max_age=s.session_hours * 3600, httponly=True,
                        secure=s.cookie_secure, samesite="strict", path="/")
    return {"ok": True, "portal": body.portal}


@router.post("/logout")
async def logout(request: Request, response: Response, principal: Principal = Depends(require_user)):
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    async with db.transaction(ctx) as conn:
        await conn.execute("UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'logout' WHERE id = $1",
                           principal.session_id)
        await _auth_event(conn, request, "LOGOUT", "SUCCESS", user_id=principal.user_id, portal=principal.portal,
                          session_id=principal.session_id)
    response.delete_cookie(SESSION_COOKIE, path="/")
    return {"ok": True}


@router.get("/me")
async def me(request: Request, principal: Principal = Depends(require_user)):
    company = None
    if principal.company_id:
        ctx = base_context(request)
        ctx.scope = "SYSTEM"
        async with db.transaction(ctx) as conn:
            row = await conn.fetchrow(
                "SELECT p.legal_name, p.uid FROM iam.party p WHERE p.id = $1", principal.company_id)
            code = await conn.fetchval(
                "SELECT code3 FROM net.carrier_code WHERE company_id = $1 AND status = 'ACTIVE' LIMIT 1",
                principal.company_id)
            company = {"name": row["legal_name"], "uid": str(row["uid"]), "code": code}
    return {
        "uid": principal.user_uid, "name": principal.display_name, "email": principal.email,
        "portal": principal.portal, "locale": principal.locale, "company": company,
        "roles": sorted(principal.roles), "permissions": sorted(principal.permissions), "is_owner": principal.is_owner,
    }


class LocaleIn(BaseModel):
    locale: str


@router.patch("/me/locale")
async def set_locale(body: LocaleIn, request: Request, principal: Principal = Depends(require_user)):
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    async with db.transaction(ctx) as conn:
        if not await conn.fetchval("SELECT 1 FROM ref.locale WHERE code = $1 AND is_enabled", body.locale):
            raise ApiError(422, "LOCALE_NOT_ENABLED", "locale is not enabled")
        await conn.execute("UPDATE iam.app_user SET preferred_locale = $2 WHERE id = $1", principal.user_id, body.locale)
    return {"ok": True}
