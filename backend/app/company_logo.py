"""A company's logo, shown next to its name on the station's departure board and in search results (owner's decision,
October 2026; migration 1115). The platform adds it when it defines the company, to a specification, as airports do:

    the file      PNG, JPEG or WebP, at most 1 MB
    the shape     a horizontal or square mark: as wide as it is high, up to four times as wide
    the size      at least 120 pixels high (and so at least 120 wide)
    kept as       a PNG re-encoded here, no taller than 240 pixels (so no wider than 960), without the file's metadata;
                  screens show it on a white tile, so a transparent background reads on the dark board too

Re-encoding keeps only pixels: whatever else the file held (metadata, scripts in a crafted file, other frames) is not
stored or served. The image is checked for its size before it is decoded, so a small file cannot unpack into a huge
picture.
"""
from __future__ import annotations

import hashlib
import io
from dataclasses import dataclass

from PIL import Image, UnidentifiedImageError

from .errors import ApiError

MAX_BYTES = 1024 * 1024
MIN_HEIGHT = 120
MAX_HEIGHT = 240
MAX_RATIO = 4
MAX_PIXELS = 25_000_000          # a decompression bomb is refused before it is decoded
FORMATS = ("PNG", "JPEG", "WEBP")


@dataclass(frozen=True)
class Logo:
    png: bytes
    width: int
    height: int
    sha256: bytes

    @property
    def version(self) -> str:
        """What the screens add to the logo's address, so a new logo is fetched and an unchanged one is cached."""
        return self.sha256[:6].hex()


def _refuse(code: str, message: str, **details) -> ApiError:
    return ApiError(422, code, message, **details)


def prepare(data: bytes) -> Logo:
    """The logo as it is kept, or a 422 naming the rule the file breaks."""
    if len(data) > MAX_BYTES:
        raise _refuse("LOGO_TOO_LARGE", "the logo file is larger than 1 MB", max_bytes=MAX_BYTES)
    try:
        im = Image.open(io.BytesIO(data), formats=FORMATS)
    except (UnidentifiedImageError, OSError, ValueError, Image.DecompressionBombError) as exc:
        raise _refuse("LOGO_FORMAT", "the logo is a PNG, JPEG or WebP image") from exc
    width, height = im.size
    if width * height > MAX_PIXELS:
        raise _refuse("LOGO_TOO_LARGE", "the logo has too many pixels", max_pixels=MAX_PIXELS)
    if height < MIN_HEIGHT:
        raise _refuse("LOGO_TOO_SMALL", "the logo is at least 120 pixels high", min_height=MIN_HEIGHT, height=height)
    if width < height or width > MAX_RATIO * height:
        raise _refuse("LOGO_SHAPE", "the logo is as wide as it is high, up to four times as wide", width=width, height=height)
    try:
        im.seek(0)                                  # the first frame of an animated file
        im.load()
    except (OSError, ValueError, Image.DecompressionBombError) as exc:
        raise _refuse("LOGO_FORMAT", "the logo image cannot be read") from exc
    im = im.convert("RGBA")
    if height > MAX_HEIGHT:
        new_w = min(MAX_RATIO * MAX_HEIGHT, max(MAX_HEIGHT, round(width * MAX_HEIGHT / height)))
        im = im.resize((new_w, MAX_HEIGHT), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    im.save(out, format="PNG", optimize=True)
    png = out.getvalue()
    return Logo(png=png, width=im.width, height=im.height, sha256=hashlib.sha256(png).digest())
