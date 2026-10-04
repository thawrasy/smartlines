"""Password hashing, session tokens and signed QR / verification tokens."""
import base64
import hashlib
import hmac
import json
import os
import secrets
import time
from functools import lru_cache

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError, VerifyMismatchError

from .config import get_settings

# Argon2id parameters from study 16.18: 64 MiB memory, 3 iterations, parallelism 1
_hasher = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=1)


def hash_password(password: str) -> str:
    return _hasher.hash(password)


def verify_password(stored: str | None, password: str) -> bool:
    if not stored:
        _hasher.hash(password)  # equalise timing when the account has no password
        return False
    try:
        return _hasher.verify(stored, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


def password_problem(password: str) -> str | None:
    """Minimum policy (NIST 800-63B): length and a short deny list, no composition rules."""
    if len(password) < 12:
        return "PASSWORD_TOO_SHORT"
    if password.lower() in {"123456789012", "password1234", "qwertyuiopas", "masslak12345"}:
        return "PASSWORD_TOO_COMMON"
    return None


def new_token() -> tuple[str, bytes]:
    """Returns (token for the client, SHA-256 hash for the database)."""
    token = secrets.token_urlsafe(32)
    return token, token_hash(token)


def token_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


def identifier_hash(identifier: str) -> bytes:
    return hmac.new(get_settings().signing_secret.encode(), identifier.lower().encode(), hashlib.sha256).digest()


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _sign(payload: str) -> str:
    key = get_settings().signing_secret.encode()
    return _b64(hmac.new(key, payload.encode(), hashlib.sha256).digest()[:16])


def ticket_qr_token(ticket_uid: str, now: float | None = None) -> tuple[str, int]:
    """Rotating ticket code: changes every qr_window_seconds, verifiable offline with the key."""
    window = get_settings().qr_window_seconds
    t = int((now or time.time()) // window)
    payload = f"T1.{ticket_uid}.{t}"
    return f"{payload}.{_sign(payload)}", (t + 1) * window


def verify_ticket_qr(token: str, now: float | None = None) -> str | None:
    """Returns the ticket uid when the token is authentic and inside the current or previous window."""
    try:
        version, uid, t_str, sig = token.split(".")
        t = int(t_str)
    except ValueError:
        return None
    if version != "T1":
        return None
    payload = f"{version}.{uid}.{t}"
    if not hmac.compare_digest(sig, _sign(payload)):
        return None
    current = int((now or time.time()) // get_settings().qr_window_seconds)
    if t not in (current, current - 1):
        return None
    return uid


def document_token(kind: str, uid: str) -> str:
    """Static signed token printed on official documents for public verification (16.25)."""
    payload = f"D1.{kind}.{uid}"
    return f"{payload}.{_sign(payload)}"


def verify_document_token(token: str) -> tuple[str, str] | None:
    try:
        version, kind, uid, sig = token.split(".")
    except ValueError:
        return None
    payload = f"{version}.{kind}.{uid}"
    if version != "D1" or not hmac.compare_digest(sig, _sign(payload)):
        return None
    return kind, uid


# ------------------------------------------------------------------ offline ticket credentials (Ed25519)
# A credential lets the driver app check a ticket with no connection. The platform signs it with a private key
# that never leaves the server (MASSLAK_TICKET_SIGNING_KEY, a base64 Ed25519 seed; in development a key derived
# from the signing secret); apps hold only the public key, which can verify but never create a ticket.
# A credential is valid for one trip, so a copy can board at most once and shows as a duplicate.

@lru_cache(maxsize=1)
def _ticket_key():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.hashes import SHA256
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    raw = os.environ.get("MASSLAK_TICKET_SIGNING_KEY", "").strip()
    seed = base64.b64decode(raw) if raw else HKDF(algorithm=SHA256(), length=32, salt=b"masslak-dev-keys",
                                                   info=b"ticket-credential").derive(get_settings().signing_secret.encode())
    return Ed25519PrivateKey.from_private_bytes(seed)


def ticket_public_key() -> str:
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    return _b64(_ticket_key().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))


def ticket_credential(claims: dict) -> str:
    """T2.<payload>.<signature>, both base64url; claims: k ticket, t trip, s seat, n name, a/b stops, x expiry."""
    payload = _b64(json.dumps({"v": 2, **claims}, separators=(",", ":"), ensure_ascii=False).encode())
    return f"T2.{payload}.{_b64(_ticket_key().sign(payload.encode()))}"


def verify_ticket_credential(token: str, now: float | None = None) -> dict | None:
    from cryptography.exceptions import InvalidSignature
    try:
        version, payload, sig = token.split(".")
        if version != "T2":
            return None
        _ticket_key().public_key().verify(base64.urlsafe_b64decode(sig + "=" * (-len(sig) % 4)), payload.encode())
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (ValueError, InvalidSignature):
        return None
    if claims.get("x", 0) < (now or time.time()):
        return None
    return claims
