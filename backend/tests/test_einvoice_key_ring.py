"""The e-invoice signing key ring (owner's decision 4, 1108), read in the process without a server: the configured list
keeps its order and the first key signs, a bare "e1" is the key of release 1.49.0, every key verifies what it signed,
and a malformed list stops the start rather than signing with a wrong key. The end-to-end tests run the server with no
list (the key of release 1.49.0), so the parsing of a configured ring is tested here."""
import base64

import pytest

from app import security as s


def _seed(fill: str) -> str:
    """base64 of a 32-byte Ed25519 seed made of a repeated pattern."""
    return base64.b64encode((fill * 32).encode()[:32]).decode()


def test_the_first_key_of_the_ring_signs_and_every_key_verifies_what_it_signed():
    keys = s.parse_einvoice_keys(f"k2:{_seed('ab')}, k1:{_seed('cd')}, e1")
    assert [kid for kid, _ in keys] == ["k2", "k1", "e1"]
    digest = b"d" * 32
    for _, key in keys:
        public = s._public_b64(key)
        assert s.einvoice_signature_valid(digest, key.sign(digest), public)
        assert not s.einvoice_signature_valid(digest, key.sign(b"another document"), public)
    # a document that names no public key is checked with the key of release 1.49.0, the bare "e1"
    assert s.einvoice_signature_valid(digest, dict(keys)["e1"].sign(digest))
    assert not s.einvoice_signature_valid(digest, dict(keys)["k2"].sign(digest))
    # no list at all: that key alone
    assert [kid for kid, _ in s.parse_einvoice_keys("  ")] == ["e1"]


@pytest.mark.parametrize("raw, message", [
    (f"K2:{_seed('ab')}", "key id"),
    (f"k2:{_seed('ab')},k2:{_seed('cd')}", "listed twice"),
    ("k2:c2hvcnQ=", "32-byte"),
    ("k2:not base64!", "32-byte"),
    ("k2", "32-byte"),
])
def test_a_malformed_ring_stops_the_start(raw, message):
    with pytest.raises(s.KeyConfigError, match=message):
        s.parse_einvoice_keys(raw)
