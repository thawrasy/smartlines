"""Acceptance tests of the database architecture review (Masslak_Database_Architecture_Review_AR_v1.0, section 6)
that need the running API. The database-only rows of the matrix are in db/tests/run_tests.sql (section 1039)."""
import asyncio
import json
import os
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

import asyncpg
import pytest

from test_e2e import free_seats, hold, login, new_passenger, owner_sql, pax, trip  # noqa: F401, F811  (pax and trip are fixtures)

BACKEND = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def test_seat_contention_one_seat_one_winner(trip):
    """Twenty people press "hold" on the same seat at the same moment: exactly one gets it, nobody gets half of it."""
    people = [new_passenger() for _ in range(20)]
    seat = free_seats(people[0], trip, 1)
    with ThreadPoolExecutor(max_workers=20) as pool:
        results = list(pool.map(lambda c: hold(c, trip, seat), people))
    codes = sorted(r.status_code for r in results)
    assert codes.count(201) == 1 and codes.count(409) == 19, codes
    assert all(r.json()["error"]["code"] == "SEAT_TAKEN" for r in results if r.status_code == 409)
    winner = next((c, r) for c, r in zip(people, results) if r.status_code == 201)
    assert winner[0].delete(f"/api/holds/{winner[1].json()['hold_token']}").json()["released_seats"] == 1


def api_role_counts(scope: str, *tables: str) -> list[int]:
    """Counts rows as the API's own database role (subject to row-level security) under a context without a user."""
    async def run():
        conn = await asyncpg.connect(os.environ["MASSLAK_DATABASE_URL"])
        try:
            async with conn.transaction():
                await conn.execute("SELECT sys.set_context(NULL, NULL, $1)", scope)
                return [await conn.fetchval(f"SELECT count(*) FROM {t}") for t in tables]
        finally:
            await conn.close()
    return asyncio.run(run())


def test_sign_in_runs_in_the_narrow_auth_scope():
    """Sign-in reads accounts in the AUTH scope and nothing more; an anonymous request reads no account, session or
    person (before 1039 an empty context could read every session)."""
    c = login("passenger@masslak.test", "PASSENGER")
    assert c.get("/api/auth/me").status_code == 200
    users, sessions, wallets = api_role_counts("AUTH", "iam.app_user", "iam.user_session", "fin.wallet")
    assert users > 0 and sessions > 0 and wallets == 0
    assert api_role_counts("PASSENGER", "iam.app_user", "iam.user_session", "iam.auth_token") == [0, 0, 0]


def test_reports_say_what_moment_and_release_they_reflect():
    admin = login("admin@masslak.test", "PLATFORM")
    r = admin.post("/api/reports/export", json={"code": "ops.load_factor", "format": "JSON",
                                               "params": {"from": "2026-01-01", "to": "2026-12-31"}})
    assert r.status_code == 200, r.text
    doc = json.loads(r.content)
    assert doc["data_as_of"] and doc["source_version"].startswith("masslak-db-") and doc["timezone"] == "Asia/Damascus"
    preview = admin.post("/api/reports/run", json={"code": "ops.load_factor", "params": {"from": "2026-01-01", "to": "2026-12-31"}}).json()
    assert preview["data_as_of"] and preview["currency"] == "SYP"


def test_daily_maintenance_reconciles_the_ledger():
    before = owner_sql("SELECT count(*) FROM fin.wallet_reconciliation")
    run = subprocess.run([sys.executable, "-m", "app.modules.notify.worker", "--maintenance"], cwd=BACKEND,
                         capture_output=True, text=True, timeout=120, env=os.environ.copy())
    assert run.returncode == 0, run.stderr
    last = owner_sql("SELECT mismatches FROM fin.wallet_reconciliation ORDER BY id DESC LIMIT 1")
    assert owner_sql("SELECT count(*) FROM fin.wallet_reconciliation") == before + 1 and last == 0


def test_key_rotation_tool_finds_nothing_under_retired_keys():
    run = subprocess.run([sys.executable, "-m", "app.tools.rekey"], cwd=BACKEND, capture_output=True, text=True,
                         timeout=120, env=os.environ.copy())
    assert run.returncode == 0, run.stderr
    assert "under a retired key" in run.stderr


def test_production_refuses_to_start_without_real_keys(monkeypatch):
    """Outside the sandbox there is no fallback to keys derived from the signing secret (review 3.12)."""
    sys.path.insert(0, BACKEND)
    from app import config, crypto
    monkeypatch.delenv("MASSLAK_FIELD_KEYS", raising=False)
    monkeypatch.delenv("MASSLAK_BIDX_KEY", raising=False)
    monkeypatch.setenv("MASSLAK_SANDBOX", "false")
    config.get_settings.cache_clear()
    try:
        with pytest.raises(crypto.CryptoConfigError):
            crypto._bidx_key()
    finally:
        config.get_settings.cache_clear()


def test_restricted_reads_leave_a_decision_record(pax):  # noqa: F811
    """Revealing an IBAN for a payout or document numbers to an authority writes sec.policy_decision; the earlier
    payout and border tests of this suite made such reads."""
    rows = owner_sql("SELECT count(*) FROM sec.policy_decision WHERE resource IN ('iam.bank_account.iban', 'brd.manifest_person.doc_no')")
    if rows == 0:
        pytest.skip("run with the payout and integration tests, which perform the reads")
    assert owner_sql("SELECT count(*) FROM sec.policy_decision WHERE decision = 'ALLOW' AND purpose_code IS NOT NULL") > 0
