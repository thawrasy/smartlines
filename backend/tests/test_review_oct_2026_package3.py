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
