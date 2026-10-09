"""Personal data and secrets kept out of the server logs (code review of October 2026).

Log lines come from many places: the API's own messages, database errors quoted as they are ("Key (email)=(...)
already exists"), uvicorn's access lines with query strings. Every record is redacted when it is created, whoever
logs it: e-mail addresses, phone numbers, long digit runs (identity, card and account numbers), bearer tokens and
the values of secret-looking query parameters. Client addresses stay, because security needs them.
"""
from __future__ import annotations

import logging
import re

_PATTERNS = [
    (re.compile(r"(?i)\bbearer\s+[a-z0-9._~+/=-]{8,}"), "Bearer [redacted]"),
    (re.compile(r"(?i)\b(token|password|passwd|secret|code|otp|key|signature)=([^&\s\"']+)"), r"\1=[redacted]"),
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"), "[email]"),
    (re.compile(r"(?<![\d.])\+?\d[\d -]{8,22}\d(?![\d.])"), "[number]"),    # 10+ digits: 09XXXXXXXX and longer
]
# record ids (request, ticket, booking) and dates stay readable: they identify records and moments, not people
_KEEP = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"
                   r"|\b\d{4}-\d{2}-\d{2}(?=\b|T)")


def redact(text: str) -> str:
    kept = _KEEP.findall(text)
    text = _KEEP.sub("\x00", text)
    for pattern, replacement in _PATTERNS:
        text = pattern.sub(replacement, text)
    for value in kept:
        text = text.replace("\x00", value, 1)
    return text


def _clean(value):
    return redact(value) if isinstance(value, str) else value


def install() -> None:
    """Redacts every log record at creation. Arguments keep their shape (uvicorn's access formatter reads them as a
    tuple), only their text is replaced."""
    previous = logging.getLogRecordFactory()
    if getattr(previous, "masslak_redacting", False):
        return

    def factory(*args, **kwargs):
        record = previous(*args, **kwargs)
        if isinstance(record.msg, str):
            record.msg = redact(record.msg)
        if isinstance(record.args, tuple):
            record.args = tuple(_clean(a) for a in record.args)
        elif isinstance(record.args, dict):
            record.args = {k: _clean(v) for k, v in record.args.items()}
        return record
    factory.masslak_redacting = True
    logging.setLogRecordFactory(factory)
