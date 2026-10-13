"""Boarding stations (owner's decisions, October 2026; docs/operations/BOARDING_STATIONS.md; migration 1097).

The platform sets the switches and the check-in window, numbers the counters and bays of each station, and keeps the
reference numbers a carrier gives. Nothing is on by default: the platform switch is off, a station is off until it is
switched on, and the reference fields are optional until the platform's setting asks for them.
"""
import json
import uuid

import asyncpg

from ...errors import ApiError, not_found
from ...security import hash_password

SETTINGS = ("boarding.stations.enabled", "boarding.mode.state_mandated", "boarding.mode.carrier_contracted",
            "boarding.checkin.opens_minutes", "boarding.checkin.closes_minutes", "boarding.references.required",
            "boarding.board.languages", "boarding.board.rotate_seconds")


def _jsonb(value):
    return json.loads(value) if isinstance(value, str) else value


async def _refused_by_database(call):
    """The database refuses with a code (INVALID_SETTING, INVALID_GATE, NOT_FOUND): a 422 here, the others as they are."""
    try:
        return await call
    except asyncpg.RaiseError as exc:
        msg = str(exc)
        if msg.startswith("NOT_FOUND"):
            raise ApiError(404, "NOT_FOUND", msg) from exc
        if msg.startswith("INVALID_"):
            raise ApiError(422, msg.split(":", 1)[0], msg) from exc
        raise


async def settings(conn) -> dict:
    rows = await conn.fetch("SELECT key, value FROM sys.setting WHERE key = ANY($1::text[]) ORDER BY key", list(SETTINGS))
    return {r["key"]: _jsonb(r["value"]) for r in rows}


async def set_setting(conn, key: str, value) -> object:
    out = await _refused_by_database(conn.fetchval("SELECT net.set_boarding_setting($1, $2::jsonb)", key, json.dumps(value)))
    return _jsonb(out)


async def _station(conn, station_uid: uuid.UUID):
    st = await conn.fetchrow("SELECT id, uid, code, name, status FROM net.station WHERE uid = $1", station_uid)
    if st is None:
        raise not_found("station")
    return st


async def station_view(conn, station_uid: uuid.UUID) -> dict:
    st = await _station(conn, station_uid)
    board = await conn.fetchrow(
        """SELECT b.enabled, b.counter_system, b.displays, b.checkin_opens_minutes, b.checkin_closes_minutes, b.bay_mode,
                  m.uid AS manager_company_uid, m.legal_name AS manager_company_name
             FROM net.station_boarding b LEFT JOIN iam.party m ON m.id = b.manager_company_id WHERE b.station_id = $1""", st["id"])
    gates = await conn.fetch(
        """SELECT g.code, g.gate_type, g.status, p.uid AS operator_uid, p.legal_name AS operator_name
             FROM net.station_gate g LEFT JOIN iam.party p ON p.id = g.operator_company_id
            WHERE g.station_id = $1 ORDER BY g.gate_type, g.code""", st["id"])
    return {
        "uid": st["uid"], "code": st["code"], "name": st["name"], "status": st["status"],
        "boarding": dict(board) if board else {"enabled": False, "counter_system": "PLATFORM", "displays": False,
                                                "checkin_opens_minutes": None, "checkin_closes_minutes": None, "bay_mode": "TRIP",
                                                "manager_company_uid": None, "manager_company_name": None},
        "boarding_on_now": await conn.fetchval("SELECT net.boarding_station_on($1)", st["id"]),
        "gates": [dict(g) for g in gates],
    }


async def set_station_boarding(conn, station_uid: uuid.UUID, body, user_id: int) -> int:
    st = await _station(conn, station_uid)
    manager = None
    if body.manager_company_uid is not None:            # the station's administration: a station operating company (1115)
        manager = await conn.fetchval(
            """SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id
                WHERE p.uid = $1 AND c.company_type = 'STATION_OPERATOR'""", body.manager_company_uid)
        if manager is None:
            raise ApiError(422, "NOT_STATION_OPERATOR", "a station is administered by a station operating company")
    await conn.execute(
        """INSERT INTO net.station_boarding (station_id, enabled, counter_system, displays, checkin_opens_minutes,
                                             checkin_closes_minutes, manager_company_id, updated_by_user_id, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, now())
           ON CONFLICT (station_id) DO UPDATE SET enabled = excluded.enabled, counter_system = excluded.counter_system,
             displays = excluded.displays, checkin_opens_minutes = excluded.checkin_opens_minutes,
             checkin_closes_minutes = excluded.checkin_closes_minutes, manager_company_id = excluded.manager_company_id,
             updated_by_user_id = excluded.updated_by_user_id, updated_at = excluded.updated_at""",
        st["id"], body.enabled, body.counter_system, body.displays, body.checkin_opens_minutes,
        body.checkin_closes_minutes, manager, user_id)
    return st["id"]


async def open_gate(conn, station_uid: uuid.UUID, gate_type: str, operator_uid: uuid.UUID | None) -> dict:
    st = await _station(conn, station_uid)
    company_id = None
    if operator_uid is not None:
        company_id = await conn.fetchval(
            "SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", operator_uid)
        if company_id is None:
            raise not_found("operating company")
    code = await _refused_by_database(conn.fetchval("SELECT net.open_station_gate($1, $2, $3)", st["id"], gate_type, company_id))
    gate_id = await conn.fetchval("SELECT id FROM net.station_gate WHERE station_id = $1 AND code = $2", st["id"], code)
    return {"code": code, "gate_type": gate_type, "id": gate_id}


async def references(conn, company_id: int) -> dict:
    rows = await conn.fetch(
        """SELECT uid, kind, licence_type, reference_no, issued_by, issued_on, expires_on, status, created_at, retired_at
             FROM net.operation_reference WHERE company_id = $1
            ORDER BY status, kind, licence_type NULLS FIRST, reference_no""", company_id)
    return {
        "references": [dict(r) for r in rows],
        "required": (await settings(conn)).get("boarding.references.required", []),
        "missing": await conn.fetchval("SELECT net.operation_references_missing($1)", company_id),
    }


async def add_reference(conn, company_id: int, user_id: int, body) -> tuple[int, uuid.UUID]:
    number = body.reference_no.strip()
    if not number or len(number) > 60:
        raise ApiError(422, "INVALID_REFERENCE", "the number is 1 to 60 characters")
    if body.kind == "LICENCE" and not body.licence_type:
        raise ApiError(422, "INVALID_REFERENCE", "a licence names its type")
    if body.kind == "AGREEMENT" and body.licence_type:
        raise ApiError(422, "INVALID_REFERENCE", "an agreement has no licence type")
    if body.issued_on and body.expires_on and body.expires_on < body.issued_on:
        raise ApiError(422, "INVALID_REFERENCE", "the number expires after it is issued")
    try:
        row = await conn.fetchrow(
            """INSERT INTO net.operation_reference (company_id, kind, licence_type, reference_no, issued_by, issued_on,
                                                    expires_on, created_by_user_id)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING id, uid""",
            company_id, body.kind, body.licence_type, number, body.issued_by, body.issued_on, body.expires_on, user_id)
    except asyncpg.UniqueViolationError as exc:
        raise ApiError(409, "REFERENCE_EXISTS", "this number is already on file for this carrier") from exc
    return row["id"], row["uid"]


async def retire_reference(conn, uid: uuid.UUID) -> int:
    row = await conn.fetchrow(
        "UPDATE net.operation_reference SET status = 'RETIRED', retired_at = now() WHERE uid = $1 AND status = 'ACTIVE' RETURNING id",
        uid)
    if row is None:
        if await conn.fetchval("SELECT 1 FROM net.operation_reference WHERE uid = $1", uid) is None:
            raise not_found("reference")
        raise ApiError(409, "REFERENCE_RETIRED", "this number is already retired")
    return row["id"]


async def grants(conn, carrier_company_id: int | None) -> list[dict]:
    """The grants a carrier gave (its own), or every grant for the platform (carrier_company_id None)."""
    rows = await conn.fetch(
        """SELECT g.uid, g.permission, g.granted_at, g.revoked_at,
                  cp.uid AS carrier_uid, cp.legal_name AS carrier_name,
                  op.uid AS operator_uid, op.legal_name AS operator_name,
                  st.uid AS station_uid, st.code AS station_code
             FROM net.station_operator_grant g
             LEFT JOIN iam.party cp ON cp.id = g.carrier_company_id
             JOIN iam.party op ON op.id = g.operator_company_id
             LEFT JOIN net.station st ON st.id = g.station_id
            WHERE ($1::bigint IS NULL OR g.carrier_company_id = $1)
            ORDER BY g.granted_at DESC, g.id DESC""", carrier_company_id)
    return [dict(r) for r in rows]


async def add_grant(conn, carrier_company_id: int | None, operator_uid: uuid.UUID, station_uid: uuid.UUID | None,
                    permission: str, user_id: int) -> tuple[int, uuid.UUID]:
    operator_id = await conn.fetchval(
        "SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", operator_uid)
    if operator_id is None:
        raise not_found("operating company")
    if operator_id == carrier_company_id:
        raise ApiError(422, "INVALID_GRANT", "a carrier does not grant its own operations to itself")
    station_id = None
    if station_uid is not None:
        station_id = await conn.fetchval("SELECT id FROM net.station WHERE uid = $1", station_uid)
        if station_id is None:
            raise not_found("station")
    try:
        row = await conn.fetchrow(
            """INSERT INTO net.station_operator_grant (carrier_company_id, operator_company_id, station_id, permission,
                                                       granted_by_user_id)
               VALUES ($1, $2, $3, $4, $5) RETURNING id, uid""",
            carrier_company_id, operator_id, station_id, permission, user_id)
    except asyncpg.UniqueViolationError as exc:
        raise ApiError(409, "GRANT_EXISTS", "this operating company already has this permission here") from exc
    return row["id"], row["uid"]


async def revoke_grant(conn, uid: uuid.UUID, user_id: int) -> int:
    row = await conn.fetchrow(
        """UPDATE net.station_operator_grant SET revoked_at = now(), revoked_by_user_id = $2
            WHERE uid = $1 AND revoked_at IS NULL RETURNING id""", uid, user_id)
    if row is None:
        if await conn.fetchval("SELECT 1 FROM net.station_operator_grant WHERE uid = $1", uid) is None:
            raise not_found("grant")
        raise ApiError(409, "GRANT_REVOKED", "this grant is already revoked")
    return row["id"]


async def onboard_operator(conn, body, user_id: int) -> tuple[int, uuid.UUID]:
    """A station operating company (1099) with its owner: it signs in to the STATION portal only."""
    company_id = await conn.fetchval(
        "INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', $1) RETURNING id", body.legal_name.strip())
    await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'STATION_OPERATOR')", company_id)
    await conn.execute(
        """INSERT INTO iam.company (id, company_type, transport_license_no, approval_status, approved_by, approved_at)
           VALUES ($1, 'STATION_OPERATOR', $2, 'APPROVED', $3, now())""", company_id, body.license_no, user_id)
    owner_party = await conn.fetchval(
        "INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id", body.owner_name.strip())
    try:
        owner_user = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, password_hash, password_changed_at, status,
                                         preferred_locale, mfa_required)
               VALUES ($1, 'COMPANY', $2, $3, now(), 'ACTIVE',
                       (SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), true) RETURNING id""",
            owner_party, body.owner_email, hash_password(body.owner_password))
    except asyncpg.UniqueViolationError as exc:
        raise ApiError(409, "EMAIL_TAKEN", "an account with this email exists") from exc
    await conn.execute("INSERT INTO iam.company_member (user_id, company_id, is_owner) VALUES ($1, $2, true)",
                       owner_user, company_id)
    return company_id, await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", company_id)


async def operator_overview(conn, company_id: int) -> dict:
    """What a station operating company sees in its portal: the rights it holds now, and its counters."""
    grants = await conn.fetch(
        """SELECT g.uid, g.permission, g.granted_at, cp.uid AS carrier_uid, cp.legal_name AS carrier_name,
                  st.uid AS station_uid, st.code AS station_code, st.name AS station_name,
                  CASE WHEN g.station_id IS NULL THEN NULL
                       ELSE net.operator_may($1, g.carrier_company_id, g.station_id, g.permission) END AS usable_now
             FROM net.station_operator_grant g
             LEFT JOIN iam.party cp ON cp.id = g.carrier_company_id
             LEFT JOIN net.station st ON st.id = g.station_id
            WHERE g.operator_company_id = $1 AND g.revoked_at IS NULL
            ORDER BY st.code NULLS FIRST, cp.legal_name NULLS FIRST, g.permission""", company_id)
    counters = await conn.fetch(
        """SELECT st.uid AS station_uid, st.code AS station_code, g.code, g.status,
                  net.boarding_station_on(st.id) AS boarding_on_now
             FROM net.station_gate g JOIN net.station st ON st.id = g.station_id
            WHERE g.operator_company_id = $1 ORDER BY st.code, g.code""", company_id)
    administered = await conn.fetch(                    # the stations whose bays it assigns (1115)
        """SELECT st.uid AS station_uid, st.code AS station_code, st.name AS station_name, b.bay_mode
             FROM net.station_boarding b JOIN net.station st ON st.id = b.station_id
            WHERE b.manager_company_id = $1 ORDER BY st.code""", company_id)
    return {"grants": [dict(r) for r in grants], "counters": [dict(r) for r in counters],
            "administered": [dict(r) for r in administered]}
