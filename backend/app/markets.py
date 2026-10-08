"""Markets (schema file 1061, expert review stage D): the time zone, currency and language of the country a company
or a person belongs to. The database decides (ref.party_market, ref.station_tz); this module reads it with a short
cache, so the hot paths (wallets, dashboards, reports) pay one small query a minute at most.

Use the market of the company the data belongs to (a carrier's dashboard, its trips, its cash day), the passenger's
market for their wallet, and the default market only where there is no company or person (public pages).
"""
import re
import time
from dataclasses import dataclass
from datetime import date, datetime
from typing import Optional
from zoneinfo import ZoneInfo

import asyncpg

TTL = 60.0
_cache: dict = {}
_ZONE = re.compile(r"^(?:UTC|[A-Za-z]+(?:/[A-Za-z0-9_+\-]+)+)$")
_COLS = """m.country_code, m.time_zone, m.currency, m.locale, m.status, c.minor_unit"""


@dataclass(frozen=True)
class Market:
    country: str
    time_zone: str
    currency: str
    locale: str
    minor_unit: int
    status: str = "ACTIVE"

    @property
    def zone(self) -> ZoneInfo:
        return ZoneInfo(self.time_zone)

    def today(self) -> date:
        return datetime.now(self.zone).date()

    def public(self) -> dict:
        return {"country": self.country, "time_zone": self.time_zone, "currency": self.currency, "locale": self.locale,
                "minor_unit": self.minor_unit}


def sql_zone(tz: str) -> str:
    """The time zone as a SQL literal, for expressions built into report SQL. Only IANA names pass."""
    if not _ZONE.match(tz or ""):
        raise ValueError(f"not a time zone name: {tz!r}")
    return f"'{tz}'"


async def _get(conn: asyncpg.Connection, key: tuple, sql: str, *args) -> Market:
    hit = _cache.get(key)
    if hit and hit[0] > time.monotonic():
        return hit[1]
    r = await conn.fetchrow(sql, *args)
    if r is None:
        raise LookupError("no default market (ref.market)")
    m = Market(r["country_code"], r["time_zone"], r["currency"], r["locale"], r["minor_unit"], r["status"])
    _cache[key] = (time.monotonic() + TTL, m)
    return m


async def default(conn: asyncpg.Connection) -> Market:
    return await _get(conn, ("default",), f"SELECT {_COLS} FROM ref.market m JOIN ref.currency c ON c.code = m.currency "
                                          "WHERE m.is_default")


async def of_party(conn: asyncpg.Connection, party_id: Optional[int]) -> Market:
    """The market of a company or a person; the default market when there is neither."""
    if party_id is None:
        return await default(conn)
    return await _get(conn, ("party", party_id),
                      f"SELECT {_COLS} FROM ref.party_market($1) m JOIN ref.currency c ON c.code = m.currency", party_id)


async def of_country(conn: asyncpg.Connection, country: str) -> Market:
    return await _get(conn, ("country", country),
                      f"SELECT {_COLS} FROM ref.market_of_country($1) m JOIN ref.currency c ON c.code = m.currency", country)


async def station_zone(conn: asyncpg.Connection, station_id: int) -> str:
    hit = _cache.get(("station", station_id))
    if hit and hit[0] > time.monotonic():
        return hit[1]
    tz = await conn.fetchval("SELECT ref.station_tz($1)", station_id) or (await default(conn)).time_zone
    _cache[("station", station_id)] = (time.monotonic() + TTL, tz)
    return tz


async def active(conn: asyncpg.Connection) -> list[Market]:
    rows = await conn.fetch(f"SELECT {_COLS} FROM ref.market m JOIN ref.currency c ON c.code = m.currency "
                            "WHERE m.status = 'ACTIVE' ORDER BY m.is_default DESC, m.country_code")
    return [Market(r["country_code"], r["time_zone"], r["currency"], r["locale"], r["minor_unit"], r["status"]) for r in rows]


def forget() -> None:
    """Drops the cache (a market or a company's country was changed)."""
    _cache.clear()
