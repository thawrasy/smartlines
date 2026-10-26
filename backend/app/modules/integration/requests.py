"""Integration requests (owner's request N2, 1155, option B): a company asks, the platform builds and approves.

A carrier or agency files a request with every detail the platform needs; it never makes clients, keys, webhooks or
scopes itself. Platform security builds the client from the request (acting as the person who asked), another person
approves it, and the company takes the key once from its portal.
"""
import ipaddress
import uuid
from typing import Literal, Optional

import asyncpg
from pydantic import BaseModel, Field, field_validator

from ...deps import Principal
from ...errors import ApiError, not_found
from ...util import rows
from . import service
from .scopes import KIND_SCOPES

EMAIL = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


class RequestIn(BaseModel):
    purpose: str = Field(min_length=10, max_length=1000)
    connection_type: Literal["READ", "WEBHOOKS", "TWO_WAY"]
    data_needed: list[str] = Field(min_length=1, max_length=12)
    system_name: str = Field(min_length=2, max_length=120)
    system_vendor: Optional[str] = Field(default=None, min_length=2, max_length=120)
    system_host: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9.-]{3,253}$")
    ip_addresses: list[str] = Field(default_factory=list, max_length=20)
    contact_name: str = Field(min_length=3, max_length=120)
    contact_email: str = Field(pattern=EMAIL, max_length=200)
    contact_mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")
    expected_volume: Literal["LOW", "MEDIUM", "HIGH"]
    environment: Literal["SANDBOX", "PRODUCTION"] = "SANDBOX"

    @field_validator("ip_addresses")
    @classmethod
    def _cidr(cls, v: list[str]) -> list[str]:
        try:
            return [str(ipaddress.ip_network(x.strip(), strict=False)) for x in v]
        except ValueError as exc:
            raise ValueError("an address or range is not valid") from exc


class BuildIn(BaseModel):
    """What platform security decides from the request: the client's name, kind and scopes."""
    name: str = Field(min_length=3, max_length=120)
    kind: Literal["CARRIER", "CHANNEL", "INTEGRATION"]
    scopes: list[str] = Field(min_length=1, max_length=12)
    rate_limit_per_min: int = Field(default=600, ge=10, le=6000)
    note: Optional[str] = Field(default=None, min_length=1, max_length=500)


class NoteIn(BaseModel):
    note: str = Field(min_length=3, max_length=500)


_SELECT = """SELECT r.*, p.legal_name AS company_name, cp.uid AS company_uid, rp.legal_name AS requested_by_name, ru.email AS requested_by_email,
                    c.uid AS client_uid, c.status AS client_status, c.name AS client_name,
                    host_list.addresses
               FROM iam.integration_request r JOIN iam.party p ON p.id = r.company_id JOIN iam.party cp ON cp.id = r.company_id
               JOIN iam.app_user ru ON ru.id = r.requested_by JOIN iam.party rp ON rp.id = ru.party_id
               LEFT JOIN iam.api_client c ON c.id = r.api_client_id
               CROSS JOIN LATERAL (SELECT coalesce(array_agg(host(a) || CASE WHEN masklen(a) IN (32, 128) THEN '' ELSE '/' || masklen(a) END),
                                                   '{}') AS addresses FROM unnest(r.ip_addresses) a) host_list"""


def _view(r: asyncpg.Record) -> dict:
    out = rows([r])[0]
    for k in ("id", "company_id", "requested_by", "handled_by", "api_client_id", "ip_addresses"):
        out.pop(k, None)
    out["ip_addresses"] = list(r["addresses"])
    out.pop("addresses", None)
    out["data_needed"] = list(r["data_needed"])
    return out


async def submit(conn: asyncpg.Connection, pr: Principal, body: RequestIn) -> dict:
    ctype = await conn.fetchval("SELECT company_type FROM iam.company WHERE id = $1", pr.company_id)
    kind = "CHANNEL" if ctype == "AGENCY" else "CARRIER"
    unknown = sorted(set(body.data_needed) - set(KIND_SCOPES.get(kind, ())))
    if unknown:
        raise ApiError(422, "SCOPE_NOT_ALLOWED", "this data is not offered to your kind of company: " + ", ".join(unknown), rejected=unknown)
    uid = await conn.fetchval(
        """INSERT INTO iam.integration_request (company_id, requested_by, purpose, connection_type, data_needed, system_name, system_vendor,
             system_host, ip_addresses, contact_name, contact_email, contact_mobile, expected_volume, environment)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::cidr[], $10, $11, $12, $13, $14) RETURNING uid""",
        pr.company_id, pr.user_id, body.purpose.strip(), body.connection_type, sorted(set(body.data_needed)), body.system_name.strip(),
        body.system_vendor, body.system_host, body.ip_addresses, body.contact_name.strip(), body.contact_email.strip().lower(),
        body.contact_mobile, body.expected_volume, body.environment)
    return {"uid": str(uid), "status": "SUBMITTED"}


async def listing(conn: asyncpg.Connection, company_id: Optional[int]) -> list[dict]:
    recs = await conn.fetch(_SELECT + " WHERE ($1::bigint IS NULL OR r.company_id = $1) ORDER BY (r.status = 'SUBMITTED') DESC, r.created_at DESC LIMIT 300",
                            company_id)
    return [_view(r) for r in recs]


async def _request(conn: asyncpg.Connection, uid: uuid.UUID, company_id: Optional[int]) -> asyncpg.Record:
    r = await conn.fetchrow(_SELECT + " WHERE r.uid = $1 AND ($2::bigint IS NULL OR r.company_id = $2) FOR UPDATE OF r", uid, company_id)
    if r is None:
        raise not_found("integration request")
    return r


async def withdraw(conn: asyncpg.Connection, uid: uuid.UUID, company_id: int) -> dict:
    r = await _request(conn, uid, company_id)
    if r["status"] != "SUBMITTED":
        raise ApiError(409, "REQUEST_HANDLED", "the platform already handled this request")
    await conn.execute("UPDATE iam.integration_request SET status = 'WITHDRAWN' WHERE id = $1", r["id"])
    return {"uid": str(uid), "status": "WITHDRAWN"}


async def reject(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, note: str) -> dict:
    r = await _request(conn, uid, None)
    if r["status"] != "SUBMITTED":
        raise ApiError(409, "REQUEST_HANDLED", "this request was already handled")
    await conn.execute("""UPDATE iam.integration_request SET status = 'REJECTED', handled_by = $2, handled_at = now(), decision_note = $3
                           WHERE id = $1""", r["id"], pr.user_id, note.strip())
    return {"uid": str(uid), "status": "REJECTED"}


async def build(conn: asyncpg.Connection, pr: Principal, uid: uuid.UUID, body: BuildIn) -> dict:
    """The client, made by platform security from the request and acting as the person who asked; PENDING until another
    person approves it."""
    r = await _request(conn, uid, None)
    if r["status"] != "SUBMITTED":
        raise ApiError(409, "REQUEST_HANDLED", "this request was already handled")
    client = await service.create(
        conn, pr, platform=True, name=body.name, kind=body.kind, scopes=body.scopes, environment=r["environment"],
        description=r["purpose"][:500], contact_email=r["contact_email"], ip_allowlist=list(r["addresses"]),
        company_uid=r["company_uid"], acting_email=r["requested_by_email"], provider_code=None, authority_code=None,
        rate_limit=body.rate_limit_per_min)
    cid = await conn.fetchval("SELECT id FROM iam.api_client WHERE uid = $1", uuid.UUID(client["uid"]))
    await conn.execute("""UPDATE iam.integration_request SET status = 'CLIENT_CREATED', api_client_id = $2, handled_by = $3, handled_at = now(),
                                 decision_note = $4 WHERE id = $1""", r["id"], cid, pr.user_id, body.note)
    return {"uid": str(uid), "status": "CLIENT_CREATED", "client": client}
