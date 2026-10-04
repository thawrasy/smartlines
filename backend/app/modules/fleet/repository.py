"""SQL for seat layouts. Row-level security limits layouts to the carrier's own and the shared templates."""
import json
import uuid
from typing import Optional

import asyncpg

from .layout import Seat


async def layouts(conn: asyncpg.Connection) -> list[asyncpg.Record]:
    return await conn.fetch(
        """SELECT l.uid, l.name, l.total_seats, l.decks, l.grid, l.company_id IS NULL AS is_template, l.created_at,
                  (SELECT count(*) FROM fleet.vehicle v WHERE v.seat_layout_id = l.id) AS vehicles
             FROM fleet.seat_layout l WHERE l.status = 'ACTIVE' AND l.grid IS NOT NULL
            ORDER BY l.company_id IS NULL, l.name""")


async def layout_by_uid(conn: asyncpg.Connection, layout_uid: uuid.UUID) -> Optional[asyncpg.Record]:
    return await conn.fetchrow(
        "SELECT * FROM fleet.seat_layout WHERE uid = $1 AND status = 'ACTIVE' AND grid IS NOT NULL", layout_uid)


async def insert_layout(conn, company_id: int, name: str, decks: list[list[str]], seats: list[Seat], user_id: int) -> asyncpg.Record:
    row = await conn.fetchrow(
        """INSERT INTO fleet.seat_layout (company_id, name, total_seats, decks, grid, created_by)
           VALUES ($1, $2, $3, $4, $5::jsonb, $6) RETURNING id, uid""",
        company_id, name, len(seats), len(decks), json.dumps(decks), user_id)
    await conn.executemany(
        """INSERT INTO fleet.seat_layout_seat (layout_id, seat_no, label, row_no, col_no, deck, cabin)
           VALUES ($1, $2, $3, $4, $5, $6, $7)""",
        [(row["id"], s.n, s.label, s.row, s.col, s.deck, s.cabin) for s in seats])
    return row


async def layout_seats(conn, layout_id: int) -> list[asyncpg.Record]:
    return await conn.fetch(
        """SELECT seat_no AS n, label, deck, row_no AS row, col_no AS col, cabin
             FROM fleet.seat_layout_seat WHERE layout_id = $1 ORDER BY seat_no""", layout_id)


async def archive(conn, layout_id: int) -> None:
    await conn.execute("UPDATE fleet.seat_layout SET status = 'ARCHIVED' WHERE id = $1", layout_id)


async def vehicle_for_update(conn, company_id: int, vehicle_uid: uuid.UUID) -> Optional[asyncpg.Record]:
    return await conn.fetchrow(
        "SELECT id, seat_layout_id, passenger_seats FROM fleet.vehicle WHERE uid = $1 AND company_id = $2 FOR UPDATE",
        vehicle_uid, company_id)


async def assign(conn, vehicle_id: int, layout_id: int, seats: int) -> None:
    await conn.execute("UPDATE fleet.vehicle SET seat_layout_id = $2, passenger_seats = $3 WHERE id = $1",
                       vehicle_id, layout_id, seats)
