"""The boarding photo policy and its replacement (migration 1087; WP1 and WP4 of the sixth round, 11 October 2026).

Two platform people propose and approve a rule that requires a photo, and a third may retire it. A required photo refuses
a booking and the gate (PHOTO_REQUIRED) when none is on file, and a linked person with a photo boards as before. A photo on
file changes only through a request with evidence, made by one platform person and applied by another."""
import uuid
from datetime import date, timedelta

from test_boarding_photo import JPEG, PNG, assigned_driver, photo_of_email, register, upload
from test_e2e import free_seats, hold, login, new_passenger, owner_sql, pax, trip  # noqa: F401
from test_families import body, funded, make_family, person, years_ago

ADMIN = ("admin@masslak.test", "PLATFORM")
SECOND = ("security@masslak.test", "PLATFORM")


def staff(who):
    return login(who[0], who[1])


def propose(c, **kw):
    data = {"market": None, "trip_scope": None, "traveller_class": None, "passenger_category": None,
            "requirement": "REQUIRED", "effective_from": (date.today() - timedelta(days=2)).isoformat(),
            "legal_basis": "test rule of the sixth round (11 October 2026)"}
    data.update(kw)
    return c.post("/api/admin/photos/rules", json=data)


def active_child_rule(admin, sec):
    """A rule that requires a photo for children, approved by the second person; the caller retires it."""
    r = propose(admin, passenger_category="CHILD")
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert sec.post(f"/api/admin/photos/rules/{uid}/approve").status_code == 200
    return uid


def ticket_of(booking_ref, category):
    return str(owner_sql("""SELECT k.uid FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                              JOIN sales.booking b ON b.id = k.booking_id
                             WHERE b.booking_ref = $1 AND p.passenger_category = $2""", booking_ref, category))


def ticket_of_member(booking_ref, member_uid):
    return str(owner_sql("""SELECT k.uid FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                              JOIN sales.booking b ON b.id = k.booking_id JOIN iam.family_member m ON m.id = p.family_member_id
                             WHERE b.booking_ref = $1 AND m.uid = $2""", booking_ref, uuid.UUID(member_uid)))


def ticket_status(ticket_uid):
    return owner_sql("SELECT status FROM sales.ticket WHERE uid = $1", uuid.UUID(ticket_uid))


def scan(trip_uid, driver, token):
    return driver.post("/api/driver/scan", json={"trip_uid": trip_uid, "token": token}).json()["result"]


def test_a_rule_needs_two_platform_people_and_a_legal_basis():
    admin, sec = staff(ADMIN), staff(SECOND)
    assert new_passenger().get("/api/admin/photos/rules").status_code == 403
    assert propose(admin, legal_basis="x").status_code == 422
    assert propose(admin, market="ZZ").json()["error"]["code"] == "MARKET_UNKNOWN"
    uid = propose(admin, passenger_category="CHILD").json()["uid"]
    try:
        r = admin.post(f"/api/admin/photos/rules/{uid}/approve")
        assert r.status_code == 409 and r.json()["error"]["code"] == "FOUR_EYES", r.text
        assert sec.post(f"/api/admin/photos/rules/{uid}/approve").json()["status"] == "APPROVED"
        r = sec.post(f"/api/admin/photos/rules/{uid}/retire")
        assert r.status_code == 409 and r.json()["error"]["code"] == "FOUR_EYES", r.text
        assert admin.post(f"/api/admin/photos/rules/{uid}/retire").json()["status"] == "RETIRED"
        r = sec.post(f"/api/admin/photos/rules/{uid}/retire")
        assert r.status_code == 409 and r.json()["error"]["code"] == "NOT_RETIRABLE", r.text
        listed = next(x for x in admin.get("/api/admin/photos/rules").json()["rules"] if x["uid"] == uid)
        assert listed["status"] == "RETIRED" and listed["requirement"] == "REQUIRED"
    finally:
        admin.post(f"/api/admin/photos/rules/{uid}/retire")


def test_a_required_photo_refuses_an_unlinked_child_at_booking_and_at_the_gate(trip):
    admin, sec = staff(ADMIN), staff(SECOND)
    c = funded(new_passenger())
    # an adult travels with the child; the first child is booked before the rule, the rule then refuses the second,
    # and the gate refuses the first (no cancellation: the ticket stays issued)
    seats = free_seats(c, trip, 2)
    first = c.post("/api/bookings", json=body(trip, [person(seats[0]), person(seats[1], "Lina", birth_date=years_ago(7))],
                                              hold(c, trip, seats).json()["hold_token"]))
    assert first.status_code == 201, first.text
    token = c.get(f"/api/tickets/{ticket_of(first.json()['booking_ref'], 'CHILD')}/qr").json()["token"]
    ticket = ticket_of(first.json()["booking_ref"], "CHILD")
    uid = active_child_rule(admin, sec)
    try:
        seats = free_seats(c, trip, 2)
        people = [person(seats[0]), person(seats[1], "Sami", birth_date=years_ago(7))]
        r = c.post("/api/bookings", json=body(trip, people, hold(c, trip, seats).json()["hold_token"]))
        assert r.status_code == 422 and r.json()["error"]["code"] == "PHOTO_REQUIRED", r.text
        assert scan(trip["uid"], assigned_driver(trip["uid"]), token) == "PHOTO_REQUIRED"
        assert ticket_status(ticket) == "ISSUED"
    finally:
        admin.post(f"/api/admin/photos/rules/{uid}/retire")


def test_a_linked_member_boards_under_the_rule_once_a_photo_is_on_file(trip):
    admin, sec = staff(ADMIN), staff(SECOND)
    head = funded(new_passenger())
    fam = make_family(head, ("SON", "Sami", years_ago(7), {}))

    def people(seats):
        return [person(seats[0], family_member_uid=fam["SELF"]["uid"]), person(seats[1], family_member_uid=fam["Sami"]["uid"])]

    uid = active_child_rule(admin, sec)
    try:
        seats = free_seats(head, trip, 2)
        r = head.post("/api/bookings", json=body(trip, people(seats), hold(head, trip, seats).json()["hold_token"]))
        assert r.status_code == 422 and r.json()["error"]["code"] == "PHOTO_REQUIRED", r.text     # linked, but no photo yet
        assert head.post(f"/api/family/members/{fam['Sami']['uid']}/photo",
                         files={"file": ("sami.jpg", JPEG, "image/jpeg")}).status_code == 201
        seats = free_seats(head, trip, 2)
        r = head.post("/api/bookings", json=body(trip, people(seats), hold(head, trip, seats).json()["hold_token"]))
        assert r.status_code == 201, r.text
        ticket = ticket_of_member(r.json()["booking_ref"], fam["Sami"]["uid"])
        token = head.get(f"/api/tickets/{ticket}/qr").json()["token"]
        assert scan(trip["uid"], assigned_driver(trip["uid"]), token) == "OK"
    finally:
        admin.post(f"/api/admin/photos/rules/{uid}/retire")


def test_a_photo_on_file_changes_only_through_a_second_platform_person_with_evidence():
    admin, sec = staff(ADMIN), staff(SECOND)
    email, c = register()
    assert upload(c, JPEG).status_code == 201
    before = photo_of_email(email)["photo_file_id"]
    party = owner_sql("SELECT p.uid FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id WHERE u.email = $1", email)
    form = {"party_uid": str(party), "reason": "the photo on file is not the holder", "evidence_kind": "IDENTITY_DOCUMENT"}
    files = {"evidence": ("id.jpg", JPEG, "image/jpeg"), "new_photo": ("new.png", PNG, "image/png")}
    # the person cannot ask for a change; the platform asks, with the evidence and the new photo
    assert c.post("/api/admin/photos/changes", data=form, files=files).status_code == 403
    r = admin.post("/api/admin/photos/changes", data=form, files=files)
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    req = r.json()["uid"]
    assert admin.post(f"/api/admin/photos/changes/{req}/approve").json()["error"]["code"] == "FOUR_EYES"
    ev = admin.get(f"/api/admin/photos/changes/{req}/evidence")
    assert ev.status_code == 200 and ev.content == JPEG
    assert sec.post(f"/api/admin/photos/changes/{req}/approve").json()["status"] == "APPLIED"
    after = photo_of_email(email)
    assert after["photo_taken_by"] == "PLATFORM" and after["photo_file_id"] != before
    assert owner_sql("SELECT count(*) FROM ref.file_object WHERE id = $1", before) == 0      # the earlier photo is gone
    assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action = 'photo.change_apply' AND object_id = $1", party_id_of(email)) == 1

    # a second request is turned down: the photo on file stays, and the candidate photo goes
    r = sec.post("/api/admin/photos/changes", data=form, files=files)
    assert r.status_code == 201, r.text
    rej = r.json()["uid"]
    assert sec.post(f"/api/admin/photos/changes/{rej}/approve").json()["error"]["code"] == "FOUR_EYES"
    assert admin.post(f"/api/admin/photos/changes/{rej}/reject").json()["status"] == "REJECTED"
    assert photo_of_email(email)["photo_file_id"] == after["photo_file_id"]
    assert owner_sql("SELECT photo_file_id IS NULL FROM iam.photo_change_request WHERE uid = $1", uuid.UUID(rej)) is True


def party_id_of(email):
    return owner_sql("SELECT party_id FROM iam.app_user WHERE email = $1", email)
