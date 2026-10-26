"""The traveller "Me" and saved travellers (owner's request N18, migration 1153).

A registered passenger is not asked again for what the account holds: the first traveller can be "Me", filled from the
person's name parts (1149), date of birth, gender and identity document. Companions booked again are kept, with the
passenger's consent, as saved travellers. Document numbers are stored only encrypted, with a blind index and the last
four shown.
"""
import uuid
from datetime import date
from typing import Literal, Optional

import asyncpg
from pydantic import BaseModel, Field, field_validator

from ... import crypto
from ...errors import ApiError, not_found
from ..sales.models import LATIN_PART, NAME_PART

PARTY_DOC = "iam.party.id_no"
SAVED_DOC = "iam.saved_traveller.id_no"
DocType = Literal["NATIONAL_ID", "PASSPORT", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER"]
# the person's document types (020) as the booking's types
PARTY_TO_BOOKING = {"NATIONAL_ID": "NATIONAL_ID", "PASSPORT": "PASSPORT", "RESIDENCE": "RESIDENCE", "FOREIGN_ID": "OTHER",
                    "OTHER": "OTHER"}
MAX_SAVED = 20


class DocumentIn(BaseModel):
    """The account holder's own identity details used for the traveller "Me"."""
    birth_date: date
    gender: Literal["M", "F"]
    id_type: Literal["NATIONAL_ID", "PASSPORT", "RESIDENCE", "OTHER"]
    id_no: str = Field(min_length=4, max_length=24, pattern=r"^[0-9A-Za-z \-/]+$")
    id_expiry: Optional[date] = None


class SavedTravellerIn(BaseModel):
    label: Optional[str] = Field(default=None, min_length=1, max_length=40)
    nationality: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    first_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    father_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    grandfather_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    last_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    first_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)
    father_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)
    grandfather_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)
    last_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)
    birth_date: Optional[date] = None
    gender: Optional[Literal["M", "F"]] = None
    id_type: Optional[DocType] = None
    id_no: Optional[str] = Field(default=None, min_length=4, max_length=24, pattern=r"^[0-9A-Za-z \-/]+$")
    id_expiry: Optional[date] = None
    consent: bool = Field(description="the passenger agrees to keep this person's details to book for them again")

    @field_validator("first_name", "father_name", "grandfather_name", "last_name", "first_name_latin", "father_name_latin",
                     "grandfather_name_latin", "last_name_latin", mode="before")
    @classmethod
    def _tidy(cls, v):
        return " ".join(v.split()) or None if isinstance(v, str) else v


# ------------------------------------------------------------------ "Me"
async def set_document(conn: asyncpg.Connection, party_id: int, body: DocumentIn) -> None:
    status = await conn.fetchval("SELECT verification_status FROM iam.party WHERE id = $1", party_id)
    if status == "VERIFIED":
        raise ApiError(409, "IDENTITY_LOCKED", "the account is verified: identity details change through a new review")
    nationality = await conn.fetchval("SELECT coalesce(nationality, 'SY') FROM iam.party WHERE id = $1", party_id)
    fc = await crypto.cipher(conn)
    sealed = fc.encrypt(body.id_no, PARTY_DOC)
    try:
        await conn.execute(
            """UPDATE iam.party SET birth_date = $2, gender = $3, id_type = $4, id_no_enc = $5, id_no_bidx = $6,
                      id_no_last4 = $7, enc_key_id = $8, id_expiry = $9 WHERE id = $1""",
            party_id, body.birth_date, body.gender, body.id_type, sealed.ciphertext,
            fc.blind_index(body.id_no, f"{body.id_type}:{nationality}"), crypto.last4(body.id_no), sealed.key_id, body.id_expiry)
    except asyncpg.UniqueViolationError as exc:
        raise ApiError(409, "DOCUMENT_IN_USE", "this document is registered to another account; contact support") from exc


async def me(conn: asyncpg.Connection, party_id: int) -> dict:
    """The traveller "Me" as the booking form shows it: the document's last four only, never the number."""
    p = await conn.fetchrow(
        """SELECT nationality, first_name, father_name, grandfather_name, last_name, first_name_latin, father_name_latin,
                  grandfather_name_latin, last_name_latin, birth_date, gender, id_type, id_no_last4, id_expiry,
                  id_no_enc IS NOT NULL AS has_document, names_complete
             FROM iam.party WHERE id = $1""", party_id)
    if p is None:
        raise not_found("person")
    out = dict(p)
    out["nationality"] = out["nationality"] or "SY"
    out["id_type"] = PARTY_TO_BOOKING.get(out["id_type"]) if out["id_type"] else None
    out["ready"] = bool(p["names_complete"] and p["birth_date"] and p["has_document"])
    for k in ("birth_date", "id_expiry"):
        out[k] = out[k].isoformat() if out[k] else None
    return out


async def me_for_booking(conn: asyncpg.Connection, party_id: int) -> dict:
    """The account holder's details with the document number in clear, to copy onto a booking."""
    p = await conn.fetchrow("SELECT * FROM iam.party WHERE id = $1", party_id)
    if p is None or not p["first_name"] or not p["last_name"]:
        raise ApiError(422, "PROFILE_INCOMPLETE", "complete your name in your account before booking as yourself")
    doc = None
    if p["id_no_enc"]:
        doc = (await crypto.cipher(conn)).decrypt(bytes(p["id_no_enc"]), p["enc_key_id"], PARTY_DOC)
    return {"nationality": p["nationality"] or "SY", "first_name": p["first_name"], "father_name": p["father_name"],
            "grandfather_name": p["grandfather_name"], "last_name": p["last_name"],
            "latin": (p["first_name_latin"], p["father_name_latin"], p["grandfather_name_latin"], p["last_name_latin"]),
            "birth_date": p["birth_date"], "gender": p["gender"],
            "id_type": PARTY_TO_BOOKING.get(p["id_type"]) if p["id_type"] else None, "id_no": doc,
            "id_expiry": p["id_expiry"]}


# ------------------------------------------------------------------ saved travellers
def _view(r: asyncpg.Record) -> dict:
    keys = ("label", "nationality", "first_name", "father_name", "grandfather_name", "last_name", "first_name_latin",
            "father_name_latin", "grandfather_name_latin", "last_name_latin", "gender", "id_type")
    out = {k: r[k] for k in keys}
    out.update(uid=str(r["uid"]), id_last4=r["id_no_last4"],
               birth_date=r["birth_date"].isoformat() if r["birth_date"] else None,
               id_expiry=r["id_expiry"].isoformat() if r["id_expiry"] else None)
    return out


async def saved(conn: asyncpg.Connection, user_id: int) -> list[dict]:
    recs = await conn.fetch("""SELECT * FROM iam.saved_traveller WHERE owner_user_id = $1 AND status = 'ACTIVE'
                                ORDER BY first_name, last_name""", user_id)
    return [_view(r) for r in recs]


async def _sealed(conn: asyncpg.Connection, body: SavedTravellerIn):
    if not body.id_no:
        return None, None, None, None
    if not body.id_type:
        raise ApiError(422, "DOCUMENT_TYPE_REQUIRED", "say which document the number belongs to")
    fc = await crypto.cipher(conn)
    sealed = fc.encrypt(body.id_no, SAVED_DOC)
    return sealed.ciphertext, fc.blind_index(body.id_no, f"{body.id_type}:{body.nationality}"), crypto.last4(body.id_no), sealed.key_id


async def save(conn: asyncpg.Connection, user_id: int, body: SavedTravellerIn, uid: Optional[uuid.UUID] = None) -> dict:
    if not body.consent:
        raise ApiError(422, "CONSENT_REQUIRED", "confirm that this person agrees to their details being kept")
    enc, bidx, last4, key = await _sealed(conn, body)
    cols = (body.label, body.nationality, body.first_name, body.father_name, body.grandfather_name, body.last_name,
            body.first_name_latin, body.father_name_latin, body.grandfather_name_latin, body.last_name_latin,
            body.birth_date, body.gender, body.id_type, body.id_expiry)
    if uid is None:
        if await conn.fetchval("SELECT count(*) FROM iam.saved_traveller WHERE owner_user_id = $1 AND status = 'ACTIVE'",
                               user_id) >= MAX_SAVED:
            raise ApiError(409, "TOO_MANY_SAVED", f"keep at most {MAX_SAVED} saved travellers; remove one first")
        r = await conn.fetchrow(
            """INSERT INTO iam.saved_traveller (owner_user_id, label, nationality, first_name, father_name, grandfather_name,
                 last_name, first_name_latin, father_name_latin, grandfather_name_latin, last_name_latin, birth_date, gender,
                 id_type, id_expiry, id_no_enc, id_no_bidx, id_no_last4, enc_key_id)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19) RETURNING *""",
            user_id, *cols, enc, bidx, last4, key)
    else:
        r = await conn.fetchrow(
            """UPDATE iam.saved_traveller SET label = $3, nationality = $4, first_name = $5, father_name = $6,
                 grandfather_name = $7, last_name = $8, first_name_latin = $9, father_name_latin = $10,
                 grandfather_name_latin = $11, last_name_latin = $12, birth_date = $13, gender = $14, id_type = $15,
                 id_expiry = $16, consent_at = now(),
                 id_no_enc = coalesce($17, id_no_enc), id_no_bidx = coalesce($18, id_no_bidx),
                 id_no_last4 = coalesce($19, id_no_last4), enc_key_id = coalesce($20, enc_key_id)
               WHERE uid = $2 AND owner_user_id = $1 AND status = 'ACTIVE' RETURNING *""",
            user_id, uid, *cols, enc, bidx, last4, key)
        if r is None:
            raise not_found("saved traveller")
    return _view(r)


async def remove(conn: asyncpg.Connection, user_id: int, uid: uuid.UUID) -> None:
    """Removing a saved traveller also clears the document: nothing of it is kept to book with."""
    n = await conn.execute(
        """UPDATE iam.saved_traveller SET status = 'REMOVED', id_no_enc = NULL, id_no_bidx = NULL, id_no_last4 = NULL,
                  enc_key_id = NULL WHERE uid = $2 AND owner_user_id = $1 AND status = 'ACTIVE'""", user_id, uid)
    if n.endswith(" 0"):
        raise not_found("saved traveller")


async def saved_for_booking(conn: asyncpg.Connection, user_id: int, uid: uuid.UUID) -> dict:
    r = await conn.fetchrow("SELECT * FROM iam.saved_traveller WHERE uid = $2 AND owner_user_id = $1 AND status = 'ACTIVE'",
                            user_id, uid)
    if r is None:
        raise ApiError(404, "NOT_SAVED", "this traveller is not among your saved travellers")
    doc = None
    if r["id_no_enc"]:
        doc = (await crypto.cipher(conn)).decrypt(bytes(r["id_no_enc"]), r["enc_key_id"], SAVED_DOC)
    return {"nationality": r["nationality"], "first_name": r["first_name"], "father_name": r["father_name"],
            "grandfather_name": r["grandfather_name"], "last_name": r["last_name"],
            "latin": (r["first_name_latin"], r["father_name_latin"], r["grandfather_name_latin"], r["last_name_latin"]),
            "birth_date": r["birth_date"], "gender": r["gender"], "id_type": r["id_type"], "id_no": doc,
            "id_expiry": r["id_expiry"]}
