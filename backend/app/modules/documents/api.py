"""Document API: /api/company/documents for carrier and agency staff, /api/admin/documents for platform review."""
import uuid
from datetime import date
from typing import Literal, Optional
from urllib.parse import quote

from fastapi import APIRouter, Depends, File, Form, Query, Request, UploadFile
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ... import db
from ...config import get_settings
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError
from . import service

company = APIRouter(prefix="/api/company/documents", tags=["documents"])
platform = APIRouter(prefix="/api/admin/documents", tags=["documents"])
staff = require_portal("OPERATOR", "AGENCY")
reviewer = require_portal("PLATFORM")


def _file_response(data: bytes, mime: str, name: str) -> Response:
    # Served as an attachment with its detected type and no sniffing, so an uploaded file never renders as a page
    return Response(data, media_type=mime, headers={
        "Content-Disposition": f"attachment; filename*=UTF-8''{quote(name)}",
        "X-Content-Type-Options": "nosniff", "Cache-Control": "no-store"})


@company.get("")
async def documents(request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"documents": await service.company_documents(conn, pr), "types": service.DOC_TYPES}


@company.post("", status_code=201)
async def upload(request: Request, pr: Principal = Depends(staff), file: UploadFile = File(...),
                 doc_type: str = Form(..., max_length=40), issuer: Optional[str] = Form(default=None, max_length=160),
                 issue_date: Optional[date] = Form(default=None), expiry_date: Optional[date] = Form(default=None),
                 vehicle_uid: Optional[uuid.UUID] = Form(default=None)):
    limit = get_settings().max_upload_bytes
    data = await file.read(limit + 1)
    if len(data) > limit:
        raise ApiError(422, "FILE_TOO_LARGE", "the file is larger than allowed", max_bytes=limit)
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        doc_id, uid = await service.upload(conn, ctx, pr, doc_type, data, file.filename or "document", issuer,
                                           issue_date, expiry_date, vehicle_uid)
    request.state.audit = {"action": "document.upload", "object_type": "document", "object_id": doc_id}
    return {"uid": uid}


@company.get("/{doc_uid}/file")
async def own_file(doc_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return _file_response(*await service.read_file(conn, ctx, pr, doc_uid, "owner download"))


@platform.get("")
async def queue(request: Request, pr: Principal = Depends(reviewer),
                status: Optional[Literal["PENDING", "APPROVED", "REJECTED"]] = Query(default="PENDING")):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"documents": await service.review_queue(conn, pr, status)}


@platform.get("/{doc_uid}/file")
async def review_file(doc_uid: uuid.UUID, request: Request, pr: Principal = Depends(reviewer)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        return _file_response(*await service.read_file(conn, ctx, pr, doc_uid, "document review"))


class DecisionIn(BaseModel):
    decision: Literal["APPROVE", "REJECT"]
    note: Optional[str] = Field(default=None, max_length=300)


@platform.post("/{doc_uid}/decision")
async def decide(doc_uid: uuid.UUID, body: DecisionIn, request: Request, pr: Principal = Depends(reviewer)):
    async with db.transaction(context_for(request, pr)) as conn:
        doc_id = await service.decide(conn, pr, doc_uid, body.decision == "APPROVE", body.note)
    request.state.audit = {"action": f"document.{body.decision.lower()}", "object_type": "document", "object_id": doc_id,
                           "reason": body.note}
    return {"ok": True}
