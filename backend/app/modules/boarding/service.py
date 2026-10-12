"""Boarding stations (owner's decisions, October 2026; docs/operations/BOARDING_STATIONS.md; migration 1097).

The platform sets the switches and the check-in window, numbers the counters and bays of each station, and keeps the
reference numbers a carrier gives. Nothing is on by default: the platform switch is off, a station is off until it is
switched on, and the reference fields are optional until the platform's setting asks for them.
"""
import json
import uuid

import asyncpg

from ...errors import ApiError, not_found

SETTINGS = ("boarding.stations.enabled", "boarding.mode.state_mandated", "boarding.mode.carrier_contracted",
            "boarding.checkin.opens_minutes", "boarding.checkin.closes_minutes", "boarding.references.required")


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
        """SELECT enabled, counter_system, displays, checkin_opens_minutes, checkin_closes_minutes
             FROM net.station_boarding WHERE station_id = $1""", st["id"])
    gates = await conn.fetch(
        """SELECT g.code, g.gate_type, g.status, p.uid AS operator_uid, p.legal_name AS operator_name
             FROM net.station_gate g LEFT JOIN iam.party p ON p.id = g.operator_company_id
            WHERE g.station_id = $1 ORDER BY g.gate_type, g.code""", st["id"])
    return {
        "uid": st["uid"], "code": st["code"], "name": st["name"], "status": st["status"],
        "boarding": dict(board) if board else {"enabled": False, "counter_system": "PLATFORM", "displays": False,
                                                "checkin_opens_minutes": None, "checkin_closes_minutes": None},
        "boarding_on_now": await conn.fetchval("SELECT net.boarding_station_on($1)", st["id"]),
        "gates": [dict(g) for g in gates],
    }


async def set_station_boarding(conn, station_uid: uuid.UUID, body, user_id: int) -> int:
    st = await _station(conn, station_uid)
    await conn.execute(
        """INSERT INTO net.station_boarding (station_id, enabled, counter_system, displays, checkin_opens_minutes,
                                             checkin_closes_minutes, updated_by_user_id, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, now())
           ON CONFLICT (station_id) DO UPDATE SET enabled = excluded.enabled, counter_system = excluded.counter_system,
             displays = excluded.displays, checkin_opens_minutes = excluded.checkin_opens_minutes,
             checkin_closes_minutes = excluded.checkin_closes_minutes,
             updated_by_user_id = excluded.updated_by_user_id, updated_at = excluded.updated_at""",
        st["id"], body.enabled, body.counter_system, body.displays, body.checkin_opens_minutes,
        body.checkin_closes_minutes, user_id)
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
