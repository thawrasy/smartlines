"""A person's name in parts (owner's requests N4 and N35, migration 1149).

The parts are kept in the script of the identity document (first, father, grandfather, family, and the mother's name if
given) and in Latin letters as in the passport. Which parts are required follows the nationality, from the platform's
setting identity.name_rules: a Syrian gives at least first, father's and family names; others give first and family
names and their Latin name. The full name as one text (iam.party.legal_name) is written from the parts.
"""
import hmac
import json
import secrets
import uuid
from datetime import datetime, timezone
from typing import Optional

import asyncpg
from pydantic import BaseModel, Field, field_validator

from ... import crypto
from ...errors import ApiError
from ..sales.models import NAME_PART

LATIN_PART = r"^[A-Za-z][A-Za-z '.-]{0,59}$"
PARTS = ("first", "father", "grandfather", "last")


class NameIn(BaseModel):
    nationality: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    first_name: str = Field(min_length=1, max_length=60, pattern=NAME_PART)
    father_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    grandfather_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    last_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    mother_name: Optional[str] = Field(default=None, min_length=1, max_length=60, pattern=NAME_PART)
    first_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)
    father_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)
    grandfather_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)
    last_name_latin: Optional[str] = Field(default=None, max_length=60, pattern=LATIN_PART)

    @field_validator("first_name", "father_name", "grandfather_name", "last_name", "mother_name", "first_name_latin",
                     "father_name_latin", "grandfather_name_latin", "last_name_latin", mode="before")
    @classmethod
    def _tidy(cls, v):
        return (" ".join(v.split()) or None) if isinstance(v, str) else v


async def rules(conn: asyncpg.Connection) -> dict:
    v = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'identity.name_rules'")
    return json.loads(v) if isinstance(v, str) else dict(v or {})


def rule_for(r: dict, nationality: str) -> dict:
    return r.get(nationality) or r.get("OTHER") or {"required": ["first", "last"], "latin_required": True}


def check(r: dict, n: NameIn) -> None:
    """Refuses a name that lacks a part its nationality requires (in the document's script, and in Latin letters where
    the rule asks for them)."""
    rule = rule_for(r, n.nationality)
    missing = [p for p in rule.get("required", []) if not getattr(n, f"{p}_name", None)]
    if missing:
        raise ApiError(422, "NAME_PARTS_REQUIRED", "give the name parts the identity document carries", missing=missing)
    if rule.get("latin_required") and not (n.first_name_latin and n.last_name_latin):
        raise ApiError(422, "LATIN_NAME_REQUIRED", "give the first and family names in Latin letters, as in the passport")


def full(first: Optional[str], father: Optional[str], grandfather: Optional[str], last: Optional[str]) -> str:
    return " ".join(p for p in (first, father, grandfather, last) if p)


def full_of(n: NameIn) -> str:
    return full(n.first_name, n.father_name, n.grandfather_name, n.last_name)


def latin_of(n: NameIn) -> Optional[str]:
    return full(n.first_name_latin, n.father_name_latin, n.grandfather_name_latin, n.last_name_latin) or None


async def save(conn: asyncpg.Connection, party_id: int, n: NameIn) -> None:
    await conn.execute(
        """UPDATE iam.party SET first_name = $2, father_name = $3, grandfather_name = $4, last_name = $5, mother_name = $6,
                  first_name_latin = $7, father_name_latin = $8, grandfather_name_latin = $9, last_name_latin = $10,
                  legal_name = $11, name_latin = $12, nationality = $13, names_complete = true
            WHERE id = $1""",
        party_id, n.first_name, n.father_name, n.grandfather_name, n.last_name, n.mother_name, n.first_name_latin,
        n.father_name_latin, n.grandfather_name_latin, n.last_name_latin, full_of(n), latin_of(n), n.nationality)


async def of_party(conn: asyncpg.Connection, party_id: int) -> dict:
    p = await conn.fetchrow(
        """SELECT nationality, first_name, father_name, grandfather_name, last_name, mother_name, first_name_latin,
                  father_name_latin, grandfather_name_latin, last_name_latin, names_complete, verification_status,
                  birth_date, gender
             FROM iam.party WHERE id = $1""", party_id)
    return dict(p) if p else {}


# ------------------------------------------------------------------ the code that confirms an e-mail
CODE_TRIES = 5


def new_code() -> str:
    return f"{secrets.randbelow(1_000_000):06d}"


async def issue_email_code(conn: asyncpg.Connection, user_id: int, purpose: str = "VERIFY_CONTACT",
                           minutes: Optional[int] = None) -> tuple[str, int]:
    """A new six-digit code for the account's e-mail; any code still open is closed by it. At most one a minute and
    five an hour."""
    await conn.execute("SELECT pg_advisory_xact_lock(hashtext('contact-code'), hashtext($1::bigint::text))", user_id)
    recent = await conn.fetchrow(
        """SELECT max(created_at) AS last, count(*) AS n FROM iam.contact_code
            WHERE user_id = $1 AND channel = 'EMAIL' AND created_at > now() - interval '1 hour'""", user_id)
    if recent["n"]:
        wait = 60 - (datetime.now(timezone.utc) - recent["last"]).total_seconds()
        if wait > 0:
            raise ApiError(429, "CODE_RESEND_TOO_SOON", "wait before asking for another code", retry_in=int(wait) + 1)
        if recent["n"] >= 5:
            raise ApiError(429, "CODE_TOO_MANY", "too many codes asked for in the last hour; try again later")
    minutes = minutes or int((await rules(conn)).get("email_code_minutes", 30))
    code, fc = new_code(), await crypto.cipher(conn)
    await conn.execute("UPDATE iam.contact_code SET consumed_at = now() WHERE user_id = $1 AND channel = 'EMAIL' AND consumed_at IS NULL",
                       user_id)
    uid = uuid.uuid4()
    await conn.execute(
        """INSERT INTO iam.contact_code (uid, user_id, channel, purpose, code_hash, expires_at)
           VALUES ($1, $2, 'EMAIL', $5, $3, now() + make_interval(mins => $4))""",
        uid, user_id, fc.blind_index(code, f"contact:{uid}"), minutes, purpose)
    return code, minutes


async def confirm_email(conn: asyncpg.Connection, user_id: int, code: str, purpose: str = "VERIFY_CONTACT") -> bool:
    """Checks the open code; every entry counts, a code is used once; a right code confirms the e-mail."""
    ch = await conn.fetchrow(
        """SELECT id, uid, attempts, expires_at, code_hash FROM iam.contact_code
            WHERE user_id = $1 AND channel = 'EMAIL' AND purpose = $2 AND consumed_at IS NULL
            ORDER BY id DESC LIMIT 1 FOR UPDATE""", user_id, purpose)
    if ch is None:
        return False
    if ch["expires_at"] <= datetime.now(timezone.utc):
        await conn.execute("UPDATE iam.contact_code SET consumed_at = now() WHERE id = $1", ch["id"])
        return False
    fc = await crypto.cipher(conn)
    ok = hmac.compare_digest(fc.blind_index(code.strip(), f"contact:{ch['uid']}"), bytes(ch["code_hash"]))
    await conn.execute(
        """UPDATE iam.contact_code SET attempts = attempts + 1,
             consumed_at = CASE WHEN $2 OR attempts + 1 >= $3 THEN now() END WHERE id = $1""", ch["id"], ok, CODE_TRIES)
    if ok:
        await conn.execute("UPDATE iam.app_user SET email_verified_at = now() WHERE id = $1", user_id)
    return ok
