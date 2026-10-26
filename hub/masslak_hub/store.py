"""The hub's local state, in one directory (default /var/lib/masslak-hub), each file written whole and then moved into
place so a power cut never leaves half a file:

    key            the hub's own key (0600): made at pairing; the platform keeps only its SHA-256
    hub.json       the platform's address and the hub and station it was paired as
    sync.json      the last pull: the station, its screens with their boards, city names and labels; and when it came
    bindings.json  per screen, the player bound to it: its MAC and the SHA-256 of the device key it holds as a cookie
"""
from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any, Optional


class Store:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)

    def _write(self, name: str, text: str, mode: int = 0o600) -> None:
        tmp = self.root / f".{name}.tmp"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.root / name)

    def _read(self, name: str, default: Any = None) -> Any:
        try:
            return json.loads((self.root / name).read_text(encoding="utf-8"))
        except (FileNotFoundError, ValueError):
            return default

    # the key and the pairing
    @property
    def key(self) -> Optional[str]:
        try:
            return (self.root / "key").read_text(encoding="utf-8").strip() or None
        except FileNotFoundError:
            return None

    def save_pairing(self, key: str, platform: str, paired: dict) -> None:
        self._write("key", key + "\n")
        self._write("hub.json", json.dumps({"platform": platform, **paired}, ensure_ascii=False))

    @property
    def hub(self) -> dict:
        return self._read("hub.json", {})

    # the last pull from the platform
    @property
    def sync(self) -> Optional[dict]:
        return self._read("sync.json")

    def save_sync(self, data: dict, at: Optional[float] = None) -> None:
        self._write("sync.json", json.dumps({**data, "synced_at": at if at is not None else time.time()}, ensure_ascii=False))

    # which player each screen is bound to
    @property
    def bindings(self) -> dict:
        return self._read("bindings.json", {})

    def save_bindings(self, bindings: dict) -> None:
        self._write("bindings.json", json.dumps(bindings))
