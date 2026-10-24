"""The settings guard (db/guard, 1084; reviews of release 1.49.0, the residual path of finding C-01).

Two reviewers of release 1.49.0 showed that 1080 closed set_config but not a SET statement of its own: as the API's
login, SET LOCAL app.scope = 'PLATFORM' made sys.ctx_is_platform() true, and the same worked for the ledger's guard
flag. The module db/guard/masslak_guard.c, loaded with the server, makes those settings superuser-only.

The static tests keep the three lists of protected names equal (module, schema, API) and every setting the schema
trusts on them, and check that every database image of the repository builds and loads the module. The live tests act
as the API's login against the running database: when the guard is loaded, every way of setting a protected value is
refused while the platform's own functions keep setting the context. CI runs them on a server with the guard
(MASSLAK_GUARD_REQUIRED=1), where a database without it fails the run instead of skipping.
"""
import asyncio
import os
import re
from pathlib import Path

import asyncpg
import pytest

from app import db, readiness
from app.guard import GUARDED_SETTINGS
from app.tools import preflight
from context import SET_CONTEXT, context_args
from test_e2e import owner_sql

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "db" / "schema"
APP_URL = os.environ.get("MASSLAK_DATABASE_URL")
needs_db = pytest.mark.skipif(not APP_URL, reason="needs MASSLAK_DATABASE_URL")

# names a schema file read before 1084 replaced the function that used them
RETIRED = {"app.new."}


def _read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8")


# ------------------------------------------------------------------ the lists agree
def test_the_module_the_schema_and_the_api_name_the_same_settings():
    c_source = _read("db/guard/masslak_guard.c")
    in_c = re.findall(r'^\s*"([a-z_]+\.[a-z_.]+)",', c_source, re.M)
    sql = _read("db/schema/1084_settings_guard.sql")
    array = re.search(r"FUNCTION sys\.guarded_settings\(\).*?ARRAY\[(.*?)\]", sql, re.S).group(1)
    in_sql = re.findall(r"'([a-z_.]+)'", array)
    assert in_c == list(GUARDED_SETTINGS) == in_sql
    assert "PGC_SUSET" in c_source


def test_every_custom_setting_the_schema_trusts_is_guarded():
    read, written = set(), set()
    for f in sorted(SCHEMA.glob("*.sql")):
        text = f.read_text(encoding="utf-8")
        read |= set(re.findall(r"current_setting\('([a-z_]+\.[a-z_.]*)'", text))
        written |= set(re.findall(r"set_config\('([a-z_]+\.[a-z_.]*)'", text))
    custom = {n for n in read | written if n not in RETIRED}
    assert custom, "the schema reads custom settings"
    assert custom <= set(GUARDED_SETTINGS), f"trusted but not guarded: {sorted(custom - set(GUARDED_SETTINGS))}"


# ------------------------------------------------------------------ every database image loads it
def test_every_database_image_builds_and_loads_the_guard():
    dev = _read("docker-compose.yml")
    for svc in ("db", "db-replica"):
        block = dev.split(f"\n  {svc}:\n", 1)[1][:400]
        assert "build: db/guard" in block and "image: masslak-postgres:" in block, svc
    assert 'ENTRYPOINT ["/usr/local/bin/masslak-guard-entry", "docker-entrypoint.sh"]' in _read("db/guard/Dockerfile")
    assert "masslak_guard" in _read("deploy/postgres/replica.sh")
    prod = _read("deploy/production/db/Dockerfile")
    assert "COPY --from=guard-src masslak_guard.c Makefile /src/" in prod and "masslak_guard.so" in prod
    assert "exec masslak-guard-entry docker-entrypoint.sh" in _read("deploy/production/db/entry.sh")
    patroni = _read("deploy/production/db/patroni.yml")
    local = patroni.split("\npostgresql:\n", 1)[1]
    assert "shared_preload_libraries: pg_stat_statements,masslak_guard" in local, "the local parameters, not bootstrap's"
    staging = _read("deploy/staging/db/Dockerfile")
    assert "masslak_guard.so" in staging and "masslak-guard-entry" in staging
    overlay = _read("deploy/production/docker-compose.production.yml")
    assert "guard-src: db/guard" in overlay and "build: !reset null" in overlay
    assert "guard-src: db/guard" in _read("deploy/staging/docker-compose.staging.yml")
    assert "--build-context guard-src=db/guard" in _read("deploy/images.sh")
    ci = _read(".github/workflows/ci.yml")
    assert "--build-context guard-src=db/guard -t masslak-db:ci" in ci and "masslak-postgres:ci db/guard" in ci


def test_the_wrapper_adds_the_module_only_when_the_image_has_it(tmp_path):
    import subprocess
    lib, bin_ = tmp_path / "lib", tmp_path / "bin"
    lib.mkdir(), bin_.mkdir()
    (bin_ / "pg_config").write_text(f"#!/bin/sh\necho {lib}\n")
    (bin_ / "show").write_text('#!/bin/sh\nprintf "%s|" "$@"\n')
    for f in bin_.iterdir():
        f.chmod(0o755)
    env = {**os.environ, "PATH": f"{bin_}:{os.environ['PATH']}"}

    def run(*args: str) -> str:
        return subprocess.run(["sh", str(ROOT / "db/guard/entry.sh"), "show", *args], env=env, check=True,
                              capture_output=True, text=True).stdout

    assert run("-c", "shared_preload_libraries=pg_stat_statements") == "-c|shared_preload_libraries=pg_stat_statements|"
    (lib / "masslak_guard.so").write_text("")
    assert run("-c", "shared_preload_libraries=pg_stat_statements", "-c", "x=1") == \
        "-c|shared_preload_libraries=pg_stat_statements,masslak_guard|-c|x=1|"
    assert run("-c", "shared_preload_libraries=masslak_guard") == "-c|shared_preload_libraries=masslak_guard|"
    assert run("-c", "wal_level=logical") == "-c|wal_level=logical|-c|shared_preload_libraries=masslak_guard|"


# ------------------------------------------------------------------ the production checks require it
def test_the_production_preflight_requires_the_guard():
    def guard_problems(enforced: int) -> list[str]:
        f = preflight.Facts(guarded_enforced=enforced)
        return [p for p in preflight.evaluate(f) if "settings guard" in p]
    assert guard_problems(0) and guard_problems(len(GUARDED_SETTINGS) - 1)
    assert guard_problems(len(GUARDED_SETTINGS)) == []


def test_readiness_requires_the_guard_on_a_production_server_only(monkeypatch):
    monkeypatch.setattr(readiness, "is_test_server", lambda: True)
    assert asyncio.run(readiness._guard()) is True          # a developer's own PostgreSQL may not have the module
    assert "settings_guard" in readiness.CHECKS


# ------------------------------------------------------------------ live, as the API's login
def _guard_loaded() -> bool:
    loaded = owner_sql("SELECT sys.guard_status()") is True
    if not loaded and os.environ.get("MASSLAK_GUARD_REQUIRED") == "1":
        pytest.fail("the database does not load the settings guard (masslak_guard), which this run requires")
    if not loaded:
        pytest.skip("the database does not load the settings guard (a PostgreSQL without db/guard)")
    return loaded


def _as_api(check, **connect):
    async def run():
        conn = await asyncpg.connect(APP_URL, **connect)
        await db.prepare_connection(conn)
        try:
            return await check(conn)
        finally:
            await conn.close()
    return asyncio.run(run())


@needs_db
def test_no_statement_of_the_login_sets_a_guarded_setting():
    _guard_loaded()
    company = owner_sql("SELECT min(company_id) FROM iam.company_member")

    async def check(conn):
        for name in GUARDED_SETTINGS:
            for statement in (f"SET LOCAL {name} = 'PLATFORM'", f"SET {name} = 'PLATFORM'", f"RESET {name}"):
                async with conn.transaction():
                    with pytest.raises(asyncpg.InsufficientPrivilegeError, match="permission denied to set parameter"):
                        await conn.execute(statement)
        async with conn.transaction():
            with pytest.raises(asyncpg.InsufficientPrivilegeError, match="permission denied to set parameter"):
                await conn.execute("ALTER ROLE CURRENT_USER SET app.scope = 'PLATFORM'")
        # the platform's own function still sets the context, and a later SET does not change it
        async with conn.transaction():
            await conn.execute(SET_CONTEXT, *context_args(None, company, "COMPANY"))
            await conn.execute("SAVEPOINT s")
            with pytest.raises(asyncpg.InsufficientPrivilegeError):
                await conn.execute("SET LOCAL app.scope = 'PLATFORM'")
            await conn.execute("ROLLBACK TO SAVEPOINT s")
            assert await conn.fetchval("SELECT sys.ctx_scope()") == "COMPANY"
            assert await conn.fetchval("SELECT sys.ctx_is_platform()") is False
            assert {r[0] for r in await conn.fetch("SELECT DISTINCT company_id FROM iam.company_member")} == {company}
    _as_api(check)


@needs_db
def test_the_login_cannot_bring_a_guarded_setting_in_its_connection_options():
    _guard_loaded()

    async def nothing(conn):
        return None
    with pytest.raises(asyncpg.InsufficientPrivilegeError, match="permission denied to set parameter"):
        _as_api(nothing, server_settings={"app.scope": "PLATFORM"})
    with pytest.raises(asyncpg.InsufficientPrivilegeError, match="permission denied to set parameter"):
        _as_api(nothing, server_settings={"masslak.migrating": "on"})


@needs_db
def test_the_guard_status_is_readable_by_the_login():
    _guard_loaded()

    async def check(conn):
        assert await conn.fetchval("SELECT sys.guard_status()") is True
        assert list(await conn.fetchval("SELECT sys.guarded_settings()")) == list(GUARDED_SETTINGS)
    _as_api(check)
