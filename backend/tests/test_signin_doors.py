"""Two sign-in doors (owner's request N16, migration 1150): individuals give their e-mail or mobile number, businesses give
the company number, the username and the password, and the company's kind decides the portal. A password set by an
administrator is temporary: it is replaced at the first sign-in before anything else, and it expires."""
import uuid

import pytest

from test_e2e import OWNER_URL, PASSWORD, client, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
TEMP = "temporary-long-passphrase"
FINAL = "my-own-long-passphrase-2026"


def carrier_no() -> str:
    return owner_sql("SELECT c.company_no FROM iam.company c JOIN iam.app_user u ON u.home_company_id = c.id WHERE u.email = 'driver@carrier.test'")


def business(company_no, username, password=PASSWORD, portal=None):
    c = client()
    body = {"company_no": company_no, "username": username, "password": password}
    if portal:
        body["portal"] = portal
    return c, c.post("/api/auth/login/business", json=body)


def test_every_company_has_a_number_and_staff_a_username():
    row = owner_sql("""SELECT c.company_no, u.username FROM iam.app_user u JOIN iam.company c ON c.id = u.home_company_id
                        WHERE u.email = 'driver@carrier.test'""", fetch=True)
    assert row["company_no"].isdigit() and 6 <= len(row["company_no"]) <= 8 and row["username"] == "driver"
    assert owner_sql("SELECT count(*) FROM iam.company WHERE company_no IS NULL") == 0
    assert owner_sql("SELECT username FROM iam.app_user WHERE email = 'admin@masslak.test'") == "admin"


def test_the_business_door_takes_the_company_number_and_the_username():
    c, r = business(carrier_no(), "driver", portal="DRIVER")
    assert r.status_code == 200, r.text
    assert r.json()["portal"] == "DRIVER" and c.get("/api/auth/me").json()["portal"] == "DRIVER"
    _, r = business(carrier_no(), "DRIVER ", portal="DRIVER")          # the username is not case-sensitive
    assert r.status_code == 200
    _, r = business(carrier_no(), "driver")                             # a driver lands in the driver's portal unasked
    assert r.status_code == 200 and r.json()["portal"] == "DRIVER"
    # without a portal named, a carrier's staff land in the carrier's portal
    _, r = business(carrier_no(), "owner")
    assert r.status_code == 200 and r.json()["portal"] == "OPERATOR"
    # an agency's number opens the agency portal; a carrier's username under the agency's number is unknown
    agency_no = owner_sql("SELECT c.company_no FROM iam.company c WHERE c.company_type = 'AGENCY' AND c.approval_status = 'APPROVED' "
                          "AND EXISTS (SELECT 1 FROM iam.app_user u WHERE u.home_company_id = c.id AND u.username = 'agency')")
    if agency_no:
        _, r = business(agency_no, "agency")
        assert r.status_code == 200 and r.json()["portal"] == "AGENCY"
        _, r = business(agency_no, "driver")
        assert r.status_code == 401 and r.json()["error"]["code"] == "INVALID_CREDENTIALS"


def test_unknown_numbers_and_wrong_passwords_look_the_same():
    _, unknown = business("999999", "driver")
    _, wrong = business(carrier_no(), "driver", password="not-the-password-at-all")
    assert unknown.status_code == wrong.status_code == 401
    assert unknown.json()["error"]["code"] == wrong.json()["error"]["code"] == "INVALID_CREDENTIALS"


def test_the_platform_staff_use_the_platform_number():
    _, r = business("100000", "admin")
    assert r.status_code == 200 and r.json()["portal"] == "PLATFORM"
    _, r = business("100000", "driver")                                 # a carrier's employee is not platform staff
    assert r.status_code == 401


def test_the_individuals_door_is_for_passengers_only():
    c = client()
    r = c.post("/api/auth/login/individual", json={"identifier": "passenger@masslak.test", "password": PASSWORD})
    assert r.status_code == 200 and r.json()["portal"] == "PASSENGER"
    r = client().post("/api/auth/login/individual", json={"identifier": "driver@carrier.test", "password": PASSWORD})
    assert r.status_code == 401 and r.json()["error"]["code"] == "INVALID_CREDENTIALS"


def test_a_password_set_by_the_company_is_changed_at_the_first_sign_in():
    o = login("owner@carrier.test", "OPERATOR")
    email = f"crew{uuid.uuid4().hex[:8]}@example.com"
    r = o.post("/api/carrier/crew", json={"full_name": "New Driver", "email": email, "password": TEMP})
    assert r.status_code == 201, r.text
    door = r.json()["sign_in"]
    assert door["company_no"] == carrier_no() and door["username"] == email.split("@")[0]

    c, r = business(door["company_no"], door["username"], TEMP, portal="DRIVER")
    assert r.status_code == 200 and r.json()["password_change_required"] is True
    blocked = c.get("/api/auth/me")
    assert blocked.status_code == 403 and blocked.json()["error"]["code"] == "PASSWORD_CHANGE_REQUIRED"
    r = c.post("/api/account/password/first", json={"current_password": TEMP, "new_password": TEMP})
    assert r.status_code == 422 and r.json()["error"]["code"] == "PASSWORD_SAME"
    r = c.post("/api/account/password/first", json={"current_password": TEMP, "new_password": FINAL})
    assert r.status_code == 200, r.text
    assert c.get("/api/auth/me").status_code == 200
    assert c.post("/api/account/password/first", json={"current_password": FINAL, "new_password": FINAL + "x"}).status_code == 409
    _, r = business(door["company_no"], door["username"], FINAL, portal="DRIVER")
    assert r.status_code == 200 and r.json()["password_change_required"] is False


def test_a_temporary_password_expires():
    o = login("owner@carrier.test", "OPERATOR")
    email = f"crew{uuid.uuid4().hex[:8]}@example.com"
    door = o.post("/api/carrier/crew", json={"full_name": "Late Driver", "email": email, "password": TEMP}).json()["sign_in"]
    owner_sql("UPDATE iam.app_user SET temp_password_expires_at = now() - interval '1 minute' WHERE email = $1", email)
    _, r = business(door["company_no"], door["username"], TEMP, portal="DRIVER")
    assert r.status_code == 403 and r.json()["error"]["code"] == "TEMP_PASSWORD_EXPIRED"


def test_the_older_sign_in_can_be_turned_off():
    owner_sql("UPDATE sys.setting SET value = jsonb_set(value, '{legacy_portal_login}', 'false') WHERE key = 'auth.doors'")
    try:
        r = client().post("/api/auth/login", json={"identifier": "passenger@masslak.test", "password": PASSWORD, "portal": "PASSENGER"})
        assert r.status_code == 410 and r.json()["error"]["code"] == "USE_SIGN_IN_DOORS"
    finally:
        owner_sql("UPDATE sys.setting SET value = jsonb_set(value, '{legacy_portal_login}', 'true') WHERE key = 'auth.doors'")
