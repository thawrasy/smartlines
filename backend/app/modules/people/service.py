"""Users and roles in every portal (owner's request N1, migration 1154).

One section for the platform, carriers, agencies and station operating companies. The platform's administrators work
with the permission users.manage, a company's with company.staff (or as the company's owner). Ready roles come from
the platform; a company or the platform may define more from the permission catalog. Nobody gives what they do not
hold: a role given or defined, and a permission granted as an exception, must be among the giver's own permissions.
Per-user exceptions grant or deny one permission until an end date and work only once a second person approves.
"""
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Literal, Optional

import asyncpg
from pydantic import BaseModel, EmailStr, Field

from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ...util import rows
from ..account.doors import temporary_password

Kind = Literal["PLATFORM", "CARRIER", "AGENCY", "STATION"]
# what a station operating company's staff may hold besides the station module (1099): managing its own people
STATION_EXTRA = ("company.staff", "company.login_log")


@dataclass
class Scope:
    kind: Kind
    company_id: Optional[int]

    @property
    def platform(self) -> bool:
        return self.kind == "PLATFORM"


class RoleIn(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    description: Optional[str] = Field(default=None, min_length=1, max_length=300)
    permissions: list[str] = Field(min_length=1, max_length=200)


class RoleUpdate(RoleIn):
    status: Literal["ACTIVE", "RETIRED"] = "ACTIVE"


class UserIn(BaseModel):
    full_name: str = Field(min_length=3, max_length=120)
    email: EmailStr
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")
    password: str = Field(min_length=12, max_length=200)
    roles: list[uuid.UUID] = Field(min_length=1, max_length=10)


class UserUpdate(BaseModel):
    roles: Optional[list[uuid.UUID]] = Field(default=None, min_length=1, max_length=10)
    status: Optional[Literal["ACTIVE", "DISABLED"]] = None


class ExceptionIn(BaseModel):
    permission: str = Field(min_length=3, max_length=80)
    effect: Literal["GRANT", "DENY"]
    valid_to: datetime
    reason: str = Field(min_length=5, max_length=500)


class DecisionIn(BaseModel):
    note: Optional[str] = Field(default=None, min_length=1, max_length=500)


# ------------------------------------------------------------------ who manages which people
async def scope_of(conn: asyncpg.Connection, pr: Principal) -> Scope:
    """The people a principal manages: the platform's staff, or their own company's."""
    if pr.portal == "PLATFORM":
        if "users.manage" not in pr.permissions:
            raise forbidden("missing permission: users.manage")
        return Scope("PLATFORM", None)
    if pr.portal not in ("OPERATOR", "AGENCY", "STATION") or not pr.company_id:
        raise forbidden("users and roles are managed from a staff portal")
    if not (pr.is_owner or "company.staff" in pr.permissions):
        raise forbidden("missing permission: company.staff")
    ctype = await conn.fetchval("SELECT company_type FROM iam.company WHERE id = $1", pr.company_id)
    kind: Kind = "AGENCY" if ctype == "AGENCY" else "STATION" if ctype == "STATION_OPERATOR" else "CARRIER"
    return Scope(kind, pr.company_id)


async def catalog_codes(conn: asyncpg.Connection, sc: Scope) -> dict[str, asyncpg.Record]:
    """The permissions people of this scope may hold."""
    if sc.platform:
        recs = await conn.fetch("SELECT * FROM iam.permission WHERE scope IN ('PLATFORM', 'BOTH') ORDER BY module, code")
    elif sc.kind == "STATION":
        recs = await conn.fetch("""SELECT * FROM iam.permission WHERE scope IN ('COMPANY', 'BOTH')
                                     AND (module = 'station' OR code = ANY($1::text[])) ORDER BY module, code""", list(STATION_EXTRA))
    else:
        recs = await conn.fetch("""SELECT * FROM iam.permission WHERE scope IN ('COMPANY', 'BOTH') AND module <> 'station'
                                   ORDER BY module, code""")
    return {r["code"]: r for r in recs}


def held(pr: Principal, sc: Scope, catalog: dict) -> set[str]:
    """What the principal may give: their own permissions; a company's owner holds the whole company catalog."""
    if not sc.platform and pr.is_owner:
        return set(catalog)
    return set(pr.permissions) & set(catalog)


def _check_giving(pr: Principal, sc: Scope, catalog: dict, codes: set[str]) -> None:
    unknown = sorted(codes - set(catalog))
    if unknown:
        raise ApiError(422, "UNKNOWN_PERMISSION", "not a permission of this portal", permissions=unknown)
    missing = sorted(codes - held(pr, sc, catalog))
    if missing:
        raise ApiError(403, "NOT_HELD", "you cannot give a permission you do not hold", permissions=missing)


async def catalog(conn: asyncpg.Connection, pr: Principal) -> dict:
    sc = await scope_of(conn, pr)
    cat = await catalog_codes(conn, sc)
    mine = held(pr, sc, cat)
    return {"kind": sc.kind, "permissions": [
        {"code": c, "module": r["module"], "description": r["description"], "sensitive": r["is_sensitive"], "grantable": c in mine}
        for c, r in cat.items()]}


# ------------------------------------------------------------------ roles
async def _roles(conn: asyncpg.Connection, sc: Scope, where: str = "", *args) -> list[asyncpg.Record]:
    holders = ("(SELECT count(*) FROM iam.user_role ur WHERE ur.role_id = r.id AND (ur.valid_to IS NULL OR ur.valid_to > now()))"
               if sc.platform else
               "(SELECT count(*) FROM iam.company_member m WHERE m.role_id = r.id AND m.company_id = $1 AND m.status = 'ACTIVE')")
    base = ("r.scope = 'PLATFORM'" if sc.platform else
            "r.scope = 'COMPANY' AND r.company_kind = $2 AND (r.company_id IS NULL OR r.company_id = $1)")
    first = () if sc.platform else (sc.company_id, sc.kind)
    n = len(first)
    extra = where.replace("$X", f"${n + 1}").replace("$Y", f"${n + 2}") if where else ""
    return await conn.fetch(
        f"""SELECT r.id, r.uid, r.code, r.name, r.description, r.status, r.is_system, r.company_id,
                   coalesce(array_agg(rp.permission_code ORDER BY rp.permission_code) FILTER (WHERE rp.permission_code IS NOT NULL), '{{}}') AS permissions,
                   {holders} AS holders
              FROM iam.role r LEFT JOIN iam.role_permission rp ON rp.role_id = r.id
             WHERE {base} {extra}
             GROUP BY r.id ORDER BY r.is_system DESC, r.name""", *first, *args)


def _role_view(r: asyncpg.Record, sc: Scope) -> dict:
    own = (r["company_id"] == sc.company_id) if not sc.platform else not r["is_system"]
    return {"uid": str(r["uid"]), "code": r["code"], "name": r["name"], "description": r["description"], "status": r["status"],
            "ready": r["is_system"], "editable": own and not r["is_system"], "permissions": list(r["permissions"]),
            "holders": r["holders"]}


async def roles(conn: asyncpg.Connection, pr: Principal) -> list[dict]:
    sc = await scope_of(conn, pr)
    # the platform's external auditor and the regulator are given through their own flows, not here
    return [_role_view(r, sc) for r in await _roles(conn, sc) if r["code"] not in ("EXTERNAL_AUDITOR", "REGULATOR")]


async def _role(conn: asyncpg.Connection, sc: Scope, uid: uuid.UUID) -> asyncpg.Record:
    found = await _roles(conn, sc, "AND r.uid = $X", uid)
    if not found:
        raise not_found("role")
    return found[0]


async def create_role(conn: asyncpg.Connection, pr: Principal, body: RoleIn) -> dict:
    sc = await scope_of(conn, pr)
    cat = await catalog_codes(conn, sc)
    codes = set(body.permissions)
    _check_giving(pr, sc, cat, codes)
    code = f"CUSTOM_{secrets.token_hex(4).upper()}"
    rid = await conn.fetchval(
        """INSERT INTO iam.role (code, name, scope, company_id, is_system, company_kind, description, created_by)
           VALUES ($1, $2, $3, $4, false, $5, $6, $7) RETURNING id""",
        code, body.name.strip(), "PLATFORM" if sc.platform else "COMPANY", sc.company_id,
        None if sc.platform else sc.kind, body.description, pr.user_id)
    await conn.executemany("INSERT INTO iam.role_permission (role_id, permission_code) VALUES ($1, $2)", [(rid, c) for c in sorted(codes)])
    uid = await conn.fetchval("SELECT uid FROM iam.role WHERE id = $1", rid)
    return _role_view(await _role(conn, sc, uid), sc)


async def update_role(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, body: RoleUpdate) -> dict:
    sc = await scope_of(conn, pr)
    r = await _role(conn, sc, uid)
    if not _role_view(r, sc)["editable"]:
        raise ApiError(409, "READY_ROLE", "a ready role is not changed; define a role of your own from it")
    cat = await catalog_codes(conn, sc)
    codes = set(body.permissions)
    # what the role already holds and stays may be kept by someone who lacks it; only additions must be held
    _check_giving(pr, sc, cat, codes - set(r["permissions"]))
    await conn.execute("UPDATE iam.role SET name = $2, description = $3, status = $4, updated_at = now() WHERE id = $1",
                       r["id"], body.name.strip(), body.description, body.status)
    await conn.execute("DELETE FROM iam.role_permission WHERE role_id = $1 AND NOT (permission_code = ANY($2::text[]))",
                       r["id"], sorted(codes))
    await conn.executemany("INSERT INTO iam.role_permission (role_id, permission_code) VALUES ($1, $2) ON CONFLICT DO NOTHING",
                           [(r["id"], c) for c in sorted(codes)])
    return _role_view(await _role(conn, sc, uid), sc)


async def _givable_roles(conn: asyncpg.Connection, pr: Principal, sc: Scope, uids: list[uuid.UUID]) -> list[asyncpg.Record]:
    if not sc.platform and len(uids) != 1:
        raise ApiError(422, "ONE_ROLE", "a member of a company's staff holds one role")
    cat = await catalog_codes(conn, sc)
    out = []
    for u in dict.fromkeys(uids):
        r = await _role(conn, sc, u)
        if r["status"] != "ACTIVE" or r["code"] in ("EXTERNAL_AUDITOR", "REGULATOR"):
            raise ApiError(409, "ROLE_NOT_GIVEN", "this role is not given here")
        _check_giving(pr, sc, cat, set(r["permissions"]) & set(cat))
        out.append(r)
    return out


# ------------------------------------------------------------------ users
async def users(conn: asyncpg.Connection, pr: Principal) -> list[dict]:
    sc = await scope_of(conn, pr)
    mfa = """EXISTS (SELECT 1 FROM iam.mfa_factor f WHERE f.user_id = u.id AND f.verified_at IS NOT NULL AND f.disabled_at IS NULL
                      AND f.factor_type IN ('TOTP','EMAIL','TELEGRAM','SMS','WHATSAPP'))"""
    if sc.platform:
        recs = await conn.fetch(
            f"""SELECT u.uid, p.legal_name AS full_name, u.email, u.username, u.status, u.last_login_at, false AS is_owner, {mfa} AS mfa_enrolled,
                       coalesce(array_agg(r.uid::text ORDER BY r.name) FILTER (WHERE r.id IS NOT NULL), '{{}}') AS roles,
                       coalesce(array_agg(r.name ORDER BY r.name) FILTER (WHERE r.id IS NOT NULL), '{{}}') AS role_names
                  FROM iam.app_user u JOIN iam.party p ON p.id = u.party_id
                  LEFT JOIN iam.user_role ur ON ur.user_id = u.id AND (ur.valid_to IS NULL OR ur.valid_to > now())
                  LEFT JOIN iam.role r ON r.id = ur.role_id
                 WHERE u.account_kind = 'PLATFORM' GROUP BY u.id, p.legal_name ORDER BY p.legal_name""")
    else:
        recs = await conn.fetch(
            f"""SELECT u.uid, p.legal_name AS full_name, u.email, u.username, m.status, u.last_login_at, m.is_owner, {mfa} AS mfa_enrolled,
                       CASE WHEN r.id IS NULL THEN '{{}}'::text[] ELSE ARRAY[r.uid::text] END AS roles,
                       CASE WHEN r.id IS NULL THEN '{{}}'::text[] ELSE ARRAY[r.name] END AS role_names
                  FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id JOIN iam.party p ON p.id = u.party_id
                  LEFT JOIN iam.role r ON r.id = m.role_id
                 WHERE m.company_id = $1 ORDER BY m.is_owner DESC, p.legal_name""", sc.company_id)
    out = rows(recs)
    for x, r in zip(out, recs):
        x["roles"], x["role_names"] = list(r["roles"]), list(r["role_names"])
    return out


async def _user(conn: asyncpg.Connection, sc: Scope, uid: uuid.UUID) -> asyncpg.Record:
    if sc.platform:
        u = await conn.fetchrow("SELECT u.id, u.status, false AS is_owner FROM iam.app_user u WHERE u.uid = $1 AND u.account_kind = 'PLATFORM'", uid)
    else:
        u = await conn.fetchrow("""SELECT u.id, m.status, m.is_owner FROM iam.app_user u
                                     JOIN iam.company_member m ON m.user_id = u.id AND m.company_id = $2 WHERE u.uid = $1""", uid, sc.company_id)
    if u is None:
        raise not_found("user")
    return u


async def add_user(conn: asyncpg.Connection, pr: Principal, body: UserIn) -> dict:
    from ...security import hash_password
    sc = await scope_of(conn, pr)
    given = await _givable_roles(conn, pr, sc, body.roles)
    kind = "PLATFORM" if sc.platform else "AGENCY" if sc.kind == "AGENCY" else "COMPANY"
    party_role = {"PLATFORM": "OPERATOR", "CARRIER": "OPERATOR", "AGENCY": "AGENCY", "STATION": "STATION_STAFF"}[sc.kind]
    party_id = await conn.fetchval("INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id", body.full_name.strip())
    await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, $2) ON CONFLICT DO NOTHING", party_id, party_role)
    try:
        user_id = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, mobile, password_hash, password_changed_at, status,
                 preferred_locale, mfa_required)
               VALUES ($1, $2, $3, $4, $5, now(), 'ACTIVE', (SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), true)
               RETURNING id""", party_id, kind, str(body.email).lower(), body.mobile, hash_password(body.password))
    except asyncpg.UniqueViolationError as exc:
        raise ApiError(409, "EMAIL_TAKEN", "this e-mail already has an account") from exc
    if sc.platform:
        await conn.executemany("INSERT INTO iam.user_role (user_id, role_id, granted_by) VALUES ($1, $2, $3)",
                               [(user_id, r["id"], pr.user_id) for r in given])
    else:
        await conn.execute("INSERT INTO iam.company_member (user_id, company_id, role_id) VALUES ($1, $2, $3)",
                           user_id, sc.company_id, given[0]["id"])
    door = await temporary_password(conn, user_id)
    uid = await conn.fetchval("SELECT uid FROM iam.app_user WHERE id = $1", user_id)
    return {"uid": str(uid), "user_id": user_id, "sign_in": door}


async def update_user(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, body: UserUpdate) -> None:
    sc = await scope_of(conn, pr)
    u = await _user(conn, sc, uid)
    if u["id"] == pr.user_id:
        raise ApiError(409, "NOT_YOURSELF", "your own roles and status are changed by another administrator")
    if u["is_owner"]:
        raise ApiError(409, "OWNER", "the company's owner is changed by the platform")
    if body.roles is not None:
        given = await _givable_roles(conn, pr, sc, body.roles)
        if sc.platform:
            await conn.execute("DELETE FROM iam.user_role WHERE user_id = $1 AND NOT (role_id = ANY($2::bigint[]))",
                               u["id"], [r["id"] for r in given])
            await conn.executemany("""INSERT INTO iam.user_role (user_id, role_id, granted_by) VALUES ($1, $2, $3)
                                      ON CONFLICT (user_id, role_id) DO NOTHING""", [(u["id"], r["id"], pr.user_id) for r in given])
        else:
            await conn.execute("UPDATE iam.company_member SET role_id = $3 WHERE user_id = $1 AND company_id = $2",
                               u["id"], sc.company_id, given[0]["id"])
    if body.status is not None and body.status != u["status"]:
        if sc.platform:
            await conn.execute("UPDATE iam.app_user SET status = $2 WHERE id = $1", u["id"], body.status)
        else:
            await conn.execute("UPDATE iam.company_member SET status = $3 WHERE user_id = $1 AND company_id = $2",
                               u["id"], sc.company_id, body.status)
        if body.status == "DISABLED":
            # a disabled member's open sessions end at once
            await conn.execute("""UPDATE iam.user_session SET revoked_at = now(), revoke_reason = 'DISABLED'
                                   WHERE user_id = $1 AND revoked_at IS NULL AND ($2::bigint IS NULL OR company_id = $2)""",
                               u["id"], sc.company_id)


# ------------------------------------------------------------------ per-user exceptions
def _exc_view(r: asyncpg.Record) -> dict:
    out = rows([r])[0]
    for k in ("id", "user_id", "company_id", "requested_by", "decided_by"):
        out.pop(k, None)
    return out


async def exceptions(conn: asyncpg.Connection, pr: Principal) -> list[dict]:
    sc = await scope_of(conn, pr)
    recs = await conn.fetch(
        """SELECT e.*, tu.uid AS user_uid, tp.legal_name AS user_name, rp.legal_name AS requested_by_name, dp.legal_name AS decided_by_name,
                  (e.status = 'ACTIVE' AND e.valid_to <= now()) AS ended
             FROM iam.permission_exception e
             JOIN iam.app_user tu ON tu.id = e.user_id JOIN iam.party tp ON tp.id = tu.party_id
             JOIN iam.app_user ru ON ru.id = e.requested_by JOIN iam.party rp ON rp.id = ru.party_id
             LEFT JOIN iam.app_user du ON du.id = e.decided_by LEFT JOIN iam.party dp ON dp.id = du.party_id
            WHERE e.company_id IS NOT DISTINCT FROM $1 ORDER BY (e.status = 'PENDING') DESC, e.created_at DESC LIMIT 500""",
        sc.company_id)
    return [_exc_view(r) for r in recs]


async def request_exception(conn: asyncpg.Connection, pr: Principal, user_uid: uuid.UUID, body: ExceptionIn) -> dict:
    sc = await scope_of(conn, pr)
    u = await _user(conn, sc, user_uid)
    if u["id"] == pr.user_id:
        raise ApiError(409, "NOT_YOURSELF", "another administrator asks for your own exceptions")
    if u["is_owner"]:
        raise ApiError(409, "OWNER", "the company's owner holds every permission of the company")
    cat = await catalog_codes(conn, sc)
    if body.permission not in cat:
        raise ApiError(422, "UNKNOWN_PERMISSION", "not a permission of this portal", permissions=[body.permission])
    if body.effect == "GRANT":
        _check_giving(pr, sc, cat, {body.permission})
    if body.valid_to.tzinfo is None:
        raise ApiError(422, "VALIDATION_FAILED", "the end date carries its time zone")
    try:
        r = await conn.fetchrow(
            """INSERT INTO iam.permission_exception (user_id, company_id, permission_code, effect, reason, valid_to, requested_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uid""",
            u["id"], sc.company_id, body.permission, body.effect, body.reason.strip(), body.valid_to, pr.user_id)
    except asyncpg.UniqueViolationError as exc:
        raise ApiError(409, "EXCEPTION_OPEN", "this person already has an open exception for this permission") from exc
    except asyncpg.CheckViolationError as exc:
        raise ApiError(422, "INVALID_WINDOW", "an exception ends in the future and lasts at most a year") from exc
    return {"uid": str(r["uid"]), "status": "PENDING"}


async def decide(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, action: Literal["approve", "reject", "revoke"],
                 note: Optional[str]) -> dict:
    sc = await scope_of(conn, pr)
    e = await conn.fetchrow("SELECT * FROM iam.permission_exception WHERE uid = $1 AND company_id IS NOT DISTINCT FROM $2 FOR UPDATE",
                            uid, sc.company_id)
    if e is None:
        raise not_found("exception")
    if action in ("approve", "reject"):
        if e["status"] != "PENDING":
            raise ApiError(409, "ALREADY_DECIDED", "this exception was already decided")
        if pr.user_id in (e["requested_by"], e["user_id"]):
            raise ApiError(409, "FOUR_EYES", "a second person decides: not the one who asked, nor the one it is for")
        if action == "approve" and e["effect"] == "GRANT":
            _check_giving(pr, sc, await catalog_codes(conn, sc), {e["permission_code"]})
        status = "ACTIVE" if action == "approve" else "REJECTED"
        await conn.execute("""UPDATE iam.permission_exception SET status = $2, decided_by = $3, decided_at = now(), decision_note = $4
                               WHERE id = $1""", e["id"], status, pr.user_id, note)
    else:
        if e["status"] != "ACTIVE":
            raise ApiError(409, "NOT_ACTIVE", "only an active exception is revoked")
        status = "REVOKED"
        await conn.execute("UPDATE iam.permission_exception SET status = 'REVOKED', decision_note = coalesce($2, decision_note) WHERE id = $1",
                           e["id"], note)
    return {"uid": str(uid), "status": status}
