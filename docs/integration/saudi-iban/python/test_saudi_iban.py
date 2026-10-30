"""Runs the shared test vectors (../test_vectors.csv) against saudi_iban.py: python -m unittest test_saudi_iban"""
import csv
import unittest
from pathlib import Path

from saudi_iban import BANKS, check_digits, message, mod97, validate

VECTORS = Path(__file__).resolve().parent.parent / "test_vectors.csv"


class SaudiIbanTest(unittest.TestCase):
    def test_vectors(self):
        with VECTORS.open(encoding="utf-8", newline="") as f:
            rows = list(csv.DictReader(f))
        self.assertGreater(len(rows), 40)
        for row in rows:
            with self.subTest(note=row["note"], input=row["input"]):
                r = validate(row["input"])
                self.assertEqual(r.valid, row["valid"] == "true")
                self.assertEqual(r.error or "", row["error"])
                self.assertEqual(r.bank_code or "", row["bank_code"])
                self.assertEqual(";".join(r.warnings), row["warnings"])

    def test_check_digits_round_trip(self):
        for code in BANKS:
            iban = f"SA{check_digits(code, '000000608010167519')}{code}000000608010167519"
            self.assertEqual(mod97(iban), 1)

    def test_arabic_indic_and_persian_digits(self):
        arabic = "".join(chr(0x0660 + int(d)) if d.isdigit() else d for d in "SA03 8000 0000 6080 1016 7519")
        persian = "".join(chr(0x06F0 + int(d)) if d.isdigit() else d for d in "SA03 8000 0000 6080 1016 7519")
        for value in (arabic, persian):
            r = validate(value)
            self.assertTrue(r.valid)
            self.assertEqual(r.iban, "SA0380000000608010167519")

    def test_messages(self):
        self.assertEqual(message("CHECKSUM_FAILED", "en"), "The MOD-97 check failed: the IBAN is mistyped")
        self.assertTrue(message("CHECKSUM_FAILED").startswith("\u0641\u0634\u0644"))
        self.assertTrue(message("LEGACY_BANK", "en"))

    def test_lenient_bank(self):
        r = validate("SA3399000000608010167519", strict_bank=False)
        self.assertTrue(r.valid)
        self.assertEqual(r.warnings, ["UNKNOWN_BANK"])

    def test_result_fields(self):
        r = validate("sa03 8000 0000 6080 1016 7519")
        self.assertEqual(r.iban, "SA0380000000608010167519")
        self.assertEqual(r.formatted, "SA03 8000 0000 6080 1016 7519")
        self.assertEqual(r.bank["swift"], "RJHISARI")


if __name__ == "__main__":
    unittest.main()
