"""Driver app: assigned trips, boarding scan, stop arrival/departure and location reports."""
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import db
from ..deps import Principal, context_for, require_portal
from ..errors import ApiError, not_found
from ..security import verify_ticket_qr
from ..util import row_dict, rows

router = APIRouter(prefix="/api/driver", tags=["driver"])
driver = require_portal("DRIVER")


async def _assigned_trip(conn, pr: Principal, trip_uid: uuid.UUID):
    t = await conn.fetchrow(
        """SELECT t.* FROM ops.trip t JOIN ops.crew_assignment ca ON ca.trip_id = t.id
            WHERE t.uid = $1 AND ca.party_id = $2 AND ca.status <> 'RELEASED'""", trip_uid, pr.party_id)
    if t is None:
        raise ApiError(403, "NOT_ASSIGNED", "the trip is assigned to another driver")
    return t


@router.get("/trips")
async def my_trips(request: Request, pr: Principal = Depends(driver)):
    async with db.transaction(context_for(request, pr)) as conn:
        trips = await conn.fetch(
            """SELECT t.id, t.uid, t.trip_no, t.status, t.departure_at, t.arrival_at, t.seats_total, v.plate_no,
                      (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.status <> 'CANCELLED') AS booked,
                      (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.status = 'BOARDED') AS boarded
                 FROM ops.trip t JOIN ops.crew_assignment ca ON ca.trip_id = t.id
                 LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id
                WHERE ca.party_id = $1 AND t.status IN ('PUBLISHED','BOARDING','DEPARTED')
                  AND t.arrival_at > now() - interval '6 hours'
                ORDER BY t.departure_at LIMIT 20""", pr.party_id)
        stops = await conn.fetch(
            """SELECT ts.trip_id, ts.seq, ts.kind, ts.sched_arr, ts.sched_dep, ts.actual_arr, ts.actual_dep,
                      s.name AS station_name, s.code AS station_code, c.code AS city_code
                 FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id JOIN ref.city c ON c.id = s.city_id
                WHERE ts.trip_id = ANY($1::bigint[]) ORDER BY ts.trip_id, ts.seq""", [t["id"] for t in trips])
    by_trip: dict[int, list] = {}
    for s in stops:
        by_trip.setdefault(s["trip_id"], []).append({k: v for k, v in row_dict(s).items() if k != "trip_id"})
    return {"trips": [{**{k: v for k, v in row_dict(t).items() if k != "id"}, "stops": by_trip.get(t["id"], [])}
                      for t in trips]}


class ScanIn(BaseModel):
    trip_uid: uuid.UUID
    token: str = Field(min_length=10, max_length=200)
    stop_seq: int = Field(default=0, ge=0)


@router.post("/scan")
async def scan(body: ScanIn, request: Request, pr: Principal = Depends(driver)):
    ticket_uid = verify_ticket_qr(body.token.strip())
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, body.trip_uid)
        if ticket_uid is None:
            return {"result": "INVALID_QR"}
        k = await conn.fetchrow(
            """SELECT k.id, k.trip_id, k.status, k.seat_no, p.full_name FROM sales.ticket k
                 JOIN sales.passenger p ON p.id = k.passenger_id WHERE k.uid = $1""", uuid.UUID(ticket_uid))
        if k is None:
            return {"result": "INVALID_QR"}
        result = "OK"
        if k["trip_id"] != t["id"]:
            result = "WRONG_TRIP"
        elif k["status"] == "BOARDED":
            result = "DUPLICATE"
        elif k["status"] != "ISSUED":
            result = "INVALID_QR"
        await conn.execute(
            """INSERT INTO sales.boarding_event (ticket_id, trip_id, stop_seq, event_type, method, result, scanned_by_user_id)
               VALUES ($1, $2, $3, $4, 'AGENT_SCAN', $5, $6)""",
            k["id"], t["id"], body.stop_seq, "BOARD" if result == "OK" else "DENIED", result, pr.user_id)
        if result == "OK":
            await conn.execute("UPDATE sales.ticket SET status = 'BOARDED', boarded_at = now() WHERE id = $1", k["id"])
            if t["status"] == "PUBLISHED":
                await conn.execute("UPDATE ops.trip SET status = 'BOARDING' WHERE id = $1", t["id"])
    request.state.audit = {"action": "boarding.scan", "object_type": "ticket", "object_id": k["id"]}
    return {"result": result, "seat_no": k["seat_no"], "passenger": k["full_name"]}


class StopEventIn(BaseModel):
    kind: Literal["ARRIVE", "DEPART"]


@router.post("/trips/{trip_uid}/stops/{seq}")
async def stop_event(trip_uid: uuid.UUID, seq: int, body: StopEventIn, request: Request, pr: Principal = Depends(driver)):
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, trip_uid)
        stop = await conn.fetchrow("SELECT * FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2", t["id"], seq)
        if stop is None:
            raise not_found("stop")
        sched = stop["sched_arr"] if body.kind == "ARRIVE" else stop["sched_dep"]
        delay = await conn.fetchval("SELECT round(extract(epoch FROM now() - $1::timestamptz) / 60)::int", sched)
        await conn.execute(
            "INSERT INTO ops.trip_stop_event (trip_id, seq, kind, ts, delay_min, by_user_id) VALUES ($1, $2, $3, now(), $4, $5)",
            t["id"], seq, body.kind, delay, pr.user_id)
        if body.kind == "ARRIVE":
            await conn.execute("UPDATE ops.trip_stop SET actual_arr = now() WHERE trip_id = $1 AND seq = $2", t["id"], seq)
        else:
            # Leaving a stop closes sales from it and frees the seats of passengers who did not show up there
            await conn.execute(
                "UPDATE ops.trip_stop SET actual_dep = now(), sales_closed_at = now() WHERE trip_id = $1 AND seq = $2",
                t["id"], seq)
            if t["status"] in ("PUBLISHED", "BOARDING"):
                await conn.execute("UPDATE ops.trip SET status = 'DEPARTED' WHERE id = $1", t["id"])
    request.state.audit = {"action": f"trip.stop.{body.kind.lower()}", "object_type": "trip", "object_id": t["id"]}
    return {"ok": True, "delay_min": delay}


class LocationIn(BaseModel):
    trip_uid: uuid.UUID
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    speed_kmh: Optional[float] = Field(default=None, ge=0, le=300)
    accuracy_m: Optional[float] = Field(default=None, ge=0)


@router.post("/location")
async def location(body: LocationIn, request: Request, pr: Principal = Depends(driver)):
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, body.trip_uid)
        await conn.execute(
            """INSERT INTO ops.geo_event (ts, trip_id, vehicle_id, driver_user_id, lat, lng, speed_kmh, accuracy_m)
               VALUES (now(), $1, $2, $3, $4, $5, $6, $7)""",
            t["id"], t["vehicle_id"], pr.user_id, body.lat, body.lng, body.speed_kmh, body.accuracy_m)
        await conn.execute(
            "UPDATE ops.tracking_alert SET status = 'RESOLVED', resolved_at = now() WHERE trip_id = $1 AND status = 'OPEN' "
            "AND kind IN ('SIGNAL_LOST','TRACKING_OFF')", t["id"])
    return {"ok": True}
