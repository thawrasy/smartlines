"""Step-up authentication (evaluation reports of October 2026, GP; schema file 1136): before an operation that moves money
out, widens access or takes data out, someone who uses a second factor must have passed it on this session within the
last auth.mfa.step_up_minutes, or confirm with a fresh code at POST /api/auth/mfa/step-up."""
import re
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from app import mfa
from app.deps import Principal, require_step_up
from app.errors import ApiError
from test_account import register, sign_in
from test_e2e import OWNER_URL, owner_sql

APP = Path(__file__).resolve().parents[1] / "app"
# every operation the owner listed: money out, wider access, data out, API keys
SENSITIVE = {
    "modules/payouts/api.py": ['@company.post("/bank-accounts"', '@company.post("/withdrawals"',
                               '@platform.post("/bank-accounts/{account_uid}/verify"', '@platform.post("/withdrawals/{withdrawal_uid}/approve"',
                               '@platform.post("/withdrawals/{withdrawal_uid}/paid"', '@platform.post("/settlements/{batch_uid}/approve"'],
    "modules/loyalty/admin.py": ['@router.post("/settlements/{settlement}/pay"'],
    "modules/agency/api.py": ['@router.post("/staff"'],
    "routers/carrier.py": ['@router.post("/crew"'],
    "routers/admin.py": ['@router.post("/external-access"'],
    "modules/schedules/api.py": ['@platform.post("/authorities/{code}/members"'],
    "routers/security.py": ['@router.put("/mfa-policy"'],
    "modules/reports/api.py": ['@router.post("/export"'],
    "modules/account/api.py": ['@router.get("/export"'],
    "modules/manifests/api.py": ['@carrier.get("/manifests/{uid}/export"'],
    "modules/integration/console.py": ['@router.post("/clients"', '@router.post("/clients/{uid}/keys"', '@router.post("/clients/{uid}/webhooks"'],
}


def _principal(required: bool, minutes_ago: float | None) -> Principal:
    at = None if minutes_ago is None else datetime.now(timezone.utc) - timedelta(minutes=minutes_ago)
    return Principal(user_id=1, user_uid="u", party_id=1, session_id=1, portal="OPERATOR", company_id=1, display_name="x",
                     email=None, locale="en", mfa_required=required, mfa_at=at, step_up_minutes=10)


def test_the_rule():
    require_step_up(_principal(True, 2))                       # passed two minutes ago
    require_step_up(_principal(False, None))                   # no second factor in use (a passenger, a sandbox)
    for stale in (11, None):
        with pytest.raises(ApiError) as e:
            require_step_up(_principal(True, stale))
        assert e.value.code == "STEP_UP_REQUIRED" and e.value.status == 403


def test_every_sensitive_operation_asks_for_it():
    for rel, routes in SENSITIVE.items():
        src = (APP / rel).read_text(encoding="utf-8")
        for route in routes:
            m = re.search(r"^" + re.escape(route) + r"[,)].*?\n(?=@|\Z)", src, re.S | re.M)
            assert m, (rel, route)
            assert "require_step_up(" in m.group(), f"{rel} {route} does not ask for a recent second factor"


@pytest.mark.skipif(not OWNER_URL, reason="needs MASSLAK_OWNER_URL to age the session")
def test_an_old_second_factor_is_confirmed_again_before_an_export():
    email, password = register()
    c, _ = sign_in(email, password)
    secret = c.post("/api/auth/mfa/enroll").json()["secret"]
    step = mfa.current_step()
    assert c.post("/api/auth/mfa/confirm", json={"code": mfa.code_at(secret, step)}).status_code == 200
    assert c.get("/api/account/export").status_code == 200       # the factor was just passed on this session

    owner_sql("""UPDATE iam.user_session SET mfa_at = now() - interval '11 minutes'
                  WHERE user_id = (SELECT id FROM iam.app_user WHERE email = $1) AND revoked_at IS NULL""", email)
    r = c.get("/api/account/export")
    assert r.status_code == 403 and r.json()["error"]["code"] == "STEP_UP_REQUIRED", r.text
    assert r.json()["error"]["next"] == "STEP_UP"

    wrong = c.post("/api/auth/mfa/step-up", json={"code": "000000"})
    assert wrong.status_code == 422 and wrong.json()["error"]["attempts_left"] == 4
    ok = c.post("/api/auth/mfa/step-up", json={"code": mfa.code_at(secret, step + 1)})
    assert ok.status_code == 200 and ok.json()["valid_minutes"] == 10, ok.text
    assert c.get("/api/account/export").status_code == 200
    events = owner_sql("""SELECT count(*) FROM audit.auth_event e JOIN iam.app_user u ON u.id = e.user_id
                           WHERE u.email = $1 AND e.reason LIKE 'step_up%'""", email)
    assert events == 2                                           # the wrong code and the right one
