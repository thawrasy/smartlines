"""Carrier API for seat layouts: /api/carrier/seat-layouts and /api/carrier/vehicles/{uid}/layout."""
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import forbidden
from . import service

router = APIRouter(prefix="/api/carrier", tags=["fleet"])
operator = require_portal("OPERATOR")


def _manage(pr: Principal) -> None:
    if "vehicle.manage" not in pr.permissions:
        raise forbidden("missing permission: vehicle.manage")


Row = Field(min_length=2, max_length=7, pattern=r"^[SsHh_DdCcRrXx ]+$")


class GridIn(BaseModel):
    decks: list[list[str]] = Field(min_length=1, max_length=2)


class LayoutIn(GridIn):
    name: str = Field(min_length=2, max_length=80)


class PresetIn(BaseModel):
    pattern: Literal["2+2", "2+1", "1+2", "1+1", "3+2", "2", "3", "4"] = "2+2"
    rows: int = Field(ge=1, le=25)
    door_row: Optional[int] = Field(default=None, ge=1, le=25)
    wc_row: Optional[int] = Field(default=None, ge=1, le=25)
    back_row_full: bool = False


class AssignIn(BaseModel):
    layout_uid: uuid.UUID


@router.get("/seat-layouts")
async def layouts(request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"layouts": await service.list_layouts(conn)}


@router.post("/seat-layouts/preset")
async def preset(body: PresetIn, pr: Principal = Depends(operator)):
    return service.preset(body.pattern, body.rows, body.door_row, body.back_row_full, body.wc_row)


@router.post("/seat-layouts/preview")
async def preview(body: GridIn, pr: Principal = Depends(operator)):
    return service.preview(body.decks)


@router.get("/seat-layouts/{layout_uid}")
async def layout(layout_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.get_layout(conn, layout_uid)


@router.post("/seat-layouts", status_code=201)
async def create(body: LayoutIn, request: Request, pr: Principal = Depends(operator)):
    _manage(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        layout_id, uid = await service.create(conn, pr.company_id, pr.user_id, body.name, body.decks)
    request.state.audit = {"action": "seat_layout.create", "object_type": "seat_layout", "object_id": layout_id}
    return {"uid": uid}


@router.post("/seat-layouts/{layout_uid}/archive")
async def archive(layout_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    _manage(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        layout_id = await service.archive(conn, pr.company_id, layout_uid)
    request.state.audit = {"action": "seat_layout.archive", "object_type": "seat_layout", "object_id": layout_id}
    return {"ok": True}


@router.post("/vehicles/{vehicle_uid}/layout")
async def assign(vehicle_uid: uuid.UUID, body: AssignIn, request: Request, pr: Principal = Depends(operator)):
    _manage(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.assign_to_vehicle(conn, pr.company_id, vehicle_uid, body.layout_uid)
    request.state.audit = {"action": "vehicle.layout", "object_type": "vehicle", "object_id": out.pop("vehicle_id")}
    return {"ok": True, **out}
