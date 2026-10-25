"""The boundaries of governorates, districts and sub-districts (migration 1125).

The same publisher as the P-code workbook (OCHA, the common operational dataset of administrative boundaries, "COD-AB")
publishes each level's boundaries as GeoJSON: one feature per area, its code in the properties ADM1_PCODE, ADM2_PCODE
and ADM3_PCODE (the most detailed one present is the feature's own) and a Polygon or MultiPolygon in WGS 84. read()
checks the file and gathers it; load() puts each shape on its area (ref.admin_area.boundary) in the caller's
transaction. A file naming an area the platform does not know, or holding a shape that is not an area, loads nothing.
"""
from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass
from typing import Optional

import asyncpg

from .importer import GeoFileError

CODE = re.compile(r"^ADM([1-3])_PCODE$", re.IGNORECASE)
AREA = re.compile(r"^[A-Z]{2}([0-9]{2}){1,3}$")


@dataclass
class Shape:
    pcode: str
    level: int
    geometry: str                     # the GeoJSON geometry as text


@dataclass
class Boundaries:
    sha256: str
    shapes: list[Shape]

    def levels(self) -> dict:
        out = {1: 0, 2: 0, 3: 0}
        for s in self.shapes:
            out[s.level] += 1
        return {"governorates": out[1], "districts": out[2], "sub_districts": out[3]}


def read(data: bytes) -> Boundaries:
    try:
        doc = json.loads(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, ValueError):
        raise GeoFileError("GEO_FILE_FORMAT: the file is not GeoJSON")
    if not isinstance(doc, dict) or doc.get("type") != "FeatureCollection" or not isinstance(doc.get("features"), list):
        raise GeoFileError("GEO_FILE_FORMAT: the file is not a GeoJSON FeatureCollection")
    shapes: list[Shape] = []
    problems: list[str] = []
    seen: set[str] = set()
    for i, f in enumerate(doc["features"], start=1):
        props = (f or {}).get("properties") or {}
        codes = {int(m.group(1)): str(v).strip() for k, v in props.items() if (m := CODE.match(str(k))) and v}
        geom = (f or {}).get("geometry") or {}
        if not codes:
            problems.append(f"feature {i}: no ADM1_PCODE, ADM2_PCODE or ADM3_PCODE")
            continue
        level = max(codes)
        pcode = codes[level].upper()
        if not AREA.match(pcode) or len(pcode) != 2 + 2 * level:
            problems.append(f"feature {i}: {pcode} is not the code of a level-{level} area")
        elif geom.get("type") not in ("Polygon", "MultiPolygon") or not geom.get("coordinates"):
            problems.append(f"{pcode}: its shape is not a polygon")
        elif pcode in seen:
            problems.append(f"{pcode}: twice in the file")
        else:
            seen.add(pcode)
            shapes.append(Shape(pcode, level, json.dumps(geom)))
        if len(problems) >= 10:
            break
    if problems:
        raise GeoFileError("GEO_FILE_INVALID: " + "; ".join(problems[:10]))
    if not shapes:
        raise GeoFileError("GEO_FILE_EMPTY: the file holds no area")
    return Boundaries(hashlib.sha256(data).hexdigest(), shapes)


async def load(conn: asyncpg.Connection, b: Boundaries, user_id: Optional[int], file_name: Optional[str]) -> dict:
    if await conn.fetchval("SELECT 1 FROM ref.geo_source WHERE sha256 = $1", b.sha256):
        return {"already_loaded": True, "counts": b.levels()}
    # an area whose code the platform changed is found by the code the file still carries (1161, N39)
    codes = await conn.fetchval("SELECT array_agg(ref.current_code('AREA', k) ORDER BY o) FROM unnest($1::text[]) WITH ORDINALITY AS u(k, o)",
                                [s.pcode for s in b.shapes])
    unknown = await conn.fetch(
        """SELECT k FROM unnest($1::text[]) AS k
            WHERE NOT EXISTS (SELECT 1 FROM ref.admin_area a WHERE a.pcode = k AND a.status = 'ACTIVE') ORDER BY k LIMIT 10""", codes)
    if unknown:
        raise GeoFileError("GEO_FILE_INVALID: areas the platform does not know (load the P-code workbook first): "
                           + ", ".join(r["k"] for r in unknown))
    source = await conn.fetchval(
        """INSERT INTO ref.geo_source (publisher, dataset, file_name, sha256, counts, imported_by, content)
           VALUES ('OCHA', 'administrative boundaries (COD-AB)', $1, $2, $3::jsonb, $4, 'BOUNDARIES') RETURNING id""",
        (file_name or "")[:200] or None, b.sha256, json.dumps(b.levels()), user_id)
    # a drawing that crosses itself is repaired; only its polygons are kept
    try:
        updated = await conn.fetchval(
            """WITH s AS (SELECT * FROM unnest($1::text[], $2::text[]) AS s(pcode, geom)),
                    u AS (UPDATE ref.admin_area a
                             SET boundary = gis.st_multi(gis.st_collectionextract(
                                   gis.st_makevalid(gis.st_setsrid(gis.st_geomfromgeojson(s.geom), 4326)), 3)),
                                 boundary_source_id = $3
                            FROM s WHERE a.pcode = s.pcode RETURNING 1)
               SELECT count(*) FROM u""", codes, [s.geometry for s in b.shapes], source)
    except asyncpg.PostgresError as e:
        raise GeoFileError(f"GEO_FILE_INVALID: a shape could not be read ({e.__class__.__name__})")
    # a place outside its sub-district by more than 2 km is reported, not changed: the file or the place may be wrong
    outside = await conn.fetch(
        """SELECT p.pcode, a.pcode AS area FROM ref.place p JOIN ref.admin_area a ON a.id = p.area_id
            WHERE p.status = 'ACTIVE' AND a.boundary_source_id = $1
              AND NOT gis.st_dwithin(a.boundary::gis.geography,
                                     gis.st_setsrid(gis.st_makepoint(p.lng::float8, p.lat::float8), 4326)::gis.geography, 2000)
            ORDER BY p.pcode""", source)
    report = b.levels() | {"updated": updated, "places_outside": len(outside)}
    await conn.execute("UPDATE ref.geo_source SET counts = $2::jsonb WHERE id = $1", source, json.dumps(report))
    return {"already_loaded": False, "counts": report, "places_outside": [dict(r) for r in outside[:50]]}
