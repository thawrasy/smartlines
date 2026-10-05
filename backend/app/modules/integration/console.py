"""The integration console: platform security manages every client; company owners manage their own.

    GET  /api/integrations/meta                         scopes, kinds, events, and for the platform: companies, providers, authorities
    GET  /api/integrations/clients                      list (a company sees its own)
    POST /api/integrations/clients                      create (PENDING)
    GET  /api/integrations/clients/{uid}                keys, webhooks, usage, recent deliveries
    PUT  /api/integrations/clients/{uid}                scopes, limits, allowed addresses, mTLS (limits and mTLS: platform)
    POST /api/integrations/clients/{uid}/approve|suspend|reactivate|revoke     platform security (approval: four-eyes)
    POST /api/integrations/clients/{uid}/keys           issue a key (shown once)
    POST /api/integrations/clients/{uid}/keys/{id}/revoke
    POST /api/integrations/clients/{uid}/webhooks       add an endpoint (secret shown once)
    DELETE /api/integrations/clients/{uid}/webhooks/{wuid}
    POST /api/integrations/clients/{uid}/webhooks/{wuid}/rotate | ping
    POST /api/integrations/clients/{uid}/deliveries/{duid}/retry
"""
from __future__ import annotations

import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_user
from ...errors import forbidden
from . import service
from .scopes import EVENTS, KIND_SCOPES, SCOPES

router = APIRouter(prefix="/api/integrations", tags=["integration console"])
KINDS = Literal["CARRIER", "CHANNEL", "PARTNER", "AUTHORITY", "INTEGRATION", "INTERNAL"]
EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


class Console:
    def __init__(self, pr: Principal, company_id: Optional[int], platform: bool):
        self.pr, self.company_id, self.platform = pr, company_id, platform


async def console(pr: Principal = Depends(require_user)) -> Console:
    if pr.portal == "PLATFORM" and "security.api_clients" in pr.permissions:
        return Console(pr, None, True)
    if pr.portal in ("OPERATOR", "AGENCY") and pr.company_id and "company.api_keys" in pr.permissions:
        return Console(pr, pr.company_id, False)
    raise forbidden("missing permission: security.api_clients | company.api_keys")


async def platform_only(c: Console = Depends(console)) -> Console:
    if not c.platform:
        raise forbidden("platform security only")
    return c


class ClientIn(BaseModel):
    name: str = Field(min_length=3, max_length=120)
    kind: KINDS
    scopes: list[str] = Field(max_length=12)
    environment: Literal["SANDBOX", "PRODUCTION"] = "SANDBOX"
    description: Optional[str] = Field(default=None, max_length=500)
    contact_email: Optional[str] = Field(default=None, pattern=EMAIL, max_length=200)
    ip_allowlist: list[str] = Field(default_factory=list, max_length=20)
    company_uid: Optional[uuid.UUID] = None
    acting_email: Optional[str] = Field(default=None, pattern=EMAIL, max_length=200)
    provider_code: Optional[str] = Field(default=None, pattern=r"^[A-Z_]{2,30}$")
    authority_code: Optional[str] = Field(default=None, max_length=40)
    rate_limit_per_min: int = Field(default=600, ge=10, le=6000)


class ClientUpdate(BaseModel):
    scopes: Optional[list[str]] = Field(default=None, max_length=12)
    rate_limit_per_min: Optional[int] = Field(default=None, ge=10, le=6000)
    ip_allowlist: Optional[list[str]] = Field(default=None, max_length=20)
    require_mtls: Optional[bool] = None
    mtls_cert_sha256: Optional[str] = Field(default=None, pattern=r"^([0-9A-Fa-f]{2}:?){31}[0-9A-Fa-f]{2}$")
    description: Optional[str] = Field(default=None, max_length=500)
    contact_email: Optional[str] = Field(default=None, pattern=EMAIL, max_length=200)


class ReasonIn(BaseModel):
    reason: Optional[str] = Field(default=None, max_length=300)


class RevokeIn(BaseModel):
    reason: str = Field(min_length=5, max_length=300)


class EndpointIn(BaseModel):
    url: str = Field(min_length=10, max_length=500)
    events: list[str] = Field(min_length=1, max_length=20)
    include_pii: bool = False


@router.get("/meta")
async def meta(request: Request, c: Console = Depends(console)):
    out = {"scopes": SCOPES, "kinds": {k: sorted(v) for k, v in KIND_SCOPES.items()},
           "events": {e: sorted(k) for e, k in EVENTS.items()}, "platform": c.platform}
    if c.platform:
        async with db.transaction(context_for(request, c.pr)) as conn:
            cos = await conn.fetch("""SELECT p.uid, p.legal_name AS name, c.company_type FROM iam.company c JOIN iam.party p ON p.id = c.id
                                       WHERE c.approval_status = 'APPROVED' ORDER BY p.legal_name LIMIT 1000""")
            pvs = await conn.fetch("SELECT code, name, adapter FROM fin.payment_provider WHERE adapter IN ('API_PARTNER', 'PARTNER_WALLET') ORDER BY sort_order")
            aus = await conn.fetch("SELECT code, name, authority_type FROM sec.authority_profile ORDER BY name")
        out.update(companies=[{**dict(r), "uid": str(r["uid"])} for r in cos], providers=[dict(r) for r in pvs],
                   authorities=[dict(r) for r in aus])
    return out


@router.get("/clients")
async def list_clients(request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        return {"clients": await service.clients(conn, c.company_id)}


@router.post("/clients", status_code=201)
async def create_client(body: ClientIn, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        out = await service.create(conn, c.pr, platform=c.platform, name=body.name, kind=body.kind, scopes=body.scopes,
                                   environment=body.environment, description=body.description, contact_email=body.contact_email,
                                   ip_allowlist=body.ip_allowlist, company_uid=body.company_uid, acting_email=body.acting_email,
                                   provider_code=body.provider_code, authority_code=body.authority_code,
                                   rate_limit=body.rate_limit_per_min)
    request.state.audit = {"action": "api_client.create", "object_type": "iam.api_client", "reason": out["uid"]}
    return out


@router.get("/clients/{uid}")
async def client_detail(uid: uuid.UUID, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        return await service.detail(conn, uid, c.company_id)


@router.put("/clients/{uid}")
async def update_client(uid: uuid.UUID, body: ClientUpdate, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        out = await service.update(conn, c.pr, uid, c.company_id, platform=c.platform, **body.model_dump())
    request.state.audit = {"action": "api_client.update", "object_type": "iam.api_client", "reason": str(uid)}
    return out


@router.post("/clients/{uid}/keys", status_code=201)
async def issue_key(uid: uuid.UUID, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        out = await service.issue_key(conn, c.pr, uid, c.company_id)
    request.state.audit = {"action": "api_key.issue", "object_type": "iam.api_key", "object_id": out["id"]}
    return out


@router.post("/clients/{uid}/keys/{key_id}/revoke")
async def revoke_key(uid: uuid.UUID, key_id: int, body: RevokeIn, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        out = await service.revoke_key(conn, c.pr, uid, key_id, c.company_id, body.reason)
    request.state.audit = {"action": "api_key.revoke", "object_type": "iam.api_key", "object_id": key_id, "reason": body.reason}
    return out


async def _client(conn, c: Console, uid: uuid.UUID):
    return await service.client_row(conn, uid, c.company_id)


@router.post("/clients/{uid}/webhooks", status_code=201)
async def add_webhook(uid: uuid.UUID, body: EndpointIn, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        cl = await _client(conn, c, uid)
        out = await service.add_endpoint(conn, cl["id"], cl["kind"], body.url, body.events, body.include_pii)
    request.state.audit = {"action": "webhook.create", "object_type": "sys.webhook_endpoint", "reason": out["uid"]}
    return out


@router.delete("/clients/{uid}/webhooks/{wuid}")
async def remove_webhook(uid: uuid.UUID, wuid: uuid.UUID, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        cl = await _client(conn, c, uid)
        out = await service.remove_endpoint(conn, cl["id"], wuid)
    request.state.audit = {"action": "webhook.remove", "object_type": "sys.webhook_endpoint", "reason": str(wuid)}
    return out


@router.post("/clients/{uid}/webhooks/{wuid}/{action}")
async def webhook_action(uid: uuid.UUID, wuid: uuid.UUID, action: Literal["rotate", "ping"], request: Request,
                         c: Console = Depends(console)):
    ctx = context_for(request, c.pr)
    async with db.transaction(ctx) as conn:
        cl = await _client(conn, c, uid)
        out = await (service.rotate_secret(conn, cl["id"], wuid) if action == "rotate" else service.ping(conn, ctx, cl["id"], wuid))
    request.state.audit = {"action": f"webhook.{action}", "object_type": "sys.webhook_endpoint", "reason": str(wuid)}
    return out


@router.post("/clients/{uid}/deliveries/{duid}/retry")
async def retry_delivery(uid: uuid.UUID, duid: uuid.UUID, request: Request, c: Console = Depends(console)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        cl = await _client(conn, c, uid)
        return await service.redeliver(conn, cl["id"], duid)


# last: its {action} segment would otherwise shadow the fixed paths above
@router.post("/clients/{uid}/{action}")
async def decide(uid: uuid.UUID, action: Literal["approve", "suspend", "reactivate", "revoke"], body: ReasonIn, request: Request,
                 c: Console = Depends(platform_only)):
    async with db.transaction(context_for(request, c.pr)) as conn:
        out = await service.decide(conn, c.pr, uid, action, body.reason)
    request.state.audit = {"action": f"api_client.{action}", "object_type": "iam.api_client", "reason": f"{uid} {body.reason or ''}".strip()}
    return out
