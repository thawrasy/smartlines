"""Security console: IP and range rules, login events, the activity log and the two-factor sign-in policy.

IP rules are managed through the application role (platform scope). The logs are read through a
separate connection on the masslak_auditor role, because the application role can only append to them.
"""
import ipaddress
import json
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field

from .. import db, mfa_policy
from ..deps import Principal, context_for, require_permission
from ..errors import ApiError, not_found
from ..util import row_dict, rows

router = APIRouter(prefix="/api/security", tags=["security"])
can_rules = require_permission("security.ip_rules")
can_audit = require_permission("audit.view", "security.ip_rules")
can_policy = require_permission("security.console")


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
                 (SELECT max(created_at) FROM audit.log_seal) AS last_seal""")
    return row_dict(r)


@router.get("/ip-rules")
async def ip_rules(request: Request, pr: Principal = Depends(can_rules), include_inactive: bool = False):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT id, rule_type, host(cidr) || '/' || masklen(cidr) AS cidr, country_code, asn, action, scope, priority,
                      reason, source, hit_count, last_hit_at, created_at, expires_at, revoked_at
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


# ---------------------------------------------------------------- two-factor sign-in policy (owner's decision 2)
class MfaPolicyIn(BaseModel):
    methods: list[Literal["TOTP", "SMS", "WHATSAPP"]] = Field(min_length=1)
    required_portals: list[Literal["PLATFORM", "INSPECTOR", "OPERATOR", "DRIVER", "AGENCY", "PASSENGER"]]
    enforce_in_sandbox: bool = False
    code_minutes: int = Field(default=5, ge=2, le=10)
    resend_seconds: int = Field(default=60, ge=30, le=300)
    sends_per_hour: int = Field(default=5, ge=3, le=20)


async def _mfa_policy_view(conn) -> dict:
    from ..config import get_settings
    from ..modules.notify import providers
    policy = await mfa_policy.current(conn)
    counts = await conn.fetch(
        """SELECT factor_type, count(DISTINCT user_id) AS people FROM iam.mfa_factor
            WHERE verified_at IS NOT NULL AND disabled_at IS NULL AND factor_type IN ('TOTP','SMS','WHATSAPP')
            GROUP BY factor_type""")
    without = await conn.fetch(
        """SELECT CASE u.account_kind WHEN 'PLATFORM' THEN 'PLATFORM' WHEN 'AGENCY' THEN 'AGENCY' ELSE
                       CASE WHEN EXISTS (SELECT 1 FROM fleet.crew_profile cp WHERE cp.party_id = u.party_id AND cp.status = 'ACTIVE')
                            THEN 'DRIVER' ELSE 'OPERATOR' END END AS portal, count(*) AS people
             FROM iam.app_user u
            WHERE u.status = 'ACTIVE' AND u.account_kind IN ('PLATFORM','COMPANY','AGENCY')
              AND NOT EXISTS (SELECT 1 FROM iam.mfa_factor f WHERE f.user_id = u.id AND f.verified_at IS NOT NULL
                                 AND f.disabled_at IS NULL AND f.factor_type IN ('TOTP','SMS','WHATSAPP'))
            GROUP BY 1""")
    return {"policy": policy.public(), "available": policy.available(),
            "delivery": {"TOTP": True, "SMS": providers.enabled("SMS"), "WHATSAPP": providers.enabled("WHATSAPP")},
            "always_required": list(mfa_policy.ALWAYS), "sandbox": get_settings().sandbox,
            "enrolled": {r["factor_type"]: r["people"] for r in counts},
            "staff_without_factor": {r["portal"]: r["people"] for r in without}}


@router.get("/mfa-policy")
async def get_mfa_policy(request: Request, pr: Principal = Depends(can_policy)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await _mfa_policy_view(conn)


@router.put("/mfa-policy")
async def set_mfa_policy(body: MfaPolicyIn, request: Request, pr: Principal = Depends(can_policy)):
    """Which methods are open and which portals must use one. A portal added here asks its staff for a second factor
    at their next sign-in (enrolment first, for those without one); the other API processes follow within half a
    minute. Platform staff keep theirs outside the sandbox whatever is chosen."""
    value = mfa_policy.Policy.of(body.model_dump()).public()
    async with db.transaction(context_for(request, pr)) as conn:
        before = await conn.fetchval("SELECT value::text FROM sys.setting WHERE key = 'auth.mfa'")
        await conn.execute(
            """INSERT INTO sys.setting (key, value, description, updated_by) VALUES ('auth.mfa', $1::jsonb, 'Two-factor sign-in policy', $2)
               ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by""",
            json.dumps(value), pr.user_id)
        from ..modules.notify.outbox import emit
        # a change of who must use a second factor is a security event (outbox, audit T3)
        await emit(conn, "security.mfa_policy_changed", "setting", pr.user_id,
                   {"before": json.loads(before) if before else None, "after": value, "changed_by": pr.user_id})
        mfa_policy.forget()
        out = await _mfa_policy_view(conn)
    request.state.audit = {"action": "security.mfa_policy", "object_type": "setting", "object_id": None,
                           "reason": f"methods={','.join(value['methods'])} portals={','.join(value['required_portals'])}"}
    return out


@router.get("/statements")
async def top_statements(request: Request, order: Literal["TOTAL", "MEAN", "CALLS", "READS"] = "TOTAL",
                         limit: int = Query(20, ge=1, le=100), min_calls: int = Query(1, ge=1),
                         pr: Principal = Depends(can_policy)):
    """The statements that cost the database most (pg_stat_statements, 1077): by total time, mean time, calls or
    blocks read from disk. Texts carry placeholders, never values. Empty, with enabled false, where the server does not
    preload the extension."""
    async with db.transaction(context_for(request, pr)) as conn:
        enabled = await conn.fetchval("SELECT sys.statement_stats_enabled()")
        found = await conn.fetch("SELECT * FROM sys.top_statements($1, $2, $3)", order, limit, min_calls)
    return {"enabled": enabled, "order": order,
            "statements": [{**row_dict(r), "queryid": str(r["queryid"]), "wal_bytes": int(r["wal_bytes"] or 0)} for r in found]}


@router.post("/statements/reset")
async def reset_statements(request: Request, pr: Principal = Depends(can_policy)):
    """Starts a new measurement window, to compare a statement before and after an index or a rewrite."""
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval("SELECT sys.reset_statement_stats()")
    if not done:
        raise ApiError(409, "STATEMENT_STATS_OFF", "statement statistics are not collected on this server")
    request.state.audit = {"action": "security.statements_reset", "object_type": "setting", "object_id": None}
    return {"reset": True}
