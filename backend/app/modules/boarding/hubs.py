"""Station displays on a closed network (owner's note N46; migration 1179; docs/design/STATION_DISPLAYS_LAN.md).

A station whose screens are on its own network runs one display hub (hub/ in this repository): a small server inside
the station that alone talks to the platform, outbound only, and serves the boards to the screens' players over the
LAN. The station's administration makes a one-time code; the hub, being installed, sends the code with the SHA-256 of
a key it made and keeps the key: the key never leaves the hub except to call here, and only its hash is stored. A
player that opens the hub announces itself; the administration approves it for one of its screens (its MAC and IP
become the screen's) or rejects it. Nobody types an address from scratch.

    Station operating company (the STATION portal; owner or station.screens)
    GET    /api/station/hubs?station_uid=          the hubs, the players waiting, the screens on the hubs, the last events
    POST   /api/station/hubs/pairing               {station_uid, label}: a one-time code for a new hub, shown once
    POST   /api/station/hubs/{hub_uid}/revoke      {reason}: the hub's key stops working; its screens wait for a new hub
    POST   /api/station/hubs/players/{uid}         {approve, screen_uid?}: a waiting player approved for a screen, or rejected
    PUT    /api/station/hubs/screens/{screen_uid}  {code, group, fixed_ip?}: the screen's code at the hub, group and address
    DELETE /api/station/hubs/screens/{screen_uid}/player   the screen's player released

    Platform (boarding.manage): the same under /api/admin/boarding/stations/{station_uid}/hubs (pairing, revoke,
    players/{uid}, screens/{screen_uid}, screens/{screen_uid}/player), each checked to be that station's

    The hub (X-Hub-Key: the key it made at pairing)
    POST   /api/hub/pair                           {code, key_sha256, version}: the hub joins its station
    GET    /api/hub/sync                           its station, its screens (code, group, player, board) and the rejected players
    POST   /api/hub/report                         {players: [{mac, ip}], uplink_gap_seconds}: who it saw on the screens' network
"""
import hashlib
import json
import re
import secrets
import uuid
from ipaddress import ip_address
from typing import Optional

import asyncpg
from fastapi import APIRouter, Depends, Header, Request
from pydantic import BaseModel, Field, field_validator

from ... import db
from ...deps import Principal, base_context, context_for, require_portal
from ...errors import ApiError
from ..notify.render import messages
from .displays import PAIR_ALPHABET, _audit, _on_station, _platform_staff, _screens_staff, _station_id

station = APIRouter(prefix="/api/station/hubs", tags=["boarding"])
platform = APIRouter(prefix="/api/admin/boarding/stations", tags=["boarding"])
hub = APIRouter(prefix="/api/hub", tags=["display hub"])

STATUS = {"NOT_STATION_ADMIN": 403, "HUB_LABEL_INVALID": 422, "HUB_LABEL_TAKEN": 409, "HUB_CODE_UNKNOWN": 404,
          "HUB_UNKNOWN": 404, "HUB_REVOKED": 409, "HUB_REASON": 422, "HUB_REPORT_INVALID": 422, "PLAYER_UNKNOWN": 404,
          "PLAYER_DECIDED": 409, "SCREEN_UNKNOWN": 404, "SCREEN_CODE_REQUIRED": 409, "SCREEN_CODE_INVALID": 422,
          "SCREEN_CODE_TAKEN": 409, "SCREEN_NO_PLAYER": 409}
MAC = re.compile(r"^[0-9a-f]{2}(:[0-9a-f]{2}){5}$")


def _hash(value: str) -> bytes:
    return hashlib.sha256(value.encode()).digest()


async def _refused(call):
    try:
        return await call
    except asyncpg.RaiseError as exc:
        code, _, message = str(exc).partition(":")
        if code in STATUS:
            raise ApiError(STATUS[code], code, message.strip() or code) from exc
        raise


class PairingIn(BaseModel):
    label: str = Field(min_length=1, max_length=60)          # where the hub is: the station's server room, the hall


class StationPairingIn(PairingIn):
    station_uid: uuid.UUID


class RevokeIn(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


class DecideIn(BaseModel):
    approve: bool
    screen_uid: Optional[uuid.UUID] = None


class NetworkIn(BaseModel):
    code: Optional[str] = Field(default=None, max_length=16)
    group: Optional[str] = Field(default=None, max_length=40)
    fixed_ip: Optional[str] = Field(default=None, max_length=45)

    @field_validator("fixed_ip")
    @classmethod
    def _ip(cls, v: Optional[str]) -> Optional[str]:
        if v:
            ip_address(v)                                  # a plain address, no range
        return v or None


# ------------------------------------------------------------------ the administration (station portal and platform)
async def _view(conn, station_id: int) -> dict:
    return json.loads(await _refused(conn.fetchval("SELECT net.station_hubs($1)::text", station_id)))


async def _start(conn, station_id: int, label: str) -> dict:
    code = "".join(secrets.choice(PAIR_ALPHABET) for _ in range(8))
    until = await _refused(conn.fetchval("SELECT net.start_hub_pairing($1, $2, $3)", station_id, label, _hash(code)))
    return {"code": code, "expires_at": until, "label": label.strip()}


async def _decide(conn, player_uid: uuid.UUID, body: DecideIn) -> int:
    if body.approve and body.screen_uid is None:
        raise ApiError(422, "SCREEN_REQUIRED", "name the screen the player shows")
    return await _refused(conn.fetchval("SELECT net.decide_hub_player($1, $2, $3)", player_uid, body.screen_uid, body.approve))


async def _network(conn, screen_uid: uuid.UUID, body: NetworkIn) -> int:
    return await _refused(conn.fetchval("SELECT net.set_screen_network($1, $2, $3, $4::inet)",
                                        screen_uid, body.code, body.group, body.fixed_ip))


async def _hub_station(conn, hub_uid: uuid.UUID) -> Optional[int]:
    return await conn.fetchval("SELECT station_id FROM net.display_hub WHERE uid = $1", hub_uid)


@station.get("")
async def station_hubs(station_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _view(conn, await _station_id(conn, station_uid))


@station.post("/pairing", status_code=201)
async def station_pairing(body: StationPairingIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _station_id(conn, body.station_uid)
        out = await _start(conn, sid, body.label)
    _audit(request, "boarding.hub_pairing", sid, f"a pairing code for the display hub {body.label.strip()}")
    return out


@station.post("/{hub_uid}/revoke")
async def station_revoke(hub_uid: uuid.UUID, body: RevokeIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _refused(conn.fetchval("SELECT net.revoke_hub($1, $2)", hub_uid, body.reason))
    _audit(request, "boarding.hub_revoke", sid, f"hub {hub_uid}: {body.reason.strip()}")
    return {"uid": hub_uid, "revoked": True}


@station.post("/players/{player_uid}")
async def station_decide(player_uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _decide(conn, player_uid, body)
    _audit(request, "boarding.hub_player", sid, f"player {player_uid} {'approved for screen ' + str(body.screen_uid) if body.approve else 'rejected'}")
    return {"uid": player_uid, "status": "APPROVED" if body.approve else "REJECTED"}


@station.put("/screens/{screen_uid}")
async def station_network(screen_uid: uuid.UUID, body: NetworkIn, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _network(conn, screen_uid, body)
    _audit(request, "boarding.screen_network", sid, f"screen {screen_uid}: {body.model_dump(exclude_none=True)}")
    return {"uid": screen_uid, **body.model_dump()}


@station.delete("/screens/{screen_uid}/player")
async def station_release(screen_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _screens_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _refused(conn.fetchval("SELECT net.release_screen_player($1)", screen_uid))
    _audit(request, "boarding.screen_release", sid, f"screen {screen_uid}: its player released")
    return {"uid": screen_uid, "released": True}


@platform.get("/{station_uid}/hubs")
async def platform_hubs(station_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _view(conn, await _station_id(conn, station_uid))


@platform.post("/{station_uid}/hubs/pairing", status_code=201)
async def platform_pairing(station_uid: uuid.UUID, body: PairingIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _station_id(conn, station_uid)
        out = await _start(conn, sid, body.label)
    _audit(request, "boarding.hub_pairing", sid, f"a pairing code for the display hub {body.label.strip()}")
    return out


@platform.post("/{station_uid}/hubs/{hub_uid}/revoke")
async def platform_revoke(station_uid: uuid.UUID, hub_uid: uuid.UUID, body: RevokeIn, request: Request,
                          pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        if await _hub_station(conn, hub_uid) != await _station_id(conn, station_uid):
            raise ApiError(404, "HUB_UNKNOWN", "no such hub at this station")
        sid = await _refused(conn.fetchval("SELECT net.revoke_hub($1, $2)", hub_uid, body.reason))
    _audit(request, "boarding.hub_revoke", sid, f"hub {hub_uid}: {body.reason.strip()}")
    return {"uid": hub_uid, "revoked": True}


async def _player_station(conn, player_uid: uuid.UUID) -> Optional[int]:
    return await conn.fetchval("""SELECT h.station_id FROM net.hub_player p JOIN net.display_hub h ON h.id = p.hub_id
                                   WHERE p.uid = $1""", player_uid)


@platform.post("/{station_uid}/hubs/players/{player_uid}")
async def platform_decide(station_uid: uuid.UUID, player_uid: uuid.UUID, body: DecideIn, request: Request,
                          pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        if await _player_station(conn, player_uid) != await _station_id(conn, station_uid):
            raise ApiError(404, "PLAYER_UNKNOWN", "no such player at this station")
        sid = await _decide(conn, player_uid, body)
    _audit(request, "boarding.hub_player", sid, f"player {player_uid} {'approved for screen ' + str(body.screen_uid) if body.approve else 'rejected'}")
    return {"uid": player_uid, "status": "APPROVED" if body.approve else "REJECTED"}


@platform.put("/{station_uid}/hubs/screens/{screen_uid}")
async def platform_network(station_uid: uuid.UUID, screen_uid: uuid.UUID, body: NetworkIn, request: Request,
                           pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _on_station(conn, await _station_id(conn, station_uid), screen_uid)
        sid = await _network(conn, screen_uid, body)
    _audit(request, "boarding.screen_network", sid, f"screen {screen_uid}: {body.model_dump(exclude_none=True)}")
    return {"uid": screen_uid, **body.model_dump()}


@platform.delete("/{station_uid}/hubs/screens/{screen_uid}/player")
async def platform_release(station_uid: uuid.UUID, screen_uid: uuid.UUID, request: Request,
                           pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _on_station(conn, await _station_id(conn, station_uid), screen_uid)
        sid = await _refused(conn.fetchval("SELECT net.release_screen_player($1)", screen_uid))
    _audit(request, "boarding.screen_release", sid, f"screen {screen_uid}: its player released")
    return {"uid": screen_uid, "released": True}


# ------------------------------------------------------------------ the hub itself
class HubPairIn(BaseModel):
    code: str = Field(min_length=8, max_length=8)
    key_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")      # the hub keeps its key; only the hash comes here
    version: Optional[str] = Field(default=None, max_length=40)


class Player(BaseModel):
    mac: str = Field(max_length=17)
    ip: str = Field(max_length=45)

    @field_validator("mac")
    @classmethod
    def _mac(cls, v: str) -> str:
        v = v.lower().replace("-", ":")
        if not MAC.match(v):
            raise ValueError("a hardware address like 3c:22:fb:01:02:03")
        return v

    @field_validator("ip")
    @classmethod
    def _ip(cls, v: str) -> str:
        return str(ip_address(v))


class ReportIn(BaseModel):
    players: list[Player] = Field(default_factory=list, max_length=500)
    uplink_gap_seconds: int = Field(default=0, ge=0, le=31_536_000)


async def _hub(conn, key: Optional[str], version: Optional[str]) -> int:
    hub_id = await conn.fetchval("SELECT net.hub_by_key($1, $2)", _hash(key), version) if key and len(key) <= 128 else None
    if hub_id is None:
        raise ApiError(401, "HUB_KEY_INVALID", "unknown or revoked hub key: pair the hub again with a new code")
    return hub_id


@hub.post("/pair", status_code=201)
async def hub_pair(body: HubPairIn, request: Request):
    """The hub joins its station with the administration's one-time code and the hash of the key it made."""
    async with db.transaction(base_context(request)) as conn:
        out = json.loads(await _refused(conn.fetchval("SELECT net.claim_hub($1, $2, $3)::text", _hash(body.code.upper()),
                                                      bytes.fromhex(body.key_sha256), body.version)))
    request.state.audit = {"action": "boarding.hub_paired", "object_type": "display_hub", "object_id": out["hub_uid"]}
    return out


@hub.get("/sync")
async def hub_sync(request: Request, x_hub_key: Optional[str] = Header(default=None), x_hub_version: Optional[str] = Header(default=None)):
    """What the hub serves: its station, its screens with their code, group, player and board (public board data only)."""
    async with db.transaction(base_context(request)) as conn:
        hub_id = await _hub(conn, x_hub_key, x_hub_version)
        out = json.loads(await conn.fetchval("SELECT net.hub_sync($1)::text", hub_id))
    # the words of the board in each language it shows, so the hub draws it without reaching the platform
    out["labels"] = {loc: messages(loc)["board"] for loc in ("ar", "en")}
    # city names as the web app gives them: the platform's own list first, then the names of the cities' places
    cities = out.get("cities") or {}
    for loc in ("ar", "en"):
        for code, name in (messages(loc).get("cities") or {}).items():
            cities.setdefault(code, {})[loc] = name
    out["cities"] = cities
    return out


@hub.post("/report")
async def hub_report(body: ReportIn, request: Request, x_hub_key: Optional[str] = Header(default=None),
                     x_hub_version: Optional[str] = Header(default=None)):
    """The players the hub saw on the screens' network, and how long its uplink was cut if it was."""
    async with db.transaction(base_context(request)) as conn:
        hub_id = await _hub(conn, x_hub_key, x_hub_version)
        return json.loads(await _refused(conn.fetchval("SELECT net.hub_report($1, $2::jsonb, $3)::text", hub_id,
                                                       json.dumps([p.model_dump() for p in body.players]), body.uplink_gap_seconds)))
