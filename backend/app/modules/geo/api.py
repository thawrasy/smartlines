"""The administrative geography (owner's request, October 2026; migration 1124).

    Public
    GET  /api/geo/areas?parent=SY02          the governorates, or the districts, sub-districts or communities under one
    GET  /api/geo/places?q=...               places by name (Arabic or English) or code, with the way up to the governorate
    GET  /api/geo/places/{pcode}             one place, its neighbourhoods when it is a city
    Platform (geo.manage)
    GET  /api/admin/geo                      what is loaded: counts by level and governorate, the loads, the cities linked
    POST /api/admin/geo/import               the United Nations workbook (.xlsx), checked and loaded
    POST /api/admin/geo/places/{pcode}/serve {code}: open a community for routes as a city of the network
"""
import json
import re
from typing import Optional

from fastapi import APIRouter, Depends, File, Query, Request, UploadFile
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from . import importer

public = APIRouter(prefix="/api/geo", tags=["geography"])
platform = APIRouter(prefix="/api/admin/geo", tags=["geography"])

MAX_FILE = 20 * 1024 * 1024
LEVELS = {2: 1, 4: 2, 6: 3, 8: 4}          # the length of a parent's code and the level of what is under it


def _ctx(request: Request) -> db.Context:
    return context_for(request, None)


@public.get("/areas")
async def areas(request: Request, parent: Optional[str] = Query(default=None, pattern=r"^[A-Z]{2}([0-9]{2}){0,3}$")):
    """The level under a code: governorates of a country (SY), districts of a governorate (SY02), sub-districts of a
    district (SY0200), communities of a sub-district (SY020000)."""
    parent = parent or "SY"
    level = LEVELS[len(parent)]
    async with db.transaction(_ctx(request)) as conn:
        if level <= 3:
            rows = await conn.fetch(
                """SELECT a.pcode, a.name_en, a.name_ar, a.level,
                          (SELECT count(*) FROM ref.admin_area c WHERE c.parent_id = a.id AND c.status = 'ACTIVE') AS areas,
                          CASE WHEN a.level = 3 THEN (SELECT count(*) FROM ref.place p WHERE p.area_id = a.id AND p.kind = 'COMMUNITY'
                                                      AND p.status = 'ACTIVE') END AS communities
                     FROM ref.admin_area a
                    WHERE a.status = 'ACTIVE' AND a.level = $1 AND left(a.pcode, $2) = $3
                    ORDER BY a.pcode""", level, len(parent), parent)
            return {"parent": parent, "level": level, "areas": [dict(r) for r in rows]}
        rows = await conn.fetch(
            """SELECT p.pcode, p.name_en, p.name_ar, p.lat, p.lng, k.code AS city_code,
                      (SELECT count(*) FROM ref.place n WHERE n.parent_place_id = p.id AND n.status = 'ACTIVE') AS neighbourhoods
                 FROM ref.place p JOIN ref.admin_area a ON a.id = p.area_id LEFT JOIN ref.city k ON k.place_id = p.id
                WHERE a.pcode = $1 AND p.kind = 'COMMUNITY' AND p.status = 'ACTIVE' ORDER BY p.name_en""", parent)
        return {"parent": parent, "level": 4, "places": [dict(r) for r in rows]}


@public.get("/places")
async def places(request: Request, q: str = Query(min_length=2, max_length=60), limit: int = Query(20, ge=1, le=50),
                 kind: Optional[str] = Query(default=None, pattern="^(COMMUNITY|NEIGHBOURHOOD)$")):
    """Places whose Arabic or English name looks like q, or whose code is q; the closest names first."""
    q = " ".join(q.split())
    async with db.transaction(_ctx(request)) as conn:
        ids = await conn.fetch(
            """SELECT p.id FROM ref.place p
                WHERE p.status = 'ACTIVE' AND ($3::text IS NULL OR p.kind = $3)
                  AND (p.pcode = upper($1) OR p.name_en ILIKE '%' || $1 || '%' OR p.name_ar LIKE '%' || $1 || '%'
                       OR p.name_en % $1 OR p.name_ar % $1)
                ORDER BY p.pcode = upper($1) DESC, greatest(similarity(p.name_en, $1), similarity(p.name_ar, $1)) DESC,
                         p.kind, p.name_en
                LIMIT $2""", q, limit, kind)
        out = [json.loads(await conn.fetchval("SELECT ref.place_path($1)::text", r["id"])) for r in ids]
    return {"places": out}


@public.get("/places/{pcode}")
async def place(pcode: str, request: Request):
    if not re.fullmatch(r"[A-Z][0-9]{3,7}", pcode):
        raise not_found("place")
    async with db.transaction(_ctx(request)) as conn:
        pid = await conn.fetchval("SELECT id FROM ref.place WHERE pcode = $1", pcode)
        if pid is None:
            raise not_found("place")
        out = json.loads(await conn.fetchval("SELECT ref.place_path($1)::text", pid))
        out["neighbourhoods"] = [dict(r) for r in await conn.fetch(
            """SELECT pcode, name_en, name_ar, lat, lng, city_area_code, city_area_en, city_area_ar FROM ref.place
                WHERE parent_place_id = $1 AND status = 'ACTIVE' ORDER BY city_area_code, name_en""", pid)]
    return out


# ------------------------------------------------------------------ platform
def _need(pr: Principal) -> None:
    if "geo.manage" not in pr.permissions:
        raise forbidden("missing permission: geo.manage")


@platform.get("")
async def summary(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        by_gov = await conn.fetch(
            """SELECT g.pcode, g.name_en, g.name_ar,
                      count(DISTINCT d.id) AS districts, count(DISTINCT s.id) AS sub_districts,
                      count(p.id) FILTER (WHERE p.kind = 'COMMUNITY') AS communities,
                      count(p.id) FILTER (WHERE p.kind = 'NEIGHBOURHOOD') AS neighbourhoods,
                      count(k.id) AS served
                 FROM ref.admin_area g
                 LEFT JOIN ref.admin_area d ON d.parent_id = g.id AND d.status = 'ACTIVE'
                 LEFT JOIN ref.admin_area s ON s.parent_id = d.id AND s.status = 'ACTIVE'
                 LEFT JOIN ref.place p ON p.area_id = s.id AND p.status = 'ACTIVE'
                 LEFT JOIN ref.city k ON k.place_id = p.id
                WHERE g.level = 1 AND g.status = 'ACTIVE'
                GROUP BY g.id ORDER BY g.pcode""")
        loads = await conn.fetch(
            """SELECT s.uid, s.publisher, s.dataset, s.file_name, s.valid_on, s.counts::text AS counts, s.imported_at,
                      u.email AS imported_by
                 FROM ref.geo_source s LEFT JOIN iam.app_user u ON u.id = s.imported_by ORDER BY s.imported_at DESC LIMIT 20""")
        cities = await conn.fetch(
            """SELECT c.code, c.name, c.is_active, p.pcode, p.name_ar,
                      (SELECT count(*) FROM net.station s WHERE s.city_id = c.id) AS stations
                 FROM ref.city c LEFT JOIN ref.place p ON p.id = c.place_id
                WHERE c.country_code = 'SY' ORDER BY c.code""")
    return {"governorates": [dict(r) for r in by_gov],
            "loads": [dict(r) | {"counts": json.loads(r["counts"])} for r in loads],
            "cities": [dict(r) for r in cities]}


@platform.post("/import")
async def load(request: Request, file: UploadFile = File(...), pr: Principal = Depends(require_portal("PLATFORM"))):
    """Checks the workbook and loads it; a workbook with any mistake loads nothing and says what is wrong."""
    _need(pr)
    data = await file.read(MAX_FILE + 1)
    if len(data) > MAX_FILE:
        raise ApiError(413, "GEO_FILE_TOO_LARGE", "the workbook is larger than 20 MB")
    try:
        wb = importer.read(data)
    except importer.GeoFileError as e:
        code, _, message = str(e).partition(": ")
        raise ApiError(422, code, message)
    async with db.transaction(context_for(request, pr)) as conn:
        try:
            out = await importer.load(conn, wb, pr.user_id, file.filename)
        except importer.GeoFileError as e:
            code, _, message = str(e).partition(": ")
            raise ApiError(422, code, message)
    request.state.audit = {"action": "geo.import", "object_type": "geo_source",
                           "reason": f"{file.filename}: {json.dumps(out['counts'])}"[:120]}
    return out


class ServeIn(BaseModel):
    code: Optional[str] = Field(default=None, pattern=r"^[A-Za-z]{3}$")


@platform.post("/places/{pcode}/serve")
async def serve(pcode: str, body: ServeIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """Opens a community for routes: it becomes a city of the network, with a three-letter code, where carriers then
    set up stations."""
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        code = await conn.fetchval("SELECT ref.serve_place($1, $2)", pcode, body.code)
    request.state.audit = {"action": "geo.serve", "object_type": "city", "reason": f"{pcode} as {code}"}
    return {"pcode": pcode, "city_code": code}
