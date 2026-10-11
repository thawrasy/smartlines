"""The boarding photo policy and its replacement, for platform staff with privacy.manage (1087; WP1 and WP4).

A rule that requires a boarding photo is proposed by one platform person and approved by another; the one who approved
it cannot retire it. A photo already on file changes only through a request with the evidence and the new photo: one
platform person requests it and a second applies or rejects it.
The database enforces the two-person rule too; the checks here answer first with a clear code. Every decision is in the
activity log with the people and the rule or the person, never the picture.
"""
import uuid
from datetime import date
from typing import Literal, Optional

from fastapi import APIRouter, Depends, File, Form, Request, Response, UploadFile
from pydantic import BaseModel, Field

from ... import db
from ...config import get_settings
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError
from ..account.service import privacy_staff
from . import service as photo

platform = APIRouter(prefix="/api/admin/photos", tags=["photos"])


class RuleIn(BaseModel):
    market: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}$")       # the country the trip departs from
    trip_scope: Optional[Literal["DOMESTIC", "INTERNATIONAL"]] = None
    traveller_class: Optional[Literal["SYRIAN_CITIZEN", "FOREIGN", "TRANSIT"]] = None
    passenger_category: Optional[Literal["ADULT", "CHILD", "INFANT", "STUDENT", "SENIOR", "DISABLED"]] = None
    requirement: Literal["REQUIRED", "OPTIONAL", "NOT_APPLICABLE"]
    effective_from: date
    legal_basis: str = Field(min_length=3, max_length=500)


async def _read(file: UploadFile) -> bytes:
    limit = get_settings().max_upload_bytes
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise ApiError(422, "FILE_TOO_LARGE", "the file is larger than allowed", max_bytes=limit)
    return data


@platform.get("/rules")
async def list_rules(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"rules": await photo.list_rules(conn)}


@platform.post("/rules", status_code=201)
async def propose_rule(body: RuleIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        if body.market and not await conn.fetchval("SELECT 1 FROM ref.market WHERE country_code = $1", body.market):
            raise ApiError(422, "MARKET_UNKNOWN", "the market is not one this platform operates in", market=body.market)
        uid = await photo.propose_rule(conn, pr, body)
        rule_id = (await photo.rule_row(conn, uuid.UUID(uid)))["id"]
    request.state.audit = {"action": "photo.rule_propose", "object_type": "photo_rule", "object_id": rule_id}
    return {"uid": uid, "status": "PROPOSED"}


class RetirementIn(BaseModel):
    reason: str = Field(min_length=10, max_length=500)


@platform.post("/rules/{uid}/approve")
async def approve_rule(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """Records this person's stage of a proposal; the rule is in force at the last stage (1092)."""
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await photo.approve_rule(conn, pr, uid)
    action = "photo.rule_approve" if out["status"] == "APPROVED" else "photo.rule_stage"
    request.state.audit = {"action": action, "object_type": "photo_rule", "object_id": out["rule_id"]}
    return {"status": out["status"], "approvals": out["approvals"], "stages": out["stages"]}


@platform.post("/rules/{uid}/withdraw")
async def withdraw_rule(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rule_id = await photo.withdraw_rule(conn, pr, uid)
    request.state.audit = {"action": "photo.rule_withdraw", "object_type": "photo_rule", "object_id": rule_id}
    return {"status": "RETIRED"}


@platform.post("/rules/{uid}/retirement", status_code=201)
async def request_retirement(uid: uuid.UUID, body: RetirementIn, request: Request,
                             pr: Principal = Depends(require_portal("PLATFORM"))):
    """Asks to retire a rule in force; it stays in force until the retirement passes the stages (1092)."""
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rule_id = await photo.request_retirement(conn, pr, uid, body.reason)
    request.state.audit = {"action": "photo.rule_retirement_request", "object_type": "photo_rule", "object_id": rule_id}
    return {"status": "RETIRING", "approvals": 0}


@platform.post("/rules/{uid}/retirement/approve")
async def approve_retirement(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await photo.approve_retirement(conn, pr, uid)
    action = "photo.rule_retired" if out["status"] == "RETIRED" else "photo.rule_retirement_stage"
    request.state.audit = {"action": action, "object_type": "photo_rule", "object_id": out["rule_id"]}
    return {"status": out["status"], "approvals": out["approvals"], "stages": out["stages"]}


@platform.post("/rules/{uid}/retirement/reject")
async def reject_retirement(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rule_id = await photo.reject_retirement(conn, pr, uid)
    request.state.audit = {"action": "photo.rule_retirement_reject", "object_type": "photo_rule", "object_id": rule_id}
    return {"status": "APPROVED"}


class EvidenceChangeIn(BaseModel):
    active: bool
    reason: str = Field(min_length=10, max_length=500)


class AgeChangeIn(BaseModel):
    min_age: Optional[int] = Field(default=None, ge=0, le=120)     # null: no age rule
    reason: str = Field(min_length=10, max_length=500)


class RequirementIn(BaseModel):
    requirement: Literal["REQUIRED", "OPTIONAL"]
    reason: str = Field(min_length=10, max_length=500)


@platform.get("/evidence-kinds")
async def settings(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """What the platform sets for a photo change: the accepted documents, the age rule, the approval stages and the data
    items that are required or optional (1088-1091)."""
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await photo.settings_view(conn)


@platform.post("/evidence-kinds/{code}/changes", status_code=201)
async def request_evidence_change(code: str, body: EvidenceChangeIn, request: Request,
                                  pr: Principal = Depends(require_portal("PLATFORM"))):
    """Asks to switch a kind of evidence on or off; it passes the approval stages (1089, 1091)."""
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        uid, change_id = await photo.request_evidence_change(conn, pr, code, body.active, body.reason)
    request.state.audit = {"action": "photo.policy_request", "object_type": "photo_policy_change", "object_id": change_id}
    return {"uid": uid, "status": "PENDING", "approvals": 0}


@platform.post("/identity-age/changes", status_code=201)
async def request_identity_age(body: AgeChangeIn, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """Asks to set (or clear) the age below which a national identity card is not accepted; it passes the stages."""
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        uid, change_id = await photo.request_identity_age(conn, pr, body.min_age, body.reason)
    request.state.audit = {"action": "photo.policy_request", "object_type": "photo_policy_change", "object_id": change_id}
    return {"uid": uid, "status": "PENDING", "approvals": 0}


@platform.post("/data-requirements/{field}/changes", status_code=201)
async def request_data_requirement(field: str, body: RequirementIn, request: Request,
                                   pr: Principal = Depends(require_portal("PLATFORM"))):
    """Asks to set a data item as required or optional for a photo change; the approval stages decide (1091)."""
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        uid, change_id = await photo.request_data_requirement(conn, pr, field, body.requirement, body.reason)
    request.state.audit = {"action": "photo.policy_request", "object_type": "photo_policy_change", "object_id": change_id}
    return {"uid": uid, "status": "PENDING", "approvals": 0}


@platform.get("/policy-changes")
async def list_policy_changes(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"changes": await photo.list_policy_changes(conn)}


@platform.post("/policy-changes/{uid}/approve")
async def approve_policy_change(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await photo.approve_policy_change(conn, pr, uid)
    action = "photo.policy_approve" if out["status"] == "APPLIED" else "photo.policy_stage"
    request.state.audit = {"action": action, "object_type": "photo_policy_change", "object_id": out["change_id"]}
    return {"status": out["status"], "approvals": out["approvals"], "stages": out["stages"]}


@platform.post("/policy-changes/{uid}/reject")
async def reject_policy_change(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        change_id = await photo.reject_policy_change(conn, pr, uid)
    request.state.audit = {"action": "photo.policy_reject", "object_type": "photo_policy_change", "object_id": change_id}
    return {"status": "REJECTED"}


@platform.get("/changes")
async def list_changes(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"changes": await photo.list_changes(conn)}


@platform.post("/changes", status_code=201)
async def request_change(request: Request, party_uid: uuid.UUID = Form(...),
                         reason: str = Form(..., min_length=10, max_length=500),
                         evidence_kind: str = Form(..., min_length=3, max_length=40),
                         evidence: UploadFile = File(...), new_photo: UploadFile = File(...),
                         pr: Principal = Depends(require_portal("PLATFORM"))):
    """Asks for the photo on file to be replaced: the evidence (an extract that carries the photo, or an identity
    document) and the new photo. A second platform person applies it; the requester cannot."""
    privacy_staff(pr)
    evidence_data, photo_data = await _read(evidence), await _read(new_photo)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        uid, party_id = await photo.request_change(conn, ctx, pr, party_uid, reason, evidence_kind, evidence_data,
                                                   evidence.filename or "evidence", photo_data, new_photo.filename or "photo")
    request.state.audit = {"action": "photo.change_request", "object_type": "party", "object_id": party_id}
    return {"uid": uid, "status": "PENDING"}


@platform.post("/changes/{uid}/approve")
async def approve_change(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """Records this person's stage of the change; the photo is replaced at the last stage (1091)."""
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await photo.approve_change(conn, pr, uid)
    action = "photo.change_apply" if out["status"] == "APPLIED" else "photo.change_stage"
    request.state.audit = {"action": action, "object_type": "party", "object_id": out["party_id"]}
    return {"status": out["status"], "approvals": out["approvals"], "stages": out["stages"]}


@platform.post("/changes/{uid}/reject")
async def reject_change(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        party_id = await photo.reject_change(conn, pr, uid)
    request.state.audit = {"action": "photo.change_reject", "object_type": "party", "object_id": party_id}
    return {"status": "REJECTED"}


@platform.get("/changes/{uid}/evidence")
async def read_evidence(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    """The evidence of a change request, for the second person who checks it. Every read is audited."""
    privacy_staff(pr)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        data, mime, party_id = await photo.read_evidence(conn, ctx, uid)
    request.state.audit = {"action": "photo.evidence_view", "object_type": "party", "object_id": party_id}
    return Response(content=data, media_type=mime)
