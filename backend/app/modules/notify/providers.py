"""Delivery channels. Each provider sends one message and raises on failure; the worker retries.

    MASSLAK_NOTIFY_EMAIL = off | log | smtp   MASSLAK_SMTP_URL = smtp://user:password@host:587  (STARTTLS)
    MASSLAK_NOTIFY_SMS   = off | log | http   MASSLAK_SMS_URL = https://gateway/send, MASSLAK_SMS_TOKEN = <bearer>
    MASSLAK_NOTIFY_WHATSAPP = off | log | cloud
        MASSLAK_WHATSAPP_URL = https://graph.facebook.com/<version>/<phone number id>/messages
        MASSLAK_WHATSAPP_TOKEN = <bearer>, MASSLAK_WHATSAPP_TEMPLATE = <approved authentication template>
        (sign-in codes only: WhatsApp sends a code through a template the business account had approved)

The log provider writes each message, address and text included, as one JSON line under data/messages/: for the
sandbox only. Outside it the API and the worker refuse to start with it (review of 1.47.0, R-27), and a channel left
unset is off: nothing is sent or kept on it until real delivery is configured.
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


class NotifyConfigError(RuntimeError):
    pass


class ChannelOff(RuntimeError):
    """The channel has no delivery configured on this server."""


_REAL = {"EMAIL": "smtp", "SMS": "http", "WHATSAPP": "cloud"}


def mode(channel: str) -> str:
    value = os.environ.get(f"MASSLAK_NOTIFY_{channel}", "").strip().lower()
    return value or ("log" if get_settings().sandbox else "off")


def enabled(channel: str) -> bool:
    return mode(channel) != "off"


def require_in_production() -> None:
    """Outside the sandbox: no channel writes personal data to plain files, and every value is one we know."""
    for channel, real in _REAL.items():
        m = mode(channel)
        if m not in ("off", "log", real):
            raise NotifyConfigError(f"MASSLAK_NOTIFY_{channel}={m} is not one of off, log, {real}")
        if m == "log" and not get_settings().sandbox:
            raise NotifyConfigError(f"MASSLAK_NOTIFY_{channel}=log keeps addresses and message texts in plain files and "
                                    f"is for the sandbox only; set {real} (real delivery) or off")


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
    m = mode("EMAIL")
    if m == "off":
        raise ChannelOff("e-mail delivery is off on this server (MASSLAK_NOTIFY_EMAIL)")
    if m == "log":
        require_in_production()
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
    m = mode("SMS")
    if m == "off":
        raise ChannelOff("SMS delivery is off on this server (MASSLAK_NOTIFY_SMS)")
    if m == "log":
        require_in_production()
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


def send_whatsapp_code(to: str, code: str, locale: str, text: str) -> None:
    """A one-time sign-in code by WhatsApp (owner's decision 2). The Cloud API sends it through an approved
    authentication template whose body takes the code; text is what the log provider records in the sandbox."""
    m = mode("WHATSAPP")
    if m == "off":
        raise ChannelOff("WhatsApp delivery is off on this server (MASSLAK_NOTIFY_WHATSAPP)")
    if m == "log":
        require_in_production()
        return _log("WHATSAPP", to, "", text)
    url = os.environ["MASSLAK_WHATSAPP_URL"]
    if not url.startswith("https://"):
        raise RuntimeError("the WhatsApp endpoint must use HTTPS")
    template = {"name": os.environ.get("MASSLAK_WHATSAPP_TEMPLATE", "masslak_sign_in_code"), "language": {"code": locale},
                "components": [{"type": "body", "parameters": [{"type": "text", "text": code}]},
                               {"type": "button", "sub_type": "url", "index": "0",
                                "parameters": [{"type": "text", "text": code}]}]}
    payload = {"messaging_product": "whatsapp", "to": to.lstrip("+"), "type": "template", "template": template}
    req = urllib.request.Request(url, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json",
                                          "Authorization": f"Bearer {os.environ['MASSLAK_WHATSAPP_TOKEN']}"}, method="POST")
    with egress.urlopen(req, timeout=15) as r:  # nosec B310 - https only, checked above
        if r.status >= 300:
            raise RuntimeError(f"WhatsApp answered {r.status}")
