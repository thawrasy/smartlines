"""Know your customer for drivers and passengers (owner's request N14, migration 1159).

A person fills the form of their kind about themselves: a driver in the driver app, a passenger in their account. Values
the form marks sensitive (the identity document's number) are encrypted and bound to the person. One compliance
reviewer decides the file, never the person who entered it; an approved file makes the person verified until it is due
for review. What a verified person unlocks (redeeming points, driving trips) is the platform setting kyc.persons.

    The person (the PASSENGER or DRIVER portal)
    GET  /api/account/kyc                       their file (or none yet) and the form of their kind
    POST /api/account/kyc/open                  the open file, or a new version starting from the approved answers
    PUT  /api/account/kyc/{uid}                 {answers}
    POST /api/account/kyc/{uid}/submit

    The platform (kyc.view to read, each opening recorded; kyc.review.compliance to decide)
    GET  /api/admin/person-kyc?status=&kind=    the files, waiting ones first
    GET  /api/admin/person-kyc/{uid}            one file in full
    POST /api/admin/person-kyc/{uid}/decide     {decision: APPROVE|RETURN|REJECT, note, fields}
    POST /api/admin/person-kyc/{uid}/reveal     {path, reason}: one encrypted value in clear, recorded
"""
import json
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import crypto, db, policy
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, not_found
from ...util import row_dict
from . import service
from .api import AnswersIn, RevealIn, _db, _json, _need

person = APIRouter(prefix="/api/account", tags=["kyc"])
platform = APIRouter(prefix="/api/admin/person-kyc", tags=["kyc"])
member = require_portal("PASSENGER", "DRIVER")
staff = require_portal("PLATFORM")
TABLE = "iam.person_kyc"

FILE_SQL = """
    SELECT k.id, k.uid, k.party_id, k.subject_kind, k.version, k.status, k.answers, k.completeness, k.return_note, k.return_fields,
           k.decision_note, k.submitted_at, k.decided_at, k.approved_at, k.review_due, k.created_at, k.updated_at,
           f.version AS form_version, f.definition, k.submitted_by, du.email AS decided_by_email
      FROM iam.person_kyc k JOIN iam.kyc_form f ON f.id = k.form_id LEFT JOIN iam.app_user du ON du.id = k.decided_by"""


class PersonDecideIn(BaseModel):
    decision: Literal["APPROVE", "RETURN", "REJECT"]
    note: Optional[str] = Field(default=None, max_length=2000)
    fields: list[str] = Field(default_factory=list, max_length=200)


async def _file(conn, uid: uuid.UUID) -> dict:
    r = await conn.fetchrow(FILE_SQL + " WHERE k.uid = $1", uid)
    if r is None:
        raise not_found("KYC file")
    d = row_dict(r)
    d["answers"], d["definition"] = _json(d["answers"]), _json(d["definition"])
    return d


async def _missing(conn, uid: uuid.UUID) -> list[str]:
    return list(await conn.fetchval("SELECT iam.person_kyc_missing($1)", uid) or [])


def _for_person(d: dict) -> dict:
    keep = ("uid", "subject_kind", "version", "status", "answers", "completeness", "return_note", "return_fields", "decision_note",
            "submitted_at", "approved_at", "review_due", "updated_at", "form_version")
    return {k: d[k] for k in keep}


async def _view(conn, pr: Principal) -> dict:
    kind = pr.portal
    rows = await conn.fetch(
        """SELECT uid, version, status, submitted_at, approved_at, review_due FROM iam.person_kyc
            WHERE party_id = $1 AND subject_kind = $2
            ORDER BY (status IN ('DRAFT', 'SUBMITTED', 'RETURNED')) DESC, version DESC""", pr.party_id, kind)
    current = await _file(conn, rows[0]["uid"]) if rows else None
    form = await conn.fetchrow("SELECT version, definition FROM iam.kyc_form WHERE status = 'ACTIVE' AND subject_kind = $1", kind)
    history = [row_dict(r) for r in sorted(rows, key=lambda r: -r["version"])]
    for h in history:
        h.pop("uid")
    return {
        "kind": kind,
        "file": _for_person(current) if current else None,
        "missing": await _missing(conn, current["uid"]) if current and current["status"] in ("DRAFT", "RETURNED") else [],
        "definition": current["definition"] if current else _json(form["definition"]) if form else None,
        "verification_status": await conn.fetchval("SELECT verification_status FROM iam.party WHERE id = $1", pr.party_id),
        "verified": await conn.fetchval("SELECT iam.person_verified($1, $2)", pr.party_id, kind),
        "required_before": (_json(await conn.fetchval("SELECT iam.kyc_setting('kyc.persons')::text")) or {})
                           .get("required_before", {}).get(kind, []),
        "approved": next((h for h in history if h["status"] == "APPROVED"), None),
        "history": history,
    }


async def _own(conn, pr: Principal, uid: uuid.UUID) -> dict:
    d = await _file(conn, uid)
    if d["party_id"] != pr.party_id or d["subject_kind"] != pr.portal:
        raise not_found("KYC file")
    return d


@person.get("/kyc")
async def my_kyc(request: Request, pr: Principal = Depends(member)):
    async with db.transaction(context_for(request, pr)) as conn:
        return await _view(conn, pr)


@person.post("/kyc/open")
async def my_open(request: Request, pr: Principal = Depends(member)):
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await _db(conn.fetchval("SELECT iam.open_person_kyc($1, $2)", pr.party_id, pr.portal))
        kid = await conn.fetchval("SELECT id FROM iam.person_kyc WHERE uid = $1", uid)
        out = await _view(conn, pr)
    request.state.audit = {"action": "kyc.open", "object_type": "person_kyc", "object_id": kid}
    return out


@person.put("/kyc/{kyc_uid}")
async def my_save(kyc_uid: uuid.UUID, body: AnswersIn, request: Request, pr: Principal = Depends(member)):
    async with db.transaction(context_for(request, pr)) as conn:
        d = await _own(conn, pr, kyc_uid)
        if d["status"] not in ("DRAFT", "RETURNED"):
            raise ApiError(409, "KYC_LOCKED", f"the file is {d['status'].lower()}; it is filled while it is a draft or returned")
        fc = await crypto.cipher(conn)
        try:
            clean = service.clean(d["definition"], body.answers, d["party_id"], fc, TABLE)
        except service.Invalid as e:
            raise ApiError(422, "KYC_INVALID", "some answers do not fit the form", errors=e.errors) from e
        missing = list(await conn.fetchval("SELECT iam.kyc_missing($1::jsonb - 'documents', $2::jsonb, NULL)",
                                           json.dumps(d["definition"]), json.dumps(clean)) or [])
        done = service.completeness(d["definition"], missing)
        await _db(conn.execute("SELECT iam.save_person_kyc($1, $2::jsonb, $3::smallint)", kyc_uid, json.dumps(clean), done))
    request.state.audit = {"action": "kyc.save", "object_type": "person_kyc", "object_id": d["id"], "reason": f"{done}% complete"}
    return {"completeness": done, "missing": missing, "answers": clean}


@person.post("/kyc/{kyc_uid}/submit")
async def my_submit(kyc_uid: uuid.UUID, request: Request, pr: Principal = Depends(member)):
    async with db.transaction(context_for(request, pr)) as conn:
        d = await _own(conn, pr, kyc_uid)
        missing = await _missing(conn, kyc_uid)
        if missing:
            raise ApiError(422, "KYC_INCOMPLETE", f"{len(missing)} item(s) are missing", missing=missing)
        out = _json(await _db(conn.fetchval("SELECT iam.submit_person_kyc($1)::text", kyc_uid)))
    request.state.audit = {"action": "kyc.submit", "object_type": "person_kyc", "object_id": d["id"]}
    return out


# ------------------------------------------------------------------ the platform
@platform.get("")
async def files(request: Request, status: Literal["WAITING", "ALL", "DUE"] = "WAITING",
                kind: Optional[Literal["DRIVER", "PASSENGER"]] = None, pr: Principal = Depends(staff)):
    _need(pr, "kyc.view")
    where = {"WAITING": "k.status = 'SUBMITTED'", "ALL": "k.status <> 'SUPERSEDED'",
             "DUE": "k.status = 'APPROVED' AND k.review_due <= current_date + 30"}[status]
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            f"""SELECT k.uid, k.subject_kind, k.version, k.status, k.completeness, k.submitted_at, k.approved_at, k.review_due,
                       p.uid AS person_uid, p.legal_name AS person_name, p.verification_status
                  FROM iam.person_kyc k JOIN iam.party p ON p.id = k.party_id
                 WHERE {where} AND ($1::text IS NULL OR k.subject_kind = $1)
                 ORDER BY k.submitted_at NULLS LAST, k.updated_at DESC LIMIT 500""", kind)
    return {"files": [row_dict(r) for r in recs]}


@platform.get("/{kyc_uid}")
async def file(kyc_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.view")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        d = await _file(conn, kyc_uid)
        who = row_dict(await conn.fetchrow(
            """SELECT p.uid, p.legal_name AS name, p.verification_status, p.id_no_last4,
                      (SELECT email FROM iam.app_user u WHERE u.party_id = p.id LIMIT 1) AS email
                 FROM iam.party p WHERE p.id = $1""", d["party_id"]))
        versions = [row_dict(r) for r in await conn.fetch(
            """SELECT uid, version, status, submitted_at, approved_at, review_due FROM iam.person_kyc
                WHERE party_id = $1 AND subject_kind = $2 ORDER BY version DESC""", d["party_id"], d["subject_kind"])]
        me = await conn.fetchval("SELECT party_id FROM iam.app_user WHERE id = $1", pr.user_id)
        await conn.execute(
            """INSERT INTO audit.data_access_log (user_id, ip, object_type, object_id, fields, purpose, request_id)
               VALUES ($1, $2::inet, 'person_kyc', $3, ARRAY['answers'], 'KYC_REVIEW', $4)""",
            pr.user_id, ctx.ip, d["id"], ctx.request_id)
    out = {k: v for k, v in d.items() if k not in ("id", "party_id", "submitted_by")}
    out.update(person=who, versions=versions,
               may_decide=(d["status"] == "SUBMITTED" and "kyc.review.compliance" in pr.permissions
                           and d["submitted_by"] != pr.user_id and me != d["party_id"]))
    return out


@platform.post("/{kyc_uid}/decide")
async def decide(kyc_uid: uuid.UUID, body: PersonDecideIn, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.review.compliance")
    async with db.transaction(context_for(request, pr)) as conn:
        d = await _file(conn, kyc_uid)
        out = _json(await _db(conn.fetchval("SELECT iam.decide_person_kyc($1, $2, $3, $4::text[])::text", kyc_uid, body.decision,
                                            body.note, body.fields)))
    request.state.audit = {"action": "kyc.decide", "object_type": "person_kyc", "object_id": d["id"],
                           "reason": f"{body.decision.lower()}{f': {body.note}' if body.note else ''}"[:300]}
    return out


@platform.post("/{kyc_uid}/reveal")
async def reveal(kyc_uid: uuid.UUID, body: RevealIn, request: Request, pr: Principal = Depends(staff)):
    """The identity document's number in clear, for the review, with the reason; recorded twice."""
    _need(pr, "kyc.view")
    ctx = context_for(request, pr)
    await policy.authorize(ctx, "iam.person_kyc.answers", "READ", "KYC_REVIEW", body.reason, "kyc.view")
    async with db.transaction(ctx) as conn:
        d = await _file(conn, kyc_uid)
        fc = await crypto.cipher(conn)
        try:
            value = service.reveal(d["definition"], d["answers"], d["party_id"], body.path, fc, TABLE)
        except LookupError as exc:
            raise not_found("encrypted value") from exc
        await conn.execute(
            """INSERT INTO audit.data_access_log (user_id, ip, object_type, object_id, fields, purpose, request_id)
               VALUES ($1, $2::inet, 'person_kyc', $3, ARRAY[$4], $5, $6)""",
            pr.user_id, ctx.ip, d["id"], body.path, f"KYC_REVIEW: {body.reason}", ctx.request_id)
    request.state.audit = {"action": "kyc.reveal", "object_type": "person_kyc", "object_id": d["id"], "reason": f"{body.path}: {body.reason}"[:300]}
    return {"path": body.path, "value": value}
