"""python -m masslak_hub pair --platform https://masslak.example --code ABCD2345 [--state /var/lib/masslak-hub]
   python -m masslak_hub serve [--port 8080] [--state /var/lib/masslak-hub]

pair: makes the hub's own key, sends the platform only its SHA-256 with the station's one-time code, and keeps the key.
serve: pulls the boards, reports the players and serves the screens on the station's network.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import logging
import os
import secrets
import sys
from pathlib import Path

import httpx
import uvicorn

from . import VERSION
from .server import create_app
from .store import Store
from .uplink import Uplink

STATE = os.environ.get("MASSLAK_HUB_STATE", "/var/lib/masslak-hub")


def _client(platform: str) -> httpx.AsyncClient:
    if not platform.startswith("https://") and not os.environ.get("MASSLAK_HUB_ALLOW_HTTP"):
        sys.exit("the platform is reached over HTTPS only")
    # MASSLAK_HUB_CA names a CA bundle to trust instead of the system's (a pinned certificate authority)
    return httpx.AsyncClient(base_url=platform.rstrip("/"), timeout=20, verify=os.environ.get("MASSLAK_HUB_CA") or True,
                             headers={"User-Agent": f"masslak-hub/{VERSION}"})


async def _pair(platform: str, code: str, store: Store) -> None:
    if store.key:
        sys.exit(f"this hub is paired already ({store.hub.get('label')}); remove {store.root}/key to pair it again")
    key = secrets.token_urlsafe(48)
    async with _client(platform) as client:
        r = await client.post("/api/hub/pair", json={"code": code.strip().upper(), "version": VERSION,
                                                    "key_sha256": hashlib.sha256(key.encode()).hexdigest()})
    if r.status_code != 201:
        sys.exit(f"pairing refused: {r.status_code} {r.text}")
    store.save_pairing(key, platform.rstrip("/"), r.json())
    print(f"paired: hub {r.json()['label']} of station {r.json()['station_code']}")


async def _serve(store: Store, host: str, port: int) -> None:
    if not store.key:
        sys.exit("pair the hub first: python -m masslak_hub pair --platform URL --code CODE")
    async with _client(store.hub["platform"]) as client:
        uplink = Uplink(store, client)
        # MASSLAK_HUB_ARP: another ARP table, for a test bench only; the station's hub reads the kernel's
        app = create_app(store, uplink, Path(os.environ.get("MASSLAK_HUB_ARP", "/proc/net/arp")))
        server = uvicorn.Server(uvicorn.Config(app, host=host, port=port, proxy_headers=False, server_header=False,
                                               access_log=False, log_level="info"))
        task = asyncio.create_task(uplink.run())
        try:
            await server.serve()
        finally:
            task.cancel()


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    p = argparse.ArgumentParser(prog="masslak_hub")
    p.add_argument("--state", default=STATE)
    sub = p.add_subparsers(dest="cmd", required=True)
    pa = sub.add_parser("pair")
    pa.add_argument("--platform", required=True)
    pa.add_argument("--code", required=True)
    se = sub.add_parser("serve")
    # the players reach the hub over the station's network; the installer's --listen narrows this to the screens' VLAN
    se.add_argument("--host", default=os.environ.get("MASSLAK_HUB_HOST", "0.0.0.0"))  # nosec B104
    se.add_argument("--port", type=int, default=int(os.environ.get("MASSLAK_HUB_PORT", "8080")))
    a = p.parse_args()
    store = Store(Path(a.state))
    asyncio.run(_pair(a.platform, a.code, store) if a.cmd == "pair" else _serve(store, a.host, a.port))


if __name__ == "__main__":
    main()
