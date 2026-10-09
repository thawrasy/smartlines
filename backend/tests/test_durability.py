"""Release 1.48.0, package D (review of release 1.47.0): a restore proves the database and the stored files belong to the
same moment (R-44), and the database reports the backups and the durability the owner chose (decision 1, R-41)."""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from test_e2e import OWNER_URL, owner_sql

BACKEND = Path(__file__).resolve().parents[1]
pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")


def files_check(*args) -> tuple[int, dict]:
    r = subprocess.run([sys.executable, "-m", "app.tools.files_check", *args], cwd=BACKEND, env=os.environ,
                       capture_output=True, text=True, timeout=300)
    return r.returncode, json.loads(r.stdout)


def test_files_check_finds_a_file_missing_or_changed_after_a_restore():
    from app.config import get_settings
    if get_settings().files_backend != "local":
        pytest.skip("the tampering below works on the volume store")
    key = owner_sql("SELECT storage_key FROM ref.file_object ORDER BY id DESC LIMIT 1")
    if key is None:
        pytest.skip("no stored file yet")
    rc, report = files_check()
    assert rc == 0 and report["checked"] >= 1 and report["ok"] == report["checked"], report
    path = (BACKEND / get_settings().files_dir / key).resolve()
    original = path.read_bytes()
    try:
        path.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))          # one bit changed: it no longer decrypts
        rc, report = files_check()
        assert rc == 1 and key in report["undecryptable"] + report["different"], report
        path.unlink()                                                       # gone, as after a restore from another time
        rc, report = files_check()
        assert rc == 1 and key in report["missing"], report
    finally:
        path.write_bytes(original)
    assert files_check("--sample", "5")[0] == 0


def test_the_database_reports_backups_and_durability():
    rows = json.loads(owner_sql(
        "SELECT json_agg(json_build_object('metric', metric, 'copy', labels ->> 'copy'))::text FROM sys.durability_metrics()"))
    metrics = {(r["metric"], r["copy"]) for r in rows}
    assert {("masslak_backup_last_success_age_seconds", "local"), ("masslak_backup_last_success_age_seconds", "offsite"),
            ("masslak_backup_last_failed", "offsite"), ("masslak_db_commits_wait_for_standby", None)} <= metrics
