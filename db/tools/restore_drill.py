#!/usr/bin/env python3
"""Restore drill: point-in-time recovery from a base backup and archived WAL, timed and checked (audit T3-01).

The drill copies a database into a scratch PostgreSQL cluster that archives its WAL, takes a base backup, keeps writing
under a steady workload, then:
  1. restores to a chosen point in time into a separate cluster and proves that every transaction up to that point is
     there and none after it;
  2. simulates losing the server (immediate stop, no final WAL switch), restores to the latest archived WAL and measures
     the data lost (RPO) and the time to a usable database (RTO);
  3. checks the restored databases: wallets reconcile with the ledger, no references to missing rows, every audit seal
     recomputes and chains, the schema hash equals the source, and the row counts of bookings, tickets, ledger and audit
     match the source at the recovery point.

The production procedure uses pgBackRest (docs/operations/RUNBOOKS.md, section 2); the drill rehearses the same recovery
mechanism (base backup + WAL + recovery target) and gives the measured numbers. Run it as root on a machine with the
PostgreSQL 16 server binaries; the scratch clusters live under --work and are removed afterwards.

    python3 db/tools/restore_drill.py --source <database> [--work /var/tmp/masslak-drill] [--report <dir>]
           [--archive-timeout 60] [--workload-seconds 20] [psql connection args for the source...]
"""
import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time

BIN = os.environ.get("PG_BIN", "/usr/lib/postgresql/16/bin")
COUNTED = ["sales.booking", "sales.ticket", "fin.ledger_txn", "fin.ledger_entry", "audit.row_change", "audit.activity_log", "drill.marker"]


def run(cmd, **kw):
    return subprocess.run(cmd, check=True, capture_output=True, text=True, **kw).stdout


def as_pg(cmd):
    return run(["runuser", "-u", "postgres", "--", *cmd])


def psql(port, db, sql, user="postgres"):
    """The last line of output: the result of the last statement (command tags of earlier ones are dropped)."""
    out = as_pg([f"{BIN}/psql", "-h", "/tmp", "-p", str(port), "-U", user, "-d", db, "-At", "-v", "ON_ERROR_STOP=1", "-c", sql]).strip()
    return out.splitlines()[-1] if out else ""


def start(data, port, log):
    as_pg([f"{BIN}/pg_ctl", "-D", data, "-l", log, "-o", f"-p {port} -k /tmp -c listen_addresses=''", "-w", "-t", "600", "start"])


def stop(data, mode="fast"):
    subprocess.run(["runuser", "-u", "postgres", "--", f"{BIN}/pg_ctl", "-D", data, "-m", mode, "-w", "stop"], capture_output=True)


def schema_hash(port, db):
    dump = as_pg([f"{BIN}/pg_dump", "-h", "/tmp", "-p", str(port), "-U", "postgres", "--schema-only", "--no-owner",
                  "--no-privileges", "-N", "drill", db])
    # pg_dump names its own version and writes a random \restrict token on every run: neither is part of the schema
    keep = (line for line in dump.splitlines() if not line.startswith(("-- Dumped ", "\\restrict ", "\\unrestrict ")))
    return hashlib.sha256("\n".join(keep).encode()).hexdigest()


def counts(port, db):
    out = {}
    for t in COUNTED:
        out[t] = int(psql(port, db, f"SELECT count(*) FROM {t}"))
    return out


SEALS_OK = """
WITH s AS (SELECT id, log_name, from_id, to_id, row_count, block_hash, prev_seal_hash, seal_hash,
                  lag(seal_hash) OVER (PARTITION BY log_name ORDER BY id) AS prev FROM audit.log_seal)
SELECT count(*) FILTER (WHERE NOT ok), count(*) FROM (
  SELECT s.prev_seal_hash IS NOT DISTINCT FROM s.prev
     AND s.seal_hash = digest(coalesce(s.prev, '\\x'::bytea) || s.block_hash || convert_to(s.from_id || ':' || s.to_id, 'UTF8'), 'sha256')
     AND s.block_hash = b.h AND s.row_count = b.n AS ok
    FROM s CROSS JOIN LATERAL (SELECT * FROM audit.seal_block(s.log_name, s.from_id, s.to_id)) b) x
"""

SEAL_BLOCK_FN = """
CREATE OR REPLACE FUNCTION audit.seal_block(p_log text, p_from bigint, p_to bigint, OUT h bytea, OUT n bigint)
LANGUAGE plpgsql STABLE AS $$
BEGIN
  EXECUTE format('SELECT digest(string_agg(encode(row_hash, ''hex''), '''' ORDER BY id), ''sha256''), count(*)
                    FROM audit.%I WHERE id BETWEEN $1 AND $2', p_log) INTO h, n USING p_from, p_to;
END $$"""


def checks(port, db):
    """Integrity of a restored database; every check must pass."""
    c = {}
    c["wallets_reconcile"] = psql(port, db, "SELECT (fin.reconcile_wallets()).mismatches") == "0"
    c["no_orphans"] = psql(port, db, "SELECT coalesce(sum(orphans), 0) FROM sys.find_orphans()") == "0"
    psql(port, db, "SET search_path = audit, public; " + SEAL_BLOCK_FN)
    bad, total = psql(port, db, "SET search_path = audit, public; " + SEALS_OK).split("|")
    c["audit_seals_recompute"] = bad == "0" and int(total) > 0
    c["audit_seals_checked"] = int(total)
    psql(port, db, "DROP FUNCTION audit.seal_block(text, bigint, bigint)")
    c["ledger_balanced"] = psql(port, db, """SELECT count(*) FROM (SELECT txn_id FROM fin.ledger_entry GROUP BY txn_id
                                              HAVING sum(CASE WHEN direction = 'DR' THEN amount ELSE -amount END) <> 0) x""") == "0"
    c["not_in_recovery"] = psql(port, db, "SELECT pg_is_in_recovery()") == "f"
    return c


def main():
    # no -h: the psql connection arguments (-h host -U user) pass through to pg_dump
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter, add_help=False)
    ap.add_argument("--help", action="help")
    ap.add_argument("--source", required=True)
    ap.add_argument("--work", default="/var/tmp/masslak-drill")
    ap.add_argument("--report", default=".")
    ap.add_argument("--archive-timeout", type=int, default=60)
    ap.add_argument("--workload-seconds", type=int, default=20)
    args, conn = ap.parse_known_args()
    db = args.source
    work = os.path.abspath(args.work)
    if os.path.exists(work):
        shutil.rmtree(work)
    paths = {k: os.path.join(work, k) for k in ("src", "archive", "base", "pitr", "latest", "logs")}
    for p in paths.values():
        os.makedirs(p)
    shutil.chown(work, "postgres")
    for p in paths.values():
        shutil.chown(p, "postgres")
    os.chmod(paths["src"], 0o700)
    report = {"source_database": db, "started_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
              "archive_timeout_s": args.archive_timeout, "steps": {}}
    P_SRC, P_PITR, P_LATEST = 5461, 5462, 5463
    t0 = time.monotonic()
    try:
        # ---------------------------------------------------------------- source cluster with WAL archiving
        as_pg([f"{BIN}/initdb", "-D", paths["src"], "--data-checksums", "-A", "trust", "-U", "postgres"])
        with open(os.path.join(paths["src"], "postgresql.auto.conf"), "a") as f:
            f.write(f"wal_level = replica\narchive_mode = on\narchive_timeout = {args.archive_timeout}\n"
                    f"archive_command = 'test ! -f {paths['archive']}/%f && cp %p {paths['archive']}/%f'\n")
        start(paths["src"], P_SRC, os.path.join(paths["logs"], "src.log"))
        roles = run(["pg_dumpall", *conn, "--roles-only", "--no-role-passwords"])
        roles = "\n".join(line for line in roles.splitlines()
                          if not line.startswith(("CREATE ROLE postgres", "ALTER ROLE postgres")))
        roles_file = os.path.join(work, "roles.sql")
        with open(roles_file, "w") as f:
            f.write(roles)
        shutil.chown(roles_file, "postgres")
        as_pg([f"{BIN}/psql", "-h", "/tmp", "-p", str(P_SRC), "-U", "postgres", "-d", "postgres", "-q", "-f", roles_file])
        psql(P_SRC, "postgres", f'CREATE DATABASE "{db}"')
        dump = os.path.join(work, "source.dump")
        run(["pg_dump", *conn, "-Fc", "-d", db, "-f", dump])
        shutil.chown(dump, "postgres")
        subprocess.run(["runuser", "-u", "postgres", "--", f"{BIN}/pg_restore", "-h", "/tmp", "-p", str(P_SRC), "-U", "postgres",
                        "-d", db, "--exit-on-error", dump], check=True, capture_output=True)
        report["database_size"] = psql(P_SRC, db, f"SELECT pg_size_pretty(pg_database_size('{db}'))")
        # seal the audit logs as the daily job does, so the restored seals can be recomputed
        for log in ("row_change", "activity_log", "data_access_log", "auth_event"):
            psql(P_SRC, db, f"SELECT audit.seal('{log}', 1000000)")
        psql(P_SRC, db, "CREATE SCHEMA drill; CREATE TABLE drill.marker (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, "
                        "at timestamptz NOT NULL DEFAULT clock_timestamp())")
        src_schema = schema_hash(P_SRC, db)

        # ---------------------------------------------------------------- base backup
        t = time.monotonic()
        as_pg([f"{BIN}/pg_basebackup", "-h", "/tmp", "-p", str(P_SRC), "-U", "postgres", "-D", paths["base"], "-X", "fetch",
               "--checkpoint=fast", "--no-sync"])
        report["steps"]["base_backup_s"] = round(time.monotonic() - t, 1)

        # ---------------------------------------------------------------- workload, recovery point, more workload
        def workload(seconds):
            end = time.monotonic() + seconds
            while time.monotonic() < end:
                psql(P_SRC, db, "INSERT INTO drill.marker DEFAULT VALUES")
                time.sleep(0.2)
        workload(args.workload_seconds / 2)
        psql(P_SRC, db, "SELECT pg_switch_wal()")
        target_time = psql(P_SRC, db, "SELECT clock_timestamp()")
        target_counts = counts(P_SRC, db)
        time.sleep(1)
        workload(args.workload_seconds / 2)
        psql(P_SRC, db, "SELECT pg_switch_wal()")               # the PITR target's WAL is archived
        workload(3)                                              # written after the last switch: lost unless archived by timeout
        last_committed = psql(P_SRC, db, "SELECT max(id) || '|' || max(at) FROM drill.marker").split("|")
        # ---------------------------------------------------------------- disaster: the server is lost without warning
        stop(paths["src"], "immediate")
        lost_at = dt.datetime.now(dt.timezone.utc)

        def restore(into, port, target):
            t = time.monotonic()
            shutil.copytree(paths["base"], into, dirs_exist_ok=True)
            run(["chown", "-R", "postgres:postgres", into])
            os.chmod(into, 0o700)
            with open(os.path.join(into, "postgresql.auto.conf"), "a") as f:
                f.write(f"archive_mode = off\nrestore_command = 'cp {paths['archive']}/%f %p'\nrecovery_target_action = promote\n")
                if target:
                    f.write(f"recovery_target_time = '{target}'\n")
            open(os.path.join(into, "recovery.signal"), "w").close()
            shutil.chown(os.path.join(into, "recovery.signal"), "postgres")
            start(into, port, os.path.join(paths["logs"], os.path.basename(into) + ".log"))
            for _ in range(600):
                if psql(port, "postgres", "SELECT pg_is_in_recovery()") == "f":
                    break
                time.sleep(0.2)
            return round(time.monotonic() - t, 1)

        # ---------------------------------------------------------------- 1. point in time
        rto_pitr = restore(paths["pitr"], P_PITR, target_time)
        got = counts(P_PITR, db)
        pitr = {"target_time": target_time, "restore_s": rto_pitr,
                "counts_match_recovery_point": got == target_counts, "counts": got, "expected": target_counts,
                "nothing_after_target": psql(P_PITR, db, f"SELECT count(*) FROM drill.marker WHERE at > '{target_time}'") == "0",
                "schema_matches_source": schema_hash(P_PITR, db) == src_schema, "checks": checks(P_PITR, db)}
        stop(paths["pitr"])
        # ---------------------------------------------------------------- 2. latest archived WAL (server lost)
        rto_latest = restore(paths["latest"], P_LATEST, None)
        last_recovered = psql(P_LATEST, db, "SELECT max(id) || '|' || max(at) FROM drill.marker").split("|")
        lost_rows = int(last_committed[0]) - int(last_recovered[0])
        lost_window = (dt.datetime.fromisoformat(last_committed[1]) - dt.datetime.fromisoformat(last_recovered[1])).total_seconds()
        latest = {"restore_s": rto_latest, "last_committed_marker": int(last_committed[0]), "last_recovered_marker": int(last_recovered[0]),
                  "markers_lost": lost_rows, "rpo_measured_s": round(max(lost_window, 0.0), 1),
                  "rto_measured_s": round((dt.datetime.now(dt.timezone.utc) - lost_at).total_seconds(), 1),
                  "schema_matches_source": schema_hash(P_LATEST, db) == src_schema, "checks": checks(P_LATEST, db)}
        stop(paths["latest"])
        report["point_in_time"] = pitr
        report["latest"] = latest
        ok = (pitr["counts_match_recovery_point"] and pitr["nothing_after_target"] and pitr["schema_matches_source"]
              and latest["schema_matches_source"]
              and all(v for k, v in pitr["checks"].items() if k != "audit_seals_checked")
              and all(v for k, v in latest["checks"].items() if k != "audit_seals_checked"))
        # compare with the approved targets (settings recovery.rpo_seconds and recovery.rto_minutes, file 1050)
        targets = {}
        for key in ("recovery.rpo_seconds", "recovery.rto_minutes"):
            v = run(["psql", *conn, "-d", db, "-At", "-c", f"SELECT value FROM sys.setting WHERE key = '{key}'"]).strip()
            targets[key] = float(v) if v else None
        report["targets"] = targets
        report["within_targets"] = {
            "rpo": targets["recovery.rpo_seconds"] is None or latest["rpo_measured_s"] <= targets["recovery.rpo_seconds"],
            "rto": targets["recovery.rto_minutes"] is None or latest["rto_measured_s"] <= targets["recovery.rto_minutes"] * 60}
        ok = ok and all(report["within_targets"].values())
        report["result"] = "PASS" if ok else "FAIL"
    finally:
        for k in ("src", "pitr", "latest"):
            stop(paths[k], "immediate")
        report["total_s"] = round(time.monotonic() - t0, 1)
        report["finished_at"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")
        os.makedirs(args.report, exist_ok=True)
        out = os.path.join(args.report, "restore_drill.json")
        with open(out, "w") as f:
            json.dump(report, f, indent=1)
        if report.get("result") == "PASS":
            shutil.rmtree(work, ignore_errors=True)
    print(json.dumps(report, indent=1))
    return 0 if report.get("result") == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
