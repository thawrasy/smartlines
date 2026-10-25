"""Vehicle makes and models (owner's request N8, migration 1157).

Platform staff holding reference.manage enter or import makes and models, and another person reviews each before carriers
can pick it. A carrier that does not find its model asks for it. The platform approves the request, which adds the model
waiting for a second person's review. It can also match the request to a model already in the list, or reject it with a
reason. A vehicle picks its model, and the database copies the make and model names onto the vehicle."""
import io
import re
import uuid
from typing import Any, Literal, Optional

import asyncpg
from pydantic import BaseModel, Field, ValidationError

from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from .service import ReviewIn, need

VehicleType = Literal["COACH", "MINIBUS", "CITY_BUS", "VAN", "TRAIN_SET", "OTHER"]
MAX_FILE = 5 * 1024 * 1024
MAX_ROWS = 3000


class MakeIn(BaseModel):
    code: Optional[str] = Field(default=None, pattern=r"^[A-Z0-9]{2,16}$")
    name_en: str = Field(min_length=2, max_length=80)
    name_ar: str = Field(min_length=2, max_length=80)
    country_code: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}$")


class ModelIn(BaseModel):
    make_uid: uuid.UUID
    name: str = Field(min_length=1, max_length=80)
    vehicle_class: Literal["BUS", "TRUCK", "TRAIN", "CAR", "OTHER"] = "BUS"
    vehicle_type: VehicleType = "COACH"
    seats_from: Optional[int] = Field(default=None, ge=1, le=120)
    seats_to: Optional[int] = Field(default=None, ge=1, le=120)
    weight_class: Optional[Literal["LIGHT", "MEDIUM", "HEAVY"]] = None
    production: Literal["CURRENT", "OLDER"] = "CURRENT"
    confidence: Literal["HIGH", "MEDIUM", "VERIFY"] = "VERIFY"
    notes: Optional[str] = Field(default=None, max_length=500)


class RequestIn(BaseModel):
    make_uid: Optional[uuid.UUID] = None
    make_name: Optional[str] = Field(default=None, min_length=2, max_length=80)
    model_name: str = Field(min_length=1, max_length=80)
    vehicle_type: VehicleType = "COACH"
    seats: Optional[int] = Field(default=None, ge=1, le=120)
    note: Optional[str] = Field(default=None, max_length=500)


class DecideIn(BaseModel):
    decision: Literal["APPROVE", "MATCH", "REJECT"]
    model_uid: Optional[uuid.UUID] = None            # MATCH: the model already in the list
    make_name_ar: Optional[str] = Field(default=None, min_length=2, max_length=80)   # APPROVE of a new make
    note: Optional[str] = Field(default=None, min_length=3, max_length=300)


def make_code(name_en: str) -> str:
    return (re.sub(r"[^A-Z0-9]", "", name_en.upper()) or "MAKE")[:16]


def _row(r: asyncpg.Record, drop: tuple = ()) -> dict:
    out = {}
    for k, v in dict(r).items():
        if k in drop or k == "id" or k.endswith("_by") or k.endswith("_id"):
            continue
        out[k] = str(v) if isinstance(v, uuid.UUID) else (v.isoformat() if hasattr(v, "isoformat") else v)
    return out


# ------------------------------------------------------------------ listing
async def catalog(conn: asyncpg.Connection, pr: Principal) -> dict:
    """Makes with their models. The platform sees every entry with its review; a carrier sees the reviewed ones."""
    platform = pr.portal == "PLATFORM"
    if platform:
        need(pr)
    where = "true" if platform else "{a}.status = 'ACTIVE'"
    makes = await conn.fetch(
        f"""SELECT k.*, ep.legal_name AS entered_name, vp.legal_name AS reviewed_name
              FROM ref.vehicle_make k LEFT JOIN iam.app_user eu ON eu.id = k.entered_by LEFT JOIN iam.party ep ON ep.id = eu.party_id
              LEFT JOIN iam.app_user vu ON vu.id = k.reviewed_by LEFT JOIN iam.party vp ON vp.id = vu.party_id
             WHERE {where.format(a='k')} ORDER BY k.name_en""")
    models = await conn.fetch(
        f"""SELECT m.*, k.uid AS make_uid, ep.legal_name AS entered_name, vp.legal_name AS reviewed_name
              FROM ref.vehicle_model m JOIN ref.vehicle_make k ON k.id = m.make_id
              LEFT JOIN iam.app_user eu ON eu.id = m.entered_by LEFT JOIN iam.party ep ON ep.id = eu.party_id
              LEFT JOIN iam.app_user vu ON vu.id = m.reviewed_by LEFT JOIN iam.party vp ON vp.id = vu.party_id
             WHERE {where.format(a='m')} {'' if platform else "AND k.status = 'ACTIVE'"} ORDER BY m.name""")
    drop = () if platform else ("entered_name", "reviewed_name", "source", "notes", "reviewed_at", "created_at", "updated_at")
    by_make: dict[str, list] = {}
    for m in models:
        by_make.setdefault(str(m["make_uid"]), []).append(_row(m, drop))
    out = []
    for k in makes:
        v = _row(k, drop)
        v["models"] = by_make.get(v["uid"], [])
        out.append(v)
    return {"makes": out}


# ------------------------------------------------------------------ entries
async def add_make(conn: asyncpg.Connection, pr: Principal, body: MakeIn, source: str = "MANUAL") -> dict:
    need(pr)
    try:
        uid = await conn.fetchval(
            """INSERT INTO ref.vehicle_make (code, name_en, name_ar, country_code, source, entered_by)
               VALUES ($1, $2, $3, $4, $5, $6) RETURNING uid""",
            body.code or make_code(body.name_en), body.name_en.strip(), body.name_ar.strip(), body.country_code, source, pr.user_id)
    except asyncpg.UniqueViolationError as e:
        raise ApiError(409, "CODE_TAKEN", "a make with this code already exists") from e
    return {"uid": str(uid), "status": "PENDING_REVIEW"}


async def _make(conn: asyncpg.Connection, uid: uuid.UUID) -> asyncpg.Record:
    r = await conn.fetchrow("SELECT * FROM ref.vehicle_make WHERE uid = $1", uid)
    if r is None:
        raise not_found("vehicle make")
    return r


async def add_model(conn: asyncpg.Connection, pr: Principal, body: ModelIn, source: str = "MANUAL") -> dict:
    need(pr)
    make = await _make(conn, body.make_uid)
    if make["status"] in ("REJECTED", "RETIRED"):
        raise ApiError(409, "ENTRY_NOT_ACTIVE", "models are added to a make in the list")
    if body.seats_from and body.seats_to and body.seats_to < body.seats_from:
        raise ApiError(422, "SEATS_RANGE", "the seats range ends before it starts")
    vehicle_type = "OTHER" if body.vehicle_class == "TRUCK" else body.vehicle_type
    try:
        uid = await conn.fetchval(
            """INSERT INTO ref.vehicle_model (make_id, name, vehicle_class, vehicle_type, seats_from, seats_to, weight_class,
                 production, confidence, notes, source, entered_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING uid""",
            make["id"], body.name.strip(), body.vehicle_class, vehicle_type, body.seats_from, body.seats_to,
            body.weight_class if body.vehicle_class == "TRUCK" else None, body.production, body.confidence, body.notes,
            source, pr.user_id)
    except asyncpg.UniqueViolationError as e:
        raise ApiError(409, "MODEL_EXISTS", "this make already has this model of this kind") from e
    return {"uid": str(uid), "status": "PENDING_REVIEW"}


TABLES = {"makes": "ref.vehicle_make", "models": "ref.vehicle_model"}


async def review(conn: asyncpg.Connection, pr: Principal, kind: Literal["makes", "models"], uid: uuid.UUID, body: ReviewIn) -> dict:
    """A second person accepts or rejects a make or model; a model is accepted only under an accepted make."""
    need(pr)
    table = TABLES[kind]
    r = await conn.fetchrow(f"SELECT * FROM {table} WHERE uid = $1 FOR UPDATE", uid)
    if r is None:
        raise not_found("vehicle " + kind[:-1])
    if r["status"] != "PENDING_REVIEW":
        raise ApiError(409, "NOTHING_TO_REVIEW", "this entry was already reviewed")
    if r["entered_by"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "another person reviews what you entered")
    if kind == "models" and body.decision == "ACCEPT":
        if await conn.fetchval("SELECT status FROM ref.vehicle_make WHERE id = $1", r["make_id"]) != "ACTIVE":
            raise ApiError(409, "MAKE_NOT_ACTIVE", "accept the make before its models")
    status = "ACTIVE" if body.decision == "ACCEPT" else "REJECTED"
    await conn.execute(f"UPDATE {table} SET status = $2, reviewed_by = $3, reviewed_at = now() WHERE id = $1", r["id"], status, pr.user_id)
    return {"uid": str(uid), "status": status}


async def retire(conn: asyncpg.Connection, pr: Principal, kind: Literal["makes", "models"], uid: uuid.UUID) -> dict:
    need(pr)
    table = TABLES[kind]
    r = await conn.fetchrow(f"SELECT id, status FROM {table} WHERE uid = $1 FOR UPDATE", uid)
    if r is None:
        raise not_found("vehicle " + kind[:-1])
    if r["status"] != "ACTIVE":
        raise ApiError(409, "ENTRY_NOT_ACTIVE", "only an active entry is retired")
    await conn.execute(f"UPDATE {table} SET status = 'RETIRED' WHERE id = $1", r["id"])
    return {"uid": str(uid), "status": "RETIRED"}


# ------------------------------------------------------------------ carriers' requests
def _carrier(pr: Principal) -> int:
    if pr.portal != "OPERATOR" or not pr.company_id:
        raise forbidden("carrier portal only")
    if "vehicle.manage" not in pr.permissions:
        raise forbidden("missing permission: vehicle.manage")
    return pr.company_id


async def submit_request(conn: asyncpg.Connection, pr: Principal, body: RequestIn) -> dict:
    company = _carrier(pr)
    make_id = None
    if body.make_uid is not None:
        make_id = await conn.fetchval("SELECT id FROM ref.vehicle_make WHERE uid = $1 AND status = 'ACTIVE'", body.make_uid)
        if make_id is None:
            raise ApiError(422, "MAKE_UNKNOWN", "choose a make from the list, or write its name")
    elif not body.make_name:
        raise ApiError(422, "MAKE_UNKNOWN", "choose a make from the list, or write its name")
    uid = await conn.fetchval(
        """INSERT INTO fleet.vehicle_model_request (company_id, requested_by, make_id, make_name, model_name, vehicle_type, seats, note)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING uid""",
        company, pr.user_id, make_id, None if make_id else body.make_name.strip(), body.model_name.strip(), body.vehicle_type,
        body.seats, body.note)
    return {"uid": str(uid), "status": "SUBMITTED"}


async def requests(conn: asyncpg.Connection, pr: Principal) -> list[dict]:
    company = None
    if pr.portal == "PLATFORM":
        need(pr)
    else:
        company = _carrier(pr)
    recs = await conn.fetch(
        """SELECT r.*, coalesce(k.name_en, r.make_name) AS make, cp.legal_name AS company_name, m.uid AS model_uid, m.name AS model
             FROM fleet.vehicle_model_request r JOIN iam.party cp ON cp.id = r.company_id
             LEFT JOIN ref.vehicle_make k ON k.id = r.make_id LEFT JOIN ref.vehicle_model m ON m.id = r.model_id
            WHERE ($1::bigint IS NULL OR r.company_id = $1)
            ORDER BY (r.status = 'SUBMITTED') DESC, r.created_at DESC LIMIT 300""", company)
    return [_row(r) | {"model_uid": str(r["model_uid"]) if r["model_uid"] else None} for r in recs]


async def decide(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, body: DecideIn) -> dict:
    """Approve (the model is added, still waiting for a second person's review), match to a model in the list, or reject."""
    need(pr)
    r = await conn.fetchrow("SELECT * FROM fleet.vehicle_model_request WHERE uid = $1 FOR UPDATE", uid)
    if r is None:
        raise not_found("model request")
    if r["status"] != "SUBMITTED":
        raise ApiError(409, "REQUEST_HANDLED", "this request was already handled")
    model_id = None
    if body.decision == "REJECT":
        if not body.note:
            raise ApiError(422, "REASON_REQUIRED", "say why the request is rejected")
        status = "REJECTED"
    elif body.decision == "MATCH":
        model_id = await conn.fetchval("SELECT id FROM ref.vehicle_model WHERE uid = $1 AND status IN ('ACTIVE', 'PENDING_REVIEW')",
                                       body.model_uid) if body.model_uid else None
        if model_id is None:
            raise ApiError(422, "MODEL_UNKNOWN", "choose the model already in the list")
        status = "MATCHED"
    else:
        make_id = r["make_id"]
        if make_id is None:
            if not body.make_name_ar:
                raise ApiError(422, "MAKE_NAME_AR", "give the new make's name in Arabic")
            made = await add_make(conn, pr, MakeIn(name_en=r["make_name"], name_ar=body.make_name_ar), source="REQUEST")
            make_id = await conn.fetchval("SELECT id FROM ref.vehicle_make WHERE uid = $1", uuid.UUID(made["uid"]))
        make_uid = await conn.fetchval("SELECT uid FROM ref.vehicle_make WHERE id = $1", make_id)
        made = await add_model(conn, pr, ModelIn(make_uid=make_uid, name=r["model_name"], vehicle_type=r["vehicle_type"],
                                                seats_from=r["seats"], seats_to=r["seats"], confidence="VERIFY"), source="REQUEST")
        model_id = await conn.fetchval("SELECT id FROM ref.vehicle_model WHERE uid = $1", uuid.UUID(made["uid"]))
        status = "APPROVED"
    await conn.execute("""UPDATE fleet.vehicle_model_request SET status = $2, model_id = $3, handled_by = $4, handled_at = now(),
                                 decision_note = $5 WHERE id = $1""", r["id"], status, model_id, pr.user_id, body.note)
    return {"uid": str(uid), "status": status}


async def withdraw(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID) -> dict:
    company = _carrier(pr)
    r = await conn.fetchrow("SELECT id, status FROM fleet.vehicle_model_request WHERE uid = $1 AND company_id = $2 FOR UPDATE", uid, company)
    if r is None:
        raise not_found("model request")
    if r["status"] != "SUBMITTED":
        raise ApiError(409, "REQUEST_HANDLED", "the platform already handled this request")
    await conn.execute("UPDATE fleet.vehicle_model_request SET status = 'WITHDRAWN' WHERE id = $1", r["id"])
    return {"uid": str(uid), "status": "WITHDRAWN"}


# ------------------------------------------------------------------ import of the owner's table
CLASSES = {"BUS", "TRUCK", "TRAIN", "CAR", "OTHER"}
TYPES = {"COACH", "MINIBUS", "CITY_BUS", "VAN", "TRAIN_SET", "OTHER"}
COUNTRIES = {"china": "CN", "germany": "DE", "japan": "JP", "korea": "KR", "south korea": "KR", "turkey": "TR", "france": "FR",
             "italy": "IT", "sweden": "SE", "netherlands": "NL", "spain": "ES", "belgium": "BE", "poland": "PL", "czech republic": "CZ",
             "czechia": "CZ", "united kingdom": "GB", "uk": "GB", "usa": "US", "united states": "US", "india": "IN", "iran": "IR",
             "russia": "RU", "belarus": "BY", "portugal": "PT", "austria": "AT", "hungary": "HU", "syria": "SY", "egypt": "EG"}


def _text(v: Any) -> str:
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def _int(v: Any) -> Optional[int]:
    t = _text(v)
    return int(float(t)) if re.fullmatch(r"\d+(\.0+)?", t) else None


def read(data: bytes) -> tuple[list[dict], list[str]]:
    """Rows of every sheet that has make_en, make_ar and model columns; rows the owner marked "remove" are left out.
    Returns the rows and the problems found (a file with any problem is refused)."""
    import openpyxl
    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    except Exception as e:                                        # not a workbook at all
        raise ApiError(422, "REGISTRY_FILE_FORMAT", "not an Excel workbook") from e
    rows: list[dict] = []
    problems: list[str] = []
    seen: set[tuple] = set()
    for sheet in wb.worksheets:
        it = sheet.iter_rows(values_only=True)
        head = [_text(h).lower() for h in next(it, ())]
        if not {"make_en", "make_ar", "model"} <= set(head):
            continue
        for i, raw in enumerate(it, start=2):
            r = {h: v for h, v in zip(head, raw) if h}
            if not _text(r.get("make_en")) and not _text(r.get("model")):
                continue
            if _text(r.get("owner_decision (keep/remove/edit)")).lower().startswith("remove"):
                continue
            klass = _text(r.get("vehicle_class")).upper() or "BUS"
            vtype = _text(r.get("vehicle_type")).upper() or ("OTHER" if klass == "TRUCK" else "COACH")
            weight = (_text(r.get("weight_class")) or _text(r.get("truck_weight_class"))).upper() or None
            key = (_text(r.get("make_en")).lower(), _text(r.get("model")).lower(), vtype)
            if key in seen:
                continue
            seen.add(key)
            where = f"{sheet.title} row {i}"
            if klass not in CLASSES or vtype not in TYPES or (weight and weight not in ("LIGHT", "MEDIUM", "HEAVY")):
                problems.append(f"{where}: class {klass}, type {vtype} or weight {weight} not known")
                continue
            try:
                model = ModelIn(make_uid=uuid.uuid4(), name=_text(r.get("model")), vehicle_class=klass, vehicle_type=vtype,
                                seats_from=_int(r.get("seats_from (approx.)") or r.get("seats_from")),
                                seats_to=_int(r.get("seats_to (approx.)") or r.get("seats_to")),
                                weight_class=weight if klass == "TRUCK" else None,
                                production="OLDER" if _text(r.get("status")).lower() == "older" else "CURRENT",
                                confidence={"high": "HIGH", "medium": "MEDIUM"}.get(_text(r.get("confidence")).lower(), "VERIFY"),
                                notes=_text(r.get("notes"))[:500] or None)
                make = MakeIn(name_en=_text(r.get("make_en")), name_ar=_text(r.get("make_ar")),
                              country_code=COUNTRIES.get(_text(r.get("country")).lower()))
            except ValidationError as e:
                problems.append(f"{where}: " + "; ".join(f"{'.'.join(map(str, x['loc']))} {x['msg']}" for x in e.errors()))
                continue
            rows.append({"make": make, "model": model})
            if len(rows) > MAX_ROWS:
                raise ApiError(422, "REGISTRY_FILE_ROWS", f"more than {MAX_ROWS} rows")
    if not rows and not problems:
        raise ApiError(422, "REGISTRY_FILE_COLUMNS", "no sheet has the make_en, make_ar and model columns")
    return rows, problems


async def load(conn: asyncpg.Connection, pr: Principal, data: bytes) -> dict:
    """Every make and model comes in as PENDING_REVIEW with the source IMPORT; entries already in the list are skipped."""
    need(pr)
    rows, problems = read(data)
    if problems:
        raise ApiError(422, "REGISTRY_FILE_ROWS", "; ".join(problems[:30]))
    makes = models = skipped = 0
    for item in rows:
        mk: MakeIn = item["make"]
        code = make_code(mk.name_en)
        make_uid = await conn.fetchval("SELECT uid FROM ref.vehicle_make WHERE code = $1", code)
        if make_uid is None:
            make_uid = uuid.UUID((await add_make(conn, pr, mk, source="IMPORT"))["uid"])
            makes += 1
        md: ModelIn = item["model"]
        md.make_uid = make_uid
        exists = await conn.fetchval(
            """SELECT 1 FROM ref.vehicle_model m JOIN ref.vehicle_make k ON k.id = m.make_id
                WHERE k.uid = $1 AND lower(m.name) = lower($2) AND m.vehicle_type = $3 AND m.status <> 'REJECTED'""",
            make_uid, md.name, "OTHER" if md.vehicle_class == "TRUCK" else md.vehicle_type)
        if exists:
            skipped += 1
            continue
        await add_model(conn, pr, md, source="IMPORT")
        models += 1
    return {"makes": makes, "models": models, "skipped": skipped}
