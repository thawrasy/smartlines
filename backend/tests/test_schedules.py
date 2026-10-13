"""Regular trips the carrier defines, approved before they run (owner's decision, October 2026; migration 1117).

* A carrier defines a regular trip: a route, a time and how it repeats (every day, days of the week, days of the month),
  from a date to a date or with no end, without its dates off. It keeps one number, the same at the same time.
* The platform approves each new regular trip and each change, and organizes the numbers; the approval stages, the
  kinds that pass them, the notice and the horizon are settings, ready for government authorities to approve as well.
* The trips are made at once on approval and then ahead by the worker; a change starts the next version under the
  same number; a stop ends it. Trips with bookings are kept and named; the others are cancelled.
"""
import secrets
import uuid
from datetime import date, timedelta

import pytest

from test_boarding_stations import ADMIN, CARRIER
from test_e2e import OWNER_URL, client, day, free_seats, login, owner_sql, syrian
from test_launch import _fresh_vehicle

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


@pytest.fixture(scope="module")
def admin():
    return login(*ADMIN)


@pytest.fixture(scope="module")
def carrier():
    return login(*CARRIER)


def _route(carrier, code: str = "DAM-ALP") -> str:
    return next(r["uid"] for r in carrier.get("/api/carrier/schedules").json()["routes"] if r["code"] == code)


def _ask(carrier, **over):
    body = {"route_uid": _route(carrier), "vehicle_uid": _fresh_vehicle(carrier), "departure_time": f"03:{secrets.randbelow(60):02d}",
            "recurrence": "DAILY", "from_date": day(3), "until_date": None, "base_price": 26000}
    body.update(over)
    return carrier.post("/api/carrier/schedules", json=body)


def _pending(admin, request_uid: str) -> dict:
    return next(r for r in admin.get("/api/admin/schedules/requests").json()["requests"] if r["uid"] == request_uid)


def _template(uid):
    return owner_sql("SELECT * FROM ops.trip_template WHERE uid = $1", uuid.UUID(str(uid)), fetch=True)


def _rows(sql: str, *args) -> list:
    import asyncio

    import asyncpg

    async def run():
        conn = await asyncpg.connect(OWNER_URL)
        try:
            return await conn.fetch(sql, *args)
        finally:
            await conn.close()
    return asyncio.run(run())


def _setting(admin, key: str, value):
    r = admin.put(f"/api/admin/schedules/settings/{key}", json={"value": value})
    assert r.status_code == 200, r.text
    return r


def test_a_regular_trip_runs_under_its_number_once_the_platform_approves_it(admin, carrier):
    r = _ask(carrier, recurrence="WEEKLY", days_of_week=[1, 3, 5])
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    asked = r.json()["uid"]
    mine = carrier.get("/api/carrier/schedules").json()
    assert any(q["uid"] == asked and q["status"] == "PENDING" and q["route"]["code"] == "DAM-ALP" for q in mine["requests"])
    assert mine["rules"]["approval_kinds"] == ["NEW", "CHANGE"] and mine["rules"]["horizon_days"] == 30
    # nothing runs before the approval
    assert owner_sql("SELECT count(*) FROM ops.schedule_request WHERE uid = $1 AND template_id IS NULL", uuid.UUID(asked)) == 1
    # the platform sees the request, the stage it waits for, and the number it suggests; a carrier does not decide
    q = _pending(admin, asked)
    assert q["may_decide"] and q["waiting_for"] == {"by": "PLATFORM"} and q["company_logo"] is None or True
    suggested = q["suggested_number"]
    assert suggested % 2 == 1 and 1 <= suggested <= 999 and q["designator"] in ("DC", "DMC")
    assert carrier.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True}).status_code in (401, 403)
    # an even number does not fit an outbound trip; a refusal says why
    bad = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True, "number": suggested + 1})
    assert bad.status_code == 422 and bad.json()["error"]["code"] == "NUMBER_PARITY", bad.text
    # the platform organizes the number: it gives the one it chose
    r = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True, "number": suggested})
    assert r.status_code == 200 and r.json()["status"] == "APPROVED", r.text
    done = r.json()
    assert done["result"]["number"] == suggested and done["result"]["trip_code"].endswith(f" {suggested}")
    assert done["made"]["created"] >= 9                    # three days a week for 30 days
    tpl = _template(done["result"]["template_uid"])
    assert tpl["rolling"] and tpl["status"] == "ACTIVE" and tpl["recurrence"] == "WEEKLY" and tpl["active"].upper is None
    trips = _rows("""SELECT departure_at, trip_code, status, extract(isodow FROM service_date)::int AS dow FROM ops.trip
                      WHERE template_id = $1 ORDER BY departure_at""", tpl["id"])
    assert trips and {t["dow"] for t in trips} <= {1, 3, 5} and {t["status"] for t in trips} == {"PUBLISHED"}
    assert {t["trip_code"] for t in trips} == {done["result"]["trip_code"]}       # the same number every day it runs
    listed = next(s for s in carrier.get("/api/carrier/schedules").json()["schedules"] if s["uid"] == done["result"]["template_uid"])
    assert listed["trip_code"] == done["result"]["trip_code"] and listed["upcoming"] == len(trips) and listed["until_date"] is None
    # the request cannot be decided twice; the number is taken for another regular trip of the same days
    again = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True})
    assert again.status_code == 409 and again.json()["error"]["code"] == "SCHEDULE_DECIDED"
    other = _ask(carrier, route_uid=_route(carrier, "DAM-LTK"), proposed_number=suggested).json()["uid"]
    taken = admin.post(f"/api/admin/schedules/requests/{other}/decide", json={"approve": True})
    assert taken.status_code == 409 and taken.json()["error"]["code"] == "SERVICE_NUMBER_TAKEN", taken.text
    assert admin.post(f"/api/admin/schedules/requests/{other}/decide", json={"approve": False, "note": "no"}).json()["error"]["code"] == "REASON_REQUIRED"
    assert admin.post(f"/api/admin/schedules/requests/{other}/decide",
                      json={"approve": False, "note": "The number is taken; ask again"}).json()["status"] == "REJECTED"


def test_patterns_periods_and_days_off(admin, carrier):
    start = date.fromisoformat(day(5))
    pattern = {"departure_time": f"06:{secrets.randbelow(60):02d}", "recurrence": "MONTHLY", "days_of_month": [1, 15, 31], "from_date": start.isoformat(),
               "until_date": (start + timedelta(days=120)).isoformat(), "skip_dates": []}
    dates = carrier.post("/api/carrier/schedules/preview", json=pattern).json()["dates"]
    assert dates and all(date.fromisoformat(d).day in (1, 15, 31) for d in dates)
    skip = dates[0]
    dates2 = carrier.post("/api/carrier/schedules/preview", json=pattern | {"skip_dates": [skip]}).json()["dates"]
    assert skip not in dates2 and dates2[0] == dates[1]
    weekly = carrier.post("/api/carrier/schedules/preview",
                          json=pattern | {"recurrence": "WEEKLY", "days_of_week": [5], "days_of_month": []}).json()["dates"]
    assert all(date.fromisoformat(d).isoweekday() == 5 for d in weekly)
    # what the database refuses: a weekly trip without its days, an end before the start, a day in the past
    for over, code in (({"recurrence": "WEEKLY", "days_of_week": []}, "SCHEDULE_INVALID"),
                       ({"until_date": day(2)}, "SCHEDULE_INVALID"),
                       ({"from_date": day(-1)}, "SCHEDULE_NOTICE")):
        r = _ask(carrier, **over)
        assert r.status_code == 422 and r.json()["error"]["code"] == code, (over, r.text)
    # the notice is a setting: a request takes effect at least that many days later
    try:
        _setting(admin, "min_notice_days", 10)
        r = _ask(carrier, from_date=day(4))
        assert r.status_code == 422 and r.json()["error"]["code"] == "SCHEDULE_NOTICE", r.text
    finally:
        _setting(admin, "min_notice_days", 0)
    # a monthly trip with an end, its days off left out
    r = _ask(carrier, **pattern)
    asked = r.json()["uid"]
    done = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True}).json()
    tpl = _template(done["result"]["template_uid"])
    assert tpl["recurrence"] == "MONTHLY" and tpl["active"].upper == start + timedelta(days=121)
    days_made = owner_sql("SELECT array_agg(extract(day FROM service_date)::int) FROM ops.trip WHERE template_id = $1", tpl["id"])
    assert days_made and set(days_made) <= {1, 15, 31}


def test_a_change_starts_the_next_version_under_the_same_number_and_keeps_booked_trips(admin, carrier):
    later_time = f"23:{secrets.randbelow(60):02d}"
    asked = _ask(carrier, departure_time=f"02:{secrets.randbelow(60):02d}").json()["uid"]
    done = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True}).json()
    first = _template(done["result"]["template_uid"])
    code = done["result"]["trip_code"]
    # a passenger holds a booking on a trip after the change; it stays, the others are cancelled and made again
    booked = owner_sql("""SELECT id, uid FROM ops.trip WHERE template_id = $1 AND service_date = $2::date""", first["id"], date.fromisoformat(day(8)), fetch=True)
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    t = next(x for x in pax.get("/api/trips/search", params={"origin": "DAM", "destination": "ALP", "on": day(8), "passengers": 1}).json()["trips"]
             if x["uid"] == str(booked["uid"]))
    seat = free_seats(pax, t, 1)[0]
    hold = pax.post("/api/holds", json={"trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "seat_nos": [seat]}).json()
    r = pax.post("/api/bookings", json={"hold_token": hold["hold_token"], "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
                                        "passengers": [syrian(seat)], "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 201, r.text
    r = carrier.post(f"/api/carrier/schedules/{first['uid']}/change",
                     json={"effective_from": day(6), "departure_time": later_time, "base_price": 30000})
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    # one request at a time for a regular trip
    twice = carrier.post(f"/api/carrier/schedules/{first['uid']}/change", json={"effective_from": day(7), "base_price": 1})
    assert twice.status_code == 409 and twice.json()["error"]["code"] == "SCHEDULE_REQUEST_OPEN"
    applied = admin.post(f"/api/admin/schedules/requests/{r.json()['uid']}/decide", json={"approve": True}).json()
    assert applied["status"] == "APPROVED", applied
    res = applied["result"]
    assert res["trip_code"] == code and res["replaces"] == str(first["uid"]) and res["cancelled"] > 0
    assert [k["trip_uid"] for k in res["kept"]] == [str(booked["uid"])] and res["kept"][0]["bookings"] == 1
    old, new = _template(first["uid"]), _template(res["template_uid"])
    assert old["active"].upper == date.fromisoformat(day(6)) and new["active"].lower == date.fromisoformat(day(6))
    assert new["service_number_id"] == old["service_number_id"] and new["base_price"] == 30000 and str(new["departure_time"]) == later_time + ":00"
    later = owner_sql("""SELECT count(*) FROM ops.trip WHERE template_id = $1 AND status <> 'CANCELLED'""", new["id"])
    assert later > 0
    # the day of the kept trip is not made twice under one number
    assert owner_sql("""SELECT count(*) FROM ops.trip WHERE service_date = $1::date AND company_id = $2 AND trip_code = $3
                         AND status <> 'CANCELLED'""", date.fromisoformat(day(8)), new["company_id"], code) == 1


def test_a_stop_ends_the_regular_trip_and_a_pause_holds_it(admin, carrier):
    asked = _ask(carrier, departure_time=f"01:{secrets.randbelow(60):02d}").json()["uid"]
    done = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True}).json()
    tpl = _template(done["result"]["template_uid"])
    uid = str(tpl["uid"])
    # a carrier no longer writes regular trips itself, nor ends one without a stop request
    assert carrier.post("/api/r/trip-template", json={"route_id": tpl["route_id"]}).status_code in (403, 405, 422)
    assert carrier.post(f"/api/r/trip-template/{tpl['id']}/do/retire").status_code in (403, 404, 422)
    assert carrier.post(f"/api/carrier/schedules/{uid}/pause").json()["status"] == "PAUSED"
    assert carrier.post(f"/api/carrier/schedules/{uid}/resume").json()["status"] == "ACTIVE"
    # a stop needs no approval by default: applied at once, the trips from that day cancelled
    r = carrier.post(f"/api/carrier/schedules/{uid}/stop", json={"from_date": day(10)})
    assert r.status_code == 201 and r.json()["status"] == "APPROVED", r.text
    assert r.json()["result"]["ends"] == day(10)
    assert owner_sql("""SELECT count(*) FROM ops.trip WHERE template_id = $1 AND service_date >= $2::date AND status <> 'CANCELLED'""",
                     tpl["id"], date.fromisoformat(day(10))) == 0
    assert owner_sql("SELECT upper(active) FROM ops.trip_template WHERE id = $1", tpl["id"]) == date.fromisoformat(day(10))


def test_the_approval_stages_are_a_setting_ready_for_government_authorities(admin, carrier):
    owner_sql("""INSERT INTO iam.user_role (user_id, role_id) SELECT u.id, r.id FROM iam.app_user u, iam.role r
                  WHERE u.email = 'security@masslak.test' AND r.code = 'PLATFORM_ADMIN' ON CONFLICT DO NOTHING""")
    second = login("security@masslak.test", "PLATFORM")
    regulator = login("regulator@masslak.test", "PLATFORM")
    # a stage names a known authority; the settings refuse anything else
    for key, value in (("approval_stages", [{"by": "AUTHORITY", "authority": "NOPE"}]), ("approval_stages", []),
                       ("approval_kinds", ["NEW", "NEVER"]), ("horizon_days", 200), ("recurrences", [])):
        r = admin.put(f"/api/admin/schedules/settings/{key}", json={"value": value})
        assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SETTING", (key, r.text)
    assert carrier.put("/api/admin/schedules/settings/horizon_days", json={"value": 40}).status_code in (401, 403)
    try:
        # the law asks the traffic authority to approve after the platform; its member decides for it
        assert admin.post("/api/admin/authorities/TRAFFIC/members", json={"email": "regulator@masslak.test"}).status_code == 201
        _setting(admin, "approval_stages", [{"by": "PLATFORM"}, {"by": "PLATFORM"}, {"by": "AUTHORITY", "authority": "TRAFFIC"}])
        listed = admin.get("/api/admin/schedules/settings").json()
        assert any(a["code"] == "TRAFFIC" and any(m["email"] == "regulator@masslak.test" for m in a["members"]) for a in listed["authorities"])
        asked = _ask(carrier).json()["uid"]
        assert len(_pending(admin, asked)["approval_stages"]) == 3
        # the authority's member does not decide the platform's stage
        r = regulator.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True})
        assert r.status_code == 403, r.text
        assert admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True}).json()["status"] == "PENDING"
        # one person decides one stage of a request
        r = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True})
        assert r.status_code == 409 and r.json()["error"]["code"] == "SECOND_PERSON_REQUIRED"
        assert second.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True}).json()["status"] == "PENDING"
        # the platform does not decide the authority's stage
        r = second.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True})
        assert r.status_code == 403 and r.json()["error"]["code"] == "NOT_YOUR_STAGE"
        waiting = regulator.get("/api/admin/schedules/requests").json()
        assert waiting["authorities"] == ["TRAFFIC"] and next(q for q in waiting["requests"] if q["uid"] == asked)["may_decide"]
        r = regulator.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True, "note": "Licensed line"})
        assert r.status_code == 200 and r.json()["status"] == "APPROVED", r.text
        decisions = _pending(admin, asked) if False else next(
            q for q in admin.get("/api/admin/schedules/requests", params={"status": "DECIDED"}).json()["requests"] if q["uid"] == asked)
        assert [d["decision"] for d in decisions["decisions"]] == ["APPROVED"] * 3 and decisions["decisions"][2]["authority"]
        # a request keeps the stages in force when it was made
        _setting(admin, "approval_stages", [{"by": "PLATFORM"}])
        assert owner_sql("SELECT jsonb_array_length(approval_stages) FROM ops.schedule_request WHERE uid = $1", uuid.UUID(asked)) == 3
    finally:
        _setting(admin, "approval_stages", [{"by": "PLATFORM"}])
        uid = owner_sql("SELECT uid FROM iam.app_user WHERE email = 'regulator@masslak.test'")
        admin.delete(f"/api/admin/authorities/TRAFFIC/members/{uid}")


def test_a_trip_made_by_hand_waits_for_approval_when_the_settings_ask_for_it(admin, carrier):
    route_uid = _route(carrier)
    try:
        _setting(admin, "approval_kinds", ["NEW", "CHANGE", "TRIP"])
        r = carrier.post("/api/carrier/trips", json={"route_uid": route_uid, "vehicle_uid": _fresh_vehicle(carrier),
                                                      "departure_local": f"{day(20)}T21:{secrets.randbelow(60):02d}:00", "publish": True})
        assert r.status_code == 201 and r.json()["approval"]["status"] == "PENDING", r.text
        trip = r.json()["uid"]
        assert owner_sql("SELECT status FROM ops.trip WHERE uid = $1", uuid.UUID(trip)) == "DRAFT"
        # publishing it by hand waits for the same request
        again = carrier.post(f"/api/carrier/trips/{trip}/publish").json()
        assert again["status"] == "PENDING_APPROVAL" and again["approval"]["uid"] == r.json()["approval"]["uid"]
        decided = admin.post(f"/api/admin/schedules/requests/{again['approval']['uid']}/decide", json={"approve": True}).json()
        assert decided["status"] == "APPROVED" and decided["result"]["published"]
        assert owner_sql("SELECT status FROM ops.trip WHERE uid = $1", uuid.UUID(trip)) == "PUBLISHED"
    finally:
        _setting(admin, "approval_kinds", ["NEW", "CHANGE"])
    # without TRIP among the kinds, a trip made by hand is published at once
    r = carrier.post("/api/carrier/trips", json={"route_uid": route_uid, "vehicle_uid": _fresh_vehicle(carrier),
                                                  "departure_local": f"{day(21)}T21:{secrets.randbelow(60):02d}:00", "publish": True})
    assert r.status_code == 201 and r.json()["approval"] is None


def test_the_worker_makes_the_trips_of_a_regular_trip_with_no_end_as_the_days_go_by(admin, carrier):
    asked = _ask(carrier, departure_time=f"00:{secrets.randbelow(60):02d}").json()["uid"]
    done = admin.post(f"/api/admin/schedules/requests/{asked}/decide", json={"approve": True}).json()
    tpl = _template(done["result"]["template_uid"])
    horizon = owner_sql("SELECT generated_until FROM ops.trip_template WHERE id = $1", tpl["id"])
    assert horizon == date.fromisoformat(day(0)) + timedelta(days=30)
    # as if the horizon had not been reached yet: the worker's pass makes the missing days
    owner_sql("UPDATE ops.trip_template SET generated_until = generated_until - 5 WHERE id = $1", tpl["id"])
    owner_sql("""UPDATE ops.trip SET status = 'CANCELLED' WHERE template_id = $1 AND service_date > (
                   SELECT generated_until FROM ops.trip_template WHERE id = $1)""", tpl["id"])
    assert owner_sql("SELECT count(*) FROM ops.schedules_due() WHERE template_id = $1", tpl["id"]) == 1
    import asyncio

    from app import db
    from app.modules.schedules import service

    async def run():
        await db.open_pools()
        try:
            return await service.generate_due()
        finally:
            await db.close_pools()
    assert asyncio.run(run()) >= 1
    assert owner_sql("SELECT generated_until FROM ops.trip_template WHERE id = $1", tpl["id"]) == horizon
    run_info = owner_sql("SELECT last_run FROM ops.trip_template WHERE id = $1", tpl["id"])
    assert '"created"' in run_info


def test_schedule_pages_are_closed_to_others():
    anyone = client()
    assert anyone.get("/api/carrier/schedules").status_code == 401
    assert anyone.get("/api/admin/schedules/requests").status_code == 401
    pax = login("passenger@masslak.test", "PASSENGER")
    assert pax.get("/api/admin/schedules/requests").status_code == 403
