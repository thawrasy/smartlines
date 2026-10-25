"""Routes of the network, defined by the platform along the roads (owner's requests N11, N37, N38; migration 1163).

    Signed in (any portal)
    GET  /api/network/routes                    the routes in effect: code, names, stations in order, distance
    GET  /api/network/routes/{uid}              one route: its versions, the version in effect with its stations,
                                                road segments and the governorates it crosses
    Platform (geo.manage)
    POST /api/admin/network/routes              {name_en, name_ar, version}: a new route, its first version proposed
    POST /api/admin/network/routes/{uid}/versions   {version}: a new version of a route proposed
    GET  /api/admin/network/versions            versions waiting for a decision, and the last decided
    POST /api/admin/network/versions/{uid}/decide   {approve, note}: another person decides
    POST /api/admin/network/versions/{uid}/withdraw who proposed withdraws
    GET  /api/admin/network/requests            carriers' requests for a route
    POST /api/admin/network/requests/{uid}/answer   {status, answer, route_uid}
    Carrier
    GET  /api/carrier/route-requests, POST /api/carrier/route-requests   {from_station_uid, to_station_uid, via, note}

A version is {effective_from, note, segments: [{road, from_seq, to_seq}], stops: [{station_uid, mandatory, km}],
distance_km}. With segments, the distance and each station's distance from the start come from the roads guide (a
station standing at a road point, or in its community); without them, the platform gives them.
"""
import uuid
from datetime import date
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal, require_user
from ...errors import ApiError, not_found
from ..geo.api import _need

public = APIRouter(prefix="/api/network/routes", tags=["network"])
platform = APIRouter(prefix="/api/admin/network", tags=["network"])
carrier = APIRouter(prefix="/api/carrier/route-requests", tags=["network"])


class SegmentIn(BaseModel):
    road: str = Field(pattern=r"^[A-Z]{1,2}[0-9]{1,3}[A-Z]?$")
    from_seq: int = Field(ge=1, le=999)
    to_seq: int = Field(ge=1, le=999)


class StopIn(BaseModel):
    station_uid: uuid.UUID
    mandatory: bool = False
    km: Optional[float] = Field(default=None, ge=0, le=5000)


class VersionIn(BaseModel):
    effective_from: Optional[date] = None
    note: Optional[str] = Field(default=None, max_length=1000)
    segments: list[SegmentIn] = Field(default_factory=list, max_length=40)
    stops: list[StopIn] = Field(min_length=2, max_length=40)
    distance_km: Optional[float] = Field(default=None, gt=0, le=5000)


async def _plan(conn: asyncpg.Connection, v: VersionIn) -> tuple[list[tuple], list[tuple], float]:
    """Checks a version against the roads guide and the stations; returns its segments, stops and distance."""
    segments: list[tuple] = []
    along: list[tuple[int, float]] = []              # (place id, km from the start) for every road point passed
    total = 0.0
    last_place = None
    for i, s in enumerate(v.segments, start=1):
        pts = await conn.fetch(
            """SELECT p.id, p.seq, p.place_id, p.km_cumulative, r.id AS road_id FROM net.road r JOIN net.road_point p ON p.road_id = r.id
                WHERE r.code = $1 AND r.status = 'ACTIVE' AND p.seq BETWEEN least($2::int, $3::int) AND greatest($2::int, $3::int)
                ORDER BY p.seq""", s.road, s.from_seq, s.to_seq)
        ends = {p["seq"]: p for p in pts}
        if s.from_seq not in ends or s.to_seq not in ends or s.from_seq == s.to_seq:
            raise ApiError(422, "ROUTE_SEGMENT", f"segment {i}: road {s.road} has no points {s.from_seq} and {s.to_seq}")
        start, end = ends[s.from_seq], ends[s.to_seq]
        if last_place is not None and start["place_id"] != last_place:
            raise ApiError(422, "ROUTE_GAP", f"segment {i} does not start where segment {i - 1} ends")
        walk = pts if s.from_seq < s.to_seq else list(reversed(pts))
        for p in walk:
            along.append((p["place_id"], total + abs(float(p["km_cumulative"]) - float(start["km_cumulative"]))))
        km = abs(float(end["km_cumulative"]) - float(start["km_cumulative"]))
        if km <= 0:
            raise ApiError(422, "ROUTE_SEGMENT", f"segment {i}: the road gives no distance between these points")
        segments.append((i, start["road_id"], start["id"], end["id"], round(km, 1)))
        total += km
        last_place = end["place_id"]
    distance = round(total, 1) if segments else v.distance_km
    if not distance:
        raise ApiError(422, "ROUTE_DISTANCE", "give the route's distance, or the road segments it follows")
    stops: list[tuple] = []
    seen: set[int] = set()
    previous = -1.0
    for i, s in enumerate(v.stops, start=1):
        st = await conn.fetchrow(
            """SELECT s.id, s.place_id, p.parent_place_id FROM net.station s LEFT JOIN ref.place p ON p.id = s.place_id
                WHERE s.uid = $1 AND s.status = 'ACTIVE'""", s.station_uid)
        if st is None:
            raise ApiError(422, "UNKNOWN_STATION", f"stop {i}: no active station")
        if st["id"] in seen:
            raise ApiError(422, "DUPLICATE_STATION", f"stop {i}: the station appears twice")
        seen.add(st["id"])
        km = 0.0 if i == 1 else s.km
        if km is None and along:
            near = [k for place, k in along if place in (st["place_id"], st["parent_place_id"]) and k > previous]
            km = near[0] if near else None
        if km is None:
            raise ApiError(422, "STOP_KM_REQUIRED", f"stop {i}: the station is not at a point of the roads; give its distance from the start")
        if km <= previous:
            raise ApiError(422, "STOP_ORDER", f"stop {i}: the distance from the start must grow along the route")
        if km > distance + 0.5:
            raise ApiError(422, "STOP_BEYOND", f"stop {i} lies beyond the end of the route")
        stops.append((i, st["id"], round(km, 1), s.mandatory or i in (1, len(v.stops))))
        previous = km
    return segments, stops, float(distance)


async def _write_version(conn: asyncpg.Connection, route_id: int, v: VersionIn, user_id: int) -> uuid.UUID:
    segments, stops, distance = await _plan(conn, v)
    if await conn.fetchval("SELECT 1 FROM net.network_route_version WHERE route_id = $1 AND status IN ('PENDING', 'APPROVED')", route_id):
        raise ApiError(409, "ROUTE_VERSION_WAITING", "a version of this route is already waiting; withdraw it or have it decided first")
    route = await conn.fetchrow("SELECT origin_station_id, dest_station_id FROM net.network_route WHERE id = $1", route_id)
    if stops[0][1] != route["origin_station_id"] or stops[-1][1] != route["dest_station_id"]:
        raise ApiError(422, "ROUTE_ENDS", "a route keeps its origin and destination; another pair of stations is another route")
    when = v.effective_from or date.today()
    if when < date.today():
        raise ApiError(422, "ROUTE_DATE", "a version takes effect today or later")
    vid, vuid = await conn.fetchrow(
        """INSERT INTO net.network_route_version (route_id, version, effective_from, distance_km, note, proposed_by)
           VALUES ($1, (SELECT coalesce(max(version), 0) + 1 FROM net.network_route_version WHERE route_id = $1), $2, $3, $4, $5)
           RETURNING id, uid""", route_id, when, distance, v.note, user_id)
    await conn.executemany(
        "INSERT INTO net.network_route_segment (version_id, seq, road_id, from_point_id, to_point_id, km) VALUES ($1, $2, $3, $4, $5, $6)",
        [(vid, *s) for s in segments])
    await conn.executemany(
        "INSERT INTO net.network_route_stop (version_id, seq, station_id, km_from_start, mandatory) VALUES ($1, $2, $3, $4, $5)",
        [(vid, *s) for s in stops])
    return vuid


_STOPS = """SELECT st.seq, s.uid AS station_uid, s.code AS station_code, s.name AS station_name, s.subtype, c.code AS city_code,
                   st.km_from_start, st.mandatory
              FROM net.network_route_stop st JOIN net.station s ON s.id = st.station_id JOIN ref.city c ON c.id = s.city_id
             WHERE st.version_id = $1 ORDER BY st.seq"""


@public.get("")
async def routes(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT r.uid, r.code, r.name_en, r.name_ar, v.id AS vid, v.version, v.distance_km, v.effective_from
                 FROM net.network_route r JOIN net.network_route_version v ON v.route_id = r.id AND v.status = 'ACTIVE'
                WHERE r.status = 'ACTIVE' ORDER BY r.code""")
        out = []
        for r in recs:
            out.append({k: v for k, v in dict(r).items() if k != "vid"} | {"stops": [dict(s) for s in await conn.fetch(_STOPS, r["vid"])]})
    return {"routes": out}


@public.get("/{uid}")
async def route(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        r = await conn.fetchrow("SELECT id, uid, code, name_en, name_ar, status FROM net.network_route WHERE uid = $1", uid)
        if r is None:
            raise not_found("route")
        versions = await conn.fetch(
            """SELECT v.id, v.uid, v.version, v.status, v.effective_from, v.distance_km, v.note, v.proposed_at, u.email AS proposed_by,
                      v.decided_at, d.email AS decided_by, v.decision_note, v.activated_at
                 FROM net.network_route_version v LEFT JOIN iam.app_user u ON u.id = v.proposed_by LEFT JOIN iam.app_user d ON d.id = v.decided_by
                WHERE v.route_id = $1 ORDER BY v.version DESC""", r["id"])
        shown = next((v for v in versions if v["status"] == "ACTIVE"), versions[0] if versions else None)
        detail = None
        if shown:
            segs = await conn.fetch(
                """SELECT g.seq, rd.code AS road, a.seq AS from_seq, b.seq AS to_seq, g.km,
                          pa.name_en AS from_en, pa.name_ar AS from_ar, pb.name_en AS to_en, pb.name_ar AS to_ar
                     FROM net.network_route_segment g JOIN net.road rd ON rd.id = g.road_id
                     JOIN net.road_point a ON a.id = g.from_point_id JOIN ref.place pa ON pa.id = a.place_id
                     JOIN net.road_point b ON b.id = g.to_point_id JOIN ref.place pb ON pb.id = b.place_id
                    WHERE g.version_id = $1 ORDER BY g.seq""", shown["id"])
            govs = await conn.fetch(
                """SELECT DISTINCT left(ar.pcode, 4) AS pcode, gv.name_en, gv.name_ar
                     FROM net.network_route_segment g JOIN net.road_point a ON a.id = g.from_point_id JOIN net.road_point b ON b.id = g.to_point_id
                     JOIN net.road_point p ON p.road_id = g.road_id AND p.seq BETWEEN least(a.seq, b.seq) AND greatest(a.seq, b.seq)
                     JOIN ref.place pl ON pl.id = p.place_id JOIN ref.admin_area ar ON ar.id = pl.area_id
                     LEFT JOIN ref.admin_area gv ON gv.pcode = left(ar.pcode, 4)
                    WHERE g.version_id = $1 ORDER BY 1""", shown["id"])
            detail = {"version": shown["version"], "status": shown["status"], "distance_km": shown["distance_km"],
                      "stops": [dict(s) for s in await conn.fetch(_STOPS, shown["id"])], "segments": [dict(s) for s in segs],
                      "governorates": [dict(g) for g in govs]}
    return {k: v for k, v in dict(r).items() if k != "id"} | {
        "shown": detail, "versions": [{k: v for k, v in dict(x).items() if k != "id"} for x in versions]}


# ------------------------------------------------------------------ platform
class RouteIn(BaseModel):
    name_en: str = Field(min_length=3, max_length=200)
    name_ar: str = Field(min_length=3, max_length=200)
    version: VersionIn


@platform.post("/routes", status_code=201)
async def add_route(body: RouteIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        ends = await conn.fetch("SELECT uid, id FROM net.station WHERE uid = ANY($1::uuid[]) AND status = 'ACTIVE'",
                                [body.version.stops[0].station_uid, body.version.stops[-1].station_uid])
        ids = {r["uid"]: r["id"] for r in ends}
        origin, dest = ids.get(body.version.stops[0].station_uid), ids.get(body.version.stops[-1].station_uid)
        if origin is None or dest is None or origin == dest:
            raise ApiError(422, "ROUTE_ENDS", "a route runs between two different active stations")
        code = await conn.fetchval("SELECT net.next_network_route_code($1, $2)", origin, dest)
        rid, ruid = await conn.fetchrow(
            """INSERT INTO net.network_route (code, name_en, name_ar, origin_station_id, dest_station_id, created_by)
               VALUES ($1, $2, $3, $4, $5, $6) RETURNING id, uid""", code, body.name_en.strip(), body.name_ar.strip(), origin, dest, pr.user_id)
        vuid = await _write_version(conn, rid, body.version, pr.user_id)
    request.state.audit = {"action": "network.route_add", "object_type": "network_route", "object_id": rid, "reason": code}
    return {"uid": ruid, "code": code, "version_uid": vuid, "status": "PENDING"}


@platform.post("/routes/{uid}/versions", status_code=201)
async def add_version(uid: uuid.UUID, body: VersionIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rid = await conn.fetchval("SELECT id FROM net.network_route WHERE uid = $1 AND status <> 'RETIRED'", uid)
        if rid is None:
            raise not_found("route")
        vuid = await _write_version(conn, rid, body, pr.user_id)
    request.state.audit = {"action": "network.route_version", "object_type": "network_route", "object_id": rid}
    return {"version_uid": vuid, "status": "PENDING"}


@platform.get("/versions")
async def versions(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT v.uid, r.uid AS route_uid, r.code, r.name_en, r.name_ar, v.version, v.status, v.effective_from, v.distance_km, v.note,
                      v.proposed_at, u.email AS proposed_by, v.decided_at, d.email AS decided_by, v.decision_note, (v.proposed_by = $1) AS mine,
                      (SELECT count(*) FROM net.network_route_stop s WHERE s.version_id = v.id) AS stops,
                      (SELECT count(*) FROM net.network_route_segment g WHERE g.version_id = v.id) AS segments
                 FROM net.network_route_version v JOIN net.network_route r ON r.id = v.route_id
                 JOIN iam.app_user u ON u.id = v.proposed_by LEFT JOIN iam.app_user d ON d.id = v.decided_by
                WHERE v.status IN ('PENDING', 'APPROVED') OR v.decided_at > now() - interval '60 days'
                ORDER BY v.status NOT IN ('PENDING', 'APPROVED'), v.proposed_at DESC LIMIT 200""", pr.user_id)
    return {"versions": [dict(r) for r in recs]}


class DecideIn(BaseModel):
    approve: bool
    note: Optional[str] = Field(default=None, max_length=500)


@platform.post("/versions/{uid}/decide")
async def decide(uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT net.decide_route_version($1, $2, $3)", uid, body.approve, body.note)
    request.state.audit = {"action": "network.route_decide", "object_type": "network_route_version", "reason": f"{uid} {status}"}
    return {"uid": uid, "status": status}


@platform.post("/versions/{uid}/withdraw")
async def withdraw(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT net.withdraw_route_version($1)", uid)
    request.state.audit = {"action": "network.route_withdraw", "object_type": "network_route_version", "reason": str(uid)}
    return {"uid": uid, "status": status}


_REQUESTS = """SELECT q.uid, co.legal_name AS company, fs.uid AS from_station_uid, fs.name AS from_station, fs.code AS from_code,
                      ts.uid AS to_station_uid, ts.name AS to_station, ts.code AS to_code, q.via, q.note, q.status, q.requested_at,
                      u.email AS requested_by, q.answered_at, a.email AS answered_by, q.answer, nr.code AS route_code
                 FROM net.route_request q JOIN iam.party co ON co.id = q.company_id
                 JOIN net.station fs ON fs.id = q.from_station_id JOIN net.station ts ON ts.id = q.to_station_id
                 LEFT JOIN iam.app_user u ON u.id = q.requested_by LEFT JOIN iam.app_user a ON a.id = q.answered_by
                 LEFT JOIN net.network_route nr ON nr.id = q.network_route_id"""


@platform.get("/requests")
async def requests_(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(_REQUESTS + " ORDER BY q.status <> 'OPEN', q.requested_at DESC LIMIT 200")
    return {"requests": [dict(r) for r in recs]}


class AnswerIn(BaseModel):
    status: Literal["DONE", "DECLINED"]
    answer: str = Field(min_length=3, max_length=1000)
    route_uid: Optional[uuid.UUID] = None


@platform.post("/requests/{uid}/answer")
async def answer(uid: uuid.UUID, body: AnswerIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rid = None
        if body.route_uid:
            rid = await conn.fetchval("SELECT id FROM net.network_route WHERE uid = $1", body.route_uid)
            if rid is None:
                raise not_found("route")
        done = await conn.fetchval(
            """UPDATE net.route_request SET status = $2, answer = $3, network_route_id = $4, answered_by = $5, answered_at = now()
                WHERE uid = $1 AND status = 'OPEN' RETURNING id""", uid, body.status, body.answer.strip(), rid, pr.user_id)
    if done is None:
        raise ApiError(409, "REQUEST_CLOSED", "the request is not open")
    request.state.audit = {"action": "network.request_answer", "object_type": "route_request", "object_id": done, "reason": body.status}
    return {"uid": uid, "status": body.status}


# ------------------------------------------------------------------ carrier
class RequestIn(BaseModel):
    from_station_uid: uuid.UUID
    to_station_uid: uuid.UUID
    via: Optional[str] = Field(default=None, max_length=500)
    note: str = Field(min_length=5, max_length=1000)


@carrier.get("")
async def my_requests(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(_REQUESTS + " WHERE q.company_id = $1 ORDER BY q.requested_at DESC LIMIT 100", pr.company_id)
    return {"requests": [dict(r) for r in recs]}


@carrier.post("", status_code=201)
async def ask(body: RequestIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    async with db.transaction(context_for(request, pr)) as conn:
        ids = {r["uid"]: r["id"] for r in await conn.fetch(
            "SELECT uid, id FROM net.station WHERE uid = ANY($1::uuid[]) AND status = 'ACTIVE'", [body.from_station_uid, body.to_station_uid])}
        a, b = ids.get(body.from_station_uid), ids.get(body.to_station_uid)
        if a is None or b is None or a == b:
            raise ApiError(422, "UNKNOWN_STATION", "choose two different active stations")
        uid = await conn.fetchval(
            """INSERT INTO net.route_request (company_id, from_station_id, to_station_id, via, note, requested_by)
               VALUES ($1, $2, $3, $4, $5, $6) RETURNING uid""", pr.company_id, a, b, body.via, body.note.strip(), pr.user_id)
    request.state.audit = {"action": "network.request", "object_type": "route_request"}
    return {"uid": uid, "status": "OPEN"}
