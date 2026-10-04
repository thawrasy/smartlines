"""Message wording per locale, from backend/app/i18n/<locale>.json. Only these files hold user-facing text."""
import json
import re
from functools import lru_cache
from pathlib import Path

_DIR = Path(__file__).resolve().parents[2] / "i18n"
_VAR = re.compile(r"\{(\w+)\}")


@lru_cache
def messages(locale: str) -> dict:
    path = _DIR / f"{locale}.json"
    if not path.exists():
        path = _DIR / "en.json"
    return json.loads(path.read_text(encoding="utf-8"))


def money(minor: int) -> str:
    return f"{minor // 100:,}"


def render(template: str, channel: str, locale: str, values: dict) -> tuple[str, str]:
    """Returns (subject, body). Unknown placeholders stay visible rather than failing silently."""
    t = messages(locale).get(template) or messages("en")[template]
    words = messages(locale)
    vals = {}
    for k, v in values.items():
        if k.endswith("amount") and isinstance(v, int):
            v = money(v)
        elif k.endswith("_city"):
            v = words.get("cities", {}).get(v, v)          # city codes become names in the reader's language
        elif k == "doc_type":
            v = words.get("doc_types", {}).get(v, v)
        vals[k] = v
    fill = lambda s: _VAR.sub(lambda m: str(vals.get(m.group(1), m.group(0))), s)
    body = t["sms"] if channel == "SMS" and "sms" in t else t["body"]
    return fill(t["subject"]), fill(body)


def mask(address: str) -> str:
    """o***@carrier.test, +9639******11"""
    if "@" in address:
        name, domain = address.split("@", 1)
        return f"{name[:1]}***@{domain}"
    return address[:5] + "*" * max(0, len(address) - 7) + address[-2:]
