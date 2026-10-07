"""Webhook egress (audit T3-02): only https, never a private or metadata address, a name that resolves to one is refused at
delivery time (DNS rebinding), and no redirect is followed. Unit tests: no API or database needed."""
import socket

import pytest

from app.errors import ApiError
from app.modules.integration import webhooks


@pytest.mark.parametrize("url, code", [
    ("http://partner.example/hook", "WEBHOOK_URL_INVALID"),
    ("https://user:pw@partner.example/hook", "WEBHOOK_URL_INVALID"),
    ("https://169.254.169.254/latest/meta-data", "WEBHOOK_URL_NOT_PUBLIC"),
    ("https://127.0.0.1/hook", "WEBHOOK_URL_NOT_PUBLIC"),
    ("https://[::1]/hook", "WEBHOOK_URL_NOT_PUBLIC"),
    ("https://[::ffff:10.0.0.5]/hook", "WEBHOOK_URL_NOT_PUBLIC"),
    ("https://192.168.1.10/hook", "WEBHOOK_URL_NOT_PUBLIC"),
])
def test_registration_refuses_insecure_or_internal_urls(url, code, monkeypatch):
    monkeypatch.delenv("MASSLAK_WEBHOOK_ALLOW_PRIVATE", raising=False)
    with pytest.raises(ApiError) as e:
        webhooks.check_url(url)
    assert e.value.code == code


def test_a_name_that_resolves_to_an_internal_address_is_refused_at_delivery(monkeypatch):
    """The name was public when registered; at delivery it resolves to the metadata service (DNS rebinding)."""
    monkeypatch.delenv("MASSLAK_WEBHOOK_ALLOW_PRIVATE", raising=False)
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("169.254.169.254", 443))])
    connected = []
    monkeypatch.setattr(socket, "create_connection", lambda *a, **k: connected.append(a) or None)
    with pytest.raises(webhooks.DeliveryError, match="URL_NOT_PUBLIC"):
        webhooks.post("https://partner.example/hook", b"{}", {})
    assert connected == []
    # a mix of public and internal answers is refused as a whole
    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443)),
                                                                 (socket.AF_INET, socket.SOCK_STREAM, 6, "", ("10.0.0.7", 443))])
    with pytest.raises(webhooks.DeliveryError, match="URL_NOT_PUBLIC"):
        webhooks.post("https://partner.example/hook", b"{}", {})


def test_delivery_refuses_plain_http_even_if_stored():
    with pytest.raises(webhooks.DeliveryError, match="URL_NOT_HTTPS"):
        webhooks.post("http://partner.example/hook", b"{}", {})


def test_a_redirect_is_reported_not_followed(monkeypatch):
    """The sender returns the status it got; a 302 is a failed delivery, never a request to the Location."""
    import http.client

    class Resp:
        status = 302

        def read(self, n=-1):
            return b""

    class Conn:
        def __init__(self, host, port, timeout=None, context=None):
            self.sock, self.requests = None, []

        def request(self, method, path, body=None, headers=None):
            self.requests.append(path)

        def getresponse(self):
            return Resp()

        def close(self):
            pass

    class Ctx:
        def wrap_socket(self, raw, server_hostname=None):
            return raw

    monkeypatch.setattr(socket, "getaddrinfo", lambda *a, **k: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("93.184.216.34", 443))])
    monkeypatch.setattr(socket, "create_connection", lambda *a, **k: object())
    monkeypatch.setattr(http.client, "HTTPSConnection", Conn)
    monkeypatch.setattr(webhooks.ssl, "create_default_context", lambda: Ctx())
    assert webhooks.post("https://partner.example/hook", b"{}", {}) == 302
