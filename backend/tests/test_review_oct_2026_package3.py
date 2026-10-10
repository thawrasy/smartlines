"""The reviews of October 2026, package 3: findings fixed in the application code.

M-04  a file written before its row goes again when the row's transaction does not commit; the daily sweep removes
      the files no row points to, and refuses when that many look like the wrong database
M-08  a large late period leaves the default partition in a transaction of its own, moved by the worker
M-13  a password common in leaks, a pattern, or one built on the person's own details is refused
H-08  every Python package pinned with its hashes; a production server runs only signed images, by digest, never its own
      build (the signatures themselves are checked in CI's production job)
(M-03 is in test_shared_limits.py; the object store's listing and deletion in test_file_store.py.)
"""
import asyncio
import os
import re
import subprocess
import time
import uuid
from pathlib import Path

import pytest

from app import db
from app.crypto import RESTRICTED_REF, FieldCipher
from app.modules.documents import storage
from app.security import _common, password_problem
from app.tools import files_sweep
from test_e2e import client, owner_sql

APP_URL = os.environ.get("MASSLAK_DATABASE_URL")
needs_db = pytest.mark.skipif(not APP_URL or not os.environ.get("MASSLAK_OWNER_URL"), reason="needs the database")


def _cipher() -> FieldCipher:
    return FieldCipher({7: os.urandom(32)}, {RESTRICTED_REF: 7}, os.urandom(32))


def _age(vol: storage.LocalStore, key: str, hours: float) -> None:
    then = time.time() - hours * 3600
    os.utime(vol._path(key), (then, then))


@needs_db
def test_a_file_whose_transaction_rolls_back_is_deleted_again(tmp_path, monkeypatch):
    vol = storage.LocalStore(str(tmp_path))
    monkeypatch.setattr(storage, "store", lambda: vol)
    ctx = db.Context(request_id=uuid.uuid4(), ip="127.0.0.1", scope="SYSTEM")

    async def run():
        await db.open_pools()
        try:
            with pytest.raises(RuntimeError, match="refused after the write"):
                async with db.transaction(ctx):
                    lost = await storage.put(_cipher(), b"%PDF-1.4\nrolled back")
                    assert vol.exists(lost.storage_key)
                    raise RuntimeError("refused after the write")
            assert not vol.exists(lost.storage_key)                    # gone with the transaction
            async with db.transaction(ctx):
                kept = await storage.put(_cipher(), b"%PDF-1.4\ncommitted")
            assert vol.exists(kept.storage_key)                        # a committed transaction keeps its file
            assert db.on_rollback(lambda: None) is False               # outside a transaction nothing is registered
        finally:
            await db.close_pools()
    asyncio.run(run())


@needs_db
def test_the_sweep_deletes_only_old_files_no_row_points_to(tmp_path):
    vol = storage.LocalStore(str(tmp_path))
    referenced, orphan, young = (f"{uuid.uuid4().hex[:4]}/{uuid.uuid4().hex}" for _ in range(3))
    for key in (referenced, orphan, young):
        vol.write(key, os.urandom(32))
    _age(vol, referenced, 48)
    _age(vol, orphan, 48)
    owner_sql("""INSERT INTO ref.file_object (storage_key, file_name, mime_type, size_bytes, sha256, data_class, enc_key_id)
                 VALUES ($1, 'kept.pdf', 'application/pdf', 32, '\\x00'::bytea, 'CONFIDENTIAL', 1)""", referenced)

    async def run(**kw):
        await db.open_pools()
        try:
            return await files_sweep.sweep(store=vol, **kw)
        finally:
            await db.close_pools()
    try:
        report = asyncio.run(run())
        assert report["stored"] == 3 and report["referenced"] == 1 and report["deleted"] == 0     # a report changes nothing
        assert report["unreferenced_older_than_grace"] == 1 and report["unreferenced_within_grace"] == 1
        done = asyncio.run(run(delete=True))
        assert done["deleted"] == 1 and done["sample"] == [orphan]
        assert vol.exists(referenced) and vol.exists(young) and not vol.exists(orphan)
    finally:            # the row points into this test's own folder: the platform's file checks must not meet it
        owner_sql("DELETE FROM ref.file_object WHERE storage_key = $1", referenced)


@needs_db
def test_the_sweep_refuses_when_most_files_look_unreferenced(tmp_path):
    vol = storage.LocalStore(str(tmp_path))
    for _ in range(files_sweep.MAX_FLOOR + 1):
        key = f"{uuid.uuid4().hex[:4]}/{uuid.uuid4().hex}"
        vol.write(key, b"x")
        _age(vol, key, 48)

    async def run():
        await db.open_pools()
        try:
            return await files_sweep.sweep(delete=True, store=vol)
        finally:
            await db.close_pools()
    out = asyncio.run(run())
    assert "refused" in out and out["deleted"] == 0 and len(list(vol.keys())) == files_sweep.MAX_FLOOR + 1


@needs_db
def test_the_worker_moves_a_large_late_period_on_its_own():
    from app.modules.notify import worker
    day = owner_sql("""SELECT d::date FROM generate_series(current_date + 30, current_date + 400, interval '1 day') d
                        WHERE to_regclass('sys.outbox_event_' || to_char(d, 'YYYYMMDD')) IS NULL LIMIT 1""")
    part = f"sys.outbox_event_{day:%Y%m%d}"
    owner_sql("UPDATE sys.setting SET value = '2'::jsonb WHERE key = 'partitions.inline_move_rows'")
    try:
        owner_sql("""INSERT INTO sys.outbox_event (event_type, aggregate_type, aggregate_id, payload, created_at)
                     SELECT 'test.m08', 'test', g, '{}'::jsonb, $1::date + make_interval(mins => g) FROM generate_series(1, 3) g""", day)
        # the daily upkeep's own call: three rows are more than it may move, so the day is left waiting
        assert owner_sql("SELECT sys.create_partition('sys.outbox_event', $1, $2::date::text, ($2::date + 1)::text, sys.partition_inline_limit())",
                         part, day) == -1
        assert owner_sql("SELECT count(*) FROM sys.outbox_event_default WHERE event_type = 'test.m08'") == 3

        async def run():
            await db.open_pools()
            try:
                return await worker.move_default_backlog()
            finally:
                await db.close_pools()
        moved = asyncio.run(run())
        assert any(m["rows"] == 3 and m["partition"] == part for m in moved)
        assert owner_sql("SELECT count(*) FROM sys.outbox_event_default") == 0
        assert owner_sql("SELECT count(*) FROM sys.outbox_event WHERE event_type = 'test.m08'") == 3
    finally:
        owner_sql("UPDATE sys.setting SET value = '50000'::jsonb WHERE key = 'partitions.inline_move_rows'")
        owner_sql("DELETE FROM sys.outbox_event WHERE event_type = 'test.m08'")


@pytest.mark.parametrize("password", [
    "password1234", "iloveyou1234", "Iloveyou12345", "correct horse battery staple", "qwertyuiopasdf",   # leaked
    "abcdefghijkl", "0987654321098", "1qaz2wsx3edc4rfv",                                             # runs
    "aaaaaaaaaaaa", "abababababab", "123412341234", "Abc!Abc!Abc!Abc!",                                # repeats
    "Masslak-Demo-2026", "my-masslak-account",                                                     # the platform
])
def test_common_and_patterned_passwords_are_refused(password):
    assert password_problem(password) == "PASSWORD_TOO_COMMON"


def test_the_leak_list_is_the_large_one():
    assert len(_common()) > 70_000                       # assets/passwords/README.md: 72,957 of 12+ characters
    assert all(len(p) >= 12 for p in list(_common())[:1000])


@pytest.mark.parametrize("password, personal", [
    ("samir.haddad1990", ("samir.haddad@example.com",)),
    ("Haddad-Train-2026", ("Samir Haddad",)),
    ("my0944123456pass", ("+963944123456",)),
    ("Lina-Orontes-Mill", ("lina@example.com",)),
])
def test_a_password_built_on_the_persons_details_is_refused(password, personal):
    assert password_problem(password, *personal) == "PASSWORD_TOO_PERSONAL"


def test_a_long_unguessable_password_passes():
    assert password_problem("Tr4in-to-Aleppo!", "samir.haddad@example.com", "Samir Haddad", "+963944123456") is None
    assert password_problem("short1") == "PASSWORD_TOO_SHORT"
    # short details are not taken for words: a name of three letters does not refuse a password containing it
    assert password_problem("Ali-crosses-the-river", "Ali Omar") is None


def test_registration_refuses_a_password_made_of_the_email():
    email = f"rania{uuid.uuid4().hex[:6]}@example.com"
    r = client().post("/api/auth/register", json={"full_name": "Rania Test", "email": email,
                                                  "password": email.split("@")[0] + "-2026"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "PASSWORD_TOO_PERSONAL"


# ------------------------------------------------------------------ H-08 signed images, hashed packages
REPO = Path(__file__).resolve().parents[2]


def test_every_package_of_the_image_is_pinned_with_its_hashes():
    pinned: dict[str, str] = {}
    hashes: dict[str, int] = {}
    current = None
    for line in (REPO / "backend" / "requirements.lock").read_text().splitlines():
        if m := re.match(r"([A-Za-z0-9._-]+)==([^\s;\\]+)", line):
            current = m.group(1).lower()
            pinned[current], hashes[current] = m.group(2), 0
        elif current and re.match(r"\s+--hash=sha256:[0-9a-f]{64}", line):
            hashes[current] += 1
    assert len(pinned) >= 30 and all(n > 0 for n in hashes.values()), hashes     # each one with its hashes
    for line in (REPO / "backend" / "requirements.txt").read_text().splitlines():
        if line.strip() and not line.startswith("#"):
            name, version = re.match(r"([A-Za-z0-9._-]+)(?:\[[^\]]+\])?==(\S+)", line).groups()
            assert pinned.get(name.lower()) == version, name                              # the lock follows the pins
    assert "pip install --no-cache-dir --require-hashes -r requirements.lock" in (REPO / "Dockerfile").read_text()


def _images(tmp_path, **refs):
    path = tmp_path / "IMAGES"
    path.write_text("commit=abc\nversion=v1\n" + "".join(f"{k}={v}\n" for k, v in refs.items()))
    return path


@pytest.mark.parametrize("refs, expected", [
    ({"masslak": "ghcr.io/o/masslak@sha256:" + "a" * 64, "masslak-egress": "ghcr.io/o/masslak-egress@sha256:" + "b" * 64},
     "names no masslak-db image"),
    ({"masslak": "ghcr.io/o/masslak:v1", "masslak-egress": "ghcr.io/o/masslak-egress@sha256:" + "b" * 64,
      "masslak-db": "ghcr.io/o/masslak-db@sha256:" + "c" * 64}, "names no masslak image by its digest"),
    ({"masslak": "ghcr.io/o/other@sha256:" + "a" * 64, "masslak-egress": "ghcr.io/o/masslak-egress@sha256:" + "b" * 64,
      "masslak-db": "ghcr.io/o/masslak-db@sha256:" + "c" * 64}, "names no masslak image by its digest"),
])
def test_a_release_must_name_each_image_by_its_digest(tmp_path, refs, expected):
    r = subprocess.run(["bash", str(REPO / "deploy" / "images.sh"), "verify", str(_images(tmp_path, **refs))],
                       capture_output=True, text=True)
    assert r.returncode == 1 and expected in r.stderr, r.stderr
    missing = subprocess.run(["bash", str(REPO / "deploy" / "images.sh"), "pull", str(tmp_path / "none"), "t"],
                             capture_output=True, text=True)
    assert missing.returncode == 1 and "is missing" in missing.stderr


def test_a_production_server_pulls_signed_images_and_never_builds():
    install = (REPO / "deploy" / "install.sh").read_text()
    update = (REPO / "deploy" / "update.sh").read_text()
    prod_install = install.split('if [ "$production" = true ]; then\n  # a production server runs the images', 1)[1].split("\nelse", 1)[0]
    assert "./deploy/images.sh pull IMAGES" in prod_install and "up -d --no-build" in prod_install and "--build" not in prod_install.replace("--no-build", "")
    prod_update = update.split('if [ "$production" = true ]; then\n  # the images built and signed once', 1)[1].split("\nelse", 1)[0]
    assert './deploy/images.sh pull "$images"' in prod_update and "compose build" not in prod_update
    assert 'if [ "$production" = true ]; then compose up -d --no-build;' in update
    preflight = (REPO / "deploy" / "production" / "preflight.sh").read_text()
    assert "command -v cosign" in preflight and "IMAGES is missing" in preflight


# ------------------------------------------------------------------ H-01 two database hosts
HA = REPO / "deploy" / "production" / "ha"
DBIMAGE = REPO / "deploy" / "production" / "db"
HA_ENV = ["MASSLAK_ENVIRONMENT=production", "POSTGRES_PASSWORD=owner-pw", "MASSLAK_REPLICATION_PASSWORD=repl-pw",
          "MASSLAK_DB_LAYOUT=ha", "MASSLAK_DB_HOSTS=10.0.0.11,10.0.0.12", "MASSLAK_DB_WITNESS=10.0.0.10",
          "PGBACKREST_REPO1_TYPE=s3", "PGBACKREST_REPO1_CIPHER_PASS=cipher", "MASSLAK_WAREHOUSE_ADDRESS=192.0.2.10/32",
          "MASSLAK_SIGNING_SECRET=not-for-the-database-hosts"]


def _init(tmp_path, env_lines):
    """deploy/production/init.sh on a copy of deploy/, as root would run it (chown is a no-op for a test user)."""
    import shutil
    deploy = tmp_path / "deploy"
    if not deploy.exists():
        shutil.copytree(REPO / "deploy", deploy, ignore=shutil.ignore_patterns(
            "tls", "bundles", "env", "secrets", "trust", "targets", ".env", "node_modules"))
    (deploy / ".env").write_text("\n".join(env_lines) + "\n")
    shim = tmp_path / "bin"
    shim.mkdir(exist_ok=True)
    (shim / "chown").write_text("#!/bin/sh\nexit 0\n")
    (shim / "chown").chmod(0o755)
    env = {**os.environ, "PATH": f"{shim}:{os.environ['PATH']}"}
    r = subprocess.run(["bash", str(deploy / "production" / "init.sh")], capture_output=True, text=True, env=env)
    return deploy, r


def _env_file(text: str) -> dict:
    return dict(line.split("=", 1) for line in text.splitlines() if "=" in line)


def test_the_installer_issues_the_cluster_certificate_and_a_bundle_per_database_host(tmp_path):
    import tarfile
    deploy, r = _init(tmp_path, HA_ENV)
    assert r.returncode == 0, r.stderr
    tls, env = deploy / "production" / "tls", _env_file((deploy / ".env").read_text())
    assert "deploy/production/ha/docker-compose.ha.yml" in env["COMPOSE_FILE"]
    rest_password, token = env["MASSLAK_PATRONI_REST_PASSWORD"], env["MASSLAK_ETCD_TOKEN"]
    assert len(rest_password) >= 32 and token.startswith("masslak-")
    cert = subprocess.run(["openssl", "x509", "-noout", "-ext", "subjectAltName,extendedKeyUsage", "-in", str(tls / "cluster.crt")],
                          capture_output=True, text=True, check=True).stdout
    for name in ("DNS:db,", "DNS:db-replica", "IP Address:10.0.0.11", "IP Address:10.0.0.12", "IP Address:10.0.0.10",
                 "TLS Web Server Authentication", "TLS Web Client Authentication"):
        assert name in cert, (name, cert)
    subprocess.run(["openssl", "verify", "-CAfile", str(tls / "ca.crt"), str(tls / "cluster.crt")], check=True, capture_output=True)
    witness = _env_file((deploy / "env" / "etcd.env").read_text())
    for i, address in ((1, "10.0.0.11"), (2, "10.0.0.12")):
        bundle = deploy / "production" / "ha" / "bundles" / f"db{i}.tar.gz"
        assert oct(bundle.stat().st_mode & 0o777) == "0o600"
        with tarfile.open(bundle) as t:
            names = {m.name.lstrip("./") for m in t.getmembers() if m.isfile()}
            # the cluster's certificate and key, the authority's certificate; never the authority's key or the others
            assert names == {"tls/ca.crt", "tls/cluster.crt", "tls/cluster.key", "db-host.env", "etcd.env", "images.env"}, names
            host = _env_file(t.extractfile("./db-host.env").read().decode())
            etcd = _env_file(t.extractfile("./etcd.env").read().decode())
        assert host["PATRONI_NAME"] == f"db{i}" and host["PATRONI_POSTGRESQL_LISTEN"] == f"{address}:5432"
        assert host["PATRONI_RESTAPI_CONNECT_ADDRESS"] == f"{address}:8008"
        assert host["PATRONI_ETCD3_HOSTS"] == "10.0.0.11:2379,10.0.0.12:2379,10.0.0.10:2379"
        assert (host["PATRONI_SUPERUSER_PASSWORD"], host["PATRONI_REPLICATION_PASSWORD"]) == ("owner-pw", "repl-pw")
        assert host["PATRONI_RESTAPI_PASSWORD"] == rest_password and host["PGBACKREST_REPO1_CIPHER_PASS"] == "cipher"
        assert host["MASSLAK_WAREHOUSE_ADDRESS"] == "192.0.2.10/32" and "MASSLAK_SIGNING_SECRET" not in host
        # etcd only over TLS, a client certificate required from members and clients alike
        assert etcd["ETCD_LISTEN_CLIENT_URLS"] == f"https://{address}:2379" and etcd["ETCD_NAME"] == f"db{i}"
        assert etcd["ETCD_CLIENT_CERT_AUTH"] == etcd["ETCD_PEER_CLIENT_CERT_AUTH"] == "true"
        assert etcd["ETCD_INITIAL_CLUSTER"] == witness["ETCD_INITIAL_CLUSTER"] == (
            "db1=https://10.0.0.11:2380,db2=https://10.0.0.12:2380,witness=https://10.0.0.10:2380")
        assert etcd["ETCD_INITIAL_CLUSTER_TOKEN"] == witness["ETCD_INITIAL_CLUSTER_TOKEN"] == token
    # run again: nothing is issued twice, the passwords stay
    _, again = _init(tmp_path, (deploy / ".env").read_text().splitlines())
    assert again.returncode == 0 and "issued" not in again.stdout
    assert _env_file((deploy / ".env").read_text())["MASSLAK_PATRONI_REST_PASSWORD"] == rest_password
    # the hosts changed after the certificate was issued: it must be issued again, not used for other addresses
    moved = [line.replace("10.0.0.12", "10.0.0.13") for line in (deploy / ".env").read_text().splitlines()]
    _, refused = _init(tmp_path, moved)
    assert refused.returncode == 1 and "does not name 10.0.0.13" in refused.stderr


@pytest.mark.parametrize("hosts, witness, expected", [
    ("10.0.0.11", "10.0.0.10", "MASSLAK_DB_HOSTS must hold"),
    ("db-a1.internal,db-a2.internal", "10.0.0.10", "MASSLAK_DB_HOSTS must hold"),        # etcd binds addresses only
    ("10.0.0.11,10.0.0.11", "10.0.0.10", "MASSLAK_DB_HOSTS must hold"),
    ("10.0.0.11,10.0.0.12", "", "MASSLAK_DB_WITNESS must hold"),
])
def test_the_installer_refuses_an_incomplete_layout(tmp_path, hosts, witness, expected):
    lines = [line for line in HA_ENV if not line.startswith(("MASSLAK_DB_HOSTS=", "MASSLAK_DB_WITNESS="))]
    _, r = _init(tmp_path, lines + [f"MASSLAK_DB_HOSTS={hosts}", f"MASSLAK_DB_WITNESS={witness}"])
    assert r.returncode == 1 and expected in r.stderr, r.stderr


def _preflight(tmp_path, env_lines):
    deploy = tmp_path / "deploy"
    (deploy / "production").mkdir(parents=True, exist_ok=True)
    (deploy / "production" / "preflight.sh").write_bytes((REPO / "deploy" / "production" / "preflight.sh").read_bytes())
    (deploy / ".env").write_text("\n".join(["MASSLAK_ENVIRONMENT=production"] + env_lines) + "\n")
    return subprocess.run(["bash", str(deploy / "production" / "preflight.sh")], capture_output=True, text=True)


def test_the_host_preflight_requires_two_database_hosts_or_the_owners_acceptance(tmp_path):
    single = _preflight(tmp_path, [])
    assert single.returncode == 1 and "the database runs on this one host" in single.stderr
    accepted = _preflight(tmp_path, ["MASSLAK_SINGLE_HOST_ACCEPTED=owner, 2026-10-10: pilot"])
    assert "the database runs on this one host" not in accepted.stderr
    one = _preflight(tmp_path, ["MASSLAK_DB_LAYOUT=ha", "MASSLAK_DB_HOSTS=10.0.0.11"])
    assert "MASSLAK_DB_HOSTS must hold the two" in one.stderr and "MASSLAK_DB_WITNESS is missing" in one.stderr
    assert "cluster.crt is missing" in one.stderr
    other = _preflight(tmp_path, ["MASSLAK_DB_LAYOUT=three"])
    assert "MASSLAK_DB_LAYOUT must be ha" in other.stderr


def test_the_proxies_route_to_the_primary_and_to_a_standby_with_tls_checked(tmp_path):
    shim = tmp_path / "bin"
    shim.mkdir()
    (shim / "su-exec").write_text('#!/bin/sh\n[ "$1" = haproxy ] && [ "$2" = haproxy ] && cat "$6"\n')   # print the configuration
    (shim / "su-exec").chmod(0o755)
    ca = tmp_path / "ca.crt"
    ca.write_text("x")
    env = {**os.environ, "PATH": f"{shim}:{os.environ['PATH']}", "MASSLAK_DB_HOSTS": "10.0.0.11,10.0.0.12", "MASSLAK_DB_CA": str(ca)}
    render = lambda mode: subprocess.run(["sh", str(DBIMAGE / "proxy.sh"), mode], capture_output=True, text=True, env=env)   # noqa: E731
    primary, replica = render("primary").stdout, render("replica").stdout
    check = f"check port 8008 check-ssl verify required ca-file {ca}"
    for cfg in (primary, replica):
        assert f"server db1 10.0.0.11:5432 {check}" in cfg and f"server db2 10.0.0.12:5432 {check}" in cfg
        assert "on-marked-down shutdown-sessions" in cfg and "option httpchk GET /primary" in cfg
    assert "default_backend primary" in primary and "standbys" not in primary
    # reports go to a standby at most 16 MB behind (Patroni reads lag in bytes), or to the primary while none is up
    assert "option httpchk GET /replica?lag=16MB" in replica
    assert "use_backend standbys if { nbsrv(standbys) gt 0 }" in replica and "default_backend primary" in replica
    assert render("other").returncode == 2
    no_hosts = subprocess.run(["sh", str(DBIMAGE / "proxy.sh"), "primary"], capture_output=True, text=True,
                              env={k: v for k, v in env.items() if k != "MASSLAK_DB_HOSTS"})
    assert no_hosts.returncode != 0 and "MASSLAK_DB_HOSTS" in no_hosts.stderr


def _masslak_patroni():
    import importlib.util
    spec = importlib.util.spec_from_file_location("masslak_patroni", DBIMAGE / "patroni-config.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.mark.parametrize("members, rc", [
    ([{"name": "db1", "role": "leader", "state": "running"}, {"name": "db2", "role": "sync_standby", "state": "streaming"}], 0),
    ([{"name": "db1", "role": "leader", "state": "running"}, {"name": "db2", "role": "replica", "state": "streaming"}], 1),
    ([{"name": "db1", "role": "leader", "state": "running"}], 1),
    ([{"name": "db1", "role": "replica", "state": "streaming"}, {"name": "db2", "role": "sync_standby", "state": "streaming"}], 1),
])
def test_the_cluster_is_healthy_with_one_primary_and_a_synchronous_standby(monkeypatch, members, rc):
    m = _masslak_patroni()
    monkeypatch.setattr(m, "call", lambda method, path, body=None: {"members": members})
    assert m.cluster() == rc


def test_zero_data_loss_is_set_on_the_cluster_through_its_rest_api(monkeypatch):
    m = _masslak_patroni()
    sent, config = [], {}

    def call(method, path, body=None):
        sent.append((method, path, body))
        if method == "PATCH":
            config.update(synchronous_mode=body["synchronous_mode"], synchronous_mode_strict=body["synchronous_mode_strict"])
        return dict(config)
    monkeypatch.setattr(m, "call", call)
    assert m.durability("on") == 0 and config["synchronous_mode_strict"] is True
    assert sent[0] == ("PATCH", "/config", {"synchronous_mode": True, "synchronous_mode_strict": True,
                                            "postgresql": {"parameters": {"synchronous_commit": "on"}}})
    assert m.durability("off") == 0 and config["synchronous_mode_strict"] is False
    with pytest.raises(SystemExit):
        m.durability("maybe")


def test_patroni_runs_with_tls_everywhere_synchronous_standby_and_rewind():
    import yaml
    cfg = yaml.safe_load((DBIMAGE / "patroni.yml").read_text())
    tls = "/var/lib/postgresql/tls/"
    assert cfg["restapi"]["certfile"] == tls + "server.crt" and cfg["restapi"]["cafile"] == tls + "ca.crt"
    assert cfg["etcd3"]["protocol"] == "https" and cfg["etcd3"]["cert"] == tls + "server.crt"
    assert cfg["ctl"]["cacert"] == tls + "ca.crt"
    dcs = cfg["bootstrap"]["dcs"]
    assert dcs["synchronous_mode"] is True and dcs["ttl"] == 30 and dcs["postgresql"]["use_pg_rewind"] is True
    params = dcs["postgresql"]["parameters"]
    assert params["ssl"] == "on" and params["ssl_min_protocol_version"] == "TLSv1.3"
    assert params["archive_command"].startswith("pgbackrest") and params["wal_level"] == "logical"
    for login in ("superuser", "replication"):
        assert cfg["postgresql"]["authentication"][login]["sslmode"] == "verify-full"
    # pg_hba.conf stays the one masslak-db-entry writes (hostssl only), not Patroni's
    assert cfg["postgresql"]["parameters"]["hba_file"] == "/var/lib/postgresql/pg_hba.conf" and "pg_hba" not in cfg["postgresql"]
    assert cfg["bootstrap"]["post_bootstrap"] == "/usr/local/bin/masslak-patroni-bootstrap"
    dockerfile = (DBIMAGE / "Dockerfile").read_text()
    assert "--require-hashes -r /tmp/patroni.lock" in dockerfile and "COPY patroni.yml /etc/patroni/patroni.yml" in dockerfile
    lock = (DBIMAGE / "patroni.lock").read_text()
    pins = re.findall(r"^([a-z0-9._-]+)==", lock, re.M)
    assert "patroni" in pins and all(re.search(rf"^{p}==\S+ \\\n\s+--hash=sha256:", lock, re.M) for p in pins), pins


def test_the_database_hosts_and_the_application_host_run_the_same_pinned_parts():
    import yaml
    host = yaml.safe_load((HA / "db-host.yml").read_text())
    app = yaml.safe_load((HA / "docker-compose.ha.yml").read_text().replace("!reset ", "").replace("!override", ""))
    assert host["services"]["etcd"]["image"] == app["services"]["etcd"]["image"]
    assert re.search(r"@sha256:[0-9a-f]{64}$", host["services"]["etcd"]["image"])
    for svc in host["services"].values():
        assert svc["network_mode"] == "host" and "ports" not in svc        # each listens on the private address alone
    patroni = host["services"]["patroni"]
    assert patroni["image"].startswith("masslak-db:") and patroni["command"] == ["patroni", "/etc/patroni/patroni.yml"]
    assert "${MASSLAK_DB_HOST_DIR}/tls/cluster.key:/tls-src/server.key:ro" in patroni["volumes"]
    assert app["services"]["db"]["entrypoint"] == ["/usr/local/bin/masslak-db-proxy", "primary"]
    assert app["services"]["db-replica"]["entrypoint"] == ["/usr/local/bin/masslak-db-proxy", "replica"]
    assert app["services"]["db"]["environment"]["PGSSLMODE"] == "verify-full"
    assert app["services"]["db"]["volumes"] == ["./deploy/production/tls/ca.crt:/tls-src/ca.crt:ro"]   # no data, no key
    durability = (REPO / "deploy" / "durability.sh").read_text()
    assert "exec -T db masslak-patroni durability" in durability


# ------------------------------------------------------------------ M-11 mobile advisories, M-14 builds and devices
def _advisories():
    import importlib.util
    spec = importlib.util.spec_from_file_location("mobile_advisories", REPO / "scripts" / "mobile_advisories.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _audit(*advisories):
    """npm audit --json in miniature: each advisory a leaf of the tree, as npm prints it."""
    vulns = {}
    for ident, package, severity in advisories:
        vulns.setdefault(package, {"via": []})["via"].append(
            {"name": package, "severity": severity, "title": f"{package} issue", "url": f"https://github.com/advisories/{ident}"})
    return {"vulnerabilities": vulns}


def test_every_mobile_advisory_is_classed_and_build_ones_do_not_ship(tmp_path):
    import datetime as dt
    import json as js
    m = _advisories()
    register = js.loads((REPO / "mobile" / "advisories.json").read_text())
    today = dt.date(2026, 10, 10)
    known = _audit(*((e["id"], e["package"], e["severity"]) for e in register["advisories"]))
    assert m.check(known, register, {"react", "query-string", "decode-uri-component"}, today) == ([], [])
    # a new high advisory nobody classed stops CI; a new moderate one is a note
    problems, notes = m.check(_audit(("GHSA-new1", "left-pad", "high"), ("GHSA-new2", "tiny", "moderate")), register, None, today)
    assert any("GHSA-new1 (left-pad, high) is not classed" in p for p in problems)
    assert any("GHSA-new2" in n for n in notes) and not any("GHSA-new2" in p for p in problems)
    # a high advisory classed runtime needs a dated acceptance
    runtime = {"advisories": [{"id": "GHSA-rt", "package": "rt", "severity": "high", "class": "runtime", "review_by": "2027-01-01"}]}
    problems, _ = m.check(_audit(("GHSA-rt", "rt", "high")), runtime, None, today)
    assert any("ships in the app and nobody accepted it" in p for p in problems)
    # a package classed build that the bundle carries is refused, and so is an entry past its review date
    problems, _ = m.check(known, register, {"node-forge"}, today)
    assert any("node-forge is classed build but the app bundle carries it" in p for p in problems)
    problems, _ = m.check(known, register, None, dt.date(2027, 6, 1))
    assert any("was due for review" in p for p in problems)
    # the bundle's packages come from its source maps
    maps = tmp_path / "_expo" / "static" / "js" / "android"
    maps.mkdir(parents=True)
    (maps / "entry.hbc.map").write_text(js.dumps({"sources": [
        "/app/node_modules/query-string/index.js", "/app/node_modules/@noble/hashes/sha2.js", "/app/src/app/index.tsx"]}))
    assert m.bundled_packages([tmp_path]) == {"query-string", "@noble/hashes"}
    for e in register["advisories"]:
        assert e["class"] in ("build", "runtime") and e.get("where") and e.get("fix")
        assert e["class"] == "build" or e.get("accepted_by"), e["id"]


def test_the_mobile_apps_build_on_eas_as_modules_and_ci_checks_their_advisories():
    import json as js
    import yaml
    assert js.loads((REPO / "mobile" / "package.json").read_text())["type"] == "module"
    builds = js.loads((REPO / "mobile" / "eas.json").read_text())["build"]
    for variant in ("passenger", "driver", "operator"):
        for profile in ("preview", "production"):
            p = builds[f"{profile}-{variant}"]
            assert p["extends"] == profile and p["env"]["APP_VARIANT"] == variant
            assert p["env"]["MASSLAK_API_URL"].startswith("https://")
    assert builds["production"]["distribution"] == "store" and builds["preview"]["distribution"] == "internal"
    assert "MASSLAK_API_PINS" not in (REPO / "mobile" / "eas.json").read_text()      # pins live in the EAS environment
    workflow = yaml.safe_load((REPO / ".github" / "workflows" / "mobile-builds.yml").read_text())
    steps = " ".join(str(s.get("run", "")) for s in workflow["jobs"]["build"]["steps"])
    assert "EXPO_TOKEN" in steps and "eas-cli@24.8.0 build" in steps and "mobile_advisories.py" in steps
    ci = (REPO / ".github" / "workflows" / "ci.yml").read_text()
    assert "python3 ../scripts/mobile_advisories.py audit.json /tmp/passenger /tmp/driver /tmp/operator" in ci
    assert ci.count("--source-maps --output-dir") == 3
    matrix = (REPO / "docs" / "operations" / "MOBILE_DEVICE_MATRIX.md").read_text()
    for case in ("Biometric lock", "Offline boarding", "Certificate pinning", "Install the preview build"):
        assert case in matrix
