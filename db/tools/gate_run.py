#!/usr/bin/env python3
"""Runs a launch gate and writes its evidence (docs/operations/LAUNCH_GATES.md, docs/operations/GATE_CLOSURE_PLAN.md).

One subcommand per gate. Each reads the environment and the release from the target database itself
(sys.setting deploy.environment, set by the migration from MASSLAK_ENVIRONMENT; sys.current_release()), so a run on a
development or trial server can never be filed as staging evidence, and every file names the commit it measured.
`db/tools/launch_gates.py check` then judges the files; the approver signs the register.

    python3 db/tools/gate_run.py recovery      --primary DSN --restored DSN --kill CMD [--restore CMD]   gate 1
    python3 db/tools/gate_run.py egress        --owner-dsn DSN --worker-exec CMD --api-exec CMD --allowed NAME  gate 2
    python3 db/tools/gate_run.py capacity      --owner-dsn DSN --base URL [--levels 1x,2x,5x] [--soak-hours 8] gate 3
    python3 db/tools/gate_run.py migrations    --owner-dsn DSN --base PREFIX [-- psql args]                   gate 4
    python3 db/tools/gate_run.py alert         --owner-dsn DSN --alertmanager URL --alert NAME --trigger CMD --restore CMD   gate 5
    python3 db/tools/gate_run.py audit-archive --owner-dsn DSN --dir DIR --public-key PEM [--bucket s3://...]  gate 6
    python3 db/tools/gate_run.py file-scanning --owner-dsn DSN --base URL --email E --password P --clamd-check CMD --stop-scanner CMD --start-scanner CMD  gate 7

DSNs are owner logins (postgresql://...); CMD is a shell command run on the operator's host (for example
`docker compose --env-file deploy/.env stop clamav`, or `ssh db-a1 sudo systemctl stop postgresql`). Gate 8 (the
external penetration test) and the approvals are filed by people: `launch_gates.py template 8`.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import uuid

import asyncpg

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EVIDENCE = os.path.join(ROOT, "docs", "operations", "evidence")
BACKEND = os.path.join(ROOT, "backend")
RPO_S, RTO_S = 60, 30 * 60
RATES = {"1x": 240, "2x": 480, "5x": 1200}
EICAR = b"X5O!P%@AP[4\\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*"


# ------------------------------------------------------------------ common
async def target(dsn: str) -> dict:
    """Which environment and release the database says it is."""
    conn = await asyncpg.connect(dsn, timeout=10)
    try:
        env = await conn.fetchval("SELECT value #>> '{}' FROM sys.setting WHERE key = 'deploy.environment'")
        rel = await conn.fetchrow("SELECT version, commit_sha, schema_hash, hash_matches FROM sys.current_release()")
    finally:
        await conn.close()
    return {"environment": env if env in ("development", "staging", "production") else "development",
            "release": rel["version"] if rel else None, "commit": rel["commit_sha"] if rel else None,
            "schema_hash": rel["schema_hash"] if rel else None, "hash_matches": bool(rel and rel["hash_matches"])}


def checkout_release() -> dict:
    """The release whose schema files this checkout holds: the last version they record, and the commit (git, or the
    RELEASE file of a release archive). Gate 4 rehearses these files, which the measured database may not run yet."""
    schema = os.path.join(ROOT, "db", "schema")
    version = None
    for name in sorted((f for f in os.listdir(schema) if f[:1].isdigit() and f.endswith(".sql")),
                       key=lambda f: int(f.split("_", 1)[0])):                    # 998 before 1000, as db/build.sh runs them
        with open(os.path.join(schema, name), encoding="utf-8") as fh:
            found = re.findall(r"INSERT INTO sys\.schema_migration \(version, description\)\s*SELECT '([0-9.]+)'", fh.read())
        version = found[-1] if found else version
    commit = None
    try:
        commit = subprocess.run(["git", "-C", ROOT, "rev-parse", "HEAD"], capture_output=True, text=True,  # nosec B603 B607
                                check=True).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        if os.path.exists(os.path.join(ROOT, "RELEASE")):
            with open(os.path.join(ROOT, "RELEASE"), encoding="utf-8") as fh:
                commit = next((ln.split("=", 1)[1].strip() for ln in fh if ln.startswith("commit=")), None)
    return {"release": version, "commit": commit}


def write(prefix: str, info: dict, doc: dict, evidence: str, operator: str | None) -> str:
    today = dt.date.today().isoformat()
    doc = {"environment": info["environment"], "date": today, "release": info.get("release"), "commit": info.get("commit"),
           "operator": operator, "tool": "db/tools/gate_run.py", **doc}
    os.makedirs(evidence, exist_ok=True)
    path = os.path.join(evidence, f"{prefix}_{info['environment']}_{today}.json")
    if os.path.exists(path):
        path = path[:-5] + f"_{dt.datetime.now().strftime('%H%M%S')}.json"
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(doc, fh, indent=1, default=str)
        fh.write("\n")
    print(json.dumps(doc, indent=1, default=str))
    print(f"\nevidence: {os.path.relpath(path, ROOT)}  (judge with: python3 db/tools/launch_gates.py check)")
    return path


def sh(cmd: str, timeout: float = 3600, stdin: str | None = None) -> subprocess.CompletedProcess:
    """An operator's command, as given on the command line (never built from untrusted input)."""
    return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout,  # nosec B602 - operator's own command
                          input=stdin)


def now() -> float:
    return time.time()


def iso(t: float | None) -> str | None:
    return dt.datetime.fromtimestamp(t, dt.timezone.utc).isoformat(timespec="seconds") if t else None


# ------------------------------------------------------------------ gate 1: recovery
def _seal_sql() -> tuple[str, str]:
    import importlib.util
    spec = importlib.util.spec_from_file_location("restore_drill", os.path.join(os.path.dirname(__file__), "restore_drill.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.SEAL_BLOCK_FN, mod.SEALS_OK


async def integrity(dsn: str) -> dict:
    """The checks of db/tools/restore_drill.py, on a restored server."""
    seal_fn, seals_ok = _seal_sql()
    conn = await asyncpg.connect(dsn, timeout=10)
    try:
        c = {"wallets_reconcile": await conn.fetchval("SELECT (fin.reconcile_wallets()).mismatches") == 0,
             "no_orphans": await conn.fetchval("SELECT coalesce(sum(orphans), 0) FROM sys.find_orphans()") == 0}
        # the restored copy is writable and scratch: a helper function recomputes every audit seal, then goes
        await conn.execute("SET search_path = audit, public")
        await conn.execute(seal_fn)
        bad, total = await conn.fetchrow(seals_ok)
        await conn.execute("DROP FUNCTION audit.seal_block(text, bigint, bigint)")
        await conn.execute("RESET search_path")
        c["audit_seals_recompute"] = int(bad) == 0 and int(total) > 0
        c["audit_seals_checked"] = int(total)
        c["ledger_balanced"] = await conn.fetchval(
            """SELECT count(*) FROM (SELECT txn_id FROM fin.ledger_entry GROUP BY txn_id
                HAVING sum(CASE WHEN direction = 'DR' THEN amount ELSE -amount END) <> 0) x""") == 0
        c["not_in_recovery"] = not await conn.fetchval("SELECT pg_is_in_recovery()")
    finally:
        await conn.close()
    return c


async def recovery(a) -> int:
    """Writes numbered rows to the primary, stops it (--kill), restores onto a new server (--restore, or by hand while
    the tool waits), then measures the rows lost (RPO) and the time to a usable database (RTO) and checks the copy."""
    info = await target(a.primary)
    drill, acked, state = uuid.uuid4(), {}, {"stop": False, "failed_at": None}

    async def writer():
        conn, seq = None, 0
        while not state["stop"]:
            try:
                if conn is None or conn.is_closed():
                    conn = await asyncpg.connect(a.primary, timeout=3, command_timeout=5)
                seq += 1
                await conn.execute("INSERT INTO sys.failover_probe (drill, seq) VALUES ($1, $2)", drill, seq)
                acked[seq] = now()
            except (OSError, asyncpg.PostgresError, asyncpg.InterfaceError, asyncio.TimeoutError):
                state["failed_at"] = state["failed_at"] or now()
                conn = None
                await asyncio.sleep(0.5)
                continue
            await asyncio.sleep(1.0 / a.rate)

    task = asyncio.create_task(writer())
    await asyncio.sleep(a.warmup)
    declared = now()
    kill = await asyncio.to_thread(sh, a.kill, 600)
    await asyncio.sleep(3)
    state["stop"] = True
    await task
    restore = None
    if a.restore:
        t0 = now()
        r = await asyncio.to_thread(sh, a.restore, a.timeout)
        restore = {"exit": r.returncode, "seconds": round(now() - t0, 1), "output_tail": (r.stdout + r.stderr)[-1500:]}
    else:
        print("restore the database on the new server now; waiting for it to answer as a primary ...", flush=True)
    usable = None
    deadline = declared + a.timeout
    while now() < deadline:
        try:
            conn = await asyncpg.connect(a.restored, timeout=3)
            try:
                if not await conn.fetchval("SELECT pg_is_in_recovery()"):
                    usable = now()
                    break
            finally:
                await conn.close()
        except (OSError, asyncpg.PostgresError, asyncio.TimeoutError):
            pass
        await asyncio.sleep(2)
    latest = {"declared_loss": iso(declared), "usable_at": iso(usable), "acknowledged": len(acked)}
    if usable is None:
        latest.update(rpo_measured_s=None, rpo_is_lower_bound=False, rto_measured_s=None, checks={}, schema_matches_source=False)
    else:
        conn = await asyncpg.connect(a.restored, timeout=10)
        try:
            kept = {r["seq"] for r in await conn.fetch("SELECT seq FROM sys.failover_probe WHERE drill = $1", drill)}
            restored_hash = await conn.fetchval("SELECT schema_hash FROM sys.current_release()")
        finally:
            await conn.close()
        lost = sorted(s for s in acked if s not in kept)
        last_kept = max((s for s in acked if s in kept), default=None)
        # data lost: from the newest acknowledged row the copy has to the newest acknowledged at all. If the copy has
        # none of the drill's rows, the loss began before the drill did and the figure is only a lower bound: warm up
        # for longer than archive_timeout (the default 150 s does) so that the measurement brackets an archived segment
        rpo = round(acked[lost[-1]] - (acked[last_kept] if last_kept else acked[lost[0]]), 2) if lost else 0.0
        latest.update(kept=len(kept & set(acked)), lost=len(lost), rpo_measured_s=rpo, rpo_is_lower_bound=bool(lost) and last_kept is None,
                      rto_measured_s=round(usable - declared, 1),
                      checks=await integrity(a.restored), schema_matches_source=restored_hash == info["schema_hash"])
    ok = (usable is not None and not latest["rpo_is_lower_bound"] and latest["rpo_measured_s"] <= RPO_S and latest["rto_measured_s"] <= RTO_S
          and latest["schema_matches_source"]
          and all(v for k, v in latest["checks"].items() if k != "audit_seals_checked"))
    doc = {"gate": 1, "what": "Server lost without warning, restored on a new server from the backup repository",
           "method": a.method, "kill_exit": kill.returncode, "restore": restore, "latest": latest,
           "targets": {"rpo_seconds": RPO_S, "rto_seconds": RTO_S}, "result": "PASS" if ok else "FAIL"}
    write("restore", info, doc, a.evidence, a.operator)
    return 0 if ok else 1


# ------------------------------------------------------------------ gate 2: egress
async def egress(a) -> int:
    info = await target(a.owner_dsn)
    probe = sh(f"{a.worker_exec} /app/deploy/egress/selftest.sh {shlex.quote(a.proxy)} {shlex.quote(a.allowed)}", 300)
    direct = sh(f"""{a.api_exec} python3 -c "import socket; socket.create_connection(('{a.direct_target}', 443), timeout=8)" """, 60)
    text = probe.stdout + probe.stderr
    passed = probe.returncode == 0 and "egress proxy: all probes passed" in text
    doc = {"gate": 2, "proxy_selftest": text[-4000:], "direct_target": a.direct_target,
           "direct_route_blocked": direct.returncode != 0, "direct_output": (direct.stdout + direct.stderr)[-500:],
           "result": "PASS" if passed and direct.returncode != 0 else "FAIL"}
    write("egress", info, doc, a.evidence, a.operator)
    return 0 if doc["result"] == "PASS" else 1


# ------------------------------------------------------------------ gate 3: capacity
async def capacity(a) -> int:
    info = await target(a.owner_dsn)
    env, today, rc = info["environment"], dt.date.today().isoformat(), 0
    for level in [x.strip() for x in a.levels.split(",") if x.strip()]:
        out = os.path.join(a.evidence, f"burst_{env}_{level}_{today}.json")
        cmd = [sys.executable, "-m", "loadtest.burst", "--base", a.base, "--rate", str(RATES[level]), "--seconds", str(a.seconds),
               "--cancel-ratio", str(a.cancel_ratio), "--owner-dsn", a.owner_dsn, "--environment", env, "--json", out]
        print("running", level, flush=True)
        rc |= subprocess.run(cmd, cwd=BACKEND).returncode                                             # nosec B603 - fixed arguments
    if a.soak_hours > 0:
        out = os.path.join(a.evidence, f"soak_{env}_{today}.json")
        cmd = [sys.executable, "-m", "loadtest.soak", "--base", a.base, "--owner-dsn", a.owner_dsn, "--hours", str(a.soak_hours),
               "--environment", env, "--json", out]
        rc |= subprocess.run(cmd, cwd=BACKEND).returncode                                             # nosec B603 - fixed arguments
    print("\njudge with: python3 db/tools/launch_gates.py check")
    return rc


# ------------------------------------------------------------------ gate 4: migrations
async def migrations(a, psql_args: list[str]) -> int:
    info = await target(a.owner_dsn)
    with tempfile.TemporaryDirectory() as tmp:
        cmd = [sys.executable, os.path.join(ROOT, "db", "tools", "migration_rehearsal.py"), "--base", a.base,
               "--scale", str(a.scale), "--report", tmp, *psql_args]
        r = subprocess.run(cmd)                                                                       # nosec B603 - fixed arguments
        files = [f for f in os.listdir(tmp) if f.startswith("migration_rehearsal_")]
        if not files:
            print("the rehearsal wrote no report", file=sys.stderr)
            return 1
        with open(os.path.join(tmp, files[0]), encoding="utf-8") as fh:
            report = json.load(fh)
    # the evidence names the release rehearsed (this checkout's files), not the one the measured database runs
    rehearsed = {**info, **checkout_release()}
    doc = {"gate": 4, "environment_release": info["release"], **report}
    write(f"migration_rehearsal_{rehearsed['release'] or 'unknown'}", rehearsed, doc, a.evidence, a.operator)
    return r.returncode


# ------------------------------------------------------------------ gate 5: alert drill
async def alert(a) -> int:
    import httpx
    info = await target(a.owner_dsn)
    am = a.alertmanager.rstrip("/")
    async with httpx.AsyncClient(timeout=10) as http:
        trig = await asyncio.to_thread(sh, a.trigger, 300)
        triggered = now()
        fired = seen = None
        while now() < triggered + a.timeout:
            r = await http.get(f"{am}/api/v2/alerts", params={"filter": f'alertname="{a.alert}"', "active": "true"})
            firing = [x for x in r.json() if x.get("status", {}).get("state") == "active"]
            if firing:
                seen, fired = now(), firing[0].get("startsAt")
                break
            await asyncio.sleep(5)
        print(f"{a.alert} {'is firing; the on-call engineer acknowledges it with a silence whose comment names the runbook section followed' if seen else 'did not fire'}", flush=True)
        ack = None
        while seen and now() < seen + a.ack_timeout:
            r = await http.get(f"{am}/api/v2/silences")
            for s in r.json():
                names = {m.get("name"): m.get("value") for m in s.get("matchers", [])}
                started = dt.datetime.fromisoformat(s["startsAt"].replace("Z", "+00:00")).timestamp()
                if names.get("alertname") == a.alert and started >= triggered - 60:
                    ack = s
                    break
            if ack:
                break
            await asyncio.sleep(5)
        rest = await asyncio.to_thread(sh, a.restore, 300)
        resolved, deadline = None, now() + a.timeout
        while seen and now() < deadline:
            r = await http.get(f"{am}/api/v2/alerts", params={"filter": f'alertname="{a.alert}"'})
            if not [x for x in r.json() if x.get("status", {}).get("state") in ("active", "suppressed")]:
                resolved = now()
                break
            await asyncio.sleep(10)
    ack_at = dt.datetime.fromisoformat(ack["startsAt"].replace("Z", "+00:00")).timestamp() if ack else None
    # minutes from the moment the alert began firing (Alertmanager's startsAt), else from when the tool saw it
    began = dt.datetime.fromisoformat(fired.replace("Z", "+00:00")).timestamp() if fired else seen
    doc = {"gate": 5, "alert": a.alert, "how_triggered": a.trigger, "trigger_exit": trig.returncode,
           "triggered_at": iso(triggered), "fired_at": fired, "seen_firing_at": iso(seen), "acknowledged_at": iso(ack_at),
           "ack_minutes": round((ack_at - began) / 60, 2) if ack_at and began else None,
           "on_call": ack.get("createdBy") if ack else None, "ack_comment": ack.get("comment") if ack else None,
           "runbook_followed": bool(ack and "RUNBOOKS" in (ack.get("comment") or "").upper()),
           "restored_with": a.restore, "restore_exit": rest.returncode, "resolved_at": iso(resolved),
           "notes": a.notes}
    write("alert_drill", info, doc, a.evidence, a.operator)
    return 0 if doc["ack_minutes"] is not None and doc["ack_minutes"] <= 15 and doc["runbook_followed"] else 1


# ------------------------------------------------------------------ gate 6: audit archive
async def audit_archive(a) -> int:
    info = await target(a.owner_dsn)
    tool = f"{shlex.quote(sys.executable)} -m app.tools.audit_export"
    os.makedirs(a.dir, exist_ok=True)
    d = shlex.quote(os.path.abspath(a.dir))
    key = f"--public-key {shlex.quote(os.path.abspath(a.public_key))}"
    export = sh(f"cd {shlex.quote(BACKEND)} && {tool} export {d}")
    verify = sh(f"cd {shlex.quote(BACKEND)} && {tool} verify {d} {key}")
    head = sh(f"cd {shlex.quote(BACKEND)} && {tool} head {d}")
    doc = {"gate": 6, "bucket": a.bucket, "export_ok": export.returncode == 0,
           "signature_verified": verify.returncode == 0, "chain_verified": verify.returncode == 0,
           "chain_tip": head.stdout.strip()[-600:], "object_lock_mode": None, "retrieved_past_export_verified": False,
           "custodian_receipt": a.custodian_receipt or "", "output": {"export": (export.stdout + export.stderr)[-1200:],
                                                                    "verify": (verify.stdout + verify.stderr)[-1200:]}}
    if a.bucket:
        bucket = a.bucket.removeprefix("s3://").split("/", 1)[0]
        sync = sh(f"aws s3 sync {d} {shlex.quote(a.bucket)}")
        lock = sh(f"aws s3api get-object-lock-configuration --bucket {shlex.quote(bucket)}")
        try:
            rule = json.loads(lock.stdout)["ObjectLockConfiguration"]["Rule"]["DefaultRetention"]
            doc["object_lock_mode"], doc["object_lock_retention"] = rule.get("Mode"), rule
        except (ValueError, KeyError):
            doc["object_lock_mode"] = None
        with tempfile.TemporaryDirectory() as back:
            got = sh(f"aws s3 sync {shlex.quote(a.bucket)} {shlex.quote(back)}")
            again = sh(f"cd {shlex.quote(BACKEND)} && {tool} verify {shlex.quote(back)} {key}")
            doc["retrieved_past_export_verified"] = sync.returncode == 0 and got.returncode == 0 and again.returncode == 0
        record = sh(f"cd {shlex.quote(BACKEND)} && {tool} record {d} {key}")
        doc["recorded_in_database"] = record.returncode == 0
    ok = all(doc[k] is True for k in ("export_ok", "signature_verified", "chain_verified", "retrieved_past_export_verified")) \
        and doc["object_lock_mode"] == "COMPLIANCE" and bool(doc["custodian_receipt"])
    doc["result"] = "PASS" if ok else "FAIL"
    write("audit_archive", info, doc, a.evidence, a.operator)
    return 0 if ok else 1


# ------------------------------------------------------------------ gate 7: file scanning
CLEAN_PDF = (b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\n2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj\n"
             b"3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]>>endobj\ntrailer<</Root 1 0 R>>\n%%EOF\n")


async def file_scanning(a) -> int:
    import httpx
    info = await target(a.owner_dsn)
    owner = await asyncpg.connect(a.owner_dsn, timeout=10)

    async def scan_state(uid: str):
        return await owner.fetchrow("""SELECT f.scan_status, f.scan_engine, f.scan_detail FROM iam.document d
                                       JOIN ref.file_object f ON f.id = d.file_id WHERE d.uid = $1::uuid""", uid)

    async def wait_clean(http, uid: str, seconds: float):
        end = now() + seconds
        while now() < end:
            st = await scan_state(uid)
            if st and st["scan_status"] != "PENDING":
                return st
            await asyncio.sleep(3)
        return await scan_state(uid)

    served, results = [], {}
    try:
        async with httpx.AsyncClient(base_url=a.base, timeout=30, headers={"X-Masslak-Client": "web"}, verify=not a.insecure) as http:
            r = await http.post("/api/auth/login", json={"identifier": a.email, "password": a.password, "portal": "OPERATOR"})
            r.raise_for_status()

            async def upload(name: str, data: bytes):
                return await http.post("/api/company/documents", data={"doc_type": "OTHER"}, files={"file": (name, data)})

            async def download(uid: str) -> int:
                g = await http.get(f"/api/company/documents/{uid}/file")
                if g.status_code == 200:                      # what the scan said about every file that was served
                    served.append((uid, (await scan_state(uid))["scan_status"]))
                return g.status_code

            # 1. a clean file is scanned and served
            clean = CLEAN_PDF + f"%{uuid.uuid4()}\n".encode()
            r = await upload("gate7-clean.pdf", clean)
            uid = r.json().get("uid") if r.status_code == 201 else None
            st = await wait_clean(http, uid, a.wait) if uid else None
            results["clean"] = {"upload": r.status_code, "scan": dict(st) if st else None,
                                "download": await download(uid) if uid else None}
            # 2. the EICAR test file is refused and never served
            r = await upload("gate7-eicar.pdf", EICAR)
            results["eicar"] = {"upload": r.status_code, "answer": r.json() if r.content else None}
            # 2b. the API's own checks refuse EICAR wherever it sits in a file, so it never reaches ClamAV through the
            # API: ClamAV is asked directly, with the signatures it runs on, and must name it
            probe = await asyncio.to_thread(sh, a.clamd_check, 120, EICAR.decode())
            results["clamav_direct"] = {"exit": probe.returncode, "output": (probe.stdout + probe.stderr)[-500:]}
            # 3. with the scanner stopped, a clean file stays in quarantine (fail closed)
            stop = await asyncio.to_thread(sh, a.stop_scanner, 300)
            await asyncio.sleep(a.settle)
            later = CLEAN_PDF + f"%{uuid.uuid4()}\n".encode()
            r = await upload("gate7-while-down.pdf", later)
            uid_down = r.json().get("uid") if r.status_code == 201 else None
            st_down = await scan_state(uid_down) if uid_down else None
            results["scanner_down"] = {"stop_exit": stop.returncode, "upload": r.status_code,
                                       "scan": dict(st_down) if st_down else None,
                                       "download": await download(uid_down) if uid_down else None}
            # 4. back up: the waiting file is scanned by the worker and served
            start = await asyncio.to_thread(sh, a.start_scanner, 300)
            t0 = now()
            st_after = await wait_clean(http, uid_down, a.wait) if uid_down else None
            results["scanner_back"] = {"start_exit": start.returncode, "scan": dict(st_after) if st_after else None,
                                       "cleared_after_s": round(now() - t0, 1),
                                       "download": await download(uid_down) if uid_down else None}
    finally:
        await owner.close()
    clean_ok = results["clean"]["download"] == 200 and (results["clean"]["scan"] or {}).get("scan_status") == "CLEAN"
    eicar_ok = results["eicar"]["upload"] == 422
    down = results["scanner_down"]
    down_ok = down["upload"] == 201 and (down["scan"] or {}).get("scan_status") == "PENDING" and down["download"] == 409
    engines = {(results.get(k, {}).get("scan") or {}).get("scan_engine") for k in ("clean", "scanner_back")}
    clamav_ok = "FOUND" in results["clamav_direct"]["output"] and "builtin+clamav" in engines
    doc = {"gate": 7, "results": results, "clean_served": clean_ok, "eicar_refused": eicar_ok,
           "clamav_detects_eicar": clamav_ok,
           "scanner_down_refused": down_ok,
           "only_clean_served": bool(served) and all(status == "CLEAN" for _, status in served)
           and results["scanner_down"]["download"] != 200,
           "served": [{"uid": u, "scan_status": st} for u, st in served],
           "pending_cleared_after_restart": (results["scanner_back"]["scan"] or {}).get("scan_status") == "CLEAN",
           "engines_seen": sorted(e for e in engines if e), "backlog_alert_seen": None}
    doc["result"] = "PASS" if all(doc[k] for k in ("clean_served", "eicar_refused", "clamav_detects_eicar", "scanner_down_refused",
                                                   "only_clean_served")) else "FAIL"
    write("file_scanning", info, doc, a.evidence, a.operator)
    return 0 if doc["result"] == "PASS" else 1


# ------------------------------------------------------------------ command line
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--evidence", default=EVIDENCE, help="where evidence is written (default docs/operations/evidence)")
    ap.add_argument("--operator", help="who ran it (name and organisation), recorded in the evidence")
    sub = ap.add_subparsers(dest="gate", required=True)

    p = sub.add_parser("recovery", help="gate 1")
    p.add_argument("--primary", required=True)
    p.add_argument("--restored", required=True)
    p.add_argument("--kill", required=True)
    p.add_argument("--restore")
    p.add_argument("--method", default="pgbackrest restore to a new host")
    p.add_argument("--rate", type=float, default=10.0)
    p.add_argument("--warmup", type=float, default=150.0, help="seconds of writes before the kill; longer than archive_timeout")
    p.add_argument("--timeout", type=float, default=RTO_S + 600)

    p = sub.add_parser("egress", help="gate 2")
    p.add_argument("--owner-dsn", required=True)
    p.add_argument("--worker-exec", required=True, help="prefix running a command in the worker container")
    p.add_argument("--api-exec", required=True, help="prefix running a command in the API container")
    p.add_argument("--proxy", default="egress:3128")
    p.add_argument("--allowed", required=True, help="a name on the production allowlist")
    p.add_argument("--direct-target", default="1.1.1.1")

    p = sub.add_parser("capacity", help="gate 3")
    p.add_argument("--owner-dsn", required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--levels", default="1x,2x,5x")
    p.add_argument("--seconds", type=int, default=300)
    p.add_argument("--cancel-ratio", type=float, default=0.1)
    p.add_argument("--soak-hours", type=float, default=8.0)

    p = sub.add_parser("migrations", help="gate 4 (psql connection args after --)")
    p.add_argument("--owner-dsn", required=True)
    p.add_argument("--base", required=True, help="last schema file of the release installed now, e.g. 1055")
    p.add_argument("--scale", type=int, default=200000)

    p = sub.add_parser("alert", help="gate 5")
    p.add_argument("--owner-dsn", required=True)
    p.add_argument("--alertmanager", required=True)
    p.add_argument("--alert", default="DatabaseDown")
    p.add_argument("--trigger", required=True)
    p.add_argument("--restore", required=True)
    p.add_argument("--timeout", type=float, default=1800)
    p.add_argument("--ack-timeout", type=float, default=1800)
    p.add_argument("--notes", default="")

    p = sub.add_parser("audit-archive", help="gate 6")
    p.add_argument("--owner-dsn", required=True)
    p.add_argument("--dir", required=True)
    p.add_argument("--public-key", required=True)
    p.add_argument("--bucket", help="s3://bucket/prefix with object lock")
    p.add_argument("--custodian-receipt", help="where the custodian recorded the chain tip, outside the platform")

    p = sub.add_parser("file-scanning", help="gate 7")
    p.add_argument("--owner-dsn", required=True)
    p.add_argument("--base", required=True)
    p.add_argument("--email", required=True)
    p.add_argument("--password", required=True)
    p.add_argument("--clamd-check", required=True,
                   help="command that passes its standard input to clamd and prints the answer, e.g. "
                        "'docker compose ... exec -T clamav clamdscan --no-summary -'")
    p.add_argument("--stop-scanner", required=True)
    p.add_argument("--start-scanner", required=True)
    p.add_argument("--wait", type=float, default=180)
    p.add_argument("--settle", type=float, default=5)
    p.add_argument("--insecure", action="store_true", help="accept a self-signed certificate (staging only)")

    argv = sys.argv[1:]
    extra = []
    if "--" in argv:
        extra = argv[argv.index("--") + 1:]
        argv = argv[:argv.index("--")]
    a = ap.parse_args(argv)
    run = {"recovery": recovery, "egress": egress, "capacity": capacity, "alert": alert, "audit-archive": audit_archive,
           "file-scanning": file_scanning}
    if a.gate == "migrations":
        return asyncio.run(migrations(a, extra))
    return asyncio.run(run[a.gate](a))


if __name__ == "__main__":
    sys.exit(main())
