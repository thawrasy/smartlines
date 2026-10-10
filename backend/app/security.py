"""Password hashing, session tokens and signed QR / verification tokens."""
import base64
import hashlib
import hmac
import json
import os
import re
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


def password_needs_rehash(stored: str | None) -> bool:
    """True when a stored hash was made with other Argon2 parameters than _hasher's (reviews of release 1.49.0): the
    next successful sign-in stores a new hash of the same password, so raising the parameters reaches every account
    that signs in, with no reset."""
    if not stored:
        return False
    try:
        return _hasher.check_needs_rehash(stored)
    except InvalidHashError:
        return False


def verify_password(stored: str | None, password: str) -> bool:
    if not stored:
        _hasher.hash(password)  # equalise timing when the account has no password
        return False
    try:
        return _hasher.verify(stored, password)
    except (VerifyMismatchError, VerificationError, InvalidHashError):
        return False


# rows of the keyboard and runs of letters and digits: a password that is one slice of these is guessed first
_RUNS = ("1234567890", "abcdefghijklmnopqrstuvwxyz", "qwertyuiop", "asdfghjkl", "zxcvbnm", "1qaz2wsx3edc4rfv5tgb")


@lru_cache(maxsize=1)
def _common() -> frozenset[str]:
    """73,000 passwords of 12 characters or more from public leak lists (assets/passwords/README.md)."""
    import gzip
    from pathlib import Path
    path = Path(__file__).parent / "assets" / "passwords" / "common.txt.gz"
    with gzip.open(path, "rt", encoding="ascii") as f:
        return frozenset(line.rstrip("\n") for line in f if line.strip())


def _is_run(text: str) -> bool:
    """A slice of one run, forwards or backwards, repeated or not (abcdefghijkl, 0987654321, 123412341234)."""
    for run in _RUNS:
        for seq in (run * 3, run[::-1] * 3):
            if text in seq:
                return True
    return False


def password_problem(password: str, *personal: str | None) -> str | None:
    """Policy of NIST SP 800-63B, without composition rules: at least 12 characters; not a password common in leaks
    (reviews of October 2026, M-13), a repeated pattern, a keyboard or alphabet run, or the platform's name; and not
    built on the person's own e-mail, name or mobile number (`personal`)."""
    if len(password) < 12:
        return "PASSWORD_TOO_SHORT"
    low = password.lower()
    folded = "".join(ch for ch in low if ch.isalnum())
    if low in _common() or folded in _common():
        return "PASSWORD_TOO_COMMON"
    if len(set(low)) <= 3 or _is_run(folded) or "masslak" in folded or any(
            folded == folded[:n] * (len(folded) // n) + folded[:len(folded) % n] for n in range(1, 5)):
        return "PASSWORD_TOO_COMMON"
    for value in personal:
        for part in _personal_parts(value):
            if part in folded:
                return "PASSWORD_TOO_PERSONAL"
    return None


def _personal_parts(value: str | None) -> list[str]:
    """The pieces of an e-mail, a name or a mobile number someone could guess: an e-mail's local part and each of
    its words of four letters or more, each name word of four letters or more, a mobile number's last seven digits."""
    if not value:
        return []
    value = value.strip().lower()
    digits = "".join(ch for ch in value if ch.isdigit())
    if len(digits) >= 7 and len(digits) >= len(value.replace("+", "").replace(" ", "")) - 1:
        return [digits[-7:]]
    local = value.split("@", 1)[0]
    words = [w for w in "".join(ch if ch.isalnum() else " " for ch in local).split() if len(w) >= 4]
    whole = "".join(ch for ch in local if ch.isalnum())
    return ([whole] if len(whole) >= 4 else []) + words


def new_token() -> tuple[str, bytes]:
    """Returns (token for the client, SHA-256 hash for the database)."""
    token = secrets.token_urlsafe(32)
    return token, token_hash(token)


def token_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode()).digest()


def lookup_digests(message: bytes) -> list[bytes]:
    """The digests of a value that is only ever looked up (a login identifier, a family invite code): one per key of
    MASSLAK_LOOKUP_KEYS, the first key's digest first. New records are stored with the first; a lookup matches any
    (reviews of release 1.49.0: the key of these digests is no longer the signing secret, so a leaked secret does not
    give the blocklist or the invite codes)."""
    return [hmac.new(key, message, hashlib.sha256).digest() for _, key in token_keys("lookup")]


def identifier_hashes(identifier: str) -> list[bytes]:
    return lookup_digests(identifier.lower().encode())


def identifier_hash(identifier: str) -> bytes:
    """The digest a new record is stored under."""
    return identifier_hashes(identifier)[0]


async def identifier_blocked(conn, kind: str, value: str) -> bool:
    """Whether a value is on the active blocklist under any key, so a block stored before a key change still applies."""
    for digest in identifier_hashes("".join(str(value).split())):           # spaces inside a number or address do not count
        if await conn.fetchval("SELECT sec.is_blocked($1, $2)", kind, digest):
            return True
    return False


def _b64(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


# ------------------------------------------------------------------ token keys, one per purpose (reviews of release 1.49.0)
# The rotating ticket codes (Q1) and the verification tokens printed on documents (D2) are signed with keys of their
# own, and every token names its key (a key id), so a key can be replaced while the tokens it signed still verify:
#   MASSLAK_QR_KEYS, MASSLAK_DOCUMENT_KEYS   kid:base64-of-32-bytes[,kid:base64...]
# The first key signs; every key listed verifies (the overlap of a rotation). A bare "s1" in the list is the key derived
# from the signing secret for that purpose alone (HKDF), which is what an unset variable means, so a server can move
# from the derived key to keys of its own without refusing the tokens already issued. Production requires keys of their
# own (app.profile). The tokens before release 1.50.0 (T1, D1) were signed with the signing secret itself: rotating
# codes live for two windows, so T1 is refused; D1 stays valid on printed documents until
# MASSLAK_LEGACY_DOCUMENT_TOKENS=refuse.
TOKEN_KEY_ENV = {"qr": "MASSLAK_QR_KEYS", "document": "MASSLAK_DOCUMENT_KEYS", "lookup": "MASSLAK_LOOKUP_KEYS"}
DERIVED_KID = "s1"
_KID = re.compile(r"^[a-z0-9]{1,12}$")


def _derived_token_key(purpose: str) -> bytes:
    if purpose == "lookup":           # digests stored before release 1.50.0 are keyed with the signing secret itself
        return get_settings().signing_secret.encode()
    from cryptography.hazmat.primitives.hashes import SHA256
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    return HKDF(algorithm=SHA256(), length=32, salt=b"masslak-keys", info=f"token/{purpose}".encode()).derive(
        get_settings().signing_secret.encode())


def parse_token_keys(purpose: str, raw: str) -> list[tuple[str, bytes]]:
    """The keys of one purpose, the signing key first; raises KeyConfigError on a malformed list."""
    name = TOKEN_KEY_ENV[purpose]
    if not raw.strip():
        return [(DERIVED_KID, _derived_token_key(purpose))]
    keys: list[tuple[str, bytes]] = []
    for item in raw.split(","):
        kid, _, b64 = item.strip().partition(":")
        if not _KID.match(kid):
            raise KeyConfigError(f"{name}: a key id is 1 to 12 lowercase letters or digits")
        if kid == DERIVED_KID and not b64:
            keys.append((kid, _derived_token_key(purpose)))
            continue
        try:
            key = base64.b64decode(b64, validate=True)
        except ValueError:
            key = b""
        if len(key) != 32:
            raise KeyConfigError(f"{name}: key {kid} must be base64 of 32 bytes")
        if any(k == kid for k, _ in keys):
            raise KeyConfigError(f"{name}: key id {kid} is listed twice")
        keys.append((kid, key))
    return keys


@lru_cache(maxsize=None)
def token_keys(purpose: str) -> tuple[tuple[str, bytes], ...]:
    return tuple(parse_token_keys(purpose, os.environ.get(TOKEN_KEY_ENV[purpose], "")))


def _mac(key: bytes, payload: str) -> str:
    return _b64(hmac.new(key, payload.encode(), hashlib.sha256).digest()[:16])


def _verify_mac(purpose: str, kid: str, payload: str, sig: str) -> bool:
    key = dict(token_keys(purpose)).get(kid)
    return key is not None and hmac.compare_digest(sig, _mac(key, payload))


def _legacy_sign(payload: str) -> str:
    """Tokens issued before release 1.50.0: signed with the signing secret itself."""
    return _mac(get_settings().signing_secret.encode(), payload)


def ticket_qr_token(ticket_uid: str, now: float | None = None) -> tuple[str, int]:
    """Rotating ticket code: changes every qr_window_seconds; Q1.<key id>.<ticket>.<window>.<signature>."""
    window = get_settings().qr_window_seconds
    t = int((now or time.time()) // window)
    kid, key = token_keys("qr")[0]
    payload = f"Q1.{kid}.{ticket_uid}.{t}"
    return f"{payload}.{_mac(key, payload)}", (t + 1) * window


def verify_ticket_qr(token: str, now: float | None = None) -> str | None:
    """Returns the ticket uid when the token is authentic and inside the current or previous window."""
    try:
        version, kid, uid, t_str, sig = token.split(".")
        t = int(t_str)
    except ValueError:
        return None
    if version != "Q1" or not _verify_mac("qr", kid, f"{version}.{kid}.{uid}.{t}", sig):
        return None
    current = int((now or time.time()) // get_settings().qr_window_seconds)
    if t not in (current, current - 1):
        return None
    return uid


def document_token(kind: str, uid: str) -> str:
    """Static signed token printed on official documents for public verification (16.25)."""
    kid, key = token_keys("document")[0]
    payload = f"D2.{kid}.{kind}.{uid}"
    return f"{payload}.{_mac(key, payload)}"


def legacy_document_tokens_accepted() -> bool:
    return os.environ.get("MASSLAK_LEGACY_DOCUMENT_TOKENS", "accept").strip().lower() != "refuse"


def verify_document_token(token: str) -> tuple[str, str] | None:
    parts = token.split(".")
    if len(parts) == 5 and parts[0] == "D2":
        version, kid, kind, uid, sig = parts
        return (kind, uid) if _verify_mac("document", kid, f"{version}.{kid}.{kind}.{uid}", sig) else None
    if len(parts) == 4 and parts[0] == "D1" and legacy_document_tokens_accepted():
        version, kind, uid, sig = parts
        return (kind, uid) if hmac.compare_digest(sig, _legacy_sign(f"{version}.{kind}.{uid}")) else None
    return None


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
    if not raw and not get_settings().sandbox:
        raise KeyConfigError("MASSLAK_TICKET_SIGNING_KEY must be set outside the sandbox")
    seed = base64.b64decode(raw) if raw else HKDF(algorithm=SHA256(), length=32, salt=b"masslak-dev-keys",
                                                   info=b"ticket-credential").derive(get_settings().signing_secret.encode())
    return Ed25519PrivateKey.from_private_bytes(seed)


# ------------------------------------------------------------------ start-up check of the signing keys
# The built-in default of MASSLAK_SIGNING_SECRET is public (it is in this repository), and a server installed by hand
# could run with it, or with an empty value from a copied .env.example: every QR code, verification link and
# derived token could then be forged. Outside the sandbox the API and the worker refuse to start instead
# (review of October 2026, stage A1).

DEFAULT_SIGNING_SECRET = "change-me-in-production-0123456789abcdef"
MIN_SIGNING_SECRET = 32


class KeyConfigError(RuntimeError):
    pass


def signing_key_problems(secret: str, ticket_key: str) -> list[str]:
    """What is wrong with the signing keys for production use; empty when they are fit."""
    problems = []
    lowered = secret.lower()
    if not secret.strip():
        problems.append("MASSLAK_SIGNING_SECRET is not set")
    elif secret == DEFAULT_SIGNING_SECRET or "change-me" in lowered or "not-for-production" in lowered:
        problems.append("MASSLAK_SIGNING_SECRET is a placeholder value")
    elif len(secret.encode()) < MIN_SIGNING_SECRET:
        problems.append(f"MASSLAK_SIGNING_SECRET is shorter than {MIN_SIGNING_SECRET} bytes")
    elif len(set(secret)) < 8:
        problems.append("MASSLAK_SIGNING_SECRET is not random")
    if not ticket_key.strip():
        problems.append("MASSLAK_TICKET_SIGNING_KEY is not set")
    else:
        try:
            seed = base64.b64decode(ticket_key.strip(), validate=True)
        except ValueError:
            seed = b""
        if len(seed) != 32:
            problems.append("MASSLAK_TICKET_SIGNING_KEY must be base64 of 32 bytes")
        elif secret and seed == secret.encode()[:32]:
            problems.append("MASSLAK_TICKET_SIGNING_KEY must not be the signing secret")
    return problems


def require_keys_in_production() -> None:
    """Called at start by the API and the worker: a malformed token key list stops the process anywhere; outside the
    sandbox, weak or missing signing keys too."""
    for purpose in TOKEN_KEY_ENV:
        token_keys(purpose)
    if get_settings().sandbox:
        return
    problems = signing_key_problems(get_settings().signing_secret, os.environ.get("MASSLAK_TICKET_SIGNING_KEY", ""))
    if problems:
        raise KeyConfigError("refusing to start outside the sandbox: " + "; ".join(problems)
                             + " (generate them with deploy/init-env.sh or from the secret store)")


# ------------------------------------------------------------------ the request context ticket (reviews of October 2026, C-01)
# Row-level security trusts the context the API sets at the start of each transaction (sys.set_context). The API's
# login must not be able to set any other: the database accepts a context from it only with a ticket, an HMAC of the
# context under a key the login can never read (sys.context_key, written by the deployment from this same derivation).
# The key is derived from the signing secret for this purpose alone (HKDF), so knowing it says nothing about the secret.
CONTEXT_TICKET_VERSION = "masslak-context-v1"


@lru_cache(maxsize=1)
def context_key() -> bytes:
    from cryptography.hazmat.primitives.hashes import SHA256
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    return HKDF(algorithm=SHA256(), length=32, salt=b"masslak-keys", info=b"db-context-ticket").derive(
        get_settings().signing_secret.encode())


def context_key_fingerprint(key: bytes | None = None) -> str:
    return hashlib.sha256(key or context_key()).hexdigest()[:16]


def context_ticket(fields: tuple, issued_at: int) -> str:
    """fields: user, company, scope, API client, request id, session, party, in this order (sys.set_context)."""
    message = "|".join([CONTEXT_TICKET_VERSION, *("" if f is None else str(f) for f in fields), str(issued_at)])
    return context_key_fingerprint() + "." + hmac.new(context_key(), message.encode(), hashlib.sha256).hexdigest()


def ticket_public_key() -> str:
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    return _b64(_ticket_key().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))


# ------------------------------------------------------------------ issued manifests (Ed25519, 1078)
# The hash of every issued manifest is signed so an authority can prove the manifest it received is the one the
# carrier issued. The key is derived from the ticket signing seed for its own purpose (HKDF, so knowing one key says
# nothing about the other), unless MASSLAK_MANIFEST_SIGNING_KEY gives one of its own (base64 of 32 bytes).
MANIFEST_KID = "manifest-signature/v1"


@lru_cache(maxsize=1)
def _manifest_key():
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.hashes import SHA256
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat
    raw = os.environ.get("MASSLAK_MANIFEST_SIGNING_KEY", "").strip()
    if raw:
        return Ed25519PrivateKey.from_private_bytes(base64.b64decode(raw))
    ticket_seed = _ticket_key().private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
    return Ed25519PrivateKey.from_private_bytes(
        HKDF(algorithm=SHA256(), length=32, salt=b"masslak-manifest", info=MANIFEST_KID.encode()).derive(ticket_seed))


def manifest_sign(digest: bytes) -> bytes:
    return _manifest_key().sign(digest)


def manifest_public_key() -> str:
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    return _b64(_manifest_key().public_key().public_bytes(Encoding.Raw, PublicFormat.Raw))


def manifest_signature_valid(digest: bytes, signature: bytes) -> bool:
    from cryptography.exceptions import InvalidSignature
    try:
        _manifest_key().public_key().verify(signature, digest)
        return True
    except InvalidSignature:
        return False


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
