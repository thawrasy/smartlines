"""Envelope encryption of data keys (third-party audit R-10): unit tests, no API server needed."""
import asyncio
import base64
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

import pytest
from cryptography.exceptions import InvalidTag

from app import crypto, kms
from app.tools.keys import register_statements

REF = "kms://masslak/field/restricted/v9"


def test_local_kek_round_trip_and_binding():
    w = kms.LocalKek(os.urandom(32))
    dek = os.urandom(32)
    blob = w.wrap(dek, REF)
    assert dek not in blob and w.unwrap(blob, REF) == dek
    with pytest.raises(InvalidTag):
        w.unwrap(blob, "kms://masslak/field/restricted/v8")          # a wrapped key moved to another row does not open
    with pytest.raises(InvalidTag):
        kms.LocalKek(os.urandom(32)).unwrap(blob, REF)               # nor under another KEK


class _FakeConn:
    def __init__(self, rows):
        self.rows = rows

    async def fetch(self, *_):
        return self.rows


def test_cipher_opens_wrapped_keys_without_any_key_in_the_environment(monkeypatch):
    kek, dek, bidx = os.urandom(32), os.urandom(32), os.urandom(32)
    w = kms.LocalKek(kek)
    rows = [{"id": 11, "key_ref": REF, "purpose": "FIELD_ENCRYPTION", "status": "ACTIVE", "wrapped_dek": w.wrap(dek, REF), "kms_key_id": None},
            {"id": 12, "key_ref": "kms://masslak/bidx/v9", "purpose": "BLIND_INDEX", "status": "ACTIVE",
             "wrapped_dek": w.wrap(bidx, "kms://masslak/bidx/v9"), "kms_key_id": None}]
    for name in ("MASSLAK_FIELD_KEYS", "MASSLAK_BIDX_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("MASSLAK_KMS_PROVIDER", "local")
    monkeypatch.setenv("MASSLAK_KEK", base64.b64encode(kek).decode())
    fc = asyncio.run(crypto.FieldCipher.load(_FakeConn(rows)))
    sealed = fc.encrypt("N1234567", "sales.passenger.id_no", key_ref=REF)
    assert sealed.key_id == 11 and fc.decrypt(sealed.ciphertext, 11, "sales.passenger.id_no") == "N1234567"
    # the same data key opened again (another process) reads the value
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    assert AESGCM(dek).decrypt(sealed.ciphertext[1:13], sealed.ciphertext[13:], b"sales.passenger.id_no") == b"N1234567"
    assert fc.blind_index("N1234567", "PASSPORT:SY") == crypto.FieldCipher({}, {}, bidx).blind_index("N1234567", "PASSPORT:SY")


class _Transit(BaseHTTPRequestHandler):
    kek = os.urandom(32)

    def do_POST(self):  # noqa: N802 (http.server API)
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.headers.get("X-Vault-Token") != "test-token":
            self.send_response(403)
            self.end_headers()
            return
        w = kms.LocalKek(self.kek)
        if "/transit/encrypt/" in self.path:
            out = {"ciphertext": "vault:v1:" + base64.b64encode(w.wrap(base64.b64decode(body["plaintext"]), "vault")).decode()}
        else:
            out = {"plaintext": base64.b64encode(w.unwrap(base64.b64decode(body["ciphertext"][9:]), "vault")).decode()}
        data = json.dumps({"data": out}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


def test_vault_transit_wraps_and_unwraps():
    server = HTTPServer(("127.0.0.1", 0), _Transit)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        v = kms.VaultTransit(f"http://127.0.0.1:{server.server_port}", "test-token")
        dek = os.urandom(32)
        blob = v.wrap(dek, REF, "masslak-field")
        assert blob.startswith(b"vault:v1:") and v.unwrap(blob, REF, "masslak-field") == dek
        with pytest.raises(kms.KmsError):
            kms.VaultTransit(f"http://127.0.0.1:{server.server_port}", "wrong-token").unwrap(blob, REF, "masslak-field")
    finally:
        server.shutdown()


def test_vault_requires_tls_off_the_local_machine():
    with pytest.raises(kms.KmsError):
        kms.VaultTransit("http://vault.internal:8200", "t")


def test_registration_statements_carry_only_the_wrapped_key():
    wrapped = kms.LocalKek(os.urandom(32)).wrap(b"k" * 32, REF)
    sql = register_statements(REF, "FIELD_ENCRYPTION", "RESTRICTED", None, wrapped)
    assert wrapped.hex() in sql and "DECRYPT_ONLY" in sql and "'ACTIVE'" in sql and ("k" * 32) not in sql
