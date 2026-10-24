"""Truck transport of goods and containers (owner's request, October 2026; migration 1131): a carrier registers a bill of
lading with its house bill and containers, a consignment from the port into Syria, puts a truck and trailer on it at its
own price, issues the TCN once the customs release is recorded, invoices per container or for the whole bill, and
moves the truck to delivery with proof of who received it. Anyone checks a document with its code."""
import time
import uuid

import pytest

from test_e2e import OWNER_URL, client, login, new_passenger, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

BOXES = [("CSQU3054383", "22G1", "SL001"), ("MSKU1234565", "22G1", "SL002")]
NOTE = "freight api test"


@pytest.fixture(scope="module", autouse=True)
def freight_on():
    admin = login("admin@masslak.test", "PLATFORM")
    before = {m["key"]: m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"]}["freight"]
    if not before:
        assert admin.put("/api/admin/modules/freight", json={"enabled": True, "reason": "freight tests"}).status_code == 200
        time.sleep(6)
    yield
    if not before:
        admin.put("/api/admin/modules/freight", json={"enabled": False, "reason": "freight tests"})


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def fleet():
    """A truck of Demo Carrier A on no active movement, a port and a station in Damascus."""
    company = owner_sql("SELECT id FROM iam.party WHERE legal_name = 'Demo Carrier A'")
    truck = owner_sql("""SELECT v.uid::text FROM fleet.vehicle v WHERE v.company_id = $1 AND v.status = 'ACTIVE'
                           AND NOT EXISTS (SELECT 1 FROM frt.truck_movement m WHERE m.truck_vehicle_id = v.id
                                            AND m.status IN ('ASSIGNED','LOADING','IN_TRANSIT','AT_BORDER'))
                         ORDER BY v.id DESC LIMIT 1""", company)
    port = owner_sql("SELECT uid::text FROM net.station WHERE status = 'ACTIVE' ORDER BY id LIMIT 1")
    dest = owner_sql("SELECT s.uid::text FROM net.station s JOIN ref.city c ON c.id = s.city_id WHERE c.code = 'DAM' AND s.status = 'ACTIVE' LIMIT 1")
    owner_sql("UPDATE frt.rate_card SET status = 'ARCHIVED' WHERE company_id = $1 AND note = $2", company, NOTE)
    return {"truck": truck, "port": port, "dest": dest}


def _consignment(carrier, fleet, bill_uid: str) -> dict:
    r = carrier.post("/api/carrier/freight/consignments", json={
        "route_kind": "PORT_IMPORT", "load_type": "FCL",
        "shipper": {"name": "Hamburg Textiles GmbH", "country": "DE"}, "consignee": {"name": "Damascus Trading", "country": "SY"},
        "origin": {"country": "SY"}, "destination": {"country": "SY", "city": "DAM", "station_uid": fleet["dest"]},
        "port_station_uid": fleet["port"], "bill_uid": bill_uid, "hbl_no": "HBL-77", "freight_payer": "CONSIGNEE",
        "cargo": {"category": "GENERAL", "description": "Cotton fabric", "gross_weight_kg": 36000, "packages": 400, "package_type": "rolls"}})
    assert r.status_code == 201, r.text
    return r.json()


def test_port_to_damascus_end_to_end(carrier, fleet):
    assert fleet["truck"], "Demo Carrier A has no free truck"
    lines = client().get("/api/public/freight/shipping-lines").json()["shipping_lines"]
    assert {"MSCU", "MAEU"} <= {x["code"] for x in lines}

    # the bill of lading: two containers declared, a third refused, a wrong check digit refused
    bl_no = "MEDU" + uuid.uuid4().hex[:8].upper()
    r = carrier.post("/api/carrier/freight/bills", json={"shipping_line": "MSCU", "bl_no": bl_no, "container_count": 2,
                                                          "port_station_uid": fleet["port"], "vessel": "MSC AURORA", "voyage": "FA1131"})
    assert r.status_code == 201, r.text
    bill = r.json()
    assert bill["status"] == "OPEN" and bill["shipping_line"] == "MSCU"
    assert carrier.post(f"/api/carrier/freight/bills/{bill['uid']}/house-bills",
                        json={"hbl_no": "HBL-77", "forwarder_name": "Levant Freight"}).status_code == 201
    r = carrier.post(f"/api/carrier/freight/bills/{bill['uid']}/containers",
                     json={"containers": [{"container_no": n, "size_type": s, "seal_no": seal, "hbl_no": "HBL-77"} for n, s, seal in BOXES]})
    assert r.status_code == 201, r.text
    assert len(r.json()["containers"]) == 2
    r = carrier.post(f"/api/carrier/freight/bills/{bill['uid']}/containers", json={"containers": [{"container_no": "MSCU6639870", "size_type": "42G1"}]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "BL_CONTAINER_COUNT"
    r = carrier.post(f"/api/carrier/freight/bills/{bill['uid']}/containers", json={"containers": [{"container_no": "CSQU3054384", "size_type": "22G1"}]})
    assert r.status_code in (409, 422)

    # the consignment takes the bill's containers with their seals
    cons = _consignment(carrier, fleet, bill["uid"])
    assert cons["consignment_no"].startswith("CS-") and cons["status"] == "DRAFT"
    r = carrier.post(f"/api/carrier/freight/consignments/{cons['uid']}/containers", json={"from_bill": True})
    assert r.status_code == 201, r.text
    cons = r.json()
    assert sorted(c["container_no"] for c in cons["containers"]) == sorted(n for n, _, _ in BOXES)
    assert {"RELEASE", "TRUCKS"} <= set(cons["gaps"]["TCN"])

    # the truck owner's price per 20 ft container, used for the truck
    r = carrier.post("/api/carrier/freight/rates", json={"route_kind": "PORT_IMPORT", "from_station_uid": fleet["port"], "to_city": "DAM",
                                                          "unit": "CONTAINER_20", "price": 750_000, "currency": "SYP", "note": NOTE})
    assert r.status_code == 201, r.text
    rate = r.json()
    again = carrier.post("/api/carrier/freight/rates", json={"route_kind": "PORT_IMPORT", "from_station_uid": fleet["port"], "to_city": "DAM",
                                                              "unit": "CONTAINER_20", "price": 800_000, "currency": "SYP", "note": NOTE})
    assert again.status_code == 409                        # one price per lane and unit at a time
    quotes = client().get("/api/public/freight/rates", params={"to_city": "DAM", "unit": "CONTAINER_20"}).json()["rates"]
    assert any(q["uid"] == rate["uid"] for q in quotes)

    r = carrier.post(f"/api/carrier/freight/consignments/{cons['uid']}/movements", json={
        "vehicle_uid": fleet["truck"], "trailer_plate": "TR-1131", "trailer_capacity_ft": 40, "driver_name": "Test Driver", "container_nos": [n for n, _, _ in BOXES],
        "rate_uid": rate["uid"], "driver_mobile": "+963944000111"})
    assert r.status_code == 201, r.text
    cons = r.json()
    move = cons["movements"][0]
    assert move["price"] == 1_500_000 and move["trailer_capacity_ft"] == 40 and len(move["containers"]) == 2
    r = carrier.post(f"/api/carrier/freight/consignments/{cons['uid']}/movements",
                     json={"vehicle_uid": fleet["truck"], "price": 1, "currency": "SYP"})
    assert r.status_code == 409                            # the truck is already on an active movement

    # no TCN before the customs release; then issued, frozen and checked by anyone with its code
    r = carrier.post("/api/carrier/freight/documents", json={"doc_type": "TCN", "consignment_uids": [cons["uid"]]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "DOCUMENT_INCOMPLETE"
    r = carrier.post(f"/api/carrier/freight/bills/{bill['uid']}/release", json={"release_no": "REL-2026-55"})
    assert r.status_code == 200 and r.json()["status"] == "RELEASED"
    r = carrier.post("/api/carrier/freight/documents", json={"doc_type": "TCN", "consignment_uids": [cons["uid"]]})
    assert r.status_code == 201, r.text
    tcn = r.json()
    assert tcn["doc_no"].startswith("TCN-") and tcn["snapshot"]["totals"]["containers"] == 2 and tcn["snapshot"]["totals"]["vehicles"] == 1
    seen = client().get(f"/api/public/freight/documents/{tcn['doc_no']}", params={"code": tcn["verify_code"]})
    assert seen.status_code == 200 and sorted(seen.json()["containers"]) == sorted(n for n, _, _ in BOXES)
    assert client().get(f"/api/public/freight/documents/{tcn['doc_no']}", params={"code": "AAAAAAAAAA"}).status_code == 404
    assert carrier.get(f"/api/carrier/freight/consignments/{cons['uid']}").json()["status"] == "CONFIRMED"

    # invoices: one container, then the whole bill refused for it, voided, then the whole bill
    r = carrier.post("/api/carrier/freight/invoices", json={"consignment_uid": cons["uid"], "basis": "CONTAINER", "container_no": BOXES[0][0]})
    assert r.status_code == 201, r.text
    one = r.json()
    assert one["total"] == 750_000 and one["bill_to_name"] == "Damascus Trading"
    r = carrier.post("/api/carrier/freight/invoices", json={"consignment_uid": cons["uid"], "basis": "BL"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "ALREADY_INVOICED"
    assert carrier.post(f"/api/carrier/freight/invoices/{one['uid']}/void", json={"reason": "invoice the whole bill"}).status_code == 200
    r = carrier.post("/api/carrier/freight/invoices", json={"consignment_uid": cons["uid"], "basis": "BL"})
    assert r.status_code == 201, r.text
    assert r.json()["total"] == 1_500_000 and len(r.json()["lines"]) == 2

    # the truck to delivery, with proof of who received the goods
    for step in ("LOADING", "IN_TRANSIT"):
        r = carrier.post(f"/api/carrier/freight/movements/{move['uid']}/status", json={"status": step})
        assert r.status_code == 200, r.text
    r = carrier.post(f"/api/carrier/freight/movements/{move['uid']}/status", json={"status": "DELIVERED"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "POD_REQUIRED"
    r = carrier.post(f"/api/carrier/freight/movements/{move['uid']}/status", json={"status": "DELIVERED", "received_by": "Warehouse keeper"})
    assert r.status_code == 200, r.text
    done = carrier.get(f"/api/carrier/freight/consignments/{cons['uid']}").json()
    assert done["status"] == "DELIVERED" and done["movements"][0]["pod_received_by"] == "Warehouse keeper"

    # another carrier and a passenger see none of it
    other = login("owner@carrierb.test", "OPERATOR")
    assert other.get(f"/api/carrier/freight/consignments/{cons['uid']}").status_code == 404
    assert other.get(f"/api/carrier/freight/bills/{bill['uid']}").status_code == 404
    assert new_passenger().get("/api/carrier/freight/bills").status_code == 403
    assert carrier.post(f"/api/carrier/freight/rates/{rate['uid']}/archive").status_code == 200


def test_export_needs_its_papers_and_takes_a_consignment_note(carrier, fleet):
    r = carrier.post("/api/carrier/freight/consignments", json={
        "route_kind": "EXPORT", "load_type": "BREAK_BULK",
        "shipper": {"name": "Aleppo Soap Works", "country": "SY"}, "consignee": {"name": "Amman Retail", "country": "JO"},
        "origin": {"country": "SY", "city": "DAM"}, "destination": {"country": "JO", "address": "Amman, Sahab industrial city"},
        "cargo": {"category": "GENERAL", "description": "Laurel soap", "gross_weight_kg": 12000}})
    assert r.status_code == 201, r.text
    cons = r.json()
    assert "TCN_DOMESTIC_ONLY" in cons["gaps"]["TCN"]
    assert {"EXPORT_PERMIT", "INVOICES", "EXIT_BORDER"} <= set(cons["gaps"]["CONSIGNMENT_NOTE"])
    r = carrier.post("/api/carrier/freight/documents", json={"doc_type": "CONSIGNMENT_NOTE", "consignment_uids": [cons["uid"]]})
    assert r.status_code == 409 and r.json()["error"]["code"] == "DOCUMENT_INCOMPLETE"
    r = carrier.post("/api/carrier/freight/consignments", json={
        "route_kind": "EXPORT", "load_type": "BULK", "shipper": {"name": "A Co", "country": "SY"}, "consignee": {"name": "B Co", "country": "JO"},
        "origin": {"country": "SY"}, "destination": {"country": "SY"}, "cargo": {"category": "GENERAL", "description": "Phosphate", "gross_weight_kg": 25000}})
    assert r.status_code == 422                            # an export leaves the country
