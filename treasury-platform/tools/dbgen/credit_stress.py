#!/usr/bin/env python3
"""credit_stress.py — the stress cases of the independent credit review (docs/35 section 13), run through the
methodology of tools/dbgen/credit_scorecard.json with credit_reference.py, beside the grade range the reviewer
expects for each (a separate AI agent in the role of a senior credit analyst, not a human review). It prints one row per case and exits 1 if a case falls outside its range.

Usage: python3 tools/dbgen/credit_stress.py [--markdown]
The cases are built in SAR millions; the subtotals are derived and the balance sheet is checked to balance.
"""
import os, sys
from datetime import date
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import credit_reference as cr


def st(**kw):
    d = dict(DUE_FROM_RELATED=0, CONTRACT_ASSETS=0, DUE_TO_RELATED=0, BANK_ACCEPTANCES=0, SHAREHOLDER_LOANS_SUB=0, EOSB=0,
             REVALUATION_RESERVE=0, MINORITY_INTEREST=0, OTHER_EQUITY=0, INTANGIBLES=0, OTHER_INCOME=0,
             LC_OUTSTANDING=0, LG_PERFORMANCE=0, LG_FINANCIAL=0, GUARANTEES_GIVEN=0)
    d.update(kw)
    d['TOTAL_CA'] = d['CASH'] + d['AR'] + d['CONTRACT_ASSETS'] + d['INVENTORY'] + d['DUE_FROM_RELATED'] + d['OTHER_CA']
    d['TOTAL_ASSETS'] = d['TOTAL_CA'] + d['PPE'] + d['INTANGIBLES'] + d['OTHER_NCA']
    d['TOTAL_CL'] = d['ST_LOANS'] + d['BANK_ACCEPTANCES'] + d['CURRENT_PORTION_LTD'] + d['AP'] + d['DUE_TO_RELATED'] + d['OTHER_CL']
    d['TOTAL_LIABS'] = d['TOTAL_CL'] + d['LT_LOANS'] + d['LEASE_LIABS'] + d['SHAREHOLDER_LOANS_SUB'] + d['EOSB'] + d['OTHER_NCL']
    d['TOTAL_EQUITY'] = d['SHARE_CAPITAL'] + d['RETAINED_EARNINGS'] + d['REVALUATION_RESERVE'] + d['OTHER_EQUITY'] + d['MINORITY_INTEREST']
    assert abs(d['TOTAL_ASSETS'] - d['TOTAL_LIABS'] - d['TOTAL_EQUITY']) < 1e-6, (d['TOTAL_ASSETS'], d['TOTAL_LIABS'], d['TOTAL_EQUITY'])
    d['GROSS_PROFIT'] = d['REVENUE'] - d['COGS']
    d['OPERATING_PROFIT'] = d['GROSS_PROFIT'] - d['OPEX']          # OPEX here includes depreciation
    d['EBITDA'] = d['OPERATING_PROFIT'] + d['DEPR_AMORT']
    d['NET_PROFIT'] = d['OPERATING_PROFIT'] - d['FINANCE_COSTS'] + d['OTHER_INCOME'] - d['ZAKAT_TAX']
    return {k: v * 1e6 for k, v in d.items()}


Q = lambda b, f: {'BUSINESS_PROFILE': b, 'FINANCIAL_POLICY': f}
DATES = dict(period_end=date(2025, 12, 31), assessment_date=date(2026, 5, 31))

A = dict(CASH=80, AR=660, INVENTORY=590, DUE_FROM_RELATED=40, OTHER_CA=60, PPE=140, INTANGIBLES=10, OTHER_NCA=40,
         ST_LOANS=600, CURRENT_PORTION_LTD=20, AP=300, DUE_TO_RELATED=20, OTHER_CL=60, LT_LOANS=60, LEASE_LIABS=30, EOSB=25, OTHER_NCL=15,
         SHARE_CAPITAL=150, RETAINED_EARNINGS=310, OTHER_EQUITY=30,
         REVENUE=4000, COGS=3600, OPEX=295, DEPR_AMORT=15, FINANCE_COSTS=43, OTHER_INCOME=5, ZAKAT_TAX=12,
         OP_CASH_FLOW=30, CAPEX=15, PRINCIPAL_REPAID=25, INTEREST_PAID=41, DIVIDENDS=20, LC_OUTSTANDING=660)
B = dict(CASH=15, AR=148, INVENTORY=8, DUE_FROM_RELATED=6, OTHER_CA=40, PPE=55, OTHER_NCA=5,
         ST_LOANS=60, CURRENT_PORTION_LTD=10, AP=55, DUE_TO_RELATED=5, OTHER_CL=30, LT_LOANS=20, LEASE_LIABS=5, EOSB=12, OTHER_NCL=6,
         SHARE_CAPITAL=50, RETAINED_EARNINGS=20, OTHER_EQUITY=4,
         REVENUE=300, COGS=255, OPEX=26, DEPR_AMORT=8, FINANCE_COSTS=7, OTHER_INCOME=1, ZAKAT_TAX=3,
         OP_CASH_FLOW=4, CAPEX=7, PRINCIPAL_REPAID=12, INTEREST_PAID=7, DIVIDENDS=0, LG_PERFORMANCE=204)
C = dict(CASH=10, AR=70, INVENTORY=60, DUE_FROM_RELATED=15, OTHER_CA=15, PPE=200, INTANGIBLES=5, OTHER_NCA=15,
         ST_LOANS=90, CURRENT_PORTION_LTD=30, AP=60, DUE_TO_RELATED=10, OTHER_CL=20, LT_LOANS=80, LEASE_LIABS=5, OTHER_NCL=15,
         SHARE_CAPITAL=200, RETAINED_EARNINGS=-120, OTHER_EQUITY=0,
         REVENUE=250, COGS=215, OPEX=42, DEPR_AMORT=12, FINANCE_COSTS=13, OTHER_INCOME=2, ZAKAT_TAX=2,
         OP_CASH_FLOW=2, CAPEX=5, PRINCIPAL_REPAID=30, INTEREST_PAID=13, DIVIDENDS=0, LG_PERFORMANCE=30)
EX = {k: v / 1e6 for k, v in cr.EXAMPLE_CUR.items()
      if k not in ('TOTAL_CA', 'TOTAL_ASSETS', 'TOTAL_CL', 'TOTAL_LIABS', 'TOTAL_EQUITY', 'GROSS_PROFIT', 'EBITDA', 'OPERATING_PROFIT', 'NET_PROFIT')}
C4 = dict(CASH=5, AR=60, INVENTORY=20, OTHER_CA=10, PPE=40, OTHER_NCA=5,
          ST_LOANS=0, CURRENT_PORTION_LTD=0, AP=50, OTHER_CL=15, LT_LOANS=0, LEASE_LIABS=0, OTHER_NCL=15,
          SHARE_CAPITAL=50, RETAINED_EARNINGS=10, OTHER_EQUITY=0,
          REVENUE=200, COGS=180, OPEX=34, DEPR_AMORT=4, FINANCE_COSTS=0, OTHER_INCOME=0, ZAKAT_TAX=1,
          OP_CASH_FLOW=-15, CAPEX=2, PRINCIPAL_REPAID=0, INTEREST_PAID=0, DIVIDENDS=0, LG_PERFORMANCE=150)
D = dict(CASH=250, AR=250, INVENTORY=200, OTHER_CA=50, PPE=1200, INTANGIBLES=20, OTHER_NCA=80,
         ST_LOANS=50, CURRENT_PORTION_LTD=50, AP=120, OTHER_CL=80, LT_LOANS=180, LEASE_LIABS=20, OTHER_NCL=70,
         SHARE_CAPITAL=600, RETAINED_EARNINGS=750, OTHER_EQUITY=130,
         REVENUE=1500, COGS=1000, OPEX=185, DEPR_AMORT=60, FINANCE_COSTS=18, OTHER_INCOME=5, ZAKAT_TAX=25,
         OP_CASH_FLOW=330, CAPEX=120, PRINCIPAL_REPAID=50, INTEREST_PAID=18, DIVIDENDS=100, LC_OUTSTANDING=100)
D2 = {k: v * 13 for k, v in D.items()}
D2.update(ST_LOANS=0, CURRENT_PORTION_LTD=0, LT_LOANS=0, LEASE_LIABS=0, FINANCE_COSTS=0, PRINCIPAL_REPAID=0, INTEREST_PAID=0,
          CASH=D['CASH'] * 13 - 300 * 13)
NO_CF = {k: v for k, v in EX.items() if k not in cr.CF_CODES}

# name, card, statement, qualitative, extra arguments, expected grade range (best, worst) of the reviewer
CASES = [
    ('a', 'تاجر بإيراد 4 مليارات وهامش EBITDA 3% وتمويل تجاري قصير في معظمه', 'TRADING_DISTRIBUTION', st(**A), Q('Ba1', 'Ba2'), {}, ('Ba2', 'B1')),
    ('a1', 'التاجر نفسه، وتدوير مرابحات 3.1 مليار في أقساط أصل الدين المسددة', 'TRADING_DISTRIBUTION', st(**dict(A, PRINCIPAL_REPAID=3100)), Q('Ba1', 'Ba2'), {}, ('Ba2', 'B1')),
    ('b', 'مقاول بإيراد 300 مليون، وتحصيل 180 يومًا، وخطابات ضمان 3 أمثال صافي الثروة', 'CONTRACTING', st(**B), Q('B1', 'Ba3'), {}, ('Ba3', 'B3')),
    ('b3', 'المقاول نفسه، والمحتجزات مدخلة أصول عقود', 'CONTRACTING', st(**dict(B, AR=60, CONTRACT_ASSETS=88)), Q('B1', 'Ba3'), {}, ('Ba3', 'B3')),
    ('c', 'خاسرة بخسائر متراكمة 60% من رأس المال وتغطية فوائد 0.4', 'GENERAL_CORPORATE', st(**C), Q('B3', 'Caa1'), {}, ('B3', 'Caa2')),
    ('c2', 'شركة عائلية: رأس مال 10 ملايين وخسائر 6 ملايين وقروض شركاء مساندة 416 مليونًا', 'GENERAL_CORPORATE',
     st(**dict(EX, SHARE_CAPITAL=10, RETAINED_EARNINGS=-6, OTHER_EQUITY=0, SHAREHOLDER_LOANS_SUB=416)), cr.EXAMPLE_QUAL, {}, ('Baa3', 'Ba2')),
    ('c3', 'الشركة نفسها بحقوق ملكية دفترية سالبة (−2 مليون)', 'GENERAL_CORPORATE',
     st(**dict(EX, SHARE_CAPITAL=10, RETAINED_EARNINGS=-12, OTHER_EQUITY=0, SHAREHOLDER_LOANS_SUB=422)), cr.EXAMPLE_QUAL, {}, ('Ba1', 'Ba3')),
    ('c4', 'مقاول بلا دين، وEBITDA −10 ملايين، وتدفق تشغيلي −15 مليونًا، وخطابات ضمان 2.5 مثل', 'CONTRACTING', st(**C4), Q('B2', 'B1'), {}, ('B2', 'Caa1')),
    ('d', 'مصنّع بإيراد 1.5 مليار وهامش 25% ودين 0.8 مثل EBITDA', 'GENERAL_CORPORATE', st(**D), Q('Baa1', 'A3'), {}, ('A3', 'Baa2')),
    ('d2', 'مصنّع بلا دين بإيراد 19.5 مليار', 'GENERAL_CORPORATE', st(**D2), Q('A2', 'A2'), {}, ('Aa3', 'A2')),
    ('d3', 'المصنّع (d) في سنة بناء رأس مال عامل، وتدفق تشغيلي −20 مليونًا', 'GENERAL_CORPORATE', st(**dict(D, OP_CASH_FLOW=-20)), Q('Baa1', 'A3'), {}, ('A3', 'Baa2')),
    ('e0', 'المثال المحسوب', 'GENERAL_CORPORATE', st(**EX), cr.EXAMPLE_QUAL, {}, ('Baa3', 'Baa3')),
    ('e1', 'المثال بلا قائمة تدفقات', 'GENERAL_CORPORATE', st(**NO_CF), cr.EXAMPLE_QUAL, {}, ('Ba1', 'Ba1')),
    ('e2', 'المثال بتدفق تشغيلي −60 مليونًا', 'GENERAL_CORPORATE', st(**dict(EX, OP_CASH_FLOW=-60)), cr.EXAMPLE_QUAL, {}, ('Ba1', 'Ba2')),
    ('e3', 'المثال بلا بند التوزيعات', 'GENERAL_CORPORATE', st(**{k: v for k, v in EX.items() if k != 'DIVIDENDS'}), cr.EXAMPLE_QUAL, {}, ('Baa3', 'Baa3')),
    ('e4', 'بلا قائمة تدفقات ولا عوامل نوعية', 'GENERAL_CORPORATE', st(**NO_CF), None, {}, None),
]


def main():
    md = '--markdown' in sys.argv
    out, bad = [], 0
    for key, name, card, cur, qual, extra, rng in CASES:
        r = cr.assess(card, cur, 'ANNUAL', qualitative=qual, **DATES, **extra)
        got = r['final'] if r['state'] == 'RATED' else r['state']
        if rng is None:
            ok = r['state'] != 'RATED'
            want = 'لا درجة نهائية'
        else:
            n, lo, hi = (cr.BY_CODE[got]['notch'] if r['state'] == 'RATED' else 99), cr.BY_CODE[rng[0]]['notch'], cr.BY_CODE[rng[1]]['notch']
            ok = lo <= n <= hi
            want = rng[0] if rng[0] == rng[1] else f'{rng[0]} إلى {rng[1]}'
        bad += 0 if ok else 1
        agg = r.get('aggregate', r.get('financial'))
        out.append((key, name, card, want, got, '' if agg is None else f'{agg:.2f}', ', '.join(r.get('adjustments', [])), 'نعم' if ok else 'لا'))
    if md:
        print('| # | الحالة | البطاقة | توقع المراجع | النتيجة | المجموع | التعديلات | ضمن المدى |')
        print('|---|---|---|---|---|---|---|---|')
        for row in out:
            print('| ' + ' | '.join(row) + ' |')
    else:
        for row in out:
            print(f'{row[0]:3s} {row[3]:14s} {row[4]:18s} {row[5]:>6s} {row[7]:3s} {row[1]}  [{row[6]}]')
        print(f'{len(out) - bad} of {len(out)} cases within the reviewer\'s range')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
