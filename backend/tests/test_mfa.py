"""Unit tests for TOTP (RFC 6238 reference values) and recovery codes."""
import base64

from app import mfa

RFC_SECRET = base64.b32encode(b"12345678901234567890").decode()


def test_rfc6238_reference_values():
    # RFC 6238 appendix B (SHA-1), last six digits of the eight-digit values
    assert mfa.code_at(RFC_SECRET, 59 // 30) == "287082"
    assert mfa.code_at(RFC_SECRET, 1111111109 // 30) == "081804"
    assert mfa.code_at(RFC_SECRET, 1234567890 // 30) == "005924"


def test_verify_accepts_drift_and_refuses_replay():
    now = 1_700_000_000
    step = mfa.current_step(now)
    code = mfa.code_at(RFC_SECRET, step)
    assert mfa.verify(RFC_SECRET, code, None, now=now) == step
    assert mfa.verify(RFC_SECRET, code, step, now=now) is None              # replay
    assert mfa.verify(RFC_SECRET, mfa.code_at(RFC_SECRET, step - 1), None, now=now) == step - 1
    assert mfa.verify(RFC_SECRET, mfa.code_at(RFC_SECRET, step - 3), None, now=now) is None
    assert mfa.verify(RFC_SECRET, "12345", None, now=now) is None


def test_provisioning_uri_and_recovery_codes():
    uri = mfa.provisioning_uri("ABC", "ops@carrier.sy")
    assert uri.startswith("otpauth://totp/Masslak%3Aops%40carrier.sy?secret=ABC&issuer=Masslak")
    codes = mfa.new_recovery_codes()
    assert len(codes) == 10 and len(set(codes)) == 10 and all(len(c) == 9 and c[4] == "-" for c in codes)
    assert mfa.hash_recovery_code(codes[0].lower()) == mfa.hash_recovery_code(codes[0].replace("-", ""))
