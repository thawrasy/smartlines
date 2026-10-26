"""Second-factor channels (owner's request N36, migration 1151): codes by e-mail or by Telegram besides the authenticator
app and the recovery codes. WhatsApp is open at launch (1152); text messages stay closed until a provider is contracted."""
import re
import uuid

import pytest

from test_account import register, sign_in
from test_e2e import OWNER_URL, client, owner_sql
from test_notifications import logged

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
SECRET = {"X-Telegram-Bot-Api-Secret-Token": "sandbox-telegram-secret"}


def code_in(body: str) -> str:
    return re.search(r"(?<!\d)(\d{6})(?!\d)", body).group(1)


def mailed_codes(to: str) -> list[str]:
    return [code_in(m["body"]) for m in logged("email") if m["to"] == to and m["subject"] == "Masslak sign-in code"]


def telegram_codes(chat: str) -> list[str]:
    return [code_in(m["body"]) for m in logged("telegram") if m["to"] == chat]


def age_codes(email: str) -> None:
    """The next code may be asked for only after auth.mfa.resend_seconds: the codes already sent are made older."""
    owner_sql("""UPDATE iam.mfa_challenge SET created_at = created_at - interval '2 minutes',
                        expires_at = expires_at - interval '2 minutes'
                  WHERE user_id = (SELECT id FROM iam.app_user WHERE email = $1)""", email)


def test_the_policy_opens_email_telegram_and_whatsapp_and_keeps_text_messages_closed():
    email, password = register()
    c, _ = sign_in(email, password)
    methods = c.get("/api/auth/mfa/methods").json()
    assert {"TOTP", "EMAIL", "TELEGRAM", "WHATSAPP"} <= set(methods["available"])
    assert "SMS" not in methods["available"]
    assert methods["telegram_bot"] and methods["account_email"].endswith("@example.com")
    closed = c.post("/api/auth/mfa/enroll", json={"method": "SMS", "mobile": "+963912345678"})
    assert closed.status_code == 409 and closed.json()["error"]["code"] == "MFA_METHOD_OFF"


def test_codes_by_email_enrol_and_sign_in():
    email, password = register()
    c, _ = sign_in(email, password)
    r = c.post("/api/auth/mfa/enroll", json={"method": "EMAIL"})                 # the account's own address
    assert r.status_code == 200 and r.json()["sent_to"].startswith(email[0]) and "@example.com" in r.json()["sent_to"]
    done = c.post("/api/auth/mfa/confirm", json={"code": mailed_codes(email)[-1], "method": "EMAIL"})
    assert done.status_code == 200 and len(done.json()["recovery_codes"]) == 10
    stored = owner_sql("""SELECT secret_enc FROM iam.mfa_factor f JOIN iam.app_user u ON u.id = f.user_id
                           WHERE u.email = $1 AND f.factor_type = 'EMAIL' AND f.verified_at IS NOT NULL""", email)
    assert email.encode() not in bytes(stored)                                    # the address is kept encrypted

    age_codes(email)
    d, r = sign_in(email, password)
    assert r.json()["mfa"] == "VERIFY" and r.json()["mfa_methods"] == ["EMAIL"]
    assert d.get("/api/bookings").json()["error"]["code"] == "MFA_REQUIRED"
    assert d.post("/api/auth/mfa/send", json={"method": "EMAIL"}).status_code == 200
    code = mailed_codes(email)[-1]
    assert d.post("/api/auth/mfa/verify", json={"code": code, "method": "EMAIL"}).json()["method"] == "email"
    assert d.get("/api/bookings").status_code == 200


def test_a_telegram_chat_is_linked_by_a_one_time_link():
    email, password = register()
    c, _ = sign_in(email, password)
    r = c.post("/api/auth/mfa/enroll", json={"method": "TELEGRAM"})
    assert r.status_code == 200, r.text
    link = r.json()["link"]
    assert link.startswith("https://t.me/") and "?start=" in link
    token = link.split("?start=", 1)[1]
    chat = str(100_000_000 + uuid.uuid4().int % 800_000_000)
    update = {"message": {"text": f"/start {token}", "chat": {"id": int(chat)}}}

    # only the platform's bot may call the webhook
    assert client().post("/api/auth/telegram/webhook", json=update).status_code == 403
    assert client().post("/api/auth/telegram/webhook", json=update,
                         headers={"X-Telegram-Bot-Api-Secret-Token": "guess"}).status_code == 403
    assert client().post("/api/auth/telegram/webhook", json=update, headers=SECRET).status_code == 200
    code = telegram_codes(chat)[-1]
    # the link works once: another chat sending the same token gets nothing
    other = str(int(chat) + 1)
    assert client().post("/api/auth/telegram/webhook", headers=SECRET,
                         json={"message": {"text": f"/start {token}", "chat": {"id": int(other)}}}).status_code == 200
    assert telegram_codes(other) == []

    done = c.post("/api/auth/mfa/confirm", json={"code": code, "method": "TELEGRAM"})
    assert done.status_code == 200, done.text
    methods = c.get("/api/auth/mfa/methods").json()
    assert methods["enrolled"] == ["TELEGRAM"] and methods["sent_to"]["TELEGRAM"] == "Telegram"

    age_codes(email)
    d, r = sign_in(email, password)
    assert r.json()["mfa"] == "VERIFY" and r.json()["mfa_methods"] == ["TELEGRAM"]
    assert d.post("/api/auth/mfa/send", json={"method": "TELEGRAM"}).status_code == 200
    assert d.post("/api/auth/mfa/verify", json={"code": telegram_codes(chat)[-1], "method": "TELEGRAM"}).json()["method"] == "telegram"


def test_an_expired_telegram_link_links_nothing():
    email, password = register()
    c, _ = sign_in(email, password)
    token = c.post("/api/auth/mfa/enroll", json={"method": "TELEGRAM"}).json()["link"].split("?start=", 1)[1]
    owner_sql("""UPDATE iam.messenger_link SET created_at = created_at - interval '20 minutes',
                        expires_at = expires_at - interval '20 minutes'
                  WHERE user_id = (SELECT id FROM iam.app_user WHERE email = $1)""", email)
    chat = str(100_000_000 + uuid.uuid4().int % 800_000_000)
    assert client().post("/api/auth/telegram/webhook", headers=SECRET,
                         json={"message": {"text": f"/start {token}", "chat": {"id": int(chat)}}}).status_code == 200
    assert telegram_codes(chat) == []
    assert c.post("/api/auth/mfa/send", json={"method": "TELEGRAM"}).json()["error"]["code"] == "MFA_METHOD_NOT_ENROLLED"
