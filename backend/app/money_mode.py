"""Phase one, no money with the platform (owner's decision N13, 1145).

While platform.money_mode is NO_FUNDS the platform holds nobody's money: bookings are paid in cash at the carrier's
counter, wallet top-ups and withdrawals stop, and there is no platform fee or commission. The database closes the
payment options that hold money (fin.set_money_mode); the API refuses the money movements here."""
import asyncpg

from .errors import ApiError


async def mode(conn: asyncpg.Connection) -> str:
    return await conn.fetchval("SELECT fin.money_mode()")


async def no_funds(conn: asyncpg.Connection) -> bool:
    return await mode(conn) == "NO_FUNDS"


async def refuse_in_phase_one(conn: asyncpg.Connection) -> None:
    if await no_funds(conn):
        raise ApiError(409, "NO_FUNDS_PHASE", "the platform holds no money in phase one: pay in cash at the carrier's counter")
