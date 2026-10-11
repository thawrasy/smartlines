"""Account and privacy use cases for the signed-in person, and the platform side of erasure requests."""
import uuid
from datetime import datetime, timezone

import asyncpg

from ... import db
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ...security import hash_password, password_problem, verify_password
from ...util import row_dict, rows

CONSENT_PURPOSES = ("MARKETING", "LOCATION", "PARTNER_SHARING")
POLICY_VERSION = "2026-10"


async def auth_event(conn, ctx: db.Context, pr: Principal, event: str, reason: str | None = None) -> None:
    await conn.execute(
        """INSERT INTO audit.auth_event (event, actor_type, user_id, portal, company_id, session_id, ip, result, reason)
           VALUES ($1, 'USER', $2, $3, $4, $5, $6::inet, 'SUCCESS', $7)""",
        event, pr.user_id, pr.portal, pr.company_id, pr.session_id, ctx.ip, reason)


# ------------------------------------------------------------------ sessions and password
async def security(conn, pr: Principal) -> dict:
    sessions = await conn.fetch(
        """SELECT id, portal, host(ip) AS ip, user_agent, issued_at, last_seen_at, expires_at, id = $2 AS current
             FROM iam.user_session WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()
            ORDER BY last_seen_at DESC""", pr.user_id, pr.session_id)
    changed = await conn.fetchval("SELECT password_changed_at FROM iam.app_user WHERE id = $1", pr.user_id)
    async with db.audit_reader() as audit:
        events = await audit.fetch(
            """SELECT event, result, portal, host(ip) AS ip, ts FROM audit.auth_event
                WHERE user_id = $1 ORDER BY ts DESC LIMIT 15""", pr.user_id)
    return {"sessions": rows(sessions), "password_changed_at": changed.isoformat() if changed else None,
            "mfa": {"enrolled": pr.mfa_enrolled, "required": pr.mfa_required}, "events": rows(events)}


async def revoke_session(conn, ctx: db.Context, pr: Principal, session_id: int) -> None:
    n = await conn.execute(
        "UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'USER' WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
        session_id, pr.user_id)
    if n.endswith(" 0"):
        raise not_found("session")
    await auth_event(conn, ctx, pr, "SESSION_REVOKED", "signed out by the user")


async def revoke_others(conn, ctx: db.Context, pr: Principal) -> int:
    n = await conn.execute(
        """UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'USER'
            WHERE user_id = $1 AND id <> $2 AND revoked_at IS NULL""", pr.user_id, pr.session_id)
    count = int(n.split()[-1])
    if count:
        await auth_event(conn, ctx, pr, "SESSION_REVOKED", f"signed out {count} other sessions")
    return count


async def change_password(conn, ctx: db.Context, pr: Principal, current: str, new: str) -> None:
    """Needs the current password; signs out every other session so a stolen session cannot outlive the change."""
    stored = await conn.fetchval("SELECT password_hash FROM iam.app_user WHERE id = $1", pr.user_id)
    if not verify_password(stored, current):
        raise ApiError(422, "PASSWORD_WRONG", "the current password is not correct")
    problem = password_problem(new, pr.email, pr.display_name)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    if verify_password(stored, new):
        raise ApiError(422, "PASSWORD_SAME", "choose a password you have not been using")
    await conn.execute("UPDATE iam.app_user SET password_hash = $2, password_changed_at = now() WHERE id = $1",
                       pr.user_id, hash_password(new))
    await revoke_others(conn, ctx, pr)
    await auth_event(conn, ctx, pr, "PASSWORD_CHANGED")


async def deactivate(conn, ctx: db.Context, pr: Principal, password: str) -> None:
    """Closes the owner's own passenger account. Nothing is deleted: the data stays, every session ends, and signing in
    again with the same details reactivates it (1085, the owner's rule of 10 October 2026). Erasure is a different
    request (request_erasure)."""
    if pr.portal != "PASSENGER":
        raise ApiError(409, "DEACTIVATE_STAFF", "staff accounts are closed by their company or the platform")
    stored = await conn.fetchval("SELECT password_hash FROM iam.app_user WHERE id = $1", pr.user_id)
    if not verify_password(stored, password):
        raise ApiError(422, "PASSWORD_WRONG", "the password is not correct")
    if await conn.fetchval(
            """SELECT 1 FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id
                WHERE b.booker_party_id = $1 AND b.status = 'CONFIRMED' AND t.departure_at > now()""", pr.party_id):
        raise ApiError(409, "UPCOMING_TRIPS", "the person has upcoming trips; close the account after they travel or cancel")
    await conn.execute("UPDATE iam.app_user SET status = 'DEACTIVATED' WHERE id = $1", pr.user_id)
    await conn.execute("UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'DEACTIVATED' "
                       "WHERE user_id = $1 AND revoked_at IS NULL", pr.user_id)
    await auth_event(conn, ctx, pr, "ACCOUNT_DEACTIVATED")


# ------------------------------------------------------------------ mobile devices
async def devices(conn, pr: Principal) -> list[dict]:
    return rows(await conn.fetch(
        """SELECT d.id, d.platform, d.app_version, d.first_seen_at, d.last_seen_at, d.revoked_at,
                  d.id = (SELECT device_id FROM iam.user_session WHERE id = $2) AS current
             FROM iam.device d WHERE d.user_id = $1 ORDER BY d.last_seen_at DESC""", pr.user_id, pr.session_id))


async def revoke_device(conn, ctx: db.Context, pr: Principal, device_id: int) -> None:
    """A lost phone: the device can no longer sign in or refresh, and its sessions end now."""
    n = await conn.execute("UPDATE iam.device SET revoked_at = now(), trust_status = 'REVOKED' WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
                           device_id, pr.user_id)
    if n.endswith(" 0"):
        raise not_found("device")
    await conn.execute("UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'DEVICE_REVOKED' WHERE device_id = $1 AND revoked_at IS NULL",
                       device_id)
    await conn.execute("DELETE FROM iam.push_token WHERE device_id = $1", device_id)
    await auth_event(conn, ctx, pr, "SESSION_REVOKED", "device signed out")


async def register_push(conn, pr: Principal, token: str) -> None:
    device = await conn.fetchval("SELECT device_id FROM iam.user_session WHERE id = $1", pr.session_id)
    if device is None:
        raise ApiError(409, "NOT_A_DEVICE", "push tokens are registered from the mobile apps")
    await conn.execute(
        """INSERT INTO iam.push_token (device_id, token) VALUES ($1, $2)
           ON CONFLICT (device_id) DO UPDATE SET token = EXCLUDED.token, updated_at = now()""", device, token)


# ------------------------------------------------------------------ privacy
async def consents(conn, pr: Principal) -> list[dict]:
    latest = await conn.fetch(
        """SELECT DISTINCT ON (purpose) purpose, granted, created_at FROM gov.consent
            WHERE party_id = $1 AND withdrawn_at IS NULL ORDER BY purpose, created_at DESC""", pr.party_id)
    have = {r["purpose"]: r for r in latest}
    return [{"purpose": p, "granted": bool(have[p]["granted"]) if p in have else False,
             "updated_at": have[p]["created_at"].isoformat() if p in have else None} for p in CONSENT_PURPOSES]


async def set_consent(conn, pr: Principal, purpose: str, granted: bool) -> None:
    if purpose not in CONSENT_PURPOSES:
        raise ApiError(422, "CONSENT_PURPOSE", "unknown purpose")
    await conn.execute(
        "INSERT INTO gov.consent (party_id, purpose, granted, source, policy_version) VALUES ($1, $2, $3, 'ACCOUNT_SETTINGS', $4)",
        pr.party_id, purpose, granted, POLICY_VERSION)


async def export(conn, ctx: db.Context, pr: Principal) -> dict:
    """Everything held about the person, in a portable form. Document numbers stay masked (last four only)."""
    profile = await conn.fetchrow(
        """SELECT u.uid, u.email, u.mobile, u.preferred_locale, u.created_at, u.last_login_at, p.legal_name
             FROM iam.app_user u JOIN iam.party p ON p.id = u.party_id WHERE u.id = $1""", pr.user_id)
    bookings = await conn.fetch(
        """SELECT b.id, b.booking_ref, b.status, b.total_amount, b.currency, b.created_at, t.trip_no
             FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id
            WHERE b.booker_party_id = $1 ORDER BY b.created_at""", pr.party_id)
    async with db.system_scope(conn, ctx):
        passengers = await conn.fetch(
            """SELECT b.booking_ref, p.full_name, p.nationality, p.id_type, p.id_no_last4, k.ticket_no, k.seat_no, k.status
                 FROM sales.passenger p JOIN sales.booking b ON b.id = p.booking_id JOIN sales.ticket k ON k.passenger_id = p.id
                WHERE b.booker_party_id = $1 ORDER BY b.created_at""", pr.party_id)
    wallet = await conn.fetch(
        """SELECT e.direction, e.amount, e.balance_after, e.created_at, t.txn_type, t.memo
             FROM fin.ledger_entry e JOIN fin.ledger_txn t ON t.id = e.txn_id JOIN fin.wallet w ON w.id = e.wallet_id
            WHERE w.owner_party_id = $1 AND w.wallet_type = 'USER' ORDER BY e.created_at, e.id""", pr.party_id)
    notes = await conn.fetch(
        "SELECT template_code, channel, created_at FROM crm.notification WHERE user_id = $1 ORDER BY created_at", pr.user_id)
    async with db.audit_reader() as audit:
        signins = await audit.fetch(
            "SELECT event, result, portal, host(ip) AS ip, ts FROM audit.auth_event WHERE user_id = $1 ORDER BY ts", pr.user_id)
    await conn.execute(
        """INSERT INTO gov.subject_request (party_id, user_id, kind, status, due_at, result, handled_at)
           VALUES ($1, $2, 'ACCESS', 'DONE', now(), 'self-service export', now())""", pr.party_id, pr.user_id)
    return {"generated_at": datetime.now(timezone.utc).isoformat(), "profile": row_dict(profile),
            "bookings": [{k: v for k, v in r.items() if k != "id"} for r in rows(bookings)],
            "passengers": rows(passengers), "wallet": rows(wallet), "notifications": rows(notes),
            "consents": await consents(conn, pr), "sign_ins": rows(signins)}


async def request_erasure(conn, pr: Principal, reason: str | None) -> str:
    if pr.portal != "PASSENGER":
        raise ApiError(409, "ERASURE_STAFF", "staff accounts are closed by their company or the platform")
    try:
        uid = await conn.fetchval(
            """INSERT INTO gov.subject_request (party_id, user_id, kind, due_at, reason)
               VALUES ($1, $2, 'ERASE', now() + interval '30 days', $3) RETURNING uid""", pr.party_id, pr.user_id, reason)
    except asyncpg.UniqueViolationError:
        raise ApiError(409, "REQUEST_OPEN", "an erasure request is already open")
    return str(uid)


async def requests(conn, pr: Principal) -> list[dict]:
    return rows(await conn.fetch(
        "SELECT uid, kind, status, due_at, created_at, handled_at FROM gov.subject_request WHERE party_id = $1 ORDER BY created_at DESC",
        pr.party_id))


# ------------------------------------------------------------------ platform
def privacy_staff(pr: Principal) -> None:
    if pr.portal != "PLATFORM" or "privacy.manage" not in pr.permissions:
        raise forbidden("missing permission: privacy.manage")


async def open_requests(conn) -> list[dict]:
    return rows(await conn.fetch(
        """SELECT r.uid, r.kind, r.status, r.due_at, r.created_at, r.reason, p.legal_name, u.email
             FROM gov.subject_request r JOIN iam.party p ON p.id = r.party_id LEFT JOIN iam.app_user u ON u.id = r.user_id
            WHERE r.status IN ('RECEIVED','IN_PROGRESS') ORDER BY r.due_at"""))


async def complete_erasure(conn, pr: Principal, request_uid: uuid.UUID) -> int:
    """Anonymises the account and party (name, identity, email, mobile, password, second factor) and ends every session.
    Refused while the person has an upcoming trip or is under a legal hold. Bookings, tickets, passenger manifests and ledger entries of past
    trips remain under the anonymised party, as financial, tax and transport records must be kept."""
    privacy_staff(pr)
    r = await conn.fetchrow("SELECT * FROM gov.subject_request WHERE uid = $1 FOR UPDATE", request_uid)
    if r is None:
        raise not_found("request")
    if r["kind"] != "ERASE" or r["status"] not in ("RECEIVED", "IN_PROGRESS"):
        raise ApiError(409, "INVALID_TRANSITION", "this request is not an open erasure request")
    if await conn.fetchval(
            """SELECT 1 FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id
                WHERE b.booker_party_id = $1 AND b.status = 'CONFIRMED' AND t.departure_at > now()""", r["party_id"]):
        raise ApiError(409, "UPCOMING_TRIPS", "the person has upcoming trips; erase after they travel or cancel")
    # gov.erase_party pseudonymises the person and their old passenger rows, withdraws consents, refuses under a
    # legal hold, writes gov.erasure_log and closes the request (review 3.15)
    await conn.fetchval("SELECT gov.erase_party($1, $2)::text", r["party_id"], r["id"])
    await conn.execute("UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'ERASED' WHERE user_id = $1 AND revoked_at IS NULL",
                       r["user_id"])
    await conn.execute("DELETE FROM iam.mfa_factor WHERE user_id = $1", r["user_id"])
    return r["id"]
