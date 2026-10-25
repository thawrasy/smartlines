"""Regular trips: the carrier asks, the platform (and later the authorities) approve (owner's decision; migration 1117).

    Carrier (the OPERATOR portal; trip.publish)
    GET  /api/carrier/schedules                      its regular trips, its requests, and the rules in force
    POST /api/carrier/schedules/preview              the next days a pattern runs, before asking
    POST /api/carrier/schedules                      a new regular trip (NEW)
    POST /api/carrier/schedules/{uid}/change         a change from a day on (CHANGE): time, days, dates off, end, vehicle, price
    POST /api/carrier/schedules/{uid}/stop           no trips from a day on (STOP)
    POST /api/carrier/schedules/{uid}/pause|resume   no new trips for a while, then again
    POST /api/carrier/schedule-requests/{uid}/withdraw

    Platform (the PLATFORM portal): schedule.approve for the platform's stages; a government authority's members decide
    its stages by membership (sec.authority_member); schedule.settings for the rules and the members
    GET  /api/admin/schedules/requests?status=       the requests, the stage each waits for, the number the platform suggests
    POST /api/admin/schedules/requests/{uid}/decide  {approve, note, number}: the last approval applies it and makes its trips
    GET  /api/admin/schedules/settings               the rules in force and the authorities with their members
    PUT  /api/admin/schedules/settings/{key}         {value}
    POST /api/admin/authorities/{code}/members       {email}
    DELETE /api/admin/authorities/{code}/members/{user_uid}

The database checks what is asked (SCHEDULE_INVALID), the notice (SCHEDULE_NOTICE), who decides which stage
(NOT_YOUR_STAGE), that one person decides one stage (SECOND_PERSON_REQUIRED), the numbers (SERVICE_NUMBER_TAKEN,
NUMBER_NOT_IN_BLOCK, NUMBER_PARITY) and a leg that continues the vehicle's leg before it (ROTATION_INVALID, 1119).
"""
import json
import re
import uuid
from datetime import date, timedelta
from typing import Any, Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, field_validator

from ... import db
from ...deps import Principal, context_for, require_portal, require_step_up
from ...errors import ApiError, forbidden, not_found
from ...util import row_dict
from . import numbers, service

carrier = APIRouter(prefix="/api/carrier", tags=["schedules"])
platform = APIRouter(prefix="/api/admin", tags=["schedules"])
operator = require_portal("OPERATOR")
staff = require_portal("PLATFORM")

HHMM = r"^([01][0-9]|2[0-3]):[0-5][0-9]$"
Recurrence = Literal["DAILY", "WEEKLY", "MONTHLY"]
STATUS = {"NOT_FOUND": 404, "FORBIDDEN": 403, "NOT_YOUR_STAGE": 403, "SCHEDULE_INVALID": 422, "SCHEDULE_NOTICE": 422,
          "NUMBER_NOT_IN_BLOCK": 422, "NUMBER_PARITY": 422, "REASON_REQUIRED": 422, "INVALID_SETTING": 422,
          "SERVICE_NUMBER_TAKEN": 409, "SECOND_PERSON_REQUIRED": 409, "SCHEDULE_DECIDED": 409, "SCHEDULE_REQUEST_OPEN": 409,
          "SCHEDULE_ENDED": 409, "SCHEDULE_STOP_REQUIRED": 409, "TRIP_APPROVAL_REQUIRED": 409, "ROTATION_INVALID": 422}


async def _db(call):
    """What the database refuses, with the status that fits it."""
    try:
        return await call
    except asyncpg.RaiseError as exc:
        code, _, message = str(exc).partition(":")
        if code in STATUS:
            raise ApiError(STATUS[code], code, message.strip() or code) from exc
        raise


def _need(pr: Principal, code: str) -> None:
    if code not in pr.permissions:
        raise forbidden(f"missing permission: {code}")


class Pattern(BaseModel):
    departure_time: str = Field(pattern=HHMM)
    recurrence: Recurrence
    days_of_week: list[int] = Field(default_factory=list, max_length=7)
    days_of_month: list[int] = Field(default_factory=list, max_length=31)
    skip_dates: list[date] = Field(default_factory=list, max_length=400)
    from_date: date
    until_date: Optional[date] = None                   # none: the trip runs until it is stopped

    @field_validator("days_of_week")
    @classmethod
    def _dow(cls, v: list[int]) -> list[int]:
        if any(d < 1 or d > 7 for d in v):
            raise ValueError("days of the week are 1 (Monday) to 7 (Sunday)")
        return sorted(set(v))

    @field_validator("days_of_month")
    @classmethod
    def _dom(cls, v: list[int]) -> list[int]:
        if any(d < 1 or d > 31 for d in v):
            raise ValueError("days of the month are 1 to 31")
        return sorted(set(v))


class ScheduleIn(Pattern):
    route_uid: uuid.UUID
    vehicle_uid: Optional[uuid.UUID] = None
    base_price: int = Field(ge=0, le=10**12)
    trip_type: Literal["SCHEDULED", "SHUTTLE", "INTERNATIONAL", "CARGO", "EXTRA"] = "SCHEDULED"
    direction: Literal["OUTBOUND", "INBOUND"] = "OUTBOUND"
    auto_publish: bool = True
    # picked from the carrier's free numbers (GET /api/carrier/numbers); left out, the default number (1165)
    proposed_number: Optional[int] = Field(default=None, ge=1000, le=9999)
    # the carrier's regular trip whose vehicle runs this one next (1119): this one takes the number after it
    follows_uid: Optional[uuid.UUID] = None
    note: Optional[str] = Field(default=None, max_length=500)


class ChangeIn(BaseModel):
    effective_from: date
    departure_time: Optional[str] = Field(default=None, pattern=HHMM)
    recurrence: Optional[Recurrence] = None
    days_of_week: Optional[list[int]] = Field(default=None, max_length=7)
    days_of_month: Optional[list[int]] = Field(default=None, max_length=31)
    skip_dates: Optional[list[date]] = Field(default=None, max_length=400)
    until_date: Optional[date] = None
    no_end: bool = False                                # true: the changed version runs until it is stopped
    vehicle_uid: Optional[uuid.UUID] = None
    base_price: Optional[int] = Field(default=None, ge=0, le=10**12)
    auto_publish: Optional[bool] = None
    note: Optional[str] = Field(default=None, max_length=500)


class StopIn(BaseModel):
    from_date: date                                     # the first day without the trip
    note: Optional[str] = Field(default=None, max_length=500)


class DecideIn(BaseModel):
    approve: bool
    note: Optional[str] = Field(default=None, max_length=500)
    number: Optional[int] = Field(default=None, ge=1000, le=9999)


class SettingIn(BaseModel):
    value: Any


class MemberIn(BaseModel):
    email: str = Field(min_length=3, max_length=200)


async def _vehicle_id(conn, pr: Principal, vehicle_uid: Optional[uuid.UUID]) -> Optional[int]:
    if vehicle_uid is None:
        return None
    vid = await conn.fetchval("SELECT id FROM fleet.vehicle WHERE uid = $1 AND company_id = $2", vehicle_uid, pr.company_id)
    if vid is None:
        raise not_found("vehicle")
    return vid


def _iso(d: Optional[date]) -> Optional[str]:
    return d.isoformat() if d else None


async def _made(conn, result: Optional[dict]) -> Optional[dict]:
    """After a request is applied, the regular trip's trips are made at once up to the horizon."""
    if not result or not result.get("template_uid"):
        return None
    tid = await conn.fetchval("SELECT id FROM ops.trip_template WHERE uid = $1", uuid.UUID(str(result["template_uid"])))
    return await service.extend(conn, tid) if tid else None


async def _rules(conn) -> dict:
    keys = ("schedule.approval_stages", "schedule.approval_kinds", "schedule.min_notice_days", "schedule.horizon_days",
            "schedule.recurrences", "schedule.min_turnaround_min")
    return {k.split(".", 1)[1]: json.loads(await conn.fetchval("SELECT ops.schedule_setting($1)::text", k)) for k in keys}


# ------------------------------------------------------------------ the carrier
SCHEDULES_SQL = """
    SELECT t.uid, t.status, t.recurrence, t.days_of_week, t.days_of_month, t.skip_dates, to_char(t.departure_time, 'HH24:MI') AS departure_time,
           lower(t.active) AS from_date, upper(t.active) - 1 AS until_date, t.base_price, t.currency, t.trip_type, t.auto_publish,
           t.rolling, t.generated_until, t.last_run, t.approved_at, t.created_at,
           r.uid AS route_uid, r.code AS route_code, so.name AS origin, sd.name AS destination, so.code AS origin_code, sd.code AS dest_code,
           v.uid AS vehicle_uid, v.plate_no, s.number AS service_no, s.direction,
           CASE WHEN s.number IS NOT NULL THEN ops.trip_designator(t.company_id) || ' ' || s.number END AS trip_code,
           CASE WHEN fs.number IS NOT NULL THEN ops.trip_designator(t.company_id) || ' ' || fs.number END AS follows_code,
           (SELECT ops.trip_designator(t.company_id) || ' ' || min(x.number) FROM net.service_number x WHERE x.follows_id = s.id) AS next_code,
           (SELECT min(x.departure_at) FROM ops.trip x WHERE x.template_id = t.id AND x.departure_at > now() AND x.status <> 'CANCELLED') AS next_departure,
           (SELECT count(*) FROM ops.trip x WHERE x.template_id = t.id AND x.departure_at > now() AND x.status <> 'CANCELLED') AS upcoming
      FROM ops.trip_template t JOIN net.route r ON r.id = t.route_id
      JOIN net.station so ON so.id = r.origin_station_id JOIN net.station sd ON sd.id = r.dest_station_id
      LEFT JOIN fleet.vehicle v ON v.id = t.default_vehicle_id LEFT JOIN net.service_number s ON s.id = t.service_number_id
      LEFT JOIN net.service_number fs ON fs.id = s.follows_id"""

REQUESTS_SQL = """
    SELECT q.uid, q.kind, q.status, q.proposal, q.effective_from, q.proposed_number, q.assigned_number, q.note, q.approval_stages,
           q.step, q.requested_at, q.decided_at, q.decision_note, q.result, q.company_id,
           t.uid AS template_uid, tr.uid AS trip_uid, tr.trip_no AS trip_no, tr.trip_code AS trip_code, t.route_id AS schedule_route_id,
           CASE WHEN tsn.number IS NOT NULL THEN ops.trip_designator(q.company_id) || ' ' || tsn.number END AS schedule_code,
           to_char(t.departure_time, 'HH24:MI') AS schedule_time,
           cp.uid AS company_uid, cp.legal_name AS company_name, iam.logo_version(cp.id) AS company_logo,
           rb.legal_name AS requested_by_name,
           coalesce((SELECT jsonb_agg(jsonb_build_object('step', a.step, 'stage', a.stage, 'decision', a.decision,
                                                         'by', dp.legal_name, 'authority', ap.name, 'number', a.assigned_number,
                                                         'note', a.note, 'at', a.decided_at) ORDER BY a.step)
                       FROM ops.schedule_approval a JOIN iam.app_user du ON du.id = a.decided_by JOIN iam.party dp ON dp.id = du.party_id
                       LEFT JOIN sec.authority_profile ap ON ap.id = a.authority_id
                      WHERE a.request_id = q.id), '[]'::jsonb) AS decisions
      FROM ops.schedule_request q JOIN iam.party cp ON cp.id = q.company_id
      JOIN iam.app_user ru ON ru.id = q.requested_by JOIN iam.party rb ON rb.id = ru.party_id
      LEFT JOIN ops.trip_template t ON t.id = q.template_id LEFT JOIN net.service_number tsn ON tsn.id = t.service_number_id
      LEFT JOIN ops.trip tr ON tr.id = q.trip_id"""


def _jsonish(d: dict) -> dict:
    for k in ("proposal", "approval_stages", "result", "decisions", "last_run"):
        if isinstance(d.get(k), str):
            d[k] = json.loads(d[k])
    return d


async def _proposal_labels(conn, d: dict) -> dict:
    """A request names its route and vehicle by id (a change, through its regular trip); the screens show their codes."""
    p = d.get("proposal") or {}
    route_id = p.get("route_id") or d.pop("schedule_route_id", None)
    if route_id:
        r = await conn.fetchrow("""SELECT r.code, so.name AS origin, sd.name AS destination, so.code AS origin_code, sd.code AS dest_code
                                     FROM net.route r JOIN net.station so ON so.id = r.origin_station_id
                                     JOIN net.station sd ON sd.id = r.dest_station_id WHERE r.id = $1""", int(route_id))
        if r:
            d["route"] = dict(r)
    if p.get("vehicle_id"):
        d["plate_no"] = await conn.fetchval("SELECT plate_no FROM fleet.vehicle WHERE id = $1", int(p["vehicle_id"]))
    return d


@carrier.get("/schedules")
async def my_schedules(request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        schedules = [_jsonish(row_dict(r)) for r in await conn.fetch(
            SCHEDULES_SQL + " WHERE t.company_id = $1 AND (t.status <> 'RETIRED' OR t.created_at > now() - interval '90 days')"
                            " ORDER BY (t.status = 'RETIRED'), s.number NULLS LAST, t.departure_time", pr.company_id)]
        requests = [await _proposal_labels(conn, _jsonish(row_dict(r))) for r in await conn.fetch(
            REQUESTS_SQL + " WHERE q.company_id = $1 AND (q.status = 'PENDING' OR q.requested_at > now() - interval '60 days')"
                           " ORDER BY q.requested_at DESC LIMIT 100", pr.company_id)]
        routes = [row_dict(r) for r in await conn.fetch(
            """SELECT r.uid, r.code, so.name AS origin, sd.name AS destination, so.code AS origin_code, sd.code AS dest_code
                 FROM net.route r JOIN net.station so ON so.id = r.origin_station_id JOIN net.station sd ON sd.id = r.dest_station_id
                WHERE r.company_id = $1 AND r.status = 'ACTIVE' ORDER BY r.code""", pr.company_id)]
        vehicles = [row_dict(r) for r in await conn.fetch(
            "SELECT uid, plate_no, passenger_seats FROM fleet.vehicle WHERE company_id = $1 AND status = 'ACTIVE' ORDER BY plate_no",
            pr.company_id)]
        rules = await _rules(conn)
    for r in requests:
        r.pop("company_id", None)
    return {"schedules": schedules, "requests": requests, "routes": routes, "vehicles": vehicles, "rules": rules}


@carrier.post("/schedules/preview")
async def preview(body: Pattern, request: Request, pr: Principal = Depends(operator)):
    """The next days a pattern runs (at most 20), within its period, before the carrier asks for it."""
    _need(pr, "trip.publish")
    until = min(body.until_date or body.from_date + timedelta(days=400), body.from_date + timedelta(days=400))
    async with db.transaction(context_for(request, pr)) as conn:
        days = await conn.fetch("SELECT d FROM ops.recurrence_days($1, $2, $3, $4, $5, $6) d LIMIT 20",
                                body.from_date, until, body.recurrence, body.days_of_week, body.days_of_month, body.skip_dates)
        in_a_month = await conn.fetchval("SELECT count(*) FROM ops.recurrence_days($1, $2, $3, $4, $5, $6)",
                                         body.from_date, min(until, body.from_date + timedelta(days=29)), body.recurrence,
                                         body.days_of_week, body.days_of_month, body.skip_dates)
    return {"dates": [d["d"].isoformat() for d in days], "in_30_days": in_a_month}


async def _ask(conn, kind: str, template_uid=None, trip_uid=None, proposal=None, effective_from=None, number=None, note=None) -> dict:
    out = json.loads(await _db(conn.fetchval(
        "SELECT ops.request_schedule($1, $2, $3, $4::jsonb, $5, $6, $7)::text",
        kind, template_uid, trip_uid, json.dumps(proposal or {}), effective_from, number, note)))
    if out["status"] == "APPROVED":                    # a kind the settings let through: applied at once, trips made
        out["made"] = await _made(conn, out.get("result"))
    out["_id"] = await conn.fetchval("SELECT id FROM ops.schedule_request WHERE uid = $1", uuid.UUID(out["uid"]))
    return out


@carrier.post("/schedules", status_code=201)
async def ask_new(body: ScheduleIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        route_id = await conn.fetchval("SELECT id FROM net.route WHERE uid = $1 AND company_id = $2", body.route_uid, pr.company_id)
        if route_id is None:
            raise not_found("route")
        currency = await conn.fetchval("SELECT ref.company_currency($1)", pr.company_id)
        follows = None
        if body.follows_uid is not None:
            follows = await conn.fetchval(
                """SELECT s.number FROM ops.trip_template t JOIN net.service_number s ON s.id = t.service_number_id
                    WHERE t.uid = $1 AND t.company_id = $2 AND t.status <> 'RETIRED'""", body.follows_uid, pr.company_id)
            if follows is None:
                raise not_found("regular trip")
        proposal = {"route_id": route_id, "vehicle_id": await _vehicle_id(conn, pr, body.vehicle_uid),
                    "departure_time": body.departure_time, "recurrence": body.recurrence, "days_of_week": body.days_of_week,
                    "days_of_month": body.days_of_month, "skip_dates": [d.isoformat() for d in body.skip_dates],
                    "from": body.from_date.isoformat(), "until": _iso(body.until_date), "base_price": body.base_price,
                    "currency": currency, "trip_type": body.trip_type, "direction": body.direction, "auto_publish": body.auto_publish}
        number = None
        if follows is not None:
            proposal["follows"] = follows
        else:
            # every regular trip asks with a number of the carrier's range (1165, N7): the one picked, else the default
            period = asyncpg.Range(body.from_date, (body.until_date + timedelta(days=1)) if body.until_date else None)
            number = body.proposed_number or await conn.fetchval("SELECT ops.suggest_schedule_number($1, $2, $3, $4, $5)",
                                                                 pr.company_id, body.trip_type, body.direction, period, route_id)
            if number is None:
                raise ApiError(409, "NUMBER_RANGE_FULL", "no number of your range is free for this trip; ask the platform for a wider range")
            await numbers.number_problem(conn, pr.company_id, body.trip_type, body.direction, number)
        out = await _ask(conn, "NEW", proposal=proposal, number=number, note=body.note)
    request.state.audit = {"action": "schedule.request", "object_type": "schedule_request", "object_id": out.pop("_id")}
    return out


@carrier.post("/schedules/{schedule_uid}/change", status_code=201)
async def ask_change(schedule_uid: uuid.UUID, body: ChangeIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    changes: dict[str, Any] = {}
    for k in ("departure_time", "recurrence", "days_of_week", "days_of_month", "base_price", "auto_publish"):
        if getattr(body, k) is not None:
            changes[k] = sorted(set(getattr(body, k))) if k.startswith("days_") else getattr(body, k)
    if body.skip_dates is not None:
        changes["skip_dates"] = sorted({d.isoformat() for d in body.skip_dates})
    if body.no_end:
        changes["until"] = None
    elif body.until_date is not None:
        changes["until"] = body.until_date.isoformat()
    async with db.transaction(context_for(request, pr)) as conn:
        if body.vehicle_uid is not None:
            changes["vehicle_id"] = await _vehicle_id(conn, pr, body.vehicle_uid)
        out = await _ask(conn, "CHANGE", template_uid=schedule_uid, proposal=changes, effective_from=body.effective_from, note=body.note)
    request.state.audit = {"action": "schedule.change_request", "object_type": "schedule_request", "object_id": out.pop("_id")}
    return out


@carrier.post("/schedules/{schedule_uid}/stop", status_code=201)
async def ask_stop(schedule_uid: uuid.UUID, body: StopIn, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        out = await _ask(conn, "STOP", template_uid=schedule_uid, effective_from=body.from_date, note=body.note)
    request.state.audit = {"action": "schedule.stop_request", "object_type": "schedule_request", "object_id": out.pop("_id")}
    return out


async def _pause(request: Request, pr: Principal, schedule_uid: uuid.UUID, frm: str, to: str) -> dict:
    _need(pr, "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        done = await _db(conn.fetchval(
            "UPDATE ops.trip_template SET status = $3 WHERE uid = $1 AND company_id = $2 AND status = $4 RETURNING id",
            schedule_uid, pr.company_id, to, frm))
    if done is None:
        raise ApiError(409, "INVALID_TRANSITION", f"only a {frm.lower()} regular trip can be set {to.lower()}")
    request.state.audit = {"action": f"schedule.{to.lower()}", "object_type": "trip_template", "object_id": done}
    return {"ok": True, "status": to}


@carrier.post("/schedules/{schedule_uid}/pause")
async def pause(schedule_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    """No new trips are made while it is paused; those already made stay."""
    return await _pause(request, pr, schedule_uid, "ACTIVE", "PAUSED")


@carrier.post("/schedules/{schedule_uid}/resume")
async def resume(schedule_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    out = await _pause(request, pr, schedule_uid, "PAUSED", "ACTIVE")
    async with db.transaction(context_for(request, pr)) as conn:
        tid = await conn.fetchval("SELECT id FROM ops.trip_template WHERE uid = $1", schedule_uid)
        out["made"] = await service.extend(conn, tid)
    return out


@carrier.post("/schedule-requests/{request_uid}/withdraw")
async def withdraw(request_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    _need(pr, "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        if not await conn.fetchval("SELECT ops.withdraw_schedule_request($1)", request_uid):
            raise ApiError(409, "SCHEDULE_DECIDED", "only a request still waiting is withdrawn")
        rid = await conn.fetchval("SELECT id FROM ops.schedule_request WHERE uid = $1", request_uid)
    request.state.audit = {"action": "schedule.withdraw", "object_type": "schedule_request", "object_id": rid}
    return {"ok": True}


# ------------------------------------------------------------------ the platform and the authorities
async def _member_of(conn, pr: Principal) -> list[str]:
    return [r["code"] for r in await conn.fetch(
        """SELECT a.code FROM sec.authority_member m JOIN sec.authority_profile a ON a.id = m.authority_id
            WHERE m.user_id = $1 ORDER BY a.code""", pr.user_id)]


@platform.get("/schedules/requests")
async def requests_list(request: Request, status: Literal["PENDING", "DECIDED", "ALL"] = "PENDING",
                        pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        authorities = await _member_of(conn, pr)
        if "schedule.approve" not in pr.permissions and not authorities:
            raise forbidden("missing permission: schedule.approve")
        where = {"PENDING": "q.status = 'PENDING'", "DECIDED": "q.status <> 'PENDING'", "ALL": "true"}[status]
        recs = await conn.fetch(REQUESTS_SQL + f" WHERE {where} ORDER BY q.requested_at {'' if status == 'PENDING' else 'DESC'} LIMIT 200")
        out = []
        for r in recs:
            d = await _proposal_labels(conn, _jsonish(row_dict(r)))
            stages = d["approval_stages"] or []
            d["waiting_for"] = stages[d["step"]] if d["status"] == "PENDING" and d["step"] < len(stages) else None
            d["may_decide"] = bool(d["waiting_for"]) and await conn.fetchval(
                "SELECT ops.may_decide_schedule_stage($1::jsonb)", json.dumps(d["waiting_for"])) and (
                d["waiting_for"]["by"] == "AUTHORITY" or "schedule.approve" in pr.permissions)
            p = d.get("proposal") or {}
            if d["kind"] == "NEW" and d["status"] == "PENDING" and p.get("route_id"):
                # the number after the leg it continues, else the first leg of a free line (1119)
                d["suggested_number"] = await conn.fetchval("SELECT ops.request_number(id) FROM ops.schedule_request WHERE uid = $1",
                                                            uuid.UUID(str(d["uid"])))
                d["designator"] = await conn.fetchval("SELECT ops.trip_designator($1)", d["company_id"])
            d.pop("company_id", None)
            out.append(d)
    return {"requests": out, "authorities": authorities}


@platform.post("/schedules/requests/{request_uid}/decide")
async def decide(request_uid: uuid.UUID, body: DecideIn, request: Request, pr: Principal = Depends(staff)):
    async with db.transaction(context_for(request, pr)) as conn:
        stage = await conn.fetchval(
            "SELECT (approval_stages -> step::int) ->> 'by' FROM ops.schedule_request WHERE uid = $1 AND status = 'PENDING'", request_uid)
        if stage == "PLATFORM":                          # an authority's members decide its stages by membership
            _need(pr, "schedule.approve")
        out = json.loads(await _db(conn.fetchval("SELECT ops.decide_schedule_request($1, $2, $3, $4)::text",
                                                 request_uid, body.approve, body.note, body.number)))
        if out["status"] == "APPROVED":
            out["made"] = await _made(conn, out.get("result"))
        rid = await conn.fetchval("SELECT id FROM ops.schedule_request WHERE uid = $1", request_uid)
    request.state.audit = {"action": "schedule.decide", "object_type": "schedule_request", "object_id": rid,
                           "reason": f"{'approved' if body.approve else 'refused'}"
                                     f"{f', number {body.number}' if body.number else ''}{f': {body.note}' if body.note else ''}"[:300]}
    return out


@platform.get("/schedules/settings")
async def settings(request: Request, pr: Principal = Depends(staff)):
    _need(pr, "schedule.settings")
    async with db.transaction(context_for(request, pr)) as conn:
        rules = await _rules(conn)
        authorities = []
        for a in await conn.fetch("SELECT id, code, name, authority_type, active FROM sec.authority_profile ORDER BY code"):
            members = await conn.fetch(
                """SELECT u.uid, u.email, p.legal_name AS name FROM sec.authority_member m JOIN iam.app_user u ON u.id = m.user_id
                     JOIN iam.party p ON p.id = u.party_id WHERE m.authority_id = $1 ORDER BY u.email""", a["id"])
            authorities.append({"code": a["code"], "name": a["name"], "type": a["authority_type"], "active": a["active"],
                                "members": [row_dict(m) for m in members]})
    return {"rules": rules, "authorities": authorities}


@platform.put("/schedules/settings/{key}")
async def set_setting(key: str, body: SettingIn, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "schedule.settings")
    if not re.fullmatch(r"[a-z_]{3,40}", key):
        raise ApiError(422, "INVALID_SETTING", "unknown setting")
    async with db.transaction(context_for(request, pr)) as conn:
        await _db(conn.execute("SELECT ops.set_schedule_setting($1, $2::jsonb)", f"schedule.{key}", json.dumps(body.value)))
        rules = await _rules(conn)
    request.state.audit = {"action": "schedule.setting", "object_type": "setting",
                           "reason": f"schedule.{key} = {json.dumps(body.value)}"[:300]}
    return {"rules": rules}


async def _authority(conn, code: str) -> int:
    aid = await conn.fetchval("SELECT id FROM sec.authority_profile WHERE code = $1", code)
    if aid is None:
        raise not_found("authority")
    return aid


@platform.post("/authorities/{code}/members", status_code=201)
async def add_member(code: str, body: MemberIn, request: Request, pr: Principal = Depends(staff)):
    """A platform staff account decides for a government authority at the stages that name it."""
    require_step_up(pr)                 # a sensitive operation: a recent second factor (1136)
    _need(pr, "schedule.settings")
    async with db.transaction(context_for(request, pr)) as conn:
        aid = await _authority(conn, code)
        user = await conn.fetchrow(
            """SELECT u.id, u.uid FROM iam.app_user u WHERE lower(u.email) = lower($1)
                  AND EXISTS (SELECT 1 FROM iam.user_role ur JOIN iam.role r ON r.id = ur.role_id
                               WHERE ur.user_id = u.id AND r.company_id IS NULL AND r.scope = 'PLATFORM')""", body.email.strip())
        if user is None:
            raise ApiError(422, "NOT_PLATFORM_STAFF", "the member is a staff account of the platform portal")
        await conn.execute("INSERT INTO sec.authority_member (authority_id, user_id, added_by) VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
                           aid, user["id"], pr.user_id)
    request.state.audit = {"action": "authority.member_add", "object_type": "authority", "object_id": aid, "reason": body.email.strip()[:200]}
    return {"ok": True, "user_uid": str(user["uid"])}


@platform.delete("/authorities/{code}/members/{user_uid}")
async def remove_member(code: str, user_uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    _need(pr, "schedule.settings")
    async with db.transaction(context_for(request, pr)) as conn:
        aid = await _authority(conn, code)
        uid = await conn.fetchval("SELECT id FROM iam.app_user WHERE uid = $1", user_uid)
        if uid is None or not await conn.fetchval("SELECT sec.remove_authority_member($1, $2)", aid, uid):
            raise not_found("member")
    request.state.audit = {"action": "authority.member_remove", "object_type": "authority", "object_id": aid}
    return {"ok": True}
