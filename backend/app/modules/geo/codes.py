"""Codes that can be changed, with the change cascading down and the old codes kept (owner's request N39, migration 1161).

    Platform (geo.manage)
    POST /api/admin/geo/codes/preview          {kind, code, new_code}: every code the change touches and any code taken
    GET  /api/admin/geo/codes/changes?status=  the changes asked for, newest first
    POST /api/admin/geo/codes/changes          {kind, code, new_code, reason, source_document, effective_on}: ask
    POST /api/admin/geo/codes/changes/{uid}/decide   {approve, note}: another person decides; in effect at once when due
    POST /api/admin/geo/codes/changes/{uid}/cancel   who asked withdraws a change not yet in effect
    GET  /api/admin/geo/codes/history?kind=&code=    a thing found by its code, old or new: its codes and their changes

A kind is AREA (governorate, district, sub-district), PLACE (community, neighbourhood), CITY (of the network) or STATION.
"""
import json
import uuid
from datetime import date
from typing import Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import not_found
from .api import _need

router = APIRouter(prefix="/api/admin/geo/codes", tags=["geography"])

KIND = "^(AREA|PLACE|CITY|STATION)$"
CODE = r"^[A-Za-z0-9-]{3,16}$"


class PreviewIn(BaseModel):
    kind: str = Field(pattern=KIND)
    code: str = Field(pattern=CODE)
    new_code: str = Field(pattern=CODE)


@router.post("/preview")
async def preview(body: PreviewIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        plan = json.loads(await conn.fetchval("SELECT ref.code_plan($1, $2, $3)::text", body.kind, body.code.upper(), body.new_code))
    plan.pop("id", None)
    for i in plan["items"]:
        i.pop("id", None)
    return plan


@router.get("/changes")
async def changes(request: Request, status: Optional[str] = Query(default=None, pattern="^(PENDING|APPROVED|APPLIED|REJECTED|CANCELLED|FAILED)$"),
                  pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT c.uid, c.entity_kind AS kind, c.old_code, c.new_code, c.reason, c.source_document, c.effective_on, c.status,
                      jsonb_array_length(c.plan) AS codes, c.plan, c.requested_at, u.email AS requested_by, c.decided_at,
                      d.email AS decided_by, c.decision_note, c.applied_at, c.failure, (c.requested_by = $2) AS mine
                 FROM net.code_change c JOIN iam.app_user u ON u.id = c.requested_by LEFT JOIN iam.app_user d ON d.id = c.decided_by
                WHERE $1::text IS NULL OR c.status = $1 ORDER BY c.requested_at DESC LIMIT 200""", status, pr.user_id)
    out = []
    for r in rows:
        x = dict(r)
        x["plan"] = [{k: v for k, v in i.items() if k != "id"} for i in json.loads(x["plan"])]
        out.append(x)
    return {"changes": out}


class ChangeIn(PreviewIn):
    reason: str = Field(min_length=5, max_length=500)
    source_document: Optional[str] = Field(default=None, max_length=300)
    effective_on: Optional[date] = None


@router.post("/changes", status_code=201)
async def ask(body: ChangeIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await conn.fetchval("SELECT ref.request_code_change($1, $2, $3, $4, $5, coalesce($6, current_date))",
                                  body.kind, body.code.upper(), body.new_code, body.reason, body.source_document, body.effective_on)
        row = await conn.fetchrow("SELECT new_code, effective_on, jsonb_array_length(plan) AS codes FROM net.code_change WHERE uid = $1", uid)
    request.state.audit = {"action": "geo.code_request", "object_type": "code_change",
                           "reason": f"{body.kind} {body.code.upper()} -> {row['new_code']}"[:120]}
    return {"uid": uid, "status": "PENDING", "new_code": row["new_code"], "effective_on": row["effective_on"], "codes": row["codes"]}


class DecideIn(BaseModel):
    approve: bool
    note: Optional[str] = Field(default=None, max_length=500)


@router.post("/changes/{uid}/decide")
async def decide(uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT ref.decide_code_change($1, $2, $3)", uid, body.approve, body.note)
        row = await conn.fetchrow("SELECT entity_kind, old_code, new_code, failure FROM net.code_change WHERE uid = $1", uid)
    request.state.audit = {"action": "geo.code_decide", "object_type": "code_change",
                           "reason": f"{row['entity_kind']} {row['old_code']} -> {row['new_code']}: {status}"[:120]}
    return {"uid": uid, "status": status, "failure": row["failure"]}


@router.post("/changes/{uid}/cancel")
async def cancel(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT ref.cancel_code_change($1)", uid)
    request.state.audit = {"action": "geo.code_cancel", "object_type": "code_change", "reason": str(uid)}
    return {"uid": uid, "status": status}


@router.get("/history")
async def history(request: Request, kind: str = Query(pattern=KIND), code: str = Query(pattern=CODE),
                  pr: Principal = Depends(require_portal("PLATFORM"))):
    _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        eid = await conn.fetchval("SELECT ref.code_entity($1, $2)", kind, code.upper())
        if eid is None:
            raise not_found("code")
        current = await conn.fetchval("SELECT ref.entity_code($1, $2)", kind, eid)
        codes = await conn.fetch(
            """SELECT h.code, h.valid_from, h.valid_to, c.uid AS change FROM net.code_history h JOIN net.code_change c ON c.id = h.change_id
                WHERE h.entity_kind = $1 AND coalesce(h.area_id, h.place_id, h.city_id, h.station_id) = $2 ORDER BY h.valid_to""", kind, eid)
        asked = await conn.fetch(
            """SELECT c.uid, c.old_code, c.new_code, c.status, c.reason, c.effective_on, c.requested_at, c.applied_at
                 FROM net.code_change c
                WHERE c.entity_kind = $1 AND coalesce(c.area_id, c.place_id, c.city_id, c.station_id) = $2
                   OR EXISTS (SELECT 1 FROM jsonb_array_elements(c.plan) i WHERE i->>'kind' = $1 AND (i->>'id')::bigint = $2)
                ORDER BY c.requested_at""", kind, eid)
    return {"kind": kind, "code": current, "old_codes": [dict(r) for r in codes], "changes": [dict(r) for r in asked]}
