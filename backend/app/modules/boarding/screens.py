"""What the station, carrier and platform screens read (build step 4), and the station's public departure board.

    Platform (boarding.manage)
    GET /api/admin/boarding/stations                      every station with its boarding switch, screens and gates
    GET /api/admin/boarding/operating-companies           the station operating companies and their counters
    Carrier (boarding.operators)
    GET /api/carrier/station-operators/options            the operating companies and stations it can give rights at
    GET /api/carrier/station-operators/activity?day=      check-ins and station sales on its trips that day
    Public
    GET /api/public/stations/{uid}/board                  the departure board: departures and arrivals with their bays,
                                                          only for a station whose screens the platform switched on
"""
from __future__ import annotations

import json
import uuid
from datetime import date, datetime, time, timedelta
from typing import Optional
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Request

from ... import db, markets
from ...deps import Principal, base_context, context_for, require_portal
from ...errors import ApiError, forbidden
from ...util import rows

platform = APIRouter(prefix="/api/admin/boarding", tags=["boarding"])
carrier = APIRouter(prefix="/api/carrier/station-operators", tags=["boarding"])
public = APIRouter(prefix="/api/public/stations", tags=["public"])


def _platform_staff(pr: Principal) -> None:
    if "boarding.manage" not in pr.permissions:
        raise forbidden("missing permission: boarding.manage")


def _grantor(pr: Principal) -> None:
    if pr.company_id is None or "boarding.operators" not in pr.permissions:
        raise forbidden("missing permission: boarding.operators")


@platform.get("/stations")
async def stations(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rs = await conn.fetch(
            """SELECT s.uid, s.code, s.name, c.code AS city, coalesce(b.enabled, false) AS enabled, coalesce(b.displays, false) AS displays,
                      coalesce(b.display_kinds, '{DEPARTURES,ARRIVALS,COMBINED}') AS display_kinds,
                      (SELECT count(*) FROM net.station_screen sc WHERE sc.station_id = s.id AND sc.active) AS screens,
                      coalesce(b.counter_system, 'PLATFORM') AS counter_system, b.checkin_opens_minutes, b.checkin_closes_minutes,
                      net.boarding_station_on(s.id) AS boarding_on_now,
                      (SELECT count(*) FROM net.station_gate g WHERE g.station_id = s.id AND g.gate_type = 'COUNTER' AND g.status = 'ACTIVE') AS counters,
                      (SELECT count(*) FROM net.station_gate g WHERE g.station_id = s.id AND g.gate_type <> 'COUNTER' AND g.status = 'ACTIVE') AS bays
                 FROM net.station s LEFT JOIN ref.city c ON c.id = s.city_id LEFT JOIN net.station_boarding b ON b.station_id = s.id
                WHERE s.status = 'ACTIVE' ORDER BY c.code NULLS LAST, s.code""")
    return {"stations": rows(rs)}


@platform.get("/operating-companies")
async def operating_companies(request: Request, pr: Principal = Depends(require_portal("PLATFORM"))):
    _platform_staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        rs = await conn.fetch(
            """SELECT p.uid, p.legal_name AS name, c.approval_status, c.created_at,
                      (SELECT count(*) FROM net.station_gate g WHERE g.operator_company_id = c.id AND g.status = 'ACTIVE') AS counters,
                      (SELECT count(*) FROM net.station_operator_grant g WHERE g.operator_company_id = c.id AND g.revoked_at IS NULL) AS grants
                 FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE c.company_type = 'STATION_OPERATOR' ORDER BY p.legal_name""")
    return {"companies": rows(rs)}


@carrier.get("/options")
async def grant_options(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    """Who and where a carrier can give rights to: the approved operating companies and the active stations."""
    _grantor(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        async with db.system_scope(conn, context_for(request, pr)):
            companies = await conn.fetch(
                """SELECT p.uid, p.legal_name AS name FROM iam.company c JOIN iam.party p ON p.id = c.id
                    WHERE c.company_type = 'STATION_OPERATOR' AND c.approval_status = 'APPROVED' ORDER BY p.legal_name""")
        stations_ = await conn.fetch(
            """SELECT s.uid, s.code, s.name, net.boarding_station_on(s.id) AS boarding_on_now FROM net.station s
                WHERE s.status = 'ACTIVE' ORDER BY s.code""")
    return {"companies": rows(companies), "stations": rows(stations_)}


@carrier.get("/activity")
async def activity(request: Request, day: Optional[date] = None, pr: Principal = Depends(require_portal("OPERATOR"))):
    """What station operating companies did on the carrier's trips in a day (its market's time zone): check-ins and sales."""
    _grantor(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        zone = ZoneInfo((await markets.of_party(conn, pr.company_id)).time_zone)
        day = day or datetime.now(zone).date()
        start = datetime.combine(day, time.min, zone)
        checkins = await conn.fetch(
            """SELECT c.pass_no, c.status, c.created_at, c.document_checked, st.code AS station, op.legal_name AS operator,
                      g.code AS counter, t.trip_no, t.trip_code, k.ticket_no
                 FROM brd.station_checkin c JOIN net.station st ON st.id = c.station_id JOIN iam.party op ON op.id = c.operator_company_id
                 JOIN ops.trip t ON t.id = c.trip_id JOIN sales.ticket k ON k.id = c.ticket_id
                 LEFT JOIN net.station_gate g ON g.id = c.counter_gate_id
                WHERE c.carrier_company_id = $1 AND c.created_at >= $2 AND c.created_at < $3 ORDER BY c.created_at DESC LIMIT 500""",
            pr.company_id, start, start + timedelta(days=1))
        sales_ = await conn.fetch(
            """SELECT b.booking_ref, b.status, s.total, s.currency, s.created_at, st.code AS station, op.legal_name AS operator,
                      g.code AS counter, t.trip_no, t.trip_code
                 FROM brd.station_sale s JOIN sales.booking b ON b.id = s.booking_id JOIN net.station st ON st.id = s.station_id
                 JOIN iam.party op ON op.id = s.operator_company_id JOIN ops.trip t ON t.id = b.trip_id
                 LEFT JOIN net.station_gate g ON g.id = s.counter_gate_id
                WHERE s.carrier_company_id = $1 AND s.created_at >= $2 AND s.created_at < $3 ORDER BY s.created_at DESC LIMIT 500""",
            pr.company_id, start, start + timedelta(days=1))
    return {"day": day.isoformat(), "checkins": rows(checkins), "sales": rows(sales_)}


@public.get("/{station_uid}/board")
async def board(station_uid: uuid.UUID, request: Request):
    """The station's departure board: public, without passenger data, for a station whose screens are switched on."""
    ctx = base_context(request)
    async with db.transaction(ctx) as conn:
        out = await conn.fetchval("SELECT brd.station_board($1)::text", station_uid)
    if out is None:
        raise ApiError(404, "BOARD_OFF", "this station has no departure board on the platform")
    return json.loads(out)
