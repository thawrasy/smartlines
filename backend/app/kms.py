"""Envelope encryption of data keys (third-party audit R-10).

The data keys (DEKs) that seal Restricted columns are stored in sec.key_registry.wrapped_dek, encrypted under a key
encryption key (KEK) that never enters the database or the application's configuration. At start-up the API asks the
key service to unwrap each DEK and keeps the clear DEK in memory only.

    MASSLAK_KMS_PROVIDER = vault | local      (unset: no envelope; keys come from MASSLAK_FIELD_KEYS as before)
    vault: MASSLAK_VAULT_ADDR, MASSLAK_VAULT_TOKEN; the KEK is the Vault Transit key named in kms_key_id.
           MASSLAK_VAULT_CA_FILE names the authority that signed Vault's certificate when it is not a public one. With
           MASSLAK_EGRESS_PROXY set, Vault is reached through the egress proxy, which lets through exactly Vault's
           host and port (deploy/egress, package 2 of the reviews of October 2026, H-06)
    local: MASSLAK_KEK = <base64 32 bytes>    (sandbox, development and staging only: the KEK sits in the
                                               environment; refused on a production server, R-29)

Wrapped layout of the local provider: version byte 0x01 | 12-byte nonce | AES-256-GCM ciphertext and tag, with the
key reference as associated data, so a wrapped key copied onto another registry row does not open.
"""
from __future__ import annotations

import base64
import json
import os
import ssl
import urllib.request
from typing import Optional, Protocol
from urllib.parse import urlparse

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

_LOCAL_VERSION = b"\x01"


class KmsError(RuntimeError):
    pass


class KeyWrapper(Protocol):
    name: str

    def wrap(self, dek: bytes, key_ref: str, kms_key_id: Optional[str]) -> bytes: ...

    def unwrap(self, blob: bytes, key_ref: str, kms_key_id: Optional[str]) -> bytes: ...


class LocalKek:
    """A KEK held in the environment. For staging and tests; production uses a key service."""
    name = "local"

    def __init__(self, kek: bytes):
        if len(kek) != 32:
            raise KmsError("MASSLAK_KEK must be 32 bytes")
        self._kek = kek

    def wrap(self, dek: bytes, key_ref: str, kms_key_id: Optional[str] = None) -> bytes:
        nonce = os.urandom(12)
        return _LOCAL_VERSION + nonce + AESGCM(self._kek).encrypt(nonce, dek, key_ref.encode())

    def unwrap(self, blob: bytes, key_ref: str, kms_key_id: Optional[str] = None) -> bytes:
        if not blob or blob[:1] != _LOCAL_VERSION:
            raise KmsError(f"{key_ref}: unknown wrapped key format")
        return AESGCM(self._kek).decrypt(blob[1:13], blob[13:], key_ref.encode())


class VaultTransit:
    """HashiCorp Vault Transit: the KEK never leaves Vault; the API holds only a token allowed to encrypt and decrypt."""
    name = "vault"

    def __init__(self, addr: str, token: str, timeout: float = 5.0, ca_file: Optional[str] = None,
                 proxy: Optional[str] = None):
        if not addr.startswith("https://") and not addr.startswith("http://127.0.0.1") and not addr.startswith("http://localhost"):
            raise KmsError("MASSLAK_VAULT_ADDR must use https outside the local machine")
        self._addr, self._token, self._timeout = addr.rstrip("/"), token, timeout
        handlers: list = [urllib.request.HTTPSHandler(context=ssl.create_default_context(cafile=ca_file or None))]
        local = urlparse(addr).hostname in ("127.0.0.1", "localhost")
        # through the egress proxy when there is one (CONNECT: the TLS session is end to end, the proxy sees no key)
        handlers.append(urllib.request.ProxyHandler({"https": proxy} if proxy and not local else {}))
        self._opener = urllib.request.build_opener(*handlers)

    def _call(self, op: str, key: Optional[str], body: dict) -> dict:
        if not key:
            raise KmsError("kms_key_id (the Vault Transit key name) is required for the vault provider")
        req = urllib.request.Request(f"{self._addr}/v1/transit/{op}/{key}", data=json.dumps(body).encode(), method="POST",
                                     headers={"X-Vault-Token": self._token, "Content-Type": "application/json"})
        try:   # the address was checked for https (or the local machine) in __init__
            with self._opener.open(req, timeout=self._timeout) as resp:  # nosec B310
                return json.loads(resp.read())["data"]
        except Exception as exc:                                               # the message never carries key material
            raise KmsError(f"vault transit {op} failed for {key}: {type(exc).__name__}") from None

    def wrap(self, dek: bytes, key_ref: str, kms_key_id: Optional[str]) -> bytes:
        return self._call("encrypt", kms_key_id, {"plaintext": base64.b64encode(dek).decode()})["ciphertext"].encode()

    def unwrap(self, blob: bytes, key_ref: str, kms_key_id: Optional[str]) -> bytes:
        return base64.b64decode(self._call("decrypt", kms_key_id, {"ciphertext": blob.decode()})["plaintext"])


def provider() -> Optional[KeyWrapper]:
    """The configured key service, or None when keys are supplied directly (MASSLAK_FIELD_KEYS)."""
    name = os.environ.get("MASSLAK_KMS_PROVIDER", "").strip().lower()
    if not name:
        return None
    if name == "local":
        from .config import is_test_server
        if not is_test_server():
            # the KEK would sit in the same environment as the data it protects (review of 1.47.0, R-29)
            raise KmsError("MASSLAK_KMS_PROVIDER=local is for test servers only; production uses a key service (vault)")
        raw = os.environ.get("MASSLAK_KEK", "").strip()
        if not raw:
            raise KmsError("MASSLAK_KEK is required for the local provider")
        return LocalKek(base64.b64decode(raw, validate=True))
    if name == "vault":
        addr, token = os.environ.get("MASSLAK_VAULT_ADDR", ""), os.environ.get("MASSLAK_VAULT_TOKEN", "")
        if not addr or not token:
            raise KmsError("MASSLAK_VAULT_ADDR and MASSLAK_VAULT_TOKEN are required for the vault provider")
        return VaultTransit(addr, token, ca_file=os.environ.get("MASSLAK_VAULT_CA_FILE") or None,
                            proxy=os.environ.get("MASSLAK_EGRESS_PROXY") or None)
    raise KmsError(f"unknown MASSLAK_KMS_PROVIDER {name!r} (vault or local)")
