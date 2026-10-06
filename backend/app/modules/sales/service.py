"""Sales use cases shared by every channel: hold seats, book and pay, list tickets, cancel and refund.

A channel describes who is buying with a Buyer: the passenger paying from their wallet, or an agency paying
from its company wallet and earning a commission. Pricing, inventory, encryption of document numbers and the
ledger postings are identical for both, so they live here once.
"""
import json
import uuid
from dataclasses import dataclass
from datetime import date, datetime, timezone
from typing import Optional

import asyncpg

from ... import crypto, db
from ...config import get_settings
from ...errors import ApiError, not_found
from ...ledger import company_wallet, platform_wallet, post_txn, user_wallet
from ...util import booking_ref, row_dict, ticket_name, ticket_no
from ..family import service as fam
from ..fares import categories as cat
from ..notify.outbox import emit
from . import documents, repository as repo
from .models import MAX_LOCKED_SEATS, BookingIn, HoldIn


@dataclass(frozen=True)
class Buyer:
    """Who pays and who appears as the booker."""
    party_id: int                    # booker_party_id: the passenger, or the agency company
    user_id: int                     # the signed-in user (passenger or agency clerk)
    channel: str = "WEB"
    agency_id: Optional[int] = None  # set for agency sales: pays from the agency wallet
    commission_bp: int = 0           # agency commission in basis points of the fares
    contact_mobile: Optional[str] = None

    async def wallet(self, conn: asyncpg.Connection, currency: str) -> asyncpg.Record:
        if self.agency_id:
            return await company_wallet(conn, self.agency_id, currency, label="Agency wallet")
        return await user_wallet(conn, self.party_id, currency)


def round_unit(amount: float) -> int:
    """Rounds to a whole currency unit (100 minor units)."""
    return int(round(amount / 100.0)) * 100


def commission_for(fares_total: int, commission_bp: int) -> int:
    """Agency commission, rounded down to a whole currency unit so it never exceeds the agreed rate."""
    return (fares_total * commission_bp // 10000) // 100 * 100


def refund_pct(rules: dict, hours_left: float) -> int:
    """Refund schedule from the fare brand snapshot: [[min_hours, percent], ...]."""
    if not rules.get("refundable", False):
        return 0
    for min_hours, pct in sorted(rules.get("refund", []), key=lambda x: -x[0]):
        if hours_left >= min_hours:
            return int(pct)
    return 0


def _json(v):
    return json.loads(v) if isinstance(v, str) else v


async def create_hold(conn: asyncpg.Connection, user_id: int, body: HoldIn) -> dict:
    if body.to_seq <= body.from_seq or len(set(body.seat_nos)) != len(body.seat_nos):
        raise ApiError(422, "INVALID_HOLD", "invalid pair or duplicate seats")
    trip = await repo.trip_on_sale_from(conn, body.trip_uid, body.from_seq)
    if trip is None or body.to_seq > trip["segments_count"]:
        raise ApiError(409, "SALES_CLOSED", "the trip is not on sale for this stop")
    if await repo.seats_held_by(conn, user_id) + len(body.seat_nos) > MAX_LOCKED_SEATS:
        raise ApiError(429, "TOO_MANY_HOLDS", "too many seats on hold")
    token = uuid.uuid4()
    locked = await repo.lock_segments(conn, trip["id"], body.seat_nos, body.from_seq, body.to_seq, token, user_id,
                                      trip["hold_min"])
    if len(locked) != len(body.seat_nos) * (body.to_seq - body.from_seq):
        raise ApiError(409, "SEAT_TAKEN", "one of the seats is no longer available")
    return {"trip_id": trip["id"], "hold_token": str(token), "expires_at": locked[0]["lock_expires_at"].isoformat()}


async def release_hold(conn: asyncpg.Connection, user_id: int, token: uuid.UUID) -> int:
    return await repo.release_segments(conn, token, user_id)


@dataclass
class Traveller:
    """One passenger of a booking request, with the identity resolved from a family member when one is named."""
    index: int                      # 1-based position on the booking
    nationality: str
    first_name: str
    father_name: Optional[str]
    grandfather_name: Optional[str]
    last_name: str
    seat_no: Optional[int]
    id_type: Optional[str]
    id_no: Optional[str]
    id_last4: Optional[str]
    passport_expiry: Optional[date]
    birth_date: Optional[date]
    gender: Optional[str]
    mobile: Optional[str]
    claimed: Optional[str]
    with_adult: Optional[int]
    member: Optional[asyncpg.Record] = None
    category: str = "ADULT"
    fare: int = 0

    @property
    def full_name(self) -> str:
        return " ".join(p for p in (self.first_name, self.father_name, self.grandfather_name, self.last_name) if p)


async def travellers(conn: asyncpg.Connection, ctx: db.Context, body: BookingIn, membership: Optional[fam.Membership]) -> list[Traveller]:
    """The passengers as booked; a family member's stored identity replaces whatever the form sent for them."""
    out, seen = [], set()
    for i, p in enumerate(body.passengers, start=1):
        t = Traveller(i, p.nationality, p.first_name, p.father_name, p.grandfather_name, p.last_name, p.seat_no, p.id_type, p.id_no,
                      p.id_last4, p.passport_expiry, p.birth_date, p.gender, p.mobile, p.category, p.with_adult)
        if p.family_member_uid:
            if membership is None:
                raise ApiError(404, "NOT_IN_FAMILY", "this traveller is not a member of your family")
            if p.family_member_uid in seen:
                raise ApiError(422, "DUPLICATE_MEMBER", "a family member is booked twice")
            seen.add(p.family_member_uid)
            async with db.system_scope(conn, ctx):
                m = await conn.fetchrow(
                    "SELECT * FROM iam.family_member WHERE family_id = $1 AND uid = $2 AND status = 'ACTIVE'",
                    membership.family["id"], p.family_member_uid)
                if m is None:
                    raise ApiError(404, "NOT_IN_FAMILY", "this traveller is not a member of your family")
                if membership.role == "MEMBER" and m["id"] != membership.member["id"]:
                    raise ApiError(403, "FAMILY_HEAD_ONLY", "only the head books for other family members")
                doc = await fam.member_document(conn, m) if not p.id_no else None
            t.member = m
            # the register is the source; a name part it lacks (the head's own record, built from the account) comes from the form
            t.nationality, t.first_name, t.father_name = m["nationality"], m["first_name"], m["father_name"] or p.father_name
            t.grandfather_name, t.last_name = m["grandfather_name"] or p.grandfather_name, m["last_name"]
            t.birth_date, t.gender = m["birth_date"], m["gender"] or p.gender
            t.mobile = p.mobile or m["mobile"]
            if doc:
                t.id_type, t.id_no, t.passport_expiry = m["id_type"], doc, m["passport_expiry"]
        out.append(t)
    return out


async def price(conn: asyncpg.Connection, trip: asyncpg.Record, body: BookingIn, buyer: Buyer, people: list[Traveller],
                travel: date) -> dict:
    """Fare of every traveller by category (4.19), the carrier's family offer, and the totals.

    An infant on a lap has no seat and pays the infant fare; an infant given a seat pays the child fare. Children and
    infants whose band needs an adult cannot travel without one, and each adult carries at most max_per_adult lap infants.
    """
    brand = await conn.fetchrow(
        "SELECT code, name, factor, rules FROM pricing.fare_brand WHERE code = $1 AND active", body.fare_brand)
    if brand is None:
        raise ApiError(422, "UNKNOWN_FARE_BRAND", "unknown fare brand")
    pair = await repo.pair_price(conn, trip["id"], body.from_seq, body.to_seq)
    adult_fare = round_unit(pair * float(brand["factor"]))
    b = await cat.bands(conn, trip["company_id"])
    for t in people:
        t.category = cat.category_for(b, t.birth_date, travel, t.claimed)
        if t.seat_no is None:
            infant = b.get("INFANT")
            if t.category != "INFANT" or infant is None or infant.seat_required:
                raise ApiError(422, "SEAT_REQUIRED", f"passenger {t.index} needs a seat", passenger=t.index)
    adults = [t for t in people if t.category == "ADULT"]
    if not adults and any(b[t.category].needs_adult for t in people if t.category in b):
        raise ApiError(422, "ADULT_REQUIRED", "children and infants travel with an adult on the same booking")
    laps = [t for t in people if t.seat_no is None]
    if laps:
        per = b["INFANT"].max_per_adult or 1
        load = {a.index: 0 for a in adults}
        for t in laps:
            if t.with_adult is None:
                t.with_adult = next((i for i, n in load.items() if n < per), None)
                if t.with_adult is None:
                    raise ApiError(422, "TOO_MANY_LAP_INFANTS", f"one adult carries at most {per} infant(s) on the lap")
            if t.with_adult not in load:
                raise ApiError(422, "LAP_ADULT_INVALID", "an infant on a lap must be carried by an adult on this booking", passenger=t.index)
            load[t.with_adult] += 1
            if load[t.with_adult] > per:
                raise ApiError(422, "TOO_MANY_LAP_INFANTS", f"one adult carries at most {per} infant(s) on the lap")
    for t in people:
        charged = "CHILD" if t.category == "INFANT" and t.seat_no is not None and "CHILD" in b else t.category
        t.fare = await cat.category_fare(conn, trip["company_id"], trip["route_id"], charged, adult_fare, travel, trip["currency"])
    gross = sum(t.fare for t in people)
    family = [t for t in people if t.member is not None]
    offer = None
    if len(family) >= 2:
        fa = sum(t.category == "ADULT" for t in family)
        offer = await cat.family_offer(conn, trip["company_id"], trip["route_id"], "TICKETS", travel, len(family), fa,
                                       len(family) - fa, sum(t.fare for t in family), len(family))
    discount = offer.discount if offer else 0
    if discount:                                  # spread over the family's tickets so each ticket keeps its own fare
        left = discount
        fam_fares = sum(t.fare for t in family)
        for k, t in enumerate(family):
            cut = left if k == len(family) - 1 else (discount * t.fare // fam_fares) // 100 * 100 if fam_fares else 0
            cut = min(cut, t.fare)
            t.fare -= cut
            left -= cut
    fares_total = sum(t.fare for t in people)
    fee = get_settings().platform_fee
    commission = commission_for(fares_total, buyer.commission_bp)
    breakdown = {"pair_price": pair, "fare_brand": brand["code"], "factor": float(brand["factor"]), "fare_per_passenger": adult_fare,
                 "passengers": len(people),
                 "lines": [{"passenger": t.index, "category": t.category, "seat": t.seat_no is not None, "fare": t.fare} for t in people],
                 "fares_gross": gross, "fares_total": fares_total, "platform_fee": fee, "total": fares_total + fee,
                 "currency": trip["currency"]}
    if offer:
        breakdown["family_offer"] = {"code": offer.code, "name": offer.name, "discount": discount}
    if buyer.agency_id:
        breakdown["agency_commission"] = commission     # funded by the carrier; the traveller pays the same price
    return {"brand": brand, "rules": _json(brand["rules"]), "fares_total": fares_total, "fee": fee, "commission": commission,
            "total": fares_total + fee, "breakdown": breakdown, "offer": offer}


async def quote(conn: asyncpg.Connection, ctx: db.Context, body: BookingIn, buyer: Buyer) -> dict:
    """The price of a booking request before paying, with the line of every traveller."""
    trip = await conn.fetchrow(
        "SELECT id, company_id, currency, trip_no, route_id FROM ops.trip WHERE uid = $1 AND status IN ('PUBLISHED','BOARDING')",
        body.trip_uid)
    if trip is None:
        raise not_found("trip")
    m = await fam.membership(conn, buyer.party_id) if not buyer.agency_id else None
    people = await travellers(conn, ctx, body, m)
    travel = await _travel_date(conn, trip["id"], body.from_seq)
    return (await price(conn, trip, body, buyer, people, travel))["breakdown"]


async def _travel_date(conn: asyncpg.Connection, trip_id: int, seq: int) -> date:
    return await conn.fetchval(
        "SELECT (sched_dep AT TIME ZONE 'Asia/Damascus')::date FROM ops.trip_stop WHERE trip_id = $1 AND seq = $2", trip_id, seq)


async def create_booking(conn: asyncpg.Connection, ctx: db.Context, buyer: Buyer, body: BookingIn,
                         before_payment=None) -> dict:
    """Books held seats and pays from the buyer's wallet in one transaction.

    before_payment(conn, total) lets a channel add its own checks (an agency's daily limit) once the price is known.
    A family head may pay from the family trips account; a linked family member's own booking is paid the way the
    head chose for them, within the member's limits and travel rules (4.20).
    """
    existing = await conn.fetchval(
        "SELECT booking_ref FROM sales.booking WHERE booker_party_id = $1 AND idempotency_key = $2",
        buyer.party_id, body.idempotency_key)
    if existing:
        return {"booking_ref": existing, "replayed": True}

    trip = await conn.fetchrow(
        "SELECT id, company_id, currency, trip_no, route_id FROM ops.trip WHERE uid = $1 AND status IN ('PUBLISHED','BOARDING')",
        body.trip_uid)
    if trip is None:
        raise not_found("trip")
    if buyer.agency_id and any(p.family_member_uid for p in body.passengers):
        raise ApiError(422, "FAMILY_NOT_AT_AGENCY", "family members are booked from the passenger's own account")
    membership = await fam.membership(conn, buyer.party_id) if not buyer.agency_id else None
    people = await travellers(conn, ctx, body, membership)
    departs = await _travel_date(conn, trip["id"], body.from_seq)
    q = await price(conn, trip, body, buyer, people, departs)
    seated = [t.seat_no for t in people if t.seat_no is not None]
    if set(seated) != await repo.held_seats(conn, trip["id"], body.hold_token, buyer.user_id, body.from_seq, body.to_seq) \
            or len(set(seated)) != len(seated):
        raise ApiError(409, "HOLD_EXPIRED", "the seat hold has expired; choose seats again")

    # International segments: every passenger needs a document accepted at each border crossed (11.9)
    reqs: dict = {}
    doc_issues = []
    for t in people:
        if t.nationality not in reqs:
            reqs[t.nationality] = await documents.requirement(conn, trip["id"], body.from_seq, body.to_seq, t.nationality, departs)
        r = reqs[t.nationality]
        codes = documents.check(r, t.id_type, t.id_no, t.passport_expiry, departs)
        documents.enforce(r, [(t.index, codes)])
        doc_issues.append(codes)

    total = q["total"]
    if before_payment:
        await before_payment(conn, total)

    # Who pays (4.20): the buyer, the family trips account, or the head's wallet for a linked member
    funding, member_payer = "OWN", None
    if membership and membership.role == "HEAD" and body.pay_from == "FAMILY_ACCOUNT":
        funding = "FAMILY_ACCOUNT"
    elif membership and membership.role == "MEMBER" and membership.member["funding"] != "OWN":
        funding, member_payer = membership.member["funding"], membership.member
        stops = await conn.fetchrow(
            """SELECT a.sched_dep, sa.city_id AS from_city, sb.city_id AS to_city
                 FROM ops.trip_stop a JOIN net.station sa ON sa.id = a.station_id, ops.trip_stop z JOIN net.station sb ON sb.id = z.station_id
                WHERE a.trip_id = $1 AND a.seq = $2 AND z.trip_id = $1 AND z.seq = $3""", trip["id"], body.from_seq, body.to_seq)
        await fam.check_rules(conn, member_payer, fam.Journey(stops["sched_dep"], stops["from_city"], stops["to_city"]))
        await fam.check_limits(conn, member_payer, total)
    elif body.pay_from == "FAMILY_ACCOUNT":
        raise ApiError(409, "NO_FAMILY_ACCOUNT", "only the family head pays from the family trips account")
    if funding == "OWN":
        wallet = await buyer.wallet(conn, trip["currency"])
    else:
        async with db.system_scope(conn, ctx):
            wallet = await fam.funding_wallet(conn, membership.family, funding, trip["currency"])
    available = wallet["balance"] - wallet["hold_balance"]      # money held for a pending withdrawal is not spendable
    if available < total:
        raise ApiError(402, "INSUFFICIENT_BALANCE", "wallet balance is not enough", required=total, balance=available)
    family_id = membership.family["id"] if membership and (funding != "OWN" or any(t.member for t in people)) else None

    channel_id = await conn.fetchval("SELECT id FROM sales.channel WHERE code = $1", buyer.channel)
    ref = booking_ref()
    while await conn.fetchval("SELECT 1 FROM sales.booking WHERE booking_ref = $1", ref):
        ref = booking_ref()
    booking_id = await conn.fetchval(
        """INSERT INTO sales.booking (booking_ref, trip_id, company_id, booker_party_id, booker_user_id, channel_id,
             status, pay_method, currency, total_amount, price_breakdown, rules_version, idempotency_key,
             agency_id, contact_mobile, family_id, funded_by_party_id, funding_source)
           VALUES ($1, $2, $3, $4, $5, $6, 'PENDING_PAYMENT', 'WALLET', $7, $8, $9::jsonb, 'v1', $10, $11, $12, $13, $14, $15)
           RETURNING id""",
        ref, trip["id"], trip["company_id"], buyer.party_id, buyer.user_id, channel_id, trip["currency"], total,
        json.dumps(q["breakdown"]), body.idempotency_key, buyer.agency_id, buyer.contact_mobile, family_id,
        membership.family["head_party_id"] if funding != "OWN" else None, funding if family_id else None)

    async with db.system_scope(conn, ctx):
        fc = await crypto.cipher(conn)
        pids: dict[int, int] = {}
        for t in sorted(people, key=lambda x: x.seat_no is None):       # adults and seated travellers first, lap infants last
            enc = bidx = key_id = None
            masked = t.id_last4
            if t.id_no:
                sealed = fc.encrypt(t.id_no, "sales.passenger.id_no")
                enc, key_id = sealed.ciphertext, sealed.key_id
                bidx = fc.blind_index(t.id_no, f"{t.id_type}:{t.nationality}")
                masked = crypto.last4(t.id_no)
            pid = await conn.fetchval(
                """INSERT INTO sales.passenger (booking_id, full_name, first_name, father_name, grandfather_name,
                     last_name, nationality, id_type, id_no_last4, mobile, id_no_enc, id_no_bidx, enc_key_id,
                     passport_expiry, passport_country, passenger_category, birth_date, gender, party_id, family_member_id,
                     accompanied_by_passenger_id)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21) RETURNING id""",
                booking_id, t.full_name, t.first_name, t.father_name, t.grandfather_name, t.last_name,
                t.nationality, t.id_type, masked, t.mobile, enc, bidx, key_id,
                t.passport_expiry if t.id_type == "PASSPORT" else None, t.nationality if t.id_type == "PASSPORT" else None,
                t.category, t.birth_date, t.gender, t.member["party_id"] if t.member else None, t.member["id"] if t.member else None,
                pids.get(t.with_adult) if t.seat_no is None else None)
            pids[t.index] = pid
            tid = await conn.fetchval(
                """INSERT INTO sales.ticket (ticket_no, booking_id, passenger_id, trip_id, from_seq, to_seq, seat_no,
                     fare_brand_code, fare_amount, total_amount, rules_snapshot)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9, $10::jsonb) RETURNING id""",
                ticket_no(ref, t.index), booking_id, pid, trip["id"], body.from_seq, body.to_seq, t.seat_no,
                q["brand"]["code"], t.fare, json.dumps({"brand": q["brand"]["code"], **q["rules"], "category": t.category}))
            r = reqs[t.nationality]
            if r.international:
                await conn.execute(
                    """INSERT INTO sales.ticket_doc (ticket_id, entry_rule_id, dest_country, passport_expiry, doc_type, exception,
                         status, issues, source)
                       VALUES ($1, $2, $3, $4, $5, $6, 'PENDING', $7::jsonb, $8)""",
                    tid, r.destination_rule_id, r.destination, t.passport_expiry if t.id_type == "PASSPORT" else None, t.id_type,
                    t.id_type is not None and t.id_type != "PASSPORT", json.dumps(doc_issues[t.index - 1]),
                    "AGENT" if buyer.agency_id else "PASSENGER")
            if t.seat_no is not None:
                await conn.execute(
                    """UPDATE ops.seat_segment SET status = 'SOLD', ticket_id = $4, lock_token = NULL,
                         lock_user_id = NULL, lock_expires_at = NULL
                       WHERE trip_id = $1 AND seat_no = $2 AND lock_token = $3""",
                    trip["id"], t.seat_no, body.hold_token, tid)

        # Price allocation (5.7): every leaf waits in escrow until the trip completes
        platform = await platform_wallet(conn, "PLATFORM", trip["currency"])
        escrow = await platform_wallet(conn, "ESCROW", trip["currency"])
        carrier = await company_wallet(conn, trip["company_id"], trip["currency"])
        alloc_id = await conn.fetchval(
            """INSERT INTO fin.price_allocation (subject_type, subject_id, booking_id, currency, total, rules_version)
               VALUES ('BOOKING', $1, $1, $2, $3, 'v1') RETURNING id""", booking_id, trip["currency"], total)
        lines = [("CARRIER_FARE", "FARE", trip["company_id"], "PER_TICKET", q["fares_total"] - q["commission"], carrier["id"]),
                 ("PLATFORM_FEE", "FEE", platform["owner_party_id"], "PER_BOOKING", q["fee"], platform["id"])]
        if buyer.agency_id:
            lines.append(("AGENCY_COMMISSION", "COMMISSION", buyer.agency_id, "PERCENT_OF_FARE", q["commission"], wallet["id"]))
        await conn.executemany(
            """INSERT INTO fin.price_allocation_line (allocation_id, code, level, is_leaf, component_type,
                 beneficiary_party_id, basis, amount, wallet_id, release_event)
               VALUES ($1, $2, 1, true, $3, $4, $5, $6, $7, 'TRIP_COMPLETED')""",
            [(alloc_id, *line) for line in lines])
        await conn.execute("UPDATE sales.booking SET price_allocation_id = $2 WHERE id = $1", booking_id, alloc_id)

        pay_txn = await post_txn(conn, "BOOKING_PAY", trip["currency"], f"booking:{booking_id}:pay",
                       [(wallet["id"], "DR", total), (escrow["id"], "CR", total)],
                       ref_type="booking", ref_id=booking_id, user_id=buyer.user_id, memo=ref)
        if member_payer is not None:
            await fam.log_spend(conn, membership.family["id"], member_payer["id"], funding, total, trip["currency"], "booking",
                                booking_id, buyer.user_id, pay_txn)
        await conn.execute("UPDATE sales.booking SET status = 'CONFIRMED', confirmed_at = now() WHERE id = $1", booking_id)
        journey = await conn.fetchrow(
            """SELECT ca.code AS from_city, cb.code AS to_city,
                      to_char(a.sched_dep AT TIME ZONE 'Asia/Damascus', 'YYYY-MM-DD HH24:MI') AS departs_local
                 FROM ops.trip_stop a JOIN net.station sa ON sa.id = a.station_id JOIN ref.city ca ON ca.id = sa.city_id,
                      ops.trip_stop z JOIN net.station sb ON sb.id = z.station_id JOIN ref.city cb ON cb.id = sb.city_id
                WHERE a.trip_id = $1 AND a.seq = $2 AND z.trip_id = $1 AND z.seq = $3""", trip["id"], body.from_seq, body.to_seq)
        await emit(conn, "booking.confirmed", "booking", booking_id, {
            "booking_ref": ref, "trip_no": trip["trip_no"], **dict(journey), "passengers": len(people),
            "total_amount": total, "booker_user_id": buyer.user_id, "agency_id": buyer.agency_id,
            "contact_mobile": buyer.contact_mobile}, company_id=trip["company_id"])
    return {"booking_id": booking_id, "booking_ref": ref, "total": total, "currency": trip["currency"],
            "commission": q["commission"] if buyer.agency_id else None}


async def booking_view(conn: asyncpg.Connection, ctx: db.Context, b: asyncpg.Record) -> dict:
    """Booking with its tickets. Tickets print the first and last name; the full name stays for manifests."""
    from ...security import document_token
    async with db.system_scope(conn, ctx):
        tickets = await repo.tickets_of(conn, b["id"])
    booking = {k: b[k] for k in ("booking_ref", "status", "total_amount", "currency", "trip_no", "carrier_name")}
    booking["price_breakdown"] = _json(b["price_breakdown"])
    booking["created_at"] = b["created_at"].isoformat()
    booking["verify_token"] = document_token("booking", b["booking_ref"])
    if b.get("contact_mobile"):
        booking["contact_mobile"] = b["contact_mobile"]
    out = []
    for t in tickets:
        d = row_dict(t)
        d["rules_snapshot"] = _json(d["rules_snapshot"])
        d["ticket_name"] = ticket_name(d.pop("first_name"), d.pop("last_name"), d["full_name"])
        out.append(d)
    return {"booking": booking, "tickets": out}


async def offline_credential(conn: asyncpg.Connection, ctx: db.Context, ticket_uid: uuid.UUID) -> dict:
    """Signed credential for showing a ticket with no connection; the caller has already checked ownership."""
    from ...security import ticket_credential
    async with db.system_scope(conn, ctx):
        k = await conn.fetchrow(
            """SELECT k.uid, k.status, k.seat_no, k.from_seq, k.to_seq, t.uid AS trip_uid, t.arrival_at, t.trip_no,
                      p.first_name, p.last_name, p.full_name,
                      (SELECT s ->> 'label' FROM jsonb_array_elements(t.seat_map -> 'seats') s
                        WHERE (s ->> 'n')::int = k.seat_no) AS seat_label
                 FROM sales.ticket k JOIN ops.trip t ON t.id = k.trip_id JOIN sales.passenger p ON p.id = k.passenger_id
                WHERE k.uid = $1""", ticket_uid)
    if k is None:
        raise not_found("ticket")
    if k["status"] not in ("ISSUED", "BOARDED"):
        raise ApiError(409, "TICKET_NOT_VALID", "ticket is not valid for boarding")
    expires = int(k["arrival_at"].timestamp()) + 6 * 3600
    token = ticket_credential({"k": str(k["uid"]), "t": str(k["trip_uid"]), "s": k["seat_label"] or str(k["seat_no"]),
                               "n": ticket_name(k["first_name"], k["last_name"], k["full_name"]),
                               "a": k["from_seq"], "b": k["to_seq"], "x": expires})
    return {"credential": token, "valid_until": expires, "trip_no": k["trip_no"]}


async def cancel_booking(conn: asyncpg.Connection, ctx: db.Context, b: asyncpg.Record, buyer: Buyer,
                         reason: str = "CUSTOMER") -> dict:
    """Cancels a confirmed booking before boarding and refunds by the fare brand schedule to the buyer's wallet.

    Whatever is not refunded stays with the carrier as the cancellation fee. An agency keeps commission only on
    that retained part, in proportion, so the allocation still adds up to what is left in escrow.
    """
    if b["status"] != "CONFIRMED" or b["trip_status"] not in ("PUBLISHED",):
        raise ApiError(409, "CANNOT_CANCEL", "this booking can no longer be cancelled")
    async with db.system_scope(conn, ctx):
        tickets = await repo.tickets_for_cancel(conn, b["id"])
        if any(t["status"] != "ISSUED" for t in tickets):
            raise ApiError(409, "CANNOT_CANCEL", "a passenger has already boarded")
        now = datetime.now(timezone.utc)
        refund = 0
        fares = 0
        for t in tickets:
            hours = (t["sched_dep"] - now).total_seconds() / 3600
            refund += t["total_amount"] * refund_pct(_json(t["rules_snapshot"]), hours) // 100
            fares += t["total_amount"]
        await repo.mark_cancelled(conn, b["id"], reason)
        if refund > 0:
            escrow = await platform_wallet(conn, "ESCROW", b["currency"])
            family = None
            if b.get("funding_source") in ("HEAD_WALLET", "FAMILY_ACCOUNT"):    # back to whoever paid (4.20)
                family = await conn.fetchrow("SELECT * FROM iam.family WHERE id = $1", b["family_id"])
                wallet = await fam.funding_wallet(conn, family, b["funding_source"], b["currency"])
            else:
                wallet = await buyer.wallet(conn, b["currency"])
            txn = await post_txn(conn, "REFUND", b["currency"], f"booking:{b['id']}:refund",
                                 [(escrow["id"], "DR", refund), (wallet["id"], "CR", refund)],
                                 ref_type="booking", ref_id=b["id"], user_id=buyer.user_id, memo=b["booking_ref"])
            spent = await conn.fetchrow("SELECT member_id FROM iam.family_spend WHERE ref_type = 'booking' AND ref_id = $1", b["id"])
            if family and spent:
                await fam.log_spend(conn, family["id"], spent["member_id"], b["funding_source"], refund, b["currency"], "refund",
                                    b["id"], buyer.user_id, txn)
        commission = await conn.fetchval(
            "SELECT amount FROM fin.price_allocation_line WHERE allocation_id = $1 AND code = 'AGENCY_COMMISSION'",
            b["price_allocation_id"]) or 0
        # Commission kept = commission x retained / fares (rounded down); the carrier line absorbs the rest
        kept = commission * (fares - refund) // fares if fares else 0
        if commission:
            await repo.refund_allocation_line(conn, b["price_allocation_id"], "AGENCY_COMMISSION", commission - kept)
        await repo.refund_allocation_line(conn, b["price_allocation_id"], "CARRIER_FARE", refund - (commission - kept))
        await emit(conn, "booking.cancelled", "booking", b["id"], {
            "booking_ref": b["booking_ref"], "refund_amount": refund, "booker_user_id": b["booker_user_id"],
            "agency_id": b["agency_id"], "contact_mobile": b["contact_mobile"]}, company_id=b["company_id"])
    return {"ok": True, "refund": refund, "currency": b["currency"], "commission_kept": kept if commission else None}
