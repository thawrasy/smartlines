"""Seat layout rules: numbering, labels, and refusal of layouts that cannot be real."""
import pytest

from app.modules.fleet import layout as L


def test_two_plus_two_coach_numbers_rows_front_to_back_left_to_right():
    seats = L.build(L.preset("2+2", 11))
    assert len(seats) == 44
    assert [s.label for s in seats[:5]] == ["1A", "1B", "1C", "1D", "2A"]
    assert (seats[0].row, seats[0].col) == (1, 1) and (seats[2].col, seats[3].col) == (4, 5)   # aisle at column 3
    assert seats[-1].n == 44 and seats[-1].label == "11D"


def test_letters_follow_the_seat_column_whatever_the_gaps():
    # Door row on the right and a full back row: the right window seat stays D in every 2+2 row
    seats = L.build([["SS_SS", "SS_DD", "SSSSS"]])
    labels = [s.label for s in seats]
    assert labels == ["1A", "1B", "1D", "1E", "2A", "2B", "3A", "3B", "3C", "3D", "3E"]


def test_mixed_rows_and_accessible_seat():
    s = L.summary([["s__s", "SS_S", "H___"]])          # lower case is accepted and normalised
    assert s["decks"] == [["S__S", "SS_S", "H___"]]
    assert s["seats_per_row"] == [[2, 3, 1]] and s["total_seats"] == 6
    assert s["seats"][-1]["cabin"] == "ACCESSIBLE"


def test_two_decks_number_lower_deck_first_and_mark_upper_seats():
    seats = L.build([["SS_SS", "SS_RR"], ["SS_SS"]])
    assert len(seats) == 10 and seats[6].deck == 2 and seats[6].label == "U1A"


def test_presets():
    assert L.summary(L.preset("2+1", 11, door_row=11))["total_seats"] == 32
    assert L.summary(L.preset("1+1", 8))["total_seats"] == 16
    assert L.summary(L.preset("2+2", 9, door_row=6, back_row_full=True))["total_seats"] == 39
    assert L.preset("3", 4)[0][0] == "SSS"


@pytest.mark.parametrize("grid, code", [
    ([["SS_SS", "SS_S"]], "LAYOUT_RAGGED"),
    ([["SS_SZ"]], "LAYOUT_CELL"),
    ([["____"]], "LAYOUT_EMPTY"),
    ([["S"]], "LAYOUT_WIDTH"),
    ([["SSSSSSS"]] * 1 + [["SS"]] * 2, "LAYOUT_DECKS"),
    ([["SSSSSSS"] * 15], "LAYOUT_TOO_MANY_SEATS"),
])
def test_impossible_layouts_are_refused(grid, code):
    with pytest.raises(L.LayoutError) as e:
        L.build(grid)
    assert str(e.value).startswith(code)
