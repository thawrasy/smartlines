"""The bulk import tool for the initial data load (use case review, gap 6): every row through the API, a dry run that
creates nothing, a per-row report, rows already present reported as EXISTS on a second run, and generated driver
passwords written only to a private file."""
import csv
import os
import secrets
import stat

import pytest

from app.tools import bulk_import
from test_e2e import BASE, OWNER_URL, PASSWORD, day, login


def write(path, header, rows):
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerows(rows)
    return str(path)


def report(path):
    with open(f"{path}.report.csv", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def run(kind, path, email="owner@carrier.test", portal="OPERATOR", *extra):
    os.environ["MASSLAK_IMPORT_PASSWORD"] = PASSWORD
    return bulk_import.main([kind, path, "--base", BASE, "--email", email, "--portal", portal, *extra])


def test_template_lists_required_columns_first(capsys):
    assert bulk_import.main(["--template", "vehicles"]) == 0
    assert capsys.readouterr().out.strip().startswith("plate_no,chassis_no,insurance_no,insurer,insurance_issue,insurance_expiry")


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_initial_load_through_the_api(tmp_path):
    tag = str(secrets.randbelow(900000) + 100000)
    owner = login("owner@carrier.test", "OPERATOR")
    layout = next(x for x in owner.get("/api/carrier/seat-layouts").json()["layouts"] if x["total_seats"] == 44)["name"]
    vehicles = write(tmp_path / "vehicles.csv", bulk_import.template("vehicles").split(","), [
        [f"IMP{tag}1", f"CHS-IMP{tag}1", f"POL-{tag}1", "Test Insurer", "2026-01-01", "2030-01-01", "COACH", "", "", "", "", layout],
        [f"IMP{tag}2", f"CHS-IMP{tag}2", f"POL-{tag}2", "Test Insurer", "2026-01-01", "2030-01-01", "COACH", "", "", "2019", "", layout],
        [f"IMP{tag}3", f"CHS-IMP{tag}3", f"POL-{tag}3", "Test Insurer", "01/01/2026", "2030-01-01", "COACH", "", "", "", "", layout],
        [f"IMP{tag}4", f"CHS-IMP{tag}4", f"POL-{tag}4", "Test Insurer", "2020-01-01", "2021-01-01", "COACH", "", "", "", "", layout]])
    # a dry run checks every row and creates nothing
    assert run("vehicles", vehicles, "owner@carrier.test", "OPERATOR", "--dry-run") == 2
    assert [r["status"] for r in report(vehicles)] == ["WOULD_CREATE", "WOULD_CREATE", "INVALID", "WOULD_CREATE"]
    plates = {v["plate_no"] for v in owner.get("/api/carrier/vehicles").json()["vehicles"]}
    assert not plates & {f"IMP{tag}{i}" for i in range(1, 5)}
    # the real run: two created, the bad date refused before sending, the expired insurance refused by the server
    assert run("vehicles", vehicles) == 2
    rows = report(vehicles)
    assert [r["status"] for r in rows] == ["CREATED", "CREATED", "INVALID", "FAILED"]
    assert "insurance_issue" in rows[2]["message"] and rows[3]["code"] == "INSURANCE_EXPIRED" and rows[0]["uid"]
    # sent again: what is there is reported, nothing is doubled
    assert run("vehicles", vehicles) == 2
    assert [r["status"] for r in report(vehicles)][:2] == ["EXISTS", "EXISTS"]
    assert sum(v["plate_no"] == f"IMP{tag}1" for v in owner.get("/api/carrier/vehicles").json()["vehicles"]) == 1

    # drivers: one without a password gets a generated one, kept in a private file only
    drivers = write(tmp_path / "drivers.csv", ["full_name", "email", "password", "mobile", "license_class"],
                    [["Imported Driver", f"imp{tag}@example.com", "", "", "D"]])
    assert run("drivers", drivers) == 0
    creds = f"{drivers}.credentials.csv"
    assert stat.S_IMODE(os.stat(creds).st_mode) == 0o600
    with open(creds, encoding="utf-8") as f:
        generated = list(csv.DictReader(f))[0]
    assert generated["email"] == f"imp{tag}@example.com" and len(generated["password"]) > 20
    assert "password" not in open(f"{drivers}.report.csv", encoding="utf-8").read().split("\n", 1)[1]
    login(f"imp{tag}@example.com", "DRIVER", generated["password"])                       # the driver can sign in

    # a route, one stop per row, then a trip on it with the imported vehicle and driver
    code = f"IMP-{tag}"
    routes = write(tmp_path / "routes.csv", bulk_import.template("routes").split(","), [
        [code, 0, "SY-DAM-C001", 0, 0, 0], [code, 2, "SY-ALP-C001", 300, 300, 4000000], [code, 1, "SY-HMS-C001", 120, 135, 1800000]])
    assert run("routes", routes) == 0, report(routes)
    assert [r["status"] for r in report(routes)] == ["CREATED"]
    trips = write(tmp_path / "trips.csv", bulk_import.template("trips").split(","),
                  [[code, f"IMP{tag}1", f"imp{tag}@example.com", f"{day(3)}T08:17"], ["NO-SUCH", f"IMP{tag}1", f"imp{tag}@example.com", f"{day(3)}T09:00"]])
    assert run("trips", trips) == 2
    rows = report(trips)
    assert rows[0]["status"] == "CREATED", rows[0]
    assert rows[1]["status"] == "INVALID" and "route" in rows[1]["message"]


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_generic_records_with_lookups(tmp_path):
    tag = secrets.token_hex(3).upper()
    tiers = write(tmp_path / "tiers.csv", ["program_id@lookup", "code", "name", "min_points"],
                  [["MASSLAK-MILES", f"T{tag}", "Imported tier", "500"], ["No Such Programme", f"U{tag}", "Bad", "1"]])
    assert run("resource:loyalty-tier", tiers, "admin@masslak.test", "PLATFORM") == 2
    rows = report(tiers)
    assert rows[0]["status"] == "CREATED" and rows[1]["status"] == "INVALID" and "matches 0" in rows[1]["message"]
