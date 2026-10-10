"""Stage A of the expert review of October 2026 (docs/operations/REVIEW_STAGE_A.md): signing keys checked at start,
top-up replays scoped to the payer, readiness, the database role's time limits, and the deployment scripts (update,
backup) refusing unsafe states. The schema drift refusal of db/upgrade.sh and the generated README figures are checked
by the database job of CI."""
import asyncio
import base64
import json
import os
import shutil
import subprocess
import uuid

import asyncpg
import pytest

from test_e2e import client, new_passenger, owner_sql

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(BACKEND)
GOOD_SECRET = base64.b64encode(os.urandom(48)).decode()
GOOD_TICKET_KEY = base64.b64encode(os.urandom(32)).decode()


# ------------------------------------------------------------------ A1 signing keys
def test_signing_key_rules():
    from app.security import DEFAULT_SIGNING_SECRET, signing_key_problems
    assert signing_key_problems(GOOD_SECRET, GOOD_TICKET_KEY) == []
    for weak in ("", DEFAULT_SIGNING_SECRET, "ci-signing-secret-not-for-production-use", "Short-but-mixed-7x", "ab" * 20):
        assert signing_key_problems(weak, GOOD_TICKET_KEY), weak
    assert signing_key_problems(GOOD_SECRET, "") == ["MASSLAK_TICKET_SIGNING_KEY is not set"]
    for bad in ("not base64 at all", base64.b64encode(b"x" * 16).decode()):
        assert signing_key_problems(GOOD_SECRET, bad) == ["MASSLAK_TICKET_SIGNING_KEY must be base64 of 32 bytes"]


def test_production_refuses_to_start_with_weak_keys(monkeypatch):
    """Outside the sandbox the API and the worker stop at start on a default, short or missing key; the ticket key
    has no fallback derived from the signing secret."""
    from app import config, security
    monkeypatch.setenv("MASSLAK_SANDBOX", "false")
    monkeypatch.setenv("MASSLAK_SIGNING_SECRET", security.DEFAULT_SIGNING_SECRET)
    monkeypatch.setenv("MASSLAK_TICKET_SIGNING_KEY", GOOD_TICKET_KEY)
    config.get_settings.cache_clear()
    try:
        with pytest.raises(security.KeyConfigError, match="placeholder"):
            security.require_keys_in_production()
        monkeypatch.setenv("MASSLAK_SIGNING_SECRET", GOOD_SECRET)
        config.get_settings.cache_clear()
        security.require_keys_in_production()
        monkeypatch.delenv("MASSLAK_TICKET_SIGNING_KEY")
        with pytest.raises(security.KeyConfigError, match="TICKET_SIGNING_KEY is not set"):
            security.require_keys_in_production()
        security._ticket_key.cache_clear()
        with pytest.raises(security.KeyConfigError):
            security._ticket_key()
        monkeypatch.setenv("MASSLAK_SANDBOX", "true")              # the sandbox keeps its development fallbacks
        config.get_settings.cache_clear()
        security.require_keys_in_production()
    finally:
        config.get_settings.cache_clear()
        security._ticket_key.cache_clear()


# ------------------------------------------------------------------ A2 top-up replays
def test_topup_replay_is_scoped_to_the_payer():
    a, b = new_passenger(), new_passenger()
    key = uuid.uuid4().hex
    first = a.post("/api/wallet/topup", json={"amount": 5000, "idempotency_key": key})
    assert first.status_code == 200 and first.json()["status"] == "SUCCESS", first.text
    assert a.post("/api/wallet/topup", json={"amount": 5000, "idempotency_key": key}).json() == {"status": "SUCCESS", "replayed": True}
    other = b.post("/api/wallet/topup", json={"amount": 5000, "idempotency_key": key})
    assert other.status_code == 409 and other.json()["error"]["code"] == "ALREADY_EXISTS", other.text
    assert "replayed" not in other.text and "SUCCESS" not in other.text
    assert b.get("/api/wallet").json()["balance"] == 0 and a.get("/api/wallet").json()["balance"] == 5000


# ------------------------------------------------------------------ A6 readiness
def test_readiness_checks_the_database_and_the_schema():
    c = client()
    assert c.get("/api/health").json() == {"ok": True}
    r = c.get("/api/ready")
    assert r.status_code == 200, r.text
    assert r.json() == {"ready": True, "checks": {"database": True, "schema": True, "audit_database": True,
                                                    "reports_replica": True, "context": True,
                                                    "settings_guard": True, "constraints": True}}
    from app.readiness import shipped_schema_files
    shipped = shipped_schema_files()
    assert len(shipped) > 60 and shipped <= set(owner_sql("SELECT array_agg(file) FROM sys.schema_file"))


def test_readiness_fails_while_the_code_is_newer_than_the_schema(tmp_path, monkeypatch):
    from app import db, readiness
    for name in readiness.shipped_schema_files():
        (tmp_path / name).write_text("")
    (tmp_path / "9999_not_applied_yet.sql").write_text("")
    monkeypatch.setattr(readiness, "SCHEMA_DIR", tmp_path)

    async def run():
        await db.open_pools()
        try:
            readiness._cache = None
            return await readiness.readiness()
        finally:
            readiness._cache = None
            await db.close_pools()
    out = asyncio.run(run())
    assert out["ready"] is False and out["checks"]["schema"] is False and out["checks"]["database"] is True


# ------------------------------------------------------------------ A7 time limits
def test_application_roles_have_time_limits():
    async def show(url):
        conn = await asyncpg.connect(url)
        try:
            return [await conn.fetchval(f"SHOW {n}") for n in ("statement_timeout", "lock_timeout",
                                                               "idle_in_transaction_session_timeout")]
        finally:
            await conn.close()
    assert asyncio.run(show(os.environ["MASSLAK_DATABASE_URL"])) == ["30s", "5s", "2min"]
    assert asyncio.run(show(os.environ["MASSLAK_AUDIT_DATABASE_URL"])) == ["30s", "5s", "2min"]


def test_a_lock_held_too_long_answers_service_busy():
    """A migration or a stuck job holds a lock: the request gives up after 5 s with 503 SERVICE_BUSY instead of
    queueing behind it with every other request."""
    async def run():
        owner = await asyncpg.connect(os.environ["MASSLAK_OWNER_URL"])
        try:
            async with owner.transaction():
                await owner.execute("LOCK TABLE ref.city IN ACCESS EXCLUSIVE MODE")
                return await asyncio.to_thread(lambda: client().get("/api/ref"))
        finally:
            await owner.close()
    r = asyncio.run(run())
    assert r.status_code == 503 and r.json()["error"]["code"] == "SERVICE_BUSY", r.text
    assert r.headers["retry-after"] == "2"
    assert client().get("/api/ref").status_code == 200


def test_database_time_limits_map_to_service_busy():
    from app.errors import db_error_handler
    for exc in (asyncpg.QueryCanceledError("canceling statement due to statement timeout"),
                asyncpg.LockNotAvailableError("canceling statement due to lock timeout"),
                asyncpg.IdleInTransactionSessionTimeoutError("terminating connection due to idle-in-transaction timeout")):
        r = asyncio.run(db_error_handler(None, exc))
        assert r.status_code == 503 and json.loads(r.body)["error"]["code"] == "SERVICE_BUSY"


# ------------------------------------------------------------------ A3, A4 deployment scripts
def test_backup_refuses_plain_files_on_a_production_server(tmp_path):
    deploy = tmp_path / "deploy"
    deploy.mkdir()
    shutil.copy(os.path.join(ROOT, "deploy", "backup.sh"), deploy / "backup.sh")
    target = tmp_path / "backups"

    def run(env_lines):
        (deploy / ".env").write_text("\n".join([f"MASSLAK_BACKUP_DIR={target}", *env_lines]) + "\n")
        return subprocess.run(["bash", str(deploy / "backup.sh")], capture_output=True, text=True, timeout=60)
    r = run(["MASSLAK_SANDBOX=false"])
    assert r.returncode == 2 and "backup refused" in r.stderr and "MASSLAK_BACKUP_AGE_RECIPIENT" in r.stderr
    r = run(["MASSLAK_SANDBOX=false", "MASSLAK_BACKUP_AGE_RECIPIENT=not-a-key"])
    assert r.returncode == 2 and "backup refused" in r.stderr
    assert not target.exists()


def test_update_stops_on_an_unapproved_or_unsettled_checkout(tmp_path):
    """deploy/update.sh settles the code before the backup and the rebuild: the stand-in backup below records that it
    ran and then stops the update, so no container is touched."""
    origin, work, other = tmp_path / "origin.git", tmp_path / "server", tmp_path / "developer"

    def git(*args, cwd=work):
        return subprocess.run(["git", "-c", "user.email=t@example.com", "-c", "user.name=t", *args], cwd=cwd,
                              check=True, capture_output=True, text=True).stdout.strip()

    def update(*args):
        return subprocess.run(["bash", "deploy/update.sh", *args], cwd=work, capture_output=True, text=True, timeout=60)
    git("init", "-q", "--bare", "-b", "main", str(origin), cwd=tmp_path)
    git("clone", "-q", str(origin), str(work), cwd=tmp_path)
    (work / "deploy").mkdir()
    shutil.copy(os.path.join(ROOT, "deploy", "update.sh"), work / "deploy" / "update.sh")
    (work / "deploy" / "backup.sh").write_text('#!/bin/sh\ntouch "$(dirname "$0")/../BACKUP_RAN"\nexit 1\n')
    os.chmod(work / "deploy" / "backup.sh", 0o755)
    (work / "deploy" / "env-split.sh").write_text("#!/bin/sh\nexit 0\n")      # writes deploy/env/*.env on a server
    os.chmod(work / "deploy" / "env-split.sh", 0o755)
    (work / "deploy" / ".env").write_text("MASSLAK_ENVIRONMENT=development\nMASSLAK_REPLICATION_PASSWORD=x\n")  # untracked
    git("add", "-A")
    git("commit", "-qm", "release")
    git("push", "-q", "-u", "origin", "main")
    ran = work / "BACKUP_RAN"

    r = update("--sha", "0" * 40)
    assert r.returncode == 1 and "not the approved" in r.stderr and not ran.exists(), r.stderr
    assert update("--sha", git("rev-parse", "HEAD")[:12]).returncode == 1 and ran.exists()   # checks passed
    ran.unlink()
    assert update("--sha", "abc").returncode == 1 and "12 characters" in update("--sha", "abc").stderr

    (work / "deploy" / "backup.sh").write_text("#!/bin/sh\nexit 0\n")                       # edited on the server
    r = update()
    assert r.returncode == 1 and "edited on this server" in r.stderr and not ran.exists()
    git("checkout", "--", "deploy/backup.sh")

    (work / "LOCAL").write_text("x")                                                          # a commit not on origin
    git("add", "LOCAL")
    git("commit", "-qm", "local change")
    r = update()
    assert r.returncode == 1 and "not on origin" in r.stderr and not ran.exists()

    git("clone", "-q", str(origin), str(other), cwd=tmp_path)                                 # origin moves on: diverged
    (other / "NEW").write_text("y")
    git("add", "NEW", cwd=other)
    git("commit", "-qm", "upstream change", cwd=other)
    git("push", "-q", cwd=other)
    r = update()
    assert r.returncode == 1 and "git pull failed" in r.stderr and not ran.exists()
