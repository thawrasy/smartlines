"""Know your customer for the companies on the platform (owner's request, October 2026; migration 1118).

The form is a versioned definition (iam.kyc_form): sections of fields, option sets and the documents asked for. Here
the answers a company or platform staff send are checked against the version the file follows, field by field: the
type, the range, the options, the rows of a table. Values the form marks sensitive (identity document and account
numbers) are encrypted before they are stored, bound to the company and the field, and kept with their last four
characters; the screens send them back as they received them to keep them, or a new value to replace them. The
database checks what is missing, scores the risk and runs the review stages.
"""
from __future__ import annotations

import base64
import re
from datetime import date
from typing import Any, Iterator

from ... import crypto

TEXT_MAX = {"text": 300, "textarea": 4000, "email": 254, "phone": 30, "url": 300, "station": 120}
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
PHONE = re.compile(r"^\+?[0-9][0-9 ()-]{5,24}$")
URL = re.compile(r"^https?://\S+$", re.IGNORECASE)
TIME = re.compile(r"^([01][0-9]|2[0-3]):[0-5][0-9]$")
COUNTRY = re.compile(r"^[A-Z]{2}$")
MONEY_MAX = 10 ** 15                     # minor units
MAX_ROWS = 200
SENSITIVE_MAX = 100


class Invalid(Exception):
    """Answers that do not fit the form: {field path: what is wrong}."""

    def __init__(self, errors: dict[str, str]):
        super().__init__(f"{len(errors)} answer(s) do not fit the form")
        self.errors = errors


def fields(definition: dict) -> Iterator[dict]:
    for section in definition.get("sections", []):
        yield from section.get("fields", [])


def option_values(definition: dict, name: str) -> set[str]:
    return {o["value"] if isinstance(o, dict) else o for o in definition.get("option_sets", {}).get(name, [])}


def aad(company_id: int, field: str, column: str | None = None) -> str:
    """The associated data of a sensitive value: copied to another company or field, it no longer decrypts."""
    return f"iam.company_kyc:{company_id}:{field}" + (f".{column}" if column else "")


def _empty(v: Any) -> bool:
    return v is None or v == [] or v == {} or (isinstance(v, str) and not v.strip())


def _number(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def check(spec: dict, v: Any, definition: dict) -> Any:
    """One answer, cleaned; ValueError with what is wrong."""
    t = spec["type"]
    if t in TEXT_MAX or t in ("date", "time", "select", "country"):
        if not isinstance(v, str):
            raise ValueError("text")
        v = v.strip()
        if t in TEXT_MAX and len(v) > int(spec.get("max", TEXT_MAX[t])):
            raise ValueError("too_long")
        if t == "email" and not EMAIL.match(v):
            raise ValueError("email")
        if t == "phone" and not PHONE.match(v):
            raise ValueError("phone")
        if t == "url" and not URL.match(v):
            raise ValueError("url")
        if t == "time" and not TIME.match(v):
            raise ValueError("time")
        if t == "country" and not COUNTRY.match(v):
            raise ValueError("country")
        if t == "date":
            try:
                d = date.fromisoformat(v)
            except ValueError as exc:
                raise ValueError("date") from exc
            if not 1900 <= d.year <= 2200:
                raise ValueError("date")
        if t == "select" and v not in option_values(definition, spec["options"]):
            raise ValueError("option")
        return v
    if t == "multi":
        allowed = option_values(definition, spec["options"])
        if not isinstance(v, list) or len(v) > 60 or not all(isinstance(x, str) and x in allowed for x in v) or len(set(v)) != len(v):
            raise ValueError("options")
        return v
    if t in ("number", "decimal", "percent", "money"):
        if not _number(v) or (t in ("number", "money") and not float(v).is_integer()):
            raise ValueError("number")
        if t in ("number", "money"):
            v = int(v)
        lo, hi = {"percent": (0, 100), "money": (0, MONEY_MAX)}.get(t, (spec.get("min"), spec.get("max")))
        lo, hi = spec.get("min", lo), spec.get("max", hi)
        if (lo is not None and v < lo) or (hi is not None and v > hi):
            raise ValueError("range")
        return round(v, 2) if t in ("decimal", "percent") else v
    if t == "yesno":
        if not isinstance(v, dict) or not isinstance(v.get("value"), bool):
            raise ValueError("yesno")
        details = v.get("details")
        if details is not None and (not isinstance(details, str) or len(details) > 1000):
            raise ValueError("too_long")
        out: dict[str, Any] = {"value": v["value"]}
        if v["value"] and details and details.strip():
            out["details"] = details.strip()
        return out
    if t == "bool":
        if not isinstance(v, bool):
            raise ValueError("bool")
        return v
    raise ValueError("type")


def _seal(fc: crypto.FieldCipher, v: Any, where: str) -> dict:
    """A sensitive value: a new one is encrypted; one sent back as stored is kept once it is proved to belong here."""
    if isinstance(v, dict) and "$enc" in v:
        try:
            fc.decrypt(base64.b64decode(v["$enc"], validate=True), int(v["$k"]), where)
        except Exception as exc:                      # noqa: BLE001 - malformed, or failing authentication: not this field's value
            raise ValueError("sealed") from exc
        return {"$enc": v["$enc"], "$k": int(v["$k"]), "$last4": str(v.get("$last4", ""))[:4]}
    if not isinstance(v, str) or len(v.strip()) > SENSITIVE_MAX:
        raise ValueError("text")
    sealed = fc.encrypt(v.strip(), where)
    return {"$enc": base64.b64encode(sealed.ciphertext).decode(), "$k": sealed.key_id, "$last4": crypto.last4(v)}


def clean(definition: dict, answers: dict, company_id: int, fc: crypto.FieldCipher) -> dict:
    """The answers that fit the form, with sensitive values encrypted; Invalid lists what does not fit. Keys the form
    does not have, empty values and empty rows are left out."""
    if not isinstance(answers, dict):
        raise Invalid({"": "object"})
    out: dict[str, Any] = {}
    errors: dict[str, str] = {}
    for f in fields(definition):
        key = f["key"]
        v = answers.get(key)
        if _empty(v):
            continue
        if f["type"] == "table":
            if not isinstance(v, list) or len(v) > MAX_ROWS:
                errors[key] = "rows"
                continue
            rows = []
            for i, row in enumerate(v):
                if not isinstance(row, dict):
                    errors[f"{key}.{i}"] = "row"
                    continue
                r: dict[str, Any] = {}
                for col in f["columns"]:
                    cv = row.get(col["key"])
                    if _empty(cv):
                        continue
                    try:
                        r[col["key"]] = (_seal(fc, cv, aad(company_id, key, col["key"])) if col.get("sensitive")
                                         else check(col, cv, definition))
                    except ValueError as exc:
                        errors[f"{key}.{i}.{col['key']}"] = str(exc)
                if r:
                    rows.append(r)
            if rows:
                out[key] = rows
            continue
        try:
            out[key] = _seal(fc, v, aad(company_id, key)) if f.get("sensitive") else check(f, v, definition)
        except ValueError as exc:
            errors[key] = str(exc)
    if errors:
        raise Invalid(errors)
    return out


def reveal(definition: dict, answers: dict, company_id: int, path: str, fc: crypto.FieldCipher) -> str:
    """One sensitive value in clear, by its path: "field" or "table.row.column"."""
    parts = path.split(".")
    spec = next((f for f in fields(definition) if f["key"] == parts[0]), None)
    if spec is None:
        raise LookupError(path)
    if len(parts) == 3 and spec["type"] == "table" and parts[1].isdigit():
        col = next((c for c in spec["columns"] if c["key"] == parts[2]), None)
        rows = answers.get(parts[0]) or []
        if col is None or not col.get("sensitive") or int(parts[1]) >= len(rows):
            raise LookupError(path)
        v, where = rows[int(parts[1])].get(parts[2]), aad(company_id, parts[0], parts[2])
    elif len(parts) == 1 and spec.get("sensitive"):
        v, where = answers.get(parts[0]), aad(company_id, parts[0])
    else:
        raise LookupError(path)
    if not isinstance(v, dict) or "$enc" not in v:
        raise LookupError(path)
    return fc.decrypt(base64.b64decode(v["$enc"]), int(v["$k"]), where)


def completeness(definition: dict, missing: list[str]) -> int:
    """The share of the required fields answered (the documents are counted apart)."""
    required = [f["key"] for f in fields(definition) if f.get("required")]
    if not required:
        return 100
    lacking = {m.split(".")[0] for m in missing if not m.startswith("doc:")}
    return round(100 * sum(1 for k in required if k not in lacking) / len(required))
