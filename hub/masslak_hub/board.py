"""The board a player shows, from the hub's last pull.

While the uplink is up the board is the platform's. When it is cut the hub keeps showing the last board it has, says
since when, and moves trips on by their times: a departure whose time has passed without news from the platform is
shown as "see the counter", never as on time. Only public board data is here: no passenger data reaches the hub.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Optional

STALE_SECONDS = 120                 # beyond this without a pull the board says when it was last updated
FINAL = {"DEPARTED", "CANCELLED", "ARRIVED"}


def _at(value: str) -> Optional[datetime]:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, ValueError):
        return None


def view(sync: dict, screen: dict, now: float) -> dict:
    board = dict(screen.get("board") or {})
    synced_at = float(sync.get("synced_at") or 0)
    stale = now - synced_at > STALE_SECONDS
    out = {"board": board or None, "labels": sync.get("labels") or {}, "cities": sync.get("cities") or {},
           "station": sync.get("station") or {}, "screen": {k: screen.get(k) for k in ("code", "kind", "label", "group")},
           "synced_at": synced_at, "stale": stale}
    if board and stale:
        moment = datetime.fromtimestamp(now, timezone.utc)
        for side in ("departures", "arrivals"):
            rows = []
            for row in board.get(side) or []:
                at = _at(row.get("at", ""))
                if at is not None and at < moment and row.get("status") not in FINAL:
                    row = {**row, "status": "SEE_COUNTER"}
                rows.append(row)
            board[side] = rows
        out["board"] = board
    return out
