"""Client address resolution behind proxies (no server or database needed)."""
from types import SimpleNamespace

from app.middleware import client_ip


def req(peer, xff=None):
    return SimpleNamespace(client=SimpleNamespace(host=peer), headers={"x-forwarded-for": xff} if xff else {})


def test_trusted_proxy_header_is_used():
    assert client_ip(req("127.0.0.1", "203.0.113.9")) == "203.0.113.9"


def test_client_supplied_entries_are_ignored():
    # A client sends "X-Forwarded-For: 1.2.3.4"; the proxy appends the real address
    assert client_ip(req("127.0.0.1", "1.2.3.4, 203.0.113.9")) == "203.0.113.9"


def test_untrusted_peer_cannot_set_its_address():
    assert client_ip(req("198.51.100.7", "1.2.3.4")) == "198.51.100.7"


def test_malformed_header_falls_back_to_peer():
    assert client_ip(req("127.0.0.1", "not-an-ip")) == "127.0.0.1"
