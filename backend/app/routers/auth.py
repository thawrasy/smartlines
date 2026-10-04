"""Registration, login, logout and the current user."""
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, EmailStr, Field

import json

from .. import crypto, db, mfa
from ..config import get_settings
from ..deps import SESSION_COOKIE, Principal, base_context, mfa_required_for, require_session, require_user
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
            """SELECT id, account_kind, password_hash, status, locked_until, failed_attempts, mfa_required,
                      EXISTS (SELECT 1 FROM iam.mfa_factor f WHERE f.user_id = app_user.id AND f.factor_type = 'TOTP'
                                 AND f.verified_at IS NOT NULL AND f.disabled_at IS NULL) AS mfa_enrolled
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
        if body.portal in ("OPERATOR", "DRIVER", "AGENCY"):
            # Agency staff open only the agency portal, carrier staff only the carrier and driver portals
            company_id = await conn.fetchval(
                """SELECT m.company_id FROM iam.company_member m JOIN iam.company c ON c.id = m.company_id
                    WHERE m.user_id = $1 AND m.status = 'ACTIVE' AND c.approval_status = 'APPROVED'
                      AND (c.company_type = 'AGENCY') = ($2 = 'AGENCY')
                    ORDER BY m.is_owner DESC LIMIT 1""", user["id"], body.portal)
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
    needs = mfa_required_for(body.portal, user["mfa_required"], user["mfa_enrolled"])
    return {"ok": True, "portal": body.portal,
            "mfa": ("VERIFY" if user["mfa_enrolled"] else "ENROLL") if needs else None}


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


# ---------------------------------------------------------------- two-factor sign-in (TOTP)
MFA_MAX_FAILURES = 5
SECRET_COLUMN = "iam.mfa_factor.secret"
RECOVERY_COLUMN = "iam.mfa_factor.recovery"


class CodeIn(BaseModel):
    code: str = Field(min_length=6, max_length=20)


def _system(request: Request):
    ctx = base_context(request)
    ctx.scope = "SYSTEM"
    return ctx


async def _issue_recovery_codes(conn, fc: crypto.FieldCipher, user_id: int) -> list[str]:
    codes = mfa.new_recovery_codes()
    sealed = fc.encrypt(json.dumps([mfa.hash_recovery_code(c) for c in codes]), RECOVERY_COLUMN)
    await conn.execute("UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 "
                       "AND factor_type = 'RECOVERY_CODES' AND disabled_at IS NULL", user_id)
    await conn.execute("""INSERT INTO iam.mfa_factor (user_id, factor_type, secret_enc, enc_key_id, verified_at)
                          VALUES ($1, 'RECOVERY_CODES', $2, $3, now())""", user_id, sealed.ciphertext, sealed.key_id)
    return codes


@router.post("/mfa/enroll")
async def mfa_enroll(request: Request, pr: Principal = Depends(require_session)):
    """Starts enrolment: returns a new secret and its otpauth URI for the authenticator app."""
    if pr.mfa_enrolled and pr.mfa_pending:
        raise ApiError(409, "MFA_VERIFY_FIRST", "confirm your current code before enrolling a new device")
    secret = mfa.new_secret()
    async with db.transaction(_system(request)) as conn:
        fc = await crypto.cipher(conn)
        sealed = fc.encrypt(secret, SECRET_COLUMN)
        await conn.execute("DELETE FROM iam.mfa_factor WHERE user_id = $1 AND factor_type = 'TOTP' AND verified_at IS NULL",
                           pr.user_id)
        await conn.execute("""INSERT INTO iam.mfa_factor (user_id, factor_type, secret_enc, enc_key_id, label)
                              VALUES ($1, 'TOTP', $2, $3, 'pending')""", pr.user_id, sealed.ciphertext, sealed.key_id)
    return {"secret": secret, "uri": mfa.provisioning_uri(secret, pr.email or pr.user_uid),
            "digits": mfa.DIGITS, "period": mfa.STEP_SECONDS}


@router.post("/mfa/confirm")
async def mfa_confirm(body: CodeIn, request: Request, pr: Principal = Depends(require_session)):
    """Finishes enrolment with the first code; returns ten single-use recovery codes, shown only once."""
    async with db.transaction(_system(request)) as conn:
        fc = await crypto.cipher(conn)
        f = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id FROM iam.mfa_factor
                                    WHERE user_id = $1 AND factor_type = 'TOTP' AND verified_at IS NULL
                                    ORDER BY id DESC LIMIT 1""", pr.user_id)
        if f is None:
            raise ApiError(409, "MFA_NOT_STARTED", "start enrolment first")
        step = mfa.verify(fc.decrypt(f["secret_enc"], f["enc_key_id"], SECRET_COLUMN), body.code, None)
        if step is None:
            await _auth_event(conn, request, "MFA_FAILED", "FAILURE", user_id=pr.user_id, portal=pr.portal,
                              session_id=pr.session_id, reason="enrol_wrong_code")
            raise ApiError(422, "MFA_CODE_INVALID", "the code does not match; check the time on your phone")
        await conn.execute("UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 AND factor_type = 'TOTP' "
                           "AND verified_at IS NOT NULL AND disabled_at IS NULL", pr.user_id)
        await conn.execute("UPDATE iam.mfa_factor SET verified_at = now(), last_used_step = $2, label = 'authenticator' "
                           "WHERE id = $1", f["id"], step)
        codes = await _issue_recovery_codes(conn, fc, pr.user_id)
        await conn.execute("UPDATE iam.user_session SET mfa_passed = true, mfa_failures = 0 WHERE id = $1", pr.session_id)
        await _auth_event(conn, request, "MFA_SUCCESS", "SUCCESS", user_id=pr.user_id, portal=pr.portal,
                          session_id=pr.session_id, reason="enrolled")
    request.state.audit = {"action": "auth.mfa_enrol", "object_type": "app_user", "object_id": pr.user_id}
    return {"ok": True, "recovery_codes": codes}


@router.post("/mfa/verify")
async def mfa_verify(body: CodeIn, request: Request, response: Response, pr: Principal = Depends(require_session)):
    """Second step of sign-in: a code from the authenticator app, or one of the recovery codes."""
    if not pr.mfa_pending:
        return {"ok": True}
    async with db.transaction(_system(request)) as conn:
        fc = await crypto.cipher(conn)
        ok, used_recovery = False, False
        f = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id, last_used_step FROM iam.mfa_factor
                                    WHERE user_id = $1 AND factor_type = 'TOTP' AND verified_at IS NOT NULL
                                      AND disabled_at IS NULL FOR UPDATE""", pr.user_id)
        if f and body.code.strip().isdigit():
            step = mfa.verify(fc.decrypt(f["secret_enc"], f["enc_key_id"], SECRET_COLUMN), body.code, f["last_used_step"])
            if step is not None:
                await conn.execute("UPDATE iam.mfa_factor SET last_used_step = $2 WHERE id = $1", f["id"], step)
                ok = True
        elif f:
            r = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id FROM iam.mfa_factor WHERE user_id = $1
                                        AND factor_type = 'RECOVERY_CODES' AND disabled_at IS NULL FOR UPDATE""", pr.user_id)
            if r:
                hashes = json.loads(fc.decrypt(r["secret_enc"], r["enc_key_id"], RECOVERY_COLUMN))
                h = mfa.hash_recovery_code(body.code)
                if h in hashes:
                    hashes.remove(h)
                    sealed = fc.encrypt(json.dumps(hashes), RECOVERY_COLUMN)
                    await conn.execute("UPDATE iam.mfa_factor SET secret_enc = $2, enc_key_id = $3 WHERE id = $1",
                                       r["id"], sealed.ciphertext, sealed.key_id)
                    ok = used_recovery = True
        if ok:
            await conn.execute("UPDATE iam.user_session SET mfa_passed = true, mfa_failures = 0 WHERE id = $1",
                               pr.session_id)
            await _auth_event(conn, request, "MFA_SUCCESS", "SUCCESS", user_id=pr.user_id, portal=pr.portal,
                              session_id=pr.session_id, reason="recovery_code" if used_recovery else "totp")
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
    if not ok:
        if fails >= MFA_MAX_FAILURES:
            response.delete_cookie(SESSION_COOKIE, path="/")
            raise ApiError(401, "MFA_TOO_MANY_ATTEMPTS", "too many wrong codes; sign in again")
        raise ApiError(422, "MFA_CODE_INVALID", "the code is not valid", attempts_left=MFA_MAX_FAILURES - fails)
    return {"ok": True, "recovery_code_used": used_recovery}


@router.post("/mfa/recovery-codes")
async def mfa_new_recovery_codes(body: CodeIn, request: Request, pr: Principal = Depends(require_user)):
    """Replaces the recovery codes; needs a current authenticator code."""
    async with db.transaction(_system(request)) as conn:
        fc = await crypto.cipher(conn)
        f = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id, last_used_step FROM iam.mfa_factor
                                    WHERE user_id = $1 AND factor_type = 'TOTP' AND verified_at IS NOT NULL
                                      AND disabled_at IS NULL FOR UPDATE""", pr.user_id)
        step = f and mfa.verify(fc.decrypt(f["secret_enc"], f["enc_key_id"], SECRET_COLUMN), body.code, f["last_used_step"])
        if not step:
            raise ApiError(422, "MFA_CODE_INVALID", "the code is not valid")
        await conn.execute("UPDATE iam.mfa_factor SET last_used_step = $2 WHERE id = $1", f["id"], step)
        codes = await _issue_recovery_codes(conn, fc, pr.user_id)
    request.state.audit = {"action": "auth.mfa_recovery_codes", "object_type": "app_user", "object_id": pr.user_id}
    return {"recovery_codes": codes}


@router.post("/mfa/disable")
async def mfa_disable(body: CodeIn, request: Request, pr: Principal = Depends(require_user)):
    """Turns the second factor off, unless the account or portal requires it."""
    async with db.transaction(_system(request)) as conn:
        account_requires = await conn.fetchval("SELECT mfa_required FROM iam.app_user WHERE id = $1", pr.user_id)
        if mfa_required_for(pr.portal, account_requires, False):
            raise ApiError(409, "MFA_REQUIRED_BY_POLICY", "two-factor sign-in is required for this account")
        fc = await crypto.cipher(conn)
        f = await conn.fetchrow("""SELECT id, secret_enc, enc_key_id, last_used_step FROM iam.mfa_factor
                                    WHERE user_id = $1 AND factor_type = 'TOTP' AND verified_at IS NOT NULL
                                      AND disabled_at IS NULL FOR UPDATE""", pr.user_id)
        if not f or not mfa.verify(fc.decrypt(f["secret_enc"], f["enc_key_id"], SECRET_COLUMN), body.code, f["last_used_step"]):
            raise ApiError(422, "MFA_CODE_INVALID", "the code is not valid")
        await conn.execute("UPDATE iam.mfa_factor SET disabled_at = now() WHERE user_id = $1 AND disabled_at IS NULL",
                           pr.user_id)
    request.state.audit = {"action": "auth.mfa_disable", "object_type": "app_user", "object_id": pr.user_id}
    return {"ok": True}
