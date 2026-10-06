"""Public catalog: reference data, stations, trip search and trip details with the seat map."""
import json
from datetime import date
from typing import Optional

from fastapi import APIRouter, Query, Request

from .. import db
from ..config import get_settings
from ..deps import base_context
from ..errors import ApiError, not_found
from ..modules.sales import documents
from ..util import row_dict, rows

router = APIRouter(prefix="/api", tags=["public"])

# Seats that are free for a segment: available, or locked with an expired hold
FREE_SEG = "(s.status = 'AVAILABLE' OR (s.status = 'LOCKED' AND s.lock_expires_at < now()))"


def _ctx(request: Request):
    ctx = base_context(request)
    ctx.scope = "PASSENGER"
    return ctx


@router.get("/health")
async def health():
    return {"ok": True}


@router.get("/public/keys/ticket")
async def ticket_key():
    """Public key for verifying offline ticket credentials (Ed25519). Apps pin it and can check tickets offline."""
    from ..security import ticket_public_key
    return {"alg": "Ed25519", "kid": "ticket-credential/v1", "public_key": ticket_public_key()}


@router.get("/ref")
async def reference(request: Request):
    async with db.transaction(_ctx(request)) as conn:
        cities = await conn.fetch(
            "SELECT id, code, name, country_code, lat, lng FROM ref.city WHERE is_active ORDER BY name")
        locales = await conn.fetch(
            "SELECT code, name, native_name, direction, is_default FROM ref.locale WHERE is_enabled ORDER BY is_default DESC, code")
        countries = await conn.fetch("SELECT code FROM ref.country ORDER BY code")
        brands = await conn.fetch(
            "SELECT code, name, factor, rules FROM pricing.fare_brand WHERE active AND company_id IS NULL ORDER BY sort")
    return {"cities": rows(cities), "locales": rows(locales), "platform_fee": get_settings().platform_fee,
            "countries": [c["code"] for c in countries],
            "fare_brands": [{**row_dict(b), "factor": float(b["factor"]),
                             "rules": json.loads(b["rules"]) if isinstance(b["rules"], str) else b["rules"]} for b in brands]}


@router.get("/stations")
async def stations(request: Request, city: Optional[str] = None):
    async with db.transaction(_ctx(request)) as conn:
        recs = await conn.fetch(
            """SELECT s.uid, s.code, s.name, s.address, s.lat, s.lng, s.station_class, c.code AS city_code, s.lead_min
                 FROM net.station s JOIN ref.city c ON c.id = s.city_id
                WHERE s.status = 'ACTIVE' AND ($1::text IS NULL OR c.code = $1)
                ORDER BY c.code, s.code""", city)
    return {"stations": rows(recs)}


@router.get("/trips/search")
async def search(request: Request, origin: str = Query(..., min_length=3, max_length=3),
                 destination: str = Query(..., min_length=3, max_length=3), on: date = Query(...),
                 passengers: int = Query(1, ge=1, le=4)):
    if origin == destination:
        raise ApiError(422, "SAME_CITY", "origin and destination must differ")
    async with db.transaction(_ctx(request)) as conn:
        recs = await conn.fetch(
            f"""
            WITH pairs AS (
              SELECT DISTINCT ON (t.id)
                     t.id, t.uid, t.trip_no, t.company_id, t.service_type, t.has_rest, t.seats_total, t.currency,
                     a.seq AS from_seq, b.seq AS to_seq, a.sched_dep AS departs_at, b.sched_arr AS arrives_at,
                     sa.name AS from_station, sb.name AS to_station, sa.code AS from_code, sb.code AS to_code,
                     coalesce(pf.price, b.fare_from_origin - a.fare_from_origin) AS price
                FROM ops.trip t
                JOIN ops.trip_stop a ON a.trip_id = t.id JOIN net.station sa ON sa.id = a.station_id
                JOIN ref.city ca ON ca.id = sa.city_id
                JOIN ops.trip_stop b ON b.trip_id = t.id AND b.seq > a.seq JOIN net.station sb ON sb.id = b.station_id
                JOIN ref.city cb ON cb.id = sb.city_id
                LEFT JOIN ops.trip_pair_fare pf ON pf.trip_id = t.id AND pf.from_seq = a.seq AND pf.to_seq = b.seq
               WHERE t.status IN ('PUBLISHED','BOARDING')
                 AND ca.code = $1 AND cb.code = $2
                 AND a.kind = 'STATION' AND b.kind = 'STATION' AND a.sellable AND a.sales_closed_at IS NULL
                 AND (t.service_type = 'INDIRECT' OR (a.seq = 0 AND b.seq = t.segments_count))
                 AND (a.sched_dep AT TIME ZONE 'Asia/Damascus')::date = $3
                 AND a.sched_dep > now() + make_interval(mins => t.sales_cutoff_min)
               ORDER BY t.id, a.seq, b.seq DESC
            )
            SELECT p.*, cp.legal_name AS carrier_name, cc.code3 AS carrier_code,
                   (SELECT count(*) FROM ops.trip_stop x WHERE x.trip_id = p.id AND x.seq > p.from_seq
                       AND x.seq < p.to_seq AND x.kind = 'STATION') AS stops_between,
                   p.seats_total - (SELECT count(DISTINCT s.seat_no) FROM ops.seat_segment s
                       WHERE s.trip_id = p.id AND s.seg >= p.from_seq AND s.seg < p.to_seq AND NOT {FREE_SEG}) AS seats_left
              FROM pairs p
              JOIN iam.party cp ON cp.id = p.company_id
              LEFT JOIN net.carrier_code cc ON cc.company_id = p.company_id AND cc.status = 'ACTIVE'
             ORDER BY p.departs_at
            """, origin.upper(), destination.upper(), on)
    trips = [row_dict(r) for r in recs]
    for t in trips:
        t.pop("id")
        t.pop("company_id")
        t["bookable"] = t["seats_left"] >= passengers
    return {"trips": trips}


@router.get("/trips/{trip_uid}/documents")
async def trip_documents(trip_uid: str, request: Request, from_seq: int = Query(..., ge=0), to_seq: int = Query(..., ge=1),
                         nationality: str = Query("SY", pattern=r"^[A-Z]{2}$")):
    """Documents a passenger of this nationality needs on this segment: passport by default on international trips,
    or the other documents an approved exception accepts (11.9)."""
    if to_seq <= from_seq:
        raise ApiError(422, "INVALID_PAIR", "to_seq must be after from_seq")
    async with db.transaction(_ctx(request)) as conn:
        t = await conn.fetchrow(
            "SELECT id FROM ops.trip WHERE uid = $1::uuid AND status IN ('PUBLISHED','BOARDING')", trip_uid)
        if t is None:
            raise not_found("trip")
        departs = await conn.fetchval(
            "SELECT (sched_dep AT TIME ZONE 'Asia/Damascus')::date FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2",
            t["id"], from_seq)
        if departs is None:
            raise ApiError(422, "INVALID_PAIR", "unknown stop")
        req = await documents.requirement(conn, t["id"], from_seq, to_seq, nationality, departs)
    return {**req.public(), "departs": departs.isoformat()}


@router.get("/trips/{trip_uid}")
async def trip_detail(trip_uid: str, request: Request, from_seq: int = Query(..., ge=0), to_seq: int = Query(..., ge=1)):
    if to_seq <= from_seq:
        raise ApiError(422, "INVALID_PAIR", "to_seq must be after from_seq")
    async with db.transaction(_ctx(request)) as conn:
        t = await conn.fetchrow(
            """SELECT t.id, t.uid, t.trip_no, t.status, t.seats_total, t.currency, t.seat_selection_mode, t.hold_min,
                      t.service_type, t.segments_count, t.departure_at, t.arrival_at, t.baggage_policy,
                      t.seat_prices_snapshot, t.seat_map, cp.legal_name AS carrier_name, cc.code3 AS carrier_code
                 FROM ops.trip t JOIN iam.party cp ON cp.id = t.company_id
                 LEFT JOIN net.carrier_code cc ON cc.company_id = t.company_id AND cc.status = 'ACTIVE'
                WHERE t.uid = $1::uuid AND t.status IN ('PUBLISHED','BOARDING')""", trip_uid)
        if t is None:
            raise not_found("trip")
        if to_seq > t["segments_count"]:
            raise ApiError(422, "INVALID_PAIR", "unknown stop")
        stops = await conn.fetch(
            """SELECT ts.seq, ts.kind, ts.sched_arr, ts.sched_dep, ts.fare_from_origin, ts.rest_min,
                      s.name AS station_name, s.code AS station_code, c.code AS city_code, s.lat, s.lng
                 FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id JOIN ref.city c ON c.id = s.city_id
                WHERE ts.trip_id = $1 ORDER BY ts.seq""", t["id"])
        seats = await conn.fetch(
            f"""SELECT s.seat_no, bool_and({FREE_SEG}) AS free
                  FROM ops.seat_segment s
                 WHERE s.trip_id = $1 AND s.seg >= $2 AND s.seg < $3
                 GROUP BY s.seat_no ORDER BY s.seat_no""", t["id"], from_seq, to_seq)
        pf = await conn.fetchval("SELECT price FROM ops.trip_pair_fare WHERE trip_id = $1 AND from_seq = $2 AND to_seq = $3",
                                 t["id"], from_seq, to_seq)
    ladder = {s["seq"]: s["fare_from_origin"] for s in stops}
    price = pf if pf is not None else ladder[to_seq] - ladder[from_seq]
    trip = row_dict(t)
    trip.pop("id")
    seat_map = trip.pop("seat_map")
    seat_map = json.loads(seat_map) if isinstance(seat_map, str) else seat_map
    return {"seat_map": seat_map, "trip": trip, "stops": rows(stops), "price": price, "from_seq": from_seq, "to_seq": to_seq,
            "seats": [{"seat_no": s["seat_no"], "free": s["free"]} for s in seats]}
