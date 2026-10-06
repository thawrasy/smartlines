"""Share images (Open Graph, 1200x630) and the square logo, drawn once per process from the brand colours and wording."""
from __future__ import annotations

import io
from functools import lru_cache
from pathlib import Path

import arabic_reshaper
from bidi.algorithm import get_display
from PIL import Image, ImageDraw, ImageFont

from ..notify.render import messages

FONTS = Path(__file__).resolve().parents[2] / "assets" / "fonts"
NAVY, SKY, LIGHT, GREEN = (11, 31, 63), (47, 123, 255), (127, 176, 255), (18, 160, 106)


def _font(name: str, size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(FONTS / name), size)


def _text(s: str, rtl: bool) -> str:
    return get_display(arabic_reshaper.reshape(s)) if rtl else s


def _mark(d: ImageDraw.ImageDraw, x: int, y: int, size: int) -> None:
    """The route mark of the logo: an arc between a light-blue and a green stop."""
    k = size / 64
    d.rounded_rectangle([x, y, x + size, y + size], radius=int(16 * k), fill=NAVY)
    pts = []
    for i in range(41):                      # cubic Bezier of the logo path
        t = i / 40
        p0, p1, p2, p3 = (15.5, 43.5), (20.5, 32.5), (24.5, 22), (32.5, 22)
        q0, q1, q2, q3 = (32.5, 22), (39.5, 22), (41.5, 32.5), (48.5, 34.5)
        a, b, c, e = (p0, p1, p2, p3) if t < 0.5 else (q0, q1, q2, q3)
        u = t * 2 if t < 0.5 else (t - 0.5) * 2
        px = (1 - u) ** 3 * a[0] + 3 * (1 - u) ** 2 * u * b[0] + 3 * (1 - u) * u ** 2 * c[0] + u ** 3 * e[0]
        py = (1 - u) ** 3 * a[1] + 3 * (1 - u) ** 2 * u * b[1] + 3 * (1 - u) * u ** 2 * c[1] + u ** 3 * e[1]
        pts.append((x + px * k, y + py * k))
    d.line(pts, fill=SKY, width=max(2, int(6.5 * k)), joint="curve")
    for (cx, cy), col in (((15.5, 43.5), LIGHT), ((48.5, 34.5), GREEN)):
        r = 5.5 * k
        d.ellipse([x + cx * k - r, y + cy * k - r, x + cx * k + r, y + cy * k + r], fill=col)


@lru_cache(maxsize=4)
def og(lang: str) -> bytes:
    w = messages(lang)["seo"]
    rtl = lang == "ar"
    img = Image.new("RGB", (1200, 630), NAVY)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 560, 1200, 630], fill=(8, 24, 50))
    _mark(d, 1200 - 80 - 120 if rtl else 80, 80, 120)
    big, mid, small = _font("IBMPlexSansArabic-SemiBold.ttf", 76), _font("IBMPlexSansArabic-SemiBold.ttf", 44), _font("IBMPlexSansArabic-Regular.ttf", 30)
    lines = [(w["brand"], big, (255, 255, 255), 230), (w["home"]["h1"], mid, (255, 255, 255), 340), (w["tagline"], small, (201, 214, 234), 420)]
    for text, font, color, y in lines:
        t = _text(text, rtl)
        width = d.textlength(t, font=font)
        d.text((1200 - 80 - width if rtl else 80, y), t, font=font, fill=color)
    host = "masslak.com"
    d.text((80 if rtl else 1200 - 80 - d.textlength(host, font=small), 575), host, font=small, fill=(255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()


@lru_cache(maxsize=1)
def logo() -> bytes:
    img = Image.new("RGBA", (512, 512), (0, 0, 0, 0))
    _mark(ImageDraw.Draw(img), 0, 0, 512)
    buf = io.BytesIO()
    img.save(buf, "PNG", optimize=True)
    return buf.getvalue()
