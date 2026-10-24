"""Bays assigned by the station's administration (owner's decision, October 2026; migration 1115).

The platform names a station's administration: a station operating company (PUT /api/admin/boarding/stations/{uid},
manager_company_uid). The administration chooses how the station gives its bays: a permanent bay for each carrier,
which it changes when it needs to (CARRIER), or a bay for each trip (TRIP). A bay set on a trip comes first in either
mode. The counter's trips, the boarding pass and the departure board show the bay in force (brd.stop_bay_id). The
platform does the same where a station has no administration yet. The database checks who may (NOT_STATION_ADMIN).

    Station operating company (the STATION portal; owner or station.bays)
    GET /api/station/bays?station_uid=        the mode, the open bays, the carriers and their bay, three days of departures
    PUT /api/station/bays/mode                {station_uid, mode}
    PUT /api/station/bays/carriers            {station_uid, carrier_uid, bay}: the carrier's permanent bay, null removes it
    PUT /api/station/bays/trips               {trip_uid, stop_seq, bay}: the bay of one departure, null clears it

    Platform (boarding.manage): the same under /api/admin/boarding/stations/{station_uid}/bays
"""
import json
import uuid
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden

station = APIRouter(prefix="/api/station/bays", tags=["boarding"])
platform = APIRouter(prefix="/api/admin/boarding/stations", tags=["boarding"])

BAY = r"^[A-Z0-9-]{1,12}$"


class ModeIn(BaseModel):
    mode: Literal["CARRIER", "TRIP"]


class CarrierBayIn(BaseModel):
    carrier_uid: uuid.UUID
    bay: Optional[str] = Field(default=None, pattern=BAY)       # empty: the carrier has no permanent bay


class TripBayIn(BaseModel):
    trip_uid: uuid.UUID
    stop_seq: int = Field(ge=0, le=500)
    bay: Optional[str] = Field(default=None, pattern=BAY)       # empty: the trip's own bay is cleared


class StationModeIn(ModeIn):
    station_uid: uuid.UUID


class StationCarrierBayIn(CarrierBayIn):
    station_uid: uuid.UUID


def _bays_staff(pr: Principal) -> None:
    if pr.company_id is None or not (pr.is_owner or "station.bays" in pr.permissions):
        raise forbidden("missing permission: station.bays")


def _platform_staff(pr: Principal) -> None:
    if "boarding.manage" not in pr.permissions:
        raise forbidden("missing permission: boarding.manage")


async def _refused(call):
    """What the database refuses: not the station's administration (403), an unknown bay or carrier (422)."""
    try:
        return await call
    except asyncpg.RaiseError as exc:
        code = str(exc).split(":", 1)[0]
        if code == "NOT_STATION_ADMIN":
            raise ApiError(403, code, "only the station's administration assigns its bays") from exc
        if code in ("BAY_UNKNOWN", "NOT_A_CARRIER", "INVALID_SETTING"):
            raise ApiError(422, code, str(exc)) from exc
        raise


async def _station_id(conn, station_uid: uuid.UUID) -> int:
    sid = await conn.fetchval("SELECT id FROM net.station WHERE uid = $1", station_uid)
    if sid is None:
        raise ApiError(404, "NOT_FOUND", "station not found")
    return sid


async def _view(conn, station_uid: uuid.UUID) -> dict:
    return json.loads(await _refused(conn.fetchval("SELECT brd.station_bays($1)::text", await _station_id(conn, station_uid))))


async def _mode(conn, station_uid: uuid.UUID, mode: str) -> int:
    sid = await _station_id(conn, station_uid)
    await _refused(conn.fetchval("SELECT net.set_station_bay_mode($1, $2)", sid, mode))
    return sid


async def _carrier_bay(conn, station_uid: uuid.UUID, body: CarrierBayIn) -> Optional[str]:
    return await _refused(conn.fetchval("SELECT net.set_carrier_bay($1, $2, $3)", await _station_id(conn, station_uid),
                                        body.carrier_uid, body.bay))


async def _trip_bay(conn, body: TripBayIn) -> Optional[str]:
    return await _refused(conn.fetchval("SELECT brd.assign_trip_bay($1, $2, $3)", body.trip_uid, body.stop_seq, body.bay))


# ------------------------------------------------------------------ the station's administration
@station.get("")
async def station_bays(station_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _bays_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _view(conn, station_uid)


@station.put("/mode")
async def station_mode(body: StationModeIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _bays_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _mode(conn, body.station_uid, body.mode)
    request.state.audit = {"action": "boarding.bay_mode", "object_type": "station", "object_id": sid, "reason": body.mode}
    return {"mode": body.mode}


@station.put("/carriers")
async def station_carrier_bay(body: StationCarrierBayIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _bays_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        bay = await _carrier_bay(conn, body.station_uid, body)
    request.state.audit = {"action": "boarding.carrier_bay", "object_type": "station", "object_id": None,
                           "reason": f"carrier {body.carrier_uid}: {bay or 'none'}"}
    return {"carrier_uid": body.carrier_uid, "bay": bay}


@station.put("/trips")
async def station_trip_bay(body: TripBayIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _bays_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        bay = await _trip_bay(conn, body)
    request.state.audit = {"action": "boarding.trip_bay", "object_type": "trip", "object_id": None,
                           "reason": f"trip {body.trip_uid} stop {body.stop_seq}: {bay or 'none'}"}
    return {"trip_uid": body.trip_uid, "stop_seq": body.stop_seq, "bay": bay}


# ------------------------------------------------------------------ the platform, where a station has no administration yet
@platform.get("/{station_uid}/bays")
async def platform_bays(station_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _view(conn, station_uid)


@platform.put("/{station_uid}/bays/mode")
async def platform_mode(station_uid: uuid.UUID, body: ModeIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _mode(conn, station_uid, body.mode)
    request.state.audit = {"action": "boarding.bay_mode", "object_type": "station", "object_id": sid, "reason": body.mode}
    return {"mode": body.mode}


@platform.put("/{station_uid}/bays/carriers")
async def platform_carrier_bay(station_uid: uuid.UUID, body: CarrierBayIn, request: Request,
                               pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        bay = await _carrier_bay(conn, station_uid, body)
    request.state.audit = {"action": "boarding.carrier_bay", "object_type": "station", "object_id": None,
                           "reason": f"carrier {body.carrier_uid}: {bay or 'none'}"}
    return {"carrier_uid": body.carrier_uid, "bay": bay}


@platform.put("/{station_uid}/bays/trips")
async def platform_trip_bay(station_uid: uuid.UUID, body: TripBayIn, request: Request,
                            pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _station_id(conn, station_uid)
        bay = await _trip_bay(conn, body)
    request.state.audit = {"action": "boarding.trip_bay", "object_type": "trip", "object_id": None,
                           "reason": f"trip {body.trip_uid} stop {body.stop_seq}: {bay or 'none'}"}
    return {"trip_uid": body.trip_uid, "stop_seq": body.stop_seq, "bay": bay}
