"""Registries API (N6, N9, 1156).
    GET  /api/registry/{banks|insurers}                    reviewed entries companies pick from (banks with branches)
    GET  /api/admin/registry/{banks|insurers}              every entry with its review and any proposed change
    POST /api/admin/registry/{banks|insurers}              a new entry, waiting for another person's review
    PUT  /api/admin/registry/{kind}/{uid}                  correct an entry before review, or propose a change after it
    POST /api/admin/registry/{kind}/{uid}/review           ACCEPT or REJECT a new entry or a proposed change (another person)
    POST /api/admin/registry/{kind}/{uid}/retire           out of the pickers
    POST /api/admin/registry/{kind}/import                 the owner's table (.xlsx); every row waits for review
    POST /api/admin/registry/banks/{uid}/branches          a branch of a bank, reviewed by another person
    POST /api/admin/registry/branches/{uid}/review
"""
import uuid
from fastapi import APIRouter, Depends, File, Request, UploadFile

from ... import db
from ...deps import Principal, context_for, require_portal, require_step_up, require_user
from ...errors import ApiError
from . import importer, service
from .service import BankIn, BranchIn, InsurerIn, Kind, ReviewIn

router = APIRouter(prefix="/api/registry", tags=["registry"])
platform = APIRouter(prefix="/api/admin/registry", tags=["registry"])
staff = require_portal("PLATFORM")


@router.get("/{kind}")
async def picker(kind: Kind, request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {kind: await service.listing(conn, pr, kind)}


@platform.get("/{kind}")
async def listing(kind: Kind, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {kind: await service.listing(conn, pr, kind)}


@platform.post("/banks", status_code=201)
async def create_bank(body: BankIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.create(conn, pr, "banks", body)
    request.state.audit = {"action": "registry.bank_create", "object_type": "bank", "object_id": None}
    return out


@platform.post("/insurers", status_code=201)
async def create_insurer(body: InsurerIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.create(conn, pr, "insurers", body)
    request.state.audit = {"action": "registry.insurer_create", "object_type": "insurer", "object_id": None}
    return out


@platform.put("/banks/{uid}")
async def change_bank(uid: uuid.UUID, body: BankIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.change(conn, pr, "banks", uid, body)
    request.state.audit = {"action": "registry.bank_change", "object_type": "bank", "object_id": None}
    return out


@platform.put("/insurers/{uid}")
async def change_insurer(uid: uuid.UUID, body: InsurerIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.change(conn, pr, "insurers", uid, body)
    request.state.audit = {"action": "registry.insurer_change", "object_type": "insurer", "object_id": None}
    return out


@platform.post("/branches/{uid}/review")
async def review_branch(uid: uuid.UUID, body: ReviewIn, request: Request, pr: Principal = Depends(staff)):
    require_step_up(pr)                 # what companies' money and policies point to: a recent second factor
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.review_branch(conn, pr, uid, body)
    request.state.audit = {"action": "registry.branch_review", "object_type": "bank_branch", "object_id": None, "reason": body.decision}
    return out


@platform.post("/banks/{uid}/branches", status_code=201)
async def add_branch(uid: uuid.UUID, body: BranchIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.add_branch(conn, pr, uid, body)
    request.state.audit = {"action": "registry.branch_create", "object_type": "bank_branch", "object_id": None}
    return out


@platform.post("/{kind}/import")
async def load(kind: Kind, request: Request, file: UploadFile = File(...), pr: Principal = Depends(staff)):
    service.need(pr)
    data = await file.read(importer.MAX_FILE + 1)
    if len(data) > importer.MAX_FILE:
        raise ApiError(413, "REGISTRY_FILE_TOO_LARGE", "the workbook is larger than 5 MB")
    try:
        items = importer.read(data, kind)
    except importer.RegistryFileError as e:
        code, _, message = str(e).partition(": ")
        raise ApiError(422, code, message) from e
    created, skipped = [], []
    async with db.transaction(context_for(request, pr)) as conn:
        table = service.TABLE[kind]
        for item in items:
            body = item["body"]
            if await conn.fetchval(f"SELECT 1 FROM {table} WHERE code = $1", body.code):
                skipped.append(body.code)
                continue
            await service.create(conn, pr, kind, body, source="IMPORT", swift_reported=item["swift_reported"])
            created.append(body.code)
    request.state.audit = {"action": f"registry.{kind}_import", "object_type": kind, "object_id": None,
                           "reason": f"{len(created)} created, {len(skipped)} skipped"}
    return {"created": created, "skipped": skipped}


@platform.post("/{kind}/{uid}/review")
async def review(kind: Kind, uid: uuid.UUID, body: ReviewIn, request: Request, pr: Principal = Depends(staff)):
    require_step_up(pr)                 # what companies' money and policies point to: a recent second factor
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.review(conn, pr, kind, uid, body)
    request.state.audit = {"action": f"registry.{kind}_review", "object_type": kind, "object_id": None, "reason": body.decision}
    return out


@platform.post("/{kind}/{uid}/retire")
async def retire(kind: Kind, uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.retire(conn, pr, kind, uid)
    request.state.audit = {"action": f"registry.{kind}_retire", "object_type": kind, "object_id": None}
    return out
