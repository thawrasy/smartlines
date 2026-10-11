"""The boarding photo (migration 1086): taken when the profile is created, kept while the account exists, read at
boarding only by the assigned driver and the carrier's office, every read audited, removed by an erasure request."""
import uuid
from datetime import date, timedelta

import pytest

from test_e2e import FRESH_DRIVER_PASSWORD, FRESH_DRIVERS, OWNER_URL, PASSWORD, client, free_seats, hold, login, new_passenger, owner_sql, pax, trip  # noqa: F401
from test_families import body, funded, make_family, person, years_ago

# well-formed enough for the scanner's built-in checks: the start marker and the end marker, nothing after it
JPEG = b"\xff\xd8\xff\xe0" + b"masslak boarding photo test image " * 4 + b"\xff\xd9"
PNG = b"\x89PNG\r\n\x1a\n" + b"masslak boarding photo test image " * 4 + b"IEND\xaeB`\x82"


def upload(c, data: bytes, name: str = "me.jpg", mime: str = "image/jpeg"):
    return c.post("/api/account/photo", files={"file": (name, data, mime)})


SWITCH_ADMIN = ("admin@masslak.test", "PLATFORM")
SWITCH_CHECKER = ("security@masslak.test", "PLATFORM")
SWITCH_FINAL = ("privacy2@masslak.test", "PLATFORM")


def switch_on(enforce: bool = True):
    """The boarding photo is switched on through an approved change (1094), once per database; with enforce, its rules are
    enforced from yesterday (1096: nothing is enforced before the date the platform sets). A no-op after that."""
    admin = login(*SWITCH_ADMIN)
    if not admin.get("/api/admin/photos/evidence-kinds").json()["enabled"]:
        r = admin.post("/api/admin/photos/feature/changes", json={
            "enabled": True, "legal_basis": "test: the switch is set by a decision with a legal basis (1094)",
            "reason": "the photo tests need the feature on (1094)"})
        assert r.status_code == 201, r.text
        uid = r.json()["uid"]
        assert login(*SWITCH_CHECKER).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "PENDING"
        assert login(*SWITCH_FINAL).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "APPLIED"
    enforced = admin.get("/api/admin/photos/evidence-kinds").json()["enforce_from"]
    if enforce and enforced is None:
        change_setting("photo.enforce_from", (date.today() - timedelta(days=1)).isoformat(), "the photo rules are enforced (1096)")
    if not enforce and enforced is not None:
        change_setting("photo.enforce_from", None, "no enforcement date before a test that checks the launch values (1096)")


def change_setting(key: str, value, reason: str = "test of the photo settings (1096)"):
    """A photo setting changed through its approval stages (1096): asked by the admin, checked, then applied."""
    admin = login(*SWITCH_ADMIN)
    r = admin.post("/api/admin/photos/settings/changes", json={"key": key, "value": value, "reason": reason})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert login(*SWITCH_CHECKER).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "PENDING"
    assert login(*SWITCH_FINAL).post(f"/api/admin/photos/policy-changes/{uid}/approve").json()["status"] == "APPLIED"


def view_access():
    return login(*SWITCH_ADMIN).get("/api/admin/photos/evidence-kinds").json()["view_access"]


@pytest.fixture(autouse=True)
def photo_switched_on():
    switch_on()


def register():
    email = f"photo{uuid.uuid4().hex[:8]}@example.com"
    password = "another-long-password"
    assert client().post("/api/auth/register", json={"full_name": "Photo Test", "email": email, "password": password}).status_code == 201
    return email, login(email, "PASSENGER", password)


def photo_of_email(email):
    return owner_sql("""SELECT pp.file_id AS photo_file_id, pp.taken_by AS photo_taken_by FROM iam.party_photo pp
                          JOIN iam.app_user u ON u.party_id = pp.party_id WHERE u.email = $1""", email, fetch=True)


def assigned_driver(trip_uid: str):
    for email, password in [(e, PASSWORD) for e in ("driver@carrier.test", "driver2@carrier.test", "driver3@carrier.test")] \
            + [(e, FRESH_DRIVER_PASSWORD) for e in FRESH_DRIVERS]:
        d = login(email, "DRIVER", password)
        if any(t["uid"] == trip_uid for t in d.get("/api/driver/trips").json()["trips"]):
            return d
    raise AssertionError("no driver is assigned to the trip")


def test_passenger_takes_the_photo_and_a_second_one_is_refused():
    email, c = register()
    assert c.get("/api/account/photo").json()["has_photo"] is False
    r = upload(c, JPEG)
    assert r.status_code == 201 and r.json() == {"taken_by": "SELF"}, r.text
    status = c.get("/api/account/photo").json()
    assert status["has_photo"] is True and status["taken_by"] == "SELF" and status["taken_at"]
    first = photo_of_email(email)
    assert first["photo_taken_by"] == "SELF"
    assert owner_sql("SELECT data_class || ' ' || mime_type FROM ref.file_object WHERE id = $1", first["photo_file_id"]) \
        == "RESTRICTED image/jpeg"
    # a photo on file is never replaced by the person: the change goes through the platform (sixth round)
    r = upload(c, PNG, "me.png", "image/png")
    assert r.status_code == 409 and r.json()["error"]["code"] == "PHOTO_EXISTS", r.text
    assert photo_of_email(email)["photo_file_id"] == first["photo_file_id"]
    assert owner_sql("SELECT count(*) FROM ref.file_object WHERE id = $1", first["photo_file_id"]) == 1


def test_only_jpeg_and_png_photos_are_accepted():
    _, c = register()
    r = upload(c, b"%PDF-1.4 not a photo", "scan.pdf", "application/pdf")
    assert r.status_code == 422 and r.json()["error"]["code"] == "PHOTO_TYPE", r.text
    r = upload(c, b"", "empty.jpg")
    assert r.status_code == 422 and r.json()["error"]["code"] == "FILE_EMPTY", r.text


def test_head_takes_a_members_photo_and_nobody_else_can():
    head = new_passenger()
    fam = make_family(head, ("SON", "Sami", years_ago(7), {}))
    r = head.post(f"/api/family/members/{fam['Sami']['uid']}/photo", files={"file": ("sami.jpg", JPEG, "image/jpeg")})
    assert r.status_code == 201 and r.json() == {"taken_by": "HEAD_OF_FAMILY"}, r.text
    other = new_passenger()
    r = other.post(f"/api/family/members/{fam['Sami']['uid']}/photo", files={"file": ("sami.jpg", JPEG, "image/jpeg")})
    assert r.status_code == 404, r.text


def test_boarding_shows_the_photo_to_the_assigned_driver_and_the_office_only(trip):
    head = funded(new_passenger())
    fam = make_family(head, ("SON", "Sami", years_ago(7), {}),
                      ("SPOUSE", "Lina", years_ago(35), {"id_type": "NATIONAL_ID", "id_no": "010203040506"}))
    assert head.post("/api/account/photo", files={"file": ("me.jpg", JPEG, "image/jpeg")}).status_code == 201
    assert head.post(f"/api/family/members/{fam['Sami']['uid']}/photo",
                     files={"file": ("sami.jpg", JPEG, "image/jpeg")}).status_code == 201
    # Lina has no photo: the driver is told so, and the boarding goes on as before (the ID is checked by hand)
    seats = free_seats(head, trip, 3)
    token = hold(head, trip, seats).json()["hold_token"]
    people = [person(seats[0], family_member_uid=fam["SELF"]["uid"]),
              person(seats[1], family_member_uid=fam["Sami"]["uid"]),
              person(seats[2], family_member_uid=fam["Lina"]["uid"])]
    r = head.post("/api/bookings", json=body(trip, people, token))
    assert r.status_code == 201, r.text
    ref = r.json()["booking_ref"]

    def ticket_of(member_uid):
        return str(owner_sql("""SELECT k.uid FROM sales.ticket k JOIN sales.passenger p ON p.id = k.passenger_id
                                  JOIN sales.booking b ON b.id = k.booking_id JOIN iam.family_member m ON m.id = p.family_member_id
                                 WHERE b.booking_ref = $1 AND m.uid = $2""", ref, uuid.UUID(member_uid)))

    sami, lina = ticket_of(fam["Sami"]["uid"]), ticket_of(fam["Lina"]["uid"])
    driver = assigned_driver(trip["uid"])
    office = login("owner@carrier.test", "OPERATOR")
    # the photo is shown only while the trip is boarding (1096): before that, the driver is told so
    original = owner_sql("SELECT status FROM ops.trip WHERE uid = $1", uuid.UUID(trip["uid"]))
    r = driver.get(f"/api/driver/trips/{trip['uid']}/tickets/{sami}/photo")
    assert r.status_code == 409 and r.json()["error"]["code"] == "NOT_BOARDING", r.text
    owner_sql("UPDATE ops.trip SET status = 'BOARDING' WHERE uid = $1", uuid.UUID(trip["uid"]))
    try:
        r = driver.get(f"/api/driver/trips/{trip['uid']}/tickets/{sami}/photo")
        assert r.status_code == 200 and r.content == JPEG and r.headers["content-type"].startswith("image/jpeg"), r.text
        r = driver.get(f"/api/driver/trips/{trip['uid']}/tickets/{lina}/photo")
        assert r.status_code == 404 and r.json()["error"]["code"] == "PHOTO_NONE", r.text
        assert head.get(f"/api/driver/trips/{trip['uid']}/tickets/{sami}/photo").status_code == 403   # a passenger is no driver
        # the office sees it only when the platform lets the office see it (1096): not by default
        r = office.get(f"/api/carrier/trips/{trip['uid']}/tickets/{sami}/photo")
        assert r.status_code == 403 and r.json()["error"]["code"] == "PHOTO_VIEW_NOT_ALLOWED", r.text
        access = dict(view_access(), CARRIER_OFFICE_AT_BOARDING=True)
        change_setting("photo.view_access", access)
        try:
            r = office.get(f"/api/carrier/trips/{trip['uid']}/tickets/{sami}/photo")
            assert r.status_code == 200 and r.content == JPEG, r.text
        finally:
            change_setting("photo.view_access", dict(access, CARRIER_OFFICE_AT_BOARDING=False))
        assert head.get(f"/api/carrier/trips/{trip['uid']}/tickets/{sami}/photo").status_code == 403
    finally:
        owner_sql("UPDATE ops.trip SET status = $2 WHERE uid = $1", uuid.UUID(trip["uid"]), original)
    # every read is in the activity log, with the viewer and the person (never the picture)
    party = owner_sql("SELECT m.party_id FROM iam.family_member m WHERE m.uid = $1", uuid.UUID(fam["Sami"]["uid"]))
    reads = owner_sql("SELECT count(*) FROM audit.activity_log WHERE action = 'photo.view' AND object_id::text = $1", str(party))
    assert reads >= 2, reads


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to complete the erasure request")
def test_erasure_removes_the_photo():
    email, c = register()
    assert upload(c, JPEG).status_code == 201
    photo = photo_of_email(email)["photo_file_id"]
    assert c.post("/api/account/erasure", json={"reason": "leaving"}).status_code == 201
    admin = login("admin@masslak.test", "PLATFORM")
    req = next(r for r in admin.get("/api/admin/privacy/requests").json()["requests"] if r["email"] == email)
    assert admin.post(f"/api/admin/privacy/requests/{req['uid']}/complete").status_code == 200
    assert owner_sql("SELECT pp.file_id FROM gov.subject_request r JOIN iam.party_photo pp ON pp.party_id = r.party_id WHERE r.uid = $1",
                     uuid.UUID(req["uid"])) is None
    assert owner_sql("SELECT count(*) FROM ref.file_object WHERE id = $1", photo) == 0
