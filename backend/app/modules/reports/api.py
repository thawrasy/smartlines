"""Reports API: /api/reports. The catalog, previews, exports in five formats, custom reports and schedules.

Platform staff need report.platform, company and agency staff report.company (owners hold every company permission).
Building custom reports needs report.custom and scheduling report.schedule. Every preview and export is written to
rpt.report_run with its parameters, row count and the file's SHA-256.
"""
import json
import re
import uuid
from datetime import date, datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field, field_validator

from ... import db, markets, release
from ...deps import Principal, context_for, require_user
from ...errors import ApiError, forbidden, not_found
from . import engine, export, freshness
from .datasets import DATASETS

router = APIRouter(prefix="/api/reports", tags=["reports"])
PORTALS = {"PLATFORM", "OPERATOR", "AGENCY"}


def viewer(pr: Principal) -> engine.Viewer:
    if pr.portal not in PORTALS:
        raise forbidden("reports are for staff portals")
    need = "report.platform" if pr.portal == "PLATFORM" else "report.company"
    if need not in pr.permissions:
        raise forbidden(f"missing permission: {need}")
    return engine.Viewer(pr.portal, pr.company_id, pr.permissions, pr.roles)


def locale_of(request: Request, pr: Principal, wanted: Optional[str]) -> str:
    loc = wanted or pr.locale or "ar"
    return loc if loc in ("ar", "en") else "en"


class Params(BaseModel):
    period_from: Optional[date] = Field(default=None, alias="from")
    period_to: Optional[date] = Field(default=None, alias="to")
    all_time: bool = False
    filters: list = Field(default_factory=list, max_length=20)
    market: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}$")   # platform reports: the market to read (1061)

    model_config = {"populate_by_name": True}

    def as_dict(self) -> dict:
        return {"from": self.period_from, "to": self.period_to, "all_time": self.all_time, "filters": self.filters,
                "market": self.market}


class Spec(BaseModel):
    columns: list[str] = Field(default_factory=list, max_length=30)
    filters: list = Field(default_factory=list, max_length=20)
    group_by: list[str] = Field(default_factory=list, max_length=4)
    totals: list = Field(default_factory=list, max_length=8)
    sort: list = Field(default_factory=list, max_length=4)


class RunIn(BaseModel):
    code: Optional[str] = Field(default=None, max_length=60)          # a catalog report
    definition: Optional[uuid.UUID] = None                              # a saved custom report
    dataset: Optional[str] = Field(default=None, max_length=40)       # an unsaved custom report
    spec: Optional[Spec] = None
    params: Params = Field(default_factory=Params)
    locale: Optional[Literal["ar", "en"]] = None


class ExportIn(RunIn):
    format: Literal["PDF", "XLSX", "CSV", "TXT", "JSON"]


async def _resolve(conn, v: engine.Viewer, pr: Principal, body: RunIn) -> tuple[str, dict, dict, str, Optional[int]]:
    """(dataset, spec, params, report code or 'custom', definition id)."""
    params = body.params.as_dict()
    if body.code:
        r = engine.resolve(body.code, v)
        if not r.period:
            params["all_time"] = True
        return r.dataset, r.spec, params, r.code, None
    if body.definition:
        row = await conn.fetchrow("SELECT id, dataset, spec, name FROM rpt.report_definition WHERE uid = $1 AND status = 'ACTIVE'",
                                  body.definition)
        if row is None:
            raise not_found("report")
        return row["dataset"], as_dict(row["spec"]), params, "custom", row["id"]
    if body.dataset and body.spec:
        if "report.custom" not in v.permissions:
            raise forbidden("missing permission: report.custom")
        return body.dataset, body.spec.model_dump(), params, "custom", None
    raise ApiError(422, "REPORT_BAD_SPEC", "name a report, a saved definition, or a dataset with a spec")


async def _log(conn, pr: Principal, code: str, definition_id: Optional[int], params: dict, fmt: str, rows: int,
               digest: Optional[str], ms: int) -> None:
    await conn.execute(
        """INSERT INTO rpt.report_run (report_code, definition_id, user_id, company_id, portal, params, format, row_count, sha256, duration_ms)
           VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, $10)""",
        None if definition_id else (code if code != "custom" else "custom.adhoc"), definition_id, pr.user_id, pr.company_id,
        pr.portal, _json(params), fmt, rows, bytes.fromhex(digest) if digest else None, ms)


def _json(d: dict) -> str:
    import json
    return json.dumps(d, default=str)


def as_dict(v) -> dict:
    """jsonb arrives as text from asyncpg unless a codec is set."""
    import json
    return json.loads(v) if isinstance(v, str) else dict(v or {})


def _period_text(params: dict, locale: str) -> str:
    if params.get("all_time"):
        return export.words(locale).get("all_time", "All records")
    today = date.today()
    d_from = params.get("from") or (today - timedelta(days=30))
    d_to = params.get("to") or today
    return f"{d_from} → {d_to}"


def _title(code: str, definition_name: Optional[str], locale: str) -> str:
    if definition_name:
        return definition_name
    w = export.words(locale)
    return w.get("titles", {}).get(code, {}).get("title") or w.get("custom", "Custom report")


@router.get("/catalog")
async def catalog(request: Request, locale: Optional[str] = None, pr: Principal = Depends(require_user)):
    v = viewer(pr)
    loc = locale_of(request, pr, locale)
    w = export.words(loc)
    reports = [{
        "code": r.code, "category": engine.category(r.code), "dataset": r.dataset, "aggregate": r.aggregate, "chart": r.chart,
        "period": r.period, "title": w.get("titles", {}).get(r.code, {}).get("title", r.code),
        "description": w.get("titles", {}).get(r.code, {}).get("description", ""), "spec": r.spec,
    } for r in engine.visible_reports(v)]
    datasets = []
    if "report.custom" in v.permissions:
        hidden = v.regulator_only
        for ds in DATASETS.values():
            if not engine.can_read(ds, v):
                continue
            datasets.append({"key": ds.key, "category": ds.category, "date_col": ds.date_col,
                             "title": w.get("categories", {}).get(ds.category, ds.category),
                             "columns": [{"key": c.key, "label": w.get("columns", {}).get(c.key, c.key), "type": c.type, "group": c.group,
                                          "filter": c.filter, "agg": c.agg, "values": c.values}
                                         for c in ds.columns if not (hidden and c.personal)]})
    async with db.transaction(context_for(request, pr)) as conn:
        saved = await conn.fetch(
            """SELECT uid, name, description, dataset, spec, shared, owner_user_id = $1 AS mine, updated_at
                 FROM rpt.report_definition WHERE status = 'ACTIVE' AND audience = $2 ORDER BY name""",
            pr.user_id, "PLATFORM" if pr.portal == "PLATFORM" else "COMPANY")
    return {"reports": reports, "datasets": datasets, "categories": w.get("categories", {}),
            "saved": [{**dict(s), "uid": str(s["uid"]), "spec": as_dict(s["spec"])} for s in saved],
            "can_custom": "report.custom" in v.permissions, "can_schedule": "report.schedule" in v.permissions}


async def _execute(request: Request, pr: Principal, v: engine.Viewer, body: RunIn, limit: int):
    """Resolves the report, runs it (audit datasets through the audit connection) and returns what the log needs."""
    source = await release.source_version()      # before the report's own connection is taken (cached for a minute)
    async with db.reports_transaction(context_for(request, pr)) as conn:
        dataset, spec, params, code, def_id = await _resolve(conn, v, pr, body)
        await engine.locate(conn, v, params.get("market") if isinstance(params, dict) else None)
        name = await conn.fetchval("SELECT name FROM rpt.report_definition WHERE id = $1", def_id) if def_id else None
        if DATASETS.get(dataset) is None or DATASETS[dataset].reader == "app":
            fresh = await freshness.check(dataset, spec, conn)    # a financial report on a stale replica stops here
            res = await engine.run(conn, v, dataset=dataset, spec=spec, params=params, limit=limit)
            res.data_as_of = await db.data_as_of(conn)
            res.freshness = fresh
            res.source_version = source
            return res, dataset, params, code, def_id, name
    async with db.audit_reader() as aconn:
        res = await engine.run(aconn, v, dataset=dataset, spec=spec, params=params, limit=limit)
        res.data_as_of = await db.data_as_of(aconn)
    res.source_version = source
    return res, dataset, params, code, def_id, name


@router.post("/run")
async def run(body: RunIn, request: Request, pr: Principal = Depends(require_user)):
    v = viewer(pr)
    loc = locale_of(request, pr, body.locale)
    res, dataset, params, code, def_id, _ = await _execute(request, pr, v, body, engine.PREVIEW_ROWS)
    async with db.transaction(context_for(request, pr)) as conn:
        await _log(conn, pr, code, def_id, params, "PREVIEW", len(res.rows), None, res.duration_ms)
    return {
        "dataset": dataset, "code": code, "truncated": res.truncated, "duration_ms": res.duration_ms,
        "columns": [{"key": c.key, "label": export.label(c, loc), "type": c.type, "values": c.values, "agg": c.agg} for c in res.columns],
        "rows": [{c.key: _plain(r[c.key]) for c in res.columns} for r in res.rows],
        "labels": {c.key: _value_labels(c.values, loc) for c in res.columns if c.values},
        "totals": {k: _plain(v) for k, v in res.totals.items()},
        "period": _period_text(params, loc),
        "freshness": res.freshness,
        **export.provenance(res),
    }


def _plain(v):
    from decimal import Decimal
    if isinstance(v, Decimal):
        return float(v)
    if isinstance(v, (datetime, date)):
        return v.isoformat()
    return v


def _value_labels(group: str, loc: str) -> dict:
    from ..notify.render import messages
    w = messages(loc)
    return w.get("reports", {}).get("values", {}).get(group) or w.get(group) or {}


@router.post("/export")
async def export_file(body: ExportIn, request: Request, pr: Principal = Depends(require_user)):
    v = viewer(pr)
    loc = locale_of(request, pr, body.locale)
    limit = engine.PDF_ROWS if body.format == "PDF" else engine.EXPORT_ROWS
    res, dataset, params, code, def_id, name = await _execute(request, pr, v, body, limit)
    meta = export.Meta(code if code != "custom" else f"custom.{dataset}", _title(code, name, loc), _period_text(params, loc),
                       pr.display_name, datetime.now(timezone.utc), loc)
    data, digest = export.render(body.format, res, meta)
    async with db.transaction(context_for(request, pr)) as conn:
        await _log(conn, pr, code, def_id, params, body.format, len(res.rows), digest, res.duration_ms)
    request.state.audit = {"action": "report.export", "object_type": "report", "object_id": None}
    safe = re.sub(r"[^A-Za-z0-9_.-]+", "-", meta.code)
    filename = f"masslak-{safe}-{date.today():%Y%m%d}.{export.EXT[body.format]}"
    return Response(content=data, media_type=export.MIME[body.format], headers={
        "Content-Disposition": f'attachment; filename="{filename}"', "X-Report-Rows": str(len(res.rows)),
        "X-Report-Truncated": "1" if res.truncated else "0", "X-Report-SHA256": digest,
        "Access-Control-Expose-Headers": "Content-Disposition, X-Report-Rows, X-Report-Truncated, X-Report-SHA256"})


# ------------------------------------------------------------------ custom reports
class DefinitionIn(BaseModel):
    name: str = Field(min_length=3, max_length=120)
    description: Optional[str] = Field(default=None, max_length=500)
    dataset: str = Field(pattern=r"^[a-z_]{3,40}$")
    spec: Spec
    shared: bool = False


@router.post("/definitions", status_code=201)
async def create_definition(body: DefinitionIn, request: Request, pr: Principal = Depends(require_user)):
    v = viewer(pr)
    if "report.custom" not in v.permissions:
        raise forbidden("missing permission: report.custom")
    ds = DATASETS.get(body.dataset)
    if ds is None or not engine.can_read(ds, v):
        raise ApiError(403, "REPORT_NOT_ALLOWED", "dataset not available")
    engine.build(ds, body.spec.model_dump(), v, {"all_time": True}, 1)        # refuses an invalid spec before it is saved
    async with db.transaction(context_for(request, pr)) as conn:
        uid = await conn.fetchval(
            """INSERT INTO rpt.report_definition (company_id, owner_user_id, audience, name, description, dataset, spec, shared)
               VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, $8) RETURNING uid""",
            None if pr.portal == "PLATFORM" else pr.company_id, pr.user_id, "PLATFORM" if pr.portal == "PLATFORM" else "COMPANY",
            body.name.strip(), body.description, body.dataset, _json(body.spec.model_dump()), body.shared)
    request.state.audit = {"action": "report.definition.create", "object_type": "report_definition", "object_id": None}
    return {"uid": str(uid)}


@router.put("/definitions/{uid}")
async def update_definition(uid: uuid.UUID, body: DefinitionIn, request: Request, pr: Principal = Depends(require_user)):
    v = viewer(pr)
    if "report.custom" not in v.permissions:
        raise forbidden("missing permission: report.custom")
    ds = DATASETS.get(body.dataset)
    if ds is None or not engine.can_read(ds, v):
        raise ApiError(403, "REPORT_NOT_ALLOWED", "dataset not available")
    engine.build(ds, body.spec.model_dump(), v, {"all_time": True}, 1)
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval(
            """UPDATE rpt.report_definition SET name = $3, description = $4, dataset = $5, spec = $6::jsonb, shared = $7
                WHERE uid = $1 AND owner_user_id = $2 AND status = 'ACTIVE' RETURNING id""",
            uid, pr.user_id, body.name.strip(), body.description, body.dataset, _json(body.spec.model_dump()), body.shared)
    if not done:
        raise not_found("report")
    return {"ok": True}


@router.delete("/definitions/{uid}")
async def archive_definition(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_user)):
    viewer(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval("UPDATE rpt.report_definition SET status = 'ARCHIVED' WHERE uid = $1 AND owner_user_id = $2 RETURNING id",
                                   uid, pr.user_id)
    if not done:
        raise not_found("report")
    return {"ok": True}


# ------------------------------------------------------------------ schedules
class ScheduleIn(BaseModel):
    code: Optional[str] = Field(default=None, max_length=60)
    definition: Optional[uuid.UUID] = None
    frequency: Literal["DAILY", "WEEKLY", "MONTHLY"]
    format: Literal["PDF", "XLSX", "CSV", "TXT"]
    locale: Literal["ar", "en"] = "ar"
    # checked against the accounts of the company (or the platform's domains), so the format check stays simple
    recipients: list[str] = Field(min_length=1, max_length=10)
    # a report with personal or money columns needs the owner's explicit consent to be sent at all (audit T3-05)
    confirm_sensitive: bool = False

    @field_validator("recipients")
    @classmethod
    def _emails(cls, v: list[str]) -> list[str]:
        if any(not EMAIL.match(e.strip()) for e in v):
            raise ValueError("REPORT_RECIPIENT_INVALID: give e-mail addresses")
        return [e.strip().lower() for e in v]


def next_run(frequency: str, after: datetime, time_zone: str) -> datetime:
    """06:00 in the owner's market (1061) on the next day, Monday or first of the month."""
    from zoneinfo import ZoneInfo
    tz = ZoneInfo(time_zone)
    local = after.astimezone(tz)
    base = local.replace(hour=6, minute=0, second=0, microsecond=0)
    if frequency == "DAILY":
        nxt = base + timedelta(days=1) if base <= local else base
    elif frequency == "WEEKLY":
        nxt = base + timedelta(days=(7 - base.weekday()) % 7 or 7)
    else:
        nxt = (base.replace(day=1) + timedelta(days=32)).replace(day=1)
    return nxt.astimezone(timezone.utc)


EMAIL = re.compile(r"^[^@\s]{1,64}@[^@\s]+\.[^@\s]{2,}$")


async def recipients_not_allowed(conn, portal: str, company_id: Optional[int], emails: list[str], accounts_only: bool = False) -> list[str]:
    """A scheduled report goes only to approved identities (audit T3-05): active members of the owner's company, or for
    platform reports active platform accounts and the platform's own mail domains (setting reports.platform_recipient_domains)."""
    emails = [e.lower() for e in emails]
    if portal == "PLATFORM":
        known = {r["email"] for r in await conn.fetch(
            """SELECT lower(u.email) AS email FROM iam.app_user u WHERE u.status = 'ACTIVE' AND lower(u.email) = ANY($1::text[])
                 AND EXISTS (SELECT 1 FROM iam.user_role ur WHERE ur.user_id = u.id AND (ur.valid_to IS NULL OR ur.valid_to > now()))""",
            emails)}
        domains = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'reports.platform_recipient_domains'")
        domains = {d.lower() for d in (json.loads(domains) if isinstance(domains, str) else (domains or []))}
        # a sensitive report goes to named platform accounts only, never to a whole domain
        return [e for e in emails if e not in known and (accounts_only or e.rsplit("@", 1)[-1] not in domains)]
    known = {r["email"] for r in await conn.fetch(
        """SELECT lower(u.email) AS email FROM iam.app_user u JOIN iam.company_member m ON m.user_id = u.id
            WHERE u.status = 'ACTIVE' AND m.company_id = $1 AND m.status = 'ACTIVE' AND lower(u.email) = ANY($2::text[])""",
        company_id, emails)}
    return [e for e in emails if e not in known]


@router.get("/schedules")
async def schedules(request: Request, pr: Principal = Depends(require_user)):
    viewer(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT s.uid, s.report_code, d.uid AS definition, d.name AS definition_name, s.frequency, s.format, s.locale, s.recipients,
                      s.next_run_at, s.last_run_at, s.active
                 FROM rpt.report_schedule s LEFT JOIN rpt.report_definition d ON d.id = s.definition_id
                WHERE s.owner_user_id = $1 ORDER BY s.created_at DESC""", pr.user_id)
    return {"schedules": [{**dict(r), "uid": str(r["uid"]), "definition": str(r["definition"]) if r["definition"] else None,
                           "recipients": list(r["recipients"])} for r in rows]}


@router.post("/schedules", status_code=201)
async def create_schedule(body: ScheduleIn, request: Request, pr: Principal = Depends(require_user)):
    v = viewer(pr)
    if "report.schedule" not in v.permissions:
        raise forbidden("missing permission: report.schedule")
    async with db.transaction(context_for(request, pr)) as conn:
        def_id = None
        if body.code:
            r = engine.resolve(body.code, v)
            sensitive = engine.sensitive(DATASETS[r.dataset], r.spec)
        elif body.definition:
            d = await conn.fetchrow("SELECT id, dataset, spec FROM rpt.report_definition WHERE uid = $1 AND status = 'ACTIVE'", body.definition)
            if not d:
                raise not_found("report")
            def_id = d["id"]
            sensitive = engine.sensitive(DATASETS[d["dataset"]], as_dict(d["spec"]))
        else:
            raise ApiError(422, "REPORT_BAD_SPEC", "name a report or a saved definition")
        if sensitive and not body.confirm_sensitive:
            raise ApiError(422, "REPORT_CONSENT_REQUIRED", "this report holds personal or financial data: confirm that it may be "
                           "sent; it goes by a link valid for a few days, to named accounts only", sensitive=True)
        async with db.system_scope(conn, context_for(request, pr)):
            refused = await recipients_not_allowed(conn, pr.portal, pr.company_id, body.recipients, accounts_only=sensitive)
        if refused:
            raise ApiError(422, "REPORT_RECIPIENT_NOT_ALLOWED",
                           "reports go only to members of your company (or the platform's own addresses)", recipients=refused)
        n = await conn.fetchval("SELECT count(*) FROM rpt.report_schedule WHERE owner_user_id = $1 AND active", pr.user_id)
        if n >= 20:
            raise ApiError(409, "REPORT_SCHEDULE_LIMIT", "at most 20 active schedules")
        uid = await conn.fetchval(
            """INSERT INTO rpt.report_schedule (report_code, definition_id, owner_user_id, company_id, portal, frequency, format, locale,
                                                recipients, next_run_at, sensitive, consent_by, consent_at)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, CASE WHEN $11 THEN $3::bigint END, CASE WHEN $11 THEN now() END)
               RETURNING uid""",
            body.code if not def_id else None, def_id, pr.user_id, pr.company_id, pr.portal, body.frequency, body.format, body.locale,
            body.recipients, next_run(body.frequency, datetime.now(timezone.utc), (await markets.of_party(conn, pr.company_id)).time_zone),
            sensitive)
    request.state.audit = {"action": "report.schedule.create", "object_type": "report_schedule", "object_id": None}
    return {"uid": str(uid), "sensitive": sensitive}


@router.delete("/schedules/{uid}")
async def stop_schedule(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_user)):
    viewer(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval("UPDATE rpt.report_schedule SET active = false WHERE uid = $1 AND owner_user_id = $2 RETURNING id",
                                   uid, pr.user_id)
    if not done:
        raise not_found("schedule")
    return {"ok": True}


# ------------------------------------------------------------------ links to sensitive scheduled reports (audit T3-05)
@router.get("/deliveries/{token}")
async def download_delivery(token: str, request: Request, pr: Principal = Depends(require_user)):
    """The recipient, signed in, downloads a sensitive report sent by link. Each download is counted and logged; the link
    stops working when it expires, when it is revoked, or when the recipient no longer belongs to the owner's company."""
    import hashlib

    from ... import crypto
    from ..documents import storage
    if len(token) > 100:
        raise not_found("report")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        async with db.system_scope(conn, ctx):
            d = await conn.fetchrow(
                """SELECT d.id, d.recipient, d.recipient_user_id, d.expires_at, d.revoked_at, d.file_name, s.portal, s.company_id, s.active,
                          f.storage_key, f.enc_key_id, f.sha256, f.mime_type
                     FROM rpt.report_delivery d JOIN rpt.report_schedule s ON s.id = d.schedule_id JOIN ref.file_object f ON f.id = d.file_id
                    WHERE d.token_hash = $1 FOR UPDATE OF d""", hashlib.sha256(token.encode()).digest())
            # someone else's link reads exactly like a link that does not exist
            if d is None or d["recipient_user_id"] != pr.user_id:
                raise not_found("report")
            if d["revoked_at"] is not None or d["expires_at"] < datetime.now(timezone.utc):
                raise ApiError(410, "REPORT_LINK_EXPIRED", "this link has expired; the next scheduled report brings a new one")
            if await recipients_not_allowed(conn, d["portal"], d["company_id"], [d["recipient"]], accounts_only=True):
                raise ApiError(403, "REPORT_RECIPIENT_NOT_ALLOWED", "you are no longer among the people this report may be sent to")
            await conn.execute(
                """UPDATE rpt.report_delivery SET download_count = download_count + 1, last_downloaded_at = now(),
                          first_downloaded_at = coalesce(first_downloaded_at, now()) WHERE id = $1""", d["id"])
            await conn.execute(
                """INSERT INTO audit.data_access_log (user_id, company_id, ip, object_type, object_id, fields, purpose, request_id)
                   VALUES ($1, $2, $3::inet, 'report_delivery', $4, ARRAY['report'], 'scheduled report download', $5)""",
                pr.user_id, d["company_id"], ctx.ip, d["id"], ctx.request_id)
            fc = await crypto.cipher(conn)
    data = storage.get(fc, d["storage_key"], d["enc_key_id"], bytes(d["sha256"]))
    request.state.audit = {"action": "report.delivery.download", "object_type": "report_delivery", "object_id": d["id"]}
    return Response(content=data, media_type=d["mime_type"],
                    headers={"Content-Disposition": f'attachment; filename="{d["file_name"]}"', "Cache-Control": "no-store",
                             "X-Content-Type-Options": "nosniff"})
