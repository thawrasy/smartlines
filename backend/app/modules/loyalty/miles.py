"""The miles programme (owner's note 19, migration 1166).

    Passenger and public
    GET  /api/loyalty/programme                     the programme's name and unit, the tiers and the switches
    GET  /api/loyalty/miles?from=&to=               the miles a ticket between two stations earns (station codes)
    GET  /api/loyalty/corner                        the partners corner: active partners and their offers; a promoted
                                                    partner first and labelled, while promoted display is on
    GET  /api/loyalty/awards                        award tickets: miles, fee and reduced amount, and whether they can
                                                    be redeemed now

    Platform (loyalty.manage)
    GET  /api/admin/miles                           the programme, its tiers, the chart, the award tickets, the partners
    PUT  /api/admin/miles/programme                 {name, name_ar, unit_en, unit_ar, expiry_months}
    PUT  /api/admin/miles/tiers/{code}              {min_points, multiplier}
    POST /api/admin/miles/chart                     {from_station, to_station, miles, network_route_uid}: replaces the pair
    POST /api/admin/miles/chart/{id}/retire
    POST /api/admin/miles/awards                    {from_station, to_station, miles, fee, reduced_amount, company_uid, seats_per_trip}
    POST /api/admin/miles/awards/{uid}/retire
    PUT  /api/admin/miles/partners/{id}             {contract_ref, corner_note, promoted, promoted_until, status}
    PUT  /api/admin/miles/settings                  {award_redemption, promoted_display}

Amounts are in the smallest unit of the currency. In the first phase miles are earned and shown; redeeming an award
ticket waits for the money phase or an agreement with the carrier (loyalty.award_redemption off).
"""
from __future__ import annotations

import uuid
from datetime import date
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, base_context, context_for, require_permission
from ...errors import ApiError, not_found
from ...modular import features
from ...util import rows

public = APIRouter(prefix="/api/loyalty", tags=["loyalty"], dependencies=[features.require_module("loyalty")])
platform = APIRouter(prefix="/api/admin/miles", tags=["admin"], dependencies=[features.require_module("loyalty")])

def _public(request: Request) -> db.Context:
    ctx = base_context(request)
    ctx.scope = "PASSENGER"
    return ctx


SETTINGS = {"award_redemption": "loyalty.award_redemption", "promoted_display": "loyalty.promoted_display"}


async def _switch(conn: asyncpg.Connection, key: str) -> bool:
    return bool(await conn.fetchval("SELECT coalesce((SELECT value = 'true'::jsonb FROM sys.setting WHERE key = $1), false)", key))


async def _programme(conn: asyncpg.Connection):
    return await conn.fetchrow(
        """SELECT id, code, name, name_ar, unit_en, unit_ar, point_value, currency, expiry_months
             FROM pricing.loyalty_program WHERE status = 'ACTIVE' ORDER BY id LIMIT 1""")


async def _station(conn: asyncpg.Connection, code: str) -> int:
    sid = await conn.fetchval("SELECT id FROM net.station WHERE code = $1 AND status = 'ACTIVE'", code.strip().upper())
    if sid is None:
        raise not_found(f"station {code}")
    return sid


@public.get("/programme")
async def programme(request: Request):
    async with db.transaction(_public(request)) as conn:
        g = await _programme(conn)
        if g is None:
            return {"programme": None}
        tiers = await conn.fetch(
            """SELECT code, name, min_points, coalesce(benefits ->> 'multiplier', '1') AS multiplier FROM pricing.loyalty_tier
                WHERE program_id = $1 ORDER BY min_points, code""", g["id"])
        switches = {k: await _switch(conn, v) for k, v in SETTINGS.items()}
    return {"programme": {k: g[k] for k in ("code", "name", "name_ar", "unit_en", "unit_ar", "currency", "expiry_months")},
            "tiers": rows(tiers), **switches}


@public.get("/miles")
async def miles_between(request: Request, from_: str = Query(alias="from", min_length=3, max_length=30),
                        to: str = Query(min_length=3, max_length=30)):
    async with db.transaction(_public(request)) as conn:
        g = await _programme(conn)
        if g is None:
            return {"miles": None}
        a, b = await _station(conn, from_), await _station(conn, to)
        miles = await conn.fetchval("SELECT pricing.chart_miles($1, $2, $3, current_date)", g["id"], a, b)
    return {"miles": miles, "unit_en": g["unit_en"], "unit_ar": g["unit_ar"]}


@public.get("/corner")
async def corner(request: Request):
    async with db.transaction(_public(request)) as conn:
        promoted_on = await _switch(conn, SETTINGS["promoted_display"])
        found = await conn.fetch(
            """SELECT lp.id, p.legal_name AS name, lp.partner_type, lp.corner_note,
                      (lp.promoted AND (lp.promoted_until IS NULL OR lp.promoted_until >= current_date)) AS promoted,
                      a.points, a.amount, a.currency, a.min_points
                 FROM pricing.loyalty_partner lp JOIN iam.party p ON p.id = lp.party_id
                 LEFT JOIN pricing.loyalty_agreement a ON a.loyalty_partner_id = lp.id AND a.status = 'ACTIVE' AND a.valid @> current_date
                WHERE lp.status = 'ACTIVE' AND length(btrim(coalesce(lp.contract_ref, ''))) >= 3
                ORDER BY p.legal_name""")
    out = []
    for r in found:
        d = dict(r)
        d["promoted"] = bool(d["promoted"]) and promoted_on            # labelled only while the display is on
        out.append(d)
    out.sort(key=lambda d: not d["promoted"])                          # promoted first, then by name
    return {"promoted_display": promoted_on, "partners": out}


@public.get("/awards")
async def awards(request: Request):
    async with db.transaction(_public(request)) as conn:
        found = await conn.fetch(
            """SELECT f.uid, fs.code AS from_code, fs.name AS from_name, ts.code AS to_code, ts.name AS to_name, f.miles, f.fee,
                      f.reduced_amount, f.currency, p.legal_name AS carrier, f.seats_per_trip
                 FROM pricing.award_fare f JOIN net.station fs ON fs.id = f.from_station_id JOIN net.station ts ON ts.id = f.to_station_id
                 LEFT JOIN iam.party p ON p.id = f.company_id
                WHERE f.status = 'ACTIVE' AND f.valid @> current_date ORDER BY fs.code, ts.code""")
        redeemable = await _switch(conn, SETTINGS["award_redemption"])
    return {"redeemable": redeemable, "awards": rows(found)}


# ------------------------------------------------------------------ platform
staff = require_permission("loyalty.manage")


@platform.get("")
async def overview(request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        g = await _programme(conn)
        if g is None:
            raise not_found("active programme")
        tiers = await conn.fetch(
            """SELECT code, name, min_points, coalesce(benefits ->> 'multiplier', '1') AS multiplier FROM pricing.loyalty_tier
                WHERE program_id = $1 ORDER BY min_points, code""", g["id"])
        chart = await conn.fetch(
            """SELECT c.id, fs.code AS from_code, fs.name AS from_name, ts.code AS to_code, ts.name AS to_name, c.miles, nr.code AS network_route,
                      lower(c.valid) AS valid_from
                 FROM pricing.miles_chart c JOIN net.station fs ON fs.id = c.from_station_id JOIN net.station ts ON ts.id = c.to_station_id
                 LEFT JOIN net.network_route nr ON nr.id = c.network_route_id
                WHERE c.program_id = $1 AND c.status = 'ACTIVE' ORDER BY fs.code, ts.code""", g["id"])
        award_rows = await conn.fetch(
            """SELECT f.uid, fs.code AS from_code, ts.code AS to_code, f.miles, f.fee, f.reduced_amount, f.currency, p.legal_name AS carrier,
                      f.seats_per_trip FROM pricing.award_fare f JOIN net.station fs ON fs.id = f.from_station_id
                 JOIN net.station ts ON ts.id = f.to_station_id LEFT JOIN iam.party p ON p.id = f.company_id
                WHERE f.program_id = $1 AND f.status = 'ACTIVE' ORDER BY fs.code, ts.code""", g["id"])
        partner_rows = await conn.fetch(
            """SELECT lp.id, p.legal_name AS name, lp.partner_type, lp.status, lp.contract_ref, lp.corner_note, lp.promoted, lp.promoted_until
                 FROM pricing.loyalty_partner lp JOIN iam.party p ON p.id = lp.party_id WHERE lp.program_id = $1 ORDER BY p.legal_name""", g["id"])
        switches = {k: await _switch(conn, v) for k, v in SETTINGS.items()}
    return {"programme": {k: g[k] for k in ("code", "name", "name_ar", "unit_en", "unit_ar", "point_value", "currency", "expiry_months")},
            "tiers": rows(tiers), "chart": rows(chart), "awards": rows(award_rows), "partners": rows(partner_rows), **switches}


class ProgrammeIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    name_ar: str = Field(min_length=1, max_length=80)
    unit_en: str = Field(min_length=1, max_length=30)
    unit_ar: str = Field(min_length=1, max_length=30)
    expiry_months: int = Field(ge=1, le=120)


@platform.put("/programme")
async def set_programme(body: ProgrammeIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        g = await _programme(conn)
        if g is None:
            raise not_found("active programme")
        await conn.execute(
            "UPDATE pricing.loyalty_program SET name = $2, name_ar = $3, unit_en = $4, unit_ar = $5, expiry_months = $6 WHERE id = $1",
            g["id"], body.name.strip(), body.name_ar.strip(), body.unit_en.strip(), body.unit_ar.strip(), body.expiry_months)
    request.state.audit = {"action": "miles.programme", "object_type": "loyalty_program", "object_id": g["id"]}
    return {"ok": True}


class TierIn(BaseModel):
    min_points: int = Field(ge=0, le=10**9)
    multiplier: float = Field(ge=1, le=5)


@platform.put("/tiers/{code}")
async def set_tier(code: str, body: TierIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        g = await _programme(conn)
        tid = await conn.fetchval(
            """UPDATE pricing.loyalty_tier SET min_points = $3, benefits = benefits || jsonb_build_object('multiplier', $4::numeric)
                WHERE program_id = $1 AND code = $2 RETURNING id""", g["id"], code, body.min_points, round(body.multiplier, 2))
        if tid is None:
            raise not_found("tier")
    request.state.audit = {"action": "miles.tier", "object_type": "loyalty_tier", "object_id": tid}
    return {"ok": True}


class ChartIn(BaseModel):
    from_station: str = Field(min_length=3, max_length=30)
    to_station: str = Field(min_length=3, max_length=30)
    miles: int = Field(gt=0, le=100_000)
    network_route_uid: Optional[uuid.UUID] = None


@platform.post("/chart", status_code=201)
async def add_chart(body: ChartIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        g = await _programme(conn)
        a, b = await _station(conn, body.from_station), await _station(conn, body.to_station)
        if a == b:
            raise ApiError(422, "SAME_STATION", "a pair is two different stations")
        route = None
        if body.network_route_uid:
            route = await conn.fetchval("SELECT id FROM net.network_route WHERE uid = $1", body.network_route_uid)
            if route is None:
                raise not_found("route of the network")
        await conn.execute(
            """UPDATE pricing.miles_chart SET status = 'RETIRED' WHERE program_id = $1 AND status = 'ACTIVE'
                  AND least(from_station_id, to_station_id) = least($2::bigint, $3::bigint)
                  AND greatest(from_station_id, to_station_id) = greatest($2::bigint, $3::bigint)""", g["id"], a, b)
        cid = await conn.fetchval(
            """INSERT INTO pricing.miles_chart (program_id, network_route_id, from_station_id, to_station_id, miles, created_by)
               VALUES ($1, $2, $3, $4, $5, $6) RETURNING id""", g["id"], route, a, b, body.miles, pr.user_id)
    request.state.audit = {"action": "miles.chart", "object_type": "miles_chart", "object_id": cid}
    return {"id": cid}


@platform.post("/chart/{chart_id}/retire")
async def retire_chart(chart_id: int, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval("UPDATE pricing.miles_chart SET status = 'RETIRED' WHERE id = $1 AND status = 'ACTIVE' RETURNING id", chart_id)
        if done is None:
            raise not_found("chart row")
    request.state.audit = {"action": "miles.chart_retire", "object_type": "miles_chart", "object_id": chart_id}
    return {"status": "RETIRED"}


class AwardIn(BaseModel):
    from_station: str = Field(min_length=3, max_length=30)
    to_station: str = Field(min_length=3, max_length=30)
    miles: int = Field(gt=0, le=10**7)
    fee: int = Field(default=0, ge=0, le=10**12)
    reduced_amount: int = Field(default=0, ge=0, le=10**12)
    company_uid: Optional[uuid.UUID] = None
    seats_per_trip: Optional[int] = Field(default=None, ge=1, le=100)


@platform.post("/awards", status_code=201)
async def add_award(body: AwardIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        g = await _programme(conn)
        a, b = await _station(conn, body.from_station), await _station(conn, body.to_station)
        if a == b:
            raise ApiError(422, "SAME_STATION", "a pair is two different stations")
        company = None
        if body.company_uid:
            company = await conn.fetchval(
                "SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1 AND c.company_type = 'CARRIER'", body.company_uid)
            if company is None:
                raise not_found("carrier")
        uid = await conn.fetchval(
            """INSERT INTO pricing.award_fare (program_id, company_id, from_station_id, to_station_id, miles, fee, reduced_amount, currency,
                                               seats_per_trip, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING uid""",
            g["id"], company, a, b, body.miles, body.fee, body.reduced_amount, g["currency"], body.seats_per_trip, pr.user_id)
    request.state.audit = {"action": "miles.award", "object_type": "award_fare", "reason": f"{body.from_station}-{body.to_station}"}
    return {"uid": str(uid)}


@platform.post("/awards/{uid}/retire")
async def retire_award(uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval("UPDATE pricing.award_fare SET status = 'RETIRED' WHERE uid = $1 AND status = 'ACTIVE' RETURNING id", uid)
        if done is None:
            raise not_found("award ticket")
    request.state.audit = {"action": "miles.award_retire", "object_type": "award_fare", "object_id": done}
    return {"status": "RETIRED"}


class PartnerIn(BaseModel):
    contract_ref: Optional[str] = Field(default=None, max_length=120)
    corner_note: Optional[str] = Field(default=None, max_length=300)
    promoted: bool = False
    promoted_until: Optional[date] = None
    status: Optional[Literal["PENDING", "ACTIVE", "SUSPENDED", "ENDED"]] = None


@platform.put("/partners/{partner_id}")
async def set_partner(partner_id: int, body: PartnerIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        try:
            done = await conn.fetchval(
                """UPDATE pricing.loyalty_partner SET contract_ref = coalesce(nullif(btrim($2), ''), contract_ref), corner_note = $3,
                          promoted = $4, promoted_until = $5, status = coalesce($6, status)
                    WHERE id = $1 RETURNING id""", partner_id, body.contract_ref, body.corner_note, body.promoted, body.promoted_until, body.status)
        except asyncpg.RaiseError as exc:
            code, _, message = str(exc).partition(":")
            raise ApiError(422, code, message.strip()) from exc
        if done is None:
            raise not_found("partner")
    request.state.audit = {"action": "miles.partner", "object_type": "loyalty_partner", "object_id": partner_id}
    return {"ok": True}


class SettingsIn(BaseModel):
    award_redemption: Optional[bool] = None
    promoted_display: Optional[bool] = None


@platform.put("/settings")
async def set_settings(body: SettingsIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        for k, key in SETTINGS.items():
            v = getattr(body, k)
            if v is not None:
                await conn.execute("UPDATE sys.setting SET value = $2::jsonb WHERE key = $1", key, "true" if v else "false")
        out = {k: await _switch(conn, v) for k, v in SETTINGS.items()}
    request.state.audit = {"action": "miles.settings", "object_type": "setting", "reason": str(out)}
    return out
