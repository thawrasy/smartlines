"""The vehicle movement code (1169, N48) without a server: its shape fits the smallest QR symbol, it is forgiven when
read by hand, it depends on the key and the serial, and a placard printed before a key change still matches."""
import base64
import os

from app import security
from app.security import vehicle_code_shape, vehicle_code_token, vehicle_code_tokens

VEHICLE = "2b1f8f9e-6a3c-4d4e-9f0a-1c2d3e4f5a6b"


def test_the_code_is_short_and_in_the_qr_capital_letters_alphabet():
    code = vehicle_code_token(VEHICLE, 1, b"k" * 32)
    assert len(code) == 16 and code.startswith("MS1")
    # 16 characters of the alphanumeric mode fit version 1 at level M (20 characters), the 21 x 21 symbol
    assert set(code) <= set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:")
    assert vehicle_code_shape(code) == code


def test_a_code_typed_by_hand_is_forgiven_and_anything_else_is_not_a_code():
    code = vehicle_code_token(VEHICLE, 1, b"k" * 32)
    assert vehicle_code_shape(f"  {code[:8].lower()} {code[8:]} ") == code
    for bad in ("", code[:-1], code + "A", "MS2" + code[3:], code[:-1] + "1", "Q1.s1.x.y.z"):
        assert vehicle_code_shape(bad) is None


def test_the_code_depends_on_the_key_the_vehicle_and_the_serial():
    a = vehicle_code_token(VEHICLE, 1, b"k" * 32)
    assert a == vehicle_code_token(VEHICLE, 1, b"k" * 32)
    assert a != vehicle_code_token(VEHICLE, 2, b"k" * 32)                  # a new placard after a revoke
    assert a != vehicle_code_token(VEHICLE.replace("2b", "3b"), 1, b"k" * 32)
    assert a != vehicle_code_token(VEHICLE, 1, b"j" * 32)


def test_a_placard_printed_before_a_key_change_still_matches(monkeypatch):
    old, new = base64.b64encode(b"o" * 32).decode(), base64.b64encode(b"n" * 32).decode()
    monkeypatch.setitem(os.environ, "MASSLAK_QR_KEYS", f"k2:{new},k1:{old}")
    security.token_keys.cache_clear()
    try:
        codes = vehicle_code_tokens(VEHICLE, 1)
        assert codes == [vehicle_code_token(VEHICLE, 1, b"n" * 32), vehicle_code_token(VEHICLE, 1, b"o" * 32)]
        assert vehicle_code_token(VEHICLE, 1) == codes[0]                   # new placards use the current key
    finally:
        security.token_keys.cache_clear()
