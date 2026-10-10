"""Registration, login (web cookie or mobile tokens), token refresh, logout and the current user."""
import asyncio
import hmac
import json
import uuid
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, EmailStr, Field

from .. import crypto, db, markets, metrics, mfa, mfa_policy, ratelimit
from ..config import get_settings
from ..deps import SESSION_COOKIE, Principal, base_context, mfa_required_for, require_session, require_user
from ..errors import ApiError
from ..security import hash_password, identifier_hash, new_token, password_problem, token_hash, verify_password

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
    locale: Optional[str] = None             # defaults to the platform setting


class LoginIn(BaseModel):
    identifier: str = Field(min_length=3, max_length=200)
    password: str = Field(min_length=1, max_length=200)
    portal: Portal = "PASSENGER"
    # Mobile apps only: a random identifier the app generates at install and keeps in the device keystore
    device_id: Optional[str] = Field(default=None, min_length=16, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")
    app_version: Optional[str] = Field(default=None, max_length=20)


MOBILE_CLIENTS = {"android": "ANDROID", "ios": "IOS"}
ACCESS_MINUTES, MOBILE_SESSION_DAYS = 15, 30
REFRESH_RACE_SECONDS = 20     # a second request with the token its own rotation replaced, this soon, is a race, not a copy


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


async def _blocked(conn, *pairs) -> bool:
    """Whether any (type, value) is on the active blocklist; values are compared as digests (sec.is_blocked, 1054)."""
    for kind, value in pairs:
        if value and await conn.fetchval("SELECT sec.is_blocked($1, $2)", kind, identifier_hash("".join(str(value).split()))):
            return True
    return False


@router.post("/register", status_code=201)
async def register(body: RegisterIn, request: Request):
    problem = password_problem(body.password)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    ctx = base_context(request)
    ctx.scope = "SYSTEM"                   # creates the person, the account and the wallet in one step
    async with db.transaction(ctx) as conn:    # its own transaction, so the token stays taken whatever follows
        for ident in filter(None, (body.email, body.mobile)):
            await ratelimit.check_identifier(conn, ident)
    async with db.transaction(ctx) as conn:
        if await _blocked(conn, ("EMAIL", body.email), ("PHONE", body.mobile)):
            raise ApiError(403, "BLOCKED", "registration is not possible with these details; contact support")
        if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = $1 OR ($2::text IS NOT NULL AND mobile = $2)",
                               body.email, body.mobile):
            raise ApiError(409, "ALREADY_REGISTERED", "an account already exists for this email or mobile")
        # The chosen language if enabled, otherwise the platform default (sys.setting ui.default_locale)
        locale = body.locale if body.locale and await conn.fetchval(
            "SELECT 1 FROM ref.locale WHERE code = $1 AND is_enabled", body.locale) else await conn.fetchval(
            "SELECT coalesce((SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), 'en')")
        party_id = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id",   # contact lives on the account
            body.full_name.strip())
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'PASSENGER')", party_id)
        user_id = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, mobile, password_hash, password_changed_at,
                 status, preferred_locale)
               VALUES ($1, 'CUSTOMER', $2, $3, $4, now(), 'ACTIVE', $5) RETURNING id""",
            party_id, body.email, body.mobile, hash_password(body.password), locale)
        await conn.execute(
            # the passenger's market currency (1061): the default market until a country is known
            "INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency) VALUES ($1, 'USER', 'Passenger wallet', ref.company_currency($1))",
            party_id)
    request.state.audit = {"action": "auth.register", "object_type": "app_user", "object_id": user_id}
    return {"ok": True}


@router.post("/login")
async def login(body: LoginIn, request: Request, response: Response):
    s = get_settings()
    ident = body.identifier.strip()
    ctx = base_context(request)
    ctx.scope = "AUTH"                     # opens accounts, factors and sessions only, not the rest of the platform
    async with db.transaction(ctx) as conn:    # its own transaction, so the token stays taken whatever follows
        await ratelimit.check_identifier(conn, ident)
    async with db.transaction(ctx) as conn:
        user = await conn.fetchrow(
            """SELECT id, account_kind, password_hash, status, locked_until, failed_attempts, mfa_required,
                      ARRAY(SELECT f.factor_type FROM iam.mfa_factor f WHERE f.user_id = app_user.id
                               AND f.factor_type IN ('TOTP','SMS','WHATSAPP')
                               AND f.verified_at IS NOT NULL AND f.disabled_at IS NULL) AS mfa_factors
                 FROM iam.app_user WHERE email = $1 OR mobile = $1""", ident)
        policy = await mfa_policy.current(conn)
        blocked = await _blocked(conn, ("EMAIL" if "@" in ident else "PHONE", ident), ("DEVICE", body.device_id))
        if blocked:             # recorded, then refused once the record is committed
            await _auth_event(conn, request, "LOGIN_FAILED", "BLOCKED", user_id=user["id"] if user else None,
                              portal=body.portal, identifier=ident, reason="blocklist")
            raise_invalid = False
        elif user is None:
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
    if blocked:
        raise ApiError(403, "BLOCKED", "sign-in is not possible; contact support")
    if raise_invalid:
        raise ApiError(401, "INVALID_CREDENTIALS", "invalid login details")

    if body.portal not in PORTALS_BY_KIND.get(user["account_kind"], set()):
        raise ApiError(403, "PORTAL_NOT_ALLOWED", "this account cannot open the requested portal")

    ctx.user_id = user["id"]
    async with db.transaction(ctx) as conn:
        company_id = None
        if body.portal in ("OPERATOR", "DRIVER", "AGENCY"):
            # Agency staff open only the agency portal, carrier staff only the carrier and driver portals
            company_id = await conn.fetchval(
                """SELECT m.company_id FROM iam.company_member m JOIN iam.company c ON c.id = m.company_id
                    WHERE m.user_id = $1 AND m.status = 'ACTIVE' AND c.approval_status = 'APPROVED'
                      AND (c.company_type = 'AGENCY') = ($2 = 'AGENCY')
                    ORDER BY m.is_owner DESC LIMIT 1""", user["id"], body.portal)
            if company_id is None:
                raise ApiError(403, "COMPANY_NOT_ACTIVE", "no approved company for this account")
            ctx.company_id = company_id
            await db.apply_context(conn, ctx)  # the crew check below reads rows of that company
            if body.portal == "DRIVER" and not await conn.fetchval(
                    "SELECT 1 FROM fleet.crew_profile cp JOIN iam.app_user u ON u.party_id = cp.party_id "
                    "WHERE u.id = $1 AND cp.company_id = $2 AND cp.status = 'ACTIVE'", user["id"], company_id):
                raise ApiError(403, "NOT_A_DRIVER", "the account is not registered as crew")
        token, thash = new_token()
        client = request.headers.get("x-masslak-client", "web")
        now = datetime.now(timezone.utc)
        refresh = refresh_hash = device = access_expires = None
        if client in MOBILE_CLIENTS:
            # Mobile: a 15-minute access token and a rotating refresh token, bound to this installation
            if not body.device_id:
                raise ApiError(422, "DEVICE_REQUIRED", "mobile sign-in needs the app's device identifier")
            device = await conn.fetchval(
                """INSERT INTO iam.device (user_id, fingerprint_hash, platform, app_version, trust_status)
                   VALUES ($1, $2, $3, $4, 'TRUSTED')
                   ON CONFLICT (user_id, fingerprint_hash) DO UPDATE SET last_seen_at = now(), app_version = EXCLUDED.app_version
                   WHERE iam.device.revoked_at IS NULL
                   RETURNING id""", user["id"], token_hash(body.device_id), MOBILE_CLIENTS[client], body.app_version)
            if device is None:
                raise ApiError(403, "DEVICE_REVOKED", "this device was signed out by the account holder")
            refresh, refresh_hash = new_token()
            access_expires = now + timedelta(minutes=ACCESS_MINUTES)
            expires = now + timedelta(days=MOBILE_SESSION_DAYS)
        else:
            client, expires = "web", now + timedelta(hours=s.session_hours)
        session_id = await conn.fetchval(
            """INSERT INTO iam.user_session (user_id, portal, company_id, token_hash, ip, user_agent, expires_at,
                 client, device_id, refresh_hash, access_expires_at)
               VALUES ($1, $2, $3, $4, $5::inet, $6, $7, $8, $9, $10, $11) RETURNING id""",
            user["id"], body.portal, company_id, thash, request.state.client_ip,
            request.headers.get("user-agent", "")[:300], expires, client, device, refresh_hash, access_expires)
        await conn.execute(
            "UPDATE iam.app_user SET failed_attempts = 0, locked_until = NULL, last_login_at = now(), "
            "last_login_ip = $2::inet WHERE id = $1", user["id"], request.state.client_ip)
        await _auth_event(conn, request, "LOGIN_SUCCESS", "SUCCESS", user_id=user["id"], portal=body.portal,
                          company_id=company_id, session_id=session_id)
    factors = list(user["mfa_factors"])
    needs = mfa_required_for(body.portal, user["mfa_required"], bool(factors), policy)
    enrolled = mfa_policy.enrolled(factors, policy)
    out = {"ok": True, "portal": body.portal, "mfa": ("VERIFY" if enrolled else "ENROLL") if needs else None,
           "mfa_methods": [m for m in factors if m in policy.available()] if needs else []}
    if refresh:
        # Mobile apps keep both tokens in the Keychain or Android Keystore; nothing goes into a cookie
        return {**out, "access_token": token, "refresh_token": refresh, "access_expires_at": access_expires.isoformat(),
                "session_expires_at": expires.isoformat()}
    response.set_cookie(SESSION_COOKIE, token, max_age=s.session_hours * 3600, httponly=True,
                        secure=s.cookie_secure, samesite="strict", path="/")
    return out


class RefreshIn(BaseModel):
    refresh_token: str = Field(min_length=20, max_length=100)
    device_id: str = Field(min_length=16, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")


@router.post("/refresh")
async def refresh(body: RefreshIn, request: Request):
    """Rotates a mobile session's tokens. A refresh token works once: presenting a rotated one again means it was
    copied, so the whole session is revoked and the person must sign in again. The check and the rotation are one
    transaction holding the session's row, and the rotation only replaces the token it checked (reviews of October 2026,
    M-02): of two requests racing with the same token one wins; the other, seconds later from the same installation,
    is told to use the winner's tokens instead of being taken for a copy."""
    ctx = base_context(request)
    ctx.scope = "AUTH"
    presented = token_hash(body.refresh_token)
    device_hash = token_hash(body.device_id)
    token, thash = new_token()
    refresh_token, rhash = new_token()
    now = datetime.now(timezone.utc)
    access_expires = now + timedelta(minutes=ACCESS_MINUTES)
    outcome = "expired"
    async with db.transaction(ctx) as conn:
        sess = await conn.fetchrow(
            """SELECT s.id, s.user_id, s.portal, s.company_id, d.fingerprint_hash FROM iam.user_session s
                 JOIN iam.device d ON d.id = s.device_id
                WHERE s.refresh_hash = $1 AND s.revoked_at IS NULL AND s.expires_at > now() AND d.revoked_at IS NULL
                FOR UPDATE OF s""", presented)
        if sess is None:
            reused = await conn.fetchrow(
                """SELECT s.id, s.user_id, s.portal, s.access_expires_at, d.fingerprint_hash FROM iam.user_session s
                     JOIN iam.device d ON d.id = s.device_id
                    WHERE s.prev_refresh_hash = $1 AND s.revoked_at IS NULL FOR UPDATE OF s""", presented)
            if reused:
                rotated_at = reused["access_expires_at"] - timedelta(minutes=ACCESS_MINUTES)
                if (now - rotated_at).total_seconds() <= REFRESH_RACE_SECONDS and \
                        hmac.compare_digest(bytes(reused["fingerprint_hash"]), device_hash):
                    outcome = "race"                      # the same installation, a moment after its own rotation
                else:
                    await conn.execute("UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'REFRESH_REUSE' WHERE id = $1",
                                       reused["id"])
                    await _auth_event(conn, request, "SESSION_REVOKED", "BLOCKED", user_id=reused["user_id"],
                                      portal=reused["portal"], session_id=reused["id"], reason="refresh_token_reuse")
        elif not hmac.compare_digest(bytes(sess["fingerprint_hash"]), device_hash):
            pass                                          # a token moved to another installation is refused
        else:
            done = await conn.execute(
                """UPDATE iam.user_session SET token_hash = $2, prev_refresh_hash = refresh_hash, refresh_hash = $3,
                     access_expires_at = $4, last_seen_at = now() WHERE id = $1 AND refresh_hash = $5""",
                sess["id"], thash, rhash, access_expires, presented)
            if done == "UPDATE 1":
                outcome = "rotated"
                await _auth_event(conn, request, "TOKEN_REFRESH", "SUCCESS", user_id=sess["user_id"], portal=sess["portal"],
                                  company_id=sess["company_id"], session_id=sess["id"])
    if outcome == "race":
        raise ApiError(409, "REFRESH_RACE", "this token was just rotated by another request; use the tokens it returned")
    if outcome != "rotated":
        raise ApiError(401, "SESSION_EXPIRED", "sign in again")
    return {"access_token": token, "refresh_token": refresh_token, "access_expires_at": access_expires.isoformat()}


@router.post("/logout")
async def logout(request: Request, response: Response, principal: Principal = Depends(require_session)):
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
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    async with db.transaction(ctx) as conn:
        if principal.company_id:
            row = await conn.fetchrow(
                "SELECT p.legal_name, p.uid FROM iam.party p WHERE p.id = $1", principal.company_id)
            code = await conn.fetchval(
                "SELECT code3 FROM net.carrier_code WHERE company_id = $1 AND status = 'ACTIVE' LIMIT 1",
                principal.company_id)
            company = {"name": row["legal_name"], "uid": str(row["uid"]), "code": code}
        # the market the screens show times and money in (1061): the company's, or the person's
        market = (await markets.of_party(conn, principal.company_id or principal.party_id)).public()
    return {
        "uid": principal.user_uid, "name": principal.display_name, "email": principal.email,
        "portal": principal.portal, "locale": principal.locale, "company": company, "market": market,
        "roles": sorted(principal.roles), "permissions": sorted(principal.permissions), "is_owner": principal.is_owner,
        "mfa": {"enrolled": principal.mfa_enrolled, "required": principal.mfa_required},
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


# ---------------------------------------------------------------- two-factor sign-in (owner's decision 2)
# The methods open on the platform (sys.setting auth.mfa, app.mfa_policy): an authenticator app (TOTP), a code by text
# message or by WhatsApp. A person may hold several; the second step accepts any of them, or a recovery code.
MFA_MAX_FAILURES = 5
CODE_TRIES = 5                          # wrong entries of one message code before it is closed
SECRET_COLUMN = "iam.mfa_factor.secret"
RECOVERY_COLUMN = "iam.mfa_factor.recovery"
PHONE_COLUMN = "iam.mfa_factor.phone"
Method = Literal["TOTP", "SMS", "WHATSAPP"]


class CodeIn(BaseModel):
    code: str = Field(min_length=6, max_length=20)
    # which factor the code comes from; omitted: the authenticator app, or a recovery code
    method: Optional[Method] = None


class EnrollIn(BaseModel):
    method: Method = "TOTP"
    # where message codes go; the account's mobile number when omitted
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")


class SendIn(BaseModel):
    method: Literal["SMS", "WHATSAPP"]


def _system(request: Request):
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    return ctx


def _masked(mobile: Optional[str]) -> Optional[str]:
    return ("•••" + mobile[-4:]) if mobile else None


async def _issue_recovery_codes(conn, fc: crypto.FieldCipher, user_id: int) -> list[str]:
    codes = mfa.new_recovery_codes()
    sealed = fc.encrypt(json.dumps([mfa.hash_recovery_code(c) for c in codes]), RECOVERY_COLUMN)
    await conn.execute("UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 "
                       "AND factor_type = 'RECOVERY_CODES' AND disabled_at IS NULL", user_id)
    await conn.execute("""INSERT INTO iam.mfa_factor (user_id, factor_type, secret_enc, enc_key_id, verified_at)
                          VALUES ($1, 'RECOVERY_CODES', $2, $3, now())""", user_id, sealed.ciphertext, sealed.key_id)
    return codes


async def _method_open(conn, method: str) -> mfa_policy.Policy:
    policy = await mfa_policy.current(conn)
    if method not in policy.available():
        raise ApiError(409, "MFA_METHOD_OFF", "this way of receiving codes is not open on the platform", method=method)
    return policy


async def _new_challenge(conn, fc: crypto.FieldCipher, pr: Principal, factor_id: int, channel: str, purpose: str,
                         policy: mfa_policy.Policy) -> tuple[str, uuid.UUID]:
    """A new message code for the person, within the policy's limits; any code still open is closed by it."""
    await conn.execute("SELECT pg_advisory_xact_lock(hashtext('mfa-send'), hashtext($1::bigint::text))", pr.user_id)
    recent = await conn.fetchrow(
        """SELECT max(created_at) AS last, count(*) AS n FROM iam.mfa_challenge
            WHERE user_id = $1 AND created_at > now() - interval '1 hour' AND send_error IS NULL""", pr.user_id)
    if recent["n"]:
        wait = policy.resend_seconds - (datetime.now(timezone.utc) - recent["last"]).total_seconds()
        if wait > 0:
            raise ApiError(429, "MFA_RESEND_TOO_SOON", "wait before asking for another code", retry_in=int(wait) + 1)
        if recent["n"] >= policy.sends_per_hour:
            raise ApiError(429, "MFA_TOO_MANY_CODES", "too many codes asked for in the last hour; use another method or wait")
    code, uid = mfa.new_message_code(), uuid.uuid4()
    await conn.execute("UPDATE iam.mfa_challenge SET consumed_at = now() WHERE user_id = $1 AND consumed_at IS NULL",
                       pr.user_id)
    await conn.execute(
        """INSERT INTO iam.mfa_challenge (uid, user_id, factor_id, session_id, channel, purpose, code_hash, expires_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, now() + make_interval(mins => $8))""",
        uid, pr.user_id, factor_id, pr.session_id, channel, purpose, fc.blind_index(code, f"mfa:{uid}"), policy.code_minutes)
    return code, uid


async def _deliver_code(request: Request, uid: uuid.UUID, channel: str, to: str, code: str, locale: str, minutes: int) -> None:
    """Sends the code outside any transaction, then records whether it left; a code that did not leave is closed."""
    from ..modules.notify import providers
    from ..modules.notify.render import render
    _, text = render("auth.mfa_code", "SMS", locale, {"code": code, "minutes": minutes})
    error = None
    try:
        if channel == "SMS":
            await asyncio.to_thread(providers.send_sms, to, text)
        else:
            await asyncio.to_thread(providers.send_whatsapp_code, to, code, locale, text)
    except Exception as exc:                                          # noqa: BLE001 - recorded, then answered as 503
        error = str(exc)[:300] or exc.__class__.__name__
    metrics.event("masslak_mfa_codes_total", channel=channel, outcome="failed" if error else "sent")
    async with db.transaction(_system(request)) as conn:
        await conn.execute(
            """UPDATE iam.mfa_challenge SET sent_at = CASE WHEN $2::text IS NULL THEN now() END, send_error = $2,
                 consumed_at = CASE WHEN $2::text IS NULL THEN consumed_at ELSE now() END WHERE uid = $1""", uid, error)
    if error:
        raise ApiError(503, "MFA_SEND_FAILED", "the code could not be sent; try again or use another method", method=channel)


async def _message_code_ok(conn, fc: crypto.FieldCipher, user_id: int, channel: str, purpose: str, code: str,
                           factor_id: Optional[int] = None) -> bool:
    """Checks the person's open message code; every entry counts, and a code is used once."""
    ch = await conn.fetchrow(
        """SELECT id, uid, attempts, expires_at, factor_id, code_hash FROM iam.mfa_challenge
            WHERE user_id = $1 AND channel = $2 AND purpose = $3 AND consumed_at IS NULL AND sent_at IS NOT NULL
            ORDER BY id DESC LIMIT 1 FOR UPDATE""", user_id, channel, purpose)
    if ch is None or (factor_id is not None and ch["factor_id"] != factor_id):
        return False
    if ch["expires_at"] <= datetime.now(timezone.utc):
        await conn.execute("UPDATE iam.mfa_challenge SET consumed_at = now() WHERE id = $1", ch["id"])
        return False
    ok = hmac.compare_digest(fc.blind_index(code, f"mfa:{ch['uid']}"), bytes(ch["code_hash"]))
    await conn.execute(
        """UPDATE iam.mfa_challenge SET attempts = attempts + 1,
             consumed_at = CASE WHEN $2 OR attempts + 1 >= $3 THEN now() END WHERE id = $1""", ch["id"], ok, CODE_TRIES)
    return ok


async def _second_factor_ok(conn, fc: crypto.FieldCipher, user_id: int, method: Optional[str], code: str,
                            recovery: bool) -> Optional[str]:
    """The method that accepted the code ('totp', 'sms', 'whatsapp', 'recovery_code'), or None."""
    if method in ("SMS", "WHATSAPP"):
        f = await conn.fetchval("""SELECT id FROM iam.mfa_factor WHERE user_id = $1 AND factor_type = $2
                                     AND verified_at IS NOT NULL AND disabled_at IS NULL""", user_id, method)
        if f and await _message_code_ok(conn, fc, user_id, method, "VERIFY", code, f):
            return method.lower()
        return None
    compact = code.strip().replace(" ", "")
    if compact.isdigit():
        f = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id, last_used_step FROM iam.mfa_factor
                                    WHERE user_id = $1 AND factor_type = 'TOTP' AND verified_at IS NOT NULL
                                      AND disabled_at IS NULL FOR UPDATE""", user_id)
        if f:
            step = mfa.verify(fc.decrypt(f["secret_enc"], f["enc_key_id"], SECRET_COLUMN), compact, f["last_used_step"])
            if step is not None:
                await conn.execute("UPDATE iam.mfa_factor SET last_used_step = $2 WHERE id = $1", f["id"], step)
                return "totp"
        return None
    if not recovery:
        return None
    r = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id FROM iam.mfa_factor WHERE user_id = $1
                                AND factor_type = 'RECOVERY_CODES' AND disabled_at IS NULL FOR UPDATE""", user_id)
    if r:
        hashes = json.loads(fc.decrypt(r["secret_enc"], r["enc_key_id"], RECOVERY_COLUMN))
        h = mfa.hash_recovery_code(code)
        if h in hashes:
            hashes.remove(h)
            sealed = fc.encrypt(json.dumps(hashes), RECOVERY_COLUMN)
            await conn.execute("UPDATE iam.mfa_factor SET secret_enc = $2, enc_key_id = $3 WHERE id = $1",
                               r["id"], sealed.ciphertext, sealed.key_id)
            return "recovery_code"
    return None


@router.get("/mfa/methods")
async def mfa_methods(request: Request, pr: Principal = Depends(require_session)):
    """What the second step offers this person: the methods open on the platform, the ones they hold, where codes go."""
    async with db.transaction(_system(request)) as conn:
        policy = await mfa_policy.current(conn)
        fc = await crypto.cipher(conn)
        held = await conn.fetch("""SELECT factor_type, secret_enc, enc_key_id, label, verified_at FROM iam.mfa_factor
                                    WHERE user_id = $1 AND disabled_at IS NULL""", pr.user_id)
        mobile = await conn.fetchval("SELECT mobile FROM iam.app_user WHERE id = $1", pr.user_id)
    enrolled = [f["factor_type"] for f in held if f["verified_at"] and f["factor_type"] in mfa_policy.METHODS]
    sent_to = {f["factor_type"]: _masked(fc.decrypt(f["secret_enc"], f["enc_key_id"], PHONE_COLUMN))
               for f in held if f["verified_at"] and f["factor_type"] in mfa_policy.MESSAGE_METHODS}
    return {"available": policy.available(), "enrolled": enrolled,
            "usable": [m for m in enrolled if m in policy.available()], "sent_to": sent_to,
            "account_mobile": _masked(mobile), "required": pr.mfa_required, "pending": pr.mfa_pending,
            "recovery_codes": any(f["factor_type"] == "RECOVERY_CODES" for f in held),
            "code_minutes": policy.code_minutes, "resend_seconds": policy.resend_seconds}


@router.post("/mfa/enroll")
async def mfa_enroll(request: Request, body: Optional[EnrollIn] = None, pr: Principal = Depends(require_session)):
    """Starts enrolling a method: an authenticator app gets a new secret and its otpauth URI; a text or WhatsApp
    number gets a code to prove it receives them."""
    body = body or EnrollIn()
    if pr.mfa_enrolled and pr.mfa_pending:
        raise ApiError(409, "MFA_VERIFY_FIRST", "confirm your current code before enrolling another method")
    if body.method == "TOTP":
        secret = mfa.new_secret()
        async with db.transaction(_system(request)) as conn:
            await _method_open(conn, "TOTP")
            fc = await crypto.cipher(conn)
            sealed = fc.encrypt(secret, SECRET_COLUMN)
            await conn.execute("DELETE FROM iam.mfa_factor WHERE user_id = $1 AND factor_type = 'TOTP' AND verified_at IS NULL",
                               pr.user_id)
            await conn.execute("""INSERT INTO iam.mfa_factor (user_id, factor_type, secret_enc, enc_key_id, label)
                                  VALUES ($1, 'TOTP', $2, $3, 'pending')""", pr.user_id, sealed.ciphertext, sealed.key_id)
        return {"method": "TOTP", "secret": secret, "uri": mfa.provisioning_uri(secret, pr.email or pr.user_uid),
                "digits": mfa.DIGITS, "period": mfa.STEP_SECONDS}
    async with db.transaction(_system(request)) as conn:
        policy = await _method_open(conn, body.method)
        mobile = body.mobile or await conn.fetchval("SELECT mobile FROM iam.app_user WHERE id = $1", pr.user_id)
        if not mobile:
            raise ApiError(422, "MFA_MOBILE_REQUIRED", "give the mobile number the codes should go to")
        fc = await crypto.cipher(conn)
        sealed = fc.encrypt(mobile, PHONE_COLUMN)
        await conn.execute("""UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 AND factor_type = $2
                                AND verified_at IS NULL AND disabled_at IS NULL""", pr.user_id, body.method)
        factor_id = await conn.fetchval(
            """INSERT INTO iam.mfa_factor (user_id, factor_type, secret_enc, enc_key_id, label)
               VALUES ($1, $2, $3, $4, $5) RETURNING id""", pr.user_id, body.method, sealed.ciphertext, sealed.key_id, mobile[-4:])
        code, uid = await _new_challenge(conn, fc, pr, factor_id, body.method, "ENROL", policy)
    await _deliver_code(request, uid, body.method, mobile, code, pr.locale, policy.code_minutes)
    return {"method": body.method, "sent_to": _masked(mobile), "expires_in": policy.code_minutes * 60,
            "resend_in": policy.resend_seconds}


@router.post("/mfa/send")
async def mfa_send(body: SendIn, request: Request, pr: Principal = Depends(require_session)):
    """Sends a code by text or WhatsApp message: for the second step of sign-in with a number already enrolled, or
    again for a number being enrolled."""
    async with db.transaction(_system(request)) as conn:
        policy = await _method_open(conn, body.method)
        f = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id, verified_at FROM iam.mfa_factor
                                    WHERE user_id = $1 AND factor_type = $2 AND disabled_at IS NULL
                                    ORDER BY verified_at IS NULL, id DESC LIMIT 1""", pr.user_id, body.method)
        if f is None:
            raise ApiError(409, "MFA_METHOD_NOT_ENROLLED", "this method is not set up for your account", method=body.method)
        fc = await crypto.cipher(conn)
        mobile = fc.decrypt(f["secret_enc"], f["enc_key_id"], PHONE_COLUMN)
        code, uid = await _new_challenge(conn, fc, pr, f["id"], body.method, "VERIFY" if f["verified_at"] else "ENROL", policy)
    await _deliver_code(request, uid, body.method, mobile, code, pr.locale, policy.code_minutes)
    return {"method": body.method, "sent_to": _masked(mobile), "expires_in": policy.code_minutes * 60,
            "resend_in": policy.resend_seconds}


@router.post("/mfa/confirm")
async def mfa_confirm(body: CodeIn, request: Request, pr: Principal = Depends(require_session)):
    """Finishes enrolling a method with its first code. The first method also gives ten single-use recovery codes,
    shown only once; enrolling the authenticator app again replaces them."""
    method = body.method or "TOTP"
    ok, codes = False, None
    async with db.transaction(_system(request)) as conn:
        await _method_open(conn, method)
        fc = await crypto.cipher(conn)
        f = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id FROM iam.mfa_factor
                                    WHERE user_id = $1 AND factor_type = $2 AND verified_at IS NULL AND disabled_at IS NULL
                                    ORDER BY id DESC LIMIT 1""", pr.user_id, method)
        if f is None:
            raise ApiError(409, "MFA_NOT_STARTED", "start enrolment first")
        step = None
        if method == "TOTP":
            step = mfa.verify(fc.decrypt(f["secret_enc"], f["enc_key_id"], SECRET_COLUMN), body.code, None)
            ok = step is not None
        else:
            ok = await _message_code_ok(conn, fc, pr.user_id, method, "ENROL", body.code, f["id"])
        if ok:
            await conn.execute("""UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 AND factor_type = $2
                                    AND verified_at IS NOT NULL AND disabled_at IS NULL""", pr.user_id, method)
            await conn.execute("UPDATE iam.mfa_factor SET verified_at = now(), last_used_step = $2, "
                               "label = CASE WHEN factor_type = 'TOTP' THEN 'authenticator' ELSE label END WHERE id = $1",
                               f["id"], step)
            has_codes = await conn.fetchval("SELECT EXISTS (SELECT 1 FROM iam.mfa_factor WHERE user_id = $1 "
                                            "AND factor_type = 'RECOVERY_CODES' AND disabled_at IS NULL)", pr.user_id)
            if method == "TOTP" or not has_codes:
                codes = await _issue_recovery_codes(conn, fc, pr.user_id)
            await conn.execute("UPDATE iam.user_session SET mfa_passed = true, mfa_failures = 0 WHERE id = $1", pr.session_id)
        await _auth_event(conn, request, "MFA_SUCCESS" if ok else "MFA_FAILED", "SUCCESS" if ok else "FAILURE",
                          user_id=pr.user_id, portal=pr.portal, session_id=pr.session_id,
                          reason=f"enrolled_{method.lower()}" if ok else "enrol_wrong_code")
    if not ok:
        raise ApiError(422, "MFA_CODE_INVALID", "the code does not match" + ("; check the time on your phone" if method == "TOTP" else ""))
    request.state.audit = {"action": "auth.mfa_enrol", "object_type": "app_user", "object_id": pr.user_id, "reason": method}
    return {"ok": True, "method": method, "recovery_codes": codes}


@router.post("/mfa/verify")
async def mfa_verify(body: CodeIn, request: Request, response: Response, pr: Principal = Depends(require_session)):
    """Second step of sign-in: a code from the authenticator app, a code sent by text or WhatsApp message (method),
    or one of the recovery codes."""
    if not pr.mfa_pending:
        return {"ok": True}
    async with db.transaction(_system(request)) as conn:
        fc = await crypto.cipher(conn)
        how = None
        if body.method is None or body.method in (await mfa_policy.current(conn)).available():
            how = await _second_factor_ok(conn, fc, pr.user_id, body.method, body.code, recovery=True)
        if how:
            await conn.execute("UPDATE iam.user_session SET mfa_passed = true, mfa_failures = 0 WHERE id = $1",
                               pr.session_id)
            await _auth_event(conn, request, "MFA_SUCCESS", "SUCCESS", user_id=pr.user_id, portal=pr.portal,
                              session_id=pr.session_id, reason=how)
        else:
            fails = await conn.fetchval("UPDATE iam.user_session SET mfa_failures = mfa_failures + 1 WHERE id = $1 "
                                        "RETURNING mfa_failures", pr.session_id)
            await _auth_event(conn, request, "MFA_FAILED", "FAILURE", user_id=pr.user_id, portal=pr.portal,
                              session_id=pr.session_id, reason="wrong_code")
            if fails >= MFA_MAX_FAILURES:
                await conn.execute("UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'mfa_failures' "
                                   "WHERE id = $1", pr.session_id)
                await _auth_event(conn, request, "SESSION_REVOKED", "BLOCKED", user_id=pr.user_id, portal=pr.portal,
                                  session_id=pr.session_id, reason="mfa_failures")
    if not how:
        if fails >= MFA_MAX_FAILURES:
            response.delete_cookie(SESSION_COOKIE, path="/")
            raise ApiError(401, "MFA_TOO_MANY_ATTEMPTS", "too many wrong codes; sign in again")
        raise ApiError(422, "MFA_CODE_INVALID", "the code is not valid", attempts_left=MFA_MAX_FAILURES - fails)
    return {"ok": True, "method": how, "recovery_code_used": how == "recovery_code"}


@router.post("/mfa/recovery-codes")
async def mfa_new_recovery_codes(body: CodeIn, request: Request, pr: Principal = Depends(require_user)):
    """Replaces the recovery codes; needs a current code from one of the person's methods."""
    async with db.transaction(_system(request)) as conn:
        fc = await crypto.cipher(conn)
        how = await _second_factor_ok(conn, fc, pr.user_id, body.method, body.code, recovery=False)
        codes = await _issue_recovery_codes(conn, fc, pr.user_id) if how else None
    if not how:
        raise ApiError(422, "MFA_CODE_INVALID", "the code is not valid")
    request.state.audit = {"action": "auth.mfa_recovery_codes", "object_type": "app_user", "object_id": pr.user_id}
    return {"recovery_codes": codes}


@router.post("/mfa/disable")
async def mfa_disable(body: CodeIn, request: Request, pr: Principal = Depends(require_user)):
    """Turns two-factor sign-in off, unless the account or the platform's policy requires it for this portal."""
    async with db.transaction(_system(request)) as conn:
        account_requires = await conn.fetchval("SELECT mfa_required FROM iam.app_user WHERE id = $1", pr.user_id)
        if mfa_required_for(pr.portal, account_requires, False, await mfa_policy.current(conn)):
            raise ApiError(409, "MFA_REQUIRED_BY_POLICY", "two-factor sign-in is required for this account")
        fc = await crypto.cipher(conn)
        how = await _second_factor_ok(conn, fc, pr.user_id, body.method, body.code, recovery=False)
        if how:
            await conn.execute("UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 AND disabled_at IS NULL",
                               pr.user_id)
    if not how:
        raise ApiError(422, "MFA_CODE_INVALID", "the code is not valid")
    request.state.audit = {"action": "auth.mfa_disable", "object_type": "app_user", "object_id": pr.user_id}
    return {"ok": True}
