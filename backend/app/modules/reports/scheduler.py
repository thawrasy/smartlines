"""Scheduled reports: the outbox worker calls run_due() between events.

Each due schedule runs with its owner's rights as they are now (portal, company, roles and permissions read again
at run time), so a report never outlives the access of the person who scheduled it: when the owner lost the
permission or the account is no longer active, the schedule is switched off instead of being sent.
"""
import asyncio
import logging
import uuid
from datetime import date, datetime, timedelta, timezone

from ... import db
from ...deps import PORTAL_SCOPE
from ..notify import providers
from . import engine, export
from .api import as_dict, next_run, recipients_not_allowed

log = logging.getLogger("masslak.reports")

PERIOD_DAYS = {"DAILY": 1, "WEEKLY": 7, "MONTHLY": 31}


async def _viewer(conn, s) -> engine.Viewer | None:
    user = await conn.fetchrow("SELECT u.id, u.party_id, p.legal_name FROM iam.app_user u JOIN iam.party p ON p.id = u.party_id "
                               "WHERE u.id = $1 AND u.status = 'ACTIVE'", s["owner_user_id"])
    if user is None:
        return None
    perms: set[str] = set()
    roles: set[str] = set()
    if s["portal"] == "PLATFORM":
        rows = await conn.fetch(
            """SELECT r.code, rp.permission_code FROM iam.user_role ur JOIN iam.role r ON r.id = ur.role_id
                 LEFT JOIN iam.role_permission rp ON rp.role_id = r.id
                WHERE ur.user_id = $1 AND (ur.valid_to IS NULL OR ur.valid_to > now())""", user["id"])
    else:
        rows = await conn.fetch(
            """SELECT r.code, rp.permission_code, m.is_owner FROM iam.company_member m LEFT JOIN iam.role r ON r.id = m.role_id
                 LEFT JOIN iam.role_permission rp ON rp.role_id = r.id
                WHERE m.user_id = $1 AND m.company_id = $2 AND m.status = 'ACTIVE'""", user["id"], s["company_id"])
        if not rows:
            return None
        if any(r["is_owner"] for r in rows):
            perms |= {p["code"] for p in await conn.fetch("SELECT code FROM iam.permission WHERE scope IN ('COMPANY','BOTH')")}
    for r in rows:
        if r["code"]:
            roles.add(r["code"])
        if r["permission_code"]:
            perms.add(r["permission_code"])
    need = "report.platform" if s["portal"] == "PLATFORM" else "report.company"
    if need not in perms or "report.schedule" not in perms:
        return None
    v = engine.Viewer(s["portal"], s["company_id"], perms, roles)
    v.user_id, v.party_id, v.name = user["id"], user["party_id"], user["legal_name"]     # for the run context and the e-mail
    return v


async def run_one(schedule_id: int) -> bool:
    """Runs one due schedule under its owner's context. Returns whether a report was sent."""
    sys_ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(sys_ctx) as conn:
        s = await conn.fetchrow("SELECT * FROM rpt.report_schedule WHERE id = $1 AND active AND next_run_at <= now() FOR UPDATE SKIP LOCKED",
                                schedule_id)
        if s is None:
            return False
        v = await _viewer(conn, s)
        if v is None:
            await conn.execute("UPDATE rpt.report_schedule SET active = false WHERE id = $1", s["id"])
            log.info("reports.schedule_stopped id=%s (owner no longer allowed)", s["id"])
            return False
        definition = None
        if s["definition_id"]:
            definition = await conn.fetchrow("SELECT dataset, spec, name, status FROM rpt.report_definition WHERE id = $1", s["definition_id"])
            if definition is None or definition["status"] != "ACTIVE":
                await conn.execute("UPDATE rpt.report_schedule SET active = false WHERE id = $1", s["id"])
                return False
        # recipients are checked again at every run: someone who left the company stops receiving the report
        refused = set(await recipients_not_allowed(conn, s["portal"], s["company_id"], list(s["recipients"])))
        recipients = [e for e in s["recipients"] if e.lower() not in refused]
        if refused:
            log.info("reports.recipients_dropped id=%s count=%s", s["id"], len(refused))
        if not recipients:
            await conn.execute("UPDATE rpt.report_schedule SET active = false WHERE id = $1", s["id"])
            log.info("reports.schedule_stopped id=%s (no allowed recipient left)", s["id"])
            return False
        await conn.execute("UPDATE rpt.report_schedule SET next_run_at = $2, last_run_at = now() WHERE id = $1",
                           s["id"], next_run(s["frequency"], datetime.now(timezone.utc)))

    # the report itself runs with the owner's row-level security
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", user_id=v.user_id, party_id=v.party_id, company_id=v.company_id,
                     scope=PORTAL_SCOPE.get(s["portal"], "PASSENGER"))
    today = date.today()
    params = {"from": today - timedelta(days=PERIOD_DAYS[s["frequency"]]), "to": today - timedelta(days=1)}
    loc = s["locale"] if s["locale"] in ("ar", "en") else "ar"
    async with db.transaction(ctx) as conn:
        if definition:
            dataset, spec, code, title = definition["dataset"], as_dict(definition["spec"]), "custom." + definition["dataset"], definition["name"]
        else:
            r = engine.resolve(s["report_code"], v)
            dataset, spec, code = r.dataset, r.spec, r.code
            title = export.words(loc).get("titles", {}).get(r.code, {}).get("title", r.code)
            if not r.period:
                params = {"all_time": True}
        limit = engine.PDF_ROWS if s["format"] == "PDF" else engine.EXPORT_ROWS
        res = await engine.run(conn, v, dataset=dataset, spec=spec, params=params, limit=limit)
        period = export.words(loc).get("all_time", "") if params.get("all_time") else f"{params['from']} → {params['to']}"
        meta = export.Meta(code, title, period, v.name, datetime.now(timezone.utc), loc)
        data, digest = export.render(s["format"], res, meta)
        import json
        await conn.execute(
            """INSERT INTO rpt.report_run (report_code, definition_id, user_id, company_id, portal, params, format, row_count, sha256, duration_ms)
               VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9, $10)""",
            None if s["definition_id"] else code, s["definition_id"], v.user_id, v.company_id, s["portal"],
            json.dumps({**params, "schedule": str(s["uid"])}, default=str), s["format"], len(res.rows), bytes.fromhex(digest), res.duration_ms)
    w = export.words(loc)
    subject = w.get("email_subject", "Masslak report: {title}").replace("{title}", title)
    body = (w.get("email_body", "{title}").replace("{title}", title).replace("{period}", period).replace("{rows}", str(len(res.rows)))
            .replace("{owner}", v.name).replace("{frequency}", w.get("frequency", {}).get(s["frequency"], s["frequency"])))
    name = f"masslak-{code}-{today:%Y%m%d}.{export.EXT[s['format']]}".replace("/", "-")
    for to in recipients:
        await asyncio.to_thread(providers.send_email, to, subject, body, ((name, export.MIME[s["format"]], data),))
    log.info("reports.schedule_sent id=%s rows=%s recipients=%s", s["id"], len(res.rows), len(recipients))
    return True


async def run_due(limit: int = 10) -> int:
    async with db.transaction(db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")) as conn:
        ids = [r["id"] for r in await conn.fetch(
            "SELECT id FROM rpt.report_schedule WHERE active AND next_run_at <= now() ORDER BY next_run_at LIMIT $1", limit)]
    sent = 0
    for i in ids:
        try:
            sent += await run_one(i)
        except Exception as exc:                      # one broken schedule never blocks the others
            log.warning("reports.schedule_failed id=%s: %s", i, exc)
    return sent
