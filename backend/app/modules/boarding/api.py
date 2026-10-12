"""Boarding stations (owner's decisions, October 2026; migration 1097). Off at launch: nothing here changes a booking,
a boarding or a ticket until the platform switches a station on.

    Platform (boarding.manage)
    GET  /api/admin/boarding/settings                       the switches, the check-in window and the required references
    PUT  /api/admin/boarding/settings                       change one setting: {key, value}
    GET  /api/admin/boarding/stations/{station_uid}         the station's switch, its counters and bays
    PUT  /api/admin/boarding/stations/{station_uid}         switch the station on or off, its counter system and window
    POST /api/admin/boarding/stations/{station_uid}/gates   open a platform gate, bay, gate or counter (the platform numbers it)
    GET  /api/admin/boarding/operator-grants                every grant (station operators' rights)
    POST /api/admin/boarding/operator-grants                grant a state-mandated operating company a right (no carrier)
    POST /api/admin/boarding/operator-grants/{uid}/revoke   revoke a grant
    POST /api/admin/boarding/operating-companies            onboard a station operating company and its owner (1099)

    Station operating company (the STATION portal, 1099; owner or station.counter)
    GET  /api/station/overview                              the rights the company holds now, and its counters

    Carrier (boarding.references)
    GET  /api/carrier/references                            the carrier's agreement and licence numbers, and those missing
    POST /api/carrier/references                            record a number
    POST /api/carrier/references/{uid}/retire               retire a number: it is never changed or deleted

    Carrier (boarding.operators): the rights it gives an operating company, for its own trips at a station
    GET  /api/carrier/station-operators/grants              the grants the carrier gave
    POST /api/carrier/station-operators/grants              give an operating company a right (booking, boarding pass, boarding)
    POST /api/carrier/station-operators/grants/{uid}/revoke revoke a grant
"""
import uuid
from datetime import date
from typing import Any, Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, EmailStr, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden
from ...security import password_problem
from . import service

platform = APIRouter(prefix="/api/admin/boarding", tags=["boarding"])
carrier = APIRouter(prefix="/api/carrier/references", tags=["boarding"])
station_operators = APIRouter(prefix="/api/carrier/station-operators", tags=["boarding"])
station = APIRouter(prefix="/api/station", tags=["boarding"])
staff = require_portal("PLATFORM")
operator = require_portal("OPERATOR")


def _platform_staff(pr: Principal) -> None:
    if "boarding.manage" not in pr.permissions:
        raise forbidden("missing permission: boarding.manage")


def _reference_keeper(pr: Principal) -> None:
    if pr.company_id is None or "boarding.references" not in pr.permissions:
        raise forbidden("missing permission: boarding.references")


def _counter_staff(pr: Principal) -> None:
    if pr.company_id is None or not (pr.is_owner or "station.counter" in pr.permissions):
        raise forbidden("missing permission: station.counter")


def _grantor(pr: Principal) -> None:
    if pr.company_id is None or "boarding.operators" not in pr.permissions:
        raise forbidden("missing permission: boarding.operators")


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


class GrantIn(BaseModel):
    operator_company_uid: uuid.UUID
    station_uid: Optional[uuid.UUID] = None                         # empty: every station
    permission: Literal["BOOKING", "BOARDING_PASS", "BOARDING"]


class OperatorIn(BaseModel):
    legal_name: str = Field(min_length=3, max_length=160)
    license_no: Optional[str] = Field(default=None, max_length=60)
    owner_name: str = Field(min_length=3, max_length=120)
    owner_email: EmailStr
    owner_password: str = Field(min_length=1, max_length=200)


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


@platform.get("/operator-grants")
async def list_grants(request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"grants": await service.grants(conn, None)}


@platform.post("/operator-grants", status_code=201)
async def add_platform_grant(body: GrantIn, request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        row_id, uid = await service.add_grant(conn, None, body.operator_company_uid, body.station_uid, body.permission, pr.user_id)
    request.state.audit = {"action": "boarding.grant_platform", "object_type": "station_operator_grant", "object_id": row_id}
    return {"uid": uid, "status": "ACTIVE"}


@platform.post("/operator-grants/{uid}/revoke")
async def revoke_platform_grant(uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        row_id = await service.revoke_grant(conn, uid, pr.user_id)
    request.state.audit = {"action": "boarding.grant_revoke", "object_type": "station_operator_grant", "object_id": row_id}
    return {"uid": uid, "status": "REVOKED"}


@station_operators.get("/grants")
async def list_carrier_grants(request: Request, pr: Principal = Depends(operator)):
    _grantor(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"grants": await service.grants(conn, pr.company_id)}


@station_operators.post("/grants", status_code=201)
async def add_carrier_grant(body: GrantIn, request: Request, pr: Principal = Depends(operator)):
    _grantor(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        row_id, uid = await service.add_grant(conn, pr.company_id, body.operator_company_uid, body.station_uid, body.permission, pr.user_id)
    request.state.audit = {"action": "boarding.grant_carrier", "object_type": "station_operator_grant", "object_id": row_id}
    return {"uid": uid, "status": "ACTIVE"}


@station_operators.post("/grants/{uid}/revoke")
async def revoke_carrier_grant(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    _grantor(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        row_id = await service.revoke_grant(conn, uid, pr.user_id)
    request.state.audit = {"action": "boarding.grant_revoke", "object_type": "station_operator_grant", "object_id": row_id}
    return {"uid": uid, "status": "REVOKED"}



@platform.post("/operating-companies", status_code=201)
async def onboard_operator(body: OperatorIn, request: Request, pr: Principal = Depends(staff)):
    """A station operating company and its owner (1099): the owner signs in to the STATION portal, with a second factor."""
    _platform_staff(pr)
    problem = password_problem(body.owner_password, body.owner_email, body.owner_name)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        company_id, uid = await service.onboard_operator(conn, body, pr.user_id)
    request.state.audit = {"action": "boarding.operator_onboard", "object_type": "company", "object_id": company_id}
    return {"uid": uid}


@station.get("/overview")
async def station_overview(request: Request, pr: Principal = Depends(require_portal("STATION"))):
    _counter_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.operator_overview(conn, pr.company_id)
