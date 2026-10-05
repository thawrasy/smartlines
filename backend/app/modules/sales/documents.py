"""Travel documents on international trips (study 11.9, revised in v2.7).

A trip segment is international when it ends in, or stops on the way in, a country other than the one it starts in.
Every passenger on such a segment needs a valid passport, unless an active entry rule approved by the platform
accepts other documents for that destination (or transit) country and the passenger's nationality. Rules are
looked up most specific first: the passenger's nationality, then any nationality, then the platform default.
When a segment crosses several borders the passenger must hold a document accepted at every one of them.
"""
import json
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import Optional

import asyncpg

from ...errors import ApiError

DOC_TYPES = ("PASSPORT", "NATIONAL_ID", "RESIDENCE", "LAISSEZ_PASSER", "TRAVEL_DOCUMENT", "OTHER")


@dataclass
class Requirement:
    international: bool
    origin: Optional[str] = None
    destination: Optional[str] = None
    transit: list = field(default_factory=list)
    docs: list = field(default_factory=lambda: ["PASSPORT"])
    passport_min_days: int = 180
    security_approval: bool = False
    enforcement: str = "BLOCK"
    exception: bool = False                     # some document other than a passport is accepted
    rule_ids: list = field(default_factory=list)
    destination_rule_id: Optional[int] = None
    notes: list = field(default_factory=list)
    labels: list = field(default_factory=list)

    def public(self) -> dict:
        return {"international": self.international, "origin": self.origin, "destination": self.destination,
                "transit": self.transit, "docs": self.docs, "passport_min_days": self.passport_min_days,
                "security_approval": self.security_approval, "exception": self.exception,
                "enforcement": self.enforcement, "notes": self.notes, "rules": self.labels}


async def segment_countries(conn: asyncpg.Connection, trip_id: int, from_seq: int, to_seq: int) -> tuple[str, str, list]:
    rows = await conn.fetch(
        """SELECT ts.seq, s.country_code FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
            WHERE ts.trip_id = $1 AND ts.seq BETWEEN $2 AND $3 ORDER BY ts.seq""", trip_id, from_seq, to_seq)
    if len(rows) < 2:
        raise ApiError(422, "BAD_SEGMENT", "unknown trip segment")
    origin, dest = rows[0]["country_code"].strip(), rows[-1]["country_code"].strip()
    transit = []
    for r in rows[1:-1]:
        c = r["country_code"].strip()
        if c not in (origin, dest) and c not in transit:
            transit.append(c)
    return origin, dest, transit


async def _rule(conn: asyncpg.Connection, country: str, role: str, nationality: str, on: date) -> Optional[asyncpg.Record]:
    return await conn.fetchrow(
        """SELECT * FROM sales.entry_rule
            WHERE status = 'ACTIVE' AND country_code = $1 AND country_role = $2
              AND (nationality = $3 OR nationality IS NULL) AND (valid IS NULL OR valid @> $4::date)
            ORDER BY (nationality IS NULL), version DESC LIMIT 1""", country, role, nationality, on)


async def requirement(conn: asyncpg.Connection, trip_id: int, from_seq: int, to_seq: int, nationality: str,
                      departs: date) -> Requirement:
    origin, dest, transit = await segment_countries(conn, trip_id, from_seq, to_seq)
    return await requirement_for(conn, origin, dest, transit, nationality, departs)


async def requirement_for(conn: asyncpg.Connection, origin: str, dest: str, transit: list, nationality: str,
                          departs: date) -> Requirement:
    """The documents a passenger of this nationality needs to travel from origin to dest through the transit countries."""
    if dest == origin and not transit:
        return Requirement(international=False, origin=origin, destination=dest)
    default = await conn.fetchval("SELECT value FROM sys.setting WHERE key = 'travel.international_default'")
    default = json.loads(default) if isinstance(default, str) else (default or {})
    req = Requirement(international=True, origin=origin, destination=dest, transit=transit, docs=None,
                      passport_min_days=0, enforcement="ALLOW_PENDING")
    borders = [(dest, "DESTINATION")] + [(c, "TRANSIT") for c in transit]
    for country, role in borders:
        r = await _rule(conn, country, role, nationality, departs)
        docs = list(r["doc_required"]) if r else list(default.get("docs", ["PASSPORT"]))
        req.docs = docs if req.docs is None else [d for d in req.docs if d in docs]
        req.passport_min_days = max(req.passport_min_days, r["passport_min_days"] if r else int(default.get("passport_min_days", 180)))
        req.security_approval = req.security_approval or bool(r and r["security_approval"])
        if (r["enforcement"] if r else default.get("enforcement", "BLOCK")) == "BLOCK":
            req.enforcement = "BLOCK"
        if r:
            req.rule_ids.append(r["id"])
            req.labels.append(r["label"])
            if r["note"]:
                req.notes.append(r["note"])
            if role == "DESTINATION":
                req.destination_rule_id = r["id"]
    if not req.docs:                       # the borders accept no common document: only a passport can work
        req.docs = ["PASSPORT"]
    req.exception = req.docs != ["PASSPORT"]
    return req


def check(req: Requirement, id_type: Optional[str], id_no: Optional[str], passport_expiry: Optional[date],
          departs: date) -> list[str]:
    """Problems with one passenger's document, as stable codes (empty when the document is acceptable)."""
    if not req.international:
        return []
    issues = []
    if not id_type or not id_no:
        issues.append("DOCUMENT_REQUIRED")
    elif id_type not in req.docs:
        issues.append("DOCUMENT_NOT_ACCEPTED")
    if id_type == "PASSPORT":
        if passport_expiry is None:
            issues.append("PASSPORT_EXPIRY_REQUIRED")
        elif passport_expiry < departs + timedelta(days=req.passport_min_days):
            issues.append("PASSPORT_EXPIRES_TOO_SOON")
    return issues


def enforce(req: Requirement, problems: list[tuple[int, list[str]]]) -> None:
    """Refuses the booking when a blocking rule is not met; under ALLOW_PENDING the problems are kept for review."""
    bad = [(i, codes) for i, codes in problems if codes]
    if bad and req.enforcement == "BLOCK":
        i, codes = bad[0]
        raise ApiError(422, codes[0], "travel document not accepted for this trip", passenger=i, docs=req.docs,
                       passport_min_days=req.passport_min_days, destination=req.destination)
