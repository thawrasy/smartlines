"""Connections across carriers (owner's request, October 2026; migration 1130).

    Carrier
    GET /api/carrier/connection-policy        the carrier's policy for connections, or the defaults
    PUT /api/carrier/connection-policy        (trip.publish) whether its trips are offered in connections, and what it does
                                              when a traveller misses its trip: FREE_CHANGE, FARE_RULES or NONE
    Platform (policy.matrix)
    GET /api/admin/connections/settings       PUT: whether connections are offered, the change times, flexible later trips

Search (GET /api/trips/connections) is public; booking goes through the journeys (kind CONNECTION) and a change through
/api/bookings/{ref}/change-options and /change.
"""
import json
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_permission, require_portal
from ...errors import forbidden
from . import connections

carrier = APIRouter(prefix="/api/carrier/connection-policy", tags=["connections"])
platform = APIRouter(prefix="/api/admin/connections", tags=["connections"])


class PolicyIn(BaseModel):
    offer_in_connections: bool = True
    missed_connection: Literal["FREE_CHANGE", "FARE_RULES", "NONE"] = "FARE_RULES"
    change_window_hours: int = Field(default=24, ge=1, le=168)
    note: Optional[str] = Field(default=None, max_length=500)


class SettingsIn(BaseModel):
    enabled: bool
    min_minutes: int = Field(ge=10, le=240)
    min_minutes_station_change: int = Field(ge=10, le=360)
    max_minutes: int = Field(ge=10, le=720)
    require_flexible: bool


def _company(pr: Principal) -> int:
    if not pr.company_id:
        raise forbidden("carrier staff only")
    return pr.company_id


@carrier.get("")
async def get_policy(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await connections.policy(conn, company)


@carrier.put("")
async def set_policy(body: PolicyIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr)
    if "trip.publish" not in pr.permissions:
        raise forbidden("missing permission: trip.publish")
    note = " ".join(body.note.split()) if body.note and body.note.strip() else None
    async with db.transaction(context_for(request, pr)) as conn:
        await conn.execute(
            """INSERT INTO ops.carrier_connection_policy (company_id, offer_in_connections, missed_connection, change_window_hours,
                 note, updated_by, updated_at) VALUES ($1, $2, $3, $4, $5, $6, now())
               ON CONFLICT (company_id) DO UPDATE SET offer_in_connections = excluded.offer_in_connections,
                 missed_connection = excluded.missed_connection, change_window_hours = excluded.change_window_hours,
                 note = excluded.note, updated_by = excluded.updated_by, updated_at = now()""",
            company, body.offer_in_connections, body.missed_connection, body.change_window_hours, note, pr.user_id)
        out = await connections.policy(conn, company)
    request.state.audit = {"action": "connections.policy", "object_type": "company", "object_id": company,
                           "reason": f"{body.missed_connection}, {body.change_window_hours} h, offered: {body.offer_in_connections}"}
    return out


@platform.get("/settings")
async def read_settings(request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        return await connections.settings(conn)


@platform.put("/settings")
async def write_settings(body: SettingsIn, request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetchval("SELECT sales.set_connection_settings($1, $2, $3, $4, $5)::text", body.enabled, body.min_minutes,
                                  body.min_minutes_station_change, body.max_minutes, body.require_flexible)
    request.state.audit = {"action": "connections.settings", "object_type": "setting",
                           "reason": f"on: {body.enabled}, {body.min_minutes}/{body.min_minutes_station_change}/{body.max_minutes} min, "
                                     f"flexible: {body.require_flexible}"}
    return json.loads(out)
