"""A price for every station pair of a route, carrier classes and the state's price bands (owner's request N10,
migration 1164).

    Carrier
    GET  /api/carrier/routes/{uid}/fares        the route's stations and the price of every pair (from the matrix, else
                                                the fare ladder), with the band that holds when the state's bands are on
    PUT  /api/carrier/routes/{uid}/fares        {cells: [{from_seq, to_seq, price}]}: every pair priced; trips made from
                                                then on take the matrix
    Platform
    GET  /api/admin/carrier-classes             the classes, the carriers' classes and the bands; the bands switch
    POST /api/admin/carrier-classes             {code, name_en, name_ar, criteria}
    POST /api/admin/carrier-classes/assign      {company_uid, class_code, source_document, assigned_on, valid_until}
    POST /api/admin/price-bands                 {class_code, vehicle_type, min_per_km, max_per_km, valid_from, source_document}
    PUT  /api/admin/price-bands/settings        {enabled}

Prices are in the smallest unit of the currency (hundredths of a pound), as everywhere in the API.
"""
import uuid
from datetime import date
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_permission, require_portal
from ...errors import ApiError, not_found

carrier = APIRouter(prefix="/api/carrier/routes", tags=["fares"])
platform = APIRouter(prefix="/api/admin", tags=["fares"])


async def _route(conn: asyncpg.Connection, uid: uuid.UUID, company: int):
    r = await conn.fetchrow("SELECT id, code, company_id FROM net.route WHERE uid = $1 AND company_id = $2", uid, company)
    if r is None:
        raise not_found("route")
    return r


def _band_problem(band, price: int, km: Optional[float]) -> Optional[str]:
    """Why a price lies outside the band, per km; nothing when there is no band or no distance to measure."""
    if band is None or not km:
        return None
    per_km = price / km
    if band["min_per_km"] is not None and per_km < band["min_per_km"]:
        return "below"
    if band["max_per_km"] is not None and per_km > band["max_per_km"]:
        return "above"
    return None


async def pair_km(conn: asyncpg.Connection, route_id: int) -> dict[int, Optional[float]]:
    rows = await conn.fetch("SELECT seq, dist_from_origin_km FROM net.route_stop WHERE route_id = $1", route_id)
    return {r["seq"]: (float(r["dist_from_origin_km"]) if r["dist_from_origin_km"] is not None else None) for r in rows}


@carrier.get("/{uid}/fares")
async def fares(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    async with db.transaction(context_for(request, pr)) as conn:
        r = await _route(conn, uid, pr.company_id)
        stops = await conn.fetch(
            """SELECT rs.seq, rs.fare_from_origin, rs.dist_from_origin_km, s.code AS station_code, s.name AS station_name
                 FROM net.route_stop rs JOIN net.station s ON s.id = rs.station_id WHERE rs.route_id = $1 ORDER BY rs.seq""", r["id"])
        set_ = {(c["from_seq"], c["to_seq"]): c["price"] for c in await conn.fetch(
            "SELECT from_seq, to_seq, price FROM net.route_pair_fare WHERE route_id = $1", r["id"])}
        band = await conn.fetchrow("SELECT * FROM pricing.band_for($1, NULL, current_date) WHERE id IS NOT NULL", pr.company_id)
    ladder = {s["seq"]: s["fare_from_origin"] or 0 for s in stops}
    km = {s["seq"]: (float(s["dist_from_origin_km"]) if s["dist_from_origin_km"] is not None else None) for s in stops}
    cells = []
    for a in stops:
        for b in stops:
            if b["seq"] <= a["seq"]:
                continue
            i, j = a["seq"], b["seq"]
            dist = km[j] - km[i] if km[i] is not None and km[j] is not None else None
            price = set_.get((i, j), ladder[j] - ladder[i])
            cells.append({"from_seq": i, "to_seq": j, "price": price, "set": (i, j) in set_, "km": dist,
                          "band": _band_problem(band, price, dist)})
    return {"code": r["code"], "stops": [dict(s) for s in stops], "cells": cells,
            "band": {k: band[k] for k in ("min_per_km", "max_per_km", "currency")} if band else None}


class Cell(BaseModel):
    from_seq: int = Field(ge=0, le=99)
    to_seq: int = Field(ge=1, le=99)
    price: int = Field(ge=0, le=10**12)


class FaresIn(BaseModel):
    cells: list[Cell] = Field(min_length=1, max_length=2000)


@carrier.put("/{uid}/fares")
async def save_fares(uid: uuid.UUID, body: FaresIn, request: Request, pr: Principal = Depends(require_permission("trip.publish"))):
    async with db.transaction(context_for(request, pr)) as conn:
        r = await _route(conn, uid, pr.company_id)
        seqs = [x["seq"] for x in await conn.fetch("SELECT seq FROM net.route_stop WHERE route_id = $1 ORDER BY seq", r["id"])]
        wanted = {(a, b) for a in seqs for b in seqs if b > a}
        given = {(c.from_seq, c.to_seq): c.price for c in body.cells}
        if set(given) != wanted:
            raise ApiError(422, "FARE_MATRIX_INCOMPLETE", "price every pair of stations of the route, each once",
                           missing=len(wanted - set(given)), extra=len(set(given) - wanted))
        km = await pair_km(conn, r["id"])
        band = await conn.fetchrow("SELECT * FROM pricing.band_for($1, NULL, current_date) WHERE id IS NOT NULL", pr.company_id)
        outside = [f"{a}-{b}" for (a, b), p in given.items()
                   if _band_problem(band, p, (km[b] - km[a]) if km.get(a) is not None and km.get(b) is not None else None)]
        if outside:
            raise ApiError(422, "FARE_OUTSIDE_BAND", "prices outside the state's band for the carrier's class", pairs=outside[:20])
        # a pair inside a longer one that costs more is allowed, and reported
        dearer = [f"{a}-{b}" for (a, b), p in given.items() for (c, d), q in given.items() if c <= a and d >= b and (c, d) != (a, b) and p > q]
        await conn.executemany(
            """INSERT INTO net.route_pair_fare (route_id, from_seq, to_seq, price, updated_by) VALUES ($1, $2, $3, $4, $5)
               ON CONFLICT (route_id, from_seq, to_seq) DO UPDATE SET price = excluded.price, updated_by = excluded.updated_by""",
            [(r["id"], a, b, p, pr.user_id) for (a, b), p in given.items()])
        # the fare ladder from the origin follows the first row of the matrix
        await conn.executemany("UPDATE net.route_stop SET fare_from_origin = $3 WHERE route_id = $1 AND seq = $2",
                               [(r["id"], b, given[(seqs[0], b)]) for b in seqs[1:]])
    request.state.audit = {"action": "route.fares", "object_type": "route", "object_id": r["id"], "reason": f"{len(given)} pairs"}
    return {"pairs": len(given), "dearer_inside_longer": sorted(set(dearer))[:20]}


async def copy_to_trip(conn: asyncpg.Connection, route_id: int, trip_id: int, company_id: int, vehicle_id: int, on: date) -> None:
    """The route's matrix goes with each trip made from it (search and sales read ops.trip_pair_fare). With the state's
    bands on, a vehicle type with its own band refuses prices outside it."""
    cells = await conn.fetch("SELECT from_seq, to_seq, price FROM net.route_pair_fare WHERE route_id = $1", route_id)
    if not cells:
        return
    vehicle_type = await conn.fetchval("SELECT vehicle_type FROM fleet.vehicle WHERE id = $1", vehicle_id)
    band = await conn.fetchrow("SELECT * FROM pricing.band_for($1, $2, $3) WHERE id IS NOT NULL", company_id, vehicle_type, on)
    if band is not None and band["vehicle_type"] is not None:
        km = await pair_km(conn, route_id)
        outside = [f"{c['from_seq']}-{c['to_seq']}" for c in cells
                   if _band_problem(band, c["price"], (km[c["to_seq"]] - km[c["from_seq"]])
                                    if km.get(c["from_seq"]) is not None and km.get(c["to_seq"]) is not None else None)]
        if outside:
            raise ApiError(422, "FARE_OUTSIDE_BAND", "the route's prices are outside the state's band for this vehicle type", pairs=outside[:20])
    await conn.executemany("INSERT INTO ops.trip_pair_fare (trip_id, from_seq, to_seq, price) VALUES ($1, $2, $3, $4)",
                           [(trip_id, c["from_seq"], c["to_seq"], c["price"]) for c in cells])


# ------------------------------------------------------------------ platform: classes and bands
async def _admin(pr: Principal = Depends(require_permission("pricing.tax_commission"))) -> Principal:
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "wrong portal for this operation")
    return pr


@platform.get("/carrier-classes")
async def classes(request: Request, pr: Principal = Depends(_admin)):
    async with db.transaction(context_for(request, pr)) as conn:
        cls = await conn.fetch("SELECT code, name_en, name_ar, criteria, status FROM ref.carrier_class ORDER BY code")
        assigned = await conn.fetch(
            """SELECT p.uid AS company_uid, p.legal_name AS company, c.code AS class_code, a.source_document, a.assigned_on, a.valid_until,
                      a.assigned_at, u.email AS assigned_by, a.ended_at
                 FROM iam.carrier_class_assignment a JOIN iam.party p ON p.id = a.company_id JOIN ref.carrier_class c ON c.id = a.class_id
                 LEFT JOIN iam.app_user u ON u.id = a.assigned_by ORDER BY a.ended_at IS NOT NULL, p.legal_name, a.assigned_at DESC LIMIT 500""")
        bands = await conn.fetch(
            """SELECT b.id, c.code AS class_code, b.vehicle_type, b.currency, b.min_per_km, b.max_per_km, b.valid_from, b.source_document, b.status
                 FROM pricing.state_price_band b JOIN ref.carrier_class c ON c.id = b.class_id ORDER BY c.code, b.vehicle_type NULLS FIRST, b.valid_from DESC""")
        on = await conn.fetchval("SELECT coalesce((SELECT value = 'true'::jsonb FROM sys.setting WHERE key = 'pricing.state_bands'), false)")
    return {"enabled": on, "classes": [dict(r) for r in cls], "assignments": [dict(r) for r in assigned], "bands": [dict(r) for r in bands]}


class ClassIn(BaseModel):
    code: str = Field(pattern=r"^[A-Z0-9]{1,8}$")
    name_en: str = Field(min_length=1, max_length=120)
    name_ar: str = Field(min_length=1, max_length=120)
    criteria: Optional[str] = Field(default=None, max_length=2000)


@platform.post("/carrier-classes", status_code=201)
async def add_class(body: ClassIn, request: Request, pr: Principal = Depends(_admin)):
    async with db.transaction(context_for(request, pr)) as conn:
        await conn.execute(
            """INSERT INTO ref.carrier_class (code, name_en, name_ar, criteria) VALUES ($1, $2, $3, $4)
               ON CONFLICT (code) DO UPDATE SET name_en = excluded.name_en, name_ar = excluded.name_ar, criteria = excluded.criteria, status = 'ACTIVE'""",
            body.code, body.name_en.strip(), body.name_ar.strip(), body.criteria)
    request.state.audit = {"action": "pricing.class", "object_type": "carrier_class", "reason": body.code}
    return {"code": body.code}


class AssignIn(BaseModel):
    company_uid: uuid.UUID
    class_code: str = Field(pattern=r"^[A-Z0-9]{1,8}$")
    source_document: str = Field(min_length=3, max_length=300)
    assigned_on: Optional[date] = None
    valid_until: Optional[date] = None


@platform.post("/carrier-classes/assign", status_code=201)
async def assign(body: AssignIn, request: Request, pr: Principal = Depends(_admin)):
    async with db.transaction(context_for(request, pr)) as conn:
        company = await conn.fetchval("SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", body.company_uid)
        cls = await conn.fetchval("SELECT id FROM ref.carrier_class WHERE code = $1 AND status = 'ACTIVE'", body.class_code)
        if company is None or cls is None:
            raise not_found("carrier or class")
        await conn.execute("UPDATE iam.carrier_class_assignment SET ended_at = now() WHERE company_id = $1 AND ended_at IS NULL", company)
        await conn.execute(
            """INSERT INTO iam.carrier_class_assignment (company_id, class_id, source_document, assigned_on, valid_until, assigned_by)
               VALUES ($1, $2, $3, coalesce($4, current_date), $5, $6)""",
            company, cls, body.source_document.strip(), body.assigned_on, body.valid_until, pr.user_id)
    request.state.audit = {"action": "pricing.class_assign", "object_type": "company", "object_id": company, "reason": body.class_code}
    return {"class_code": body.class_code}


class BandIn(BaseModel):
    class_code: str = Field(pattern=r"^[A-Z0-9]{1,8}$")
    vehicle_type: Optional[Literal["COACH", "MINIBUS", "CITY_BUS", "VAN", "TRAIN_SET", "OTHER"]] = None
    min_per_km: Optional[int] = Field(default=None, ge=0)
    max_per_km: Optional[int] = Field(default=None, ge=0)
    valid_from: Optional[date] = None
    source_document: Optional[str] = Field(default=None, max_length=300)


@platform.post("/price-bands", status_code=201)
async def add_band(body: BandIn, request: Request, pr: Principal = Depends(_admin)):
    if body.min_per_km is None and body.max_per_km is None:
        raise ApiError(422, "BAND_EMPTY", "give a lowest or a highest price per km")
    if body.min_per_km is not None and body.max_per_km is not None and body.min_per_km > body.max_per_km:
        raise ApiError(422, "BAND_ORDER", "the lowest price per km is above the highest")
    async with db.transaction(context_for(request, pr)) as conn:
        cls = await conn.fetchval("SELECT id FROM ref.carrier_class WHERE code = $1", body.class_code)
        if cls is None:
            raise not_found("class")
        await conn.execute(
            """UPDATE pricing.state_price_band SET status = 'RETIRED'
                WHERE class_id = $1 AND vehicle_type IS NOT DISTINCT FROM $2 AND valid_from = coalesce($3, current_date) AND status = 'ACTIVE'""",
            cls, body.vehicle_type, body.valid_from)
        bid = await conn.fetchval(
            """INSERT INTO pricing.state_price_band (class_id, vehicle_type, min_per_km, max_per_km, valid_from, source_document, created_by)
               VALUES ($1, $2, $3, $4, coalesce($5, current_date), $6, $7) RETURNING id""",
            cls, body.vehicle_type, body.min_per_km, body.max_per_km, body.valid_from, body.source_document, pr.user_id)
    request.state.audit = {"action": "pricing.band", "object_type": "state_price_band", "object_id": bid, "reason": body.class_code}
    return {"id": bid}


class BandsSettingIn(BaseModel):
    enabled: bool


@platform.put("/price-bands/settings")
async def band_setting(body: BandsSettingIn, request: Request, pr: Principal = Depends(_admin)):
    async with db.transaction(context_for(request, pr)) as conn:
        await conn.execute("UPDATE sys.setting SET value = $1::jsonb WHERE key = 'pricing.state_bands'", "true" if body.enabled else "false")
    request.state.audit = {"action": "pricing.bands_switch", "object_type": "setting", "reason": str(body.enabled)}
    return {"enabled": body.enabled}
