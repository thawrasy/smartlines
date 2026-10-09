"""Driver app: assigned trips, boarding scan, stop arrival/departure and location reports."""
import uuid
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import db, telemetry
from ..deps import Principal, context_for, require_portal
from ..errors import ApiError, not_found
from ..security import ticket_public_key, verify_ticket_credential, verify_ticket_qr
from ..util import row_dict, ticket_name

router = APIRouter(prefix="/api/driver", tags=["driver"])
driver = require_portal("DRIVER")
SCAN_LEAD_HOURS = 24      # an offline scan claimed earlier than this before departure is dated at its upload


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
    token: str = Field(min_length=10, max_length=600)
    # the stop of the trip where the passenger boards; omitted: the first stop of their ticket (R-10)
    stop_seq: Optional[int] = Field(default=None, ge=0)


def _ticket_from_token(token: str, trip_uid: uuid.UUID, at: Optional[datetime] = None) -> tuple[Optional[str], Optional[str]]:
    """(ticket uid, early result). Accepts the rotating online code (T1) and the signed offline credential (T2).
    at: when the code was scanned, for a scan made offline and uploaded later; the credential must have been valid then."""
    token = token.strip()
    if token.startswith("T2."):
        claims = verify_ticket_credential(token, at.timestamp() if at else None)
        if claims is None:
            return None, "INVALID_QR"
        if claims.get("t") != str(trip_uid):
            return claims["k"], "WRONG_TRIP"
        return claims["k"], None
    uid = verify_ticket_qr(token)
    return uid, None if uid else "INVALID_QR"


async def _board(conn, pr: Principal, t, ticket_uid: Optional[str], early: Optional[str], stop_seq: Optional[int],
                 method: str = "AGENT_SCAN", device_scan_id: Optional[str] = None, scanned_at=None) -> dict:
    """Applies one boarding decision and records it. A repeated device scan id is answered from the first record.
    The boarding names a stop of the trip, by default the first stop of the ticket; a passenger boards only at a stop
    their ticket covers (WRONG_STOP otherwise), and a stop the trip does not have is not recorded (review R-10)."""
    if device_scan_id:
        prior = await conn.fetchrow(
            "SELECT result FROM sales.boarding_event WHERE scanned_by_user_id = $1 AND device_scan_id = $2",
            pr.user_id, device_scan_id)
        if prior:
            return {"result": prior["result"], "replayed": True}
    if ticket_uid is None:
        return {"result": early or "INVALID_QR"}
    k = await conn.fetchrow(
        """SELECT k.id, k.trip_id, k.status, k.seat_no, k.from_seq, k.to_seq, p.full_name, p.first_name, p.last_name,
                  (SELECT s ->> 'label' FROM ops.trip t, jsonb_array_elements(t.seat_map -> 'seats') s
                    WHERE t.id = k.trip_id AND (s ->> 'n')::int = k.seat_no) AS seat_label
             FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id WHERE k.uid = $1""", uuid.UUID(ticket_uid))
    if k is None:
        return {"result": "INVALID_QR"}
    stop = stop_seq if stop_seq is not None else (k["from_seq"] if k["trip_id"] == t["id"] else 0)
    if not await conn.fetchval("SELECT 1 FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2", t["id"], stop):
        return {"result": "UNKNOWN_STOP"}
    result = early or "OK"
    if result == "OK":
        if k["trip_id"] != t["id"]:
            result = "WRONG_TRIP"
        elif k["status"] == "BOARDED":
            result = "DUPLICATE"
        elif k["status"] != "ISSUED":
            result = "INVALID_QR"
        elif not k["from_seq"] <= stop < k["to_seq"]:
            result = "WRONG_STOP"
    await conn.execute(
        """INSERT INTO sales.boarding_event (ticket_id, trip_id, stop_seq, event_type, method, result, scanned_by_user_id,
             device_scan_id, scanned_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)""",
        k["id"], t["id"], stop, "BOARD" if result == "OK" else "DENIED", method, result, pr.user_id,
        device_scan_id, scanned_at)
    if result == "OK":
        await conn.execute("UPDATE sales.ticket SET status = 'BOARDED', boarded_at = coalesce($2, now()) WHERE id = $1",
                           k["id"], scanned_at)
        if t["status"] == "PUBLISHED":
            await conn.execute("UPDATE ops.trip SET status = 'BOARDING' WHERE id = $1", t["id"])
    return {"result": result, "ticket_id": k["id"], "seat_no": k["seat_no"], "seat_label": k["seat_label"] or str(k["seat_no"]),
            "passenger": ticket_name(k["first_name"], k["last_name"], k["full_name"])}


@router.post("/scan")
async def scan(body: ScanIn, request: Request, pr: Principal = Depends(driver)):
    ticket_uid, early = _ticket_from_token(body.token, body.trip_uid)
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, body.trip_uid)
        out = await _board(conn, pr, t, ticket_uid, early, body.stop_seq)
    if "ticket_id" in out:
        request.state.audit = {"action": "boarding.scan", "object_type": "ticket", "object_id": out.pop("ticket_id")}
    return out


@router.get("/trips/{trip_uid}/offline")
async def offline_pack(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(driver)):
    """Everything the driver app needs to board this trip with no connection: the ticket list with seat and status
    (to refuse cancelled tickets and catch duplicates) and the public key that verifies credentials. Names are the
    ticket names only; document numbers never leave the server."""
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, trip_uid)
        # an offline scan of this trip by this driver cannot be older than their first download of the pack (R-09)
        await conn.execute(
            """INSERT INTO ops.offline_pack_download (trip_id, user_id, company_id) VALUES ($1, $2, $3)
               ON CONFLICT (trip_id, user_id) DO UPDATE SET last_at = now(),
                 downloads = ops.offline_pack_download.downloads + 1""", t["id"], pr.user_id, t["company_id"])
        async with db.system_scope(conn, context_for(request, pr)):
            tickets = await conn.fetch(
                """SELECT k.uid, k.status, k.seat_no, k.from_seq, k.to_seq, p.first_name, p.last_name, p.full_name
                     FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                    WHERE k.trip_id = $1 AND k.status IN ('ISSUED','BOARDED','CANCELLED') ORDER BY k.seat_no""", t["id"])
    return {"trip_uid": str(trip_uid), "trip_no": t["trip_no"], "generated_at": datetime.now(timezone.utc).isoformat(),
            "public_key": ticket_public_key(),
            "tickets": [{"uid": str(k["uid"]), "status": k["status"], "seat_no": k["seat_no"], "from_seq": k["from_seq"],
                         "to_seq": k["to_seq"], "name": ticket_name(k["first_name"], k["last_name"], k["full_name"])}
                        for k in tickets]}


class OfflineScan(BaseModel):
    scan_id: str = Field(min_length=8, max_length=64, pattern=r"^[A-Za-z0-9_-]+$")   # generated on the device
    token: str = Field(min_length=10, max_length=600)
    scanned_at: datetime
    stop_seq: Optional[int] = Field(default=None, ge=0)


class BatchIn(BaseModel):
    trip_uid: uuid.UUID
    scans: list[OfflineScan] = Field(min_length=1, max_length=200)


@router.post("/scans/batch")
async def scans_batch(body: BatchIn, request: Request, pr: Principal = Depends(driver)):
    """Uploads scans made offline, in the order they happened. Each is applied once (the device scan id makes a
    retried upload harmless); the server's answer is final, so the app corrects its local state from it."""
    now = datetime.now(timezone.utc)
    results = []
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, body.trip_uid)
        pack_at = await conn.fetchval("SELECT first_at FROM ops.offline_pack_download WHERE trip_id = $1 AND user_id = $2",
                                      t["id"], pr.user_id)
        for sc in sorted(body.scans, key=lambda x: x.scanned_at):
            when = min(sc.scanned_at if sc.scanned_at.tzinfo else sc.scanned_at.replace(tzinfo=timezone.utc), now)
            # The credential is checked at the time of the scan, not of the upload: a driver who syncs the next day still
            # boarded the passenger while the credential was valid. A time more than a day before departure cannot be a
            # boarding of this trip (the app corrects its clock with the pack), nor can a time before this driver first
            # downloaded the trip's pack (R-09): the upload time is used instead.
            if when < t["departure_at"] - timedelta(hours=SCAN_LEAD_HOURS) or (pack_at and when < pack_at):
                when = now
            ticket_uid, early = _ticket_from_token(sc.token, body.trip_uid, when)
            out = await _board(conn, pr, t, ticket_uid, early, sc.stop_seq, "OFFLINE_SCAN", sc.scan_id, when)
            out.pop("ticket_id", None)
            results.append({"scan_id": sc.scan_id, **out})
    request.state.audit = {"action": "boarding.offline_batch", "object_type": "trip", "object_id": t["id"]}
    return {"results": results}


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
    # evidence fields (audit T3-11): the device's own id and counter for the position, when it was taken, and how
    event_id: Optional[uuid.UUID] = None
    seq: Optional[int] = Field(default=None, ge=0)
    device_ts: Optional[datetime] = None
    provider: Optional[Literal["GPS", "NETWORK", "FUSED", "DEVICE"]] = None
    is_mock: bool = False


def _filed_at(device_ts: Optional[datetime], now: datetime) -> tuple[datetime, Optional[datetime]]:
    """The time a position is filed under: when the device took it, unless that time is implausible (the trust grade
    says so then), and the device time as given."""
    taken = device_ts.astimezone(timezone.utc) if device_ts and device_ts.tzinfo else None
    return (taken if taken and now - timedelta(days=6) < taken <= now + timedelta(minutes=2) else now), taken


def _point(ts: datetime, taken: Optional[datetime], p) -> dict:
    return {"ts": ts, "lat": p.lat, "lng": p.lng, "speed_kmh": p.speed_kmh, "accuracy_m": p.accuracy_m, "event_id": p.event_id,
            "seq": p.seq, "device_ts": taken, "provider": p.provider, "is_mock": p.is_mock}


async def _to_telemetry(request: Request, pr: Principal, trip_uid: uuid.UUID, points: list[dict]) -> tuple[list, list]:
    """Positions with a telemetry database (review stage D2): graded on the primary for the driver's own trip, then
    appended to the telemetry database. Returns the grades and the trust of each position stored (not duplicates).
    When the telemetry database does not answer, the positions wait on the primary for the worker (R-03)."""
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, trip_uid)
        graded = await telemetry.accept(conn, t["id"], points)
    try:
        return graded, await telemetry.store(t["id"], graded, points)
    except ApiError as exc:
        if exc.code != "TELEMETRY_UNAVAILABLE":
            raise
    async with db.transaction(context_for(request, pr)) as conn:
        await telemetry.queue(conn, t["id"], t["company_id"], graded, points)
    return graded, [g["trust"] for g in graded]


@router.post("/location")
async def location(body: LocationIn, request: Request, pr: Principal = Depends(driver)):
    now = datetime.now(timezone.utc)
    ts, taken = _filed_at(body.device_ts, now)
    if telemetry.enabled():
        graded, stored = await _to_telemetry(request, pr, body.trip_uid, [_point(ts, taken, body)])
        if not stored:
            return {"ok": True, "duplicate": True}
        return {"ok": True, "trust": graded[0]["trust"], "flags": list(graded[0]["trust_flags"])}
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, body.trip_uid)
        # the installation the driver signed in from (mobile sessions are bound to a registered device) (T3-11)
        device = await conn.fetchval("SELECT device_id FROM iam.user_session WHERE id = $1", pr.session_id)
        row = await conn.fetchrow(
            """INSERT INTO ops.geo_event (ts, trip_id, vehicle_id, driver_user_id, lat, lng, speed_kmh, accuracy_m,
                                          event_id, seq, device_ts, provider, is_mock, device_id)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
               ON CONFLICT (event_id, ts) DO NOTHING RETURNING trust, trust_flags""",
            ts, t["id"], t["vehicle_id"], pr.user_id, body.lat, body.lng, body.speed_kmh, body.accuracy_m,
            body.event_id, body.seq, taken, body.provider, body.is_mock, device)
        if row is None:
            return {"ok": True, "duplicate": True}
        await conn.execute(
            "UPDATE ops.tracking_alert SET status = 'RESOLVED', resolved_at = now() WHERE trip_id = $1 AND status = 'OPEN' "
            "AND kind IN ('SIGNAL_LOST','TRACKING_OFF')", t["id"])
    return {"ok": True, "trust": row["trust"], "flags": list(row["trust_flags"])}


class PositionIn(BaseModel):
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)
    speed_kmh: Optional[float] = Field(default=None, ge=0, le=300)
    accuracy_m: Optional[float] = Field(default=None, ge=0)
    event_id: Optional[uuid.UUID] = None
    seq: Optional[int] = Field(default=None, ge=0)
    device_ts: Optional[datetime] = None
    provider: Optional[Literal["GPS", "NETWORK", "FUSED", "DEVICE"]] = None
    is_mock: bool = False


class LocationsIn(BaseModel):
    trip_uid: uuid.UUID
    points: list[PositionIn] = Field(min_length=1, max_length=120)


@router.post("/locations")
async def locations(body: LocationsIn, request: Request, pr: Principal = Depends(driver)):
    """Several positions in one request and one transaction (capacity model: at 20,000 vehicles reporting every 10 s,
    an app that sends its buffered positions every 30 s turns 2,000 requests a second into about 700). Same evidence
    rules as /location: each position keeps its own id, counter, device time and trust grade."""
    now = datetime.now(timezone.utc)
    filed = [_filed_at(p.device_ts, now) for p in body.points]
    if telemetry.enabled():
        _, stored = await _to_telemetry(request, pr, body.trip_uid, [_point(f[0], f[1], p) for f, p in zip(filed, body.points)])
        grades: dict[str, int] = {}
        for g in stored:
            grades[g] = grades.get(g, 0) + 1
        return {"ok": True, "accepted": len(stored), "duplicates": len(body.points) - len(stored), "trust": grades}
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _assigned_trip(conn, pr, body.trip_uid)
        device = await conn.fetchval("SELECT device_id FROM iam.user_session WHERE id = $1", pr.session_id)
        rows = await conn.fetch(
            """INSERT INTO ops.geo_event (ts, trip_id, vehicle_id, driver_user_id, lat, lng, speed_kmh, accuracy_m,
                                          event_id, seq, device_ts, provider, is_mock, device_id)
               SELECT p.ts, $1, $2, $3, p.lat, p.lng, p.speed, p.accuracy, p.event_id, p.seq, p.device_ts, p.provider, p.is_mock, $4
                 FROM unnest($5::timestamptz[], $6::numeric[], $7::numeric[], $8::real[], $9::real[], $10::uuid[], $11::bigint[],
                             $12::timestamptz[], $13::text[], $14::boolean[])
                      AS p(ts, lat, lng, speed, accuracy, event_id, seq, device_ts, provider, is_mock)
               ON CONFLICT (event_id, ts) DO NOTHING RETURNING trust""",
            t["id"], t["vehicle_id"], pr.user_id, device,
            [f[0] for f in filed], [p.lat for p in body.points], [p.lng for p in body.points],
            [p.speed_kmh for p in body.points], [p.accuracy_m for p in body.points], [p.event_id for p in body.points],
            [p.seq for p in body.points], [f[1] for f in filed], [p.provider for p in body.points],
            [p.is_mock for p in body.points])
        if rows:
            await conn.execute(
                "UPDATE ops.tracking_alert SET status = 'RESOLVED', resolved_at = now() WHERE trip_id = $1 AND status = 'OPEN' "
                "AND kind IN ('SIGNAL_LOST','TRACKING_OFF')", t["id"])
    grades: dict[str, int] = {}
    for r in rows:
        grades[r["trust"]] = grades.get(r["trust"], 0) + 1
    return {"ok": True, "accepted": len(rows), "duplicates": len(body.points) - len(rows), "trust": grades}



# ------------------------------------------------------------------ device attestation (audit T3-11)
class AttestationIn(BaseModel):
    provider: Literal["PLAY_INTEGRITY", "APP_ATTEST", "SIMULATED"]
    token: str = Field(min_length=8, max_length=8000)


@router.post("/device/attestation")
async def device_attestation(body: AttestationIn, request: Request, pr: Principal = Depends(driver)):
    """The driver app proves it runs unmodified on a genuine device. The verdict is kept on the device; positions from a
    device that failed are rejected, and with tracking.device_attestation REQUIRED only attested devices count."""
    from ..attestation import verify
    passed = await verify(body.provider, body.token)
    async with db.transaction(context_for(request, pr)) as conn:
        device = await conn.fetchval("SELECT device_id FROM iam.user_session WHERE id = $1", pr.session_id)
        if device is None:
            raise ApiError(409, "DEVICE_REQUIRED", "attestation needs the mobile app's registered device")
        await conn.execute(
            """UPDATE iam.device SET attestation_state = $2, attested_at = now(), attestation_provider = $3
                WHERE id = $1 AND user_id = $4 AND revoked_at IS NULL""",
            device, "PASSED" if passed else "FAILED", body.provider, pr.user_id)
    request.state.audit = {"action": "device.attestation", "object_type": "device", "object_id": device}
    return {"attestation": "PASSED" if passed else "FAILED"}
