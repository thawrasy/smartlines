"""What the landing pages show: cities, stations, the routes worth a page, and live figures from published trips.

Route pages exist for every city pair a carrier serves (approved routes, both directions) and for the main intercity and
international corridors, so a page never depends on demo data. Live figures (departures in the next seven days, the
cheapest fare, first and last departure, journey time, carriers) come from published trips and are cached for ten minutes.
"""
from __future__ import annotations

import math
import time
import uuid
from dataclasses import dataclass, field
from typing import Optional

from ... import db

# city code -> URL slug (English, stable: the same in both languages)
SLUG = {
    "DAM": "damascus", "ALP": "aleppo", "HMS": "homs", "HMA": "hama", "LTK": "latakia", "TRT": "tartus", "DRA": "daraa",
    "SWD": "sweida", "DRZ": "deir-ez-zor", "HSK": "hasakah", "RQA": "raqqa", "IDL": "idlib", "QNT": "quneitra",
    "RDM": "rif-dimashq", "BEY": "beirut", "AMM": "amman",
}
CODE = {v: k for k, v in SLUG.items()}

# the main corridors (each also gets its return page)
CORRIDORS = [
    ("DAM", "ALP"), ("DAM", "HMS"), ("DAM", "HMA"), ("DAM", "LTK"), ("DAM", "TRT"), ("DAM", "DRA"), ("DAM", "SWD"), ("DAM", "DRZ"),
    ("DAM", "HSK"), ("DAM", "RQA"), ("DAM", "IDL"), ("ALP", "LTK"), ("ALP", "HMS"), ("ALP", "HMA"), ("ALP", "TRT"), ("ALP", "DRZ"),
    ("ALP", "RQA"), ("HMS", "LTK"), ("HMS", "TRT"), ("LTK", "TRT"), ("DRZ", "HSK"), ("HMS", "HMA"),
    ("DAM", "BEY"), ("DAM", "AMM"), ("ALP", "BEY"), ("HMS", "BEY"), ("LTK", "BEY"), ("ALP", "AMM"),
]
ROAD_FACTOR = 1.3          # road distance over the straight line, for pairs without published trips
AVG_KMH = 65


@dataclass
class City:
    code: str
    name: str
    country: str
    lat: Optional[float]
    lng: Optional[float]
    stations: list[dict] = field(default_factory=list)

    @property
    def slug(self) -> str:
        return SLUG.get(self.code, self.code.lower())


@dataclass
class Trip:
    departs: object
    arrives: object
    price: int
    carrier: str
    origin_station: str
    origin_code: str
    dest_station: str
    dest_code: str


@dataclass
class Route:
    a: str
    b: str
    km: Optional[int]
    minutes: Optional[int]
    trips: list[Trip]
    carriers: int

    @property
    def slug(self) -> str:
        return f"{SLUG[self.a]}-to-{SLUG[self.b]}"

    @property
    def cheapest(self) -> Optional[int]:
        return min((t.price for t in self.trips), default=None)


@dataclass
class Catalog:
    cities: dict[str, City]
    routes: dict[str, Route]          # by slug
    built: float

    def international(self, r: Route) -> bool:
        return self.cities[r.a].country != self.cities[r.b].country


_cache: Optional[Catalog] = None
TTL = 600


def _km(a: City, b: City) -> Optional[int]:
    if None in (a.lat, a.lng, b.lat, b.lng):
        return None
    p1, p2 = math.radians(a.lat), math.radians(b.lat)
    dp, dl = p2 - p1, math.radians(b.lng - a.lng)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    straight = 2 * 6371 * math.asin(math.sqrt(h))
    return int(round(straight * ROAD_FACTOR / 5) * 5)


async def catalog() -> Catalog:
    global _cache
    if _cache and time.monotonic() - _cache.built < TTL:
        return _cache
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")
    async with db.transaction(ctx) as conn:
        rows = await conn.fetch("SELECT code, name, country_code, lat, lng FROM ref.city WHERE is_active AND code = ANY($1::text[])", list(SLUG))
        cities = {r["code"]: City(r["code"], r["name"], r["country_code"], float(r["lat"]) if r["lat"] is not None else None,
                                  float(r["lng"]) if r["lng"] is not None else None) for r in rows}
        for s in await conn.fetch(
                """SELECT c.code AS city, s.code, s.name FROM net.station s JOIN ref.city c ON c.id = s.city_id
                    WHERE s.status = 'ACTIVE' AND s.subtype <> 'BORDER' ORDER BY s.code"""):
            if s["city"] in cities:
                cities[s["city"]].stations.append({"code": s["code"], "name": s["name"]})
        served = await conn.fetch(
            """SELECT DISTINCT ca.code AS a, cb.code AS b FROM net.route r
                 JOIN net.station sa ON sa.id = r.origin_station_id JOIN ref.city ca ON ca.id = sa.city_id
                 JOIN net.station sb ON sb.id = r.dest_station_id JOIN ref.city cb ON cb.id = sb.city_id""")
        trips = await conn.fetch(
            """SELECT ca.code AS a, cb.code AS b, sa.sched_dep AS departs, sb.sched_arr AS arrives,
                      sb.fare_from_origin - sa.fare_from_origin AS price, p.legal_name AS carrier,
                      xa.name AS origin_station, xa.code AS origin_code, xb.name AS dest_station, xb.code AS dest_code
                 FROM ops.trip t JOIN iam.party p ON p.id = t.company_id
                 JOIN ops.trip_stop sa ON sa.trip_id = t.id JOIN net.station xa ON xa.id = sa.station_id JOIN ref.city ca ON ca.id = xa.city_id
                 JOIN ops.trip_stop sb ON sb.trip_id = t.id AND sb.seq > sa.seq JOIN net.station xb ON xb.id = sb.station_id
                 JOIN ref.city cb ON cb.id = xb.city_id
                WHERE t.status IN ('PUBLISHED', 'BOARDING') AND sa.sched_dep > now() AND sa.sched_dep < now() + interval '7 days'
                  AND ca.code <> cb.code AND sa.sellable AND sb.sellable
                ORDER BY sa.sched_dep""")
    pairs = {(r["a"], r["b"]) for r in served} | {(r["b"], r["a"]) for r in served}
    pairs |= set(CORRIDORS) | {(b, a) for a, b in CORRIDORS}
    by_pair: dict[tuple, list[Trip]] = {}
    for t in trips:
        by_pair.setdefault((t["a"], t["b"]), []).append(Trip(t["departs"], t["arrives"], int(t["price"]), t["carrier"], t["origin_station"],
                                                              t["origin_code"], t["dest_station"], t["dest_code"]))
    routes = {}
    for a, b in sorted(pairs):
        if a not in cities or b not in cities:
            continue
        ts = by_pair.get((a, b), [])
        durations = sorted(int((t.arrives - t.departs).total_seconds() // 60) for t in ts if t.arrives and t.departs)
        km = _km(cities[a], cities[b])
        minutes = durations[len(durations) // 2] if durations else (int(round(km / AVG_KMH * 60 / 15) * 15) if km else None)
        r = Route(a, b, km, minutes, ts[:40], len({t.carrier for t in ts}))
        routes[r.slug] = r
    _cache = Catalog(cities, routes, time.monotonic())
    return _cache


def reset() -> None:
    global _cache
    _cache = None
