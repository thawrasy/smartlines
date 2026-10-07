"""Platform administration: overview, carrier onboarding and approval, central stations."""
import uuid
from datetime import date
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, EmailStr, Field

from .. import db
from ..deps import Principal, context_for, require_permission, require_portal
from ..errors import ApiError, not_found
from ..ledger import company_wallet, platform_wallet, post_txn
from ..security import hash_password, password_problem
from ..util import row_dict, rows

router = APIRouter(prefix="/api/admin", tags=["admin"])
platform = require_portal("PLATFORM")


@router.get("/overview")
async def overview(request: Request, pr: Principal = Depends(platform)):
    async with db.transaction(context_for(request, pr)) as conn:
        r = await conn.fetchrow(
            """SELECT
                 (SELECT count(*) FROM iam.company WHERE approval_status = 'APPROVED') AS carriers,
                 (SELECT count(*) FROM iam.company WHERE approval_status = 'PENDING') AS carriers_pending,
                 (SELECT count(*) FROM iam.app_user WHERE account_kind = 'CUSTOMER') AS passengers,
                 (SELECT count(*) FROM ops.trip WHERE status IN ('PUBLISHED','BOARDING','DEPARTED')) AS active_trips,
                 (SELECT count(*) FROM sales.booking WHERE status IN ('CONFIRMED','COMPLETED')) AS bookings,
                 (SELECT coalesce(sum(total_amount), 0) FROM sales.booking WHERE status IN ('CONFIRMED','COMPLETED')) AS gmv,
                 (SELECT count(*) FROM net.station WHERE status = 'ACTIVE') AS stations""")
    return row_dict(r)


@router.get("/companies")
async def companies(request: Request, pr: Principal = Depends(platform)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT p.uid, p.legal_name, c.company_type, c.approval_status, c.created_at, cc.code3,
                      (SELECT count(*) FROM fleet.vehicle v WHERE v.company_id = c.id) AS vehicles,
                      (SELECT count(*) FROM ops.trip t WHERE t.company_id = c.id) AS trips
                 FROM iam.company c JOIN iam.party p ON p.id = c.id
                 LEFT JOIN net.carrier_code cc ON cc.company_id = c.id AND cc.status = 'ACTIVE'
                ORDER BY c.created_at DESC""")
    return {"companies": rows(recs)}


class OnboardIn(BaseModel):
    legal_name: str = Field(min_length=3, max_length=160)
    code3: str = Field(pattern=r"^[A-Z]{3}$")
    transport_license_no: Optional[str] = None
    owner_name: str = Field(min_length=3, max_length=120)
    owner_email: EmailStr
    owner_password: str


@router.post("/companies", status_code=201)
async def onboard_carrier(body: OnboardIn, request: Request, pr: Principal = Depends(require_permission("company.approve"))):
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "platform portal only")
    problem = password_problem(body.owner_password)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        if await conn.fetchval("SELECT 1 FROM net.carrier_code WHERE code3 = $1 UNION SELECT 1 FROM net.code_reservation WHERE code = $1",
                               body.code3):
            raise ApiError(409, "CODE_TAKEN", "carrier code is taken or reserved")
        cid = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', $1) RETURNING id", body.legal_name.strip())
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'OPERATOR')", cid)
        await conn.execute(
            """INSERT INTO iam.company (id, transport_license_no, approval_status, approved_by, approved_at)
               VALUES ($1, $2, 'APPROVED', $3, now())""", cid, body.transport_license_no, pr.user_id)
        await conn.execute(
            "INSERT INTO net.carrier_code (company_id, code3, status, approved_by, valid_from) VALUES ($1, $2, 'ACTIVE', $3, current_date)",
            cid, body.code3, pr.user_id)
        owner_party = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id",   # contact on the account
            body.owner_name.strip())
        owner_user = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, password_hash, password_changed_at, status,
                 preferred_locale, mfa_required) VALUES ($1, 'COMPANY', $2, $3, now(), 'ACTIVE', (SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), true) RETURNING id""",
            owner_party, body.owner_email, hash_password(body.owner_password))
        await conn.execute("INSERT INTO iam.company_member (user_id, company_id, is_owner) VALUES ($1, $2, true)",
                           owner_user, cid)
        await company_wallet(conn, cid, "SYP")
        uid = await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", cid)
    request.state.audit = {"action": "company.onboard", "object_type": "company", "object_id": cid}
    return {"uid": str(uid)}


class StatusIn(BaseModel):
    status: Literal["APPROVED", "SUSPENDED", "REJECTED"]
    reason: str = Field(min_length=3, max_length=300)


@router.post("/companies/{company_uid}/status")
async def set_company_status(company_uid: uuid.UUID, body: StatusIn, request: Request,
                             pr: Principal = Depends(require_permission("company.approve"))):
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await conn.fetchval("SELECT id FROM iam.party WHERE uid = $1", company_uid)
        n = await conn.execute(
            "UPDATE iam.company SET approval_status = $2, approved_by = $3, approved_at = now() WHERE id = $1",
            cid, body.status, pr.user_id)
        if n.endswith(" 0"):
            raise not_found("company")
    request.state.audit = {"action": "company.status", "object_type": "company", "object_id": cid, "reason": body.reason}
    return {"ok": True}


@router.get("/stations")
async def all_stations(request: Request, pr: Principal = Depends(platform)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT s.uid, s.code, s.name, s.station_class, s.status, c.code AS city_code, s.lat, s.lng,
                      op.legal_name AS owner_name
                 FROM net.station s JOIN ref.city c ON c.id = s.city_id LEFT JOIN iam.party op ON op.id = s.owner_company_id
                ORDER BY s.code""")
    return {"stations": rows(recs)}


class StationIn(BaseModel):
    city_code: str = Field(pattern=r"^[A-Z]{3}$")
    number: int = Field(ge=1, le=999)
    name: str = Field(min_length=3, max_length=160)
    address: Optional[str] = None
    lat: float = Field(ge=-90, le=90)
    lng: float = Field(ge=-180, le=180)


@router.post("/stations", status_code=201)
async def add_central_station(body: StationIn, request: Request, pr: Principal = Depends(require_permission("station.approve"))):
    async with db.transaction(context_for(request, pr)) as conn:
        city = await conn.fetchrow("SELECT id, country_code FROM ref.city WHERE code = $1", body.city_code)
        if city is None:
            raise not_found("city")
        code = f"{city['country_code']}-{body.city_code}-C{body.number:03d}"
        sid = await conn.fetchval(
            """INSERT INTO net.station (code, city_id, country_code, station_class, name, address, lat, lng, status,
                 verified_by, verified_at)
               VALUES ($1, $2, $3, 'CENTRAL', $4, $5, $6, $7, 'ACTIVE', $8, now()) RETURNING id""",
            code, city["id"], city["country_code"], body.name.strip(), body.address, body.lat, body.lng, pr.user_id)
    request.state.audit = {"action": "station.create", "object_type": "station", "object_id": sid}
    return {"code": code}


# ------------------------------------------------------------------ agencies
class AgencyIn(BaseModel):
    legal_name: str = Field(min_length=3, max_length=160)
    license_no: Optional[str] = Field(default=None, max_length=60)
    owner_name: str = Field(min_length=3, max_length=120)
    owner_email: EmailStr
    owner_password: str
    commission_bp: int = Field(ge=0, le=2000)            # basis points of the fares, at most 20%
    daily_limit: int = Field(gt=0, le=100_000_000_000)   # minor units


@router.post("/agencies", status_code=201)
async def onboard_agency(body: AgencyIn, request: Request, pr: Principal = Depends(require_permission("company.approve"))):
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "platform portal only")
    problem = password_problem(body.owner_password)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        aid = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', $1) RETURNING id", body.legal_name.strip())
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'AGENCY')", aid)
        await conn.execute(
            """INSERT INTO iam.company (id, company_type, transport_license_no, approval_status, approved_by, approved_at)
               VALUES ($1, 'AGENCY', $2, 'APPROVED', $3, now())""", aid, body.license_no, pr.user_id)
        await conn.execute(
            """INSERT INTO sales.agency_agreement (agency_id, commission_bp, daily_limit, created_by)
               VALUES ($1, $2, $3, $4)""", aid, body.commission_bp, body.daily_limit, pr.user_id)
        owner_party = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id",   # contact on the account
            body.owner_name.strip())
        owner_user = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, password_hash, password_changed_at, status,
                 preferred_locale, mfa_required) VALUES ($1, 'AGENCY', $2, $3, now(), 'ACTIVE', (SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), true) RETURNING id""",
            owner_party, body.owner_email, hash_password(body.owner_password))
        await conn.execute("INSERT INTO iam.company_member (user_id, company_id, is_owner) VALUES ($1, $2, true)",
                           owner_user, aid)
        await company_wallet(conn, aid, "SYP", label="Agency wallet")
        uid = await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", aid)
    request.state.audit = {"action": "agency.onboard", "object_type": "company", "object_id": aid}
    return {"uid": str(uid)}


async def _agency_id(conn, agency_uid: uuid.UUID) -> int:
    aid = await conn.fetchval(
        "SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1 AND c.company_type = 'AGENCY'",
        agency_uid)
    if aid is None:
        raise not_found("agency")
    return aid


@router.get("/agencies")
async def agencies(request: Request, pr: Principal = Depends(require_permission("company.approve", "cash.remittance"))):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT p.uid, p.legal_name, c.approval_status, a.commission_bp, a.daily_limit, a.status AS agreement_status,
                      w.balance, w.currency,
                      (SELECT count(*) FROM sales.booking b WHERE b.agency_id = c.id AND b.status <> 'CANCELLED') AS bookings
                 FROM iam.company c JOIN iam.party p ON p.id = c.id
                 LEFT JOIN sales.agency_agreement a ON a.agency_id = c.id AND a.status <> 'ENDED'
                 LEFT JOIN fin.wallet w ON w.owner_party_id = c.id AND w.wallet_type = 'COMPANY' AND w.currency = 'SYP'
                WHERE c.company_type = 'AGENCY' ORDER BY p.legal_name""")
    return {"agencies": rows(recs)}


class AgreementIn(BaseModel):
    commission_bp: int = Field(ge=0, le=2000)
    daily_limit: int = Field(gt=0, le=100_000_000_000)
    status: Literal["ACTIVE", "SUSPENDED"] = "ACTIVE"
    reason: str = Field(min_length=3, max_length=300)


@router.post("/agencies/{agency_uid}/agreement")
async def update_agreement(agency_uid: uuid.UUID, body: AgreementIn, request: Request,
                           pr: Principal = Depends(require_permission("company.approve"))):
    """Changes apply to new sales only; each booking keeps the commission in its price snapshot."""
    async with db.transaction(context_for(request, pr)) as conn:
        aid = await _agency_id(conn, agency_uid)
        n = await conn.execute(
            """UPDATE sales.agency_agreement SET commission_bp = $2, daily_limit = $3, status = $4
                WHERE agency_id = $1 AND status <> 'ENDED'""", aid, body.commission_bp, body.daily_limit, body.status)
        if n.endswith(" 0"):
            raise not_found("agreement")
    request.state.audit = {"action": "agency.agreement", "object_type": "company", "object_id": aid, "reason": body.reason}
    return {"ok": True}


class DepositIn(BaseModel):
    amount: int = Field(gt=0, le=100_000_000_000)        # minor units
    bank_reference: str = Field(min_length=3, max_length=60, pattern=r"^[0-9A-Za-z\-/]+$")
    idempotency_key: str = Field(min_length=8, max_length=80)


@router.post("/agencies/{agency_uid}/deposit")
async def agency_deposit(agency_uid: uuid.UUID, body: DepositIn, request: Request,
                         pr: Principal = Depends(require_permission("cash.remittance"))):
    """Credits an agency's prepaid balance after finance has seen the bank transfer arrive."""
    async with db.transaction(context_for(request, pr)) as conn:
        aid = await _agency_id(conn, agency_uid)
        wallet = await company_wallet(conn, aid, "SYP", label="Agency wallet")
        clearing = await platform_wallet(conn, "BANK_CLEARING", "SYP")
        if await conn.fetchval("SELECT 1 FROM fin.ledger_txn WHERE idempotency_key = $1", f"agency-deposit:{body.idempotency_key}"):
            return {"ok": True, "replayed": True}
        await post_txn(conn, "TOPUP", "SYP", f"agency-deposit:{body.idempotency_key}",
                       [(clearing["id"], "DR", body.amount), (wallet["id"], "CR", body.amount)],
                       ref_type="company", ref_id=aid, user_id=pr.user_id, memo=f"Bank transfer {body.bank_reference}")
        balance = await conn.fetchval("SELECT balance FROM fin.wallet WHERE id = $1", wallet["id"])
    request.state.audit = {"action": "agency.deposit", "object_type": "company", "object_id": aid,
                           "reason": body.bank_reference}
    return {"ok": True, "balance": balance}


# ------------------------------------------------------------------ regulatory requirements (audit T3-14)
class RequirementChangeIn(BaseModel):
    level: Literal["OFF", "OPTIONAL", "REQUIRED"]
    required_from: Optional[date] = None
    reason: str = Field(min_length=10, max_length=500)


class RequirementDecisionIn(BaseModel):
    approve: bool
    note: Optional[str] = Field(default=None, max_length=500)


@router.get("/compliance/requirements")
async def requirements(request: Request, pr: Principal = Depends(require_permission("modules.manage"))):
    """Every configurable requirement with its level, and the changes proposed or decided for it."""
    async with db.transaction(context_for(request, pr)) as conn:
        reqs = await conn.fetch("""SELECT code, domain, applies_to, subject_type, license_type, level, required_from, authority, description
                                     FROM sys.compliance_requirement ORDER BY code""")
        changes = await conn.fetch(
            """SELECT c.uid, c.code, c.from_level, c.to_level, c.required_from, c.reason, c.impact, c.status, c.proposed_at, c.decided_at,
                      c.decision_note, pu.email AS proposed_by, du.email AS decided_by
                 FROM sys.requirement_change c JOIN iam.app_user pu ON pu.id = c.proposed_by LEFT JOIN iam.app_user du ON du.id = c.decided_by
                ORDER BY c.proposed_at DESC LIMIT 200""")
    return {"requirements": rows(reqs), "changes": rows(changes)}


@router.post("/compliance/requirements/{code}/changes", status_code=201)
async def propose_requirement(code: str, body: RequirementChangeIn, request: Request,
                              pr: Principal = Depends(require_permission("modules.manage"))):
    """Proposes a change; it applies only when a second platform user approves it, with its impact measured now."""
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await conn.fetchval("SELECT sys.propose_requirement_change($1, $2, $3, $4)", code, body.level, body.required_from,
                                  body.reason.strip())
        row = await conn.fetchrow("SELECT uid, impact FROM sys.requirement_change WHERE id = $1", cid)
    request.state.audit = {"action": "compliance.requirement.propose", "object_type": "requirement_change", "object_id": cid}
    return {"uid": str(row["uid"]), "impact": row_dict(row)["impact"]}


@router.post("/compliance/changes/{uid}/decision")
async def decide_requirement(uid: uuid.UUID, body: RequirementDecisionIn, request: Request,
                             pr: Principal = Depends(require_permission("modules.manage"))):
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await conn.fetchval("SELECT id FROM sys.requirement_change WHERE uid = $1", uid)
        if cid is None:
            raise not_found("requirement change")
        status = await conn.fetchval("SELECT sys.decide_requirement_change($1, $2, $3)", cid, body.approve, body.note)
    request.state.audit = {"action": "compliance.requirement.decide", "object_type": "requirement_change", "object_id": cid}
    return {"status": status}



# ------------------------------------------------------------------ resends of money and authority events (audit T3-12)
class RetryDecisionIn(BaseModel):
    approve: bool
    note: Optional[str] = Field(default=None, max_length=300)


@router.get("/delivery-retries")
async def delivery_retries(request: Request, pr: Principal = Depends(require_permission("events.replay_approve"))):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetch(
            """SELECT r.uid, r.event_type, r.reason, r.status, r.created_at, r.decided_at, r.decision_note, c.name AS client,
                      d.delivery_uid, d.attempts, d.last_error
                 FROM sys.delivery_retry_request r JOIN sys.webhook_delivery d ON d.id = r.delivery_id
                 LEFT JOIN iam.api_client c ON c.id = r.api_client_id
                ORDER BY (r.status = 'PENDING') DESC, r.created_at DESC LIMIT 200""")
    return {"requests": rows(out)}


@router.post("/delivery-retries/{uid}/decision")
async def decide_delivery_retry(uid: uuid.UUID, body: RetryDecisionIn, request: Request,
                                pr: Principal = Depends(require_permission("events.replay_approve"))):
    async with db.transaction(context_for(request, pr)) as conn:
        r = await conn.fetchrow("SELECT id, delivery_id, requested_by, status FROM sys.delivery_retry_request WHERE uid = $1 FOR UPDATE", uid)
        if r is None:
            raise not_found("retry request")
        if r["status"] != "PENDING":
            raise ApiError(409, "INVALID_TRANSITION", "this request was already decided")
        if r["requested_by"] == pr.user_id:
            raise ApiError(409, "RETRY_SELF_APPROVAL", "a second person approves a resend")
        await conn.execute("""UPDATE sys.delivery_retry_request SET status = $2, decided_by = $3, decided_at = now(), decision_note = $4
                               WHERE id = $1""", r["id"], "APPROVED" if body.approve else "REJECTED", pr.user_id, body.note)
        if body.approve:
            await conn.execute("""UPDATE sys.webhook_delivery SET status = 'PENDING', next_attempt_at = now(), attempts = 0
                                   WHERE id = $1 AND status IN ('DEAD', 'FAILED')""", r["delivery_id"])
    request.state.audit = {"action": "webhook.retry.decide", "object_type": "delivery_retry_request", "object_id": r["id"]}
    return {"status": "APPROVED" if body.approve else "REJECTED"}


# ------------------------------------------------------------------ violations on low-trust positions (audit T3-11)
class ViolationReviewIn(BaseModel):
    decision: Literal["CONFIRM", "DISMISS"]
    note: str = Field(min_length=10, max_length=500)


@router.get("/violations/review")
async def violations_to_review(request: Request, pr: Principal = Depends(require_permission("violation.review"))):
    """Violations whose evidence is graded low-trust: they count only after a person looks at the positions behind them."""
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetch(
            """SELECT v.uid, v.kind, v.started_at, v.ended_at, v.max_distance_m, v.in_service, v.carrying_passengers, v.status,
                      v.evidence, v.tracking_source, p.legal_name AS company, fv.plate_no
                 FROM ops.route_violation v JOIN iam.party p ON p.id = v.company_id LEFT JOIN fleet.vehicle fv ON fv.id = v.vehicle_id
                WHERE v.evidence_trust = 'LOW' AND v.reviewed_by IS NULL AND v.status = 'OPEN'
                ORDER BY v.started_at LIMIT 200""")
    return {"violations": rows(out)}


@router.post("/violations/{uid}/review")
async def review_violation(uid: uuid.UUID, body: ViolationReviewIn, request: Request,
                           pr: Principal = Depends(require_permission("violation.review"))):
    async with db.transaction(context_for(request, pr)) as conn:
        vid = await conn.fetchval(
            """UPDATE ops.route_violation SET reviewed_by = $2, status = $3, justification = $4
                WHERE uid = $1 AND evidence_trust = 'LOW' AND reviewed_by IS NULL AND status = 'OPEN' RETURNING id""",
            uid, pr.user_id, "CONFIRMED" if body.decision == "CONFIRM" else "CLOSED", body.note.strip())
        if vid is None:
            raise ApiError(409, "VIOLATION_NOT_AWAITING_REVIEW", "only an open violation on low-trust evidence is reviewed here")
    request.state.audit = {"action": "violation.review", "object_type": "route_violation", "object_id": vid}
    return {"status": "CONFIRMED" if body.decision == "CONFIRM" else "CLOSED"}


# ------------------------------------------------------------------ external reviewers (owner decision, 8 October 2026)
class ExternalAccessIn(BaseModel):
    email: str = Field(min_length=3, max_length=254)
    organisation: str = Field(min_length=2, max_length=120)
    purpose: str = Field(min_length=10, max_length=500)
    engagement_ref: str = Field(min_length=3, max_length=80)
    days: int = Field(ge=1, le=90)


@router.get("/external-access")
async def external_access(request: Request, pr: Principal = Depends(require_permission("external_access.grant"))):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetch(
            """SELECT g.uid, u.email, g.organisation, g.purpose, g.engagement_ref, g.starts_at, g.expires_at, g.revoked_at,
                      gb.email AS granted_by, (g.revoked_at IS NULL AND g.expires_at > now()) AS active
                 FROM sec.external_access_grant g JOIN iam.app_user u ON u.id = g.user_id JOIN iam.app_user gb ON gb.id = g.granted_by
                ORDER BY g.created_at DESC LIMIT 200""")
    return {"grants": rows(out)}


@router.post("/external-access", status_code=201)
async def grant_external_access(body: ExternalAccessIn, request: Request,
                                pr: Principal = Depends(require_permission("external_access.grant"))):
    """Read-only access for an auditor or tester: their own platform account, a named engagement, a second person granting
    it, and an end date (at most security.external_access_max_days). The role EXTERNAL_AUDITOR cannot be given otherwise."""
    async with db.transaction(context_for(request, pr)) as conn:
        user = await conn.fetchval("SELECT id FROM iam.app_user WHERE lower(email) = lower($1)", str(body.email).strip())
        if user is None:
            raise not_found("account")
        uid = await conn.fetchval(
            """INSERT INTO sec.external_access_grant (user_id, granted_by, organisation, purpose, engagement_ref, expires_at)
               VALUES ($1, $2, $3, $4, $5, now() + make_interval(days => $6)) RETURNING uid""",
            user, pr.user_id, body.organisation.strip(), body.purpose.strip(), body.engagement_ref.strip(), body.days)
    request.state.audit = {"action": "external_access.grant", "object_type": "external_access_grant", "object_id": None}
    return {"uid": str(uid)}


@router.post("/external-access/{uid}/revoke")
async def revoke_external_access(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_permission("external_access.grant"))):
    async with db.transaction(context_for(request, pr)) as conn:
        gid = await conn.fetchval(
            "UPDATE sec.external_access_grant SET revoked_at = now(), revoked_by = $2 WHERE uid = $1 AND revoked_at IS NULL RETURNING id",
            uid, pr.user_id)
        if gid is None:
            raise ApiError(409, "INVALID_TRANSITION", "no active grant with that id")
    request.state.audit = {"action": "external_access.revoke", "object_type": "external_access_grant", "object_id": gid}
    return {"revoked": True}
