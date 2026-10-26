"""What makes a fill hard to cheat (owner's note of 26 October 2026; migration 1181; docs/design/FUEL_STATIONS.md).

Secure tags. The platform hands carriers NTAG 424 DNA tags programmed for Secure Unique NFC (SUN, NXP AN12196): each tap
the tag writes a fresh message, picc_data (its serial and a counter, encrypted with the shared meta key) and cmac (a MAC
of the tap with a key drawn from the tag's serial). A copied tag cannot make a valid MAC; a recorded message replays a
counter the database has already seen. A plain tag gives its serial only and counts as a riskier fill.

Pump stickers. Each pump carries a QR sticker beside its meter: "FP1" + base32(pump uid, sticker version, HMAC). A new
sticker raises the version and the old one stops working.

Live photos. The pump app takes the meter's photo from the live camera (no gallery, no file picker) and sends the frame
as a JPEG with no metadata. A file carrying a camera's metadata (EXIF) came from somewhere else and is refused. Each
photo's 64-bit difference hash goes to the database, which flags a near match with a recent photo as a reused picture.
"""
import base64
import hashlib
import hmac
import io
import re
import uuid
from typing import Optional

from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.cmac import CMAC
from PIL import Image, UnidentifiedImageError

from ...config import get_settings
from ...errors import ApiError

MIN_SIDE = 240                      # the shorter side of a camera frame, in pixels


def tag_hash(serial_hex: str) -> bytes:
    """The NFC tag's serial number, normalised; only its hash is ever stored (the same for a serial or a SUN message)."""
    return hashlib.sha256("fuel-tag:".encode() + serial_hex.strip().upper().replace(":", "").replace(" ", "").encode()).digest()


# ------------------------------------------------------------------ secure tags (NTAG 424 DNA, SUN)
def _master() -> bytes:
    key = get_settings().fuel_tag_key.strip()
    if key:
        return bytes.fromhex(key)
    return hmac.new(get_settings().signing_secret.encode(), b"fuel-tag-master", hashlib.sha256).digest()[:16]


def meta_key() -> bytes:
    """The key every tag encrypts its serial and counter with (SDMMetaRead)."""
    return hmac.new(_master(), b"sdm-meta", hashlib.sha256).digest()[:16]


def file_key(uid: bytes) -> bytes:
    """The tag's own MAC key (SDMFileRead), drawn from its serial: one tag's key opens no other."""
    return hmac.new(_master(), b"sdm-file" + uid, hashlib.sha256).digest()[:16]


def _cmac(key: bytes, data: bytes) -> bytes:
    c = CMAC(algorithms.AES(key))
    c.update(data)
    return c.finalize()


def read_sun(message: str, meta: Optional[bytes] = None, file_key_of=None) -> tuple[str, int]:
    """Checks a tap's message (the tag's URL, or its picc_data and cmac) and returns the tag's serial and counter."""
    found = dict(re.findall(r"(picc_data|picc|e|cmac|c)=([0-9A-Fa-f]+)", message))
    picc = found.get("picc_data") or found.get("picc") or found.get("e")
    mac = found.get("cmac") or found.get("c")
    if not picc or not mac or len(picc) != 32 or len(mac) != 16:
        raise ApiError(422, "FUEL_TAG_MESSAGE", "this is not a secure tag's message")
    d = Cipher(algorithms.AES(meta or meta_key()), modes.CBC(bytes(16))).decryptor()
    plain = d.update(bytes.fromhex(picc)) + d.finalize()
    if plain[0] != 0xC7:                       # the serial (7 bytes) and the counter are both mirrored
        raise ApiError(422, "FUEL_TAG_MESSAGE", "this is not a secure tag's message")
    uid, ctr = plain[1:8], plain[8:11]
    session = _cmac((file_key_of or file_key)(uid), bytes.fromhex("3CC300010080") + uid + ctr)
    expected = _cmac(session, b"")[1::2]
    if not hmac.compare_digest(expected, bytes.fromhex(mac)):
        raise ApiError(422, "FUEL_TAG_FORGED", "the tag's signature does not match: not a tag the platform issued")
    return uid.hex().upper(), int.from_bytes(ctr, "little")


# ------------------------------------------------------------------ the pumps' QR stickers
def _pump_key() -> bytes:
    return hmac.new(get_settings().signing_secret.encode(), b"fuel-pump-sticker", hashlib.sha256).digest()


def pump_code(pump_uid: uuid.UUID, version: int) -> str:
    body = pump_uid.bytes + version.to_bytes(2, "big")
    return "FP1" + base64.b32encode(body + hmac.new(_pump_key(), body, hashlib.sha256).digest()[:10]).decode().rstrip("=")


def read_pump_code(code: str) -> tuple[uuid.UUID, int]:
    raw = code.strip().upper().replace(" ", "")
    try:
        data = base64.b32decode(raw[3:] + "=" * (-len(raw[3:]) % 8)) if raw.startswith("FP1") else b""
    except ValueError:
        data = b""
    body, sig = data[:18], data[18:]
    if len(data) != 28 or not hmac.compare_digest(sig, hmac.new(_pump_key(), body, hashlib.sha256).digest()[:10]):
        raise ApiError(422, "FUEL_PUMP_QR_INVALID", "this is not a pump sticker of the platform")
    return uuid.UUID(bytes=body[:16]), int.from_bytes(body[16:], "big")


def controller_hash(key: str) -> bytes:
    return hashlib.sha256(("fuel-controller:" + key).encode()).digest()


# ------------------------------------------------------------------ live photos
def _has_exif(data: bytes) -> bool:
    """Whether a JPEG carries an APP1 Exif segment (what a camera app or a gallery file writes)."""
    i = 2
    while i + 4 <= len(data) and data[i] == 0xFF:
        marker, size = data[i + 1], int.from_bytes(data[i + 2:i + 4], "big")
        if marker == 0xE1 and data[i + 4:i + 10] == b"Exif\x00\x00":
            return True
        if marker in (0xDA, 0xD9):             # the image data starts: no more metadata segments
            return False
        i += 2 + size
    return False


def live_photo(data: bytes) -> int:
    """Checks a photo is a frame of the app's live camera and returns its difference hash (a signed 64-bit number)."""
    if not data.startswith(b"\xff\xd8"):
        raise ApiError(422, "FUEL_PHOTO_NOT_LIVE", "take the photo with the app's camera")
    if _has_exif(data):
        raise ApiError(422, "FUEL_PHOTO_NOT_LIVE", "this photo was not taken with the app's camera; a saved picture is not accepted")
    try:
        img = Image.open(io.BytesIO(data))
        img.load()
    except (UnidentifiedImageError, OSError) as exc:
        raise ApiError(422, "FUEL_PHOTO_NOT_LIVE", "the photo cannot be read") from exc
    if min(img.size) < MIN_SIDE:
        raise ApiError(422, "FUEL_PHOTO_NOT_LIVE", "the photo is too small to read the meter")
    return dhash(img)


def dhash(img: Image.Image) -> int:
    small = img.convert("L").resize((9, 8), Image.Resampling.LANCZOS)
    px = list(small.getdata())
    bits = 0
    for row in range(8):
        for col in range(8):
            bits = (bits << 1) | (px[row * 9 + col] > px[row * 9 + col + 1])
    return bits - (1 << 64) if bits >= 1 << 63 else bits


def sun_message(uid_hex: str, counter: int) -> str:
    """The message a programmed tag writes on a tap (for the programming bench's check and the tests)."""
    uid = bytes.fromhex(uid_hex)
    ctr = counter.to_bytes(3, "little")
    e = Cipher(algorithms.AES(meta_key()), modes.CBC(bytes(16))).encryptor()
    picc = e.update(bytes([0xC7]) + uid + ctr + bytes(5)) + e.finalize()
    session = _cmac(file_key(uid), bytes.fromhex("3CC300010080") + uid + ctr)
    return f"picc_data={picc.hex().upper()}&cmac={_cmac(session, b'')[1::2].hex().upper()}"
