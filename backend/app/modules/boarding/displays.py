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
    PUT    /api/station/screens/{screen_uid}/filter   {bays, carriers}: the bays and carriers it shows, empty for all (1129)
    POST   /api/station/screens/{screen_uid}/pair     {code}: the display showing that code opens this screen (1129)

    Platform (boarding.manage): the same under /api/admin/boarding/stations/{station_uid}/screens

    Public
    GET    /api/public/screens/{screen_uid}      the board of one screen: its kind, place, and the departures or arrivals or both
    POST   /api/public/screens/pair              a display asks to be paired: a short code to show and a secret to keep (1129)
    POST   /api/public/screens/pair/state        {token}: whether the display was paired, and its screen

A screen that was seen and stops reading its board is reported unseen to the administration (worker, 1129).
"""
import hashlib
import json
import secrets
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


class ScreenFilter(BaseModel):
    bays: list[str] = Field(default_factory=list, max_length=40)
    carriers: list[uuid.UUID] = Field(default_factory=list, max_length=40)


class PairIn(BaseModel):
    code: str = Field(min_length=6, max_length=8)


class PairState(BaseModel):
    token: str = Field(min_length=32, max_length=64)


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
          "SCREEN_LABEL_INVALID": 422, "SCREEN_LABEL_TAKEN": 409, "SCREENS_LIMIT": 409, "SCREEN_BAY_UNKNOWN": 422,
          "SCREEN_CARRIER_UNKNOWN": 422, "SCREEN_FILTER_LIMIT": 422, "PAIRING_UNKNOWN": 404, "PAIRING_BUSY": 429}

# the letters and digits of a pairing code: none that is mistaken for another (0/O, 1/I/L, 2/Z, 5/S, 8/B, 6/G)
PAIR_ALPHABET = "ACDEFHJKMNPRTUVWXY3479"


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


async def _filter(conn, screen_uid: uuid.UUID, body: ScreenFilter) -> int:
    return await _refused(conn.fetchval("SELECT net.set_screen_filter($1, $2, $3)", screen_uid, body.bays, body.carriers))


async def _pair(conn, screen_uid: uuid.UUID, body: PairIn) -> int:
    return await _refused(conn.fetchval("SELECT net.claim_screen_pairing($1, $2)", body.code, screen_uid))


def _token_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


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


@station.put("/{screen_uid}/filter")
async def station_filter(screen_uid: uuid.UUID, body: ScreenFilter, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _filter(conn, screen_uid, body)
    _audit(request, "boarding.screen_filter", sid, f"screen {screen_uid}: bays {body.bays}, carriers {len(body.carriers)}")
    return {"uid": screen_uid, "bays": body.bays, "carriers": body.carriers}


@station.post("/{screen_uid}/pair")
async def station_pair(screen_uid: uuid.UUID, body: PairIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _pair(conn, screen_uid, body)
    _audit(request, "boarding.screen_pair", sid, f"screen {screen_uid} paired with a display")
    return {"uid": screen_uid, "paired": True}


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


@platform.put("/{station_uid}/screens/{screen_uid}/filter")
async def platform_filter(station_uid: uuid.UUID, screen_uid: uuid.UUID, body: ScreenFilter, request: Request,
                          pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _on_station(conn, await _station_id(conn, station_uid), screen_uid)
        sid = await _filter(conn, screen_uid, body)
    _audit(request, "boarding.screen_filter", sid, f"screen {screen_uid}: bays {body.bays}, carriers {len(body.carriers)}")
    return {"uid": screen_uid, "bays": body.bays, "carriers": body.carriers}


@platform.post("/{station_uid}/screens/{screen_uid}/pair")
async def platform_pair(station_uid: uuid.UUID, screen_uid: uuid.UUID, body: PairIn, request: Request,
                        pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _on_station(conn, await _station_id(conn, station_uid), screen_uid)
        sid = await _pair(conn, screen_uid, body)
    _audit(request, "boarding.screen_pair", sid, f"screen {screen_uid} paired with a display")
    return {"uid": screen_uid, "paired": True}


# ------------------------------------------------------------------ the screen itself
@public.post("/pair")
async def pair_start(request: Request):
    """A display asks to be paired: a short code to show for ten minutes, and a secret only it keeps (stored as a hash),
    with which it asks whether the administration gave it a screen. Public, as the boards; limited per address."""
    token = secrets.token_urlsafe(32)
    async with db.transaction(base_context(request)) as conn:
        for _ in range(8):                                  # a code another display holds is drawn again
            code = "".join(secrets.choice(PAIR_ALPHABET) for _ in range(6))
            try:
                async with conn.transaction():
                    until = await _refused(conn.fetchval("SELECT net.start_screen_pairing($1, $2)", code, _token_hash(token)))
                return {"code": code, "token": token, "expires_at": until}
            except asyncpg.RaiseError as exc:
                if not str(exc).startswith("PAIRING_CODE_TAKEN"):
                    raise
    raise ApiError(429, "PAIRING_BUSY", "no free code at the moment; try again")


@public.post("/pair/state")
async def pair_state(body: PairState, request: Request):
    """Whether the display holding this secret was paired, and the screen it opens."""
    async with db.transaction(base_context(request)) as conn:
        return json.loads(await conn.fetchval("SELECT net.screen_pairing_state($1)::text", _token_hash(body.token)))



@public.get("/{screen_uid}")
async def screen_board(screen_uid: uuid.UUID, request: Request):
    """The board of one screen: public, without passenger data; 404 for an unknown or stopped screen, a kind the
    platform no longer allows, or a station whose screens are off."""
    async with db.transaction(base_context(request)) as conn:
        out = await conn.fetchval("SELECT brd.screen_board($1)::text", screen_uid)
    if out is None:
        raise ApiError(404, "SCREEN_OFF", "this screen shows nothing at the moment")
    return json.loads(out)
