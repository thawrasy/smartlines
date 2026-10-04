"""Seat layouts: the real arrangement of seats in a vehicle, row by row.

A layout is one grid per deck. Each row is a string with one character per position across the vehicle, seen from
the back looking forward (the driver sits front left):

    S  passenger seat              H  accessible seat (wheelchair space or priority seat)
    _  aisle                       D  door
    C  toilet (WC)                 R  stairs (double-deck)
    X  nothing (empty position, luggage, driver area)

    2+2 coach row      "SS_SS"     2+1 VIP row        "SS_S"      1+1 row       "S_S"
    door row (right)   "SS_DD"     full back row      "SSSSS"     toilet row    "SS_CC"

Seats are numbered 1..N row by row, front to back, left to right, lower deck first. Each seat also gets a label:
the row number (counting rows that have seats) and a letter for its seat column (A at the left window), so a seat
keeps the same letter in every row whatever the gaps: 3A, 3B | 3C, 3D.

This module is pure: it parses, validates and numbers. It is the single numbering logic; the interface asks the
server for a preview instead of numbering seats itself.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass

SEAT_CELLS = {"S": "ECONOMY", "H": "ACCESSIBLE"}
OTHER_CELLS = set("_DCRX")
MAX_DECKS, MAX_ROWS, MIN_WIDTH, MAX_WIDTH, MAX_SEATS = 2, 25, 2, 7, 99
LETTERS = "ABCDEFG"


class LayoutError(ValueError):
    """Carries a stable error code for the API (first word of the message)."""


@dataclass(frozen=True)
class Seat:
    n: int          # seat number: the inventory key (ops.seat_segment.seat_no)
    label: str      # printed on the ticket, e.g. "3C"
    deck: int
    row: int        # 1-based row within the deck, counting every grid row
    col: int        # 1-based position across the vehicle
    cabin: str

    def as_dict(self) -> dict:
        return asdict(self)


def normalise(decks: list[list[str]]) -> list[list[str]]:
    """Upper case, no spaces; validation follows in build()."""
    return [[row.replace(" ", "").upper() for row in deck] for deck in decks]


def build(decks: list[list[str]]) -> list[Seat]:
    decks = normalise(decks)
    if not 1 <= len(decks) <= MAX_DECKS:
        raise LayoutError("LAYOUT_DECKS: a vehicle has one or two decks")
    seats: list[Seat] = []
    for d, rows in enumerate(decks, start=1):
        if not 1 <= len(rows) <= MAX_ROWS:
            raise LayoutError(f"LAYOUT_ROWS: each deck has 1 to {MAX_ROWS} rows")
        width = len(rows[0])
        if not MIN_WIDTH <= width <= MAX_WIDTH:
            raise LayoutError(f"LAYOUT_WIDTH: a row has {MIN_WIDTH} to {MAX_WIDTH} positions")
        for row in rows:
            if len(row) != width:
                raise LayoutError("LAYOUT_RAGGED: every row of a deck has the same number of positions")
            bad = set(row) - set(SEAT_CELLS) - OTHER_CELLS
            if bad:
                raise LayoutError(f"LAYOUT_CELL: unknown position code {''.join(sorted(bad))}")
        # Letters follow the seat columns of the deck, so the right window seat is the same letter in every row
        seat_cols = [c for c in range(width) if any(row[c] in SEAT_CELLS for row in rows)]
        letter = {c: LETTERS[i] for i, c in enumerate(seat_cols)}
        label_row = 0
        for r, row in enumerate(rows, start=1):
            if any(ch in SEAT_CELLS for ch in row):
                label_row += 1
            for c, ch in enumerate(row):
                if ch in SEAT_CELLS:
                    seats.append(Seat(n=len(seats) + 1, label=f"{'U' if d == 2 else ''}{label_row}{letter[c]}",
                                      deck=d, row=r, col=c + 1, cabin=SEAT_CELLS[ch]))
    if not seats:
        raise LayoutError("LAYOUT_EMPTY: a layout needs at least one passenger seat")
    if len(seats) > MAX_SEATS:
        raise LayoutError(f"LAYOUT_TOO_MANY_SEATS: at most {MAX_SEATS} passenger seats")
    return seats


def summary(decks: list[list[str]]) -> dict:
    """What the interface shows: the grid, every seat, and the count per row."""
    decks = normalise(decks)
    seats = build(decks)
    per_row = [[sum(ch in SEAT_CELLS for ch in row) for row in deck] for deck in decks]
    return {"decks": decks, "total_seats": len(seats), "seats_per_row": per_row, "seats": [s.as_dict() for s in seats]}


def preset(pattern: str, rows: int, *, door_row: int | None = None, back_row_full: bool = False,
           wc_row: int | None = None) -> list[list[str]]:
    """A starting grid from a row pattern such as "2+2", "2+1", "1+1" or "3" (no aisle). The carrier then edits
    single positions to match the vehicle exactly."""
    parts = [int(p) for p in pattern.split("+")]
    if not 1 <= len(parts) <= 2 or not all(1 <= p <= 4 for p in parts):
        raise LayoutError("LAYOUT_PATTERN: use a pattern like 2+2, 2+1, 1+1 or 3")
    row = "_".join("S" * p for p in parts)
    grid = [row] * rows
    right = len(row) - len(row.rstrip("S")) if "_" in row else 0
    if door_row and 1 <= door_row <= rows and right:
        grid[door_row - 1] = row[: len(row) - right] + "D" * right
    if wc_row and 1 <= wc_row <= rows and right:
        grid[wc_row - 1] = row[: len(row) - right] + "C" * right
    if back_row_full:
        grid.append("S" * len(row))
    return [grid]
