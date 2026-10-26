"""The new Syrian pound (1176): 100 old pounds make one new pound since 1 January 2026. Stored amounts keep their
integers (one old pound is one new piastre); the currency counts them in ten-thousandths of a pound and people see two
decimals, on screens, in messages and in invoice codes alike."""
from decimal import Decimal

from app import money


def test_amounts_read_in_new_pounds():
    money._UNITS["XNP"] = (4, 2)                        # a pound stored like the new Syrian pound
    assert money.major(2_900_000, "XNP") == Decimal("290.00")          # an old fare of 29,000 is 290 new pounds
    assert money.text(2_900_000, "XNP") == "290"
    assert money.text(2_905_049, "XNP") == "290.50"                    # rounded half up to the piastre
    assert money.text(123_456_789_000, "XNP") == "12,345,678.90"
    assert money.to_minor("290.50", "XNP") == 2_905_000
    money._UNITS["XTD"] = (3, 3)                        # a dinar keeps its three decimals
    assert money.text(1_234, "XTD") == "1.234"
    assert money.units("NOT-A-CURRENCY") == (2, 2)
