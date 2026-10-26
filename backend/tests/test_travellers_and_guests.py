"""The traveller "Me", saved travellers and booking without an account (owner's request N18, migration 1153)."""
import uuid

import pytest

from test_e2e import OWNER_URL, bookable_trip, client, free_seats, hold, owner_sql, publish_fresh_trip, syrian
from test_identity_names import email_code, register, signed_in

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
SY_NAME = {"nationality": "SY", "first_name": "Lina", "father_name": "Omar", "last_name": "Haddad",
           "first_name_latin": "Lina", "last_name_latin": "Haddad"}


def trip_for(c):
    t = bookable_trip(c)
    if t is None:
        publish_fresh_trip()
        t = bookable_trip(c)
    assert t, "no bookable trip"
    return t


def book(c, t, passengers):
    """Holds the seats and books, paying from the wallet topped up in the sandbox."""
    assert c.post("/api/wallet/topup", json={"amount": 10000000, "idempotency_key": uuid.uuid4().hex}).status_code == 200
    seats = [p["seat_no"] for p in passengers]
    h = hold(c, t, seats).json()["hold_token"]
    return c.post("/api/bookings", json={
        "hold_token": h, "trip_uid": t["uid"], "from_seq": t["from_seq"], "to_seq": t["to_seq"], "fare_brand": "STANDARD",
        "idempotency_key": uuid.uuid4().hex, "passengers": passengers})


def passenger():
    email = f"me{uuid.uuid4().hex[:8]}@example.com"
    assert register(client(), email, name=SY_NAME).status_code == 201
    return email, signed_in(email)


def test_the_account_holder_books_as_me_without_typing_again():
    email, c = passenger()
    me = c.get("/api/account/me-traveller").json()
    assert me["first_name"] == "Lina" and me["ready"] is False             # no document yet
    number = f"01{uuid.uuid4().int % 10**8:08d}"          # a document is registered to one person only
    r = c.put("/api/account/document", json={"birth_date": "1990-04-02", "gender": "F", "id_type": "NATIONAL_ID",
                                             "id_no": number})
    assert r.status_code == 200 and r.json()["ready"] is True and r.json()["id_no_last4"] == number[-4:], r.text
    stored = owner_sql("SELECT id_no_enc FROM iam.party p JOIN iam.app_user u ON u.party_id = p.id WHERE u.email = $1", email)
    assert number.encode() not in bytes(stored)

    t = trip_for(c)
    seat = free_seats(c, t, 1)[0]
    # the form's names are ignored for "Me": the account's are used
    r = book(c, t, [{**syrian(seat), "first_name": "Someone", "grandfather_name": "Ahmad", "self_traveller": True}])
    assert r.status_code == 201, r.text
    tickets = c.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"]
    assert tickets[0]["full_name"].startswith("Lina Omar") and tickets[0]["full_name"].endswith("Haddad")

    # once verified, the identity details change only through a new review
    owner_sql("UPDATE iam.party SET verification_status = 'VERIFIED' WHERE id = (SELECT party_id FROM iam.app_user WHERE email = $1)", email)
    r = c.put("/api/account/document", json={"birth_date": "1990-04-02", "gender": "F", "id_type": "NATIONAL_ID", "id_no": "0109999999"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "IDENTITY_LOCKED"


def test_saved_travellers_need_consent_and_are_booked_by_reference():
    email, c = passenger()
    friend = {"nationality": "SY", "first_name": "Sami", "father_name": "Fadi", "grandfather_name": "Nabil", "last_name": "Kurdi",
              "birth_date": "1988-01-01", "gender": "M", "id_type": "NATIONAL_ID", "id_no": "0207654321", "label": "Sami"}
    r = c.post("/api/account/travellers", json={**friend, "consent": False})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONSENT_REQUIRED"
    r = c.post("/api/account/travellers", json={**friend, "consent": True})
    assert r.status_code == 201 and r.json()["id_last4"] == "4321" and "id_no" not in r.json()
    uid = r.json()["uid"]
    assert [x["uid"] for x in c.get("/api/account/travellers").json()["travellers"]] == [uid]

    # another passenger cannot book someone else's saved traveller
    _, other = passenger()
    t = trip_for(other)
    seat = free_seats(other, t, 1)[0]
    r = book(other, t, [{**syrian(seat), "saved_traveller_uid": uid}])
    assert r.status_code == 404 and r.json()["error"]["code"] == "NOT_SAVED"

    seat = free_seats(c, t, 1)[0]
    r = book(c, t, [{**syrian(seat), "saved_traveller_uid": uid}])
    assert r.status_code == 201, r.text
    tickets = c.get(f"/api/bookings/{r.json()['booking_ref']}").json()["tickets"]
    assert tickets[0]["full_name"] == "Sami Fadi Nabil Kurdi"

    assert c.delete(f"/api/account/travellers/{uid}").status_code == 200
    assert c.get("/api/account/travellers").json()["travellers"] == []
    assert owner_sql("SELECT id_no_enc FROM iam.saved_traveller WHERE uid = $1", uuid.UUID(uid)) is None


def test_a_guest_books_with_an_email_code_and_may_turn_into_an_account():
    email = f"guest{uuid.uuid4().hex[:8]}@example.com"
    g = client()
    assert g.post("/api/auth/guest/start", json={"email": email}).json()["sent"] is True
    code = email_code(email)
    wrong = f"{(int(code) + 1) % 1_000_000:06d}"
    assert g.post("/api/auth/guest/verify", json={"email": email, "code": wrong}).status_code == 422
    r = g.post("/api/auth/guest/verify", json={"email": email, "code": code})
    assert r.status_code == 200 and r.json()["portal"] == "PASSENGER", r.text
    assert g.get("/api/auth/me").json()["is_guest"] is True

    t = trip_for(g)
    seat = free_seats(g, t, 1)[0]
    r = book(g, t, [{**syrian(seat), "id_no": "0301112223"}])
    assert r.status_code == 201, r.text
    ref = r.json()["booking_ref"]

    # a guest account has no password: the individuals' door does not open it
    assert client().post("/api/auth/login/individual", json={"identifier": email, "password": "anything-long-enough"}).status_code == 401
    # the guest keeps the booking by choosing a password
    r = g.post("/api/account/claim", json={"name": SY_NAME, "password": "my-guest-password-2026", "password_confirm": "my-guest-password-2026"})
    assert r.status_code == 200, r.text
    assert g.get("/api/auth/me").json()["is_guest"] is False
    c = client()
    assert c.post("/api/auth/login/individual", json={"identifier": email, "password": "my-guest-password-2026"}).status_code == 200
    assert c.get(f"/api/bookings/{ref}").status_code == 200


def test_an_email_with_an_account_signs_in_instead_and_citizens_can_be_asked_for_an_account():
    email, _ = passenger()
    r = client().post("/api/auth/guest/start", json={"email": email})
    assert r.status_code == 409 and r.json()["error"]["code"] == "ACCOUNT_EXISTS"

    owner_sql("UPDATE sys.setting SET value = jsonb_set(value, '{account_required_for}', '\"CITIZENS\"') WHERE key = 'booking.guest'")
    try:
        guest = f"guest{uuid.uuid4().hex[:8]}@example.com"
        g = client()
        g.post("/api/auth/guest/start", json={"email": guest})
        assert g.post("/api/auth/guest/verify", json={"email": guest, "code": email_code(guest)}).status_code == 200
        t = trip_for(g)
        seat, other = free_seats(g, t, 2)
        r = book(g, t, [syrian(seat)])
        assert r.status_code == 403 and r.json()["error"]["code"] == "ACCOUNT_REQUIRED"
        foreign = {"nationality": "FR", "first_name": "Marie", "last_name": "Dubois", "seat_no": other, "id_type": "PASSPORT",
                   "first_name_latin": "Marie", "last_name_latin": "Dubois", "id_no": "FR123456"}
        assert book(g, t, [foreign]).status_code == 201
    finally:
        owner_sql("UPDATE sys.setting SET value = jsonb_set(value, '{account_required_for}', '\"NONE\"') WHERE key = 'booking.guest'")
    owner_sql("UPDATE sys.setting SET value = jsonb_set(value, '{enabled}', 'false') WHERE key = 'booking.guest'")
    try:
        r = client().post("/api/auth/guest/start", json={"email": f"guest{uuid.uuid4().hex[:8]}@example.com"})
        assert r.status_code == 403 and r.json()["error"]["code"] == "GUEST_BOOKING_OFF"
    finally:
        owner_sql("UPDATE sys.setting SET value = jsonb_set(value, '{enabled}', 'true') WHERE key = 'booking.guest'")
