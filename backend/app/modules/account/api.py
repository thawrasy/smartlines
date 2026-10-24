"""Account API: /api/account for every signed-in person, /api/admin/privacy for privacy staff."""
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, File, Request, Response, UploadFile
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from ... import db
from ...config import get_settings
from ...deps import Principal, context_for, require_portal, require_session, require_user, require_step_up
from ...errors import ApiError
from ..photo import service as photo
from . import names, service

router = APIRouter(prefix="/api/account", tags=["account"])
platform = APIRouter(prefix="/api/admin/privacy", tags=["account"])


@router.get("/profile")
async def profile(request: Request, pr: Principal = Depends(require_user)):
    """The person's name in parts and its rules (N4), the e-mail's confirmation (N35) and the account's verification."""
    async with db.transaction(context_for(request, pr)) as conn:
        person = await names.of_party(conn, pr.party_id)
        verified = await conn.fetchval("SELECT email_verified_at IS NOT NULL FROM iam.app_user WHERE id = $1", pr.user_id)
        return {"name": {k: person.get(k) for k in ("nationality", "first_name", "father_name", "grandfather_name", "last_name",
                                                     "mother_name", "first_name_latin", "father_name_latin",
                                                     "grandfather_name_latin", "last_name_latin")},
                "names_complete": person.get("names_complete"), "verification_status": person.get("verification_status"),
                "email": pr.email, "email_verified": verified, "rules": await names.rules(conn)}


@router.put("/names")
async def set_names(body: names.NameIn, request: Request, pr: Principal = Depends(require_user)):
    """The person gives or corrects their name parts. Once the account is verified (KYC), the name follows the
    document reviewed and is changed through a new review, not here."""
    async with db.transaction(context_for(request, pr)) as conn:
        status = await conn.fetchval("SELECT verification_status FROM iam.party WHERE id = $1", pr.party_id)
        if status == "VERIFIED":
            raise ApiError(409, "NAME_LOCKED", "the account is verified: a change of name goes through a new identity review")
        names.check(await names.rules(conn), body)
        await names.save(conn, pr.party_id, body)
    request.state.audit = {"action": "account.names", "object_type": "party", "object_id": pr.party_id}
    return {"ok": True, "name": names.full_of(body)}


class CodeIn(BaseModel):
    code: str = Field(pattern=r"^\s*[0-9]{6}\s*$")


@router.post("/email/send")
async def send_email_code(request: Request, pr: Principal = Depends(require_user)):
    """Another code to confirm the account's e-mail."""
    from ...routers.auth import send_email_code as deliver
    async with db.transaction(context_for(request, pr)) as conn:
        if await conn.fetchval("SELECT email_verified_at IS NOT NULL FROM iam.app_user WHERE id = $1", pr.user_id):
            return {"ok": True, "already": True}
        if not pr.email:
            raise ApiError(409, "NO_EMAIL", "the account has no e-mail")
        code, minutes = await names.issue_email_code(conn, pr.user_id)
    return {"ok": True, "sent": await deliver(pr.email, code, minutes, pr.locale)}


@router.post("/email/verify")
async def verify_email(body: CodeIn, request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        ok = await names.confirm_email(conn, pr.user_id, body.code)
    if not ok:
        raise ApiError(422, "CODE_WRONG", "the code is wrong or has expired; ask for another one")
    request.state.audit = {"action": "account.email_verified", "object_type": "app_user", "object_id": pr.user_id}
    return {"ok": True}


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


class DeactivateIn(BaseModel):
    password: str = Field(min_length=1, max_length=200)


@router.post("/deactivate")
async def deactivate(body: DeactivateIn, request: Request, pr: Principal = Depends(require_user)):
    """Closes the account, keeping its data (1085): reactivated by signing in again with the same details."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await service.deactivate(conn, ctx, pr, body.password)
    request.state.audit = {"action": "account.deactivate", "object_type": "party", "object_id": pr.party_id}
    return {"ok": True}


@router.get("/photo")
async def photo_status(request: Request, pr: Principal = Depends(require_user)):
    """Whether a boarding photo is on file for the signed-in person (1086)."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await photo.status(conn, ctx, pr)


@router.post("/photo", status_code=201)
async def take_photo(request: Request, file: UploadFile = File(...), pr: Principal = Depends(require_user)):
    """The passenger's own boarding photo (1086): taken at the profile's creation, kept while the account exists."""
    limit = get_settings().max_upload_bytes
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise ApiError(422, "FILE_TOO_LARGE", "the photo is larger than allowed", max_bytes=limit)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        out = await photo.take(conn, ctx, pr, data, file.filename or "photo", pr.party_id)
    request.state.audit = {"action": "photo.upload", "object_type": "party", "object_id": out["party_id"]}
    return {"taken_by": out["taken_by"]}


@router.get("/photo/image")
async def my_photo_image(request: Request, pr: Principal = Depends(require_user)):
    """The traveler's own boarding photo, on request in the app (1096), when the platform lets the traveler see it."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        data, mime = await photo.read_own(conn, ctx, pr)
    request.state.audit = {"action": "photo.view", "object_type": "party", "object_id": pr.party_id}
    return Response(content=data, media_type=mime)


@router.post("/photo/verify")
async def verify_photo_identity(request: Request, pr: Principal = Depends(require_user)):
    """Checks the person with the identity provider the platform holds (1096). Refused until one is connected."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return await photo.verify_identity(conn, pr)


@router.post("/password/first")
async def first_password(body: PasswordIn, request: Request, pr: Principal = Depends(require_session)):
    """The temporary password set by an administrator is replaced here, before the second factor and anything else
    (N16, 1150)."""
    if not pr.password_must_change:
        raise ApiError(409, "PASSWORD_NOT_TEMPORARY", "this password was chosen by you; change it from the account page")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await service.change_password(conn, ctx, pr, body.current_password, body.new_password)
    return {"ok": True}


@router.post("/password")
async def change_password(body: PasswordIn, request: Request, pr: Principal = Depends(require_user)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await service.change_password(conn, ctx, pr, body.current_password, body.new_password)
    return {"ok": True}


@router.get("/devices")
async def devices(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"devices": await service.devices(conn, pr)}


@router.post("/devices/{device_id}/revoke")
async def revoke_device(device_id: int, request: Request, pr: Principal = Depends(require_user)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        await service.revoke_device(conn, ctx, pr, device_id)
    return {"ok": True}


class PushIn(BaseModel):
    token: str = Field(min_length=10, max_length=300, pattern=r"^[A-Za-z0-9_:\-\[\]\.]+$")


@router.post("/push-token")
async def push_token(body: PushIn, request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        await service.register_push(conn, pr, body.token)
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
    require_step_up(pr)                 # a sensitive operation: a recent second factor (1136)
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
