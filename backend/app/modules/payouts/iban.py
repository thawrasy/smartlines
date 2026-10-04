"""IBAN checks (ISO 13616): format and the mod-97 check digits, so a typing error never reaches a bank transfer."""
import re

_FORMAT = re.compile(r"^[A-Z]{2}[0-9]{2}[A-Z0-9]{11,30}$")


def normalise(value: str) -> str:
    return re.sub(r"[\s-]", "", value).upper()


def valid(value: str) -> bool:
    iban = normalise(value)
    if not _FORMAT.match(iban):
        return False
    rearranged = iban[4:] + iban[:4]
    digits = "".join(str(int(ch, 36)) for ch in rearranged)
    return int(digits) % 97 == 1
