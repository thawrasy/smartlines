"""The hub's only link out: outbound HTTPS to the platform with its own key. Nothing reaches the hub from the internet.

Every SYNC_SECONDS it pulls its station, screens and boards; every REPORT_SECONDS it reports the players it saw on
the screens' network. When a pull fails the hub keeps what it has and remembers since when; the first report after the
link returns says how long it was cut.
"""
from __future__ import annotations

import asyncio
import logging
import time
from typing import Callable, Optional

import httpx

from . import VERSION
from .store import Store

log = logging.getLogger("masslak_hub")
SYNC_SECONDS = 15
REPORT_SECONDS = 30
SEEN_WINDOW = 90


class Uplink:
    def __init__(self, store: Store, client: httpx.AsyncClient, on_sync: Callable[[], None] = lambda: None):
        self.store, self.client, self.on_sync = store, client, on_sync
        self.seen: dict[str, tuple[str, float]] = {}       # MAC -> (IP, when) of players that asked for a board
        self.down_since: Optional[float] = None
        self.gap_to_report = 0

    def headers(self) -> dict:
        return {"X-Hub-Key": self.store.key or "", "X-Hub-Version": VERSION}

    def saw(self, mac: str, ip: str) -> None:
        self.seen[mac] = (ip, time.time())

    async def pull(self) -> bool:
        try:
            r = await self.client.get("/api/hub/sync", headers=self.headers())
            r.raise_for_status()
            data = r.json()
        except (httpx.HTTPError, ValueError) as exc:
            if self.down_since is None:
                self.down_since = time.time()
                log.warning("uplink cut: %s; showing the last boards", exc)
            return False
        if self.down_since is not None:
            self.gap_to_report += int(time.time() - self.down_since)
            log.info("uplink back after %s s", int(time.time() - self.down_since))
            self.down_since = None
        self.store.save_sync(data)
        self._prune(data)
        self.on_sync()
        return True

    def _prune(self, data: dict) -> None:
        """A screen whose player was released or replaced forgets the device key of the old player."""
        players = {s["code"]: s.get("mac") for s in data.get("screens") or []}
        bindings = self.store.bindings
        kept = {code: b for code, b in bindings.items() if players.get(code) and players[code] == b.get("mac")}
        if kept != bindings:
            self.store.save_bindings(kept)

    async def report(self) -> bool:
        now = time.time()
        players = [{"mac": mac, "ip": ip} for mac, (ip, at) in self.seen.items() if now - at <= SEEN_WINDOW]
        try:
            r = await self.client.post("/api/hub/report", headers=self.headers(),
                                       json={"players": players[:500], "uplink_gap_seconds": self.gap_to_report})
            r.raise_for_status()
        except httpx.HTTPError:
            return False
        self.gap_to_report = 0
        return True

    async def run(self) -> None:
        last_report = 0.0
        while True:
            await self.pull()
            if time.time() - last_report >= REPORT_SECONDS and self.down_since is None:
                if await self.report():
                    last_report = time.time()
            await asyncio.sleep(SYNC_SECONDS)
