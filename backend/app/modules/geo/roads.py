"""Loading the roads guide (owner's request N38, migration 1162).

The owner's workbook has a sheet of every road point (road, order, governorate, district and sub-district P-codes, the
place's P-code, its position, the distance from the point before and from the start, notes) and an index of the roads
(number, names, regional number, start and end, number of points, length). The sheets are found by their columns, so
their names (in Arabic) do not matter.

read() checks the workbook on its own; load() checks it against the geography the platform loaded and writes it in the
caller's transaction. A mistake anywhere loads nothing. Doubts that do not stop the load (a distance shorter than the
straight line, a running total that does not add up, a position far from the place's) come back as warnings.
"""
from __future__ import annotations

import hashlib
import io
import json
import math
import re
from dataclasses import dataclass, field
from typing import Optional

import asyncpg

from .importer import GeoFileError, _text

ROAD = re.compile(r"^[A-Z]{1,2}[0-9]{1,3}[A-Z]?$")
PLACE = re.compile(r"^[A-Z][0-9]{3,7}$")
AREA = re.compile(r"^[A-Z]{2}([0-9]{2}){1,3}$")
CLASSES = {"M": "INTERNATIONAL", "P": "MAIN", "D": "MAIN", "S": "SECONDARY", "U": "URBAN"}
CROSSING = "\u0645\u0639\u0628\u0631"          # "crossing", as the file's notes write a border crossing
# the columns of the points sheet, in order, and of the index; recognised by the English part of their headings
POINT_HEAD = (15, "Location Pcode")
INDEX_HEAD = (4, "Road name (English)")


@dataclass
class Point:
    road: str
    seq: int
    governorate: str
    district: str
    sub_district: str
    place: str
    lat: float
    lng: float
    km_from_previous: float
    km_cumulative: Optional[float]
    note: Optional[str]

    @property
    def border(self) -> bool:
        return bool(self.note) and CROSSING in self.note


@dataclass
class Road:
    code: str
    road_class: str
    name_ar: str
    name_en: str
    regional: Optional[str]
    points_expected: Optional[int]
    length_km: Optional[float]
    note: Optional[str]
    points: list[Point] = field(default_factory=list)


@dataclass
class Guide:
    sha256: str
    roads: list[Road]

    def counts(self) -> dict:
        return {"roads": len(self.roads), "points": sum(len(r.points) for r in self.roads),
                "by_class": {c: sum(r.road_class == c for r in self.roads) for c in sorted({r.road_class for r in self.roads})}}


def _num(v) -> Optional[float]:
    try:
        return float(str(v).replace(",", "").strip())
    except (TypeError, ValueError):
        return None


def _sheet(wb, col: int, words: str):
    for ws in wb.worksheets:
        head = next(ws.iter_rows(max_row=1, values_only=True), ())
        if len(head) > col and words in _text(head[col]):
            return [r for r in ws.iter_rows(min_row=2, values_only=True) if r and any(v not in (None, "") for v in r)]
    return None


def read(data: bytes) -> Guide:
    import openpyxl
    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    except Exception as e:                                          # not a workbook at all
        raise GeoFileError("ROADS_FILE_FORMAT: not an Excel workbook") from e
    points, index = _sheet(wb, *POINT_HEAD), _sheet(wb, *INDEX_HEAD)
    if points is None or index is None:
        raise GeoFileError("ROADS_FILE_SHEETS: the workbook needs the sheet of road points and the index of roads")
    problems: list[str] = []
    roads: dict[str, Road] = {}
    for i, r in enumerate(index, start=2):
        code = _text(r[0]).upper()
        if not ROAD.match(code):
            problems.append(f"index row {i}: road number {code!r}")
            continue
        if code in roads:
            problems.append(f"index row {i}: road {code} twice")
            continue
        cls = CLASSES.get(code[0])
        if cls is None:
            problems.append(f"index row {i}: road {code} has no known class")
            continue
        name_ar, name_en = _text(r[3]), _text(r[4])
        if len(name_ar) < 2 or len(name_en) < 2:
            problems.append(f"index row {i}: road {code} has no name")
        count = _num(r[8])
        roads[code] = Road(code, cls, name_ar[:200], name_en[:200], (_text(r[5]) or None) if _text(r[5]) not in ("—", "-") else None,
                           int(count) if count is not None else None, _num(r[9]), (_text(r[13]) or None) if len(r) > 13 else None)
    for i, r in enumerate(points, start=2):
        code = _text(r[0]).upper()
        if code not in roads:
            problems.append(f"points row {i}: road {code!r} is not in the index")
            continue
        seq, lat, lng, km = _num(r[3]), _num(r[16]), _num(r[17]), _num(r[18])
        gov, dist, sub, place = (_text(r[c]).upper() for c in (6, 9, 12, 15))
        bad = [n for n, ok in (("order", seq is not None and seq >= 1 and seq == int(seq)), ("governorate", AREA.match(gov) and len(gov) == 4),
                               ("district", AREA.match(dist) and len(dist) == 6), ("sub-district", AREA.match(sub) and len(sub) == 8),
                               ("place", PLACE.match(place)), ("position", lat is not None and lng is not None),
                               ("distance", km is not None and km >= 0)) if not ok]
        if bad:
            problems.append(f"points row {i}: road {code}: {', '.join(bad)}")
            continue
        if not (sub.startswith(dist) and dist.startswith(gov)):
            problems.append(f"points row {i}: road {code}: {sub} is not under {dist} and {gov}")
            continue
        roads[code].points.append(Point(code, int(seq), gov, dist, sub, place, lat, lng, km, _num(r[19]),
                                        (_text(r[21]) or None) if len(r) > 21 else None))
    for road in roads.values():
        road.points.sort(key=lambda p: p.seq)
        if len(road.points) < 2:
            problems.append(f"road {road.code}: fewer than two points")
            continue
        if [p.seq for p in road.points] != list(range(1, len(road.points) + 1)):
            problems.append(f"road {road.code}: the order does not run 1 to {len(road.points)} without gaps")
        if road.points_expected is not None and road.points_expected != len(road.points):
            problems.append(f"road {road.code}: the index says {road.points_expected} points, the sheet has {len(road.points)}")
        if road.points[0].km_from_previous != 0:
            problems.append(f"road {road.code}: the first point is 0 km from the start")
    if problems:
        raise GeoFileError("ROADS_FILE_INVALID: " + "; ".join(problems[:12]) + (f" (and {len(problems) - 12} more)" if len(problems) > 12 else ""))
    if not roads:
        raise GeoFileError("ROADS_FILE_EMPTY: the workbook holds no road")
    return Guide(hashlib.sha256(data).hexdigest(), list(roads.values()))


def _km(a_lat, a_lng, b_lat, b_lng) -> float:
    rad = math.radians
    h = math.sin(rad(b_lat - a_lat) / 2) ** 2 + math.cos(rad(a_lat)) * math.cos(rad(b_lat)) * math.sin(rad(b_lng - a_lng) / 2) ** 2
    return 2 * 6371.0 * math.asin(math.sqrt(h))


async def load(conn: asyncpg.Connection, g: Guide, user_id: Optional[int], file_name: Optional[str]) -> dict:
    if await conn.fetchval("SELECT 1 FROM ref.geo_source WHERE sha256 = $1", g.sha256):
        return {"already_loaded": True, "counts": g.counts()}
    # every point a known place, in the sub-district the file says (old codes read through the code changes, 1161)
    codes = sorted({p.place for r in g.roads for p in r.points})
    known = {r["code"]: r for r in await conn.fetch(
        """SELECT k AS code, p.id, p.status, p.lat, p.lng, a.pcode AS sub_district
             FROM unnest($1::text[]) AS k
             JOIN ref.place p ON p.id = ref.code_entity('PLACE', k) JOIN ref.admin_area a ON a.id = p.area_id""", codes)}
    problems, warnings = [], []
    for r in g.roads:
        for p in r.points:
            k = known.get(p.place)
            if k is None or k["status"] != "ACTIVE":
                problems.append(f"road {r.code} point {p.seq}: no active place {p.place} (load the geography first)")
            elif await conn.fetchval("SELECT ref.current_code('AREA', $1)", p.sub_district) != k["sub_district"]:
                problems.append(f"road {r.code} point {p.seq}: {p.place} lies in {k['sub_district']}, not {p.sub_district}")
            elif _km(p.lat, p.lng, float(k["lat"]), float(k["lng"])) > 1.0:
                warnings.append(f"road {r.code} point {p.seq}: the position is {_km(p.lat, p.lng, float(k['lat']), float(k['lng'])):.1f} km from the place's")
    if problems:
        raise GeoFileError("ROADS_FILE_INVALID: " + "; ".join(problems[:12]) + (f" (and {len(problems) - 12} more)" if len(problems) > 12 else ""))
    for r in g.roads:
        total = 0.0
        for a, b in zip(r.points, r.points[1:]):
            straight = _km(a.lat, a.lng, b.lat, b.lng)
            total += b.km_from_previous
            if b.km_from_previous + 0.5 < straight:
                warnings.append(f"road {r.code} point {b.seq}: {b.km_from_previous:g} km from the point before, shorter than the straight line ({straight:.1f} km)")
            if b.km_cumulative is not None and abs(b.km_cumulative - total) > 1.0:
                warnings.append(f"road {r.code} point {b.seq}: the file's running total is {b.km_cumulative:g} km, the distances add up to {total:g} km")
                break
    source = await conn.fetchval(
        """INSERT INTO ref.geo_source (publisher, dataset, file_name, sha256, counts, imported_by, content)
           VALUES ('OWNER', 'roads guide', $1, $2, $3::jsonb, $4, 'ROADS') RETURNING id""",
        (file_name or "")[:200] or None, g.sha256, json.dumps(g.counts()), user_id)
    added = updated = 0
    kept: list[str] = []
    for r in g.roads:
        row = await conn.fetchrow("SELECT id, verification_status FROM net.road WHERE code = $1", r.code)
        if row and row["verification_status"] != "OWNER_FILE":
            kept.append(r.code)                     # verified beyond the owner's file: a newer file does not overwrite it
            continue
        rid = await conn.fetchval(
            """INSERT INTO net.road (code, road_class, name_ar, name_en, regional_number, length_km, note, source_id, status)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'ACTIVE')
               ON CONFLICT (code) DO UPDATE SET road_class = excluded.road_class, name_ar = excluded.name_ar, name_en = excluded.name_en,
                   regional_number = excluded.regional_number, note = excluded.note, source_id = excluded.source_id, status = 'ACTIVE'
               RETURNING id""",
            r.code, r.road_class, r.name_ar, r.name_en, r.regional, r.length_km, (r.note or "")[:2000] or None, source)
        added += row is None
        updated += row is not None
        await conn.execute(
            """INSERT INTO net.road_point AS t (road_id, seq, place_id, lat, lng, km_from_previous, is_border, note)
               SELECT $1, x.seq, ref.code_entity('PLACE', x.place), x.lat, x.lng, x.km, x.border, x.note
                 FROM unnest($2::int[], $3::text[], $4::numeric[], $5::numeric[], $6::numeric[], $7::boolean[], $8::text[])
                      AS x(seq, place, lat, lng, km, border, note)
               ON CONFLICT (road_id, seq) DO UPDATE SET place_id = excluded.place_id, lat = excluded.lat, lng = excluded.lng,
                   km_from_previous = excluded.km_from_previous, is_border = excluded.is_border, note = excluded.note""",
            rid, [p.seq for p in r.points], [p.place for p in r.points], [round(p.lat, 6) for p in r.points],
            [round(p.lng, 6) for p in r.points], [p.km_from_previous for p in r.points], [p.border for p in r.points],
            [(p.note or "")[:1000] or None for p in r.points])
        await conn.execute("SELECT net.trim_road($1, $2)", rid, len(r.points))
        await conn.execute("SELECT net.road_recount($1)", rid)
        if r.length_km is not None:
            km = await conn.fetchval("SELECT length_km FROM net.road WHERE id = $1", rid)
            if km is not None and abs(float(km) - r.length_km) > 2:
                warnings.append(f"road {r.code}: the index gives {r.length_km:g} km, the distances add up to {float(km):g} km")
    junctions = await conn.fetchval("SELECT count(*) FROM net.road_junction")
    report = g.counts() | {"added": added, "updated": updated, "kept_verified": kept, "junctions": junctions, "warnings": len(warnings)}
    await conn.execute("UPDATE ref.geo_source SET counts = $2::jsonb WHERE id = $1", source, json.dumps(report))
    return {"already_loaded": False, "counts": report, "warnings": warnings[:100]}
