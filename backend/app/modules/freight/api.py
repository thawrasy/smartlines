"""Truck transport of goods and containers (owner's request, October 2026; migration 1131).

    Truck owner (carrier company or individual operator; permission freight.operate, held by owners and carrier operations)
    GET|POST /api/carrier/freight/bills                         bills of lading: line, number, port, containers declared
    GET      /api/carrier/freight/bills/{uid}                   with its house bills and containers
    POST     /api/carrier/freight/bills/{uid}/house-bills       a forwarder's house bill (in-house BL)
    POST     /api/carrier/freight/bills/{uid}/containers        containers, no more than the bill declares
    POST     /api/carrier/freight/bills/{uid}/release           the customs release number
    GET|POST /api/carrier/freight/consignments                  consignments: seller, buyer, route, papers, cargo
    GET      /api/carrier/freight/consignments/{uid}            with containers, invoices, trucks, documents and what it lacks
    POST     /api/carrier/freight/consignments/{uid}/containers     from its bill of lading, or listed
    POST     /api/carrier/freight/consignments/{uid}/invoices       the commercial invoices it carries
    POST     /api/carrier/freight/consignments/{uid}/movements      a truck, its trailer and driver, its containers, the price
    POST     /api/carrier/freight/movements/{uid}/status            loading, in transit, at the border, delivered (who received)
    GET|POST /api/carrier/freight/rates                         the truck owner's prices; POST /rates/{uid}/archive
    GET|POST /api/carrier/freight/invoices                      transport invoices: the bill of lading, a container or the consignment
    POST     /api/carrier/freight/invoices/{uid}/void|paid
    GET|POST /api/carrier/freight/documents                     consignment notes and TCNs (one or several consignments)
    GET      /api/carrier/freight/documents/{doc_no}            POST /documents/{doc_no}/void
    Anyone
    GET /api/public/freight/shipping-lines
    GET /api/public/freight/rates?from_city=&to_city=&unit=     the active prices on a lane, by truck owner
    GET /api/public/freight/documents/{doc_no}?code=            a document checked with its code

The database keeps the rules (1131): valid container numbers, the bill's container count, a truck or trailer on one
active movement, the trailer's length, documents complete before they are issued and frozen after, a container never
invoiced twice. The freight switch (features.freight) opens all of it.
"""
import json
import uuid
from datetime import date
from typing import Literal, Optional

from fastapi import APIRouter, Depends, Query, Request
from pydantic import BaseModel, Field, field_validator

from ... import db, markets
from ...deps import Principal, base_context, context_for, require_portal
from ...errors import ApiError, forbidden, not_found

carrier = APIRouter(prefix="/api/carrier/freight", tags=["freight"])
public = APIRouter(prefix="/api/public/freight", tags=["freight"])

RouteKind = Literal["DOMESTIC", "PORT_IMPORT", "PORT_EXPORT", "EXPORT", "IMPORT", "TRANSIT_PORT_OUT", "TRANSIT_IN_PORT", "TRANSIT_LAND"]
CONTAINER = r"^[A-Z]{3}[UJZ][0-9]{7}$"
SIZE = r"^[24L][0-9A-Z][0-9A-Z]{2}$"
REF = r"^[A-Za-z0-9/ -]{2,40}$"
COUNTRY = r"^[A-Z]{2}$"
LOCODE = r"^[A-Z]{2}[A-Z0-9]{3}$"


def _j(v):
    return json.loads(v) if isinstance(v, str) else v


def _upper(v):
    return v.strip().upper() if isinstance(v, str) else v


def _company(pr: Principal, *perms: str) -> int:
    if not pr.company_id:
        raise forbidden("carrier staff only")
    if perms and not pr.permissions.intersection(perms):
        raise forbidden("missing permission: " + " | ".join(perms))
    return pr.company_id


READ = WRITE = ("freight.operate",)          # the company permission of the freight module (1030); freight.manage is the platform's


async def _id(conn, table: str, uid: uuid.UUID, what: str) -> int:
    i = await conn.fetchval(f"SELECT id FROM {table} WHERE uid = $1", uid)
    if i is None:
        raise not_found(what)
    return i


async def _station(conn, uid: Optional[uuid.UUID]) -> Optional[int]:
    if uid is None:
        return None
    i = await conn.fetchval("SELECT id FROM net.station WHERE uid = $1", uid)
    if i is None:
        raise not_found("station")
    return i


async def _city(conn, code: Optional[str]) -> Optional[int]:
    if code is None:
        return None
    i = await conn.fetchval("SELECT id FROM ref.city WHERE code = $1", code.upper())
    if i is None:
        raise not_found("city")
    return i


# ------------------------------------------------------------------ bills of lading
class BillIn(BaseModel):
    shipping_line: str = Field(pattern=r"^[A-Z0-9]{2,6}$")
    bl_no: str = Field(min_length=4, max_length=35)
    direction: Literal["IMPORT", "EXPORT", "TRANSIT"] = "IMPORT"
    container_count: int = Field(ge=0, le=999)
    vessel: Optional[str] = Field(default=None, max_length=80)
    voyage: Optional[str] = Field(default=None, max_length=30)
    port_of_loading: Optional[str] = Field(default=None, pattern=LOCODE)
    port_of_discharge: Optional[str] = Field(default=None, pattern=LOCODE)
    port_station_uid: Optional[uuid.UUID] = None
    consignee_name: Optional[str] = Field(default=None, max_length=200)
    notify_name: Optional[str] = Field(default=None, max_length=200)
    release_no: Optional[str] = Field(default=None, pattern=REF)
    release_date: Optional[date] = None
    cargo_description: Optional[str] = Field(default=None, max_length=500)

    _u = field_validator("bl_no", "shipping_line", mode="before")(_upper)


class HouseBillIn(BaseModel):
    hbl_no: str = Field(min_length=3, max_length=35)
    forwarder_name: str = Field(min_length=2, max_length=200)
    consignee_name: Optional[str] = Field(default=None, max_length=200)

    _u = field_validator("hbl_no", mode="before")(_upper)


class BoxIn(BaseModel):
    container_no: str = Field(pattern=CONTAINER)
    size_type: str = Field(pattern=SIZE)
    seal_no: Optional[str] = Field(default=None, pattern=r"^[A-Za-z0-9-]{3,20}$")
    gross_weight_kg: Optional[int] = Field(default=None, ge=1, le=40000)
    hbl_no: Optional[str] = Field(default=None, max_length=35)
    empty_return_depot: Optional[str] = Field(default=None, max_length=120)
    free_time_until: Optional[date] = None

    _u = field_validator("container_no", "size_type", "hbl_no", mode="before")(_upper)


class BoxesIn(BaseModel):
    containers: list[BoxIn] = Field(min_length=1, max_length=200)


class ReleaseIn(BaseModel):
    release_no: str = Field(pattern=REF)
    release_date: Optional[date] = None


async def _bill(conn, bl_id: int) -> dict:
    b = await conn.fetchrow(
        """SELECT b.uid, b.bl_no, sl.code AS shipping_line, sl.name AS shipping_line_name, b.direction, b.vessel, b.voyage,
                  b.port_of_loading, b.port_of_discharge, s.uid AS port_station_uid, s.name AS port_name, b.consignee_name, b.notify_name,
                  b.container_count, b.release_no, b.release_date, b.cargo_description, b.status, b.created_at
             FROM frt.bill_of_lading b JOIN frt.shipping_line sl ON sl.id = b.shipping_line_id LEFT JOIN net.station s ON s.id = b.port_station_id
            WHERE b.id = $1""", bl_id)
    hbls = await conn.fetch("SELECT hbl_no, forwarder_name, consignee_name FROM frt.house_bill WHERE bl_id = $1 ORDER BY hbl_no", bl_id)
    boxes = await conn.fetch(
        """SELECT c.container_no, c.size_type, c.seal_no, c.gross_weight_kg, h.hbl_no, c.empty_return_depot, c.free_time_until, c.status
             FROM frt.bl_container c LEFT JOIN frt.house_bill h ON h.id = c.house_bill_id WHERE c.bl_id = $1 ORDER BY c.container_no""", bl_id)
    return dict(b) | {"house_bills": [dict(h) for h in hbls], "containers": [dict(x) for x in boxes]}


@carrier.get("/bills")
async def list_bills(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT b.uid, b.bl_no, sl.code AS shipping_line, b.container_count, b.release_no, b.status, b.created_at,
                      (SELECT count(*) FROM frt.bl_container c WHERE c.bl_id = b.id AND c.status <> 'CANCELLED') AS listed
                 FROM frt.bill_of_lading b JOIN frt.shipping_line sl ON sl.id = b.shipping_line_id
                WHERE b.company_id = $1 ORDER BY b.created_at DESC LIMIT 200""", company)
    return {"bills": [dict(r) for r in rows]}


@carrier.post("/bills", status_code=201)
async def create_bill(body: BillIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        line = await conn.fetchval("SELECT id FROM frt.shipping_line WHERE code = $1 AND status = 'ACTIVE'", body.shipping_line)
        if line is None:
            raise ApiError(422, "SHIPPING_LINE_UNKNOWN", "no such shipping line")
        bl_id = await conn.fetchval(
            """INSERT INTO frt.bill_of_lading (company_id, shipping_line_id, bl_no, direction, container_count, vessel, voyage,
                 port_of_loading, port_of_discharge, port_station_id, consignee_name, notify_name, release_no, release_date,
                 cargo_description, status, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15,
                       CASE WHEN $13::text IS NULL THEN 'OPEN' ELSE 'RELEASED' END, $16) RETURNING id""",
            company, line, body.bl_no, body.direction, body.container_count, body.vessel, body.voyage, body.port_of_loading,
            body.port_of_discharge, await _station(conn, body.port_station_uid), body.consignee_name, body.notify_name, body.release_no,
            body.release_date, body.cargo_description, pr.user_id)
        out = await _bill(conn, bl_id)
    request.state.audit = {"action": "freight.bill", "object_type": "bill_of_lading", "object_id": bl_id, "reason": f"{body.shipping_line} {body.bl_no}"}
    return out


@carrier.get("/bills/{uid}")
async def get_bill(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _bill(conn, await _id(conn, "frt.bill_of_lading", uid, "bill of lading"))


@carrier.post("/bills/{uid}/house-bills", status_code=201)
async def add_house_bill(uid: uuid.UUID, body: HouseBillIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        bl_id = await _id(conn, "frt.bill_of_lading", uid, "bill of lading")
        await conn.execute("INSERT INTO frt.house_bill (bl_id, hbl_no, forwarder_name, consignee_name) VALUES ($1, $2, $3, $4)",
                           bl_id, body.hbl_no, body.forwarder_name, body.consignee_name)
        return await _bill(conn, bl_id)


@carrier.post("/bills/{uid}/containers", status_code=201)
async def add_bill_containers(uid: uuid.UUID, body: BoxesIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        bl_id = await _id(conn, "frt.bill_of_lading", uid, "bill of lading")
        for box in body.containers:
            hbl = None
            if box.hbl_no:
                hbl = await conn.fetchval("SELECT id FROM frt.house_bill WHERE bl_id = $1 AND hbl_no = $2", bl_id, box.hbl_no)
                if hbl is None:
                    raise ApiError(422, "HOUSE_BILL_UNKNOWN", f"no house bill {box.hbl_no} under this bill")
            await conn.execute(
                """INSERT INTO frt.bl_container (bl_id, house_bill_id, container_no, size_type, seal_no, gross_weight_kg, empty_return_depot,
                     free_time_until) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)""",
                bl_id, hbl, box.container_no, box.size_type, box.seal_no, box.gross_weight_kg, box.empty_return_depot, box.free_time_until)
        return await _bill(conn, bl_id)


@carrier.post("/bills/{uid}/release")
async def release_bill(uid: uuid.UUID, body: ReleaseIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        bl_id = await _id(conn, "frt.bill_of_lading", uid, "bill of lading")
        await conn.execute("""UPDATE frt.bill_of_lading SET release_no = $2, release_date = coalesce($3, current_date),
                                     status = CASE WHEN status = 'OPEN' THEN 'RELEASED' ELSE status END WHERE id = $1""",
                           bl_id, body.release_no, body.release_date)
        out = await _bill(conn, bl_id)
    request.state.audit = {"action": "freight.release", "object_type": "bill_of_lading", "object_id": bl_id, "reason": body.release_no}
    return out


# ------------------------------------------------------------------ consignments
class Party(BaseModel):
    name: str = Field(min_length=2, max_length=200)
    country: str = Field(pattern=COUNTRY)
    address: Optional[str] = Field(default=None, max_length=300)
    tax_no: Optional[str] = Field(default=None, max_length=40)


class Place(BaseModel):
    country: str = Field(default="SY", pattern=COUNTRY)
    city: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    station_uid: Optional[uuid.UUID] = None
    address: Optional[str] = Field(default=None, max_length=300)


class Cargo(BaseModel):
    category: str = Field(pattern=r"^[A-Z_]{2,20}$")
    description: str = Field(min_length=2, max_length=500)
    hs_code: Optional[str] = Field(default=None, pattern=r"^[0-9]{4,10}$")
    packages: Optional[int] = Field(default=None, ge=1)
    package_type: Optional[str] = Field(default=None, max_length=40)
    gross_weight_kg: float = Field(gt=0, le=1_000_000)
    net_weight_kg: Optional[float] = Field(default=None, gt=0)
    volume_m3: Optional[float] = Field(default=None, gt=0)
    un_number: Optional[str] = Field(default=None, pattern=r"^UN[0-9]{4}$")
    adr_class: Optional[str] = Field(default=None, pattern=r"^[1-9](\.[1-6])?$")
    temp_min_c: Optional[float] = None
    temp_max_c: Optional[float] = None
    declared_value: Optional[int] = Field(default=None, ge=0)
    value_currency: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")


class ConsignmentIn(BaseModel):
    route_kind: RouteKind
    load_type: Literal["FCL", "LCL", "BREAK_BULK", "BULK", "LIQUID", "VEHICLES"]
    shipper: Party
    consignee: Party
    notify_name: Optional[str] = Field(default=None, max_length=200)
    origin: Place
    destination: Place
    port_station_uid: Optional[uuid.UUID] = None
    exit_border_uid: Optional[uuid.UUID] = None
    entry_border_uid: Optional[uuid.UUID] = None
    arrival_port: Optional[str] = Field(default=None, pattern=LOCODE)
    bill_uid: Optional[uuid.UUID] = None
    hbl_no: Optional[str] = Field(default=None, max_length=35)
    export_permit_no: Optional[str] = Field(default=None, pattern=REF)
    export_permit_date: Optional[date] = None
    customs_declaration_no: Optional[str] = Field(default=None, pattern=REF)
    release_no: Optional[str] = Field(default=None, pattern=REF)
    tir_carnet_no: Optional[str] = Field(default=None, pattern=r"^[A-Z]{0,3}[0-9]{6,10}$")
    incoterm: Optional[Literal["EXW", "FCA", "CPT", "CIP", "DAP", "DPU", "DDP", "FAS", "FOB", "CFR", "CIF"]] = None
    freight_payer: Literal["SHIPPER", "CONSIGNEE", "THIRD_PARTY"] = "SHIPPER"
    cargo: Cargo


class InvoiceRefIn(BaseModel):
    invoice_no: str = Field(pattern=r"^[A-Za-z0-9/ -]{1,40}$")
    invoice_date: Optional[date] = None
    amount: Optional[int] = Field(default=None, ge=0)
    currency: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")


class ConsignmentBoxesIn(BaseModel):
    from_bill: bool = False                       # every container of the consignment's bill (or of its house bill)
    containers: list[BoxIn] = Field(default_factory=list, max_length=200)


class MovementIn(BaseModel):
    vehicle_uid: uuid.UUID
    trailer_uid: Optional[uuid.UUID] = None          # a trailer of the fleet (phase 3), or a hired one by its plate and length
    trailer_plate: Optional[str] = Field(default=None, min_length=2, max_length=20)
    trailer_capacity_ft: Optional[Literal[20, 40, 45]] = None
    driver_name: Optional[str] = Field(default=None, min_length=2, max_length=120)
    driver_uid: Optional[uuid.UUID] = None
    driver_licence_no: Optional[str] = Field(default=None, max_length=40)
    driver_mobile: Optional[str] = Field(default=None, pattern=r"^\+?[0-9]{8,15}$")
    container_nos: list[str] = Field(default_factory=list, max_length=3)
    rate_uid: Optional[uuid.UUID] = None
    price: Optional[int] = Field(default=None, ge=0)
    currency: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")     # the truck owner's market currency when left out


class StatusIn(BaseModel):
    status: Literal["LOADING", "IN_TRANSIT", "AT_BORDER", "DELIVERED", "CANCELLED"]
    station_uid: Optional[uuid.UUID] = None
    note: Optional[str] = Field(default=None, max_length=300)
    received_by: Optional[str] = Field(default=None, max_length=120)


async def _consignment(conn, cid: int) -> dict:
    c = await conn.fetchrow("SELECT uid, status, company_id FROM frt.consignment WHERE id = $1", cid)
    snap = _j(await conn.fetchval("SELECT frt.consignment_snapshot($1)::text", cid))
    moves = await conn.fetch(
        """SELECT m.uid, m.truck_plate, m.trailer_plate, m.trailer_capacity_ft, m.driver_name, m.price, m.currency, m.status,
                  m.loaded_at, m.delivered_at, m.pod_received_by, cp.legal_name AS carrier,
                  ARRAY(SELECT k.container_no FROM frt.movement_container x JOIN frt.consignment_container k ON k.id = x.consignment_container_id
                         WHERE x.movement_id = m.id ORDER BY k.container_no) AS containers
             FROM frt.truck_movement m JOIN iam.party cp ON cp.id = m.carrier_company_id WHERE m.consignment_id = $1 ORDER BY m.id""", cid)
    docs = await conn.fetch(
        """SELECT d.doc_no, d.doc_type, d.scope, d.version, d.status, d.issued_at FROM frt.transport_document d
             JOIN frt.document_consignment x ON x.document_id = d.id WHERE x.consignment_id = $1 ORDER BY d.issued_at""", cid)
    gaps = {t: list(await conn.fetchval("SELECT frt.document_gaps($1, $2)", cid, t) or []) for t in ("CONSIGNMENT_NOTE", "TCN")}
    return snap | {"uid": c["uid"], "status": c["status"], "movements": [dict(m) for m in moves], "documents": [dict(d) for d in docs],
                   "gaps": gaps}


@carrier.get("/consignments")
async def list_consignments(request: Request, status: Optional[str] = Query(default=None, max_length=20),
                            pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT c.uid, c.consignment_no, c.route_kind, c.load_type, c.shipper_name, c.consignee_name, c.dest_country, c.status,
                      c.created_at, (SELECT count(*) FROM frt.consignment_container k WHERE k.consignment_id = c.id AND k.status <> 'CANCELLED') AS containers,
                      (SELECT count(*) FROM frt.truck_movement m WHERE m.consignment_id = c.id AND m.status <> 'CANCELLED') AS trucks
                 FROM frt.consignment c WHERE ($1::text IS NULL OR c.status = $1) ORDER BY c.created_at DESC LIMIT 200""", status)
    return {"consignments": [dict(r) for r in rows]}


@carrier.post("/consignments", status_code=201)
async def create_consignment(body: ConsignmentIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        bl_id = hbl = None
        if body.bill_uid:
            bl_id = await _id(conn, "frt.bill_of_lading", body.bill_uid, "bill of lading")
            if body.hbl_no:
                hbl = await conn.fetchval("SELECT id FROM frt.house_bill WHERE bl_id = $1 AND hbl_no = $2", bl_id, body.hbl_no.upper())
                if hbl is None:
                    raise ApiError(422, "HOUSE_BILL_UNKNOWN", f"no house bill {body.hbl_no} under this bill")
        g = body.cargo
        cid = await conn.fetchval(
            """INSERT INTO frt.consignment (company_id, route_kind, load_type, shipper_name, shipper_country, shipper_address, shipper_tax_no,
                 consignee_name, consignee_country, consignee_address, consignee_tax_no, notify_name,
                 origin_country, origin_city_id, origin_station_id, origin_address, dest_country, dest_city_id, dest_station_id, dest_address,
                 port_station_id, exit_border_id, entry_border_id, arrival_port, bl_id, house_bill_id, export_permit_no, export_permit_date,
                 customs_declaration_no, release_no, tir_carnet_no, incoterm, freight_payer, cargo_category, cargo_description, hs_code,
                 packages, package_type, gross_weight_kg, net_weight_kg, volume_m3, un_number, adr_class, temp_min_c, temp_max_c,
                 declared_value, value_currency, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22, $23, $24, $25,
                       $26, $27, $28, $29, $30, $31, $32, $33, $34, $35, $36, $37, $38, $39, $40, $41, $42, $43, $44, $45, $46, $47, $48)
               RETURNING id""",
            company, body.route_kind, body.load_type, body.shipper.name, body.shipper.country, body.shipper.address, body.shipper.tax_no,
            body.consignee.name, body.consignee.country, body.consignee.address, body.consignee.tax_no, body.notify_name,
            body.origin.country, await _city(conn, body.origin.city), await _station(conn, body.origin.station_uid), body.origin.address,
            body.destination.country, await _city(conn, body.destination.city), await _station(conn, body.destination.station_uid),
            body.destination.address, await _station(conn, body.port_station_uid), await _station(conn, body.exit_border_uid),
            await _station(conn, body.entry_border_uid), body.arrival_port, bl_id, hbl, body.export_permit_no, body.export_permit_date,
            body.customs_declaration_no, body.release_no, body.tir_carnet_no, body.incoterm, body.freight_payer, g.category, g.description,
            g.hs_code, g.packages, g.package_type, g.gross_weight_kg, g.net_weight_kg, g.volume_m3, g.un_number, g.adr_class, g.temp_min_c,
            g.temp_max_c, g.declared_value, g.value_currency, pr.user_id)
        out = await _consignment(conn, cid)
    request.state.audit = {"action": "freight.consignment", "object_type": "consignment", "object_id": cid,
                           "reason": f"{body.route_kind}: {out['consignment_no']}"}
    return out


@carrier.get("/consignments/{uid}")
async def get_consignment(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        return await _consignment(conn, await _id(conn, "frt.consignment", uid, "consignment"))


@carrier.post("/consignments/{uid}/containers", status_code=201)
async def add_consignment_containers(uid: uuid.UUID, body: ConsignmentBoxesIn, request: Request,
                                     pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await _id(conn, "frt.consignment", uid, "consignment")
        if body.from_bill:
            c = await conn.fetchrow("SELECT bl_id, house_bill_id FROM frt.consignment WHERE id = $1", cid)
            if c["bl_id"] is None:
                raise ApiError(422, "NO_BILL", "the consignment has no bill of lading")
            await conn.execute(
                """INSERT INTO frt.consignment_container (consignment_id, bl_container_id, container_no, size_type)
                   SELECT $1, b.id, b.container_no, b.size_type FROM frt.bl_container b
                    WHERE b.bl_id = $2 AND b.status <> 'CANCELLED' AND ($3::bigint IS NULL OR b.house_bill_id = $3)
                      AND NOT EXISTS (SELECT 1 FROM frt.consignment_container k WHERE k.consignment_id = $1 AND k.container_no = b.container_no)""",
                cid, c["bl_id"], c["house_bill_id"])
        for box in body.containers:
            on_bill = await conn.fetchval(
                """SELECT b.id FROM frt.bl_container b JOIN frt.consignment c ON c.bl_id = b.bl_id
                    WHERE c.id = $1 AND b.container_no = $2""", cid, box.container_no)
            await conn.execute(
                """INSERT INTO frt.consignment_container (consignment_id, bl_container_id, container_no, size_type, seal_no, gross_weight_kg)
                   VALUES ($1, $2, $3, $4, $5, $6)""", cid, on_bill, box.container_no, box.size_type, box.seal_no, box.gross_weight_kg)
        return await _consignment(conn, cid)


@carrier.post("/consignments/{uid}/invoices", status_code=201)
async def add_commercial_invoice(uid: uuid.UUID, body: InvoiceRefIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await _id(conn, "frt.consignment", uid, "consignment")
        await conn.execute("INSERT INTO frt.consignment_invoice (consignment_id, invoice_no, invoice_date, amount, currency) VALUES ($1, $2, $3, $4, $5)",
                           cid, body.invoice_no, body.invoice_date, body.amount, body.currency)
        return await _consignment(conn, cid)


async def _price(conn, rate: Optional[dict], boxes: list, cons: dict, body: MovementIn) -> tuple[int, str, Optional[int]]:
    """The movement's price: the one given, or the truck owner's rate for its unit (a container each, the truck, the tons)."""
    if rate is None:
        if body.price is None:
            raise ApiError(422, "PRICE_REQUIRED", "give the price or a rate of yours")
        return body.price, body.currency or (await markets.of_party(conn, cons["company_id"])).currency, None
    unit = rate["unit"]
    if unit.startswith("CONTAINER_"):
        feet = int(unit.split("_")[1])
        n = sum(1 for b in boxes if {"2": 20, "4": 40, "L": 45}.get(b["size_type"][0]) == feet)
        if n == 0:
            raise ApiError(422, "RATE_UNIT", f"the rate is for {feet} ft containers and the truck carries none")
        return rate["price"] * n, rate["currency"], rate["id"]
    if unit == "TRUCK":
        return rate["price"], rate["currency"], rate["id"]
    if unit == "TON":
        kg = sum(b["gross_weight_kg"] or 0 for b in boxes) or float(cons["gross_weight_kg"])
        return int(round(rate["price"] * kg / 1000)), rate["currency"], rate["id"]
    raise ApiError(422, "RATE_UNIT", "a rate per bill of lading is invoiced, not put on a truck")


@carrier.post("/consignments/{uid}/movements", status_code=201)
async def add_movement(uid: uuid.UUID, body: MovementIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await _id(conn, "frt.consignment", uid, "consignment")
        cons = await conn.fetchrow("SELECT id, gross_weight_kg, $2::bigint AS company_id FROM frt.consignment WHERE id = $1", cid, company)
        v = await conn.fetchrow("SELECT id, plate_no, plate_country FROM fleet.vehicle WHERE uid = $1 AND company_id = $2", body.vehicle_uid, company)
        if v is None:
            raise not_found("truck")
        t = None
        if body.trailer_uid:
            t = await conn.fetchrow("SELECT id, plate_no, container_capacity FROM fleet.trailer WHERE uid = $1 AND company_id = $2",
                                    body.trailer_uid, company)
            if t is None:
                raise not_found("trailer")
        d = None
        if body.driver_uid:
            d = await conn.fetchrow(
                """SELECT p.id, p.legal_name, p.nationality FROM iam.party p JOIN fleet.crew_profile c ON c.party_id = p.id
                    WHERE p.uid = $1 AND c.company_id = $2""", body.driver_uid, company)
            if d is None:
                raise not_found("driver")
        boxes = []
        for no in body.container_nos:
            b = await conn.fetchrow("SELECT id, size_type, gross_weight_kg FROM frt.consignment_container WHERE consignment_id = $1 AND container_no = $2",
                                    cid, no.strip().upper())
            if b is None:
                raise ApiError(422, "CONTAINER_NOT_IN_CONSIGNMENT", f"container {no} is not of this consignment")
            boxes.append(b)
        rate = None
        if body.rate_uid:
            rate = await conn.fetchrow("SELECT id, unit, price, currency FROM frt.rate_card WHERE uid = $1 AND company_id = $2 AND status = 'ACTIVE'",
                                       body.rate_uid, company)
            if rate is None:
                raise not_found("rate")
        price, currency, rate_id = await _price(conn, rate, boxes, cons, body)
        mid = await conn.fetchval(
            """INSERT INTO frt.truck_movement (consignment_id, carrier_company_id, truck_vehicle_id, trailer_id, driver_party_id, truck_plate,
                 truck_plate_country, trailer_plate, trailer_capacity_ft, driver_name, driver_licence_no, driver_nationality, driver_mobile,
                 rate_card_id, price, currency, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, coalesce($7, 'SY'), $8, $9, $10, $11, $12, $13, $14, $15, $16, $17) RETURNING id""",
            cid, company, v["id"], t["id"] if t else None, d["id"] if d else None, v["plate_no"], v["plate_country"],
            t["plate_no"] if t else body.trailer_plate, t["container_capacity"] if t else body.trailer_capacity_ft,
            d["legal_name"] if d else body.driver_name, body.driver_licence_no,
            d["nationality"] if d else None, body.driver_mobile, rate_id, price, currency, pr.user_id)
        for b in boxes:
            await conn.execute("INSERT INTO frt.movement_container (movement_id, consignment_container_id) VALUES ($1, $2)", mid, b["id"])
        out = await _consignment(conn, cid)
    request.state.audit = {"action": "freight.movement", "object_type": "truck_movement", "object_id": mid, "reason": f"{v['plate_no']}: {price} {currency}"}
    return out


@carrier.post("/movements/{uid}/status")
async def movement_status(uid: uuid.UUID, body: StatusIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        mid = await _id(conn, "frt.truck_movement", uid, "truck movement")
        out = json.loads(await conn.fetchval("SELECT frt.set_movement_status($1, $2, $3, $4, $5)::text", mid, body.status,
                                             await _station(conn, body.station_uid), body.note, body.received_by))
    request.state.audit = {"action": "freight.movement_status", "object_type": "truck_movement", "object_id": mid, "reason": body.status}
    return out


# ------------------------------------------------------------------ the truck owner's prices
class RateIn(BaseModel):
    route_kind: Optional[RouteKind] = None
    from_city: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    from_station_uid: Optional[uuid.UUID] = None
    to_city: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    to_station_uid: Optional[uuid.UUID] = None
    to_country: Optional[str] = Field(default=None, pattern=COUNTRY)
    unit: Literal["CONTAINER_20", "CONTAINER_40", "CONTAINER_45", "TRUCK", "TON", "BL"]
    price: int = Field(gt=0)
    currency: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")     # the truck owner's market currency when left out
    includes_empty_return: bool = False
    free_waiting_hours: int = Field(default=24, ge=0, le=240)
    waiting_per_day: Optional[int] = Field(default=None, ge=0)
    note: Optional[str] = Field(default=None, max_length=300)
    valid_from: Optional[date] = None
    valid_to: Optional[date] = None


RATE_SQL = """SELECT r.uid, r.route_kind, fc.code AS from_city, fs.code AS from_station, fs.name AS from_station_name, tc.code AS to_city,
                     ts.code AS to_station, ts.name AS to_station_name, r.to_country, r.unit, r.price, r.currency, r.includes_empty_return,
                     r.free_waiting_hours, r.waiting_per_day, r.note, lower(r.valid) AS valid_from, upper(r.valid) AS valid_to, r.status,
                     cp.legal_name AS carrier, cp.uid AS carrier_uid
                FROM frt.rate_card r JOIN iam.party cp ON cp.id = r.company_id
                LEFT JOIN ref.city fc ON fc.id = r.from_city_id LEFT JOIN net.station fs ON fs.id = r.from_station_id
                LEFT JOIN ref.city tc ON tc.id = r.to_city_id LEFT JOIN net.station ts ON ts.id = r.to_station_id"""


@carrier.get("/rates")
async def list_rates(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(RATE_SQL + " WHERE r.company_id = $1 AND r.status <> 'ARCHIVED' ORDER BY r.created_at DESC", company)
    return {"rates": [dict(r) for r in rows]}


@carrier.post("/rates", status_code=201)
async def create_rate(body: RateIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        rid = await conn.fetchval(
            """INSERT INTO frt.rate_card (company_id, route_kind, from_city_id, from_station_id, to_city_id, to_station_id, to_country, unit,
                 price, currency, includes_empty_return, free_waiting_hours, waiting_per_day, note, valid)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, daterange(coalesce($15, current_date), $16)) RETURNING id""",
            company, body.route_kind, await _city(conn, body.from_city), await _station(conn, body.from_station_uid),
            await _city(conn, body.to_city), await _station(conn, body.to_station_uid), body.to_country, body.unit, body.price,
            body.currency or (await markets.of_party(conn, company)).currency, body.includes_empty_return, body.free_waiting_hours,
            body.waiting_per_day, body.note, body.valid_from, body.valid_to)
        row = await conn.fetchrow(RATE_SQL + " WHERE r.id = $1", rid)
    request.state.audit = {"action": "freight.rate", "object_type": "rate_card", "object_id": rid, "reason": f"{body.unit} {body.price} {body.currency}"}
    return dict(row)


@carrier.post("/rates/{uid}/archive")
async def archive_rate(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        n = await conn.execute("UPDATE frt.rate_card SET status = 'ARCHIVED' WHERE uid = $1 AND company_id = $2", uid, company)
    if n.endswith(" 0"):
        raise not_found("rate")
    return {"ok": True}


# ------------------------------------------------------------------ transport invoices
class TransportInvoiceIn(BaseModel):
    consignment_uid: uuid.UUID
    basis: Literal["BL", "CONTAINER", "CONSIGNMENT"]
    container_no: Optional[str] = Field(default=None, pattern=CONTAINER)

    _u = field_validator("container_no", mode="before")(_upper)


class ReasonIn(BaseModel):
    reason: str = Field(min_length=3, max_length=300)


@carrier.get("/invoices")
async def list_invoices(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    company = _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT i.uid, i.invoice_no, i.basis, c.consignment_no, b.bl_no, i.bill_to_name, i.total, i.currency, i.status, i.issued_at,
                      (SELECT count(*) FROM frt.transport_invoice_line l WHERE l.invoice_id = i.id) AS lines
                 FROM frt.transport_invoice i JOIN frt.consignment c ON c.id = i.consignment_id LEFT JOIN frt.bill_of_lading b ON b.id = i.bl_id
                WHERE i.carrier_company_id = $1 ORDER BY i.issued_at DESC LIMIT 200""", company)
    return {"invoices": [dict(r) for r in rows]}


@carrier.post("/invoices", status_code=201)
async def issue_invoice(body: TransportInvoiceIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        cid = await _id(conn, "frt.consignment", body.consignment_uid, "consignment")
        box = None
        if body.basis == "CONTAINER":
            box = await conn.fetchval("SELECT id FROM frt.consignment_container WHERE consignment_id = $1 AND container_no = $2", cid, body.container_no)
            if box is None:
                raise ApiError(422, "INVOICE_BASIS", "name a container of the consignment")
        out = json.loads(await conn.fetchval("SELECT frt.issue_transport_invoice($1, $2, $3)::text", cid, body.basis, box))
    request.state.audit = {"action": "freight.invoice", "object_type": "transport_invoice", "reason": f"{out['invoice_no']}: {out['total']} {out['currency']}"}
    return out


async def _invoice_status(uid: uuid.UUID, status: str, reason: Optional[str], request: Request, pr: Principal) -> dict:
    company = _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        row = await conn.fetchrow(
            """UPDATE frt.transport_invoice SET status = $3, void_reason = coalesce($4, void_reason)
                WHERE uid = $1 AND carrier_company_id = $2 AND status = 'ISSUED' RETURNING invoice_no, status""", uid, company, status, reason)
    if row is None:
        raise ApiError(409, "INVOICE_NOT_OPEN", "only an issued invoice of yours is paid or voided")
    request.state.audit = {"action": f"freight.invoice_{status.lower()}", "object_type": "transport_invoice", "reason": (reason or row["invoice_no"])[:120]}
    return dict(row)


@carrier.post("/invoices/{uid}/void")
async def void_invoice(uid: uuid.UUID, body: ReasonIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    return await _invoice_status(uid, "VOID", body.reason, request, pr)


@carrier.post("/invoices/{uid}/paid")
async def paid_invoice(uid: uuid.UUID, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    return await _invoice_status(uid, "PAID", None, request, pr)


# ------------------------------------------------------------------ the platform's documents
class DocumentIn(BaseModel):
    doc_type: Literal["CONSIGNMENT_NOTE", "TCN"]
    consignment_uids: list[uuid.UUID] = Field(min_length=1, max_length=50)
    replaces: Optional[str] = Field(default=None, max_length=40)       # the number of the document this one replaces


@carrier.get("/documents")
async def list_documents(request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        rows = await conn.fetch(
            """SELECT d.uid, d.doc_no, d.doc_type, d.scope, d.version, d.status, d.issued_at,
                      (d.snapshot -> 'totals') AS totals FROM frt.transport_document d ORDER BY d.issued_at DESC LIMIT 200""")
    return {"documents": [dict(r) | {"totals": _j(r["totals"])} for r in rows]}


@carrier.post("/documents", status_code=201)
async def issue_document(body: DocumentIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        ids = [await _id(conn, "frt.consignment", u, "consignment") for u in body.consignment_uids]
        old = None
        if body.replaces:
            old = await conn.fetchval("SELECT id FROM frt.transport_document WHERE doc_no = $1", body.replaces)
            if old is None:
                raise not_found("document")
        out = json.loads(await conn.fetchval("SELECT frt.issue_document($1, $2::bigint[], $3)::text", body.doc_type, ids, old))
    request.state.audit = {"action": "freight.document", "object_type": "transport_document", "reason": f"{out['doc_no']} ({len(ids)})"}
    return out


@carrier.get("/documents/{doc_no}")
async def get_document(doc_no: str, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *READ)
    async with db.transaction(context_for(request, pr)) as conn:
        d = await conn.fetchrow(
            """SELECT uid, doc_no, doc_type, scope, version, status, void_reason, verify_code, encode(sha256, 'hex') AS sha256, issued_at, snapshot
                 FROM frt.transport_document WHERE doc_no = $1""", doc_no)
    if d is None:
        raise not_found("document")
    return dict(d) | {"snapshot": _j(d["snapshot"])}


@carrier.post("/documents/{doc_no}/void")
async def void_document(doc_no: str, body: ReasonIn, request: Request, pr: Principal = Depends(require_portal("OPERATOR"))):
    _company(pr, *WRITE)
    async with db.transaction(context_for(request, pr)) as conn:
        did = await conn.fetchval("SELECT id FROM frt.transport_document WHERE doc_no = $1", doc_no)
        if did is None:
            raise not_found("document")
        out = json.loads(await conn.fetchval("SELECT frt.void_document($1, $2)::text", did, body.reason))
    request.state.audit = {"action": "freight.document_void", "object_type": "transport_document", "object_id": did, "reason": body.reason[:120]}
    return out


# ------------------------------------------------------------------ anyone
@public.get("/shipping-lines")
async def shipping_lines(request: Request):
    async with db.transaction(base_context(request)) as conn:
        rows = await conn.fetch("SELECT code, name, country FROM frt.shipping_line WHERE status = 'ACTIVE' ORDER BY name")
    return {"shipping_lines": [dict(r) for r in rows]}


@public.get("/rates")
async def lane_rates(request: Request, unit: Optional[str] = Query(default=None, pattern=r"^[A-Z_0-9]{2,12}$"),
                     from_city: Optional[str] = Query(default=None, pattern=r"^[A-Z]{3}$"),
                     to_city: Optional[str] = Query(default=None, pattern=r"^[A-Z]{3}$"),
                     to_country: Optional[str] = Query(default=None, pattern=COUNTRY)):
    """The truck owners' active prices on a lane, lowest first: what a customer compares before choosing."""
    async with db.transaction(base_context(request)) as conn:
        rows = await conn.fetch(
            RATE_SQL + """ WHERE r.status = 'ACTIVE' AND r.valid @> current_date AND ($1::text IS NULL OR r.unit = $1)
                            AND ($2::text IS NULL OR fc.code = $2 OR fs.city_id = (SELECT id FROM ref.city WHERE code = $2))
                            AND ($3::text IS NULL OR tc.code = $3 OR ts.city_id = (SELECT id FROM ref.city WHERE code = $3))
                            AND ($4::text IS NULL OR r.to_country = $4)
                          ORDER BY r.currency, r.price LIMIT 100""", unit, from_city, to_city, to_country)
    return {"rates": [{k: v for k, v in dict(r).items() if k != "status"} for r in rows]}


@public.get("/documents/{doc_no}")
async def verify_document(doc_no: str, request: Request, code: str = Query(min_length=10, max_length=10)):
    async with db.transaction(base_context(request)) as conn:
        out = await conn.fetchval("SELECT frt.verify_document($1, $2)::text", doc_no, code)
    if out is None:
        raise not_found("document")
    return json.loads(out)
