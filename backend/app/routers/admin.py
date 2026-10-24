"""Platform administration: overview, carrier onboarding and approval, central stations."""
import json
import uuid
from datetime import date
from typing import Literal, Optional

from fastapi import APIRouter, Depends, File, Request, UploadFile
from pydantic import BaseModel, EmailStr, Field

from .. import company_logo, db, markets
from ..deps import Principal, context_for, require_permission, require_portal, require_step_up
from ..errors import ApiError, not_found
from ..ledger import company_wallet, platform_wallet, post_txn
from ..modules.account.doors import temporary_password
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
            """SELECT p.uid, p.legal_name, c.company_type, c.approval_status, c.created_at, cc.code3, cc.code2,
                      iam.logo_version(c.id) AS logo,
                      (SELECT count(*) FROM fleet.vehicle v WHERE v.company_id = c.id) AS vehicles,
                      (SELECT count(*) FROM ops.trip t WHERE t.company_id = c.id) AS trips
                 FROM iam.company c JOIN iam.party p ON p.id = c.id
                 LEFT JOIN net.carrier_code cc ON cc.company_id = c.id AND cc.status = 'ACTIVE'
                ORDER BY c.created_at DESC""")
    return {"companies": rows(recs)}


async def _open_market(conn, code: Optional[str]) -> markets.Market:
    """The market a new company joins (1061): the one named, which must be open, or the default market."""
    m = await (markets.of_country(conn, code) if code else markets.default(conn))
    if code and (m.country != code or m.status != "ACTIVE"):
        raise ApiError(409, "MARKET_NOT_OPEN", "the platform does not operate in this country yet")
    return m


CODE2 = r"^([A-Z][A-Z0-9]|[0-9][A-Z])$"   # two characters, one at least a letter (study 4.16 a)


async def _code_free(conn, code: str, company_id: Optional[int] = None) -> bool:
    """A carrier code nobody else holds and the platform has not reserved (study 4.16 a)."""
    return not await conn.fetchval(
        """SELECT 1 FROM net.carrier_code WHERE (code3 = $1 OR code2 = $1) AND company_id IS DISTINCT FROM $2
           UNION SELECT 1 FROM net.code_reservation WHERE code = $1""", code, company_id)


class OnboardIn(BaseModel):
    legal_name: str = Field(min_length=3, max_length=160)
    market: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}$")     # country of an open market; default market if none
    code3: str = Field(pattern=r"^[A-Z]{3}$")
    code2: Optional[str] = Field(default=None, pattern=CODE2)      # the designator of its trip numbers, "QD 214" (1114)
    transport_license_no: Optional[str] = None
    owner_name: str = Field(min_length=3, max_length=120)
    owner_email: EmailStr
    owner_password: str


@router.post("/companies", status_code=201)
async def onboard_carrier(body: OnboardIn, request: Request, pr: Principal = Depends(require_permission("company.approve"))):
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "platform portal only")
    problem = password_problem(body.owner_password, body.owner_email, body.owner_name)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        if not await _code_free(conn, body.code3) or (body.code2 and not await _code_free(conn, body.code2)):
            raise ApiError(409, "CODE_TAKEN", "carrier code is taken or reserved")
        m = await _open_market(conn, body.market)
        cid = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name, country_code) VALUES ('COMPANY', $1, $2) RETURNING id",
            body.legal_name.strip(), m.country)
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'OPERATOR')", cid)
        await conn.execute(
            """INSERT INTO iam.company (id, transport_license_no, approval_status, approved_by, approved_at)
               VALUES ($1, $2, 'APPROVED', $3, now())""", cid, body.transport_license_no, pr.user_id)
        await conn.execute(
            """INSERT INTO net.carrier_code (company_id, code3, code2, status, approved_by, valid_from)
               VALUES ($1, $2, $3, 'ACTIVE', $4, current_date)""",
            cid, body.code3, body.code2, pr.user_id)
        owner_party = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id",   # contact on the account
            body.owner_name.strip())
        owner_user = await conn.fetchval(
            """INSERT INTO iam.app_user (party_id, account_kind, email, password_hash, password_changed_at, status,
                 preferred_locale, mfa_required) VALUES ($1, 'COMPANY', $2, $3, now(), 'ACTIVE', (SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), true) RETURNING id""",
            owner_party, body.owner_email, hash_password(body.owner_password))
        await conn.execute("INSERT INTO iam.company_member (user_id, company_id, is_owner) VALUES ($1, $2, true)",
                           owner_user, cid)
        door = await temporary_password(conn, owner_user)
        await company_wallet(conn, cid, m.currency)
        await conn.fetchval("SELECT iam.open_company_kyc($1)", cid)       # its KYC file to fill (1118)
        uid = await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", cid)
    request.state.audit = {"action": "company.onboard", "object_type": "company", "object_id": cid}
    return {"uid": str(uid), "sign_in": door}


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


class DesignatorIn(BaseModel):
    code2: Optional[str] = Field(default=None, pattern=CODE2)      # empty: trip numbers use the three-letter code


async def _company(conn, company_uid: uuid.UUID) -> int:
    cid = await conn.fetchval("SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", company_uid)
    if cid is None:
        raise not_found("company")
    return cid


def _platform_only(pr: Principal) -> None:
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "platform portal only")


@router.put("/companies/{company_uid}/designator")
async def set_designator(company_uid: uuid.UUID, body: DesignatorIn, request: Request,
                         pr: Principal = Depends(require_permission("company.approve"))):
    """The two-character designator of a carrier's trip numbers (1114). Trips already made keep the number printed on
    their tickets; the new designator names the trips made from now on."""
    _platform_only(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await _company(conn, company_uid)
        if body.code2 and not await _code_free(conn, body.code2, cid):
            raise ApiError(409, "CODE_TAKEN", "carrier code is taken or reserved")
        n = await conn.execute("UPDATE net.carrier_code SET code2 = $2 WHERE company_id = $1 AND status = 'ACTIVE'", cid, body.code2)
        if n.endswith(" 0"):
            raise ApiError(409, "NO_CARRIER_CODE", "the company has no active carrier code")
    request.state.audit = {"action": "company.designator", "object_type": "company", "object_id": cid, "reason": body.code2 or "-"}
    return {"code2": body.code2}


@router.put("/companies/{company_uid}/logo")
async def set_logo(company_uid: uuid.UUID, request: Request, file: UploadFile = File(...),
                   pr: Principal = Depends(require_permission("company.approve"))):
    """The company's logo, to the specification in app/company_logo.py: checked, re-encoded and kept (1115)."""
    _platform_only(pr)
    logo = company_logo.prepare(await file.read(company_logo.MAX_BYTES + 1))
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await _company(conn, company_uid)
        await conn.execute(
            """INSERT INTO iam.company_logo (company_id, image, width, height, sha256, uploaded_by, uploaded_at)
               VALUES ($1, $2, $3, $4, $5, $6, now())
               ON CONFLICT (company_id) DO UPDATE SET image = excluded.image, width = excluded.width, height = excluded.height,
                 sha256 = excluded.sha256, uploaded_by = excluded.uploaded_by, uploaded_at = excluded.uploaded_at""",
            cid, logo.png, logo.width, logo.height, logo.sha256, pr.user_id)
    request.state.audit = {"action": "company.logo", "object_type": "company", "object_id": cid, "reason": logo.version}
    return {"logo": logo.version, "width": logo.width, "height": logo.height, "bytes": len(logo.png)}


@router.delete("/companies/{company_uid}/logo")
async def remove_logo(company_uid: uuid.UUID, request: Request, pr: Principal = Depends(require_permission("company.approve"))):
    _platform_only(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await _company(conn, company_uid)
        if not await conn.fetchval("SELECT iam.remove_company_logo($1)", cid):
            raise not_found("logo")
    request.state.audit = {"action": "company.logo_remove", "object_type": "company", "object_id": cid}
    return {"logo": None}


@router.get("/stations")
async def all_stations(request: Request, pr: Principal = Depends(platform)):
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT s.uid, s.code, s.name, s.station_class, s.status, c.code AS city_code, s.lat, s.lng,
                      op.legal_name AS owner_name, p.pcode AS place_pcode, p.name_en AS place_en, p.name_ar AS place_ar
                 FROM net.station s JOIN ref.city c ON c.id = s.city_id LEFT JOIN iam.party op ON op.id = s.owner_company_id
                 LEFT JOIN ref.place p ON p.id = s.place_id
                ORDER BY s.code""")
    return {"stations": rows(recs)}


async def _station_place(conn, pcode: Optional[str], city_code: Optional[str]):
    """The place a station stands in (1125): an active community or neighbourhood. The city of the network is the
    place's own when its community is open for routes, else the one given; a station of a city stands in that city's
    governorate."""
    place = None
    if pcode:
        place = await conn.fetchrow(
            """SELECT p.id, p.lat, p.lng, k.code AS served, g.id AS governorate
                 FROM ref.place p
                 LEFT JOIN ref.city k ON k.place_id = coalesce(p.parent_place_id, p.id)
                 JOIN ref.admin_area s ON s.id = p.area_id JOIN ref.admin_area d ON d.id = s.parent_id JOIN ref.admin_area g ON g.id = d.parent_id
                WHERE p.pcode = $1 AND p.status = 'ACTIVE'""", pcode)
        if place is None:
            raise ApiError(422, "PLACE_UNKNOWN", "no active place with this code", place=pcode)
    code = city_code or (place["served"] if place else None)
    if code is None:
        raise ApiError(422, "CITY_REQUIRED", "the place is not in a city open for routes: open it, or name the city")
    city = await conn.fetchrow(
        """SELECT c.id, c.code, c.country_code,
                  (SELECT g.id FROM ref.place p JOIN ref.admin_area s ON s.id = p.area_id JOIN ref.admin_area d ON d.id = s.parent_id
                     JOIN ref.admin_area g ON g.id = d.parent_id WHERE p.id = c.place_id) AS governorate
             FROM ref.city c WHERE c.code = $1""", code)
    if city is None:
        raise not_found("city")
    if place and city["governorate"] and place["governorate"] != city["governorate"]:
        raise ApiError(422, "PLACE_NOT_IN_CITY", "the place is in another governorate than the city", place=pcode, city=code)
    return city, place


class StationIn(BaseModel):
    city_code: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    place: Optional[str] = Field(default=None, pattern=r"^[A-Z][0-9]{3,7}$")     # the community or neighbourhood (1125)
    number: int = Field(ge=1, le=999)
    name: str = Field(min_length=3, max_length=160)
    address: Optional[str] = None
    lat: Optional[float] = Field(default=None, ge=-90, le=90)                   # the place's position when not given
    lng: Optional[float] = Field(default=None, ge=-180, le=180)


@router.post("/stations", status_code=201)
async def add_central_station(body: StationIn, request: Request, pr: Principal = Depends(require_permission("station.approve"))):
    async with db.transaction(context_for(request, pr)) as conn:
        city, place = await _station_place(conn, body.place, body.city_code)
        lat = body.lat if body.lat is not None else (float(place["lat"]) if place else None)
        lng = body.lng if body.lng is not None else (float(place["lng"]) if place else None)
        if lat is None or lng is None:
            raise ApiError(422, "POSITION_REQUIRED", "a station needs its position, or a place to take it from")
        code = f"{city['country_code']}-{city['code']}-C{body.number:03d}"
        sid = await conn.fetchval(
            """INSERT INTO net.station (code, city_id, country_code, station_class, name, address, lat, lng, status,
                 verified_by, verified_at, place_id)
               VALUES ($1, $2, $3, 'CENTRAL', $4, $5, $6, $7, 'ACTIVE', $8, now(), $9) RETURNING id""",
            code, city["id"], city["country_code"], body.name.strip(), body.address, lat, lng, pr.user_id,
            place["id"] if place else None)
    request.state.audit = {"action": "station.create", "object_type": "station", "object_id": sid}
    return {"code": code}


class StationPlaceIn(BaseModel):
    place: str = Field(pattern=r"^[A-Z][0-9]{3,7}$")


@router.put("/stations/{station_uid}/place")
async def set_station_place(station_uid: uuid.UUID, body: StationPlaceIn, request: Request,
                            pr: Principal = Depends(require_permission("station.approve"))):
    """Records the place an existing station stands in (1125), in the governorate of its city."""
    async with db.transaction(context_for(request, pr)) as conn:
        st = await conn.fetchrow(
            "SELECT s.id, c.code AS city_code FROM net.station s JOIN ref.city c ON c.id = s.city_id WHERE s.uid = $1", station_uid)
        if st is None:
            raise not_found("station")
        _, place = await _station_place(conn, body.place, st["city_code"])
        await conn.execute("UPDATE net.station SET place_id = $2 WHERE id = $1", st["id"], place["id"])
    request.state.audit = {"action": "station.place", "object_type": "station", "object_id": st["id"], "reason": body.place}
    return {"place": body.place}


# ------------------------------------------------------------------ agencies
class AgencyIn(BaseModel):
    legal_name: str = Field(min_length=3, max_length=160)
    license_no: Optional[str] = Field(default=None, max_length=60)
    owner_name: str = Field(min_length=3, max_length=120)
    owner_email: EmailStr
    owner_password: str
    commission_bp: int = Field(ge=0, le=2000)            # basis points of the fares, at most 20%
    daily_limit: int = Field(gt=0, le=100_000_000_000)   # minor units
    market: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}$")     # country of an open market; default market if none


@router.post("/agencies", status_code=201)
async def onboard_agency(body: AgencyIn, request: Request, pr: Principal = Depends(require_permission("company.approve"))):
    if pr.portal != "PLATFORM":
        raise ApiError(403, "FORBIDDEN", "platform portal only")
    problem = password_problem(body.owner_password, body.owner_email, body.owner_name)
    if problem:
        raise ApiError(422, problem, "password does not meet the policy")
    async with db.transaction(context_for(request, pr)) as conn:
        m = await _open_market(conn, body.market)
        aid = await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name, country_code) VALUES ('COMPANY', $1, $2) RETURNING id",
            body.legal_name.strip(), m.country)
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
        door = await temporary_password(conn, owner_user)
        await company_wallet(conn, aid, m.currency, label="Agency wallet")
        uid = await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", aid)
    request.state.audit = {"action": "agency.onboard", "object_type": "company", "object_id": aid}
    return {"uid": str(uid), "sign_in": door}


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
                      fin.wallet_balance(w.id) AS balance, w.currency,
                      (SELECT count(*) FROM sales.booking b WHERE b.agency_id = c.id AND b.status <> 'CANCELLED') AS bookings
                 FROM iam.company c JOIN iam.party p ON p.id = c.id
                 LEFT JOIN sales.agency_agreement a ON a.agency_id = c.id AND a.status <> 'ENDED'
                 LEFT JOIN fin.wallet w ON w.owner_party_id = c.id AND w.wallet_type = 'COMPANY' AND w.currency = ref.company_currency(c.id)
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
        currency = (await markets.of_party(conn, aid)).currency           # the agency's market (1061)
        wallet = await company_wallet(conn, aid, currency, label="Agency wallet")
        clearing = await platform_wallet(conn, "BANK_CLEARING", currency)
        if await conn.fetchval("SELECT 1 FROM fin.ledger_txn WHERE idempotency_key = $1", f"agency-deposit:{body.idempotency_key}"):
            return {"ok": True, "replayed": True}
        await post_txn(conn, "TOPUP", currency, f"agency-deposit:{body.idempotency_key}",
                       [(clearing["id"], "DR", body.amount), (wallet["id"], "CR", body.amount)],
                       ref_type="company", ref_id=aid, user_id=pr.user_id, memo=f"Bank transfer {body.bank_reference}")
        balance = await conn.fetchval("SELECT fin.wallet_balance($1)", wallet["id"])
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
    require_step_up(pr)                 # a sensitive operation: a recent second factor (1136)
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


# ------------------------------------------------------------------ cancellation penalty (1106)
class CancelPenaltyIn(BaseModel):
    """Only where the regulators impose a penalty on a carrier that cancels a trip; the passengers are refunded in full
    whatever this says. legal_ref names the regulator's decision."""
    enabled: bool
    basis: Optional[Literal["PERCENT_OF_FARES", "PER_TICKET", "PER_TRIP"]] = None
    value: Optional[float] = Field(default=None, gt=0)
    payee: Optional[Literal["PLATFORM", "PASSENGERS", "AUTHORITY"]] = None
    authority_party_id: Optional[int] = None
    within_hours: Optional[int] = Field(default=None, ge=0, le=720)
    legal_ref: Optional[str] = Field(default=None, max_length=120)


@router.get("/trips/cancel-penalty")
async def get_cancel_penalty(request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        value = await conn.fetchval("SELECT value::text FROM sys.setting WHERE key = 'trip.cancel_penalty'")
    return json.loads(value or '{"enabled": false}')


@router.put("/trips/cancel-penalty")
async def set_cancel_penalty(body: CancelPenaltyIn, request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    value = {k: v for k, v in body.model_dump().items() if v is not None} if body.enabled else {"enabled": False}
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetchval("SELECT ops.set_cancel_penalty($1::jsonb)::text", json.dumps(value))
    request.state.audit = {"action": "trip.cancel_penalty_setting", "object_type": "setting",
                           "reason": (body.legal_ref or "turned off")[:120]}
    return json.loads(out)


# ------------------------------------------------------------------ seats booked at once (1122)
class SeatLimitsIn(BaseModel):
    """Four seats a booking unless the platform or a regulator decides otherwise; a family head up to the family's size
    within family_max_seats; an agency's group up to agency_group. basis names the decision behind the change."""
    max_seats: int = Field(ge=1, le=20)
    family_max_seats: int = Field(ge=1, le=20)
    agency_group: int = Field(ge=1, le=60)
    basis: str = Field(min_length=3, max_length=160)


@router.get("/booking/seat-limits")
async def get_seat_limits(request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        return json.loads(await conn.fetchval("SELECT sales.seat_limits()::text"))


@router.put("/booking/seat-limits")
async def set_seat_limits(body: SeatLimitsIn, request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetchval("SELECT sales.set_seat_limits($1, $2, $3, $4)::text",
                                  body.max_seats, body.family_max_seats, body.agency_group, body.basis)
    request.state.audit = {"action": "booking.seat_limits", "object_type": "setting",
                           "reason": f"{body.max_seats}/{body.family_max_seats}/{body.agency_group}: {body.basis}"[:120]}
    return json.loads(out)


class MoneyModeIn(BaseModel):
    """Phase one (N13): NO_FUNDS while the platform holds no money (cash at the counter only, no fee or commission), FULL
    afterwards; basis names the decision."""
    mode: Literal["FULL", "NO_FUNDS"]
    basis: str = Field(min_length=3, max_length=160)


@router.get("/money-mode")
async def get_money_mode(request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        return json.loads(await conn.fetchval("SELECT fin.money_mode_state()::text"))


@router.put("/money-mode")
async def set_money_mode(body: MoneyModeIn, request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    require_step_up(pr)                 # a sensitive operation: it opens or closes every way money moves
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetchval("SELECT fin.set_money_mode($1, $2)::text", body.mode, body.basis)
    request.state.audit = {"action": "platform.money_mode", "object_type": "setting", "reason": f"{body.mode}: {body.basis}"[:120]}
    return json.loads(out)


class PassengerMixIn(BaseModel):
    """Adults and children of one booking (N34): four adults and six children unless the platform or a regulator decides
    otherwise; infants on a lap stay within the adults, and every seat within max_seats. basis names the decision."""
    max_adults: int = Field(ge=1, le=20)
    max_children: int = Field(ge=0, le=20)
    basis: str = Field(min_length=3, max_length=160)


@router.put("/booking/passenger-mix")
async def set_passenger_mix(body: PassengerMixIn, request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetchval("SELECT sales.set_passenger_mix($1, $2, $3)::text", body.max_adults, body.max_children, body.basis)
    request.state.audit = {"action": "booking.passenger_mix", "object_type": "setting",
                           "reason": f"{body.max_adults}/{body.max_children}: {body.basis}"[:120]}
    return json.loads(out)


# ------------------------------------------------------------------ first interface language by country (1141)
class VisitorLocaleIn(BaseModel):
    """Visitors in Syria see Arabic first and visitors from elsewhere English, unless the platform decides otherwise per
    country; a visitor's own choice always wins."""
    default: str = Field(min_length=2, max_length=5)
    countries: dict[str, str] = Field(default_factory=dict, max_length=250)
    basis: str = Field(min_length=3, max_length=160)


@router.get("/ui/visitor-locale")
async def get_visitor_locale(request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    async with db.transaction(context_for(request, pr)) as conn:
        value = await conn.fetchval("SELECT value::text FROM sys.setting WHERE key = 'ui.visitor_locale'")
        langs = await conn.fetch("SELECT code, name, native_name FROM ref.locale WHERE is_enabled ORDER BY code")
    return {**json.loads(value or '{"default": "en", "countries": {}}'), "languages": [dict(r) for r in langs]}


@router.put("/ui/visitor-locale")
async def set_visitor_locale(body: VisitorLocaleIn, request: Request, pr: Principal = Depends(require_permission("policy.matrix"))):
    doc = {"default": body.default, "countries": {k.strip().upper(): v for k, v in body.countries.items()}}
    async with db.transaction(context_for(request, pr)) as conn:
        out = await conn.fetchval("SELECT sys.set_visitor_locale($1::jsonb, $2)::text", json.dumps(doc), body.basis)
    request.state.audit = {"action": "ui.visitor_locale", "object_type": "setting", "reason": body.basis[:120]}
    return json.loads(out)
