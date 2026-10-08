#!/usr/bin/env python3
"""Launch gate checker (docs/operations/LAUNCH_GATES.md; expert review of October 2026, stage B).

Reads the evidence files in docs/operations/evidence and judges each gate against its success criterion, so the
go/no-go meeting reads one table instead of nine reports. A gate counts as met only by evidence from staging or
production (egress: production); a development run shows as "development only", never as passed. The approver still
signs the register: this tool checks the evidence, it does not decide.

    python3 db/tools/launch_gates.py check [--evidence DIR] [--json]
    python3 db/tools/launch_gates.py template <gate>      a skeleton for the gates people run by hand (5 to 8)

Evidence files are named by their gate (restore_*, egress_*, burst_*, soak_*, load_*, migration_rehearsal_*,
alert_drill_*, audit_archive_*, file_scanning_*, pentest_*). Each may say "environment": "development", "staging" or
"production"; a file that does not, and has neither word in its name, counts as development.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EVIDENCE = os.path.join(ROOT, "docs", "operations", "evidence")
RPO_S, RTO_S = 60, 30 * 60                       # owner decision of 8 October 2026 (recovery.rpo_seconds, rto_minutes)
CAPACITY_RATES = {"1x": 240, "2x": 480, "5x": 1200}    # bookings a second at the launch burst, twice and five times it

GATES = {
    1: ("Recovery", ("restore_",)),
    2: ("Egress", ("egress_",)),
    3: ("Capacity", ("burst_", "soak_", "load_")),
    4: ("Migrations", ("migration_rehearsal_",)),
    5: ("Monitoring", ("alert_drill_",)),
    6: ("Audit archive", ("audit_archive_",)),
    7: ("File scanning", ("file_scanning_",)),
    8: ("Security testing", ("pentest_",)),
    9: ("AI and contact centre", ()),
}

TEMPLATES = {
    5: {"gate": 5, "environment": "staging", "date": "YYYY-MM-DD", "commit": "", "alert": "BookingLatencyHigh",
        "how_triggered": "", "fired_at": "", "acknowledged_at": "", "ack_minutes": None, "on_call": "",
        "runbook_followed": False, "notes": ""},
    6: {"gate": 6, "environment": "production", "date": "YYYY-MM-DD", "commit": "", "bucket": "", "object_lock_mode": "COMPLIANCE",
        "export_ok": False, "signature_verified": False, "chain_verified": False, "retrieved_past_export_verified": False,
        "chain_tip": "", "custodian_receipt": "", "notes": ""},
    7: {"gate": 7, "environment": "staging", "date": "YYYY-MM-DD", "commit": "", "clean_served": False, "eicar_refused": False,
        "scanner_down_refused": False, "only_clean_served": False, "backlog_alert_seen": False, "notes": ""},
    8: {"gate": 8, "environment": "production", "date": "YYYY-MM-DD", "firm": "", "report_ref": "", "retest_ref": "",
        "findings": [{"id": "F-01", "severity": "HIGH", "title": "", "status": "OPEN | FIXED_RETESTED | ACCEPTED",
                      "accepted_reason": "", "accepted_on": "", "accepted_by": ""}]},
}


def environment(path: str, doc) -> str:
    env = doc.get("environment") if isinstance(doc, dict) else None
    name = os.path.basename(path).lower()
    if env in ("development", "staging", "production"):
        return env
    if "production" in name:
        return "production"
    if "staging" in name:
        return "staging"
    return "development"


def load(path: str):
    with open(path, encoding="utf-8") as fh:
        if path.endswith(".json"):
            return json.load(fh)
        return {"text": fh.read()}


# ------------------------------------------------------------------ the success criteria (LAUNCH_GATES.md, column 4)
def recovery(doc) -> list[str]:
    out = []
    latest = doc.get("latest") or {}
    if doc.get("result") != "PASS":
        out.append("the drill did not pass")
    if (latest.get("rpo_measured_s") or 1e9) > RPO_S:
        out.append(f"data lost {latest.get('rpo_measured_s')} s, over the RPO of {RPO_S} s")
    if (latest.get("rto_measured_s") or 1e9) > RTO_S:
        out.append(f"usable after {latest.get('rto_measured_s')} s, over the RTO of {RTO_S} s")
    if not all(v for k, v in (latest.get("checks") or {}).items() if isinstance(v, bool)) or not latest.get("checks"):
        out.append("a post-restore check failed (wallets, orphans, audit seals, ledger)")
    if not latest.get("schema_matches_source"):
        out.append("the restored schema differs from the source")
    return out


def egress(doc) -> list[str]:
    text = doc.get("text") or json.dumps(doc)
    out = [] if "egress proxy: all probes passed" in text or doc.get("result") == "PASS" else ["the proxy self-test did not pass"]
    if doc.get("direct_route_blocked") is False or ("reached the internet" in text):
        out.append("a container reached the internet without the proxy")
    return out


def migrations(doc) -> list[str]:
    out = []
    if not doc.get("migration_ok"):
        out.append("the migration failed")
    if not doc.get("within_criteria"):
        out.append("locks, WAL or time outside MIGRATION_PLANS.md")
    return out


def monitoring(doc) -> list[str]:
    out = []
    if doc.get("ack_minutes") is None or doc["ack_minutes"] > 15:
        out.append("no acknowledgement within 15 minutes recorded")
    if not doc.get("runbook_followed"):
        out.append("the named runbook was not followed")
    return out


def audit_archive(doc) -> list[str]:
    need = ("export_ok", "signature_verified", "chain_verified", "retrieved_past_export_verified")
    out = [f"{k} is not true" for k in need if doc.get(k) is not True]
    if not doc.get("custodian_receipt"):
        out.append("no custodian receipt of the chain tip")
    return out


def file_scanning(doc) -> list[str]:
    need = ("clean_served", "eicar_refused", "scanner_down_refused", "only_clean_served")
    return [f"{k} is not true" for k in need if doc.get(k) is not True]


def pentest(doc) -> list[str]:
    out = []
    if not doc.get("report_ref"):
        out.append("no report reference")
    for f in doc.get("findings") or []:
        if str(f.get("severity", "")).upper() in ("CRITICAL", "HIGH"):
            if f.get("status") == "FIXED_RETESTED":
                continue
            if f.get("status") == "ACCEPTED" and f.get("accepted_reason") and f.get("accepted_on") and f.get("accepted_by"):
                continue
            out.append(f"{f.get('id')} ({f.get('severity')}) is neither fixed and retested nor accepted with a dated reason")
    return out


CRITERIA = {1: recovery, 2: egress, 4: migrations, 5: monitoring, 6: audit_archive, 7: file_scanning, 8: pentest}


def capacity(files: list[tuple[str, str, dict]]) -> tuple[str, list[str], list[str]]:
    """Gate 3 needs, from staging: the burst passing at 1x and 2x, a 5x run recorded, and a soak of 8 hours passing."""
    staging = [(p, d) for p, env, d in files if env in ("staging", "production")]
    used, missing = [], []
    for label, rate in CAPACITY_RATES.items():
        runs = [(p, d) for p, d in staging if os.path.basename(p).startswith("burst_")
                and float(d.get("target_per_second") or 0) >= rate]
        if label == "5x":
            ok = runs
        else:
            ok = [(p, d) for p, d in runs if (d.get("verdict") or {}).get("status") == "PASS"]
        if ok:
            used.append(os.path.basename(ok[-1][0]))
        else:
            missing.append(f"burst at {rate}/s ({label}) {'recorded' if label == '5x' else 'passing'} on staging")
    soaks = [(p, d) for p, d in staging if os.path.basename(p).startswith("soak_")
             and (d.get("verdict") or {}).get("status") == "PASS" and float(d.get("duration_s") or 0) >= 8 * 3600]
    if soaks:
        used.append(os.path.basename(soaks[-1][0]))
    else:
        missing.append("a soak of at least 8 hours passing on staging")
    if not missing:
        return "Passed", used, []
    dev = [os.path.basename(p) for p, env, _ in files if env == "development"]
    return ("Development only" if dev and not staging else "Open"), used or dev, missing


def check(evidence_dir: str) -> list[dict]:
    paths = sorted(glob.glob(os.path.join(evidence_dir, "*")))
    rows = []
    for gate, (name, prefixes) in GATES.items():
        if gate == 9:
            rows.append({"gate": 9, "name": name, "status": "Not applicable yet", "evidence": [],
                         "reasons": ["the phase stays closed; the database refuses to open it without an approved DPIA (1055)"]})
            continue
        files = []
        for p in paths:
            base = os.path.basename(p)
            if base.startswith(prefixes) and os.path.isfile(p):
                try:
                    doc = load(p)
                except (OSError, ValueError):
                    continue
                files.append((p, environment(p, doc), doc))
        if gate == 3:
            status, used, reasons = capacity(files)
            rows.append({"gate": 3, "name": name, "status": status, "evidence": used, "reasons": reasons})
            continue
        needed_env = ("production",) if gate in (2,) else ("staging", "production")
        best = None
        for p, env, doc in files:
            problems = CRITERIA[gate](doc) if isinstance(doc, dict) else ["unreadable"]
            if env in needed_env and not problems:
                best = ("Passed", [os.path.basename(p)], [])
            elif env in needed_env and (best is None or best[0] != "Passed"):
                best = ("Failed", [os.path.basename(p)], problems)
            elif best is None or best[0] == "Development only":
                best = ("Development only", [os.path.basename(p)],
                        [f"evidence from {env}; the gate needs {' or '.join(needed_env)}"] + problems)
        rows.append({"gate": gate, "name": name, **dict(zip(("status", "evidence", "reasons"),
                                                            best or ("Open", [], ["no evidence yet"])))})
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(prog="launch_gates.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("check")
    c.add_argument("--evidence", default=EVIDENCE)
    c.add_argument("--json", action="store_true")
    t = sub.add_parser("template")
    t.add_argument("gate", type=int, choices=sorted(TEMPLATES))
    args = ap.parse_args()
    if args.cmd == "template":
        print(json.dumps(TEMPLATES[args.gate], indent=1))
        return 0
    rows = check(args.evidence)
    if args.json:
        print(json.dumps(rows, indent=1))
    else:
        for r in rows:
            print(f"{r['gate']}  {r['name']:22} {r['status']:20} {', '.join(r['evidence']) or '-'}")
            for why in r["reasons"]:
                print(f"{'':27}- {why}")
    general_launch = all(r["status"] == "Passed" for r in rows if r["gate"] != 9)
    print(f"\ngeneral launch: {'all gates 1-8 passed (the approvers sign the register)' if general_launch else 'not yet'}")
    return 0 if general_launch else 1


if __name__ == "__main__":
    sys.exit(main())
