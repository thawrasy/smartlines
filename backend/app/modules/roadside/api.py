"""Government bodies (N47) and the vehicle movement code (N48), migration 1169.

    Platform (authority.manage)
    GET  /api/admin/authorities                         the bodies, their members and scopes
    POST /api/admin/authorities                         {code, kind, name_ar, name_en}
    PUT  /api/admin/authorities/{code}                  {name_ar, name_en, active}
    POST /api/admin/authorities/{code}/scopes           {category, legal_basis, days}: a scope, in force once approved
    POST /api/admin/authorities/{code}/scopes/{id}/approve   by another person
    (members are added and removed by the routes of the regular trips module, schedules/api.py, which take this right too)
    GET  /api/admin/authorities/checks                  the latest roadside checks across the network
    Carrier (vehicle.placard)
    GET  /api/carrier/vehicles/{uid}/placard            the vehicle's placard in force, if any
    POST /api/carrier/vehicles/{uid}/placard            prints a placard (the next serial) when none is in force
    GET  /api/carrier/vehicles/{uid}/placard.pdf        the two pages to print
    POST /api/carrier/vehicles/{uid}/placard/revoke     {reason}: a lost or copied placard
    GET  /api/carrier/roadside-checks                   the checks of the company's vehicles
    Inspector portal (roadside.check)
    GET  /api/roadside/bodies                           the bodies the member acts for
    POST /api/roadside/scan                             {code, body, lat, lng}: opens a check and shows what the body may see
    POST /api/roadside/checks/{uid}/sample              {mode: SAMPLE|FULL}: the server draws the people
    POST /api/roadside/checks/{uid}/close               {outcome, note, people: [{ticket, outcome, note}]}
    GET  /api/roadside/checks                           the member's latest checks
"""
from __future__ import annotations

import json
import uuid
from datetime import date
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_permission, require_portal
from ...errors import ApiError, forbidden, not_found
from ...security import token_hash, vehicle_code_shape, vehicle_code_token, vehicle_code_tokens
from ...util import ticket_name
from . import movements, placard

platform = APIRouter(prefix="/api/admin/authorities", tags=["roadside"])
carrier = APIRouter(prefix="/api/carrier", tags=["roadside"])
inspector = APIRouter(prefix="/api/roadside", tags=["roadside"])

KINDS = ("INTERIOR", "PUBLIC_SECURITY", "TRAFFIC", "TRANSPORT_AUTHORITY", "FINANCE", "TRANSPORT_MINISTRY", "CUSTOMS",
         "BORDER", "POLICE", "REGULATOR", "OTHER")
CATEGORIES = ("MANIFEST_VEHICLE", "TRACKING", "MANIFEST_PERSON", "IDENTITY", "MANIFEST_CARGO", "BOOKING", "PAYMENT", "TAX",
              "REGULATORY")
# what a kind of body starts with (the platform adds or removes; each scope is approved by a second person)
DEFAULT_SCOPES = {
    "INTERIOR": ("MANIFEST_VEHICLE", "TRACKING", "MANIFEST_PERSON", "IDENTITY", "MANIFEST_CARGO"),
    "PUBLIC_SECURITY": ("MANIFEST_VEHICLE", "TRACKING", "MANIFEST_PERSON", "IDENTITY", "MANIFEST_CARGO"),
    "TRAFFIC": ("MANIFEST_VEHICLE", "TRACKING"),
    "TRANSPORT_AUTHORITY": ("MANIFEST_VEHICLE", "TRACKING", "REGULATORY", "MANIFEST_CARGO"),
    "FINANCE": ("TAX", "PAYMENT"),
}


def _platform(pr: Principal) -> None:
    if pr.portal != "PLATFORM" or "authority.manage" not in pr.permissions:
        raise forbidden("government bodies are managed by the platform")


async def _body(conn, code: str):
    row = await conn.fetchrow("SELECT id, code, authority_type, active FROM sec.authority_profile WHERE code = $1", code.upper())
    if row is None:
        raise not_found("authority")
    return row


# ------------------------------------------------------------------ platform: the register
class BodyIn(BaseModel):
    code: str = Field(pattern=r"^[A-Z][A-Z0-9-]{1,23}$")
    kind: Literal[KINDS]                                     # type: ignore[valid-type]
    name_ar: str = Field(min_length=2, max_length=200)
    name_en: str = Field(min_length=2, max_length=200)
    default_scopes: bool = True


class BodyEdit(BaseModel):
    name_ar: Optional[str] = Field(default=None, min_length=2, max_length=200)
    name_en: Optional[str] = Field(default=None, min_length=2, max_length=200)
    active: Optional[bool] = None


class ScopeIn(BaseModel):
    category: Literal[CATEGORIES]                            # type: ignore[valid-type]
    legal_basis: str = Field(min_length=3, max_length=300)
    days: int = Field(default=365, ge=1, le=1095)


@platform.get("")
async def bodies(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT a.id, a.code, a.authority_type AS kind, a.name, a.name_ar, a.name_en, a.active, a.protocol,
                      (SELECT count(*) FROM sec.authority_member m WHERE m.authority_id = a.id) AS members
                 FROM sec.authority_profile a ORDER BY a.active DESC, a.code""")
        scopes = await conn.fetch(
            """SELECT s.id, s.authority_id, s.data_category AS category, s.legal_basis, lower(s.valid) AS valid_from,
                      upper(s.valid) AS valid_to, s.approved_by IS NOT NULL AS approved, cu.email AS created_by, au.email AS approved_by
                 FROM sec.authority_scope s LEFT JOIN iam.app_user cu ON cu.id = s.created_by LEFT JOIN iam.app_user au ON au.id = s.approved_by
                WHERE upper(s.valid) > current_date ORDER BY s.authority_id, s.data_category""")
        members = await conn.fetch(
            """SELECT m.authority_id, u.uid::text AS uid, u.email, m.added_at FROM sec.authority_member m
                 JOIN iam.app_user u ON u.id = m.user_id ORDER BY u.email""")
    out = []
    for r in rows:
        d = dict(r)
        d["scopes"] = [{k: v for k, v in dict(s).items() if k != "authority_id"} for s in scopes if s["authority_id"] == r["id"]]
        d["member_list"] = [{k: v for k, v in dict(m).items() if k != "authority_id"} for m in members if m["authority_id"] == r["id"]]
        d.pop("id")
        out.append(d)
    return {"bodies": out, "kinds": list(KINDS), "categories": list(CATEGORIES)}


@platform.post("", status_code=201)
async def body_add(body: BodyIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        if await conn.fetchval("SELECT 1 FROM sec.authority_profile WHERE code = $1", body.code):
            raise ApiError(409, "AUTHORITY_EXISTS", "a body already has this code")
        aid = await conn.fetchval(
            """INSERT INTO sec.authority_profile (code, name, name_ar, name_en, authority_type, protocol, active)
               VALUES ($1, $2, $3, $4, $5, 'MANUAL', true) RETURNING id""",
            body.code, body.name_en.strip(), body.name_ar.strip(), body.name_en.strip(), body.kind)
        if body.default_scopes:
            for cat in DEFAULT_SCOPES.get(body.kind, ()):
                await conn.execute(
                    """INSERT INTO sec.authority_scope (authority_id, data_category, scope_type, legal_basis, valid, created_by)
                       VALUES ($1, $2, 'ALL', 'default for the kind of body, to be approved', daterange(current_date, current_date + 365), $3)""",
                    aid, cat, pr.user_id)
    request.state.audit = {"action": "authority.add", "object_type": "authority", "object_id": body.code}
    return {"code": body.code}


@platform.put("/{code}")
async def body_edit(code: str, body: BodyEdit, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        a = await _body(conn, code)
        await conn.execute(
            """UPDATE sec.authority_profile SET name_ar = coalesce($2, name_ar), name_en = coalesce($3, name_en),
                      name = coalesce($3, name), active = coalesce($4, active) WHERE id = $1""",
            a["id"], body.name_ar, body.name_en, body.active)
    request.state.audit = {"action": "authority.edit", "object_type": "authority", "object_id": a["code"]}
    return {"code": a["code"]}


@platform.post("/{code}/scopes", status_code=201)
async def scope_add(code: str, body: ScopeIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        a = await _body(conn, code)
        sid = await conn.fetchval(
            """INSERT INTO sec.authority_scope (authority_id, data_category, scope_type, legal_basis, valid, created_by)
               VALUES ($1, $2, 'ALL', $3, daterange(current_date, current_date + $4), $5) RETURNING id""",
            a["id"], body.category, body.legal_basis.strip(), body.days, pr.user_id)
    request.state.audit = {"action": "authority.scope_add", "object_type": "authority", "object_id": a["code"]}
    return {"id": sid, "approved": False}


@platform.post("/{code}/scopes/{sid}/approve")
async def scope_approve(code: str, sid: int, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        a = await _body(conn, code)
        s = await conn.fetchrow("SELECT created_by, approved_by FROM sec.authority_scope WHERE id = $1 AND authority_id = $2", sid, a["id"])
        if s is None:
            raise not_found("scope")
        if s["approved_by"] is not None:
            raise ApiError(409, "SCOPE_APPROVED", "this scope is already approved")
        if s["created_by"] == pr.user_id:
            raise ApiError(409, "SCOPE_SAME_PERSON", "another person approves a scope")
        await conn.execute("UPDATE sec.authority_scope SET approved_by = $2 WHERE id = $1", sid, pr.user_id)
    request.state.audit = {"action": "authority.scope_approve", "object_type": "authority", "object_id": a["code"]}
    return {"id": sid, "approved": True}


_CHECKS = """SELECT f.uid, f.created_at, f.closed_at, f.status, f.result, f.outcome, f.movement_kind, f.movement_ref,
                    f.warnings, f.sample_mode, jsonb_array_length(f.sample) AS sampled, f.note, f.lat, f.lng,
                    v.plate_no, cp.legal_name AS carrier, a.code AS body, u.email AS inspector
               FROM fleet.field_check_log f JOIN fleet.vehicle v ON v.id = f.vehicle_id
               JOIN iam.party cp ON cp.id = v.company_id
               LEFT JOIN sec.field_check_body b ON b.check_id = f.id LEFT JOIN sec.authority_profile a ON a.id = b.authority_id
               LEFT JOIN iam.app_user u ON u.id = f.inspector_user_id"""


@platform.get("/checks")
async def checks_all(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(f"{_CHECKS} ORDER BY f.created_at DESC LIMIT 200")
    return {"checks": [dict(r) for r in rows]}


# ------------------------------------------------------------------ carrier: the placard
async def _vehicle(conn, pr: Principal, uid: uuid.UUID):
    v = await conn.fetchrow(
        """SELECT v.id, v.uid::text AS uid, v.plate_no, v.passenger_seats, cp.legal_name AS carrier
             FROM fleet.vehicle v JOIN iam.party cp ON cp.id = v.company_id WHERE v.uid = $1 AND v.company_id = $2""",
        uid, pr.company_id)
    if v is None:
        raise not_found("vehicle")
    return v


def _carrier(pr: Principal) -> None:
    if pr.portal != "OPERATOR" or not pr.company_id or "vehicle.placard" not in pr.permissions:
        raise forbidden("the carrier prints its vehicles' placards")


async def _tag(conn, vehicle_id: int):
    return await conn.fetchrow(
        """SELECT t.id, t.serial, t.issued_at, t.token_hash, u.email AS issued_by FROM fleet.vehicle_qr_tag t
             LEFT JOIN iam.app_user u ON u.id = t.issued_by WHERE t.vehicle_id = $1 AND t.revoked_at IS NULL""", vehicle_id)


@carrier.get("/vehicles/{uid}/placard")
async def placard_get(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, pr, uid)
        tag = await _tag(conn, v["id"])
        revoked = await conn.fetchval("SELECT count(*) FROM fleet.vehicle_qr_tag WHERE vehicle_id = $1 AND revoked_at IS NOT NULL", v["id"])
    return {"vehicle": {"uid": v["uid"], "plate_no": v["plate_no"]},
            "placard": {k: tag[k] for k in ("serial", "issued_at", "issued_by")} if tag else None, "revoked": revoked}


@carrier.post("/vehicles/{uid}/placard", status_code=201)
async def placard_issue(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, pr, uid)
        await conn.execute("SELECT pg_advisory_xact_lock(hashtext('placard'), $1::int)", v["id"])
        if await _tag(conn, v["id"]):
            raise ApiError(409, "PLACARD_IN_FORCE", "the vehicle has a placard in force; revoke it to print another")
        serial = await conn.fetchval("SELECT coalesce(max(serial), 0) + 1 FROM fleet.vehicle_qr_tag WHERE vehicle_id = $1", v["id"])
        await conn.execute(
            "INSERT INTO fleet.vehicle_qr_tag (vehicle_id, token_hash, serial, issued_by) VALUES ($1, $2, $3, $4)",
            v["id"], token_hash(vehicle_code_token(v["uid"], serial)), serial, pr.user_id)
    request.state.audit = {"action": "vehicle.placard_issue", "object_type": "vehicle", "object_id": v["uid"]}
    return {"serial": serial}


@carrier.get("/vehicles/{uid}/placard.pdf")
async def placard_pdf(uid: uuid.UUID, request: Request, size: Literal["A4", "A3"] = "A3",
                      pr: Principal = Depends(require_portal("OPERATOR"))):
    _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, pr, uid)
        tag = await _tag(conn, v["id"])
    if tag is None:
        raise ApiError(409, "NO_PLACARD", "print a placard for the vehicle first")
    token = next((t for t in vehicle_code_tokens(v["uid"], tag["serial"]) if token_hash(t) == bytes(tag["token_hash"])), None)
    if token is None:
        raise ApiError(409, "PLACARD_KEY_RETIRED", "the key this placard was made with is retired; revoke it and print another")
    data = placard.pdf(token, v["carrier"], v["plate_no"], v["passenger_seats"], tag["serial"], size)
    request.state.audit = {"action": "vehicle.placard_pdf", "object_type": "vehicle", "object_id": v["uid"]}
    return Response(data, media_type="application/pdf",
                    headers={"Content-Disposition": f'attachment; filename="placard-{v["plate_no"]}-{tag["serial"]}.pdf"'})


class RevokeIn(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


@carrier.post("/vehicles/{uid}/placard/revoke")
async def placard_revoke(uid: uuid.UUID, body: RevokeIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _carrier(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, pr, uid)
        tag = await _tag(conn, v["id"])
        if tag is None:
            raise ApiError(409, "NO_PLACARD", "the vehicle has no placard in force")
        await conn.execute("UPDATE fleet.vehicle_qr_tag SET revoked_at = now(), revoked_by = $2, revoke_reason = $3 WHERE id = $1",
                           tag["id"], pr.user_id, body.reason.strip())
    request.state.audit = {"action": "vehicle.placard_revoke", "object_type": "vehicle", "object_id": v["uid"]}
    return {"revoked": tag["serial"]}


@carrier.get("/roadside-checks")
async def carrier_checks(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    if not pr.company_id or not pr.permissions.intersection({"vehicle.placard", "vehicle.manage", "report.company"}):
        raise forbidden("the company's roadside checks")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(f"{_CHECKS} WHERE v.company_id = $1 ORDER BY f.created_at DESC LIMIT 200", pr.company_id)
    return {"checks": [{k: v for k, v in dict(r).items() if k != "inspector"} for r in rows]}


# ------------------------------------------------------------------ inspector: scan, sample, close
inspect = require_permission("roadside.check")


async def _acting_body(conn, pr: Principal, code: Optional[str]):
    """The body a check is made for: one of the member's bodies (the one named, or the only one). Platform staff without
    a membership check for the platform itself, with every scope."""
    rows = await conn.fetch(
        """SELECT a.id, a.code, a.authority_type, a.name_ar, a.name_en FROM sec.authority_member m
             JOIN sec.authority_profile a ON a.id = m.authority_id WHERE m.user_id = $1 AND a.active ORDER BY a.code""", pr.user_id)
    if code:
        rows = [r for r in rows if r["code"] == code.upper()]
    if len(rows) == 1:
        return rows[0]
    if not rows and pr.portal == "PLATFORM" and not code:
        return None
    if not rows:
        raise forbidden("the account is not a member of an active government body")
    raise ApiError(422, "BODY_REQUIRED", "name the body the check is made for", bodies=[r["code"] for r in rows])


async def _may(conn, body, *categories: str) -> bool:
    if body is None:                                     # platform staff
        return True
    for cat in categories:
        if await conn.fetchval("SELECT sec.authority_may($1, $2)", body["id"], cat):
            return True
    return False


@inspector.get("/bodies")
async def my_bodies(request: Request, pr: Principal = Depends(inspect)):
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT a.code, a.authority_type AS kind, a.name_ar, a.name_en,
                      array(SELECT s.data_category FROM sec.authority_scope s WHERE s.authority_id = a.id AND s.approved_by IS NOT NULL
                             AND s.valid @> current_date ORDER BY 1) AS scopes
                 FROM sec.authority_member m JOIN sec.authority_profile a ON a.id = m.authority_id
                WHERE m.user_id = $1 AND a.active ORDER BY a.code""", pr.user_id)
    return {"bodies": [dict(r) for r in rows], "platform": pr.portal == "PLATFORM"}


class ScanIn(BaseModel):
    code: str = Field(min_length=10, max_length=60)
    body: Optional[str] = Field(default=None, max_length=24)
    lat: Optional[float] = Field(default=None, ge=-90, le=90)
    lng: Optional[float] = Field(default=None, ge=-180, le=180)


def _warnings(vehicle, movement, doc_expired: bool) -> list[str]:
    w = []
    if vehicle["status"] in ("BLOCKED", "IMPOUNDED", "OUT_OF_SERVICE", "RETIRED"):
        w.append("VEHICLE_BLOCKED")
    if doc_expired:
        w.append("VEHICLE_DOCUMENT_EXPIRED")
    if movement is None:
        w.append("NO_MOVEMENT")
        return w
    capacity = (movement.get("seats") or vehicle["passenger_seats"] or 0) + (movement.get("standing") or 0)
    if capacity and (movement.get("boarded") or 0) > capacity:
        w.append("OVERLOAD")
    today = date.today()
    if any(c.get("licence_expiry") and c["licence_expiry"] < today for c in movement.get("crew") or []):
        w.append("LICENCE_EXPIRED")
    if movement.get("kind") == "SCHEDULED_TRIP" and movement.get("status") == "DEPARTED" and movement.get("manifest_issued") is False:
        w.append("MANIFEST_NOT_ISSUED")
    return w


@inspector.post("/scan", status_code=201)
async def scan(body: ScanIn, request: Request, pr: Principal = Depends(inspect)):
    if pr.portal not in ("INSPECTOR", "PLATFORM"):
        raise forbidden("roadside checks are made from the inspector portal")
    code = vehicle_code_shape(body.code)
    if code is None:
        raise ApiError(422, "CODE_INVALID", "this is not a movement code of the platform")
    async with db.transaction(context_for(request, pr)) as conn:
        acting = await _acting_body(conn, pr, body.body)
        # the placard is found by the code's digest: a code no placard was printed with answers as unknown
        tag = await conn.fetchrow("SELECT id, vehicle_id, revoked_at FROM fleet.vehicle_qr_tag WHERE token_hash = $1", token_hash(code))
        if tag is None:
            raise ApiError(404, "CODE_UNKNOWN", "no placard was printed with this code")
        v = await conn.fetchrow(
            """SELECT v.id, v.uid::text AS uid, v.plate_no, v.vehicle_type, v.make, v.model, v.passenger_seats, v.status,
                      cp.legal_name AS carrier, c.approval_status AS carrier_status
                 FROM fleet.vehicle v JOIN iam.party cp ON cp.id = v.company_id JOIN iam.company c ON c.id = v.company_id
                WHERE v.id = $1""", tag["vehicle_id"])
        result = "REVOKED" if tag["revoked_at"] else "VALID"
        window = await conn.fetchval("SELECT coalesce((SELECT (value #>> '{}')::int FROM sys.setting WHERE key = 'roadside.window_minutes'), 180)")
        movement = await movements.current(conn, dict(v), window) if result == "VALID" else None
        doc_expired = await conn.fetchval(
            """SELECT EXISTS (SELECT 1 FROM fleet.license_record WHERE subject_vehicle_id = $1 AND expiry_date < current_date
                                AND status <> 'SUSPENDED')""", v["id"])
        warnings = _warnings(v, movement, doc_expired) if result == "VALID" else ["CODE_" + result]
        check = await conn.fetchrow(
            """INSERT INTO fleet.field_check_log (inspector_user_id, vehicle_id, method, result, lat, lng, tag_id, movement_kind,
                                                  movement_ref, trip_id, warnings, status)
               VALUES ($1, $2, 'QR', $3, $4, $5, $6, $7, $8, $9, $10::jsonb, 'OPEN') RETURNING id, uid""",
            pr.user_id, v["id"], result, body.lat, body.lng, tag["id"],
            movement["kind"] if movement else None, movement["ref"] if movement else None,
            movement.get("trip_id") if movement else None, json.dumps(warnings))
        if acting:
            await conn.execute("INSERT INTO sec.field_check_body (check_id, authority_id) VALUES ($1, $2)", check["id"], acting["id"])
        see_movement = await _may(conn, acting, "MANIFEST_VEHICLE", "TRACKING")
        see_cargo = await _may(conn, acting, "MANIFEST_CARGO")
    shown = None
    if movement and see_movement:
        shown = {k: val for k, val in movement.items() if k not in ("trip_id", "cargo")}
        shown["crew"] = [{"role": c["crew_role"], "name": c["name"], "licence_expiry": c.get("licence_expiry")} for c in movement.get("crew") or []]
        if see_cargo:
            shown["cargo"] = movement.get("cargo")
    request.state.audit = {"action": "roadside.scan", "object_type": "vehicle", "object_id": v["uid"]}
    return {"check": str(check["uid"]), "result": result, "warnings": warnings, "body": acting["code"] if acting else None,
            "vehicle": {"plate_no": v["plate_no"], "type": v["vehicle_type"], "make": v["make"], "model": v["model"],
                        "seats": v["passenger_seats"], "status": v["status"], "carrier": v["carrier"],
                        "carrier_status": v["carrier_status"]},
            "movement": shown, "movement_hidden": bool(movement) and not see_movement}


async def _open_check(conn, pr: Principal, uid: uuid.UUID):
    c = await conn.fetchrow(
        """SELECT f.id, f.status, f.trip_id, f.sample_mode, f.sample, f.inspector_user_id, b.authority_id
             FROM fleet.field_check_log f LEFT JOIN sec.field_check_body b ON b.check_id = f.id WHERE f.uid = $1""", uid)
    if c is None or c["inspector_user_id"] != pr.user_id:
        raise not_found("check")
    if c["status"] != "OPEN":
        raise ApiError(409, "CHECK_CLOSED", "the check is closed")
    return c


class SampleIn(BaseModel):
    mode: Literal["SAMPLE", "FULL"] = "SAMPLE"


@inspector.post("/checks/{uid}/sample")
async def sample(uid: uuid.UUID, body: SampleIn, request: Request, pr: Principal = Depends(inspect)):
    async with db.transaction(context_for(request, pr)) as conn:
        c = await _open_check(conn, pr, uid)
        if c["sample_mode"] != "NONE":
            raise ApiError(409, "SAMPLE_DRAWN", "the people for this check are already drawn")
        if c["trip_id"] is None:
            raise ApiError(409, "NO_PASSENGERS", "the vehicle has no scheduled trip to draw passengers from")
        size = await conn.fetchval("SELECT coalesce((SELECT (value #>> '{}')::int FROM sys.setting WHERE key = 'roadside.sample_size'), 3)")
        # the server draws: the officer does not choose who is checked
        rows = await conn.fetch(
            f"""SELECT k.uid::text AS ticket, k.seat_no, k.status, p.first_name, p.last_name, p.full_name
                  FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                 WHERE k.trip_id = $1 AND k.status IN ('BOARDED', 'ISSUED')
                 ORDER BY {'k.seat_no' if body.mode == 'FULL' else 'random()'} {'' if body.mode == 'FULL' else 'LIMIT $2'}""",
            *((c["trip_id"],) if body.mode == "FULL" else (c["trip_id"], size)))
        drawn = [{"ticket": r["ticket"], "seat": r["seat_no"], "outcome": None} for r in rows]
        await conn.execute("UPDATE fleet.field_check_log SET sample_mode = $2, sample = $3::jsonb WHERE id = $1",
                           c["id"], body.mode, json.dumps(drawn))
        names = await _may(conn, {"id": c["authority_id"]} if c["authority_id"] else None, "MANIFEST_PERSON")
    people = [{"ticket": r["ticket"], "seat": r["seat_no"], "boarded": r["status"] == "BOARDED",
               "name": ticket_name(r["first_name"], r["last_name"], r["full_name"]) if names else None} for r in rows]
    request.state.audit = {"action": "roadside.sample", "object_type": "field_check", "object_id": str(uid)}
    return {"mode": body.mode, "people": people, "names_hidden": not names}


class PersonOutcome(BaseModel):
    ticket: str = Field(min_length=10, max_length=40)
    outcome: Literal["CHECKED", "ISSUE", "ABSENT"]
    note: Optional[str] = Field(default=None, max_length=300)


class CloseIn(BaseModel):
    outcome: Literal["CLEAR", "ISSUES"]
    note: Optional[str] = Field(default=None, max_length=1000)
    people: list[PersonOutcome] = Field(default_factory=list, max_length=200)


@inspector.post("/checks/{uid}/close")
async def close(uid: uuid.UUID, body: CloseIn, request: Request, pr: Principal = Depends(inspect)):
    async with db.transaction(context_for(request, pr)) as conn:
        c = await _open_check(conn, pr, uid)
        sample = json.loads(c["sample"]) if isinstance(c["sample"], str) else list(c["sample"])
        given = {p.ticket: p for p in body.people}
        unknown = set(given) - {s["ticket"] for s in sample}
        if unknown:
            raise ApiError(422, "NOT_DRAWN", "only the people drawn for this check are recorded")
        for s in sample:
            if s["ticket"] in given:
                s["outcome"], s["note"] = given[s["ticket"]].outcome, given[s["ticket"]].note
        if body.outcome == "CLEAR" and any(s.get("outcome") in ("ISSUE", "ABSENT") for s in sample):
            raise ApiError(422, "OUTCOME_MISMATCH", "a check with an issue is not clear")
        await conn.execute(
            "UPDATE fleet.field_check_log SET sample = $2::jsonb, outcome = $3, note = $4, status = 'CLOSED' WHERE id = $1",
            c["id"], json.dumps(sample), body.outcome, (body.note or "").strip() or None)
    request.state.audit = {"action": "roadside.close", "object_type": "field_check", "object_id": str(uid)}
    return {"check": str(uid), "outcome": body.outcome}


@inspector.get("/checks")
async def my_checks(request: Request, pr: Principal = Depends(inspect)):
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(f"{_CHECKS} WHERE f.inspector_user_id = $1 ORDER BY f.created_at DESC LIMIT 100", pr.user_id)
    return {"checks": [dict(r) for r in rows]}
