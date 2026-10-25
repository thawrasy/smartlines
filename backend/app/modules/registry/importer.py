"""Import of the owner's phase-1 tables of banks and insurers (.xlsx). Every row comes in as UNVERIFIED and PENDING_REVIEW
with the source IMPORT, so a second person still reviews each one. A code already in the registry is skipped (a change to
a reviewed entry is proposed on screen). A row with a mistake refuses the whole file, saying what is wrong and where; a
SWIFT code that is not a valid SWIFT/BIC is kept aside for the follow-up with the bank instead of refusing the row."""
import io
import re
from typing import Any, Optional

from pydantic import ValidationError

from .service import SWIFT, BankIn, InsurerIn

MAX_FILE = 5 * 1024 * 1024
MAX_ROWS = 2000

# the owner's insurers table names some columns in Arabic: phone, fax, website (email carries "Email" in its header)
ALIASES = {
    "\u0631\u0642\u0645 \u0627\u0644\u0647\u0627\u062a\u0641": "phone",
    "\u0631\u0642\u0645 \u0627\u0644\u0641\u0627\u0643\u0633": "fax",
    "\u0627\u0644\u0645\u0648\u0642\u0639 \u0627\u0644\u0625\u0644\u0643\u062a\u0631\u0648\u0646\u064a": "website",
}
# read from the file but not kept as address lines
IGNORED = {"verification_status", "swift_status", "is_central_bank", "plus_code_from_file"}
KNOWN = {"banks": set(BankIn.model_fields) | {"is_central_bank"}, "insurers": set(InsurerIn.model_fields) | {"longitude", "latitude"}}


class RegistryFileError(Exception):
    pass


def _text(v: Any) -> str:
    if v is None:
        return ""
    if isinstance(v, float) and v.is_integer():
        v = int(v)
    return str(v).strip()


def _column(head: str) -> str:
    if head in ALIASES:
        return ALIASES[head]
    if "email" in head.lower():
        return "email"
    return head


def read(data: bytes, kind: str) -> list[dict]:
    """The checked rows of the workbook's first sheet, each ready for the registry."""
    import openpyxl
    try:
        wb = openpyxl.load_workbook(io.BytesIO(data), read_only=True, data_only=True)
    except Exception as e:                                       # not a workbook at all
        raise RegistryFileError("REGISTRY_FILE_FORMAT: not an Excel workbook") from e
    sheet = next((wb[s] for s in wb.sheetnames if s.endswith("_import")), wb[wb.sheetnames[0]])
    it = sheet.iter_rows(values_only=True)
    head = [_column(_text(h)) for h in next(it, ())]
    missing = [c for c in ("code", "name_ar", "name_en") if c not in head]
    if missing:
        raise RegistryFileError(f"REGISTRY_FILE_COLUMNS: the sheet lacks {', '.join(missing)}")
    problems: list[str] = []
    out: list[dict] = []
    seen: set[str] = set()
    for i, raw in enumerate(it, start=2):
        if not raw or all(v in (None, "") for v in raw):
            continue
        if len(out) >= MAX_ROWS:
            raise RegistryFileError(f"REGISTRY_FILE_ROWS: more than {MAX_ROWS} rows")
        row = {h: _text(v) for h, v in zip(head, raw) if h}
        code = row.get("code", "").upper()
        if code in seen:
            problems.append(f"row {i}: {code} twice")
            continue
        seen.add(code)
        item, problem = _bank(row, code) if kind == "banks" else _insurer(row, code, head)
        if problem:
            problems.append(f"row {i} ({code or 'no code'}): {problem}")
        elif item is not None:
            out.append(item)
    if problems:
        raise RegistryFileError("REGISTRY_FILE_ROWS: " + "; ".join(problems[:30]))
    return out


def _clean(row: dict, keys: tuple[str, ...]) -> dict:
    return {k: row[k] for k in keys if row.get(k)}


def _bank(row: dict, code: str) -> tuple[Optional[dict], Optional[str]]:
    swift = row.get("swift_bic", "").replace(" ", "").upper()
    reported = None
    status = (row.get("swift_status") or "TO_VERIFY").upper()
    if swift and not re.match(SWIFT, swift):
        reported, swift, status = swift[:20], "", "INVALID"
    central = row.get("is_central_bank", "").lower() in ("yes", "true", "1", "y")
    address = {k: row[k] for k in ("governorate", "city", "address") if row.get(k)}
    try:
        body = BankIn(code=code, name_ar=row["name_ar"], name_en=row["name_en"], swift_bic=swift or None,
                      swift_status=status if status in ("TO_VERIFY", "VERIFIED", "INVALID") else "TO_VERIFY",
                      bank_type=(row.get("bank_type") or ("CENTRAL" if central else "PRIVATE")).upper(), address=address,
                      **_clean(row, ("short_name", "iban_bank_code", "phone", "fax", "email", "website", "notes")))
    except ValidationError as e:
        return None, "; ".join(f"{'.'.join(map(str, x['loc']))} {x['msg']}" for x in e.errors())
    return {"body": body, "swift_reported": reported}, None


def _insurer(row: dict, code: str, head: list[str]) -> tuple[Optional[dict], Optional[str]]:
    address = {h: row[h] for h in head if h and h not in KNOWN["insurers"] and h not in IGNORED and row.get(h)}
    try:
        lat = float(row["latitude"]) if row.get("latitude") else None
        lng = float(row["longitude"]) if row.get("longitude") else None
    except ValueError:
        return None, "latitude or longitude is not a number"
    try:
        body = InsurerIn(code=code, name_ar=row["name_ar"], name_en=row["name_en"], lat=lat, lng=lng, address=address,
                         ownership=(row.get("ownership") or "PRIVATE").upper(),
                         insurance_kind=(row.get("insurance_kind") or "CONVENTIONAL").upper(),
                         **_clean(row, ("licence_no", "phone", "fax", "email", "website", "notes")))
    except ValidationError as e:
        return None, "; ".join(f"{'.'.join(map(str, x['loc']))} {x['msg']}" for x in e.errors())
    return {"body": body, "swift_reported": None}, None
