"""What a vehicle is doing now (1169, N48): the movement the roadside scan shows.

Each service that moves people or goods on a vehicle adds a resolver here: an async function that takes the
connection, the vehicle and the window in minutes, and answers its current movement or None. The scan asks them in
order and shows the first answer, so a new module joins the roadside check the way it joins the menu: by adding its
resolver. A resolver answers:

    {"kind": "SCHEDULED_TRIP", "ref": <a reference to show>, "trip_id": <ops.trip id or None>, "title": ...,
     "departure_at": ..., "from": ..., "to": ..., "status": ..., "seats": ..., "sold": ..., "boarded": ...,
     "crew": [...], "cargo": {...}, "manifest_issued": bool}
"""
from __future__ import annotations

from typing import Awaitable, Callable, Optional

import asyncpg

Resolver = Callable[[asyncpg.Connection, dict, int], Awaitable[Optional[dict]]]


async def scheduled_trip(conn: asyncpg.Connection, vehicle: dict, window: int) -> Optional[dict]:
    """A scheduled trip of the vehicle: boarding or on the road, else published and departing within the window."""
    t = await conn.fetchrow(
        """SELECT t.id, t.trip_no, t.trip_code, t.status, t.departure_at, t.arrival_at, t.seats_total,
                  coalesce(t.standing_capacity, 0) AS standing,
                  (SELECT s.name FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                    WHERE ts.trip_id = t.id ORDER BY ts.seq LIMIT 1) AS origin,
                  (SELECT s.name FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
                    WHERE ts.trip_id = t.id ORDER BY ts.seq DESC LIMIT 1) AS destination
             FROM ops.trip t
            WHERE t.vehicle_id = $1
              AND (t.status IN ('BOARDING', 'DEPARTED')
                   OR (t.status = 'PUBLISHED' AND t.departure_at BETWEEN now() - make_interval(mins => $2)
                                                                     AND now() + make_interval(mins => $2)))
            ORDER BY CASE t.status WHEN 'DEPARTED' THEN 0 WHEN 'BOARDING' THEN 1 ELSE 2 END,
                     abs(extract(epoch FROM t.departure_at - now()))
            LIMIT 1""", vehicle["id"], window)
    if t is None:
        return None
    counts = await conn.fetchrow(
        """SELECT count(*) FILTER (WHERE status IN ('ISSUED', 'BOARDED')) AS sold,
                  count(*) FILTER (WHERE status = 'BOARDED') AS boarded
             FROM sales.ticket WHERE trip_id = $1""", t["id"])
    crew = await conn.fetch(
        """SELECT c.crew_role, p.legal_name AS name, p.uid::text AS party_uid,
                  (SELECT min(l.expiry_date) FROM fleet.license_record l
                    WHERE l.subject_person_id = c.party_id AND l.status <> 'SUSPENDED') AS licence_expiry
             FROM ops.crew_assignment c JOIN iam.party p ON p.id = c.party_id
            WHERE c.trip_id = $1 AND c.status <> 'RELEASED' ORDER BY c.crew_role""", t["id"])
    cargo = await conn.fetchrow(
        """SELECT (SELECT count(*) FROM ship.shipment_leg l WHERE l.trip_id = $1 AND l.status <> 'CANCELLED') AS parcels,
                  (SELECT coalesce(sum(used_weight_kg), 0) FROM ship.load d WHERE d.trip_id = $1) AS load_kg""", t["id"])
    manifest = await conn.fetchval("SELECT EXISTS (SELECT 1 FROM brd.manifest m WHERE m.trip_id = $1 AND m.issued_at IS NOT NULL)", t["id"])
    return {"kind": "SCHEDULED_TRIP", "ref": t["trip_code"] or str(t["trip_no"]), "trip_id": t["id"], "trip_no": t["trip_no"],
            "status": t["status"], "departure_at": t["departure_at"], "arrival_at": t["arrival_at"],
            "origin": t["origin"], "destination": t["destination"],
            "seats": t["seats_total"], "standing": t["standing"], "sold": counts["sold"], "boarded": counts["boarded"],
            "crew": [dict(c) for c in crew], "cargo": dict(cargo), "manifest_issued": manifest}


async def charter(conn: asyncpg.Connection, vehicle: dict, window: int) -> Optional[dict]:
    """A chartered vehicle (1123): the charter it is named on, today or within the window."""
    r = await conn.fetchrow(
        """SELECT q.ref, q.status, q.starts_at, q.ends_at, q.passengers
             FROM sales.charter_request q
            WHERE (q.vehicle_id = $1 OR EXISTS (SELECT 1 FROM sales.charter_vehicle cv WHERE cv.request_id = q.id AND cv.vehicle_id = $1))
              AND q.status = 'CONFIRMED'
              AND q.starts_at <= now() + make_interval(mins => $2) AND coalesce(q.ends_at, q.starts_at + interval '1 day') >= now()
            ORDER BY abs(extract(epoch FROM q.starts_at - now())) LIMIT 1""", vehicle["id"], window)
    if r is None:
        return None
    return {"kind": "CHARTER", "ref": r["ref"], "trip_id": None, "status": r["status"], "departure_at": r["starts_at"],
            "arrival_at": r["ends_at"], "sold": r["passengers"], "crew": [], "cargo": {}, "manifest_issued": None}


# in order: the first that answers is the vehicle's movement
RESOLVERS: list[Resolver] = [scheduled_trip, charter]


async def current(conn: asyncpg.Connection, vehicle: dict, window: int) -> Optional[dict]:
    for resolve in RESOLVERS:
        try:
            async with conn.transaction():          # a module whose tables are not in this phase answers nothing
                found = await resolve(conn, vehicle, window)
        except (asyncpg.UndefinedTableError, asyncpg.UndefinedColumnError, asyncpg.InsufficientPrivilegeError):
            found = None
        if found:
            return found
    return None
