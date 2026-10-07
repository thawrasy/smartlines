"""Egress proxy (audit T3-02): every outbound connection goes through the proxy's CONNECT tunnel, a refusal stops it,
production cannot start without a proxy, and the allowlist holds only names. Unit tests with a fake proxy; with
MASSLAK_TEST_EGRESS_PROXY set (host:port of a running deploy/egress/squid.conf) they also run against the real proxy."""
import os
import socket
import threading
import urllib.request

import pytest

from app import egress
from app.modules.integration import webhooks


class FakeProxy:
    """Answers CONNECT with the given status and records the targets asked for."""

    def __init__(self, status: str):
        self.status, self.targets = status, []
        self.srv = socket.socket()
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(5)
        self.port = self.srv.getsockname()[1]
        threading.Thread(target=self._serve, daemon=True).start()

    def _serve(self):
        while True:
            try:
                c, _ = self.srv.accept()
            except OSError:
                return
            data = b""
            while b"\r\n\r\n" not in data:
                part = c.recv(4096)
                if not part:
                    break
                data += part
            self.targets.append(data.split(b"\r\n", 1)[0].decode())
            c.sendall(f"HTTP/1.1 {self.status}\r\n\r\n".encode())
            c.close()


def test_tunnel_asks_the_proxy_and_honours_a_refusal(monkeypatch):
    refusing = FakeProxy("403 Forbidden")
    monkeypatch.setenv("MASSLAK_EGRESS_PROXY", f"http://127.0.0.1:{refusing.port}")
    with pytest.raises(egress.EgressError, match="EGRESS_REFUSED"):
        egress.tunnel("169.254.169.254", 443)
    assert refusing.targets == ["CONNECT 169.254.169.254:443 HTTP/1.1"]
    accepting = FakeProxy("200 Connection established")
    monkeypatch.setenv("MASSLAK_EGRESS_PROXY", f"http://127.0.0.1:{accepting.port}")
    egress.tunnel("partner.example", 443).close()
    egress.tunnel("2001:db8::5", 443).close()
    assert accepting.targets == ["CONNECT partner.example:443 HTTP/1.1", "CONNECT [2001:db8::5]:443 HTTP/1.1"]


def test_webhook_delivery_goes_through_the_proxy(monkeypatch):
    refusing = FakeProxy("403 Forbidden")
    monkeypatch.setenv("MASSLAK_EGRESS_PROXY", f"http://127.0.0.1:{refusing.port}")
    real = socket.getaddrinfo
    monkeypatch.setattr(socket, "getaddrinfo", lambda host, *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))]
                        if host == "partner.example" else real(host, *a, **k))
    with pytest.raises(egress.EgressError):
        webhooks.post("https://partner.example/hook", b"{}", {})
    assert refusing.targets == ["CONNECT partner.example:443 HTTP/1.1"]


def test_urlopen_uses_the_proxy_and_ignores_environment_proxies(monkeypatch):
    seen = {}
    real = urllib.request.build_opener

    def spy(*handlers):
        seen["proxies"] = [h.proxies for h in handlers if isinstance(h, urllib.request.ProxyHandler)]
        return real(*handlers)
    monkeypatch.setattr(urllib.request, "build_opener", spy)
    monkeypatch.setenv("HTTPS_PROXY", "http://somewhere-else:8080")
    monkeypatch.setenv("MASSLAK_EGRESS_PROXY", "http://egress:3128")
    with pytest.raises(OSError):
        egress.urlopen(urllib.request.Request("https://psp.invalid/pay", method="POST", data=b"{}"), timeout=2)
    assert seen["proxies"] == [{"https": "http://egress:3128"}]
    monkeypatch.delenv("MASSLAK_EGRESS_PROXY")
    with pytest.raises(OSError):
        egress.urlopen(urllib.request.Request("https://psp.invalid/pay", method="POST", data=b"{}"), timeout=2)
    assert seen["proxies"] == [{}]


def test_production_needs_a_proxy(monkeypatch):
    monkeypatch.delenv("MASSLAK_EGRESS_PROXY", raising=False)
    monkeypatch.setattr(egress, "get_settings", lambda: type("S", (), {"sandbox": False})())
    with pytest.raises(RuntimeError, match="MASSLAK_EGRESS_PROXY is required"):
        egress.require_in_production()
    monkeypatch.setenv("MASSLAK_EGRESS_PROXY", "http://egress:3128")
    egress.require_in_production()


def test_allowlist_takes_names_never_addresses():
    assert egress._domain("https://Hooks.Partner.example/x") == "hooks.partner.example"
    assert egress._domain("https://10.1.2.3/x") is None
    assert egress._domain("https://[::1]/x") is None
    assert egress._domain(None) is None


REAL = os.environ.get("MASSLAK_TEST_EGRESS_PROXY")


@pytest.mark.skipif(not REAL, reason="set MASSLAK_TEST_EGRESS_PROXY to a running egress proxy")
@pytest.mark.parametrize("target", ["169.254.169.254", "10.0.0.5", "127.0.0.1", "localhost", "not-allowlisted.example"])
def test_the_real_proxy_refuses_internal_and_unlisted_targets(monkeypatch, target):
    monkeypatch.setenv("MASSLAK_EGRESS_PROXY", f"http://{REAL}")
    with pytest.raises(egress.EgressError, match="403"):
        egress.tunnel(target, 443)
