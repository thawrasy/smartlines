"""The administrative geography (owner's request, October 2026; migration 1124).

    Public
    GET  /api/geo/areas?parent=SY02          the governorates, or the districts, sub-districts or communities under one
    GET  /api/geo/places?q=...               places by name (Arabic or English) or code, with the way up to the governorate
    GET  /api/geo/places/{pcode}             one place, its neighbourhoods when it is a city
    GET  /api/geo/cities                     the cities of the network with their names in Arabic and English (1125)
    GET  /api/geo/locate?lat=&lng=           the sub-district a point lies in and the nearest places (1125)
    GET  /api/geo/areas/{pcode}/boundary     an area's boundary as GeoJSON, simplified for a map (1125)
    Platform (geo.manage)
    GET  /api/admin/geo                      what is loaded: counts by level and governorate, the loads, the cities linked
    POST /api/admin/geo/import               the United Nations workbook (.xlsx), checked and loaded
    POST /api/admin/geo/boundaries           the same publisher's boundaries (GeoJSON), checked and loaded (1125)
    POST /api/admin/geo/places/{pcode}/serve {code}: open a community for routes as a city of the network
    GET  /api/admin/geo/proposed             places surveyed in the field waiting for review, and the last reviewed (1125)
    POST /api/admin/geo/places               propose a place surveyed in the field (1125)
    POST /api/admin/geo/places/{pcode}/review {accept, note}: another person accepts or rejects it (1125)
    GET  /api/admin/geo/names                corrections of the published names (1127)
    POST /api/admin/geo/names                {lang, wrong, correct, scope, reason}: set one, applied at once and after each load
    DELETE /api/admin/geo/names/{id}         remove one: the names go back to the published ones
"""
import json
import re
from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, File, Query, Request, UploadFile
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from . import boundaries, importer

public = APIRouter(prefix="/api/geo", tags=["geography"])
platform = APIRouter(prefix="/api/admin/geo", tags=["geography"])

MAX_FILE = 20 * 1024 * 1024
MAX_BOUNDARIES = 80 * 1024 * 1024        # the sub-districts' boundaries of a country, as GeoJSON
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
                       OR p.name_en % $1 OR p.name_ar % $1
                       OR p.published_en ILIKE '%' || $1 || '%' OR p.published_ar LIKE '%' || $1 || '%')
                ORDER BY p.pcode = upper($1) DESC,
                         greatest(similarity(p.name_en, $1), similarity(p.name_ar, $1), similarity(p.published_en, $1)) DESC,
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
        out["status"] = await conn.fetchval("SELECT status FROM ref.place WHERE id = $1", pid)
        out["neighbourhoods"] = [dict(r) for r in await conn.fetch(
            """SELECT pcode, name_en, name_ar, lat, lng, city_area_code, city_area_en, city_area_ar FROM ref.place
                WHERE parent_place_id = $1 AND status = 'ACTIVE' ORDER BY city_area_code, name_en""", pid)]
    return out


@public.get("/cities")
async def cities(request: Request):
    """The cities of the network, with their names in Arabic and English from their places, so that a city opened for
    routes is named in every language at once (1125)."""
    async with db.transaction(_ctx(request)) as conn:
        rows = await conn.fetch(
            """SELECT c.code, c.name AS name_en, coalesce(p.name_ar, c.name) AS name_ar, p.pcode
                 FROM ref.city c LEFT JOIN ref.place p ON p.id = c.place_id WHERE c.is_active ORDER BY c.code""")
    return {"cities": [dict(r) for r in rows]}


@public.get("/locate")
async def locate(request: Request, lat: float = Query(ge=-90, le=90), lng: float = Query(ge=-180, le=180),
                 limit: int = Query(5, ge=1, le=20)):
    """Where a point lies: the sub-district holding it (by its boundary when loaded, else by the nearest place) and
    the nearest places with their distance in metres (1125)."""
    async with db.transaction(_ctx(request)) as conn:
        return json.loads(await conn.fetchval("SELECT ref.locate($1, $2, $3)::text", round(lat, 6), round(lng, 6), limit))


@public.get("/areas/{pcode}/boundary")
async def boundary(pcode: str, request: Request, detail: float = Query(0.002, ge=0, le=0.05)):
    """An area's boundary as a GeoJSON feature, simplified by detail degrees for a map (0 keeps every point)."""
    if not re.fullmatch(r"[A-Z]{2}([0-9]{2}){1,3}", pcode):
        raise not_found("area")
    async with db.transaction(_ctx(request)) as conn:
        r = await conn.fetchrow(
            """SELECT a.pcode, a.level, a.name_en, a.name_ar,
                      gis.st_asgeojson(CASE WHEN $2 > 0 THEN gis.st_simplifypreservetopology(a.boundary, $2) ELSE a.boundary END, 6)
                        AS geometry
                 FROM ref.admin_area a WHERE a.pcode = $1 AND a.status = 'ACTIVE'""", pcode, detail)
    if r is None or r["geometry"] is None:
        raise not_found("boundary")
    return {"type": "Feature", "geometry": json.loads(r["geometry"]),
            "properties": {"pcode": r["pcode"], "level": r["level"], "name_en": r["name_en"], "name_ar": r["name_ar"]}}


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
                      count(k.id) AS served,
                      (g.boundary IS NOT NULL) AS has_boundary,
                      count(DISTINCT s.id) FILTER (WHERE s.boundary IS NOT NULL) AS sub_district_boundaries
                 FROM ref.admin_area g
                 LEFT JOIN ref.admin_area d ON d.parent_id = g.id AND d.status = 'ACTIVE'
                 LEFT JOIN ref.admin_area s ON s.parent_id = d.id AND s.status = 'ACTIVE'
                 LEFT JOIN ref.place p ON p.area_id = s.id AND p.status = 'ACTIVE'
                 LEFT JOIN ref.city k ON k.place_id = p.id
                WHERE g.level = 1 AND g.status = 'ACTIVE'
                GROUP BY g.id ORDER BY g.pcode""")
        loads = await conn.fetch(
            """SELECT s.uid, s.publisher, s.content, s.dataset, s.file_name, s.valid_on, s.counts::text AS counts, s.imported_at,
                      u.email AS imported_by
                 FROM ref.geo_source s LEFT JOIN iam.app_user u ON u.id = s.imported_by ORDER BY s.imported_at DESC LIMIT 20""")
        cities = await conn.fetch(
            """SELECT c.code, c.name, c.is_active, p.pcode, p.name_ar,
                      (SELECT count(*) FROM net.station s WHERE s.city_id = c.id) AS stations
                 FROM ref.city c LEFT JOIN ref.place p ON p.id = c.place_id
                WHERE c.country_code = 'SY' ORDER BY c.code""")
        proposed = await conn.fetchval("SELECT count(*) FROM ref.place WHERE status = 'PROPOSED'")
    return {"governorates": [dict(r) for r in by_gov], "proposed": proposed,
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


@platform.post("/boundaries")
async def load_boundaries(request: Request, file: UploadFile = File(...), pr: Principal = Depends(require_portal("PLATFORM"))):
    """The boundaries of the areas (GeoJSON from the same publisher): checked whole, then each shape put on its area."""
    _need(pr)
    data = await file.read(MAX_BOUNDARIES + 1)
    if len(data) > MAX_BOUNDARIES:
        raise ApiError(413, "GEO_FILE_TOO_LARGE", "the boundaries file is larger than 80 MB")
    try:
        b = boundaries.read(data)
        async with db.transaction(context_for(request, pr)) as conn:
            out = await boundaries.load(conn, b, pr.user_id, file.filename)
    except importer.GeoFileError as e:
        code, _, message = str(e).partition(": ")
        raise ApiError(422, code, message)
    request.state.audit = {"action": "geo.boundaries", "object_type": "geo_source",
                           "reason": f"{file.filename}: {json.dumps(out['counts'])}"[:120]}
    return out


# ------------------------------------------------------------------ places surveyed in the field (1125)
@platform.get("/proposed")
async def proposed(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT p.pcode, p.kind, p.status, p.name_en, p.name_ar, p.lat, p.lng, p.surveyed_on, p.survey_note, p.proposed_at,
                      p.reviewed_at, p.review_note, u.email AS proposed_by, r.email AS reviewed_by, (p.proposed_by = $1) AS mine,
                      a.pcode AS sub_district, a.name_en AS sub_district_en, a.name_ar AS sub_district_ar,
                      c.name_en AS city_en, c.name_ar AS city_ar
                 FROM ref.place p JOIN ref.admin_area a ON a.id = p.area_id
                 LEFT JOIN ref.place c ON c.id = p.parent_place_id
                 LEFT JOIN iam.app_user u ON u.id = p.proposed_by LEFT JOIN iam.app_user r ON r.id = p.reviewed_by
                WHERE p.proposed_by IS NOT NULL AND (p.status = 'PROPOSED' OR p.reviewed_at > now() - interval '90 days')
                ORDER BY p.status <> 'PROPOSED', coalesce(p.reviewed_at, p.proposed_at) DESC LIMIT 200""", pr.user_id)
    return {"places": [dict(r) for r in rows]}


class ProposeIn(BaseModel):
    kind: str = Field(pattern="^(COMMUNITY|NEIGHBOURHOOD)$")
    sub_district: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}[0-9]{6}$")   # a community's
    city: Optional[str] = Field(default=None, pattern=r"^[A-Z][0-9]{3,7}$")           # a neighbourhood's
    name_en: str = Field(min_length=2, max_length=160)
    name_ar: str = Field(min_length=2, max_length=160)
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    surveyed_on: date
    note: Optional[str] = Field(default=None, max_length=1000)
    not_duplicate: bool = False


@platform.post("/places", status_code=201)
async def propose(body: ProposeIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """Records a place found by a field survey; it is used once another person has reviewed it."""
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        code = await conn.fetchval(
            "SELECT ref.propose_place($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
            body.kind, body.sub_district, body.city, body.name_en, body.name_ar, round(body.lat, 6), round(body.lng, 6),
            body.surveyed_on, body.note, body.not_duplicate)
    request.state.audit = {"action": "geo.propose", "object_type": "place", "reason": f"{code} {body.name_en}"[:120]}
    return {"pcode": code, "status": "PROPOSED"}


class ReviewIn(BaseModel):
    accept: bool
    note: Optional[str] = Field(default=None, max_length=500)


@platform.post("/places/{pcode}/review")
async def review(pcode: str, body: ReviewIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT ref.review_place($1, $2, $3)", pcode, body.accept, body.note)
    request.state.audit = {"action": "geo.review", "object_type": "place", "reason": f"{pcode} {status}"}
    return {"pcode": pcode, "status": status}


# ------------------------------------------------------------------ corrections of the published names (1127)
@platform.get("/names")
async def names(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT c.id, c.lang, c.wrong, c.correct, c.scope_pcode, a.name_en AS scope_en, a.name_ar AS scope_ar, c.reason,
                      c.set_at, u.email AS set_by,
                      (SELECT count(*) FROM ref.place p JOIN ref.admin_area s ON s.id = p.area_id
                        WHERE p.status = 'ACTIVE' AND (c.scope_pcode IS NULL OR c.scope_pcode = p.pcode
                               OR (c.scope_pcode ~ '^[A-Z]{2}' AND left(s.pcode, length(c.scope_pcode)) = c.scope_pcode))
                          AND CASE c.lang WHEN 'en' THEN p.published_en ELSE p.published_ar END ~ ('(^|[^[:alpha:]])' || c.wrong || '([^[:alpha:]]|$)'))
                        AS places
                 FROM ref.name_correction c
                 LEFT JOIN LATERAL (SELECT name_en, name_ar FROM ref.admin_area WHERE pcode = c.scope_pcode
                                    UNION ALL SELECT name_en, name_ar FROM ref.place WHERE pcode = c.scope_pcode LIMIT 1) a ON true
                 LEFT JOIN iam.app_user u ON u.id = c.set_by
                WHERE c.status = 'ACTIVE' ORDER BY c.id""")
    return {"corrections": [dict(r) for r in rows]}


class NameIn(BaseModel):
    lang: str = Field(pattern="^(en|ar)$")
    wrong: str = Field(min_length=2, max_length=60)
    correct: str = Field(min_length=1, max_length=80)
    scope: Optional[str] = Field(default=None, pattern=r"^([A-Z]{2}([0-9]{2}){0,3}|[A-Z][0-9]{3,7})$")   # an area, or one place
    reason: str = Field(min_length=3, max_length=300)


@platform.post("/names", status_code=201)
async def set_name(body: NameIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """A word of the published names written otherwise, in the areas under scope (the country when none): applied at
    once to every name that carries it, and again after each load."""
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        changed = await conn.fetchval("SELECT ref.set_name_correction($1, $2, $3, $4, $5)", body.lang, body.wrong.strip(),
                                      body.correct.strip(), body.scope, body.reason)
    request.state.audit = {"action": "geo.name", "object_type": "name_correction",
                           "reason": f"{body.wrong} -> {body.correct} in {body.scope or 'all'}"[:120]}
    return {"changed": changed}


@platform.delete("/names/{correction_id}")
async def remove_name(correction_id: int, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        changed = await conn.fetchval("SELECT ref.remove_name_correction($1)", correction_id)
    request.state.audit = {"action": "geo.name_remove", "object_type": "name_correction", "object_id": correction_id}
    return {"changed": changed}

