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
PRIVACY = ("privacy@masslak.test", "PLATFORM")
PRIVACY2 = ("privacy2@masslak.test", "PLATFORM")


def staff(who):
    return login(who[0], who[1])


def propose(c, **kw):
    data = {"market": None, "trip_scope": None, "traveller_class": None, "passenger_category": None,
            "requirement": "REQUIRED", "effective_from": (date.today() - timedelta(days=2)).isoformat(),
            "legal_basis": "test rule of the sixth round (11 October 2026)"}
    data.update(kw)
    return c.post("/api/admin/photos/rules", json=data)


def rule_status(admin, uid: str) -> str:
    return next(x["status"] for x in admin.get("/api/admin/photos/rules").json()["rules"] if x["uid"] == uid)


def active_child_rule(admin, sec, privacy):
    """A rule that requires a photo for children, passed through its stages; the caller retires it."""
    r = propose(admin, passenger_category="CHILD")
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert approve_through("/api/admin/photos/rules", uid, sec, privacy)["status"] == "APPROVED"
    return uid


def retire_child_rule(admin, sec, privacy2, uid: str):
    """The retirement of a rule in force, asked by the admin and passed through its stages: the checker, then the
    final approval by a person who did not give the rule its final approval."""
    r = admin.post(f"/api/admin/photos/rules/{uid}/retirement", json={"reason": "test: the rule is retired after its test"})
    assert r.status_code == 201, r.text
    assert sec.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["status"] == "PENDING"
    assert privacy2.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["status"] == "RETIRED"


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


def test_a_rule_passes_its_stages_and_its_retirement_passes_the_same_stages():
    admin, sec, privacy, privacy2 = staff(ADMIN), staff(SECOND), staff(PRIVACY), staff(PRIVACY2)
    assert new_passenger().get("/api/admin/photos/rules").status_code == 403
    assert propose(admin, legal_basis="x").status_code == 422
    assert propose(admin, market="ZZ").json()["error"]["code"] == "MARKET_UNKNOWN"
    uid = propose(admin, passenger_category="CHILD").json()["uid"]
    try:
        # the one who proposes does not approve; the first stage is recorded; the rule is in force at the last
        assert admin.post(f"/api/admin/photos/rules/{uid}/approve").json()["error"]["code"] == "FOUR_EYES"
        first = sec.post(f"/api/admin/photos/rules/{uid}/approve")
        assert first.status_code == 200 and first.json()["status"] == "PENDING" and first.json()["approvals"] == 1, first.text
        assert first.json()["stages"] == ["CHECK", "APPROVE"]
        assert sec.post(f"/api/admin/photos/rules/{uid}/approve").json()["error"]["code"] == "ALREADY_APPROVED"
        last = privacy.post(f"/api/admin/photos/rules/{uid}/approve")
        assert last.status_code == 200 and last.json()["status"] == "APPROVED" and last.json()["approvals"] == 2, last.text
        assert privacy.post(f"/api/admin/photos/rules/{uid}/approve").json()["error"]["code"] == "NOT_PROPOSED"

        # the retirement of a rule in force: the one who proposed it asks; it stays in force until the last stage; the asker,
        # the proposer and the final approver do not approve it; the checker and the second final approver do
        r = admin.post(f"/api/admin/photos/rules/{uid}/retirement", json={"reason": "test: the rule is no longer needed"})
        assert r.status_code == 201 and r.json()["status"] == "RETIRING", r.text
        assert admin.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["error"]["code"] == "FOUR_EYES"
        assert privacy.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["error"]["code"] == "FOUR_EYES"
        assert sec.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["status"] == "PENDING"
        assert sec.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["error"]["code"] == "ALREADY_APPROVED"
        assert privacy2.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["status"] == "RETIRED"
        assert sec.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["error"]["code"] == "NOT_PENDING"
        listed = next(x for x in admin.get("/api/admin/photos/rules").json()["rules"] if x["uid"] == uid)
        assert listed["status"] == "RETIRED" and listed["requirement"] == "REQUIRED"
        assert listed["stages"] == ["CHECK", "APPROVE"] and listed["retirement_stages"] == ["CHECK", "APPROVE"]
    finally:
        if rule_status(admin, uid) == "APPROVED":
            retire_child_rule(admin, sec, privacy2, uid)


def test_a_proposal_can_be_withdrawn_and_a_turned_down_retirement_keeps_the_rule_in_force():
    admin, sec, privacy, privacy2 = staff(ADMIN), staff(SECOND), staff(PRIVACY), staff(PRIVACY2)
    withdrawn = propose(admin, passenger_category="CHILD").json()["uid"]
    r = sec.post(f"/api/admin/photos/rules/{withdrawn}/withdraw")
    assert r.status_code == 200 and r.json()["status"] == "RETIRED", r.text
    assert sec.post(f"/api/admin/photos/rules/{withdrawn}/approve").json()["error"]["code"] == "NOT_PROPOSED"
    assert rule_status(admin, withdrawn) == "RETIRED"

    uid = active_child_rule(admin, sec, privacy)
    try:
        # the checker asks; the proposer does not approve it; it is turned down, and the rule is still in force
        assert sec.post(f"/api/admin/photos/rules/{uid}/retirement", json={"reason": "test: asked and then turned down"}).status_code == 201
        assert admin.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["error"]["code"] == "FOUR_EYES"
        assert sec.post(f"/api/admin/photos/rules/{uid}/retirement/reject").json()["status"] == "APPROVED"
        assert rule_status(admin, uid) == "APPROVED"
        assert admin.post(f"/api/admin/photos/rules/{uid}/retirement/approve").json()["error"]["code"] == "NOT_PENDING"
    finally:
        if rule_status(admin, uid) == "APPROVED":
            retire_child_rule(admin, sec, privacy2, uid)


def test_a_required_photo_refuses_an_unlinked_child_at_booking_and_at_the_gate(trip):
    admin, sec, privacy, privacy2 = staff(ADMIN), staff(SECOND), staff(PRIVACY), staff(PRIVACY2)
    c = funded(new_passenger())
    # an adult travels with the child; the first child is booked before the rule, the rule then refuses the second,
    # and the gate refuses the first (no cancellation: the ticket stays issued)
    seats = free_seats(c, trip, 2)
    first = c.post("/api/bookings", json=body(trip, [person(seats[0]), person(seats[1], "Lina", birth_date=years_ago(7))],
                                              hold(c, trip, seats).json()["hold_token"]))
    assert first.status_code == 201, first.text
    token = c.get(f"/api/tickets/{ticket_of(first.json()['booking_ref'], 'CHILD')}/qr").json()["token"]
    ticket = ticket_of(first.json()["booking_ref"], "CHILD")
    uid = active_child_rule(admin, sec, privacy)
    try:
        seats = free_seats(c, trip, 2)
        people = [person(seats[0]), person(seats[1], "Sami", birth_date=years_ago(7))]
        r = c.post("/api/bookings", json=body(trip, people, hold(c, trip, seats).json()["hold_token"]))
        assert r.status_code == 422 and r.json()["error"]["code"] == "PHOTO_REQUIRED", r.text
        assert scan(trip["uid"], assigned_driver(trip["uid"]), token) == "PHOTO_REQUIRED"
        assert ticket_status(ticket) == "ISSUED"
    finally:
        retire_child_rule(admin, sec, privacy2, uid)


def test_a_linked_member_boards_under_the_rule_once_a_photo_is_on_file(trip):
    admin, sec, privacy, privacy2 = staff(ADMIN), staff(SECOND), staff(PRIVACY), staff(PRIVACY2)
    head = funded(new_passenger())
    fam = make_family(head, ("SON", "Sami", years_ago(7), {}))

    def people(seats):
        return [person(seats[0], family_member_uid=fam["SELF"]["uid"]), person(seats[1], family_member_uid=fam["Sami"]["uid"])]

    uid = active_child_rule(admin, sec, privacy)
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
        retire_child_rule(admin, sec, privacy2, uid)


def approve_through(path: str, uid: str, *approvers) -> dict:
    """Each approver records the next stage in turn; the last response says whether the change applied."""
    out = None
    for who in approvers:
        r = who.post(f"{path}/{uid}/approve")
        assert r.status_code == 200, r.text
        out = r.json()
    return out


def test_a_photo_on_file_changes_only_through_its_stages_with_evidence():
    admin, sec, privacy = staff(ADMIN), staff(SECOND), staff(PRIVACY)
    email, c = register()
    assert upload(c, JPEG).status_code == 201
    before = photo_of_email(email)["photo_file_id"]
    party = owner_sql("SELECT p.uid FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id WHERE u.email = $1", email)
    form = {"party_uid": str(party), "reason": "the photo on file is not the holder", "evidence_kind": "PASSPORT"}
    files = {"evidence": ("id.jpg", JPEG, "image/jpeg"), "new_photo": ("new.png", PNG, "image/png")}
    # the person cannot ask for a change; the platform asks, with the evidence and the new photo
    assert c.post("/api/admin/photos/changes", data=form, files=files).status_code == 403
    r = admin.post("/api/admin/photos/changes", data=form, files=files)
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    req = r.json()["uid"]
    # the one who asks does not approve; the first stage is recorded; the same person cannot record a second stage
    assert admin.post(f"/api/admin/photos/changes/{req}/approve").json()["error"]["code"] == "FOUR_EYES"
    first = sec.post(f"/api/admin/photos/changes/{req}/approve")
    assert first.status_code == 200 and first.json()["status"] == "PENDING" and first.json()["approvals"] == 1, first.text
    assert first.json()["stages"] == ["CHECK", "APPROVE"]
    assert sec.post(f"/api/admin/photos/changes/{req}/approve").json()["error"]["code"] == "ALREADY_APPROVED"
    ev = admin.get(f"/api/admin/photos/changes/{req}/evidence")
    assert ev.status_code == 200 and ev.content == JPEG
    # the final stage replaces the photo
    last = privacy.post(f"/api/admin/photos/changes/{req}/approve")
    assert last.status_code == 200 and last.json()["status"] == "APPLIED" and last.json()["approvals"] == 2, last.text
    assert privacy.post(f"/api/admin/photos/changes/{req}/approve").json()["error"]["code"] == "NOT_PENDING"
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


def policy(admin, sec, privacy, path: str, body: dict) -> str:
    """A change to the photo policy, asked by the admin and passed through both stages; returns its last status."""
    r = admin.post(path, json={**body, "reason": "test: the change needs the approval stages"})
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    uid = r.json()["uid"]
    return approve_through("/api/admin/photos/policy-changes", uid, sec, privacy)["status"]


def test_the_accepted_evidence_and_the_age_rule_change_only_through_the_stages():
    admin, sec, privacy = staff(ADMIN), staff(SECOND), staff(PRIVACY)
    email, c = register()
    assert upload(c, JPEG).status_code == 201
    party = owner_sql("SELECT p.uid FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id WHERE u.email = $1", email)
    settings = admin.get("/api/admin/photos/evidence-kinds").json()
    assert {"CIVIL_REGISTRY_EXTRACT", "IDENTITY_DOCUMENT", "PASSPORT", "TRAVEL_DOCUMENT", "TEMPORARY_ID"} <= {k["code"] for k in settings["kinds"]}
    assert all(k["active"] for k in settings["kinds"])
    assert settings["approval_stages"] == ["CHECK", "APPROVE"]
    assert settings["identity_card_min_age"] == 18                       # the default, set by the law when it is known
    # the person cannot ask; an unknown kind is not found
    assert c.post("/api/admin/photos/evidence-kinds/PASSPORT/changes", json={"active": False, "reason": "test: not the person"}).status_code == 403
    assert admin.post("/api/admin/photos/evidence-kinds/NO_SUCH_KIND/changes", json={"active": False, "reason": "test: no such kind"}).status_code == 404
    files = {"evidence": ("passport.jpg", JPEG, "image/jpeg"), "new_photo": ("new.png", PNG, "image/png")}
    form = {"party_uid": str(party), "reason": "the photo on file is not the holder", "evidence_kind": "PASSPORT"}

    # the switch off goes through both stages, and the request with the kind is refused meanwhile
    assert policy(admin, sec, privacy, "/api/admin/photos/evidence-kinds/PASSPORT/changes", {"active": False}) == "APPLIED"
    try:
        r = admin.post("/api/admin/photos/changes", data=form, files=files)
        assert r.status_code == 422 and r.json()["error"]["code"] == "EVIDENCE_KIND_NOT_ACCEPTED", r.text
        r = admin.post("/api/admin/photos/changes", data={**form, "evidence_kind": "BIRTH_CERTIFICATE"}, files=files)
        assert r.status_code == 422 and r.json()["error"]["code"] == "EVIDENCE_KIND_NOT_ACCEPTED", r.text
    finally:
        assert policy(admin, sec, privacy, "/api/admin/photos/evidence-kinds/PASSPORT/changes", {"active": True}) == "APPLIED"
    r = admin.post("/api/admin/photos/changes", data=form, files=files)
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    assert owner_sql("SELECT evidence_kind FROM iam.photo_change_request WHERE uid = $1", uuid.UUID(r.json()["uid"])) == "PASSPORT"

    # the age rule (18 by default): a national identity card is refused for this person, the passport still stands;
    # the temporary identity document is under the same rule; clearing the rule accepts the card again
    assert policy(admin, sec, privacy, "/api/admin/photos/identity-age/changes", {"min_age": 120}) == "APPLIED"
    card = {**form, "evidence_kind": "IDENTITY_DOCUMENT"}
    r = admin.post("/api/admin/photos/changes", data=card, files=files)
    assert r.status_code == 422 and r.json()["error"]["code"] == "EVIDENCE_KIND_NOT_ACCEPTED", r.text
    for kind in ("TEMPORARY_ID", "TRAVEL_DOCUMENT"):
        r = admin.post("/api/admin/photos/changes", data={**form, "evidence_kind": kind}, files=files)
        assert r.status_code == 422 and r.json()["error"]["code"] == "EVIDENCE_KIND_NOT_ACCEPTED", (kind, r.text)
    assert policy(admin, sec, privacy, "/api/admin/photos/identity-age/changes", {"min_age": None}) == "APPLIED"
    assert admin.get("/api/admin/photos/evidence-kinds").json()["identity_card_min_age"] is None
    r = admin.post("/api/admin/photos/changes", data=card, files=files)
    assert r.status_code == 201, r.text

    # a travel document is for a Syrian citizen only
    r = admin.post("/api/admin/photos/changes", data={**form, "evidence_kind": "TRAVEL_DOCUMENT"}, files=files)
    assert r.status_code == 422 and r.json()["error"]["code"] == "EVIDENCE_KIND_NOT_ACCEPTED", r.text
    owner_sql("UPDATE iam.party SET nationality = 'SY' WHERE uid = $1", uuid.UUID(str(party)))
    r = admin.post("/api/admin/photos/changes", data={**form, "evidence_kind": "TRAVEL_DOCUMENT"}, files=files)
    assert r.status_code == 201 and r.json()["status"] == "PENDING", r.text
    assert owner_sql("SELECT count(*) FROM audit.activity_log WHERE action = 'photo.policy_approve'") >= 4


def test_a_data_item_is_required_or_optional_by_the_platform_setting():
    admin, sec, privacy = staff(ADMIN), staff(SECOND), staff(PRIVACY)
    email, c = register()
    party = owner_sql("SELECT p.uid FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id WHERE u.email = $1", email)
    form = {"party_uid": str(party), "reason": "the photo on file is not the holder", "evidence_kind": "PASSPORT"}
    files = {"evidence": ("passport.jpg", JPEG, "image/jpeg"), "new_photo": ("new.png", PNG, "image/png")}
    items = {i["field_code"]: i["requirement"] for i in admin.get("/api/admin/photos/evidence-kinds").json()["data_requirements"]}
    assert items["party.birth_date"] == "OPTIONAL"
    # the birth date is optional: the change goes ahead without it
    r = admin.post("/api/admin/photos/changes", data=form, files=files)
    assert r.status_code == 201, r.text
    # the platform requires it: the change is refused for a person whose record has no birth date
    assert policy(admin, sec, privacy, "/api/admin/photos/data-requirements/party.birth_date/changes", {"requirement": "REQUIRED"}) == "APPLIED"
    try:
        r = admin.post("/api/admin/photos/changes", data=form, files=files)
        assert r.status_code == 422 and r.json()["error"]["code"] == "DATA_REQUIRED", r.text
        assert r.json()["error"]["field"] == "party.birth_date"
        owner_sql("UPDATE iam.party SET birth_date = $2 WHERE uid = $1", uuid.UUID(str(party)), date(1990, 1, 1))
        r = admin.post("/api/admin/photos/changes", data=form, files=files)
        assert r.status_code == 201, r.text
    finally:
        assert policy(admin, sec, privacy, "/api/admin/photos/data-requirements/party.birth_date/changes", {"requirement": "OPTIONAL"}) == "APPLIED"


def party_id_of(email):
    return owner_sql("SELECT party_id FROM iam.app_user WHERE email = $1", email)
