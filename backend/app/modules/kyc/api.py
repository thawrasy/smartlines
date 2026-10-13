"""Know your customer for the companies on the platform (owner's request, October 2026; migration 1118).

    Company (the OPERATOR portal; company.kyc, which the owner holds)
    GET  /api/carrier/kyc                       its file (or none yet), the form it follows, the documents asked for
    POST /api/carrier/kyc/open                  the open file, or a new version starting from the approved answers
    PUT  /api/carrier/kyc/{uid}                 {answers}: checked against the form, sensitive values encrypted
    POST /api/carrier/kyc/{uid}/submit          for review, once nothing is missing

    Platform (the PLATFORM portal): kyc.view to read (each opening recorded), kyc.capture to fill a file from paper,
    kyc.review.compliance|finance|tax for the stages; a government authority's members decide its stages by membership;
    kyc.settings for the form and its rules
    GET  /api/admin/kyc?status=                 a row per company: its file in work or in force, the stage waiting, risk
    GET  /api/admin/kyc/{uid}                   a file in full, its decisions and versions
    POST /api/admin/kyc/companies/{uid}/open    the company's open file, to capture it
    PUT  /api/admin/kyc/{uid}                   {answers}, captured from paper
    POST /api/admin/kyc/{uid}/submit
    POST /api/admin/kyc/{uid}/decide            {decision: APPROVE|RETURN|REJECT, note, fields, risk_level}
    POST /api/admin/kyc/{uid}/reveal            {path, reason}: one encrypted value in clear, recorded
    GET  /api/admin/kyc/form                    the version in force, the draft and the history
    PUT  /api/admin/kyc/form                    {definition, note}: the draft of the next version, checked
    POST /api/admin/kyc/form/{version}/activate
    GET  /api/admin/kyc/settings
    PUT  /api/admin/kyc/settings/{key}          {value}
"""
import json
import re
import uuid
from typing import Any, Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field

from ... import crypto, db, policy
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from ...util import row_dict
from . import service

carrier = APIRouter(prefix="/api/carrier", tags=["kyc"])
platform = APIRouter(prefix="/api/admin", tags=["kyc"])
operator = require_portal("OPERATOR")
staff = require_portal("PLATFORM")

SETTINGS = ("review_stages", "risk_rules", "risk_levels", "review_months", "ubo_threshold_pct", "documents_on_submit",
            "required_before", "distinct_reviewers")
STATUS = {"NOT_FOUND": 404, "FORBIDDEN": 403, "NOT_YOUR_STAGE": 403, "KYC_INCOMPLETE": 422, "KYC_INVALID": 422,
          "KYC_FORM_INVALID": 422, "INVALID_SETTING": 422, "REASON_REQUIRED": 422, "KYC_LOCKED": 409, "KYC_NOT_IN_REVIEW": 409,
          "KYC_PROHIBITED": 409, "SECOND_PERSON_REQUIRED": 409, "KYC_NO_FORM": 409, "KYC_FORM_FROZEN": 409}


async def _db(call):
    """What the database refuses, with the status that fits it."""
    try:
        return await call
    except asyncpg.RaiseError as exc:
        code, _, message = str(exc).partition(":")
        if code in STATUS:
            raise ApiError(STATUS[code], code, message.strip() or code) from exc
        raise


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden("missing permission: " + " | ".join(codes))


def _json(v: Any) -> Any:
    return json.loads(v) if isinstance(v, str) else v


class AnswersIn(BaseModel):
    answers: dict[str, Any]


class DecideIn(BaseModel):
    decision: Literal["APPROVE", "RETURN", "REJECT"]
    note: Optional[str] = Field(default=None, max_length=2000)
    fields: list[str] = Field(default_factory=list, max_length=200)
    risk_level: Optional[Literal["LOW", "MEDIUM", "HIGH", "PROHIBITED"]] = None


class RevealIn(BaseModel):
    path: str = Field(pattern=r"^[a-z][a-z0-9_]{1,40}(\.[0-9]{1,3}\.[a-z][a-z0-9_]{1,40})?$")
    reason: str = Field(min_length=5, max_length=300)


class FormIn(BaseModel):
    definition: dict[str, Any]
    note: Optional[str] = Field(default=None, max_length=500)


class SettingIn(BaseModel):
    value: Any


# ------------------------------------------------------------------ shared
FILE_SQL = """
    SELECT k.id, k.uid, k.company_id, k.version, k.status, k.answers, k.completeness, k.round, k.step, k.review_stages,
           k.risk_score, k.risk_level, k.risk_override, k.risk_override_reason, k.risk_factors, k.return_note, k.return_fields,
           k.submitted_at, k.decided_at, k.approved_at, k.review_due, k.created_at, k.updated_at, k.form_id, f.version AS form_version,
           f.definition, su.email AS submitted_by_email, uu.email AS updated_by_email,
           (SELECT ua.account_kind FROM iam.app_user ua WHERE ua.id = k.updated_by) AS updated_by_kind
      FROM iam.company_kyc k JOIN iam.kyc_form f ON f.id = k.form_id
      LEFT JOIN iam.app_user su ON su.id = k.submitted_by LEFT JOIN iam.app_user uu ON uu.id = k.updated_by"""


async def _file(conn, uid: uuid.UUID) -> dict:
    r = await conn.fetchrow(FILE_SQL + " WHERE k.uid = $1", uid)
    if r is None:
        raise not_found("KYC file")
    d = row_dict(r)
    for k in ("answers", "review_stages", "risk_factors", "definition"):
        d[k] = _json(d[k])
    return d


def _waiting_for(d: dict) -> Optional[dict]:
    stages = d.get("review_stages") or []
    return stages[d["step"]] if d["status"] == "SUBMITTED" and d["step"] < len(stages) else None


async def _documents(conn, company_id: int, definition: dict) -> list[dict]:
    """The documents the form asks for, with the latest the company uploaded of each type."""
    latest = {r["doc_type"]: row_dict(r) for r in await conn.fetch(
        """SELECT DISTINCT ON (doc_type) doc_type, uid, status, expiry_date, created_at FROM iam.document
            WHERE company_id = $1 ORDER BY doc_type, created_at DESC""", company_id)}
    out = []
    for d in definition.get("documents", []):
        doc = latest.get(d["type"])
        out.append({"type": d["type"], "required": d["required"], "status": doc["status"] if doc else None,
                    "expiry_date": doc["expiry_date"] if doc else None, "uploaded_at": doc["created_at"] if doc else None})
    return out


async def _missing(conn, d: dict) -> list[str]:
    return list(await conn.fetchval("SELECT iam.kyc_missing($1::jsonb, $2::jsonb, $3)",
                                    json.dumps(d["definition"]), json.dumps(d["answers"]), d["company_id"]) or [])


async def _save(conn, request: Request, pr: Principal, d: dict, answers: dict) -> dict:
    """Checks the answers against the file's form, encrypts the sensitive ones, saves them with how complete they are."""
    if d["status"] not in ("DRAFT", "RETURNED"):
        raise ApiError(409, "KYC_LOCKED", f"the file is {d['status'].lower()}; it is filled while it is a draft or returned")
    fc = await crypto.cipher(conn)
    try:
        clean = service.clean(d["definition"], answers, d["company_id"], fc)
    except service.Invalid as e:
        raise ApiError(422, "KYC_INVALID", "some answers do not fit the form", errors=e.errors) from e
    d["answers"] = clean
    missing = await _missing(conn, d)
    done = service.completeness(d["definition"], missing)
    await _db(conn.execute("SELECT iam.save_company_kyc($1, $2::jsonb, $3::smallint)", d["uid"], json.dumps(clean), done))
    request.state.audit = {"action": "kyc.save", "object_type": "company_kyc", "object_id": d["id"], "reason": f"{done}% complete"}
    return {"completeness": done, "missing": missing, "answers": clean}


async def _submit(conn, request: Request, d: dict) -> dict:
    missing = await _missing(conn, d)
    if missing:
        raise ApiError(422, "KYC_INCOMPLETE", f"{len(missing)} item(s) are missing", missing=missing)
    out = _json(await _db(conn.fetchval("SELECT iam.submit_company_kyc($1)::text", d["uid"])))
    request.state.audit = {"action": "kyc.submit", "object_type": "company_kyc", "object_id": d["id"]}
    return out


def _for_company(d: dict) -> dict:
    """What the company sees of its file: not its risk, nor who reviewed it."""
    keep = ("uid", "version", "status", "answers", "completeness", "return_note", "return_fields", "submitted_at",
            "approved_at", "review_due", "updated_at", "form_version")
    out = {k: d[k] for k in keep}
    w = _waiting_for(d)
    out["waiting_for"] = w["by"] if w else None
    return out


# ------------------------------------------------------------------ the company
async def _company_file(conn, pr: Principal, uid: uuid.UUID) -> dict:
    d = await _file(conn, uid)
    if d["company_id"] != pr.company_id:
        raise not_found("KYC file")
    return d


async def _carrier_view(conn, pr: Principal) -> dict:
    rows = await conn.fetch(
        """SELECT uid, status FROM iam.company_kyc WHERE company_id = $1
            ORDER BY (status IN ('DRAFT', 'SUBMITTED', 'RETURNED')) DESC, version DESC""", pr.company_id)
    form = await conn.fetchrow("SELECT version, definition FROM iam.kyc_form WHERE status = 'ACTIVE'")
    current = await _file(conn, rows[0]["uid"]) if rows else None
    definition = current["definition"] if current else _json(form["definition"]) if form else None
    history = [row_dict(r) for r in await conn.fetch(
        """SELECT version, status, submitted_at, approved_at, review_due FROM iam.company_kyc
            WHERE company_id = $1 ORDER BY version DESC""", pr.company_id)]
    return {
        "file": _for_company(current) if current else None,
        "missing": await _missing(conn, current) if current and current["status"] in ("DRAFT", "RETURNED") else [],
        "definition": definition,
        "documents": await _documents(conn, pr.company_id, definition) if definition else [],
        "ubo_threshold_pct": _json(await conn.fetchval("SELECT iam.kyc_setting('kyc.ubo_threshold_pct')::text")),
        "approved": next((h for h in history if h["status"] == "APPROVED"), None),
        "history": history,
    }


@carrier.get("/kyc")
async def carrier_kyc(request: Request, pr: Principal = Depends(operator)):
    _need(pr, "company.kyc")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _carrier_view(conn, pr)


@carrier.post("/kyc/open")
async def carrier_open(request: Request, pr: Principal = Depends(operator)):
    """The open file, or a new version: an update starts from the approved answers, which stay in force until the new
    version is approved."""
    _need(pr, "company.kyc")
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await _db(conn.fetchval("SELECT iam.open_company_kyc($1)", pr.company_id))
        kid = await conn.fetchval("SELECT id FROM iam.company_kyc WHERE uid = $1", uid)
        out = await _carrier_view(conn, pr)
    request.state.audit = {"action": "kyc.open", "object_type": "company_kyc", "object_id": kid}
    return out


@carrier.put("/kyc/{kyc_uid}")
async def carrier_save(kyc_uid: uuid.UUID, body: AnswersIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "company.kyc")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _save(conn, request, pr, await _company_file(conn, pr, kyc_uid), body.answers)


@carrier.post("/kyc/{kyc_uid}/submit")
async def carrier_submit(kyc_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "company.kyc")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _submit(conn, request, await _company_file(conn, pr, kyc_uid))


# ------------------------------------------------------------------ the platform and the authorities
async def _member_of(conn, pr: Principal) -> list[str]:
    return [r["code"] for r in await conn.fetch(
        """SELECT a.code FROM sec.authority_member m JOIN sec.authority_profile a ON a.id = m.authority_id
            WHERE m.user_id = $1 ORDER BY a.code""", pr.user_id)]


async def _reader(conn, pr: Principal) -> list[str]:
    """Platform staff with kyc.view read every file; an authority's members, the files waiting for their authority."""
    authorities = await _member_of(conn, pr)
    if "kyc.view" not in pr.permissions and not authorities:
        raise forbidden("missing permission: kyc.view")
    return authorities


LIST_SQL = """
    SELECT p.uid AS company_uid, p.legal_name AS company_name, iam.logo_version(c.id) AS company_logo, c.company_type,
           k.uid, k.version, k.status, k.completeness, k.step, k.review_stages, k.submitted_at, k.updated_at,
           coalesce(k.risk_override, k.risk_level) AS risk_level, k.risk_score, f.version AS form_version,
           ap.approved_at, ap.review_due, coalesce(ap.risk_override, ap.risk_level) AS approved_risk_level
      FROM iam.company c JOIN iam.party p ON p.id = c.id
      LEFT JOIN LATERAL (SELECT * FROM iam.company_kyc x WHERE x.company_id = c.id AND x.status <> 'SUPERSEDED'
                          ORDER BY (x.status IN ('DRAFT', 'SUBMITTED', 'RETURNED')) DESC, x.version DESC LIMIT 1) k ON true
      LEFT JOIN iam.kyc_form f ON f.id = k.form_id
      LEFT JOIN iam.company_kyc ap ON ap.company_id = c.id AND ap.status = 'APPROVED'"""


@platform.get("/kyc")
async def kyc_list(request: Request, status: Literal["WAITING", "ALL", "DUE", "OPEN", "NONE"] = "ALL",
                   pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        authorities = await _reader(conn, pr)
        where = {"WAITING": "k.status = 'SUBMITTED'", "ALL": "true",
                 "DUE": "ap.review_due IS NOT NULL AND ap.review_due <= current_date + 30",
                 "OPEN": "k.status IN ('DRAFT', 'RETURNED')", "NONE": "k.uid IS NULL"}[status]
        recs = await conn.fetch(LIST_SQL + f" WHERE {where} ORDER BY k.submitted_at NULLS LAST, p.legal_name LIMIT 500")
        out = []
        for r in recs:
            d = row_dict(r)
            d["review_stages"] = _json(d["review_stages"]) or []
            d["waiting_for"] = _waiting_for(d) if d["uid"] else None
            if "kyc.view" not in pr.permissions and not (d["waiting_for"] and d["waiting_for"].get("authority") in authorities):
                continue
            d["may_decide"] = bool(d["waiting_for"]) and await conn.fetchval(
                "SELECT iam.may_decide_kyc_stage($1::jsonb)", json.dumps(d["waiting_for"]))
            d.pop("review_stages")
            out.append(d)
    return {"files": out, "authorities": authorities}


# ------------------------------------------------------------------ the form and the settings
@platform.get("/kyc/form")
async def form(request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.view", "kyc.settings")
    async with db.transaction(context_for(request, pr)) as conn:
        versions = [row_dict(r) for r in await conn.fetch(
            """SELECT f.version, f.status, f.note, f.created_at, f.activated_at, f.definition,
                      (SELECT count(*) FROM iam.company_kyc k WHERE k.form_id = f.id) AS files
                 FROM iam.kyc_form f ORDER BY f.version DESC""")]
    for v in versions:
        v["definition"] = _json(v["definition"])
    active = next((v for v in versions if v["status"] == "ACTIVE"), None)
    draft = next((v for v in versions if v["status"] == "DRAFT"), None)
    for v in versions:
        if v is not active and v is not draft:
            v.pop("definition")
    return {"active": active, "draft": draft, "versions": versions}


@platform.put("/kyc/form")
async def form_save(body: FormIn, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.settings")
    async with db.transaction(context_for(request, pr)) as conn:
        version = await _db(conn.fetchval("SELECT iam.save_kyc_form($1::jsonb, $2)", json.dumps(body.definition), body.note))
    request.state.audit = {"action": "kyc.form_save", "object_type": "kyc_form", "object_id": version, "reason": body.note or "-"}
    return {"version": version}


@platform.post("/kyc/form/{version}/activate")
async def form_activate(version: int, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.settings")
    async with db.transaction(context_for(request, pr)) as conn:
        await _db(conn.execute("SELECT iam.activate_kyc_form($1)", version))
    request.state.audit = {"action": "kyc.form_activate", "object_type": "kyc_form", "object_id": version}
    return {"version": version, "status": "ACTIVE"}


async def _settings(conn) -> dict:
    out = {k: _json(await conn.fetchval("SELECT iam.kyc_setting($1)::text", f"kyc.{k}")) for k in SETTINGS}
    out["authorities"] = [row_dict(r) for r in await conn.fetch("SELECT code, name FROM sec.authority_profile ORDER BY code")]
    return out


@platform.get("/kyc/settings")
async def settings(request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.view", "kyc.settings")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _settings(conn)


@platform.put("/kyc/settings/{key}")
async def set_setting(key: str, body: SettingIn, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.settings")
    if key not in SETTINGS or not re.fullmatch(r"[a-z_]{3,40}", key):
        raise ApiError(422, "INVALID_SETTING", "unknown setting")
    async with db.transaction(context_for(request, pr)) as conn:
        await _db(conn.execute("SELECT iam.set_kyc_setting($1, $2::jsonb)", f"kyc.{key}", json.dumps(body.value)))
        out = await _settings(conn)
    request.state.audit = {"action": "kyc.setting", "object_type": "setting", "reason": f"kyc.{key} = {json.dumps(body.value)}"[:300]}
    return out


async def _platform_file(conn, pr: Principal, uid: uuid.UUID, authorities: list[str]) -> dict:
    d = await _file(conn, uid)
    w = _waiting_for(d)
    if "kyc.view" not in pr.permissions and not (w and w.get("authority") in authorities):
        raise not_found("KYC file")
    return d


@platform.get("/kyc/{kyc_uid}")
async def kyc_file(kyc_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        authorities = await _reader(conn, pr)
        d = await _platform_file(conn, pr, kyc_uid, authorities)
        company = row_dict(await conn.fetchrow(
            """SELECT p.uid, p.legal_name AS name, iam.logo_version(c.id) AS logo, c.company_type, c.approval_status
                 FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE c.id = $1""", d["company_id"]))
        decisions = [row_dict(r) for r in await conn.fetch(
            """SELECT dc.round, dc.step, dc.stage, dc.decision, dc.note, dc.fields, dc.risk_override, dc.decided_at,
                      pp.legal_name AS decided_by, a.code AS authority
                 FROM iam.kyc_decision dc JOIN iam.app_user u ON u.id = dc.decided_by JOIN iam.party pp ON pp.id = u.party_id
                 LEFT JOIN sec.authority_profile a ON a.id = dc.authority_id
                WHERE dc.kyc_id = $1 ORDER BY dc.round, dc.step""", d["id"])]
        for x in decisions:
            x["stage"] = _json(x["stage"])
        versions = [row_dict(r) for r in await conn.fetch(
            """SELECT uid, version, status, submitted_at, approved_at, review_due, coalesce(risk_override, risk_level) AS risk_level
                 FROM iam.company_kyc WHERE company_id = $1 ORDER BY version DESC""", d["company_id"])]
        w = _waiting_for(d)
        out = {k: v for k, v in d.items() if k not in ("id", "company_id", "form_id")}
        out.update(company=company, decisions=decisions, versions=versions, waiting_for=w,
                   may_decide=bool(w) and await conn.fetchval("SELECT iam.may_decide_kyc_stage($1::jsonb)", json.dumps(w)),
                   documents=await _documents(conn, d["company_id"], d["definition"]),
                   missing=await _missing(conn, d) if d["status"] in ("DRAFT", "RETURNED") else [],
                   ubo_threshold_pct=_json(await conn.fetchval("SELECT iam.kyc_setting('kyc.ubo_threshold_pct')::text")))
        await conn.execute(
            """INSERT INTO audit.data_access_log (user_id, company_id, ip, object_type, object_id, fields, purpose, request_id)
               VALUES ($1, $2, $3::inet, 'company_kyc', $4, ARRAY['answers'], 'KYC_REVIEW', $5)""",
            pr.user_id, d["company_id"], ctx.ip, d["id"], ctx.request_id)
    return out


@platform.post("/kyc/companies/{company_uid}/open")
async def platform_open(company_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    """Platform staff open a company's file to capture it from its paper form."""
    _need(pr, "kyc.capture")
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await conn.fetchval("SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", company_uid)
        if cid is None:
            raise not_found("company")
        uid = await _db(conn.fetchval("SELECT iam.open_company_kyc($1)", cid))
        kid = await conn.fetchval("SELECT id FROM iam.company_kyc WHERE uid = $1", uid)
    request.state.audit = {"action": "kyc.open", "object_type": "company_kyc", "object_id": kid}
    return {"uid": str(uid)}


@platform.put("/kyc/{kyc_uid}")
async def platform_save(kyc_uid: uuid.UUID, body: AnswersIn, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.capture")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _save(conn, request, pr, await _file(conn, kyc_uid), body.answers)


@platform.post("/kyc/{kyc_uid}/submit")
async def platform_submit(kyc_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "kyc.capture")
    async with db.transaction(context_for(request, pr)) as conn:
        return await _submit(conn, request, await _file(conn, kyc_uid))


@platform.post("/kyc/{kyc_uid}/decide")
async def platform_decide(kyc_uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(staff)):
    """One stage's decision; the database checks who decides which stage and that one person decides one stage."""
    async with db.transaction(context_for(request, pr)) as conn:
        authorities = await _reader(conn, pr)
        d = await _platform_file(conn, pr, kyc_uid, authorities)
        out = _json(await _db(conn.fetchval("SELECT iam.decide_company_kyc($1, $2, $3, $4::text[], $5)::text", kyc_uid,
                                            body.decision, body.note, body.fields, body.risk_level)))
    request.state.audit = {"action": "kyc.decide", "object_type": "company_kyc", "object_id": d["id"],
                           "reason": f"{body.decision.lower()}{f' ({body.risk_level})' if body.risk_level else ''}"
                                     f"{f': {body.note}' if body.note else ''}"[:300]}
    return out


@platform.post("/kyc/{kyc_uid}/reveal")
async def platform_reveal(kyc_uid: uuid.UUID, body: RevealIn, request: Request, pr: Principal = Depends(staff)):
    """One identity document or account number in clear, for the review, with the reason; recorded twice: the policy
    decision and the data access log."""
    _need(pr, "kyc.view")
    ctx = context_for(request, pr)
    await policy.authorize(ctx, "iam.company_kyc.answers", "READ", "KYC_REVIEW", body.reason, "kyc.view")
    async with db.transaction(ctx) as conn:
        d = await _file(conn, kyc_uid)
        fc = await crypto.cipher(conn)
        try:
            value = service.reveal(d["definition"], d["answers"], d["company_id"], body.path, fc)
        except LookupError as exc:
            raise not_found("encrypted value") from exc
        await conn.execute(
            """INSERT INTO audit.data_access_log (user_id, company_id, ip, object_type, object_id, fields, purpose, request_id)
               VALUES ($1, $2, $3::inet, 'company_kyc', $4, ARRAY[$5], $6, $7)""",
            pr.user_id, d["company_id"], ctx.ip, d["id"], body.path, f"KYC_REVIEW: {body.reason}", ctx.request_id)
    request.state.audit = {"action": "kyc.reveal", "object_type": "company_kyc", "object_id": d["id"], "reason": f"{body.path}: {body.reason}"[:300]}
    return {"path": body.path, "value": value}
