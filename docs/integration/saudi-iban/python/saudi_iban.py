"""Saudi IBAN validation: ISO 13616 structure, ISO 7064 MOD 97-10 check digits, and the SAMA bank-code lookup.

Reference implementation for integrators. No dependencies; the bank table is ../saudi_banks.json and the messages ../messages.json.

    >>> r = validate("SA03 8000 0000 6080 1016 7519")
    >>> r.valid, r.bank["name_en"], r.formatted
    (True, 'Al Rajhi Bank', 'SA03 8000 0000 6080 1016 7519')
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
BANKS: dict[str, dict] = {b["code"]: b for b in json.loads((_ROOT / "saudi_banks.json").read_text("utf-8"))["banks"]}
MESSAGES: dict = json.loads((_ROOT / "messages.json").read_text("utf-8"))

LENGTH = 24
_SEPARATORS = re.compile(r"[\s\u00a0\u200f\u200e\-]")      # spaces, no-break space, RTL/LTR marks, hyphens
_ARABIC_DIGITS = {base + i: str(i) for base in (0x0660, 0x06F0) for i in range(10)}   # Arabic-Indic, Persian
_FORMAT = re.compile(r"^SA[0-9]{2}[0-9]{2}[0-9A-Z]{18}$")   # SWIFT IBAN Registry: SA2!n2!n18!c


@dataclass
class Result:
    valid: bool
    error: str | None = None            # first failed rule; message(error) gives its text
    iban: str = ""                      # normalised, electronic form
    formatted: str = ""                 # print form, groups of four
    bank_code: str | None = None
    bank: dict | None = None
    warnings: list[str] = field(default_factory=list)


def message(code: str, lang: str = "ar") -> str:
    """The user-facing text for an error or warning code, in "ar" or "en"."""
    return (MESSAGES["errors"].get(code) or MESSAGES["warnings"][code])[lang]


def normalise(value: str) -> str:
    """Electronic form: no separators, upper case, Arabic-Indic digits as ASCII, an optional leading 'IBAN' dropped."""
    iban = _SEPARATORS.sub("", value or "").translate(_ARABIC_DIGITS).upper()
    return iban.removeprefix("IBAN")


def mod97(iban: str) -> int:
    """Remainder of the rearranged IBAN modulo 97, one character at a time so no big integers are needed."""
    remainder = 0
    for ch in iban[4:] + iban[:4]:
        value = int(ch, 36)                         # '0'..'9' -> 0..9, 'A'..'Z' -> 10..35
        remainder = (remainder * (100 if value > 9 else 10) + value) % 97
    return remainder


def check_digits(bank_code: str, account: str) -> str:
    """The two check digits for a bank code and an 18-character account part."""
    return f"{98 - mod97('SA00' + bank_code + account):02d}"


def validate(value: str, *, strict_bank: bool = True) -> Result:
    """Checks, in order: characters, country, length, format, check-digit range, MOD-97, bank code.

    With strict_bank=False an unregistered bank code is a warning instead of an error, so a bank SAMA licenses after
    saudi_banks.json was last updated is not refused.
    """
    iban = normalise(value)
    if not iban:
        return Result(False, "EMPTY")
    if not re.fullmatch(r"[0-9A-Z]+", iban):
        return Result(False, "INVALID_CHARACTERS", iban)
    if not iban.startswith("SA"):
        return Result(False, "COUNTRY_NOT_SA", iban)
    if len(iban) != LENGTH:
        return Result(False, "WRONG_LENGTH", iban)
    if not _FORMAT.match(iban):
        return Result(False, "INVALID_FORMAT", iban)
    formatted = " ".join(iban[i:i + 4] for i in range(0, LENGTH, 4))
    code = iban[4:6]
    bank = BANKS.get(code)
    if iban[2:4] in ("00", "01", "99"):
        return Result(False, "INVALID_CHECK_DIGITS", iban, formatted, code, bank)
    if mod97(iban) != 1:
        return Result(False, "CHECKSUM_FAILED", iban, formatted, code, bank)
    if bank is None:
        if strict_bank:
            return Result(False, "UNKNOWN_BANK", iban, formatted, code)
        return Result(True, None, iban, formatted, code, None, ["UNKNOWN_BANK"])
    warnings = ["LEGACY_BANK"] if bank["status"] == "legacy_merged" else []
    return Result(True, None, iban, formatted, code, bank, warnings)
