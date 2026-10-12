"""Boarding stations (owner's decisions, October 2026; migration 1097). Off at launch: nothing here changes a booking,
a boarding or a ticket until the platform switches a station on.

    Platform (boarding.manage)
    GET  /api/admin/boarding/settings                       the switches, the check-in window and the required references
    PUT  /api/admin/boarding/settings                       change one setting: {key, value}
    GET  /api/admin/boarding/stations/{station_uid}         the station's switch, its counters and bays
    PUT  /api/admin/boarding/stations/{station_uid}         switch the station on or off, its counter system and window
    POST /api/admin/boarding/stations/{station_uid}/gates   open a platform gate, bay, gate or counter (the platform numbers it)

    Carrier (boarding.references)
    GET  /api/carrier/references                            the carrier's agreement and licence numbers, and those missing
    POST /api/carrier/references                            record a number
    POST /api/carrier/references/{uid}/retire               retire a number: it is never changed or deleted
"""
import uuid
from datetime import date
from typing import Any, Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden
from . import service

platform = APIRouter(prefix="/api/admin/boarding", tags=["boarding"])
carrier = APIRouter(prefix="/api/carrier/references", tags=["boarding"])
staff = require_portal("PLATFORM")
operator = require_portal("OPERATOR")


def _platform_staff(pr: Principal) -> None:
    if "boarding.manage" not in pr.permissions:
        raise forbidden("missing permission: boarding.manage")


def _reference_keeper(pr: Principal) -> None:
    if pr.company_id is None or "boarding.references" not in pr.permissions:
        raise forbidden("missing permission: boarding.references")


class SettingIn(BaseModel):
    key: Literal["boarding.stations.enabled", "boarding.mode.state_mandated", "boarding.mode.carrier_contracted",
                 "boarding.checkin.opens_minutes", "boarding.checkin.closes_minutes", "boarding.references.required"]
    value: Any


class StationBoardingIn(BaseModel):
    enabled: bool
    counter_system: Literal["PLATFORM", "EXTERNAL"] = "PLATFORM"   # EXTERNAL: the station runs its own system, linked to the platform
    displays: bool = False                                          # the station has screens the platform feeds
    checkin_opens_minutes: Optional[int] = Field(default=None, ge=0, le=1440)
    checkin_closes_minutes: Optional[int] = Field(default=None, ge=0, le=1440)


class GateIn(BaseModel):
    gate_type: Literal["PLATFORM", "BAY", "GATE", "COUNTER"]
    operator_company_uid: Optional[uuid.UUID] = None                # a counter names its operating company; the others none


class ReferenceIn(BaseModel):
    kind: Literal["AGREEMENT", "LICENCE"]
    licence_type: Optional[str] = Field(default=None, min_length=1, max_length=60)
    reference_no: str = Field(min_length=1, max_length=60)
    issued_by: Optional[str] = Field(default=None, min_length=1, max_length=120)
    issued_on: Optional[date] = None
    expires_on: Optional[date] = None


@platform.get("/settings")
async def get_settings(request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"settings": await service.settings(conn)}


@platform.put("/settings")
async def put_setting(body: SettingIn, request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        value = await service.set_setting(conn, body.key, body.value)
    request.state.audit = {"action": f"boarding.setting:{body.key}", "object_type": "setting", "object_id": None}
    return {"key": body.key, "value": value}


@platform.get("/stations/{station_uid}")
async def get_station(station_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.station_view(conn, station_uid)


@platform.put("/stations/{station_uid}")
async def put_station(station_uid: uuid.UUID, body: StationBoardingIn, request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    if body.checkin_opens_minutes is not None and body.checkin_closes_minutes is not None \
            and body.checkin_opens_minutes <= body.checkin_closes_minutes:
        raise ApiError(422, "INVALID_SETTING", "the check-in opens more minutes before departure than it closes")
    async with db.transaction(context_for(request, pr)) as conn:
        station_id = await service.set_station_boarding(conn, station_uid, body, pr.user_id)
        view = await service.station_view(conn, station_uid)
    request.state.audit = {"action": "boarding.station", "object_type": "station", "object_id": station_id}
    return view


@platform.post("/stations/{station_uid}/gates", status_code=201)
async def post_gate(station_uid: uuid.UUID, body: GateIn, request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        gate = await service.open_gate(conn, station_uid, body.gate_type, body.operator_company_uid)
    request.state.audit = {"action": "boarding.gate_open", "object_type": "station_gate", "object_id": gate["id"]}
    return {"code": gate["code"], "gate_type": gate["gate_type"]}


@carrier.get("")
async def list_references(request: Request, pr: Principal = Depends(operator)):
    _reference_keeper(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.references(conn, pr.company_id)


@carrier.post("", status_code=201)
async def add_reference(body: ReferenceIn, request: Request, pr: Principal = Depends(operator)):
    _reference_keeper(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        row_id, uid = await service.add_reference(conn, pr.company_id, pr.user_id, body)
    request.state.audit = {"action": "boarding.reference_add", "object_type": "operation_reference", "object_id": row_id}
    return {"uid": uid, "status": "ACTIVE"}


@carrier.post("/{uid}/retire")
async def retire_reference(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    _reference_keeper(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        row_id = await service.retire_reference(conn, uid)
    request.state.audit = {"action": "boarding.reference_retire", "object_type": "operation_reference", "object_id": row_id}
    return {"uid": uid, "status": "RETIRED"}
