"""Passenger categories and families (study 4.19 and 4.20): carriers set age bands, category fares and family offers;
the head of a family books and pays for its members, approves the account a member opens on another device, and
limits each member to times, routes and amounts."""
import datetime as dt
import time
import uuid

import pytest

from test_e2e import free_seats, hold, login, new_passenger, owner_sql, pax, trip  # noqa: F401  (fixtures)
from test_modules import CACHE_SECONDS, switch

FEE = 100000


def years_ago(n: int, days: int = 30) -> str:
    return (dt.date.today() - dt.timedelta(days=round(365.25 * n) + days)).isoformat()


def person(seat, first="Rami", **kw):
    return {"nationality": "SY", "first_name": first, "father_name": "Khaled", "grandfather_name": "Omar", "last_name": "Haddad",
            "seat_no": seat, **kw}


def funded(c, amount=30_000_000):
    for _ in range(amount // 10_000_000):
        assert c.post("/api/wallet/topup", json={"amount": 10_000_000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    return c


def body(t, passengers, token=None, **kw):
    return {"hold_token": token, "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"],
            "idempotency_key": uuid.uuid4().hex, "passengers": passengers, **kw}


def categories(c, t) -> dict:
    r = c.get(f"/api/trips/{t['uid']}", params={"from_seq": t["from_seq"], "to_seq": t["to_seq"]})
    assert r.status_code == 200, r.text
    return {x["category"]: x for x in r.json()["categories"]}


@pytest.fixture(scope="module")
def owner():
    return login("owner@carrier.test", "OPERATOR")


def test_trip_shows_who_counts_as_a_child_and_what_each_pays(pax, trip):
    cats = categories(pax, trip)
    assert set(cats) == {"ADULT", "CHILD", "INFANT"}
    assert cats["ADULT"]["fare"] == trip["price"]
    assert cats["CHILD"]["fare"] < trip["price"] and cats["INFANT"]["fare"] <= cats["CHILD"]["fare"]
    assert cats["INFANT"]["seat_required"] is False and cats["INFANT"]["needs_adult"] is True


def test_quote_prices_each_traveller_and_enforces_the_rules(pax, trip):
    cats = categories(pax, trip)
    p = new_passenger()
    trio = [person(1), person(2, "Lina", birth_date=years_ago(cats["CHILD"]["min_age"] + 1)),
            person(None, "Sami", birth_date=years_ago(0, 120))]
    r = p.post("/api/bookings/quote", json=body(trip, trio))
    assert r.status_code == 200, r.text
    q = r.json()
    assert [x["category"] for x in q["lines"]] == ["ADULT", "CHILD", "INFANT"] and q["lines"][2]["seat"] is False
    assert [x["fare"] for x in q["lines"]] == [cats["ADULT"]["fare"], cats["CHILD"]["fare"], cats["INFANT"]["fare"]]
    assert q["total"] == sum(x["fare"] for x in q["lines"]) + FEE

    def err(passengers):
        r = p.post("/api/bookings/quote", json=body(trip, passengers))
        assert r.status_code == 422, r.text
        return r.json()["error"]["code"]
    assert err([person(1), person(2, "Lina", category="CHILD")]) == "BIRTH_DATE_REQUIRED"
    assert err([person(2, "Lina", birth_date=years_ago(6))]) == "ADULT_REQUIRED"
    assert err([person(1), person(None, "A", birth_date=years_ago(0, 60)), person(None, "B", birth_date=years_ago(1))]) == "TOO_MANY_LAP_INFANTS"
    assert err([person(1), person(2, "Lina", birth_date=years_ago(5), category="ADULT")]) == "CATEGORY_MISMATCH"
    assert err([person(1), person(None, "Lina", birth_date=years_ago(6))]) == "SEAT_REQUIRED"
    assert err([person(1), person(None, "Sami")]) == "BIRTH_DATE_REQUIRED"           # a lap traveller is an infant only by date of birth


def test_booking_with_a_child_and_an_infant_on_the_lap(pax, trip):
    p = funded(new_passenger())
    seats = free_seats(p, trip, 2)
    h = hold(p, trip, seats).json()["hold_token"]
    people = [person(seats[0]), person(seats[1], "Lina", birth_date=years_ago(7)), person(None, "Sami", birth_date=years_ago(1))]
    q = p.post("/api/bookings/quote", json=body(trip, people)).json()
    r = p.post("/api/bookings", json=body(trip, people, h))
    assert r.status_code == 201, r.text
    assert r.json()["total"] == q["total"]
    tickets = p.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"]
    assert len(tickets) == 3 and sum(t["seat_no"] is None for t in tickets) == 1
    lap = owner_sql("""SELECT count(*) FROM sales.passenger p JOIN sales.booking b ON b.id = p.booking_id
                        WHERE b.booking_ref = $1 AND p.passenger_category = 'INFANT' AND p.accompanied_by_passenger_id IS NOT NULL""",
                    r.json()["booking_ref"])
    assert lap == 1


def test_a_carrier_sets_its_own_age_bands_and_child_fares(owner, pax, trip):
    route = owner_sql("SELECT route_id FROM ops.trip WHERE uid = $1", uuid.UUID(trip["uid"]))
    made = []
    try:
        for cat, lo, hi, seat, adult in (("INFANT", 0, 3, False, True), ("CHILD", 3, 14, True, True), ("ADULT", 14, None, True, False)):
            r = owner.post("/api/r/age-band", json={"category": cat, "min_age": lo, "max_age": hi, "seat_required": seat,
                                                     "needs_adult": adult, "max_per_adult": 1 if cat == "INFANT" else None})
            assert r.status_code == 201, r.text
            made.append(("age-band", r.json()["_key"]))
            assert owner.post(f"/api/r/age-band/{r.json()['_key']}/do/activate").status_code == 200
        r = owner.post("/api/r/category-fare", json={"category": "CHILD", "route_id": route, "method": "FIXED", "value": 1_000_000,
                                                      "currency": "SYP"})
        assert r.status_code == 201, r.text
        made.append(("category-fare", r.json()["_key"]))
        assert owner.post(f"/api/r/category-fare/{r.json()['_key']}/do/activate").status_code == 200
        cats = categories(pax, trip)
        assert cats["CHILD"]["max_age"] == 14 and cats["CHILD"]["fare"] == 1_000_000
        q = new_passenger().post("/api/bookings/quote", json=body(trip, [person(1), person(2, "Lina", birth_date=years_ago(13))])).json()
        assert q["lines"][1]["category"] == "CHILD" and q["lines"][1]["fare"] == 1_000_000     # 13 is a child on this carrier
    finally:
        for res, key in made:
            owner.post(f"/api/r/{res}/{key}/do/retire")
    assert categories(pax, trip)["CHILD"]["max_age"] == 12                                       # back to the platform default


def make_family(head, *members):
    r = head.post("/api/family", json={"name": "Haddad family"})
    assert r.status_code == 201, r.text
    out = {"SELF": next(m for m in r.json()["members"] if m["relation"] == "SELF")}
    for relation, first, born, extra in members:
        r = head.post("/api/family/members", json={"relation": relation, "first_name": first, "father_name": "Khaled",
                                                   "grandfather_name": "Omar", "last_name": "Haddad", "birth_date": born, **extra})
        assert r.status_code == 201, r.text
        out[first] = r.json()
    return out


def test_family_register_offer_and_booking_for_the_whole_family(owner, trip):
    code = "FAM" + uuid.uuid4().hex[:6].upper()
    # 15% so it is the best offer on the trip whatever else the carrier runs (the demo data has a 10% one)
    r = owner.post("/api/r/family-offer", json={"code": code, "name": "Family 15%", "applies_to": "BOTH", "min_members": 3,
                                                 "min_adults": 1, "min_minors": 1, "discount_type": "PCT", "discount_value": 15})
    assert r.status_code == 201, r.text
    offer = r.json()["_key"]
    assert owner.post(f"/api/r/family-offer/{offer}/do/activate").status_code == 200
    try:
        head = funded(new_passenger())
        fam = make_family(head, ("SPOUSE", "Lina", years_ago(35), {"id_type": "NATIONAL_ID", "id_no": "010203040506"}),
                          ("SON", "Sami", years_ago(7), {}))
        listed = head.get("/api/family").json()
        assert listed["role"] == "HEAD" and len(listed["members"]) == 3
        assert next(m for m in listed["members"] if m["first_name"] == "Lina")["id_last4"] == "0506"   # stored encrypted, shown masked
        seats = free_seats(head, trip, 3)
        h = hold(head, trip, seats).json()["hold_token"]
        people = [person(seats[0], family_member_uid=fam["SELF"]["uid"]), person(seats[1], family_member_uid=fam["Lina"]["uid"]),
                  person(seats[2], family_member_uid=fam["Sami"]["uid"])]
        r = head.post("/api/bookings", json=body(trip, people, h))
        assert r.status_code == 201, r.text
        b = head.get(f"/api/bookings/{r.json()['booking_ref']}").json()["booking"]["price_breakdown"]
        assert b["family_offer"]["code"] == code and b["family_offer"]["discount"] == round(b["fares_gross"] * 0.15 / 100) * 100
        assert sum(x["list_fare"] for x in b["lines"]) - sum(x["fare"] for x in b["lines"]) == b["family_offer"]["discount"]
        assert [x["category"] for x in b["lines"]] == ["ADULT", "ADULT", "CHILD"]
        # the spouse's stored document travelled onto the booking, still encrypted
        assert owner_sql("""SELECT p.id_no_last4 FROM sales.passenger p JOIN sales.booking k ON k.id = p.booking_id
                             WHERE k.booking_ref = $1 AND p.first_name = 'Lina'""", r.json()["booking_ref"]) == "0506"
        # someone else's member cannot be booked
        other = new_passenger()
        r = other.post("/api/bookings/quote", json=body(trip, [person(1, family_member_uid=fam["Lina"]["uid"])]))
        assert r.status_code == 404 and r.json()["error"]["code"] == "NOT_IN_FAMILY"
    finally:
        owner.post(f"/api/r/family-offer/{offer}/do/retire")


def link_member(head, member_uid):
    """The member opens their own account on another device and enters the head's code; the head approves."""
    code = head.post(f"/api/family/members/{member_uid}/invite").json()["code"]
    member = funded(new_passenger(), 10_000_000)
    assert member.post("/api/family/join", json={"code": "WRONG123", "device_label": "Phone"}).json()["error"]["code"] == "INVITE_INVALID"
    r = member.post("/api/family/join", json={"code": code, "device_label": "Lina's phone", "device_id": "device-" + uuid.uuid4().hex})
    assert r.status_code == 200 and r.json()["status"] == "PENDING", r.text
    assert member.get("/api/family").json()["role"] is None              # nothing linked before the head approves
    req = next(x for x in head.get("/api/family").json()["requests"] if x["member_uid"] == member_uid)
    assert req["status"] == "PENDING" and req["device_label"] == "Lina's phone"
    r = head.post(f"/api/family/requests/{req['uid']}/approve", json={"funding": "HEAD_WALLET"})
    assert r.status_code == 200, r.text
    return member


def test_a_member_on_another_device_books_within_the_heads_rules(trip):
    head = funded(new_passenger())
    fam = make_family(head, ("SISTER", "Lina", years_ago(20), {}), ("BROTHER", "Omar", years_ago(17), {}))
    member = link_member(head, fam["Lina"]["uid"])
    mine = member.get("/api/family").json()
    assert mine["role"] == "MEMBER" and mine["me"]["first_name"] == "Lina" and "members" not in mine   # no sight of the others
    me = mine["me"]["uid"]

    departs = dt.datetime.fromisoformat(owner_sql("""SELECT to_char(sched_dep AT TIME ZONE 'Asia/Damascus', 'YYYY-MM-DD"T"HH24:MI')
                                                    FROM ops.trip_stop ts JOIN ops.trip t ON t.id = ts.trip_id
                                                   WHERE t.uid = $1 AND ts.seq = $2""", uuid.UUID(trip["uid"]), trip["from_seq"]))
    window = ("13:00", "14:00") if departs.hour < 12 else ("06:00", "07:00")
    rule = head.post(f"/api/family/members/{me}/rules", json={"rule_type": "TIME_WINDOW", "days": [1, 2, 3, 4, 5, 6, 7],
                                                               "start_time": window[0], "end_time": window[1]})
    assert rule.status_code == 201, rule.text

    def book():
        seat = free_seats(member, trip, 1)
        h = hold(member, trip, seat).json()["hold_token"]
        return member.post("/api/bookings", json=body(trip, [person(seat[0], "Lina", family_member_uid=me)], h))
    r = book()
    assert r.status_code == 403 and r.json()["error"]["code"] == "FAMILY_TIME_NOT_ALLOWED"
    assert head.delete(f"/api/family/rules/{rule.json()['uid']}").status_code == 200
    assert head.post(f"/api/family/members/{me}/rules", json={"rule_type": "ROUTE", "from_city": "ALP", "to_city": "LTK"}).status_code == 201
    r = book()
    assert r.status_code == 403 and r.json()["error"]["code"] == "FAMILY_ROUTE_NOT_ALLOWED"
    seen = member.get("/api/family").json()["rules"]                 # the member sees their own rules, as the apps show them
    assert [(x["rule_type"], x["from_city"], x["to_city"]) for x in seen] == [("ROUTE", "ALP", "LTK")]
    for x in head.get(f"/api/family/members/{me}/rules").json()["rules"]:
        head.delete(f"/api/family/rules/{x['uid']}")
    assert head.patch(f"/api/family/members/{me}", json={"per_trip_limit": 100_000}).status_code == 200
    r = book()
    assert r.status_code == 403 and r.json()["error"]["code"] == "FAMILY_LIMIT_PER_TRIP"
    assert head.patch(f"/api/family/members/{me}", json={"per_trip_limit": 0}).status_code == 200

    head_before, member_before = head.get("/api/wallet").json()["balance"], member.get("/api/wallet").json()["balance"]
    r = book()
    assert r.status_code == 201, r.text
    total, ref = r.json()["total"], r.json()["booking_ref"]
    assert head.get("/api/wallet").json()["balance"] == head_before - total          # paid by the head, as approved
    assert member.get("/api/wallet").json()["balance"] == member_before
    spend = head.get("/api/family/spend").json()["spend"]
    assert spend[0]["amount"] == total and spend[0]["member_uid"] == me
    # a member cannot loosen their own rules or book for the rest of the family
    assert member.patch(f"/api/family/members/{me}", json={"funding": "OWN"}).json()["error"]["code"] == "NO_FAMILY"
    r = member.post("/api/bookings/quote", json=body(trip, [person(1, "Omar", family_member_uid=fam["Omar"]["uid"])]))
    assert r.status_code == 403 and r.json()["error"]["code"] == "FAMILY_HEAD_ONLY"
    # the head sees what the family paid for; cancelling refunds whoever paid
    assert head.get(f"/api/bookings/{ref}").status_code == 200
    assert ref in [b["booking_ref"] for b in head.get("/api/bookings").json()["bookings"]]
    r = member.post(f"/api/bookings/{ref}/cancel")
    assert r.status_code == 200, r.text
    assert head.get("/api/wallet").json()["balance"] == head_before - total + r.json()["refund"]


def test_family_trips_account_and_privacy(trip):
    head = funded(new_passenger())
    fam = make_family(head, ("DAUGHTER", "Maya", years_ago(9), {}))
    r = head.post("/api/family/account/topup", json={"amount": 8_000_000, "idempotency_key": uuid.uuid4().hex})
    assert r.status_code == 200 and r.json()["family_account_balance"] == 8_000_000, r.text
    seats = free_seats(head, trip, 2)
    h = hold(head, trip, seats).json()["hold_token"]
    people = [person(seats[0], family_member_uid=fam["SELF"]["uid"]), person(seats[1], "Maya", family_member_uid=fam["Maya"]["uid"])]
    r = head.post("/api/bookings", json=body(trip, people, h, pay_from="FAMILY_ACCOUNT"))
    assert r.status_code == 201, r.text
    assert head.get("/api/family").json()["account"]["balance"] == 8_000_000 - r.json()["total"]
    stranger = new_passenger()
    assert stranger.get("/api/family").json()["role"] is None
    assert stranger.patch(f"/api/family/members/{fam['Maya']['uid']}", json={"mobile": "+963900000000"}).json()["error"]["code"] == "NO_FAMILY"
    r = stranger.post("/api/bookings/quote", json=body(trip, [person(1)], pay_from="FAMILY_ACCOUNT"))
    assert r.status_code == 200          # a quote does not pay; paying from a family account needs a family


def test_family_passes_bought_together_with_the_family_offer(owner):
    admin = login("admin@masslak.test", "PLATFORM")
    was_on = next(m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"] if m["key"] == "shuttle_subscriptions")
    if not was_on:
        switch(admin, "shuttle_subscriptions", True)
        time.sleep(CACHE_SECONDS)
    company = owner_sql("SELECT company_id FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = 'owner@carrier.test'")
    code = "FP" + uuid.uuid4().hex[:6].upper()
    plan = owner_sql("""INSERT INTO sales.subscription_plan (company_id, code, name, period_days, rides_limit, passenger_category, price, status)
                        VALUES ($1, $2, 'Monthly family pass', 30, 60, 'ADULT', 1500000, 'ACTIVE') RETURNING id""", company, code)
    r = owner.post("/api/r/family-offer", json={"code": code, "name": "Family passes", "applies_to": "PASSES", "min_members": 2,
                                                 "min_adults": 2, "min_minors": 0, "discount_type": "FIXED_PER_MEMBER", "discount_value": 200000})
    offer = r.json()["_key"]
    owner.post(f"/api/r/family-offer/{offer}/do/activate")
    try:
        head = funded(new_passenger())
        fam = make_family(head, ("SPOUSE", "Lina", years_ago(33), {}), ("SON", "Sami", years_ago(8), {}))
        r = head.post("/api/family/passes", json={"plan_id": plan, "member_uids": [fam["SELF"]["uid"], fam["Sami"]["uid"]],
                                                  "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 422 and r.json()["error"]["code"] == "PLAN_CATEGORY"      # an adult plan is not sold for a child
        before = head.get("/api/wallet").json()["balance"]
        r = head.post("/api/family/passes", json={"plan_id": plan, "member_uids": [fam["SELF"]["uid"], fam["Lina"]["uid"]],
                                                  "idempotency_key": uuid.uuid4().hex})
        assert r.status_code == 201, r.text
        out = r.json()
        assert out["gross"] == 3_000_000 and out["discount"] == 400_000 and out["total"] == 2_600_000 and len(out["passes"]) == 2
        assert head.get("/api/wallet").json()["balance"] == before - 2_600_000
        assert owner_sql("SELECT count(*) FROM sales.subscription WHERE family_offer_id IS NOT NULL AND plan_id = $1", plan) == 2
    finally:
        owner.post(f"/api/r/family-offer/{offer}/do/retire")
        owner_sql("UPDATE sales.subscription_plan SET status = 'RETIRED' WHERE id = $1", plan)
        if not was_on:
            switch(admin, "shuttle_subscriptions", False)
