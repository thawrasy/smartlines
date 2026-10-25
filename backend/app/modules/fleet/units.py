"""One fleet for every kind of vehicle (owner's notes of 25 October 2026, migration 1173).

A company defines all its vehicles from one screen: coaches, city buses, minibuses, vans, rigid trucks, tractor heads
with the trailers they pull, rental cars and taxis. What it may define follows the lines its contract with the platform
opened (iam.company_fleet_line). Every vehicle carries its licences, its insurance policy with the insurer picked from
the registry (checked with the insurer's system later), its service plans and its workshop visits; a vehicle in the
workshop takes no trip and no rental until it is back.

    GET  /api/fleet/options                         the company's lines, the uses they allow, trailer kinds, rental classes
    GET  /api/fleet/units                           every vehicle and trailer with its next expiry, insurance and service
    POST /api/fleet/vehicles                        a vehicle of any use, with its insurance
    GET  /api/fleet/vehicles/{uid}                  a vehicle with its licences, insurance, plans, visits, coupling, history
    POST /api/fleet/vehicles/{uid}/insurance        a new policy (renewal or a change of insurer)
    POST /api/fleet/vehicles/{uid}/odometer         an odometer reading
    POST /api/fleet/vehicles/{uid}/service-plans    a service plan: oil change, periodic service, tyres, inspection, contract
    PATCH /api/fleet/service-plans/{uid}            a plan corrected or ended
    POST /api/fleet/vehicles/{uid}/maintenance      sent to the workshop (the vehicle is in maintenance)
    POST /api/fleet/maintenance/{uid}/return        back from the workshop
    POST /api/fleet/trailers                        a trailer with its plate, licence and insurance
    GET|PATCH /api/fleet/trailers/{uid}             a trailer with its licences and history, or corrected
    POST /api/fleet/trailers/{uid}/licences         a licence of a trailer
    POST /api/fleet/couplings                       a tractor head pulls a trailer, with its driver
    POST /api/fleet/couplings/{id}/end              uncoupled
    GET  /api/fleet/rentals                         the rental desk: bookings, their car, driver and kilometres
    POST /api/fleet/rentals/{uid}/confirm           a car (and a driver for a hire with one) given to a booking
    POST /api/fleet/rentals/{uid}/pickup            handed over: odometer and fuel recorded, the contract opened
    POST /api/fleet/rentals/{uid}/return            taken back: odometer and fuel, extra kilometres charged, contract closed
    GET|POST /api/admin/companies/{uid}/fleet-lines the platform opens a line by contract
    POST /api/admin/fleet-lines/{id}/end            and closes it
"""
import uuid
from datetime import date, datetime, timezone
from typing import Literal, Optional

import asyncpg
from fastapi import APIRouter, Depends, Request
from pydantic import BaseModel, Field, model_validator

from ... import db
from ...deps import Principal, context_for, require_portal
from ...errors import ApiError, forbidden, not_found
from ...modular import features
from ...util import row_dict, rows
from ..registry import service as registry
from . import service as fleet

carrier = APIRouter(prefix="/api/fleet", tags=["fleet"])
platform = APIRouter(prefix="/api/admin", tags=["fleet"])
operator = require_portal("OPERATOR")
staff = require_portal("PLATFORM")

Use = Literal["COACH", "CITY_BUS", "MINIBUS", "VAN", "TRUCK", "TRACTOR", "RENTAL_CAR", "TAXI"]
Line = Literal["BUS", "TRUCK", "RENTAL", "TAXI"]
Fuel = Literal["PETROL", "DIESEL", "HYBRID", "PLUG_IN_HYBRID", "ELECTRIC", "RANGE_EXTENDER", "GAS"]
LINE_OF = {"COACH": "BUS", "CITY_BUS": "BUS", "MINIBUS": "BUS", "VAN": "BUS", "TRUCK": "TRUCK", "TRACTOR": "TRUCK",
           "RENTAL_CAR": "RENTAL", "TAXI": "TAXI"}
BUS_USES = ("COACH", "CITY_BUS", "MINIBUS", "VAN")
TRAILER_TYPES = ["FLATBED", "CURTAIN", "REEFER", "TANKER", "CONTAINER_CHASSIS", "LOWBED", "TIPPER", "BOX"]


def _need(pr: Principal) -> int:
    if not pr.company_id:
        raise forbidden("a company's fleet")
    if "vehicle.manage" not in pr.permissions:
        raise forbidden("missing permission: vehicle.manage")
    return pr.company_id


def _staff(pr: Principal) -> None:
    if not pr.permissions.intersection({"company.approve", "reference.manage"}):
        raise forbidden("missing permission: company.approve")


MODULE_OF = {"TRUCK": "cargo", "RENTAL": "car_rental"}       # lines whose tables open with a platform module


async def _module(line: str) -> None:
    key = MODULE_OF.get(line)
    if key and not await features.is_on(key):
        raise ApiError(409, "MODULE_DISABLED", f"the platform has not switched on the {key} module yet")


async def _lines(conn: asyncpg.Connection, company: int) -> list[str]:
    return [r["line"] for r in await conn.fetch(
        "SELECT line FROM iam.company_fleet_line WHERE company_id = $1 AND valid @> CURRENT_DATE AND ended_at IS NULL ORDER BY line", company)]


# ------------------------------------------------------------------ options and the list
@carrier.get("/options")
async def options(request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        lines = [x for x in await _lines(conn, company) if x not in MODULE_OF or await features.is_on(MODULE_OF[x])]
        classes = await conn.fetch("SELECT code, name FROM rent.rental_vehicle_class ORDER BY sort") if "RENTAL" in lines else []
        branches = await conn.fetch(
            """SELECT b.id, s.name FROM rent.rental_branch b JOIN net.station s ON s.id = b.station_id
                WHERE b.company_id = $1 AND b.status = 'ACTIVE' ORDER BY s.name""", company) if "RENTAL" in lines else []
    return {"lines": lines, "uses": [u for u, line in LINE_OF.items() if line in lines], "trailer_types": TRAILER_TYPES if "TRUCK" in lines else [],
            "rental_classes": rows(classes), "rental_branches": rows(branches)}


@carrier.get("/units")
async def units(request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        vehicles = await conn.fetch(
            """SELECT v.uid, v.fleet_use, v.vehicle_class, v.plate_no, v.make, v.model, v.manufacture_year, v.colour, v.fuel_type,
                      v.passenger_seats, v.cargo_capacity_kg, v.odometer_km, v.status, v.block_reason,
                      (SELECT min(l.expiry_date) FROM fleet.license_record l
                        WHERE l.subject_type = 'VEHICLE' AND l.subject_id = v.id AND l.status <> 'SUSPENDED') AS next_expiry,
                      (SELECT max(upper(p.period)) FROM fleet.insurance_policy p WHERE p.vehicle_id = v.id AND p.status = 'VALID') AS insured_until,
                      (SELECT i.name_en FROM fleet.insurance_policy p JOIN ref.insurer i ON i.id = p.insurer_id
                        WHERE p.vehicle_id = v.id AND p.status = 'VALID' ORDER BY upper(p.period) DESC LIMIT 1) AS insurer,
                      (SELECT bool_or(d.due) FROM fleet.service_plan p, fleet.service_due(p, v.odometer_km) d
                        WHERE p.vehicle_id = v.id AND p.status = 'ACTIVE') AS service_due,
                      (SELECT t.plate_no FROM fleet.truck_combination c JOIN fleet.trailer t ON t.id = c.trailer_id
                        WHERE c.truck_vehicle_id = v.id AND c.period @> now()) AS trailer_plate
                 FROM fleet.vehicle v WHERE v.company_id = $1 ORDER BY v.fleet_use, v.plate_no""", company)
        trailers = await conn.fetch(
            """SELECT t.uid, t.plate_no, t.plate_country, t.trailer_type, t.payload_kg, t.axles, t.status, t.make, t.manufacture_year,
                      (SELECT min(l.expiry_date) FROM fleet.license_record l WHERE l.subject_type = 'TRAILER' AND l.subject_id = t.id) AS next_expiry,
                      (SELECT max(upper(p.period)) FROM fleet.insurance_policy p WHERE p.trailer_id = t.id AND p.status = 'VALID') AS insured_until,
                      (SELECT v.plate_no FROM fleet.truck_combination c JOIN fleet.vehicle v ON v.id = c.truck_vehicle_id
                        WHERE c.trailer_id = t.id AND c.period @> now()) AS head_plate
                 FROM fleet.trailer t WHERE t.company_id = $1 ORDER BY t.plate_no""", company)
    return {"vehicles": rows(vehicles), "trailers": rows(trailers)}


# ------------------------------------------------------------------ a vehicle of any use
class InsuranceIn(BaseModel):
    insurer_uid: uuid.UUID                                # from the registry of insurance companies (1156)
    policy_no: str = Field(min_length=3, max_length=40)
    coverage_type: Literal["THIRD_PARTY", "COMPREHENSIVE"] = "THIRD_PARTY"
    passenger_cover: bool = False
    cargo_cover: bool = False
    issue_date: date
    expiry_date: date

    @model_validator(mode="after")
    def _dates(self):
        if self.expiry_date <= self.issue_date:
            raise ValueError("the policy ends before it starts")
        return self


class FleetVehicleIn(BaseModel):
    fleet_use: Use
    plate_no: str = Field(min_length=3, max_length=20)
    plate_country: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    chassis_no: str = Field(min_length=5, max_length=40)
    machine_no: Optional[str] = Field(default=None, min_length=3, max_length=40)
    model_uid: Optional[uuid.UUID] = None
    trim_uid: Optional[uuid.UUID] = None
    make: Optional[str] = Field(default=None, max_length=60)
    model: Optional[str] = Field(default=None, max_length=60)
    manufacture_year: Optional[int] = Field(default=None, ge=1970, le=2100)
    colour: Optional[str] = Field(default=None, min_length=2, max_length=30)
    fuel_type: Optional[Fuel] = None
    odometer_km: Optional[int] = Field(default=None, ge=0, le=9999999)
    ownership_type: Literal["OWNED", "LEASED"] = "OWNED"
    # buses: the seat layout gives the seats
    seat_layout_uid: Optional[uuid.UUID] = None
    # cars and taxis: seats; trucks: payload, weights and axles
    passenger_seats: Optional[int] = Field(default=None, ge=1, le=99)
    cargo_capacity_kg: Optional[int] = Field(default=None, ge=0, le=60000)
    gvw_kg: Optional[int] = Field(default=None, ge=1000, le=100000)
    tare_kg: Optional[int] = Field(default=None, ge=500, le=40000)
    axle_config: Optional[str] = Field(default=None, pattern=r"^[0-9]x[0-9]$")
    # rental cars: their class and home branch
    rental_class: Optional[str] = Field(default=None, max_length=20)
    home_branch_id: Optional[int] = None
    # a taxi's licence from the transport authority
    taxi_licence_no: Optional[str] = Field(default=None, min_length=3, max_length=40)
    taxi_licence_expiry: Optional[date] = None
    insurance: InsuranceIn


async def _insure(conn: asyncpg.Connection, company: int, body: InsuranceIn, vehicle: Optional[int] = None,
                  trailer: Optional[int] = None) -> str:
    """A policy with the insurer from the registry, and the insurance licence that governs eligibility (030)."""
    if body.expiry_date <= date.today():
        raise ApiError(422, "INSURANCE_EXPIRED", "a valid insurance policy is required")
    insurer = await registry.picked_insurer(conn, body.insurer_uid)
    try:
        uid = await conn.fetchval(
            """INSERT INTO fleet.insurance_policy (vehicle_id, trailer_id, insurer_id, policy_no, coverage_type, passenger_cover,
                 cargo_cover, period, source, status)
               VALUES ($1, $2, $3, $4, $5, $6, $7, daterange($8, $9), 'MANUAL', 'VALID') RETURNING uid""",
            vehicle, trailer, insurer["id"], body.policy_no.strip(), body.coverage_type, body.passenger_cover, body.cargo_cover,
            body.issue_date, body.expiry_date)
    except asyncpg.UniqueViolationError as e:
        raise ApiError(409, "POLICY_EXISTS", "this insurer already has a policy with this number") from e
    await conn.execute(
        """INSERT INTO fleet.license_record (company_id, subject_type, subject_id, subject_vehicle_id, subject_trailer_id,
             license_type, license_no, issuer, issue_date, expiry_date, status)
           VALUES ($1, $2, $3, $4, $5, 'INSURANCE', $6, $7, $8, $9, 'VALID')""",
        company, "VEHICLE" if vehicle else "TRAILER", vehicle or trailer, vehicle, trailer, body.policy_no.strip(),
        insurer["name_en"], body.issue_date, body.expiry_date)
    return str(uid)


@carrier.post("/vehicles", status_code=201)
async def add_vehicle(body: FleetVehicleIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    use = body.fleet_use
    async with db.transaction(context_for(request, pr)) as conn:
        if LINE_OF[use] not in await _lines(conn, company):
            raise ApiError(403, "FLEET_LINE_CLOSED", "the company's contract does not cover this kind of vehicle")
        await _module(LINE_OF[use])
        klass = "BUS" if use in BUS_USES else "TRUCK" if use in ("TRUCK", "TRACTOR") else "CAR"
        vtype = use if use in BUS_USES else "OTHER"
        layout_id, seats = None, body.passenger_seats
        if use in BUS_USES:
            layout_id, seats = await fleet.layout_for_new_vehicle(conn, body.seat_layout_uid, body.passenger_seats)
        elif klass == "CAR" and not seats:
            raise ApiError(422, "SEATS_REQUIRED", "give the car's passenger seats")
        model_id = trim_id = None
        if body.model_uid is not None:
            m = await conn.fetchrow("SELECT id, vehicle_class FROM ref.vehicle_model WHERE uid = $1 AND status = 'ACTIVE'", body.model_uid)
            if m is None:
                raise ApiError(422, "MODEL_UNKNOWN", "choose a vehicle model from the list, or ask the platform to add it")
            model_id = m["id"]
            if body.trim_uid is not None:
                trim_id = await conn.fetchval("SELECT id FROM ref.vehicle_trim WHERE uid = $1 AND model_id = $2 AND status = 'ACTIVE'",
                                              body.trim_uid, model_id)
                if trim_id is None:
                    raise ApiError(422, "TRIM_UNKNOWN", "choose a trim of the vehicle's model")
        if use == "RENTAL_CAR" and not body.rental_class:
            raise ApiError(422, "RENTAL_CLASS_REQUIRED", "choose the car's rental class")
        if use == "TAXI" and not (body.taxi_licence_no and body.taxi_licence_expiry):
            raise ApiError(422, "TAXI_LICENCE_REQUIRED", "give the taxi licence number and its expiry")
        try:
            vid = await conn.fetchval(
                """INSERT INTO fleet.vehicle (company_id, vehicle_class, vehicle_type, fleet_use, make, model, model_id, trim_id,
                     manufacture_year, plate_no, plate_country, chassis_no, machine_no, passenger_seats, seat_layout_id,
                     cargo_capacity_kg, colour, fuel_type, odometer_km, odometer_at, ownership_type, owner_party_id, status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19,
                           CASE WHEN $19::integer IS NULL THEN NULL ELSE now() END, $20, $1, 'ACTIVE') RETURNING id""",
                company, klass, vtype, use, body.make, body.model, model_id, trim_id, body.manufacture_year, body.plate_no.strip(),
                body.plate_country, body.chassis_no.strip().upper(), body.machine_no, seats or 0, layout_id, body.cargo_capacity_kg or 0,
                body.colour, body.fuel_type, body.odometer_km, body.ownership_type)
        except asyncpg.UniqueViolationError as e:
            raise ApiError(409, "VEHICLE_EXISTS", "another vehicle has this plate or chassis number") from e
        if klass == "TRUCK":
            await conn.execute(
                """INSERT INTO fleet.truck_unit (vehicle_id, axle_config, gvw_kg, tare_kg, fuel_type)
                   VALUES ($1, $2, $3, $4, $5)""", vid, body.axle_config, body.gvw_kg, body.tare_kg, body.fuel_type)
        if use == "RENTAL_CAR":
            await conn.execute(
                """INSERT INTO rent.rental_fleet (vehicle_id, company_id, rental_class, home_branch_id, status)
                   VALUES ($1, $2, $3, $4, 'AVAILABLE')""", vid, company, body.rental_class, body.home_branch_id)
        if use == "TAXI":
            await conn.execute(
                """INSERT INTO fleet.license_record (company_id, subject_type, subject_id, subject_vehicle_id, license_type, license_no,
                     issuer, issue_date, expiry_date, status)
                   VALUES ($1, 'VEHICLE', $2, $2, 'TAXI', $3, 'Transport authority', CURRENT_DATE, $4, 'VALID')""",
                company, vid, body.taxi_licence_no, body.taxi_licence_expiry)
        await _insure(conn, company, body.insurance, vehicle=vid)
        uid = await conn.fetchval("SELECT uid FROM fleet.vehicle WHERE id = $1", vid)
    request.state.audit = {"action": "vehicle.create", "object_type": "vehicle", "object_id": vid, "reason": use}
    return {"uid": str(uid)}


async def _vehicle(conn: asyncpg.Connection, company: int, uid: uuid.UUID, lock: bool = False) -> asyncpg.Record:
    v = await conn.fetchrow(f"SELECT * FROM fleet.vehicle WHERE uid = $1 AND company_id = $2{' FOR UPDATE' if lock else ''}", uid, company)
    if v is None:
        raise not_found("vehicle")
    return v


@carrier.get("/vehicles/{uid}")
async def vehicle(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, company, uid)
        licences = await conn.fetch(
            """SELECT uid, license_type, license_no, issuer, issue_date, expiry_date, status FROM fleet.license_record
                WHERE subject_type = 'VEHICLE' AND subject_id = $1 ORDER BY license_type, expiry_date DESC""", v["id"])
        policies = await conn.fetch(
            """SELECT p.uid, coalesce(i.name_en, p.insurer_name) AS insurer, i.name_ar AS insurer_ar, p.policy_no, p.coverage_type,
                      p.passenger_cover, p.cargo_cover, lower(p.period) AS issue_date, upper(p.period) AS expiry_date, p.status,
                      p.source, p.verified_at
                 FROM fleet.insurance_policy p LEFT JOIN ref.insurer i ON i.id = p.insurer_id
                WHERE p.vehicle_id = $1 ORDER BY upper(p.period) DESC""", v["id"])
        plans = await conn.fetch(
            """SELECT p.uid, p.kind, p.every_km, p.every_months, p.last_km, p.last_date, p.provider, p.contract_no, p.contract_until,
                      p.notes, p.status, d.next_km, d.next_date, d.due
                 FROM fleet.service_plan p, fleet.service_due(p, $2) d WHERE p.vehicle_id = $1 ORDER BY p.status, p.kind""",
            v["id"], v["odometer_km"])
        visits = await conn.fetch(
            """SELECT m.uid, m.kind, m.workshop, m.sent_at, m.odometer_out, m.expected_back, m.returned_at, m.odometer_in, m.cost,
                      m.currency, m.notes, p.uid AS plan_uid
                 FROM fleet.maintenance_visit m LEFT JOIN fleet.service_plan p ON p.id = m.plan_id
                WHERE m.vehicle_id = $1 ORDER BY m.sent_at DESC LIMIT 50""", v["id"])
        coupling = await conn.fetchrow(
            """SELECT c.id, t.uid AS trailer_uid, t.plate_no AS trailer_plate, lower(c.period) AS since
                 FROM fleet.truck_combination c JOIN fleet.trailer t ON t.id = c.trailer_id
                WHERE c.truck_vehicle_id = $1 AND c.period @> now()""", v["id"])
        truck = await conn.fetchrow("SELECT axle_config, gvw_kg, tare_kg FROM fleet.truck_unit WHERE vehicle_id = $1", v["id"])
        rental = await conn.fetchrow("SELECT rental_class, home_branch_id, status FROM rent.rental_fleet WHERE vehicle_id = $1", v["id"])
        history = await conn.fetch(
            """SELECT c.changed_at, c.field, c.old_value, c.new_value, c.reason, u.email AS changed_by
                 FROM fleet.vehicle_change c LEFT JOIN iam.app_user u ON u.id = c.changed_by
                WHERE c.vehicle_id = $1 ORDER BY c.changed_at DESC, c.id DESC LIMIT 200""", v["id"])
    out = row_dict(v)
    for k in ("id", "company_id", "owner_party_id", "seat_layout_id", "model_id", "trim_id", "change_reason"):
        out.pop(k, None)
    return {"vehicle": out, "licences": rows(licences), "insurance": rows(policies), "service_plans": rows(plans),
            "maintenance": rows(visits), "coupling": row_dict(coupling) if coupling else None,
            "truck": row_dict(truck) if truck else None, "rental": row_dict(rental) if rental else None, "history": rows(history)}


@carrier.post("/vehicles/{uid}/insurance", status_code=201)
async def add_insurance(uid: uuid.UUID, body: InsuranceIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, company, uid)
        out = await _insure(conn, company, body, vehicle=v["id"])
    request.state.audit = {"action": "vehicle.insurance", "object_type": "vehicle", "object_id": v["id"]}
    return {"uid": out}


class OdometerIn(BaseModel):
    odometer_km: int = Field(ge=0, le=9999999)


@carrier.post("/vehicles/{uid}/odometer")
async def odometer(uid: uuid.UUID, body: OdometerIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, company, uid, lock=True)
        if v["odometer_km"] is not None and body.odometer_km < v["odometer_km"]:
            raise ApiError(422, "ODOMETER_BACKWARDS", "the reading is below the last one", last=v["odometer_km"])
        await conn.execute("UPDATE fleet.vehicle SET odometer_km = $2, odometer_at = now() WHERE id = $1", v["id"], body.odometer_km)
    return {"uid": str(uid), "odometer_km": body.odometer_km}


# ------------------------------------------------------------------ service plans and the workshop
class PlanIn(BaseModel):
    kind: Literal["OIL_CHANGE", "PERIODIC", "TYRES", "INSPECTION", "CONTRACT", "OTHER"]
    every_km: Optional[int] = Field(default=None, ge=100, le=500000)
    every_months: Optional[int] = Field(default=None, ge=1, le=120)
    last_km: Optional[int] = Field(default=None, ge=0)
    last_date: Optional[date] = None
    provider: Optional[str] = Field(default=None, min_length=2, max_length=120)
    contract_no: Optional[str] = Field(default=None, min_length=2, max_length=60)
    contract_until: Optional[date] = None
    notes: Optional[str] = Field(default=None, max_length=500)


class PlanEdit(BaseModel):
    every_km: Optional[int] = Field(default=None, ge=100, le=500000)
    every_months: Optional[int] = Field(default=None, ge=1, le=120)
    last_km: Optional[int] = Field(default=None, ge=0)
    last_date: Optional[date] = None
    provider: Optional[str] = Field(default=None, min_length=2, max_length=120)
    contract_no: Optional[str] = Field(default=None, min_length=2, max_length=60)
    contract_until: Optional[date] = None
    notes: Optional[str] = Field(default=None, max_length=500)
    status: Optional[Literal["ACTIVE", "ENDED"]] = None


@carrier.post("/vehicles/{uid}/service-plans", status_code=201)
async def add_plan(uid: uuid.UUID, body: PlanIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    if body.kind != "CONTRACT" and not (body.every_km or body.every_months):
        raise ApiError(422, "PLAN_INTERVAL", "give the distance or the months between services")
    if body.kind == "CONTRACT" and not (body.provider and body.contract_no):
        raise ApiError(422, "PLAN_CONTRACT", "a maintenance contract names its provider and number")
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, company, uid)
        out = await conn.fetchval(
            """INSERT INTO fleet.service_plan (company_id, vehicle_id, kind, every_km, every_months, last_km, last_date, provider,
                 contract_no, contract_until, notes, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12) RETURNING uid""",
            company, v["id"], body.kind, body.every_km, body.every_months, body.last_km if body.last_km is not None else v["odometer_km"],
            body.last_date or date.today(), body.provider, body.contract_no, body.contract_until, body.notes, pr.user_id)
    return {"uid": str(out)}


@carrier.patch("/service-plans/{uid}")
async def edit_plan(uid: uuid.UUID, body: PlanEdit, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    given = body.model_dump(exclude_unset=True)
    if not given:
        raise ApiError(422, "NOTHING_TO_CHANGE", "give at least one field to change")
    async with db.transaction(context_for(request, pr)) as conn:
        pid = await conn.fetchval("SELECT id FROM fleet.service_plan WHERE uid = $1 AND company_id = $2", uid, company)
        if pid is None:
            raise not_found("service plan")
        cols = list(given)
        try:
            await conn.execute(f"UPDATE fleet.service_plan SET {', '.join(f'{c} = ${i + 2}' for i, c in enumerate(cols))} WHERE id = $1",
                               pid, *[given[c] for c in cols])
        except asyncpg.CheckViolationError as e:
            raise ApiError(422, "PLAN_INTERVAL", "a plan keeps a distance or months between services, or a contract") from e
    return {"uid": str(uid), "changed": cols}


class SendIn(BaseModel):
    kind: Literal["OIL_CHANGE", "PERIODIC", "TYRES", "INSPECTION", "REPAIR", "ACCIDENT", "OTHER"]
    plan_uid: Optional[uuid.UUID] = None
    workshop: Optional[str] = Field(default=None, min_length=2, max_length=120)
    odometer_km: Optional[int] = Field(default=None, ge=0)
    expected_back: Optional[date] = None
    notes: Optional[str] = Field(default=None, max_length=500)


class ReturnIn(BaseModel):
    odometer_km: Optional[int] = Field(default=None, ge=0)
    cost: Optional[int] = Field(default=None, ge=0)
    currency: Optional[str] = Field(default=None, pattern=r"^[A-Z]{3}$")
    notes: Optional[str] = Field(default=None, max_length=500)


@carrier.post("/vehicles/{uid}/maintenance", status_code=201)
async def send(uid: uuid.UUID, body: SendIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, company, uid)
        plan = None
        if body.plan_uid is not None:
            plan = await conn.fetchval("SELECT id FROM fleet.service_plan WHERE uid = $1 AND vehicle_id = $2", body.plan_uid, v["id"])
            if plan is None:
                raise not_found("service plan")
        if await conn.fetchval("""SELECT EXISTS (SELECT 1 FROM ops.trip WHERE vehicle_id = $1 AND status IN ('BOARDING', 'DEPARTED'))""", v["id"]):
            raise ApiError(409, "VEHICLE_ON_TRIP", "the vehicle is on a trip; send it when the trip ends")
        try:
            out = await conn.fetchval(
                """INSERT INTO fleet.maintenance_visit (company_id, vehicle_id, plan_id, kind, workshop, odometer_out, expected_back,
                     notes, opened_by) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING uid""",
                company, v["id"], plan, body.kind, body.workshop, body.odometer_km, body.expected_back, body.notes, pr.user_id)
        except asyncpg.ExclusionViolationError as e:
            raise ApiError(409, "VEHICLE_HELD", "the vehicle already has an out-of-service period from now") from e
        later = await conn.fetchval(
            """SELECT count(*) FROM ops.trip WHERE vehicle_id = $1 AND departure_at > now() AND status IN ('DRAFT', 'PUBLISHED')""", v["id"])
    request.state.audit = {"action": "vehicle.maintenance", "object_type": "vehicle", "object_id": v["id"], "reason": body.kind}
    return {"uid": str(out), "status": "IN_MAINTENANCE", "trips_to_reassign": later}


@carrier.post("/maintenance/{uid}/return")
async def back(uid: uuid.UUID, body: ReturnIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        m = await conn.fetchrow("SELECT * FROM fleet.maintenance_visit WHERE uid = $1 AND company_id = $2 FOR UPDATE", uid, company)
        if m is None:
            raise not_found("workshop visit")
        if m["returned_at"] is not None:
            raise ApiError(409, "VISIT_CLOSED", "the vehicle is already back")
        if body.odometer_km is not None and m["odometer_out"] is not None and body.odometer_km < m["odometer_out"]:
            raise ApiError(422, "ODOMETER_BACKWARDS", "the reading is below the one when it was sent")
        await conn.execute(
            """UPDATE fleet.maintenance_visit SET returned_at = now(), odometer_in = $2, cost = $3, currency = $4,
                      notes = coalesce($5, notes), closed_by = $6 WHERE id = $1""",
            m["id"], body.odometer_km, body.cost, body.currency, body.notes, pr.user_id)
    request.state.audit = {"action": "vehicle.maintenance_return", "object_type": "vehicle", "object_id": m["vehicle_id"]}
    return {"uid": str(uid), "status": "ACTIVE"}


# ------------------------------------------------------------------ trailers and couplings
class TrailerIn(BaseModel):
    plate_no: str = Field(min_length=3, max_length=20)
    plate_country: str = Field(default="SY", pattern=r"^[A-Z]{2}$")
    chassis_no: Optional[str] = Field(default=None, min_length=5, max_length=40)
    trailer_type: Literal["FLATBED", "CURTAIN", "REEFER", "TANKER", "CONTAINER_CHASSIS", "LOWBED", "TIPPER", "BOX"]
    payload_kg: int = Field(gt=0, le=80000)
    axles: int = Field(ge=1, le=8)
    volume_m3: Optional[float] = Field(default=None, gt=0, le=200)
    length_m: Optional[float] = Field(default=None, gt=0, le=30)
    container_capacity: Optional[Literal[20, 40]] = None
    make: Optional[str] = Field(default=None, max_length=60)
    manufacture_year: Optional[int] = Field(default=None, ge=1970, le=2100)
    licence_no: str = Field(min_length=3, max_length=40)
    licence_issuer: str = Field(default="Transport authority", min_length=2, max_length=120)
    licence_issue: date
    licence_expiry: date
    insurance: Optional[InsuranceIn] = None


class TrailerEdit(BaseModel):
    plate_no: Optional[str] = Field(default=None, min_length=3, max_length=20)
    plate_country: Optional[str] = Field(default=None, pattern=r"^[A-Z]{2}$")
    chassis_no: Optional[str] = Field(default=None, min_length=5, max_length=40)
    trailer_type: Optional[Literal["FLATBED", "CURTAIN", "REEFER", "TANKER", "CONTAINER_CHASSIS", "LOWBED", "TIPPER", "BOX"]] = None
    payload_kg: Optional[int] = Field(default=None, gt=0, le=80000)
    axles: Optional[int] = Field(default=None, ge=1, le=8)
    make: Optional[str] = Field(default=None, max_length=60)
    manufacture_year: Optional[int] = Field(default=None, ge=1970, le=2100)
    status: Optional[Literal["ACTIVE", "RETIRED"]] = None
    reason: Optional[str] = Field(default=None, max_length=500)


class LicenceIn(BaseModel):
    license_type: Literal["TRANSPORT", "INSPECTION", "CROSS_BORDER", "OTHER"]
    license_no: str = Field(min_length=3, max_length=40)
    issuer: str = Field(min_length=2, max_length=120)
    issue_date: date
    expiry_date: date


async def _trailer(conn: asyncpg.Connection, company: int, uid: uuid.UUID) -> asyncpg.Record:
    t = await conn.fetchrow("SELECT * FROM fleet.trailer WHERE uid = $1 AND company_id = $2", uid, company)
    if t is None:
        raise not_found("trailer")
    return t


async def _licence(conn: asyncpg.Connection, company: int, trailer: int, body: LicenceIn) -> str:
    if body.expiry_date <= body.issue_date:
        raise ApiError(422, "LICENCE_DATES", "the licence ends before it starts")
    return str(await conn.fetchval(
        """INSERT INTO fleet.license_record (company_id, subject_type, subject_id, subject_trailer_id, license_type, license_no, issuer,
             issue_date, expiry_date, status)
           VALUES ($1, 'TRAILER', $2, $2, $3, $4, $5, $6, $7, 'VALID') RETURNING uid""",
        company, trailer, body.license_type, body.license_no.strip(), body.issuer, body.issue_date, body.expiry_date))


@carrier.post("/trailers", status_code=201)
async def add_trailer(body: TrailerIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        if "TRUCK" not in await _lines(conn, company):
            raise ApiError(403, "FLEET_LINE_CLOSED", "the company's contract does not cover trucks")
        await _module("TRUCK")
        try:
            tid = await conn.fetchval(
                """INSERT INTO fleet.trailer (company_id, plate_no, plate_country, chassis_no, trailer_type, payload_kg, axles, volume_m3,
                     length_m, container_capacity, make, manufacture_year, ownership_type, status)
                   VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, 'OWNED', 'ACTIVE') RETURNING id""",
                company, body.plate_no.strip(), body.plate_country, body.chassis_no, body.trailer_type, body.payload_kg, body.axles,
                body.volume_m3, body.length_m, body.container_capacity, body.make, body.manufacture_year)
        except asyncpg.UniqueViolationError as e:
            raise ApiError(409, "TRAILER_EXISTS", "another trailer has this plate") from e
        await _licence(conn, company, tid, LicenceIn(license_type="TRANSPORT", license_no=body.licence_no, issuer=body.licence_issuer,
                                                     issue_date=body.licence_issue, expiry_date=body.licence_expiry))
        if body.insurance:
            await _insure(conn, company, body.insurance, trailer=tid)
        uid = await conn.fetchval("SELECT uid FROM fleet.trailer WHERE id = $1", tid)
    request.state.audit = {"action": "trailer.create", "object_type": "trailer", "object_id": tid}
    return {"uid": str(uid)}


@carrier.get("/trailers/{uid}")
async def trailer(uid: uuid.UUID, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trailer(conn, company, uid)
        licences = await conn.fetch(
            """SELECT uid, license_type, license_no, issuer, issue_date, expiry_date, status FROM fleet.license_record
                WHERE subject_type = 'TRAILER' AND subject_id = $1 ORDER BY license_type, expiry_date DESC""", t["id"])
        policies = await conn.fetch(
            """SELECT p.uid, coalesce(i.name_en, p.insurer_name) AS insurer, p.policy_no, p.coverage_type, lower(p.period) AS issue_date,
                      upper(p.period) AS expiry_date, p.status FROM fleet.insurance_policy p LEFT JOIN ref.insurer i ON i.id = p.insurer_id
                WHERE p.trailer_id = $1 ORDER BY upper(p.period) DESC""", t["id"])
        history = await conn.fetch(
            """SELECT c.changed_at, c.field, c.old_value, c.new_value, c.reason, u.email AS changed_by
                 FROM fleet.trailer_change c LEFT JOIN iam.app_user u ON u.id = c.changed_by
                WHERE c.trailer_id = $1 ORDER BY c.changed_at DESC, c.id DESC LIMIT 200""", t["id"])
    out = row_dict(t)
    for k in ("id", "company_id", "owner_party_id", "change_reason"):
        out.pop(k, None)
    return {"trailer": out, "licences": rows(licences), "insurance": rows(policies), "history": rows(history)}


@carrier.patch("/trailers/{uid}")
async def edit_trailer(uid: uuid.UUID, body: TrailerEdit, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    given = body.model_dump(exclude_unset=True)
    reason = (given.pop("reason", None) or "").strip()
    if not given:
        raise ApiError(422, "NOTHING_TO_CHANGE", "give at least one field to change")
    if any(k in given for k in ("plate_no", "plate_country", "chassis_no")) and len(reason) < 3:
        raise ApiError(422, "TRAILER_CHANGE_REASON", "changing the plate or chassis number needs its reason")
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trailer(conn, company, uid)
        if t["status"] == "BLOCKED" and "status" in given:
            raise ApiError(409, "TRAILER_HELD", "a blocked trailer is released by the platform")
        cols = list(given)
        try:
            await conn.execute(f"UPDATE fleet.trailer SET {', '.join(f'{c} = ${i + 2}' for i, c in enumerate(cols))}, "
                               f"change_reason = ${len(cols) + 2} WHERE id = $1", t["id"], *[given[c] for c in cols], reason or None)
        except asyncpg.UniqueViolationError as e:
            raise ApiError(409, "TRAILER_EXISTS", "another trailer has this plate") from e
    request.state.audit = {"action": "trailer.edit", "object_type": "trailer", "object_id": t["id"], "reason": (reason or ", ".join(cols))[:300]}
    return {"uid": str(uid), "changed": cols}


@carrier.post("/trailers/{uid}/licences", status_code=201)
async def add_trailer_licence(uid: uuid.UUID, body: LicenceIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trailer(conn, company, uid)
        return {"uid": await _licence(conn, company, t["id"], body)}


@carrier.post("/trailers/{uid}/insurance", status_code=201)
async def add_trailer_insurance(uid: uuid.UUID, body: InsuranceIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        t = await _trailer(conn, company, uid)
        return {"uid": await _insure(conn, company, body, trailer=t["id"])}


class CouplingIn(BaseModel):
    tractor_uid: uuid.UUID
    trailer_uid: uuid.UUID
    driver_uid: Optional[uuid.UUID] = None


@carrier.post("/couplings", status_code=201)
async def couple(body: CouplingIn, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    await _module("TRUCK")
    async with db.transaction(context_for(request, pr)) as conn:
        v = await _vehicle(conn, company, body.tractor_uid)
        if v["fleet_use"] not in ("TRACTOR", "TRUCK"):
            raise ApiError(422, "NOT_A_TRUCK", "only a truck or a tractor head pulls a trailer")
        if v["status"] != "ACTIVE":
            raise ApiError(409, "VEHICLE_NOT_AVAILABLE", "the head is not active")
        t = await _trailer(conn, company, body.trailer_uid)
        if t["status"] != "ACTIVE":
            raise ApiError(409, "TRAILER_NOT_AVAILABLE", "the trailer is not active")
        driver = None
        if body.driver_uid is not None:
            driver = await conn.fetchval(
                """SELECT c.party_id FROM fleet.crew_profile c JOIN iam.party p ON p.id = c.party_id
                    WHERE p.uid = $1 AND c.company_id = $2 AND c.crew_type = 'DRIVER'""", body.driver_uid, company)
            if driver is None:
                raise not_found("driver")
        if not await conn.fetchval("SELECT EXISTS (SELECT 1 FROM fleet.truck_unit WHERE vehicle_id = $1)", v["id"]):
            await conn.execute("INSERT INTO fleet.truck_unit (vehicle_id) VALUES ($1)", v["id"])
        try:
            cid = await conn.fetchval(
                """INSERT INTO fleet.truck_combination (company_id, truck_vehicle_id, trailer_id, driver_party_id, period)
                   VALUES ($1, $2, $3, $4, tstzrange(now(), NULL)) RETURNING id""", company, v["id"], t["id"], driver)
        except asyncpg.ExclusionViolationError as e:
            raise ApiError(409, "ALREADY_COUPLED", "the head or the trailer is coupled to another; uncouple it first") from e
    request.state.audit = {"action": "truck.couple", "object_type": "vehicle", "object_id": v["id"]}
    return {"id": cid}


@carrier.post("/couplings/{cid}/end")
async def uncouple(cid: int, request: Request, pr: Principal = Depends(operator)):
    company = _need(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        done = await conn.fetchval(
            """UPDATE fleet.truck_combination SET period = tstzrange(lower(period), now())
                WHERE id = $1 AND company_id = $2 AND period @> now() RETURNING id""", cid, company)
        if done is None:
            raise not_found("coupling")
    return {"id": cid, "ended": True}


# ------------------------------------------------------------------ the rental desk
async def _rental(pr: Principal) -> int:
    await _module("RENTAL")
    company = _need(pr) if "vehicle.manage" in pr.permissions else pr.company_id
    if not company or not pr.permissions.intersection({"vehicle.manage", "rental.operate"}):
        raise forbidden("missing permission: rental.operate")
    return company


async def _booking(conn: asyncpg.Connection, company: int, uid: uuid.UUID) -> asyncpg.Record:
    b = await conn.fetchrow("SELECT * FROM rent.rental_booking WHERE uid = $1 AND company_id = $2 FOR UPDATE", uid, company)
    if b is None:
        raise not_found("rental booking")
    return b


@carrier.get("/rentals")
async def rentals(request: Request, pr: Principal = Depends(operator)):
    company = await _rental(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        recs = await conn.fetch(
            """SELECT b.uid, b.rental_class, lower(b.period) AS starts_at, upper(b.period) AS ends_at, b.quoted_total, b.currency,
                      b.status, b.with_driver, rp.legal_name AS renter, v.uid AS vehicle_uid, v.plate_no, dp.legal_name AS driver,
                      r.unlimited_km, r.km_included_per_day, r.extra_km_price, c.contract_no, c.final_amount, c.status AS contract_status,
                      d.km_out, d.km_in, d.driven, d.allowed, d.extra, d.extra_charge
                 FROM rent.rental_booking b LEFT JOIN iam.party rp ON rp.id = b.renter_party_id
                 LEFT JOIN fleet.vehicle v ON v.id = b.vehicle_id LEFT JOIN iam.party dp ON dp.id = b.driver_party_id
                 LEFT JOIN rent.rental_rate r ON r.id = b.rate_id LEFT JOIN rent.rental_contract c ON c.booking_id = b.id
                 LEFT JOIN LATERAL rent.hire_distance(c.id) d ON c.id IS NOT NULL
                WHERE b.company_id = $1 ORDER BY (b.status IN ('PENDING', 'CONFIRMED', 'PICKED_UP')) DESC, lower(b.period) DESC LIMIT 300""",
            company)
    return {"rentals": rows(recs)}


class ConfirmIn(BaseModel):
    vehicle_uid: uuid.UUID
    driver_uid: Optional[uuid.UUID] = None


class HandoverIn(BaseModel):
    odometer_km: int = Field(ge=0, le=9999999)
    fuel_level_pct: int = Field(ge=0, le=100)
    damage: Optional[str] = Field(default=None, max_length=500)


@carrier.post("/rentals/{uid}/confirm")
async def confirm_rental(uid: uuid.UUID, body: ConfirmIn, request: Request, pr: Principal = Depends(operator)):
    company = await _rental(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        b = await _booking(conn, company, uid)
        if b["status"] not in ("PENDING", "CONFIRMED"):
            raise ApiError(409, "INVALID_STATE", "only a waiting or confirmed booking takes a car")
        car = await conn.fetchrow(
            """SELECT v.id, v.status, f.rental_class FROM fleet.vehicle v JOIN rent.rental_fleet f ON f.vehicle_id = v.id
                WHERE v.uid = $1 AND v.company_id = $2""", body.vehicle_uid, company)
        if car is None:
            raise not_found("rental car")
        if car["status"] != "ACTIVE":
            raise ApiError(409, "VEHICLE_IN_MAINTENANCE" if car["status"] == "IN_MAINTENANCE" else "VEHICLE_NOT_AVAILABLE",
                           "the car is not available")
        driver = None
        if b["with_driver"]:
            if body.driver_uid is None:
                raise ApiError(422, "DRIVER_REQUIRED", "this hire comes with a driver: choose one")
            driver = await conn.fetchval("SELECT id FROM iam.party WHERE uid = $1", body.driver_uid)
        elif body.driver_uid is not None:
            raise ApiError(422, "NO_DRIVER_HIRE", "this hire is for the car alone")
        try:
            await conn.execute("UPDATE rent.rental_booking SET vehicle_id = $2, driver_party_id = $3, status = 'CONFIRMED' WHERE id = $1",
                               b["id"], car["id"], driver)
        except asyncpg.ExclusionViolationError as e:
            raise ApiError(409, "CAR_TAKEN", "the car is booked for part of this period") from e
    request.state.audit = {"action": "rental.confirm", "object_type": "rental_booking", "object_id": b["id"]}
    return {"uid": str(uid), "status": "CONFIRMED"}


@carrier.post("/rentals/{uid}/pickup")
async def pickup(uid: uuid.UUID, body: HandoverIn, request: Request, pr: Principal = Depends(operator)):
    company = await _rental(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        b = await _booking(conn, company, uid)
        if b["status"] != "CONFIRMED" or b["vehicle_id"] is None:
            raise ApiError(409, "INVALID_STATE", "confirm the booking with a car first")
        last = await conn.fetchval("SELECT odometer_km FROM fleet.vehicle WHERE id = $1", b["vehicle_id"])
        if last is not None and body.odometer_km < last:
            raise ApiError(422, "ODOMETER_BACKWARDS", "the reading is below the car's last one", last=last)
        await conn.execute("UPDATE rent.rental_booking SET status = 'PICKED_UP' WHERE id = $1", b["id"])
        no = f"RC-{datetime.now(timezone.utc):%y%m%d}-{b['id']}"
        cid = await conn.fetchval(
            """INSERT INTO rent.rental_contract (contract_no, booking_id, vehicle_id, terms, signed_at, status)
               VALUES ($1, $2, $3, jsonb_build_object('with_driver', $4::boolean), now(), 'OPEN') RETURNING id""",
            no, b["id"], b["vehicle_id"], b["with_driver"])
        await conn.execute(
            """INSERT INTO rent.rental_inspection (contract_id, stage, odometer_km, fuel_level_pct, damage, inspector_user_id)
               VALUES ($1, 'PICKUP', $2, $3, $4, $5)""", cid, body.odometer_km, body.fuel_level_pct,
            json_damage(body.damage), pr.user_id)
        await conn.execute("UPDATE rent.rental_fleet SET status = 'RENTED' WHERE vehicle_id = $1", b["vehicle_id"])
    request.state.audit = {"action": "rental.pickup", "object_type": "rental_booking", "object_id": b["id"]}
    return {"uid": str(uid), "status": "PICKED_UP", "contract_no": no}


@carrier.post("/rentals/{uid}/return")
async def take_back(uid: uuid.UUID, body: HandoverIn, request: Request, pr: Principal = Depends(operator)):
    company = await _rental(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        b = await _booking(conn, company, uid)
        if b["status"] != "PICKED_UP":
            raise ApiError(409, "INVALID_STATE", "the car was not handed over")
        c = await conn.fetchrow("SELECT * FROM rent.rental_contract WHERE booking_id = $1 FOR UPDATE", b["id"])
        await conn.execute(
            """INSERT INTO rent.rental_inspection (contract_id, stage, odometer_km, fuel_level_pct, damage, inspector_user_id)
               VALUES ($1, 'RETURN', $2, $3, $4, $5)""", c["id"], body.odometer_km, body.fuel_level_pct, json_damage(body.damage), pr.user_id)
        d = await conn.fetchrow("SELECT * FROM rent.hire_distance($1)", c["id"])
        final = (b["quoted_total"] or 0) + (d["extra_charge"] or 0)
        await conn.execute("UPDATE rent.rental_contract SET closed_at = now(), final_amount = $2, status = 'CLOSED' WHERE id = $1", c["id"], final)
        await conn.execute("UPDATE rent.rental_booking SET status = 'RETURNED' WHERE id = $1", b["id"])
        await conn.execute("UPDATE rent.rental_fleet SET status = 'AVAILABLE' WHERE vehicle_id = $1", b["vehicle_id"])
    request.state.audit = {"action": "rental.return", "object_type": "rental_booking", "object_id": b["id"]}
    return {"uid": str(uid), "status": "RETURNED", "driven": d["driven"], "allowed": d["allowed"], "extra_km": d["extra"],
            "extra_charge": d["extra_charge"], "final_amount": final, "unlimited": d["unlimited"]}


def json_damage(text: Optional[str]) -> str:
    import json
    return json.dumps({"note": text} if text else {})


# ------------------------------------------------------------------ the platform opens lines by contract
class LineIn(BaseModel):
    line: Line
    contract_ref: Optional[str] = Field(default=None, min_length=2, max_length=60)
    valid_from: Optional[date] = None
    valid_to: Optional[date] = None
    note: Optional[str] = Field(default=None, max_length=300)


@platform.get("/companies/{uid}/fleet-lines")
async def company_lines(uid: uuid.UUID, request: Request, pr: Principal = Depends(staff)):
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        company = await conn.fetchval("SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", uid)
        if company is None:
            raise not_found("company")
        recs = await conn.fetch(
            """SELECT l.id, l.line, l.contract_ref, lower(l.valid) AS valid_from, upper(l.valid) AS valid_to, l.note,
                      l.valid @> CURRENT_DATE AND l.ended_at IS NULL AS open, l.ended_at, u.email AS granted_by
                 FROM iam.company_fleet_line l LEFT JOIN iam.app_user u ON u.id = l.granted_by
                WHERE l.company_id = $1 ORDER BY l.ended_at IS NULL DESC, l.line, lower(l.valid) DESC""", company)
        counts = await conn.fetch("SELECT fleet_use, count(*) AS n FROM fleet.vehicle WHERE company_id = $1 GROUP BY fleet_use", company)
    return {"lines": rows(recs), "vehicles": {r["fleet_use"]: r["n"] for r in counts}}


@platform.post("/companies/{uid}/fleet-lines", status_code=201)
async def open_line(uid: uuid.UUID, body: LineIn, request: Request, pr: Principal = Depends(staff)):
    _staff(pr)
    start = body.valid_from or date.today()
    if body.valid_to and body.valid_to <= start:
        raise ApiError(422, "LINE_DATES", "the line ends before it starts")
    async with db.transaction(context_for(request, pr)) as conn:
        company = await conn.fetchval("SELECT c.id FROM iam.company c JOIN iam.party p ON p.id = c.id WHERE p.uid = $1", uid)
        if company is None:
            raise not_found("company")
        try:
            lid = await conn.fetchval(
                """INSERT INTO iam.company_fleet_line (company_id, line, contract_ref, valid, granted_by, note)
                   VALUES ($1, $2, $3, daterange($4, $5), $6, $7) RETURNING id""",
                company, body.line, body.contract_ref, start, body.valid_to, pr.user_id, body.note)
        except asyncpg.ExclusionViolationError as e:
            raise ApiError(409, "LINE_OPEN", "the company already holds this line for these dates") from e
    request.state.audit = {"action": "company.fleet_line_open", "object_type": "company", "object_id": company, "reason": body.line}
    return {"id": lid}


@platform.post("/fleet-lines/{lid}/end")
async def close_line(lid: int, request: Request, pr: Principal = Depends(staff)):
    _staff(pr)
    async with db.transaction(context_for(request, pr)) as conn:
        r = await conn.fetchrow("SELECT * FROM iam.company_fleet_line WHERE id = $1 FOR UPDATE", lid)
        if r is None or r["ended_at"] is not None:
            raise not_found("open line")
        await conn.execute(
            """UPDATE iam.company_fleet_line SET valid = daterange(lower(valid), greatest(lower(valid) + 1, CURRENT_DATE)), ended_by = $2,
                      ended_at = now() WHERE id = $1""", lid, pr.user_id)
    request.state.audit = {"action": "company.fleet_line_close", "object_type": "company", "object_id": r["company_id"], "reason": r["line"]}
    return {"id": lid, "ended": datetime.now(timezone.utc).date().isoformat()}
