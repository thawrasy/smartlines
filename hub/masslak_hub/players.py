"""Which player may show which screen.

A screen's board is shown to one player only: the one the station's administration approved for it, recognised by
three things together: its hardware address (MAC, read from the hub's ARP table, so the player cannot just claim it),
its fixed IP (the address the station's network reserves for it), and the device key the hub gave it the first time
(kept by the player as a cookie; the hub keeps its SHA-256). An IP alone is not enough: any device plugged into the
network can take an address. A player not yet approved sees a waiting page with its own address to give the
administration; a rejected one, or one that lost its key, sees nothing.
"""
from __future__ import annotations

import hashlib
import secrets
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

ARP = Path("/proc/net/arp")


def mac_of(ip: str, arp: Path = ARP) -> Optional[str]:
    """The hardware address the hub's kernel learnt for an IP on its own network; none for an address it did not see
    directly (a device on another network, behind a router, cannot be a screen's player)."""
    try:
        lines = arp.read_text().splitlines()[1:]
    except OSError:
        return None
    for line in lines:
        parts = line.split()
        if len(parts) >= 4 and parts[0] == ip and parts[2] != "0x0" and parts[3] != "00:00:00:00:00:00":
            return parts[3].lower()
    return None


def digest(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


@dataclass
class Decision:
    verdict: str                     # SHOW, BIND, WAIT, MISMATCH, REFUSED, UNKNOWN_SCREEN
    screen: Optional[dict] = None
    token: Optional[str] = None      # a new device key, when the player is bound now


def decide(screens: list[dict], rejected: list[str], bindings: dict, code: str, mac: Optional[str], ip: str,
           cookie: Optional[str]) -> Decision:
    screen = next((s for s in screens if s.get("code") == code.upper()), None)
    if screen is None:
        return Decision("UNKNOWN_SCREEN")
    if mac is None or mac in rejected:
        return Decision("REFUSED", screen)
    if screen.get("mac") != mac:
        return Decision("WAIT", screen)                    # not (yet) this screen's player: the hub reports it as waiting
    if screen.get("ip") != ip:
        return Decision("MISMATCH", screen)                # the right player at another address: reported, not shown
    bound = bindings.get(screen["code"])
    if bound and bound.get("mac") == mac:
        if cookie and secrets.compare_digest(digest(cookie), bound.get("key_sha256", "")):
            return Decision("SHOW", screen)
        return Decision("REFUSED", screen)                 # the player lost its key: release and approve it again
    return Decision("BIND", screen, secrets.token_urlsafe(32))
