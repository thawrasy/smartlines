"""Demo data for a test server: platform staff, a carrier with fleet, routes and a week of trips, a travel agency
and a passenger.

Usage (owner connection, never the API role):
    MASSLAK_OWNER_URL=postgresql://postgres@localhost/masslak python3 backend/scripts/seed_demo.py

All demo accounts share the password printed at the end. Never run this on a production database.
"""
import asyncio
import os
import sys
from datetime import date, datetime, timedelta
from pathlib import Path

import asyncpg

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import json  # noqa: E402
from app.modules.fleet import layout as seat_layout  # noqa: E402
from app.security import hash_password  # noqa: E402
from zoneinfo import ZoneInfo  # noqa: E402

LOCAL_TZ = ZoneInfo("Asia/Damascus")   # the demo carriers are in the default market, Syria (1061)

PASSWORD = os.environ.get("MASSLAK_DEMO_PASSWORD", "Masslak-Demo-2026")

STATIONS = [  # city, number, name, lat, lng
    ("DAM", 1, "Damascus Central Station", 33.5138, 36.2765),
    ("HMS", 1, "Homs Central Station", 34.7308, 36.7094),
    ("HMA", 1, "Hama Central Station", 35.1318, 36.7578),
    ("ALP", 1, "Aleppo Central Station", 36.2021, 37.1343),
    ("LTK", 1, "Latakia Central Station", 35.5238, 35.7917),
    ("TRT", 1, "Tartus Central Station", 34.8890, 35.8866),
    ("DRA", 1, "Daraa Central Station", 32.6250, 36.1060),
]
# route code, [(city, arr_offset, dep_offset, fare_from_origin SYP)]
ROUTES = [
    ("DAM-ALP", [("DAM", 0, 0, 0), ("HMS", 115, 125, 20000), ("HMA", 170, 175, 28000), ("ALP", 315, 315, 42000)]),
    ("ALP-DAM", [("ALP", 0, 0, 0), ("HMA", 140, 145, 14000), ("HMS", 190, 200, 22000), ("DAM", 315, 315, 42000)]),
    ("DAM-LTK", [("DAM", 0, 0, 0), ("HMS", 115, 125, 20000), ("TRT", 200, 205, 30000), ("LTK", 250, 250, 36000)]),
    ("DAM-DRA", [("DAM", 0, 0, 0), ("DRA", 90, 90, 15000)]),
]
DEPARTURES = {"DAM-ALP": ["07:30", "10:00", "15:00"], "ALP-DAM": ["08:00", "16:00"], "DAM-LTK": ["09:00", "14:00"],
              "DAM-DRA": ["08:30", "13:30", "18:00"]}
# Four-digit trip numbers (1119): the first three digits are the line of a vehicle's day, the last its leg, odd away
# from Damascus and even back. DC 1101 to Aleppo at 07:30 returns as DC 1102 at 16:00 on the same vehicle; the other
# departures start lines of their own (a return on its own takes leg 2 of its line).
NUMBERS = {("DAM-ALP", "07:30"): (1101, None), ("DAM-ALP", "10:00"): (1111, None), ("DAM-ALP", "15:00"): (1121, None),
           ("ALP-DAM", "08:00"): (1132, None), ("ALP-DAM", "16:00"): (1102, ("DAM-ALP", "07:30")),
           ("DAM-LTK", "09:00"): (1141, None), ("DAM-LTK", "14:00"): (1151, None),
           ("DAM-DRA", "08:30"): (1161, None), ("DAM-DRA", "13:30"): (1171, None), ("DAM-DRA", "18:00"): (1181, None)}


async def user(conn, party_type, name, email, kind, locale="en"):
    # a person's contact lives on their account only; a company keeps its business e-mail on its party
    pid = await conn.fetchval("INSERT INTO iam.party (party_type, legal_name, email) VALUES ($1, $2, $3) RETURNING id",
                              party_type, name, None if party_type == "PERSON" else email)
    uid = await conn.fetchval(
        """INSERT INTO iam.app_user (party_id, account_kind, email, password_hash, password_changed_at, status, preferred_locale)
           VALUES ($1, $2, $3, $4, now(), 'ACTIVE', $5) RETURNING id""", pid, kind, email, hash_password(PASSWORD), locale)
    return pid, uid


DEMO_LAYOUTS = [
    # name, grid: 44 seats in eleven 2+2 rows; 32 seats in 2+1 rows with the door on the right of the last row
    ("Coach 2+2, 44 seats", seat_layout.preset("2+2", 11)),
    ("VIP 2+1, 32 seats", seat_layout.preset("2+1", 11, door_row=11)),
]


async def seed_layouts(conn) -> bool:
    """Seat layouts for the demo carrier's vehicles, and the matching seat map on trips that have none. Idempotent."""
    company = await conn.fetchval("SELECT id FROM iam.party WHERE legal_name = 'Demo Carrier A' AND party_type = 'COMPANY'")
    if company is None or await conn.fetchval("SELECT 1 FROM fleet.seat_layout WHERE company_id = $1", company):
        return False
    by_seats = {}
    for name, decks in DEMO_LAYOUTS:
        seats = seat_layout.build(decks)
        lid = await conn.fetchval(
            """INSERT INTO fleet.seat_layout (company_id, name, total_seats, decks, grid)
               VALUES ($1, $2, $3, $4, $5::jsonb) RETURNING id""", company, name, len(seats), len(decks), json.dumps(decks))
        await conn.executemany(
            "INSERT INTO fleet.seat_layout_seat (layout_id, seat_no, label, row_no, col_no, deck, cabin) VALUES ($1, $2, $3, $4, $5, $6, $7)",
            [(lid, s.n, s.label, s.row, s.col, s.deck, s.cabin) for s in seats])
        snapshot = {"layout": str(await conn.fetchval("SELECT uid FROM fleet.seat_layout WHERE id = $1", lid)), "name": name,
                    "decks": decks, "seats": [s.as_dict() for s in seats]}
        by_seats[len(seats)] = (lid, snapshot)
    for vid, n in await conn.fetch("SELECT id, passenger_seats FROM fleet.vehicle WHERE company_id = $1", company):
        if n in by_seats:
            lid, snapshot = by_seats[n]
            await conn.execute("UPDATE fleet.vehicle SET seat_layout_id = $2 WHERE id = $1", vid, lid)
            await conn.execute("UPDATE ops.trip SET seat_map = $2::jsonb WHERE vehicle_id = $1 AND seat_map IS NULL AND seats_total = $3",
                               vid, json.dumps(snapshot), n)
    return True


async def seed_finance(conn) -> bool:
    """Finance users other than the administrator: an officer, so payouts and statements are approved by someone other
    than their author, and a treasurer, who pays out what two others approved (the payer approves nothing, 1074)."""
    added = False
    for name, email in (("Finance Officer", "finance@masslak.test"), ("Treasurer", "treasury@masslak.test")):
        if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = $1", email):
            continue
        _, uid = await user(conn, "PERSON", name, email, "PLATFORM")
        await conn.execute("INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = 'PLATFORM_FINANCE' AND company_id IS NULL", uid)
        added = True
    return added


async def seed_counter(conn) -> bool:
    """A counter clerk of the demo carrier, who sells tickets for cash and collects pay-later reservations (1056)."""
    if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = 'counter@carrier.test'"):
        return False
    company = await conn.fetchval(
        "SELECT m.company_id FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = 'owner@carrier.test'")
    if company is None:
        return False
    _, uid = await user(conn, "PERSON", "Lina (counter)", "counter@carrier.test", "COMPANY")
    await conn.execute("INSERT INTO iam.company_member (user_id, company_id, role_id) SELECT $1, $2, id FROM iam.role WHERE code = 'CARRIER_COUNTER' AND company_id IS NULL",
                       uid, company)
    return True


async def seed_security(conn) -> bool:
    """A security officer, so travel-document exceptions drafted by the administrator are approved by someone else."""
    if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = 'security@masslak.test'"):
        return False
    _, uid = await user(conn, "PERSON", "Security Officer", "security@masslak.test", "PLATFORM")
    await conn.execute("INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = 'PLATFORM_SECURITY' AND company_id IS NULL", uid)
    _, uid_privacy = await user(conn, "PERSON", "Privacy Officer", "privacy@masslak.test", "PLATFORM")
    await conn.execute("INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = 'PLATFORM_SECURITY' AND company_id IS NULL", uid_privacy)
    _, uid_privacy2 = await user(conn, "PERSON", "Privacy Officer (second)", "privacy2@masslak.test", "PLATFORM")
    await conn.execute("INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = 'PLATFORM_SECURITY' AND company_id IS NULL", uid_privacy2)
    return True


async def seed_agency(conn) -> bool:
    """A travel agency with a 5% commission, a daily limit of SYP 500,000 and a prepaid SYP 200,000. Idempotent, so it
    can be added to a database seeded before agencies existed."""
    if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = 'agency@agency.test'"):
        return False
    admin = await conn.fetchval("SELECT id FROM iam.app_user WHERE email = 'admin@masslak.test'")
    agency = await conn.fetchval("INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', 'Demo Travel Agency') RETURNING id")
    await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'AGENCY')", agency)
    await conn.execute("INSERT INTO iam.company (id, company_type, approval_status, approved_by, approved_at) VALUES ($1, 'AGENCY', 'APPROVED', $2, now())",
                       agency, admin)
    await conn.execute("INSERT INTO sales.agency_agreement (agency_id, commission_bp, daily_limit, created_by) VALUES ($1, 500, 50000000, $2)",
                       agency, admin)
    wallet = await conn.fetchval("INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, label, currency) VALUES ($1, $1, 'COMPANY', 'Agency wallet', 'SYP') RETURNING id",
                                 agency)
    _, owner = await user(conn, "PERSON", "Rana (agency owner)", "agency@agency.test", "AGENCY")
    await conn.execute("INSERT INTO iam.company_member (user_id, company_id, is_owner) VALUES ($1, $2, true)", owner, agency)
    clearing = await conn.fetchval(
        """SELECT w.id FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
            WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'BANK_CLEARING' AND w.currency = 'SYP'""")
    txn = await conn.fetchval("INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, memo) VALUES ('TOPUP', 'SYP', 'demo-agency-deposit-1', 'demo') RETURNING id")
    await conn.execute("INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES ($1, $2, 'DR', 20000000), ($1, $3, 'CR', 20000000)",
                       txn, clearing, wallet)
    return True


async def seed_families(conn) -> bool:
    """A family offer of the demo carrier, the demo passenger's family (spouse, a child and an infant), and a domestic
    manifest route to a traffic authority approved by the security officer (4.19, 4.20, 11.10). Idempotent."""
    if await conn.fetchval("SELECT 1 FROM iam.family f JOIN iam.app_user u ON u.party_id = f.head_party_id WHERE u.email = 'passenger@masslak.test'"):
        return False
    carrier = await conn.fetchval("SELECT id FROM iam.party WHERE legal_name = 'Demo Carrier A' AND party_type = 'COMPANY'")
    owner = await conn.fetchval("SELECT id FROM iam.app_user WHERE email = 'owner@carrier.test'")
    await conn.execute(
        """INSERT INTO pricing.family_offer (company_id, code, name, applies_to, min_members, min_adults, min_minors, discount_type,
             discount_value, max_discount, status, created_by)
           VALUES ($1, 'FAMILY10', 'Family travel: 10% off', 'BOTH', 3, 1, 1, 'PCT', 10, 2000000, 'ACTIVE', $2) ON CONFLICT DO NOTHING""",
        carrier, owner)
    head = await conn.fetchrow("SELECT u.party_id, p.legal_name FROM iam.app_user u JOIN iam.party p ON p.id = u.party_id WHERE u.email = 'passenger@masslak.test'")
    fam = await conn.fetchval("INSERT INTO iam.family (head_party_id, name) VALUES ($1, 'Al-Halabi family') RETURNING id", head["party_id"])
    today = date.today()
    members = (("SELF", "Samer", "Fadi", "Nabil", "Al-Halabi", today.replace(year=today.year - 38), "M", head["party_id"]),
               ("SPOUSE", "Rasha", "Adel", "Hassan", "Al-Halabi", today.replace(year=today.year - 34), "F", None),
               ("DAUGHTER", "Lana", "Samer", "Fadi", "Al-Halabi", today.replace(year=today.year - 8), "F", None),
               ("SON", "Karim", "Samer", "Fadi", "Al-Halabi", today.replace(year=today.year - 1), "M", None))
    for relation, first, father, grand, last, born, sex, party in members:
        if party is None:
            party = await conn.fetchval(
                """INSERT INTO iam.party (party_type, legal_name, nationality, birth_date, gender, country_code)
                   VALUES ('PERSON', $1, 'SY', $2, $3, 'SY') RETURNING id""", f"{first} {father} {grand} {last}", born, sex)
        await conn.execute(
            """INSERT INTO iam.family_member (family_id, party_id, relation, first_name, father_name, grandfather_name, last_name,
                 nationality, birth_date, gender, funding) VALUES ($1, $2, $3, $4, $5, $6, $7, 'SY', $8, $9, $10)""",
            fam, party, relation, first, father, grand, last, born, sex, "OWN" if relation == "SELF" else "HEAD_WALLET")
    authority = await conn.fetchval(
        """INSERT INTO sec.authority_profile (code, name, authority_type, protocol, active) VALUES ('TRAFFIC', 'Traffic police', 'TRAFFIC', 'REST', true)
           ON CONFLICT (code) DO UPDATE SET active = true RETURNING id""")
    admin = await conn.fetchval("SELECT id FROM iam.app_user WHERE email = 'admin@masslak.test'")
    security = await conn.fetchval("SELECT id FROM iam.app_user WHERE email = 'security@masslak.test'")
    if security:
        await conn.execute(
            """INSERT INTO brd.manifest_route (authority_id, scope, channel, legal_basis, status, created_by, approved_by, approved_at)
               VALUES ($1, 'DOMESTIC', 'API_PULL', 'Demo: passenger lists of domestic coach trips', 'ACTIVE', $2, $3, now())""",
            authority, admin, security)
    return True


async def seed_charter(conn) -> bool:
    """What the demo carrier hires out (1123): coaches for tourism companies by the day, its scheduled trips whole or in
    blocks of ten seats, and a van for travellers by special request. Idempotent."""
    carrier = await conn.fetchval("SELECT id FROM iam.party WHERE legal_name = 'Demo Carrier A' AND party_type = 'COMPANY'")
    if carrier is None or await conn.fetchval("SELECT 1 FROM sales.charter_offer WHERE company_id = $1", carrier):
        return False
    owner = await conn.fetchval("SELECT id FROM iam.app_user WHERE email = 'owner@carrier.test'")
    dam = await conn.fetchval("SELECT id FROM ref.city WHERE code = 'DAM'")
    offers = (
        ("VEHICLE", "Coach with driver for tours", "COACH", 45, 4, None, ["AGENCY"], "PER_DAY", 150_000_000, 48, 72, 80,
         "Driver and fuel included up to 300 km a day; the driver rests 9 hours a night; waiting beyond two hours is charged."),
        ("WHOLE_TRIP", "Our scheduled trips, whole or in blocks", None, None, 1, 10, ["AGENCY"], "PER_SEAT", 2_500_000, 24, 48, 100,
         "A block of ten seats or more on any of our scheduled trips, or the whole trip when no seat is sold yet."),
        ("VEHICLE", "Family van by special request", "VAN", 12, 2, None, ["PASSENGER", "AGENCY"], "ON_REQUEST", None, 24, 24, 50,
         "Priced for each request: the route, the day and the waiting. Driver included."),
    )
    for kind, title, vtype, seats, vehicles, min_seats, audience, basis, price, notice, before, pct, policy in offers:
        await conn.execute(
            """INSERT INTO sales.charter_offer (company_id, kind, title, vehicle_type, seats, vehicles, partial_seats, min_seats, audience,
                 price_basis, price, currency, notice_hours, cancel_before_hours, cancel_refund_pct, base_city_id, policy, created_by)
               VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'SYP', $12, $13, $14, $15, $16, $17)""",
            carrier, kind, title, vtype, seats, vehicles, min_seats is not None, min_seats, audience, basis, price, notice, before, pct,
            dam, policy, owner)
    return True


async def main():
    url = os.environ.get("MASSLAK_OWNER_URL", "postgresql://postgres@localhost:5432/masslak")
    conn = await asyncpg.connect(url)
    # demo accounts share a published password: never on a production database (review of 1.47.0, R-26)
    env = await conn.fetchval("SELECT value #>> '{}' FROM sys.setting WHERE key = 'deploy.environment'")
    if "production" in (env, os.environ.get("MASSLAK_ENVIRONMENT")):
        sys.exit("refusing to load demo data: this database belongs to a production server")
    async with conn.transaction():
        await conn.execute("SELECT sys.set_context(NULL, NULL, 'SYSTEM')")
        if await conn.fetchval("SELECT 1 FROM iam.app_user WHERE email = 'admin@masslak.test'"):
            added = [what for what, done in (("agency", await seed_agency(conn)), ("seat layouts", await seed_layouts(conn)),
                                                    ("finance user", await seed_finance(conn)),
                                                    ("security officer", await seed_security(conn)),
                                                    ("counter clerk", await seed_counter(conn)),
                                                    ("family and manifest route", await seed_families(conn)),
                                                    ("charter offers", await seed_charter(conn))) if done]
            print(f"demo {' and '.join(added)} added" if added else "demo data already present")
            return
        # Platform staff
        _, admin = await user(conn, "PERSON", "Platform Administrator", "admin@masslak.test", "PLATFORM")
        for role in ("PLATFORM_ADMIN", "PLATFORM_SECURITY", "PLATFORM_FINANCE"):
            await conn.execute("INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = $2 AND company_id IS NULL",
                               admin, role)
        _, regulator = await user(conn, "PERSON", "Regulator Observer", "regulator@masslak.test", "PLATFORM")
        await conn.execute("INSERT INTO iam.user_role (user_id, role_id) SELECT $1, id FROM iam.role WHERE code = 'REGULATOR' AND company_id IS NULL",
                           regulator)
        await conn.execute("SELECT sys.set_context($1, NULL, 'SYSTEM')", admin)

        # Central stations
        station = {}
        for city, n, name, lat, lng in STATIONS:
            cid = await conn.fetchval("SELECT id FROM ref.city WHERE code = $1", city)
            station[city] = await conn.fetchval(
                """INSERT INTO net.station (code, city_id, country_code, station_class, name, lat, lng, status, verified_by, verified_at)
                   VALUES ($1, $2, 'SY', 'CENTRAL', $3, $4, $5, 'ACTIVE', $6, now()) RETURNING id""",
                f"SY-{city}-C{n:03d}", cid, name, lat, lng, admin)

        # Carrier with owner, driver, vehicles
        company = await conn.fetchval("INSERT INTO iam.party (party_type, legal_name) VALUES ('COMPANY', 'Demo Carrier A') RETURNING id")
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'OPERATOR')", company)
        await conn.execute("INSERT INTO iam.company (id, approval_status, approved_by, approved_at) VALUES ($1, 'APPROVED', $2, now())",
                           company, admin)
        # DCA, and DC the designator of its trip numbers ("DC 1101", 1114, 1119)
        await conn.execute("""INSERT INTO net.carrier_code (company_id, code3, code2, status, approved_by, valid_from)
                              VALUES ($1, 'DCA', 'DC', 'ACTIVE', $2, current_date)""", company, admin)
        await conn.execute("INSERT INTO fin.wallet (owner_party_id, company_id, wallet_type, label, currency) VALUES ($1, $1, 'COMPANY', 'Carrier wallet', 'SYP')",
                           company)
        _, owner = await user(conn, "PERSON", "Maher (carrier owner)", "owner@carrier.test", "COMPANY")
        await conn.execute("INSERT INTO iam.company_member (user_id, company_id, is_owner) VALUES ($1, $2, true)", owner, company)
        drivers = []
        for i, (dname, demail) in enumerate((("Khaled (driver)", "driver@carrier.test"), ("Omar (driver)", "driver2@carrier.test"),
                                              ("Hasan (driver)", "driver3@carrier.test"))):
            dparty, duser = await user(conn, "PERSON", dname, demail, "COMPANY")
            await conn.execute("INSERT INTO iam.company_member (user_id, company_id, role_id) SELECT $1, $2, id FROM iam.role WHERE code = 'CARRIER_DRIVER' AND company_id IS NULL",
                               duser, company)
            await conn.execute("INSERT INTO fleet.crew_profile (party_id, company_id, crew_type, license_class) VALUES ($1, $2, 'DRIVER', 'D')",
                               dparty, company)
            drivers.append(dparty)
        vehicles = []
        for plate, chassis, seats in (("123456", "CHS-DCA-0001", 44), ("654321", "CHS-DCA-0002", 44), ("223344", "CHS-DCA-0003", 32)):
            vid = await conn.fetchval(
                # a coach's luggage hold, registered for 800 kg of cargo (parcels on its trips stay within it, 1067)
                """INSERT INTO fleet.vehicle (company_id, vehicle_type, make, model, manufacture_year, plate_no, chassis_no, passenger_seats,
                     owner_party_id, status, cargo_capacity_kg) VALUES ($1, 'COACH', 'Demo', 'Coach', 2022, $2, $3, $4, $1, 'ACTIVE', 800)
                   RETURNING id""",
                company, plate, chassis, seats)
            await conn.execute(
                """INSERT INTO fleet.license_record (company_id, subject_type, subject_id, license_type, license_no, issuer, issue_date, expiry_date, status)
                   VALUES ($1, 'VEHICLE', $2, 'INSURANCE', $3, 'Demo Insurance Co.', current_date - 30, current_date + 335, 'VALID')""",
                company, vid, f"POL-{plate}")
            vehicles.append((vid, seats))

        # Routes and a week of published trips; vehicles rotate so they never overlap
        await conn.execute("SELECT sys.set_context($1, $2, 'COMPANY')", owner, company)
        today = datetime.now(LOCAL_TZ).date()
        busy: dict[int, list] = {v: [] for v, _ in vehicles}
        n_trips = 0
        number_ids: dict[tuple, int] = {}          # (route, departure) -> its service number
        reserved: dict[tuple, tuple] = {}          # (route, departure, day) -> the vehicle kept for it, and when
        followers = {after: key for key, (_, after) in NUMBERS.items() if after}
        stops_of = dict(ROUTES)
        for code, stops in ROUTES:
            ids = [station[c] for c, *_ in stops]
            rid = await conn.fetchval(
                """INSERT INTO net.route (company_id, code, origin_station_id, dest_station_id, service_type, std_duration_min)
                   VALUES ($1, $2, $3, $4, $5, $6) RETURNING id""",
                company, code, ids[0], ids[-1], "INDIRECT" if len(stops) > 2 else "DIRECT", stops[-1][1])
            for i, (city, arr, dep, fare) in enumerate(stops):
                await conn.execute(
                    """INSERT INTO net.route_stop (route_id, seq, station_id, kind, arr_offset_min, dep_offset_min, fare_from_origin)
                       VALUES ($1, $2, $3, $4, $5, $6, $7)""",
                    rid, i, station[city], "ORIGIN" if i == 0 else ("DEST" if i == len(stops) - 1 else "STOP"), arr, dep, fare * 100)
            # one service number for each departure time, repeated every day (study 4.16 b, 1114): odd outbound from
            # Damascus, even on the way back; a leg after another on the same vehicle follows it (1119)
            numbers = {}
            for hhmm in DEPARTURES[code]:
                number, after = NUMBERS[(code, hhmm)]
                numbers[hhmm] = number_ids[(code, hhmm)] = await conn.fetchval(
                    """INSERT INTO net.service_number (company_id, number, block, route_id, direction, valid, follows_id)
                       VALUES ($1, $2, 'SCHEDULED', $3, $4, daterange(current_date - 1, NULL), $5) RETURNING id""",
                    company, number, rid, "OUTBOUND" if number % 2 else "INBOUND", number_ids.get(after) if after else None)
            for day in range(0, 7):
                for hhmm in DEPARTURES[code]:
                    h, m = map(int, hhmm.split(":"))
                    dep_at = datetime(today.year, today.month, today.day, h, m, tzinfo=LOCAL_TZ) + timedelta(days=day)
                    if dep_at < datetime.now(LOCAL_TZ) + timedelta(minutes=45):
                        continue
                    arr_at = dep_at + timedelta(minutes=stops[-1][1])
                    kept = reserved.pop((code, hhmm, day), None)                  # the vehicle of the leg before it
                    if kept:
                        busy[kept[0]].remove(kept[1])
                    vid, seats = next(((v, s) for v, s in sorted(vehicles, key=lambda x: x[0] != (kept[0] if kept else None))
                                       if all(arr_at + timedelta(minutes=30) <= b0 or dep_at >= b1 + timedelta(minutes=30) for b0, b1 in busy[v])),
                                      (None, None))
                    if vid is None:
                        continue
                    busy[vid].append((dep_at, arr_at))
                    if (code, hhmm) in followers:                                  # keep the vehicle for its next leg
                        fcode, fhhmm = followers[(code, hhmm)]
                        fh, fm = map(int, fhhmm.split(":"))
                        f_dep = datetime(today.year, today.month, today.day, fh, fm, tzinfo=LOCAL_TZ) + timedelta(days=day)
                        window = (f_dep, f_dep + timedelta(minutes=stops_of[fcode][-1][1]))
                        busy[vid].append(window)
                        reserved[(fcode, fhhmm, day)] = (vid, window)
                    trip_no = f"DCA-{code}-{dep_at:%H%M}/{dep_at:%d%b%y}".upper()
                    tid = await conn.fetchval(
                        """INSERT INTO ops.trip (trip_no, company_id, route_id, service_type, vehicle_id, departure_at, arrival_at, status,
                             seats_total, segments_count, currency, base_price, published_at, service_number_id)
                           VALUES ($1, $2, $3, $4, $5, $6, $7, 'PUBLISHED', $8, $9, 'SYP', $10, now(), $11) RETURNING id""",
                        trip_no, company, rid, "INDIRECT" if len(stops) > 2 else "DIRECT", vid, dep_at, arr_at, seats,
                        len(stops) - 1, stops[-1][3] * 100, numbers[hhmm])
                    for i, (city, arr, dep, fare) in enumerate(stops):
                        await conn.execute(
                            """INSERT INTO ops.trip_stop (trip_id, seq, station_id, sched_arr, sched_dep, fare_from_origin)
                               VALUES ($1, $2, $3, $4, $5, $6)""",
                            tid, i, station[city], dep_at + timedelta(minutes=arr), dep_at + timedelta(minutes=dep), fare * 100)
                    await conn.execute(
                        "INSERT INTO ops.seat_segment (trip_id, seat_no, seg) SELECT $1, s, g FROM generate_series(1, $2) s, generate_series(0, $3) g",
                        tid, seats, len(stops) - 2)
                    # one driver per vehicle, so crew schedules never overlap either
                    await conn.execute("INSERT INTO ops.crew_assignment (trip_id, party_id, crew_role) VALUES ($1, $2, 'DRIVER')",
                                       tid, drivers[[v for v, _ in vehicles].index(vid)])
                    n_trips += 1

        await seed_agency(conn)
        await seed_layouts(conn)
        await seed_finance(conn)
        await seed_security(conn)

        # Passenger with a funded wallet
        await conn.execute("SELECT sys.set_context(NULL, NULL, 'SYSTEM')")
        pparty, _ = await user(conn, "PERSON", "Samer Al-Halabi", "passenger@masslak.test", "CUSTOMER")
        await conn.execute("INSERT INTO iam.party_role (party_id, role_code) VALUES ($1, 'PASSENGER')", pparty)
        wallet = await conn.fetchval(
            "INSERT INTO fin.wallet (owner_party_id, wallet_type, label, currency) VALUES ($1, 'USER', 'Passenger wallet', 'SYP') RETURNING id", pparty)
        clearing = await conn.fetchval(
            """SELECT w.id FROM fin.wallet w JOIN iam.party p ON p.id = w.owner_party_id
                WHERE p.legal_name = 'Masslak Platform' AND w.wallet_type = 'GATEWAY_CLEARING' AND w.currency = 'SYP'""")
        txn = await conn.fetchval("INSERT INTO fin.ledger_txn (txn_type, currency, idempotency_key, memo) VALUES ('TOPUP', 'SYP', 'demo-topup-1', 'demo') RETURNING id")
        await conn.execute("INSERT INTO fin.ledger_entry (txn_id, wallet_id, direction, amount) VALUES ($1, $2, 'DR', 50000000), ($1, $3, 'CR', 50000000)",
                           txn, clearing, wallet)
        await seed_families(conn)
        await seed_counter(conn)
        await seed_charter(conn)
    await conn.close()
    print(f"demo data created: {n_trips} trips")
    print(f"accounts (password: {PASSWORD}):")
    for e, p in (("passenger@masslak.test", "PASSENGER"), ("owner@carrier.test", "OPERATOR"), ("counter@carrier.test", "OPERATOR"),
                 ("driver@carrier.test", "DRIVER"),
                 ("agency@agency.test", "AGENCY"), ("finance@masslak.test", "PLATFORM"), ("treasury@masslak.test", "PLATFORM"),
                 ("security@masslak.test", "PLATFORM"), ("privacy@masslak.test", "PLATFORM"), ("privacy2@masslak.test", "PLATFORM"), ("admin@masslak.test", "PLATFORM"), ("regulator@masslak.test", "PLATFORM")):
        print(f"  {e:28s} portal {p}")


if __name__ == "__main__":
    asyncio.run(main())
