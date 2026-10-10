"""Carrier-issued manifests (study 11.10, revised in 2.8).

The carrier issues the manifest of every trip, domestic or international. A manifest is a versioned snapshot of the
passengers (with their category), the crew, the vehicle and the cargo the trip carries (every shipment leg on its hold
or on a load it pulls). At issue the snapshot is hashed in a canonical form rebuilt from its own rows, the hash is
signed (Ed25519) and the database seals the rows: a change is a new version that supersedes the last one (1078). A
domestic trip has one manifest; an international trip has one per border point it crosses (a pre-arrival manifest
only for those), and its passengers must carry a document. An international manifest whose crossing has an authority
is SUBMITTED to it, and that authority answers it through the border contract of the integration API.

Which authorities receive a manifest, and how, is not code: platform officers keep routing rules (brd.manifest_route),
each activated by a second officer. Issuing creates one delivery per matching route: offered for the authority to pull
through the integration API, pushed as a signed webhook notice, or handled by hand. With no rule the manifest simply
stays issued and printable, ready for an integration added later.
"""
from __future__ import annotations

import hashlib
import json
from datetime import datetime, timedelta, timezone
from typing import Optional

import asyncpg

from ... import crypto, db, security
from ...errors import ApiError
from ..notify.outbox import emit

TYPES = ("PRE_DEPARTURE", "PRE_ARRIVAL", "FINAL", "AMENDMENT", "CANCELLATION")
LIVE = ("ISSUED", "SUBMITTED", "ACKNOWLEDGED")
DOC_TYPES = {"PASSPORT", "NATIONAL_ID", "RESIDENCE", "TRAVEL_DOCUMENT", "LAISSEZ_PASSER", "OTHER"}
PUSH_ATTEMPTS = 6
CANONICAL_VERSION = 1


async def scope_of(conn: asyncpg.Connection, trip_id: int) -> tuple[str, list[str], list[int]]:
    """DOMESTIC or INTERNATIONAL, the countries the trip touches, and its city ids (first and last stop)."""
    stops = await conn.fetch(
        """SELECT s.country_code, s.city_id FROM ops.trip_stop ts JOIN net.station s ON s.id = ts.station_id
            WHERE ts.trip_id = $1 ORDER BY ts.seq""", trip_id)
    countries = list(dict.fromkeys(r["country_code"].strip() for r in stops))
    return ("INTERNATIONAL" if len(countries) > 1 else "DOMESTIC"), countries, [stops[0]["city_id"], stops[-1]["city_id"]]


async def border_points(conn: asyncpg.Connection, trip_id: int) -> list[int]:
    """Border points of an international trip: its crossing plan, else the border stations among its stops."""
    rows = await conn.fetch(
        """SELECT DISTINCT p.station_id FROM ops.trip_crossing_plan c JOIN brd.border_point p ON p.station_id = c.exit_station_id
            WHERE c.trip_id = $1""", trip_id)
    if not rows:
        rows = await conn.fetch(
            """SELECT DISTINCT p.station_id FROM ops.trip_stop ts JOIN brd.border_point p ON p.station_id = ts.station_id
                WHERE ts.trip_id = $1""", trip_id)
    return [r["station_id"] for r in rows]


async def _persons(conn: asyncpg.Connection, trip: asyncpg.Record, mtype: str) -> list[asyncpg.Record]:
    if mtype == "CANCELLATION":
        return []
    statuses = ["BOARDED"] if mtype == "FINAL" else ["ISSUED", "BOARDED"]
    return await conn.fetch(
        """SELECT k.id AS ticket_id, k.ticket_no, k.seat_no, k.status, p.full_name, p.passenger_category, p.birth_date, p.gender,
                  p.nationality, p.id_type, p.id_no_enc, p.id_no_bidx, p.id_no_last4, p.enc_key_id, p.passport_country,
                  p.passport_expiry, a.station_id AS embark, z.station_id AS disembark, sa.code AS embark_code, sz.code AS disembark_code,
                  (SELECT s ->> 'label' FROM jsonb_array_elements(t.seat_map -> 'seats') s WHERE (s ->> 'n')::int = k.seat_no) AS seat_label
             FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id JOIN ops.trip t ON t.id = k.trip_id
             JOIN ops.trip_stop a ON a.trip_id = k.trip_id AND a.seq = k.from_seq JOIN net.station sa ON sa.id = a.station_id
             JOIN ops.trip_stop z ON z.trip_id = k.trip_id AND z.seq = k.to_seq JOIN net.station sz ON sz.id = z.station_id
            WHERE k.trip_id = $1 AND k.status = ANY($2::text[]) ORDER BY k.seat_no NULLS LAST, k.id""", trip["id"], statuses)


async def _cargo(conn: asyncpg.Connection, trip_id: int, mtype: str) -> list[asyncpg.Record]:
    """What the trip carries: every leg not cancelled on its hold or on a load it pulls, with the shipment's size."""
    if mtype == "CANCELLATION":
        return []
    return await conn.fetch(
        """SELECT l.id AS leg_id, s.id AS shipment_id, s.tracking_no, coalesce(s.cargo_category, 'GENERAL') AS cargo_category,
                  coalesce(nullif(btrim(s.contents), ''), sp.name) AS description, z.weight_kg, nullif(z.pieces, 0) AS packages,
                  (SELECT min(p.hs_code) FROM ship.parcel p WHERE p.shipment_id = s.id) AS hs_code
             FROM ship.shipment_leg l JOIN ship.shipment s ON s.id = l.shipment_id JOIN ship.service_product sp ON sp.id = s.service_id
            CROSS JOIN LATERAL ship.shipment_size(s.id) z
            WHERE l.status <> 'CANCELLED'
              AND (l.trip_id = $1 OR l.load_id IN (SELECT id FROM ship.load WHERE trip_id = $1))
            ORDER BY l.id""", trip_id)


async def canonical(conn: asyncpg.Connection, manifest_id: int) -> dict:
    """The canonical form of a manifest, rebuilt from its own rows (canonical_version 1): what payload_sha256 hashes and
    the platform signs. An authority recomputes the hash from the manifest it received; anyone with the rows can
    recompute it here (verify)."""
    m = await conn.fetchrow(
        """SELECT m.trip_id, m.version, m.manifest_type, m.scope, t.trip_no, s.code AS border_point
             FROM brd.manifest m JOIN ops.trip t ON t.id = m.trip_id LEFT JOIN net.station s ON s.id = m.border_point_id
            WHERE m.id = $1""", manifest_id)
    _, countries, _ = await scope_of(conn, m["trip_id"])
    persons = await conn.fetch(
        """SELECT mp.person_role AS role, k.ticket_no AS ticket, mp.full_name AS name, mp.age_category AS category, mp.nationality,
                  mp.birth_date, mp.sex, mp.doc_type, mp.doc_last4, se.code AS embark, sd.code AS disembark, mp.seat_label AS seat
             FROM brd.manifest_person mp LEFT JOIN sales.ticket k ON k.id = mp.ticket_id
             LEFT JOIN net.station se ON se.id = mp.embark_station_id LEFT JOIN net.station sd ON sd.id = mp.disembark_station_id
            WHERE mp.manifest_id = $1 ORDER BY mp.person_role DESC, mp.id""", manifest_id)
    vehicle = await conn.fetchrow("SELECT plate_no, plate_country, chassis_no FROM brd.manifest_vehicle WHERE manifest_id = $1 LIMIT 1",
                                  manifest_id)
    cargo = await conn.fetch(
        """SELECT s.tracking_no AS shipment, c.cargo_category AS category, c.cargo_description AS description, c.hs_code,
                  c.declared_weight_kg AS weight_kg, c.packages, c.container_no, c.seal_no, c.un_number, c.adr_class
             FROM brd.manifest_cargo c LEFT JOIN ship.shipment s ON s.id = c.shipment_id WHERE c.manifest_id = $1 ORDER BY c.id""",
        manifest_id)
    return {"canonical_version": CANONICAL_VERSION, "trip_no": m["trip_no"], "scope": m["scope"], "type": m["manifest_type"],
            "version": m["version"], "border_point": m["border_point"], "countries": countries,
            "persons": [_plain(p) for p in persons], "vehicle": _plain(vehicle) if vehicle else None, "cargo": [_plain(c) for c in cargo]}


def _plain(row) -> dict:
    """Only JSON strings, integers and nulls: dates in ISO form and decimals as text, so the hash an authority computes
    over the JSON it received equals the one computed here."""
    return {k: (v.isoformat() if hasattr(v, "isoformat") else str(v) if not isinstance(v, (str, int, type(None))) else v)
            for k, v in dict(row).items()}


def digest_of(canon: dict) -> bytes:
    return hashlib.sha256(json.dumps(canon, sort_keys=True, default=str, separators=(",", ":")).encode()).digest()


async def verify(conn: asyncpg.Connection, ctx: db.Context, m: asyncpg.Record) -> dict:
    """Recomputes the hash from the manifest's rows and checks the platform's signature on it. The rows are read in the
    platform scope, as at issue, so a module switched off since (cargo) does not hide a row from the hash."""
    if m["canonical_version"] is None:
        return {"verifiable": False, "reason": "issued before release 1.48.0"}
    async with db.system_scope(conn, ctx):
        digest = digest_of(await canonical(conn, m["id"]))
    stored = bytes(m["payload_sha256"])
    return {"verifiable": True, "sha256": stored.hex(), "hash_matches": digest == stored, "kid": m["signing_kid"],
            "signature_valid": bool(m["payload_signature"]) and security.manifest_signature_valid(stored, bytes(m["payload_signature"]))}


async def issue(conn: asyncpg.Connection, ctx: db.Context, trip: asyncpg.Record, mtype: str, user_id: int) -> list[dict]:
    """Issues the next version of the trip's manifest(s) and routes each to the authorities. The caller has checked that
    the trip belongs to the carrier; the snapshot and the routing run in the platform scope of the same transaction.
    People, crew, vehicle and cargo are written while the manifest is a DRAFT, then hashed, signed and sealed: from
    then on the database refuses any change to them (1078)."""
    if mtype not in TYPES:
        raise ApiError(422, "MANIFEST_TYPE", "unknown manifest type")
    scope, countries, cities = await scope_of(conn, trip["id"])
    if mtype == "PRE_ARRIVAL" and scope != "INTERNATIONAL":
        raise ApiError(409, "MANIFEST_TYPE_SCOPE", "a pre-arrival manifest is issued for international trips only", scope=scope)
    async with db.system_scope(conn, ctx):
        points: list[Optional[int]] = [None]
        if scope == "INTERNATIONAL":
            points = await border_points(conn, trip["id"])
            if not points:
                raise ApiError(409, "CROSSING_PLAN_REQUIRED", "an international trip needs its border crossings before a manifest is issued")
        people = await _persons(conn, trip, mtype)
        if scope == "INTERNATIONAL":
            missing = [p["ticket_no"] for p in people if not p["id_no_enc"] or not p["id_type"] or not p["birth_date"]]
            if missing:
                raise ApiError(409, "MANIFEST_DOC_REQUIRED", "passengers of an international trip need a document and a date of birth",
                               tickets=missing)
        cargo = await _cargo(conn, trip["id"], mtype)
        unweighed = [c["tracking_no"] for c in cargo if not c["weight_kg"] or c["weight_kg"] <= 0]
        if unweighed:
            raise ApiError(409, "MANIFEST_CARGO_WEIGHT", "every shipment on the trip needs its weight before the manifest is issued",
                           shipments=unweighed)
        content = "MIXED" if people and cargo else ("CARGO" if cargo else "PASSENGER")
        crew = await conn.fetch(
            """SELECT ca.party_id, ca.crew_role, pa.legal_name, pa.nationality, pa.birth_date, pa.gender, pa.id_type, pa.id_no_last4
                 FROM ops.crew_assignment ca JOIN iam.party pa ON pa.id = ca.party_id
                WHERE ca.trip_id = $1 AND ca.status <> 'CANCELLED' ORDER BY ca.id""", trip["id"])
        vehicle = await conn.fetchrow(
            "SELECT id, plate_no, plate_country, chassis_no FROM fleet.vehicle WHERE id = (SELECT vehicle_id FROM ops.trip WHERE id = $1)",
            trip["id"])
        fc = await crypto.cipher(conn)
        issued = []
        for point in points:
            prev = await conn.fetchrow(
                """SELECT id, version FROM brd.manifest WHERE trip_id = $1 AND border_point_id IS NOT DISTINCT FROM $2
                    ORDER BY version DESC LIMIT 1""", trip["id"], point)
            if mtype == "AMENDMENT" and prev is None:
                raise ApiError(409, "NOTHING_TO_AMEND", "issue the manifest before amending it")
            version = (prev["version"] + 1) if prev else 1
            m = await conn.fetchrow(
                """INSERT INTO brd.manifest (trip_id, border_point_id, version, manifest_type, content_type, status, scope, supersedes_id)
                   VALUES ($1, $2, $3, $4, $5, 'DRAFT', $6, $7) RETURNING id, uid""",
                trip["id"], point, version, mtype, content, scope, prev["id"] if prev else None)
            for p in people:
                enc = key_id = None
                if p["id_no_enc"]:
                    clear = fc.decrypt(bytes(p["id_no_enc"]), p["enc_key_id"], "sales.passenger.id_no")
                    sealed = fc.encrypt(clear, "brd.manifest_person.doc_no")
                    enc, key_id = sealed.ciphertext, sealed.key_id
                doc_type = p["id_type"] if p["id_type"] in DOC_TYPES else ("OTHER" if p["id_type"] else None)
                issuing = (p["passport_country"] or p["nationality"]) if doc_type else None
                await conn.execute(
                    """INSERT INTO brd.manifest_person (manifest_id, person_role, ticket_id, doc_type, doc_no_enc, doc_no_bidx, enc_key_id,
                         issuing_country, doc_expiry, nationality, birth_date, sex, embark_station_id, disembark_station_id, full_name,
                         age_category, doc_last4, seat_label, passenger_category)
                       VALUES ($1, 'PASSENGER', $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)""",
                    m["id"], p["ticket_id"], doc_type, enc, p["id_no_bidx"] if enc else None, key_id, issuing, p["passport_expiry"],
                    p["nationality"] or "SY", p["birth_date"], p["gender"], p["embark"], p["disembark"], p["full_name"],
                    p["passenger_category"] if p["passenger_category"] in ("ADULT", "CHILD", "INFANT") else "ADULT",
                    p["id_no_last4"], p["seat_label"] or (str(p["seat_no"]) if p["seat_no"] else None),
                    "DOMESTIC" if scope == "DOMESTIC" else None)
            for c in crew:
                await conn.execute(
                    """INSERT INTO brd.manifest_person (manifest_id, person_role, crew_party_id, nationality, birth_date, sex, full_name,
                         doc_type, doc_last4) VALUES ($1, 'CREW', $2, $3, $4, $5, $6, $7, $8)""",
                    m["id"], c["party_id"], c["nationality"] or "SY", c["birth_date"], c["gender"], c["legal_name"],
                    c["id_type"] if c["id_type"] in DOC_TYPES else None, c["id_no_last4"])
            if vehicle:
                await conn.execute(
                    """INSERT INTO brd.manifest_vehicle (manifest_id, vehicle_id, plate_no, plate_country, chassis_no)
                       VALUES ($1, $2, $3, $4, $5)""", m["id"], vehicle["id"], vehicle["plate_no"], vehicle["plate_country"] or "SY",
                    vehicle["chassis_no"])
            for c in cargo:
                await conn.execute(
                    """INSERT INTO brd.manifest_cargo (manifest_id, shipment_id, leg_id, cargo_category, cargo_description, hs_code,
                         declared_weight_kg, packages) VALUES ($1, $2, $3, $4, $5, $6, greatest(round($7::numeric, 1), 0.1), $8)""",
                    m["id"], c["shipment_id"], c["leg_id"], c["cargo_category"], c["description"][:200], c["hs_code"],
                    c["weight_kg"], c["packages"])
            digest = digest_of(await canonical(conn, m["id"]))
            # submitted at once to the authority of its crossing, which answers through the border contract (R-12)
            border_authority = await conn.fetchval("SELECT authority_id FROM brd.border_point WHERE station_id = $1", point) \
                if point is not None else None
            status = "SUBMITTED" if border_authority else "ISSUED"
            if prev:
                await conn.execute("UPDATE brd.manifest SET status = 'SUPERSEDED' WHERE id = $1 AND status = ANY($2::text[])",
                                   prev["id"], list(LIVE))
            await conn.execute(
                """UPDATE brd.manifest SET status = $5, issued_by = $2, issued_at = now(), closed_at = now(), payload_sha256 = $3,
                     persons_count = $4, payload_signature = $6, signing_kid = $7, canonical_version = $8 WHERE id = $1""",
                m["id"], user_id, digest, len(people) + len(crew), status, security.manifest_sign(digest), security.MANIFEST_KID,
                CANONICAL_VERSION)
            deliveries = await route(conn, m["id"], trip, scope, mtype, countries, cities, point, content)
            await emit(conn, "manifest.issued", "manifest", m["id"],
                       {"manifest_uid": str(m["uid"]), "trip_no": trip["trip_no"], "scope": scope, "type": mtype, "version": version,
                        "persons": len(people), "cargo": len(cargo), "deliveries": len(deliveries)}, company_id=trip["company_id"])
            issued.append({"uid": str(m["uid"]), "scope": scope, "border_point_id": point, "version": version, "type": mtype,
                           "status": status, "content": content, "persons": len(people), "crew": len(crew), "cargo": len(cargo),
                           "sha256": digest.hex(), "deliveries": deliveries})
    return issued


async def answer(conn: asyncpg.Connection, manifest_id: int, authority_id: int, status: str, ack_ref: Optional[str] = None,
                 reason: Optional[str] = None) -> str:
    """One answer of an authority, whichever contract it came through (border decisions or a routed delivery): its
    delivery of the manifest is answered, and a manifest submitted to the authority of its crossing takes the answer.
    Returns the manifest's status."""
    await conn.execute(
        """UPDATE brd.manifest_delivery SET status = $3, ack_ref = coalesce($4, ack_ref), reject_reason = $5, acknowledged_at = now()
            WHERE manifest_id = $1 AND authority_id = $2 AND status NOT IN ('ACKNOWLEDGED', 'REJECTED')""",
        manifest_id, authority_id, status, ack_ref, reason)
    return await conn.fetchval(
        """UPDATE brd.manifest m SET status = $3 FROM brd.border_point bp
            WHERE m.id = $1 AND bp.station_id = m.border_point_id AND bp.authority_id = $2 AND m.status = 'SUBMITTED'
           RETURNING m.status""", manifest_id, authority_id, status) \
        or await conn.fetchval("SELECT status FROM brd.manifest WHERE id = $1", manifest_id)


async def route(conn: asyncpg.Connection, manifest_id: int, trip: asyncpg.Record, scope: str, mtype: str, countries: list[str],
                cities: list[int], point: Optional[int], content: str = "PASSENGER") -> list[dict]:
    """One delivery per authority whose active routes match this manifest (the first matching route of an authority wins).
    A route for passengers or for cargo takes the manifests that carry them; a mixed manifest matches both."""
    rows = await conn.fetch(
        """SELECT r.id, r.authority_id, r.channel, a.name AS authority FROM brd.manifest_route r
             JOIN sec.authority_profile a ON a.id = r.authority_id AND a.active
            WHERE r.status = 'ACTIVE' AND r.scope IN ($1, 'ALL') AND $2 = ANY(r.manifest_types)
              AND (r.content_type = 'ALL' OR r.content_type = $7 OR $7 = 'MIXED')
              AND (r.country_code IS NULL OR r.country_code = ANY($3::bpchar[]))
              AND (r.border_point_id IS NULL OR r.border_point_id = $4)
              AND (r.city_id IS NULL OR r.city_id = ANY($5::bigint[]))
              AND (r.company_id IS NULL OR r.company_id = $6)
            ORDER BY r.authority_id, r.company_id NULLS LAST, r.border_point_id NULLS LAST, r.id""",
        scope, mtype, countries, point, cities, trip["company_id"], content)
    out, seen = [], set()
    for r in rows:
        if r["authority_id"] in seen:
            continue
        seen.add(r["authority_id"])
        status = {"API_PULL": "AVAILABLE", "API_PUSH": "PENDING"}.get(r["channel"], "MANUAL")
        d = await conn.fetchrow(
            """INSERT INTO brd.manifest_delivery (manifest_id, route_id, authority_id, channel, status)
               VALUES ($1, $2, $3, $4, $5) RETURNING uid""", manifest_id, r["id"], r["authority_id"], r["channel"], status)
        out.append({"uid": str(d["uid"]), "authority": r["authority"], "channel": r["channel"], "status": status})
    return out


async def push_due(conn: asyncpg.Connection) -> int:
    """Worker step: tells authorities with a webhook that a manifest is waiting (a signed notice without personal data;
    the authority then pulls the manifest through the API and acknowledges it). Runs in the platform scope."""
    rows = await conn.fetch(
        """SELECT d.id, d.uid, d.attempts, d.authority_id, m.uid AS manifest_uid, m.scope, m.manifest_type, m.version, t.trip_no
             FROM brd.manifest_delivery d JOIN brd.manifest m ON m.id = d.manifest_id JOIN ops.trip t ON t.id = m.trip_id
            WHERE d.status = 'PENDING' AND d.channel = 'API_PUSH' AND d.next_attempt_at <= now()
            ORDER BY d.id LIMIT 50 FOR UPDATE OF d SKIP LOCKED""")
    for d in rows:
        has_endpoint = await conn.fetchval(
            """SELECT 1 FROM sys.webhook_endpoint e JOIN iam.api_client c ON c.id = e.api_client_id
                WHERE c.authority_id = $1 AND c.kind = 'AUTHORITY' AND c.status = 'ACTIVE' AND e.status = 'ACTIVE'
                  AND 'manifest.available' = ANY(e.events)""", d["authority_id"])
        if has_endpoint:
            await emit(conn, "manifest.available", "manifest_delivery", d["id"],
                       {"delivery_uid": str(d["uid"]), "manifest_uid": str(d["manifest_uid"]), "authority_id": d["authority_id"],
                        "trip_no": d["trip_no"], "scope": d["scope"], "type": d["manifest_type"], "version": d["version"]})
            await conn.execute("UPDATE brd.manifest_delivery SET status = 'SENT', attempts = attempts + 1, sent_at = now() WHERE id = $1", d["id"])
        else:
            failed = d["attempts"] + 1 >= PUSH_ATTEMPTS
            await conn.execute(
                """UPDATE brd.manifest_delivery SET attempts = attempts + 1, last_error = 'NO_ACTIVE_ENDPOINT',
                     status = CASE WHEN $2 THEN 'FAILED' ELSE status END, next_attempt_at = $3 WHERE id = $1""",
                d["id"], failed, datetime.now(timezone.utc) + timedelta(minutes=2 ** min(d["attempts"], 6)))
    return len(rows)


def view(m: asyncpg.Record) -> dict:
    return {"uid": str(m["uid"]), "scope": m["scope"], "type": m["manifest_type"], "version": m["version"], "status": m["status"],
            "border_point": m.get("border_point"), "persons": m["persons_count"], "issued_at": m["issued_at"],
            "content": m.get("content_type"), "signed": bool(m.get("payload_signature")),
            "sha256": bytes(m["payload_sha256"]).hex() if m["payload_sha256"] else None}
