"""Encrypted file store.

Files are encrypted with AES-256-GCM before they are written, with the storage key as associated data, so a file
moved to another key fails to decrypt. Storage keys are random and carry no user input, so a file name can never
reach the file system or the object store.

Two stores hold the encrypted bytes (MASSLAK_FILES_BACKEND): "local", a mounted volume (one server, the sandbox and
small installations), and "s3", any S3-compatible object store (code review of October 2026, 3.2), which several API
servers can share. The object store adds its own server-side encryption on top (MASSLAK_FILES_S3_SSE): every write
asks for it and a write the store does not confirm as encrypted is removed and refused. python -m app.tools.files_move
copies a volume's files into the object store and checks every file the database refers to.
"""
import asyncio
import hashlib
import hmac
import os
import secrets
import urllib.error
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from functools import lru_cache
from pathlib import Path
from typing import Iterator, Optional
from urllib.parse import quote, urlparse

from ... import egress
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


class StoreUnavailable(OSError):
    """The file store cannot be reached or answers with a server error: nothing is wrong with the file."""


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


class LocalStore:
    """Files on a mounted volume, one file per storage key."""
    name = "local"

    def __init__(self, root: str):
        self.root = Path(root).resolve()

    def _path(self, key: str) -> Path:
        path = (self.root / key).resolve()
        if self.root not in path.parents:
            raise FileRejected("FILE_PATH: invalid storage key")
        return path

    def write(self, key: str, data: bytes) -> None:
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        tmp.write_bytes(data)
        tmp.replace(path)                 # a reader never sees half a file

    def read(self, key: str) -> bytes:
        try:
            return self._path(key).read_bytes()
        except FileNotFoundError:
            raise FileRejected("FILE_MISSING: the stored file is not in the file store") from None

    def exists(self, key: str) -> bool:
        return self._path(key).is_file()

    def keys(self) -> Iterator[str]:
        for path in sorted(self.root.rglob("*")):
            if path.is_file() and not path.name.endswith(".tmp"):
                yield path.relative_to(self.root).as_posix()


class S3Store:
    """Objects in an S3-compatible store, signed with AWS Signature Version 4 (no SDK: the standard library only).

    Every write asks for server-side encryption (SSE-S3 "AES256", or "aws:kms" with a key id) and checks that the
    store confirms it. Reached directly (a store on the private network) or through the egress proxy (a cloud store,
    MASSLAK_FILES_S3_VIA_PROXY=true; its domain is added to the proxy's allowlist)."""
    name = "s3"

    def __init__(self, endpoint: str, bucket: str, access_key: str, secret_key: str, region: str = "us-east-1",
                 prefix: str = "", sse: str = "AES256", kms_key_id: str = "", path_style: bool = True,
                 via_proxy: bool = False, timeout: float = 15.0):
        u = urlparse(endpoint)
        if u.scheme not in ("http", "https") or not u.hostname or (u.path or "/") != "/":
            raise ValueError("MASSLAK_FILES_S3_ENDPOINT must look like https://s3.example.com (no path)")
        if sse not in ("AES256", "aws:kms"):
            raise ValueError("MASSLAK_FILES_S3_SSE must be AES256 or aws:kms")
        if not (bucket and access_key and secret_key):
            raise ValueError("the S3 file store needs MASSLAK_FILES_S3_BUCKET, _ACCESS_KEY and _SECRET_KEY")
        self.scheme, self.netloc = u.scheme, u.netloc
        self.bucket, self.prefix = bucket, prefix.strip("/") + "/" if prefix.strip("/") else ""
        self.access_key, self.secret_key, self.region = access_key, secret_key, region
        self.sse, self.kms_key_id = sse, kms_key_id
        self.path_style, self.via_proxy, self.timeout = path_style, via_proxy, timeout

    # ------------------------------------------------------------------ signing (AWS Signature Version 4)
    def sign(self, method: str, host: str, path: str, query: str, headers: dict, payload_hash: str, now: datetime) -> dict:
        """Returns the headers with x-amz-date, x-amz-content-sha256 and Authorization added. `path` is already
        URI-encoded; `query` is the canonical query string."""
        amz_date = now.strftime("%Y%m%dT%H%M%SZ")
        h = {k.lower(): str(v) for k, v in headers.items()}
        h.update({"host": host, "x-amz-date": amz_date, "x-amz-content-sha256": payload_hash})
        names = sorted(h)
        canonical = "\n".join([method, path, query, "".join(f"{k}:{' '.join(h[k].split())}\n" for k in names),
                               ";".join(names), payload_hash])
        scope = f"{amz_date[:8]}/{self.region}/s3/aws4_request"
        to_sign = "\n".join(["AWS4-HMAC-SHA256", amz_date, scope, hashlib.sha256(canonical.encode()).hexdigest()])
        key = ("AWS4" + self.secret_key).encode()
        for part in (amz_date[:8], self.region, "s3", "aws4_request"):
            key = hmac.new(key, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        h["authorization"] = (f"AWS4-HMAC-SHA256 Credential={self.access_key}/{scope}, "
                              f"SignedHeaders={';'.join(names)}, Signature={signature}")
        return h

    def _request(self, method: str, key: str, body: bytes = b"", headers: Optional[dict] = None) -> tuple[int, dict, bytes]:
        object_path = quote(self.prefix + key, safe="/-_.~")
        if self.path_style:
            host, path = self.netloc, f"/{quote(self.bucket, safe='-_.~')}/{object_path}"
        else:
            host, path = f"{self.bucket}.{self.netloc}", f"/{object_path}"
        signed = self.sign(method, host, path, "", headers or {}, hashlib.sha256(body).hexdigest(),
                           datetime.now(timezone.utc))
        req = urllib.request.Request(f"{self.scheme}://{host}{path}", data=body if method == "PUT" else None,
                                     method=method, headers=signed)
        try:
            if self.via_proxy:
                resp = egress.urlopen(req, timeout=self.timeout)
            else:   # a store on the private network: environment proxies are ignored
                resp = urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req, timeout=self.timeout)  # nosec B310
            with resp:
                return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
        except urllib.error.HTTPError as e:
            with e:
                status, data = e.code, e.read()
            if status >= 500 or status == 429:
                raise StoreUnavailable(f"FILE_STORE_UNAVAILABLE: {method} answered {status}") from None
            return status, {k.lower(): v for k, v in e.headers.items()}, data
        except (urllib.error.URLError, OSError) as e:
            raise StoreUnavailable(f"FILE_STORE_UNAVAILABLE: {method} failed ({type(e).__name__})") from None

    def write(self, key: str, data: bytes) -> None:
        headers = {"content-type": "application/octet-stream", "x-amz-server-side-encryption": self.sse}
        if self.sse == "aws:kms" and self.kms_key_id:
            headers["x-amz-server-side-encryption-aws-kms-key-id"] = self.kms_key_id
        status, h, body = self._request("PUT", key, data, headers)
        if status != 200:
            raise RuntimeError(f"FILE_STORE_REFUSED: PUT answered {status}: {body[:200].decode(errors='replace')}")
        if h.get("x-amz-server-side-encryption") != self.sse:
            # the store took the object without encrypting it: it must not stay there
            self._request("DELETE", key)
            raise RuntimeError("FILE_STORE_NOT_ENCRYPTED: the object store did not confirm server-side encryption "
                               f"({self.sse}); enable it on the store or the bucket")

    def read(self, key: str) -> bytes:
        status, _, body = self._request("GET", key)
        if status == 404:
            raise FileRejected("FILE_MISSING: the stored file is not in the file store")
        if status != 200:
            raise RuntimeError(f"FILE_STORE_REFUSED: GET answered {status}: {body[:200].decode(errors='replace')}")
        return body

    def exists(self, key: str) -> bool:
        status, _, _ = self._request("HEAD", key)
        if status not in (200, 404):
            raise RuntimeError(f"FILE_STORE_REFUSED: HEAD answered {status}")
        return status == 200


def s3_from_settings() -> S3Store:
    """The object store of the MASSLAK_FILES_S3_* settings (also used by app.tools.files_move before the switch)."""
    st = get_settings()
    if not st.sandbox and not st.files_s3_endpoint.startswith("https://"):
        raise ValueError("MASSLAK_FILES_S3_ENDPOINT must use https outside the sandbox")
    return S3Store(st.files_s3_endpoint, st.files_s3_bucket, st.files_s3_access_key,
                   st.files_s3_secret_key or _secret_file(st.files_s3_secret_key_file), region=st.files_s3_region,
                   prefix=st.files_s3_prefix, sse=st.files_s3_sse, kms_key_id=st.files_s3_kms_key_id,
                   path_style=st.files_s3_path_style, via_proxy=st.files_s3_via_proxy, timeout=st.files_s3_timeout)


def store_from_settings():
    backend = get_settings().files_backend
    if backend == "local":
        return LocalStore(get_settings().files_dir)
    if backend == "s3":
        return s3_from_settings()
    raise ValueError("MASSLAK_FILES_BACKEND must be local or s3")


def _secret_file(path: str) -> str:
    return Path(path).read_text().strip() if path and os.path.isfile(path) else ""


@lru_cache
def store():
    """The configured store (read once per process; startup fails on a wrong setting, see main.lifespan)."""
    return store_from_settings()


async def put(cipher: FieldCipher, data: bytes, generated_mime: str | None = None) -> Stored:
    """Stores an upload (its type recognised from its first bytes), or a file the platform generated itself
    (generated_mime, e.g. a scheduled report), which skips the upload limits."""
    if not data:
        raise FileRejected("FILE_EMPTY: the file is empty")
    if generated_mime is None and len(data) > get_settings().max_upload_bytes:
        raise FileRejected("FILE_TOO_LARGE: the file is larger than allowed")
    mime = generated_mime or detect(data)
    key = f"{secrets.token_hex(2)}/{secrets.token_hex(16)}"
    sealed = cipher.encrypt_bytes(data, f"file:{key}")
    await asyncio.to_thread(store().write, key, sealed.ciphertext)
    return Stored(key, mime, len(data), hashlib.sha256(data).digest(), sealed.key_id)


async def get(cipher: FieldCipher, storage_key: str, key_id: int, sha256: bytes) -> bytes:
    sealed = await asyncio.to_thread(store().read, storage_key)
    data = cipher.decrypt_bytes(sealed, key_id, f"file:{storage_key}")
    if hashlib.sha256(data).digest() != sha256:
        raise FileRejected("FILE_TAMPERED: the stored file does not match its hash")
    return data
