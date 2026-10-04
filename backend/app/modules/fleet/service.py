"""Seat layout use cases: preview, create, archive, assign to a vehicle, and the seat map snapshot for a trip."""
import json
import uuid
from typing import Optional

import asyncpg

from ...errors import ApiError, not_found
from . import layout as L
from . import repository as repo


def _grid(v):
    return json.loads(v) if isinstance(v, str) else v


def checked(decks: list[list[str]]) -> tuple[list[list[str]], list[L.Seat]]:
    try:
        decks = L.normalise(decks)
        return decks, L.build(decks)
    except L.LayoutError as e:
        code, _, msg = str(e).partition(": ")
        raise ApiError(422, code, msg)


def preview(decks: list[list[str]]) -> dict:
    checked(decks)
    return L.summary(decks)


def preset(pattern: str, rows: int, door_row: Optional[int], back_row_full: bool, wc_row: Optional[int]) -> dict:
    try:
        return L.summary(L.preset(pattern, rows, door_row=door_row, back_row_full=back_row_full, wc_row=wc_row))
    except L.LayoutError as e:
        code, _, msg = str(e).partition(": ")
        raise ApiError(422, code, msg)


async def list_layouts(conn: asyncpg.Connection) -> list[dict]:
    out = []
    for r in await repo.layouts(conn):
        decks = _grid(r["grid"])
        out.append({"uid": str(r["uid"]), "name": r["name"], "total_seats": r["total_seats"], "decks": decks,
                    "seats_per_row": L.summary(decks)["seats_per_row"], "is_template": r["is_template"],
                    "vehicles": r["vehicles"]})
    return out


async def get_layout(conn: asyncpg.Connection, layout_uid: uuid.UUID) -> dict:
    r = await repo.layout_by_uid(conn, layout_uid)
    if r is None:
        raise not_found("seat layout")
    return {"uid": str(r["uid"]), "name": r["name"], **L.summary(_grid(r["grid"]))}


async def create(conn: asyncpg.Connection, company_id: int, user_id: int, name: str, decks: list[list[str]]) -> tuple[int, str]:
    decks, seats = checked(decks)
    row = await repo.insert_layout(conn, company_id, name.strip(), decks, seats, user_id)
    return row["id"], str(row["uid"])


async def archive(conn: asyncpg.Connection, company_id: int, layout_uid: uuid.UUID) -> int:
    r = await repo.layout_by_uid(conn, layout_uid)
    if r is None or r["company_id"] != company_id:
        raise not_found("seat layout")
    await repo.archive(conn, r["id"])
    return r["id"]


async def assign_to_vehicle(conn: asyncpg.Connection, company_id: int, vehicle_uid: uuid.UUID, layout_uid: uuid.UUID) -> dict:
    """The vehicle takes the layout's seat count. Trips already created keep their own seat map snapshot."""
    v = await repo.vehicle_for_update(conn, company_id, vehicle_uid)
    lay = await repo.layout_by_uid(conn, layout_uid)
    if v is None or lay is None:
        raise not_found("vehicle or seat layout")
    await repo.assign(conn, v["id"], lay["id"], lay["total_seats"])
    return {"vehicle_id": v["id"], "passenger_seats": lay["total_seats"]}


async def layout_for_new_vehicle(conn: asyncpg.Connection, layout_uid: Optional[uuid.UUID],
                                 passenger_seats: Optional[int]) -> tuple[int, int]:
    """Returns (layout id, seat count). Every new vehicle needs a layout so the system matches the real seats; the
    seat count comes from the layout and a different typed count is refused."""
    if layout_uid is None:
        raise ApiError(422, "SEAT_LAYOUT_REQUIRED", "choose the vehicle's seat layout")
    lay = await repo.layout_by_uid(conn, layout_uid)
    if lay is None:
        raise not_found("seat layout")
    if passenger_seats is not None and passenger_seats != lay["total_seats"]:
        raise ApiError(422, "SEAT_COUNT_MISMATCH", "the seat count differs from the layout", layout_seats=lay["total_seats"])
    return lay["id"], lay["total_seats"]


async def trip_seat_map(conn: asyncpg.Connection, vehicle_id: int) -> Optional[dict]:
    """Snapshot stored on a new trip: the grid and every seat, so the sold seat numbers never move."""
    v = await conn.fetchrow(
        """SELECT l.id, l.uid, l.name, l.grid FROM fleet.vehicle v JOIN fleet.seat_layout l ON l.id = v.seat_layout_id
            WHERE v.id = $1""", vehicle_id)
    if v is None or v["grid"] is None:
        return None
    seats = [dict(s) for s in await repo.layout_seats(conn, v["id"])]
    return {"layout": str(v["uid"]), "name": v["name"], "decks": _grid(v["grid"]), "seats": seats}
