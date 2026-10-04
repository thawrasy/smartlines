"""Encrypted file store.

Files are encrypted with AES-256-GCM before they are written, with the storage key as associated data, so a file
moved to another key fails to decrypt. Storage keys are random and carry no user input, so a file name can never
reach the file system. This local adapter writes to a mounted volume; an object store adapter (S3 or MinIO with
server-side encryption on top) implements the same two functions.
"""
import hashlib
import secrets
from dataclasses import dataclass
from pathlib import Path

from ...config import get_settings
from ...crypto import FieldCipher

# Accepted types, recognised from the file's first bytes, never from its name or the declared content type
SIGNATURES = {
    "application/pdf": (b"%PDF-",),
    "image/png": (b"\x89PNG\r\n\x1a\n",),
    "image/jpeg": (b"\xff\xd8\xff",),
}


class FileRejected(ValueError):
    pass


@dataclass(frozen=True)
class Stored:
    storage_key: str
    mime_type: str
    size: int
    sha256: bytes
    key_id: int


def detect(data: bytes) -> str:
    for mime, magics in SIGNATURES.items():
        if any(data.startswith(m) for m in magics):
            return mime
    raise FileRejected("FILE_TYPE: only PDF, PNG and JPEG files are accepted")


def _path(storage_key: str) -> Path:
    root = Path(get_settings().files_dir).resolve()
    path = (root / storage_key).resolve()
    if root not in path.parents:
        raise FileRejected("FILE_PATH: invalid storage key")
    return path


def put(cipher: FieldCipher, data: bytes) -> Stored:
    if not data:
        raise FileRejected("FILE_EMPTY: the file is empty")
    if len(data) > get_settings().max_upload_bytes:
        raise FileRejected("FILE_TOO_LARGE: the file is larger than allowed")
    mime = detect(data)
    key = f"{secrets.token_hex(2)}/{secrets.token_hex(16)}"
    sealed = cipher.encrypt_bytes(data, f"file:{key}")
    path = _path(key)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(sealed.ciphertext)
    return Stored(key, mime, len(data), hashlib.sha256(data).digest(), sealed.key_id)


def get(cipher: FieldCipher, storage_key: str, key_id: int, sha256: bytes) -> bytes:
    data = cipher.decrypt_bytes(_path(storage_key).read_bytes(), key_id, f"file:{storage_key}")
    if hashlib.sha256(data).digest() != sha256:
        raise FileRejected("FILE_TAMPERED: the stored file does not match its hash")
    return data
