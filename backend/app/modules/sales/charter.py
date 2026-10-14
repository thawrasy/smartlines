"""Charter: buses, minibuses and whole trips hired from carriers (owner's request, October 2026; migration 1123).

A carrier publishes what it hires out (offers): a vehicle apart from the scheduled trips (a coach, a minibus, a van), or
its scheduled trips whole or in blocks of seats, each offer with who may ask (tourism companies, travellers by special
request), how it prices, the notice it needs, what it refunds on a cancellation and its policy in words. A customer asks
under an offer; the carrier prices the request (valid for some hours) or declines it; the customer accepts and pays at
once, into the platform's escrow, and the request is confirmed. A confirmed whole-trip request takes its seats off sale.
When the service is done the carrier marks it so and is paid, less the platform's commission (charter.commission_bp).
A carrier that cancels refunds in full; a customer that cancels a confirmed request is refunded as the offer says.
"""
from __future__ import annotations

import json
import math
import secrets
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

import asyncpg
from pydantic import BaseModel, Field, model_validator

from ... import db
from ...errors import ApiError, not_found
from ...ledger import company_wallet, platform_wallet, post_txn, user_wallet
from ..notify.outbox import emit
from .models import MOBILE

KINDS = ("VEHICLE", "WHOLE_TRIP")
VEHICLE_TYPES = ("COACH", "MINIBUS", "VAN", "CITY_BUS")
BASES = ("PER_DAY", "PER_KM", "PER_TRIP", "PER_SEAT", "ON_REQUEST")
OPEN = ("REQUESTED", "QUOTED")


@dataclass
class Customer:
    """Who asks: a tourism company (its staff act for it) or a traveller."""
    party_id: int
    user_id: int
    kind: str                      # AGENCY or PASSENGER


# ------------------------------------------------------------------ the carrier's offers
class OfferIn(BaseModel):
    kind: Literal["VEHICLE", "WHOLE_TRIP"]
    title: str = Field(min_length=3, max_length=80)
    vehicle_type: Optional[Literal["COACH", "MINIBUS", "VAN", "CITY_BUS"]] = None
    seats: Optional[int] = Field(default=None, ge=1, le=99)
    vehicles: int = Field(default=1, ge=1, le=500)
    partial_seats: bool = True
    min_seats: Optional[int] = Field(default=None, ge=1, le=99)
    audience: list[Literal["AGENCY", "PASSENGER"]] = Field(min_length=1, max_length=2)
    price_basis: Literal["PER_DAY", "PER_KM", "PER_TRIP", "PER_SEAT", "ON_REQUEST"]
    price: Optional[int] = Field(default=None, gt=0)
    currency: str = Field(pattern=r"^[A-Z]{3}$")
    notice_hours: int = Field(default=48, ge=0, le=2160)
    cancel_before_hours: int = Field(default=48, ge=0, le=2160)
    cancel_refund_pct: int = Field(default=100, ge=0, le=100)
    with_driver: bool = True
    base_city: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    policy: str = Field(min_length=10, max_length=2000)

    @model_validator(mode="after")
    def _shape(self):
        self.audience = sorted(set(self.audience))
        if (self.price_basis == "ON_REQUEST") != (self.price is None):
            raise ValueError("CHARTER_PRICE: give a price, or price on request")
        if self.kind == "VEHICLE" and (not self.vehicle_type or not self.seats or self.price_basis == "PER_SEAT"):
            raise ValueError("CHARTER_VEHICLE: a vehicle offer names the kind of vehicle and its seats, and is not priced by the seat")
        if self.kind == "WHOLE_TRIP":
            if self.price_basis in ("PER_DAY", "PER_KM"):
                raise ValueError("CHARTER_TRIP: a trip is priced by the trip, by the seat or on request")
            if self.partial_seats and not self.min_seats:
                raise ValueError("CHARTER_TRIP: give the smallest block of seats, or sell whole trips only")
            self.vehicle_type, self.seats = None, None
        return self


class OfferPatch(BaseModel):
    title: Optional[str] = Field(default=None, min_length=3, max_length=80)
    vehicles: Optional[int] = Field(default=None, ge=1, le=500)
    audience: Optional[list[Literal["AGENCY", "PASSENGER"]]] = Field(default=None, min_length=1, max_length=2)
    price: Optional[int] = Field(default=None, gt=0)
    notice_hours: Optional[int] = Field(default=None, ge=0, le=2160)
    cancel_before_hours: Optional[int] = Field(default=None, ge=0, le=2160)
    cancel_refund_pct: Optional[int] = Field(default=None, ge=0, le=100)
    policy: Optional[str] = Field(default=None, min_length=10, max_length=2000)
    status: Optional[Literal["ACTIVE", "PAUSED", "ARCHIVED"]] = None


OFFER_SQL = """
    SELECT o.uid, o.kind, o.title, o.vehicle_type, o.seats, o.vehicles, o.partial_seats, o.min_seats, o.audience, o.price_basis,
           o.price, o.currency, o.notice_hours, o.cancel_before_hours, o.cancel_refund_pct, o.with_driver, o.policy, o.status,
           c.code AS base_city, p.legal_name AS carrier_name, p.uid AS carrier_uid, iam.logo_version(o.company_id) AS carrier_logo,
           o.created_at, o.updated_at
      FROM sales.charter_offer o JOIN iam.party p ON p.id = o.company_id LEFT JOIN ref.city c ON c.id = o.base_city_id"""


def _offer(r: asyncpg.Record) -> dict:
    return {k: (list(v) if k == "audience" else v) for k, v in dict(r).items()}


async def _city(conn: asyncpg.Connection, code: Optional[str]) -> Optional[int]:
    if code is None:
        return None
    cid = await conn.fetchval("SELECT id FROM ref.city WHERE code = $1 AND is_active", code)
    if cid is None:
        raise ApiError(422, "UNKNOWN_CITY", f"no city {code}")
    return cid


async def create_offer(conn: asyncpg.Connection, company_id: int, user_id: int, body: OfferIn) -> dict:
    city = await _city(conn, body.base_city)
    uid = await conn.fetchval(
        """INSERT INTO sales.charter_offer (company_id, kind, title, vehicle_type, seats, vehicles, partial_seats, min_seats, audience,
             price_basis, price, currency, notice_hours, cancel_before_hours, cancel_refund_pct, with_driver, base_city_id, policy,
             created_by)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19) RETURNING uid""",
        company_id, body.kind, body.title.strip(), body.vehicle_type, body.seats, body.vehicles, body.partial_seats,
        body.min_seats if body.kind == "WHOLE_TRIP" and body.partial_seats else None, body.audience, body.price_basis, body.price,
        body.currency, body.notice_hours, body.cancel_before_hours, body.cancel_refund_pct, body.with_driver, city, body.policy.strip(),
        user_id)
    return _offer(await conn.fetchrow(OFFER_SQL + " WHERE o.uid = $1", uid))


async def change_offer(conn: asyncpg.Connection, company_id: int, uid: uuid.UUID, body: OfferPatch) -> dict:
    o = await conn.fetchrow("SELECT * FROM sales.charter_offer WHERE uid = $1 AND company_id = $2 FOR UPDATE", uid, company_id)
    if o is None:
        raise not_found("offer")
    if o["status"] == "ARCHIVED":
        raise ApiError(409, "OFFER_ARCHIVED", "an archived offer stays as it was")
    if body.price is not None and o["price_basis"] == "ON_REQUEST":
        raise ApiError(422, "CHARTER_PRICE", "this offer is priced on request")
    patch = body.model_dump(exclude_none=True)
    if "audience" in patch:
        patch["audience"] = sorted(set(patch["audience"]))
    if "title" in patch:
        patch["title"] = patch["title"].strip()
    if patch:
        cols = list(patch)
        await conn.execute(f"UPDATE sales.charter_offer SET {', '.join(f'{c} = ${i + 2}' for i, c in enumerate(cols))} WHERE id = $1",
                           o["id"], *[patch[c] for c in cols])
    return _offer(await conn.fetchrow(OFFER_SQL + " WHERE o.uid = $1", uid))


async def carrier_offers(conn: asyncpg.Connection, company_id: int) -> list[dict]:
    rows = await conn.fetch(OFFER_SQL + " WHERE o.company_id = $1 AND o.status <> 'ARCHIVED' ORDER BY o.kind, o.created_at DESC", company_id)
    return [_offer(r) for r in rows]


async def open_offers(conn: asyncpg.Connection, audience: str, kind: Optional[str] = None) -> list[dict]:
    """The offers open to this kind of customer: every carrier's active offers that name it."""
    rows = await conn.fetch(OFFER_SQL + """ WHERE o.status = 'ACTIVE' AND $1 = ANY(o.audience) AND ($2::text IS NULL OR o.kind = $2)
                                             ORDER BY p.legal_name, o.kind, o.title""", audience, kind)
    return [_offer(r) for r in rows]


# ------------------------------------------------------------------ a customer's request
class RequestIn(BaseModel):
    offer_uid: uuid.UUID
    contact_name: str = Field(min_length=2, max_length=120)
    contact_mobile: str = Field(pattern=MOBILE)
    note: Optional[str] = Field(default=None, max_length=500)
    idempotency_key: str = Field(min_length=8, max_length=80)
    # a vehicle apart from the trips
    from_city: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    to_city: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    starts_at: Optional[datetime] = None
    ends_at: Optional[datetime] = None
    passengers: Optional[int] = Field(default=None, ge=1, le=999)
    vehicles: int = Field(default=1, ge=1, le=50)
    itinerary: Optional[str] = Field(default=None, max_length=1000)
    # a scheduled trip, whole or a block of its seats
    trip_uid: Optional[uuid.UUID] = None
    from_seq: Optional[int] = Field(default=None, ge=0, le=500)
    to_seq: Optional[int] = Field(default=None, ge=1, le=500)
    whole: bool = False
    seats: Optional[int] = Field(default=None, ge=1, le=99)


def _ref() -> str:
    return "CH" + "".join(secrets.choice("0123456789ABCDEFGHJKLMNPQRSTUVWXYZ") for _ in range(8))


async def _trip_seats(conn: asyncpg.Connection, trip_id: int, from_seq: int, to_seq: int) -> tuple[int, int]:
    """The trip's seats and those free on every segment between the two stops."""
    row = await conn.fetchrow(
        """SELECT count(*) AS total,
                  count(*) FILTER (WHERE free) AS free
             FROM (SELECT s.seat_no, bool_and(s.status = 'AVAILABLE' OR (s.status = 'LOCKED' AND s.lock_expires_at < now())) AS free
                     FROM ops.seat_segment s WHERE s.trip_id = $1 AND s.seg >= $2 AND s.seg < $3 GROUP BY s.seat_no) x""",
        trip_id, from_seq, to_seq)
    return row["total"], row["free"]


async def create_request(conn: asyncpg.Connection, who: Customer, body: RequestIn) -> dict:
    done = await conn.fetchval("SELECT uid FROM sales.charter_request WHERE requester_party_id = $1 AND idempotency_key = $2",
                               who.party_id, body.idempotency_key)
    if done:                                                   # the same request sent again: the one it made
        return await request_view(conn, done) | {"replayed": True}
    o = await conn.fetchrow("SELECT * FROM sales.charter_offer WHERE uid = $1 AND status = 'ACTIVE'", body.offer_uid)
    if o is None:
        raise not_found("offer")
    if who.kind not in o["audience"]:
        raise ApiError(403, "OFFER_NOT_FOR_YOU", "this carrier hires this out to others only", audience=list(o["audience"]))
    earliest = datetime.now(timezone.utc) + timedelta(hours=o["notice_hours"])
    cols: dict = {}
    if o["kind"] == "VEHICLE":
        if not (body.from_city and body.to_city and body.starts_at and body.ends_at and body.passengers):
            raise ApiError(422, "CHARTER_SHAPE", "a vehicle is asked for from a city to a city, from a time to a time, for some travellers")
        if body.ends_at <= body.starts_at:
            raise ApiError(422, "CHARTER_SHAPE", "the hire ends after it starts")
        if body.starts_at < earliest:
            raise ApiError(422, "NOTICE_TOO_SHORT", f"this carrier needs {o['notice_hours']} hours' notice", notice_hours=o["notice_hours"])
        if body.vehicles > o["vehicles"]:
            raise ApiError(422, "TOO_MANY_VEHICLES", f"this carrier hires out {o['vehicles']} of these", vehicles=o["vehicles"])
        if body.passengers > o["seats"] * body.vehicles:
            raise ApiError(422, "TOO_MANY_PASSENGERS", f"{body.vehicles} vehicle(s) seat {o['seats'] * body.vehicles}",
                           seats=o["seats"] * body.vehicles)
        cols = {"from_city_id": await _city(conn, body.from_city), "to_city_id": await _city(conn, body.to_city),
                "starts_at": body.starts_at, "ends_at": body.ends_at, "passengers": body.passengers, "vehicles": body.vehicles,
                "itinerary": (body.itinerary or "").strip() or None}
    else:
        if body.trip_uid is None or body.from_seq is None or body.to_seq is None or body.to_seq <= body.from_seq:
            raise ApiError(422, "CHARTER_SHAPE", "a trip is asked for from a stop to a later one")
        trip = await conn.fetchrow(
            """SELECT t.id, t.segments_count, a.sched_dep FROM ops.trip t JOIN ops.trip_stop a ON a.trip_id = t.id AND a.seq = $3
                WHERE t.uid = $1 AND t.company_id = $2 AND t.status = 'PUBLISHED'""", body.trip_uid, o["company_id"], body.from_seq)
        if trip is None or body.to_seq > trip["segments_count"]:
            raise not_found("trip")
        if trip["sched_dep"] < earliest:
            raise ApiError(422, "NOTICE_TOO_SHORT", f"this carrier needs {o['notice_hours']} hours' notice", notice_hours=o["notice_hours"])
        total, free = await _trip_seats(conn, trip["id"], body.from_seq, body.to_seq)
        if body.whole:
            if free < total:
                raise ApiError(409, "WHOLE_TRIP_TAKEN", "seats of this trip are already sold; ask for a block instead", seats_left=free)
            seats = total
        else:
            if not o["partial_seats"]:
                raise ApiError(422, "WHOLE_TRIP_ONLY", "this carrier hires its trips whole")
            seats = body.seats or 0
            if seats < (o["min_seats"] or 1):
                raise ApiError(422, "BLOCK_TOO_SMALL", f"a block is at least {o['min_seats']} seats", min_seats=o["min_seats"])
            if seats > free:
                raise ApiError(409, "NOT_ENOUGH_SEATS", f"{free} seats left", seats_left=free)
        cols = {"trip_id": trip["id"], "from_seq": body.from_seq, "to_seq": body.to_seq, "seats": seats, "whole": body.whole}
    ref = _ref()
    while await conn.fetchval("SELECT 1 FROM sales.charter_request WHERE ref = $1", ref):
        ref = _ref()
    terms = {k: o[k] for k in ("title", "price_basis", "price", "currency", "vehicle_type", "seats", "with_driver", "cancel_before_hours",
                               "cancel_refund_pct", "policy")}
    names = ["ref", "offer_id", "company_id", "requester_party_id", "requester_user_id", "requester_kind", "agency_id", "contact_name",
             "contact_mobile", "kind", "terms", "note", "idempotency_key", *cols]
    values = [ref, o["id"], o["company_id"], who.party_id, who.user_id, who.kind, who.party_id if who.kind == "AGENCY" else None,
              " ".join(body.contact_name.split()), body.contact_mobile,
              o["kind"], json.dumps(terms),
              (body.note or "").strip() or None, body.idempotency_key, *cols.values()]
    marks = [f"${i + 1}::jsonb" if n == "terms" else f"${i + 1}" for i, n in enumerate(names)]
    rid = await conn.fetchval(f"INSERT INTO sales.charter_request ({', '.join(names)}) VALUES ({', '.join(marks)}) RETURNING id", *values)
    await emit(conn, "charter.requested", "charter_request", rid, {"ref": ref, "kind": o["kind"]}, company_id=o["company_id"])
    return await request_view(conn, await conn.fetchval("SELECT uid FROM sales.charter_request WHERE id = $1", rid))


REQUEST_SQL = """
    SELECT r.id, r.uid, r.ref, r.kind, r.status, r.requester_kind, r.contact_name, r.contact_mobile, r.note, r.created_at,
           r.starts_at, r.ends_at, r.passengers, r.vehicles, r.itinerary, cf.code AS from_city, ct.code AS to_city,
           t.uid AS trip_uid, t.trip_no, t.trip_code, r.from_seq, r.to_seq, r.seats, r.whole,
           a.sched_dep AS trip_departs_at, sa.code AS trip_from, sb.code AS trip_to,
           r.price, r.currency, r.valid_until, r.quote_note, r.quoted_at, r.paid_at, r.refunded_amount, r.closed_at, r.closed_reason,
           v.plate_no AS vehicle_plate, v.vehicle_type AS vehicle_kind,
           o.uid AS offer_uid, r.terms,
           cp.legal_name AS carrier_name, cp.uid AS carrier_uid, iam.logo_version(r.company_id) AS carrier_logo,
           CASE WHEN r.requester_kind = 'AGENCY' THEN rp.legal_name END AS agency_name,
           (SELECT count(*) FROM sales.charter_seat s WHERE s.request_id = r.id AND s.released_at IS NULL) AS seats_held
      FROM sales.charter_request r
      LEFT JOIN sales.charter_offer o ON o.id = r.offer_id
      JOIN iam.party cp ON cp.id = r.company_id
      LEFT JOIN iam.party rp ON rp.id = r.requester_party_id                  -- a tourism company by name; a traveller by contact
      LEFT JOIN ref.city cf ON cf.id = r.from_city_id LEFT JOIN ref.city ct ON ct.id = r.to_city_id
      LEFT JOIN ops.trip t ON t.id = r.trip_id
      LEFT JOIN ops.trip_stop a ON a.trip_id = r.trip_id AND a.seq = r.from_seq LEFT JOIN net.station sa ON sa.id = a.station_id
      LEFT JOIN ops.trip_stop b ON b.trip_id = r.trip_id AND b.seq = r.to_seq LEFT JOIN net.station sb ON sb.id = b.station_id
      LEFT JOIN fleet.vehicle v ON v.id = r.vehicle_id"""


def estimate(r) -> Optional[int]:
    """What the offer's own price comes to for this request, before the carrier prices it (none when priced on request or
    by the kilometre, which the carrier measures)."""
    terms = r["terms"]
    p, basis = terms.get("price"), terms["price_basis"]
    if p is None or basis in ("ON_REQUEST", "PER_KM"):
        return None
    if r["kind"] == "VEHICLE":
        n = r["vehicles"] or 1
        if basis == "PER_DAY":
            return p * n * max(1, math.ceil((r["ends_at"] - r["starts_at"]).total_seconds() / 86400))
        return p * n
    return p * r["seats"] if basis == "PER_SEAT" else p


def _status(r) -> str:
    """A price past its time has lapsed even before anyone touches the request."""
    if r["status"] == "QUOTED" and r["valid_until"] and r["valid_until"] < datetime.now(timezone.utc):
        return "EXPIRED"
    return r["status"]


def _view(r: asyncpg.Record) -> dict:
    out = {k: v for k, v in dict(r).items() if k != "id"}
    out["terms"] = json.loads(r["terms"]) if isinstance(r["terms"], str) else r["terms"]
    out["status"] = _status(r)
    out["estimate"] = estimate(out)
    return out


async def request_view(conn: asyncpg.Connection, uid: uuid.UUID, party_id: Optional[int] = None) -> dict:
    """One request; with party_id, only when that customer made it."""
    r = await conn.fetchrow(REQUEST_SQL + " WHERE r.uid = $1 AND ($2::bigint IS NULL OR r.requester_party_id = $2)", uid, party_id)
    if r is None:
        raise not_found("charter request")
    return _view(r)


async def list_requests(conn: asyncpg.Connection, *, company_id: Optional[int] = None, party_id: Optional[int] = None,
                        status: Optional[str] = None, limit: int = 200) -> list[dict]:
    rows = await conn.fetch(
        REQUEST_SQL + """ WHERE ($1::bigint IS NULL OR r.company_id = $1) AND ($2::bigint IS NULL OR r.requester_party_id = $2)
                            AND ($3::text IS NULL OR r.status = $3) ORDER BY r.created_at DESC LIMIT $4""",
        company_id, party_id, status, limit)
    return [_view(r) for r in rows]


async def _mine(conn: asyncpg.Connection, uid: uuid.UUID, *, company_id: Optional[int] = None,
                party_id: Optional[int] = None) -> asyncpg.Record:
    r = await conn.fetchrow(
        """SELECT r.*, (r.terms ->> 'cancel_before_hours')::int AS cancel_before_hours,
                  (r.terms ->> 'cancel_refund_pct')::int AS cancel_refund_pct
             FROM sales.charter_request r
            WHERE r.uid = $1 AND ($2::bigint IS NULL OR r.company_id = $2) AND ($3::bigint IS NULL OR r.requester_party_id = $3)
              FOR UPDATE""", uid, company_id, party_id)
    if r is None:
        raise not_found("charter request")
    return r


async def _starts(conn: asyncpg.Connection, r) -> datetime:
    if r["kind"] == "VEHICLE":
        return r["starts_at"]
    return await conn.fetchval("SELECT sched_dep FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2", r["trip_id"], r["from_seq"])


# ------------------------------------------------------------------ the carrier prices, declines, names the vehicle
class QuoteIn(BaseModel):
    price: int = Field(gt=0)
    valid_hours: int = Field(default=48, ge=1, le=168)
    note: Optional[str] = Field(default=None, max_length=500)
    vehicle_uid: Optional[uuid.UUID] = None


async def _vehicle(conn: asyncpg.Connection, company_id: int, uid: Optional[uuid.UUID]) -> Optional[int]:
    if uid is None:
        return None
    vid = await conn.fetchval("SELECT id FROM fleet.vehicle WHERE uid = $1 AND company_id = $2 AND status = 'ACTIVE'", uid, company_id)
    if vid is None:
        raise not_found("vehicle")
    return vid


async def quote(conn: asyncpg.Connection, company_id: int, user_id: int, uid: uuid.UUID, body: QuoteIn) -> dict:
    r = await _mine(conn, uid, company_id=company_id)
    if r["status"] not in OPEN:
        raise ApiError(409, "CHARTER_CLOSED", "this request is no longer open", charter_status=r["status"])
    starts = await _starts(conn, r)
    now = datetime.now(timezone.utc)
    if starts <= now:
        raise ApiError(409, "CHARTER_STARTED", "the service has already begun")
    currency = (json.loads(r["terms"]) if isinstance(r["terms"], str) else r["terms"])["currency"]
    vehicle = await _vehicle(conn, company_id, body.vehicle_uid)
    await conn.execute(
        """UPDATE sales.charter_request SET status = 'QUOTED', price = $2, currency = $3, valid_until = $4, quote_note = $5,
             quoted_by = $6, quoted_at = now(), vehicle_id = coalesce($7, vehicle_id) WHERE id = $1""",
        r["id"], body.price, currency, min(now + timedelta(hours=body.valid_hours), starts), (body.note or "").strip() or None,
        user_id, vehicle)
    await emit(conn, "charter.quoted", "charter_request", r["id"], {"ref": r["ref"], "price": body.price, "currency": currency},
               company_id=company_id)
    return await request_view(conn, uid)


async def decline(conn: asyncpg.Connection, company_id: int, user_id: int, uid: uuid.UUID, reason: str) -> dict:
    r = await _mine(conn, uid, company_id=company_id)
    if r["status"] not in OPEN:
        raise ApiError(409, "CHARTER_CLOSED", "this request is no longer open", charter_status=r["status"])
    await conn.execute("UPDATE sales.charter_request SET status = 'DECLINED', closed_by = $2, closed_at = now(), closed_reason = $3 WHERE id = $1",
                       r["id"], user_id, reason.strip())
    await emit(conn, "charter.declined", "charter_request", r["id"], {"ref": r["ref"]}, company_id=company_id)
    return await request_view(conn, uid)


async def assign_vehicle(conn: asyncpg.Connection, company_id: int, uid: uuid.UUID, vehicle_uid: uuid.UUID) -> dict:
    r = await _mine(conn, uid, company_id=company_id)
    if r["kind"] != "VEHICLE" or r["status"] not in ("QUOTED", "CONFIRMED"):
        raise ApiError(409, "CHARTER_CLOSED", "a vehicle is named on a priced or confirmed vehicle hire", charter_status=r["status"])
    await conn.execute("UPDATE sales.charter_request SET vehicle_id = $2 WHERE id = $1", r["id"], await _vehicle(conn, company_id, vehicle_uid))
    return await request_view(conn, uid)


# ------------------------------------------------------------------ the money
async def _payer_wallet(conn: asyncpg.Connection, r, currency: str):
    if r["requester_kind"] == "AGENCY":
        return await company_wallet(conn, r["requester_party_id"], currency, label="Agency wallet")
    return dict(await user_wallet(conn, r["requester_party_id"], currency))


async def accept(conn: asyncpg.Connection, ctx: db.Context, who: Customer, uid: uuid.UUID) -> dict:
    """The customer accepts the price: the seats of a whole-trip request are taken off sale and the price is paid into
    escrow, both or neither."""
    r = await _mine(conn, uid, party_id=who.party_id)
    if r["status"] == "CONFIRMED":
        return await request_view(conn, uid) | {"replayed": True}
    if r["status"] != "QUOTED":
        raise ApiError(409, "CHARTER_NOT_PRICED", "the carrier has not priced this request", charter_status=r["status"])
    if r["valid_until"] < datetime.now(timezone.utc):
        await conn.execute("UPDATE sales.charter_request SET status = 'EXPIRED' WHERE id = $1", r["id"])
        raise ApiError(409, "QUOTE_EXPIRED", "the carrier's price has lapsed; ask again")
    if r["kind"] == "WHOLE_TRIP":
        await conn.fetchval("SELECT sales.charter_block_seats($1)", r["id"])
    async with db.system_scope(conn, ctx):
        wallet = await _payer_wallet(conn, r, r["currency"])
        available = wallet["balance"] - wallet["hold_balance"]
        if available < r["price"]:
            raise ApiError(402, "INSUFFICIENT_BALANCE", "wallet balance is not enough", required=r["price"], balance=available)
        escrow = await platform_wallet(conn, "ESCROW", r["currency"])
        txn = await post_txn(conn, "CHARTER_PAY", r["currency"], f"charter:{r['id']}:pay",
                             [(wallet["id"], "DR", r["price"]), (escrow["id"], "CR", r["price"])],
                             ref_type="charter_request", ref_id=r["id"], user_id=who.user_id, memo=r["ref"])
    await conn.execute("UPDATE sales.charter_request SET status = 'CONFIRMED', paid_txn_id = $2, paid_at = now() WHERE id = $1",
                       r["id"], txn)
    await emit(conn, "charter.confirmed", "charter_request", r["id"], {"ref": r["ref"], "price": r["price"]}, company_id=r["company_id"])
    return await request_view(conn, uid)


async def withdraw(conn: asyncpg.Connection, who: Customer, uid: uuid.UUID) -> dict:
    r = await _mine(conn, uid, party_id=who.party_id)
    if r["status"] not in OPEN:
        raise ApiError(409, "CHARTER_CLOSED", "only an open request is withdrawn; cancel a confirmed one", charter_status=r["status"])
    await conn.execute("UPDATE sales.charter_request SET status = 'WITHDRAWN', closed_by = $2, closed_at = now() WHERE id = $1",
                       r["id"], who.user_id)
    return await request_view(conn, uid)


async def _commission_bp(conn: asyncpg.Connection) -> int:
    return await conn.fetchval("SELECT sales.setting_int('charter.commission_bp', 0)")


async def _settle(conn: asyncpg.Connection, r, refund: int, user_id: int, kind: str) -> tuple[int, int]:
    """Pays out what escrow holds for a confirmed request: refund to the customer, the rest to the carrier less the
    platform's commission. Returns the transaction and the commission."""
    price, cur = r["price"], r["currency"]
    kept = price - refund
    commission = kept * await _commission_bp(conn) // 10000
    escrow = await platform_wallet(conn, "ESCROW", cur)
    entries = [(escrow["id"], "DR", price)]
    if refund:
        entries.append(((await _payer_wallet(conn, r, cur))["id"], "CR", refund))
    if kept - commission:
        entries.append(((await company_wallet(conn, r["company_id"], cur))["id"], "CR", kept - commission))
    if commission:
        entries.append(((await platform_wallet(conn, "COMMISSION", cur))["id"], "CR", commission))
    txn = await post_txn(conn, kind, cur, f"charter:{r['id']}:{kind.lower()}", entries, ref_type="charter_request", ref_id=r["id"],
                         user_id=user_id, memo=r["ref"])
    return txn, commission


async def complete(conn: asyncpg.Connection, ctx: db.Context, company_id: int, user_id: int, uid: uuid.UUID) -> dict:
    """The carrier has done the service: the price leaves escrow for the carrier, less the platform's commission."""
    r = await _mine(conn, uid, company_id=company_id)
    if r["status"] != "CONFIRMED":
        raise ApiError(409, "CHARTER_NOT_CONFIRMED", "only a confirmed charter is done", charter_status=r["status"])
    if await _starts(conn, r) > datetime.now(timezone.utc):
        raise ApiError(409, "CHARTER_NOT_STARTED", "the service is marked done once it has begun")
    async with db.system_scope(conn, ctx):
        txn, commission = await _settle(conn, r, 0, user_id, "CHARTER_RELEASE")
    await conn.execute("UPDATE sales.charter_request SET status = 'COMPLETED', released_txn_id = $2, closed_by = $3, closed_at = now() WHERE id = $1",
                       r["id"], txn, user_id)
    await emit(conn, "charter.completed", "charter_request", r["id"], {"ref": r["ref"], "commission": commission}, company_id=company_id)
    return await request_view(conn, uid)


async def cancel(conn: asyncpg.Connection, ctx: db.Context, uid: uuid.UUID, user_id: int, reason: str, *,
                 company_id: Optional[int] = None, who: Optional[Customer] = None) -> dict:
    """A confirmed charter cancelled: by the carrier with a full refund; by the customer with the refund its offer gives
    when cancelled in time (cancel_before_hours before the start), none after. Seats held go back on sale."""
    r = await _mine(conn, uid, company_id=company_id, party_id=who.party_id if who else None)
    if r["status"] in OPEN and company_id is not None:
        return await decline(conn, company_id, user_id, uid, reason)
    if r["status"] != "CONFIRMED":
        raise ApiError(409, "CHARTER_NOT_CONFIRMED", "only a confirmed charter is cancelled; withdraw an open request",
                       charter_status=r["status"])
    starts = await _starts(conn, r)
    if who is not None and starts <= datetime.now(timezone.utc):
        raise ApiError(409, "CHARTER_STARTED", "the service has already begun")
    if company_id is not None:
        refund = r["price"]
    else:
        in_time = starts - datetime.now(timezone.utc) >= timedelta(hours=r["cancel_before_hours"])
        refund = r["price"] * r["cancel_refund_pct"] // 100 if in_time else 0
    if r["kind"] == "WHOLE_TRIP":
        await conn.fetchval("SELECT sales.charter_release_seats($1)", r["id"])
    async with db.system_scope(conn, ctx):
        txn, _ = await _settle(conn, r, refund, user_id, "CHARTER_REFUND")
    await conn.execute(
        """UPDATE sales.charter_request SET status = 'CANCELLED', refund_txn_id = $2, refunded_amount = $3, closed_by = $4,
             closed_at = now(), closed_reason = $5 WHERE id = $1""", r["id"], txn, refund, user_id, reason.strip() or None)
    await emit(conn, "charter.cancelled", "charter_request", r["id"],
               {"ref": r["ref"], "refund": refund, "by": "CARRIER" if company_id is not None else "CUSTOMER"}, company_id=r["company_id"])
    return await request_view(conn, uid)
