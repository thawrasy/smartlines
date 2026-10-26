"""Users and roles API (owner's request N1, 1154): /api/people, the same section in the platform, carrier, agency and
station portals. Each call works on the people the signed-in administrator manages (the platform's staff, or their own
company's); giving roles and deciding exceptions are sensitive and ask for a recent second factor."""
import uuid

from fastapi import APIRouter, Depends, Request

from ... import db
from ...deps import Principal, context_for, require_step_up, require_user
from . import service

router = APIRouter(prefix="/api/people", tags=["people"])


@router.get("/catalog")
async def catalog(request: Request, pr: Principal = Depends(require_user)):
    """The permissions of this portal, each marked whether the administrator may give it."""
    async with db.transaction(context_for(request, pr)) as conn:
        return await service.catalog(conn, pr)


@router.get("/roles")
async def roles(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"roles": await service.roles(conn, pr)}


@router.post("/roles", status_code=201)
async def create_role(body: service.RoleIn, request: Request, pr: Principal = Depends(require_user)):
    require_step_up(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.create_role(conn, pr, body)
    request.state.audit = {"action": "people.role_create", "object_type": "role", "object_id": None}
    return out


@router.put("/roles/{uid}")
async def update_role(uid: uuid.UUID, body: service.RoleUpdate, request: Request, pr: Principal = Depends(require_user)):
    require_step_up(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.update_role(conn, pr, uid, body)
    request.state.audit = {"action": "people.role_update", "object_type": "role", "object_id": None}
    return out


@router.get("/users")
async def users(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"users": await service.users(conn, pr)}


@router.post("/users", status_code=201)
async def add_user(body: service.UserIn, request: Request, pr: Principal = Depends(require_user)):
    """A new member of staff with a temporary password the administrator chose, changed at the first sign-in (N16)."""
    from ...errors import ApiError
    from ...security import password_problem
    require_step_up(pr)
    problem = password_problem(body.password, str(body.email), body.full_name, body.mobile)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.add_user(conn, pr, body)
    request.state.audit = {"action": "people.user_create", "object_type": "app_user", "object_id": out.pop("user_id")}
    return out


@router.put("/users/{uid}")
async def update_user(uid: uuid.UUID, body: service.UserUpdate, request: Request, pr: Principal = Depends(require_user)):
    require_step_up(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await service.update_user(conn, pr, uid, body)
    request.state.audit = {"action": "people.user_update", "object_type": "app_user", "object_id": None}
    return {"ok": True}


@router.get("/exceptions")
async def exceptions(request: Request, pr: Principal = Depends(require_user)):
    async with db.transaction(context_for(request, pr)) as conn:
        return {"exceptions": await service.exceptions(conn, pr)}


@router.post("/users/{uid}/exceptions", status_code=201)
async def request_exception(uid: uuid.UUID, body: service.ExceptionIn, request: Request, pr: Principal = Depends(require_user)):
    """Asks to grant or deny one permission to a person until a date; a second administrator approves it."""
    require_step_up(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.request_exception(conn, pr, uid, body)
    request.state.audit = {"action": "people.exception_request", "object_type": "permission_exception", "object_id": None,
                           "reason": body.reason}
    return out


@router.post("/exceptions/{uid}/{action}")
async def decide(uid: uuid.UUID, action: str, body: service.DecisionIn, request: Request, pr: Principal = Depends(require_user)):
    from ...errors import not_found
    if action not in ("approve", "reject", "revoke"):
        raise not_found("action")
    require_step_up(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        out = await service.decide(conn, pr, uid, action, body.note)
    request.state.audit = {"action": f"people.exception_{action}", "object_type": "permission_exception", "object_id": None}
    return out
