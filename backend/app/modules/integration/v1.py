"""Public integration API v1. Authenticate with an API key (X-Api-Key); see /api/v1/openapi.json.

    GET    /api/v1/me                                   the client, its scopes and limits
    GET    /api/v1/events                               events this client may subscribe to
    trips:read      GET  /api/v1/trips/search, /api/v1/trips/{uid}
    manifests:read  GET  /api/v1/trips (the company's trips), /api/v1/trips/{uid}/manifest
    bookings:read   GET  /api/v1/bookings, /api/v1/bookings/{ref}
    bookings:write  POST /api/v1/holds, DELETE /api/v1/holds/{token}, POST /api/v1/bookings, POST /api/v1/bookings/{ref}/cancel
    shipments:read  GET  /api/v1/shipments/{tracking_no}
    reports:read    GET  /api/v1/reports, /api/v1/reports/{code}?format=json|csv|txt|xlsx|pdf
    wallet:credit   POST /api/v1/wallet/lookup, POST /api/v1/wallet/credits, GET /api/v1/wallet/credits[/{reference}]
    border:read     GET  /api/v1/border/manifests, /api/v1/border/manifests/{uid}
    border:respond  POST /api/v1/border/manifests/{uid}/decisions
    webhooks:manage GET/POST /api/v1/webhooks, DELETE /api/v1/webhooks/{uid}, POST /api/v1/webhooks/{uid}/rotate|ping,
                    GET /api/v1/webhooks/deliveries, POST /api/v1/webhooks/deliveries/{uid}/retry

Every call is counted per client and day; calls that read personal data are written to the activity log with the client.
Errors use the platform's format: {"error": {"code", "message", ...}} with stable codes.
"""
from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from fastapi.openapi.utils import get_openapi
from pydantic import BaseModel, Field

from ... import db, markets, policy
from ...crypto import cipher
from ...errors import ApiError, not_found
from ...routers import public
from ..agency import service as agency
from ..payments import service as payments
from ..reports import api as reports
from ..sales import service as sales
from ..sales.models import AgencyBookingIn, HoldIn
from . import service
from .auth import Caller, api_caller, context
from .scopes import EVENTS, SCOPES

async def _period(conn, party_id, date_from: date, date_to: date) -> tuple[datetime, datetime]:
    """A period of whole days in the caller's market (1061): from midnight of the first day to midnight after the last."""
    zone = (await markets.of_party(conn, party_id)).zone
    return datetime.combine(date_from, time.min, zone), datetime.combine(date_to + timedelta(days=1), time.min, zone)


router = APIRouter(prefix="/api/v1", tags=["integration v1"])
MOBILE = r"^\+?[0-9]{8,15}$"


def _iso(v):
    return v.isoformat() if v else None


@router.get("/me")
async def me(caller: Caller = Depends(api_caller)):
    return {"client": caller.client_uid, "name": caller.name, "kind": caller.kind, "environment": caller.environment,
            "scopes": sorted(caller.scopes), "rate_limit_per_min": caller.rate_limit,
            "acting_account": caller.principal.email if caller.principal else None, "api_version": "v1"}


@router.get("/events")
async def events(caller: Caller = Depends(api_caller)):
    return {"events": sorted(e for e, kinds in EVENTS.items() if caller.kind in kinds)}


# ------------------------------------------------------------------ trips (public timetable data)
@router.get("/trips/search")
async def trip_search(request: Request, origin: str = Query(..., min_length=3, max_length=3),
                      destination: str = Query(..., min_length=3, max_length=3), on: date = Query(...),
                      passengers: int = Query(1, ge=1, le=4), caller: Caller = Depends(api_caller)):
    """Published trips between two cities on a day, with fares and free seats (city codes as in /api/ref)."""
    caller.need("trips:read")
    return await public.search(request, origin=origin.upper(), destination=destination.upper(), on=on, passengers=passengers)


@router.get("/trips")
async def company_trips(request: Request, date_from: date = Query(..., alias="from"), date_to: Optional[date] = Query(None, alias="to"),
                        status: Optional[str] = Query(None, pattern=r"^[A-Z_]{3,20}$"), caller: Caller = Depends(api_caller)):
    """The company's own trips departing in a period (at most 62 days), with seats sold."""
    pr = caller.acting("manifests:read")
    date_to = date_to or date_from
    if date_to < date_from or (date_to - date_from).days > 62:
        raise ApiError(422, "BAD_PERIOD", "give a period of at most 62 days")
    async with db.transaction(context(request, caller)) as conn:
        start, end = await _period(conn, pr.company_id, date_from, date_to)
        rows = await conn.fetch(
            """SELECT t.uid, t.trip_no, t.status, t.departure_at, t.arrival_at, t.seats_total, t.currency,
                      (SELECT count(*) FROM sales.ticket k WHERE k.trip_id = t.id AND k.status NOT IN ('CANCELLED')) AS tickets,
                      v.plate_no, (SELECT string_agg(s.code, '-' ORDER BY ts.seq) FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                                    WHERE ts.trip_id = t.id) AS stops
                 FROM ops.trip t LEFT JOIN fleet.vehicle v ON v.id = t.vehicle_id
                WHERE t.company_id = $1 AND t.departure_at >= $2 AND t.departure_at < $3 AND ($4::text IS NULL OR t.status = $4)
                ORDER BY t.departure_at LIMIT 2000""", pr.company_id, start, end, status)
    return {"trips": [{**dict(r), "uid": str(r["uid"]), "departure_at": _iso(r["departure_at"]), "arrival_at": _iso(r["arrival_at"])}
                      for r in rows]}


@router.get("/trips/{trip_uid}")
async def trip_detail(trip_uid: uuid.UUID, request: Request, from_seq: int = Query(..., ge=0), to_seq: int = Query(..., ge=1),
                      caller: Caller = Depends(api_caller)):
    """Fares, fare brands and the seat map of a published trip between two stops."""
    caller.need("trips:read")
    return await public.trip_detail(str(trip_uid), request, from_seq=from_seq, to_seq=to_seq)


@router.get("/trips/{trip_uid}/manifest")
async def manifest(trip_uid: uuid.UUID, request: Request, caller: Caller = Depends(api_caller)):
    """Passengers of one of the company's trips: seat, names, nationality, document type and last digits, journey, boarding."""
    pr = caller.acting("manifests:read")
    async with db.transaction(context(request, caller)) as conn:
        t = await conn.fetchrow("SELECT id, trip_no, status, departure_at FROM ops.trip WHERE uid = $1 AND company_id = $2", trip_uid, pr.company_id)
        if t is None:
            raise not_found("trip")
        recs = await conn.fetch(
            """SELECT k.ticket_no, k.seat_no, k.status, p.full_name, p.nationality, p.id_type, p.id_no_last4, b.booking_ref,
                      sa.code AS from_station, sb.code AS to_station, k.boarded_at
                 FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id JOIN sales.booking b ON b.id = k.booking_id
                 JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq JOIN net.station sa ON sa.id = a.station_id
                 JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq JOIN net.station sb ON sb.id = z.station_id
                WHERE k.trip_id = $1 AND k.status <> 'CANCELLED' ORDER BY k.seat_no""", t["id"])
    request.state.audit = {"action": "manifest.view", "object_type": "trip", "object_id": t["id"]}
    return {"trip_no": t["trip_no"], "status": t["status"], "departure_at": _iso(t["departure_at"]),
            "passengers": [{**dict(r), "boarded_at": _iso(r["boarded_at"])} for r in recs]}


# ------------------------------------------------------------------ bookings
def _booking_row(r) -> dict:
    return {"booking_ref": r["booking_ref"], "status": r["status"], "trip_no": r["trip_no"], "departure_at": _iso(r["departure_at"]),
            "from_station": r["from_station"], "to_station": r["to_station"], "passengers": r["passengers"],
            "total_amount": r["total_amount"], "currency": r["currency"], "channel": "AGENCY" if r["agency_id"] else "DIRECT",
            "created_at": _iso(r["created_at"]), "cancelled_at": _iso(r["cancelled_at"])}


_BOOKINGS = """SELECT b.id, b.booking_ref, b.status, b.total_amount, b.currency, b.agency_id, b.created_at, b.cancelled_at, t.trip_no, t.departure_at,
                      (SELECT count(*) FROM sales.ticket k WHERE k.booking_id = b.id) AS passengers,
                      (SELECT s.code FROM sales.ticket k JOIN ops.trip_stop ts ON ts.trip_id = k.trip_id AND ts.seq = k.from_seq
                         JOIN net.station s ON s.id = ts.station_id WHERE k.booking_id = b.id LIMIT 1) AS from_station,
                      (SELECT s.code FROM sales.ticket k JOIN ops.trip_stop ts ON ts.trip_id = k.trip_id AND ts.seq = k.to_seq
                         JOIN net.station s ON s.id = ts.station_id WHERE k.booking_id = b.id LIMIT 1) AS to_station
                 FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id
                WHERE (b.company_id = $1 OR b.agency_id = $1)"""


@router.get("/bookings")
async def bookings(request: Request, date_from: date = Query(..., alias="from"), date_to: Optional[date] = Query(None, alias="to"),
                   status: Optional[str] = Query(None, pattern=r"^[A-Z_]{3,20}$"), after: Optional[int] = Query(None, ge=0),
                   caller: Caller = Depends(api_caller)):
    """Bookings made in a period (at most 62 days): a carrier's sales on its trips, or an agency's own sales. Pages of 500 (after=next)."""
    pr = caller.acting("bookings:read")
    date_to = date_to or date_from
    if date_to < date_from or (date_to - date_from).days > 62:
        raise ApiError(422, "BAD_PERIOD", "give a period of at most 62 days")
    async with db.transaction(context(request, caller)) as conn:
        start, end = await _period(conn, pr.company_id, date_from, date_to)
        rows = await conn.fetch(_BOOKINGS + """ AND b.created_at >= $2 AND b.created_at < $3 AND ($4::text IS NULL OR b.status = $4)
                                                AND ($5::bigint IS NULL OR b.id > $5) AND b.status <> 'HELD' ORDER BY b.id LIMIT 500""",
                                pr.company_id, start, end, status, after)
    return {"bookings": [_booking_row(r) for r in rows], "next": rows[-1]["id"] if len(rows) == 500 else None}


@router.get("/bookings/{ref}")
async def booking(ref: str, request: Request, caller: Caller = Depends(api_caller)):
    """One booking with its tickets."""
    pr = caller.acting("bookings:read")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        b = await conn.fetchrow(_BOOKINGS + " AND b.booking_ref = $2", pr.company_id, ref.upper())
        if b is None:
            raise not_found("booking")
        tickets = await conn.fetch(
            """SELECT k.ticket_no, k.uid, k.seat_no, k.status, k.fare_amount, k.total_amount, p.full_name, p.nationality, k.boarded_at
                 FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id WHERE k.booking_id = $1 ORDER BY k.seat_no""", b["id"])
    request.state.audit = {"action": "booking.view", "object_type": "booking", "object_id": b["id"]}
    return {"booking": _booking_row(b),
            "tickets": [{**dict(t), "uid": str(t["uid"]), "boarded_at": _iso(t["boarded_at"])} for t in tickets]}


@router.post("/holds", status_code=201)
async def hold(body: HoldIn, request: Request, caller: Caller = Depends(api_caller)):
    """Holds seats for a few minutes while the sale is completed (sales channels)."""
    pr = caller.acting("bookings:write")
    async with db.transaction(context(request, caller)) as conn:
        await agency.ensure_can_sell(conn, pr)
        out = await sales.create_hold(conn, pr.user_id, body)
    out.pop("trip_id", None)
    return out


@router.delete("/holds/{hold_token}")
async def release(hold_token: uuid.UUID, request: Request, caller: Caller = Depends(api_caller)):
    pr = caller.acting("bookings:write")
    async with db.transaction(context(request, caller)) as conn:
        n = await sales.release_hold(conn, pr.user_id, hold_token)
    return {"ok": True, "released_seats": n}


@router.post("/bookings", status_code=201)
async def sell(body: AgencyBookingIn, request: Request, caller: Caller = Depends(api_caller)):
    """Sells the held seats from the agency balance (idempotent on idempotency_key)."""
    pr = caller.acting("bookings:write")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        out = await agency.sell(conn, ctx, pr, body)
    if not out.get("replayed"):
        request.state.audit = {"action": "agency.sell", "object_type": "booking", "object_id": out.pop("booking_id")}
    return out


@router.post("/bookings/{ref}/cancel")
async def cancel(ref: str, request: Request, caller: Caller = Depends(api_caller)):
    """Cancels an agency booking under the fare rules; the refund goes back to the agency balance."""
    pr = caller.acting("bookings:write")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        bid, out = await agency.cancel(conn, ctx, pr, ref.upper())
    request.state.audit = {"action": "booking.cancel", "object_type": "booking", "object_id": bid}
    return out


# ------------------------------------------------------------------ shipments
@router.get("/shipments/{tracking_no}")
async def shipment(tracking_no: str, request: Request, caller: Caller = Depends(api_caller)):
    """Status and tracking events of a parcel or shipment (no personal data)."""
    caller.need("shipments:read")
    from ...modular.workflows import track
    return await track(tracking_no, request)


# ------------------------------------------------------------------ reports
@router.get("/reports")
async def report_catalog(request: Request, locale: Optional[Literal["ar", "en"]] = None, caller: Caller = Depends(api_caller)):
    """Reports this client can run, with their columns."""
    pr = caller.acting("reports:read")
    out = await reports.catalog(request, locale=locale, pr=pr)
    return {"reports": out["reports"], "categories": out["categories"]}


@router.get("/reports/{code}")
async def report(code: str, request: Request, format: Literal["json", "csv", "txt", "xlsx", "pdf"] = "json",
                 date_from: Optional[date] = Query(None, alias="from"), date_to: Optional[date] = Query(None, alias="to"),
                 locale: Optional[Literal["ar", "en"]] = None, caller: Caller = Depends(api_caller)):
    """Runs a catalog report for a period and returns the file (the same rules and limits as the portals)."""
    pr = caller.acting("reports:read")
    body = reports.ExportIn(code=code, format=format.upper(), locale=locale,
                            params=reports.Params(period_from=date_from, period_to=date_to))
    return await reports.export_file(body, request, pr)


# ------------------------------------------------------------------ wallet credits (banks and e-wallets)
class LookupIn(BaseModel):
    mobile: str = Field(pattern=MOBILE)


class CreditIn(BaseModel):
    mobile: str = Field(pattern=MOBILE)
    amount: int = Field(gt=0, le=1_000_000_000, description="minor units of the currency (100 to the unit)")
    reference: str = Field(min_length=6, max_length=60, pattern=r"^[A-Za-z0-9_.:-]+$", description="your unique transaction id")


def _partner(caller: Caller) -> int:
    caller.need("wallet:credit")
    if not caller.provider_id:
        raise ApiError(403, "PARTNER_NOT_CONFIGURED", "this client is not linked to a payment provider")
    return caller.provider_id


@router.post("/wallet/lookup")
async def wallet_lookup(body: LookupIn, request: Request, caller: Caller = Depends(api_caller)):
    """Before taking the money: is there a Masslak account with this mobile? Returns the first name only."""
    _partner(caller)
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            person = await payments.passenger_by_mobile(conn, body.mobile, required=False)
    return {"exists": person is not None, "first_name": (person["legal_name"] or "").split(" ")[0] if person else None}


@router.post("/wallet/credits", status_code=201)
async def wallet_credit(body: CreditIn, request: Request, caller: Caller = Depends(api_caller)):
    """Credits the passenger's wallet at once. Idempotent on reference."""
    provider_id = _partner(caller)
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        out = await payments.partner_credit(conn, ctx, caller.client_id, provider_id, body.mobile, body.amount, body.reference)
    request.state.audit = {"action": "wallet.partner_credit", "object_type": "payment", "reason": body.reference}
    return out


def _credit(r) -> dict:
    return {"payment": str(r["uid"]), "reference": r["provider_ref"], "status": r["status"], "amount": r["amount"], "currency": r["currency"],
            "mobile": r["payer_mobile_mask"], "created_at": _iso(r["created_at"]), "refunded_amount": r["refunded_amount"]}


@router.get("/wallet/credits")
async def wallet_credits(request: Request, date_from: date = Query(..., alias="from"), date_to: Optional[date] = Query(None, alias="to"),
                         caller: Caller = Depends(api_caller)):
    """Your credits in a period (at most 62 days), for daily reconciliation."""
    _partner(caller)
    date_to = date_to or date_from
    if date_to < date_from or (date_to - date_from).days > 62:
        raise ApiError(422, "BAD_PERIOD", "give a period of at most 62 days")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        start, end = await _period(conn, None, date_from, date_to)        # credits go to passengers of the default market
        async with db.system_scope(conn, ctx):
            rows = await conn.fetch(
                """SELECT * FROM fin.payment WHERE api_client_id = $1 AND created_at >= $2 AND created_at < $3 ORDER BY id LIMIT 10000""",
                caller.client_id, start, end)
    return {"credits": [_credit(r) for r in rows], "total": sum(r["amount"] for r in rows if r["status"] == "SUCCESS")}


@router.get("/wallet/credits/{reference}")
async def wallet_credit_status(reference: str, request: Request, caller: Caller = Depends(api_caller)):
    _partner(caller)
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            r = await conn.fetchrow("SELECT * FROM fin.payment WHERE api_client_id = $1 AND provider_ref = $2", caller.client_id, reference)
    if r is None:
        raise not_found("credit")
    return _credit(r)


# ------------------------------------------------------------------ border manifests (authorities)
def _authority(caller: Caller, scope: str) -> int:
    caller.need(scope)
    if not caller.authority_id:
        raise ApiError(403, "AUTHORITY_NOT_LINKED", "this client is not linked to an authority")
    return caller.authority_id


_MANIFESTS = """SELECT m.id, m.uid, m.version, m.manifest_type, m.content_type, m.status, m.closed_at, m.created_at, t.trip_no, t.departure_at,
                       s.code AS border_point, s.name AS border_point_name,
                       (SELECT count(*) FROM brd.manifest_person mp WHERE mp.manifest_id = m.id) AS persons
                  FROM brd.manifest m JOIN ops.trip t ON t.id = m.trip_id JOIN brd.border_point bp ON bp.station_id = m.border_point_id
                  JOIN net.station s ON s.id = bp.station_id LEFT JOIN brd.crossing_profile cp ON cp.id = m.profile_id
                 WHERE (bp.authority_id = $1 OR cp.authority_id = $1) AND m.status IN ('SUBMITTED', 'ACKNOWLEDGED', 'REJECTED')"""


def _manifest_row(r) -> dict:
    return {"uid": str(r["uid"]), "version": r["version"], "type": r["manifest_type"], "content": r["content_type"], "status": r["status"],
            "trip_no": r["trip_no"], "departure_at": _iso(r["departure_at"]), "border_point": r["border_point"],
            "border_point_name": r["border_point_name"], "persons": r["persons"], "closed_at": _iso(r["closed_at"])}


@router.get("/border/manifests")
async def border_manifests(request: Request, status: Optional[Literal["SUBMITTED", "ACKNOWLEDGED", "REJECTED"]] = None,
                           since: Optional[datetime] = None, caller: Caller = Depends(api_caller)):
    """Manifests submitted for this authority's border points (newest first, at most 500)."""
    authority = _authority(caller, "border:read")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            rows = await conn.fetch(_MANIFESTS + " AND ($2::text IS NULL OR m.status = $2) AND ($3::timestamptz IS NULL OR m.created_at >= $3) "
                                    "ORDER BY m.id DESC LIMIT 500", authority, status, since)
    return {"manifests": [_manifest_row(r) for r in rows]}


async def _manifest(conn, authority: int, uid: uuid.UUID):
    m = await conn.fetchrow(_MANIFESTS + " AND m.uid = $2", authority, uid)
    if m is None:
        raise not_found("manifest")
    return m


@router.get("/border/manifests/{uid}")
async def border_manifest(uid: uuid.UUID, request: Request, caller: Caller = Depends(api_caller)):
    """A manifest with its people (full document numbers), vehicles and cargo."""
    authority = _authority(caller, "border:read")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            m = await _manifest(conn, authority, uid)
            people = await conn.fetch(
                """SELECT mp.id, mp.person_role, mp.doc_type, mp.doc_no_enc, mp.enc_key_id, mp.issuing_country, mp.doc_expiry, mp.nationality,
                          mp.birth_date, mp.sex, mp.passenger_category, coalesce(sp.full_name, cp.legal_name) AS full_name,
                          se.code AS embark, sd.code AS disembark, k.seat_no
                     FROM brd.manifest_person mp LEFT JOIN sales.ticket k ON k.id = mp.ticket_id LEFT JOIN sales.passenger sp ON sp.id = k.passenger_id
                     LEFT JOIN iam.party cp ON cp.id = mp.crew_party_id LEFT JOIN net.station se ON se.id = mp.embark_station_id
                     LEFT JOIN net.station sd ON sd.id = mp.disembark_station_id WHERE mp.manifest_id = $1 ORDER BY mp.person_role, mp.id""", m["id"])
            vehicles = await conn.fetch("SELECT plate_no, plate_country, chassis_no FROM brd.manifest_vehicle WHERE manifest_id = $1", m["id"])
            cargo = await conn.fetch(
                """SELECT id, cargo_category, cargo_description, hs_code, declared_weight_kg, packages, container_no, seal_no, un_number, adr_class
                     FROM brd.manifest_cargo WHERE manifest_id = $1 ORDER BY id""", m["id"])
            c = await cipher(conn)
    # the decision to show document numbers is recorded with its purpose (review 3.11)
    await policy.authorize(ctx, "brd.manifest_person.doc_no", "READ", "AUTHORITY_MANIFEST", f"border manifest {uid} for its authority")
    out_people = []
    for p in people:
        try:
            doc_no = c.decrypt(p["doc_no_enc"], p["enc_key_id"], "brd.manifest_person.doc_no")
        except Exception:
            doc_no = None   # a key this process does not hold: the platform resends the manifest
        out_people.append({"id": p["id"], "role": p["person_role"], "full_name": p["full_name"], "doc_type": p["doc_type"], "doc_no": doc_no,
                           "issuing_country": p["issuing_country"], "doc_expiry": _iso(p["doc_expiry"]), "nationality": p["nationality"],
                           "birth_date": _iso(p["birth_date"]), "sex": p["sex"], "category": p["passenger_category"], "seat_no": p["seat_no"],
                           "embark": p["embark"], "disembark": p["disembark"]})
    request.state.audit = {"action": "border.manifest_read", "object_type": "brd.manifest", "object_id": m["id"]}
    return {**_manifest_row(m), "people": out_people, "vehicles": [dict(v) for v in vehicles],
            "cargo": [{**dict(x), "declared_weight_kg": float(x["declared_weight_kg"])} for x in cargo]}


class Decision(BaseModel):
    subject: Literal["MANIFEST", "PERSON", "VEHICLE", "CARGO"]
    subject_id: Optional[int] = None
    decision: Literal["OK", "HOLD", "DENY"]
    reason_code: Optional[str] = Field(default=None, pattern=r"^[A-Z0-9_]{2,40}$")
    silent: bool = False


class DecisionsIn(BaseModel):
    decisions: list[Decision] = Field(min_length=1, max_length=500)


@router.post("/border/manifests/{uid}/decisions")
async def border_decide(uid: uuid.UUID, body: DecisionsIn, request: Request, caller: Caller = Depends(api_caller)):
    """Decisions on the manifest or on single people, vehicles or cargo. A manifest-level OK acknowledges it, DENY rejects it.
    Silent decisions are seen by the platform only, never by the carrier."""
    authority = _authority(caller, "border:respond")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            m = await _manifest(conn, authority, uid)
            if m["status"] != "SUBMITTED":
                raise ApiError(409, "MANIFEST_NOT_OPEN", "decisions are accepted on submitted manifests only", manifest_status=m["status"])
            tables = {"PERSON": "brd.manifest_person", "CARGO": "brd.manifest_cargo"}
            for d in body.decisions:
                if d.subject == "MANIFEST":
                    if d.subject_id is not None:
                        raise ApiError(422, "SUBJECT_ID_NOT_EXPECTED", "a manifest decision has no subject_id")
                elif d.subject in tables:
                    ok = d.subject_id is not None and await conn.fetchval(
                        f"SELECT 1 FROM {tables[d.subject]} WHERE id = $1 AND manifest_id = $2", d.subject_id, m["id"])  # nosec B608
                    if not ok:
                        raise ApiError(422, "SUBJECT_NOT_IN_MANIFEST", "this subject is not part of the manifest", subject_id=d.subject_id)
                elif d.subject_id is None or not await conn.fetchval(
                        "SELECT 1 FROM brd.manifest_vehicle WHERE manifest_id = $1 AND vehicle_id = $2", m["id"], d.subject_id):
                    raise ApiError(422, "SUBJECT_NOT_IN_MANIFEST", "this vehicle is not part of the manifest", subject_id=d.subject_id)
            await conn.executemany(
                """INSERT INTO brd.manifest_response (manifest_id, subject_type, subject_id, decision, reason_code, silent_flag)
                   VALUES ($1, $2, $3, $4, $5, $6)""",
                [(m["id"], d.subject, d.subject_id, d.decision, d.reason_code, d.silent) for d in body.decisions])
            final = next((d.decision for d in body.decisions if d.subject == "MANIFEST" and d.decision != "HOLD"), None)
            status = {"OK": "ACKNOWLEDGED", "DENY": "REJECTED"}.get(final or "", m["status"])
            if status != m["status"]:
                await conn.execute("UPDATE brd.manifest SET status = $2 WHERE id = $1", m["id"], status)
    request.state.audit = {"action": "border.manifest_decision", "object_type": "brd.manifest", "object_id": m["id"],
                           "reason": f"{len(body.decisions)} decisions"}
    return {"manifest": str(uid), "status": status, "recorded": len(body.decisions)}


# ------------------------------------------------------------------ routed manifests (authorities, domestic and international)
_DELIVERIES = """SELECT d.id, d.uid, d.status, d.channel, d.created_at, d.acknowledged_at, d.ack_ref, r.include_documents,
                        m.id AS manifest_id, m.uid AS manifest_uid, m.scope, m.manifest_type, m.version, m.status AS manifest_status,
                        m.issued_at, m.persons_count, encode(m.payload_sha256, 'hex') AS sha256, t.trip_no, t.departure_at,
                        cp.legal_name AS carrier, s.code AS border_point
                   FROM brd.manifest_delivery d JOIN brd.manifest_route r ON r.id = d.route_id JOIN brd.manifest m ON m.id = d.manifest_id
                   JOIN ops.trip t ON t.id = m.trip_id JOIN iam.party cp ON cp.id = t.company_id
                   LEFT JOIN net.station s ON s.id = m.border_point_id
                  WHERE d.authority_id = $1 AND d.channel IN ('API_PULL','API_PUSH') AND d.status <> 'PENDING'"""


def _delivery_row(r) -> dict:
    return {"uid": str(r["uid"]), "status": r["status"], "manifest_uid": str(r["manifest_uid"]), "scope": r["scope"],
            "type": r["manifest_type"], "version": r["version"], "manifest_status": r["manifest_status"], "trip_no": r["trip_no"],
            "departure_at": _iso(r["departure_at"]), "carrier": r["carrier"], "border_point": r["border_point"],
            "persons": r["persons_count"], "sha256": r["sha256"], "issued_at": _iso(r["issued_at"]), "ack_ref": r["ack_ref"]}


@router.get("/manifests/deliveries")
async def manifest_deliveries(request: Request, status: Optional[Literal["AVAILABLE", "SENT", "ACKNOWLEDGED", "REJECTED"]] = None,
                              caller: Caller = Depends(api_caller)):
    """Manifests the platform routed to this authority (study 11.10), newest first, at most 500."""
    authority = _authority(caller, "manifests:receive")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            rows = await conn.fetch(_DELIVERIES + " AND ($2::text IS NULL OR d.status = $2) ORDER BY d.id DESC LIMIT 500", authority, status)
    return {"deliveries": [_delivery_row(r) for r in rows]}


async def _delivery(conn, authority: int, uid: uuid.UUID):
    d = await conn.fetchrow(_DELIVERIES + " AND d.uid = $2", authority, uid)
    if d is None:
        raise not_found("delivery")
    return d


@router.get("/manifests/deliveries/{uid}")
async def manifest_delivery(uid: uuid.UUID, request: Request, caller: Caller = Depends(api_caller)):
    """The manifest of one delivery. Full document numbers only where the route was approved for them; otherwise the
    last four characters."""
    authority = _authority(caller, "manifests:receive")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            d = await _delivery(conn, authority, uid)
            people = await conn.fetch(
                """SELECT mp.id, mp.person_role, mp.full_name, mp.age_category, mp.doc_type, mp.doc_no_enc, mp.enc_key_id, mp.doc_last4,
                          mp.issuing_country, mp.doc_expiry, mp.nationality, mp.birth_date, mp.sex, mp.seat_label,
                          se.code AS embark, sd.code AS disembark
                     FROM brd.manifest_person mp LEFT JOIN net.station se ON se.id = mp.embark_station_id
                     LEFT JOIN net.station sd ON sd.id = mp.disembark_station_id WHERE mp.manifest_id = $1 ORDER BY mp.person_role, mp.id""",
                d["manifest_id"])
            vehicles = await conn.fetch("SELECT plate_no, plate_country, chassis_no FROM brd.manifest_vehicle WHERE manifest_id = $1",
                                        d["manifest_id"])
            c = await cipher(conn)
    if d["include_documents"]:
        await policy.authorize(ctx, "brd.manifest_person.doc_no", "READ", "AUTHORITY_MANIFEST", f"manifest delivery {uid} on an approved route")
    out = []
    for p in people:
        doc_no = None
        if d["include_documents"] and p["doc_no_enc"]:
            try:
                doc_no = c.decrypt(p["doc_no_enc"], p["enc_key_id"], "brd.manifest_person.doc_no")
            except Exception:
                doc_no = None
        out.append({"id": p["id"], "role": p["person_role"], "full_name": p["full_name"], "category": p["age_category"],
                    "doc_type": p["doc_type"], "doc_no": doc_no, "doc_last4": p["doc_last4"], "issuing_country": p["issuing_country"],
                    "doc_expiry": _iso(p["doc_expiry"]), "nationality": p["nationality"], "birth_date": _iso(p["birth_date"]), "sex": p["sex"],
                    "seat": p["seat_label"], "embark": p["embark"], "disembark": p["disembark"]})
    request.state.audit = {"action": "manifest.delivery_read", "object_type": "brd.manifest_delivery", "object_id": d["id"]}
    return {**_delivery_row(d), "people": out, "vehicles": [dict(v) for v in vehicles]}


class DeliveryAck(BaseModel):
    status: Literal["ACKNOWLEDGED", "REJECTED"]
    ack_ref: Optional[str] = Field(default=None, max_length=80)
    reason: Optional[str] = Field(default=None, max_length=300)
    decisions: list[Decision] = Field(default_factory=list, max_length=500)


@router.post("/manifests/deliveries/{uid}/ack")
async def manifest_ack(uid: uuid.UUID, body: DeliveryAck, request: Request, caller: Caller = Depends(api_caller)):
    """The authority confirms receipt (or refuses the manifest with a reason) and may send decisions on single people."""
    authority = _authority(caller, "manifests:receive")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            d = await _delivery(conn, authority, uid)
            if d["status"] in ("ACKNOWLEDGED", "REJECTED"):
                raise ApiError(409, "ALREADY_ANSWERED", "this delivery was already answered", delivery_status=d["status"])
            for x in body.decisions:
                if x.subject == "PERSON" and not (x.subject_id and await conn.fetchval(
                        "SELECT 1 FROM brd.manifest_person WHERE id = $1 AND manifest_id = $2", x.subject_id, d["manifest_id"])):
                    raise ApiError(422, "SUBJECT_NOT_IN_MANIFEST", "this subject is not part of the manifest", subject_id=x.subject_id)
            await conn.executemany(
                """INSERT INTO brd.manifest_response (manifest_id, subject_type, subject_id, decision, reason_code, silent_flag)
                   VALUES ($1, $2, $3, $4, $5, $6)""",
                [(d["manifest_id"], x.subject, x.subject_id, x.decision, x.reason_code, x.silent) for x in body.decisions])
            await conn.execute(
                """UPDATE brd.manifest_delivery SET status = $2, ack_ref = $3, reject_reason = $4, acknowledged_at = now() WHERE id = $1""",
                d["id"], body.status, body.ack_ref, body.reason)
    request.state.audit = {"action": "manifest.delivery_ack", "object_type": "brd.manifest_delivery", "object_id": d["id"],
                           "reason": body.status}
    return {"delivery": str(uid), "status": body.status, "decisions": len(body.decisions)}


# ------------------------------------------------------------------ webhooks (self-service for the client)
class WebhookIn(BaseModel):
    url: str = Field(min_length=10, max_length=500)
    events: list[str] = Field(min_length=1, max_length=20)


@router.get("/webhooks")
async def webhooks_list(request: Request, caller: Caller = Depends(api_caller)):
    caller.need("webhooks:manage")
    async with db.transaction(context(request, caller)) as conn:
        rows = await conn.fetch("""SELECT uid, url, events, status, include_pii, created_at, last_success_at FROM sys.webhook_endpoint
                                    WHERE api_client_id = $1 AND status <> 'DISABLED' ORDER BY id""", caller.client_id)
    return {"webhooks": [{**dict(r), "uid": str(r["uid"]), "events": list(r["events"]), "created_at": _iso(r["created_at"]),
                          "last_success_at": _iso(r["last_success_at"])} for r in rows]}


@router.post("/webhooks", status_code=201)
async def webhooks_add(body: WebhookIn, request: Request, caller: Caller = Depends(api_caller)):
    """Adds an endpoint. The signing secret is returned once; personal data is never included for self-registered endpoints."""
    caller.need("webhooks:manage")
    async with db.transaction(context(request, caller)) as conn:
        out = await service.add_endpoint(conn, caller.client_id, caller.kind, body.url, body.events, False)
    request.state.audit = {"action": "webhook.create", "object_type": "sys.webhook_endpoint", "reason": out["uid"]}
    return out


@router.get("/webhooks/deliveries")
async def webhook_deliveries(request: Request, status: Optional[Literal["PENDING", "DELIVERED", "FAILED", "DEAD"]] = None,
                             caller: Caller = Depends(api_caller)):
    caller.need("webhooks:manage")
    async with db.transaction(context(request, caller)) as conn:
        rows = await conn.fetch(
            """SELECT d.delivery_uid, d.event_type, d.status, d.attempts, d.http_status, d.last_error, d.created_at, d.delivered_at,
                      d.next_attempt_at, e.uid AS endpoint
                 FROM sys.webhook_delivery d JOIN sys.webhook_endpoint e ON e.id = d.endpoint_id
                WHERE e.api_client_id = $1 AND ($2::text IS NULL OR d.status = $2) ORDER BY d.id DESC LIMIT 200""", caller.client_id, status)
    return {"deliveries": [{**dict(r), "delivery_uid": str(r["delivery_uid"]), "endpoint": str(r["endpoint"]), "created_at": _iso(r["created_at"]),
                            "delivered_at": _iso(r["delivered_at"]), "next_attempt_at": _iso(r["next_attempt_at"])} for r in rows]}


@router.post("/webhooks/deliveries/{delivery_uid}/retry")
async def webhook_retry(delivery_uid: uuid.UUID, request: Request, caller: Caller = Depends(api_caller)):
    caller.need("webhooks:manage")
    async with db.transaction(context(request, caller)) as conn:
        out = await service.redeliver(conn, caller.client_id, delivery_uid)
    request.state.audit = {"action": "webhook.redeliver", "object_type": "webhook_delivery", "object_id": None}
    return out


@router.delete("/webhooks/{uid}")
async def webhooks_remove(uid: uuid.UUID, request: Request, caller: Caller = Depends(api_caller)):
    caller.need("webhooks:manage")
    async with db.transaction(context(request, caller)) as conn:
        return await service.remove_endpoint(conn, caller.client_id, uid)


@router.post("/webhooks/{uid}/{action}")
async def webhooks_action(uid: uuid.UUID, action: Literal["rotate", "ping"], request: Request, caller: Caller = Depends(api_caller)):
    caller.need("webhooks:manage")
    ctx = context(request, caller)
    async with db.transaction(ctx) as conn:
        return await (service.rotate_secret(conn, caller.client_id, uid) if action == "rotate"
                      else service.ping(conn, ctx, caller.client_id, uid))


# ------------------------------------------------------------------ the contract
_spec: Optional[dict] = None


@router.get("/openapi.json", include_in_schema=False)
async def openapi():
    """OpenAPI 3 description of v1 only, with the API key security scheme."""
    global _spec
    if _spec is None:
        _spec = get_openapi(title="Masslak Integration API", version="1.0.0", routes=router.routes,
                            description="Partner API of the Masslak land transport platform. Authenticate with the X-Api-Key header. "
                                        "Scopes: " + "; ".join(f"{k}: {v}" for k, v in SCOPES.items()) + ".")
        _spec.setdefault("components", {})["securitySchemes"] = {"ApiKey": {"type": "apiKey", "in": "header", "name": "X-Api-Key"}}
        _spec["security"] = [{"ApiKey": []}]
    return _spec
