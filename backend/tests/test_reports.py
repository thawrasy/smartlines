"""Reports: the catalog per portal, previews, the five export formats, custom reports and scheduled delivery.

What must never happen: a company seeing another company's rows, the regulator seeing personal data, a column or
operator that is not in the dataset reaching SQL, or an export that is not logged.
"""
import csv
import hashlib
import io
import json
import os
import subprocess
import sys
import zipfile

import pytest

from test_e2e import OWNER_URL, login, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
PERIOD = {"from": "2026-01-01", "to": "2026-12-31"}
AR = json.load(open(os.path.join(os.path.dirname(__file__), "..", "app", "i18n", "ar.json"), encoding="utf-8"))["reports"]


@pytest.fixture(scope="module")
def admin():
    return login("admin@masslak.test", "PLATFORM")


@pytest.fixture(scope="module")
def owner():
    return login("owner@carrier.test", "OPERATOR")


@pytest.fixture(scope="module")
def agency():
    return login("agency@agency.test", "AGENCY")


@pytest.fixture(scope="module")
def regulator():
    return login("regulator@masslak.test", "PLATFORM")


def codes(c):
    r = c.get("/api/reports/catalog")
    assert r.status_code == 200, r.text
    return r.json()


def test_catalog_depends_on_portal(admin, owner, agency, passenger_client):
    a, o, g = codes(admin), codes(owner), codes(agency)
    a_codes, o_codes, g_codes = {r["code"] for r in a["reports"]}, {r["code"] for r in o["reports"]}, {r["code"] for r in g["reports"]}
    assert {"sales.daily", "fin.payments", "sec.failed_sign_ins", "plat.companies"} <= a_codes
    assert "ops.load_factor" in o_codes and "fin.payments" not in o_codes and "sales.by_carrier" not in o_codes
    assert {"sales.bookings", "sales.agency", "fin.wallet_movements"} <= g_codes and "ops.load_factor" not in g_codes
    assert a["can_custom"] and {d["key"] for d in a["datasets"]} >= {"bookings", "trips", "payments"}
    assert "payments" not in {d["key"] for d in o["datasets"]}
    # titles come translated, every report has one
    assert all(r["title"] and r["title"] != r["code"] for r in a["reports"])
    assert passenger_client.get("/api/reports/catalog").status_code == 403


@pytest.fixture(scope="module")
def passenger_client():
    return login("passenger@masslak.test", "PASSENGER")


def test_preview_runs_every_catalog_report(admin):
    for r in codes(admin)["reports"]:
        res = admin.post("/api/reports/run", json={"code": r["code"], "params": PERIOD})
        assert res.status_code == 200, (r["code"], res.text)
        body = res.json()
        assert body["columns"] and isinstance(body["rows"], list), r["code"]


def test_company_sees_only_its_own_rows(owner):
    res = owner.post("/api/reports/run", json={"code": "ops.load_factor", "params": PERIOD}).json()
    carriers = {row["carrier"] for row in res["rows"]}
    assert len(carriers) <= 1, carriers
    company = owner_sql("SELECT company_id FROM iam.company_member m JOIN iam.app_user u ON u.id = m.user_id WHERE u.email = $1",
                        "owner@carrier.test")
    name = owner_sql("SELECT legal_name FROM iam.party WHERE id = $1", company)
    assert carriers <= {name}, (carriers, name)
    # a platform dataset is refused, and so is a column that is not in the dataset
    assert owner.post("/api/reports/run", json={"dataset": "payments", "spec": {"columns": ["amount"]}}).status_code == 403
    r = owner.post("/api/reports/run", json={"dataset": "trips", "spec": {"columns": ["trip_no", "1; DROP TABLE ops.trip"]}})
    assert r.status_code == 422 and r.json()["error"]["code"] == "REPORT_UNKNOWN_COLUMN"
    r = owner.post("/api/reports/run", json={"dataset": "trips", "spec": {"columns": ["trip_no"], "filters": [["trip_no", "union", "x"]]}})
    assert r.status_code == 422
    # filter values travel as parameters: quotes and percent signs are just text
    r = owner.post("/api/reports/run", json={"dataset": "trips", "spec": {"columns": ["trip_no"], "filters": [["trip_no", "contains", "'%_\\"]]},
                                             "params": PERIOD})
    assert r.status_code == 200 and r.json()["rows"] == []


def test_regulator_sees_grouped_figures_without_personal_data(regulator):
    cat = codes(regulator)
    assert cat["reports"] and all(r["aggregate"] for r in cat["reports"])
    assert regulator.post("/api/reports/run", json={"code": "sales.bookings", "params": PERIOD}).status_code == 404
    assert regulator.post("/api/reports/run", json={"code": "sales.by_route", "params": PERIOD}).status_code == 200


def test_exports_in_five_formats_are_logged(admin):
    before = owner_sql("SELECT count(*) FROM rpt.report_run")
    for fmt in ("PDF", "XLSX", "CSV", "TXT", "JSON"):
        r = admin.post("/api/reports/export", json={"code": "ops.load_factor", "format": fmt, "params": PERIOD, "locale": "ar"})
        assert r.status_code == 200, (fmt, r.text)
        data = r.content
        assert r.headers["x-report-sha256"] == hashlib.sha256(data).hexdigest()
        assert "attachment" in r.headers["content-disposition"]
        if fmt == "PDF":
            assert data.startswith(b"%PDF")
        elif fmt == "XLSX":
            z = zipfile.ZipFile(io.BytesIO(data))
            sheet = z.read("xl/worksheets/sheet1.xml").decode()
            assert 'rightToLeft="1"' in sheet
        elif fmt == "CSV":
            assert data.startswith(b"\xef\xbb\xbf")
            rows = list(csv.reader(io.StringIO(data.decode("utf-8-sig"))))
            assert rows[0][0] == AR["columns"]["trip_no"]           # translated heading
        elif fmt == "TXT":
            assert data.decode().split("\n")[0].split("\t")[0] == "trip_no"     # stable keys for other systems
        else:
            doc = json.loads(data)
            assert doc["report"] == "ops.load_factor" and doc["columns"][0]["key"] == "trip_no"
    after = owner_sql("SELECT count(*) FROM rpt.report_run")
    assert after - before == 5
    last = owner_sql("SELECT format, sha256 IS NOT NULL AS digest FROM rpt.report_run ORDER BY id DESC LIMIT 1", fetch=True)
    assert last["format"] == "JSON" and last["digest"]
    # the export log cannot be rewritten
    with pytest.raises(Exception):
        owner_sql("UPDATE rpt.report_run SET row_count = 0 WHERE id = (SELECT max(id) FROM rpt.report_run)")


def test_custom_report_saved_shared_and_isolated(owner, agency, admin):
    spec = {"group_by": ["origin_city", "dest_city"], "totals": [["count", "*"], ["sum", "seats_sold"], ["sum", "revenue"]],
            "sort": [["sum__revenue", "desc"]]}
    r = owner.post("/api/reports/definitions", json={"name": "Revenue by route", "dataset": "trips", "spec": spec, "shared": True})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    run = owner.post("/api/reports/run", json={"definition": uid, "params": PERIOD})
    assert run.status_code == 200 and [c["key"] for c in run.json()["columns"]][:2] == ["origin_city", "dest_city"]
    assert uid in {s["uid"] for s in codes(owner)["saved"]}
    # another company and the platform do not see it as theirs
    assert uid not in {s["uid"] for s in codes(agency)["saved"]}
    assert agency.post("/api/reports/run", json={"definition": uid}).status_code == 404
    # an invalid spec is refused before it is saved
    bad = owner.post("/api/reports/definitions", json={"name": "Bad", "dataset": "trips", "spec": {"columns": ["nope"]}})
    assert bad.status_code == 422
    x = owner.post("/api/reports/export", json={"definition": uid, "format": "XLSX", "params": PERIOD})
    assert x.status_code == 200 and x.content[:2] == b"PK"
    assert owner.delete(f"/api/reports/definitions/{uid}").status_code == 200
    assert uid not in {s["uid"] for s in codes(owner)["saved"]}


def test_scheduled_report_is_delivered_with_the_owner_rights(admin):
    r = admin.post("/api/reports/schedules", json={"code": "sales.daily", "frequency": "DAILY", "format": "XLSX", "locale": "ar",
                                                   "recipients": ["finance-team@masslak.com"]})
    assert r.status_code == 201, r.text
    uid = r.json()["uid"]
    assert uid in {s["uid"] for s in admin.get("/api/reports/schedules").json()["schedules"]}
    owner_sql("UPDATE rpt.report_schedule SET next_run_at = now() - interval '1 minute' WHERE uid = $1::uuid", uid)
    env = {**os.environ}
    out = subprocess.run([sys.executable, "-m", "app.modules.notify.worker", "--once"], cwd=os.path.join(os.path.dirname(__file__), ".."),
                         env=env, capture_output=True, text=True, timeout=120)
    assert out.returncode == 0, out.stderr[-2000:]
    sent = owner_sql("""SELECT r.format, r.row_count FROM rpt.report_run r WHERE r.params ->> 'schedule' = $1""", uid, fetch=True)
    assert sent and sent["format"] == "XLSX", out.stderr[-1500:]
    row = owner_sql("SELECT next_run_at > now() AS later, last_run_at IS NOT NULL AS ran FROM rpt.report_schedule WHERE uid = $1::uuid",
                    uid, fetch=True)
    assert row["later"] and row["ran"]
    assert admin.delete(f"/api/reports/schedules/{uid}").status_code == 200
