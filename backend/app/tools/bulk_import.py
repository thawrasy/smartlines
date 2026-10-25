"""Bulk import of the initial data load from CSV files, through the API (use case review, gap 6).

Every row goes through the same API a clerk uses, so every business rule, permission and audit record applies; the
tool never writes to the database. Each run writes a report with one line per row, and a row already present is
reported as EXISTS rather than created twice, so a file can be sent again after fixing the rows that failed.

    export MASSLAK_IMPORT_PASSWORD=...            # never on the command line
    python -m app.tools.bulk_import --base https://masslak.example --email ops@carrier.sy KIND file.csv [--dry-run]
    python -m app.tools.bulk_import --template KIND        # the CSV header of a kind, required columns first

Kinds (load them in this order; the platform's stations and reference data come first, see docs/operations/INITIAL_DATA_LOAD.md):
    routes      one row per stop: code, seq, station_code, arr_offset_min, dep_offset_min, fare_from_origin [, network_route];
                the code groups the rows of one route; on a route of the network (its code in network_route, required
                while the platform keeps carriers to its routes) the system sets the route's code, given in the report
    vehicles    plate_no, chassis_no, insurance_no, insurer, insurance_issue, insurance_expiry [, vehicle_type, make,
                model, manufacture_year, passenger_seats, seat_layout (its name)]
    drivers     full_name, email [, password, mobile, license_class]; a driver without a password gets a generated one,
                written only to the credentials file (mode 0600) named by --credentials
    trips       route_code, plate_no, driver_email, departure_local (YYYY-MM-DDTHH:MM, the market's local time)
    resource:<key>  any record the generic screens can create (GET /api/r/<key>/_spec lists its fields); a column named
                <field>@lookup is resolved through /api/r/<key>/lookup/<field> by the label the screens show for the
                record it points to (its code where it has one, else its name), which must match exactly one record

Sign-in: the portal (--portal, OPERATOR by default) may ask for a second factor; the code is read from
MASSLAK_IMPORT_OTP or asked for. Exit status: 0 every row created or present, 2 some rows invalid or failed, 1 the run
could not start.
"""
from __future__ import annotations

import argparse
import csv
import getpass
import os
import secrets
import sys
import time
from dataclasses import dataclass, field
from datetime import date
from typing import Callable, Optional

import httpx

CLIENT = {"X-Masslak-Client": "web"}


@dataclass
class Kind:
    path: str                                  # where a row is created
    required: tuple
    optional: tuple = ()
    list_path: Optional[str] = None            # where existing records are listed, to report EXISTS
    list_key: str = ""
    key: Optional[str] = None                  # the column that identifies a record already present
    ints: tuple = ()
    dates: tuple = ()


KINDS = {
    "vehicles": Kind("/api/carrier/vehicles", ("plate_no", "chassis_no", "insurance_no", "insurer", "insurance_issue", "insurance_expiry"),
                     ("vehicle_type", "make", "model", "manufacture_year", "passenger_seats", "seat_layout"),
                     "/api/carrier/vehicles", "vehicles", "plate_no", ints=("manufacture_year", "passenger_seats"),
                     dates=("insurance_issue", "insurance_expiry")),
    "drivers": Kind("/api/carrier/crew", ("full_name", "email"), ("password", "mobile", "license_class"), "/api/carrier/crew", "crew", "email"),
    "routes": Kind("/api/carrier/routes", ("code", "seq", "station_code", "arr_offset_min", "dep_offset_min", "fare_from_origin"), ("network_route",),
                   "/api/carrier/routes", "routes", "code", ints=("seq", "arr_offset_min", "dep_offset_min", "fare_from_origin")),
    "trips": Kind("/api/carrier/trips", ("route_code", "plate_no", "driver_email", "departure_local")),
}


@dataclass
class Outcome:
    row: int
    key: str
    status: str                                # CREATED, EXISTS, WOULD_CREATE, INVALID, FAILED
    uid: str = ""
    code: str = ""
    message: str = ""


@dataclass
class Session:
    http: httpx.Client
    pause: Callable[[float], None] = time.sleep
    cache: dict = field(default_factory=dict)

    def call(self, method: str, path: str, **kw) -> httpx.Response:
        """One request, waiting out rate limits and a busy server (it answers 429 or 503 with Retry-After)."""
        for attempt in range(6):
            r = self.http.request(method, path, **kw)
            if r.status_code not in (429, 503) or attempt == 5:
                return r
            self.pause(min(float(r.headers.get("Retry-After", 2 ** attempt)), 30))
        return r

    def listing(self, path: str, key: str) -> list[dict]:
        if path not in self.cache:
            r = self.call("GET", path)
            r.raise_for_status()
            self.cache[path] = r.json()[key]
        return self.cache[path]


def sign_in(base: str, email: str, portal: str, password: str, otp: Callable[[], str], verify) -> Session:
    http = httpx.Client(base_url=base.rstrip("/"), headers=CLIENT, timeout=30, verify=verify)
    r = http.post("/api/auth/login", json={"identifier": email, "password": password, "portal": portal})
    if r.status_code != 200:
        raise SystemExit(f"sign-in refused: {r.status_code} {r.text[:200]}")
    step = r.json().get("mfa")
    if step == "ENROLL":
        raise SystemExit("this account must set up two-step sign-in in the portal before importing")
    if step == "VERIFY":
        v = http.post("/api/auth/mfa/verify", json={"code": otp().strip()})
        if v.status_code != 200 or not v.json().get("ok"):
            raise SystemExit("the second-factor code was not accepted")
    return Session(http)


def _error(r: httpx.Response) -> tuple[str, str]:
    try:
        e = r.json().get("error", {})
        return e.get("code", str(r.status_code)), e.get("message", "")[:300]
    except ValueError:
        return str(r.status_code), r.text[:300]


def _typed(kind: Kind, row: dict) -> tuple[dict, Optional[str]]:
    """The row's non-empty values with numbers and dates checked; the first problem, if any."""
    missing = [c for c in kind.required if not (row.get(c) or "").strip()]
    if missing:
        return {}, f"missing {', '.join(missing)}"
    out = {}
    for c, v in row.items():
        v = (v or "").strip()
        if not c or not v:
            continue
        try:
            if c in kind.ints:
                out[c] = int(v)
            elif c in kind.dates:
                out[c] = date.fromisoformat(v).isoformat()
            else:
                out[c] = v
        except ValueError:
            return {}, f"{c}: {v!r} is not a valid {'number' if c in kind.ints else 'date (YYYY-MM-DD)'}"
    return out, None


def _find(items: list[dict], column: str, value: str, field_name: str = "uid") -> Optional[str]:
    hit = next((x for x in items if str(x.get(column, "")).casefold() == value.casefold()), None)
    return str(hit[field_name]) if hit else None


def _body(s: Session, kind_name: str, values: dict, generated: dict) -> tuple[Optional[dict], Optional[str]]:
    """The API body of a row, with codes and names resolved to the ids the API takes."""
    if kind_name == "vehicles":
        body = {k: v for k, v in values.items() if k != "seat_layout"}
        if "seat_layout" in values:
            uid = _find(s.listing("/api/carrier/seat-layouts", "layouts"), "name", values["seat_layout"])
            if not uid:
                return None, f"seat layout {values['seat_layout']!r} not found"
            body["seat_layout_uid"] = uid
        return body, None
    if kind_name == "drivers":
        body = dict(values)
        if "password" not in body:
            body["password"] = generated[values["email"]] = "Ms-" + secrets.token_urlsafe(18)
        return body, None
    if kind_name == "trips":
        route = _find(s.listing("/api/carrier/routes", "routes"), "code", values["route_code"])
        vehicle = _find(s.listing("/api/carrier/vehicles", "vehicles"), "plate_no", values["plate_no"])
        driver = _find(s.listing("/api/carrier/crew", "crew"), "email", values["driver_email"])
        for what, found, name in (("route", route, values["route_code"]), ("vehicle", vehicle, values["plate_no"]),
                                  ("driver", driver, values["driver_email"])):
            if not found:
                return None, f"{what} {name!r} not found"
        return {"route_uid": route, "vehicle_uid": vehicle, "driver_uid": driver, "departure_local": values["departure_local"]}, None
    raise ValueError(kind_name)


def run_rows(s: Session, kind_name: str, rows: list[dict], dry_run: bool, generated: dict) -> list[Outcome]:
    kind = KINDS[kind_name]
    present = {str(x.get(kind.key, "")).casefold() for x in s.listing(kind.list_path, kind.list_key)} if kind.key else set()
    out = []
    for i, row in enumerate(rows, start=2):                 # line 1 is the header
        values, problem = _typed(kind, row)
        key = str(values.get(kind.key) or row.get(kind.key or "", "") or "") if kind.key else ""
        if problem:
            out.append(Outcome(i, key, "INVALID", message=problem))
            continue
        if kind.key and key.casefold() in present:
            out.append(Outcome(i, key, "EXISTS"))
            continue
        body, problem = _body(s, kind_name, values, generated)
        if problem:
            out.append(Outcome(i, key, "INVALID", message=problem))
            continue
        if dry_run:
            out.append(Outcome(i, key, "WOULD_CREATE"))
            present.add(key.casefold())
            continue
        r = s.call("POST", kind.path, json=body)
        if r.status_code in (200, 201):
            out.append(Outcome(i, key, "CREATED", uid=str(r.json().get("uid", ""))))
            present.add(key.casefold())
            for path in list(s.cache):                       # later rows may refer to what was just created
                s.cache.pop(path)
        else:
            code, message = _error(r)
            out.append(Outcome(i, key, "EXISTS" if code == "ALREADY_EXISTS" else "FAILED", code=code, message=message))
    return out


def run_routes(s: Session, rows: list[dict], dry_run: bool) -> list[Outcome]:
    """Routes come one stop per row; the rows of a code make one route, in the order of seq. On a route of the network
    (1163) the system sets the code; a route already defined on the same network route with the same stations is
    reported as EXISTS."""
    kind = KINDS["routes"]
    listed = s.listing(kind.list_path, kind.list_key)
    present = {str(x["code"]).casefold() for x in listed}
    served = {(x.get("network_route_code"), tuple(st["station_code"] for st in x.get("stops", []))) for x in listed if x.get("network_route_code")}
    stations = s.listing("/api/carrier/stations", "stations")
    network = None
    groups: dict[str, list[tuple[int, dict]]] = {}
    out = []
    for i, row in enumerate(rows, start=2):
        values, problem = _typed(kind, row)
        if problem:
            out.append(Outcome(i, (row.get("code") or "").strip(), "INVALID", message=problem))
            continue
        groups.setdefault(values["code"], []).append((i, values))
    for code, stops in groups.items():
        first = stops[0][0]
        ordered = [v for _, v in sorted(stops, key=lambda x: x[1]["seq"])]
        net_code = (ordered[0].get("network_route") or "").strip().upper()
        if (net_code and (net_code, tuple(v["station_code"] for v in ordered)) in served) or (not net_code and code.casefold() in present):
            out.append(Outcome(first, code, "EXISTS"))
            continue
        body, problem = {"code": code, "stops": []}, None
        if net_code:
            if network is None:
                network = s.listing("/api/network/routes", "routes")
            body = {"network_route_uid": _find(network, "code", net_code), "stops": []}
            if not body["network_route_uid"]:
                problem = f"route of the network {net_code!r} not found or not in effect"
        for v in ordered:
            if problem:
                break
            uid = _find(stations, "code", v["station_code"])
            if not uid:
                problem = f"station {v['station_code']!r} not found or not usable by this carrier"
                break
            body["stops"].append({"station_uid": uid, "arr_offset_min": v["arr_offset_min"], "dep_offset_min": v["dep_offset_min"],
                                  "fare_from_origin": v["fare_from_origin"]})
        if problem:
            out.append(Outcome(first, code, "INVALID", message=problem))
        elif dry_run:
            out.append(Outcome(first, code, "WOULD_CREATE"))
        else:
            r = s.call("POST", kind.path, json=body)
            if r.status_code in (200, 201):
                made = r.json()
                out.append(Outcome(first, code, "CREATED", uid=str(made.get("uid", "")),
                                   message=f"route code {made['code']}" if made.get("code") and made["code"] != code else ""))
            else:
                c, m = _error(r)
                out.append(Outcome(first, code, "EXISTS" if c == "ALREADY_EXISTS" else "FAILED", code=c, message=m))
    return out


def run_resource(s: Session, key: str, rows: list[dict], dry_run: bool) -> list[Outcome]:
    """Any generic record: the columns are the form's fields; <field>@lookup columns are resolved by label."""
    r = s.call("GET", f"/api/r/{key}/_spec")
    if r.status_code != 200:
        raise SystemExit(f"resource {key!r} is not available to this account: {r.status_code} {r.text[:200]}")
    spec = r.json()
    form = {f["name"] if isinstance(f, dict) else f for f in spec.get("form", [])}
    out = []
    for i, row in enumerate(rows, start=2):
        body, problem = {}, None
        for col, raw in row.items():
            value = (raw or "").strip()
            if not col or value == "":
                continue
            name, _, how = col.partition("@")
            if name not in form:
                problem = f"{name} is not a field of {key}"
                break
            if how == "lookup":
                found = s.call("GET", f"/api/r/{key}/lookup/{name}", params={"q": value})
                hits = [h for h in (found.json().get("options", []) if found.status_code == 200 else [])
                        if str(h.get("label", "")).casefold() == value.casefold()]
                if len(hits) != 1:
                    problem = f"{name}: {value!r} matches {len(hits)} records"
                    break
                body[name] = hits[0]["id"]
            else:
                body[name] = value
        if problem:
            out.append(Outcome(i, "", "INVALID", message=problem))
            continue
        if dry_run:
            out.append(Outcome(i, "", "WOULD_CREATE"))
            continue
        r = s.call("POST", f"/api/r/{key}", json=body)
        if r.status_code in (200, 201):
            created = r.json()
            out.append(Outcome(i, "", "CREATED", uid=str(created.get("_key", created.get("uid", "")))))
        else:
            c, m = _error(r)
            out.append(Outcome(i, "", "EXISTS" if c == "ALREADY_EXISTS" else "FAILED", code=c, message=m))
    return out


def template(kind_name: str) -> str:
    k = KINDS[kind_name]
    return ",".join(k.required + k.optional)


def main(argv: Optional[list[str]] = None) -> int:
    p = argparse.ArgumentParser(prog="python -m app.tools.bulk_import", description=__doc__.split("\n\n")[0])
    p.add_argument("kind", nargs="?", help="vehicles, drivers, routes, trips or resource:<key>")
    p.add_argument("file", nargs="?", help="the CSV file (UTF-8, with a header line)")
    p.add_argument("--template", metavar="KIND", help="print the CSV header of a kind and stop")
    p.add_argument("--base", default=os.environ.get("MASSLAK_IMPORT_URL", "http://localhost:8000"))
    p.add_argument("--email", default=os.environ.get("MASSLAK_IMPORT_EMAIL"))
    p.add_argument("--portal", default="OPERATOR", choices=["OPERATOR", "PLATFORM", "AGENCY", "STATION"])
    p.add_argument("--dry-run", action="store_true", help="check every row and report, without creating anything")
    p.add_argument("--report", help="the report file (CSV); default: <file>.report.csv")
    p.add_argument("--credentials", help="where generated driver passwords are written (mode 0600); default: <file>.credentials.csv")
    p.add_argument("--ca", help="a CA bundle for the server's certificate")
    a = p.parse_args(argv)
    if a.template:
        print(template(a.template))
        return 0
    if not a.kind or not a.file or not a.email:
        p.error("KIND, FILE and --email (or MASSLAK_IMPORT_EMAIL) are needed")
    if a.kind not in KINDS and not a.kind.startswith("resource:"):
        p.error(f"unknown kind {a.kind!r}")
    with open(a.file, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    password = os.environ.get("MASSLAK_IMPORT_PASSWORD") or getpass.getpass("password: ")
    s = sign_in(a.base, a.email, a.portal, password, lambda: os.environ.get("MASSLAK_IMPORT_OTP") or input("second-factor code: "),
                a.ca or True)
    generated: dict[str, str] = {}
    if a.kind == "routes":
        outcomes = run_routes(s, rows, a.dry_run)
    elif a.kind.startswith("resource:"):
        outcomes = run_resource(s, a.kind.split(":", 1)[1], rows, a.dry_run)
    else:
        outcomes = run_rows(s, a.kind, rows, a.dry_run, generated)
    report = a.report or f"{a.file}.report.csv"
    with open(report, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["row", "key", "status", "uid", "code", "message"])
        for o in sorted(outcomes, key=lambda o: o.row):
            w.writerow([o.row, o.key, o.status, o.uid, o.code, o.message])
    if generated and not a.dry_run:
        path = a.credentials or f"{a.file}.credentials.csv"
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", newline="", encoding="utf-8") as f:
            w = csv.writer(f)
            w.writerow(["email", "password"])
            w.writerows(generated.items())
        print(f"generated passwords: {path} (give each driver theirs, then delete the file)")
    counts: dict[str, int] = {}
    for o in outcomes:
        counts[o.status] = counts.get(o.status, 0) + 1
    print(f"{a.kind}: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items())) + f"; report: {report}")
    return 2 if counts.get("INVALID") or counts.get("FAILED") else 0


if __name__ == "__main__":
    sys.exit(main())
