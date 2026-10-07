"""Delivery channels. Each provider sends one message and raises on failure; the worker retries.

    MASSLAK_NOTIFY_EMAIL = log | smtp       MASSLAK_SMTP_URL = smtp://user:password@host:587  (STARTTLS)
    MASSLAK_NOTIFY_SMS   = log | http       MASSLAK_SMS_URL = https://gateway/send, MASSLAK_SMS_TOKEN = <bearer>

The log provider writes each message as one JSON line under data/messages/, for development and tests.
"""
import json
import os
import ssl
import urllib.request
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path
from urllib.parse import urlparse

from ... import egress
from ...config import get_settings


def _log(channel: str, to: str, subject: str, body: str, attachments: tuple = ()) -> None:
    folder = Path(get_settings().files_dir).resolve().parent / "messages"
    folder.mkdir(parents=True, exist_ok=True)
    files = []
    for name, _mime, data in attachments:          # kept next to the log so a developer can open what was sent
        (folder / "attachments").mkdir(exist_ok=True)
        (folder / "attachments" / Path(name).name).write_bytes(data)
        files.append({"name": Path(name).name, "bytes": len(data)})
    with open(folder / f"{channel.lower()}.jsonl", "a", encoding="utf-8") as f:
        f.write(json.dumps({"at": datetime.now(timezone.utc).isoformat(), "to": to, "subject": subject, "body": body,
                            **({"attachments": files} if files else {})}, ensure_ascii=False) + "\n")


def send_email(to: str, subject: str, body: str, attachments: tuple = ()) -> None:
    """attachments: (filename, mime type, bytes) tuples, e.g. a scheduled report."""
    if os.environ.get("MASSLAK_NOTIFY_EMAIL", "log") != "smtp":
        return _log("EMAIL", to, subject, body, attachments)
    url = urlparse(os.environ["MASSLAK_SMTP_URL"])
    msg = EmailMessage()
    msg["From"] = os.environ.get("MASSLAK_MAIL_FROM", "Masslak <no-reply@masslak.com>")
    msg["To"], msg["Subject"] = to, subject
    msg.set_content(body)
    for name, mime, data in attachments:
        main, _, sub = mime.split(";")[0].partition("/")
        msg.add_attachment(data, maintype=main, subtype=sub or "octet-stream", filename=name)
    with egress.SMTP(url.hostname, url.port or 587, timeout=15) as s:     # through the egress proxy (T3-02)
        s.starttls(context=ssl.create_default_context())
        if url.username:
            s.login(url.username, url.password or "")
        s.send_message(msg)


def send_sms(to: str, body: str) -> None:
    if os.environ.get("MASSLAK_NOTIFY_SMS", "log") != "http":
        return _log("SMS", to, "", body)
    url = os.environ["MASSLAK_SMS_URL"]
    if not url.startswith("https://"):
        raise RuntimeError("the SMS gateway must use HTTPS")
    req = urllib.request.Request(url, data=json.dumps({"to": to, "text": body}).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {os.environ['MASSLAK_SMS_TOKEN']}"}, method="POST")
    # The scheme is checked to be https above, so file:// and custom schemes can never be opened
    with egress.urlopen(req, timeout=15) as r:  # nosec B310
        if r.status >= 300:
            raise RuntimeError(f"SMS gateway answered {r.status}")
