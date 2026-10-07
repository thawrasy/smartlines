"""Module switches and the generic resource engine: a switched-off module disappears, every resource answers its spec
and list for every portal that shows it, records stay inside their company, and actions follow their state machine."""
import secrets
import time
import uuid

import pytest

from test_e2e import OWNER_URL, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")

CACHE_SECONDS = 6          # app.modular.features caches the switches for five seconds


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def carrier():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def agency():
    return login("agency@agency.test", "AGENCY")


@pytest.fixture(scope="module")
def passenger():
    return login("passenger@masslak.test", "PASSENGER")


def switch(admin, key, enabled):
    r = admin.put(f"/api/admin/modules/{key}", json={"enabled": enabled, "reason": "automated test"})
    assert r.status_code == 200, r.text


@pytest.fixture(scope="module")
def all_on(admin):
    before = {m["key"]: m["enabled"] for m in admin.get("/api/admin/modules").json()["modules"]}
    for key, on in before.items():
        if not on:
            switch(admin, key, True)
    time.sleep(CACHE_SECONDS)
    yield
    for key, on in before.items():
        if not on:
            switch(admin, key, False)


def test_switching_needs_a_reason_and_the_permission(admin, carrier):
    r = admin.put("/api/admin/modules/taxi", json={"enabled": True, "reason": ""})
    assert r.status_code == 422
    assert admin.put("/api/admin/modules/no_such_module", json={"enabled": True, "reason": "test"}).status_code == 404
    assert carrier.put("/api/admin/modules/taxi", json={"enabled": True, "reason": "test"}).status_code == 403
    assert carrier.get("/api/admin/modules").status_code == 403


def test_a_switched_off_module_disappears(admin, carrier, all_on):
    assert carrier.get("/api/r/taxi-office/_spec").status_code == 200
    assert "taxi" in {m["key"] for m in carrier.get("/api/modules").json()["modules"]}
    switch(admin, "taxi", False)
    try:
        time.sleep(CACHE_SECONDS)
        r = carrier.get("/api/r/taxi-office")
        assert r.status_code == 404 and r.json()["error"]["code"] == "MODULE_DISABLED"
        assert "taxi" not in {m["key"] for m in carrier.get("/api/modules").json()["modules"]}
        assert "taxi" not in admin.get("/api/features").json()["enabled"]
    finally:
        switch(admin, "taxi", True)
        time.sleep(CACHE_SECONDS)


@pytest.mark.parametrize("who", ["admin", "carrier", "agency", "passenger"])
def test_every_visible_resource_answers_spec_list_and_lookups(request, who, all_on):
    client = request.getfixturevalue(who)
    menus = client.get("/api/modules").json()["modules"]
    keys = [r["key"] for m in menus for r in m["resources"]]
    assert keys, f"{who} sees no resources"
    failures = []
    for key in keys:
        spec = client.get(f"/api/r/{key}/_spec")
        rows = client.get(f"/api/r/{key}", params={"limit": 5})
        if spec.status_code != 200 or rows.status_code != 200:
            failures.append((key, spec.status_code, rows.status_code))
            continue
        for col in spec.json()["form"]:
            if col["ref"] and client.get(f"/api/r/{key}/lookup/{col['name']}").status_code != 200:
                failures.append((key, "lookup", col["name"]))
    assert not failures, failures


def test_records_stay_inside_their_company(carrier, agency, all_on):
    code = f"CC-{uuid.uuid4().hex[:6].upper()}"
    r = carrier.post("/api/r/cost-center", json={"code": code, "name": "Damascus garage"})
    assert r.status_code == 201, r.text
    key = r.json()["_key"]
    mine = carrier.get("/api/r/cost-center", params={"q": code}).json()["rows"]
    assert [x["code"] for x in mine] == [code]
    assert agency.get("/api/r/cost-center", params={"q": code}).json()["rows"] == []
    assert agency.get(f"/api/r/cost-center/{key}").status_code == 404
    assert agency.patch(f"/api/r/cost-center/{key}", json={"name": "taken over"}).status_code == 404
    r = carrier.patch(f"/api/r/cost-center/{key}", json={"name": "Aleppo garage"})
    assert r.status_code == 200 and r.json()["name"] == "Aleppo garage"


def test_read_only_portals_and_state_machine(admin, carrier, all_on):
    code = f"T{uuid.uuid4().hex[:5].upper()}"
    assert carrier.post("/api/r/line", json={"code": code, "name": "Test line"}).status_code == 403
    r = admin.post("/api/r/line", json={"code": code})
    assert r.status_code == 422 and r.json()["error"]["code"] == "REQUIRED_FIELDS"
    spec = admin.get("/api/r/line/_spec").json()
    form = {c["name"]: c for c in spec["form"]}
    body = {"code": code, "name": "Test line"}
    for name in ("kind", "fare_regime"):
        if form[name]["choices"]:
            body[name] = form[name]["choices"][0]
    # the shuttle opens city by city (1042): a shuttle line is activated only in an opened city
    opened = owner_sql("SELECT city_id FROM sys.city_rollout WHERE feature_key = 'shuttle_rides' AND status IN ('PILOT', 'OPEN') LIMIT 1")
    closed = owner_sql("""SELECT id FROM ref.city WHERE id NOT IN (SELECT city_id FROM sys.city_rollout WHERE feature_key = 'shuttle_rides')
                          ORDER BY id LIMIT 1""")
    if body.get("kind") == "SHUTTLE":
        r = admin.post("/api/r/line", json={**body, "code": code + "X", "city_id": closed})
        assert r.status_code == 201, r.text
        r = admin.post(f"/api/r/line/{r.json()['_key']}/do/activate")
        assert r.status_code == 409 and "CITY_NOT_OPEN" in r.text, r.text
    body["city_id"] = opened
    r = admin.post("/api/r/line", json=body)
    assert r.status_code == 201, r.text
    key = r.json()["_key"]
    assert r.json()["status"] == "DRAFT"
    r = admin.post(f"/api/r/line/{key}/do/activate")
    assert r.status_code == 200 and r.json()["status"] == "ACTIVE"
    r = admin.post(f"/api/r/line/{key}/do/activate")
    assert r.status_code == 409 and r.json()["error"]["code"] == "INVALID_STATE"
    assert carrier.post(f"/api/r/line/{key}/do/suspend").status_code == 403
    assert any(x["code"] == code for x in carrier.get("/api/r/line", params={"q": code}).json()["rows"])


def test_four_eyes_actions_refuse_the_author(admin, all_on):
    spec = {c["name"]: c for c in admin.get("/api/r/entry-rule/_spec").json()["form"]}
    body = {"country_code": "LB", "label": f"Test rule {uuid.uuid4().hex[:6]}", "version": secrets.randbelow(10 ** 6) + 1000}
    for name, col in spec.items():
        if col["required"] and name not in body:
            if col["choices"]:
                body[name] = col["choices"][0]
            elif col["type"] in ("jsonb", "json"):
                body[name] = {}
            elif col["type"] in ("bigint", "integer", "smallint", "numeric"):
                body[name] = 1
            elif col["type"] == "boolean":
                body[name] = False
            else:
                body[name] = "X"
    r = admin.post("/api/r/entry-rule", json=body)
    assert r.status_code == 201, r.text
    assert r.json()["status"] == "DRAFT"
    r = admin.post(f"/api/r/entry-rule/{r.json()['_key']}/do/approve")
    assert r.status_code == 409 and r.json()["error"]["code"] == "FOUR_EYES"


def test_dashboard_specs_name_real_resources():
    from app.modular import dashboards
    assert dashboards.check() == []


@pytest.mark.parametrize("who", ["admin", "carrier", "agency", "passenger"])
def test_every_module_dashboard_answers_for_its_portals(request, who, all_on):
    client = request.getfixturevalue(who)
    for m in client.get("/api/modules").json()["modules"]:
        r = client.get(f"/api/m/{m['key']}/dashboard")
        assert r.status_code == 200, (m["key"], r.text)
        d = r.json()
        visible = {x["key"] for x in m["resources"]}
        assert {t["res"] for t in d["tiles"]} <= visible
        if d["trend"]:
            assert len(d["trend"]["points"]) == 30


def test_dashboards_follow_portals_and_switches(admin, carrier, agency, all_on):
    assert agency.get("/api/m/approved_lines/dashboard").status_code == 404      # not an agency module
    switch(admin, "rail", False)
    try:
        time.sleep(CACHE_SECONDS)
        r = carrier.get("/api/m/rail/dashboard")
        assert r.status_code == 404 and r.json()["error"]["code"] == "MODULE_DISABLED"
    finally:
        switch(admin, "rail", True)
        time.sleep(CACHE_SECONDS)
