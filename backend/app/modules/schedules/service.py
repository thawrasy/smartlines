"""Regular trips: how a carrier's trip repeats, and the trips it makes (owner's decision, October 2026; migration 1117).

A regular trip (ops.trip_template) has a route, a departure time and a pattern: every day, chosen days of the week, or
chosen days of the month, from a date to a date or with no end, without its dates off. It keeps one number every day
it runs. A carrier asks for it, and for each change or stop, through a request (ops.schedule_request) that passes the
approval stages the platform sets (ops.schedule_setting); the database checks and applies it. Here the trips are made:
right after an approval, and by the worker every minute for the regular trips whose horizon moved on, so one with no
end runs until it is stopped. A day that cannot be made (the vehicle busy, the number taken by a trip kept with its
bookings) is skipped and named in the regular trip's last run.
"""
import json
import logging
import uuid
from datetime import date, datetime, timedelta
from typing import Optional
from zoneinfo import ZoneInfo

import asyncpg

from ... import db, markets
from ..fleet import service as fleet

log = logging.getLogger("masslak.schedules")

SOONEST = timedelta(minutes=30)          # a trip is made at least this long before it leaves (as a trip made by hand)


async def insert_trip(conn: asyncpg.Connection, company_id: int, route, vehicle, dep: datetime, publish: bool,
                      driver_party: Optional[int] = None, template_id: Optional[int] = None,
                      trip_type: str = "SCHEDULED", service_number_id: Optional[int] = None) -> tuple[int, str]:
    """Writes one trip with its stops, seat segments and driver: the same trip whether made by hand or by a regular trip."""
    stops = await conn.fetch("SELECT * FROM net.route_stop WHERE route_id = $1 ORDER BY seq", route["id"])
    code3 = await conn.fetchval("SELECT code3 FROM net.carrier_code WHERE company_id = $1 AND status = 'ACTIVE'",
                                company_id) or "XXX"
    local = dep.astimezone(ZoneInfo(await markets.station_zone(conn, stops[0]["station_id"])))
    trip_no = f"{code3}-{route['code']}-{local:%H%M}/{local:%d%b%y}".upper()
    n = len(stops)
    arrival = dep + timedelta(minutes=stops[-1]["arr_offset_min"])
    status = "PUBLISHED" if publish else "DRAFT"
    # The trip keeps the vehicle's seat map as it is today, so seats sold never move if the layout changes
    seat_map = await fleet.trip_seat_map(conn, vehicle["id"])
    trip_id = await conn.fetchval(
        """INSERT INTO ops.trip (trip_no, company_id, route_id, service_type, vehicle_id, departure_at, arrival_at,
             status, seats_total, segments_count, currency, base_price, published_at, seat_map, template_id, trip_type,
             service_number_id)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NULL, $11, CASE WHEN $8 = 'PUBLISHED' THEN now() END,
                   $12::jsonb, $13, $14, $15)
           RETURNING id""",
        trip_no, company_id, route["id"], "INDIRECT" if n > 2 else "DIRECT", vehicle["id"], dep, arrival, status,
        vehicle["passenger_seats"], n - 1, stops[-1]["fare_from_origin"], json.dumps(seat_map) if seat_map else None,
        template_id, trip_type, service_number_id)
    await conn.executemany(
        """INSERT INTO ops.trip_stop (trip_id, seq, station_id, kind, sched_arr, sched_dep, fare_from_origin, rest_min)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
        [(trip_id, s["seq"], s["station_id"], "REST" if s["kind"] == "REST" else "STATION",
          dep + timedelta(minutes=s["arr_offset_min"]), dep + timedelta(minutes=s["dep_offset_min"]),
          s["fare_from_origin"], s["rest_min"]) for s in stops])
    await conn.execute(
        """INSERT INTO ops.seat_segment (trip_id, seat_no, seg)
           SELECT $1, seat, seg FROM generate_series(1, $2) seat, generate_series(0, $3) seg""",
        trip_id, vehicle["passenger_seats"], n - 2)
    if driver_party:
        await conn.execute("INSERT INTO ops.crew_assignment (trip_id, party_id, crew_role) VALUES ($1, $2, 'DRIVER')",
                           trip_id, driver_party)
    return trip_id, trip_no


class Incomplete(Exception):
    """The regular trip has no active route or no vehicle to make its trips with."""


async def make_trips(conn: asyncpg.Connection, tpl, start: date, end: date, publish: bool,
                     vehicle_id: Optional[int] = None) -> tuple[list[dict], list[dict]]:
    """The trips of a regular trip for each day it runs between two dates. A departure already made is skipped (one trip
    per regular trip and departure, 1054), so the same days can be made again; each day stands alone."""
    route = await conn.fetchrow("SELECT id, code, origin_station_id FROM net.route WHERE id = $1 AND status = 'ACTIVE'", tpl["route_id"])
    vehicle = await conn.fetchrow("SELECT id, passenger_seats FROM fleet.vehicle WHERE id = $1",
                                  vehicle_id or tpl["default_vehicle_id"])
    if route is None or vehicle is None:
        raise Incomplete()
    zone = ZoneInfo(await markets.station_zone(conn, route["origin_station_id"]))     # its times are local there
    soonest = datetime.now(zone) + SOONEST
    days = await conn.fetch(
        """SELECT d FROM ops.recurrence_days($1, $2, $3, $4, $5, $6) d
            WHERE $7::daterange @> d""",
        start, end, tpl["recurrence"], tpl["days_of_week"], tpl["days_of_month"], tpl["skip_dates"], tpl["active"])
    created, skipped = [], []
    for (day,) in days:
        dep = datetime.combine(day, tpl["departure_time"], tzinfo=zone)
        if dep < soonest:
            skipped.append({"date": day.isoformat(), "reason": "TOO_SOON"})
        elif await conn.fetchval("SELECT 1 FROM ops.trip WHERE template_id = $1 AND departure_at = $2", tpl["id"], dep):
            skipped.append({"date": day.isoformat(), "reason": "EXISTS"})
        else:
            try:                                          # a vehicle busy that day skips the day, not the whole range
                async with conn.transaction():
                    made, trip_no = await insert_trip(conn, tpl["company_id"], route, vehicle, dep, publish, template_id=tpl["id"],
                                                      trip_type=tpl["trip_type"])
                created.append({"date": day.isoformat(), "trip_no": trip_no,
                                "trip_code": await conn.fetchval("SELECT trip_code FROM ops.trip WHERE id = $1", made)})
            except (asyncpg.RaiseError, asyncpg.UniqueViolationError, asyncpg.ExclusionViolationError) as e:
                # a service number already used that day by another trip of the carrier (1114), or the vehicle busy
                reason = ("TRIP_NUMBER_TAKEN" if "trip_number_day_uq" in str(e)
                          else "SAME_DEPARTURE" if "trip_trip_no_key" in str(e)        # another trip on the route that minute
                          else "VEHICLE_BUSY" if isinstance(e, asyncpg.ExclusionViolationError) else str(e).split(":")[0])
                skipped.append({"date": day.isoformat(), "reason": reason})
    return created, skipped


async def extend(conn: asyncpg.Connection, template_id: int) -> Optional[dict]:
    """Makes the trips of an approved regular trip up to the horizon and records the run. None when nothing is due."""
    due = await conn.fetchrow("SELECT from_day, to_day FROM ops.schedules_due() WHERE template_id = $1", template_id)
    if due is None:
        return None
    tpl = await conn.fetchrow("SELECT * FROM ops.trip_template WHERE id = $1", template_id)
    try:
        created, skipped = await make_trips(conn, tpl, due["from_day"], due["to_day"], tpl["auto_publish"])
    except Incomplete:
        created, skipped = [], [{"date": due["from_day"].isoformat(), "reason": "TEMPLATE_INCOMPLETE"}]
    run = {"at": datetime.now().astimezone().isoformat(timespec="seconds"), "from": due["from_day"].isoformat(),
           "to": due["to_day"].isoformat(), "created": len(created), "skipped": skipped[:60],
           "skipped_count": len(skipped)}
    await conn.execute("UPDATE ops.trip_template SET generated_until = $2, last_run = $3::jsonb WHERE id = $1",
                       template_id, due["to_day"], json.dumps(run))
    return run


async def generate_due(limit: int = 50) -> int:
    """The worker's pass: every regular trip whose horizon moved on gets its trips, one regular trip per transaction."""
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        due = [r["template_id"] for r in await conn.fetch("SELECT template_id FROM ops.schedules_due() LIMIT $1", limit)]
    done = 0
    for template_id in due:
        try:
            async with db.transaction(ctx) as conn:
                run = await extend(conn, template_id)
            if run and run["skipped_count"]:
                log.warning("regular trip %s: %s trip(s) made, %s day(s) skipped", template_id, run["created"], run["skipped_count"])
            done += 1
        except Exception:                                 # noqa: BLE001 - one regular trip never stops the others
            log.exception("making the trips of regular trip %s failed; the next pass tries again", template_id)
    return done
