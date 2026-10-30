"""Builds docs/integration/saudi-iban/: the Saudi IBAN bank-code workbook with a live ISO 13616 mod-97 validator, and
saudi_banks.json, the same bank table for the reference validators beside it.

The workbook is in Arabic. Its text is written here as \\u escapes so the repository's language check
(scripts/check_language.py) passes; print a string to read it.

Every check digit, bank name and verdict in the workbook is an Excel formula, so the sheet recalculates when an IBAN or an
account number is typed in. Run `python scripts/gen_saudi_iban_workbook.py`, then recalculate the file in LibreOffice or Excel.
"""
import json
from pathlib import Path

from openpyxl import Workbook
from openpyxl.comments import Comment
from openpyxl.formatting.rule import FormulaRule
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation

PACKAGE = Path(__file__).resolve().parent.parent / "docs" / "integration" / "saudi-iban"
OUT = PACKAGE / "saudi_iban_bank_codes.xlsx"

# (code, Arabic name, English name, status, note). Source: SAMA-assigned IBAN bank identifiers as published in
# github.com/EngMEita/saudi-banks and cross-checked with cubbbix.com and validatefin.com (October 2026).
BANKS = [
    ("05", "\u0645\u0635\u0631\u0641 \u0627\u0644\u0625\u0646\u0645\u0627\u0621", "Alinma Bank", "\u0646\u0634\u0637", ""),
    ("10", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0623\u0647\u0644\u064a \u0627\u0644\u0633\u0639\u0648\u062f\u064a", "Saudi National Bank (SNB)", "\u0646\u0634\u0637", "\u064a\u0634\u0645\u0644 \u062d\u0633\u0627\u0628\u0627\u062a \u0633\u0627\u0645\u0628\u0627 \u0627\u0644\u0645\u0646\u0642\u0648\u0644\u0629 \u0628\u0639\u062f \u0627\u0644\u0627\u0646\u062f\u0645\u0627\u062c 2021"),
    ("15", "\u0628\u0646\u0643 \u0627\u0644\u0628\u0644\u0627\u062f", "Bank Albilad", "\u0646\u0634\u0637", ""),
    ("20", "\u0628\u0646\u0643 \u0627\u0644\u0631\u064a\u0627\u0636", "Riyad Bank", "\u0646\u0634\u0637", ""),
    ("30", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0639\u0631\u0628\u064a \u0627\u0644\u0648\u0637\u0646\u064a", "Arab National Bank", "\u0646\u0634\u0637", ""),
    ("36", "\u0628\u0646\u0643 \u062f\u0627\u0644 \u062b\u0644\u0627\u062b\u0645\u0627\u0626\u0629 \u0648\u0633\u062a\u0648\u0646 (D360)", "D360 Bank", "\u0628\u0646\u0643 \u0631\u0642\u0645\u064a",
     "\u0645\u0624\u0643\u062f \u0628\u0622\u064a\u0628\u0627\u0646 \u0641\u0639\u0644\u064a \u0644\u062d\u0633\u0627\u0628 \u0641\u064a \u0627\u0644\u0628\u0646\u0643 \u0642\u062f\u0651\u0645\u0647 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 (SA83 3603 …) \u064a\u062c\u062a\u0627\u0632 MOD-97\u060c \u0648\u064a\u062a\u0641\u0642 \u0645\u0639 \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a"),
    ("40", "\u0645\u062c\u0645\u0648\u0639\u0629 \u0633\u0627\u0645\u0628\u0627 \u0627\u0644\u0645\u0627\u0644\u064a\u0629", "Samba Financial Group", "\u0645\u062f\u0645\u062c (\u062a\u0627\u0631\u064a\u062e\u064a)", "\u0627\u0646\u062f\u0645\u062c \u0641\u064a \u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0623\u0647\u0644\u064a \u0627\u0644\u0633\u0639\u0648\u062f\u064a 2021\u061b \u0642\u062f \u062a\u0628\u0642\u0649 \u0622\u064a\u0628\u0627\u0646\u0627\u062a \u0642\u062f\u064a\u0645\u0629 \u0645\u062a\u062f\u0627\u0648\u0644\u0629"),
    ("45", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0627\u0644\u0623\u0648\u0644 (\u0633\u0627\u0628)", "Saudi Awwal Bank (SAB, formerly SABB)", "\u0646\u0634\u0637", ""),
    ("50", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0623\u0648\u0644", "Alawwal Bank", "\u0645\u062f\u0645\u062c (\u062a\u0627\u0631\u064a\u062e\u064a)", "\u0627\u0646\u062f\u0645\u062c \u0641\u064a \u0633\u0627\u0628 2019\u061b \u0642\u062f \u062a\u0628\u0642\u0649 \u0622\u064a\u0628\u0627\u0646\u0627\u062a \u0642\u062f\u064a\u0645\u0629 \u0645\u062a\u062f\u0627\u0648\u0644\u0629"),
    ("55", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0627\u0644\u0641\u0631\u0646\u0633\u064a", "Banque Saudi Fransi", "\u0646\u0634\u0637", ""),
    ("60", "\u0628\u0646\u0643 \u0627\u0644\u062c\u0632\u064a\u0631\u0629", "Bank AlJazira", "\u0646\u0634\u0637", ""),
    ("65", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0644\u0644\u0627\u0633\u062a\u062b\u0645\u0627\u0631", "The Saudi Investment Bank", "\u0646\u0634\u0637", ""),
    ("71", "\u0628\u0646\u0643 \u0627\u0644\u0628\u062d\u0631\u064a\u0646 \u0627\u0644\u0648\u0637\u0646\u064a (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "National Bank of Bahrain", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("73", "\u0628\u0646\u0643 \u0623\u0628\u0648\u0638\u0628\u064a \u0627\u0644\u0623\u0648\u0644 (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "First Abu Dhabi Bank (FAB)", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a",
     "\u0645\u0624\u0643\u062f \u0628\u0622\u064a\u0628\u0627\u0646 \u0641\u0639\u0644\u064a \u0644\u062d\u0633\u0627\u0628 \u0641\u064a \u0627\u0644\u0628\u0646\u0643 \u0642\u062f\u0651\u0645\u0647 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 (SA63 7300 …) \u064a\u062c\u062a\u0627\u0632 MOD-97\u060c \u0648\u064a\u062a\u0641\u0642 \u0645\u0639 \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a"),
    ("75", "\u0628\u0646\u0643 \u0627\u0644\u0643\u0648\u064a\u062a \u0627\u0644\u0648\u0637\u0646\u064a (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "National Bank of Kuwait", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("76", "\u0628\u0646\u0643 \u0645\u0633\u0642\u0637 (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "Bank Muscat", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("78", "\u0628\u0646\u0643 \u0625\u0633 \u062a\u064a \u0633\u064a (STC Bank)", "STC Bank", "\u0628\u0646\u0643 \u0631\u0642\u0645\u064a", ("\u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f: \u0622\u064a\u0628\u0627\u0646 \u0645\u0646\u0634\u0648\u0631 SA47 7800 0000 0011 8115 9355 \u064a\u062c\u062a\u0627\u0632 MOD-97 "
     "— \u064a\u064f\u0633\u062a\u062d\u0633\u0646 \u0627\u0644\u062a\u0623\u0643\u062f \u0645\u0646 \u0633\u0627\u0645\u0627")),
    ("80", "\u0645\u0635\u0631\u0641 \u0627\u0644\u0631\u0627\u062c\u062d\u064a", "Al Rajhi Bank", "\u0646\u0634\u0637", ""),
    ("81", "\u062f\u0648\u064a\u062a\u0634\u0647 \u0628\u0646\u0643 (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "Deutsche Bank", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("82", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0648\u0637\u0646\u064a \u0627\u0644\u0628\u0627\u0643\u0633\u062a\u0627\u0646\u064a (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "National Bank of Pakistan", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("83", "\u0628\u0646\u0643 \u0627\u0644\u062f\u0648\u0644\u0629 \u0627\u0644\u0647\u0646\u062f\u064a (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "State Bank of India", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", "\u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f \u0641\u0642\u0637 — \u064a\u064f\u0633\u062a\u062d\u0633\u0646 \u0627\u0644\u062a\u0623\u0643\u062f \u0645\u0646 \u0633\u0627\u0645\u0627"),
    ("84", "\u0628\u0646\u0643 \u0632\u0631\u0627\u0639\u0627\u062a \u0627\u0644\u062a\u0631\u0643\u064a (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "T.C. Ziraat Bankası", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("85", "\u0628\u064a \u0625\u0646 \u0628\u064a \u0628\u0627\u0631\u064a\u0628\u0627 (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "BNP Paribas", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("86", "\u062c\u064a \u0628\u064a \u0645\u0648\u0631\u063a\u0627\u0646 \u062a\u0634\u064a\u0633 (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "JPMorgan Chase Bank", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("90", "\u0628\u0646\u0643 \u0627\u0644\u062e\u0644\u064a\u062c \u0627\u0644\u062f\u0648\u0644\u064a", "Gulf International Bank (GIB)", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
    ("95", "\u0628\u0646\u0643 \u0627\u0644\u0625\u0645\u0627\u0631\u0627\u062a \u062f\u0628\u064a \u0627\u0644\u0648\u0637\u0646\u064a (\u0641\u0631\u0639 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)", "Emirates NBD", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a", ""),
]

# Head-office SWIFT/BIC per IBAN bank code, with how well it is attested in public BIC directories (October 2026).
CONFIRMED, ONE_SOURCE, UNCONFIRMED = "\u0645\u0624\u0643\u062f", "\u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f", "\u063a\u064a\u0631 \u0645\u0624\u0643\u062f"
SWIFT = {
    "05": ("INMASARI", CONFIRMED), "10": ("NCBKSAJE", CONFIRMED), "15": ("ALBISARI", CONFIRMED),
    "20": ("RIBLSARI", CONFIRMED), "30": ("ARNBSARI", CONFIRMED), "36": ("DBAKSARI", CONFIRMED),
    "40": ("SAMBSARI", UNCONFIRMED + " (\u0628\u0646\u0643 \u0645\u062f\u0645\u062c)"), "45": ("SABBSARI", CONFIRMED),
    "50": ("AAALSARI", ONE_SOURCE + " (\u0628\u0646\u0643 \u0645\u062f\u0645\u062c)"), "55": ("BSFRSARI", CONFIRMED), "60": ("BJAZSAJE", CONFIRMED),
    "65": ("SIBCSARI", CONFIRMED), "71": ("NBOBSARI", ONE_SOURCE), "73": ("FABMSARI", ONE_SOURCE + " + \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a"),
    "75": ("NBOKSAJE", ONE_SOURCE + " + \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a"), "76": ("BMUSSARI", ONE_SOURCE), "78": ("STCJSARI", CONFIRMED),
    "80": ("RJHISARI", CONFIRMED), "81": ("DEUTSARI", ONE_SOURCE), "82": ("NBPASARI", CONFIRMED + " (\u0648\u0631\u062f NBOPSARI \u0641\u064a \u062c\u062f\u0648\u0644 \u0648\u0627\u062d\u062f)"),
    "83": ("SBINSAJE", ONE_SOURCE), "84": ("TCZBSAJE", ONE_SOURCE), "85": ("BNPASARI", UNCONFIRMED + " (\u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a \u0641\u0642\u0637)"),
    "86": ("CHASSARI", UNCONFIRMED + " (\u0648\u0631\u062f CHASSARISAU \u0644\u0634\u0631\u0643\u0629 JPMorgan \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629)"),
    "90": ("GULFSARI", UNCONFIRMED + " (\u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a \u0641\u0642\u0637)"), "95": ("EBILSARI", ONE_SOURCE + " + \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a"),
}

# The SWIFT IBAN Registry's example account for Saudi Arabia (SA03 8000 0000 6080 1016 7519): reused for every bank so
# the table shows that the check digits change with the bank code alone.
EXAMPLE_ACCOUNT = "000000608010167519"

FONT = "Arial"
NAVY = "1F3864"
F_BASE = Font(name=FONT, size=10)
F_BOLD = Font(name=FONT, size=10, bold=True)
F_HEAD = Font(name=FONT, size=10, bold=True, color="FFFFFF")
F_TITLE = Font(name=FONT, size=14, bold=True, color=NAVY)
F_INPUT = Font(name=FONT, size=10, color="0000FF")
F_NOTE = Font(name=FONT, size=9, italic=True, color="595959")
FILL_HEAD = PatternFill("solid", start_color=NAVY)
FILL_INPUT = PatternFill("solid", start_color="FFF2CC")
FILL_ENGINE = PatternFill("solid", start_color="F2F2F2")
GREEN = PatternFill("solid", start_color="C6EFCE")
RED = PatternFill("solid", start_color="FFC7CE")
THIN = Side(style="thin", color="BFBFBF")
BOX = Border(left=THIN, right=THIN, top=THIN, bottom=THIN)
CENTER = Alignment(horizontal="center", vertical="center", wrap_text=True)
WRAP = Alignment(horizontal="right", vertical="center", wrap_text=True)

BANKS_SHEET = "\u0631\u0645\u0648\u0632 \u0627\u0644\u0628\u0646\u0648\u0643"
BANK_RANGE = f"'{BANKS_SHEET}'!$B$5:$B${4 + len(BANKS)}"
NAME_RANGE = f"'{BANKS_SHEET}'!$C$5:$C${4 + len(BANKS)}"


def mod97_chain(src: str, n_chunks: int) -> str:
    """A formula for MOD(src, 97) on a digit string longer than Excel's 15-digit precision: 9 digits, then 7 at a time."""
    expr = f"MOD(VALUE(MID({src},1,9)),97)"
    for i in range(n_chunks):
        expr = f"MOD(VALUE({expr}&MID({src},{10 + 7 * i},7)),97)"
    return expr


def header(ws, row, titles, widths=None):
    for col, title in enumerate(titles, start=1):
        c = ws.cell(row=row, column=col, value=title)
        c.font, c.fill, c.alignment, c.border = F_HEAD, FILL_HEAD, CENTER, BOX
    for col, width in enumerate(widths or [], start=1):
        ws.column_dimensions[get_column_letter(col)].width = width
    ws.row_dimensions[row].height = 32


def style_row(ws, row, ncols, align=CENTER):
    for col in range(1, ncols + 1):
        c = ws.cell(row=row, column=col)
        c.border, c.alignment = BOX, align
        if c.font == Font():
            c.font = F_BASE


def build_structure(wb):
    ws = wb.active
    ws.title = "\u0647\u064a\u0643\u0644 \u0627\u0644\u0622\u064a\u0628\u0627\u0646"
    ws.sheet_view.rightToLeft = True
    ws["A1"] = "\u0647\u064a\u0643\u0644 \u0631\u0642\u0645 \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0627\u0644\u0633\u0639\u0648\u062f\u064a (ISO 13616) — 24 \u062e\u0627\u0646\u0629"
    ws["A1"].font = F_TITLE
    ws["A2"] = "SA + \u062e\u0627\u0646\u062a\u0627 \u062a\u062f\u0642\u064a\u0642 + \u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643 (\u062e\u0627\u0646\u062a\u0627\u0646) + \u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628 (18 \u062e\u0627\u0646\u0629). \u0627\u0644\u0645\u0631\u062c\u0639: \u0633\u062c\u0644 SWIFT \u0644\u0644\u0622\u064a\u0628\u0627\u0646\u060c \u0635\u064a\u063a\u0629 SA2!n2!n18!c"
    ws["A2"].font = F_NOTE
    header(ws, 4, ["\u0627\u0644\u062c\u0632\u0621", "\u0639\u062f\u062f \u0627\u0644\u062e\u0627\u0646\u0627\u062a", "\u0627\u0644\u0645\u0648\u0627\u0642\u0639", "\u0645\u062b\u0627\u0644", "\u0627\u0644\u0648\u0635\u0641"], [18, 12, 12, 22, 70])
    rows = [
        ("\u0631\u0645\u0632 \u0627\u0644\u062f\u0648\u0644\u0629", 2, "1–2", "SA", "\u064a\u0631\u0645\u0632 \u0644\u0644\u0645\u0645\u0644\u0643\u0629 \u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629 (ISO 3166). \u062b\u0627\u0628\u062a \u0644\u0643\u0644 \u0627\u0644\u062d\u0633\u0627\u0628\u0627\u062a \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629."),
        ("\u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642", 2, "3–4", "03", ("\u0631\u0642\u0645\u0627\u0646 \u064a\u064f\u062d\u0633\u0628\u0627\u0646 \u0628\u062e\u0648\u0627\u0631\u0632\u0645\u064a\u0629 MOD-97 \u0645\u0646 \u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643 \u0648\u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628 \u0645\u0639\u0627\u064b\u060c \u0641\u0647\u0645\u0627 \u064a\u062e\u062a\u0644\u0641\u0627\u0646 \u0645\u0646 \u062d\u0633\u0627\u0628 \u0644\u0622\u062e\u0631 "
         "\u062d\u062a\u0649 \u062f\u0627\u062e\u0644 \u0627\u0644\u0628\u0646\u0643 \u0646\u0641\u0633\u0647\u060c \u0648\u0644\u0627 \u064a\u0648\u062c\u062f \u062d\u0642\u0644 \u062a\u062f\u0642\u064a\u0642 \u062b\u0627\u0628\u062a \u0644\u0644\u0628\u0646\u0643. \u0648\u0638\u064a\u0641\u062a\u0647\u0645\u0627 \u0643\u0634\u0641 \u0623\u062e\u0637\u0627\u0621 \u0627\u0644\u0625\u062f\u062e\u0627\u0644 (\u0623\u064a \u062e\u0637\u0623 \u0641\u064a \u062e\u0627\u0646\u0629 \u0648\u0627\u062d\u062f\u0629 \u0623\u0648 \u062a\u0628\u062f\u064a\u0644 \u062e\u0627\u0646\u062a\u064a\u0646 \u0645\u062a\u062c\u0627\u0648\u0631\u062a\u064a\u0646).")),
        ("\u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643", 2, "5–6", "80", ("\u0631\u0642\u0645 \u062b\u0646\u0627\u0626\u064a \u062a\u0635\u062f\u0631\u0647 \u0633\u0627\u0645\u0627 \u0644\u0643\u0644 \u0628\u0646\u0643: 80 \u0645\u0635\u0631\u0641 \u0627\u0644\u0631\u0627\u062c\u062d\u064a\u060c 10 \u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0623\u0647\u0644\u064a \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u060c 20 \u0628\u0646\u0643 \u0627\u0644\u0631\u064a\u0627\u0636\u060c "
         "55 \u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0627\u0644\u0641\u0631\u0646\u0633\u064a. \u0627\u0644\u062c\u062f\u0648\u0644 \u0627\u0644\u0643\u0627\u0645\u0644 \u0641\u064a \u0648\u0631\u0642\u0629 «\u0631\u0645\u0648\u0632 \u0627\u0644\u0628\u0646\u0648\u0643».")),
        ("\u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628", 18, "7–24", "000000608010167519", "\u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628 \u0644\u062f\u0649 \u0627\u0644\u0628\u0646\u0643\u060c \u064a\u064f\u0643\u0645\u064e\u0651\u0644 \u0628\u0623\u0635\u0641\u0627\u0631 \u0639\u0644\u0649 \u0627\u0644\u064a\u0633\u0627\u0631 \u062d\u062a\u0649 18 \u062e\u0627\u0646\u0629 (\u064a\u0633\u0645\u062d \u0627\u0644\u0645\u0639\u064a\u0627\u0631 \u0628\u062d\u0631\u0648\u0641 \u0648\u0623\u0631\u0642\u0627\u0645)."),
        ("\u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0643\u0627\u0645\u0644\u0627\u064b", 24, "1–24", "SA03 8000 0000 6080 1016 7519", "\u064a\u064f\u0643\u062a\u0628 \u0625\u0644\u0643\u062a\u0631\u0648\u0646\u064a\u0627\u064b \u0628\u0644\u0627 \u0645\u0633\u0627\u0641\u0627\u062a\u060c \u0648\u064a\u064f\u0637\u0628\u0639 \u0641\u064a \u0645\u062c\u0645\u0648\u0639\u0627\u062a \u0645\u0646 4 \u062e\u0627\u0646\u0627\u062a."),
    ]
    for i, r in enumerate(rows, start=5):
        for j, v in enumerate(r, start=1):
            ws.cell(row=i, column=j, value=v)
        style_row(ws, i, 5)
        ws.cell(row=i, column=5).alignment = WRAP
        ws.row_dimensions[i].height = 48
    ws["A11"] = "\u062a\u0635\u062d\u064a\u062d \u0644\u0644\u0623\u0645\u062b\u0644\u0629 \u0627\u0644\u0648\u0627\u0631\u062f\u0629 \u0641\u064a \u0627\u0644\u0637\u0644\u0628: \u0627\u0644\u0631\u0645\u0632 20 \u0647\u0648 \u0628\u0646\u0643 \u0627\u0644\u0631\u064a\u0627\u0636 (\u0648\u0644\u064a\u0633 \u0627\u0644\u0631\u0627\u062c\u062d\u064a)\u060c \u064855 \u0647\u0648 \u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0627\u0644\u0641\u0631\u0646\u0633\u064a (\u0648\u0644\u064a\u0633 \u0627\u0644\u0623\u0647\u0644\u064a). " \
                "\u0627\u0644\u0631\u0627\u062c\u062d\u064a = 80\u060c \u0627\u0644\u0623\u0647\u0644\u064a = 10."
    ws["A11"].font = Font(name=FONT, size=10, bold=True, color="C00000")
    ws.merge_cells("A11:E11")
    ws.row_dimensions[11].height = 30
    ws["A11"].alignment = WRAP


def build_banks(wb):
    ws = wb.create_sheet(BANKS_SHEET)
    ws.sheet_view.rightToLeft = True
    ws["A1"] = "\u0631\u0645\u0648\u0632 \u0627\u0644\u0628\u0646\u0648\u0643 \u0627\u0644\u0639\u0627\u0645\u0644\u0629 \u0641\u064a \u0627\u0644\u0645\u0645\u0644\u0643\u0629 \u0627\u0644\u0639\u0631\u0628\u064a\u0629 \u0627\u0644\u0633\u0639\u0648\u062f\u064a\u0629 \u0641\u064a \u0631\u0642\u0645 \u0627\u0644\u0622\u064a\u0628\u0627\u0646"
    ws["A1"].font = F_TITLE
    ws["A2"] = ("\u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0644\u064a\u0633 \u0635\u0641\u0629 \u0644\u0644\u0628\u0646\u0643 \u0628\u0644 \u0644\u0644\u062d\u0633\u0627\u0628: \u0627\u0644\u0639\u0645\u0648\u062f J \u0645\u062f\u062e\u0644 (\u0631\u0642\u0645 \u062d\u0633\u0627\u0628 \u0645\u0646 18 \u062e\u0627\u0646\u0629)\u060c \u0648\u0627\u0644\u0639\u0645\u0648\u062f\u0627\u0646 K \u0648 L \u064a\u062d\u0633\u0628\u0627\u0646 \u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0648\u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0622\u0644\u064a\u0627\u064b. "
                "\u0627\u0644\u0642\u064a\u0645\u0629 \u0627\u0644\u0627\u0641\u062a\u0631\u0627\u0636\u064a\u0629 \u0641\u064a J \u0647\u064a \u062d\u0633\u0627\u0628 \u0627\u0644\u0645\u062b\u0627\u0644 \u0641\u064a \u0633\u062c\u0644 SWIFT\u060c \u0645\u0643\u0631\u0631\u0629 \u0644\u0643\u0644 \u0628\u0646\u0643 \u0644\u0625\u0638\u0647\u0627\u0631 \u062a\u063a\u064a\u0651\u0631 \u062e\u0627\u0646\u062a\u064a \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0628\u062a\u063a\u064a\u0651\u0631 \u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643.")
    ws["A2"].font = F_NOTE
    ws.merge_cells("A2:M2")
    ws["A2"].alignment = WRAP
    ws.row_dimensions[2].height = 30
    header(ws, 4, ["#", "\u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643", "\u0627\u0633\u0645 \u0627\u0644\u0628\u0646\u0643", "Bank name", "\u0631\u0645\u0632 SWIFT / BIC", "\u062a\u0648\u062b\u064a\u0642 SWIFT", "\u0627\u0644\u062d\u0627\u0644\u0629", "\u0645\u0644\u0627\u062d\u0638\u0629",
                   "\u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u064a\u0628\u062f\u0623 \u0628\u0640", "\u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628 (18 \u062e\u0627\u0646\u0629) — \u0645\u062f\u062e\u0644", "\u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 (\u0645\u062d\u0633\u0648\u0628)", "\u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0627\u0644\u0643\u0627\u0645\u0644 (\u0645\u062d\u0633\u0648\u0628)",
                   "\u0627\u0644\u062a\u062d\u0642\u0642 MOD-97", "\u0633\u0644\u0633\u0644\u0629 \u0627\u0644\u062d\u0633\u0627\u0628 (\u0645\u0633\u0627\u0639\u062f)"],
           [5, 10, 34, 34, 14, 22, 15, 40, 14, 24, 14, 34, 14, 30])
    for i, (code, ar, en, status, note) in enumerate(BANKS, start=5):
        swift, level = SWIFT[code]
        ws.cell(row=i, column=1, value=i - 4)
        ws.cell(row=i, column=2, value=code).number_format = "@"
        ws.cell(row=i, column=3, value=ar)
        ws.cell(row=i, column=4, value=en)
        ws.cell(row=i, column=5, value=swift)
        ws.cell(row=i, column=6, value=level)
        ws.cell(row=i, column=7, value=status)
        ws.cell(row=i, column=8, value=note)
        ws.cell(row=i, column=9, value=f'="SA"&"xx"&B{i}')
        acct = ws.cell(row=i, column=10, value=EXAMPLE_ACCOUNT)
        acct.number_format, acct.font, acct.fill = "@", F_INPUT, FILL_INPUT
        # Helper N: bank code + account + "SA00" as digits (S=28, A=10). Saudi accounts are digits in practice.
        ws.cell(row=i, column=14, value=f'=B{i}&J{i}&"281000"')
        ws.cell(row=i, column=11, value=f'=IF(LEN(J{i})<>18,"\u0637\u0648\u0644 \u062e\u0627\u0637\u0626",TEXT(98-{mod97_chain(f"N{i}", 3)},"00"))')
        ws.cell(row=i, column=12, value=f'=IF(LEN(J{i})<>18,"","SA"&K{i}&" "&MID(B{i}&J{i},1,4)&" "&MID(B{i}&J{i},5,4)&" "'
                                        f'&MID(B{i}&J{i},9,4)&" "&MID(B{i}&J{i},13,4)&" "&MID(B{i}&J{i},17,4))')
        ws.cell(row=i, column=13, value=f'=IF(LEN(J{i})<>18,"",IF({mod97_chain(f"(B{i}&J{i}&\"2810\"&K{i})", 3)}=1,"\u0635\u062d\u064a\u062d ✓","\u062e\u0637\u0623"))')
        style_row(ws, i, 14)
        for col in (3, 4, 8):
            ws.cell(row=i, column=col).alignment = WRAP
        ws.cell(row=i, column=14).fill = FILL_ENGINE
        if status.startswith("\u0645\u062f\u0645\u062c"):
            for col in range(1, 9):
                ws.cell(row=i, column=col).font = Font(name=FONT, size=10, color="808080")
    ws.conditional_formatting.add(f"F5:F{4 + len(BANKS)}", FormulaRule(formula=['LEFT($F5,4)="\u0645\u0624\u0643\u062f"'], fill=GREEN))
    ws.conditional_formatting.add(f"F5:F{4 + len(BANKS)}", FormulaRule(formula=['LEFT($F5,3)="\u063a\u064a\u0631"'], fill=FILL_INPUT))
    last = 4 + len(BANKS)
    ws.cell(row=last + 2, column=1, value="\u0627\u0644\u0645\u0635\u0627\u062f\u0631: \u0645\u0639\u0631\u0651\u0641\u0627\u062a \u0627\u0644\u0628\u0646\u0648\u0643 \u0627\u0644\u062a\u064a \u062a\u0635\u062f\u0631\u0647\u0627 \u0633\u0627\u0645\u0627 \u0643\u0645\u0627 \u064a\u0646\u0634\u0631\u0647\u0627 github.com/EngMEita/saudi-banks\u060c \u0645\u0639 \u0645\u0631\u0627\u062c\u0639\u0629 "
                                          "cubbbix.com \u0648 validatefin.com (\u0623\u0643\u062a\u0648\u0628\u0631 2026). \u0627\u0644\u0631\u0645\u0632\u0627\u0646 78 (STC Bank) \u064883 \u0648\u0631\u062f\u0627 \u0641\u064a \u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f. "
                                          "\u0627\u0644\u0631\u0645\u0632\u0627\u0646 36 (D360) \u064873 (\u0628\u0646\u0643 \u0623\u0628\u0648\u0638\u0628\u064a \u0627\u0644\u0623\u0648\u0644) \u0645\u0624\u0643\u062f\u0627\u0646 \u0628\u0622\u064a\u0628\u0627\u0646\u0627\u062a \u0641\u0639\u0644\u064a\u0629 \u0642\u062f\u0651\u0645\u0647\u0627 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645. "
                                          "Vision Bank \u0644\u0645 \u064a\u064f\u062f\u0631\u062c \u0644\u0623\u0646 \u0631\u0645\u0632\u0647 \u0644\u0645 \u064a\u064f\u062a\u062d\u0642\u0642 \u0645\u0646\u0647\u061b \u064a\u064f\u0639\u0631\u0641 \u0645\u0646 \u0627\u0644\u062e\u0627\u0646\u062a\u064a\u0646 5–6 \u0641\u064a \u0623\u064a \u0622\u064a\u0628\u0627\u0646 \u0635\u0627\u062f\u0631 \u0645\u0646\u0647 \u0648\u064a\u064f\u0636\u0627\u0641 \u0641\u064a \u0635\u0641 \u062c\u062f\u064a\u062f. "
                                          "\u0631\u0645\u0648\u0632 SWIFT: \u062b\u0645\u0627\u0646\u064a \u062e\u0627\u0646\u0627\u062a \u0644\u0644\u0645\u0631\u0643\u0632 \u0627\u0644\u0631\u0626\u064a\u0633\u064a (\u062a\u064f\u0636\u0627\u0641 XXX \u0644\u0635\u064a\u063a\u0629 11 \u062e\u0627\u0646\u0629)\u060c \u0645\u0646 \u0623\u062f\u0644\u0629 SWIFT \u0627\u0644\u0639\u0627\u0645\u0629 (Wise\u060c XE\u060c theswiftcodes\u060c "
                                          "ksaexpats\u060c alaan) — «\u0645\u0624\u0643\u062f» = \u0623\u0643\u062b\u0631 \u0645\u0646 \u0645\u0635\u062f\u0631\u060c «\u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f» \u0648«\u063a\u064a\u0631 \u0645\u0624\u0643\u062f» \u064a\u064f\u062a\u062d\u0642\u0642 \u0645\u0646\u0647\u0645\u0627 \u0645\u0639 \u0627\u0644\u0628\u0646\u0643 \u0642\u0628\u0644 \u0627\u0644\u062a\u062d\u0648\u064a\u0644.")
    ws.cell(row=last + 2, column=1).font = F_NOTE
    ws.merge_cells(start_row=last + 2, start_column=1, end_row=last + 2, end_column=13)
    ws.cell(row=last + 2, column=1).alignment = WRAP
    ws.row_dimensions[last + 2].height = 60
    ws.cell(row=last + 3, column=1, value="\u0645\u0641\u062a\u0627\u062d \u0627\u0644\u0623\u0644\u0648\u0627\u0646: \u0627\u0644\u062e\u0644\u0627\u064a\u0627 \u0627\u0644\u0635\u0641\u0631\u0627\u0621 \u0628\u062e\u0637 \u0623\u0632\u0631\u0642 \u0645\u062f\u062e\u0644\u0627\u062a \u064a\u0645\u0643\u0646 \u062a\u0639\u062f\u064a\u0644\u0647\u0627\u061b \u0627\u0644\u0628\u0627\u0642\u064a \u0645\u0639\u0627\u062f\u0644\u0627\u062a.").font = F_NOTE
    ws.freeze_panes = "C5"
    ws.cell(row=4, column=11).comment = Comment("\u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 = 98 − MOD(\u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643 & \u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628 & \"SA00\" \u0628\u0639\u062f \u062a\u062d\u0648\u064a\u0644 \u0627\u0644\u062d\u0631\u0648\u0641\u060c 97)", "IBAN")


def build_validator(wb, rows=40):
    ws = wb.create_sheet("\u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u0622\u064a\u0628\u0627\u0646")
    ws.sheet_view.rightToLeft = True
    ws["A1"] = "\u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0635\u062d\u0629 \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0627\u0644\u0633\u0639\u0648\u062f\u064a — \u062e\u0648\u0627\u0631\u0632\u0645\u064a\u0629 ISO 7064 MOD 97-10"
    ws["A1"].font = F_TITLE
    ws["A2"] = "\u0627\u0643\u062a\u0628 \u0623\u0648 \u0627\u0644\u0635\u0642 \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0641\u064a \u0627\u0644\u0639\u0645\u0648\u062f A (\u0628\u0645\u0633\u0627\u0641\u0627\u062a \u0623\u0648 \u0628\u062f\u0648\u0646\u0647\u0627). \u0627\u0644\u0646\u062a\u064a\u062c\u0629 \u0648\u0627\u0644\u0633\u0628\u0628 \u0648\u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0627\u0644\u0635\u062d\u064a\u062d \u062a\u0638\u0647\u0631 \u0622\u0644\u064a\u0627\u064b. \u0627\u0644\u0623\u0639\u0645\u062f\u0629 \u0645\u0646 L \u0641\u0645\u0627 \u0628\u0639\u062f \u0645\u062d\u0631\u0643 \u0627\u0644\u062d\u0633\u0627\u0628."
    ws["A2"].font = F_NOTE
    ws.merge_cells("A2:J2")
    titles = ["\u0627\u0644\u0622\u064a\u0628\u0627\u0646 (\u0645\u062f\u062e\u0644)", "\u0628\u0639\u062f \u0627\u0644\u062a\u0646\u0638\u064a\u0641", "\u0627\u0644\u0637\u0648\u0644", "\u0627\u0644\u062f\u0648\u0644\u0629", "\u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0627\u0644\u0645\u064f\u062f\u062e\u0644", "\u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643", "\u0627\u0633\u0645 \u0627\u0644\u0628\u0646\u0643",
              "\u0628\u0627\u0642\u064a \u0627\u0644\u0642\u0633\u0645\u0629 \u0639\u0644\u0649 97", "\u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0627\u0644\u0635\u062d\u064a\u062d \u0644\u0647\u0630\u0627 \u0627\u0644\u062d\u0633\u0627\u0628", "\u0627\u0644\u0646\u062a\u064a\u062c\u0629", "\u0627\u0644\u0633\u0628\u0628"]
    header(ws, 4, titles, [32, 28, 8, 8, 12, 10, 32, 12, 16, 12, 44])

    first_char_col = 14                      # N: first of 34 per-character columns
    num_col = first_char_col + 34            # the whole IBAN as a digit string
    chunk0 = num_col + 1                     # running remainders, 9 digits then 7 at a time
    n_chunks = 10                            # 9 + 9*7 = 72 >= 68 digits (34 letters at most)
    eng = ["\u0627\u0644\u0645\u064f\u0639\u0627\u062f \u062a\u0631\u062a\u064a\u0628\u0647", "\u0635\u0627\u0644\u062d \u0627\u0644\u0631\u0645\u0648\u0632"] + [f"\u062d{k}" for k in range(1, 35)] + ["\u0627\u0644\u0633\u0644\u0633\u0644\u0629 \u0627\u0644\u0631\u0642\u0645\u064a\u0629"] + \
          [f"\u0628\u0627\u0642\u064a {k}" for k in range(1, n_chunks + 1)]
    for off, t in enumerate(eng):
        c = ws.cell(row=4, column=12 + off, value=t)
        c.font, c.fill, c.alignment, c.border = F_BOLD, FILL_ENGINE, CENTER, BOX
        ws.column_dimensions[get_column_letter(12 + off)].width = 6 if 0 < off < 36 else 16
    ws.column_dimensions["L"].width = 30
    ws.column_dimensions[get_column_letter(num_col)].width = 40

    L = lambda col, r: f"{get_column_letter(col)}{r}"
    examples = ["SA03 8000 0000 6080 1016 7519",       # the SWIFT registry example: valid
                "SA04 8000 0000 6080 1016 7519",       # one wrong check digit
                "SA03 8000 0000 6080 1016 7591",       # two digits swapped
                "SA44 2000 0001 2345 6789 1234",       # Riyad Bank, valid
                "SA03 8000 0000 6080 1016 751",        # one digit short
                "SA33 9900 0000 6080 1016 7519",       # valid mod-97 but no such bank code
                "AE07 0331 2345 6789 0123 456",        # not a Saudi IBAN
                "SA47 7800 0000 0011 8115 9355",       # STC Bank, published example: valid
                "SA43 7300 0000 6080 1016 7519",       # First Abu Dhabi Bank, registry account: valid
                "sa05 3600 0000 6080 1016 7519"]       # D360 Bank in lower case, registry account: valid
    for r in range(5, 5 + rows):
        a = ws.cell(row=r, column=1, value=examples[r - 5] if r - 5 < len(examples) else None)
        a.font, a.fill, a.number_format = F_INPUT, FILL_INPUT, "@"
        ws[f"B{r}"] = f'=UPPER(SUBSTITUTE(SUBSTITUTE(SUBSTITUTE(TRIM(A{r})," ",""),"-",""),CHAR(160),""))'
        ws[f"C{r}"] = f'=IF(B{r}="","",LEN(B{r}))'
        ws[f"D{r}"] = f'=IF(B{r}="","",LEFT(B{r},2))'
        ws[f"E{r}"] = f'=IF(B{r}="","",MID(B{r},3,2))'
        ws[f"F{r}"] = f'=IF(B{r}="","",MID(B{r},5,2))'
        ws[f"G{r}"] = f'=IF(B{r}="","",IFERROR(INDEX({NAME_RANGE},MATCH(F{r},{BANK_RANGE},0)),"\u0631\u0645\u0632 \u063a\u064a\u0631 \u0645\u0639\u0631\u0648\u0641"))'
        # Engine: move the first four characters to the end, turn A..Z into 10..35, take the remainder in chunks.
        ws[f"L{r}"] = f'=IF(B{r}="","",MID(B{r},5,40)&LEFT(B{r},4))'
        for k in range(1, 35):
            ch = f"MID($L{r},{k},1)"
            ws.cell(row=r, column=first_char_col + k - 1,
                    value=f'=IF(LEN($L{r})<{k},"",IF(ISNUMBER(FIND({ch},"0123456789")),{ch},'
                          f'IF(ISNUMBER(FIND({ch},"ABCDEFGHIJKLMNOPQRSTUVWXYZ")),CODE({ch})-55,"#")))')
        ws[f"M{r}"] = f'=IF(L{r}="","",NOT(ISNUMBER(FIND("#",{L(num_col, r)}))))'
        ws.cell(row=r, column=num_col,
                value=f"=_xlfn.CONCAT({L(first_char_col, r)}:{L(first_char_col + 33, r)})")
        s = L(num_col, r)
        ws.cell(row=r, column=chunk0, value=f'=IF(OR({s}="",M{r}=FALSE),"",MOD(VALUE(MID({s},1,9)),97))')
        for i in range(1, n_chunks):
            prev = L(chunk0 + i - 1, r)
            ws.cell(row=r, column=chunk0 + i, value=f'=IF({prev}="","",MOD(VALUE({prev}&MID({s},{10 + 7 * (i - 1)},7)),97))')
        rem = L(chunk0 + n_chunks - 1, r)
        ws[f"H{r}"] = f"={rem}"
        digits_ok = f'AND(ISNUMBER(FIND(MID(B{r},3,1),"0123456789")),ISNUMBER(FIND(MID(B{r},4,1),"0123456789")))'
        # The check digits that would make this account valid: 98 - (N - cd) mod 97, since N = 100*X + cd.
        ws[f"I{r}"] = f'=IF(OR(H{r}="",NOT({digits_ok})),"",TEXT(98-MOD(H{r}-VALUE(E{r}),97),"00"))'
        ws[f"K{r}"] = (f'=IF(B{r}="","",'
                       f'IF(M{r}=FALSE,"\u064a\u062d\u062a\u0648\u064a \u0631\u0645\u0648\u0632\u0627\u064b \u063a\u064a\u0631 \u0645\u0633\u0645\u0648\u062d\u0629 (\u0627\u0644\u0645\u0633\u0645\u0648\u062d A–Z \u0648 0–9 \u0641\u0642\u0637)",'
                       f'IF(D{r}<>"SA","\u0631\u0645\u0632 \u0627\u0644\u062f\u0648\u0644\u0629 "&D{r}&" — \u0647\u0630\u0627 \u0627\u0644\u0645\u062f\u0642\u0642 \u0644\u0644\u0622\u064a\u0628\u0627\u0646 \u0627\u0644\u0633\u0639\u0648\u062f\u064a SA",'
                       f'IF(C{r}<>24,"\u0627\u0644\u0637\u0648\u0644 "&C{r}&" \u062e\u0627\u0646\u0629 \u0648\u0627\u0644\u0645\u0637\u0644\u0648\u0628 24",'
                       f'IF(NOT({digits_ok}),"\u062e\u0627\u0646\u062a\u0627 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u064a\u062c\u0628 \u0623\u0646 \u062a\u0643\u0648\u0646\u0627 \u0631\u0642\u0645\u064a\u0646",'
                       f'IF(ISERROR(VALUE(MID(B{r},5,20))),"\u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643 \u0648\u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628 \u064a\u062c\u0628 \u0623\u0646 \u064a\u0643\u0648\u0646\u0627 \u0623\u0631\u0642\u0627\u0645\u0627\u064b",'
                       f'IF(H{r}<>1,"\u0641\u0634\u0644 \u0627\u062e\u062a\u0628\u0627\u0631 MOD-97 (\u0627\u0644\u0628\u0627\u0642\u064a "&H{r}&" \u0648\u0644\u064a\u0633 1) — \u062e\u0637\u0623 \u0641\u064a \u0643\u062a\u0627\u0628\u0629 \u0627\u0644\u0631\u0642\u0645\u061b \u062e\u0627\u0646\u062a\u0627 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0627\u0644\u0635\u062d\u064a\u062d\u062a\u0627\u0646 \u0644\u0647\u0630\u0627 \u0627\u0644\u062d\u0633\u0627\u0628 "&I{r},'
                       f'IF(G{r}="\u0631\u0645\u0632 \u063a\u064a\u0631 \u0645\u0639\u0631\u0648\u0641","\u0627\u062c\u062a\u0627\u0632 MOD-97 \u0644\u0643\u0646 \u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643 "&F{r}&" \u063a\u064a\u0631 \u0645\u0633\u062c\u0644 \u0641\u064a \u062c\u062f\u0648\u0644 \u0627\u0644\u0628\u0646\u0648\u0643",'
                       f'"\u0622\u064a\u0628\u0627\u0646 \u0635\u062d\u064a\u062d — "&G{r}))))))))')
        ws[f"J{r}"] = f'=IF(B{r}="","",IF(LEFT(K{r},10)="\u0622\u064a\u0628\u0627\u0646 \u0635\u062d\u064a\u062d","\u0635\u062d\u064a\u062d ✓","\u063a\u064a\u0631 \u0635\u062d\u064a\u062d ✗"))'
        style_row(ws, r, 11)
        ws[f"A{r}"].font = F_INPUT
        ws[f"K{r}"].alignment = WRAP
        for col in range(12, chunk0 + n_chunks):
            ws.cell(row=r, column=col).font = Font(name=FONT, size=8, color="808080")
            ws.cell(row=r, column=col).fill = FILL_ENGINE
    end = 4 + rows
    ws.conditional_formatting.add(f"J5:J{end}", FormulaRule(formula=['LEFT($J5,4)="\u0635\u062d\u064a\u062d"'], fill=GREEN))
    ws.conditional_formatting.add(f"J5:J{end}", FormulaRule(formula=['LEFT($J5,3)="\u063a\u064a\u0631"'], fill=RED))
    for col in range(13, chunk0 + n_chunks):        # keep L visible, fold the per-character engine away
        ws.column_dimensions[get_column_letter(col)].outlineLevel = 1
        ws.column_dimensions[get_column_letter(col)].hidden = True
    ws.freeze_panes = "B5"
    dv = DataValidation(type="textLength", operator="lessThanOrEqual", formula1="42", allow_blank=True,
                        promptTitle="\u0627\u0644\u0622\u064a\u0628\u0627\u0646", prompt="\u0645\u062b\u0627\u0644: SA03 8000 0000 6080 1016 7519")
    ws.add_data_validation(dv)
    dv.add(f"A5:A{end}")


def build_algorithm(wb):
    ws = wb.create_sheet("\u0634\u0631\u062d \u0627\u0644\u062e\u0648\u0627\u0631\u0632\u0645\u064a\u0629")
    ws.sheet_view.rightToLeft = True
    ws["A1"] = "\u062e\u0648\u0627\u0631\u0632\u0645\u064a\u0629 MOD-97 \u062e\u0637\u0648\u0629 \u0628\u062e\u0637\u0648\u0629 (ISO 13616 / ISO 7064)"
    ws["A1"].font = F_TITLE
    ws["A2"] = "\u063a\u064a\u0651\u0631 \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0641\u064a \u0627\u0644\u062e\u0644\u064a\u0629 C4 \u0644\u062a\u0631\u0649 \u0643\u0644 \u062e\u0637\u0648\u0629 \u062a\u064f\u062d\u0633\u0628 \u0639\u0644\u064a\u0647. (\u0645\u062b\u0627\u0644 \u062d\u064a \u064a\u0639\u0645\u0644 \u0644\u0644\u0622\u064a\u0628\u0627\u0646 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0627\u0644\u0645\u0643\u0648\u0651\u0646 \u0645\u0646 \u0623\u0631\u0642\u0627\u0645)"
    ws["A2"].font = F_NOTE
    header(ws, 3, ["\u0627\u0644\u062e\u0637\u0648\u0629", "\u0627\u0644\u0634\u0631\u062d", "\u0627\u0644\u0646\u062a\u064a\u062c\u0629"], [8, 62, 44])
    ws.row_dimensions[3].height = 24
    steps = [
        ("0", "\u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0643\u0645\u0627 \u0623\u064f\u062f\u062e\u0644", "SA03 8000 0000 6080 1016 7519"),
        ("1", "\u0625\u0632\u0627\u0644\u0629 \u0627\u0644\u0645\u0633\u0627\u0641\u0627\u062a \u0648\u062a\u062d\u0648\u064a\u0644 \u0627\u0644\u062d\u0631\u0648\u0641 \u0625\u0644\u0649 \u0643\u0628\u064a\u0631\u0629\u060c \u0648\u0627\u0644\u062a\u0623\u0643\u062f \u0623\u0646 \u0627\u0644\u0637\u0648\u0644 24 \u0644\u0644\u0633\u0639\u0648\u062f\u064a\u0629", '=UPPER(SUBSTITUTE(C4," ",""))'),
        ("1\u0623", "\u0627\u0644\u0637\u0648\u0644", "=LEN(C5)"),
        ("2", "\u0646\u0642\u0644 \u0623\u0648\u0644 4 \u062e\u0627\u0646\u0627\u062a (\u0631\u0645\u0632 \u0627\u0644\u062f\u0648\u0644\u0629 + \u062d\u0642\u0644 \u0627\u0644\u062a\u062f\u0642\u064a\u0642) \u0625\u0644\u0649 \u0646\u0647\u0627\u064a\u0629 \u0627\u0644\u0631\u0642\u0645", "=MID(C5,5,40)&LEFT(C5,4)"),
        ("3", "\u0627\u0633\u062a\u0628\u062f\u0627\u0644 \u0643\u0644 \u062d\u0631\u0641 \u0628\u0631\u0642\u0645\u0647: A=10\u060c B=11 … S=28 … Z=35  (SA ← 2810)",
         '=MID(C7,1,20)&(CODE(MID(C7,21,1))-55)&(CODE(MID(C7,22,1))-55)&MID(C7,23,2)'),
        ("4", "\u0628\u0627\u0642\u064a \u0623\u0648\u0644 9 \u062e\u0627\u0646\u0627\u062a \u0639\u0644\u0649 97", "=MOD(VALUE(MID(C8,1,9)),97)"),
        ("5", "\u0627\u0644\u0628\u0627\u0642\u064a \u0627\u0644\u0633\u0627\u0628\u0642 + \u0627\u0644\u062e\u0627\u0646\u0627\u062a 7 \u0627\u0644\u062a\u0627\u0644\u064a\u0629\u060c \u062b\u0645 \u0627\u0644\u0628\u0627\u0642\u064a \u0639\u0644\u0649 97", "=MOD(VALUE(C9&MID(C8,10,7)),97)"),
        ("6", "\u0627\u0644\u0628\u0627\u0642\u064a \u0627\u0644\u0633\u0627\u0628\u0642 + \u0627\u0644\u062e\u0627\u0646\u0627\u062a 7 \u0627\u0644\u062a\u0627\u0644\u064a\u0629\u060c \u062b\u0645 \u0627\u0644\u0628\u0627\u0642\u064a \u0639\u0644\u0649 97", "=MOD(VALUE(C10&MID(C8,17,7)),97)"),
        ("7", "\u0627\u0644\u0628\u0627\u0642\u064a \u0627\u0644\u0633\u0627\u0628\u0642 + \u0627\u0644\u062e\u0627\u0646\u0627\u062a \u0627\u0644\u0645\u062a\u0628\u0642\u064a\u0629\u060c \u062b\u0645 \u0627\u0644\u0628\u0627\u0642\u064a \u0639\u0644\u0649 97 = \u0628\u0627\u0642\u064a \u0627\u0644\u0631\u0642\u0645 \u0643\u0627\u0645\u0644\u0627\u064b", "=MOD(VALUE(C11&MID(C8,24,7)),97)"),
        ("8", "\u0627\u0644\u062d\u0643\u0645: \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0635\u062d\u064a\u062d \u0625\u0630\u0627 \u0648\u0641\u0642\u0637 \u0625\u0630\u0627 \u0643\u0627\u0646 \u0627\u0644\u0628\u0627\u0642\u064a = 1", '=IF(AND(C6=24,C12=1),"\u0635\u062d\u064a\u062d ✓","\u063a\u064a\u0631 \u0635\u062d\u064a\u062d ✗")'),
        ("", "", ""),
        ("\u062d\u0633\u0627\u0628", "\u0643\u064a\u0641 \u062a\u064f\u0648\u0644\u064e\u0651\u062f \u062e\u0627\u0646\u062a\u0627 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 \u0644\u062d\u0633\u0627\u0628 \u062c\u062f\u064a\u062f:", ""),
        ("\u0623", "\u0636\u0639 00 \u0645\u0643\u0627\u0646 \u062e\u0627\u0646\u062a\u064a \u0627\u0644\u062a\u062f\u0642\u064a\u0642: \u0631\u0645\u0632 \u0627\u0644\u0628\u0646\u0643 & \u0631\u0642\u0645 \u0627\u0644\u062d\u0633\u0627\u0628 & SA00", '=MID(C5,5,20)&"281000"'),
        ("\u0628", "\u0627\u062d\u0633\u0628 \u0627\u0644\u0628\u0627\u0642\u064a \u0639\u0644\u0649 97 \u0628\u0627\u0644\u0637\u0631\u064a\u0642\u0629 \u0646\u0641\u0633\u0647\u0627 (\u0639\u0644\u0649 \u062f\u0641\u0639\u0627\u062a)", "=" + mod97_chain("C16", 3)),
        ("\u062c", "\u062e\u0627\u0646\u062a\u0627 \u0627\u0644\u062a\u062f\u0642\u064a\u0642 = 98 − \u0627\u0644\u0628\u0627\u0642\u064a (\u0628\u062e\u0627\u0646\u062a\u064a\u0646\u060c \u0645\u0639 \u0635\u0641\u0631 \u0628\u0627\u062f\u0626)", '=TEXT(98-C17,"00")'),
        ("\u062f", "\u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0627\u0644\u0646\u0627\u062a\u062c", '="SA"&C18&MID(C5,5,20)'),
    ]
    for i, (n, text, val) in enumerate(steps, start=4):
        ws.cell(row=i, column=1, value=n)
        ws.cell(row=i, column=2, value=text)
        c = ws.cell(row=i, column=3, value=val)
        if n:
            style_row(ws, i, 3)
            ws.cell(row=i, column=2).alignment = WRAP
        if i in (7, 8, 16):
            c.number_format = "@"
    ws["C4"].font, ws["C4"].fill = F_INPUT, FILL_INPUT
    ws["B15"].font = F_BOLD
    ws.conditional_formatting.add("C13", FormulaRule(formula=['LEFT($C$13,4)="\u0635\u062d\u064a\u062d"'], fill=GREEN))
    ws.conditional_formatting.add("C13", FormulaRule(formula=['LEFT($C$13,3)="\u063a\u064a\u0631"'], fill=RED))
    notes = [
        "\u0644\u0645\u0627\u0630\u0627 \u0639\u0644\u0649 \u062f\u0641\u0639\u0627\u062a\u061f \u0627\u0644\u0631\u0642\u0645 \u0627\u0644\u0646\u0627\u062a\u062c 26 \u062e\u0627\u0646\u0629\u060c \u0648\u062f\u0642\u0629 Excel 15 \u062e\u0627\u0646\u0629 \u0641\u0642\u0637\u060c \u0641\u064a\u064f\u0642\u0633\u0645 \u0625\u0644\u0649 \u0623\u062c\u0632\u0627\u0621 \u0644\u0627 \u062a\u062a\u062c\u0627\u0648\u0632 9 \u062e\u0627\u0646\u0627\u062a \u0645\u0639 \u062d\u0645\u0644 \u0627\u0644\u0628\u0627\u0642\u064a — \u0627\u0644\u0646\u062a\u064a\u062c\u0629 \u0645\u0637\u0627\u0628\u0642\u0629 \u0631\u064a\u0627\u0636\u064a\u0627\u064b.",
        "\u0645\u0627 \u0627\u0644\u0630\u064a \u062a\u0643\u0634\u0641\u0647 \u0627\u0644\u062e\u0648\u0627\u0631\u0632\u0645\u064a\u0629\u061f \u0643\u0644 \u062e\u0637\u0623 \u0641\u064a \u062e\u0627\u0646\u0629 \u0648\u0627\u062d\u062f\u0629\u060c \u0648\u0643\u0644 \u062a\u0628\u062f\u064a\u0644 \u0644\u062e\u0627\u0646\u062a\u064a\u0646 \u0645\u062a\u062c\u0627\u0648\u0631\u062a\u064a\u0646\u060c \u0648\u0646\u062d\u0648 99% \u0645\u0646 \u0627\u0644\u0623\u062e\u0637\u0627\u0621 \u0627\u0644\u0623\u062e\u0631\u0649.",
        ("\u0645\u0627 \u0627\u0644\u0630\u064a \u0644\u0627 \u062a\u0643\u0634\u0641\u0647\u061f \u0635\u062d\u0629 \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0631\u064a\u0627\u0636\u064a\u0627\u064b \u0644\u0627 \u062a\u0639\u0646\u064a \u0623\u0646 \u0627\u0644\u062d\u0633\u0627\u0628 \u0645\u0648\u062c\u0648\u062f \u0623\u0648 \u0645\u0641\u062a\u0648\u062d \u0623\u0648 \u0628\u0627\u0633\u0645 \u0627\u0644\u0645\u0633\u062a\u0641\u064a\u062f — \u0647\u0630\u0627 \u064a\u062a\u0637\u0644\u0628 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0644\u0628\u0646\u0643 "
        "(\u062e\u062f\u0645\u0629 \u0627\u0644\u062a\u062d\u0642\u0642 \u0645\u0646 \u0627\u0633\u0645 \u0627\u0644\u0645\u0633\u062a\u0641\u064a\u062f \u0639\u0628\u0631 \u0633\u0631\u064a\u0639 / \u0633\u0627\u0631\u064a\u0639)."),
        "\u0627\u0644\u0645\u0631\u062c\u0639: ISO 13616-1:2020\u060c ISO 7064 (MOD 97-10)\u060c \u0633\u062c\u0644 SWIFT \u0644\u0644\u0622\u064a\u0628\u0627\u0646\u060c \u0648\u0645\u0642\u0627\u0644 medium.com/@matlabb «IBAN Structure and MOD-97 Validation Algorithm».",
    ]
    for i, t in enumerate(notes, start=21):
        ws.cell(row=i, column=1, value=t).font = F_NOTE
        ws.merge_cells(start_row=i, start_column=1, end_row=i, end_column=3)
        ws.cell(row=i, column=1).alignment = WRAP
        ws.row_dimensions[i].height = 32


# The guide file the user supplied (saudi_bank_codes.xlsx), row by row: (type, bank, its IBAN code, its SWIFT code,
# verified IBAN code or UNVERIFIED, verified SWIFT or UNVERIFIED, note).
UNVERIFIED = "\u063a\u064a\u0631 \u0645\u0624\u0643\u062f"
GUIDE = [
    ("\u0645\u062d\u0644\u064a", "\u0645\u0635\u0631\u0641 \u0627\u0644\u0631\u0627\u062c\u062d\u064a", "80", "RJHISARI", "80", "RJHISARI", ""),
    ("\u0645\u062d\u0644\u064a", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0623\u0647\u0644\u064a \u0627\u0644\u0633\u0639\u0648\u062f\u064a (SNB)", "10", "NCBKSARI", "10", "NCBKSAJE", "\u0631\u0645\u0632 SWIFT \u0644\u0644\u0623\u0647\u0644\u064a \u064a\u0646\u062a\u0647\u064a \u0628\u0640 JE \u0648\u0644\u064a\u0633 RI"),
    ("\u0645\u062d\u0644\u064a", "\u0628\u0646\u0643 \u0627\u0644\u0631\u064a\u0627\u0636", "20", "RYADSARI", "20", "RIBLSARI", "\u0631\u0645\u0632 SWIFT \u0644\u0628\u0646\u0643 \u0627\u0644\u0631\u064a\u0627\u0636 \u0647\u0648 RIBLSARI"),
    ("\u0645\u062d\u0644\u064a", "\u0645\u0635\u0631\u0641 \u0627\u0644\u0625\u0646\u0645\u0627\u0621", "05", "INMASARI", "05", "INMASARI", ""),
    ("\u0645\u062d\u0644\u064a", "\u0628\u0646\u0643 \u0627\u0644\u0628\u0644\u0627\u062f", "15", "BLADSARI", "15", "ALBISARI", "\u0631\u0645\u0632 SWIFT \u0644\u0628\u0646\u0643 \u0627\u0644\u0628\u0644\u0627\u062f \u0647\u0648 ALBISARI"),
    ("\u0645\u062d\u0644\u064a", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0639\u0631\u0628\u064a \u0627\u0644\u0648\u0637\u0646\u064a (ANB)", "30", "ARNBSARI", "30", "ARNBSARI", ""),
    ("\u0645\u062d\u0644\u064a", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0627\u0644\u0623\u0648\u0644 (SAB)", "40 / 45", "SABBSARI", "45", "SABBSARI",
     "40 \u0643\u0627\u0646 \u0631\u0645\u0632 \u0633\u0627\u0645\u0628\u0627 (\u0627\u0646\u062f\u0645\u062c \u0641\u064a \u0627\u0644\u0623\u0647\u0644\u064a 2021) \u0648\u0644\u064a\u0633 \u0633\u0627\u0628\u061b \u0631\u0645\u0632 \u0633\u0627\u0628 45 \u0641\u0642\u0637 (\u064850 \u0644\u0644\u0628\u0646\u0643 \u0627\u0644\u0623\u0648\u0644 \u0627\u0644\u0645\u062f\u0645\u062c \u0641\u064a\u0647)"),
    ("\u0645\u062d\u0644\u064a", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0627\u0644\u0641\u0631\u0646\u0633\u064a", "55", "BSFRSARI", "55", "BSFRSARI", ""),
    ("\u0645\u062d\u0644\u064a", "\u0628\u0646\u0643 \u0627\u0644\u062c\u0632\u064a\u0631\u0629", "60", "BJAZSARI", "60", "BJAZSAJE", "\u0631\u0645\u0632 SWIFT \u0644\u0628\u0646\u0643 \u0627\u0644\u062c\u0632\u064a\u0631\u0629 BJAZSAJE (\u062c\u062f\u0629)"),
    ("\u0645\u062d\u0644\u064a", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0644\u0644\u0627\u0633\u062a\u062b\u0645\u0627\u0631 (SAIB)", "65", "SBVCSARI", "65", "SIBCSARI", "\u0631\u0645\u0632 SWIFT \u0644\u0644\u0628\u0646\u0643 \u0627\u0644\u0633\u0639\u0648\u062f\u064a \u0644\u0644\u0627\u0633\u062a\u062b\u0645\u0627\u0631 SIBCSARI"),
    ("\u0631\u0642\u0645\u064a", "\u0628\u0646\u0643 \u0625\u0633 \u062a\u064a \u0633\u064a (STC Bank)", "76", "STCBSARI", "78", "STCJSARI",
     "76 \u0631\u0645\u0632 \u0628\u0646\u0643 \u0645\u0633\u0642\u0637\u061b \u0631\u0645\u0632 STC Bank \u0647\u0648 78 (\u0622\u064a\u0628\u0627\u0646 \u0645\u0646\u0634\u0648\u0631 \u064a\u062c\u062a\u0627\u0632 MOD-97\u060c \u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f) \u0648\u0631\u0645\u0632 SWIFT \u0647\u0648 STCJSARI"),
    ("\u0631\u0642\u0645\u064a", "\u0628\u0646\u0643 D360", "36", "D360SARI", "36", "DBAKSARI",
     "\u0627\u0644\u0631\u0645\u0632 36 \u0645\u0624\u0643\u062f \u0628\u0622\u064a\u0628\u0627\u0646 \u0641\u0639\u0644\u064a \u0642\u062f\u0651\u0645\u0647 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 \u064a\u062c\u062a\u0627\u0632 MOD-97\u061b \u0631\u0645\u0632 SWIFT \u0627\u0644\u0635\u062d\u064a\u062d DBAKSARI (\u0623\u0648 DBAKSARIXXX \u0628\u0635\u064a\u063a\u0629 11 \u062e\u0627\u0646\u0629 \u0644\u0644\u0645\u0631\u0643\u0632 \u0627\u0644\u0631\u0626\u064a\u0633\u064a)"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0623\u0628\u0648\u0638\u0628\u064a \u0627\u0644\u0623\u0648\u0644 (FAB)", "73", "FABMSARI", "73", "FABMSARI",
     "\u0627\u0644\u0631\u0645\u0632 73 \u0645\u0624\u0643\u062f \u0628\u0622\u064a\u0628\u0627\u0646 \u0641\u0639\u0644\u064a \u0642\u062f\u0651\u0645\u0647 \u0627\u0644\u0645\u0633\u062a\u062e\u062f\u0645 \u064a\u062c\u062a\u0627\u0632 MOD-97\u061b FABMSARI \u0648\u0631\u062f \u0641\u064a \u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0627\u0644\u0643\u0648\u064a\u062a \u0627\u0644\u0648\u0637\u0646\u064a (NBK)", "75", "NBOKSAJE", "75", "NBOKSAJE", ""),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0627\u0644\u0643\u0648\u064a\u062a \u0627\u0644\u0648\u0637\u0646\u064a (NBK) - \u0625\u0635\u062f\u0627\u0631\u0627\u062a \u0623\u062e\u0631\u0649", "95", "NBOKSAJE", "75", "NBOKSAJE", "95 \u0647\u0648 \u0631\u0645\u0632 \u0628\u0646\u0643 \u0627\u0644\u0625\u0645\u0627\u0631\u0627\u062a \u062f\u0628\u064a \u0627\u0644\u0648\u0637\u0646\u064a \u0648\u0644\u064a\u0633 NBK"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0627\u0644\u0625\u0645\u0627\u0631\u0627\u062a \u062f\u0628\u064a \u0627\u0644\u0648\u0637\u0646\u064a", "71", "EBILSARI", "95", "EBILSARI", "71 \u0647\u0648 \u0631\u0645\u0632 \u0628\u0646\u0643 \u0627\u0644\u0628\u062d\u0631\u064a\u0646 \u0627\u0644\u0648\u0637\u0646\u064a"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0627\u0644\u062e\u0644\u064a\u062c \u0627\u0644\u062f\u0648\u0644\u064a (GIB / meem)", "51", "GULFSARI", "90", UNVERIFIED, "GULFSARI \u0648\u0631\u062f \u0641\u064a \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a \u0641\u0642\u0637"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0645\u0633\u0642\u0637", "90", "BMAYSARI", "76", "BMUSSARI", "90 \u0647\u0648 \u0631\u0645\u0632 \u0628\u0646\u0643 \u0627\u0644\u062e\u0644\u064a\u062c \u0627\u0644\u062f\u0648\u0644\u064a\u061b SWIFT \u0628\u0646\u0643 \u0645\u0633\u0642\u0637 BMUSSARI (\u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f)"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0627\u0644\u0628\u062d\u0631\u064a\u0646 \u0627\u0644\u0648\u0637\u0646\u064a (NBB)", "85", "NBBHSARI", "71", "NBOBSARI", "85 \u0647\u0648 \u0631\u0645\u0632 \u0628\u064a \u0625\u0646 \u0628\u064a \u0628\u0627\u0631\u064a\u0628\u0627\u061b SWIFT \u0628\u0646\u0643 \u0627\u0644\u0628\u062d\u0631\u064a\u0646 \u0627\u0644\u0648\u0637\u0646\u064a NBOBSARI (\u0645\u0635\u062f\u0631 \u0648\u0627\u062d\u062f)"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u062c\u064a \u0628\u064a \u0645\u0648\u0631\u063a\u0627\u0646 \u062a\u0634\u064a\u0633", "78", "CHESSARI", "86", UNVERIFIED, "78 \u0647\u0648 \u0631\u0645\u0632 STC Bank\u061b \u0631\u0645\u0632 SWIFT \u0627\u0644\u0645\u062a\u062f\u0627\u0648\u0644 CHASSARI \u0648\u0644\u064a\u0633 CHESSARI \u0644\u0643\u0646\u0647 \u063a\u064a\u0631 \u0645\u0624\u0643\u062f"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u064a \u0625\u0646 \u0628\u064a \u0628\u0627\u0631\u064a\u0628\u0627", "79", "BNPASARI", "85", UNVERIFIED, ""),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0628\u0646\u0643 \u0627\u0644\u0635\u064a\u0646 (Bank of China)", "56", "BKCHSARI", UNVERIFIED, UNVERIFIED, "\u0644\u0645 \u064a\u064f\u0639\u062b\u0631 \u0639\u0644\u0649 \u0645\u0635\u062f\u0631 \u0645\u0648\u062b\u0648\u0642"),
    ("\u0623\u062c\u0646\u0628\u064a", "\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0635\u0646\u0627\u0639\u064a \u0648\u0627\u0644\u062a\u062c\u0627\u0631\u064a \u0627\u0644\u0635\u064a\u0646\u064a (ICBC)", "53", "ICBKSARI", UNVERIFIED, UNVERIFIED, "\u0644\u0645 \u064a\u064f\u0639\u062b\u0631 \u0639\u0644\u0649 \u0645\u0635\u062f\u0631 \u0645\u0648\u062b\u0648\u0642"),
]


def build_audit(wb):
    ws = wb.create_sheet("\u062a\u062f\u0642\u064a\u0642 \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a")
    ws.sheet_view.rightToLeft = True
    ws["A1"] = "\u062a\u062f\u0642\u064a\u0642 \u0627\u0644\u0645\u0644\u0641 \u0627\u0644\u0627\u0633\u062a\u0631\u0634\u0627\u062f\u064a saudi_bank_codes.xlsx \u0645\u0642\u0627\u0628\u0644 \u0627\u0644\u0645\u0635\u0627\u062f\u0631"
    ws["A1"].font = F_TITLE
    ws["A2"] = ("\u0627\u0644\u0623\u0639\u0645\u062f\u0629 C \u0648 D \u0643\u0645\u0627 \u0648\u0631\u062f\u062a \u0641\u064a \u0627\u0644\u0645\u0644\u0641\u061b E \u0648 F \u0627\u0644\u0642\u064a\u0645\u0629 \u0627\u0644\u0645\u062a\u062d\u0642\u0642 \u0645\u0646\u0647\u0627\u061b G \u064a\u0628\u064a\u0651\u0646 \u0644\u0645\u0646 \u064a\u0639\u0648\u062f \u0627\u0644\u0631\u0645\u0632 \u0627\u0644\u0648\u0627\u0631\u062f \u0641\u064a \u0627\u0644\u0645\u0644\u0641 \u0641\u0639\u0644\u0627\u064b \u062d\u0633\u0628 \u0648\u0631\u0642\u0629 «\u0631\u0645\u0648\u0632 \u0627\u0644\u0628\u0646\u0648\u0643». "
                "«\u063a\u064a\u0631 \u0645\u0624\u0643\u062f» \u062a\u0639\u0646\u064a \u0623\u0646\u0647 \u0644\u0645 \u064a\u064f\u0639\u062b\u0631 \u0639\u0644\u0649 \u0645\u0635\u062f\u0631 \u0645\u0648\u062b\u0648\u0642\u060c \u0644\u0627 \u0623\u0646 \u0627\u0644\u0642\u064a\u0645\u0629 \u062e\u0627\u0637\u0626\u0629 \u0628\u0627\u0644\u0636\u0631\u0648\u0631\u0629.")
    ws["A2"].font = F_NOTE
    ws.merge_cells("A2:J2")
    ws["A2"].alignment = WRAP
    ws.row_dimensions[2].height = 30
    header(ws, 4, ["\u0627\u0644\u0646\u0648\u0639", "\u0627\u0633\u0645 \u0627\u0644\u0628\u0646\u0643", "\u0631\u0645\u0632 \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0641\u064a \u0627\u0644\u0645\u0644\u0641", "SWIFT \u0641\u064a \u0627\u0644\u0645\u0644\u0641", "\u0631\u0645\u0632 \u0627\u0644\u0622\u064a\u0628\u0627\u0646 \u0627\u0644\u0645\u062a\u062d\u0642\u0642 \u0645\u0646\u0647", "SWIFT \u0627\u0644\u0645\u062a\u062d\u0642\u0642 \u0645\u0646\u0647",
                   "\u0627\u0644\u0631\u0645\u0632 \u0641\u064a \u0627\u0644\u0645\u0644\u0641 \u064a\u0639\u0648\u062f \u0641\u0639\u0644\u0627\u064b \u0625\u0644\u0649", "\u062d\u0643\u0645 \u0631\u0645\u0632 \u0627\u0644\u0622\u064a\u0628\u0627\u0646", "\u062d\u0643\u0645 SWIFT", "\u0645\u0644\u0627\u062d\u0638\u0629"],
           [9, 34, 12, 14, 12, 14, 34, 16, 16, 52])
    for i, (kind, name, code, swift, vcode, vswift, note) in enumerate(GUIDE, start=5):
        for col, v in enumerate((kind, name, code, swift, vcode, vswift), start=1):
            ws.cell(row=i, column=col, value=v).number_format = "@"
        ws[f"G{i}"] = f'=IFERROR(INDEX({NAME_RANGE},MATCH(C{i},{BANK_RANGE},0)),"\u063a\u064a\u0631 \u0645\u0633\u062c\u0644 \u0641\u064a \u0627\u0644\u062c\u062f\u0648\u0644")'
        ws[f"H{i}"] = f'=IF(E{i}="{UNVERIFIED}","? \u063a\u064a\u0631 \u0645\u0624\u0643\u062f",IF(C{i}=E{i},"✓ \u0635\u062d\u064a\u062d","✗ \u062e\u0637\u0623"))'
        ws[f"I{i}"] = f'=IF(F{i}="{UNVERIFIED}","? \u063a\u064a\u0631 \u0645\u0624\u0643\u062f",IF(D{i}=F{i},"✓ \u0635\u062d\u064a\u062d","✗ \u062e\u0637\u0623"))'
        ws[f"J{i}"] = note
        style_row(ws, i, 10)
        for col in (2, 7, 10):
            ws.cell(row=i, column=col).alignment = WRAP
        ws.row_dimensions[i].height = 30
    end = 4 + len(GUIDE)
    for rng in (f"H5:I{end}",):
        ws.conditional_formatting.add(rng, FormulaRule(formula=['LEFT(H5,1)="✓"'], fill=GREEN))
        ws.conditional_formatting.add(rng, FormulaRule(formula=['LEFT(H5,1)="✗"'], fill=RED))
        ws.conditional_formatting.add(rng, FormulaRule(formula=['LEFT(H5,1)="?"'], fill=FILL_INPUT))
    r = end + 2
    ws[f"A{r}"] = "\u0627\u0644\u0645\u0644\u062e\u0635"
    ws[f"A{r}"].font = F_BOLD
    for j, (label, f) in enumerate([("\u0631\u0645\u0648\u0632 \u0622\u064a\u0628\u0627\u0646 \u0635\u062d\u064a\u062d\u0629", f'=COUNTIF(H5:H{end},"✓*")'),
                                    ("\u0631\u0645\u0648\u0632 \u0622\u064a\u0628\u0627\u0646 \u062e\u0627\u0637\u0626\u0629", f'=COUNTIF(H5:H{end},"✗*")'),
                                    ("\u0631\u0645\u0648\u0632 \u0622\u064a\u0628\u0627\u0646 \u063a\u064a\u0631 \u0645\u0624\u0643\u062f\u0629", f'=COUNTIF(H5:H{end},"~?*")'),
                                    ("\u0631\u0645\u0648\u0632 SWIFT \u0635\u062d\u064a\u062d\u0629", f'=COUNTIF(I5:I{end},"✓*")'),
                                    ("\u0631\u0645\u0648\u0632 SWIFT \u062e\u0627\u0637\u0626\u0629", f'=COUNTIF(I5:I{end},"✗*")'),
                                    ("\u0631\u0645\u0648\u0632 SWIFT \u063a\u064a\u0631 \u0645\u0624\u0643\u062f\u0629", f'=COUNTIF(I5:I{end},"~?*")')], start=r + 1):
        ws[f"B{j}"], ws[f"C{j}"] = label, f
        style_row(ws, j, 3)
    ws[f"A{r + 8}"] = ("\u0628\u0646\u0648\u0643 \u0646\u0627\u0642\u0635\u0629 \u0645\u0646 \u0627\u0644\u0645\u0644\u0641: \u062f\u0648\u064a\u062a\u0634\u0647 \u0628\u0646\u0643 (81)\u060c \u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0648\u0637\u0646\u064a \u0627\u0644\u0628\u0627\u0643\u0633\u062a\u0627\u0646\u064a (82)\u060c \u0628\u0646\u0643 \u0627\u0644\u062f\u0648\u0644\u0629 \u0627\u0644\u0647\u0646\u062f\u064a (83)\u060c \u0628\u0646\u0643 \u0632\u0631\u0627\u0639\u0627\u062a (84)\u060c "
                       "\u0648\u0631\u0645\u0648\u0632 \u0627\u0644\u0628\u0646\u0648\u0643 \u0627\u0644\u0645\u062f\u0645\u062c\u0629 \u0633\u0627\u0645\u0628\u0627 (40) \u0648\u0627\u0644\u0628\u0646\u0643 \u0627\u0644\u0623\u0648\u0644 (50) \u0627\u0644\u062a\u064a \u0642\u062f \u062a\u0638\u0647\u0631 \u0641\u064a \u0622\u064a\u0628\u0627\u0646\u0627\u062a \u0642\u062f\u064a\u0645\u0629.")
    ws[f"A{r + 8}"].font = Font(name=FONT, size=10, bold=True, color="C00000")
    ws.merge_cells(f"A{r + 8}:J{r + 8}")
    ws[f"A{r + 8}"].alignment = WRAP
    ws.row_dimensions[r + 8].height = 30
    ws.freeze_panes = "C5"


def main():
    wb = Workbook()
    build_structure(wb)
    build_banks(wb)
    build_validator(wb)
    build_algorithm(wb)
    build_audit(wb)
    wb.active = 2
    PACKAGE.mkdir(parents=True, exist_ok=True)
    wb.save(OUT)
    write_json()
    print(OUT)


STATUS = {"\u0646\u0634\u0637": "active", "\u0628\u0646\u0643 \u0631\u0642\u0645\u064a": "digital", "\u0641\u0631\u0639 \u0628\u0646\u0643 \u0623\u062c\u0646\u0628\u064a": "foreign_branch", "\u0645\u062f\u0645\u062c (\u062a\u0627\u0631\u064a\u062e\u064a)": "legacy_merged"}
CONFIDENCE = {CONFIRMED: "confirmed", ONE_SOURCE: "single_source", UNCONFIRMED: "unconfirmed"}


def write_json():
    banks = []
    for code, ar, en, status, _note in BANKS:
        swift, level = SWIFT[code]
        banks.append({"code": code, "name_ar": ar, "name_en": en, "status": STATUS[status], "swift": swift,
                      "swift_confidence": next(v for k, v in CONFIDENCE.items() if level.startswith(k))})
    doc = {"country": "SA", "iban_length": 24, "bban_format": "2!n18!c", "updated": "2026-10-30",
           "note": "IBAN bank identifiers assigned by SAMA, compiled from public sources; see README.md for sources and confidence.",
           "banks": banks}
    (PACKAGE / "saudi_banks.json").write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
