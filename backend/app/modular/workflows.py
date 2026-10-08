"""Module workflows: the steps people take, beyond keeping records.

    Passenger
    GET  /api/w/subscriptions/plans              shuttle plans on sale
    POST /api/w/subscriptions                    buy a plan from the wallet: subscription and QR pass
    GET  /api/w/subscriptions/mine
    GET  /api/w/parcels/options                  services and stations for the send form
    POST /api/w/parcels/quote                    price of a parcel (zone and weight)
    POST /api/w/parcels                          send: shipment, first tracking event, payment from the wallet
    GET  /api/w/parcels/mine
    GET  /api/track/{tracking_no}                public tracking, without personal data
    GET  /api/w/taxi/cities                      cities with an approved meter tariff
    POST /api/w/taxi/estimate                    fare estimate from the city's meter tariff
    POST /api/w/taxi/requests                    request a taxi
    GET  /api/w/taxi/requests/mine
    POST /api/w/taxi/requests/{uid}/cancel
    GET  /api/w/rental/offers                    classes, prices and available cars at a branch for a period
    POST /api/w/rental/bookings                  book a car (the rental company confirms it)
    GET  /api/w/rental/bookings/mine
    POST /api/w/rental/bookings/{uid}/cancel
    POST /api/w/freight/requests                 post a load for carriers to bid on
    GET  /api/w/freight/requests/mine            my loads with their bids
    POST /api/w/freight/bids/{id}/accept         award the load: contract, other bids rejected

    Carrier
    GET  /api/w/freight/market                   open loads to bid on
    POST /api/w/freight/requests/{uid}/bid       bid on a load
    POST /api/w/freight/bids/{id}/withdraw

    Platform
    GET  /api/w/travel-rules                     document rules of international trips and the platform default
    POST /api/w/travel-rules                     draft a rule or an exception (other documents than a passport)
    POST /api/w/travel-rules/{id}/approve        second officer approves (four-eyes); replaces the active version
    POST /api/w/travel-rules/{id}/retire
    GET  /api/w/travel-rules/check               effective requirement for a destination and nationality

Rules are checked in the caller's own scope (row-level security decides what they can see); the bookkeeping the caller
may not touch directly (the operator's wallet, the inventory of passes) runs in the platform scope of the same
transaction, with the caller still recorded in the audit trail.
"""
import json
import math
import secrets
import uuid
from datetime import date, datetime, timedelta, timezone
from typing import Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from .. import db, markets
from ..deps import Principal, context_for, require_user
from ..errors import ApiError, not_found
from ..ledger import company_wallet, post_txn, user_wallet
from ..modules.notify.outbox import emit
from ..modules.sales import documents
from . import features

router = APIRouter(tags=["workflows"])
ROAD_FACTOR = 1.3            # straight line to road distance in Syrian cities


async def _ready(module: str, pr: Principal, *portals: str) -> None:
    if not await features.is_on(module):
        raise ApiError(404, "MODULE_DISABLED", f"module {module} is switched off")
    if portals and pr.portal not in portals:
        raise ApiError(403, "FORBIDDEN", "not available in this portal")


def _key(prefix: str, n: int = 8) -> str:
    return prefix + "".join(secrets.choice("0123456789") for _ in range(n))


async def _charge(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, company_id: int, amount: int, currency: str,
                  txn_type: str, idem: str, ref_type: str, memo: str) -> tuple[int, int]:
    """Moves amount from the caller's wallet to the operator's; returns (wallet id, ledger transaction id)."""
    async with db.system_scope(conn, ctx):
        wallet = await user_wallet(conn, pr.party_id, currency)
        available = wallet["balance"] - wallet["hold_balance"]
        if available < amount:
            raise ApiError(402, "INSUFFICIENT_BALANCE", "wallet balance is not enough", required=amount, balance=available)
        operator = await company_wallet(conn, company_id, currency)
        try:
            txn = await post_txn(conn, txn_type, currency, idem, [(wallet["id"], "DR", amount), (operator["id"], "CR", amount)],
                                 ref_type=ref_type, user_id=pr.user_id, memo=memo)
        except asyncpg.UniqueViolationError:
            raise ApiError(409, "DUPLICATE_REQUEST", "this payment was already made")
    return wallet["id"], txn


# ------------------------------------------------------------------ shuttle subscriptions

class BuyPlan(BaseModel):
    plan_id: int
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.get("/api/w/subscriptions/plans")
async def plans(request: Request, pr: Principal = Depends(require_user)):
    await _ready("shuttle_subscriptions", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT p.id, p.code, p.name, p.period_days, p.rides_limit, p.passenger_category, p.price, p.currency,
                      c.legal_name AS operator, l.name AS line, z.name AS zone
                 FROM sales.subscription_plan p JOIN iam.party c ON c.id = p.company_id
                 LEFT JOIN net.line l ON l.id = p.line_id LEFT JOIN sales.shuttle_zone z ON z.id = p.zone_id
                WHERE p.status = 'ACTIVE' ORDER BY p.price""")
    return {"plans": [dict(r) for r in rows]}


@router.post("/api/w/subscriptions", status_code=201)
async def buy_plan(body: BuyPlan, request: Request, pr: Principal = Depends(require_user)):
    await _ready("shuttle_subscriptions", pr, "PASSENGER")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        plan = await conn.fetchrow("SELECT * FROM sales.subscription_plan WHERE id = $1 AND status = 'ACTIVE'", body.plan_id)
        if plan is None:
            raise not_found("plan")
        if await conn.fetchval(
                """SELECT 1 FROM sales.subscription WHERE plan_id = $1 AND party_id = $2 AND status = 'ACTIVE'
                    AND ends_on >= current_date""", plan["id"], pr.party_id):
            raise ApiError(409, "ALREADY_SUBSCRIBED", "you already have an active subscription to this plan")
        wallet_id, txn = await _charge(conn, ctx, pr, plan["company_id"], plan["price"], plan["currency"], "SUBSCRIPTION_PAY",
                                       f"subscription:{pr.party_id}:{body.idempotency_key}", "subscription", plan["code"])
        start = date.today()
        async with db.system_scope(conn, ctx):
            sub = await conn.fetchrow(
                """INSERT INTO sales.subscription (plan_id, company_id, party_id, wallet_id, starts_on, ends_on, price_paid,
                     currency, ledger_txn_id, status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'ACTIVE') RETURNING id, uid, starts_on, ends_on""",
                plan["id"], plan["company_id"], pr.party_id, wallet_id, start, start + timedelta(days=plan["period_days"] - 1),
                plan["price"], plan["currency"], txn)
            pass_no = _key("SP", 10)
            await conn.execute("INSERT INTO sales.shuttle_pass (subscription_id, pass_no, medium, status) VALUES ($1, $2, 'QR', 'ACTIVE')",
                               sub["id"], pass_no)
            await emit(conn, "subscription.activated", "subscription", sub["id"],
                       {"plan": plan["name"], "pass_no": pass_no, "ends_on": sub["ends_on"]}, company_id=plan["company_id"])
    return {"uid": str(sub["uid"]), "pass_no": pass_no, "starts_on": sub["starts_on"], "ends_on": sub["ends_on"]}


@router.get("/api/w/subscriptions/mine")
async def my_subscriptions(request: Request, pr: Principal = Depends(require_user)):
    await _ready("shuttle_subscriptions", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT s.uid, s.starts_on, s.ends_on, s.rides_used, s.price_paid, s.currency, s.status, p.name AS plan,
                      p.rides_limit, c.legal_name AS operator,
                      (SELECT pass_no FROM sales.shuttle_pass sp WHERE sp.subscription_id = s.id AND sp.status = 'ACTIVE' LIMIT 1) AS pass_no
                 FROM sales.subscription s JOIN sales.subscription_plan p ON p.id = s.plan_id JOIN iam.party c ON c.id = s.company_id
                WHERE s.party_id = $1 ORDER BY s.created_at DESC LIMIT 50""", pr.party_id)
    return {"subscriptions": [dict(r) | {"uid": str(r["uid"])} for r in rows]}


# ------------------------------------------------------------------ parcels

class ParcelIn(BaseModel):
    service_id: int
    origin_station_id: int
    dest_station_id: int
    weight_kg: float = Field(gt=0, le=1000)
    declared_value: int = Field(default=0, ge=0, le=10_000_000_000)


class SendParcel(ParcelIn):
    recipient_name: str = Field(min_length=3, max_length=120)
    recipient_mobile: str = Field(pattern=r"^\+?[0-9]{8,15}$")
    contents: Optional[str] = Field(default=None, max_length=200)
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.get("/api/w/parcels/options")
async def parcel_options(request: Request, pr: Principal = Depends(require_user)):
    await _ready("cargo", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        services = await conn.fetch(
            """SELECT s.id, s.code, s.name, s.max_weight_kg FROM ship.service_product s
                WHERE s.status = 'ACTIVE' AND EXISTS (SELECT 1 FROM ship.rate_table r WHERE r.service_id = s.id
                      AND r.status = 'PUBLISHED' AND r.valid @> current_date) ORDER BY s.id""")
        stations = await conn.fetch(
            """SELECT s.id, s.code, s.name, c.code AS city FROM net.station s JOIN ref.city c ON c.id = s.city_id
                WHERE s.status = 'ACTIVE' AND s.subtype <> 'BORDER' ORDER BY c.code, s.name""")
    return {"services": [dict(r) for r in services], "stations": [dict(r) for r in stations]}


async def _parcel_quote(conn: asyncpg.Connection, body: ParcelIn) -> dict:
    service = await conn.fetchrow("SELECT * FROM ship.service_product WHERE id = $1 AND status = 'ACTIVE'", body.service_id)
    if service is None:
        raise not_found("service")
    if service["max_weight_kg"] and body.weight_kg > float(service["max_weight_kg"]):
        raise ApiError(422, "TOO_HEAVY", f"this service takes parcels up to {service['max_weight_kg']} kg")
    if body.origin_station_id == body.dest_station_id:
        raise ApiError(422, "SAME_STATION", "origin and destination must differ")
    cities = await conn.fetch("SELECT id, city_id FROM net.station WHERE id = ANY($1::bigint[]) AND status = 'ACTIVE'",
                              [body.origin_station_id, body.dest_station_id])
    by_id = {r["id"]: r["city_id"] for r in cities}
    if len(by_id) != 2:
        raise not_found("station")
    o, d = by_id[body.origin_station_id], by_id[body.dest_station_id]
    zone = await conn.fetchval(
        """SELECT ch.price_zone FROM ship.pricing_zone_chart ch
             JOIN ship.geo_zone a ON a.id = ch.origin_zone_id JOIN ship.geo_zone b ON b.id = ch.dest_zone_id
            WHERE a.city_id = $1 AND b.city_id = $2 AND (ch.valid IS NULL OR ch.valid @> current_date) LIMIT 1""", o, d)
    table = await conn.fetchrow(
        """SELECT * FROM ship.rate_table WHERE service_id = $1 AND status = 'PUBLISHED' AND valid @> current_date
            ORDER BY company_id NULLS LAST, id LIMIT 1""", service["id"])
    if table is None:
        raise ApiError(409, "NO_RATES", "this service has no published prices")
    zones = [r["price_zone"] for r in await conn.fetch(
        "SELECT DISTINCT price_zone FROM ship.rate_table_entry WHERE rate_table_id = $1 ORDER BY 1", table["id"])]
    if not zones:
        raise ApiError(409, "NO_RATES", "this service has no published prices")
    if zone not in zones:              # no chart entry: same city is the nearest zone, other cities the middle one
        zone = zones[0] if o == d else zones[len(zones) // 2]
    entries = await conn.fetch(
        "SELECT * FROM ship.rate_table_entry WHERE rate_table_id = $1 AND price_zone = $2 ORDER BY weight_break", table["id"], zone)
    fit = next((e for e in entries if float(e["weight_break"]) >= body.weight_kg), None)
    if fit is not None:
        price = fit["price"]
    else:
        top = entries[-1]
        price = top["price"] + math.ceil(body.weight_kg - float(top["weight_break"])) * (top["per_kg_over"] or 0)
        fit = top
    price = max(price, fit["min_charge"] or 0)
    company = table["company_id"] or await conn.fetchval(
        "SELECT id FROM iam.company WHERE company_type = 'CARRIER' AND approval_status = 'APPROVED' ORDER BY id LIMIT 1")
    return {"price": int(price), "currency": table["currency"] or (await markets.of_party(conn, company)).currency, "zone": zone,
            "service": service["name"],
            "company_id": company, "rate_table_id": table["id"]}


@router.post("/api/w/parcels/quote")
async def parcel_quote(body: ParcelIn, request: Request, pr: Principal = Depends(require_user)):
    await _ready("cargo", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        q = await _parcel_quote(conn, body)
    return {k: q[k] for k in ("price", "currency", "zone", "service")}


@router.post("/api/w/parcels", status_code=201)
async def send_parcel(body: SendParcel, request: Request, pr: Principal = Depends(require_user)):
    await _ready("cargo", pr, "PASSENGER")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        q = await _parcel_quote(conn, body)
        _, txn = await _charge(conn, ctx, pr, q["company_id"], q["price"], q["currency"], "SHIPMENT_PAY",
                               f"parcel:{pr.party_id}:{body.idempotency_key}", "shipment", q["service"])
        async with db.system_scope(conn, ctx):
            for _ in range(5):
                tracking = _key("MS", 10)
                if not await conn.fetchval("SELECT 1 FROM ship.shipment WHERE tracking_no = $1", tracking):
                    break
            sid = await conn.fetchval(
                """INSERT INTO ship.shipment (tracking_no, company_id, shipper_party_id, service_id, shipper_type,
                     origin_station_id, dest_station_id, payer_type, declared_value, currency, billable_weight_kg,
                     price_breakdown, recipient_name, recipient_mobile, contents, status)
                   VALUES ($1, $2, $3, $4, 'INDIVIDUAL', $5, $6, 'SENDER', $7, $8, $9, $10::jsonb, $11, $12, $13, 'CREATED')
                   RETURNING id""",
                tracking, q["company_id"], pr.party_id, body.service_id, body.origin_station_id, body.dest_station_id,
                body.declared_value, q["currency"], body.weight_kg,
                json.dumps({"zone": q["zone"], "price": q["price"], "ledger_txn_id": txn}),
                body.recipient_name.strip(), body.recipient_mobile, body.contents)
            await conn.execute(
                "INSERT INTO ship.tracking_event (shipment_id, milestone, station_id, actor_user_id) VALUES ($1, 'CREATED', $2, $3)",
                sid, body.origin_station_id, pr.user_id)
            await emit(conn, "shipment.created", "shipment", sid, {"tracking_no": tracking, "price": q["price"]}, company_id=q["company_id"])
    return {"tracking_no": tracking, "price": q["price"], "currency": q["currency"]}


@router.get("/api/w/parcels/mine")
async def my_parcels(request: Request, pr: Principal = Depends(require_user)):
    await _ready("cargo", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT s.tracking_no, s.status, s.created_at, s.recipient_name, s.billable_weight_kg, sp.name AS service,
                      oa.name AS origin, da.name AS destination, oa.code AS origin_code, da.code AS destination_code,
                      (s.price_breakdown->>'price')::bigint AS price, s.currency
                 FROM ship.shipment s JOIN ship.service_product sp ON sp.id = s.service_id
                 LEFT JOIN net.station oa ON oa.id = s.origin_station_id LEFT JOIN net.station da ON da.id = s.dest_station_id
                WHERE s.shipper_party_id = $1 ORDER BY s.created_at DESC LIMIT 50""", pr.party_id)
    return {"parcels": [dict(r) for r in rows]}


@router.get("/api/track/{tracking_no}")
async def track(tracking_no: str, request: Request):
    """Public tracking: status, places and times only."""
    if not (6 <= len(tracking_no) <= 40) or not tracking_no.replace("-", "").isalnum():
        raise not_found("shipment")
    if not await features.is_on("cargo"):
        raise ApiError(404, "MODULE_DISABLED", "module cargo is switched off")
    ctx = context_for(request, None)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            s = await conn.fetchrow(
                """SELECT s.id, s.tracking_no, s.status, s.created_at, s.eta, sp.name AS service, oa.name AS origin, da.name AS destination,
                          oa.code AS origin_code, da.code AS destination_code
                     FROM ship.shipment s JOIN ship.service_product sp ON sp.id = s.service_id
                     LEFT JOIN net.station oa ON oa.id = s.origin_station_id LEFT JOIN net.station da ON da.id = s.dest_station_id
                    WHERE s.tracking_no = $1""", tracking_no.upper())
            if s is None:
                raise not_found("shipment")
            events = await conn.fetch(
                """SELECT e.milestone, e.ts, st.name AS place, st.code AS place_code FROM ship.tracking_event e
                     LEFT JOIN net.station st ON st.id = e.station_id WHERE e.shipment_id = $1 ORDER BY e.ts DESC, e.id DESC""", s["id"])
    return {**{k: s[k] for k in ("tracking_no", "status", "created_at", "eta", "service", "origin", "destination", "origin_code",
                                    "destination_code")},
            "events": [dict(e) for e in events]}


# ------------------------------------------------------------------ taxi

class TaxiTrip(BaseModel):
    city_id: int
    pickup_lat: float = Field(ge=29, le=38)
    pickup_lng: float = Field(ge=34, le=43)
    dropoff_lat: float = Field(ge=29, le=38)
    dropoff_lng: float = Field(ge=34, le=43)


class TaxiRequest(TaxiTrip):
    pickup_text: str = Field(min_length=2, max_length=160)
    dropoff_text: str = Field(min_length=2, max_length=160)
    seats: int = Field(default=1, ge=1, le=7)
    kind: str = Field(default="INSTANT", pattern="^(INSTANT|ADVANCE)$")
    requested_for: Optional[datetime] = None


def _km(a_lat, a_lng, b_lat, b_lng) -> float:
    r = 6371.0
    p1, p2 = math.radians(a_lat), math.radians(b_lat)
    dp, dl = p2 - p1, math.radians(b_lng - a_lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(math.sqrt(h))


async def _taxi_estimate(conn: asyncpg.Connection, body: TaxiTrip) -> dict:
    tariff = await conn.fetchrow(
        """SELECT * FROM taxi.meter_tariff WHERE city_id = $1 AND status = 'ACTIVE' AND valid @> current_date
            ORDER BY version DESC LIMIT 1""", body.city_id)
    if tariff is None:
        raise ApiError(409, "NO_TARIFF", "taxis are not available in this city yet")
    km = round(_km(body.pickup_lat, body.pickup_lng, body.dropoff_lat, body.dropoff_lng) * ROAD_FACTOR, 1)
    if km < 0.3:
        raise ApiError(422, "TOO_SHORT", "pickup and drop-off are too close")
    if km > 80:
        raise ApiError(422, "TOO_FAR", "city taxis cover trips up to 80 km")
    fare = tariff["flag_fall"] + round(tariff["per_km"] * km)
    fare = max(fare, tariff["min_fare"] or 0)
    fare = int(math.ceil(fare / 50000) * 50000)          # nearest 500 pounds up
    return {"km": km, "minutes": max(5, round(km * 2.4)), "fare": fare,
            "currency": tariff["currency"] or (await markets.default(conn)).currency}


@router.get("/api/w/taxi/cities")
async def taxi_cities(request: Request, pr: Principal = Depends(require_user)):
    await _ready("taxi", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT DISTINCT c.id, c.code, c.lat, c.lng FROM taxi.meter_tariff t JOIN ref.city c ON c.id = t.city_id
                WHERE t.status = 'ACTIVE' AND t.valid @> current_date ORDER BY c.code""")
    return {"cities": [dict(r) for r in rows]}


@router.post("/api/w/taxi/estimate")
async def taxi_estimate(body: TaxiTrip, request: Request, pr: Principal = Depends(require_user)):
    await _ready("taxi", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _taxi_estimate(conn, body)


@router.post("/api/w/taxi/requests", status_code=201)
async def taxi_request(body: TaxiRequest, request: Request, pr: Principal = Depends(require_user)):
    await _ready("taxi", pr, "PASSENGER")
    if body.kind == "ADVANCE":
        now = datetime.now(timezone.utc)
        if body.requested_for is None or not (now + timedelta(minutes=20) <= body.requested_for <= now + timedelta(days=7)):
            raise ApiError(422, "BAD_TIME", "book between 20 minutes and 7 days ahead")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        est = await _taxi_estimate(conn, body)
        if await conn.fetchval("SELECT count(*) FROM taxi.ride_request WHERE rider_user_id = $1 AND status = 'SEARCHING'", pr.user_id) >= 2:
            raise ApiError(409, "TOO_MANY_REQUESTS", "you already have requests looking for a driver")
        async with db.system_scope(conn, ctx):
            r = await conn.fetchrow(
                """INSERT INTO taxi.ride_request (rider_user_id, kind, city_id, pickup_lat, pickup_lng, pickup_text, dropoff_lat,
                     dropoff_lng, dropoff_text, requested_for, seats, fare_estimate, currency, status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, coalesce($10, now()), $11, $12, $13, 'SEARCHING')
                   RETURNING uid, created_at""",
                pr.user_id, body.kind, body.city_id, body.pickup_lat, body.pickup_lng, body.pickup_text.strip(), body.dropoff_lat,
                body.dropoff_lng, body.dropoff_text.strip(), body.requested_for, body.seats, est["fare"], est["currency"])
    return {"uid": str(r["uid"]), "status": "SEARCHING", **est}


@router.get("/api/w/taxi/requests/mine")
async def my_taxi_requests(request: Request, pr: Principal = Depends(require_user)):
    await _ready("taxi", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT r.uid, r.kind, r.pickup_text, r.dropoff_text, r.requested_for, r.seats, r.fare_estimate, r.currency,
                      r.status, r.created_at, c.code AS city, rd.status AS ride_status, rd.fare
                 FROM taxi.ride_request r JOIN ref.city c ON c.id = r.city_id
                 LEFT JOIN taxi.ride rd ON rd.request_id = r.id
                WHERE r.rider_user_id = $1 ORDER BY r.created_at DESC LIMIT 30""", pr.user_id)
    return {"requests": [dict(r) | {"uid": str(r["uid"])} for r in rows]}


@router.post("/api/w/taxi/requests/{uid}/cancel")
async def cancel_taxi(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_user)):
    await _ready("taxi", pr, "PASSENGER")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        r = await conn.fetchrow("SELECT id, status FROM taxi.ride_request WHERE uid = $1 AND rider_user_id = $2 FOR UPDATE", uid, pr.user_id)
        if r is None:
            raise not_found("request")
        if r["status"] not in ("SEARCHING", "ASSIGNED"):
            raise ApiError(409, "INVALID_STATE", "this request can no longer be cancelled")
        async with db.system_scope(conn, ctx):
            await conn.execute("UPDATE taxi.ride_request SET status = 'CANCELLED' WHERE id = $1", r["id"])
    return {"status": "CANCELLED"}


# ------------------------------------------------------------------ car rental

class RentalBooking(BaseModel):
    rate_id: int
    pickup_branch_id: int
    return_branch_id: Optional[int] = None
    starts_at: datetime
    ends_at: datetime


def _days(a: datetime, b: datetime) -> int:
    return max(1, math.ceil((b - a).total_seconds() / 86400))


def _rate_total(rate, days: int) -> int:
    per = {"DAY": 1, "WEEK": 7, "MONTH": 30}[rate["unit"]]
    return int(math.ceil(days / per) * rate["price"])


@router.get("/api/w/rental/offers")
async def rental_offers(request: Request, branch_id: Optional[int] = None, starts_at: Optional[datetime] = None,
                        ends_at: Optional[datetime] = None, pr: Principal = Depends(require_user)):
    await _ready("car_rental", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        branches = await conn.fetch(
            """SELECT b.id, s.name AS station, s.code AS station_code, c.code AS city, rc.brand, b.branch_type FROM rent.rental_branch b
                 JOIN net.station s ON s.id = b.station_id JOIN ref.city c ON c.id = s.city_id
                 JOIN rent.rental_company rc ON rc.company_id = b.company_id
                WHERE b.status = 'ACTIVE' AND rc.status = 'ACTIVE' ORDER BY c.code, s.name""")
        offers = []
        if branch_id and starts_at and ends_at:
            if ends_at <= starts_at:
                raise ApiError(422, "BAD_PERIOD", "return must be after pickup")
            days = _days(starts_at, ends_at)
            branch = await conn.fetchrow("SELECT * FROM rent.rental_branch WHERE id = $1 AND status = 'ACTIVE'", branch_id)
            if branch is None:
                raise not_found("branch")
            rows = await conn.fetch(
                """SELECT DISTINCT ON (r.rental_class) r.*, k.name AS class_name, k.sort,
                          (SELECT count(*) FROM rent.rental_fleet f WHERE f.company_id = r.company_id AND f.rental_class = r.rental_class
                             AND f.status = 'AVAILABLE' AND (f.home_branch_id IS NULL OR f.home_branch_id = $2)) AS available
                     FROM rent.rental_rate r JOIN rent.rental_vehicle_class k ON k.code = r.rental_class
                    WHERE r.company_id = $1 AND r.status = 'ACTIVE' AND r.valid @> $3::date AND (r.branch_id IS NULL OR r.branch_id = $2)
                    ORDER BY r.rental_class, r.branch_id NULLS LAST, r.price""", branch["company_id"], branch_id, starts_at.date())
            for r in sorted(rows, key=lambda x: x["sort"] or 0):
                offers.append({"rate_id": r["id"], "rental_class": r["rental_class"], "class_name": r["class_name"], "unit": r["unit"],
                               "price": r["price"], "total": _rate_total(r, days), "days": days, "deposit": r["deposit_amount"] or 0,
                               "km_per_day": r["km_included_per_day"], "available": r["available"],
                               "currency": r["currency"] or (await markets.of_party(conn, branch["company_id"])).currency})
    return {"branches": [dict(b) for b in branches], "offers": offers}


@router.post("/api/w/rental/bookings", status_code=201)
async def book_rental(body: RentalBooking, request: Request, pr: Principal = Depends(require_user)):
    await _ready("car_rental", pr, "PASSENGER")
    now = datetime.now(timezone.utc)
    if body.ends_at <= body.starts_at or body.starts_at < now - timedelta(minutes=5) or body.starts_at > now + timedelta(days=180):
        raise ApiError(422, "BAD_PERIOD", "pick a period starting in the next 180 days")
    if _days(body.starts_at, body.ends_at) > 90:
        raise ApiError(422, "TOO_LONG", "online bookings are up to 90 days")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        rate = await conn.fetchrow("SELECT * FROM rent.rental_rate WHERE id = $1 AND status = 'ACTIVE'", body.rate_id)
        branch = await conn.fetchrow("SELECT * FROM rent.rental_branch WHERE id = $1 AND status = 'ACTIVE'", body.pickup_branch_id)
        if rate is None or branch is None or branch["company_id"] != rate["company_id"]:
            raise not_found("offer")
        back = body.return_branch_id or body.pickup_branch_id
        if not await conn.fetchval("SELECT 1 FROM rent.rental_branch WHERE id = $1 AND company_id = $2 AND status = 'ACTIVE'",
                                   back, rate["company_id"]):
            raise not_found("return branch")
        total = _rate_total(rate, _days(body.starts_at, body.ends_at))
        async with db.system_scope(conn, ctx):
            b = await conn.fetchrow(
                """INSERT INTO rent.rental_booking (company_id, renter_party_id, rental_class, rate_id, pickup_branch_id,
                     return_branch_id, period, quoted_total, currency, status)
                   VALUES ($1, $2, $3, $4, $5, $6, tstzrange($7, $8), $9, $10, 'PENDING') RETURNING id, uid""",
                rate["company_id"], pr.party_id, rate["rental_class"], rate["id"], body.pickup_branch_id, back,
                body.starts_at, body.ends_at, total, rate["currency"] or (await markets.of_party(conn, rate["company_id"])).currency)
            await emit(conn, "rental.requested", "rental_booking", b["id"], {"class": rate["rental_class"], "total": total},
                       company_id=rate["company_id"])
    return {"uid": str(b["uid"]), "status": "PENDING", "quoted_total": total, "deposit": rate["deposit_amount"] or 0}


@router.get("/api/w/rental/bookings/mine")
async def my_rentals(request: Request, pr: Principal = Depends(require_user)):
    await _ready("car_rental", pr, "PASSENGER")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT b.uid, b.rental_class, k.name AS class_name, lower(b.period) AS starts_at, upper(b.period) AS ends_at,
                      b.quoted_total, b.currency, b.status, rc.brand, s.name AS pickup, s.code AS pickup_code
                 FROM rent.rental_booking b JOIN rent.rental_vehicle_class k ON k.code = b.rental_class
                 JOIN rent.rental_company rc ON rc.company_id = b.company_id
                 JOIN rent.rental_branch br ON br.id = b.pickup_branch_id JOIN net.station s ON s.id = br.station_id
                WHERE b.renter_party_id = $1 ORDER BY b.created_at DESC LIMIT 30""", pr.party_id)
    return {"bookings": [dict(r) | {"uid": str(r["uid"])} for r in rows]}


@router.post("/api/w/rental/bookings/{uid}/cancel")
async def cancel_rental(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_user)):
    await _ready("car_rental", pr, "PASSENGER")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        b = await conn.fetchrow("SELECT id, status FROM rent.rental_booking WHERE uid = $1 AND renter_party_id = $2 FOR UPDATE",
                                uid, pr.party_id)
        if b is None:
            raise not_found("booking")
        if b["status"] not in ("PENDING", "CONFIRMED"):
            raise ApiError(409, "INVALID_STATE", "this booking can no longer be cancelled")
        async with db.system_scope(conn, ctx):
            await conn.execute("UPDATE rent.rental_booking SET status = 'CANCELLED' WHERE id = $1", b["id"])
    return {"status": "CANCELLED"}


# ------------------------------------------------------------------ freight marketplace

class FreightIn(BaseModel):
    origin_station_id: int
    dest_station_id: int
    cargo_category: str = Field(pattern="^(GENERAL|FOOD|REFRIGERATED|LIQUID|LIVESTOCK|VEHICLES|CONTAINERS|OTHER)$")
    cargo_description: str = Field(min_length=3, max_length=300)
    declared_weight_kg: float = Field(gt=0, le=60000)
    packages: Optional[int] = Field(default=None, gt=0, le=10000)
    required_trailer_type: Optional[str] = Field(default=None, pattern="^(FLATBED|CURTAIN|REEFER|TANKER|CONTAINER_CHASSIS|LOWBED|TIPPER|BOX)$")
    pickup_from: datetime
    pickup_to: datetime
    target_price: Optional[int] = Field(default=None, ge=0)


class BidIn(BaseModel):
    price: int = Field(gt=0, le=100_000_000_000)
    valid_hours: int = Field(default=48, ge=1, le=168)
    truck_vehicle_id: Optional[int] = None


@router.post("/api/w/freight/requests", status_code=201)
async def post_freight(body: FreightIn, request: Request, pr: Principal = Depends(require_user)):
    await _ready("freight", pr, "PASSENGER", "OPERATOR")
    now = datetime.now(timezone.utc)
    if not (now - timedelta(hours=1) <= body.pickup_from < body.pickup_to <= now + timedelta(days=60)):
        raise ApiError(422, "BAD_WINDOW", "the pickup window must be in the next 60 days")
    if body.origin_station_id == body.dest_station_id:
        raise ApiError(422, "SAME_STATION", "origin and destination must differ")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        if await conn.fetchval("SELECT count(*) FROM net.station WHERE id = ANY($1::bigint[]) AND status = 'ACTIVE'",
                               [body.origin_station_id, body.dest_station_id]) != 2:
            raise not_found("station")
        async with db.system_scope(conn, ctx):     # the new row is only visible to the policy after the statement
            r = await conn.fetchrow(
                """INSERT INTO frt.freight_request (shipper_party_id, shipper_company_id, origin_station_id, dest_station_id,
                     cargo_category, cargo_description, declared_weight_kg, packages, required_trailer_type, pickup_window,
                     mode, target_price, currency, status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, tstzrange($10, $11), 'BID', $12, $13, 'OPEN') RETURNING id, uid""",
                pr.party_id, pr.company_id if pr.portal == "OPERATOR" else None, body.origin_station_id, body.dest_station_id,
                body.cargo_category, body.cargo_description.strip(), body.declared_weight_kg, body.packages,
                body.required_trailer_type, body.pickup_from, body.pickup_to, body.target_price,
                (await markets.of_party(conn, pr.company_id if pr.portal == "OPERATOR" else pr.party_id)).currency)
            await emit(conn, "freight.request_opened", "freight_request", r["id"], {"weight_kg": body.declared_weight_kg})
    return {"uid": str(r["uid"]), "status": "OPEN"}


_REQUEST_COLS = """r.id, r.uid, r.cargo_category, r.cargo_description, r.declared_weight_kg, r.packages, r.required_trailer_type,
       lower(r.pickup_window) AS pickup_from, upper(r.pickup_window) AS pickup_to, r.target_price, r.currency, r.status, r.created_at,
       os.name AS origin, ds.name AS destination, os.code AS origin_code, ds.code AS destination_code"""


@router.get("/api/w/freight/requests/mine")
async def my_freight(request: Request, pr: Principal = Depends(require_user)):
    await _ready("freight", pr, "PASSENGER", "OPERATOR")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            f"""SELECT {_REQUEST_COLS} FROM frt.freight_request r
                  LEFT JOIN net.station os ON os.id = r.origin_station_id LEFT JOIN net.station ds ON ds.id = r.dest_station_id
                 WHERE r.shipper_party_id = $1 ORDER BY r.created_at DESC LIMIT 30""", pr.party_id)
        bids = await conn.fetch(
            """SELECT b.id, b.request_id, b.price, b.currency, b.valid_until, b.status, b.created_at, c.legal_name AS carrier
                 FROM frt.freight_bid b JOIN iam.party c ON c.id = b.carrier_company_id
                WHERE b.request_id = ANY($1::bigint[]) ORDER BY b.price""", [r["id"] for r in rows])
    by_req: dict = {}
    for b in bids:
        by_req.setdefault(b["request_id"], []).append({k: b[k] for k in ("id", "price", "currency", "valid_until", "status", "created_at", "carrier")})
    return {"requests": [{k: (str(v) if k == "uid" else v) for k, v in dict(r).items() if k != "id"} | {"bids": by_req.get(r["id"], [])}
                         for r in rows]}


@router.post("/api/w/freight/bids/{bid_id}/accept")
async def accept_bid(bid_id: int, request: Request, pr: Principal = Depends(require_user)):
    await _ready("freight", pr, "PASSENGER", "OPERATOR")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        bid = await conn.fetchrow("SELECT * FROM frt.freight_bid WHERE id = $1", bid_id)
        if bid is None:
            raise not_found("bid")
        req = await conn.fetchrow("SELECT * FROM frt.freight_request WHERE id = $1 AND shipper_party_id = $2 FOR UPDATE",
                                  bid["request_id"], pr.party_id)
        if req is None:
            raise not_found("bid")
        if req["status"] != "OPEN":
            raise ApiError(409, "INVALID_STATE", "this load is no longer open")
        if bid["status"] != "SUBMITTED" or bid["valid_until"] < datetime.now(timezone.utc):
            raise ApiError(409, "BID_NOT_VALID", "this bid has expired or was withdrawn")
        async with db.system_scope(conn, ctx):
            await conn.execute("UPDATE frt.freight_bid SET status = 'REJECTED' WHERE request_id = $1 AND id <> $2 AND status = 'SUBMITTED'",
                               req["id"], bid["id"])
            await conn.execute("UPDATE frt.freight_bid SET status = 'ACCEPTED' WHERE id = $1", bid["id"])
            await conn.execute("UPDATE frt.freight_request SET status = 'AWARDED' WHERE id = $1", req["id"])
            contract = await conn.fetchrow(
                """INSERT INTO frt.freight_contract (request_id, carrier_company_id, accepted_bid_id, terms, price, currency, status)
                   VALUES ($1, $2, $3, $4::jsonb, $5, $6, 'DRAFT') RETURNING id, uid""",
                req["id"], bid["carrier_company_id"], bid["id"],
                json.dumps({"payment": "on delivery", "liability": "CMR", "source": "marketplace"}), bid["price"], bid["currency"])
            await emit(conn, "freight.bid_accepted", "freight_contract", contract["id"], {"price": bid["price"]},
                       company_id=bid["carrier_company_id"])
    return {"contract_uid": str(contract["uid"]), "price": bid["price"]}


@router.get("/api/w/freight/market")
async def freight_market(request: Request, pr: Principal = Depends(require_user)):
    await _ready("freight", pr, "OPERATOR")
    async with db.transaction(context_for(request, pr)) as conn:
        # the market view (16.26): open loads without the shipper's identity, addresses or contacts
        rows = await conn.fetch(
            """SELECT r.*, (SELECT jsonb_build_object('id', b.id, 'price', b.price, 'status', b.status, 'valid_until', b.valid_until)
                              FROM frt.freight_bid b WHERE b.request_id = r.id AND b.carrier_company_id = $1) AS my_bid
                 FROM frt.open_loads() r ORDER BY r.pickup_from LIMIT 100""", pr.company_id)
        trucks = await conn.fetch(
            """SELECT v.id, v.plate_no FROM fleet.truck_unit t JOIN fleet.vehicle v ON v.id = t.vehicle_id
                WHERE v.company_id = $1 AND v.status = 'ACTIVE' ORDER BY v.plate_no""", pr.company_id)
    return {"requests": [{k: (str(v) if k == "uid" else json.loads(v) if k == "my_bid" and v else v) for k, v in dict(r).items() if k != "id"}
                         for r in rows], "trucks": [dict(t) for t in trucks]}


@router.post("/api/w/freight/requests/{uid}/bid", status_code=201)
async def place_bid(uid: uuid.UUID, body: BidIn, request: Request, pr: Principal = Depends(require_user)):
    await _ready("freight", pr, "OPERATOR")
    if "freight.operate" not in pr.permissions:
        raise ApiError(403, "FORBIDDEN", "missing permission: freight.operate")
    async with db.transaction(context_for(request, pr)) as conn:
        req = await conn.fetchrow("SELECT id, currency FROM frt.open_loads() WHERE uid = $1", uid)
        if req is None:
            own = await conn.fetchval("SELECT 1 FROM frt.freight_request WHERE uid = $1 AND shipper_company_id = $2", uid, pr.company_id)
            if own:
                raise ApiError(409, "OWN_LOAD", "you cannot bid on your own load")
            raise ApiError(409, "INVALID_STATE", "this load is not open for bids")
        if body.truck_vehicle_id and not await conn.fetchval(
                "SELECT 1 FROM fleet.truck_unit t JOIN fleet.vehicle v ON v.id = t.vehicle_id WHERE t.vehicle_id = $1 AND v.company_id = $2",
                body.truck_vehicle_id, pr.company_id):
            raise not_found("truck")
        try:
            b = await conn.fetchrow(
                """INSERT INTO frt.freight_bid (request_id, carrier_company_id, truck_vehicle_id, price, currency, valid_until, status)
                   VALUES ($1, $2, $3, $4, $5, now() + make_interval(hours => $6), 'SUBMITTED') RETURNING id, valid_until""",
                req["id"], pr.company_id, body.truck_vehicle_id, body.price,
                req["currency"] or (await markets.of_party(conn, pr.company_id)).currency, body.valid_hours)
        except asyncpg.UniqueViolationError:
            raise ApiError(409, "ALREADY_BID", "your company already bid on this load")
    return {"id": b["id"], "valid_until": b["valid_until"], "status": "SUBMITTED"}


@router.post("/api/w/freight/bids/{bid_id}/withdraw")
async def withdraw_bid(bid_id: int, request: Request, pr: Principal = Depends(require_user)):
    await _ready("freight", pr, "OPERATOR")
    async with db.transaction(context_for(request, pr)) as conn:
        n = await conn.execute(
            "UPDATE frt.freight_bid SET status = 'WITHDRAWN' WHERE id = $1 AND carrier_company_id = $2 AND status = 'SUBMITTED'",
            bid_id, pr.company_id)
        if n.endswith(" 0"):
            raise ApiError(409, "INVALID_STATE", "only a submitted bid of your company can be withdrawn")
    return {"status": "WITHDRAWN"}


# ------------------------------------------------------------------ travel document rules (platform)

DOCS = ("PASSPORT", "NATIONAL_ID", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER")


class TravelRuleIn(BaseModel):
    country_code: str = Field(pattern=r"^[A-Z]{2}$")
    country_role: str = Field(default="DESTINATION", pattern="^(DESTINATION|TRANSIT)$")
    nationality: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}$")
    doc_required: list[str] = Field(min_length=1, max_length=6)
    passport_min_days: int = Field(default=180, ge=0, le=730)
    security_approval: bool = False
    enforcement: str = Field(default="BLOCK", pattern="^(BLOCK|ALLOW_PENDING)$")
    valid_from: Optional[date] = None
    valid_to: Optional[date] = None
    legal_basis: Optional[str] = Field(default=None, max_length=300)
    note: Optional[str] = Field(default=None, max_length=300)
    label: str = Field(min_length=3, max_length=120)


def _rule_manager(pr: Principal) -> None:
    if pr.portal != "PLATFORM" or "border.manage" not in pr.permissions:
        raise ApiError(403, "FORBIDDEN", "missing permission: border.manage")


_RULE_COLS = """r.id, r.country_code, r.country_role, r.nationality, r.doc_required, r.passport_min_days, r.security_approval,
       r.enforcement, lower(r.valid) AS valid_from, upper(r.valid) AS valid_to, r.legal_basis, r.note, r.label, r.version,
       r.status, r.created_at, cu.email AS created_by, au.email AS approved_by, (r.created_by = $1) AS mine"""


@router.get("/api/w/travel-rules")
async def travel_rules(request: Request, pr: Principal = Depends(require_user)):
    await _ready("international", pr, "PLATFORM")
    _rule_manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            f"""SELECT {_RULE_COLS} FROM sales.entry_rule r
                  LEFT JOIN iam.app_user cu ON cu.id = r.created_by LEFT JOIN iam.app_user au ON au.id = r.approved_by
                 ORDER BY (r.status = 'RETIRED'), r.country_code, r.country_role, r.nationality NULLS FIRST, r.version DESC""", pr.user_id)
        default = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'travel.international_default'")
        countries = await conn.fetch("SELECT code, name FROM ref.country WHERE is_active ORDER BY name")
    default = json.loads(default) if isinstance(default, str) else default
    return {"rules": [dict(r) for r in rows], "default": default or {"docs": ["PASSPORT"], "passport_min_days": 180},
            "countries": [dict(c) for c in countries]}


@router.post("/api/w/travel-rules", status_code=201)
async def add_travel_rule(body: TravelRuleIn, request: Request, pr: Principal = Depends(require_user)):
    await _ready("international", pr, "PLATFORM")
    _rule_manager(pr)
    docs = list(dict.fromkeys(body.doc_required))
    if any(d not in DOCS for d in docs):
        raise ApiError(422, "UNKNOWN_DOCUMENT", "unknown document type")
    exception = docs != ["PASSPORT"]
    if exception and len((body.legal_basis or "").strip()) < 5:
        raise ApiError(422, "LEGAL_BASIS_REQUIRED", "an exception must cite the agreement, decree or circular that allows it")
    if body.valid_from and body.valid_to and body.valid_to <= body.valid_from:
        raise ApiError(422, "BAD_PERIOD", "the end of the period must be after its start")
    if body.nationality == body.country_code and body.country_role == "TRANSIT":
        raise ApiError(422, "BAD_RULE", "a transit rule for the country's own citizens has no effect")
    async with db.transaction(context_for(request, pr)) as conn:
        version = await conn.fetchval(
            """SELECT coalesce(max(version), 0) + 1 FROM sales.entry_rule
                WHERE country_code = $1 AND country_role = $2 AND nationality IS NOT DISTINCT FROM $3""",
            body.country_code, body.country_role, body.nationality)
        rid = await conn.fetchval(
            """INSERT INTO sales.entry_rule (country_code, country_role, nationality, doc_required, security_approval, passport_min_days,
                 enforcement, valid, legal_basis, note, label, version, status, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, CASE WHEN $8::date IS NULL AND $9::date IS NULL THEN NULL ELSE daterange($8, $9) END,
                       $10, $11, $12, $13, 'DRAFT', $14) RETURNING id""",
            body.country_code, body.country_role, body.nationality, docs, body.security_approval, body.passport_min_days,
            body.enforcement, body.valid_from, body.valid_to, (body.legal_basis or "").strip() or None, (body.note or "").strip() or None,
            body.label.strip(), version, pr.user_id)
    request.state.audit = {"action": "entry_rule.create", "object_type": "sales.entry_rule", "reason": f"rule {rid} docs {','.join(docs)}"}
    return {"id": rid, "status": "DRAFT", "version": version, "exception": exception}


@router.post("/api/w/travel-rules/{rule_id}/approve")
async def approve_travel_rule(rule_id: int, request: Request, pr: Principal = Depends(require_user)):
    await _ready("international", pr, "PLATFORM")
    _rule_manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        r = await conn.fetchrow("SELECT * FROM sales.entry_rule WHERE id = $1 FOR UPDATE", rule_id)
        if r is None:
            raise not_found("rule")
        if r["status"] != "DRAFT":
            raise ApiError(409, "INVALID_STATE", "only a draft rule can be approved")
        if r["created_by"] == pr.user_id:
            raise ApiError(409, "FOUR_EYES", "someone other than the author must approve this rule")
        # the approved version replaces the active one for the same country, role and nationality
        await conn.execute(
            """UPDATE sales.entry_rule SET status = 'RETIRED' WHERE status = 'ACTIVE' AND id <> $1 AND country_code = $2
                AND country_role = $3 AND nationality IS NOT DISTINCT FROM $4""", r["id"], r["country_code"], r["country_role"], r["nationality"])
        await conn.execute("UPDATE sales.entry_rule SET status = 'ACTIVE', approved_by = $2 WHERE id = $1", r["id"], pr.user_id)
    request.state.audit = {"action": "entry_rule.approve", "object_type": "sales.entry_rule", "reason": f"rule {rule_id}"}
    return {"id": rule_id, "status": "ACTIVE"}


@router.post("/api/w/travel-rules/{rule_id}/retire")
async def retire_travel_rule(rule_id: int, request: Request, pr: Principal = Depends(require_user)):
    await _ready("international", pr, "PLATFORM")
    _rule_manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        n = await conn.execute("UPDATE sales.entry_rule SET status = 'RETIRED' WHERE id = $1 AND status IN ('DRAFT', 'ACTIVE')", rule_id)
        if n.endswith(" 0"):
            raise ApiError(409, "INVALID_STATE", "this rule is already retired")
    request.state.audit = {"action": "entry_rule.retire", "object_type": "sales.entry_rule", "reason": f"rule {rule_id}"}
    return {"id": rule_id, "status": "RETIRED"}


@router.get("/api/w/travel-rules/check")
async def check_travel_rule(request: Request, destination: str, nationality: str, origin: str = "SY", transit: str = "",
                            on: Optional[date] = None, pr: Principal = Depends(require_user)):
    """What a passenger of this nationality needs from origin to destination (through the transit countries) on a day."""
    await _ready("international", pr, "PLATFORM", "OPERATOR", "AGENCY")
    codes = [destination, nationality, origin, *[t for t in transit.split(",") if t]]
    if any(len(c) != 2 or not c.isalpha() or not c.isupper() for c in codes):
        raise ApiError(422, "BAD_COUNTRY", "countries are two-letter ISO codes")
    async with db.transaction(context_for(request, pr)) as conn:
        req = await documents.requirement_for(conn, origin, destination, [t for t in transit.split(",") if t], nationality,
                                              on or date.today())
    return req.public()
