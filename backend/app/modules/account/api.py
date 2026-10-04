"""Account API: /api/account for every signed-in person, /api/admin/privacy for privacy staff."""
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal, require_user
from . import service

router = APIRouter(prefix="/api/account", tags=["account"])
platform = APIRouter(prefix="/api/admin/privacy", tags=["account"])


@router.get("/security")
async def security(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.security(conn, pr)


@router.post("/sessions/{session_id}/revoke")
async def revoke(session_id: int, request: Request, pr: Principal = Depends(require_user)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await service.revoke_session(conn, ctx, pr, session_id)
    return {"ok": True}


@router.post("/sessions/revoke-others")
async def revoke_others(request: Request, pr: Principal = Depends(require_user)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return {"ok": True, "revoked": await service.revoke_others(conn, ctx, pr)}


class PasswordIn(BaseModel):
    current_password: str = Field(min_length=1, max_length=200)
    new_password: str = Field(min_length=1, max_length=200)


@router.post("/password")
async def change_password(body: PasswordIn, request: Request, pr: Principal = Depends(require_user)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await service.change_password(conn, ctx, pr, body.current_password, body.new_password)
    return {"ok": True}


@router.get("/consents")
async def consents(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"consents": await service.consents(conn, pr), "policy_version": service.POLICY_VERSION}


class ConsentIn(BaseModel):
    purpose: Literal["MARKETING", "LOCATION", "PARTNER_SHARING"]
    granted: bool


@router.post("/consents")
async def set_consent(body: ConsentIn, request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        await service.set_consent(conn, pr, body.purpose, body.granted)
    return {"ok": True}


@router.get("/export")
async def export(request: Request, pr: Principal = Depends(require_user)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        data = await service.export(conn, ctx, pr)
    request.state.audit = {"action": "privacy.export", "object_type": "party", "object_id": pr.party_id}
    return JSONResponse(data, headers={"Content-Disposition": 'attachment; filename="masslak-my-data.json"',
                                       "Cache-Control": "no-store"})


class ErasureIn(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=300)


@router.get("/requests")
async def requests(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"requests": await service.requests(conn, pr)}


@router.post("/erasure", status_code=201)
async def erasure(body: ErasureIn, request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await service.request_erasure(conn, pr, body.reason)
    request.state.audit = {"action": "privacy.erasure_request", "object_type": "party", "object_id": pr.party_id}
    return {"uid": uid}


@platform.get("/requests")
async def open_requests(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    service.privacy_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"requests": await service.open_requests(conn)}


@platform.post("/requests/{request_uid}/complete")
async def complete(request_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    async with db.transaction(context_for(request, pr)) as conn:
        rid = await service.complete_erasure(conn, pr, request_uid)
    request.state.audit = {"action": "privacy.erasure_done", "object_type": "subject_request", "object_id": rid}
    return {"ok": True}
