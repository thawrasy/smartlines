"""The file stores (code review of October 2026, 3.2): a volume, or an S3-compatible object store with server-side
encryption. The signing and the refusals are checked against a stand-in server; with MASSLAK_TEST_S3_ENDPOINT set
(CI starts SeaweedFS for it) the same code runs against a real object store, and the move tool with it."""
import asyncio
import os
import threading
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest

from app.crypto import RESTRICTED_REF, FieldCipher
from app.modules.documents import storage
from app.tools import files_move, files_versions

S3_URL = os.environ.get("MASSLAK_TEST_S3_ENDPOINT", "")
S3_BUCKET = os.environ.get("MASSLAK_TEST_S3_BUCKET", "masslak-files")
S3_KEY = os.environ.get("MASSLAK_TEST_S3_ACCESS_KEY", "masslak-files")
S3_SECRET = os.environ.get("MASSLAK_TEST_S3_SECRET_KEY", "")
needs_s3 = pytest.mark.skipif(not S3_URL, reason="needs MASSLAK_TEST_S3_ENDPOINT (an S3-compatible store)")


def cipher() -> FieldCipher:
    return FieldCipher({7: os.urandom(32)}, {RESTRICTED_REF: 7}, os.urandom(32))


def test_signature_matches_the_aws_example():
    """The example request of the Signature Version 4 documentation (GET /test.txt with a Range header)."""
    s = storage.S3Store("https://s3.amazonaws.com", "examplebucket", "AKIAIOSFODNN7EXAMPLE",
                        "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region="us-east-1")
    h = s.sign("GET", "examplebucket.s3.amazonaws.com", "/test.txt", "", {"Range": "bytes=0-9"},
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", datetime(2013, 5, 24, tzinfo=timezone.utc))
    assert h["authorization"] == (
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
        "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")


class _Fake(BaseHTTPRequestHandler):
    """A stand-in object store: answers what the test asks for and records the requests."""
    replies: dict = {}
    seen: list = []

    def _answer(self):
        length = int(self.headers.get("content-length") or 0)
        body = self.rfile.read(length) if length else b""
        self.seen.append((self.command, self.path, {k.lower(): v for k, v in self.headers.items()}, body))
        status, headers = self.replies.get(self.command, (200, {}))
        self.send_response(status)
        for k, v in headers.items():
            self.send_header(k, v)
        self.send_header("content-length", "0")
        self.end_headers()

    do_GET = do_PUT = do_HEAD = do_DELETE = _answer

    def log_message(self, *args):
        pass


@pytest.fixture
def fake():
    server = HTTPServer(("127.0.0.1", 0), _Fake)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    _Fake.replies, _Fake.seen = {}, []
    yield storage.S3Store(f"http://127.0.0.1:{server.server_port}", "files", "AK", "SK", prefix="masslak"), _Fake
    server.shutdown()


def test_a_write_the_store_does_not_encrypt_is_removed_and_refused(fake):
    s, srv = fake
    srv.replies = {"PUT": (200, {}), "DELETE": (204, {})}
    with pytest.raises(RuntimeError, match="FILE_STORE_NOT_ENCRYPTED"):
        s.write("ab/cd", b"sealed bytes")
    (put, path, headers, body), (delete, path2, _, _) = srv.seen
    assert put == "PUT" and delete == "DELETE" and path == path2 == "/files/masslak/ab/cd" and body == b"sealed bytes"
    assert headers["x-amz-server-side-encryption"] == "AES256"
    assert "x-amz-server-side-encryption" in headers["authorization"].split("SignedHeaders=")[1]   # signed, not added later
    srv.seen.clear()
    srv.replies = {"PUT": (200, {"x-amz-server-side-encryption": "AES256"})}
    s.write("ab/cd", b"sealed bytes")                      # confirmed: kept
    assert [r[0] for r in srv.seen] == ["PUT"]


def test_store_failures_are_told_apart_from_bad_files(fake):
    s, srv = fake
    srv.replies = {"GET": (404, {})}
    with pytest.raises(storage.FileRejected, match="FILE_MISSING"):
        s.read("ab/cd")
    srv.replies = {"GET": (503, {}), "PUT": (500, {})}
    with pytest.raises(storage.StoreUnavailable):
        s.read("ab/cd")
    with pytest.raises(storage.StoreUnavailable):
        s.write("ab/cd", b"x")
    srv.replies = {"GET": (403, {})}
    with pytest.raises(RuntimeError, match="FILE_STORE_REFUSED"):
        s.read("ab/cd")
    closed = storage.S3Store("http://127.0.0.1:9", "files", "AK", "SK", timeout=2)
    with pytest.raises(storage.StoreUnavailable):
        closed.read("ab/cd")


def test_the_volume_keeps_keys_inside_and_never_shows_half_a_file(tmp_path):
    vol = storage.LocalStore(str(tmp_path))
    with pytest.raises(storage.FileRejected, match="FILE_PATH"):
        vol.write("../outside", b"x")
    vol.write("ab/cd", b"one")
    (tmp_path / "ab" / "ef.tmp").write_bytes(b"half")
    assert vol.read("ab/cd") == b"one" and list(vol.keys()) == ["ab/cd"] and vol.exists("ab/cd")
    with pytest.raises(storage.FileRejected, match="FILE_MISSING"):
        vol.read("ab/zz")


def test_settings_choose_the_store_and_refuse_plain_http_in_production(monkeypatch):
    from app.config import get_settings
    try:
        monkeypatch.setenv("MASSLAK_FILES_BACKEND", "s3")
        monkeypatch.setenv("MASSLAK_FILES_S3_ENDPOINT", "http://store.internal:9000")
        monkeypatch.setenv("MASSLAK_FILES_S3_BUCKET", "files")
        monkeypatch.setenv("MASSLAK_FILES_S3_ACCESS_KEY", "AK")
        monkeypatch.setenv("MASSLAK_FILES_S3_SECRET_KEY", "SK")
        monkeypatch.setenv("MASSLAK_SANDBOX", "false")
        get_settings.cache_clear()
        with pytest.raises(ValueError, match="https"):
            storage.store_from_settings()
        monkeypatch.setenv("MASSLAK_FILES_S3_ENDPOINT", "https://store.internal:9000")
        get_settings.cache_clear()
        assert isinstance(storage.store_from_settings(), storage.S3Store)
        monkeypatch.setenv("MASSLAK_FILES_S3_SSE", "none")
        get_settings.cache_clear()
        with pytest.raises(ValueError, match="AES256 or aws:kms"):
            storage.store_from_settings()
        monkeypatch.setenv("MASSLAK_FILES_BACKEND", "ftp")
        get_settings.cache_clear()
        with pytest.raises(ValueError, match="local or s3"):
            storage.store_from_settings()
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


def real_store(**kw) -> storage.S3Store:
    return storage.S3Store(S3_URL, S3_BUCKET, S3_KEY, kw.pop("secret", S3_SECRET), prefix=kw.pop("prefix", "tests"), **kw)


@needs_s3
def test_files_round_trip_through_the_object_store_encrypted_twice(monkeypatch):
    s3 = real_store()
    monkeypatch.setattr(storage, "store", lambda: s3)
    fc = cipher()
    pdf = b"%PDF-1.4\n" + uuid.uuid4().hex.encode()
    stored = asyncio.run(storage.put(fc, pdf))
    status, headers, _ = s3._request("HEAD", stored.storage_key)
    assert status == 200 and headers["x-amz-server-side-encryption"] == "AES256"       # the store's encryption
    assert pdf not in s3.read(stored.storage_key)                                        # and the platform's own
    assert asyncio.run(storage.get(fc, stored.storage_key, stored.key_id, stored.sha256)) == pdf
    other = asyncio.run(storage.put(fc, b"%PDF-1.4\nanother"))
    s3.write(stored.storage_key, s3.read(other.storage_key))         # another file's bytes put in its place
    with pytest.raises(Exception):
        asyncio.run(storage.get(fc, stored.storage_key, stored.key_id, stored.sha256))
    with pytest.raises(RuntimeError, match="FILE_STORE_REFUSED: GET answered 403"):
        real_store(secret="not-the-secret").read(other.storage_key)


@needs_s3
def test_the_object_store_lists_and_deletes_for_the_sweep():
    """The daily sweep (M-04) lists the store a thousand objects at a time and deletes what no row points to."""
    s3 = real_store(prefix=f"sweep-{uuid.uuid4().hex[:8]}")
    keys = sorted(f"{uuid.uuid4().hex[:4]}/{uuid.uuid4().hex}" for _ in range(3))
    for k in keys:
        s3.write(k, b"sealed bytes")
    listed = dict(s3.listing())
    assert sorted(listed) == keys and all(when.tzinfo is not None for when in listed.values())
    s3.delete(keys[0])
    s3.delete(keys[0])                                    # deleting twice is not an error
    assert sorted(dict(s3.listing())) == keys[1:] and not s3.exists(keys[0])


@needs_s3
def test_the_move_tool_copies_a_volume_once_and_finds_differences(tmp_path):
    vol = storage.LocalStore(str(tmp_path))
    keys = [f"{uuid.uuid4().hex[:4]}/{uuid.uuid4().hex}" for _ in range(5)]
    for k in keys:
        vol.write(k, os.urandom(64))
    s3 = real_store(prefix=f"move-{uuid.uuid4().hex[:8]}")
    assert files_move.copy(vol, s3) == {"copied": 5, "already_there": 0}
    assert files_move.copy(vol, s3) == {"copied": 0, "already_there": 5}
    assert files_move.compare(keys, s3, vol) == {"referenced": 5, "ok": 5, "missing": [], "different": []}
    s3.write(keys[0], b"changed")
    out = files_move.compare(keys + ["ab/never-copied"], s3, vol)
    assert out["missing"] == ["ab/never-copied"] and out["different"] == [keys[0]] and out["ok"] == 4


def test_a_cloud_store_is_added_to_the_egress_allowlist(monkeypatch, tmp_path):
    from app import egress
    from app.config import get_settings

    class NoRows:
        async def fetch(self, *_):
            return []
    try:
        for k, v in {"MASSLAK_FILES_BACKEND": "s3", "MASSLAK_FILES_S3_ENDPOINT": "https://s3.eu-central-1.amazonaws.com",
                     "MASSLAK_FILES_S3_BUCKET": "masslak-files", "MASSLAK_FILES_S3_VIA_PROXY": "true",
                     "MASSLAK_FILES_S3_PATH_STYLE": "false"}.items():
            monkeypatch.setenv(k, v)
        get_settings.cache_clear()
        asyncio.run(egress.write_allowlists(NoRows(), str(tmp_path)))
        assert "masslak-files.s3.eu-central-1.amazonaws.com" in (tmp_path / "generated.txt").read_text().split()
        monkeypatch.setenv("MASSLAK_FILES_S3_VIA_PROXY", "false")             # a store on the private network
        get_settings.cache_clear()
        asyncio.run(egress.write_allowlists(NoRows(), str(tmp_path)))
        assert "amazonaws" not in (tmp_path / "generated.txt").read_text()
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


def locked_bucket(retention_days: int = 1) -> storage.S3Store:
    """A new bucket made with Object Lock and a default retention, as the production profile requires (H-04)."""
    s3 = real_store(prefix="drill")
    s3.bucket = f"masslak-locked-{uuid.uuid4().hex[:8]}"
    status, _, body = s3._request("PUT", None, b"", {"x-amz-bucket-object-lock-enabled": "true"})
    assert status == 200, body
    rule = (b'<ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><ObjectLockEnabled>Enabled'
            b'</ObjectLockEnabled><Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>%d</Days></DefaultRetention>'
            b'</Rule></ObjectLockConfiguration>' % retention_days)
    import base64
    import hashlib
    md5 = base64.b64encode(hashlib.md5(rule, usedforsecurity=False).digest()).decode()
    status, _, body = s3._request("PUT", None, rule, {"content-md5": md5}, query={"object-lock": ""})
    assert status == 200, body
    return s3


@needs_s3
def test_the_preflight_tells_a_locked_bucket_from_a_plain_one():
    plain = real_store()
    assert files_versions.problems(plain.protection(), 14)                       # made without Object Lock
    locked = locked_bucket(retention_days=30)
    assert locked.protection() == {"versioning": "Enabled", "object_lock": True, "retention_mode": "GOVERNANCE",
                                   "retention_days": 30}
    assert files_versions.problems(locked.protection(), 14) == []
    assert "default retention is 30 days" in files_versions.problems(locked.protection(), 60)[0]


@needs_s3
def test_joint_restore_drill_brings_every_file_back_to_the_backups_moment(monkeypatch):
    """The backup records each file's version; after it, files are changed, deleted and added; the restore puts the
    recorded versions back, and every file the backup knew decrypts to its recorded hash again (H-04)."""
    import io
    s3 = locked_bucket()
    monkeypatch.setattr(storage, "store", lambda: s3)
    fc = cipher()
    kept = [asyncio.run(storage.put(fc, b"%PDF-1.4\n" + uuid.uuid4().hex.encode())) for _ in range(3)]
    taken = io.StringIO()
    assert files_versions.manifest(s3, taken) == 3                               # the backup's record
    header, entries = files_versions.read_manifest(iter(taken.getvalue().splitlines()))
    assert header["bucket"] == s3.bucket and {e["key"] for e in entries} == {k.storage_key for k in kept}
    # after the backup: one file changed, one deleted, one added
    s3.write(kept[0].storage_key, b"changed after the backup")
    s3.delete(kept[1].storage_key)
    later = asyncio.run(storage.put(fc, b"%PDF-1.4\nwritten after the backup"))
    with pytest.raises(Exception):
        asyncio.run(storage.get(fc, kept[0].storage_key, kept[0].key_id, kept[0].sha256))
    assert files_versions.restore(s3, entries, dry_run=True)["restored"] == 2   # a dry run changes nothing
    assert not s3.exists(kept[1].storage_key)
    out = files_versions.restore(s3, entries)
    assert (out["restored"], out["unchanged"], out["newer_files_left"]) == (2, 1, 1)
    for k in kept:
        asyncio.run(storage.get(fc, k.storage_key, k.key_id, k.sha256))          # whole and unchanged again
    assert s3.exists(later.storage_key)          # no row of the restored database points to it: the sweep removes it
    assert files_versions.restore(s3, entries)["restored"] == 0                  # running it again changes nothing
