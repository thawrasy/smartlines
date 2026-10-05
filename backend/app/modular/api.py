"""Module switches and the resource endpoints of the modules.

    GET  /api/features                       public: which modules are switched on
    GET  /api/modules                        the caller's modules and their resources (menus)
    GET  /api/admin/modules                  platform: every module with its state
    PUT  /api/admin/modules/{key}            platform: switch a module on or off (modules.manage)
    GET  /api/r/{res}/_spec                  columns, choices, references and actions of a resource
    GET  /api/r/{res}                        list (?q=, ?f_<column>=, ?limit=, ?offset=)
    POST /api/r/{res}                        create
    GET  /api/r/{res}/{key}                  read
    PATCH /api/r/{res}/{key}                 update
    DELETE /api/r/{res}/{key}                delete (where allowed)
    POST /api/r/{res}/{key}/do/{action}      state action
    GET  /api/r/{res}/lookup/{column}        choices for a reference column
    GET  /api/m/{module}/dashboard           tiles, breakdowns, trend and latest records for the caller's portal
"""
import json
import re
from typing import Optional

from fastapi import APIRouter, Body, Depends, Query, Request
from pydantic import BaseModel

from .. import db
from ..deps import Principal, context_for, optional_principal, require_permission, require_user
from ..errors import ApiError, not_found
from . import dashboards, engine, features
from .registry import BY_KEY, MODULES
from .specs import RESOURCES

router = APIRouter(tags=["modules"])
KEY_RE = re.compile(r"^[A-Za-z0-9_~:.@+,()\[\] -]{1,160}$")


def _resource(key: str) -> engine.Resource:
    res = RESOURCES.get(key)
    if res is None:
        raise not_found("resource")
    return res


async def _ready(res: engine.Resource, pr: Principal, write: bool = False) -> None:
    if not await features.is_on(res.module):
        raise ApiError(404, "MODULE_DISABLED", f"module {res.module} is switched off")
    engine.check_access(res, pr, write)


@router.get("/api/features")
async def public_features():
    return {"enabled": sorted(k for k, v in (await features.load()).items() if v)}


@router.get("/api/modules")
async def my_modules(pr: Optional[Principal] = Depends(optional_principal)):
    state = await features.load()
    portal = pr.portal if pr and not pr.mfa_pending else None
    out = []
    for m in MODULES:
        if not state.get(m.key):
            continue
        resources = []
        if portal:
            for r in RESOURCES.values():
                perm = r.perm_for(portal)
                if r.module == m.key and perm is not False and (not perm or perm in pr.permissions):
                    resources.append({"key": r.key, "group": r.group})
        if portal is None or portal in m.portals:
            out.append({"key": m.key, "phase": m.phase, "icon": m.icon, "resources": resources})
    return {"enabled": sorted(k for k, v in state.items() if v), "modules": out}


@router.get("/api/admin/modules")
async def all_modules(pr: Principal = Depends(require_permission("modules.manage"))):
    state = await features.load(fresh=True)
    known = {m.key for m in MODULES}
    return {"modules": [{"key": m.key, "phase": m.phase, "icon": m.icon, "portals": list(m.portals),
                         "enabled": state.get(m.key, False),
                         "resources": sum(1 for r in RESOURCES.values() if r.module == m.key)} for m in MODULES],
            "other_flags": {k: v for k, v in state.items() if k not in known}}


class SwitchIn(BaseModel):
    enabled: bool
    reason: str = ""


@router.put("/api/admin/modules/{key}")
async def switch_module(key: str, body: SwitchIn, request: Request,
                        pr: Principal = Depends(require_permission("modules.manage"))):
    if key not in BY_KEY:
        raise not_found("module")
    if len(body.reason.strip()) < 3:
        raise ApiError(422, "REASON_REQUIRED", "give a reason for the change")
    async with db.transaction(context_for(request, pr)) as conn:
        await conn.execute(
            "UPDATE sys.setting SET value = jsonb_set(value, ARRAY[$1], to_jsonb($2::boolean)), updated_at = now(), "
            "updated_by = $3 WHERE key = 'features'", key, body.enabled, pr.user_id)
        await features.load(conn, fresh=True)
    features.invalidate()
    request.state.audit = {"action": "module.enable" if body.enabled else "module.disable", "object_type": "module",
                           "reason": body.reason.strip()[:200]}
    return {"key": key, "enabled": body.enabled}


# ------------------------------------------------------------------ resources
@router.get("/api/r/{res_key}/_spec")
async def spec(res_key: str, request: Request, pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await engine.describe(conn, res, pr)


@router.get("/api/r/{res_key}")
async def list_resource(res_key: str, request: Request, q: Optional[str] = Query(default=None, max_length=80),
                        limit: int = Query(default=50, ge=1, le=200), offset: int = Query(default=0, ge=0, le=100000),
                        pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr)
    filters = {k[2:]: v for k, v in request.query_params.items() if k.startswith("f_")}
    async with db.transaction(context_for(request, pr)) as conn:
        return await engine.list_rows(conn, res, pr, q, filters, limit, offset)


@router.get("/api/r/{res_key}/lookup/{column}")
async def lookup(res_key: str, column: str, request: Request, q: Optional[str] = Query(default=None, max_length=80),
                 pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr)
    if column not in res.form and column not in res.list and column not in res.filters:
        raise not_found("column")
    async with db.transaction(context_for(request, pr)) as conn:
        meta = await engine.table_meta(conn, res.table)
        ref = meta.cols[column].ref if column in meta.cols else None
        if not ref:
            raise not_found("reference")
        return {"options": await engine.lookup(conn, ref, q, key=meta.cols[column].ref_col)}


@router.post("/api/r/{res_key}", status_code=201)
async def create(res_key: str, request: Request, body: dict = Body(...), pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr, write=True)
    async with db.transaction(context_for(request, pr)) as conn:
        row = await engine.create_row(conn, res, pr, body)
    request.state.audit = {"action": f"{res.key}.create", "object_type": res.table, "reason": "key " + str(row["_key"])}
    return row


def _key(key: str) -> str:
    if not KEY_RE.match(key):
        raise not_found("record")
    return key


@router.get("/api/r/{res_key}/{key}")
async def read(res_key: str, key: str, request: Request, pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await engine.get_row(conn, res, _key(key))


@router.patch("/api/r/{res_key}/{key}")
async def update(res_key: str, key: str, request: Request, body: dict = Body(...), pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr, write=True)
    async with db.transaction(context_for(request, pr)) as conn:
        row = await engine.update_row(conn, res, pr, _key(key), body)
    request.state.audit = {"action": f"{res.key}.update", "object_type": res.table, "reason": ("key " + key + " fields " + json.dumps(sorted(body)))[:250]}
    return row


@router.delete("/api/r/{res_key}/{key}")
async def delete(res_key: str, key: str, request: Request, pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr, write=True)
    async with db.transaction(context_for(request, pr)) as conn:
        await engine.delete_row(conn, res, _key(key))
    request.state.audit = {"action": f"{res.key}.delete", "object_type": res.table, "reason": "key " + key}
    return {"ok": True}


@router.post("/api/r/{res_key}/{key}/do/{action}")
async def act(res_key: str, key: str, action: str, request: Request, pr: Principal = Depends(require_user)):
    res = _resource(res_key)
    await _ready(res, pr, write=True)
    async with db.transaction(context_for(request, pr)) as conn:
        row = await engine.run_action(conn, res, pr, _key(key), action)
    request.state.audit = {"action": f"{res.key}.{action}", "object_type": res.table, "reason": "key " + key}
    return row


@router.get("/api/m/{module}/dashboard")
async def dashboard(module: str, request: Request, pr: Principal = Depends(require_user)):
    if module not in BY_KEY or pr.portal not in BY_KEY[module].portals:
        raise not_found("module")
    if not await features.is_on(module):
        raise ApiError(404, "MODULE_DISABLED", f"module {module} is switched off")
    async with db.transaction(context_for(request, pr)) as conn:
        return await dashboards.build(conn, module, pr)
