"""Isolation between companies, carriers and shippers (study 16.26): signed in as any company, the database shows no row
that belongs to another company, except the rows that are public by design or shared between two parties of a deal.
The sweep runs as the application role on every table that carries a company column, so a new table that forgets its
row-level security fails here."""
import asyncio

import asyncpg

from test_e2e import OWNER_URL

COLUMNS = ("company_id", "carrier_company_id", "owner_company_id", "seller_company_id", "buyer_company_id", "lessee_company_id",
           "shipper_company_id", "agency_id", "partner_company_id", "charged_to_company_id")

# Visible to other companies on purpose; each entry says why
ALLOWED = {
    "ops.trip.company_id": "published trips are the public timetable",
    "net.route.company_id": "active routes are a public catalog",
    "net.line_permit.company_id": "active line permits are public regulatory data",
    "net.timetable_template.company_id": "active shuttle timetables are public",
    "sales.subscription_plan.company_id": "active pass plans are on sale to everyone",
    "pricing.family_offer.company_id": "active family offers are advertised to travellers",
    "pricing.passenger_age_band.company_id": "travellers must see who counts as a child on each carrier",
    "pricing.category_fare_rule.company_id": "child and infant fares are part of the published price",
    "rail.fare_class.company_id": "rail fare classes are a public catalog",
    "rail.coach_layout.company_id": "coach layouts are shown when choosing a seat",
    "rent.rental_company.company_id": "rental companies are listed for renters",
    "rent.rental_branch.company_id": "branches are public pick-up points",
    "rent.rental_addon.company_id": "add-ons are part of the published offer",
    "taxi.taxi_office.company_id": "taxi offices are listed for passengers",
    "taxi.taxi_permit.company_id": "active taxi permits are public regulatory data",
    "ptn.partner.company_id": "service partners (stations, rest stops) are listed for drivers",
    "iam.role.company_id": "platform role templates (no company) are shared",
    # two parties of one deal: each sees the shared record, nothing else of the other
    "sales.booking.company_id": "an agency sees the bookings it sold on a carrier's trip",
    "sales.booking.agency_id": "a carrier sees the bookings agencies sold on its trips",
    "ship.shipment.company_id": "the carrier of a leg sees the shipment it carries",
    "ship.shipment_leg.carrier_company_id": "the shipment owner sees the legs other carriers run",
    "ship.capacity_booking.seller_company_id": "buyer and seller of cargo capacity",
    "ship.capacity_booking.buyer_company_id": "buyer and seller of cargo capacity",
    "ctr.service_contract.carrier_company_id": "the client company sees its transport contract",
    "ptn.partner_sale.company_id": "the partner station sees the sales it made to a carrier's driver",
    "pricing.cancellation_policy.company_id": "cancellation policies are published terms of sale",
    "ops.trip_disruption.partner_company_id": "the carrier of a disrupted trip sees the partner it called in; the partner reads it only (1054)",
    "sales.passenger_compensation.charged_to_company_id": "the parties of a booking see who bears its compensation; only the platform writes it (1054)",
}


async def sweep() -> dict:
    conn = await asyncpg.connect(OWNER_URL)
    try:
        cols = await conn.fetch(
            """SELECT n.nspname || '.' || c.relname AS t, a.attname AS col FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped
                  AND a.attname = ANY($1::text[]) AND n.nspname NOT IN ('audit','pg_catalog','information_schema')""", list(COLUMNS))
        companies = await conn.fetch(
            """SELECT DISTINCT ON (c.id) c.id, c.company_type, m.user_id FROM iam.company c JOIN iam.company_member m ON m.company_id = c.id
                WHERE m.status = 'ACTIVE' ORDER BY c.id, m.user_id""")
        leaks: dict = {}
        for comp in companies:
            scope = "AGENCY" if comp["company_type"] == "AGENCY" else "COMPANY"
            for r in cols:
                key = f"{r['t']}.{r['col']}"
                if key in ALLOWED:
                    continue
                tr = conn.transaction()
                await tr.start()
                try:
                    await conn.execute("SET LOCAL ROLE masslak_app")
                    await conn.execute("SELECT sys.set_context($1, $2, $3)", comp["user_id"], comp["id"], scope)
                    n = await conn.fetchval(f"SELECT count(*) FROM {r['t']} WHERE {r['col']} IS NOT NULL AND {r['col']} <> $1",  # nosec B608
                                            comp["id"])
                    if n:
                        leaks.setdefault(key, []).append((comp["id"], n))
                except asyncpg.InsufficientPrivilegeError:
                    pass                                    # the application cannot read the table at all
                finally:
                    await tr.rollback()
        return leaks
    finally:
        await conn.close()


def test_no_company_sees_another_companys_rows():
    leaks = asyncio.run(sweep())
    assert leaks == {}, f"rows of other companies visible: {leaks}"


async def sweep_writes() -> list:
    """Signed in as a company, try to hand one of its rows to another company: every write policy (WITH CHECK), tenant
    guard or key must refuse it (third-party audit R-01 and R-05)."""
    conn = await asyncpg.connect(OWNER_URL)
    try:
        cols = await conn.fetch(
            """SELECT n.nspname || '.' || c.relname AS t, a.attname AS col FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
                 JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE c.relkind IN ('r','p') AND NOT c.relispartition AND a.attnum > 0 AND NOT a.attisdropped AND a.attgenerated = ''
                  AND a.attname = ANY($1::text[]) AND n.nspname NOT IN ('audit','pg_catalog','information_schema')""", list(COLUMNS))
        companies = await conn.fetch(
            """SELECT DISTINCT ON (c.id) c.id, c.company_type, m.user_id FROM iam.company c JOIN iam.company_member m ON m.company_id = c.id
                WHERE m.status = 'ACTIVE' AND c.company_type IN ('CARRIER','AGENCY') ORDER BY c.id, m.user_id LIMIT 3""")
        accepted = []
        for comp in companies:
            other = next(c["id"] for c in companies if c["id"] != comp["id"])
            scope = "AGENCY" if comp["company_type"] == "AGENCY" else "COMPANY"
            for r in cols:
                key = f"{r['t']}.{r['col']}"
                if key in ALLOWED:
                    continue
                tr = conn.transaction()
                await tr.start()
                try:
                    await conn.execute("SET LOCAL ROLE masslak_app")
                    await conn.execute("SELECT sys.set_context($1, $2, $3)", comp["user_id"], comp["id"], scope)
                    moved = await conn.fetchval(  # nosec B608
                        f"""WITH one AS (SELECT ctid FROM {r['t']} WHERE {r['col']} = $1 LIMIT 1)
                            UPDATE {r['t']} t SET {r['col']} = $2 FROM one WHERE t.ctid = one.ctid RETURNING t.{r['col']} = $2""", comp["id"], other)
                    if moved:
                        accepted.append((key, comp["id"]))
                except asyncpg.PostgresError:
                    pass                                    # refused: policy, guard, key, check or privilege
                finally:
                    await tr.rollback()
        return accepted
    finally:
        await conn.close()


def test_no_company_can_hand_its_rows_to_another_company():
    accepted = asyncio.run(sweep_writes())
    assert accepted == [], f"rows reassigned to another company: {accepted}"
