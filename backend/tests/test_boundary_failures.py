"""The failure paths of six boundary modules (independent review, round 9, Team R-23): device attestation, the telemetry
database, the message providers, the file scanner, the S3 file store and the payment providers.

Each was below 70 % line coverage because the suite reaches them through a working service: what they do when the
service does not answer, answers wrongly or is not configured was not exercised. These tests play those services with
fakes, without a database or a network.
"""
import asyncio
import io
import json
import socket
import threading
import types
import urllib.error
from contextlib import asynccontextmanager

import pytest

from app import attestation, egress, telemetry
from app.errors import ApiError
from app.modules.documents import scanner, storage
from app.modules.notify import providers
from app.modules.payments import adapters, breaker


def settings(sandbox: bool):
    return lambda: types.SimpleNamespace(sandbox=sandbox, signing_secret="test-secret", telemetry_upkeep_url="")


class Answer(io.BytesIO):
    """A urlopen result: readable, a context manager, with a status."""

    def __init__(self, body: bytes = b"", status: int = 200):
        super().__init__(body)
        self.status = status


def run(coro):
    return asyncio.run(coro)


# ------------------------------------------------------------------ device attestation
def test_attestation_is_simulated_in_the_sandbox_only_and_never_assumed(monkeypatch):
    monkeypatch.setattr(attestation, "get_settings", settings(True))
    assert run(attestation.verify("SIMULATED", "pass-1")) is True
    assert run(attestation.verify("SIMULATED", "fail-1")) is False
    monkeypatch.setattr(attestation, "get_settings", settings(False))
    with pytest.raises(ApiError) as e:
        run(attestation.verify("SIMULATED", "pass-1"))
    assert e.value.code == "ATTESTATION_PROVIDER"
    # a real provider without its verifier configured is refused, not passed
    monkeypatch.delenv("MASSLAK_ATTESTATION_URL", raising=False)
    with pytest.raises(ApiError) as e:
        run(attestation.verify("PLAY_INTEGRITY", "token"))
    assert e.value.status == 503 and e.value.code == "ATTESTATION_NOT_CONFIGURED"
    monkeypatch.setenv("MASSLAK_ATTESTATION_URL", "http://verifier.internal/check")      # not https
    with pytest.raises(ApiError) as e:
        run(attestation.verify("APP_ATTEST", "token"))
    assert e.value.code == "ATTESTATION_NOT_CONFIGURED"


def test_attestation_takes_the_verifier_verdict_and_fails_closed_when_it_is_down(monkeypatch):
    monkeypatch.setattr(attestation, "get_settings", settings(False))
    monkeypatch.setenv("MASSLAK_ATTESTATION_URL", "https://verifier.example/check")
    monkeypatch.setenv("MASSLAK_ATTESTATION_TOKEN", "t")
    sent = {}

    def answer(req, timeout):
        sent["auth"], sent["body"] = req.headers["Authorization"], json.loads(req.data)
        return Answer(json.dumps({"verdict": sent["body"]["token"].upper()}).encode())
    monkeypatch.setattr(egress, "urlopen", answer)
    assert run(attestation.verify("PLAY_INTEGRITY", "pass")) is True
    assert sent == {"auth": "Bearer t", "body": {"provider": "PLAY_INTEGRITY", "token": "pass"}}
    assert run(attestation.verify("PLAY_INTEGRITY", "tampered")) is False

    def down(req, timeout):
        raise OSError("connection refused")
    monkeypatch.setattr(egress, "urlopen", down)
    with pytest.raises(ApiError) as e:
        run(attestation.verify("PLAY_INTEGRITY", "pass"))
    assert e.value.status == 502 and e.value.code == "ATTESTATION_UNAVAILABLE"


# ------------------------------------------------------------------ telemetry database
class FakePool:
    def __init__(self, fetch=None, fetchval=None):
        self.conn = types.SimpleNamespace(fetch=fetch, fetchval=fetchval)

    @asynccontextmanager
    async def acquire(self):
        yield self.conn


ROW = {c: None for c in telemetry._COLUMNS} | {"trust_flags": ["MOCK"], "trust": "LOW"}


def test_positions_the_telemetry_database_cannot_take_are_a_503_to_retry(monkeypatch):
    async def ok(sql, *args):
        assert args[-1] == ["{MOCK}"]                       # flags travel as array literals
        return [{"trust": "LOW"}]
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: FakePool(fetch=ok))
    assert run(telemetry.store_rows([ROW])) == ["LOW"]

    async def unreachable(sql, *args):
        raise OSError("no route")
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: FakePool(fetch=unreachable))
    with pytest.raises(ApiError) as e:
        run(telemetry.store_rows([ROW]))
    assert e.value.status == 503 and e.value.code == "TELEMETRY_UNAVAILABLE"

    import asyncpg

    async def refused(sql, *args):
        raise asyncpg.exceptions.ReadOnlySQLTransactionError("read only")
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: FakePool(fetch=refused))
    with pytest.raises(ApiError) as e:
        run(telemetry.store_rows([ROW]))
    assert e.value.code == "TELEMETRY_UNAVAILABLE"

    async def bug(sql, *args):
        raise KeyError("a programming error is not hidden as an outage")
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: FakePool(fetch=bug))
    with pytest.raises(KeyError):
        run(telemetry.store_rows([ROW]))


def test_the_backlog_stops_at_the_first_failure_and_counts_the_attempt(monkeypatch):
    waiting = [{"id": 7, "positions": json.dumps([{**ROW, "ts": "2026-10-18T10:00:00+00:00", "received_at": None,
                                                    "device_ts": None, "event_id": "6f1c7a52-6d5e-4ad7-9a3e-1f3d2c1b0a99"}])}]
    executed = []

    class Conn:
        async def fetch(self, sql, batch):
            return waiting

        async def execute(self, sql, ids, *rest):
            executed.append((sql.split()[3], ids, rest))

    @asynccontextmanager
    async def transaction(ctx):
        yield Conn()
    monkeypatch.setattr(telemetry.db, "transaction", transaction)
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: object())
    revived = []

    async def down(rows):
        revived.extend(rows)
        raise ApiError(503, "TELEMETRY_UNAVAILABLE", "positions were not stored; send them again")
    monkeypatch.setattr(telemetry, "store_rows", down)
    assert run(telemetry.drain_backlog()) == 0
    assert executed == [("attempts", [7], ("positions were not stored; send them again",))]
    assert revived[0]["ts"].year == 2026 and str(revived[0]["event_id"]).startswith("6f1c7a52")

    executed.clear()

    async def up(rows):
        return ["LOW"]
    monkeypatch.setattr(telemetry, "store_rows", up)
    assert run(telemetry.drain_backlog()) == 1
    assert executed[0][1] == [7] and executed[0][0] == "delivered_at"
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: None)
    assert run(telemetry.drain_backlog()) == 0


def test_telemetry_upkeep_and_metrics_report_what_they_could_not_do(monkeypatch):
    monkeypatch.setattr(telemetry, "get_settings", settings(False))

    async def ahead(sql):
        return 3
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: FakePool(fetchval=ahead))
    out = run(telemetry.upkeep(90, held=False))
    assert out == {"partitions_created": 3, "partitions_dropped": 0, "retention": "not applied"}

    async def down(sql):
        raise OSError("down")
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: FakePool(fetch=down))
    assert run(telemetry.metrics()) == [("masslak_telemetry_up", {}, 0.0)]

    async def rows(sql):
        return [{"metric": "masslak_telemetry_positions", "labels": "{}", "value": 5.0}]
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: FakePool(fetch=rows))
    assert run(telemetry.metrics())[1] == ("masslak_telemetry_positions", {}, 5.0)
    monkeypatch.setattr(telemetry.db, "telemetry_pool", lambda: None)
    assert run(telemetry.metrics()) == [] and run(telemetry.upkeep(90, held=False)) is None


# ------------------------------------------------------------------ message providers
def test_a_channel_left_unset_is_off_outside_the_sandbox_and_log_is_refused_there(monkeypatch):
    monkeypatch.setattr(providers, "get_settings", settings(False))
    for ch in ("EMAIL", "SMS", "WHATSAPP"):
        monkeypatch.delenv(f"MASSLAK_NOTIFY_{ch}", raising=False)
    with pytest.raises(providers.ChannelOff):
        providers.send_email("a@b.test", "s", "b")
    with pytest.raises(providers.ChannelOff):
        providers.send_sms("+963900000000", "b")
    with pytest.raises(providers.ChannelOff):
        providers.send_whatsapp_code("+963900000000", "123456", "ar", "code")
    monkeypatch.setenv("MASSLAK_NOTIFY_SMS", "log")
    with pytest.raises(providers.NotifyConfigError):
        providers.send_sms("+963900000000", "b")
    monkeypatch.setenv("MASSLAK_NOTIFY_SMS", "carrier-pigeon")
    with pytest.raises(providers.NotifyConfigError):
        providers.require_in_production()


def test_sms_and_whatsapp_go_over_https_only_and_raise_when_the_gateway_refuses(monkeypatch):
    monkeypatch.setattr(providers, "get_settings", settings(False))
    monkeypatch.setenv("MASSLAK_NOTIFY_SMS", "http")
    monkeypatch.setenv("MASSLAK_NOTIFY_WHATSAPP", "cloud")
    monkeypatch.setenv("MASSLAK_SMS_TOKEN", "s")
    monkeypatch.setenv("MASSLAK_WHATSAPP_TOKEN", "w")
    monkeypatch.setenv("MASSLAK_SMS_URL", "http://gateway.example/send")
    with pytest.raises(RuntimeError, match="HTTPS"):
        providers.send_sms("+963900000000", "b")
    monkeypatch.setenv("MASSLAK_WHATSAPP_URL", "http://graph.example/messages")
    with pytest.raises(RuntimeError, match="HTTPS"):
        providers.send_whatsapp_code("+963900000000", "123456", "ar", "code")
    monkeypatch.setenv("MASSLAK_SMS_URL", "https://gateway.example/send")
    monkeypatch.setenv("MASSLAK_WHATSAPP_URL", "https://graph.example/messages")
    sent = []
    status = {"code": 202}

    def gateway(req, timeout):
        sent.append((req.full_url, req.headers["Authorization"], json.loads(req.data)))
        return Answer(b"", status["code"])
    monkeypatch.setattr(egress, "urlopen", gateway)
    providers.send_sms("+963900000000", "your ticket")
    providers.send_whatsapp_code("+963900000000", "123456", "ar", "code")
    assert sent[0][1] == "Bearer s" and sent[0][2] == {"to": "+963900000000", "text": "your ticket"}
    wa = sent[1][2]
    assert sent[1][1] == "Bearer w" and wa["to"] == "963900000000" and wa["template"]["language"] == {"code": "ar"}
    assert wa["template"]["components"][0]["parameters"][0]["text"] == "123456"
    status["code"] = 400
    with pytest.raises(RuntimeError, match="SMS gateway answered 400"):
        providers.send_sms("+963900000000", "b")
    with pytest.raises(RuntimeError, match="WhatsApp answered 400"):
        providers.send_whatsapp_code("+963900000000", "1", "en", "c")


def test_email_goes_through_the_egress_smtp_with_starttls_and_its_attachments(monkeypatch):
    monkeypatch.setattr(providers, "get_settings", settings(False))
    monkeypatch.setenv("MASSLAK_NOTIFY_EMAIL", "smtp")
    monkeypatch.setenv("MASSLAK_SMTP_URL", "smtp://mailer:pw@smtp.example:2525")
    seen = {}

    class SMTP:
        def __init__(self, host, port, timeout):
            seen["at"] = (host, port)

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

        def starttls(self, context):
            seen["tls"] = True

        def login(self, user, password):
            seen["login"] = (user, password)

        def send_message(self, msg):
            seen["msg"] = msg
    monkeypatch.setattr(egress, "SMTP", SMTP)
    providers.send_email("a@b.test", "Report", "attached", (("r.csv", "text/csv; charset=utf-8", b"a,b\n"),))
    assert seen["at"] == ("smtp.example", 2525) and seen["tls"] and seen["login"] == ("mailer", "pw")
    parts = list(seen["msg"].iter_attachments())
    assert seen["msg"]["To"] == "a@b.test" and parts[0].get_filename() == "r.csv" and parts[0].get_content_type() == "text/csv"


# ------------------------------------------------------------------ file scanner
class Clamd(threading.Thread):
    """A one-connection clamd that answers INSTREAM with a fixed reply."""

    def __init__(self, reply: bytes):
        super().__init__(daemon=True)
        self.reply, self.got = reply, b""
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(1)
        self.port = self.sock.getsockname()[1]

    def run(self):
        conn, _ = self.sock.accept()
        with conn:
            while not self.got.endswith(b"\0\0\0\0"):
                part = conn.recv(65536)
                if not part:
                    break
                self.got += part
            conn.sendall(self.reply)
        self.sock.close()


PNG = b"\x89PNG\r\n\x1a\n" + b"\0" * 32 + b"IEND\xaeB`\x82"


@pytest.mark.parametrize("reply,expected", [(b"stream: OK\0", None), (b"stream: Eicar-Test-Signature FOUND\0", "Eicar-Test-Signature")])
def test_clamav_verdicts_from_a_clamd_stream(reply, expected):
    clamd = Clamd(reply)
    clamd.start()
    assert scanner.clamav(PNG * 3, f"127.0.0.1:{clamd.port}") == expected
    clamd.join(5)
    assert clamd.got.startswith(b"zINSTREAM\0")


def test_clamav_down_or_confused_leaves_the_file_pending():
    clamd = Clamd(b"INSTREAM size limit exceeded. ERROR\0")
    clamd.start()
    with pytest.raises(scanner.Unavailable, match="size limit"):
        scanner.clamav(PNG, f"127.0.0.1:{clamd.port}")
    clamd.join(5)
    free = socket.socket()
    free.bind(("127.0.0.1", 0))
    port = free.getsockname()[1]
    free.close()                                            # nothing listens there now
    with pytest.raises(scanner.Unavailable, match="clamd"):
        scanner.clamav(PNG, f"127.0.0.1:{port}", timeout=2)
    with pytest.raises(scanner.Unavailable):
        scanner.clamav(PNG, "/nonexistent/clamd.sock", timeout=2)


def test_production_waits_for_clamav_and_the_sandbox_may_scan_built_in_only(monkeypatch):
    monkeypatch.delenv("MASSLAK_CLAMD", raising=False)
    monkeypatch.setattr(scanner, "get_settings", settings(False))
    with pytest.raises(scanner.Unavailable, match="production files wait for ClamAV"):
        scanner.scan(PNG, "image/png")
    monkeypatch.setattr(scanner, "get_settings", settings(True))
    assert scanner.scan(PNG, "image/png") == scanner.Verdict("CLEAN", "builtin", "sandbox: built-in checks only")
    monkeypatch.setenv("MASSLAK_CLAMD", "127.0.0.1:1")
    monkeypatch.setattr(scanner, "clamav", lambda data, target: "Win.Trojan")
    assert scanner.scan(PNG, "image/png").status == "QUARANTINED"
    monkeypatch.setattr(scanner, "clamav", lambda data, target: None)
    assert scanner.scan(PNG, "image/png") == scanner.Verdict("CLEAN", "builtin+clamav", "")
    assert scanner.scan(PNG + b"x" * 2000, "image/png").detail == "DATA_AFTER_IMAGE"
    assert scanner.scan(PNG, "application/pdf").detail == "TYPE_MISMATCH"


# ------------------------------------------------------------------ S3 file store
def s3(**kw) -> storage.S3Store:
    return storage.S3Store("https://s3.example.com", "files", "AK", "SK", prefix="masslak", **kw)


def test_the_s3_store_checks_its_settings():
    for bad in (dict(endpoint="ftp://s3.example.com"), dict(endpoint="https://s3.example.com/path")):
        with pytest.raises(ValueError):
            storage.S3Store(bad["endpoint"], "files", "AK", "SK")
    with pytest.raises(ValueError, match="AES256 or aws:kms"):
        s3(sse="none")
    with pytest.raises(ValueError, match="needs"):
        storage.S3Store("https://s3.example.com", "", "AK", "SK")


def test_an_object_the_store_did_not_encrypt_is_removed_and_refused(monkeypatch):
    store, calls = s3(sse="aws:kms", kms_key_id="k1"), []

    def request(method, key, body=b"", headers=None, query=None):
        calls.append((method, key, headers))
        return (200, {}, b"") if method == "PUT" else (204, {}, b"")
    monkeypatch.setattr(store, "_request", request)
    with pytest.raises(RuntimeError, match="FILE_STORE_NOT_ENCRYPTED"):
        store.write("a/b", b"data")
    assert calls[0][2]["x-amz-server-side-encryption-aws-kms-key-id"] == "k1" and calls[1][:2] == ("DELETE", "a/b")
    monkeypatch.setattr(store, "_request", lambda *a, **k: (403, {}, b"denied"))
    with pytest.raises(RuntimeError, match="PUT answered 403"):
        store.write("a/b", b"data")
    with pytest.raises(RuntimeError, match="GET answered 403"):
        store.read("a/b")
    with pytest.raises(RuntimeError, match="HEAD answered 403"):
        store.exists("a/b")
    with pytest.raises(RuntimeError, match="DELETE answered 403"):
        store.delete("a/b")
    monkeypatch.setattr(store, "_request", lambda *a, **k: (404, {}, b""))
    with pytest.raises(storage.FileRejected, match="FILE_MISSING"):
        store.read("a/b")
    assert store.exists("a/b") is False


def test_bucket_protection_versions_and_listing_read_every_page(monkeypatch):
    store = s3()
    pages = {
        "versioning": (200, {}, b"<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"),
        "object-lock": (200, {}, b"<ObjectLockConfiguration><ObjectLockEnabled>Enabled</ObjectLockEnabled><Rule><DefaultRetention>"
                                 b"<Mode>COMPLIANCE</Mode><Years>1</Years></DefaultRetention></Rule></ObjectLockConfiguration>"),
    }
    versions = [
        b"<ListVersionsResult><IsTruncated>true</IsTruncated><NextKeyMarker>masslak/a</NextKeyMarker>"
        b"<NextVersionIdMarker>v1</NextVersionIdMarker><Version><Key>masslak/a</Key><VersionId>v2</VersionId>"
        b"<IsLatest>true</IsLatest><LastModified>2026-10-18T10:00:00Z</LastModified><ETag>\"e2\"</ETag></Version></ListVersionsResult>",
        b"<ListVersionsResult><IsTruncated>false</IsTruncated><DeleteMarker><Key>masslak/b</Key><VersionId>v9</VersionId>"
        b"<IsLatest>true</IsLatest></DeleteMarker></ListVersionsResult>"]
    listing = [
        b"<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>t2</NextContinuationToken><Contents>"
        b"<Key>masslak/a</Key><LastModified>2026-10-18T10:00:00Z</LastModified></Contents></ListBucketResult>",
        b"<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>masslak/c</Key>"
        b"<LastModified>2026-10-18T11:00:00.000Z</LastModified></Contents></ListBucketResult>"]
    seen = []

    def request(method, key, body=b"", headers=None, query=None):
        q = query or {}
        seen.append(q)
        for name, answer in pages.items():
            if name in q:
                return answer
        if "versions" in q:
            return 200, {}, versions.pop(0)
        if q.get("list-type") == "2":
            return 200, {}, listing.pop(0)
        return 200, {}, b"<CopyObjectResult/>"
    monkeypatch.setattr(store, "_request", request)
    assert store.protection() == {"versioning": "Enabled", "object_lock": True, "retention_mode": "COMPLIANCE",
                                  "retention_days": 365}
    got = list(store.versions())
    assert [(v["key"], v["version_id"], v["deleted"]) for v in got] == [("a", "v2", False), ("b", "v9", True)]
    assert any(q.get("version-id-marker") == "v1" for q in seen)
    assert [k for k, _ in store.listing()] == ["a", "c"]
    assert any(q.get("continuation-token") == "t2" for q in seen)
    store.restore_version("a", "v1")
    pages["object-lock"] = (404, {}, b"")
    assert store.protection()["object_lock"] is False
    monkeypatch.setattr(store, "_request", lambda *a, **k: (200, {}, b"<Error><Code>AccessDenied</Code></Error>"))
    with pytest.raises(RuntimeError, match="restoring a to version v1"):
        store.restore_version("a", "v1")


def test_a_store_that_does_not_answer_is_unavailable_and_a_refusal_is_an_answer(monkeypatch):
    store = s3()

    def answer(code):
        def opener(*a, **k):
            class Opener:
                def open(self, req, timeout):
                    raise urllib.error.HTTPError(req.full_url, code, "x", {}, io.BytesIO(b"<Error/>"))
            return Opener()
        return opener
    monkeypatch.setattr(storage.urllib.request, "build_opener", answer(503))
    with pytest.raises(storage.StoreUnavailable, match="GET answered 503"):
        store.read("a")
    monkeypatch.setattr(storage.urllib.request, "build_opener", answer(403))
    with pytest.raises(RuntimeError, match="GET answered 403"):
        store.read("a")

    def unreachable(*a, **k):
        class Opener:
            def open(self, req, timeout):
                raise urllib.error.URLError("no route")
        return Opener()
    monkeypatch.setattr(storage.urllib.request, "build_opener", unreachable)
    with pytest.raises(storage.StoreUnavailable, match="URLError"):
        store.exists("a")


# ------------------------------------------------------------------ payment providers
PROVIDER = {"code": "TESTPSP", "config": {"base_url": "https://psp.example", "merchant_id": "m1"}}
PAYMENT = {"reference": "CRD123", "uid": "u1", "amount": 1500, "currency": "SYP", "provider_ref": "CRD123"}


@pytest.fixture
def psp(monkeypatch):
    monkeypatch.setattr(adapters, "get_settings", settings(False))
    monkeypatch.setenv("MASSLAK_PSP_TESTPSP_SECRET", "psp-secret")
    monkeypatch.setenv("MASSLAK_PSP_TESTPSP_KEY", "psp-key")
    breaker.reset()
    calls, answers = [], []

    def provider(req, timeout):
        calls.append((req.full_url, dict(req.headers), json.loads(req.data)))
        a = answers.pop(0)
        if isinstance(a, BaseException):
            raise a
        return Answer(a if isinstance(a, bytes) else json.dumps(a).encode())
    monkeypatch.setattr(egress, "urlopen", provider)
    yield calls, answers
    breaker.reset()


def http_error(code):
    return urllib.error.HTTPError("https://psp.example", code, "x", {}, io.BytesIO(b""))


def test_a_real_provider_call_is_signed_idempotent_and_classified(psp):
    calls, answers = psp
    answers.append({"checkout_url": "https://psp.example/pay/1"})
    act = adapters.HostedCard().start(PROVIDER, PAYMENT, "https://masslak.test/back")
    url, headers, body = calls[0]
    assert act.url == "https://psp.example/pay/1" and url == "https://psp.example/v1/checkout-sessions"
    assert headers["Idempotency-key"] == "CRD123" and headers["Authorization"] == "Bearer psp-key"
    raw = json.dumps(body).encode()
    assert adapters.verify(b"psp-secret", raw, headers["X-masslak-signature"])
    answers.append({"checkout_url": "http://psp.example/pay/1"})                    # not a secure page
    with pytest.raises(adapters.ProviderUnknown):
        adapters.HostedCard().start(PROVIDER, PAYMENT, "https://masslak.test/back")
    answers.append(http_error(402))                                                  # a definite refusal
    with pytest.raises(adapters.ProviderRefused):
        adapters.HostedCard().start(PROVIDER, PAYMENT, "x")
    answers.append(http_error(504))                                                  # no answer: may have acted
    with pytest.raises(adapters.ProviderUnknown):
        adapters.HostedCard().start(PROVIDER, PAYMENT, "x")
    answers.append(b"<html>not json</html>")
    with pytest.raises(adapters.ProviderUnknown, match="unreadable"):
        adapters.HostedCard().start(PROVIDER, PAYMENT, "x")
    with pytest.raises(ApiError) as e:
        adapters.HostedCard().start({"code": "X", "config": {"base_url": "http://psp.example"}}, PAYMENT, "x")
    assert e.value.code == "PAYMENT_PROVIDER_NOT_CONFIGURED"


def test_refunds_and_wallet_confirmations_read_what_the_provider_says(psp):
    calls, answers = psp
    answers += [{"status": "ACCEPTED", "refund_id": "R1"}, {"status": "DECLINED"}, {"status": "PROCESSING"}]
    assert adapters.HostedCard().refund(PROVIDER, PAYMENT, 500, "RFD1") == "R1"
    with pytest.raises(adapters.ProviderRefused):
        adapters.Instalments().refund(PROVIDER, PAYMENT, 500, "RFD1")
    with pytest.raises(adapters.ProviderUnknown, match="did not say"):
        adapters.PartnerWallet().refund(PROVIDER, PAYMENT, 500, "RFD1")
    assert calls[0][2] == {"payment_reference": "CRD123", "amount": 500, "refund_reference": "RFD1"}
    answers += [{}, {"status": "PENDING"}, {"status": "SUCCESS", "amount": 1400, "currency": "SYP", "event_id": "e1"},
                {"status": "FAILED", "amount": 0, "failure_code": "OTP_INVALID"}]
    assert adapters.PartnerWallet().start(PROVIDER, PAYMENT, "x", mobile="+963900000000").kind == "OTP"
    assert adapters.PartnerWallet().confirm(PROVIDER, PAYMENT, "123456") is None
    took = adapters.PartnerWallet().confirm(PROVIDER, PAYMENT, "123456")
    assert (took.status, took.amount, took.event_id) == ("SUCCESS", 1400, "e1")      # what it took, not what was asked
    failed = adapters.PartnerWallet().confirm(PROVIDER, PAYMENT, "000000")
    assert failed.status == "FAILED" and failed.failure_code == "OTP_INVALID"


def test_without_its_secret_a_provider_is_not_configured_outside_the_sandbox(monkeypatch):
    monkeypatch.setattr(adapters, "get_settings", settings(False))
    monkeypatch.delenv("MASSLAK_PSP_NOSECRET_SECRET", raising=False)
    with pytest.raises(ApiError) as e:
        adapters.secret_for({"code": "NOSECRET", "config": {}})
    assert e.value.status == 503
    monkeypatch.setattr(adapters, "get_settings", settings(True))
    assert len(adapters.secret_for({"code": "NOSECRET", "config": {}})) == 32
    with pytest.raises(ApiError) as e:
        adapters.parse_notice(b'{"event_id": "e"}')
    assert e.value.code == "BAD_NOTIFICATION"
    assert not adapters.verify(b"k", b"{}", "t=notanumber,v1=x") and not adapters.verify(b"k", b"{}", None)
    assert not adapters.verify(b"k", b"{}", adapters.sign(b"k", b"{}", ts=1))       # too old
