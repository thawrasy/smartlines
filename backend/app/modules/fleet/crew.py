"""Driver and crew details (owner's request N3, migration 1158).

A carrier enters a driver, host or assistant with their name in parts and a national number, which is encrypted on the
person. Each crew member carries licences: driving with its class, the transport authority's licence and the traffic
department's permit. Each licence has its dates and pictures of its two faces. The platform setting crew.licences says
which licences each kind must hold, and whether a crew member is refused on a trip without them. The screens list
what is missing or has run out either way."""
import uuid
from datetime import date
from typing import Literal, Optional

import asyncpg
from pydantic import BaseModel, EmailStr, Field, field_validator, model_validator

from ... import crypto, db
from ...deps import Principal
from ...errors import ApiError, forbidden, not_found
from ..documents import service as documents

PARTY_DOC = "iam.party.id_no"
CrewType = Literal["DRIVER", "HOST", "ASSISTANT"]
LicenceType = Literal["DRIVING", "HEAVY_DRIVING", "TRANSPORT", "TRAFFIC", "CROSS_BORDER", "MEDICAL", "FIRST_AID", "CRIMINAL_RECORD", "OTHER"]
MAX_IMAGE = 8 * 1024 * 1024


def _tidy(v):
    return (" ".join(v.split()) or None) if isinstance(v, str) else v


class CrewIn(BaseModel):
    crew_type: CrewType = "DRIVER"
    first_name: Optional[str] = Field(default=None, min_length=2, max_length=60)
    father_name: Optional[str] = Field(default=None, min_length=2, max_length=60)
    grandfather_name: Optional[str] = Field(default=None, min_length=2, max_length=60)
    last_name: Optional[str] = Field(default=None, min_length=2, max_length=60)
    mother_name: Optional[str] = Field(default=None, min_length=2, max_length=60)
    full_name: Optional[str] = Field(default=None, min_length=3, max_length=120)      # older clients
    national_id: Optional[str] = Field(default=None, pattern=r"^[0-9A-Za-z-]{5,20}$")
    birth_date: Optional[date] = None
    email: Optional[EmailStr] = None
    mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")
    password: Optional[str] = None
    license_class: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9][A-Za-z0-9 +-]{0,15}$")

    _names = field_validator("first_name", "father_name", "grandfather_name", "last_name", "mother_name", "full_name",
                             mode="before")(lambda cls, v: _tidy(v))

    @model_validator(mode="after")
    def _shape(self):
        if not self.full_name and not (self.first_name and self.last_name):
            raise ValueError("give the first and family names")
        if self.crew_type == "DRIVER" and not (self.email and self.password):
            raise ValueError("a driver signs in to the driver app: give an e-mail and a password")
        if self.email and not self.password:
            raise ValueError("an account needs a password")
        return self

    @property
    def display_name(self) -> str:
        if self.first_name and self.last_name:
            return " ".join(p for p in (self.first_name, self.father_name, self.last_name) if p)
        return self.full_name or ""


class LicenceIn(BaseModel):
    license_type: LicenceType
    license_no: str = Field(min_length=3, max_length=40)
    issuer: str = Field(min_length=2, max_length=120)
    license_class: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9][A-Za-z0-9 +-]{0,15}$")
    issue_date: date
    expiry_date: date

    @model_validator(mode="after")
    def _dates(self):
        if self.expiry_date <= self.issue_date:
            raise ValueError("the licence ends after it was issued")
        return self


def carrier_of(pr: Principal) -> int:
    if pr.portal != "OPERATOR" or not pr.company_id:
        raise forbidden("carrier portal only")
    if not pr.permissions.intersection({"company.staff", "trip.assign_crew"}):
        raise forbidden("missing permission: company.staff | trip.assign_crew")
    return pr.company_id


async def add_identity(conn: asyncpg.Connection, party_id: int, body: CrewIn) -> None:
    """The name in parts and the national number, encrypted with its blind index and last four characters."""
    if body.first_name and body.last_name:              # older clients send one full name: the parts are left as they are
        await conn.execute(
            """UPDATE iam.party SET first_name = $2, father_name = $3::text, grandfather_name = $4::text, last_name = $5,
                      mother_name = $6::text, names_complete = true WHERE id = $1""",
            party_id, body.first_name, body.father_name, body.grandfather_name, body.last_name, body.mother_name)
    if body.birth_date:
        await conn.execute("UPDATE iam.party SET birth_date = $2 WHERE id = $1", party_id, body.birth_date)
    if body.national_id:
        nationality = await conn.fetchval("SELECT coalesce(nationality, 'SY') FROM iam.party WHERE id = $1", party_id)
        fc = await crypto.cipher(conn)
        value = body.national_id.upper().replace("-", "")
        sealed = fc.encrypt(value, PARTY_DOC)
        try:
            await conn.execute(
                """UPDATE iam.party SET id_type = 'NATIONAL_ID', id_no_enc = $2, id_no_bidx = $3, id_no_last4 = $4, enc_key_id = $5
                    WHERE id = $1""",
                party_id, sealed.ciphertext, fc.blind_index(value, f"NATIONAL_ID:{nationality}"), crypto.last4(value), sealed.key_id)
        except asyncpg.UniqueViolationError as exc:
            raise ApiError(409, "DOCUMENT_IN_USE", "this national number is registered to another person; contact support") from exc


async def _member(conn: asyncpg.Connection, company: int, uid: uuid.UUID) -> asyncpg.Record:
    r = await conn.fetchrow(
        """SELECT p.id, p.uid, cp.crew_type FROM iam.party p JOIN fleet.crew_profile cp ON cp.party_id = p.id
            WHERE p.uid = $1 AND cp.company_id = $2""", uid, company)
    if r is None:
        raise not_found("crew member")
    return r


async def listing(conn: asyncpg.Connection, company: int) -> list[dict]:
    recs = await conn.fetch(
        """SELECT p.uid, p.legal_name AS full_name, p.first_name, p.father_name, p.last_name, p.id_no_last4,
                  cp.crew_type, cp.license_class, cp.status, u.email,
                  fleet.crew_licence_problems(p.id, current_date) AS problems,
                  (SELECT min(l.expiry_date) FROM fleet.license_record l
                    WHERE l.subject_type = 'DRIVER' AND l.subject_id = p.id AND l.status <> 'SUSPENDED' AND l.expiry_date >= current_date) AS next_expiry
             FROM fleet.crew_profile cp JOIN iam.party p ON p.id = cp.party_id
             LEFT JOIN iam.app_user u ON u.party_id = p.id
            WHERE cp.company_id = $1 ORDER BY cp.crew_type, p.legal_name""", company)
    return [{**dict(r), "uid": str(r["uid"]), "problems": list(r["problems"]),
             "next_expiry": r["next_expiry"].isoformat() if r["next_expiry"] else None} for r in recs]


async def detail(conn: asyncpg.Connection, company: int, uid: uuid.UUID) -> dict:
    m = await _member(conn, company, uid)
    person = await conn.fetchrow(
        """SELECT p.legal_name AS full_name, p.first_name, p.father_name, p.grandfather_name, p.last_name, p.mother_name,
                  p.birth_date, p.id_no_last4, cp.crew_type, cp.license_class, cp.status,
                  fleet.crew_licence_problems(p.id, current_date) AS problems
             FROM iam.party p JOIN fleet.crew_profile cp ON cp.party_id = p.id WHERE p.id = $1""", m["id"])
    licences = await conn.fetch(
        """SELECT l.uid, l.license_type, l.license_no, l.issuer, l.license_class, l.issue_date, l.expiry_date, l.status,
                  fd.uid AS front_uid, bd.uid AS back_uid
             FROM fleet.license_record l LEFT JOIN iam.document fd ON fd.id = l.document_id LEFT JOIN iam.document bd ON bd.id = l.back_document_id
            WHERE l.subject_type = 'DRIVER' AND l.subject_id = $1 ORDER BY l.license_type, l.expiry_date DESC""", m["id"])
    out = {k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in dict(person).items()}
    out["problems"] = list(person["problems"])
    out["uid"] = str(uid)
    out["licences"] = [{**{k: (v.isoformat() if hasattr(v, "isoformat") else v) for k, v in dict(x).items()}, "uid": str(x["uid"]),
                        "front_uid": str(x["front_uid"]) if x["front_uid"] else None,
                        "back_uid": str(x["back_uid"]) if x["back_uid"] else None,
                        "expired": x["expiry_date"] < date.today()} for x in licences]
    return out


async def add_licence(conn: asyncpg.Connection, company: int, uid: uuid.UUID, body: LicenceIn) -> str:
    m = await _member(conn, company, uid)
    lid = await conn.fetchval(
        """INSERT INTO fleet.license_record (company_id, subject_type, subject_id, license_type, license_no, issuer, license_class,
             issue_date, expiry_date)
           VALUES ($1, 'DRIVER', $2, $3, $4, $5, $6, $7, $8) RETURNING uid""",
        company, m["id"], body.license_type, body.license_no.strip(), body.issuer.strip(),
        body.license_class.upper() if body.license_class else None, body.issue_date, body.expiry_date)
    if body.license_type == "DRIVING" and body.license_class:
        await conn.execute("UPDATE fleet.crew_profile SET license_class = $2 WHERE party_id = $1", m["id"], body.license_class.upper())
    return str(lid)


async def add_image(conn: asyncpg.Connection, ctx: db.Context, pr: Principal, company: int, uid: uuid.UUID, licence_uid: uuid.UUID,
                    side: Literal["front", "back"], data: bytes, file_name: str) -> str:
    """A picture of one face of a licence: stored encrypted and scanned like every document, then reviewed by the platform."""
    m = await _member(conn, company, uid)
    lic = await conn.fetchrow("SELECT id, issuer, issue_date, expiry_date FROM fleet.license_record WHERE uid = $1 AND subject_type = 'DRIVER' AND subject_id = $2",
                              licence_uid, m["id"])
    if lic is None:
        raise not_found("licence")
    if len(data) > MAX_IMAGE:
        raise ApiError(413, "FILE_TOO_LARGE", "the picture is larger than 8 MB")
    file_id = await documents.store_file(conn, ctx, pr, company, data, file_name)
    doc = await conn.fetchrow(
        """INSERT INTO iam.document (owner_type, owner_id, doc_type, issuer, issue_date, expiry_date, file_id, company_id, uploaded_by)
           VALUES ('LICENSE', $1, $2, $3, $4, $5, $6, $7, $8) RETURNING id, uid""",
        lic["id"], "LICENSE_FRONT" if side == "front" else "LICENSE_BACK", lic["issuer"], lic["issue_date"], lic["expiry_date"],
        file_id, company, pr.user_id)
    column = "document_id" if side == "front" else "back_document_id"
    await conn.execute(f"UPDATE fleet.license_record SET {column} = $2 WHERE id = $1", lic["id"], doc["id"])
    return str(doc["uid"])
