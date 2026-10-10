"""The production profile (reviews of October 2026, package 2).

H-02, H-05, H-10  the migration's preflight decides from the database's own facts (app.tools.preflight)
H-05, H-06        the API and the worker refuse to start outside the profile (app.profile)
H-06              the data keys are wrapped by the key service the first time, adopting a key the environment still
                  gives (app.tools.keys bootstrap), and each container receives only its part of deploy/.env
The database and the containers themselves are exercised by the CI job "Production installation".
"""
import asyncio
import base64
import os
import subprocess
from pathlib import Path

import asyncpg
import pytest

from app import config, kms, profile
from app.guard import GUARDED_SETTINGS
from app.tools import keys, preflight

OWNER_URL = os.environ.get("MASSLAK_OWNER_URL")
REPO = Path(__file__).resolve().parents[2]


# ------------------------------------------------------------------ the preflight's decisions
def hba(n, kind, users, address, method, database=("all",), options=()):
    return {"line_number": n, "type": kind, "database": list(database), "user_name": list(users), "address": address,
            "auth_method": method, "options": list(options), "error": None}


# the lines deploy/production/db/entry.sh writes, as pg_hba_file_rules shows them
PROFILE_HBA = [
    hba(3, "local", ["all"], None, "trust"),
    hba(4, "hostssl", ["masslak_cdc"], "192.0.2.10", "scram-sha-256", options=["clientcert=verify-full"]),
    hba(5, "host", ["masslak_cdc"], "all", "reject"),
    hba(6, "hostssl", ["replicator"], "samenet", "scram-sha-256", database=["replication"]),
    hba(7, "host", ["all"], "all", "reject", database=["replication"]),
    hba(8, "hostssl", ["all"], "samenet", "scram-sha-256"),
    hba(9, "host", ["all"], "all", "reject"),
]


def good() -> preflight.Facts:
    return preflight.Facts(ssl="on", connection_encrypted=True, hba=[dict(r) for r in PROFILE_HBA], archive_mode="on",
                           archive_command="pgbackrest --stanza=masslak archive-push %p",
                           archive_check={"repo_type": "s3", "repo_host": "", "check_ok": "1", "plugins": ""},
                           db_layout="ha", sync_standbys=1, guarded_enforced=len(GUARDED_SETTINGS))


def test_the_profile_as_written_passes():
    assert preflight.evaluate(good()) == []


@pytest.mark.parametrize("change, expected", [
    (lambda f: setattr(f, "ssl", "off"), "TLS is off"),
    (lambda f: setattr(f, "connection_encrypted", False), "not encrypted"),
    (lambda f: f.hba.insert(1, hba(2, "host", ["all"], "samenet", "scram-sha-256")), "accepts host connections"),
    (lambda f: f.hba.insert(1, hba(2, "hostssl", ["all"], "samenet", "trust")), "signs in with trust"),
    # a generic line before the warehouse's own lines lets it in without its certificate (first match wins)
    (lambda f: f.hba.insert(1, hba(2, "hostssl", ["all"], "samenet", "scram-sha-256")), "without a client certificate"),
    (lambda f: f.hba.__setitem__(1, hba(4, "hostssl", ["masslak_cdc"], "192.0.2.10", "scram-sha-256")), "without a client certificate"),
    (lambda f: setattr(f, "archive_mode", "off"), "WAL archiving is off"),
    (lambda f: setattr(f, "archive_command", "cp %p /mnt/wal/%f"), "not pgBackRest"),
    (lambda f: f.archive_check.update(repo_type="posix"), "on this host"),
    (lambda f: f.archive_check.update(check_ok="0", check_output="ERROR: [082]: WAL segment was not archived"),
     "could not archive a WAL segment"),
    (lambda f: f.archive_check.update(plugins="test_decoding"), "decoding plugins"),
    (lambda f: setattr(f, "archive_check", None), "not the production database image"),
])
def test_each_gap_is_named(change, expected):
    f = good()
    change(f)
    problems = preflight.evaluate(f)
    assert any(expected in p for p in problems), problems


LOCKED = {"versioning": "Enabled", "object_lock": True, "retention_mode": "GOVERNANCE", "retention_days": 30}


@pytest.mark.parametrize("protection, error, expected", [
    ({**LOCKED, "versioning": "Suspended"}, "", "does not keep old versions"),
    ({**LOCKED, "object_lock": False, "retention_days": 0}, "", "no Object Lock"),
    ({**LOCKED, "retention_days": 7}, "", "default retention is 7 days"),
    (None, "FILE_STORE_UNAVAILABLE: GET failed (URLError)", "cannot be read (FILE_STORE_UNAVAILABLE"),
])
def test_files_in_object_storage_must_be_versioned_and_locked(protection, error, expected):
    """H-04: a restore can bring the files back to a backup's moment only from a bucket that kept and locked them."""
    f = good()
    f.files_backend, f.files_protection, f.files_error, f.backup_keep_days = "s3", protection, error, 14
    problems = preflight.evaluate(f)
    assert len(problems) == 1 and expected in problems[0], problems
    f.files_protection = LOCKED
    assert preflight.evaluate(f) == []
    f.files_backend, f.files_protection = "local", None          # files on the volume travel in the backup itself
    assert preflight.evaluate(f) == []


@pytest.mark.parametrize("layout, accepted, standbys, expected", [
    ("ha", "", 0, "no synchronous standby streams"),
    ("single", "", 1, "the database runs on one host"),
    ("single", "   ", 1, "the database runs on one host"),
    ("two", "", 1, "MASSLAK_DB_LAYOUT is 'two'"),
])
def test_the_database_runs_on_two_hosts_or_one_the_owner_accepted(layout, accepted, standbys, expected):
    """H-01: two database hosts with a synchronous standby, or the owner's written acceptance of one host."""
    f = good()
    f.db_layout, f.single_host_accepted, f.sync_standbys = layout, accepted, standbys
    problems = preflight.evaluate(f)
    assert len(problems) == 1 and expected in problems[0], problems
    f.db_layout, f.single_host_accepted = "single", "owner, 2026-10-10: pilot on one host"
    assert preflight.evaluate(f) == []


def test_the_layout_comes_from_the_environment(monkeypatch):
    f = preflight.Facts()
    monkeypatch.delenv("MASSLAK_DB_LAYOUT", raising=False)
    preflight.gather_layout(f)
    assert f.db_layout == "single"                              # unset: one host, which then needs the acceptance
    monkeypatch.setenv("MASSLAK_DB_LAYOUT", "ha")
    preflight.gather_layout(f)
    assert f.db_layout == "ha"


def test_a_repository_host_is_off_this_host():
    f = good()
    f.archive_check.update(repo_type="posix", repo_host="backup.internal")
    assert preflight.evaluate(f) == []


def test_the_archive_check_lines_are_read_as_written():
    enc = lambda s: base64.b64encode(s.encode()).decode()   # noqa: E731
    output = "a\tb = c"
    lines = [f"repo_type={enc('s3')}", "repo_host=", f"check_ok={enc('1')}", f"check_output={enc(output)}"]
    assert preflight.parse_archive_check(lines) == {"repo_type": "s3", "repo_host": "", "check_ok": "1", "check_output": "a\tb = c"}


# ------------------------------------------------------------------ the API and the worker at start-up
URL = "postgresql://masslak_api:x@pgbouncer:6432/masslak?sslmode=verify-full&sslrootcert=/etc/masslak/trust/ca.crt"
ENV = {"MASSLAK_PROFILE": "production", "MASSLAK_KMS_PROVIDER": "vault",
       "MASSLAK_QR_KEYS": "q202610:" + "A" * 43 + "=", "MASSLAK_DOCUMENT_KEYS": "d202610:" + "B" * 43 + "=",
       "MASSLAK_LOOKUP_KEYS": "l202610:" + "C" * 43 + "="}


@pytest.fixture
def production_urls(monkeypatch):
    s = config.get_settings()
    for name in ("database_url", "audit_database_url", "reports_database_url"):
        monkeypatch.setattr(s, name, URL)
    monkeypatch.setattr(s, "cookie_secure", True)          # the CI job runs the API over plain HTTP (false there)
    for name in ("telemetry_database_url", "telemetry_upkeep_url"):    # a CI step may point at its telemetry database
        monkeypatch.setattr(s, name, "")
    return s


def test_a_complete_profile_starts(production_urls):
    assert profile.problems(ENV) == []


@pytest.mark.parametrize("env, expected", [
    ({"MASSLAK_KMS_PROVIDER": "vault"}, "does not run the production profile"),
    ({**ENV, "MASSLAK_KMS_PROVIDER": "local"}, "MASSLAK_KMS_PROVIDER=vault"),
    ({**ENV, "MASSLAK_FIELD_KEYS": "kms://masslak/field/restricted/v1=AAAA"}, "data keys sit in this process"),
    ({**ENV, "MASSLAK_BIDX_KEY": "AAAA"}, "data keys sit in this process"),
    ({**ENV, "POSTGRES_PASSWORD": "owner"}, "must not hold"),
    ({**ENV, "PGBACKREST_REPO1_CIPHER_PASS": "x"}, "must not hold"),
    ({**ENV, "MASSLAK_PATRONI_REST_PASSWORD": "x"}, "must not hold"),
    ({k: v for k, v in ENV.items() if k != "MASSLAK_QR_KEYS"}, "MASSLAK_QR_KEYS must name a key of its own"),
    ({**ENV, "MASSLAK_DOCUMENT_KEYS": "s1,d1:" + "B" * 43 + "="}, "MASSLAK_DOCUMENT_KEYS must name a key of its own"),
    ({k: v for k, v in ENV.items() if k != "MASSLAK_LOOKUP_KEYS"}, "MASSLAK_LOOKUP_KEYS must name a key of its own"),
])
def test_each_gap_stops_the_start(production_urls, env, expected):
    assert any(expected in p for p in profile.problems(env)), profile.problems(env)


def test_a_session_cookie_sent_over_plain_http_stops_the_start(production_urls, monkeypatch):
    # reviews of release 1.49.0: the default is right, a wrong environment value used to pass unnoticed
    monkeypatch.setattr(production_urls, "cookie_secure", False)
    assert any("MASSLAK_COOKIE_SECURE=false" in p for p in profile.problems(ENV))


def test_the_telemetry_database_must_be_reached_over_checked_tls(production_urls, monkeypatch):
    # reviews of release 1.49.0: the one connection the profile did not check
    monkeypatch.setattr(production_urls, "telemetry_database_url", "")
    monkeypatch.setattr(production_urls, "telemetry_upkeep_url", "")
    assert profile.problems(ENV) == []                       # no telemetry database: nothing to check
    monkeypatch.setattr(production_urls, "telemetry_database_url", "postgresql://masslak_tel:x@telemetry/masslak_tel")
    assert any("MASSLAK_TELEMETRY_DATABASE_URL" in p for p in profile.problems(ENV))
    monkeypatch.setattr(production_urls, "telemetry_database_url", URL.replace("pgbouncer:6432/masslak", "telemetry/masslak_tel"))
    monkeypatch.setattr(production_urls, "telemetry_upkeep_url", "postgresql://masslak_tel_upkeep:x@telemetry/masslak_tel?sslmode=require")
    found = profile.problems(ENV)
    assert not any("MASSLAK_TELEMETRY_DATABASE_URL" in p for p in found)
    assert any("MASSLAK_TELEMETRY_UPKEEP_URL" in p for p in found)


def test_the_production_telemetry_overlay_runs_tls_and_checks_it():
    root = Path(__file__).resolve().parents[2]
    overlay = (root / "deploy/production/docker-compose.telemetry.yml").read_text(encoding="utf-8")
    assert "image: masslak-db:" in overlay and '"-c", "ssl=on"' in overlay and "ssl_min_protocol_version=TLSv1.3" in overlay
    assert overlay.count("sslmode=verify-full&sslrootcert=/etc/masslak/trust/ca.crt") == 4    # migrate, app, worker (two)
    assert "./deploy/production/tls/telemetry.crt:/tls-src/server.crt:ro" in overlay
    init = (root / "deploy/production/init.sh").read_text(encoding="utf-8")
    assert "issue telemetry telemetry" in init and "deploy/production/docker-compose.telemetry.yml" in init


def test_a_connection_that_does_not_check_the_certificate_stops_the_start(production_urls, monkeypatch):
    monkeypatch.setattr(production_urls, "reports_database_url", URL.replace("verify-full", "require"))
    assert any("MASSLAK_REPORTS_DATABASE_URL" in p for p in profile.problems(ENV))
    monkeypatch.setattr(production_urls, "reports_database_url", URL.split("&")[0])        # no authority given
    assert any("MASSLAK_REPORTS_DATABASE_URL" in p for p in profile.problems(ENV))


def test_test_servers_are_not_held_to_the_profile(monkeypatch):
    monkeypatch.setattr(config, "is_test_server", lambda: True)
    monkeypatch.setattr(profile, "is_test_server", lambda: True)
    profile.require_in_production()                 # the CI and development servers run without it
    monkeypatch.setattr(profile, "is_test_server", lambda: False)
    with pytest.raises(RuntimeError, match="production profile is incomplete"):
        profile.require_in_production()


def test_vault_is_reached_through_the_egress_proxy_unless_local():
    remote = kms.VaultTransit("https://vault.internal:8200", "t", proxy="http://egress:3128")
    local = kms.VaultTransit("http://127.0.0.1:8200", "t", proxy="http://egress:3128")
    # an empty ProxyHandler leaves the opener without any proxy, the environment's included
    proxies = lambda w: next((h.proxies for h in w._opener.handlers if hasattr(h, "proxies")), {})   # noqa: E731
    assert proxies(remote) == {"https": "http://egress:3128"} and proxies(local) == {}


# ------------------------------------------------------------------ data keys wrapped by the key service
class _Rollback(Exception):
    pass


def _bootstrap(env: dict, monkeypatch):
    for k in ("MASSLAK_FIELD_KEYS", "MASSLAK_BIDX_KEY"):
        monkeypatch.delenv(k, raising=False)
    for k, v in env.items():
        monkeypatch.setenv(k, v)
    wrapper = kms.LocalKek(os.urandom(32))

    async def run():
        conn = await asyncpg.connect(OWNER_URL)
        try:
            async with conn.transaction():
                lines = await keys.bootstrap(conn, wrapper, "masslak-field")
                rows = await conn.fetch("SELECT key_ref, purpose, wrapped_dek, kms_key_id FROM sec.key_registry "
                                        "WHERE wrapped_dek IS NOT NULL ORDER BY id")
                raise _Rollback((lines, rows))       # never kept: the shared test database stays as it was
        except _Rollback as r:
            return r.args[0]
        finally:
            await conn.close()
    return wrapper, asyncio.run(run())


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_a_key_that_sealed_rows_is_never_replaced_by_a_new_one(monkeypatch):
    with pytest.raises(kms.KmsError, match="rows are sealed under kms://masslak/field/restricted/v1"):
        _bootstrap({}, monkeypatch)


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
def test_keys_the_environment_gives_are_adopted_and_open_with_the_key_service(monkeypatch):
    given = {ref: os.urandom(32) for ref in ("kms://masslak/field/restricted/v1", "kms://masslak/field/confidential/v1",
                                              "kms://masslak/webhook/v1")}
    bidx = os.urandom(32)
    env = {"MASSLAK_FIELD_KEYS": ",".join(f"{r}={base64.b64encode(k).decode()}" for r, k in given.items()),
           "MASSLAK_BIDX_KEY": base64.b64encode(bidx).decode()}
    wrapper, (lines, rows) = _bootstrap(env, monkeypatch)
    opened = {r["key_ref"]: wrapper.unwrap(bytes(r["wrapped_dek"]), r["key_ref"], r["kms_key_id"]) for r in rows}
    assert {r["kms_key_id"] for r in rows} == {"masslak-field"}
    for ref, key in given.items():
        assert opened[ref] == key, ref
    assert opened["kms://masslak/bidx/v1"] == bidx
    assert all("adopted" in line for line in lines), lines


# ------------------------------------------------------------------ one environment file per container
def test_each_container_receives_only_its_part_of_the_environment(tmp_path):
    (tmp_path / "env-split.sh").write_bytes((REPO / "deploy" / "env-split.sh").read_bytes())
    lines = ["MASSLAK_ENVIRONMENT=production", "POSTGRES_USER=postgres", "POSTGRES_PASSWORD=owner",
             "MASSLAK_API_PASSWORD=api", "MASSLAK_REPLICATION_PASSWORD=repl", "MASSLAK_SIGNING_SECRET=sign",
             "MASSLAK_FIELD_KEYS=kms://x=AAAA", "MASSLAK_BIDX_KEY=BBBB", "MASSLAK_KMS_PROVIDER=vault",
             "MASSLAK_VAULT_TOKEN=tok", "PGBACKREST_REPO1_TYPE=s3", "PGBACKREST_REPO1_CIPHER_PASS=cipher",
             "MASSLAK_BACKUP_AGE_IDENTITY=/root/key", "MASSLAK_BACKUP_KEEP_DAYS=30", "MASSLAK_IMAGE_KEY=/etc/masslak/release.pub", "MASSLAK_SMS_URL=", "# a comment",
             "COMPOSE_FILE=a:b"]
    (tmp_path / ".env").write_text("\n".join(lines) + "\n")
    subprocess.run(["bash", str(tmp_path / "env-split.sh")], check=True, capture_output=True)
    read = lambda name: dict(l.split("=", 1) for l in (tmp_path / "env" / f"{name}.env").read_text().splitlines())   # noqa: E731,E741
    app, migrate, db = read("app"), read("migrate"), read("db")
    assert read("worker") == app
    assert set(app) == {"MASSLAK_ENVIRONMENT", "POSTGRES_USER", "MASSLAK_SIGNING_SECRET", "MASSLAK_KMS_PROVIDER",
                        "MASSLAK_VAULT_TOKEN"}, app
    assert {"POSTGRES_PASSWORD", "MASSLAK_FIELD_KEYS", "MASSLAK_REPLICATION_PASSWORD"} <= set(migrate)
    assert not {"PGBACKREST_REPO1_CIPHER_PASS", "MASSLAK_BACKUP_AGE_IDENTITY", "COMPOSE_FILE", "MASSLAK_IMAGE_KEY"} & set(migrate)
    assert migrate["MASSLAK_BACKUP_KEEP_DAYS"] == "30"     # its preflight compares the file bucket's lock with it (H-04)
    assert set(db) == {"POSTGRES_USER", "POSTGRES_PASSWORD", "PGBACKREST_REPO1_TYPE", "PGBACKREST_REPO1_CIPHER_PASS"}
    assert oct((tmp_path / "env" / "app.env").stat().st_mode & 0o777) == "0o600"
    # two database hosts (H-01): the proxies get the owner's login only, pgBackRest's settings go to the hosts' bundles;
    # the cluster's REST password and etcd token reach no container through these files
    (tmp_path / ".env").write_text("\n".join(lines + ["MASSLAK_DB_LAYOUT=ha", "MASSLAK_PATRONI_REST_PASSWORD=rest",
                                                      "MASSLAK_ETCD_TOKEN=tok"]) + "\n")
    subprocess.run(["bash", str(tmp_path / "env-split.sh")], check=True, capture_output=True)
    assert set(read("db")) == {"POSTGRES_USER", "POSTGRES_PASSWORD"}
    assert not {"MASSLAK_PATRONI_REST_PASSWORD", "MASSLAK_ETCD_TOKEN"} & (set(read("app")) | set(read("migrate")))
    assert read("migrate")["MASSLAK_DB_LAYOUT"] == "ha"           # its preflight checks the layout (H-01)
    # a test server's API keeps its data keys (there is no key service there)
    (tmp_path / ".env").write_text("\n".join(line.replace("production", "development") for line in lines) + "\n")
    subprocess.run(["bash", str(tmp_path / "env-split.sh")], check=True, capture_output=True)
    assert {"MASSLAK_FIELD_KEYS", "MASSLAK_BIDX_KEY"} <= set(read("app")) and "POSTGRES_PASSWORD" not in read("app")
