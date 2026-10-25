"""Bank and insurer registries (N6, N9, migration 1156).

Platform staff holding reference.manage enter or import an entry; it waits as PENDING_REVIEW until another person reviews
it. A change to a reviewed entry is kept as a proposal (pending_changes) and applied only when a second person accepts it,
so no single person can quietly change the bank a company's money goes to. Companies see only reviewed entries that are
not hidden from them (the central bank, reinsurers)."""
import json
import uuid
from typing import Any, Literal, Optional

import asyncpg
from pydantic import BaseModel, Field

from ...deps import Principal
from ...errors import ApiError, forbidden, not_found

SWIFT = r"^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$"
CODE = r"^[A-Z0-9]{2,12}$"
EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"
URL = r"^https?://\S+$"
Kind = Literal["banks", "insurers"]
TABLE = {"banks": "ref.bank", "insurers": "ref.insurer"}


class _Common(BaseModel):
    name_ar: str = Field(min_length=2, max_length=160)
    name_en: str = Field(min_length=2, max_length=160)
    address: dict[str, Any] = Field(default_factory=dict)
    phone: Optional[str] = Field(default=None, min_length=5, max_length=40)
    fax: Optional[str] = Field(default=None, min_length=5, max_length=40)
    email: Optional[str] = Field(default=None, pattern=EMAIL, max_length=200)
    website: Optional[str] = Field(default=None, pattern=URL, max_length=300)
    notes: Optional[str] = Field(default=None, max_length=1000)


class BankIn(_Common):
    code: str = Field(pattern=CODE)
    short_name: Optional[str] = Field(default=None, min_length=2, max_length=40)
    bank_type: Literal["CENTRAL", "PUBLIC", "PRIVATE", "ISLAMIC"] = "PRIVATE"
    swift_bic: Optional[str] = Field(default=None, pattern=SWIFT)
    swift_status: Literal["TO_VERIFY", "VERIFIED", "INVALID"] = "TO_VERIFY"
    iban_bank_code: Optional[str] = Field(default=None, pattern=r"^[0-9A-Z]{2,10}$")


class InsurerIn(_Common):
    code: str = Field(pattern=CODE)
    ownership: Literal["PUBLIC", "PRIVATE"] = "PRIVATE"
    insurance_kind: Literal["CONVENTIONAL", "TAKAFUL", "REINSURANCE"] = "CONVENTIONAL"
    licence_no: Optional[str] = Field(default=None, min_length=2, max_length=40)
    lat: Optional[float] = Field(default=None, ge=-90, le=90)
    lng: Optional[float] = Field(default=None, ge=-180, le=180)


class BranchIn(BaseModel):
    name_ar: str = Field(min_length=2, max_length=160)
    name_en: str = Field(min_length=2, max_length=160)
    branch_code: Optional[str] = Field(default=None, pattern=r"^[0-9A-Z]{1,12}$")
    swift_bic: Optional[str] = Field(default=None, pattern=SWIFT)
    is_head_office: bool = False
    address: dict[str, Any] = Field(default_factory=dict)
    phone: Optional[str] = Field(default=None, min_length=5, max_length=40)
    email: Optional[str] = Field(default=None, pattern=EMAIL, max_length=200)


class ReviewIn(BaseModel):
    decision: Literal["ACCEPT", "REJECT"]
    note: Optional[str] = Field(default=None, min_length=3, max_length=300)


MODEL = {"banks": BankIn, "insurers": InsurerIn}
# what a proposal may change (never the status, the review or who entered it)
FIELDS = {"banks": set(BankIn.model_fields), "insurers": set(InsurerIn.model_fields)}
HIDDEN = {"banks": ("bank_type", "CENTRAL"), "insurers": ("insurance_kind", "REINSURANCE")}


def need(pr: Principal) -> None:
    if pr.portal != "PLATFORM" or "reference.manage" not in pr.permissions:
        raise forbidden("missing permission: reference.manage")


def _view(r: asyncpg.Record, platform: bool) -> dict:
    out = {k: (str(v) if isinstance(v, uuid.UUID) else v) for k, v in dict(r).items()
           if k not in ("id", "entered_by", "reviewed_by", "pending_by", "bank_id")}
    for k in ("address", "pending_changes"):
        if isinstance(out.get(k), str):
            out[k] = json.loads(out[k])
    for k in ("lat", "lng"):
        if out.get(k) is not None:
            out[k] = float(out[k])
    for k in ("created_at", "updated_at", "reviewed_at", "pending_at"):
        if out.get(k) is not None:
            out[k] = out[k].isoformat()
    if not platform:
        for k in ("notes", "pending_changes", "pending_at", "entered_by_name", "reviewed_by_name", "pending_by_name", "source",
                  "status", "reviewed_at", "hidden_from_companies", "created_at", "updated_at", "swift_reported"):
            out.pop(k, None)
    return out


def _select(kind: Kind) -> str:
    return f"""SELECT x.*, ep.legal_name AS entered_by_name, vp.legal_name AS reviewed_by_name, pp.legal_name AS pending_by_name
                 FROM {TABLE[kind]} x LEFT JOIN iam.app_user eu ON eu.id = x.entered_by LEFT JOIN iam.party ep ON ep.id = eu.party_id
                 LEFT JOIN iam.app_user vu ON vu.id = x.reviewed_by LEFT JOIN iam.party vp ON vp.id = vu.party_id
                 LEFT JOIN iam.app_user pu ON pu.id = x.pending_by LEFT JOIN iam.party pp ON pp.id = pu.party_id"""


async def listing(conn: asyncpg.Connection, pr: Principal, kind: Kind) -> list[dict]:
    """The platform sees every entry with its review; a company sees the reviewed, visible ones (banks with branches)."""
    platform = pr.portal == "PLATFORM"
    if platform:
        need(pr)
        recs = await conn.fetch(_select(kind) + " ORDER BY (x.status = 'PENDING_REVIEW' OR x.pending_changes IS NOT NULL) DESC, x.code")
    else:
        recs = await conn.fetch(_select(kind) + " WHERE x.status = 'ACTIVE' AND NOT x.hidden_from_companies ORDER BY x.name_en")
    out = [_view(r, platform) for r in recs]
    if kind == "banks":
        branches = await conn.fetch(
            f"""SELECT b.*, x.uid AS bank_uid, ep.legal_name AS entered_by_name, vp.legal_name AS reviewed_by_name
                  FROM ref.bank_branch b JOIN ref.bank x ON x.id = b.bank_id
                  LEFT JOIN iam.app_user eu ON eu.id = b.entered_by LEFT JOIN iam.party ep ON ep.id = eu.party_id
                  LEFT JOIN iam.app_user vu ON vu.id = b.reviewed_by LEFT JOIN iam.party vp ON vp.id = vu.party_id
                 WHERE {'true' if platform else "b.status = 'ACTIVE'"} ORDER BY b.is_head_office DESC, b.name_en""")
        by_bank: dict[str, list[dict]] = {}
        for b in branches:
            v = _view(b, platform)
            v.pop("area_id", None)
            by_bank.setdefault(str(b["bank_uid"]), []).append(v)
        for o in out:
            o["branches"] = by_bank.get(o["uid"], [])
    return out


def _values(kind: Kind, body: BaseModel) -> dict:
    data = body.model_dump()
    field, value = HIDDEN[kind]
    data["hidden_from_companies"] = data.get(field) == value
    data["address"] = json.dumps(data["address"])
    return data


async def create(conn: asyncpg.Connection, pr: Principal, kind: Kind, body: BaseModel, source: str = "MANUAL",
                 swift_reported: Optional[str] = None) -> dict:
    need(pr)
    data = _values(kind, body)
    if kind == "banks" and swift_reported:
        data["swift_reported"] = swift_reported
    cols = list(data) + ["entered_by", "source"]
    vals = list(data.values()) + [pr.user_id, source]
    try:
        uid = await conn.fetchval(
            f"INSERT INTO {TABLE[kind]} ({', '.join(cols)}) VALUES ({', '.join(f'${i + 1}' for i in range(len(cols)))}) RETURNING uid",
            *vals)
    except asyncpg.UniqueViolationError as e:
        raise ApiError(409, "CODE_TAKEN", "an entry with this code or SWIFT code already exists") from e
    return {"uid": str(uid), "status": "PENDING_REVIEW"}


async def _entry(conn: asyncpg.Connection, kind: Kind, uid: uuid.UUID) -> asyncpg.Record:
    r = await conn.fetchrow(f"SELECT * FROM {TABLE[kind]} WHERE uid = $1 FOR UPDATE", uid)
    if r is None:
        raise not_found("registry entry")
    return r


async def _apply(conn: asyncpg.Connection, kind: Kind, entry_id: int, data: dict) -> None:
    cols = [k for k in data if k in FIELDS[kind] or k == "hidden_from_companies"]
    sets = ", ".join(f"{c} = ${i + 2}" for i, c in enumerate(cols))
    try:
        await conn.execute(f"UPDATE {TABLE[kind]} SET {sets} WHERE id = $1", entry_id, *[data[c] for c in cols])
    except asyncpg.UniqueViolationError as e:
        raise ApiError(409, "CODE_TAKEN", "an entry with this code or SWIFT code already exists") from e


async def change(conn: asyncpg.Connection, pr: Principal, kind: Kind, uid: uuid.UUID, body: BaseModel) -> dict:
    """An entry not yet reviewed is corrected by the person who entered it; a reviewed one gets a proposal for review."""
    need(pr)
    r = await _entry(conn, kind, uid)
    data = _values(kind, body)
    if r["status"] == "PENDING_REVIEW":
        if r["entered_by"] != pr.user_id:
            raise ApiError(409, "NOT_YOURS", "only the person who entered it corrects an entry before its review")
        await _apply(conn, kind, r["id"], data)
        return {"uid": str(uid), "status": "PENDING_REVIEW"}
    if r["status"] != "ACTIVE":
        raise ApiError(409, "ENTRY_NOT_ACTIVE", "a rejected or retired entry is not changed")
    if r["pending_changes"] is not None:
        raise ApiError(409, "CHANGE_PENDING", "a change to this entry is already waiting for review")
    def same(k: str, v: Any) -> bool:
        old = r[k] if k in r.keys() else None
        if k == "address":
            return (json.loads(old) if isinstance(old, str) else old or {}) == json.loads(v)
        if k in ("lat", "lng"):                     # numeric(9,6) against the float sent
            return (old is None and v is None) or (old is not None and v is not None and abs(float(old) - float(v)) < 1e-6)
        return old == v
    proposal = {k: v for k, v in data.items() if not same(k, v)}
    if not proposal:
        raise ApiError(409, "NO_CHANGE", "nothing differs from the reviewed entry")
    if "address" in proposal:
        proposal["address"] = json.loads(proposal["address"])
    await conn.execute(f"UPDATE {TABLE[kind]} SET pending_changes = $2::jsonb, pending_by = $3, pending_at = now() WHERE id = $1",
                       r["id"], json.dumps(proposal), pr.user_id)
    return {"uid": str(uid), "status": "ACTIVE", "pending_changes": proposal}


async def review(conn: asyncpg.Connection, pr: Principal, kind: Kind, uid: uuid.UUID, body: ReviewIn) -> dict:
    """A second person decides a new entry or a proposed change; the person who made it never reviews it."""
    need(pr)
    r = await _entry(conn, kind, uid)
    if r["status"] == "PENDING_REVIEW":
        if r["entered_by"] == pr.user_id:
            raise ApiError(409, "FOUR_EYES", "another person reviews what you entered")
        status = "ACTIVE" if body.decision == "ACCEPT" else "REJECTED"
        await conn.execute(f"UPDATE {TABLE[kind]} SET status = $2, reviewed_by = $3, reviewed_at = now(), notes = coalesce($4, notes) WHERE id = $1",
                           r["id"], status, pr.user_id, body.note)
        return {"uid": str(uid), "status": status}
    if r["pending_changes"] is None:
        raise ApiError(409, "NOTHING_TO_REVIEW", "this entry has nothing waiting for review")
    if r["pending_by"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "another person reviews the change you proposed")
    if body.decision == "ACCEPT":
        data = json.loads(r["pending_changes"]) if isinstance(r["pending_changes"], str) else dict(r["pending_changes"])
        if "address" in data:
            data["address"] = json.dumps(data["address"])
        await _apply(conn, kind, r["id"], data)
    await conn.execute(f"UPDATE {TABLE[kind]} SET pending_changes = NULL, pending_by = NULL, pending_at = NULL WHERE id = $1", r["id"])
    return {"uid": str(uid), "status": "ACTIVE", "change": "APPLIED" if body.decision == "ACCEPT" else "REJECTED"}


async def retire(conn: asyncpg.Connection, pr: Principal, kind: Kind, uid: uuid.UUID) -> dict:
    """A reviewed entry leaves the pickers; rows that already point to it keep it."""
    need(pr)
    r = await _entry(conn, kind, uid)
    if r["status"] != "ACTIVE":
        raise ApiError(409, "ENTRY_NOT_ACTIVE", "only an active entry is retired")
    await conn.execute(f"UPDATE {TABLE[kind]} SET status = 'RETIRED', pending_changes = NULL, pending_by = NULL, pending_at = NULL WHERE id = $1",
                       r["id"])
    return {"uid": str(uid), "status": "RETIRED"}


# ------------------------------------------------------------------ branches
async def add_branch(conn: asyncpg.Connection, pr: Principal, bank_uid: uuid.UUID, body: BranchIn) -> dict:
    need(pr)
    bank = await _entry(conn, "banks", bank_uid)
    if bank["status"] in ("REJECTED", "RETIRED"):
        raise ApiError(409, "ENTRY_NOT_ACTIVE", "branches are added to a bank in the registry")
    data = body.model_dump()
    data["address"] = json.dumps(data["address"])
    cols = list(data) + ["bank_id", "entered_by"]
    try:
        uid = await conn.fetchval(
            f"INSERT INTO ref.bank_branch ({', '.join(cols)}) VALUES ({', '.join(f'${i + 1}' for i in range(len(cols)))}) RETURNING uid",
            *data.values(), bank["id"], pr.user_id)
    except asyncpg.UniqueViolationError as e:
        raise ApiError(409, "CODE_TAKEN", "this bank already has a branch with this code, or a head office") from e
    return {"uid": str(uid), "status": "PENDING_REVIEW"}


async def review_branch(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, body: ReviewIn) -> dict:
    need(pr)
    r = await conn.fetchrow("SELECT * FROM ref.bank_branch WHERE uid = $1 FOR UPDATE", uid)
    if r is None:
        raise not_found("bank branch")
    if r["status"] != "PENDING_REVIEW":
        raise ApiError(409, "NOTHING_TO_REVIEW", "this branch was already reviewed")
    if r["entered_by"] == pr.user_id:
        raise ApiError(409, "FOUR_EYES", "another person reviews what you entered")
    status = "ACTIVE" if body.decision == "ACCEPT" else "REJECTED"
    await conn.execute("UPDATE ref.bank_branch SET status = $2, reviewed_by = $3, reviewed_at = now() WHERE id = $1", r["id"], status, pr.user_id)
    return {"uid": str(uid), "status": status}


async def picked_bank(conn: asyncpg.Connection, bank_uid: uuid.UUID, branch_uid: Optional[uuid.UUID]) -> tuple[asyncpg.Record, Optional[asyncpg.Record]]:
    """A bank (and branch) a company may pick: reviewed, active and shown to companies."""
    bank = await conn.fetchrow("SELECT * FROM ref.bank WHERE uid = $1 AND status = 'ACTIVE' AND NOT hidden_from_companies", bank_uid)
    if bank is None:
        raise ApiError(422, "BANK_UNKNOWN", "choose a bank from the list")
    branch = None
    if branch_uid is not None:
        branch = await conn.fetchrow("SELECT * FROM ref.bank_branch WHERE uid = $1 AND bank_id = $2 AND status = 'ACTIVE'", branch_uid, bank["id"])
        if branch is None:
            raise ApiError(422, "BRANCH_UNKNOWN", "choose a branch of this bank from the list")
    return bank, branch


async def picked_insurer(conn: asyncpg.Connection, insurer_uid: uuid.UUID) -> asyncpg.Record:
    r = await conn.fetchrow("SELECT * FROM ref.insurer WHERE uid = $1 AND status = 'ACTIVE' AND NOT hidden_from_companies", insurer_uid)
    if r is None:
        raise ApiError(422, "INSURER_UNKNOWN", "choose an insurance company from the list")
    return r
