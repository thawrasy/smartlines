"""Unit tests for field encryption and blind indexes (no server needed)."""
import os

import pytest
from cryptography.exceptions import InvalidTag

from app.crypto import FieldCipher, last4, normalise_identifier

KEY = os.urandom(32)


def make(active=True):
    return FieldCipher({7: KEY}, {"kms://masslak/field/restricted/v1": 7} if active else {}, os.urandom(32))


def test_round_trip_and_random_nonce():
    fc = make()
    a = fc.encrypt("01020304050", "sales.passenger.id_no")
    b = fc.encrypt("01020304050", "sales.passenger.id_no")
    assert a.key_id == 7 and a.ciphertext != b.ciphertext
    assert b"01020304050" not in a.ciphertext
    assert fc.decrypt(a.ciphertext, 7, "sales.passenger.id_no") == "01020304050"


def test_ciphertext_is_bound_to_its_column():
    fc = make()
    s = fc.encrypt("N1234567", "sales.passenger.id_no")
    with pytest.raises(InvalidTag):
        fc.decrypt(s.ciphertext, 7, "iam.party.id_no")


def test_tampering_is_detected():
    fc = make()
    s = bytearray(fc.encrypt("N1234567", "sales.passenger.id_no").ciphertext)
    s[-1] ^= 1
    with pytest.raises(InvalidTag):
        fc.decrypt(bytes(s), 7, "sales.passenger.id_no")


def test_blind_index_matches_the_same_document_only():
    fc = make()
    assert fc.blind_index("010-203 040", "NATIONAL_ID:SY") == fc.blind_index("010203040", "NATIONAL_ID:SY")
    assert fc.blind_index("010203040", "NATIONAL_ID:SY") != fc.blind_index("010203040", "PASSPORT:SY")
    assert fc.blind_index("010203040", "NATIONAL_ID:SY") != fc.blind_index("010203041", "NATIONAL_ID:SY")


def test_normalising_and_masking():
    assert normalise_identifier("n 12-34/56") == "N123456"
    # Arabic-Indic digits zero to three (U+0660..U+0663), as typed on an Arabic keyboard
    assert normalise_identifier("\u0660\u0661\u0662\u0663") == "0123"
    assert last4("N 1234-5678") == "5678"


def test_no_active_key_refuses_to_encrypt():
    with pytest.raises(Exception):
        make(active=False).encrypt("x", "sales.passenger.id_no")
