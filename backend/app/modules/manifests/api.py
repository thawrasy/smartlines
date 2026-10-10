"""Trip manifests issued by the carrier (study 11.10) and their deliveries to authorities.

    Carrier
    GET  /api/carrier/trips/{trip_uid}/manifests     versions of the trip's manifests with their deliveries
    POST /api/carrier/trips/{trip_uid}/manifests     issue: PRE_DEPARTURE, PRE_ARRIVAL (international), FINAL, AMENDMENT or CANCELLATION
    GET  /api/carrier/manifests/{uid}                one version: people (documents masked), crew, vehicle, cargo, deliveries
    GET  /api/carrier/manifests/{uid}/verify         the hash recomputed from the sealed rows and the platform's signature checked
    GET  /api/carrier/manifests/{uid}/export         the signed snapshot as CSV, to print or hand over when offline

    Platform (routing rules themselves are records of the trip_manifests module, approved by a second officer)
    GET  /api/admin/manifests                        recent manifests of every carrier with their delivery status
    POST /api/admin/manifests/deliveries/{uid}/done  a delivery handled by hand: sent, or acknowledged with the authority's reference
"""
from __future__ import annotations

import csv
import io
import uuid
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from ...modular import features
from . import service

carrier = APIRouter(prefix="/api/carrier", tags=["manifests"])
platform = APIRouter(prefix="/api/admin/manifests", tags=["manifests"])
operator = require_portal("OPERATOR")
staff = require_portal("PLATFORM")


async def _on() -> None:
    if not await features.is_on("trip_manifests"):
        raise ApiError(404, "MODULE_DISABLED", "module trip_manifests is switched off")


def _need(pr: Principal, *codes: str) -> None:
    if not pr.permissions.intersection(codes):
        raise forbidden(f"missing permission: {' or '.join(codes)}")


class IssueIn(BaseModel):
    type: Literal["PRE_DEPARTURE", "PRE_ARRIVAL", "FINAL", "AMENDMENT", "CANCELLATION"] = "PRE_DEPARTURE"


async def _trip(conn, pr: Principal, uid: uuid.UUID):
    t = await conn.fetchrow("SELECT id, uid, trip_no, company_id, status FROM ops.trip WHERE uid = $1 AND company_id = $2", uid, pr.company_id)
    if t is None:
        raise not_found("trip")
    return t


async def _deliveries(conn, manifest_ids: list[int]) -> dict[int, list[dict]]:
    rows = await conn.fetch(
        """SELECT d.manifest_id, d.uid, d.channel, d.status, d.ack_ref, d.sent_at, d.acknowledged_at, a.name AS authority
             FROM brd.manifest_delivery d JOIN sec.authority_profile a ON a.id = d.authority_id
            WHERE d.manifest_id = ANY($1::bigint[]) ORDER BY a.name""", manifest_ids)
    out: dict[int, list[dict]] = {}
    for r in rows:
        out.setdefault(r["manifest_id"], []).append(
            {"uid": str(r["uid"]), "authority": r["authority"], "channel": r["channel"], "status": r["status"], "ack_ref": r["ack_ref"],
             "sent_at": r["sent_at"], "acknowledged_at": r["acknowledged_at"]})
    return out


_LIST = """SELECT m.id, m.uid, m.scope, m.manifest_type, m.version, m.status, m.persons_count, m.issued_at, m.payload_sha256,
                  m.content_type, m.payload_signature, s.code AS border_point
             FROM brd.manifest m LEFT JOIN net.station s ON s.id = m.border_point_id"""


@carrier.get("/trips/{trip_uid}/manifests")
async def trip_manifests(trip_uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "manifest.issue", "manifest.view", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trip(conn, pr, trip_uid)
        rows = await conn.fetch(_LIST + " WHERE m.trip_id = $1 ORDER BY m.border_point_id NULLS FIRST, m.version DESC", t["id"])
        dl = await _deliveries(conn, [r["id"] for r in rows])
        scope, countries, _ = await service.scope_of(conn, t["id"])
    return {"trip_no": t["trip_no"], "scope": scope, "countries": countries,
            "manifests": [service.view(r) | {"deliveries": dl.get(r["id"], [])} for r in rows]}


@carrier.post("/trips/{trip_uid}/manifests", status_code=201)
async def issue(trip_uid: uuid.UUID, body: IssueIn, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "manifest.issue")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        t = await _trip(conn, pr, trip_uid)
        if t["status"] in ("DRAFT", "CANCELLED") and body.type != "CANCELLATION":
            raise ApiError(409, "TRIP_NOT_PUBLISHED", "a manifest is issued for a published trip")
        out = await service.issue(conn, ctx, t, body.type, pr.user_id)
    request.state.audit = {"action": "manifest.issue", "object_type": "trip", "object_id": t["id"], "reason": body.type}
    return {"trip_no": t["trip_no"], "issued": out}


async def _manifest(conn, pr: Principal, uid: uuid.UUID):
    m = await conn.fetchrow(
        """SELECT m.id, m.uid, m.trip_id, m.scope, m.manifest_type, m.version, m.status, m.persons_count, m.issued_at, m.payload_sha256,
                  m.content_type, m.payload_signature, m.signing_kid, m.canonical_version, s.code AS border_point, t.trip_no
             FROM brd.manifest m JOIN ops.trip t ON t.id = m.trip_id LEFT JOIN net.station s ON s.id = m.border_point_id
            WHERE m.uid = $1 AND t.company_id = $2""", uid, pr.company_id)
    if m is None:
        raise not_found("manifest")
    return m


@carrier.get("/manifests/{uid}")
async def manifest_detail(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "manifest.issue", "manifest.view", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        m = await _manifest(conn, pr, uid)
        people = await conn.fetch(
            """SELECT mp.person_role, mp.full_name, mp.age_category, mp.nationality, mp.birth_date, mp.sex, mp.doc_type, mp.doc_last4,
                      mp.seat_label, se.code AS embark, sd.code AS disembark
                 FROM brd.manifest_person mp LEFT JOIN net.station se ON se.id = mp.embark_station_id
                 LEFT JOIN net.station sd ON sd.id = mp.disembark_station_id WHERE mp.manifest_id = $1 ORDER BY mp.person_role DESC, mp.id""",
            m["id"])
        vehicle = await conn.fetchrow("SELECT plate_no, plate_country, chassis_no FROM brd.manifest_vehicle WHERE manifest_id = $1", m["id"])
        cargo = await conn.fetch(
            """SELECT s.tracking_no, c.cargo_category, c.cargo_description, c.hs_code, c.declared_weight_kg, c.packages
                 FROM brd.manifest_cargo c LEFT JOIN ship.shipment s ON s.id = c.shipment_id WHERE c.manifest_id = $1 ORDER BY c.id""",
            m["id"])
        dl = await _deliveries(conn, [m["id"]])
    request.state.audit = {"action": "manifest.view", "object_type": "brd.manifest", "object_id": m["id"]}
    return service.view(m) | {"trip_no": m["trip_no"], "people": [dict(p) for p in people], "vehicle": dict(vehicle) if vehicle else None,
                              "cargo": [{**dict(c), "declared_weight_kg": float(c["declared_weight_kg"])} for c in cargo],
                              "deliveries": dl.get(m["id"], [])}


@carrier.get("/manifests/{uid}/verify")
async def manifest_verify(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    """Whether the manifest still is what was issued: its hash recomputed from the sealed rows, and the signature."""
    await _on()
    _need(pr, "manifest.issue", "manifest.view", "trip.publish")
    ctx = context_for(request, pr)
    async with db.transaction(ctx) as conn:
        m = await _manifest(conn, pr, uid)
        return await service.verify(conn, ctx, m)


@carrier.get("/manifests/{uid}/export")
async def manifest_export(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    await _on()
    _need(pr, "manifest.issue", "manifest.view", "trip.publish")
    async with db.transaction(context_for(request, pr)) as conn:
        m = await _manifest(conn, pr, uid)
        people = await conn.fetch(
            """SELECT mp.person_role, mp.full_name, mp.age_category, mp.nationality, mp.birth_date, mp.sex, mp.doc_type, mp.doc_last4,
                      mp.seat_label, se.code AS embark, sd.code AS disembark
                 FROM brd.manifest_person mp LEFT JOIN net.station se ON se.id = mp.embark_station_id
                 LEFT JOIN net.station sd ON sd.id = mp.disembark_station_id WHERE mp.manifest_id = $1 ORDER BY mp.person_role DESC, mp.id""",
            m["id"])
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["trip", m["trip_no"], "scope", m["scope"], "type", m["manifest_type"], "version", m["version"],
                "issued_at", m["issued_at"].isoformat() if m["issued_at"] else "", "sha256", bytes(m["payload_sha256"]).hex() if m["payload_sha256"] else ""])
    w.writerow(["role", "full_name", "category", "nationality", "birth_date", "sex", "doc_type", "doc_last4", "seat", "embark", "disembark"])
    for p in people:
        w.writerow([p["person_role"], p["full_name"], p["age_category"] or "", p["nationality"], p["birth_date"] or "", p["sex"] or "",
                    p["doc_type"] or "", p["doc_last4"] or "", p["seat_label"] or "", p["embark"] or "", p["disembark"] or ""])
    request.state.audit = {"action": "manifest.export", "object_type": "brd.manifest", "object_id": m["id"]}
    name = f"manifest-{m['trip_no'].replace('/', '-')}-v{m['version']}.csv"
    return Response(("\ufeff" + buf.getvalue()).encode("utf-8"), media_type="text/csv; charset=utf-8",
                    headers={"Content-Disposition": f'attachment; filename="{name}"'})


# ------------------------------------------------------------------ platform

class DoneIn(BaseModel):
    status: Literal["SENT", "ACKNOWLEDGED", "REJECTED"]
    ack_ref: Optional[str] = Field(default=None, max_length=80)
    reason: Optional[str] = Field(default=None, max_length=300)


@platform.get("")
async def recent(request: Request, status: Optional[str] = None, pr: Principal = Depends(staff)):
    await _on()
    _need(pr, "manifest.routes", "border.manage")
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT m.id, m.uid, m.scope, m.manifest_type, m.version, m.status, m.persons_count, m.issued_at, m.payload_sha256,
                      s.code AS border_point, t.trip_no, cp.legal_name AS carrier
                 FROM brd.manifest m JOIN ops.trip t ON t.id = m.trip_id JOIN iam.party cp ON cp.id = t.company_id
                 LEFT JOIN net.station s ON s.id = m.border_point_id
                WHERE m.issued_at IS NOT NULL AND ($1::text IS NULL OR m.status = $1) ORDER BY m.issued_at DESC LIMIT 200""", status)
        dl = await _deliveries(conn, [r["id"] for r in rows])
    return {"manifests": [service.view(r) | {"trip_no": r["trip_no"], "carrier": r["carrier"], "deliveries": dl.get(r["id"], [])}
                          for r in rows]}


@platform.post("/deliveries/{uid}/done")
async def delivery_done(uid: uuid.UUID, body: DoneIn, request: Request, pr: Principal = Depends(staff)):
    await _on()
    _need(pr, "manifest.routes", "border.manage")
    async with db.transaction(context_for(request, pr)) as conn:
        d = await conn.fetchrow("SELECT id, status, channel FROM brd.manifest_delivery WHERE uid = $1", uid)
        if d is None:
            raise not_found("delivery")
        if d["status"] in ("ACKNOWLEDGED", "REJECTED"):
            raise ApiError(409, "ALREADY_ANSWERED", "this delivery was already answered")
        await conn.execute(
            """UPDATE brd.manifest_delivery SET status = $2, ack_ref = coalesce($3, ack_ref), reject_reason = $4,
                 sent_at = coalesce(sent_at, now()), acknowledged_at = CASE WHEN $2 = 'SENT' THEN NULL ELSE now() END WHERE id = $1""",
            d["id"], body.status, body.ack_ref, body.reason)
    request.state.audit = {"action": "manifest.delivery_done", "object_type": "brd.manifest_delivery", "object_id": d["id"],
                           "reason": body.status}
    return {"status": body.status}
