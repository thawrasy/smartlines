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
    from ...money import text
    return text(minor)


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
        elif k in ("incident_type", "severity", "refund_to", "reason_code"):   # codes become words (1101, 1102, 1148)
            v = words.get(k + "_labels", {}).get(v, v)
        vals[k] = v
    if template.startswith("security.") or template == "account.signed_in_elsewhere":   # the shield (1142)
        lab = words.get("shield_labels", {})
        for k in ("kind", "severity", "level", "previous", "client", "status"):
            if k in values:
                vals[k + "_label"] = lab.get(str(values[k]), str(values[k]))
        vals["by_label"] = lab.get("AUTO" if values.get("auto") else "STAFF", "")
        vals["metrics_text"] = ", ".join(f"{k} {v}" for k, v in (values.get("metrics") or {}).items())
        vals["actions_text"] = ", ".join(lab.get(a.get("action", ""), a.get("action", "")) for a in (values.get("actions") or [])) \
            or lab.get("NONE", "")
    if template.startswith("booking.trip_changed."):         # a trip change (N42): seats and the moved time read as words
        vals["seats_text"] = ", ".join(str(x) for x in (values.get("new_seats") or [])) or "-"
        shift = int(values.get("shift_min") or 0)
        vals["shift_text"] = f"{'+' if shift > 0 else '-'}{abs(shift) // 60:d}:{abs(shift) % 60:02d}"
        vals["free_cancel_text"] = words.get("trip_change_labels", {}).get("FREE_CANCEL", "") if values.get("free_cancel") else ""
        if vals.get("new_trip_code") is None and "new_trip_no" in vals:
            vals["new_trip_code"] = vals["new_trip_no"]
    if template == "fuel.filled":                            # a fill (1180): money, fuel and the checks read as words
        lab = words.get("fuel_labels", {})
        vals["balance"] = money(int(values.get("balance") or 0))
        left = values.get("left_amount")
        vals["left_amount"] = money(int(left)) if left is not None else lab.get("NO_BUDGET", "-")
        vals["fuel_type"] = lab.get(str(values.get("fuel_type")), values.get("fuel_type"))
        vals["held_note"] = " ".join(x for x in (lab.get("HELD", "") if values.get("held") else "",
                                                 lab.get("LOW_BALANCE", "") if values.get("low_balance") else "") if x)
    if vals.get("trip_code") is None and "trip_no" in vals:   # the trip number passengers read (1114), else the reference
        vals["trip_code"] = vals["trip_no"]
    def fill(s: str) -> str:
        return _VAR.sub(lambda m: str(vals.get(m.group(1), m.group(0))), s)
    body = t["sms"] if channel == "SMS" and "sms" in t else t["body"]
    return fill(t["subject"]), fill(body)


def mask(address: str) -> str:
    """o***@carrier.test, +9639******11"""
    if "@" in address:
        name, domain = address.split("@", 1)
        return f"{name[:1]}***@{domain}"
    return address[:5] + "*" * max(0, len(address) - 7) + address[-2:]
