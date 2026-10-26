"""The first interface language by the visitor's country (owner decision, October 2026; migration 1141): Arabic for a
visitor in Syria, English for a visitor from anywhere else, and the platform sets the language of each country. The
country is the header the edge proxy sets."""
import pytest

from test_e2e import OWNER_URL, client, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def _first(country=None):
    headers = {"CF-IPCountry": country} if country else {}
    return client().get("/api/markets", headers=headers).json()["visitor"]


def test_arabic_in_syria_and_english_elsewhere():
    assert _first("SY") == {"country": "SY", "locale": "ar"}
    assert _first("DE") == {"country": "DE", "locale": "en"}
    assert _first("sy")["locale"] == "ar"                      # the code is read in upper case
    # no country, an unknown one (XX) or a malformed one: the default
    assert _first() == {"country": None, "locale": "en"}
    assert _first("XX")["country"] is None and _first("Syria")["country"] is None
    # without a country the browser's first language decides, when the platform has it
    r = client().get("/api/markets", headers={"Accept-Language": "ar-SY,ar;q=0.9,en;q=0.8"}).json()["visitor"]
    assert r == {"country": None, "locale": "ar"}
    assert client().get("/api/markets", headers={"Accept-Language": "ja-JP"}).json()["visitor"]["locale"] == "en"
    # a country wins over the browser
    assert client().get("/api/markets", headers={"CF-IPCountry": "DE", "Accept-Language": "ar"}).json()["visitor"]["locale"] == "en"


def test_the_platform_sets_the_language_of_each_country():
    admin = login("admin@masslak.test", "PLATFORM")
    before = admin.get("/api/admin/ui/visitor-locale").json()
    assert before["default"] == "en" and before["countries"] == {"SY": "ar"}
    assert {lang["code"] for lang in before["languages"]} >= {"ar", "en"}
    try:
        r = admin.put("/api/admin/ui/visitor-locale", json={"default": "en", "countries": {"SY": "ar", "lb": "ar", "JO": "ar"},
                                                             "basis": "Arabic first in the neighbouring countries"})
        assert r.status_code == 200, r.text
        assert r.json()["countries"] == {"SY": "ar", "LB": "ar", "JO": "ar"}
        assert _first("LB")["locale"] == "ar" and _first("TR")["locale"] == "en"
        # only enabled languages and two-letter country codes
        for bad in ({"default": "en", "countries": {"SY": "tr"}}, {"default": "zz", "countries": {}},
                    {"default": "en", "countries": {"SYR": "ar"}}):
            r = admin.put("/api/admin/ui/visitor-locale", json={**bad, "basis": "a wrong value"})
            assert r.status_code == 409 and r.json()["error"]["code"] == "INVALID_SETTING", r.text
        # the platform alone sets it
        r = login("owner@carrier.test", "OPERATOR").put("/api/admin/ui/visitor-locale", json={
            "default": "ar", "countries": {}, "basis": "a carrier tries"})
        assert r.status_code == 403
    finally:
        assert admin.put("/api/admin/ui/visitor-locale", json={"default": "en", "countries": {"SY": "ar"},
                                                                "basis": "back to the approved default"}).status_code == 200
    assert owner_sql("SELECT sys.visitor_locale('SY')") == "ar"
