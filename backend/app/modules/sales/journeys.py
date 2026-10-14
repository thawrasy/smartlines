"""Journeys: one way, a round trip, or several places one after the other, booked together (owner's request, October
2026; migration 1121).

A journey is booked in one go and paid at once: one booking per trip, as before, each with its own tickets, rules and
refunds, sharing the journey's uid and numbered by leg. Every traveller takes a seat on every leg; the seats are given
side by side where the trip has them. A group larger than a booking (an agency's tourism group) is split into bookings
of the platform's seat limit (four unless it decides otherwise, 1122) on each leg, all of the same journey. If any leg cannot be booked (no seats, sales closed, not
enough money), nothing is: the whole journey is one transaction. The legs must follow each other in time. A baby on a
lap (with_adult naming the traveller who carries them) takes no seat and travels in the same booking as that traveller
on every leg; whether the carrier lets a baby travel on a lap is checked on each leg, as for a single booking.
"""
from __future__ import annotations

import json
import uuid
from typing import Awaitable, Callable, Literal, Optional

import asyncpg
from pydantic import BaseModel, Field, model_validator

from ...errors import ApiError
from . import repository as repo
from .models import MOBILE, BookingIn, HoldIn, PassengerIn
from .service import create_hold

MAX_LEGS = 6
GROUP_LIMIT = 60                     # the request's own bound; the agency's setting (agency.group.max_passengers) is lower


class JourneyLegIn(BaseModel):
    trip_uid: uuid.UUID
    from_seq: int = Field(ge=0, le=500)
    to_seq: int = Field(ge=1, le=500)


class JourneyIn(BaseModel):
    kind: Literal["ONE_WAY", "ROUND_TRIP", "MULTI_CITY"]
    legs: list[JourneyLegIn] = Field(min_length=1, max_length=MAX_LEGS)
    passengers: list[PassengerIn] = Field(min_length=1, max_length=GROUP_LIMIT)
    fare_brand: str = "STANDARD"
    idempotency_key: str = Field(min_length=8, max_length=60)
    # options paid at once or reserved for a cash payment; card, instalments and financing go booking by booking
    pay_with: Literal["WALLET", "PAY_LATER"] = "WALLET"

    @model_validator(mode="after")
    def _shape(self):
        n = len(self.legs)
        if (self.kind == "ONE_WAY" and n != 1) or (self.kind == "ROUND_TRIP" and n != 2) or (self.kind == "MULTI_CITY" and n < 2):
            raise ValueError("JOURNEY_SHAPE: one way has one trip, a round trip two, several places two to six")
        if any(leg.to_seq <= leg.from_seq for leg in self.legs):
            raise ValueError("INVALID_HOLD: each trip is booked from a stop to a later one")
        for i, p in enumerate(self.passengers, start=1):
            if p.with_adult is None:
                continue
            if p.with_adult == i or p.with_adult > len(self.passengers) or self.passengers[p.with_adult - 1].with_adult is not None:
                raise ValueError("JOURNEY_INFANT: a baby on a lap names a traveller of the journey with a seat, who carries them")
            if p.birth_date is None:
                raise ValueError("JOURNEY_INFANT: give the date of birth of a baby on a lap")
        return self

    @property
    def seated(self) -> int:
        """The travellers who take a seat: all but the babies on a lap."""
        return sum(p.with_adult is None for p in self.passengers)


class AgencyJourneyIn(JourneyIn):
    contact_mobile: str = Field(pattern=MOBILE)


async def _legs(conn: asyncpg.Connection, body: JourneyIn) -> list[asyncpg.Record]:
    """Each leg's trip, its boarding and arrival times and the free seats on its segment; the legs in order of travel."""
    out = []
    for i, leg in enumerate(body.legs, start=1):
        row = await conn.fetchrow(
            f"""SELECT t.id, t.uid, coalesce(a.sched_dep, t.departure_at) AS departs_at, coalesce(b.sched_arr, t.arrival_at) AS arrives_at,
                       ARRAY(SELECT s.seat_no FROM ops.seat_segment s WHERE s.trip_id = t.id AND s.seg >= $2 AND s.seg < $3
                              GROUP BY s.seat_no HAVING count(*) = $3 - $2 AND bool_and({repo.FREE_SEG})
                              ORDER BY s.seat_no) AS free
                  FROM ops.trip t
                  JOIN ops.trip_stop a ON a.trip_id = t.id AND a.seq = $2
                  JOIN ops.trip_stop b ON b.trip_id = t.id AND b.seq = $3
                 WHERE t.uid = $1 AND t.status IN ('PUBLISHED', 'BOARDING')""", leg.trip_uid, leg.from_seq, leg.to_seq)
        if row is None:
            raise ApiError(409, "SALES_CLOSED", f"trip {i} of the journey is not on sale for these stops", leg=i)
        if out and row["departs_at"] < out[-1]["arrives_at"]:
            raise ApiError(422, "JOURNEY_ORDER", f"trip {i} leaves before trip {i - 1} arrives", leg=i)
        if len(row["free"]) < body.seated:
            raise ApiError(409, "NOT_ENOUGH_SEATS", f"trip {i} has {len(row['free'])} seats left for {body.seated} travellers",
                           leg=i, seats_left=len(row["free"]))
        out.append(row)
    return out


async def book(conn: asyncpg.Connection, party_id: int, user_id: int, body: JourneyIn, per: int,
               sell: Callable[[BookingIn], Awaitable[dict]], extra: Optional[dict] = None) -> dict:
    """Books every leg for every traveller in one transaction: on each leg the travellers in bookings of at most per
    seats (the caller's seat limit), each seat held and then booked through the channel's own sale (sell), which
    prices, checks and pays it."""
    first_key = f"{body.idempotency_key}:1:1"
    done = await conn.fetchval("SELECT journey_uid FROM sales.booking WHERE booker_party_id = $1 AND idempotency_key = $2",
                               party_id, first_key)
    if done:                                                     # the same journey sent again: its bookings stand
        return {"journey_uid": done, "replayed": True}
    legs = await _legs(conn, body)
    journey = uuid.uuid4()
    # the travellers with a seat in bookings of per seats; a baby on a lap goes in the booking of the one who carries them
    seated = [i for i, p in enumerate(body.passengers) if p.with_adult is None]
    groups = [seated[i:i + per] for i in range(0, len(seated), per)]
    laps = {i: p.with_adult - 1 for i, p in enumerate(body.passengers) if p.with_adult is not None}
    booked = []
    for n, (leg, trip) in enumerate(zip(body.legs, legs), start=1):
        seats = list(trip["free"])
        for g, people in enumerate(groups, start=1):
            mine, seats = seats[:len(people)], seats[len(people):]
            hold = await create_hold(conn, user_id, HoldIn(trip_uid=leg.trip_uid, from_seq=leg.from_seq, to_seq=leg.to_seq,
                                                           seat_nos=mine), limit=per)
            travellers = [body.passengers[i].model_copy(update={"seat_no": s, "with_adult": None}) for i, s in zip(people, mine)]
            travellers += [body.passengers[i].model_copy(update={"seat_no": None, "with_adult": people.index(a) + 1})
                           for i, a in laps.items() if a in people]
            out = await sell(BookingIn(
                hold_token=uuid.UUID(hold["hold_token"]), trip_uid=leg.trip_uid, from_seq=leg.from_seq, to_seq=leg.to_seq,
                fare_brand=body.fare_brand, idempotency_key=f"{body.idempotency_key}:{n}:{g}", pay_with=body.pay_with,
                passengers=travellers, **(extra or {})))
            await conn.execute("UPDATE sales.booking SET journey_uid = $1, journey_kind = $2, journey_leg = $3 WHERE id = $4",
                               journey, body.kind, n, out["booking_id"])
            booked.append({"leg": n, "booking_ref": out["booking_ref"], "booking_id": out["booking_id"], "total": out["total"],
                           "currency": out["currency"], "status": out["status"], "pay_by": out.get("pay_by")})
    totals: dict[str, int] = {}
    for b in booked:
        totals[b["currency"]] = totals.get(b["currency"], 0) + b["total"]
    return {"journey_uid": journey, "kind": body.kind, "bookings": booked,
            "totals": [{"currency": c, "total": t} for c, t in totals.items()],
            "status": "CONFIRMED" if all(b["status"] == "CONFIRMED" for b in booked) else "PENDING_PAYMENT"}


async def view(conn: asyncpg.Connection, party_id: int, journey_uid: uuid.UUID) -> Optional[dict]:
    """The journey's bookings the booker holds, leg by leg, with each trip's way and times."""
    rows = await conn.fetch(
        f"""SELECT b.booking_ref, b.status, b.total_amount AS total, b.currency, b.journey_kind, b.journey_leg AS leg,
                   CASE WHEN b.status = 'PENDING_PAYMENT' THEN b.hold_expires_at END AS pay_by,
                   t.uid AS trip_uid, t.trip_no, t.trip_code, k.from_seq, k.to_seq,
                   (SELECT count(*) FROM sales.ticket x WHERE x.booking_id = b.id AND x.status <> 'CANCELLED') AS travellers,
                   {repo.JOURNEY_SQL.strip()}
              FROM sales.booking b JOIN ops.trip t ON t.id = b.trip_id
              JOIN LATERAL (SELECT min(from_seq) AS from_seq, max(to_seq) AS to_seq FROM sales.ticket WHERE booking_id = b.id) k ON true
             WHERE b.booker_party_id = $1 AND b.journey_uid = $2
             ORDER BY b.journey_leg, b.id""", party_id, journey_uid)
    if not rows:
        return None
    return {"journey_uid": journey_uid, "kind": rows[0]["journey_kind"],
            "bookings": [{k: (json.loads(r[k]) if k == "journey" and isinstance(r[k], str) else r[k])
                          for k in r.keys() if k != "journey_kind"} for r in rows]}
