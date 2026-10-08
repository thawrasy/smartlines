"""SSRF and DNS rebinding on partner webhook endpoints (review stage B; penetration test scope, section on outbound
calls). Partners choose the URL, so every spelling of an internal address must be refused at registration, every
address a name resolves to is checked again at each delivery, and a slow endpoint cannot hold a worker. Unit tests: no
API or database needed. The egress proxy repeats the address check in production (test_egress.py, selftest.sh)."""
import socket
import threading
import time

import pytest

from app import config
from app.errors import ApiError
from app.modules.integration import webhooks


@pytest.fixture
def production(monkeypatch):
    monkeypatch.setenv("MASSLAK_SANDBOX", "false")
    monkeypatch.delenv("MASSLAK_WEBHOOK_ALLOW_PRIVATE", raising=False)
    config.get_settings.cache_clear()
    yield
    config.get_settings.cache_clear()


INTERNAL = [
    "https://100.100.100.200/latest/meta-data",      # shared address space 100.64.0.0/10 (a cloud metadata service)
    "https://100.64.0.1/hook",
    "https://169.254.169.254/latest/meta-data",
    "https://[fd00:ec2::254]/latest/meta-data",       # IPv6 metadata (unique local)
    "https://[64:ff9b::a9fe:a9fe]/hook",              # NAT64 form of 169.254.169.254
    "https://[64:ff9b::7f00:1]/hook",                 # NAT64 form of 127.0.0.1
    "https://[::ffff:127.0.0.1]/hook",                # IPv4-mapped IPv6
    "https://[::ffff:a9fe:a9fe]/hook",
    "https://[2002:7f00:1::1]/hook",                  # 6to4 of 127.0.0.1
    "https://[fe80::1%25eth0]/hook",                  # link-local with a zone
    "https://[::]/hook",
    "https://0.0.0.0/hook",
    "https://2130706433/hook",                        # 127.0.0.1 as one decimal number
    "https://0x7f000001/hook",                        # ... as hexadecimal
    "https://0177.0.0.1/hook",                        # ... with an octal part
    "https://127.1/hook",                             # ... in short form
    "https://10.1/hook",
    "https://198.18.0.1/hook",                        # benchmarking
    "https://192.0.2.10/hook",                        # documentation
    "https://224.0.0.1/hook",                         # multicast
    "https://255.255.255.255/hook",
    "https://localhost/hook",
    "https://LOCALHOST./hook",                        # trailing dot and capitals
    "https://intranet/hook",                          # a single label resolves on the local search domain
    "https://db.internal/hook",
    "https://printer.local/hook",
    "https://router.home.arpa/hook",
    "https://anything.localhost/hook",
]


@pytest.mark.parametrize("url", INTERNAL)
def test_every_spelling_of_an_internal_address_is_refused(url, production):
    with pytest.raises(ApiError) as e:
        webhooks.check_url(url)
    assert e.value.code == "WEBHOOK_URL_NOT_PUBLIC", url


@pytest.mark.parametrize("url, code", [
    ("https://partner.example.com:6379/hook", "WEBHOOK_URL_PORT"),      # an internal service port on a public name
    ("https://partner.example.com:22/", "WEBHOOK_URL_PORT"),
    ("https://partner.example.com:99999/", "WEBHOOK_URL_INVALID"),
    ("https://user@partner.example.com/hook", "WEBHOOK_URL_INVALID"),
    ("ftp://partner.example.com/hook", "WEBHOOK_URL_INVALID"),
    ("https:///hook", "WEBHOOK_URL_INVALID"),
    ("https://partner.example.com/" + "a" * 500, "WEBHOOK_URL_INVALID"),
])
def test_ports_credentials_and_malformed_urls_are_refused(url, code, production):
    with pytest.raises(ApiError) as e:
        webhooks.check_url(url)
    assert e.value.code == code


@pytest.mark.parametrize("url", ["https://hooks.partner.com/masslak", "https://partner.com:443/x?y=1", "https://93.184.216.34/hook",
                                 "https://[2606:4700:4700::1111]/hook"])
def test_public_endpoints_are_accepted(url, production):
    assert webhooks.check_url(url) == url


def answers(*addrs):
    return lambda *a, **k: [(socket.AF_INET6 if ":" in x else socket.AF_INET, socket.SOCK_STREAM, 6, "", (x, 443)) for x in addrs]


@pytest.mark.parametrize("addrs", [
    ("100.100.100.200",), ("64:ff9b::a9fe:a9fe",), ("::ffff:10.0.0.7",), ("fd00:ec2::254",), ("127.0.0.53",),
    ("93.184.216.34", "100.64.3.4"),                  # one internal answer among public ones refuses the whole set
])
def test_a_name_that_rebinds_to_an_internal_address_is_refused_at_delivery(addrs, monkeypatch, production):
    monkeypatch.setattr(socket, "getaddrinfo", answers(*addrs))
    connected = []
    monkeypatch.setattr(socket, "create_connection", lambda *a, **k: connected.append(a))
    with pytest.raises(webhooks.DeliveryError, match="URL_NOT_PUBLIC"):
        webhooks.post("https://hooks.partner.com/masslak", b"{}", {})
    assert connected == []


def test_delivery_connects_to_the_address_it_checked(monkeypatch, production):
    """Time of check and time of use are the same lookup: a second resolution (a rebinding answer) is never made."""
    calls = []

    def resolve(*a, **k):
        calls.append(a[0])
        return answers("93.184.216.34")() if len(calls) == 1 else answers("127.0.0.1")()
    monkeypatch.setattr(socket, "getaddrinfo", resolve)
    targets = []

    def connect(addr, *a, **k):
        targets.append(addr[0])
        raise ConnectionRefusedError(111, "refused")
    monkeypatch.setattr(socket, "create_connection", connect)
    with pytest.raises(OSError):
        webhooks.post("https://hooks.partner.com/masslak", b"{}", {})
    assert calls == ["hooks.partner.com"] and targets == ["93.184.216.34"]


def test_an_endpoint_that_answers_one_byte_at_a_time_cannot_hold_the_worker(monkeypatch, production):
    """Slow-drip answer: every read is within the per-read timeout, but the delivery stops at the total deadline."""
    srv = socket.socket()
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    port = srv.getsockname()[1]
    stop = threading.Event()

    def drip():
        conn, _ = srv.accept()
        conn.recv(65536)
        try:
            for b in b"HTTP/1.1 200 OK\r\nX-Slow: " + b"a" * 1000:
                if stop.is_set():
                    break
                conn.sendall(bytes([b]))
                time.sleep(0.2)
        except OSError:
            pass
        conn.close()
    threading.Thread(target=drip, daemon=True).start()

    class PlainContext:                                 # the receiver speaks plain HTTP: no TLS needed for the timing
        verify_mode, check_hostname, post_handshake_auth = 0, False, None

        def wrap_socket(self, raw, server_hostname=None):
            return raw

        def load_verify_locations(self, *_):
            pass
    real_resolve, real_connect = socket.getaddrinfo, socket.create_connection
    # the partner's name resolves to a public address; the connection itself goes to the local slow server
    monkeypatch.setattr(socket, "getaddrinfo", lambda host, *a, **k: real_resolve(host, *a, **k) if host == "127.0.0.1"
                        else answers("93.184.216.34")())
    monkeypatch.setattr(socket, "create_connection", lambda addr, *a, **k: real_connect(("127.0.0.1", port), *a, **k))
    monkeypatch.setattr(webhooks.ssl, "create_default_context", lambda: PlainContext())
    monkeypatch.setattr(webhooks, "DEADLINE", 1.5)
    t0 = time.monotonic()
    try:
        with pytest.raises(webhooks.DeliveryError, match="DEADLINE"):
            webhooks.post("https://hooks.partner.com/masslak", b"{}", {})
    finally:
        stop.set()
        srv.close()
    assert time.monotonic() - t0 < 5


def test_a_payment_provider_address_follows_the_same_rules():
    """Platform staff set the provider's address; an internal one is refused there too (the proxy checks again)."""
    import os
    if not os.environ.get("MASSLAK_TEST_URL"):
        pytest.skip("needs the running API")
    from test_e2e import login
    admin = login("admin@masslak.test", "PLATFORM")
    provider = next(p for p in admin.get("/api/admin/payments/providers").json()["providers"] if p["adapter"] == "HOSTED_CARD")
    body = {"status": provider["status"], "min_amount": provider["min_amount"], "max_amount": provider["max_amount"],
            "fee_pct": provider["fee_pct"], "fee_borne_by": provider["fee_borne_by"]}
    r = admin.put(f"/api/admin/payments/providers/{provider['code']}", json={**body, "config": {"base_url": "https://169.254.169.254/"}})
    assert r.status_code == 422 and r.json()["error"]["code"] == "CONFIG_URL_NOT_PUBLIC", r.text
