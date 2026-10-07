"""Platform administration: overview, carrier onboarding and approval, central stations."""
import uuid
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
