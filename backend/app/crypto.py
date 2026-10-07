"""Field-level encryption for Restricted data (study 16.8, 16.13, 16.18).

Restricted values such as identity document numbers are stored as AES-256-GCM ciphertext in *_enc columns,
with a blind index (keyed HMAC-SHA256) in *_bidx columns for exact matching and a masked last-4 for display.

* Every ciphertext row carries enc_key_id, a reference to sec.key_registry. The registry holds key references
  only; key material comes from the environment (in production, injected from KMS or Vault):
      MASSLAK_FIELD_KEYS = "kms://masslak/field/restricted/v1=<base64 32 bytes>,<other ref>=<key>"
      MASSLAK_BIDX_KEY   = "<base64 32 bytes>"
* Ciphertext layout: version byte 0x01 | 12-byte random nonce | ciphertext and 16-byte tag.
* Associated data binds a ciphertext to its column ("sales.passenger.id_no"), so a value copied into another
  column fails to decrypt.
* Rotation: a new key is registered as ACTIVE and the old one moved to DECRYPT_ONLY; rows keep their own key id
  and are re-encrypted by `python -m app.tools.rekey` (the database refuses new data under a non-active key).
* Outside the sandbox the API refuses to start without real keys: there is no fallback to keys derived from another
  secret (review 3.12). Keys come either from MASSLAK_FIELD_KEYS and MASSLAK_BIDX_KEY, or, with envelope encryption
  (third-party audit R-10), from sec.key_registry.wrapped_dek opened by the key service (app/kms.py).
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import logging
import os
import unicodedata
from dataclasses import dataclass

import asyncpg
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

from . import kms
from .config import get_settings

log = logging.getLogger("masslak.crypto")
_VERSION = b"\x01"
RESTRICTED_REF = "kms://masslak/field/restricted/v1"


class CryptoConfigError(RuntimeError):
    pass


def _derive(label: str) -> bytes:
    """Development fallback: a key derived from the signing secret. Never used when real keys are configured."""
    return HKDF(algorithm=SHA256(), length=32, salt=b"masslak-dev-keys", info=label.encode()).derive(
        get_settings().signing_secret.encode())


def _decode_key(text: str, name: str) -> bytes:
    try:
        key = base64.b64decode(text.strip(), validate=True)
    except ValueError as exc:
        raise CryptoConfigError(f"{name} is not valid base64") from exc
    if len(key) != 32:
        raise CryptoConfigError(f"{name} must be 32 bytes")
    return key


def _configured_field_keys() -> dict[str, bytes]:
    raw = os.environ.get("MASSLAK_FIELD_KEYS", "").strip()
    keys: dict[str, bytes] = {}
    for item in filter(None, (p.strip() for p in raw.split(","))):
        ref, _, value = item.rpartition("=")
        if not ref:
            raise CryptoConfigError("MASSLAK_FIELD_KEYS entries must look like <key_ref>=<base64 key>")
        keys[ref] = _decode_key(value, ref)
    return keys


def _bidx_key() -> bytes:
    raw = os.environ.get("MASSLAK_BIDX_KEY", "").strip()
    if raw:
        return _decode_key(raw, "MASSLAK_BIDX_KEY")
    if not get_settings().sandbox:
        # review 3.12: real data is never protected by a key derived from another secret
        raise CryptoConfigError("MASSLAK_BIDX_KEY must be set outside the sandbox (injected from KMS or Vault)")
    return _derive("blind-index")


@dataclass(frozen=True)
class Sealed:
    ciphertext: bytes
    key_id: int


class FieldCipher:
    """Encrypts and decrypts Restricted columns. Build it once per process with load()."""

    def __init__(self, keys_by_id: dict[int, bytes], active: dict[str, int], bidx_key: bytes):
        self._keys = keys_by_id
        self._active = active
        self._bidx = bidx_key

    @classmethod
    async def load(cls, conn: asyncpg.Connection) -> "FieldCipher":
        rows = await conn.fetch(
            """SELECT id, key_ref, purpose, status, wrapped_dek, kms_key_id FROM sec.key_registry
                WHERE purpose IN ('FIELD_ENCRYPTION', 'WEBHOOK_SECRET', 'BLIND_INDEX') AND status IN ('ACTIVE', 'DECRYPT_ONLY')""")
        configured = _configured_field_keys()
        wrapper = kms.provider()
        wrapped = [r for r in rows if r["wrapped_dek"] is not None]
        if not configured and not (wrapper and wrapped) and not get_settings().sandbox:
            raise CryptoConfigError("outside the sandbox the data keys come from MASSLAK_FIELD_KEYS or from wrapped keys opened "
                                    "by the key service (MASSLAK_KMS_PROVIDER)")
        keys, active, bidx = {}, {}, None
        for r in rows:
            key = configured.get(r["key_ref"])
            if key is None and wrapper and r["wrapped_dek"] is not None:
                key = wrapper.unwrap(bytes(r["wrapped_dek"]), r["key_ref"], r["kms_key_id"])   # envelope (R-10)
            if key is None and not configured and not wrapped:
                key = _derive(r["key_ref"])                                                     # sandbox only
            if key is None:
                continue  # registered but not provided to this process: values under it cannot be read here
            if r["purpose"] == "BLIND_INDEX":
                if r["status"] == "ACTIVE" and r["wrapped_dek"] is not None:
                    bidx = key
                continue
            keys[r["id"]] = key
            if r["status"] == "ACTIVE":
                active[r["key_ref"]] = r["id"]
        return cls(keys, active, bidx if bidx is not None and not os.environ.get("MASSLAK_BIDX_KEY") else _bidx_key())

    def encrypt(self, value: str, column: str, key_ref: str = RESTRICTED_REF) -> Sealed:
        key_id = self._active.get(key_ref)
        if key_id is None:
            raise CryptoConfigError(f"no active key for {key_ref}")
        nonce = os.urandom(12)
        ct = AESGCM(self._keys[key_id]).encrypt(nonce, value.encode(), column.encode())
        return Sealed(_VERSION + nonce + ct, key_id)

    def encrypt_bytes(self, data: bytes, purpose: str, key_ref: str = RESTRICTED_REF) -> Sealed:
        """Same scheme for files: the purpose (for example "file:<storage key>") is the associated data."""
        key_id = self._active.get(key_ref)
        if key_id is None:
            raise CryptoConfigError(f"no active key for {key_ref}")
        nonce = os.urandom(12)
        return Sealed(_VERSION + nonce + AESGCM(self._keys[key_id]).encrypt(nonce, data, purpose.encode()), key_id)

    def decrypt_bytes(self, blob: bytes, key_id: int, purpose: str) -> bytes:
        if not blob or blob[:1] != _VERSION:
            raise ValueError("unknown ciphertext version")
        key = self._keys.get(key_id)
        if key is None:
            raise CryptoConfigError(f"key {key_id} is not available to this process")
        return AESGCM(key).decrypt(blob[1:13], blob[13:], purpose.encode())

    def decrypt(self, blob: bytes, key_id: int, column: str) -> str:
        if not blob or blob[:1] != _VERSION:
            raise ValueError("unknown ciphertext version")
        key = self._keys.get(key_id)
        if key is None:
            raise CryptoConfigError(f"key {key_id} is not available to this process")
        return AESGCM(key).decrypt(blob[1:13], blob[13:], column.encode()).decode()

    def blind_index(self, value: str, scope: str) -> bytes:
        """Deterministic keyed hash for exact matching; scope separates kinds (for example the document type)."""
        return hmac.new(self._bidx, f"{scope}|{normalise_identifier(value)}".encode(), hashlib.sha256).digest()


def normalise_identifier(value: str) -> str:
    """Upper case, Western digits, no spaces or separators, so the same document always matches."""
    text = unicodedata.normalize("NFKC", value).upper()
    return "".join(str(unicodedata.digit(ch)) if ch.isdigit() else ch for ch in text if ch.isalnum())


def last4(value: str) -> str:
    return normalise_identifier(value)[-4:]


def masked_mobile(last: str | None) -> str | None:
    """How a stored phone number is shown back: only its last four digits."""
    return f"*******{last}" if last else None


_cipher: FieldCipher | None = None


async def cipher(conn: asyncpg.Connection) -> FieldCipher:
    global _cipher
    if _cipher is None:
        _cipher = await FieldCipher.load(conn)
    return _cipher


def reset_cipher() -> None:
    """Forget the loaded keys (after a rotation or in tests)."""
    global _cipher
    _cipher = None
