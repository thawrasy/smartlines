"""Two clerks loading the last space of a trip's hold at the same moment: one shipment fits, the other is refused
(1067, after the external technical report of October 2026).

The capacity row is locked while a change is checked, so the second clerk waits for the first and then counts the
first clerk's shipment. Without the lock both would see free space and both would fit.
"""
import asyncio
import uuid

import asyncpg
import pytest

from test_e2e import OWNER_URL

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


async def _setup(conn) -> dict:
    trip = await conn.fetchrow("""SELECT t.id, t.company_id, t.vehicle_id FROM ops.trip t
                                   WHERE t.vehicle_id IS NOT NULL AND t.status = 'PUBLISHED'
                                     -- a vehicle offering no hold on any trip, so restoring its capacity afterwards is allowed
                                     AND NOT EXISTS (SELECT 1 FROM ship.trip_cargo_capacity c JOIN ops.trip o ON o.id = c.trip_id
                                                      WHERE o.vehicle_id = t.vehicle_id)
                                   ORDER BY t.departure_at DESC LIMIT 1""")
    old_capacity = await conn.fetchval("SELECT cargo_capacity_kg FROM fleet.vehicle WHERE id = $1", trip["vehicle_id"])
    await conn.execute("UPDATE fleet.vehicle SET cargo_capacity_kg = greatest(cargo_capacity_kg, 500) WHERE id = $1",
                       trip["vehicle_id"])
    await conn.execute("INSERT INTO ship.trip_cargo_capacity (trip_id, max_weight_kg) VALUES ($1, 300)", trip["id"])
    service = await conn.fetchval("SELECT min(id) FROM ship.service_product")
    if service is None:
        service = await conn.fetchval("INSERT INTO ship.service_product (code, name) VALUES ('CAP_TEST', 'Capacity test') RETURNING id")
    stations = await conn.fetch("SELECT id FROM net.station ORDER BY id LIMIT 2")
    shipper = await conn.fetchval("SELECT min(id) FROM iam.party WHERE party_type = 'PERSON'")
    tag = uuid.uuid4().hex[:10]
    shipments = []
    for n in (1, 2):
        sid = await conn.fetchval(
            """INSERT INTO ship.shipment (tracking_no, company_id, shipper_party_id, service_id, origin_station_id, dest_station_id)
               VALUES ($1, $2, $3, $4, $5, $6) RETURNING id""",
            f"CAP-{tag}-{n}", trip["company_id"], shipper, service, stations[0]["id"], stations[1]["id"])
        await conn.execute("""INSERT INTO ship.parcel (shipment_id, piece_no, label_no, weight_kg, content_desc)
                              VALUES ($1, 1, $2, 200, 'capacity race')""", sid, f"CAPL-{tag}-{n}")
        shipments.append(sid)
    return {"trip": trip, "old_capacity": old_capacity, "shipments": shipments}


async def _cleanup(conn, s: dict) -> None:
    await conn.execute("DELETE FROM ship.shipment_leg WHERE shipment_id = ANY($1::bigint[])", s["shipments"])
    await conn.execute("DELETE FROM ship.parcel WHERE shipment_id = ANY($1::bigint[])", s["shipments"])
    await conn.execute("DELETE FROM ship.shipment WHERE id = ANY($1::bigint[])", s["shipments"])
    await conn.execute("DELETE FROM ship.trip_cargo_capacity WHERE trip_id = $1", s["trip"]["id"])
    await conn.execute("UPDATE fleet.vehicle SET cargo_capacity_kg = $2 WHERE id = $1", s["trip"]["vehicle_id"], s["old_capacity"])


def test_two_clerks_cannot_both_fit_into_the_last_space():
    async def run():
        setup = await asyncpg.connect(OWNER_URL)
        s = await _setup(setup)
        first, second = await asyncpg.connect(OWNER_URL), await asyncpg.connect(OWNER_URL)
        leg = """INSERT INTO ship.shipment_leg (shipment_id, seq, mode, carrier_company_id, trip_id)
                 VALUES ($1, 1, 'BUS_HOLD', $2, $3)"""
        try:
            t1, t2 = first.transaction(), second.transaction()
            await t1.start()
            await t2.start()
            await first.execute(leg, s["shipments"][0], s["trip"]["company_id"], s["trip"]["id"])   # 200 of 300 kg
            waiting = asyncio.create_task(second.execute(leg, s["shipments"][1], s["trip"]["company_id"], s["trip"]["id"]))
            await asyncio.sleep(0.5)
            assert not waiting.done(), "the second clerk must wait for the first, not check against stale space"
            await t1.commit()
            with pytest.raises(asyncpg.RaiseError, match="CARGO_CAPACITY"):
                await waiting
            await t2.rollback()
            used = await setup.fetchval("SELECT used_weight_kg FROM ship.trip_cargo_capacity WHERE trip_id = $1", s["trip"]["id"])
            assert used == 200
        finally:
            await first.close()
            await second.close()
            await _cleanup(setup, s)
            await setup.close()
    asyncio.run(run())
