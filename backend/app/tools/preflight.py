"""The production profile's preflight (reviews of October 2026, package 2: H-02, H-05, H-10).

A server declared production (MASSLAK_ENVIRONMENT=production) migrates and updates only when its database is set up
as the production profile requires (deploy/production). deploy/migrate.sh runs this before any schema change, and
deploy/update.sh before it takes the backup, so a refused update has changed nothing. It connects as the owner and
checks on the database itself, not on what a configuration file says:

  tls        ssl is on, this connection is encrypted, and every TCP line of pg_hba.conf is hostssl or rejects
  hba        no TCP line lets anyone in without a password; the warehouse login only with a client certificate
  archiving  archive_mode is on with pgBackRest; pgBackRest's own check proves, now, that a WAL segment reaches the
             repository; and the repository is off this host (object storage, or a repository host)
  decoding   no logical decoding plugin but pgoutput is installed: a replication login could otherwise decode every
             table (H-10)
  files      with the files in an object store, its bucket keeps every version and locks them at least as long as
             backups are kept, so a restore can bring the files back to the backup's moment (H-04; files_versions)
  layout     the database runs on two hosts with automatic failover (MASSLAK_DB_LAYOUT=ha) and a synchronous standby
             streams from the primary now; or on one host, which the owner accepted in writing
             (MASSLAK_SINGLE_HOST_ACCEPTED): losing it then means a restore, not a failover (H-01)

The archiving and decoding facts come from /usr/local/bin/masslak-archive-check, which only the production database
image has (deploy/production/db); the owner runs it through COPY ... FROM PROGRAM, so it reports from inside the
database container.

    python -m app.tools.preflight [--owner-url URL]     (default: MASSLAK_OWNER_URL, else the PG* environment)

Exit status 0 when everything holds, 1 with one line per failure otherwise.
"""
from __future__ import annotations

import argparse
import asyncio
import base64
import os
import sys
from dataclasses import dataclass, field

import asyncpg

from ..modules.documents import storage
from . import files_versions

ARCHIVE_CHECK = "/usr/local/bin/masslak-archive-check"
# repository types pgBackRest keeps away from the database host; posix and cifs are paths on a host, which is off-site
# only when that host is another machine, so they pass only with a repository host (repo1-host)
OFF_HOST_REPOSITORIES = {"s3", "gcs", "azure", "sftp"}


@dataclass
class Facts:
    ssl: str = "off"
    connection_encrypted: bool = False
    hba: list[dict] = field(default_factory=list)          # pg_hba_file_rules rows
    archive_mode: str = "off"
    archive_command: str = ""
    archive_check: dict | None = None                       # what masslak-archive-check printed; None: not available
    archive_check_error: str = ""
    files_backend: str = "local"
    files_protection: dict | None = None                    # the bucket's versioning and Object Lock (S3 only)
    files_error: str = ""
    backup_keep_days: int = 14
    db_layout: str = "single"                               # MASSLAK_DB_LAYOUT
    single_host_accepted: str = ""                          # MASSLAK_SINGLE_HOST_ACCEPTED: who accepted one host, and when
    sync_standbys: int = 0                                  # standbys streaming that confirm every commit


def evaluate(f: Facts) -> list[str]:
    """Every way the database falls short of the production profile, one sentence each."""
    problems: list[str] = []
    if f.ssl != "on":
        problems.append("TLS is off on the database (ssl=off): start it with the production profile (deploy/production)")
    elif not f.connection_encrypted:
        problems.append("this connection to the database is not encrypted: connect with sslmode=verify-full")
    for r in f.hba:
        kind, method, line = r.get("type"), r.get("auth_method"), r.get("line_number")
        if r.get("error"):
            problems.append(f"pg_hba.conf line {line} is invalid: {r['error']}")
            continue
        if kind == "local" or method == "reject":
            continue
        if kind != "hostssl":
            problems.append(f"pg_hba.conf line {line} accepts {kind} connections ({method}): only hostssl lines may let "
                            "anyone in over the network")
        if method in ("trust", "password", "md5", "ident"):
            problems.append(f"pg_hba.conf line {line} signs in with {method}: network sign-in uses scram-sha-256")
    problems += _warehouse_login(f.hba)
    if f.archive_mode not in ("on", "always"):
        problems.append("WAL archiving is off (archive_mode): a point-in-time restore would lose everything since the "
                        "last backup")
    elif "pgbackrest" not in f.archive_command:
        problems.append(f"WAL is archived by {f.archive_command!r}, not pgBackRest: the production profile archives with "
                        "pgBackRest to a repository off this host")
    c = f.archive_check
    if c is None:
        problems.append("the database cannot report its backups (" + (f.archive_check_error or "no archive check") +
                        "): it is not the production database image (deploy/production/db)")
    else:
        repo_type, repo_host = c.get("repo_type", ""), c.get("repo_host", "")
        if repo_type not in OFF_HOST_REPOSITORIES and not repo_host:
            problems.append(f"the pgBackRest repository is {repo_type or 'not set'} on this host: put it in object storage "
                            "(PGBACKREST_REPO1_TYPE=s3, gcs or azure), on sftp, or on a repository host")
        if c.get("check_ok") != "1":
            detail = " ".join((c.get("check_output") or "").split())[-300:]
            problems.append("pgBackRest could not archive a WAL segment to its repository just now: " + (detail or "no output"))
        if c.get("plugins"):
            problems.append(f"logical decoding plugins other than pgoutput are installed ({c['plugins']}): a replication "
                            "login could decode every table")
    if f.db_layout == "ha":
        if f.sync_standbys < 1:
            problems.append("no synchronous standby streams from the primary: with two database hosts the other host "
                            "confirms every commit, so a failover loses none (deploy/production/ha/install-db-host.sh)")
    elif f.db_layout == "single":
        if not f.single_host_accepted.strip():
            problems.append("the database runs on one host (MASSLAK_DB_LAYOUT is not ha): put it on two hosts with "
                            "automatic failover (HIGH_AVAILABILITY.md), or record the owner's acceptance of one host, who "
                            "and when, in MASSLAK_SINGLE_HOST_ACCEPTED: losing the host then means a restore of about "
                            "30 minutes, not a failover of under a minute")
    else:
        problems.append(f"MASSLAK_DB_LAYOUT is {f.db_layout!r}: ha (two database hosts) or single")
    if f.files_backend == "s3":
        if f.files_protection is None:
            problems.append(f"the file bucket's versioning and Object Lock cannot be read ({f.files_error or 'no answer'})")
        else:
            problems += files_versions.problems(f.files_protection, f.backup_keep_days)
    return problems


def gather_layout(f: Facts) -> None:
    """Where the database runs, as this server declares it (H-01)."""
    f.db_layout = os.environ.get("MASSLAK_DB_LAYOUT", "").strip() or "single"
    f.single_host_accepted = os.environ.get("MASSLAK_SINGLE_HOST_ACCEPTED", "")


def gather_files(f: Facts) -> None:
    """The object store's protection, when the files are there (H-04)."""
    f.files_backend = os.environ.get("MASSLAK_FILES_BACKEND", "local")
    f.backup_keep_days = files_versions.keep_days()
    if f.files_backend == "s3":
        try:
            f.files_protection = storage.s3_from_settings().protection()
        except Exception as exc:                        # noqa: BLE001 - named in the refusal
            f.files_error = str(exc).splitlines()[0][:200] if str(exc) else type(exc).__name__


def _catch_all(rule: dict) -> bool:
    # an address of pg_hba.conf being compared, not a socket being bound
    return rule.get("address") in ("all", "0.0.0.0", "::") and rule.get("auth_method") is not None  # nosec B104


def _warehouse_login(hba: list[dict]) -> list[str]:
    """pg_hba.conf takes the first line that matches. Follow the lines the warehouse login (masslak_cdc) could match,
    up to the first one that matches every address: each must refuse it or ask for a client certificate."""
    problems = []
    for r in hba:
        if r.get("error") or r.get("type") == "local":
            continue
        if not {"masslak_cdc", "all"} & set(r.get("user_name") or []) or (r.get("database") or []) == ["replication"]:
            continue
        if r.get("auth_method") != "reject" and "clientcert=verify-full" not in (r.get("options") or []):
            problems.append(f"pg_hba.conf line {r.get('line_number')} lets the warehouse login in without a client "
                            "certificate (clientcert=verify-full)")
        if _catch_all(r):
            break
    return problems


def parse_archive_check(lines: list[str]) -> dict:
    """masslak-archive-check prints key=<base64 value> lines (base64, so COPY reads any text unchanged)."""
    out = {}
    for line in lines:
        key, _, value = line.partition("=")
        if key:
            out[key] = base64.b64decode(value).decode(errors="replace").strip() if value else ""
    return out


async def gather(conn: asyncpg.Connection) -> Facts:
    f = Facts()
    f.ssl = await conn.fetchval("SHOW ssl")
    f.connection_encrypted = bool(await conn.fetchval("SELECT ssl FROM pg_stat_ssl WHERE pid = pg_backend_pid()"))
    f.hba = [dict(r) for r in await conn.fetch(
        "SELECT line_number, type, database, user_name, address, auth_method, options, error FROM pg_hba_file_rules")]
    f.sync_standbys = await conn.fetchval(
        "SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming' AND sync_state IN ('sync', 'quorum')")
    f.archive_mode = await conn.fetchval("SHOW archive_mode")
    f.archive_command = await conn.fetchval("SHOW archive_command")
    try:
        async with conn.transaction():
            await conn.execute("CREATE TEMPORARY TABLE masslak_archive_check (line text) ON COMMIT DROP")
            await conn.execute(f"COPY masslak_archive_check FROM PROGRAM '{ARCHIVE_CHECK}'")
            lines = [r["line"] for r in await conn.fetch("SELECT line FROM masslak_archive_check")]
        f.archive_check = parse_archive_check(lines)
    except asyncpg.PostgresError as exc:
        f.archive_check_error = str(exc).splitlines()[0][:200]
    return f


# Like every step of the migration (deploy/migrate.sh), the preflight never waits for the standby: with zero data loss
# on and the standby stopped, the commit of its temporary table would otherwise wait for it, and the standby itself
# starts only after the migration (asyncpg does not read PGOPTIONS, so it is set here).
LOCAL_COMMIT = {"synchronous_commit": "local"}


async def run(url: str | None) -> list[str]:
    conn = await (asyncpg.connect(url, server_settings=LOCAL_COMMIT) if url else asyncpg.connect(server_settings=LOCAL_COMMIT))
    try:
        facts = await gather(conn)
    finally:
        await conn.close()
    gather_layout(facts)
    await asyncio.to_thread(gather_files, facts)
    return evaluate(facts)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--owner-url", default=os.environ.get("MASSLAK_OWNER_URL"))
    args = ap.parse_args()
    problems = asyncio.run(run(args.owner_url))
    if problems:
        print("production preflight refused:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        sys.exit(1)
    print("production preflight passed: TLS only, archiving proven to an off-host repository, pgoutput only; "
          "files in object storage are versioned and locked; the database layout is "
          + ("two hosts with a synchronous standby" if os.environ.get("MASSLAK_DB_LAYOUT") == "ha" else "one host, accepted"))


if __name__ == "__main__":
    main()
