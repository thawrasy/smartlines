"""Demo data for the switchable modules, so every module screen and dashboard has something to show on a test server.

Usage (owner connection, after seed_demo.py; never on production):
    MASSLAK_OWNER_URL=postgresql://postgres@localhost/masslak python3 backend/scripts/seed_modules.py

Each table gets the values that matter for a demo (names, codes, statuses, amounts in pounds and dates spread over the
last 30 days)
from PLAN below; every other required column is filled from the catalog: references point at existing rows, CHECK lists
give their first value, and types get a neutral value. Tables are retried until no more rows can be added, so the order
of PLAN only matters for readability. The script is idempotent: it does nothing when the module data is already there.
"""
import asyncio
import json
import os
import random
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app.modular import engine  # noqa: E402
from app.modular.specs import RESOURCES  # noqa: E402

rnd = random.Random(2026)
NOW = datetime.now(timezone.utc)
TODAY = date.today()
CITIES = [("DAM", 33.5138, 36.2765), ("ALP", 36.2021, 37.1343), ("HMS", 34.7308, 36.7094), ("LTK", 35.5238, 35.7917),
          ("HMA", 35.1318, 36.7578), ("TRT", 34.8890, 35.8866), ("DRA", 32.6250, 36.1060)]
FIRST = ["Rami", "Lina", "Omar", "Huda", "Fadi", "Rana", "Sami", "Maya", "Nour", "Khaled", "Dima", "Tarek", "Salma", "Yousef"]
LAST = ["Haddad", "Khoury", "Nasser", "Saleh", "Darwish", "Hamwi", "Halabi", "Jaber", "Shami", "Azar"]


def day_at(i, n, days=30):
    """Row i of n spread evenly over the last days days, at a daytime hour."""
    d = days * (1 - (i + 0.5) / n)
    return (NOW - timedelta(days=d)).replace(hour=7 + (i * 5) % 14, minute=(i * 13) % 60)


def ago(max_days=30, min_days=0):
    """A moment in the last max_days days, earlier days less busy than recent ones."""
    d = min_days + (max_days - min_days) * (rnd.random() ** 1.6)
    return NOW - timedelta(days=d, minutes=rnd.randint(0, 600))


def person(i):
    return f"{FIRST[i % len(FIRST)]} {LAST[(i * 7) % len(LAST)]}"


def weighted(*pairs):
    """weighted(("ACTIVE", 6), ("SUSPENDED", 1)) -> a picker for row i."""
    pool = [v for v, w in pairs for _ in range(w)]
    random.Random(len(pool) * 31 + len(pairs)).shuffle(pool)
    return lambda i: pool[i % len(pool)]


def cycle(*values):
    return lambda i: values[i % len(values)]


REF = "!ref"            # always point the column at an existing row
BORDER = "@border"       # a border-crossing station


def ref_by(index):
    """Point at the existing row number index(i) of the referenced table, e.g. five bids per request."""
    return ("!refi", index)


def derive(sql, dep):
    """Pick the column from the rows `sql` returns for the value already chosen for column `dep` of the same row,
    e.g. a manifest lists a ticket of the manifest's own trip."""
    return ("!derive", sql, dep)


def money(lo, hi, step=500):
    return lambda i: rnd.randrange(lo // step, hi // step + 1) * step


# table -> (rows, {column: value or function of the row number})
PLAN = [
    # ---------------------------------------------------------------- parents some module tables need
    ("pricing.loyalty_program", 1, {"code": "MASSLAK-MILES", "name": "Masslak Miles", "point_value": 10, "currency": "SYP"}),
    ("pricing.points_account", 6, {}),
    ("sec.authority_profile", 4, {"code": cycle("CIVIL", "CUSTOMS", "VEHICLES", "BORDER"),
                                  "name": cycle("Civil registry", "Customs directorate", "Vehicle registry", "Border authority")}),
    ("acct.accounting_connection", 1, {}),
    ("acct.sync_item", 6, {"idempotency_key": lambda i: f"sync-{i}"}),
    ("ops.incident", 6, {"occurred_at": lambda i: ago(30)}),
    ("iam.api_client", 2, {"name": cycle("TravelHub API", "SyriaTrips partner")}),
    ("sales.booking", 12, {"booking_ref": lambda i: f"DM{7300 + i}", "idempotency_key": lambda i: f"demo-booking-{i}",
                           "total_amount": money(20000, 90000), "price_breakdown": {}, "rules_version": "1", "currency": "SYP"}),
    ("sales.passenger", 12, {"full_name": person, "first_name": lambda i: FIRST[i % len(FIRST)], "father_name": "Ahmad",
                             "grandfather_name": "Mahmoud", "last_name": lambda i: LAST[(i * 7) % len(LAST)], "nationality": "SY"}),
    ("fleet.insurance_policy", 6, {"insurer_name": cycle("Syrian Insurance Co.", "Al-Aqeelah Takaful", "Trust Syria"),
                                   "policy_no": lambda i: f"POL-26-{3300 + i}"}),
    ("sales.ticket", 12, {"ticket_no": lambda i: f"T-26-{8100 + i}", "from_seq": 1, "to_seq": 2,
                          "fare_amount": money(20000, 42000), "total_amount": money(20000, 45000), "rules_snapshot": {}}),
    # ---------------------------------------------------------------- approved lines
    ("net.line", 6, {"code": cycle("L-DAM-ALP", "L-DAM-LTK", "L-DAM-DRA", "L-ALP-LTK", "L-DAM-SHT", "L-HMS-TRT"),
                     "name": cycle("Damascus - Aleppo", "Damascus - Latakia", "Damascus - Daraa", "Aleppo - Latakia",
                                   "Damascus city shuttle", "Homs - Tartus"),
                     "status": weighted(("ACTIVE", 4), ("DRAFT", 1), ("SUSPENDED", 1)), "created_at": lambda i: ago(60, 20)}),
    ("net.line_version", 8, {"version": lambda i: i // 6 + 1, "distance_km": cycle(355, 330, 100, 190, 18, 95),
                             "typical_min": cycle(315, 250, 90, 180, 45, 80),
                             "status": weighted(("ACTIVE", 4), ("PENDING_APPROVAL", 2), ("DRAFT", 1), ("APPROVED", 1))}),
    ("net.line_permit", 6, {"permit_no": lambda i: f"LP-2026-{i + 101:04d}", "max_vehicles": cycle(12, 8, 6, 10),
                            "max_trips_day": cycle(24, 16, 12, 20), "status": weighted(("ACTIVE", 4), ("PENDING", 1), ("SUSPENDED", 1))}),
    ("net.line_tariff", 4, {"status": weighted(("ACTIVE", 2), ("APPROVED", 1), ("DRAFT", 1))}),
    ("net.timetable_template", 5, {"kind": "HEADWAY", "headway_min": cycle(10, 15, 20), "window_from": "06:00", "window_to": "22:00",
                                    "status": weighted(("ACTIVE", 4), ("DRAFT", 1))}),
    ("ops.route_adherence_event", 26, {"ts": lambda i: ago(30)}),
    # ---------------------------------------------------------------- shuttles
    ("sales.shuttle_zone", 4, {"code": cycle("Z-MAZZEH", "Z-MIDAN", "Z-BARZEH", "Z-JARAMANA"),
                               "name": cycle("Mazzeh", "Midan", "Barzeh", "Jaramana")}),
    ("sales.subscription_plan", 5, {"code": cycle("MONTH-40", "MONTH-UNL", "WEEK-12", "STUDENT-M", "SENIOR-M"),
                                    "name": cycle("Monthly, 40 rides", "Monthly unlimited", "Weekly, 12 rides", "Student monthly",
                                                  "Senior monthly"),
                                    "period_days": cycle(30, 30, 7, 30, 30), "rides_limit": cycle(40, None, 12, 60, 40),
                                    "price": cycle(150000, 240000, 45000, 90000, 75000), "currency": "SYP",
                                    "status": weighted(("ACTIVE", 4), ("DRAFT", 1))}),
    ("sales.nfc_card", 14, {"status": weighted(("ACTIVE", 10), ("BLOCKED", 1), ("LOST", 1)), "issued_at": lambda i: ago(90, 5)}),
    ("sales.subscription", 34, {"created_at": lambda i: ago(30), "price_paid": cycle(150000, 240000, 45000, 90000),
                                "rides_used": lambda i: rnd.randint(0, 35),
                                "status": weighted(("ACTIVE", 7), ("EXPIRED", 2), ("PENDING", 1), ("CANCELLED", 1))}),
    ("sales.shuttle_pass", 24, {"pass_no": lambda i: f"SP-{i + 5001}", "status": weighted(("ACTIVE", 8), ("EXPIRED", 2), ("REVOKED", 1))}),
    ("ops.shuttle_ride", 90, {"created_at": lambda i: ago(30), "board_ts": lambda i: ago(30),
                              "charged_amount": money(2000, 6000), "outstanding_amount": cycle(0, 0, 0, 0, 0, 0, 2500),
                              "status": weighted(("CLOSED", 8), ("OPEN", 2), ("REVIEW", 1))}),
    ("ops.ride_segment_charge", 60, {"ts": lambda i: ago(30), "amount": money(1000, 4000), "seq_from": 1, "seq_to": cycle(2, 3, 4)}),
    # ---------------------------------------------------------------- cargo
    ("ship.service_product", 5, {"code": cycle("GROUND", "EXPRESS_1D", "SAME_DAY", "ECONOMY", "FREIGHT_LTL"),
                                 "name": cycle("Standard parcel", "Express next day", "Same-day city", "Coach hold parcel",
                                               "Pallet freight")}),
    ("ship.hub", 4, {"code": cycle("HUB-DAM", "HUB-ALP", "HUB-HMS", "HUB-LTK"),
                     "name": cycle("Damascus hub", "Aleppo hub", "Homs hub", "Latakia hub"),
                     "status": weighted(("ACTIVE", 3), ("SUSPENDED", 1))}),
    ("ship.access_point", 8, {"code": lambda i: f"AP-{i + 1:03d}", "name": cycle("Mazzeh kiosk", "Bab Touma shop", "Aleppo Old City desk",
                                                                               "Homs station desk", "Latakia port kiosk",
                                                                               "Tartus market", "Hama centre", "Daraa station")}),
    ("ship.locker_compartment", 24, {"status": weighted(("FREE", 5), ("OCCUPIED", 3), ("RESERVED", 1), ("OUT_OF_ORDER", 1))}),
    ("ship.rate_table", 3, {"status": weighted(("PUBLISHED", 2), ("DRAFT", 1))}),
    ("ship.shipper_account", 6, {"status": weighted(("ACTIVE", 4), ("PENDING", 1), ("ON_HOLD", 1)), "credit_limit": money(500000, 5000000, 50000),
                                 "created_at": lambda i: ago(90, 10)}),
    ("ship.address", 30, {"created_at": lambda i: ago(60)}),
    ("ship.shipment", 120, {"created_at": lambda i: ago(30), "updated_at": lambda i: ago(10),
                            "declared_value": money(50000, 3000000, 5000), "cod_amount": cycle(0, 0, 0, 125000, 0, 60000),
                            "status": weighted(("DELIVERED", 10), ("IN_NETWORK", 4), ("OUT_FOR_DELIVERY", 3), ("PICKED_UP", 2),
                                               ("CREATED", 2), ("EXCEPTION", 1), ("RETURNED", 1))}),
    ("ship.tracking_event", 200, {"ts": lambda i: ago(30)}),
    ("ship.pickup_request", 30, {"created_at": lambda i: ago(30),
                                 "status": weighted(("PICKED_UP", 5), ("ASSIGNED", 2), ("REQUESTED", 2), ("FAILED", 1))}),
    ("ship.courier_route", 12, {"route_date": lambda i: (TODAY - timedelta(days=i % 10)).isoformat(),
                                "status": weighted(("COMPLETED", 6), ("IN_PROGRESS", 2), ("PLANNED", 2))}),
    ("ship.courier_assignment", 40, {"kind": "DELIVERY", "shipment_id": REF, "status": weighted(("DONE", 6), ("PENDING", 2), ("FAILED", 1))}),
    ("ship.delivery_attempt", 50, {"ts": lambda i: ago(30)}),
    ("ship.cod_collection", 26, {"amount": money(25000, 400000, 5000), "collected_at": lambda i: ago(20),
                                 "status": weighted(("REMITTED", 4), ("COLLECTED", 3), ("PENDING", 2), ("PAID_OUT", 2))}),
    ("ship.cargo_claim", 9, {"amount": money(50000, 800000, 5000), "created_at": lambda i: ago(30),
                             "status": weighted(("OPEN", 2), ("UNDER_REVIEW", 2), ("APPROVED", 1), ("PAID", 1), ("REJECTED", 1))}),
    ("ship.return_authorization", 8, {"created_at": lambda i: ago(30)}),
    ("ship.handling_unit", 12, {"created_at": lambda i: ago(20)}),
    ("ship.load", 10, {"created_at": lambda i: ago(25), "status": weighted(("CLOSED", 4), ("IN_TRANSIT", 2), ("LOADING", 2), ("PLANNED", 2))}),
    # ---------------------------------------------------------------- international and border
    # Travel documents: passport by default; exceptions name the documents accepted and their legal basis (11.9)
    ("sales.entry_rule", 6, {"country_code": cycle("LB", "LB", "JO", "TR", "IQ", "JO"), "country_role": "DESTINATION",
                             "nationality": cycle("SY", "LB", None, None, "SY", "SY"),
                             "doc_required": cycle(["PASSPORT", "NATIONAL_ID"], ["NATIONAL_ID", "PASSPORT"], ["PASSPORT"], ["PASSPORT"],
                                                   ["PASSPORT"], ["PASSPORT", "LAISSEZ_PASSER"]),
                             "passport_min_days": cycle(0, 0, 180, 150, 180, 180), "enforcement": "BLOCK",
                             "legal_basis": cycle("Syrian-Lebanese bilateral arrangement on crossing with national ID", "Citizens returning home",
                                                  None, None, None, "Draft: Jordanian circular on laissez-passer holders"),
                             "note": cycle("Bring the original national ID card, issued less than 10 years ago.", None, None, None, None, None),
                             "label": cycle("Syrians to Lebanon: national ID or passport", "Lebanese returning home", "Jordan: passport",
                                            "Turkey: passport", "Iraq: passport for Syrians", "Jordan: laissez-passer (pending)"),
                             "version": lambda i: 1, "valid": None, "security_approval": False,
                             "created_by": REF, "approved_by": cycle(REF, REF, REF, REF, REF, None),
                             "status": cycle("ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE", "ACTIVE", "DRAFT"), "created_at": lambda i: ago(60)}),
    ("sales.ticket_doc", 12, {"status": weighted(("VERIFIED", 5), ("PENDING", 3), ("REJECTED", 1))}),
    ("brd.border_point", 2, {"station_id": BORDER, "code": cycle("JDY", "NSB", "BAH", "KSB"), "name": cycle("Jdeidet Yabous", "Nasib", "Bab al-Hawa", "Kasab"),
                             "status": weighted(("ACTIVE", 3), ("RESTRICTED", 1))}),
    ("brd.crossing_profile", 3, {"status": "ACTIVE"}),
    ("brd.manifest", 22, {"created_at": lambda i: ago(30),
                          "status": weighted(("ACKNOWLEDGED", 6), ("SUBMITTED", 3), ("DRAFT", 2), ("REJECTED", 1), ("CLOSED", 1))}),
    ("brd.manifest_person", 80, {"person_role": "PASSENGER", "crew_party_id": None,
                                  "ticket_id": derive("SELECT k.id FROM sales.ticket k JOIN brd.manifest m ON m.trip_id = k.trip_id"
                                                      " WHERE m.id = $1 ORDER BY k.id", "manifest_id")}),
    ("ops.trip_crossing_plan", 4, {"exit_station_id": BORDER, "entry_station_id": "@border2", "seq": 1}),
    ("brd.manifest_discrepancy", 6, {"created_at": lambda i: ago(30), "resolved_at": cycle(None, None, ago(5))}),
    # ---------------------------------------------------------------- government links
    ("sec.gov_adapter_config", 5, {"status": weighted(("ACTIVE", 3), ("TESTING", 2))}),
    ("sec.verification_job", 70, {"requested_at": lambda i: ago(30),
                                  "status": weighted(("MATCHED", 9), ("QUEUED", 1), ("SENT", 1), ("MISMATCH", 1), ("NOT_FOUND", 1))}),
    # ---------------------------------------------------------------- stations and tracking
    ("net.station_gate", 8, {}),
    ("net.station_display", 6, {"status": weighted(("ACTIVE", 5), ("OFFLINE", 1)), "last_seen_at": lambda i: ago(1)}),
    ("ops.tracking_state", 4, {"status": weighted(("ON", 3), ("OFF", 1)), "last_ping_at": lambda i: NOW - timedelta(minutes=2 + i)}),
    ("ops.trip_delay", 24, {"reported_at": lambda i: ago(30)}),
    ("ops.driver_notice", 18, {"created_at": lambda i: ago(20)}),
    ("fleet.vehicle_service_status", 5, {"vehicle_id": "@buses", "status": weighted(("ACTIVE", 3), ("OUT_OF_SERVICE", 1), ("IMPOUNDED", 1)),
                                         "created_at": lambda i: ago(30)}),
    ("fleet.insurance_claim", 6, {"amount": money(200000, 5000000, 50000), "created_at": lambda i: ago(30),
                                  "status": weighted(("UNDER_REVIEW", 2), ("NOTIFIED", 1), ("ACCEPTED", 1), ("PAID", 1), ("REJECTED", 1))}),
    ("fleet.boarding_validator", 6, {"status": weighted(("ACTIVE", 5), ("OFFLINE", 1))}),
    # ---------------------------------------------------------------- freight
    ("fleet.truck_unit", 6, {"vehicle_id": "@trucks", "gvw_kg": 40000, "tare_kg": cycle(8200, 8800, 9100)}),
    ("fleet.trailer", 6, {"status": weighted(("ACTIVE", 4), ("PENDING", 1), ("BLOCKED", 1)), "created_at": lambda i: ago(60)}),
    ("frt.freight_request", 36, {"mode": "BID", "shipper_company_id": None,
                                 "cargo_category": cycle("GENERAL", "FOOD", "GENERAL", "REFRIGERATED", "VEHICLES", "CONTAINERS"),
                                 "cargo_description": cycle("Olive oil, 40 pallets", "Flour sacks for bakeries", "Cement bags", "Citrus from the coast",
                                                            "Generator sets", "Two 40ft containers", "Steel rebar", "Cotton bales"),
                                 "declared_weight_kg": cycle(18000, 24000, 30000, 12000, 8000, 26000), "packages": cycle(40, 600, 1200, 900, 4, 2),"created_at": lambda i: ago(30), "target_price": money(800000, 9000000, 50000),
                                 "status": weighted(("OPEN", 4), ("AWARDED", 2), ("CONTRACTED", 4), ("CANCELLED", 1), ("EXPIRED", 1))}),
    ("frt.freight_bid", 70, {"carrier_company_id": "@companies", "request_id": ref_by(lambda i: i // 5), "created_at": lambda i: ago(30), "price": money(700000, 9500000, 50000),
                             "status": weighted(("SUBMITTED", 4), ("ACCEPTED", 2), ("REJECTED", 3), ("WITHDRAWN", 1))}),
    ("frt.freight_contract", 14, {"created_at": lambda i: ago(30), "price": money(900000, 9000000, 50000),
                                  "status": weighted(("IN_PROGRESS", 3), ("SIGNED", 2), ("COMPLETED", 4), ("DISPUTED", 1))}),
    ("frt.container", 8, {"container_no": lambda i: f"MSCU{4410020 + i * 37:07d}"}),
    ("frt.freight_claim", 4, {"amount": money(100000, 2000000, 50000), "created_at": lambda i: ago(30)}),
    # ---------------------------------------------------------------- sales channels
    ("sales.channel", 4, {"created_at": lambda i: ago(90)}),
    ("sales.channel_agreement", 4, {"rate_bp": cycle(600, 800, 1000), "status": weighted(("ACTIVE", 3), ("DRAFT", 1))}),
    ("sales.channel_statement", 6, {"gross_sales": money(2000000, 20000000, 50000), "net_due": money(1500000, 18000000, 50000),
                                    "status": weighted(("SETTLED", 3), ("ISSUED", 2), ("DISPUTED", 1))}),
    ("sales.channel_memo", 8, {"amount": money(20000, 400000, 5000), "created_at": lambda i: ago(30)}),
    # ---------------------------------------------------------------- rail
    ("rail.fare_class", 3, {}),
    ("rail.coach_layout", 3, {}),
    ("rail.journey", 26, {"created_at": lambda i: ago(30),
                          "status": weighted(("COMPLETED", 5), ("BOOKED", 4), ("IN_PROGRESS", 1), ("DISRUPTED", 1), ("CANCELLED", 1))}),
    # ---------------------------------------------------------------- taxi
    ("taxi.taxi_office", 4, {"company_id": "@companies", "name": cycle("Sham Taxi", "Aleppo Cabs", "Homs Taxi Co.", "Coast Taxi"),
                             "status": weighted(("ACTIVE", 3), ("PENDING", 1))}),
    ("taxi.taxi_permit", 10, {"vehicle_id": "@taxis", "status": weighted(("ACTIVE", 8), ("SUSPENDED", 1), ("PENDING", 1))}),
    ("taxi.meter_tariff", 3, {"status": weighted(("ACTIVE", 2), ("DRAFT", 1)), "flag_fall": 3000, "per_km": 1500, "per_wait_min": 300,
                              "min_fare": 6000}),
    ("taxi.taxi_shift", 10, {"vehicle_id": "@taxis", "status": weighted(("ON", 5), ("PAUSED", 1), ("ENDED", 4))}),
    ("taxi.ride_request", 80, {"pickup_text": cycle("Marjeh Square", "Umayyad Square", "Mazzeh", "Bab Touma", "Abu Rummaneh", "Midan"),
                               "dropoff_text": cycle("Damascus University", "Jaramana", "Hamidiyeh Souq", "Damascus Airport", "Mazzeh", "Marjeh Square"),"created_at": lambda i: ago(30), "fare_estimate": money(6000, 45000),
                               "status": weighted(("COMPLETED", 8), ("SEARCHING", 1), ("ASSIGNED", 1), ("CANCELLED", 2), ("EXPIRED", 1))}),
    ("taxi.ride", 64, {"fare_mode": "METER", "tariff_id": REF, "started_at": lambda i: day_at(i, 64),
                       "ended_at": lambda i: day_at(i, 64) + timedelta(minutes=18 + i % 25), "fare": money(6000, 45000),
                       "status": weighted(("COMPLETED", 10), ("ON_TRIP", 1), ("ARRIVING", 1), ("CANCELLED", 1))}),
    # ---------------------------------------------------------------- car rental
    ("rent.rental_company", 2, {"company_id": "@companies", "brand": cycle("Masslak Rent", "Sham Rent a Car"), "status": "ACTIVE"}),
    ("rent.rental_branch", 4, {"name": cycle("Damascus airport", "Mazzeh branch", "Aleppo centre", "Latakia corniche")}),
    ("rent.rental_fleet", 16, {"vehicle_id": "@cars", "status": weighted(("AVAILABLE", 6), ("RENTED", 4), ("MAINTENANCE", 1))}),
    ("rent.rental_rate", 6, {"price": money(150000, 600000, 5000), "deposit_amount": money(500000, 2000000, 50000), "status": "ACTIVE"}),
    ("rent.rental_addon", 4, {"price": money(10000, 60000, 5000)}),
    ("rent.rental_booking", 40, {"created_at": lambda i: ago(30), "quoted_total": money(300000, 4000000, 5000),
                                 "status": weighted(("RETURNED", 5), ("PICKED_UP", 3), ("CONFIRMED", 3), ("PENDING", 2), ("CANCELLED", 1))}),
    ("rent.deposit_hold", 14, {"amount": money(500000, 2000000, 50000),
                               "status": weighted(("HELD", 3), ("RELEASED", 3), ("PARTIALLY_CAPTURED", 1))}),
    # ---------------------------------------------------------------- transit passengers
    ("net.corridor", 3, {"status": weighted(("ACTIVE", 2), ("DRAFT", 1)), "created_at": lambda i: ago(90)}),
    ("ops.crossing_event", 40, {"occurred_at": lambda i: ago(30), "created_at": lambda i: ago(30)}),
    ("ops.transit_reconciliation", 12, {"status": weighted(("MATCHED", 4), ("OPEN", 2), ("DISCREPANCY", 1), ("RESOLVED", 2))}),
    # ---------------------------------------------------------------- contract transport
    ("ctr.service_contract", 5, {"price": money(2000000, 15000000, 100000), "created_at": lambda i: ago(120, 30),
                                 "status": weighted(("ACTIVE", 4), ("DRAFT", 1))}),
    ("ctr.contract_rider", 40, {"status": weighted(("ACTIVE", 8), ("PAUSED", 1))}),
    ("ctr.attendance_event", 160, {"occurred_at": lambda i: ago(30)}),
    ("ctr.contract_invoice", 10, {"amount": money(2000000, 15000000, 100000), "status": weighted(("PAID", 3), ("ISSUED", 2), ("DRAFT", 1))}),
    # ---------------------------------------------------------------- carrier billing
    ("bill.plan", 3, {"code": cycle("BASIC", "PRO", "ENTERPRISE"), "name": cycle("Basic", "Professional", "Enterprise"),
                      "annual_fee": cycle(6000000, 15000000, 36000000), "status": "ACTIVE"}),
    ("bill.company_subscription", 3, {"company_id": "@companies", "source": "PLAN", "plan_id": REF,
                                      "starts_at": lambda i: NOW - timedelta(days=200), "ends_at": lambda i: NOW + timedelta(days=165), "status": weighted(("ACTIVE", 2), ("GRACE", 1)), "created_at": lambda i: ago(200, 30)}),
    ("bill.usage_event", 140, {"ts": lambda i: ago(30)}),
    ("bill.carrier_invoice", 8, {"subtotal": lambda i: 500000 + i * 125000, "discount": 0, "tax": lambda i: (500000 + i * 125000) // 10,
                                 "total": lambda i: (500000 + i * 125000) * 11 // 10, "created_at": lambda i: ago(60),
                                 "status": weighted(("PAID", 4), ("DUE", 2), ("OVERDUE", 1), ("DRAFT", 1))}),
    # ---------------------------------------------------------------- service partners
    ("ptn.partner", 4, {"company_id": "@partners", "party_id": "@partners", "code": lambda i: f"PTN-{i + 1:03d}", "status": weighted(("ACTIVE", 5), ("PENDING", 1)), "created_at": lambda i: ago(120)}),
    ("ptn.fuel_price", 6, {"unit_price": cycle(10500, 9800, 11000), "valid_from": lambda i: ago(30)}),
    ("ptn.fuel_card", 8, {"daily_limit": 1000000, "monthly_limit": 20000000, "created_at": lambda i: ago(90)}),
    ("ptn.fuel_session", 60, {"opened_at": lambda i: ago(30), "status": weighted(("COMPLETED", 9), ("FLAGGED", 1), ("OPEN", 1))}),
    ("ptn.fuel_anomaly", 7, {"status": weighted(("OPEN", 3), ("EXPLAINED", 2), ("CONFIRMED", 1), ("DISMISSED", 1))}),
    ("ptn.partner_menu_item", 10, {"price": money(5000, 40000)}),
    ("ptn.partner_order", 40, {"created_at": lambda i: ago(30), "amount": money(8000, 90000),
                               "status": weighted(("PICKED_UP", 6), ("READY", 1), ("ACCEPTED", 1), ("PLACED", 1), ("CANCELLED", 1))}),
    ("ptn.partner_sale", 70, {"created_at": lambda i: ago(30), "amount": money(20000, 600000),
                              "status": weighted(("COMPLETED", 9), ("PENDING", 1), ("REVERSED", 1))}),
    # ---------------------------------------------------------------- loyalty and campaigns
    ("pricing.loyalty_partner", 4, {"status": weighted(("ACTIVE", 3), ("PENDING", 1))}),
    ("pricing.reward_catalog", 6, {"status": weighted(("ACTIVE", 5), ("DRAFT", 1))}),
    ("pricing.reward_voucher", 30, {"created_at": lambda i: ago(30), "value": money(10000, 100000, 5000),
                                    "status": weighted(("ISSUED", 4), ("USED", 4), ("EXPIRED", 1))}),
    ("pricing.partner_redemption", 24, {"redeemed_at": lambda i: ago(30), "value": money(10000, 100000, 5000)}),
    ("pricing.campaign", 6, {"name": cycle("Back to university", "Eid travel offer", "Weekend coast trips", "First ride free",
                                           "Family discount", "Winter promo"),
                             "budget_total": money(5000000, 40000000, 500000), "budget_spent": money(500000, 5000000, 50000),
                             "created_at": lambda i: ago(30), "status": weighted(("LIVE", 3), ("APPROVED", 1), ("PAUSED", 1), ("ENDED", 1))}),
    ("pricing.promo_code", 8, {"code": lambda i: f"MASSLAK{10 + i}"}),
    ("pricing.bin_range", 3, {"from_bin": cycle("45800000", "52100000", "62700000"), "to_bin": cycle("45899999", "52199999", "62799999")}),
    ("pricing.override_policy", 2, {"target_type": "COMPANY", "user_id": None}),
    ("pricing.award_seat_rule", 3, {"line_id": REF, "route_id": None}),
    ("net.geofence", 4, {"polygon": None, "center_lat": cycle(33.5138, 36.2021, 34.7308, 35.5238),
                         "center_lng": cycle(36.2765, 37.1343, 36.7094, 35.7917), "radius_m": 400}),
    ("ship.capacity_booking", 6, {"trip_id": REF, "load_id": None, "route_id": None}),
    ("ship.carrier_scorecard", 3, {"carrier_company_id": REF, "access_point_id": None}),
    ("ship.delivery_preference", 6, {"shipment_id": REF, "party_id": None}),
    ("ship.integration_partner", 3, {"party_id": "@partners", "name": cycle("Aramex Syria", "DHL partner desk", "Local Express")}),
    ("ship.handling_unit_item", 10, {"shipment_id": REF, "parcel_id": None}),
    ("ship.shipment_leg", 30, {"load_id": None, "courier_route_id": None, "created_at": lambda i: ago(30),
                                "trip_id": derive("SELECT id FROM ops.trip WHERE company_id = $1 ORDER BY id", "carrier_company_id")}),
    ("pricing.sponsor_account", 3, {}),
    # ---------------------------------------------------------------- accounting operations
    ("acct.tax_code", 3, {}),
    ("acct.cost_center", 4, {"name": cycle("Damascus garage", "Aleppo office", "Coast operations", "Head office")}),
    ("acct.cash_box", 3, {}),
    ("acct.cash_session", 12, {"opened_at": lambda i: ago(20), "status": weighted(("RECONCILED", 4), ("CLOSED", 2), ("OPEN", 1))}),
    ("acct.cash_receipt", 60, {"cash_session_id": REF, "receipt_date": lambda i: ago(30).date().isoformat(), "amount": money(20000, 800000)}),
    ("acct.cash_payment", 30, {"cash_session_id": REF, "payment_date": lambda i: ago(30).date().isoformat(), "amount": money(20000, 500000)}),
    ("acct.sales_invoice", 18, {"created_at": lambda i: ago(30), "subtotal": lambda i: 400000 + i * 90000,
                                "tax": lambda i: (400000 + i * 90000) // 10, "total": lambda i: (400000 + i * 90000) * 11 // 10,
                                "status": weighted(("PAID", 4), ("ISSUED", 3), ("PARTIALLY_PAID", 1), ("DRAFT", 1))}),
    # ---------------------------------------------------------------- contact centre
    ("crm.call_queue", 3, {}),
    ("crm.call_agent", 8, {"status": weighted(("AVAILABLE", 3), ("BUSY", 3), ("BREAK", 1), ("OFFLINE", 1))}),
    ("crm.call", 150, {"started_at": lambda i: ago(30),
                       "state": weighted(("ENDED", 14), ("QUEUED", 1), ("AGENT_HANDLING", 1), ("AI_HANDLING", 1))}),
    ("crm.callback_request", 12, {"due_at": lambda i: NOW + timedelta(hours=i * 3 - 12),
                                  "status": weighted(("PENDING", 3), ("DONE", 3), ("FAILED", 1))}),
]
TABLE_ORDER = [t for t, _, _ in PLAN]
# every other resource table gets a couple of rows so no screen is empty
EXTRA = sorted({r.table for r in RESOURCES.values()} - set(TABLE_ORDER))


class Seeder:
    def __init__(self, conn):
        self.conn = conn
        self.ids: dict = {}
        self.company = self.agency = self.passenger = self.platform = None
        self.failures: dict = {}
        self.named: dict = {}
        self.partial: dict = {}
        self.uniq: dict = {}

    async def refs(self, table, key=None):
        if key and (table, key) not in self.ids:
            meta = await engine.table_meta(self.conn, table)
            if key not in meta.pk:      # the foreign key points at a unique column other than the primary key
                self.ids[(table, key)] = [r[0] for r in await self.conn.fetch(f"SELECT {key} FROM {table} ORDER BY 1 LIMIT 200")]
        if key and (table, key) in self.ids:
            return self.ids[(table, key)]
        if table not in self.ids:
            meta = await engine.table_meta(self.conn, table)
            key = meta.pk[0]
            where = ""
            if "company_id" in meta.cols and table.split(".")[0] not in ("iam",):
                where = f" WHERE company_id = {self.company}"
            rows = await self.conn.fetch(f"SELECT {key} FROM {table}{where} ORDER BY {key} LIMIT 200")
            if not rows and where:
                rows = await self.conn.fetch(f"SELECT {key} FROM {table} ORDER BY {key} LIMIT 200")
            self.ids[table] = [r[0] for r in rows]
        return self.ids[table]

    def value(self, table, col, meta_col, i):
        n, t = col, meta_col.pg_type
        if meta_col.choices:
            return meta_col.choices[i % len(meta_col.choices)] if self.pk_col or col in self.uniq.get(table, ()) else meta_col.choices[0]
        if n == "currency":
            return "SYP"
        if n in ("country_code", "nationality", "country") or n.endswith("_country"):
            return "SY"
        if n in ("locale", "lang", "language"):
            return "en"
        if t.startswith("geography") or t.startswith("geometry"):
            _, lat, lng = CITIES[i % len(CITIES)]
            if "polygon" in t.lower():
                d = 0.02
                return (f"SRID=4326;POLYGON(({lng - d} {lat - d},{lng + d} {lat - d},{lng + d} {lat + d},{lng - d} {lat + d},"
                        f"{lng - d} {lat - d}))")
            if "linestring" in t.lower():
                _, lat2, lng2 = CITIES[(i + 1) % len(CITIES)]
                return f"SRID=4326;LINESTRING({lng} {lat},{lng2} {lat2})"
            return f"SRID=4326;POINT({lng + rnd.uniform(-.02, .02):.5f} {lat + rnd.uniform(-.02, .02):.5f})"
        if t.endswith("[]"):
            return "{}"
        if t in ("jsonb", "json"):
            return "{}"
        if t == "boolean":
            return "false"
        if t == "uuid":
            return str(uuid.uuid4())
        if t == "inet":
            return "10.0.0.1"
        if t == "interval":
            return "1 hour"
        if t.startswith("time ") or t == "time without time zone":
            return f"{6 + i % 14:02d}:{(i * 15) % 60:02d}"
        if t in ("tstzrange", "daterange") and n == "period":
            lo, hi = TODAY - timedelta(days=30 * (i + 1)), TODAY - timedelta(days=30 * i)
            if i == 0:
                hi = TODAY + timedelta(days=30)
            return f"[{lo},{hi})"
        if t == "tstzrange":
            return f"[{(NOW - timedelta(days=60)).isoformat()},{(NOW + timedelta(days=300)).isoformat()})"
        if t == "daterange":
            return f"[{TODAY - timedelta(days=60)},{TODAY + timedelta(days=300)})"
        if t == "int4range" or t == "int8range":
            return "[1,100)"
        if t.startswith("timestamp"):
            return ago(30).isoformat()
        if t == "date":
            if "expir" in n or n.endswith("_until") or n in ("ends_on", "due_date", "valid_to"):
                return (TODAY + timedelta(days=200 + i)).isoformat()
            if "birth" in n:
                return date(1975 + i % 30, 1 + i % 12, 1 + i % 27).isoformat()
            return (TODAY - timedelta(days=i % 30)).isoformat()
        if t in ("smallint", "integer", "bigint"):
            if engine.is_money(meta_col):
                return str(rnd.randrange(10, 400) * 500)
            if n.endswith("_bp"):
                return "500"
            if n in ("seq", "line_no", "version", "priority") or n.endswith("_no") or n.endswith("_seq"):
                return str(i + 1)
            return str(1 + i % 9)
        if t.startswith("numeric") or t in ("real", "double precision"):
            return f"{1 + (i % 40) * 1.5:.2f}"
        if t == "bytea":
            return uuid.uuid4().bytes + uuid.uuid4().bytes
        # text-like
        if n.endswith("_hash") or n.endswith("_hmac"):
            return uuid.uuid4().hex + uuid.uuid4().hex
        if n == "email" or n.endswith("_email"):
            return f"demo{i + 1}@{table.split('.')[1].replace('_', '-')}.example"
        if "phone" in n or n.endswith("_msisdn"):
            return f"+9639{rnd.randint(30000000, 99999999)}"
        if n in ("code",) or n.endswith("_code"):
            return f"{table.split('.')[1][:4].upper()}{i + 1:03d}"
        if n.endswith("_no") or n.endswith("_number") or n in ("plate", "vin", "serial", "imei", "iban", "reference", "ref"):
            return f"{table.split('.')[1][:3].upper()}-{2026}{i + 1:05d}"
        if n in ("name", "full_name", "holder_name", "contact_name", "driver_name", "legal_name") or n.endswith("_name"):
            return person(i) if any(k in n or k in table for k in ("person", "rider", "agent", "driver", "holder", "contact",
                                                                  "employee", "receiver", "escort")) else \
                f"{table.split('.')[1].replace('_', ' ').title()} {i + 1}"
        if n in ("label", "title"):
            return f"{table.split('.')[1].replace('_', ' ').title()} {i + 1}"
        if n in ("city", "city_code"):
            return CITIES[i % len(CITIES)][0]
        return f"{n.replace('_', ' ').capitalize()} {i + 1}"

    async def row(self, table, i, overrides):
        meta = await engine.table_meta(self.conn, table)
        if table not in self.uniq:
            self.uniq[table] = {r[0] for r in await self.conn.fetch(
                """SELECT a.attname FROM pg_constraint k JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = ANY(k.conkey)
                    WHERE k.conrelid = $1::regclass AND k.contype IN ('u', 'x')""", table)}
        vals = {}
        seen_refs: dict = {}
        for col, c in meta.cols.items():
            if c.generated:
                continue
            k = 0
            if c.ref:
                k = seen_refs.get(c.ref, 0)
                seen_refs[c.ref] = k + 1
            self.pk_col = col in meta.pk
            if col in overrides:
                v = overrides[col]
                v = v(i) if callable(v) and not isinstance(v, tuple) else v
                if isinstance(v, tuple) and v[0] == "!derive":
                    found = [r[0] for r in await self.conn.fetch(v[1], vals.get(v[2]))] if vals.get(v[2]) is not None else []
                    v = found[i % len(found)] if found else None
                elif isinstance(v, tuple) and v[0] == "!refi":
                    ids = await self.refs(c.ref)
                    if not ids:
                        raise LookupError(f"no rows in {c.ref}")
                    v = ids[v[1](i) % len(ids)]
                elif v == REF:
                    ids = await self.refs(c.ref, c.ref_col)
                    if not ids:
                        raise LookupError(f"no rows in {c.ref}")
                    v = ids[(i + k) % len(ids)]
                elif isinstance(v, str) and v.startswith("@"):
                    pool = self.named[v[1:]]
                    v = pool[i % len(pool)]
                if v is None and c.notnull:
                    continue
                vals[col] = v
                continue
            if col == "company_id" and c.ref:
                vals[col] = self.company
            elif col in ("party_id", "customer_party_id", "passenger_party_id") and c.ref and table.split(".")[0] in ("sales", "taxi", "rent", "ship"):
                # one row in five belongs to the demo passenger, the rest to other people
                others = [p for p in await self.refs(c.ref) if p != self.passenger]
                vals[col] = self.passenger if i % 5 == 0 or not others else others[(i + k) % len(others)]
            elif c.has_default and col not in ("status", "state"):
                continue
            elif c.ref:
                ids = await self.refs(c.ref, c.ref_col)
                if not ids:
                    if c.notnull:
                        raise LookupError(f"no rows in {c.ref}")
                    continue
                vals[col] = ids[(i + k) % len(ids)]
            elif c.notnull and not c.has_default:
                vals[col] = self.value(table, col, c, i)
                if vals[col] is None:
                    vals.pop(col)
            elif col in ("status", "state") and c.choices:
                continue
        for k, v in vals.items():      # amounts above are in pounds; money is stored in minor units
            mc = meta.cols[k]
            if engine.is_money(mc) and "points" not in k and mc.pg_type in ("bigint", "integer") and str(v).lstrip("-").isdigit():
                vals[k] = int(v) * 100
        cols = [k for k, v in vals.items() if v is not None]
        params = []
        exprs = []
        for k in cols:
            v = vals[k]
            typ = meta.cols[k].pg_type
            if isinstance(v, (datetime, date)):
                v = v.isoformat()
            if isinstance(v, list) and typ.endswith("[]"):
                v = "{" + ",".join(str(x) for x in v) + "}"
            if isinstance(v, (dict, list)):
                v = json.dumps(v)
            params.append(v if isinstance(v, bytes) else str(v))
            exprs.append(f"${len(params)}" if isinstance(v, bytes) else f"${len(params)}::text::{typ}")
        sql = f"INSERT INTO {table} ({', '.join(cols)}) VALUES ({', '.join(exprs)}) RETURNING {meta.pk[0]}"
        async with self.conn.transaction():
            return await self.conn.fetchval(sql, *params)

    async def make(self, table, n, overrides):
        """Rows created up front for named pools; returns their keys."""
        out = []
        for i in range(n):
            out.append(await self.row(table, i, overrides))
        self.ids.pop(table, None)
        return out

    async def fill(self, table, n, overrides):
        added = 0
        last = None
        for i in range(n):
            try:
                await self.row(table, i, overrides)
                added += 1
            except Exception as e:  # noqa: BLE001 - reported at the end
                last = f"{type(e).__name__}: {str(e).splitlines()[0][:220]}"
                self.partial.setdefault(table, set()).add(last)
        self.ids.pop(table, None)
        if added == 0 and last:
            self.failures[table] = last
        elif table in self.failures:
            del self.failures[table]
        return added


async def main():
    url = os.environ.get("MASSLAK_OWNER_URL")
    if not url:
        sys.exit("MASSLAK_OWNER_URL is required (owner connection)")
    conn = await asyncpg.connect(url)
    s = Seeder(conn)
    s.company = await conn.fetchval("SELECT id FROM iam.party WHERE legal_name = 'Demo Carrier A' AND party_type = 'COMPANY'")
    s.passenger = await conn.fetchval("SELECT party_id FROM iam.app_user WHERE email = 'passenger@masslak.test'")
    if s.company is None or s.passenger is None:
        sys.exit("run seed_demo.py first")
    if await conn.fetchval("SELECT count(*) FROM ship.shipment") > 0:
        print("module demo data already present")
        return
    city = await conn.fetchval("SELECT id FROM ref.city WHERE code = 'DAM'")
    s.named["border"] = []
    for code, name, lat, lng in (("SY-DAM-X901", "Jdeidet Yabous crossing", 33.6330, 36.0750),
                                  ("SY-DRA-X902", "Nasib crossing", 32.5450, 36.2050)):
        sid = await conn.fetchval("SELECT id FROM net.station WHERE code = $1", code) or await conn.fetchval(
            """INSERT INTO net.station (code, city_id, country_code, station_class, subtype, name, lat, lng, status)
               VALUES ($1, $2, 'SY', 'CENTRAL', 'BORDER', $3, $4, $5, 'ACTIVE') RETURNING id""", code, city, name, lat, lng)
        s.named["border"].append(sid)
    s.named["border2"] = list(reversed(s.named["border"]))
    admin = await conn.fetchval("SELECT id FROM iam.app_user WHERE email = 'admin@masslak.test'")
    s.named["companies"] = [s.company]
    for name in ("Al-Sham Transport", "Coast Express", "Northern Freight Co.", "Fajr Mobility"):
        pid = await conn.fetchval("SELECT id FROM iam.party WHERE legal_name = $1", name) or await conn.fetchval(
            "INSERT INTO iam.party (party_type, legal_name, email) VALUES ('COMPANY', $1, $2) RETURNING id",
            name, name.lower().replace(" ", "").replace(".", "") + "@demo.example")
        if not await conn.fetchval("SELECT 1 FROM iam.company WHERE id = $1", pid):
            await conn.execute("INSERT INTO iam.company (id, approval_status, approved_by, approved_at) VALUES ($1, 'APPROVED', $2, now())",
                               pid, admin)
        s.named["companies"].append(pid)
    s.named["partners"] = s.named["companies"][1:]
    for pool, n, vtype, prefix in (("trucks", 6, "OTHER", "TRK"), ("cars", 16, "OTHER", "RNT"), ("taxis", 10, "OTHER", "TAX"),
                                   ("buses", 6, "COACH", "BUS")):
        s.named[pool] = await s.make("fleet.vehicle", n, {
            "vehicle_type": vtype, "plate_no": lambda i, p=prefix: f"{p} {120400 + i * 17}", "chassis_no": lambda i, p=prefix: f"{p}CH{880000 + i}",
            "passenger_seats": 44 if vtype == "COACH" else 4, "seat_layout_id": None, "status": "ACTIVE",
            "make": cycle("Hyundai", "Kia", "Toyota", "Mercedes", "MAN") if pool != "buses" else "Mercedes",
            "manufacture_year": cycle(2018, 2020, 2021, 2023), "owner_party_id": s.company})
    extra = [(t, 3, {}) for t in EXTRA]
    todo = [(t, n, o) for t, n, o in PLAN] + extra
    done: dict = {}
    for _ in range(4):           # retry: later tables provide references for earlier ones
        progress = False
        for table, n, overrides in todo:
            if done.get(table):
                continue
            if (table, n, overrides) in extra and await conn.fetchval(f"SELECT count(*) FROM {table}"):
                done[table] = -1          # reference data that ships with the schema
                continue
            added = await s.fill(table, n, overrides)
            if added:
                done[table] = added
                progress = True
        if not progress:
            break
    print(f"seeded {sum(v for v in done.values() if v > 0)} rows in {sum(1 for v in done.values() if v > 0)} tables")
    for table, err in sorted(s.failures.items()):
        if not done.get(table):
            print(f"  not seeded {table}: {err}")
    if os.environ.get("SEED_VERBOSE"):
        for table, errs in sorted(s.partial.items()):
            for e in sorted(errs):
                print(f"  row skipped in {table}: {e}")
    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
