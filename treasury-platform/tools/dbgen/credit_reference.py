#!/usr/bin/env python3
"""credit_reference.py — the credit assessment of docs/35 computed in Python, apart from the database.

It reads tools/dbgen/credit_scorecard.json and computes, from the lines of a statement (and of the statement it is
compared with), every metric, the score of each scorecard metric on the linear continuum, the financial and the
weighted aggregates, the indicated grade, the notches, the standalone caps, the group support, the override and the
absolute caps, and the risk level of each balance sheet item rule. fin.usp_ComputeCreditAssessment (db/static/046)
does the same in T-SQL; db/tests/credit_assessment_tests.sql expects the numbers this module gives for the same
fixtures, so the two implementations check each other.

Usage: python3 tools/dbgen/credit_reference.py [example]   the worked example of docs/35 section 14
"""
import json, math, os, sys
from datetime import date

HERE = os.path.dirname(os.path.abspath(__file__))
M = json.load(open(os.path.join(HERE, 'credit_scorecard.json'), encoding='utf-8'))
S = M['score_points']
GRADES = {g['notch']: g for g in M['grades']}
BY_CODE = {g['code']: g for g in M['grades']}
METRICS = {m['code']: m for m in M['metrics']}
CARDS = {c['code']: c for c in M['scorecards']}
MONTHS = {'ANNUAL': 12, 'SEMIANNUAL': 6, 'QUARTERLY': 3, 'MONTHLY': 1}
CF_CODES = ('OP_CASH_FLOW', 'CAPEX', 'PRINCIPAL_REPAID', 'INTEREST_PAID', 'DIVIDENDS')
# The optional lines of the credit assessment count as zero when a statement does not have them (docs/35 section 4).
OPTIONAL_ZERO = ('DUE_FROM_RELATED', 'CONTRACT_ASSETS', 'DUE_TO_RELATED', 'BANK_ACCEPTANCES', 'SHAREHOLDER_LOANS_SUB', 'EOSB',
                 'REVALUATION_RESERVE', 'LC_OUTSTANDING', 'LG_PERFORMANCE', 'LG_FINANCIAL', 'GUARANTEES_GIVEN', 'ZAKAT_DISPUTED') + CF_CODES
BEST, WORST = 'BEST', 'WORST'


class InputError(Exception):
    """An input the computation refuses (50064 or 50065 in the database)."""


def adjustments(card):
    return M['adjustments'] + CARDS[card]['extra_adjustments']


def grid_score(v, b):
    """The score of value v on the grid b (nine boundary values, best cap first): 0.5 at the best cap or beyond,
    20.5 at the worst cap or beyond, linear between two boundaries."""
    asc = b[0] < b[8]
    if (asc and v <= b[0]) or (not asc and v >= b[0]):
        return S[0]
    if (asc and v >= b[8]) or (not asc and v <= b[8]):
        return S[8]
    for i in range(8):
        lo, hi = b[i], b[i + 1]
        if (asc and lo <= v < hi) or (not asc and hi < v <= lo):
            return S[i] + (v - lo) / (hi - lo) * (S[i + 1] - S[i])
    raise AssertionError('unreachable')


def notch_of(score):
    """The notch (1 = Aaa ... 20 = Ca) of a score: Aaa below 1.5, then one notch per point, Ca from 19.5."""
    return min(20, max(1, math.floor(score - 0.5) + 1))


def grade_of_score(score):
    return GRADES[notch_of(score)]['code']


def item_level(v, t, direction):
    """The risk level of value v under thresholds t; a value on a threshold belongs to the worse level."""
    levels = ('LOW', 'MODERATE', 'ELEVATED', 'HIGH')
    for i, lim in enumerate(t):
        if (direction == 'LOWER_BETTER' and v < lim) or (direction == 'HIGHER_BETTER' and v > lim):
            return levels[i]
    return 'CRITICAL'


class Lines:
    """The amounts of a statement: a missing line is None, but an optional line counts as zero."""
    def __init__(self, d, period_type):
        self.d, self.k = d, 12 / MONTHS[period_type]

    def __call__(self, c):
        if c in self.d:
            return self.d[c]
        return 0 if c in OPTIONAL_ZERO else None

    def flow(self, c, absolute=False):
        v = self(c)
        return None if v is None else (abs(v) if absolute else v) * self.k

    def cf_given(self):
        return any(self(c) not in (None, 0) for c in CF_CODES)

    def ebitda(self):
        op, da = self('OPERATING_PROFIT'), self('DEPR_AMORT')
        if op is not None and da is not None:
            return (op + abs(da)) * self.k
        return self.flow('EBITDA')


def metrics(cur, prior, period_type, prior_period_type, fx, unit):
    """Every metric of the dictionary: code -> (status, value or BEST/WORST, reason). status is COMPUTED, EXTREME or
    NOT_COMPUTABLE."""
    a = Lines(cur, period_type)
    p = Lines(prior, prior_period_type) if prior is not None else None
    out = {}
    def comp(code, value): out[code] = ('COMPUTED', value, None)
    def ext(code, which, reason): out[code] = ('EXTREME', which, reason)
    def nc(code, reason): out[code] = ('NOT_COMPUTABLE', None, reason)
    def need(*cs): return any(a(c) is None for c in cs)

    core_debt = ('ST_LOANS', 'CURRENT_PORTION_LTD', 'LT_LOANS', 'LEASE_LIABS')
    debt = None if need(*core_debt) else sum(a(c) for c in core_debt + ('BANK_ACCEPTANCES', 'DUE_TO_RELATED'))
    st_debt = None if need('ST_LOANS', 'CURRENT_PORTION_LTD') else a('ST_LOANS') + a('BANK_ACCEPTANCES') + a('CURRENT_PORTION_LTD')
    rev, np_, opp = a.flow('REVENUE'), a.flow('NET_PROFIT'), a.flow('OPERATING_PROFIT')
    ebitda = a.ebitda()
    cogs = a.flow('COGS', True)
    fc = a.flow('FINANCE_COSTS', True)
    interest = None if fc is None else max(fc, a.flow('INTEREST_PAID', True))
    cf = a.cf_given()
    cfo = a.flow('OP_CASH_FLOW') if cf else None
    te, shl, it = a('TOTAL_EQUITY'), a('SHAREHOLDER_LOANS_SUB'), a('INTANGIBLES')
    quasi = None if te is None else te + shl
    tnw_tang = None if quasi is None or it is None else quasi - it
    adj_tnw = None if tnw_tang is None else tnw_tang - a('DUE_FROM_RELATED') - a('REVALUATION_RESERVE')
    contingent = a('LC_OUTSTANDING') + a('LG_PERFORMANCE') + a('LG_FINANCIAL') + a('GUARANTEES_GIVEN')

    if rev is None: nc('REVENUE_SIZE', 'missing REVENUE')
    elif rev <= 0: ext('REVENUE_SIZE', WORST, 'revenue not positive')
    else: comp('REVENUE_SIZE', rev * fx / unit)
    for code, num in (('EBITDA_MARGIN', ebitda), ('NET_MARGIN', np_)):
        if rev is None or num is None or rev <= 0: nc(code, 'missing lines or revenue not positive')
        else: comp(code, num / rev * 100)
    ta = a('TOTAL_ASSETS')
    pta = p('TOTAL_ASSETS') if p is not None else None
    base = (ta + pta) / 2 if ta is not None and pta is not None else ta
    if opp is None or ta is None or base <= 0: nc('ROA', 'missing lines or assets not positive')
    else: comp('ROA', opp / base * 100)
    if debt is None or ebitda is None: nc('DEBT_TO_EBITDA', 'missing lines')
    elif debt == 0: ext('DEBT_TO_EBITDA', BEST if ebitda > 0 else WORST, 'no debt')
    elif ebitda <= 0: ext('DEBT_TO_EBITDA', WORST, 'EBITDA not positive with debt')
    else: comp('DEBT_TO_EBITDA', debt / ebitda)
    tl = a('TOTAL_LIABS')
    if tl is None or adj_tnw is None: nc('TL_TO_TNW', 'missing lines')
    elif adj_tnw <= 0: ext('TL_TO_TNW', WORST, 'adjusted tangible net worth not positive')
    else: comp('TL_TO_TNW', (tl - shl) / adj_tnw)
    if ebitda is None or interest is None: nc('EBITDA_TO_INTEREST', 'missing lines')
    elif interest == 0: ext('EBITDA_TO_INTEREST', BEST if ebitda > 0 else WORST, 'no finance costs')
    elif ebitda <= 0: ext('EBITDA_TO_INTEREST', WORST, 'EBITDA not positive')
    else: comp('EBITDA_TO_INTEREST', ebitda / interest)
    zak = a.flow('ZAKAT_TAX', True)
    principal = p('CURRENT_PORTION_LTD') if p is not None and p('CURRENT_PORTION_LTD') is not None else a('CURRENT_PORTION_LTD')
    if ebitda is None or zak is None or interest is None or principal is None: nc('DSCR', 'missing lines')
    else:
        num, den = ebitda - zak, principal + interest
        if den == 0: ext('DSCR', BEST if num > 0 else WORST, 'no debt service')
        elif num <= 0: ext('DSCR', WORST, 'numerator not positive')
        else: comp('DSCR', num / den)
    if not cf: nc('CFO_TO_DEBT', 'no cash flow statement')
    elif debt is None: nc('CFO_TO_DEBT', 'missing lines')
    else:
        cfo_avg = (cfo + p.flow('OP_CASH_FLOW')) / 2 if p is not None and p.cf_given() else cfo
        if debt == 0: ext('CFO_TO_DEBT', BEST if cfo_avg >= 0 else WORST, 'no debt')
        else: comp('CFO_TO_DEBT', cfo_avg / debt * 100)
    ca, cl = a('TOTAL_CA'), a('TOTAL_CL')
    if ca is None or cl is None: nc('CURRENT_RATIO', 'missing lines')
    elif cl == 0: ext('CURRENT_RATIO', BEST, 'no current liabilities')
    else: comp('CURRENT_RATIO', ca / cl)
    ar = None if a('AR') is None else a('AR') + a('CONTRACT_ASSETS')
    dso = None if rev is None or ar is None or rev <= 0 else ar / rev * 365
    dio = None if cogs is None or a('INVENTORY') is None or cogs <= 0 else a('INVENTORY') / cogs * 365
    dpo = None if cogs is None or a('AP') is None or cogs <= 0 else a('AP') / cogs * 365
    for code, v in (('DSO', dso), ('DIO', dio), ('DPO', dpo)):
        if v is None: nc(code, 'missing lines or base not positive')
        else: comp(code, v)
    if dso is None or dio is None or dpo is None: nc('CASH_CYCLE', 'missing lines or base not positive')
    else: comp('CASH_CYCLE', dso + dio - dpo)
    if a('CASH') is None or st_debt is None: nc('CASH_TO_ST_DEBT', 'missing lines')
    elif st_debt == 0: ext('CASH_TO_ST_DEBT', BEST, 'no short-term debt')
    else: comp('CASH_TO_ST_DEBT', a('CASH') / st_debt)
    # ratios of an optional line to a base: zero when the line is zero, WORST on a base that is not positive
    def share(code, num, base_, missing):
        if missing or base_ is None: nc(code, 'missing lines')
        elif num == 0: comp(code, 0)
        elif base_ <= 0: ext(code, WORST, 'base not positive')
        else: comp(code, num / base_ * 100)
    share('RELATED_TO_TNW', a('DUE_FROM_RELATED'), tnw_tang, False)
    share('INTANGIBLES_TO_EQUITY', it, quasi, it is None)
    for code, line in (('EOSB_TO_TNW', 'EOSB'), ('ZAKAT_DISPUTED_TO_TNW', 'ZAKAT_DISPUTED'), ('DUE_TO_RELATED_TO_TNW', 'DUE_TO_RELATED'),
                       ('GUARANTEES_TO_TNW', 'GUARANTEES_GIVEN')):
        share(code, a(line), adj_tnw, False)
    if adj_tnw is None: nc('CONTINGENT_TO_TNW', 'missing lines')
    elif contingent == 0: comp('CONTINGENT_TO_TNW', 0)
    elif adj_tnw <= 0: ext('CONTINGENT_TO_TNW', WORST, 'adjusted tangible net worth not positive')
    else: comp('CONTINGENT_TO_TNW', contingent / adj_tnw)
    trade = None if need('AR', 'INVENTORY', 'ST_LOANS') else a('AR') + a('INVENTORY')
    share('ST_DEBT_TO_TRADE_ASSETS', None if trade is None else a('ST_LOANS') + a('BANK_ACCEPTANCES'), trade, trade is None)
    if a('OTHER_CA') is None or ca is None or ca <= 0: nc('OTHER_CA_SHARE', 'missing lines or no current assets')
    else: comp('OTHER_CA_SHARE', a('OTHER_CA') / ca * 100)
    if rev is None or rev <= 0: nc('CONTRACT_ASSETS_TO_REVENUE', 'revenue missing or not positive')
    else: comp('CONTRACT_ASSETS_TO_REVENUE', a('CONTRACT_ASSETS') / rev * 100)
    if ca is None or cl is None or ta is None or ta <= 0: nc('NWC_TO_ASSETS', 'missing lines')
    else: comp('NWC_TO_ASSETS', (ca - cl) / ta * 100)
    if quasi is None or ta is None or ta <= 0: nc('EQUITY_RATIO', 'missing lines')
    else: comp('EQUITY_RATIO', quasi / ta * 100)
    if debt is None: nc('ST_DEBT_SHARE', 'missing lines')
    elif debt == 0: ext('ST_DEBT_SHARE', BEST, 'no debt')
    else: comp('ST_DEBT_SHARE', st_debt / debt * 100)
    cp = a('CURRENT_PORTION_LTD')
    if not cf: nc('CFO_TO_CPLTD', 'no cash flow statement')
    elif cp is None: nc('CFO_TO_CPLTD', 'missing lines')
    elif cp == 0: ext('CFO_TO_CPLTD', BEST, 'no instalments due')
    else: comp('CFO_TO_CPLTD', cfo / cp)
    re_, sc = a('RETAINED_EARNINGS'), a('SHARE_CAPITAL')
    if re_ is None or sc is None: nc('ACC_LOSS_TO_CAPITAL', 'missing lines')
    elif re_ >= 0: ext('ACC_LOSS_TO_CAPITAL', BEST, 'no accumulated losses')
    elif sc <= 0: nc('ACC_LOSS_TO_CAPITAL', 'share capital not positive')
    else: comp('ACC_LOSS_TO_CAPITAL', -re_ / sc * 100)
    if p is None:
        nc('REVENUE_GROWTH', 'no prior statement'); nc('GROSS_MARGIN_CHANGE', 'no prior statement')
    else:
        prev, pgp, gp = p.flow('REVENUE'), p.flow('GROSS_PROFIT'), a.flow('GROSS_PROFIT')
        if rev is None or prev is None or prev <= 0: nc('REVENUE_GROWTH', 'prior revenue missing or not positive')
        else: comp('REVENUE_GROWTH', (rev - prev) / prev * 100)
        if gp is None or pgp is None or rev is None or prev is None or rev <= 0 or prev <= 0: nc('GROSS_MARGIN_CHANGE', 'missing lines')
        else: comp('GROSS_MARGIN_CHANGE', gp / rev * 100 - pgp / prev * 100)
    if not cf: nc('CFO_TO_EBITDA', 'no cash flow statement')
    elif ebitda is None: nc('CFO_TO_EBITDA', 'missing lines')
    elif ebitda <= 0:
        if cfo < 0: ext('CFO_TO_EBITDA', WORST, 'negative operating cash flow and EBITDA not positive')
        else: nc('CFO_TO_EBITDA', 'EBITDA not positive')
    else: comp('CFO_TO_EBITDA', cfo / ebitda * 100)
    dv = a.flow('DIVIDENDS', True)
    if np_ is None: nc('PAYOUT_RATIO', 'missing lines')
    elif dv == 0:
        if np_ > 0: ext('PAYOUT_RATIO', BEST, 'no dividends')
        else: nc('PAYOUT_RATIO', 'no profit and no dividends')
    elif np_ <= 0: ext('PAYOUT_RATIO', WORST, 'dividends with no profit')
    else: comp('PAYOUT_RATIO', dv / np_ * 100)
    facts = dict(cf=cf, quasi=quasi, adj_tnw=adj_tnw, share_capital=sc, rev=rev, exposure=a('DUE_FROM_RELATED') + a('GUARANTEES_GIVEN'))
    return out, facts


def assess(card, cur, period_type, *, prior=None, prior_period_type='ANNUAL', fx=1.0, assurance='AUDITED',
           opinion='UNQUALIFIED', going_concern=False, restated_change_pct=None, is_holding=False, basis='STANDALONE',
           period_end=None, assessment_date=None, qualitative=None, documented=(), support=None, parent_notch=None,
           parent_age_months=0, override=0, breach=None, flow_shortfall=False):
    """breach: None, 'WAIVER_REQUESTED' or 'OPEN' (an open covenant breach without a waiver request)."""
    c = CARDS[card]
    m, facts = metrics(cur, prior, period_type, prior_period_type, fx, c['amount_unit'])
    factors = []
    for sm in c['metrics']:
        md = METRICS[sm['m']]
        if md['kind'] == 'QUALITATIVE':
            gcode = (qualitative or {}).get(sm['m'])
            if gcode is None:
                factors.append((sm['m'], 'NOT_COMPUTABLE', None, None, sm['w'], True))
            else:
                g = BY_CODE[gcode]
                factors.append((sm['m'], 'ANALYST', None, (g['from'] + g['to']) / 2, sm['w'], True))
            continue
        st, v, _ = m[sm['m']]
        if st == 'NOT_COMPUTABLE':
            factors.append((sm['m'], st, None, None, sm['w'], False)); continue
        score = S[0] if v == BEST else S[8] if v == WORST else grid_score(v, sm['b'])
        factors.append((sm['m'], st, None if st == 'EXTREME' else v, round(score, 4), sm['w'], False))
    qw = sum(f[4] for f in factors if not f[5])
    qs = [f for f in factors if not f[5] and f[3] is not None]
    coverage = round(sum(f[4] for f in qs) / qw * 100, 2)
    res = dict(metrics=m, factors=[f[:4] for f in factors], coverage=coverage)
    if coverage < c['min_coverage']:
        return dict(res, state='INSUFFICIENT_DATA')
    fin = round(sum(f[4] * f[3] for f in qs) / sum(f[4] for f in qs), 4)
    fin_notch = notch_of(fin)
    res.update(financial=fin, financial_grade=GRADES[fin_notch]['code'])
    quals = [f for f in factors if f[5]]
    if any(f[3] is None for f in quals):
        return dict(res, state='INDICATIVE')
    for f in quals:
        if abs(notch_of(f[3]) - fin_notch) > M['qualitative_bound'] and f[0] not in documented:
            raise InputError(f'{f[0]} more than {M["qualitative_bound"]} notches from the financial grade without a document')
    scored = [f for f in factors if f[3] is not None]
    agg = round(sum(f[4] * f[3] for f in scored) / sum(f[4] for f in scored), 4)
    n0 = notch_of(agg)
    applies = {
        'AUDIT_QUALIFIED': assurance == 'AUDITED' and opinion == 'QUALIFIED',
        'UNAUDITED_ANNUAL': assurance == 'MANAGEMENT' and period_type == 'ANNUAL',
        'STALE_STATEMENT': None,
        'INCOMPLETE_STATEMENT': not facts['cf'],
        'RESTATEMENT': None,
        'HALF_CAPITAL_LOST_CURED': None, 'HALF_CAPITAL_LOST': None,
        'RELATED_PARTY_EXPOSURE': None,
        'HOLDCO_STANDALONE': is_holding and basis == 'STANDALONE',
        'OPEN_BREACH': breach == 'OPEN',
        'BREACH_WAIVER_REQUESTED': breach == 'WAIVER_REQUESTED',
        'FLOW_SHORTFALL': flow_shortfall,
        'GOING_CONCERN': going_concern,
        'NEGATIVE_EQUITY': facts['quasi'] is not None and facts['quasi'] <= 0,
        'SIZE_CEILING': None,
        'SECTOR_CEILING': True,
        'AUDIT_ADVERSE': assurance == 'AUDITED' and opinion in ('ADVERSE', 'DISCLAIMER'),
        'SOVEREIGN_CEILING': True,
    }
    applied = []
    for ad in adjustments(card):
        r, par = ad['r'], ad['p']
        ok = applies[r]
        if r == 'STALE_STATEMENT':
            ok = bool(period_end and assessment_date) and \
                 (assessment_date.year - period_end.year) * 12 + assessment_date.month - period_end.month > par
        elif r == 'RESTATEMENT':
            ok = restated_change_pct is not None and restated_change_pct > par
        elif r in ('HALF_CAPITAL_LOST', 'HALF_CAPITAL_LOST_CURED'):
            al = m['ACC_LOSS_TO_CAPITAL']
            lost = al[0] == 'COMPUTED' and al[1] >= par
            cured = facts['quasi'] is not None and facts['share_capital'] is not None and facts['quasi'] >= facts['share_capital']
            ok = lost and (cured if r == 'HALF_CAPITAL_LOST_CURED' else not cured)
        elif r == 'RELATED_PARTY_EXPOSURE':
            t = facts['adj_tnw']
            ok = t is not None and facts['exposure'] > 0 and (t <= 0 or facts['exposure'] > par / 100 * t)
        elif r == 'SIZE_CEILING':
            rs = m['REVENUE_SIZE']
            ok = (rs[0] == 'COMPUTED' and rs[1] < par) or rs[1] == WORST
        if ok:
            applied.append(ad)
    notches = sum(ad['n'] for ad in applied if ad['stage'] == 'NOTCH')
    cap_of = lambda stage: max([BY_CODE[ad['cap']]['notch'] for ad in applied if ad['stage'] == stage and ad['cap']] or [1])
    n1 = n0 - notches                                      # a notch down adds one
    n2 = max(n1, cap_of('STANDALONE'))                     # the standalone grade
    n3 = n2
    if support:
        if parent_age_months > M['support_max_age_months']:
            raise InputError('the parent assessment is older than 12 months')
        n3 = min(n2, max(n2 - support, parent_notch))      # support lifts, never above the parent, never lowers
    n4 = n3 - override
    n5 = max(n4, cap_of('ABSOLUTE'))
    final = min(20, max(1, n5))
    items = {}
    for ir in c['items']:
        st, v, _ = m[ir['r']]
        if st == 'NOT_COMPUTABLE':
            items[ir['r']] = ('NOT_ASSESSED', None)
        elif st == 'EXTREME':
            items[ir['r']] = ('LOW' if v == BEST else 'CRITICAL', None)
        else:
            items[ir['r']] = (item_level(v, ir['t'], METRICS[ir['r']]['dir']), v)
    return dict(res, state='RATED', aggregate=agg, indicated=GRADES[n0]['code'], adjustments=[ad['r'] for ad in applied],
                notches=notches, standalone=GRADES[min(20, n2)]['code'], final=GRADES[final]['code'], items=items)


# The worked example of docs/35 section 14, and the main fixture of the tests: an industrial company, annual audited
# statement in SAR, its lines given here in millions. OPEX includes depreciation, so EBITDA = OPERATING_PROFIT +
# DEPR_AMORT = 90 + 40.
EXAMPLE_CUR = dict(CASH=45, AR=160, INVENTORY=130, DUE_FROM_RELATED=20, OTHER_CA=25, TOTAL_CA=380, PPE=520, INTANGIBLES=30,
                   OTHER_NCA=70, TOTAL_ASSETS=1000, ST_LOANS=120, CURRENT_PORTION_LTD=60, AP=110, DUE_TO_RELATED=10,
                   OTHER_CL=50, TOTAL_CL=350, LT_LOANS=180, LEASE_LIABS=20, SHAREHOLDER_LOANS_SUB=0, EOSB=18, OTHER_NCL=12,
                   TOTAL_LIABS=580, SHARE_CAPITAL=250, RETAINED_EARNINGS=140, OTHER_EQUITY=30, MINORITY_INTEREST=0,
                   TOTAL_EQUITY=420, REVENUE=900, COGS=650, GROSS_PROFIT=250, OPEX=160, DEPR_AMORT=40, EBITDA=130,
                   OPERATING_PROFIT=90, FINANCE_COSTS=22, OTHER_INCOME=4, ZAKAT_TAX=8, NET_PROFIT=64, OP_CASH_FLOW=95,
                   CAPEX=60, PRINCIPAL_REPAID=55, INTEREST_PAID=21, DIVIDENDS=30, LC_OUTSTANDING=90, LG_PERFORMANCE=100,
                   LG_FINANCIAL=20, GUARANTEES_GIVEN=0)
EXAMPLE_CUR = {k: v * 1000000 for k, v in EXAMPLE_CUR.items()}   # stored in SAR
EXAMPLE_PRIOR = dict(EXAMPLE_CUR, TOTAL_ASSETS=940000000, REVENUE=850000000, GROSS_PROFIT=245000000, CURRENT_PORTION_LTD=55000000,
                     OP_CASH_FLOW=85000000)
EXAMPLE_QUAL = {'BUSINESS_PROFILE': 'Ba1', 'FINANCIAL_POLICY': 'Baa3'}
EXAMPLE_DATES = dict(period_end=date(2025, 12, 31), assessment_date=date(2026, 4, 30))


def show(r):
    print(f"state {r['state']}  coverage {r['coverage']}  financial {r.get('financial')} {r.get('financial_grade')}")
    for code, st, v, sc in r['factors']:
        print(f"  {code:20s} {st:15s} {'' if v is None else round(v, 6):>14}  score {'' if sc is None else sc}")
    if r['state'] == 'RATED':
        print(f"aggregate {r['aggregate']}  indicated {r['indicated']}  adjustments {r['adjustments']} notches {r['notches']} "
              f"standalone {r['standalone']}  final {r['final']}")
        for k, (lvl, v) in r['items'].items():
            print(f"  item {k:26s} {lvl:12s} {'' if v is None else round(v, 4)}")


if __name__ == '__main__':
    show(assess('GENERAL_CORPORATE', EXAMPLE_CUR, 'ANNUAL', prior=EXAMPLE_PRIOR, qualitative=EXAMPLE_QUAL, **EXAMPLE_DATES))
