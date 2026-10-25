"""Trip numbers from the carrier's range (owner's request N7, migration 1165): every carrier has the whole block of a
trip type by default; the platform narrows and widens it; the carrier picks a free number, or takes the default; a
regular trip always asks with a number; a trip made by hand may run under a free extra number."""
import secrets

import pytest

from test_boarding_stations import ADMIN, CARRIER
from test_e2e import OWNER_URL, day, login, owner_sql
from test_schedules import _ask, _route

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def people():
    return login(*ADMIN), login(*CARRIER)


@pytest.fixture(scope="module")
def company():
    return str(owner_sql("""SELECT p.uid FROM iam.party p JOIN iam.company_member m ON m.company_id = p.id
                              JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = $1 LIMIT 1""", CARRIER[0]))


def test_the_carrier_picks_from_its_range_and_the_platform_narrows_it(people, company):
    admin, carrier = people
    whole = carrier.get("/api/carrier/numbers", params={"trip_type": "SCHEDULED", "direction": "OUTBOUND", "from_date": day(3)}).json()
    assert whole["range"] == {"from": 1000, "to": 4999} and whole["suggested"] % 10 == 1
    assert whole["free"] and all(n % 2 == 1 and 1000 <= n <= 4999 for n in whole["free"])
    back = carrier.get("/api/carrier/numbers", params={"trip_type": "SCHEDULED", "direction": "INBOUND", "from_date": day(3)}).json()
    assert all(n % 2 == 0 for n in back["free"])
    assert carrier.put("/api/admin/number-ranges", json={"company_uid": company, "block": "SCHEDULED", "from_no": 3000, "to_no": 3099}).status_code == 403
    bad = admin.put("/api/admin/number-ranges", json={"company_uid": company, "block": "SCHEDULED", "from_no": 3000, "to_no": 5100})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "NUMBER_RANGE_INVALID"
    try:
        r = admin.put("/api/admin/number-ranges", json={"company_uid": company, "block": "SCHEDULED", "from_no": 3000, "to_no": 3099,
                                                         "note": "Decision 7/2026"})
        assert r.status_code == 200 and r.json()["range"] == {"from": 3000, "to": 3099}, r.text
        narrow = carrier.get("/api/carrier/numbers", params={"trip_type": "SCHEDULED", "direction": "OUTBOUND", "from_date": day(3)}).json()
        assert narrow["range"] == {"from": 3000, "to": 3099} and 3000 <= narrow["suggested"] <= 3099
        assert narrow["free"] and all(3000 <= n <= 3099 for n in narrow["free"])
        out = _ask(carrier, proposed_number=1001)
        assert out.status_code == 422 and out.json()["error"]["code"] == "NUMBER_OUT_OF_RANGE", out.text
        assert _ask(carrier, proposed_number=3002).json()["error"]["code"] == "NUMBER_PARITY"
        # no number picked: the request takes the default of the range
        asked = _ask(carrier, route_uid=_route(carrier, "DAM-LTK"))
        assert asked.status_code == 201, asked.text
        number = owner_sql("SELECT proposed_number FROM ops.schedule_request WHERE uid = $1::uuid", asked.json()["uid"])
        assert 3000 <= number <= 3099 and number % 2 == 1
        listed = admin.get("/api/admin/number-ranges").json()
        assert any(x["company_uid"] == company and x["block"] == "SCHEDULED" and x["from_no"] == 3000 and x["ended_at"] is None for x in listed["ranges"])
        assert listed["blocks"]["EXTRA"] == {"from": 8000, "to": 8999}
        # the carrier asks for more; one open request per block; widening answers it
        ask = carrier.post("/api/carrier/number-ranges/requests", json={"block": "SCHEDULED", "note": "Our range is nearly full"})
        assert ask.status_code == 201, ask.text
        again = carrier.post("/api/carrier/number-ranges/requests", json={"block": "SCHEDULED", "note": "Again"})
        assert again.status_code == 409 and again.json()["error"]["code"] == "NUMBER_RANGE_REQUEST_OPEN"
    finally:
        assert admin.put("/api/admin/number-ranges", json={"company_uid": company, "block": "SCHEDULED", "note": "Whole block"}).json()["range"] \
            == {"from": 1000, "to": 4999}
    mine = carrier.get("/api/carrier/number-ranges").json()
    assert next(x for x in mine["ranges"] if x["block"] == "SCHEDULED") == {"block": "SCHEDULED", "from": 1000, "to": 4999}
    assert mine["requests"][0]["status"] == "DONE" and mine["requests"][0]["answer"] == "Whole block"
    # a request the platform declines says why
    ask = carrier.post("/api/carrier/number-ranges/requests", json={"block": "CARGO", "note": "We start cargo"}).json()["uid"]
    assert admin.post(f"/api/admin/number-ranges/requests/{ask}/decline", json={"answer": "No"}).status_code == 422
    assert admin.post(f"/api/admin/number-ranges/requests/{ask}/decline", json={"answer": "The whole block is yours already"}).json() == {"status": "DECLINED"}


def test_a_trip_made_by_hand_runs_under_a_free_extra_number(people):
    _, carrier = people
    route = next(r for r in carrier.get("/api/carrier/routes").json()["routes"] if r["code"] == "DAM-ALP")
    on = day(6)
    offer = carrier.get("/api/carrier/numbers/for-trip", params={"route_uid": route["uid"], "day": on}).json()
    assert offer["extra_range"] == {"from": 8000, "to": 8999} and 8000 <= offer["suggested_extra"] <= 8999
    from test_trip_changes import vehicle
    v = vehicle(carrier, 44)
    when = f"{on}T{5 + secrets.randbelow(4):02d}:{secrets.randbelow(60):02d}:00"
    unknown = carrier.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": v, "departure_local": when, "service_number": 4999})
    assert unknown.status_code == 422 and unknown.json()["error"]["code"] == "SERVICE_NUMBER_UNKNOWN"
    made = carrier.post("/api/carrier/trips", json={"route_uid": route["uid"], "vehicle_uid": v, "departure_local": when,
                                                    "service_number": offer["suggested_extra"]})
    assert made.status_code == 201, made.text
    assert made.json()["trip_code"].endswith(f" {offer['suggested_extra']}")
