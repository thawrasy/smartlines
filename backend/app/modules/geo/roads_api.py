"""The roads guide (owner's request N38, migration 1162).

    Public
    GET  /api/geo/roads                         the roads: class, names, regional number, length, points, verification,
                                                governorates crossed
    GET  /api/geo/roads/{code}                  one road and its points in order, each with the other roads crossing there
    GET  /api/geo/roads/junctions               the places on two roads or more
    GET  /api/geo/roads/map                     every road's line and the junctions, to draw the network
    Platform (geo.manage)
    POST /api/admin/roads/import                the owner's roads workbook (.xlsx), checked whole and loaded
    POST /api/admin/roads/{code}/verification   {to_status, document_ref, note}: ask to raise how far a road is verified
    GET  /api/admin/roads/verifications         the steps asked and decided
    POST /api/admin/roads/verifications/{uid}/decide   {approve, note}: another person decides
    GET  /api/admin/roads/corrections           corrections proposed by carriers and the platform
    POST /api/admin/roads/{code}/corrections    {seq, kind, place, km, remark}: the platform proposes one
    POST /api/admin/roads/corrections/{uid}/review     {accept, note}: another person accepts (applied) or rejects
    Carrier
    POST /api/carrier/roads/{code}/corrections  {seq, kind, place, km, remark}: propose a correction
    GET  /api/carrier/roads/corrections         the carrier's proposals and their outcome
"""
import json
import re
import uuid
from typing import Optional

from fastapi import APIRouter, Depends, File, Query, Request, UploadFile
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, not_found
from . import importer, roads
from .api import _need

public = APIRouter(prefix="/api/geo/roads", tags=["roads"])
platform = APIRouter(prefix="/api/admin/roads", tags=["roads"])
carrier = APIRouter(prefix="/api/carrier/roads", tags=["roads"])

MAX_FILE = 10 * 1024 * 1024
ROAD = r"^[A-Z]{1,2}[0-9]{1,3}[A-Z]?$"


def _code(code: str) -> str:
    code = code.upper()
    if not re.fullmatch(ROAD, code):
        raise not_found("road")
    return code


@public.get("")
async def road_list(request: Request, road_class: Optional[str] = Query(default=None, pattern="^(INTERNATIONAL|MAIN|SECONDARY|URBAN)$")):
    async with db.transaction(context_for(request, None)) as conn:
        rows = await conn.fetch(
            """SELECT r.code, r.road_class, r.name_ar, r.name_en, r.regional_number, r.length_km, r.verification_status,
                      count(p.id) AS points,
                      (SELECT array_agg(DISTINCT left(a.pcode, 4) ORDER BY left(a.pcode, 4)) FROM net.road_point q
                         JOIN ref.place pl ON pl.id = q.place_id JOIN ref.admin_area a ON a.id = pl.area_id WHERE q.road_id = r.id) AS governorates,
                      (SELECT f.name_en FROM net.road_point f2 JOIN ref.place f ON f.id = f2.place_id WHERE f2.road_id = r.id ORDER BY f2.seq LIMIT 1) AS start_en,
                      (SELECT f.name_ar FROM net.road_point f2 JOIN ref.place f ON f.id = f2.place_id WHERE f2.road_id = r.id ORDER BY f2.seq LIMIT 1) AS start_ar,
                      (SELECT f.name_en FROM net.road_point f2 JOIN ref.place f ON f.id = f2.place_id WHERE f2.road_id = r.id ORDER BY f2.seq DESC LIMIT 1) AS end_en,
                      (SELECT f.name_ar FROM net.road_point f2 JOIN ref.place f ON f.id = f2.place_id WHERE f2.road_id = r.id ORDER BY f2.seq DESC LIMIT 1) AS end_ar
                 FROM net.road r LEFT JOIN net.road_point p ON p.road_id = r.id
                WHERE r.status = 'ACTIVE' AND ($1::text IS NULL OR r.road_class = $1)
                GROUP BY r.id ORDER BY array_position(ARRAY['INTERNATIONAL','MAIN','SECONDARY','URBAN'], r.road_class),
                         substring(r.code from '^[A-Z]+'), (substring(r.code from '[0-9]+'))::int, r.code""", road_class)
    return {"roads": [dict(r) for r in rows]}


@public.get("/junctions")
async def junctions(request: Request):
    async with db.transaction(context_for(request, None)) as conn:
        rows = await conn.fetch("SELECT pcode, name_en, name_ar, roads, road_codes FROM net.road_junction ORDER BY roads DESC, name_en")
    return {"junctions": [dict(r) for r in rows]}


@public.get("/map")
async def road_map(request: Request):
    """Every road as its points' positions in order, to draw the network."""
    async with db.transaction(context_for(request, None)) as conn:
        rows = await conn.fetch(
            """SELECT r.code, r.road_class, json_agg(json_build_array(p.lng, p.lat) ORDER BY p.seq)::text AS line
                 FROM net.road r JOIN net.road_point p ON p.road_id = r.id WHERE r.status = 'ACTIVE' GROUP BY r.id ORDER BY r.code""")
        nodes = await conn.fetch(
            """SELECT j.pcode, j.name_en, j.name_ar, j.roads, pl.lat, pl.lng FROM net.road_junction j JOIN ref.place pl ON pl.id = j.place_id""")
    return {"roads": [{"code": r["code"], "road_class": r["road_class"], "line": json.loads(r["line"])} for r in rows],
            "junctions": [dict(n) for n in nodes]}


@public.get("/{code}")
async def road(code: str, request: Request):
    code = _code(code)
    async with db.transaction(context_for(request, None)) as conn:
        r = await conn.fetchrow(
            """SELECT r.id, r.code, r.road_class, r.name_ar, r.name_en, r.regional_number, r.length_km, r.note, r.verification_status,
                      r.updated_at, s.file_name AS source_file, s.imported_at AS source_loaded_at
                 FROM net.road r LEFT JOIN ref.geo_source s ON s.id = r.source_id WHERE r.code = $1 AND r.status = 'ACTIVE'""", code)
        if r is None:
            raise not_found("road")
        points = await conn.fetch(
            """SELECT p.seq, pl.pcode, pl.name_en, pl.name_ar, p.lat, p.lng, p.km_from_previous, p.km_cumulative, p.is_border, p.note,
                      a.pcode AS sub_district, a.name_en AS sub_district_en, a.name_ar AS sub_district_ar,
                      (SELECT array_agg(DISTINCT o.code ORDER BY o.code) FROM net.road_point x JOIN net.road o ON o.id = x.road_id
                        WHERE x.place_id = p.place_id AND o.id <> p.road_id AND o.status = 'ACTIVE') AS crossing_roads
                 FROM net.road_point p JOIN ref.place pl ON pl.id = p.place_id JOIN ref.admin_area a ON a.id = pl.area_id
                WHERE p.road_id = $1 ORDER BY p.seq""", r["id"])
    out = {k: v for k, v in dict(r).items() if k != "id"}
    return out | {"points": [dict(p) for p in points]}


# ------------------------------------------------------------------ platform
@platform.post("/import")
async def load(request: Request, file: UploadFile = File(...), pr: Principal = Depends(require_portal("PLATFORM"))):
    """Checks the owner's roads workbook and loads it; a workbook with any mistake loads nothing and says what is wrong."""
    _need(pr)
    data = await file.read(MAX_FILE + 1)
    if len(data) > MAX_FILE:
        raise ApiError(413, "ROADS_FILE_TOO_LARGE", "the workbook is larger than 10 MB")
    try:
        guide = roads.read(data)
        async with db.transaction(context_for(request, pr)) as conn:
            out = await roads.load(conn, guide, pr.user_id, file.filename)
    except importer.GeoFileError as e:
        code, _, message = str(e).partition(": ")
        raise ApiError(422, code, message)
    request.state.audit = {"action": "roads.import", "object_type": "geo_source",
                           "reason": f"{file.filename}: {json.dumps({k: out['counts'].get(k) for k in ('roads', 'points')})}"[:120]}
    return out


class VerificationIn(BaseModel):
    to_status: str = Field(pattern="^(OWNER_FILE|CARRIER_CONFIRMED|AUTHORITY_APPROVED)$")
    document_ref: str = Field(min_length=3, max_length=300)
    note: Optional[str] = Field(default=None, max_length=1000)


@platform.post("/{code}/verification", status_code=201)
async def ask_verification(code: str, body: VerificationIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await conn.fetchval("SELECT net.request_road_verification($1, $2, $3, $4)", _code(code), body.to_status,
                                  body.document_ref, body.note)
    request.state.audit = {"action": "roads.verification", "object_type": "road", "reason": f"{code} -> {body.to_status}"}
    return {"uid": uid, "status": "PENDING"}


@platform.get("/verifications")
async def verifications(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT v.uid, r.code AS road, v.from_status, v.to_status, v.document_ref, v.note, v.status, v.requested_at,
                      u.email AS requested_by, v.decided_at, d.email AS decided_by, v.decision_note, (v.requested_by = $1) AS mine
                 FROM net.road_verification v JOIN net.road r ON r.id = v.road_id JOIN iam.app_user u ON u.id = v.requested_by
                 LEFT JOIN iam.app_user d ON d.id = v.decided_by
                ORDER BY v.status <> 'PENDING', v.requested_at DESC LIMIT 200""", pr.user_id)
    return {"verifications": [dict(r) for r in rows]}


class DecideIn(BaseModel):
    approve: bool
    note: Optional[str] = Field(default=None, max_length=500)


@platform.post("/verifications/{uid}/decide")
async def decide_verification(uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT net.decide_road_verification($1, $2, $3)", uid, body.approve, body.note)
    request.state.audit = {"action": "roads.verification_decide", "object_type": "road_verification", "reason": f"{uid} {status}"}
    return {"uid": uid, "status": status}


class CorrectionIn(BaseModel):
    seq: Optional[int] = Field(default=None, ge=1, le=999)
    kind: str = Field(pattern="^(PLACE|DISTANCE|REMARK)$")
    place: Optional[str] = Field(default=None, pattern=r"^[A-Z][0-9]{3,7}$")
    km: Optional[float] = Field(default=None, ge=0, le=2000)
    remark: str = Field(min_length=5, max_length=1000)


async def _propose(request: Request, pr: Principal, code: str, body: CorrectionIn) -> dict:
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await conn.fetchval("SELECT net.propose_road_correction($1, $2, $3, $4, $5, $6)", _code(code), body.seq, body.kind,
                                  body.place, body.km, body.remark)
    request.state.audit = {"action": "roads.correction", "object_type": "road", "reason": f"{code} {body.kind} {body.seq or ''}"[:120]}
    return {"uid": uid, "status": "PENDING"}


_CORRECTIONS = """SELECT c.uid, r.code AS road, pt.seq, c.kind, pl.pcode AS place, pl.name_en AS place_en, pl.name_ar AS place_ar,
                         c.km_from_previous AS km, c.remark, c.status, c.proposed_at, u.email AS proposed_by, co.legal_name AS company,
                         c.reviewed_at, v.email AS reviewed_by, c.review_note, (c.proposed_by = $1) AS mine,
                         cur.pcode AS current_place, pt.km_from_previous AS current_km
                    FROM net.road_correction c JOIN net.road r ON r.id = c.road_id
                    LEFT JOIN net.road_point pt ON pt.id = c.point_id LEFT JOIN ref.place cur ON cur.id = pt.place_id
                    LEFT JOIN ref.place pl ON pl.id = c.place_id JOIN iam.app_user u ON u.id = c.proposed_by
                    LEFT JOIN iam.party co ON co.id = c.company_id LEFT JOIN iam.app_user v ON v.id = c.reviewed_by"""


@platform.get("/corrections")
async def corrections(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(_CORRECTIONS + " ORDER BY c.status <> 'PENDING', c.proposed_at DESC LIMIT 300", pr.user_id)
    return {"corrections": [dict(r) for r in rows]}


@platform.post("/{code}/corrections", status_code=201)
async def platform_propose(code: str, body: CorrectionIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    return await _propose(request, pr, code, body)


class ReviewIn(BaseModel):
    accept: bool
    note: Optional[str] = Field(default=None, max_length=500)


@platform.post("/corrections/{uid}/review")
async def review(uid: uuid.UUID, body: ReviewIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT net.review_road_correction($1, $2, $3)", uid, body.accept, body.note)
    request.state.audit = {"action": "roads.correction_review", "object_type": "road_correction", "reason": f"{uid} {status}"}
    return {"uid": uid, "status": status}


# ------------------------------------------------------------------ carrier
@carrier.post("/{code}/corrections", status_code=201)
async def carrier_propose(code: str, body: CorrectionIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    return await _propose(request, pr, code, body)


@carrier.get("/corrections")
async def carrier_corrections(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(_CORRECTIONS + " WHERE c.company_id = $2 ORDER BY c.proposed_at DESC LIMIT 200", pr.user_id, pr.company_id)
    return {"corrections": [dict(r) for r in rows]}
