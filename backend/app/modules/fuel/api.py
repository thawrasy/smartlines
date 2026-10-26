"""Fuel stations (owner's note of 25 October 2026; migration 1180; docs/design/FUEL_STATIONS.md).

A fuel company signs in to its own portal (FUEL). It owns one station or a chain; its attendants work at the pump from
the same portal on a phone: they identify the vehicle by its NFC card, by the short-lived code the driver's app shows, or
by the card's number, see the budget left, fill, photograph the pump's meter and enter its figures. Money is paid in
advance to the fuel company, never to the platform: the fuel company records each sum it received, each fill takes its
amount, a fill outside the checks is held until someone decides. The vehicle's owner is told of every fill.

    Fuel company (the FUEL portal; fuel.manage, fuel.attend at the pump)
    GET    /api/fuel/overview                        its stations with prices and the day's fills, accounts, open anomalies
    GET    /api/fuel/staff                           its people and the stations each attends
    POST   /api/fuel/stations/{uid}/attendants       {user_uid, role}: assign a member of staff to a station
    DELETE /api/fuel/stations/{uid}/attendants/{user_uid}
    POST   /api/fuel/stations/{uid}/prices           {fuel_type, unit_price}: the price from now on
    GET    /api/fuel/accounts/{uid}                  an account held with the company and its movements
    POST   /api/fuel/accounts/{uid}/topup            {amount, reference}: a sum the company received
    GET    /api/fuel/fills                           its stations' fills; ?status=, ?station_uid=
    GET    /api/fuel/fills/{uid}/photo               the meter's photo of a fill
    POST   /api/fuel/fills/{uid}/reverse             {reason}: the fill given back to the account
    GET    /api/fuel/anomalies                       what the checks found; POST /api/fuel/anomalies/{uid} {outcome, note}
    POST   /api/fuel/pump/identify                   {station_uid, tag | card_no | code}: the vehicle and what it may take
    POST   /api/fuel/pump/bind                       {station_uid, code, tag}: a new NFC card bound to the vehicle
    POST   /api/fuel/pump/fill                       multipart: the fill with the meter's photo

    Company with vehicles (the carrier portal; vehicle.manage)
    GET    /api/carrier/fuel                         fuel companies, its accounts, its cards with budgets, its vehicles
    POST   /api/carrier/fuel/accounts                {fuel_company_uid, low_balance}; PATCH /accounts/{uid} {low_balance}
    POST   /api/carrier/fuel/cards                   {vehicle_uid, account_uid, fuel_types, budget_period, budget_amount, budget_litres}
    PATCH  /api/carrier/fuel/cards/{uid}             the same fields; POST /cards/{uid}/block {reason}, /unblock, /unbind
    GET    /api/carrier/fuel/cards/{uid}/code        the code to show at the pump
    GET    /api/carrier/fuel/fills, /fills/{uid}/photo, /consumption?days=, /anomalies; POST /anomalies/{uid}

    Driver (the DRIVER portal)
    GET    /api/driver/fuel                          the cards the driver may fill with; GET /api/driver/fuel/{card_uid}/code

    Platform (partners.manage)
    GET    /api/admin/fuel                           fuel companies, their stations and activity
    POST   /api/admin/fuel/companies                 {legal_name, license_no, owner_name, owner_email, owner_password}
    POST   /api/admin/fuel/companies/{uid}/stations  {name, code, pumps, station_uid}
    POST   /api/admin/fuel/stations/{uid}/status     {status}
    GET    /api/admin/fuel/anomalies; POST /api/admin/fuel/anomalies/{uid}
"""
import base64
import hashlib
import hmac
import json
import time
import uuid
from decimal import Decimal
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, File, Form, Query, Request, Response, UploadFile
from pydantic import BaseModel, Field, model_validator

from ... import crypto, db
from ...config import get_settings
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from ...security import hash_password
from ..account.doors import temporary_password
from ..documents import storage
from ..notify.outbox import emit
from ..photo import service as photo

fuel = APIRouter(prefix="/api/fuel", tags=["fuel"])
carrier = APIRouter(prefix="/api/carrier/fuel", tags=["fuel"])
driver = APIRouter(prefix="/api/driver/fuel", tags=["fuel"])
platform = APIRouter(prefix="/api/admin/fuel", tags=["fuel"])

FuelType = Literal["DIESEL", "GASOLINE", "LPG", "CNG", "ADBLUE"]
PHOTO_TYPES = ("image/jpeg", "image/png")
STATUS = {"NOT_STATION_STAFF": 403, "STATION_INACTIVE": 409, "FUEL_IDENTIFY_ONE": 422, "FUEL_CARD_UNKNOWN": 404,
          "FUEL_TAG_TAKEN": 409, "FUEL_CARD_HAS_TAG": 409, "NOT_A_FLEET": 403, "FUEL_COMPANY_UNKNOWN": 404,
          "FUEL_ACCOUNT_UNKNOWN": 404, "FUEL_AMOUNT": 422, "FUEL_CANNOT_FILL": 409, "FUEL_TYPE_NOT_ALLOWED": 422,
          "FUEL_NO_PRICE": 409, "FUEL_FIGURES": 422, "FUEL_PHOTO_REQUIRED": 422, "FUEL_BUDGET": 409,
          "FUEL_BUDGET_LITRES": 409, "FUEL_BALANCE": 409, "FUEL_ACCOUNT_CLOSED": 409, "FUEL_ANOMALY_UNKNOWN": 404,
          "FUEL_ANOMALY_DECIDED": 409, "FUEL_ANOMALY_NOTE": 422, "FUEL_SALE_UNKNOWN": 404, "FUEL_SALE_REVERSED": 409,
          "FUEL_REASON": 422, "NOT_FUEL_COMPANY": 403, "TENANT_MISMATCH": 422, "VEHICLE_NOT_OWNED_OR_LEASED": 422,
          "FUEL_COMPANY_REQUIRED": 422}


async def _refused(call):
    try:
        return await call
    except asyncpg.RaiseError as exc:
        code, _, message = str(exc).partition(":")
        if code in STATUS:
            raise ApiError(STATUS[code], code, message.strip() or code) from exc
        raise


def _json(value) -> dict:
    return json.loads(value) if isinstance(value, str) else value


def _audit(request: Request, action: str, object_type: str, ref, reason: Optional[str] = None) -> None:
    # the activity log's object id is a number; the fuel records are named by their uid, kept with the reason
    request.state.audit = {"action": action, "object_type": object_type, "object_id": None,
                           "reason": f"{ref}: {reason}" if reason else str(ref)}


def _tag_hash(tag: str) -> bytes:
    """The NFC tag's serial number, normalised; only its hash is ever stored."""
    return hashlib.sha256("fuel-tag:".encode() + tag.strip().upper().replace(":", "").encode()).digest()


# ------------------------------------------------------------------ the code the driver's app shows at the pump
def _code_key() -> bytes:
    return hmac.new(get_settings().signing_secret.encode(), b"fuel-pump-code", hashlib.sha256).digest()


def make_code(card_uid: uuid.UUID, seconds: int) -> tuple[str, int]:
    """A signed code naming the card, valid for a short time: shown as a QR code (or typed) at the pump."""
    exp = int(time.time()) + seconds
    body = card_uid.bytes + exp.to_bytes(5, "big")
    sig = hmac.new(_code_key(), body, hashlib.sha256).digest()[:10]
    return "F1" + base64.b32encode(body + sig).decode().rstrip("="), exp


def read_code(code: str) -> uuid.UUID:
    raw = code.strip().upper().replace(" ", "").replace("-", "")
    if not raw.startswith("F1"):
        raise ApiError(422, "FUEL_CODE_INVALID", "this is not a fuel code")
    try:
        data = base64.b32decode(raw[2:] + "=" * (-len(raw[2:]) % 8))
    except ValueError as exc:
        raise ApiError(422, "FUEL_CODE_INVALID", "this is not a fuel code") from exc
    body, sig = data[:21], data[21:]
    if len(data) != 31 or not hmac.compare_digest(sig, hmac.new(_code_key(), body, hashlib.sha256).digest()[:10]):
        raise ApiError(422, "FUEL_CODE_INVALID", "this is not a fuel code")
    if int.from_bytes(body[16:], "big") < time.time():
        raise ApiError(410, "FUEL_CODE_EXPIRED", "the code expired; ask the driver to show a new one")
    return uuid.UUID(bytes=body[:16])


async def _code_seconds(conn) -> int:
    v = _json(await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'fuel.checks'") or "{}")
    return max(30, min(int(v.get("code_seconds", 120)), 900))


# ------------------------------------------------------------------ shared reads
async def _fills(conn, where: str, args: list, limit: int) -> list[dict]:
    rows = await conn.fetch(
        f"""SELECT s.uid, s.created_at, s.station_name, s.plate_no, s.holder_name, s.fuel_type, s.qty AS litres, s.unit_price,
                   s.amount, s.expected_amount, s.currency, s.status, s.identified_by, s.pump_ref, s.odometer_km,
                   s.meter_photo_file_id IS NOT NULL AS has_photo, p.uid AS station_uid,
                   coalesce((SELECT jsonb_agg(jsonb_build_object('uid', an.uid, 'type', an.anomaly_type, 'severity', an.severity,
                                                                 'status', an.status, 'evidence', an.evidence, 'note', an.note)
                                              ORDER BY an.id)
                               FROM ptn.fuel_anomaly an WHERE an.session_id = s.session_id), '[]'::jsonb)::text AS anomalies
              FROM ptn.partner_sale s JOIN ptn.partner p ON p.id = s.partner_id
             WHERE s.method = 'PREPAID' {where} ORDER BY s.created_at DESC LIMIT {int(limit)}""", *args)
    return [{**dict(r), "anomalies": json.loads(r["anomalies"])} for r in rows]


async def _anomalies(conn, status: Optional[str]) -> list[dict]:
    rows = await conn.fetch(
        """SELECT an.uid, an.anomaly_type AS type, an.severity, an.status, an.evidence::text AS evidence, an.note, an.created_at,
                  an.resolved_at, s.uid AS sale_uid, s.plate_no, s.station_name, s.holder_name, s.qty AS litres, s.amount,
                  s.currency, s.created_at AS filled_at
             FROM ptn.fuel_anomaly an JOIN ptn.partner_sale s ON s.session_id = an.session_id
            WHERE ($1::text IS NULL OR an.status = $1) ORDER BY an.created_at DESC LIMIT 200""", status)
    return [{**dict(r), "evidence": json.loads(r["evidence"])} for r in rows]


async def _photo(request: Request, pr: Principal, sale_uid: uuid.UUID) -> Response:
    """The meter's photo of a fill the caller sees (its fuel company or the vehicle's company)."""
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        file_id = await conn.fetchval("SELECT meter_photo_file_id FROM ptn.partner_sale WHERE uid = $1 AND method = 'PREPAID'", sale_uid)
        if file_id is None:
            raise not_found("photo")
        data, mime = await read_meter_photo(conn, ctx, file_id)
    _audit(request, "fuel.photo_viewed", "fuel_sale", sale_uid)
    return Response(content=data, media_type=mime, headers={"Cache-Control": "private, no-store"})


async def read_meter_photo(conn, ctx: db.Context, file_id: int) -> tuple[bytes, str]:
    async with db.system_scope(conn, ctx):
        row = await conn.fetchrow("SELECT storage_key, enc_key_id, sha256, mime_type, scan_status FROM ref.file_object WHERE id = $1", file_id)
        if row is None:
            raise not_found("photo")
        if row["scan_status"] != "CLEAN":
            raise ApiError(409, "FILE_NOT_CLEAN", "the photo is not available until it passes the security scan")
        data = await storage.get(await crypto.cipher(conn), row["storage_key"], row["enc_key_id"], bytes(row["sha256"]))
    return data, row["mime_type"]


class DecideIn(BaseModel):
    outcome: Literal["EXPLAINED", "CONFIRMED", "DISMISSED"]
    note: str = Field(min_length=3, max_length=300)


async def _decide(request: Request, pr: Principal, anomaly_uid: uuid.UUID, body: DecideIn) -> dict:
    async with db.transaction(context_for(request, pr)) as conn:
        sale = await _refused(conn.fetchval("SELECT ptn.decide_fuel_anomaly($1, $2, $3)", anomaly_uid, body.outcome, body.note))
    _audit(request, "fuel.anomaly_decided", "fuel_anomaly", anomaly_uid, f"{body.outcome}: {body.note}")
    return {"ok": True, "sale_status": sale}


# ================================================================== the fuel company's portal
def _company(pr: Principal) -> None:
    if not pr.company_id:
        raise forbidden("a fuel company's portal")


def _manager(pr: Principal) -> None:
    _company(pr)
    if not (pr.is_owner or "fuel.manage" in pr.permissions):
        raise forbidden("missing permission: fuel.manage")


def _attendant(pr: Principal) -> None:
    _company(pr)
    if not (pr.is_owner or "fuel.attend" in pr.permissions):
        raise forbidden("missing permission: fuel.attend")


fuel_staff = require_portal("FUEL")


async def _station(conn, uid: uuid.UUID) -> int:
    sid = await conn.fetchval("SELECT id FROM ptn.partner WHERE uid = $1 AND partner_type = 'FUEL'", uid)
    if sid is None:
        raise not_found("station")
    return sid


@fuel.get("/overview")
async def overview(request: Request, pr: Principal = Depends(fuel_staff)):
    _company(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        view = _json(await _refused(conn.fetchval("SELECT ptn.fuel_company_view($1)::text", pr.company_id)))
        mine = await conn.fetch(
            """SELECT p.uid, p.code, pa.legal_name AS name, p.pumps, e.role FROM ptn.station_employee e
                 JOIN ptn.partner p ON p.id = e.partner_id JOIN iam.party pa ON pa.id = p.party_id
                WHERE e.user_id = $1 AND e.status = 'ACTIVE' AND p.status = 'ACTIVE' AND p.company_id = $2 ORDER BY p.code""",
            pr.user_id, pr.company_id)
        enabled = await conn.fetchval("SELECT sys.feature_on('{service_partners}')")
    manage = pr.is_owner or "fuel.manage" in pr.permissions
    return {**view, "my_stations": [dict(r) for r in mine], "enabled": enabled,
            "can": {"manage": manage, "attend": pr.is_owner or "fuel.attend" in pr.permissions},
            **({} if manage else {"accounts": []})}


@fuel.get("/staff")
async def staff(request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        people = await conn.fetch(
            """SELECT u.uid, coalesce(p.legal_name, u.email) AS name, u.username, m.is_owner,
                      coalesce((SELECT jsonb_agg(jsonb_build_object('station_uid', pt.uid, 'code', pt.code, 'role', e.role) ORDER BY pt.code)
                                  FROM ptn.station_employee e JOIN ptn.partner pt ON pt.id = e.partner_id
                                 WHERE e.user_id = u.id AND e.status = 'ACTIVE'), '[]'::jsonb)::text AS stations
                 FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id JOIN iam.party p ON p.id = u.party_id
                WHERE m.company_id = $1 AND m.status = 'ACTIVE' ORDER BY name""", pr.company_id)
    return {"people": [{**dict(r), "stations": json.loads(r["stations"])} for r in people]}


class AttendantIn(BaseModel):
    user_uid: uuid.UUID
    role: Literal["ATTENDANT", "CASHIER", "MANAGER"] = "ATTENDANT"


@fuel.post("/stations/{station_uid}/attendants", status_code=201)
async def attendant_add(station_uid: uuid.UUID, body: AttendantIn, request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _station(conn, station_uid)
        user_id = await conn.fetchval(
            """SELECT u.id FROM iam.app_user u JOIN iam.company_member m ON m.user_id = u.id
                WHERE u.uid = $1 AND m.company_id = $2 AND m.status = 'ACTIVE'""", body.user_uid, pr.company_id)
        if user_id is None:
            raise not_found("member of staff")
        await conn.execute(
            """INSERT INTO ptn.station_employee (partner_id, user_id, role) VALUES ($1, $2, $3)
               ON CONFLICT (partner_id, user_id) DO UPDATE SET role = EXCLUDED.role, status = 'ACTIVE'""", sid, user_id, body.role)
    _audit(request, "fuel.attendant_assigned", "fuel_station", station_uid, body.role)
    return {"ok": True}


@fuel.delete("/stations/{station_uid}/attendants/{user_uid}")
async def attendant_remove(station_uid: uuid.UUID, user_uid: uuid.UUID, request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _station(conn, station_uid)
        n = await conn.execute(
            """UPDATE ptn.station_employee SET status = 'DISABLED'
                WHERE partner_id = $1 AND user_id = (SELECT id FROM iam.app_user WHERE uid = $2) AND status = 'ACTIVE'""", sid, user_uid)
    if n.endswith(" 0"):
        raise not_found("attendant")
    _audit(request, "fuel.attendant_removed", "fuel_station", station_uid)
    return {"ok": True}


class PriceIn(BaseModel):
    fuel_type: FuelType
    unit_price: int = Field(gt=0, le=10**12)


@fuel.post("/stations/{station_uid}/prices", status_code=201)
async def price_set(station_uid: uuid.UUID, body: PriceIn, request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        sid = await _station(conn, station_uid)
        await conn.execute(
            """INSERT INTO ptn.fuel_price (partner_id, fuel_type, unit_price, currency)
               VALUES ($1, $2, $3, ref.company_currency($4))""", sid, body.fuel_type, body.unit_price, pr.company_id)
    _audit(request, "fuel.price_set", "fuel_station", station_uid, f"{body.fuel_type} {body.unit_price}")
    return {"ok": True}


async def _account_view(conn, uid: uuid.UUID) -> dict:
    a = await conn.fetchrow(
        """SELECT a.id, a.uid, a.currency, a.balance, a.low_balance, a.status, a.created_at,
                  (SELECT legal_name FROM iam.party WHERE id = a.fuel_company_id) AS fuel_company,
                  ptn.account_visible(a.id) AS visible
             FROM ptn.fuel_account a WHERE a.uid = $1""", uid)
    if a is None:
        raise not_found("fuel account")
    entries = await conn.fetch(
        """SELECT e.kind, e.amount, e.balance_after, e.reference, e.note, e.created_at, s.uid AS sale_uid, s.plate_no, s.station_name
             FROM ptn.fuel_account_entry e LEFT JOIN ptn.partner_sale s ON s.id = e.sale_id
            WHERE e.account_id = $1 ORDER BY e.id DESC LIMIT 200""", a["id"])
    out = dict(a)
    out.pop("id"), out.pop("visible")
    return {**out, "entries": [dict(e) for e in entries]}


@fuel.get("/accounts/{uid}")
async def account_get(uid: uuid.UUID, request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _account_view(conn, uid)


class TopupIn(BaseModel):
    amount: int = Field(gt=0, le=10**14)
    reference: Optional[str] = Field(default=None, max_length=80)


@fuel.post("/accounts/{uid}/topup")
async def account_topup(uid: uuid.UUID, body: TopupIn, request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        balance = await _refused(conn.fetchval("SELECT ptn.fuel_topup($1, $2, $3)", uid, body.amount, body.reference))
    _audit(request, "fuel.topup", "fuel_account", uid, f"{body.amount} {body.reference or ''}".strip())
    return {"balance": balance}


@fuel.get("/fills")
async def fills(request: Request, status: Optional[Literal["COMPLETED", "PENDING", "DISPUTED", "REVERSED"]] = None,
                station_uid: Optional[uuid.UUID] = None, limit: int = Query(default=100, ge=1, le=500),
                pr: Principal = Depends(fuel_staff)):
    _company(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await _fills(conn, "AND p.company_id = $1 AND ($2::text IS NULL OR s.status = $2) AND ($3::uuid IS NULL OR p.uid = $3)"
                            + ("" if pr.is_owner or "fuel.manage" in pr.permissions else
                               " AND EXISTS (SELECT 1 FROM ptn.station_employee e WHERE e.partner_id = p.id AND e.user_id = $4)"),
                            [pr.company_id, status, station_uid] + ([] if pr.is_owner or "fuel.manage" in pr.permissions else [pr.user_id]),
                            limit)
    return {"fills": rows}


@fuel.get("/fills/{uid}/photo")
async def fill_photo(uid: uuid.UUID, request: Request, pr: Principal = Depends(fuel_staff)):
    _company(pr)
    return await _photo(request, pr, uid)


class ReasonIn(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


@fuel.post("/fills/{uid}/reverse")
async def fill_reverse(uid: uuid.UUID, body: ReasonIn, request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        balance = await _refused(conn.fetchval("SELECT ptn.fuel_reverse_sale($1, $2)", uid, body.reason))
    _audit(request, "fuel.fill_reversed", "fuel_sale", uid, body.reason)
    return {"balance": balance}


@fuel.get("/anomalies")
async def anomalies(request: Request, status: Optional[Literal["OPEN", "EXPLAINED", "CONFIRMED", "DISMISSED"]] = "OPEN",
                    pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"anomalies": await _anomalies(conn, status)}


@fuel.post("/anomalies/{uid}")
async def anomaly_decide(uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(fuel_staff)):
    _manager(pr)
    return await _decide(request, pr, uid, body)


# ------------------------------------------------------------------ at the pump
class IdentifyIn(BaseModel):
    station_uid: uuid.UUID
    tag: Optional[str] = Field(default=None, min_length=4, max_length=64)
    card_no: Optional[str] = Field(default=None, min_length=8, max_length=12)
    code: Optional[str] = Field(default=None, min_length=10, max_length=80)

    @model_validator(mode="after")
    def _one(self):
        if sum(x is not None for x in (self.tag, self.card_no, self.code)) != 1:
            raise ValueError("identify the vehicle one way: its tag, its card number or the driver's code")
        return self


@fuel.post("/pump/identify")
async def pump_identify(body: IdentifyIn, request: Request, pr: Principal = Depends(fuel_staff)):
    _attendant(pr)
    card_uid = read_code(body.code) if body.code else None
    async with db.transaction(context_for(request, pr)) as conn:
        state = _json(await _refused(conn.fetchval(
            "SELECT ptn.fuel_identify($1, $2, $3, $4)::text", body.station_uid,
            _tag_hash(body.tag) if body.tag else None, body.card_no, card_uid)))
    return {**state, "identified_by": "NFC" if body.tag else "APP" if body.code else "CARD_NO"}


class BindIn(BaseModel):
    station_uid: uuid.UUID
    code: str = Field(min_length=10, max_length=80)
    tag: str = Field(min_length=4, max_length=64)


@fuel.post("/pump/bind")
async def pump_bind(body: BindIn, request: Request, pr: Principal = Depends(fuel_staff)):
    _attendant(pr)
    card_uid = read_code(body.code)
    async with db.transaction(context_for(request, pr)) as conn:
        await _refused(conn.execute("SELECT ptn.fuel_bind_tag($1, $2, $3)", body.station_uid, card_uid, _tag_hash(body.tag)))
    _audit(request, "fuel.tag_bound", "fuel_card", card_uid)
    return {"ok": True, "card_uid": card_uid}


@fuel.post("/pump/fill", status_code=201)
async def pump_fill(request: Request, station_uid: uuid.UUID = Form(...), card_uid: uuid.UUID = Form(...),
                    identified_by: Literal["NFC", "APP", "CARD_NO"] = Form(...), fuel_type: FuelType = Form(...),
                    litres: Decimal = Form(..., gt=0, le=2000, max_digits=8, decimal_places=2),
                    amount: int = Form(..., gt=0, le=10**14), odometer_km: Optional[int] = Form(default=None, ge=0, le=9_999_999),
                    pump: Optional[str] = Form(default=None, max_length=20), photo_file: Optional[UploadFile] = File(default=None),
                    pr: Principal = Depends(fuel_staff)):
    _attendant(pr)
    ctx = context_for(request, pr)
    data = None
    if photo_file is not None:
        limit = get_settings().max_upload_bytes
        data = await photo_file.read(limit + 1)
        if len(data) > limit:
            raise ApiError(422, "FILE_TOO_LARGE", "the file is larger than allowed", max_bytes=limit)
    async with db.transaction(ctx) as conn:
        file_id = await photo.store(conn, ctx, pr, data, photo_file.filename or "meter.jpg", PHOTO_TYPES, "PHOTO_TYPE") if data else None
        out = _json(await _refused(conn.fetchval(
            "SELECT ptn.fuel_fill($1, $2, $3, $4, $5, $6, $7, $8, $9)::text", station_uid, card_uid, identified_by, fuel_type,
            litres, amount, file_id, odometer_km, pump)))
        await emit(conn, "fuel.filled", "fuel_sale", out["sale_id"], {
            "sale_uid": out["sale_uid"], "station": out["station"], "plate_no": out["plate_no"], "fuel_type": fuel_type,
            "litres": float(litres), "amount": amount, "currency": out["currency"], "balance": out["balance"],
            "left_amount": out["left_amount"], "held": out["status"] == "HELD", "low_balance": out["low_balance"],
            "anomalies": [a["type"] for a in out["anomalies"]]}, company_id=out["holder_company_id"])
    _audit(request, "fuel.filled", "fuel_sale", out["sale_uid"], f"{litres} L {amount}")
    for k in ("sale_id", "holder_company_id"):
        out.pop(k, None)
    return out


# ================================================================== the company with vehicles
def _fleet(pr: Principal) -> None:
    if pr.portal != "OPERATOR" or not pr.company_id or not (pr.is_owner or "vehicle.manage" in pr.permissions):
        raise forbidden("missing permission: vehicle.manage")


fleet_staff = require_portal("OPERATOR")


@carrier.get("")
async def carrier_view(request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        companies = await conn.fetch(
            """SELECT p.uid, p.legal_name AS name FROM iam.company c JOIN iam.party p ON p.id = c.id
                WHERE c.company_type = 'FUEL_COMPANY' AND c.approval_status = 'APPROVED' ORDER BY p.legal_name""")
        accounts = await conn.fetch(
            """SELECT a.uid, a.currency, a.balance, a.low_balance, a.status, fp.uid AS fuel_company_uid, fp.legal_name AS fuel_company
                 FROM ptn.fuel_account a JOIN iam.party fp ON fp.id = a.fuel_company_id
                WHERE a.holder_company_id = $1 ORDER BY fp.legal_name""", pr.company_id)
        cards = await conn.fetch(
            """SELECT c.uid, c.card_no, c.status, c.blocked_reason, c.fuel_types, c.budget_period, c.budget_amount, c.budget_litres,
                      v.uid AS vehicle_uid, v.plate_no, a.uid AS account_uid, fp.legal_name AS fuel_company,
                      EXISTS (SELECT 1 FROM ptn.fuel_card_tag t WHERE t.card_id = c.id AND t.unbound_at IS NULL) AS tag_bound,
                      (SELECT coalesce(sum(s.amount), 0) FROM ptn.partner_sale s WHERE s.card_id = c.id AND s.status <> 'REVERSED'
                          AND s.created_at >= ptn_budget.start) AS used_amount,
                      (SELECT coalesce(sum(s.qty), 0) FROM ptn.partner_sale s WHERE s.card_id = c.id AND s.status <> 'REVERSED'
                          AND s.created_at >= ptn_budget.start) AS used_litres
                 FROM ptn.fuel_card c
                 LEFT JOIN fleet.vehicle v ON v.id = c.vehicle_id
                 LEFT JOIN ptn.fuel_account a ON a.id = c.account_id
                 LEFT JOIN iam.party fp ON fp.id = a.fuel_company_id
                 CROSS JOIN LATERAL (SELECT coalesce(date_trunc(lower(coalesce(c.budget_period, 'MONTH')),
                                                     now() AT TIME ZONE coalesce(ref.company_tz(c.company_id), 'UTC'))
                                                     AT TIME ZONE coalesce(ref.company_tz(c.company_id), 'UTC'), now()) AS start) ptn_budget
                WHERE c.company_id = $1 AND c.status <> 'RETIRED' ORDER BY v.plate_no NULLS LAST""", pr.company_id)
        vehicles = await conn.fetch(
            """SELECT v.uid, v.plate_no, v.fuel_type, v.fuel_tank_l FROM fleet.vehicle v
                WHERE v.company_id = $1 AND v.status = 'ACTIVE' ORDER BY v.plate_no""", pr.company_id)
        enabled = await conn.fetchval("SELECT sys.feature_on('{service_partners}')")
    return {"enabled": enabled, "fuel_companies": [dict(r) for r in companies], "accounts": [dict(r) for r in accounts],
            "cards": [dict(r) for r in cards], "vehicles": [dict(r) for r in vehicles]}


class AccountIn(BaseModel):
    fuel_company_uid: uuid.UUID
    low_balance: Optional[int] = Field(default=None, gt=0, le=10**14)


@carrier.post("/accounts", status_code=201)
async def carrier_open(body: AccountIn, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await _refused(conn.fetchval("SELECT ptn.fuel_open_account($1, NULL)", body.fuel_company_uid))
        if body.low_balance:
            await _set_low_balance(conn, pr, uid, body.low_balance)
    _audit(request, "fuel.account_opened", "fuel_account", uid)
    return {"uid": uid}


class LowBalanceIn(BaseModel):
    low_balance: Optional[int] = Field(default=None, gt=0, le=10**14)


async def _set_low_balance(conn, pr: Principal, uid: uuid.UUID, value: Optional[int]) -> None:
    # the account moves through the database's functions only: the holder sets its own alert there
    await _refused(conn.execute("SELECT ptn.fuel_set_low_balance($1, $2)", uid, value))


@carrier.patch("/accounts/{uid}")
async def carrier_account_edit(uid: uuid.UUID, body: LowBalanceIn, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _set_low_balance(conn, pr, uid, body.low_balance)
    _audit(request, "fuel.account_alert", "fuel_account", uid, str(body.low_balance))
    return {"ok": True}


class CardIn(BaseModel):
    fuel_types: list[FuelType] = Field(min_length=1, max_length=5)
    budget_period: Optional[Literal["DAY", "WEEK", "MONTH"]] = None
    budget_amount: Optional[int] = Field(default=None, gt=0, le=10**14)
    budget_litres: Optional[Decimal] = Field(default=None, gt=0, le=100000, max_digits=8, decimal_places=2)

    @model_validator(mode="after")
    def _budget(self):
        if (self.budget_period is None) != (self.budget_amount is None and self.budget_litres is None):
            raise ValueError("a budget names its period and an amount, litres or both")
        return self


class NewCardIn(CardIn):
    vehicle_uid: uuid.UUID
    account_uid: uuid.UUID


@carrier.post("/cards", status_code=201)
async def card_add(body: NewCardIn, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        vehicle_id = await conn.fetchval("SELECT id FROM fleet.vehicle WHERE uid = $1 AND company_id = $2", body.vehicle_uid, pr.company_id)
        account_id = await conn.fetchval("SELECT id FROM ptn.fuel_account WHERE uid = $1 AND holder_company_id = $2",
                                         body.account_uid, pr.company_id)
        if vehicle_id is None or account_id is None:
            raise not_found("vehicle or fuel account")
        try:
            row = await _refused(conn.fetchrow(
                """INSERT INTO ptn.fuel_card (company_id, vehicle_id, account_id, fuel_types, budget_period, budget_amount, budget_litres)
                   VALUES ($1, $2, $3, $4, $5, $6, $7) RETURNING uid, card_no""",
                pr.company_id, vehicle_id, account_id, body.fuel_types, body.budget_period, body.budget_amount, body.budget_litres))
        except asyncpg.UniqueViolationError as exc:
            raise ApiError(409, "FUEL_CARD_EXISTS", "the vehicle already has a card in use; block or retire it first") from exc
    _audit(request, "fuel.card_issued", "fuel_card", row["uid"])
    return dict(row)


async def _card_update(conn, pr: Principal, uid: uuid.UUID, sets: str, args: list) -> None:
    n = await conn.execute(f"UPDATE ptn.fuel_card SET {sets} WHERE uid = $1 AND company_id = $2", uid, pr.company_id, *args)
    if n.endswith(" 0"):
        raise not_found("fuel card")


@carrier.patch("/cards/{uid}")
async def card_edit(uid: uuid.UUID, body: CardIn, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _refused(_card_update(conn, pr, uid, "fuel_types = $3, budget_period = $4, budget_amount = $5, budget_litres = $6",
                                    [body.fuel_types, body.budget_period, body.budget_amount, body.budget_litres]))
    _audit(request, "fuel.card_budget", "fuel_card", uid,
           f"{body.budget_period or '-'} {body.budget_amount or '-'} {body.budget_litres or '-'}")
    return {"ok": True}


@carrier.post("/cards/{uid}/block")
async def card_block(uid: uuid.UUID, body: ReasonIn, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        await _card_update(conn, pr, uid, "status = 'BLOCKED', blocked_reason = $3", [body.reason])
    _audit(request, "fuel.card_blocked", "fuel_card", uid, body.reason)
    return {"ok": True}


@carrier.post("/cards/{uid}/unblock")
async def card_unblock(uid: uuid.UUID, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        try:
            await _card_update(conn, pr, uid, "status = 'ACTIVE'", [])
        except asyncpg.UniqueViolationError as exc:
            raise ApiError(409, "FUEL_CARD_EXISTS", "the vehicle has another card in use") from exc
    _audit(request, "fuel.card_unblocked", "fuel_card", uid)
    return {"ok": True}


@carrier.post("/cards/{uid}/unbind")
async def card_unbind(uid: uuid.UUID, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        n = await conn.fetchval("SELECT ptn.fuel_unbind_tag($1)", uid)
    if not n:
        raise ApiError(409, "FUEL_NO_TAG", "the card has no tag bound")
    _audit(request, "fuel.tag_unbound", "fuel_card", uid)
    return {"ok": True}


async def _code_for(conn, card_uid: uuid.UUID, where: str, args: list) -> dict:
    row = await conn.fetchrow(
        f"""SELECT c.uid, c.status, v.plate_no FROM ptn.fuel_card c JOIN fleet.vehicle v ON v.id = c.vehicle_id
             WHERE c.uid = $1 {where}""", card_uid, *args)
    if row is None:
        raise not_found("fuel card")
    if row["status"] != "ACTIVE":
        raise ApiError(409, "FUEL_CARD_INACTIVE", "the card is not in use")
    code, exp = make_code(row["uid"], await _code_seconds(conn))
    return {"code": code, "expires_in": exp - int(time.time()), "plate_no": row["plate_no"]}


@carrier.get("/cards/{uid}/code")
async def card_code(uid: uuid.UUID, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _code_for(conn, uid, "AND c.company_id = $2", [pr.company_id])


@carrier.get("/fills")
async def carrier_fills(request: Request, vehicle_uid: Optional[uuid.UUID] = None,
                        status: Optional[Literal["COMPLETED", "PENDING", "DISPUTED", "REVERSED"]] = None,
                        limit: int = Query(default=100, ge=1, le=500), pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await _fills(conn, """AND s.company_id = $1 AND ($2::text IS NULL OR s.status = $2)
                                     AND ($3::uuid IS NULL OR s.vehicle_id = (SELECT id FROM fleet.vehicle WHERE uid = $3))""",
                            [pr.company_id, status, vehicle_uid], limit)
    return {"fills": rows}


@carrier.get("/fills/{uid}/photo")
async def carrier_photo(uid: uuid.UUID, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    return await _photo(request, pr, uid)


@carrier.get("/consumption")
async def consumption(request: Request, days: int = Query(default=30, ge=1, le=366), pr: Principal = Depends(fleet_staff)):
    """Per vehicle over the last days: fills, litres, amount, kilometres between the first and last odometer, and the
    litres per 100 km of the fills after the first (the first fills what an earlier stretch used)."""
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """WITH f AS (
                 SELECT s.vehicle_id, s.plate_no, s.qty, s.amount, s.currency, s.odometer_km, s.status, s.session_id,
                        row_number() OVER (PARTITION BY s.vehicle_id ORDER BY s.created_at) AS n
                   FROM ptn.partner_sale s
                  WHERE s.company_id = $1 AND s.method = 'PREPAID' AND s.status <> 'REVERSED'
                    AND s.created_at >= now() - make_interval(days => $2))
               SELECT v.uid AS vehicle_uid, max(f.plate_no) AS plate_no, count(*) AS fills, sum(f.qty) AS litres,
                      sum(f.amount) AS amount, max(f.currency) AS currency,
                      max(f.odometer_km) - min(f.odometer_km) AS km,
                      CASE WHEN max(f.odometer_km) > min(f.odometer_km)
                           THEN round(sum(f.qty) FILTER (WHERE f.n > 1) * 100 / (max(f.odometer_km) - min(f.odometer_km)), 1) END AS l_per_100km,
                      (SELECT count(*) FROM ptn.fuel_anomaly an WHERE an.session_id = ANY (array_agg(f.session_id))) AS anomalies
                 FROM f JOIN fleet.vehicle v ON v.id = f.vehicle_id
                GROUP BY v.uid ORDER BY sum(f.amount) DESC""", pr.company_id, days)
    return {"days": days, "vehicles": [dict(r) for r in rows]}


@carrier.get("/anomalies")
async def carrier_anomalies(request: Request, status: Optional[Literal["OPEN", "EXPLAINED", "CONFIRMED", "DISMISSED"]] = "OPEN",
                            pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"anomalies": await _anomalies(conn, status)}


@carrier.post("/anomalies/{uid}")
async def carrier_decide(uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(fleet_staff)):
    _fleet(pr)
    return await _decide(request, pr, uid, body)


# ================================================================== the driver
drivers = require_portal("DRIVER")


@driver.get("")
async def driver_cards(request: Request, pr: Principal = Depends(drivers)):
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT c.uid, c.card_no, v.plate_no, c.fuel_types FROM ptn.fuel_card c JOIN fleet.vehicle v ON v.id = c.vehicle_id
                WHERE c.company_id = $1 AND c.status = 'ACTIVE' AND (c.driver_party_id IS NULL OR c.driver_party_id = $2)
                ORDER BY v.plate_no""", pr.company_id, pr.party_id)
    return {"cards": [dict(r) for r in rows]}


@driver.get("/{card_uid}/code")
async def driver_code(card_uid: uuid.UUID, request: Request, pr: Principal = Depends(drivers)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await _code_for(conn, card_uid, "AND c.company_id = $2 AND (c.driver_party_id IS NULL OR c.driver_party_id = $3)",
                               [pr.company_id, pr.party_id])


# ================================================================== the platform
def _platform(pr: Principal) -> None:
    if "partners.manage" not in pr.permissions:
        raise forbidden("missing permission: partners.manage")


admins = require_portal("PLATFORM")


@platform.get("")
async def admin_view(request: Request, pr: Principal = Depends(admins)):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT p.uid, p.legal_name AS name, c.company_no, c.approval_status,
                      coalesce((SELECT jsonb_agg(jsonb_build_object('uid', pt.uid, 'code', pt.code, 'name', pa.legal_name,
                                                                     'status', pt.status, 'pumps', pt.pumps,
                                                                     'station', (SELECT s.name FROM net.station s WHERE s.id = pt.station_id))
                                                  ORDER BY pt.code)
                                  FROM ptn.partner pt JOIN iam.party pa ON pa.id = pt.party_id WHERE pt.company_id = c.id), '[]'::jsonb)::text AS stations,
                      (SELECT count(*) FROM ptn.fuel_account a WHERE a.fuel_company_id = c.id) AS accounts,
                      (SELECT count(*) FROM ptn.partner_sale s JOIN ptn.partner pt ON pt.id = s.partner_id
                        WHERE pt.company_id = c.id AND s.created_at >= now() - interval '1 day') AS fills_24h
                 FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE c.company_type = 'FUEL_COMPANY' ORDER BY p.legal_name""")
        enabled = await conn.fetchval("SELECT sys.feature_on('{service_partners}')")
        open_anomalies = await conn.fetchval("SELECT count(*) FROM ptn.fuel_anomaly WHERE status = 'OPEN'")
    return {"enabled": enabled, "open_anomalies": open_anomalies,
            "companies": [{**dict(r), "stations": json.loads(r["stations"])} for r in rows]}


class CompanyIn(BaseModel):
    legal_name: str = Field(min_length=2, max_length=200)
    license_no: Optional[str] = Field(default=None, max_length=60)
    owner_name: str = Field(min_length=3, max_length=120)
    owner_email: str = Field(min_length=5, max_length=200, pattern=r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
    owner_password: str = Field(min_length=12, max_length=200)


@platform.post("/companies", status_code=201)
async def admin_company(body: CompanyIn, request: Request, pr: Principal = Depends(admins)):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        company_id = await conn.fetchval("INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', $1) RETURNING id",
                                         body.legal_name.strip())
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'FUEL_COMPANY')", company_id)
        await conn.execute(
            """INSERT INTO iam.company (id, company_type, transport_license_no, approval_status, approved_by, approved_at)
               VALUES ($1, 'FUEL_COMPANY', $2, 'APPROVED', $3, now())""", company_id, body.license_no, pr.user_id)
        owner_party = await conn.fetchval("INSERT INTO iam.party (party_type, legal_name) VALUES ('PERSON', $1) RETURNING id",
                                          body.owner_name.strip())
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'FUEL_STAFF')", owner_party)
        try:
            owner = await conn.fetchval(
                """INSERT INTO iam.app_user (party_id, account_kind, email, password_hash, password_changed_at, status,
                                             preferred_locale, mfa_required)
                   VALUES ($1, 'COMPANY', lower($2), $3, now(), 'ACTIVE',
                           (SELECT value #>> '{}' FROM sys.setting WHERE key = 'ui.default_locale'), true) RETURNING id""",
                owner_party, body.owner_email, hash_password(body.owner_password))
        except asyncpg.UniqueViolationError as exc:
            raise ApiError(409, "EMAIL_TAKEN", "an account with this email exists") from exc
        await conn.execute("INSERT INTO iam.company_member (user_id, company_id, is_owner) VALUES ($1, $2, true)", owner, company_id)
        door = await temporary_password(conn, owner)
        uid = await conn.fetchval("SELECT uid FROM iam.party WHERE id = $1", company_id)
    _audit(request, "fuel.company_added", "company", uid, body.legal_name)
    return {"uid": uid, "door": door}


class StationIn(BaseModel):
    name: str = Field(min_length=2, max_length=200)
    code: str = Field(pattern=r"^[A-Z0-9-]{3,30}$")
    pumps: Optional[int] = Field(default=None, ge=1, le=99)
    station_uid: Optional[uuid.UUID] = None


@platform.post("/companies/{uid}/stations", status_code=201)
async def admin_station(uid: uuid.UUID, body: StationIn, request: Request, pr: Principal = Depends(admins)):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        company_id = await conn.fetchval(
            "SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1 AND c.company_type = 'FUEL_COMPANY'", uid)
        if company_id is None:
            raise not_found("fuel company")
        station_id = None
        if body.station_uid:
            station_id = await conn.fetchval("SELECT id FROM net.station WHERE uid = $1", body.station_uid)
            if station_id is None:
                raise not_found("station")
        party = await conn.fetchval("INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', $1) RETURNING id", body.name.strip())
        try:
            sid = await _refused(conn.fetchval(
                """INSERT INTO ptn.partner (party_id, company_id, partner_type, code, station_id, pumps, status, compliance_state)
                   VALUES ($1, $2, 'FUEL', $3, $4, $5, 'ACTIVE', 'COMPLIANT') RETURNING uid""",
                party, company_id, body.code, station_id, body.pumps))
        except asyncpg.UniqueViolationError as exc:
            raise ApiError(409, "STATION_CODE_TAKEN", "another partner has this code") from exc
    _audit(request, "fuel.station_added", "fuel_station", sid, body.code)
    return {"uid": sid}


class StationStatusIn(BaseModel):
    status: Literal["ACTIVE", "SUSPENDED", "ENDED"]


@platform.post("/stations/{uid}/status")
async def admin_station_status(uid: uuid.UUID, body: StationStatusIn, request: Request, pr: Principal = Depends(admins)):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        n = await conn.execute("UPDATE ptn.partner SET status = $2 WHERE uid = $1 AND partner_type = 'FUEL'", uid, body.status)
    if n.endswith(" 0"):
        raise not_found("fuel station")
    _audit(request, "fuel.station_status", "fuel_station", uid, body.status)
    return {"ok": True}


@platform.get("/anomalies")
async def admin_anomalies(request: Request, status: Optional[Literal["OPEN", "EXPLAINED", "CONFIRMED", "DISMISSED"]] = "OPEN",
                          pr: Principal = Depends(admins)):
    _platform(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        return {"anomalies": await _anomalies(conn, status)}


@platform.post("/anomalies/{uid}")
async def admin_decide(uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(admins)):
    _platform(pr)
    return await _decide(request, pr, uid, body)
