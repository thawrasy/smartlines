"""Prices round to a whole currency unit with halves up, the same as the database's round() (the review before release
1.52.0 found Python's round() taking a half to the even unit, so a half rounded up or down by the unit's parity)."""
from app.util import round_minor, round_unit


def test_halves_round_up_whatever_the_unit():
    assert [round_unit(v) for v in (2550, 2650, 150, 250)] == [2600, 2700, 200, 300]


def test_other_amounts_round_to_the_nearest_unit():
    assert [round_unit(v) for v in (2549.9, 2500.0, 12345.0, 0, 99.99, 1_000_049)] == [2500, 2500, 12300, 0, 100, 1_000_000]


def test_minor_units_round_halves_up():
    assert [round_minor(v) for v in (0.5, 1.5, 2.5, 2.49, 1_000_000.5)] == [1, 2, 3, 2, 1_000_001]
