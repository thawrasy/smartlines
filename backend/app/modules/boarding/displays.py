"""Station display screens (owner's decision, October 2026; migration 1120).

A station shows its departures and its arrivals on separate screens, each headed "Departures" or "Arrivals" in the
languages the board shows in turn. The platform decides which kinds of screen a station may show (PUT
/api/admin/boarding/stations/{uid}, display_kinds: DEPARTURES, ARRIVALS, COMBINED). The station's administration
registers its screens, gives each a kind and a place, and distributes them: each screen has its own link
(/screen/{uid}) that opens its board full screen. The platform does the same where a station has no administration
yet. The database checks who may (NOT_STATION_ADMIN, SCREEN_UNKNOWN) and which kinds are allowed.

    Station operating company (the STATION portal; owner or station.screens)
    GET    /api/station/screens?station_uid=     whether the boards are on, the kinds allowed, the screens and when each was seen
    POST   /api/station/screens                  {station_uid, kind, label}: a new screen and its link
    PATCH  /api/station/screens/{screen_uid}     {kind?, label?, active?}
    DELETE /api/station/screens/{screen_uid}     taken down for good; its link stops working

    Platform (boarding.manage): the same under /api/admin/boarding/stations/{station_uid}/screens

    Public
    GET    /api/public/screens/{screen_uid}      the board of one screen: its kind, place, and the departures or arrivals or both
"""
import json
import uuid
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, base_context, context_for, require_portal
from ...errors import ApiError, forbidden

station = APIRouter(prefix="/api/station/screens", tags=["boarding"])
platform = APIRouter(prefix="/api/admin/boarding/stations", tags=["boarding"])
public = APIRouter(prefix="/api/public/screens", tags=["public"])

Kind = Literal["DEPARTURES", "ARRIVALS", "COMBINED"]


class ScreenIn(BaseModel):
    kind: Kind
    label: str = Field(min_length=1, max_length=60)           # where the screen is: a hall, a gate, an entrance


class StationScreenIn(ScreenIn):
    station_uid: uuid.UUID


class ScreenChange(BaseModel):
    kind: Optional[Kind] = None
    label: Optional[str] = Field(default=None, min_length=1, max_length=60)
    active: Optional[bool] = None


def _screens_staff(pr: Principal) -> None:
    if pr.company_id is None or not (pr.is_owner or "station.screens" in pr.permissions):
        raise forbidden("missing permission: station.screens")


def _platform_staff(pr: Principal) -> None:
    if "boarding.manage" not in pr.permissions:
        raise forbidden("missing permission: boarding.manage")


STATUS = {"NOT_STATION_ADMIN": 403, "SCREEN_UNKNOWN": 404, "SCREEN_KIND_INVALID": 422, "SCREEN_KIND_NOT_ALLOWED": 422,
          "SCREEN_LABEL_INVALID": 422, "SCREEN_LABEL_TAKEN": 409, "SCREENS_LIMIT": 409}


async def _refused(call):
    """What the database refuses: not the station's administration (403), an unknown screen (404), a kind the platform
    does not allow or a place already named (422, 409)."""
    try:
        return await call
    except asyncpg.RaiseError as exc:
        code, _, message = str(exc).partition(":")
        if code in STATUS:
            raise ApiError(STATUS[code], code, message.strip() or code) from exc
        raise


async def _station_id(conn, station_uid: uuid.UUID) -> int:
    sid = await conn.fetchval("SELECT id FROM net.station WHERE uid = $1", station_uid)
    if sid is None:
        raise ApiError(404, "NOT_FOUND", "station not found")
    return sid


async def _view(conn, station_id: int) -> dict:
    return json.loads(await _refused(conn.fetchval("SELECT net.station_screens($1)::text", station_id)))


async def _add(conn, station_id: int, body: ScreenIn) -> dict:
    uid = await _refused(conn.fetchval("SELECT net.add_station_screen($1, $2, $3)", station_id, body.kind, body.label))
    return {"uid": uid, "kind": body.kind, "label": body.label.strip(), "active": True, "link": f"/screen/{uid}"}


async def _change(conn, screen_uid: uuid.UUID, body: ScreenChange) -> int:
    return await _refused(conn.fetchval("SELECT net.change_station_screen($1, $2, $3, $4)",
                                        screen_uid, body.kind, body.label, body.active))


async def _remove(conn, screen_uid: uuid.UUID) -> int:
    return await _refused(conn.fetchval("SELECT net.remove_station_screen($1)", screen_uid))


async def _on_station(conn, station_id: int, screen_uid: uuid.UUID) -> None:
    """A platform path names the station; the screen must be one of its own."""
    if await conn.fetchval("SELECT station_id FROM net.station_screen WHERE uid = $1", screen_uid) != station_id:
        raise ApiError(404, "SCREEN_UNKNOWN", "no such screen at this station")


def _audit(request: Request, action: str, station_id: Optional[int], reason: str) -> None:
    request.state.audit = {"action": action, "object_type": "station", "object_id": station_id, "reason": reason}


# ------------------------------------------------------------------ the station's administration
@station.get("")
async def station_screens(station_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _view(conn, await _station_id(conn, station_uid))


@station.post("", status_code=201)
async def station_add(body: StationScreenIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _station_id(conn, body.station_uid)
        out = await _add(conn, sid, body)
    _audit(request, "boarding.screen_add", sid, f"{body.kind}: {out['label']}")
    return out


@station.patch("/{screen_uid}")
async def station_change(screen_uid: uuid.UUID, body: ScreenChange, request: Request,
                         pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _change(conn, screen_uid, body)
    _audit(request, "boarding.screen_change", sid, f"screen {screen_uid}: {body.model_dump(exclude_none=True)}")
    return {"uid": screen_uid, **body.model_dump(exclude_none=True)}


@station.delete("/{screen_uid}")
async def station_remove(screen_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _remove(conn, screen_uid)
    _audit(request, "boarding.screen_remove", sid, f"screen {screen_uid}")
    return {"uid": screen_uid, "removed": True}


# ------------------------------------------------------------------ the platform, where a station has no administration yet
@platform.get("/{station_uid}/screens")
async def platform_screens(station_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _view(conn, await _station_id(conn, station_uid))


@platform.post("/{station_uid}/screens", status_code=201)
async def platform_add(station_uid: uuid.UUID, body: ScreenIn, request: Request,
                       pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _station_id(conn, station_uid)
        out = await _add(conn, sid, body)
    _audit(request, "boarding.screen_add", sid, f"{body.kind}: {out['label']}")
    return out


@platform.patch("/{station_uid}/screens/{screen_uid}")
async def platform_change(station_uid: uuid.UUID, screen_uid: uuid.UUID, body: ScreenChange, request: Request,
                          pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _on_station(conn, await _station_id(conn, station_uid), screen_uid)
        sid = await _change(conn, screen_uid, body)
    _audit(request, "boarding.screen_change", sid, f"screen {screen_uid}: {body.model_dump(exclude_none=True)}")
    return {"uid": screen_uid, **body.model_dump(exclude_none=True)}


@platform.delete("/{station_uid}/screens/{screen_uid}")
async def platform_remove(station_uid: uuid.UUID, screen_uid: uuid.UUID, request: Request,
                          pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _on_station(conn, await _station_id(conn, station_uid), screen_uid)
        sid = await _remove(conn, screen_uid)
    _audit(request, "boarding.screen_remove", sid, f"screen {screen_uid}")
    return {"uid": screen_uid, "removed": True}


# ------------------------------------------------------------------ the screen itself
@public.get("/{screen_uid}")
async def screen_board(screen_uid: uuid.UUID, request: Request):
    """The board of one screen: public, without passenger data; 404 for an unknown or stopped screen, a kind the
    platform no longer allows, or a station whose screens are off."""
    async with db.transaction(base_context(request)) as conn:
        out = await conn.fetchval("SELECT brd.screen_board($1)::text", screen_uid)
    if out is None:
        raise ApiError(404, "SCREEN_OFF", "this screen shows nothing at the moment")
    return json.loads(out)
