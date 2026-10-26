"""A person's name in parts and the sign-up form (owner's requests N4 and N35, migration 1149): the nationality decides
the parts required, the e-mail and the password are typed twice, the e-mail is confirmed by a code, and an account made
with one name only is asked for the parts at the next sign-in."""
import json
import uuid
from pathlib import Path

import pytest

from app.config import get_settings
from test_e2e import OWNER_URL, client, owner_sql

pytestmark = pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL")
PASSWORD = "another-long-password"


def email_code(to: str) -> str:
    path = Path(get_settings().files_dir).resolve().parent / "messages" / "email.jsonl"
    lines = [json.loads(x) for x in path.read_text(encoding="utf-8").splitlines()] if path.exists() else []
    body = next(m["body"] for m in reversed(lines) if m["to"] == to)
    return next(w.strip(".,") for w in body.split() if w.strip(".,").isdigit() and len(w.strip(".,")) == 6)


def register(c, email, **extra):
    body = {"email": email, "email_confirm": email, "password": PASSWORD, "password_confirm": PASSWORD, **extra}
    return c.post("/api/auth/register", json=body)


def signed_in(email):
    c = client()
    assert c.post("/api/auth/login", json={"identifier": email, "password": PASSWORD, "portal": "PASSENGER"}).status_code == 200
    return c


def test_the_nationality_decides_the_name_parts_and_the_confirmations_must_match():
    c = client()
    email = f"n{uuid.uuid4().hex[:8]}@example.com"
    r = register(c, email, name={"nationality": "SY", "first_name": "\u0633\u0627\u0645\u0631", "last_name": "\u0627\u0644\u062e\u0637\u064a\u0628"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "NAME_PARTS_REQUIRED" and r.json()["error"]["missing"] == ["father"]
    r = register(c, email, name={"nationality": "DE", "first_name": "Anna", "last_name": "Schmidt"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "LATIN_NAME_REQUIRED"
    r = register(c, email, name={"nationality": "SY", "first_name": "\u0633\u0627\u0645\u0631", "father_name": "\u0645\u062d\u0645\u062f", "last_name": "\u0627\u0644\u062e\u0637\u064a\u0628"},
                 email_confirm=f"x{email}")
    assert r.status_code == 422 and r.json()["error"]["code"] == "EMAIL_MISMATCH"
    r = register(c, email, name={"nationality": "SY", "first_name": "\u0633\u0627\u0645\u0631", "father_name": "\u0645\u062d\u0645\u062f", "last_name": "\u0627\u0644\u062e\u0637\u064a\u0628"},
                 password_confirm=PASSWORD + "x")
    assert r.status_code == 422 and r.json()["error"]["code"] == "PASSWORD_MISMATCH"
    r = register(c, email, name={"nationality": "SY", "first_name": "\u0633\u0627\u0645\u0631", "father_name": "\u0645\u062d\u0645\u062f", "last_name": "\u0627\u0644\u062e\u0637\u064a\u0628",
                                 "first_name_latin": "Samer", "last_name_latin": "Al-Khatib"})
    assert r.status_code == 201, r.text
    row = owner_sql("""SELECT p.legal_name, p.name_latin, p.names_complete, p.verification_status, u.email_verified_at
                         FROM iam.app_user u JOIN iam.party p ON p.id = u.party_id WHERE u.email = $1""", email, fetch=True)
    assert row["legal_name"] == "\u0633\u0627\u0645\u0631 \u0645\u062d\u0645\u062f \u0627\u0644\u062e\u0637\u064a\u0628" and row["name_latin"] == "Samer Al-Khatib" and row["names_complete"]
    assert row["verification_status"] == "UNVERIFIED" and row["email_verified_at"] is None


def test_the_email_is_confirmed_by_a_code_sent_to_it():
    c = client()
    email = f"v{uuid.uuid4().hex[:8]}@example.com"
    r = register(c, email, name={"nationality": "SY", "first_name": "Lina", "father_name": "Omar", "last_name": "Haddad"})
    assert r.status_code == 201 and r.json()["email_code_sent"] is True
    me = signed_in(email)
    assert me.get("/api/auth/me").json()["email_verified"] is False
    code = email_code(email)
    wrong = f"{(int(code) + 1) % 1_000_000:06d}"
    assert me.post("/api/account/email/verify", json={"code": wrong}).json()["error"]["code"] == "CODE_WRONG"
    assert me.post("/api/account/email/verify", json={"code": code}).status_code == 200
    assert me.get("/api/auth/me").json()["email_verified"] is True
    assert me.post("/api/account/email/verify", json={"code": code}).status_code == 422          # used once


def test_an_account_with_one_name_is_asked_for_the_parts():
    c = client()
    email = f"o{uuid.uuid4().hex[:8]}@example.com"
    assert register(c, email, full_name="Test User").status_code == 201        # an older app sends one name
    me = signed_in(email)
    assert me.get("/api/auth/me").json()["names_complete"] is False
    profile = me.get("/api/account/profile").json()
    assert profile["name"]["first_name"] is None and profile["rules"]["SY"]["required"] == ["first", "father", "last"]
    r = me.put("/api/account/names", json={"nationality": "SY", "first_name": "Test"})
    assert r.status_code == 422 and r.json()["error"]["code"] == "NAME_PARTS_REQUIRED"
    r = me.put("/api/account/names", json={"nationality": "SY", "first_name": "Test", "father_name": "Ahmad", "last_name": "User",
                                           "mother_name": "Huda"})
    assert r.status_code == 200 and r.json()["name"] == "Test Ahmad User"
    assert me.get("/api/auth/me").json()["names_complete"] is True
    # once the identity is verified, the name follows the document reviewed
    owner_sql("UPDATE iam.party SET verification_status = 'VERIFIED' WHERE id = (SELECT party_id FROM iam.app_user WHERE email = $1)", email)
    r = me.put("/api/account/names", json={"nationality": "SY", "first_name": "Other", "father_name": "Ahmad", "last_name": "User"})
    assert r.status_code == 409 and r.json()["error"]["code"] == "NAME_LOCKED"
