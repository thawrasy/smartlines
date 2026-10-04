"""Seat holds, bookings paid from the wallet, tickets with rotating QR codes, and cancellation."""
import json
import uuid
from datetime import datetime, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, field_validator, model_validator

from .. import db
from ..config import get_settings
from ..deps import Principal, context_for, require_portal
from ..errors import ApiError, forbidden, not_found
from ..ledger import platform_wallet, post_txn, user_wallet, company_wallet
from ..security import document_token, ticket_qr_token
from ..util import booking_ref, row_dict, rows, ticket_no, ticket_name

router = APIRouter(prefix="/api", tags=["bookings"])
passenger = require_portal("PASSENGER")

FREE_SEG = "(status = 'AVAILABLE' OR (status = 'LOCKED' AND lock_expires_at < now()))"
MAX_SEATS, MAX_LOCKED_SEATS = 4, 8


class HoldIn(BaseModel):
    trip_uid: uuid.UUID
    from_seq: int = Field(ge=0)
    to_seq: int = Field(ge=1)
    seat_nos: list[int] = Field(min_length=1, max_length=MAX_SEATS)


@router.post("/holds", status_code=201)
async def create_hold(body: HoldIn, request: Request, pr: Principal = Depends(passenger)):
    if body.to_seq <= body.from_seq or len(set(body.seat_nos)) != len(body.seat_nos):
        raise ApiError(422, "INVALID_HOLD", "invalid pair or duplicate seats")
    ctx = context_for(request, pr)
    token = uuid.uuid4()
    async with db.transaction(ctx) as conn:
        trip = await conn.fetchrow(
            """SELECT t.id, t.hold_min, t.segments_count FROM ops.trip t
                 JOIN ops.trip_stop a ON a.trip_id = t.id AND a.seq = $2
                WHERE t.uid = $1 AND t.status IN ('PUBLISHED','BOARDING') AND a.sales_closed_at IS NULL
                  AND a.sched_dep > now() + make_interval(mins => t.sales_cutoff_min)""",
            body.trip_uid, body.from_seq)
        if trip is None or body.to_seq > trip["segments_count"]:
            raise ApiError(409, "SALES_CLOSED", "the trip is not on sale for this stop")
        held = await conn.fetchval(
            "SELECT count(DISTINCT (trip_id, seat_no)) FROM ops.seat_segment WHERE lock_user_id = $1 "
            "AND status = 'LOCKED' AND lock_expires_at > now()", pr.user_id)
        if held + len(body.seat_nos) > MAX_LOCKED_SEATS:
            raise ApiError(429, "TOO_MANY_HOLDS", "too many seats on hold")
        expected = len(body.seat_nos) * (body.to_seq - body.from_seq)
        locked = await conn.fetch(
            f"""UPDATE ops.seat_segment
                   SET status = 'LOCKED', lock_token = $4, lock_user_id = $5,
                       lock_expires_at = now() + make_interval(mins => $6)
                 WHERE trip_id = $1 AND seat_no = ANY($2::smallint[]) AND seg >= $3 AND seg < $7 AND {FREE_SEG}
             RETURNING seat_no, lock_expires_at""",
            trip["id"], body.seat_nos, body.from_seq, token, pr.user_id, trip["hold_min"], body.to_seq)
        if len(locked) != expected:
            raise ApiError(409, "SEAT_TAKEN", "one of the seats is no longer available")
    request.state.audit = {"action": "booking.hold", "object_type": "trip", "object_id": trip["id"]}
    return {"hold_token": str(token), "expires_at": locked[0]["lock_expires_at"].isoformat()}


@router.delete("/holds/{hold_token}")
async def release_hold(hold_token: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        released = await conn.fetchval(
            """WITH r AS (UPDATE ops.seat_segment SET status = 'AVAILABLE', lock_token = NULL, lock_user_id = NULL,
                            lock_expires_at = NULL
                          WHERE lock_token = $1 AND lock_user_id = $2 AND status = 'LOCKED' RETURNING seat_no)
               SELECT count(DISTINCT seat_no) FROM r""", hold_token, pr.user_id)
    return {"ok": True, "released_seats": released}


# One name part: letters in any script, single spaces, hyphens, apostrophes or dots between them
NAME_PART = r"^[^\W\d_]+(?:[ '\-.][^\W\d_]+)*\.?$"


class PassengerIn(BaseModel):
    """Passenger names exactly as on the identity document. Syrian citizens give the four parts of the
    national ID (first, father, grandfather, family). Other nationalities give the given and family names
    of the passport or ID; father's and grandfather's names only when the document carries them."""
    nationality: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    first_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    father_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    grandfather_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    last_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    seat_no: int
    id_type: Optional[Literal["NATIONAL_ID", "PASSPORT", "RESIDENCE", "OTHER"]] = None
    id_last4: Optional[str] = Field(default=None, pattern=r"^[0-9A-Za-z]{3,4}$")
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")

    @field_validator("first_name", "father_name", "grandfather_name", "last_name", mode="before")
    @classmethod
    def _tidy(cls, v):
        return " ".join(v.split()) or None if isinstance(v, str) else v

    @model_validator(mode="after")
    def _syrian_four_part_name(self):
        if self.nationality == "SY" and not (self.father_name and self.grandfather_name):
            raise ValueError("NAME_PARTS_REQUIRED: Syrian citizens need first, father, grandfather and family names")
        return self

    @property
    def full_name(self) -> str:
        return " ".join(p for p in (self.first_name, self.father_name, self.grandfather_name, self.last_name) if p)


class BookingIn(BaseModel):
    hold_token: uuid.UUID
    trip_uid: uuid.UUID
    from_seq: int
    to_seq: int
    fare_brand: str = "STANDARD"
    passengers: list[PassengerIn] = Field(min_length=1, max_length=MAX_SEATS)
    idempotency_key: str = Field(min_length=8, max_length=80)


def _round_unit(amount: float) -> int:
    """Rounds to a whole currency unit (100 minor units)."""
    return int(round(amount / 100.0)) * 100


@router.post("/bookings", status_code=201)
async def create_booking(body: BookingIn, request: Request, pr: Principal = Depends(passenger)):
    s = get_settings()
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        existing = await conn.fetchval(
            "SELECT booking_ref FROM sales.booking WHERE booker_party_id = $1 AND idempotency_key = $2",
            pr.party_id, body.idempotency_key)
        if existing:
            return {"booking_ref": existing, "replayed": True}

        trip = await conn.fetchrow(
            "SELECT id, company_id, currency, trip_no FROM ops.trip WHERE uid = $1 AND status IN ('PUBLISHED','BOARDING')",
            body.trip_uid)
        if trip is None:
            raise not_found("trip")
        brand = await conn.fetchrow(
            "SELECT code, name, factor, rules FROM pricing.fare_brand WHERE code = $1 AND active", body.fare_brand)
        if brand is None:
            raise ApiError(422, "UNKNOWN_FARE_BRAND", "unknown fare brand")
        seat_nos = [p.seat_no for p in body.passengers]
        held = await conn.fetch(
            """SELECT seat_no, count(*) AS segs FROM ops.seat_segment
                WHERE trip_id = $1 AND lock_token = $2 AND lock_user_id = $3 AND status = 'LOCKED'
                  AND lock_expires_at > now() AND seg >= $4 AND seg < $5
                GROUP BY seat_no""", trip["id"], body.hold_token, pr.user_id, body.from_seq, body.to_seq)
        held_ok = {h["seat_no"] for h in held if h["segs"] == body.to_seq - body.from_seq}
        if set(seat_nos) != held_ok:
            raise ApiError(409, "HOLD_EXPIRED", "the seat hold has expired; choose seats again")

        ladder = dict(await conn.fetch(
            "SELECT seq, fare_from_origin FROM ops.trip_stop WHERE trip_id = $1 AND seq IN ($2, $3)",
            trip["id"], body.from_seq, body.to_seq))
        pair_override = await conn.fetchval(
            "SELECT price FROM ops.trip_pair_fare WHERE trip_id = $1 AND from_seq = $2 AND to_seq = $3",
            trip["id"], body.from_seq, body.to_seq)
        pair_price = pair_override if pair_override is not None else ladder[body.to_seq] - ladder[body.from_seq]
        fare = _round_unit(pair_price * float(brand["factor"]))
        fares_total = fare * len(body.passengers)
        fee = s.platform_fee
        total = fares_total + fee
        rules = json.loads(brand["rules"]) if isinstance(brand["rules"], str) else brand["rules"]
        breakdown = {"pair_price": pair_price, "fare_brand": brand["code"], "factor": float(brand["factor"]),
                     "fare_per_passenger": fare, "passengers": len(body.passengers), "fares_total": fares_total,
                     "platform_fee": fee, "total": total, "currency": trip["currency"]}

        wallet = await user_wallet(conn, pr.party_id, trip["currency"])
        if wallet["balance"] < total:
            raise ApiError(402, "INSUFFICIENT_BALANCE", "wallet balance is not enough", required=total,
                           balance=wallet["balance"])

        channel_id = await conn.fetchval("SELECT id FROM sales.channel WHERE code = 'WEB'")
        ref = booking_ref()
        while await conn.fetchval("SELECT 1 FROM sales.booking WHERE booking_ref = $1", ref):
            ref = booking_ref()
        booking_id = await conn.fetchval(
            """INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, booker_user_id, channel_id,
                 status, pay_method, currency, total_amount, price_breakdown, rules_version, idempotency_key)
               VALUES ($1, $2, $3, $4, $5, $6, 'PENDING_PAYMENT', 'WALLET', $7, $8, $9::jsonb, 'v1', $10)
               RETURNING id""",
            ref, trip["id"], trip["company_id"], pr.party_id, pr.user_id, channel_id, trip["currency"], total,
            json.dumps(breakdown), body.idempotency_key)

        async with db.system_scope(conn, ctx):
            tickets = []
            for i, p in enumerate(body.passengers, start=1):
                pid = await conn.fetchval(
                    """INSERT INTO sales.passenger (booking_id, full_name, first_name, father_name, grandfather_name,
                         last_name, nationality, id_type, id_no_last4, mobile)
                       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING id""",
                    booking_id, p.full_name, p.first_name, p.father_name, p.grandfather_name, p.last_name,
                    p.nationality, p.id_type, p.id_last4, p.mobile)
                tid = await conn.fetchval(
                    """INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no,
                         fare_brand_code, fare_amount, total_amount, rules_snapshot)
                       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9, $10::jsonb) RETURNING id""",
                    ticket_no(ref, i), booking_id, pid, trip["id"], body.from_seq, body.to_seq, p.seat_no,
                    brand["code"], fare, json.dumps({"brand": brand["code"], **rules}))
                await conn.execute(
                    """UPDATE ops.seat_segment SET status = 'SOLD', ticket_id = $4, lock_token = NULL,
                         lock_user_id = NULL, lock_expires_at = NULL
                       WHERE trip_id = $1 AND seat_no = $2 AND lock_token = $3""",
                    trip["id"], p.seat_no, body.hold_token, tid)
                tickets.append(tid)

            # Price allocation: the carrier fare is held in escrow until the trip completes; the fee is the platform's
            platform = await platform_wallet(conn, "PLATFORM", trip["currency"])
            escrow = await platform_wallet(conn, "ESCROW", trip["currency"])
            carrier = await company_wallet(conn, trip["company_id"], trip["currency"])
            alloc_id = await conn.fetchval(
                """INSERT INTO fin.price_allocation (subject_type, subject_id, booking_id, currency, total, rules_version)
                   VALUES ('BOOKING', $1, $1, $2, $3, 'v1') RETURNING id""", booking_id, trip["currency"], total)
            await conn.execute(
                """INSERT INTO fin.price_allocation_line (allocation_id, code, level, is_leaf, component_type,
                     beneficiary_party_id, basis, amount, wallet_id, release_event)
                   VALUES ($1, 'CARRIER_FARE', 1, true, 'FARE', $2, 'PER_TICKET', $3, $4, 'TRIP_COMPLETED'),
                          ($1, 'PLATFORM_FEE', 1, true, 'FEE', $5, 'PER_BOOKING', $6, $7, 'TRIP_COMPLETED')""",
                alloc_id, trip["company_id"], fares_total, carrier["id"], platform["owner_party_id"], fee, platform["id"])
            await conn.execute("UPDATE sales.booking SET price_allocation_id = $2 WHERE id = $1", booking_id, alloc_id)

            await post_txn(conn, "BOOKING_PAY", trip["currency"], f"booking:{booking_id}:pay",
                           [(wallet["id"], "DR", total), (escrow["id"], "CR", total)],
                           ref_type="booking", ref_id=booking_id, user_id=pr.user_id, memo=ref)
            await conn.execute(
                "UPDATE sales.booking SET status = 'CONFIRMED', confirmed_at = now() WHERE id = $1", booking_id)
    request.state.audit = {"action": "booking.create", "object_type": "booking", "object_id": booking_id}
    return {"booking_ref": ref, "total": total, "currency": trip["currency"]}


async def _booking_for(conn, pr: Principal, ref: str):
    b = await conn.fetchrow(
        """SELECT b.*, t.trip_no, t.uid AS trip_uid, t.departure_at, t.status AS trip_status,
                  cp.legal_name AS carrier_name
             FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
            WHERE b.booking_ref = $1 AND b.booker_party_id = $2""", ref.upper(), pr.party_id)
    if b is None:
        raise not_found("booking")
    return b


@router.get("/bookings")
async def my_bookings(request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT b.booking_ref, b.status, b.total_amount, b.currency, b.created_at, t.trip_no, t.uid AS trip_uid,
                      cp.legal_name AS carrier_name,
                      (SELECT jsonb_build_object('from_station', sa.name, 'from_code', sa.code, 'from_city', ca.code, 'departs_at', a.sched_dep,
                                                 'to_station', sb.name, 'to_code', sb.code, 'to_city', cb.code, 'arrives_at', z.sched_arr)
                         FROM sales.ticket k
                         JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
                         JOIN net.station sa ON sa.id = a.station_id JOIN ref.city ca ON ca.id = sa.city_id
                         JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq
                         JOIN net.station sb ON sb.id = z.station_id JOIN ref.city cb ON cb.id = sb.city_id
                        WHERE k.booking_id = b.id LIMIT 1) AS journey
                 FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id JOIN iam.party cp ON cp.id = b.company_id
                WHERE b.booker_party_id = $1 ORDER BY b.created_at DESC LIMIT 50""", pr.party_id)
    out = []
    for r in recs:
        d = row_dict(r)
        d["journey"] = json.loads(d["journey"]) if isinstance(d["journey"], str) else d["journey"]
        out.append(d)
    return {"bookings": out}


@router.get("/bookings/{ref}")
async def booking_detail(ref: str, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        b = await _booking_for(conn, pr, ref)
        async with db.system_scope(conn, context_for(request, pr)):
            tickets = await conn.fetch(
                """SELECT k.uid, k.ticket_no, k.seat_no, k.status, k.fare_brand_code, k.total_amount, k.from_seq, k.to_seq,
                          p.full_name, p.first_name, p.last_name, p.nationality, sa.name AS from_station, sa.code AS from_code, ca.code AS from_city, a.sched_dep AS departs_at,
                          sb.name AS to_station, sb.code AS to_code, cb.code AS to_city, z.sched_arr AS arrives_at, k.rules_snapshot
                     FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                     JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
                     JOIN net.station sa ON sa.id = a.station_id JOIN ref.city ca ON ca.id = sa.city_id
                     JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq
                     JOIN net.station sb ON sb.id = z.station_id JOIN ref.city cb ON cb.id = sb.city_id
                    WHERE k.booking_id = $1 ORDER BY k.ticket_no""", b["id"])
    booking = {k: b[k] for k in ("booking_ref", "status", "total_amount", "currency", "trip_no", "carrier_name")}
    booking["price_breakdown"] = json.loads(b["price_breakdown"]) if isinstance(b["price_breakdown"], str) else b["price_breakdown"]
    booking["created_at"] = b["created_at"].isoformat()
    booking["verify_token"] = document_token("booking", b["booking_ref"])
    tk = []
    for t in tickets:
        d = row_dict(t)
        d["rules_snapshot"] = json.loads(d["rules_snapshot"]) if isinstance(d["rules_snapshot"], str) else d["rules_snapshot"]
        d["ticket_name"] = ticket_name(d.pop("first_name"), d.pop("last_name"), d["full_name"])
        tk.append(d)
    return {"booking": booking, "tickets": tk}


@router.get("/tickets/{ticket_uid}/qr")
async def ticket_qr(ticket_uid: uuid.UUID, request: Request, pr: Principal = Depends(passenger)):
    async with db.transaction(context_for(request, pr)) as conn:
        ok = await conn.fetchval(
            """SELECT k.status FROM sales.ticket k JOIN sales.booking b ON b.id = k.booking_id
                WHERE k.uid = $1 AND b.booker_party_id = $2""", ticket_uid, pr.party_id)
    if ok is None:
        raise not_found("ticket")
    if ok not in ("ISSUED", "BOARDED"):
        raise ApiError(409, "TICKET_NOT_VALID", "ticket is not valid for boarding")
    token, valid_until = ticket_qr_token(str(ticket_uid))
    return {"token": token, "valid_until": valid_until, "window": get_settings().qr_window_seconds}


def refund_pct(rules: dict, hours_left: float) -> int:
    """Refund schedule from the fare brand snapshot: [[min_hours, percent], ...]."""
    if not rules.get("refundable", False):
        return 0
    for min_hours, pct in sorted(rules.get("refund", []), key=lambda x: -x[0]):
        if hours_left >= min_hours:
            return int(pct)
    return 0


@router.post("/bookings/{ref}/cancel")
async def cancel_booking(ref: str, request: Request, pr: Principal = Depends(passenger)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        b = await _booking_for(conn, pr, ref)
        if b["status"] != "CONFIRMED" or b["trip_status"] not in ("PUBLISHED",):
            raise ApiError(409, "CANNOT_CANCEL", "this booking can no longer be cancelled")
        async with db.system_scope(conn, ctx):
            tickets = await conn.fetch(
                """SELECT k.id, k.total_amount, k.status, k.rules_snapshot, a.sched_dep
                     FROM sales.ticket k JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq
                    WHERE k.booking_id = $1""", b["id"])
            if any(t["status"] != "ISSUED" for t in tickets):
                raise ApiError(409, "CANNOT_CANCEL", "a passenger has already boarded")
            now = datetime.now(timezone.utc)
            refund = 0
            for t in tickets:
                rules = json.loads(t["rules_snapshot"]) if isinstance(t["rules_snapshot"], str) else t["rules_snapshot"]
                hours = (t["sched_dep"] - now).total_seconds() / 3600
                refund += t["total_amount"] * refund_pct(rules, hours) // 100
            await conn.execute("UPDATE sales.ticket SET status = 'CANCELLED' WHERE booking_id = $1", b["id"])
            await conn.execute(
                """UPDATE ops.seat_segment SET status = 'AVAILABLE', ticket_id = NULL
                    WHERE ticket_id IN (SELECT id FROM sales.ticket WHERE booking_id = $1)""", b["id"])
            await conn.execute(
                "UPDATE sales.booking SET status = 'CANCELLED', cancelled_at = now(), cancel_reason = 'CUSTOMER' WHERE id = $1",
                b["id"])
            if refund > 0:
                escrow = await platform_wallet(conn, "ESCROW", b["currency"])
                wallet = await user_wallet(conn, pr.party_id, b["currency"])
                await post_txn(conn, "REFUND", b["currency"], f"booking:{b['id']}:refund",
                               [(escrow["id"], "DR", refund), (wallet["id"], "CR", refund)],
                               ref_type="booking", ref_id=b["id"], user_id=pr.user_id, memo=b["booking_ref"])
            # Whatever is not refunded stays with the carrier as the cancellation fee, released with the trip
            await conn.execute(
                """UPDATE fin.price_allocation_line SET refunded_amount = LEAST(amount, $2),
                       status = CASE WHEN $2 >= amount THEN 'REFUNDED' ELSE 'PARTIAL_REFUND' END
                    WHERE allocation_id = $1 AND code = 'CARRIER_FARE'""",
                b["price_allocation_id"], refund)
    request.state.audit = {"action": "booking.cancel", "object_type": "booking", "object_id": b["id"]}
    return {"ok": True, "refund": refund, "currency": b["currency"]}
