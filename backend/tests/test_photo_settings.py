"""The boarding photo's settings (migration 1096): who may see the photo and when, the date the rules are enforced from, how
often a person is checked again, and the identity provider. Each is a platform setting, changed through the approval stages;
none is forced at launch.

The traveler sees the photo on request, the driver and the carrier's office only while the trip is boarding, and nothing is
required before the date the platform sets."""
from datetime import date, timedelta

import pytest

from test_boarding_photo import JPEG, change_setting, register, switch_on, upload, view_access
from test_e2e import free_seats, hold, login, new_passenger, pax, trip  # noqa: F401
from test_families import body, funded, person, years_ago
from test_photo_policy import ADMIN, PRIVACY, PRIVACY2, SECOND, active_child_rule, retire_child_rule, staff


@pytest.fixture(autouse=True)
def photo_switched_on():
    switch_on(enforce=False)                    # the launch values are checked with no enforcement date


def settings_view():
    return login(*ADMIN).get("/api/admin/photos/evidence-kinds").json()


def test_the_settings_have_their_launch_values():
    view = settings_view()
    assert view["view_access"] == {"TRAVELER": True, "DRIVER_AT_BOARDING": True,
                                   "CARRIER_OFFICE_AT_BOARDING": False, "AGENT": False}
    assert view["verify_every_days"] is None and view["enforce_from"] is None
    assert view["identity_provider"] == "NONE"


@pytest.mark.parametrize("key, value", [
    ("photo.view_access", {"TRAVELER": True, "DRIVER_AT_BOARDING": True, "CARRIER_OFFICE_AT_BOARDING": "yes", "AGENT": False}),
    ("photo.view_access", {"TRAVELER": True, "DRIVER_AT_BOARDING": True, "CARRIER_OFFICE_AT_BOARDING": False}),
    ("photo.verify_every_days", 0),
    ("photo.verify_every_days", 366),
    ("photo.verify_every_days", True),
    ("photo.enforce_from", "2026-13-40"),
    ("photo.enforce_from", "11/10/2026"),
    ("photo.identity_provider", "SOME_PROVIDER"),
    ("photo.enabled", True),                                    # the switch has its own change, with a legal basis
])
def test_an_invalid_setting_is_refused_before_it_is_asked(key, value):
    r = login(*ADMIN).post("/api/admin/photos/settings/changes", json={"key": key, "value": value, "reason": "test of invalid values"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "INVALID_SETTING", r.text


def test_the_traveler_sees_the_own_photo_on_request_and_only_when_allowed():
    email, c = register()
    assert upload(c, JPEG).status_code == 201
    r = c.get("/api/account/photo/image")
    assert r.status_code == 200 and r.content == JPEG and r.headers["content-type"].startswith("image/jpeg"), r.text
    access = dict(view_access(), TRAVELER=False)
    change_setting("photo.view_access", access)
    try:
        r = c.get("/api/account/photo/image")
        assert r.status_code == 403 and r.json()["error"]["code"] == "PHOTO_VIEW_NOT_ALLOWED", r.text
    finally:
        change_setting("photo.view_access", dict(access, TRAVELER=True))
    assert c.get("/api/account/photo/image").status_code == 200


def test_identity_verification_refuses_until_a_provider_is_connected():
    _, c = register()
    r = c.post("/api/account/photo/verify")
    assert r.status_code == 409 and r.json()["error"]["code"] == "IDENTITY_PROVIDER_NOT_CONFIGURED", r.text


def test_the_enforcement_date_decides_when_a_required_photo_is_asked(trip):
    admin, sec, privacy, privacy2 = staff(ADMIN), staff(SECOND), staff(PRIVACY), staff(PRIVACY2)
    c = funded(new_passenger())
    uid = active_child_rule(admin, sec, privacy)               # a rule that requires a photo for children
    try:
        # the rule is in force, but the platform has not set the date it is enforced from: nothing is refused
        change_setting("photo.enforce_from", (date.today() + timedelta(days=1)).isoformat())
        seats = free_seats(c, trip, 2)
        r = c.post("/api/bookings", json=body(trip, [person(seats[0]), person(seats[1], "Lina", birth_date=years_ago(7))],
                                              hold(c, trip, seats).json()["hold_token"]))
        assert r.status_code == 201, r.text
        # from the date: a child without a photo is refused at booking
        change_setting("photo.enforce_from", (date.today() - timedelta(days=1)).isoformat())
        seats = free_seats(c, trip, 2)
        r = c.post("/api/bookings", json=body(trip, [person(seats[0]), person(seats[1], "Sami", birth_date=years_ago(7))],
                                              hold(c, trip, seats).json()["hold_token"]))
        assert r.status_code == 422 and r.json()["error"]["code"] == "PHOTO_REQUIRED", r.text
    finally:
        change_setting("photo.enforce_from", None)
        retire_child_rule(admin, sec, privacy2, uid)


def test_the_app_is_told_whether_the_photo_is_in_use_and_whether_the_traveler_may_see_it():
    email, c = register()
    status = c.get("/api/account/photo").json()
    assert status["enabled"] is True and status["can_view"] is True and status["has_photo"] is False
    access = dict(view_access(), TRAVELER=False)
    change_setting("photo.view_access", access)
    try:
        assert c.get("/api/account/photo").json()["can_view"] is False
    finally:
        change_setting("photo.view_access", dict(access, TRAVELER=True))
