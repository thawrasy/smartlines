"""Outbound connections through the egress proxy (audit T3-02).

In production every connection to the outside world goes through one forward proxy (MASSLAK_EGRESS_PROXY,
deploy/egress/squid.conf): webhooks, payment providers, the SMS gateway, the SMTP relay and government adapters. The API
and worker containers have no route to the internet of their own. The proxy:
* tunnels only HTTPS and mail submission (CONNECT to ports 443, 465 and 587); plain HTTP is refused,
* refuses private, loopback, link-local, metadata and other reserved addresses after its own DNS lookup, so a name that
  rebinds to an internal address is stopped even after the application's own check,
* allows only the domains of an allowlist: the fixed providers (deploy/egress/allowlist.txt) and the domains of active
  partner webhook endpoints, written by the worker every minute (write_allowlists).

The application keeps its own checks in front of the proxy (webhooks.check_url and webhooks.post): two layers.
The key service (Vault) is an internal service and is reached directly.

The sandbox may run without a proxy; production refuses to start without one (require_in_production).
"""
from __future__ import annotations

import os
import smtplib
import socket
import urllib.request
from pathlib import Path
from typing import Optional
from urllib.parse import urlparse

from .config import get_settings


class EgressError(OSError):
    pass


def proxy() -> Optional[tuple[str, int]]:
    url = os.environ.get("MASSLAK_EGRESS_PROXY", "").strip()
    if not url:
        return None
    u = urlparse(url if "://" in url else f"http://{url}")
    if not u.hostname:
        raise EgressError("MASSLAK_EGRESS_PROXY must look like http://egress:3128")
    return u.hostname, u.port or 3128


def require_in_production() -> None:
    """Production must send every outbound connection through the proxy."""
    if not get_settings().sandbox and proxy() is None:
        raise RuntimeError("MASSLAK_EGRESS_PROXY is required outside the sandbox (audit T3-02): outbound traffic goes "
                           "through the egress proxy only")


def tunnel(host: str, port: int, timeout: float = 15.0) -> socket.socket:
    """A TCP connection to host:port, through the proxy's CONNECT when a proxy is set, directly otherwise."""
    p = proxy()
    if p is None:
        return socket.create_connection((host, port), timeout=timeout)
    sock = socket.create_connection(p, timeout=timeout)
    try:
        target = f"[{host}]:{port}" if ":" in host else f"{host}:{port}"
        sock.sendall(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
        reply = b""
        while b"\r\n\r\n" not in reply:
            part = sock.recv(4096)
            if not part:
                break
            reply += part
            if len(reply) > 16384:
                break
        status = reply.split(b"\r\n", 1)[0].decode(errors="replace")
        parts = status.split()
        if len(parts) < 2 or parts[1] != "200":
            raise EgressError(f"EGRESS_REFUSED: the egress proxy refused {target} ({status[:80]})")
    except BaseException:
        sock.close()
        raise
    return sock


def urlopen(req: urllib.request.Request, timeout: float):
    """urllib.request.urlopen through the proxy (HTTPS is tunnelled with CONNECT). Environment proxies are ignored."""
    p = proxy()
    handler = urllib.request.ProxyHandler({"https": f"http://{p[0]}:{p[1]}"} if p else {})
    return urllib.request.build_opener(handler).open(req, timeout=timeout)


class SMTP(smtplib.SMTP):
    """SMTP whose connection goes through the proxy tunnel."""

    def _get_socket(self, host, port, timeout):
        return tunnel(host, port, timeout if isinstance(timeout, (int, float)) else 15.0)


def _domain(url: Optional[str]) -> Optional[str]:
    if not url:
        return None
    host = urlparse(url if "://" in url else f"https://{url}").hostname
    if not host or host.replace(".", "").isdigit() or ":" in host:
        return None                      # literal addresses are never allowlisted by name
    return host.lower()


async def write_allowlists(conn, directory: str) -> int:
    """Writes the domains the proxy may reach for partner webhooks and configured providers. Returns how many."""
    domains: set[str] = set()
    for r in await conn.fetch("SELECT url FROM sys.webhook_endpoint WHERE status = 'ACTIVE'"):
        domains.add(_domain(r["url"]))
    for r in await conn.fetch("SELECT config ->> 'base_url' AS u FROM fin.payment_provider WHERE config ? 'base_url'"):
        domains.add(_domain(r["u"]))
    for r in await conn.fetch("""SELECT endpoint AS u FROM sec.gov_adapter_config WHERE endpoint ~ '^https://'
                                 UNION SELECT endpoint FROM sec.authority_profile WHERE endpoint ~ '^https://'"""):
        domains.add(_domain(r["u"]))
    for env in ("MASSLAK_SMS_URL", "MASSLAK_SMTP_URL", "MASSLAK_WHATSAPP_URL"):
        domains.add(_domain(os.environ.get(env)))
    st = get_settings()
    if st.files_backend == "s3" and st.files_s3_via_proxy:      # a cloud object store for files
        host = _domain(st.files_s3_endpoint)
        domains.add(f"{st.files_s3_bucket}.{host}" if host and not st.files_s3_path_style else host)
    domains.discard(None)
    path = Path(directory)
    path.mkdir(parents=True, exist_ok=True)
    tmp = path / "generated.txt.tmp"
    tmp.write_text("# written by the worker (app.egress.write_allowlists); do not edit\n"
                   + "".join(f"{d}\n" for d in sorted(domains)))
    tmp.replace(path / "generated.txt")
    return len(domains)
