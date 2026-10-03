"""Security console: IP and range rules, login events and the activity log.

IP rules are managed through the application role (platform scope). The logs are read through a
separate connection on the masslak_auditor role, because the application role can only append to them.
"""
import ipaddress
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from .. import db
from ..deps import Principal, context_for, require_permission
from ..errors import ApiError, not_found
from ..util import row_dict, rows

router = APIRouter(prefix="/api/security", tags=["security"])
can_rules = require_permission("security.ip_rules")
can_audit = require_permission("audit.view", "security.ip_rules")


@router.get("/summary")
async def summary(pr: Principal = Depends(can_audit)):
    async with db.audit_reader() as conn:
        r = await conn.fetchrow(
            """SELECT
                 (SELECT count(*) FROM audit.auth_event WHERE ts > now() - interval '24 hours') AS logins_24h,
                 (SELECT count(*) FROM audit.auth_event WHERE ts > now() - interval '24 hours' AND result <> 'SUCCESS') AS failed_24h,
                 (SELECT count(*) FROM audit.activity_log WHERE ts > now() - interval '24 hours') AS actions_24h,
                 (SELECT count(*) FROM audit.activity_log WHERE ts > now() - interval '24 hours' AND result = 'BLOCKED') AS blocked_24h,
                 (SELECT count(*) FROM sec.ip_rule WHERE revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now())
                     AND source LIKE 'AUTO%') AS auto_blocks_active,
                 (SELECT max(sealed_at) FROM audit.log_seal) AS last_seal""")
    return row_dict(r)


@router.get("/ip-rules")
async def ip_rules(request: Request, pr: Principal = Depends(can_rules), include_inactive: bool = False):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT id, rule_type, host(cidr) || '/' || masklen(cidr) AS cidr, country_code, asn, action, scope, priority,
                      reason, source, created_at, expires_at, revoked_at
                 FROM sec.ip_rule
                WHERE $1 OR (revoked_at IS NULL AND (expires_at IS NULL OR expires_at > now()))
                ORDER BY created_at DESC LIMIT 300""", include_inactive)
    return {"rules": rows(recs)}


class IpRuleIn(BaseModel):
    target: str = Field(min_length=2, max_length=64, description="IP, CIDR range, 2-letter country or AS number")
    action: Literal["BLOCK", "ALLOW", "THROTTLE", "CHALLENGE"] = "BLOCK"
    scope: Literal["ALL", "PASSENGER", "OPERATOR", "AGENCY", "ADMIN", "API", "PAYMENT_WEBHOOK", "DRIVER"] = "ALL"
    priority: int = Field(default=100, ge=0, le=1000)
    reason: str = Field(min_length=3, max_length=300)
    expires_hours: Optional[int] = Field(default=None, ge=1, le=24 * 365)


@router.post("/ip-rules", status_code=201)
async def add_ip_rule(body: IpRuleIn, request: Request, pr: Principal = Depends(can_rules)):
    t = body.target.strip().upper()
    cidr = country = asn = None
    if t.startswith("AS") and t[2:].isdigit():
        rule_type, asn = "ASN", int(t[2:])
    elif len(t) == 2 and t.isalpha():
        rule_type, country = "COUNTRY", t
    else:
        try:
            cidr = str(ipaddress.ip_network(body.target.strip(), strict=False))
        except ValueError:
            raise ApiError(422, "INVALID_TARGET", "enter an IP address, a CIDR range, a country code or an AS number")
        rule_type = "CIDR"
    if rule_type == "CIDR" and body.action == "BLOCK" and ipaddress.ip_address(request.state.client_ip) in ipaddress.ip_network(cidr):
        raise ApiError(409, "SELF_BLOCK", "this rule would block your own address")
    async with db.transaction(context_for(request, pr)) as conn:
        rid = await conn.fetchval(
            """INSERT INTO sec.ip_rule (rule_type, cidr, country_code, asn, action, scope, priority, reason, source,
                 created_by, approved_by, expires_at)
               VALUES ($1, $2::cidr, $3, $4, $5, $6, $7, $8, 'MANUAL', $9, $9,
                       CASE WHEN $10::int IS NULL THEN NULL ELSE now() + make_interval(hours => $10::int) END)
               RETURNING id""",
            rule_type, cidr, country, asn, body.action, body.scope, body.priority, body.reason, pr.user_id,
            body.expires_hours)
    request.state.audit = {"action": "security.ip_rule.create", "object_type": "ip_rule", "object_id": rid,
                           "reason": body.reason}
    return {"id": rid}


class RevokeIn(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


@router.post("/ip-rules/{rule_id}/revoke")
async def revoke_ip_rule(rule_id: int, body: RevokeIn, request: Request, pr: Principal = Depends(can_rules)):
    async with db.transaction(context_for(request, pr)) as conn:
        n = await conn.execute(
            "UPDATE sec.ip_rule SET revoked_at = now(), revoked_by = $2, revoke_reason = $3 WHERE id = $1 AND revoked_at IS NULL",
            rule_id, pr.user_id, body.reason)
    if n.endswith(" 0"):
        raise not_found("active rule")
    request.state.audit = {"action": "security.ip_rule.revoke", "object_type": "ip_rule", "object_id": rule_id,
                           "reason": body.reason}
    return {"ok": True}


@router.get("/auth-events")
async def auth_events(pr: Principal = Depends(can_audit), result: Optional[str] = None,
                      ip: Optional[str] = None, limit: int = Query(100, le=500)):
    async with db.audit_reader() as conn:
        recs = await conn.fetch(
            """SELECT e.ts, e.event, e.result, e.portal, host(e.ip) AS ip, e.reason, e.user_agent,
                      u.email AS user_email
                 FROM audit.auth_event e LEFT JOIN iam.app_user u ON u.id = e.user_id
                WHERE ($1::text IS NULL OR e.result = $1) AND ($2::inet IS NULL OR e.ip = $2::inet)
                ORDER BY e.ts DESC LIMIT $3""", result, ip, limit)
    return {"events": rows(recs)}


@router.get("/activity")
async def activity(pr: Principal = Depends(can_audit), limit: int = Query(100, le=500)):
    async with db.audit_reader() as conn:
        recs = await conn.fetch(
            """SELECT a.ts, a.action, a.result, a.portal, host(a.ip) AS ip, a.http_method, a.endpoint, a.http_status,
                      a.latency_ms, a.object_type, a.object_id, a.reason, u.email AS user_email
                 FROM audit.activity_log a LEFT JOIN iam.app_user u ON u.id = a.user_id
                ORDER BY a.ts DESC LIMIT $1""", limit)
    return {"activity": rows(recs)}
