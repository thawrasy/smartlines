"""Border crossings and airports (owner's note N45, migration 1168).

    Public
    GET  /api/geo/ports                       the active crossings and airports: code, kind, names, the crossing on the
                                              other side, governorate, position (pickers, the public site)
    Platform (geo.manage)
    GET  /api/admin/ports                     every port with its area, place, station, status and how it was matched
    GET  /api/admin/ports/{code}/history      every change of a port: field, old and new value, who, when, why
    POST /api/admin/ports/import              the owner's approved workbook (.xlsx), checked whole and loaded
    PUT  /api/admin/ports/{code}              {names, counterpart, status, status_confirmed, place, position, station,
                                               review_note, reason}: edits a port; its code and kind never change
"""
import json
from typing import Optional

from fastapi import APIRouter, Depends, File, Query, Request, UploadFile
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, not_found
from . import importer, ports
from .api import _need

public = APIRouter(prefix="/api/geo/ports", tags=["ports"])
platform = APIRouter(prefix="/api/admin/ports", tags=["ports"])

MAX_FILE = 5 * 1024 * 1024
_ROW = """SELECT p.code, p.kind, p.name_ar, p.name_en, p.counterpart_name_ar, p.counterpart_name_en, p.counterpart_country,
                 p.iata_code, p.lat, p.lng, p.status, gov.pcode AS governorate, gov.name_en AS governorate_en, gov.name_ar AS governorate_ar"""
_FROM = """FROM net.port_of_entry p JOIN ref.admin_area a ON a.id = p.area_id
           LEFT JOIN ref.admin_area gov ON gov.pcode = left(a.pcode, 4)"""


def _code(code: str) -> str:
    code = code.upper()
    if not ports.CODE.match(code):
        raise not_found("port")
    return code


@public.get("")
async def port_list(request: Request, kind: Optional[str] = Query(default=None, pattern="^(LAND_BORDER|INTL_AIRPORT|LOCAL_AIRPORT)$")):
    async with db.transaction(context_for(request, None)) as conn:
        rows = await conn.fetch(
            f"""{_ROW} {_FROM} WHERE p.status <> 'CLOSED' AND ($1::text IS NULL OR p.kind = $1)
                ORDER BY array_position(ARRAY['LAND_BORDER','INTL_AIRPORT','LOCAL_AIRPORT'], p.kind), p.code""", kind)
    return {"ports": [dict(r) for r in rows]}


@platform.get("")
async def admin_list(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            f"""{_ROW}, p.status_confirmed, p.position_source, p.match_quality, p.review_note, p.edited_by_hand, p.updated_at,
                       a.pcode AS sub_district, a.name_en AS sub_district_en, a.name_ar AS sub_district_ar,
                       pl.pcode AS place, pl.name_en AS place_en, pl.name_ar AS place_ar, st.code AS station,
                       (SELECT count(*) FROM net.port_of_entry_change c WHERE c.port_id = p.id) AS changes
                  {_FROM} LEFT JOIN ref.place pl ON pl.id = p.place_id LEFT JOIN net.station st ON st.id = p.station_id
                 ORDER BY array_position(ARRAY['LAND_BORDER','INTL_AIRPORT','LOCAL_AIRPORT'], p.kind), p.code""")
        last = await conn.fetchrow(
            "SELECT file_name, sha256, imported_at, counts FROM ref.geo_source WHERE content = 'PORTS' ORDER BY id DESC LIMIT 1")
    src = dict(last) if last else None
    if src and isinstance(src.get("counts"), str):
        src["counts"] = json.loads(src["counts"])
    return {"ports": [dict(r) for r in rows], "last_file": src}


@platform.get("/{code}/history")
async def history(code: str, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        port = await conn.fetchval("SELECT id FROM net.port_of_entry WHERE code = $1", _code(code))
        if port is None:
            raise not_found("port")
        rows = await conn.fetch(
            """SELECT c.changed_at, c.field, c.old_value, c.new_value, c.reason, u.email AS changed_by, s.file_name AS by_file
                 FROM net.port_of_entry_change c LEFT JOIN iam.app_user u ON u.id = c.changed_by
                 LEFT JOIN ref.geo_source s ON s.id = c.by_file
                WHERE c.port_id = $1 ORDER BY c.changed_at DESC, c.id DESC LIMIT 500""", port)
    return {"code": _code(code), "changes": [dict(r) for r in rows]}


@platform.post("/import")
async def load(request: Request, file: UploadFile = File(...), pr: Principal = Depends(require_portal("PLATFORM"))):
    """Checks the owner's workbook of crossings and airports and loads it; a workbook with any mistake loads nothing."""
    _need(pr)
    data = await file.read(MAX_FILE + 1)
    if len(data) > MAX_FILE:
        raise ApiError(413, "PORTS_FILE_TOO_LARGE", "the workbook is larger than 5 MB")
    try:
        reg = ports.read(data)
        async with db.transaction(context_for(request, pr)) as conn:
            out = await ports.load(conn, reg, pr.user_id, file.filename)
    except importer.GeoFileError as e:
        code, _, message = str(e).partition(": ")
        raise ApiError(422, code, message)
    request.state.audit = {"action": "ports.import", "object_type": "geo_source",
                           "reason": f"{file.filename}: {json.dumps(out['counts'].get('by_kind'))}"[:120]}
    return out


class PortIn(BaseModel):
    name_ar: Optional[str] = Field(default=None, min_length=2, max_length=200)
    name_en: Optional[str] = Field(default=None, min_length=2, max_length=200)
    counterpart_name_ar: Optional[str] = Field(default=None, min_length=2, max_length=200)
    counterpart_name_en: Optional[str] = Field(default=None, min_length=2, max_length=200)
    status: Optional[str] = Field(default=None, pattern="^(ACTIVE|RESTRICTED|CLOSED)$")
    status_confirmed: Optional[bool] = None
    place: Optional[str] = Field(default=None, pattern=r"^[A-Z][0-9]{3,7}$", description="a place's P-code, field-survey places included")
    lat: Optional[float] = Field(default=None, ge=32, le=37.5)
    lng: Optional[float] = Field(default=None, ge=35.5, le=42.5)
    station: Optional[str] = Field(default=None, max_length=40, description="the border station that serves the port; empty unlinks it")
    review_note: Optional[str] = Field(default=None, max_length=2000)
    reason: str = Field(min_length=3, max_length=500)


@platform.put("/{code}")
async def edit(code: str, body: PortIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """Edits a port. Names, status, place, position and station change; the code and kind never do. Every change is kept
    in the port's history with the reason given; a surveyed position replaces the United Nations location's."""
    _need(pr)
    if (body.lat is None) != (body.lng is None):
        raise ApiError(422, "PORT_POSITION", "give both the latitude and the longitude")
    sets, args = [], []
    for f in ("name_ar", "name_en", "counterpart_name_ar", "counterpart_name_en", "status", "status_confirmed", "review_note"):
        v = getattr(body, f)
        if v is not None:
            args.append(v.strip() if isinstance(v, str) else v)
            sets.append(f"{f} = ?")
    async with db.transaction(context_for(request, pr)) as conn:
        port = await conn.fetchrow("SELECT id, kind FROM net.port_of_entry WHERE code = $1", _code(code))
        if port is None:
            raise not_found("port")
        if body.place is not None:
            place = await conn.fetchrow(
                "SELECT pl.id, pl.area_id, pl.status FROM ref.place pl WHERE pl.id = ref.code_entity('PLACE', $1)", body.place)
            if place is None or place["status"] != "ACTIVE":
                raise ApiError(422, "PORT_PLACE", "no active place with that code")
            args += [place["id"], place["area_id"]]
            sets += ["place_id = ?", "area_id = ?"]
        if body.lat is not None:
            args += [round(body.lat, 6), round(body.lng, 6)]
            sets += ["lat = ?", "lng = ?", "position_source = 'SURVEY'", "match_quality = 'SURVEYED'"]
        if body.station is not None:
            station = None
            if body.station.strip():
                station = await conn.fetchval("SELECT id FROM net.station WHERE id = ref.code_entity('STATION', $1)", body.station.strip().upper())
                if station is None:
                    raise ApiError(422, "PORT_STATION", "no station with that code")
            args.append(station)
            sets.append("station_id = ?")
        if not sets:
            raise ApiError(422, "NOTHING_TO_CHANGE", "give at least one field to change")
        args.append(body.reason.strip())
        sets.append("change_reason = ?")        # the history trigger records it and clears it
        # each ? takes the next argument, in order, from $2 on ($1 is the port)
        sql, n = [], 2
        for s in sets:
            if s.endswith("?"):
                s, n = s[:-1] + f"${n}", n + 1
            sql.append(s)
        await conn.execute(f"UPDATE net.port_of_entry SET {', '.join(sql)} WHERE id = $1", port["id"], *args)
        changed = await conn.fetchval("SELECT count(*) FROM net.port_of_entry_change WHERE port_id = $1 AND changed_at = now()", port["id"])
    request.state.audit = {"action": "ports.edit", "object_type": "port_of_entry", "object_id": _code(code), "reason": body.reason[:120]}
    return {"code": _code(code), "changed_fields": changed}
