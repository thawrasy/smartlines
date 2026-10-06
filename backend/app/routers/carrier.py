"""Carrier (operator) portal: dashboard, fleet, crew, routes, trips, manifest and trip completion."""
import json
import uuid
from datetime import date, datetime, timedelta
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, EmailStr, Field

from .. import db
from ..deps import Principal, context_for, require_portal
from ..errors import ApiError, forbidden, not_found
from ..ledger import platform_wallet, post_txn
from ..modules.fleet import service as fleet
from ..security import hash_password, password_problem
from ..util import LOCAL_TZ, row_dict, rows

router = APIRouter(prefix="/api/carrier", tags=["carrier"])
operator = require_portal("OPERATOR")


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


@router.get("/dashboard")
async def dashboard(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        today = datetime.now(LOCAL_TZ).date()
        stats = await conn.fetchrow(
            """SELECT
                 (SELECT count(*) FROM ops.trip WHERE company_id = $1 AND (departure_at AT TIME ZONE 'Asia/Damascus')::date = $2
                     AND status <> 'CANCELLED') AS trips_today,
                 (SELECT coalesce(sum(total_amount), 0) FROM sales.booking WHERE company_id = $1
                     AND status IN ('CONFIRMED','COMPLETED') AND (created_at AT TIME ZONE 'Asia/Damascus')::date = $2) AS sales_today,
                 (SELECT count(*) FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id WHERE b.company_id = $1
                     AND k.status <> 'CANCELLED' AND (b.created_at AT TIME ZONE 'Asia/Damascus')::date = $2) AS tickets_today,
                 (SELECT coalesce(balance, 0) FROM fin.wallet WHERE owner_party_id = $1 AND wallet_type = 'COMPANY'
                     AND currency = 'SYP') AS released_balance,
                 (SELECT count(*) FROM fleet.vehicle WHERE company_id = $1 AND status = 'ACTIVE') AS active_vehicles""",
            pr.company_id, today)
        load = await conn.fetchrow(
            """SELECT coalesce(sum(sold), 0) AS sold, coalesce(sum(cap), 0) AS cap FROM (
                 SELECT t.seats_total * t.segments_count AS cap,
                        (SELECT count(*) FROM ops.seat_segment s WHERE s.trip_id = t.id AND s.status = 'SOLD') AS sold
                   FROM ops.trip t WHERE t.company_id = $1 AND t.status IN ('PUBLISHED','BOARDING','DEPARTED','COMPLETED')
                    AND t.departure_at > now() - interval '30 days') x""", pr.company_id)
        trips = await conn.fetch(
            """SELECT t.uid, t.trip_no, t.status, t.departure_at, t.seats_total, v.plate_no,
                      so.name AS origin, sd.name AS destination, so.code AS origin_code, sd.code AS dest_code,
                      (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.status <> 'CANCELLED') AS sold
                 FROM ops.trip t JOIN net.route r ON r.id = t.route_id
                 JOIN net.station so ON so.id = r.origin_station_id JOIN net.station sd ON sd.id = r.dest_station_id
                 LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id
                WHERE t.company_id = $1 AND t.departure_at >= now() - interval '6 hours' AND t.status <> 'CANCELLED'
                ORDER BY t.departure_at LIMIT 8""", pr.company_id)
        alerts = await conn.fetch(
            """SELECT 'LICENSE_EXPIRING' AS kind, l.license_type AS detail, l.expiry_date::text AS at, v.plate_no AS subject
                 FROM fleet.license_record l JOIN fleet.vehicle v ON v.id = l.subject_id AND l.subject_type = 'VEHICLE'
                WHERE l.company_id = $1 AND l.expiry_date < current_date + 30
               UNION ALL
               SELECT 'TRACKING_' || a.kind, a.severity, a.opened_at::text, t.trip_no
                 FROM ops.tracking_alert a JOIN ops.trip t ON t.id = a.trip_id
                WHERE t.company_id = $1 AND a.status = 'OPEN'
               LIMIT 10""", pr.company_id)
    lf = round(100 * load["sold"] / load["cap"]) if load["cap"] else 0
    return {**row_dict(stats), "load_factor": lf, "trips": rows(trips), "alerts": rows(alerts)}


# ------------------------------------------------------------------ stations
@router.get("/stations")
async def usable_stations(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT s.uid, s.code, s.name, s.station_class, c.code AS city_code
                 FROM net.station s JOIN ref.city c ON c.id = s.city_id
                WHERE s.status = 'ACTIVE' AND (s.station_class = 'CENTRAL' OR s.owner_company_id = $1)
                ORDER BY c.code, s.code""", pr.company_id)
    return {"stations": rows(recs)}


# ------------------------------------------------------------------ vehicles
class VehicleIn(BaseModel):
    plate_no: str = Field(min_length=3, max_length=20)
    chassis_no: str = Field(min_length=5, max_length=40)
    vehicle_type: Literal["COACH", "MINIBUS", "CITY_BUS", "VAN"] = "COACH"
    make: Optional[str] = None
    model: Optional[str] = None
    manufacture_year: Optional[int] = Field(default=None, ge=1970, le=2100)
    # The seat layout defines rows, seats per row, aisle and doors; the seat count comes from it
    seat_layout_uid: Optional[uuid.UUID] = None
    passenger_seats: Optional[int] = Field(default=None, ge=1, le=99)
    insurance_no: str = Field(min_length=3, max_length=40)
    insurer: str = Field(min_length=2, max_length=120)
    insurance_issue: date
    insurance_expiry: date


@router.get("/vehicles")
async def vehicles(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT v.uid, v.plate_no, v.vehicle_type, v.make, v.model, v.manufacture_year, v.passenger_seats,
                      v.status, v.block_reason, v.ownership_type, l.uid AS seat_layout_uid, l.name AS seat_layout_name,
                      (SELECT min(l.expiry_date) FROM fleet.license_record l
                        WHERE l.subject_type = 'VEHICLE' AND l.subject_id = v.id) AS next_expiry
                 FROM fleet.vehicle v LEFT JOIN fleet.seat_layout l ON l.id = v.seat_layout_id
                WHERE v.company_id = $1 ORDER BY v.plate_no""", pr.company_id)
    return {"vehicles": rows(recs)}


@router.post("/vehicles", status_code=201)
async def add_vehicle(body: VehicleIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "vehicle.manage")
    if body.insurance_expiry <= max(body.insurance_issue, date.today()):
        raise ApiError(422, "INSURANCE_EXPIRED", "a valid insurance policy is required to register a vehicle")
    async with db.transaction(context_for(request, pr)) as conn:
        layout_id, seats = await fleet.layout_for_new_vehicle(conn, body.seat_layout_uid, body.passenger_seats)
        vid = await conn.fetchval(
            """INSERT INTO fleet.vehicle (company_id, vehicle_type, make, model, manufacture_year, plate_no, chassis_no,
                 passenger_seats, seat_layout_id, owner_party_id, status)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $1, 'ACTIVE') RETURNING id""",
            pr.company_id, body.vehicle_type, body.make, body.model, body.manufacture_year, body.plate_no.strip(),
            body.chassis_no.strip().upper(), seats, layout_id)
        await conn.execute(
            """INSERT INTO fleet.license_record (company_id, subject_type, subject_id, license_type, license_no, issuer,
                 issue_date, expiry_date, status)
               VALUES ($1, 'VEHICLE', $2, 'INSURANCE', $3, $4, $5, $6, 'VALID')""",
            pr.company_id, vid, body.insurance_no, body.insurer, body.insurance_issue, body.insurance_expiry)
        uid = await conn.fetchval("SELECT uid FROM fleet.vehicle WHERE id = $1", vid)
    request.state.audit = {"action": "vehicle.create", "object_type": "vehicle", "object_id": vid}
    return {"uid": str(uid)}


# ------------------------------------------------------------------ crew
class DriverIn(BaseModel):
    full_name: str = Field(min_length=3, max_length=120)
    email: EmailStr
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")
    password: str
    license_class: Optional[str] = None


@router.get("/crew")
async def crew(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT p.uid, p.legal_name AS full_name, cp.crew_type, cp.license_class, cp.status, u.email
                 FROM fleet.crew_profile cp JOIN iam.party p ON p.id = cp.party_id
                 LEFT JOIN iam.app_user u ON u.party_id = p.id
                WHERE cp.company_id = $1 ORDER BY p.legal_name""", pr.company_id)
    return {"crew": rows(recs)}


@router.post("/crew", status_code=201)
async def add_driver(body: DriverIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "company.staff", "trip.assign_crew")
    problem = password_problem(body.password)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        role_id = await conn.fetchval("SELECT id FROM iam.role WHERE code = 'CARRIER_DRIVER' AND company_id IS NULL")
        party_id = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name, email, mobile) VALUES ('PERSON', $1, $2, $3) RETURNING id",
            body.full_name.strip(), body.email, body.mobile)
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'DRIVER')", party_id)
        user_id = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, mobile, password_hash, password_changed_at, status,
                 preferred_locale) VALUES ($1, 'COMPANY', $2, $3, $4, now(), 'ACTIVE', (SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale')) RETURNING id""",
            party_id, body.email, body.mobile, hash_password(body.password))
        await conn.execute("INSERT INTO iam.company_member (user_id, company_id, role_id) VALUES ($1, $2, $3)",
                           user_id, pr.company_id, role_id)
        await conn.execute(
            "INSERT INTO fleet.crew_profile (party_id, company_id, crew_type, license_class) VALUES ($1, $2, 'DRIVER', $3)",
            party_id, pr.company_id, body.license_class)
        uid = await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", party_id)
    request.state.audit = {"action": "crew.create", "object_type": "party", "object_id": party_id}
    return {"uid": str(uid)}


# ------------------------------------------------------------------ routes
class RouteStopIn(BaseModel):
    station_uid: uuid.UUID
    arr_offset_min: int = Field(ge=0)
    dep_offset_min: int = Field(ge=0)
    fare_from_origin: int = Field(ge=0)


class RouteIn(BaseModel):
    code: str = Field(min_length=2, max_length=20, pattern=r"^[A-Z0-9-]+$")
    stops: list[RouteStopIn] = Field(min_length=2, max_length=20)


@router.get("/routes")
async def routes(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT r.id, r.uid, r.code, r.service_type, r.status, r.std_duration_min
                 FROM net.route r WHERE r.company_id = $1 ORDER BY r.code""", pr.company_id)
        stops = await conn.fetch(
            """SELECT rs.route_id, rs.seq, rs.kind, rs.arr_offset_min, rs.dep_offset_min, rs.fare_from_origin,
                      s.uid AS station_uid, s.name AS station_name, s.code AS station_code, c.code AS city_code
                 FROM net.route_stop rs JOIN net.station s ON s.id = rs.station_id JOIN ref.city c ON c.id = s.city_id
                WHERE rs.route_id = ANY($1::bigint[]) ORDER BY rs.route_id, rs.seq""", [r["id"] for r in recs])
    by_route: dict[int, list] = {}
    for s in stops:
        by_route.setdefault(s["route_id"], []).append({k: v for k, v in row_dict(s).items() if k != "route_id"})
    return {"routes": [{**{k: v for k, v in row_dict(r).items() if k != "id"}, "stops": by_route.get(r["id"], [])}
                       for r in recs]}


@router.post("/routes", status_code=201)
async def add_route(body: RouteIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    fares = [s.fare_from_origin for s in body.stops]
    if fares[0] != 0 or any(b <= a for a, b in zip(fares, fares[1:])):
        raise ApiError(422, "INVALID_FARE_LADDER", "the fare ladder must start at 0 and increase at every stop")
    offs = [(s.arr_offset_min, s.dep_offset_min) for s in body.stops]
    if offs[0] != (0, 0) or any(d < a for a, d in offs) or any(b[0] <= a[1] for a, b in zip(offs, offs[1:])):
        raise ApiError(422, "INVALID_TIMES", "stop times must increase along the route")
    async with db.transaction(context_for(request, pr)) as conn:
        ids = []
        for s in body.stops:
            sid = await conn.fetchval(
                "SELECT id FROM net.station WHERE uid = $1 AND status = 'ACTIVE' "
                "AND (station_class = 'CENTRAL' OR owner_company_id = $2)", s.station_uid, pr.company_id)
            if sid is None:
                raise ApiError(422, "UNKNOWN_STATION", "station not available")
            ids.append(sid)
        if len(set(ids)) != len(ids):
            raise ApiError(422, "DUPLICATE_STATION", "a station appears twice")
        rid = await conn.fetchval(
            """INSERT INTO net.route (company_id, code, origin_station_id, dest_station_id, service_type, std_duration_min)
               VALUES ($1, $2, $3, $4, $5, $6) RETURNING id""",
            pr.company_id, body.code, ids[0], ids[-1], "INDIRECT" if len(ids) > 2 else "DIRECT", offs[-1][0])
        n = len(ids)
        await conn.executemany(
            """INSERT INTO net.route_stop (route_id, seq, station_id, kind, arr_offset_min, dep_offset_min, fare_from_origin)
               VALUES ($1, $2, $3, $4, $5, $6, $7)""",
            [(rid, i, ids[i], "ORIGIN" if i == 0 else ("DEST" if i == n - 1 else "STOP"),
              s.arr_offset_min, s.dep_offset_min, s.fare_from_origin) for i, s in enumerate(body.stops)])
        uid = await conn.fetchval("SELECT uid FROM net.route WHERE id = $1", rid)
    request.state.audit = {"action": "route.create", "object_type": "route", "object_id": rid}
    return {"uid": str(uid)}


# ------------------------------------------------------------------ trips
class TripIn(BaseModel):
    route_uid: uuid.UUID
    vehicle_uid: uuid.UUID
    departure_local: datetime                 # local time in Asia/Damascus, e.g. 2026-10-10T07:30
    driver_uid: Optional[uuid.UUID] = None
    publish: bool = True


@router.get("/trips")
async def trips(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT t.uid, t.trip_no, t.status, t.departure_at, t.arrival_at, t.seats_total, t.segments_count,
                      v.plate_no, r.code AS route_code, so.name AS origin, sd.name AS destination, so.code AS origin_code, sd.code AS dest_code,
                      (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.status <> 'CANCELLED') AS sold,
                      (SELECT p.legal_name FROM ops.crew_assignment ca JOIN iam.party p ON p.id = ca.party_id
                        WHERE ca.trip_id = t.id AND ca.crew_role = 'DRIVER' LIMIT 1) AS driver_name
                 FROM ops.trip t JOIN net.route r ON r.id = t.route_id
                 JOIN net.station so ON so.id = r.origin_station_id JOIN net.station sd ON sd.id = r.dest_station_id
                 LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id
                WHERE t.company_id = $1 AND t.departure_at > now() - interval '3 days'
                ORDER BY t.departure_at LIMIT 200""", pr.company_id)
    return {"trips": rows(recs)}


@router.post("/trips", status_code=201)
async def create_trip(body: TripIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    dep = body.departure_local.replace(tzinfo=LOCAL_TZ) if body.departure_local.tzinfo is None else body.departure_local
    if dep < datetime.now(LOCAL_TZ) + timedelta(minutes=30):
        raise ApiError(422, "DEPARTURE_TOO_SOON", "departure must be at least 30 minutes ahead")
    async with db.transaction(context_for(request, pr)) as conn:
        route = await conn.fetchrow("SELECT id, code FROM net.route WHERE uid = $1 AND company_id = $2 AND status = 'ACTIVE'",
                                    body.route_uid, pr.company_id)
        vehicle = await conn.fetchrow("SELECT id, passenger_seats, plate_no FROM fleet.vehicle WHERE uid = $1",
                                      body.vehicle_uid)
        if route is None or vehicle is None:
            raise not_found("route or vehicle")
        stops = await conn.fetch("SELECT * FROM net.route_stop WHERE route_id = $1 ORDER BY seq", route["id"])
        code3 = await conn.fetchval("SELECT code3 FROM net.carrier_code WHERE company_id = $1 AND status = 'ACTIVE'",
                                    pr.company_id) or "XXX"
        local = dep.astimezone(LOCAL_TZ)
        trip_no = f"{code3}-{route['code']}-{local:%H%M}/{local:%d%b%y}".upper()
        n = len(stops)
        arrival = dep + timedelta(minutes=stops[-1]["arr_offset_min"])
        status = "PUBLISHED" if body.publish else "DRAFT"
        # The trip keeps the vehicle's seat map as it is today, so seats sold never move if the layout changes
        seat_map = await fleet.trip_seat_map(conn, vehicle["id"])
        trip_id = await conn.fetchval(
            """INSERT INTO ops.trip (trip_no, company_id, route_id, service_type, vehicle_id, departure_at, arrival_at,
                 status, seats_total, segments_count, currency, base_price, published_at, seat_map)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'SYP', $11, CASE WHEN $8 = 'PUBLISHED' THEN now() END,
                       $12::jsonb)
               RETURNING id""",
            trip_no, pr.company_id, route["id"], "INDIRECT" if n > 2 else "DIRECT", vehicle["id"], dep, arrival, status,
            vehicle["passenger_seats"], n - 1, stops[-1]["fare_from_origin"], json.dumps(seat_map) if seat_map else None)
        await conn.executemany(
            """INSERT INTO ops.trip_stop (trip_id, seq, station_id, kind, sched_arr, sched_dep, fare_from_origin, rest_min)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
            [(trip_id, s["seq"], s["station_id"], "REST" if s["kind"] == "REST" else "STATION",
              dep + timedelta(minutes=s["arr_offset_min"]), dep + timedelta(minutes=s["dep_offset_min"]),
              s["fare_from_origin"], s["rest_min"]) for s in stops])
        await conn.execute(
            """INSERT INTO ops.seat_segment (trip_id, seat_no, seg)
               SELECT $1, seat, seg FROM generate_series(1, $2) seat, generate_series(0, $3) seg""",
            trip_id, vehicle["passenger_seats"], n - 2)
        if body.driver_uid:
            driver = await conn.fetchval(
                """SELECT cp.party_id FROM fleet.crew_profile cp JOIN iam.party p ON p.id = cp.party_id
                    WHERE p.uid = $1 AND cp.status = 'ACTIVE'""", body.driver_uid)
            if driver is None:
                raise not_found("driver")
            await conn.execute("INSERT INTO ops.crew_assignment (trip_id, party_id, crew_role) VALUES ($1, $2, 'DRIVER')",
                               trip_id, driver)
        uid = await conn.fetchval("SELECT uid FROM ops.trip WHERE id = $1", trip_id)
    request.state.audit = {"action": "trip.create", "object_type": "trip", "object_id": trip_id}
    return {"uid": str(uid), "trip_no": trip_no}


async def _own_trip(conn, pr: Principal, trip_uid: uuid.UUID):
    t = await conn.fetchrow("SELECT * FROM ops.trip WHERE uid = $1 AND company_id = $2", trip_uid, pr.company_id)
    if t is None:
        raise not_found("trip")
    return t


@router.post("/trips/{trip_uid}/publish")
async def publish_trip(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _own_trip(conn, pr, trip_uid)
        if t["status"] != "DRAFT":
            raise ApiError(409, "INVALID_TRANSITION", "only draft trips can be published")
        await conn.execute("UPDATE ops.trip SET status = 'PUBLISHED', published_at = now() WHERE id = $1", t["id"])
    request.state.audit = {"action": "trip.publish", "object_type": "trip", "object_id": t["id"]}
    return {"ok": True}


@router.get("/trips/{trip_uid}/manifest")
async def manifest(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "manifest.view", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _own_trip(conn, pr, trip_uid)
        recs = await conn.fetch(
            """SELECT k.ticket_no, k.seat_no, k.status, p.full_name, p.nationality, p.id_type, p.id_no_last4, b.booking_ref,
                      sa.name AS from_station, sb.name AS to_station, sa.code AS from_code, sb.code AS to_code, k.boarded_at
                 FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id JOIN sales.booking b ON b.id = k.booking_id
                 JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq JOIN net.station sa ON sa.id = a.station_id
                 JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq JOIN net.station sb ON sb.id = z.station_id
                WHERE k.trip_id = $1 AND k.status <> 'CANCELLED' ORDER BY k.seat_no""", t["id"])
    request.state.audit = {"action": "manifest.view", "object_type": "trip", "object_id": t["id"]}
    return {"trip_no": t["trip_no"], "passengers": rows(recs)}


@router.post("/trips/{trip_uid}/complete")
async def complete_trip(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    """Completes the trip and releases each allocation leaf from escrow to its beneficiary (5.7)."""
    _need(pr, "trip.complete")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        t = await _own_trip(conn, pr, trip_uid)
        if t["status"] not in ("PUBLISHED", "BOARDING", "DEPARTED"):
            raise ApiError(409, "INVALID_TRANSITION", "trip cannot be completed from its current status")
        if t["departure_at"] > datetime.now(LOCAL_TZ):
            raise ApiError(409, "TRIP_NOT_STARTED", "a trip can be completed only after departure")
        await conn.execute("UPDATE ops.trip SET status = 'COMPLETED' WHERE id = $1", t["id"])
        released = 0
        async with db.system_scope(conn, ctx):
            escrow = await platform_wallet(conn, "ESCROW", t["currency"])
            lines = await conn.fetch(
                """SELECT l.id, l.amount - l.refunded_amount AS due, l.wallet_id, b.id AS booking_id
                     FROM fin.price_allocation_line l JOIN fin.price_allocation a ON a.id = l.allocation_id
                     JOIN sales.booking b ON b.id = a.booking_id
                    WHERE b.trip_id = $1 AND l.is_leaf AND l.release_event = 'TRIP_COMPLETED'
                      AND l.status IN ('HELD','PARTIAL_REFUND')""", t["id"])
            entries = [(ln["wallet_id"], "CR", ln["due"]) for ln in lines if ln["due"] > 0]
            released = sum(e[2] for e in entries)
            if released:
                await post_txn(conn, "RELEASE", t["currency"], f"trip:{t['id']}:release",
                               [(escrow["id"], "DR", released), *entries],
                               ref_type="trip", ref_id=t["id"], user_id=pr.user_id, memo=t["trip_no"])
            await conn.execute(
                "UPDATE fin.price_allocation_line SET status = 'RELEASED', released_at = now() WHERE id = ANY($1::bigint[])", [ln["id"] for ln in lines])
            await conn.execute("UPDATE sales.booking SET status = 'COMPLETED' WHERE trip_id = $1 AND status = 'CONFIRMED'",
                               t["id"])
            await conn.execute("UPDATE sales.ticket SET status = 'NO_SHOW' WHERE trip_id = $1 AND status = 'ISSUED'", t["id"])
    request.state.audit = {"action": "trip.complete", "object_type": "trip", "object_id": t["id"]}
    return {"ok": True, "released": released}
