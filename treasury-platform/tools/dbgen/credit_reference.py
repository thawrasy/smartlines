#!/usr/bin/env python3
"""credit_reference.py — the credit assessment of docs/35 (version 2) computed in Python, apart from the database.

It reads tools/dbgen/credit_scorecard.json and computes, from the lines of a statement (and of the statement it is
compared with), the facilities of the platform, the credit bureau report, the product lines and the analyst's inputs:
  1. the analytical statement: the reported lines re-tabulated by the standard adjustments, with the reconciliation
     rows (docs/35 section 6), and the named quantities every metric reads;
  2. every metric of the dictionary by its pattern (RATIO, AMOUNT, DIFF, GROWTH) or by its own rule (VALUE);
  3. the score of each scorecard metric on the linear continuum, the factors with their missing weight spread inside
     the factor first, the financial and weighted aggregates;
  4. the adjustments in their order: notches (at most four down), standalone caps, group support, the override,
     absolute caps; the liquidity label, the facility grade (loss given default) and the data completeness;
  5. the risk level of every item rule, the remedies with the grade each would give (the pro-forma), and the two
     scenarios of the company's activity (stagnant market, financial crisis) with the resilience overlay.
fin.usp_ComputeCreditAssessment (db/static/047) does the same in T-SQL; db/tests/credit_assessment_tests.sql expects
the numbers this module gives for the same fixtures, so the two implementations check each other.

Usage: python3 tools/dbgen/credit_reference.py [stress case key]
"""
import copy, json, math, os, sys
import credit_methodology
from decimal import Decimal, ROUND_HALF_UP

HERE = os.path.dirname(os.path.abspath(__file__))
M = credit_methodology.load()
S = M['score_points']
GRADES = {g['notch']: g for g in M['grades']}
BY_CODE = {g['code']: g for g in M['grades']}
GR = [GRADES[n]['code'] for n in range(1, 21)]
N = {g: i + 1 for i, g in enumerate(GR)}
METRICS = {m['code']: m for m in M['metrics']}
CARDS = {c['code']: c for c in M['scorecards']}
LINES = {x['code']: x for x in M['lines']}
ADJ = {a['r']: a for a in M['adjustments'] + [x for c in M['scorecards'] for x in c['extra_adjustments']]}
REMEDIES = {r['code']: r for r in M['remedies']}
INDUSTRIES = {d['code']: d for d in M['industries']['divisions'] + M['industries'].get('activities', [])}
DIVISIONS_WITH_ACTIVITIES = {a['division'] for a in M['industries'].get('activities', [])}
CR = M['country_risk']
COUNTRIES = {c['iso2']: c for c in CR['countries']}
DRIVERS = [d['code'] for d in M['shock_drivers']]
DRV = {d['code']: d for d in M['shock_drivers']}
SCENARIOS = M['macro_scenarios']
BASE_SCENARIO = next(x['code'] for x in SCENARIOS if x['resilience_base'])
PCAT = {p['code']: p for p in M['product_categories']}
MONTHS = {'ANNUAL': 12, 'SEMIANNUAL': 6, 'QUARTERLY': 3, 'MONTHLY': 1}
CF = ('OP_CASH_FLOW', 'CFO_BEFORE_WC', 'CAPEX', 'PRINCIPAL_REPAID', 'INTEREST_PAID', 'DIVIDENDS', 'PARTNER_DRAWINGS')
LEVELS = ('LOW', 'MODERATE', 'ELEVATED', 'HIGH', 'CRITICAL')
BEST, WORST = 'BEST', 'WORST'
MID = lambda g: (BY_CODE[g]['from'] + BY_CODE[g]['to']) / 2 if g != 'Aaa' else 1.0


def rnd(x, n=0):
    """Rounding half away from zero, as T-SQL's ROUND does (Python's round goes to the even neighbour)."""
    return float(Decimal(repr(float(x))).quantize(Decimal(1).scaleb(-n), rounding=ROUND_HALF_UP))


class InputError(Exception):
    """An input the computation refuses (50064 or 50065 in the database)."""


def grid_score(v, b):
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
    return min(20, max(1, math.floor(score - 0.5) + 1))


def item_level(v, t, direction):
    for i, lim in enumerate(t):
        if (direction == 'LOWER_BETTER' and v < lim) or (direction == 'HIGHER_BETTER' and v > lim):
            return LEVELS[i]
    return 'CRITICAL'


TOTALS = {}
for _x in M['lines']:
    if _x['kind'] == 'TOTAL':
        _toks = _x['formula'].replace('+', ' + ').replace('-', ' - ').split()
        _sign, _comps = 1, []
        for _t in _toks:
            if _t == '+': _sign = 1
            elif _t == '-': _sign = -1
            else: _comps.append((_t, _sign))
        TOTALS[_x['code']] = _comps


class Stmt:
    """The lines of a statement, stored in the currency unit (SAR). A LINE absent is zero; a TOTAL absent is the sum
    of its components (as the statement module computes it); a breakdown or disclosure (OF_WHICH, DETAIL, MEMO) absent is unknown, and an OF_WHICH larger than its
    parent by more than the tolerance is ignored and reported. Flows (income statement, cash flow) are annualised."""
    def __init__(self, d, period_type='ANNUAL', tol=1.0):
        for k in d:
            assert k in LINES, f'unknown line {k}'
        self.d, self.k = d, 12 / MONTHS[period_type]
        self.inconsistent = []
        for c, v in d.items():
            x = LINES[c]
            if x['kind'] == 'OF_WHICH' and v is not None:
                p = x['parent']
                par = d.get(p)
                if p == 'AR_GROSS' and par is None and d.get('AR') is not None:
                    par = d['AR'] + (d.get('AR_ECL_ALLOWANCE') or 0)
                if par is not None and v > par + tol:
                    self.inconsistent.append(c)

    def __call__(self, c):
        if c in self.inconsistent:
            return None
        v = self.d.get(c)
        if v is None:
            if LINES[c]['kind'] == 'TOTAL':
                return sum(sign * self(x) for x, sign in TOTALS[c])
            return 0.0 if LINES[c]['kind'] == 'LINE' else None
        return v * self.k if LINES[c]['section'] in ('IS', 'CF') else v

    def z(self, c):
        v = self(c)
        return 0.0 if v is None else v

    def known(self, c):
        return self(c) is not None


def lv(state, value):
    """A metric or quantity result: (state, value); state COMPUTED, EXTREME (value BEST or WORST) or NOT_COMPUTABLE."""
    return (state, value)


C = lambda v: ('COMPUTED', v)
E = lambda w: ('EXTREME', w)
NA = ('NOT_COMPUTABLE', None)


def analytical(card, s, p, ctx):
    """The analytical statement: named quantities Q and the reconciliation rows R (docs/35 section 6)."""
    P = CARDS[card]['params']
    H = CARDS[card]['realisable_haircuts']
    ev = ctx['evidence']
    Q, R = {}, []
    def rec(code, line, bucket, amount):
        if amount:
            R.append((code, line, bucket, rnd(amount, 4)))
    rev, cogs, opex, da = s('REVENUE'), s('COGS'), s('OPEX'), s('DEPR_AMORT')
    op = s('OPERATING_PROFIT')
    impair = s.z('IMPAIRMENTS')
    ebitda = op + da + impair
    rec('ADJ_IMPAIRMENTS', 'IMPAIRMENTS', 'EBITDA', impair)
    capint = s.z('CAPITALISED_INTEREST')
    interest = max(s('FINANCE_COSTS') + capint, s('INTEREST_PAID'))
    rec('ADJ_CAP_INTEREST', 'CAPITALISED_INTEREST', 'INTEREST', capint)
    zak = s('ZAKAT_TAX')
    cf = any(s(c) not in (None, 0) for c in CF)
    ffo = s('CFO_BEFORE_WC') if s('CFO_BEFORE_WC') else ebitda - interest - zak
    restricted = s.z('CASH_RESTRICTED')
    cash_adj = s('CASH') - restricted
    rec('ADJ_RESTRICTED_CASH', 'CASH_RESTRICTED', 'NOT_CASH', restricted)
    sub_ok, cc_ok = 'SUBORDINATION' in ev, 'CAPITAL_RESOLUTION' in ev
    shl_sub = s('SHAREHOLDER_LOANS_SUB')
    shl_sub_eq = shl_sub if sub_ok else 0.0
    shl_sub_debt = 0.0 if sub_ok else shl_sub
    cc_debt = 0.0 if cc_ok else s('CAPITAL_CONTRIBUTIONS')
    rec('ADJ_SHL_SUB', 'SHAREHOLDER_LOANS_SUB', 'EQUITY' if sub_ok else 'DEBT', shl_sub)
    rec('ADJ_CAPITAL_CONTRIB', 'CAPITAL_CONTRIBUTIONS', 'EQUITY' if cc_ok else 'DEBT', s('CAPITAL_CONTRIBUTIONS'))
    fact = s.z('AR_FACTORED_RECOURSE')
    reclass = s('LT_LOANS') if ctx['breach_at_period_end'] else 0.0
    supplier = s.z('SUPPLIER_FINANCE')
    eosb = s('EOSB') * P['eosb_debt_pct'] / 100
    for code, line, bucket, amt in (('ADJ_LEASE', 'LEASE_LIABS', 'DEBT', s('LEASE_LIABS') + s('LEASE_LIABS_CURRENT')),
                                    ('ADJ_EOSB', 'EOSB', 'DEBT', eosb), ('ADJ_RELATED_DEBT', 'DUE_TO_RELATED', 'ST_DEBT', s('DUE_TO_RELATED')),
                                    ('ADJ_SHL_UNSUB', 'SHAREHOLDER_LOANS_UNSUB', 'ST_DEBT', s('SHAREHOLDER_LOANS_UNSUB')),
                                    ('ADJ_PARTNERS', 'PARTNERS_CURRENT_ACCOUNTS', 'ST_DEBT', s('PARTNERS_CURRENT_ACCOUNTS')),
                                    ('ADJ_SUPPLIER_FIN', 'SUPPLIER_FINANCE', 'ST_DEBT', supplier), ('ADJ_DIVIDENDS', 'DIVIDENDS_PAYABLE', 'ST_DEBT', s('DIVIDENDS_PAYABLE')),
                                    ('ADJ_FACTORING', 'AR_FACTORED_RECOURSE', 'ST_DEBT', fact), ('ADJ_BREACH_RECLASS', 'LT_LOANS', 'ST_DEBT', reclass)):
        rec(code, line, bucket, amt)
    st_debt = (s('ST_LOANS') + s('BANK_ACCEPTANCES') + s('CURRENT_PORTION_LTD') + s('LEASE_LIABS_CURRENT') + s('DUE_TO_RELATED')
               + s('SHAREHOLDER_LOANS_UNSUB') + s('PARTNERS_CURRENT_ACCOUNTS') + supplier + s('DIVIDENDS_PAYABLE') + fact + reclass)
    debt = (s('ST_LOANS') + s('BANK_ACCEPTANCES') + s('CURRENT_PORTION_LTD') + s('LEASE_LIABS_CURRENT') + s('LT_LOANS') + s('LEASE_LIABS')
            + s('DUE_TO_RELATED') + s('SHAREHOLDER_LOANS_UNSUB') + s('PARTNERS_CURRENT_ACCOUNTS') + supplier
            + s('DIVIDENDS_PAYABLE') + eosb + shl_sub_debt + cc_debt + fact)
    bank_debt = s('ST_LOANS') + s('BANK_ACCEPTANCES') + s('CURRENT_PORTION_LTD') + s('LT_LOANS') + fact + supplier
    # the credit bureau: debt in SIMAH above the statement's bank debt (docs/35 section 10)
    bu = ctx.get('bureau')
    hidden = 0.0
    if bu is not None:
        gap = bu['outstanding'] - bank_debt
        recent = bu.get('months_after_period_end', 0) <= 6
        if bank_debt > 0 and gap / bank_debt * 100 > M['bureau']['hidden_debt_pct'] and recent:
            hidden = gap
        elif bank_debt == 0 and bu['outstanding'] > 0 and recent:
            hidden = bu['outstanding']
        rec('ADJ_BUREAU_HIDDEN_DEBT', 'ST_LOANS', 'DEBT', hidden)
    debt += hidden
    quasi = s('TOTAL_EQUITY') + shl_sub_eq - cc_debt
    related = s('DUE_FROM_RELATED') + s.z('ADVANCES_TO_RELATED')
    over365, gov365 = s.z('AR_AGE_OVER_365'), s.z('AR_AGE_OVER_365_GOV')
    impair_ar = max(0.0, over365 - gov365 - s.z('AR_ECL_ALLOWANCE'))
    slow = max(0.0, s.z('INV_SLOW_MOVING') - s.z('INV_PROVISION')) * P['inv_slow_haircut'] / 100
    reval = max(s('REVALUATION_RESERVE'), s.z('PPE_REVALUATION_SURPLUS'))
    for code, line, bucket, amt in (('ADJ_INTANGIBLES', 'INTANGIBLES', 'NOT_TNW', s('INTANGIBLES')), ('ADJ_REVALUATION', 'REVALUATION_RESERVE', 'NOT_TNW', reval),
                                    ('ADJ_RELATED', 'DUE_FROM_RELATED', 'NOT_TNW', related), ('ADJ_AR_IMPAIR', 'AR_AGE_OVER_365', 'NOT_TNW', impair_ar),
                                    ('ADJ_AR_GOV_NONCURRENT', 'AR_AGE_OVER_365_GOV', 'NON_CURRENT', gov365), ('ADJ_INV_SLOW', 'INV_SLOW_MOVING', 'NOT_TNW', slow),
                                    ('ADJ_RETENTIONS', 'RETENTIONS_OVERDUE', 'NON_CURRENT', s.z('RETENTIONS_OVERDUE'))):
        rec(code, line, bucket, amt)
    tang_quasi = quasi - s('INTANGIBLES')
    adj_tnw = tang_quasi - reval - related - impair_ar - slow
    adj_ca = s('TOTAL_CA') - related - impair_ar - gov365 - slow - s.z('RETENTIONS_OVERDUE')
    adj_cl = s('TOTAL_CL') + s('SHAREHOLDER_LOANS_UNSUB') + reclass + fact
    adj_tl = s('TOTAL_LIABS') - shl_sub_eq + cc_debt + fact
    # break-up value: each asset after the haircut of its kind (card parameters)
    r = lambda amt, b: max(0.0, amt) * (1 - H[b] / 100)
    real = r(cash_adj, 'CASH') + r(restricted, 'CASH_RESTRICTED') + r(s('SHORT_TERM_INVESTMENTS'), 'SHORT_TERM_INVESTMENTS')
    ar = s('AR')
    dso_fb = (ar + s('CONTRACT_ASSETS')) / rev * 365 if rev > 0 else 999
    gov = s.z('AR_GOVERNMENT') + s.z('AR_SEMI_GOVERNMENT')
    relt = s.z('AR_RELATED_TRADE')
    if s.known('AR_AGE_OVER_365') and s.known('AR_AGE_181_365'):
        ng365 = max(0.0, over365 - gov365 - s.z('AR_ECL_ALLOWANCE'))
        a181 = s('AR_AGE_181_365')
        rest = max(0.0, ar - ng365 - gov365 - a181 - relt)
        gov_young = min(max(0.0, gov - gov365), rest)
        real += ng365 * (1 - H['AR_PRIVATE_OVER_365'] / 100) + gov365 * (1 - min(100, H['AR_GOVERNMENT'] + P['gov_over365_extra_haircut']) / 100)
        real += r(a181, 'AR_PRIVATE_181_365') + r(relt, 'AR_RELATED') + r(gov_young, 'AR_GOVERNMENT') + r(rest - gov_young, 'AR_PRIVATE_0_180')
    else:
        rest = max(0.0, ar - gov - relt)
        bucket = 'AR_PRIVATE_181_365' if dso_fb > P['ar_fallback_dso_days'] else 'AR_PRIVATE_0_180'
        real += r(gov, 'AR_GOVERNMENT') + r(relt, 'AR_RELATED') + r(rest, bucket)
    ca_ = s('CONTRACT_ASSETS')
    if s.known('RETENTIONS'):
        ro = s.z('RETENTIONS_OVERDUE')
        real += r(ca_ - s('RETENTIONS'), 'CONTRACT_ASSETS') + r(s('RETENTIONS') - ro, 'RETENTIONS')
        real += ro * (1 - min(100, H['RETENTIONS'] + P['retentions_overdue_extra_haircut']) / 100)
    else:
        real += r(ca_, 'RETENTIONS')
    inv = s('INVENTORY')
    if any(s.known(c) for c in ('INV_RAW', 'INV_WIP', 'INV_FINISHED', 'INV_SLOW_MOVING')):
        sl = max(0.0, s.z('INV_SLOW_MOVING') - s.z('INV_PROVISION'))
        wip, raw, fin = s.z('INV_WIP'), s.z('INV_RAW') + s.z('INV_SPARES'), s.z('INV_FINISHED') + s.z('INV_IN_TRANSIT')
        rest = max(0.0, inv - sl - wip - raw - fin)
        real += r(sl, 'INVENTORY_SLOW') + r(wip, 'INVENTORY_WIP') + r(raw + rest, 'INVENTORY_RAW') + r(fin, 'INVENTORY_FINISHED')
    else:
        real += r(inv, 'INVENTORY_RAW')
    oca = s('OTHER_CA')
    adv_rel, adv_sup, vat = s.z('ADVANCES_TO_RELATED'), s.z('ADVANCES_TO_SUPPLIERS'), s.z('VAT_RECEIVABLE')
    real += r(adv_rel, 'DUE_FROM_RELATED') + r(adv_sup, 'ADVANCES_TO_SUPPLIERS') + r(vat, 'AR_GOVERNMENT') + r(oca - adv_rel - adv_sup - vat, 'PREPAYMENTS_OTHER')
    real += r(s('DUE_FROM_RELATED'), 'DUE_FROM_RELATED')
    ppe = s('PPE') - s.z('PPE_REVALUATION_SURPLUS')
    parts = ('PPE_LAND_BUILDINGS', 'PPE_MACHINERY', 'PPE_VEHICLES', 'PPE_CWIP')
    if any(s.known(c) for c in parts):
        tot = 0.0
        for c in parts:
            real += r(s.z(c), c); tot += s.z(c)
        real += r(ppe - tot, 'PPE_OTHER')
    else:
        real += r(ppe, 'PPE_MACHINERY')
    for c in ('ROU_ASSETS', 'INVESTMENT_PROPERTY', 'INVESTMENTS_IN_ASSOCIATES', 'LT_INVESTMENTS', 'INTANGIBLES', 'LT_RECEIVABLES', 'OTHER_NCA'):
        real += r(s(c), c)
    # liquidity: twelve-month sources and uses (docs/35 section 9)
    ar_bb = max(0.0, ar - over365 - relt) * (1 - H['AR_PRIVATE_0_180'] / 100)
    inv_bb = max(0.0, inv - s.z('INV_SLOW_MOVING')) * (1 - H['INVENTORY_FINISHED'] / 100)
    plat = ctx['platform'] or {}
    trade = s('ST_LOANS') + s('BANK_ACCEPTANCES')
    roll_ok = not ctx['breach_at_period_end'] and plat.get('expiring_12m_share_pct', 0) <= P['rollover_max_expiring_pct']
    roll = P['rollover_pct'] / 100 * ctx.get('rollover_factor', 1.0) * min(trade, ar_bb + inv_bb) if roll_ok else 0.0
    pp = P['partners_liquidity_pct'] / 100
    lq_st = (s('ST_LOANS') + s('BANK_ACCEPTANCES') + s('CURRENT_PORTION_LTD') + s('LEASE_LIABS_CURRENT') + s('DUE_TO_RELATED')
             + pp * (s('PARTNERS_CURRENT_ACCOUNTS') + s('SHAREHOLDER_LOANS_UNSUB')) + supplier + s('DIVIDENDS_PAYABLE') + reclass + fact)
    pdiv = p('DIVIDENDS') if p is not None and p('DIVIDENDS') else s('DIVIDENDS')
    pdraw = p('PARTNER_DRAWINGS') if p is not None and p('PARTNER_DRAWINGS') else s('PARTNER_DRAWINGS')
    sources = cash_adj + P['sti_liquidity_pct'] / 100 * s('SHORT_TERM_INVESTMENTS') + max(ffo, 0.0) + (plat.get('committed_undrawn') or 0)
    uses = lq_st - roll + da * P['maint_capex_factor'] + pdiv + pdraw + max(-ffo, 0.0)
    # comparison statement
    pta = p('TOTAL_ASSETS') if p is not None else None
    prev = p('REVENUE') if p is not None else None
    pcogs = p('COGS') if p is not None else None
    cfo = s('OP_CASH_FLOW')
    cavg = (cfo + p('OP_CASH_FLOW')) / 2 if p is not None and p('OP_CASH_FLOW') else cfo
    principal = (p('CURRENT_PORTION_LTD') + p('LEASE_LIABS_CURRENT')) if p is not None else (s('CURRENT_PORTION_LTD') + s('LEASE_LIABS_CURRENT'))
    contingent_lines = ('LC_OUTSTANDING', 'LG_PERFORMANCE', 'LG_ADVANCE_PAYMENT', 'LG_FINANCIAL', 'GUARANTEES_GIVEN')
    Q.update(
        REVENUE=rev, COGS=cogs, OPEX=opex, GROSS_PROFIT=s('GROSS_PROFIT'), OPERATING_PROFIT=op, DEPR_AMORT=da, NET_PROFIT=s('NET_PROFIT'),
        EBITDA=ebitda, INTEREST=interest, ZAKAT_TAX=zak, FFO=ffo, CF=cf, CFO=cfo if cf else None, CFO_AVG=cavg if cf else None,
        CAPEX=s('CAPEX') if cf else None, FCF=(cfo - s('CAPEX') - s('DIVIDENDS')) if cf else None,
        FCF_PARTNERS=(cfo - s('CAPEX') - s('DIVIDENDS') - s('PARTNER_DRAWINGS')) if cf else None,
        RCF=ffo - s('DIVIDENDS') - s('PARTNER_DRAWINGS'),
        EBITDA_LESS_TAX=ebitda - zak, DEBT_SERVICE=principal + interest, CPLTD=s('CURRENT_PORTION_LTD'),
        DEBT=debt, ST_DEBT=st_debt, BANK_DEBT=bank_debt, HIDDEN_DEBT=hidden, NET_DEBT=debt - cash_adj - s('SHORT_TERM_INVESTMENTS'),
        CASH_ADJ=cash_adj, LIQUID=cash_adj + s('SHORT_TERM_INVESTMENTS'), CASH_REPORTED=s('CASH'),
        MONTHLY_CASH_COSTS=(cogs + opex - da) / 12,
        QUASI=quasi, TANG_QUASI=tang_quasi, ADJ_TNW=adj_tnw, ADJ_TL=adj_tl, ADJ_CA=adj_ca, ADJ_CL=adj_cl, NWC_ADJ=adj_ca - adj_cl,
        DEBT_PLUS_QUASI=debt + quasi, RELATED=related, TOTAL_ASSETS=s('TOTAL_ASSETS'), INTANGIBLES=s('INTANGIBLES'),
        REALISABLE=real, REALISABLE_NW=real - adj_tl, LIQ_SOURCES=sources, LIQ_USES=uses, ROLLOVER=roll,
        AVG_ASSETS=(s('TOTAL_ASSETS') + pta) / 2 if pta else s('TOTAL_ASSETS'),
        AVG_DEBT=debt, NET_PROFIT_RECURRING=s('NET_PROFIT') - s.z('NONRECURRING_GAINS') + s.z('NONRECURRING_LOSSES'),
        AR_TRADE=ar + s('CONTRACT_ASSETS'), AR=ar, INVENTORY=inv, AP=s('AP'), CA=s('TOTAL_CA'), OTHER_CA=oca,
        CONTRACT_ASSETS=s('CONTRACT_ASSETS'), CONTRACT_LIABILITIES=s('CONTRACT_LIABILITIES'),
        LIQUID_ASSETS=cash_adj + s('SHORT_TERM_INVESTMENTS') + ar + inv,
        NONOP_ASSETS=s('INVESTMENT_PROPERTY') + s('LT_INVESTMENTS') + s('INVESTMENTS_IN_ASSOCIATES') + s('DUE_FROM_RELATED') + s('OTHER_NCA'),
        PPE=s('PPE'), PPE_GROSS=s('PPE_GROSS'), PPE_ACC_DEP=None if s('PPE_ACC_DEPRECIATION') is None else abs(s('PPE_ACC_DEPRECIATION')),
        PPE_CWIP=s('PPE_CWIP'), ASSETS_PLEDGED=s('ASSETS_PLEDGED'),
        TRADE_ASSETS=ar + inv, BANK_ST_DEBT=trade, TRADE_FINANCE=s('BANK_ACCEPTANCES') + s.z('LC_OUTSTANDING'),
        REV_TOP5=s('REV_TOP5'), REV_TOP_CUSTOMER=s('REV_TOP_CUSTOMER'),
        REV_GOV=None if not (s.known('REV_GOVERNMENT') or s.known('REV_SEMI_GOVERNMENT')) else s.z('REV_GOVERNMENT') + s.z('REV_SEMI_GOVERNMENT'),
        REV_EXPORT=s('REV_EXPORT'), REV_CASH=s('REV_CASH'), REV_RELATED=s('REV_RELATED'), REV_RECURRING=s('REV_RECURRING'), BACKLOG=s('BACKLOG'),
        AR_TOP5=s('AR_TOP5'), AR_RELATED=s('AR_RELATED_TRADE'), AP_OVERDUE=s('AP_OVERDUE'), SUPPLIER_FINANCE=s('SUPPLIER_FINANCE'),
        STAFF_COSTS=s('STAFF_COSTS'), ECL_CHARGE=s('ECL_CHARGE'), NONRECURRING_GAINS=s('NONRECURRING_GAINS'),
        DEBT_SECURED=s('DEBT_SECURED'), DEBT_DUE_1Y=s('DEBT_DUE_1Y'),
        # the maturity profile needs the debt due within a year and at least one later bucket: the first alone is no profile
        DEBT_PROFILE=None if not s.known('DEBT_DUE_1Y') or not any(s.known(c) for c in ('DEBT_DUE_1_2Y', 'DEBT_DUE_2_5Y', 'DEBT_DUE_OVER_5Y'))
        else sum(s.z(c) for c in ('DEBT_DUE_1Y', 'DEBT_DUE_1_2Y', 'DEBT_DUE_2_5Y', 'DEBT_DUE_OVER_5Y')),
        FLOAT_SHOCK=None if s('DEBT_FLOATING') is None else s('DEBT_FLOATING') * P['rate_shock_pct'] / 100,
        FX_OPEN=s('NET_FX_OPEN_POSITION') if s.known('NET_FX_OPEN_POSITION') else s('DEBT_FOREIGN_CCY'),
        DUE_FROM_SHAREHOLDERS=s('DUE_FROM_SHAREHOLDERS'), DUE_TO_RELATED=s('DUE_TO_RELATED'), EOSB=s('EOSB'),
        ZAKAT_DISPUTED=s('ZAKAT_DISPUTED'), GUARANTEES_GIVEN=s('GUARANTEES_GIVEN'), LEGAL_CLAIMS=s('LEGAL_CLAIMS'),
        PURCHASES_RELATED=s('PURCHASES_RELATED'), PARTNERS_ON_DEMAND=s('PARTNERS_CURRENT_ACCOUNTS') + s('SHAREHOLDER_LOANS_UNSUB'),
        CONTINGENT=None if not any(s.known(c) for c in contingent_lines) else sum(s.z(c) for c in contingent_lines),
        P_REVENUE=prev, DPO_DAYS=s('AP') / cogs * 365 if cogs > 0 else None,
        P_DPO_DAYS=(p('AP') / pcogs * 365) if p is not None and pcogs else None,
        FAC_LIMITS=(plat.get('limits') or 0.0), FAC_OUTSTANDING=(plat.get('outstanding') or 0.0), UNDRAWN_COMMITTED=(plat.get('committed_undrawn') or 0.0),
        GUARANTOR_LIQUID=None, GUARANTEED=None, GUARANTOR_GIVEN=None, GUARANTOR_NET_WORTH=None,
    )
    gu = ctx.get('guarantors')
    if gu:
        Q.update(GUARANTOR_LIQUID=sum(g['liquid'] for g in gu), GUARANTEED=sum(g['guaranteed'] for g in gu),
                 GUARANTOR_GIVEN=sum(g['given'] for g in gu), GUARANTOR_NET_WORTH=sum(g['net_worth'] for g in gu))
    # fixed costs and the breakeven (card's fixed_cost_rule)
    fr = CARDS[card]['fixed_cost_rule']
    ga, sd = s('GENERAL_ADMIN'), s('SELLING_DISTRIBUTION')
    if ga is None and sd is None:
        fixed = da + s('FINANCE_COSTS') + fr['fallback_opex_fixed_pct'] / 100 * max(0.0, opex - da + s.z('COGS_DEPRECIATION'))
    else:
        fixed = (da + s('FINANCE_COSTS') + s.z('RENT_SHORT_TERM') + (ga or 0)
                 + fr['staff_fixed_pct'] / 100 * max(0.0, s.z('STAFF_COSTS') - fr['ga_staff_share_pct'] / 100 * (ga or 0))
                 + fr['selling_fixed_pct'] / 100 * (sd or 0))
    total_costs = cogs + opex + s('FINANCE_COSTS')
    fixed = min(fixed, total_costs)
    Q.update(FIXED_COSTS=fixed, TOTAL_COSTS=total_costs)
    return Q, R


def metric_pattern(md, Q):
    """A metric by its pattern (docs/35 section 4): unknown term, then the denominator zero, the numerator zero, the
    denominator negative and the numerator negative, each by the metric's rule, else the ratio."""
    num = Q.get(md['num'])
    den = Q.get(md.get('den')) if md.get('den') else None
    if num is None or (md.get('den') and den is None):
        return NA
    pat = md['pattern']
    if pat == 'AMOUNT':
        if num <= 0 and md.get('nn') == 'WORST':
            return E(WORST)
        return C(num)
    if pat == 'DIFF':
        return C(num - den)
    if pat == 'GROWTH':
        return NA if den <= 0 else C((num - den) / den * 100)
    dz, nz, dn, nn = md['dz'], md['nz'], md['dn'], md['nn']
    if den == 0:
        if dz == 'BEST' or (dz == 'BEST_IF_NUM_POS' and num > 0) or (dz == 'BEST_IF_NUM_NONNEG' and num >= 0):
            return E(BEST)
        if dz in ('WORST', 'BEST_IF_NUM_POS', 'BEST_IF_NUM_NONNEG'):
            return E(WORST)
        return NA
    if num == 0:
        if nz == 'VALUE0':
            return C(0.0)
        if nz == 'WORST':
            return E(WORST)
        if nz == 'BEST_IF_DEN_POS' and den > 0:
            return E(BEST)
    if den < 0:
        if dn == 'WORST':
            return E(WORST)
        if dn == 'NA':
            return NA
    if num < 0:
        if nn == 'WORST':
            return E(WORST)
        if nn == 'NA':
            return NA
        if nn == 'BEST_IF_DEN_POS' and den > 0:
            return E(BEST)
    return C(num / den * md['scale'])


def metric_values(card, s, p, Q, ctx):
    """The metrics whose rule does not fit a pattern (VALUE)."""
    rev, cogs = Q['REVENUE'], Q['COGS']
    V = {}
    ms = ctx.get('market_size')
    V['MARKET_SHARE'] = NA if not ms or rev <= 0 or rev / ms * 100 > 100 else C(rev / ms * 100)
    cash = s('CASH')
    if cash == 0: V['RESTRICTED_CASH_SHARE'] = C(0.0)
    elif s.known('CASH_RESTRICTED'): V['RESTRICTED_CASH_SHARE'] = C(s('CASH_RESTRICTED') / cash * 100)
    else: V['RESTRICTED_CASH_SHARE'] = NA
    dso = Q['AR_TRADE'] / rev * 365 if rev > 0 else None
    dio = Q['INVENTORY'] / cogs * 365 if cogs > 0 else None
    dpo = Q['AP'] / cogs * 365 if cogs > 0 else None
    V['CASH_CYCLE'] = NA if None in (dso, dio, dpo) else C(dso + dio - dpo)
    gross = s('AR_GROSS') if s.known('AR_GROSS') else (s('AR') + s.z('AR_ECL_ALLOWANCE'))
    if s('AR') == 0: V['AR_OVER_180_SHARE'] = C(0.0)
    elif s.known('AR_AGE_181_365') and s.known('AR_AGE_OVER_365') and gross > 0:
        V['AR_OVER_180_SHARE'] = C((s('AR_AGE_181_365') + s('AR_AGE_OVER_365')) / gross * 100)
    else: V['AR_OVER_180_SHARE'] = NA
    if s('AR') == 0: V['AR_OVER_365_SHARE'] = C(0.0)
    elif s.known('AR_AGE_OVER_365') and gross > 0: V['AR_OVER_365_SHARE'] = C(s('AR_AGE_OVER_365') / gross * 100)
    else: V['AR_OVER_365_SHARE'] = NA
    if not (s.known('AR_AGE_OVER_365') and s.known('AR_ECL_ALLOWANCE')): V['ECL_COVERAGE_365'] = NA
    else:
        priv = s('AR_AGE_OVER_365') - s.z('AR_AGE_OVER_365_GOV')
        V['ECL_COVERAGE_365'] = E(BEST) if priv <= 0 else C(s('AR_ECL_ALLOWANCE') / priv * 100)
    def growth_gap(cur, pri, base, pbase):
        if p is None or pri is None or pri <= 0 or pbase is None or pbase <= 0 or base is None:
            return NA
        return C((cur - pri) / pri * 100 - (base - pbase) / pbase * 100)
    V['AR_GROWTH_VS_REVENUE'] = growth_gap(Q['AR_TRADE'], None if p is None else p('AR') + p('CONTRACT_ASSETS'), rev, Q['P_REVENUE'])
    V['INV_GROWTH_VS_COGS'] = growth_gap(Q['INVENTORY'], None if p is None else p('INVENTORY'), cogs, None if p is None else p('COGS'))
    inv = s('INVENTORY')
    if inv == 0: V['INV_SLOW_SHARE'] = C(0.0)
    elif s.known('INV_SLOW_MOVING'): V['INV_SLOW_SHARE'] = C(s('INV_SLOW_MOVING') / inv * 100)
    else: V['INV_SLOW_SHARE'] = NA
    if not (s.known('INV_SLOW_MOVING') and s.known('INV_PROVISION')): V['INV_PROVISION_COVERAGE'] = NA
    elif s('INV_SLOW_MOVING') == 0: V['INV_PROVISION_COVERAGE'] = E(BEST)
    else: V['INV_PROVISION_COVERAGE'] = C(s('INV_PROVISION') / s('INV_SLOW_MOVING') * 100)
    if s.known('RETENTIONS') and s('RETENTIONS') > 0 and s.known('RETENTIONS_OVERDUE'):
        V['RETENTIONS_OVERDUE_SHARE'] = C(s('RETENTIONS_OVERDUE') / s('RETENTIONS') * 100)
    else: V['RETENTIONS_OVERDUE_SHARE'] = NA
    if not ctx['holding_standalone']: V['DOUBLE_LEVERAGE'] = NA
    else:
        base = Q['QUASI']
        inva = s('INVESTMENTS_IN_ASSOCIATES')
        V['DOUBLE_LEVERAGE'] = C(0.0) if inva == 0 else E(WORST) if base <= 0 else C(inva / base * 100)
    if s.known('PURCHASES_TOP5'):
        b = s('COGS_MATERIALS') if s.known('COGS_MATERIALS') and s('COGS_MATERIALS') > 0 else cogs
        V['AP_TOP5_SHARE'] = NA if b <= 0 else C(s('PURCHASES_TOP5') / b * 100)
    elif s.known('AP_TOP5'):
        V['AP_TOP5_SHARE'] = NA if s('AP') <= 0 else C(s('AP_TOP5') / s('AP') * 100)
    else: V['AP_TOP5_SHARE'] = NA
    plat = ctx['platform'] or {}
    V['LARGEST_LENDER_SHARE'] = C(plat['largest_lender_share_pct']) if plat.get('limits') else NA
    V['FACILITIES_EXPIRING_12M_SHARE'] = C(plat['expiring_12m_share_pct']) if plat.get('limits') else NA
    # collateral cover: the platform's recoverable cover over the exposure, else the pledged assets over secured debt
    L = M['lgd']
    if plat.get('collateral'):
        expo = max(plat.get('limits') or 0, plat.get('outstanding') or 0)
        rec = sum(cv * (1 - L['collateral_haircuts'][k] / 100) for k, cv in plat['collateral'])
        V['COLLATERAL_COVERAGE'] = NA if expo <= 0 else C(rec / expo)
    elif s.known('DEBT_SECURED') and s('DEBT_SECURED') > 0 and s.known('ASSETS_PLEDGED'):
        V['COLLATERAL_COVERAGE'] = C(s('ASSETS_PLEDGED') * (1 - L['collateral_haircuts']['GENERIC'] / 100) / s('DEBT_SECURED'))
    else: V['COLLATERAL_COVERAGE'] = NA
    dd = s('DIVIDENDS') + s('PARTNER_DRAWINGS')
    if not Q['CF']: V['PARTNER_DRAWINGS_TO_CFO'] = NA
    elif dd == 0: V['PARTNER_DRAWINGS_TO_CFO'] = C(0.0)
    elif Q['FFO'] <= 0: V['PARTNER_DRAWINGS_TO_CFO'] = E(WORST)
    else: V['PARTNER_DRAWINGS_TO_CFO'] = C(dd / Q['FFO'] * 100)
    fixed, total = Q['FIXED_COSTS'], Q['TOTAL_COSTS']
    var = max(0.0, total - fixed)
    cm = (rev - var) / rev if rev > 0 else -1
    if cm <= 0: V['BREAKEVEN_SAFETY_MARGIN'] = E(WORST)
    elif fixed == 0: V['BREAKEVEN_SAFETY_MARGIN'] = C(100.0)
    else: V['BREAKEVEN_SAFETY_MARGIN'] = C((rev - fixed / cm) / rev * 100)
    nd, rcf = Q['NET_DEBT'], Q['RCF']
    if nd <= 0: V['RCF_TO_NET_DEBT'] = E(BEST) if rcf >= 0 else NA
    else: V['RCF_TO_NET_DEBT'] = C(rcf / nd * 100)
    re_, sc = s('RETAINED_EARNINGS'), s('SHARE_CAPITAL')
    if re_ >= 0: V['ACC_LOSS_TO_CAPITAL'] = E(BEST)
    elif sc <= 0: V['ACC_LOSS_TO_CAPITAL'] = NA
    else: V['ACC_LOSS_TO_CAPITAL'] = C(-re_ / sc * 100)
    if p is None: V['GROSS_MARGIN_CHANGE'] = NA
    else:
        pr = p('REVENUE')
        V['GROSS_MARGIN_CHANGE'] = NA if rev <= 0 or not pr or pr <= 0 else C(Q['GROSS_PROFIT'] / rev * 100 - p('GROSS_PROFIT') / pr * 100)
    eb = Q['EBITDA']
    if not Q['CF']: V['CFO_TO_EBITDA'] = NA
    elif eb <= 0: V['CFO_TO_EBITDA'] = E(WORST) if Q['CFO'] < 0 else NA
    else: V['CFO_TO_EBITDA'] = C(Q['CFO'] / eb * 100)
    np_, dv = Q['NET_PROFIT'], s('DIVIDENDS')
    if dv == 0: V['PAYOUT_RATIO'] = E(BEST) if np_ > 0 else NA
    elif np_ <= 0: V['PAYOUT_RATIO'] = E(WORST)
    else: V['PAYOUT_RATIO'] = C(dv / np_ * 100)
    # products of the fiscal year (owner request 2026-10-19, second message)
    mix = ctx.get('product_mix') or []
    ind = INDUSTRIES.get(ctx.get('industry')) if ctx.get('industry') else None
    if mix:
        rw = sum(m['revenue_share_pct'] for m in mix)
        V['PRODUCT_CASH_FLOW_QUALITY'] = NA if rw <= 0 else C(sum(PCAT[m['category']]['cash_flow_quality'] * m['revenue_share_pct'] for m in mix) / rw)
        V['PRODUCT_CONCENTRATION'] = NA if rw <= 0 else C(max(m['revenue_share_pct'] for m in mix) / rw * 100)
        iw = sum(m.get('inventory_share_pct', 0) for m in mix)
        cats = [(PCAT[m['category']], m.get('inventory_share_pct', 0)) for m in mix] if iw > 0 else [(PCAT[m['category']], 1) for m in mix]
    elif ind:
        V['PRODUCT_CASH_FLOW_QUALITY'] = NA; V['PRODUCT_CONCENTRATION'] = NA
        cats = [(PCAT[c], 1) for c in ind['product_categories']]
    else:
        V['PRODUCT_CASH_FLOW_QUALITY'] = NA; V['PRODUCT_CONCENTRATION'] = NA
        cats = []
    if cats:
        w = sum(x for _, x in cats)
        V['INVENTORY_CRISIS_VALUE'] = C(sum(c['inventory_value_pct']['FINANCIAL_CRISIS'] * x for c, x in cats) / w)
        V['INVENTORY_DAYS_TO_SELL_STAGNANT'] = C(sum(c['days_to_sell']['STAGNANT_MARKET'] * x for c, x in cats) / w)
    else:
        V['INVENTORY_CRISIS_VALUE'] = NA; V['INVENTORY_DAYS_TO_SELL_STAGNANT'] = NA
    bu = ctx.get('bureau')
    bd = Q['BANK_DEBT']
    if bu is None: V['BUREAU_DEBT_GAP'] = NA
    elif bd <= 0: V['BUREAU_DEBT_GAP'] = C(0.0) if bu['outstanding'] == 0 else E(WORST)
    else: V['BUREAU_DEBT_GAP'] = C((bu['outstanding'] - bd) / bd * 100)
    return V


def all_metrics(card, s, p, Q, ctx, fx, unit):
    m = {}
    vals = metric_values(card, s, p, Q, ctx)
    for code, md in METRICS.items():
        if md['kind'] != 'QUANTITATIVE':
            continue
        if md['pattern'] == 'VALUE':
            m[code] = vals[code]
        else:
            m[code] = metric_pattern(md, Q)
            if md['pattern'] == 'AMOUNT' and m[code][0] == 'COMPUTED':
                m[code] = C(m[code][1] * fx / unit)
    return m


def sgl(cov_state):
    st, v = cov_state
    t = M['liquidity']['sgl']
    if st == 'NOT_COMPUTABLE': return None
    if v == BEST: return 'SGL-1'
    if v == WORST: return 'SGL-4'
    return 'SGL-1' if v >= t[0] else 'SGL-2' if v >= t[1] else 'SGL-3' if v >= t[2] else 'SGL-4'


def completeness(card, s, Q):
    """The disclosures the methodology asks for and those the statement gives (docs/35 section 11); and the data the
    report requests besides them (the bureau report, the product mix, the extra disclosures of the activity)."""
    ta = s('TOTAL_ASSETS')
    checks = []
    def chk(name, cond, given):
        if cond: checks.append((name, given))
    chk('AR_AGING', s('AR') > 0.05 * ta, all(s.known(c) for c in ('AR_AGE_0_90', 'AR_AGE_91_180', 'AR_AGE_181_365', 'AR_AGE_OVER_365')))
    chk('AR_ALLOWANCE', s('AR') > 0.05 * ta, s.known('AR_GROSS') or s.known('AR_ECL_ALLOWANCE'))
    chk('CUSTOMER_CONCENTRATION', s('REVENUE') > 0, s.known('REV_TOP5') or s.known('REV_TOP_CUSTOMER'))
    chk('INVENTORY_BREAKDOWN', s('INVENTORY') > 0.05 * ta, s.known('INV_SLOW_MOVING'))
    chk('RESTRICTED_CASH', s('BANK_ACCEPTANCES') > 0 or any(s.z(c) > 0 for c in ('LC_OUTSTANDING', 'LG_PERFORMANCE', 'LG_FINANCIAL', 'LG_ADVANCE_PAYMENT')), s.known('CASH_RESTRICTED'))
    chk('DEBT_MATURITY', Q['DEBT'] > 0, s.known('DEBT_DUE_1Y'))
    chk('DEBT_SECURED', Q['DEBT'] > 0, s.known('DEBT_SECURED'))
    chk('COST_BREAKDOWN', True, s.known('STAFF_COSTS') and (s.known('GENERAL_ADMIN') or s.known('SELLING_DISTRIBUTION')))
    chk('CONTINGENTS', True, any(s.known(c) for c in ('LC_OUTSTANDING', 'LG_PERFORMANCE', 'LG_FINANCIAL', 'LG_ADVANCE_PAYMENT', 'GUARANTEES_GIVEN')))
    chk('RETENTIONS', s('CONTRACT_ASSETS') > 0, s.known('RETENTIONS'))
    chk('BACKLOG', card == 'CONTRACTING', s.known('BACKLOG'))
    chk('RELATED_BREAKDOWN', s('DUE_FROM_RELATED') > 0, s.known('DUE_FROM_SHAREHOLDERS'))
    chk('PPE_BREAKDOWN', s('PPE') > 0.1 * ta, any(s.known(c) for c in ('PPE_LAND_BUILDINGS', 'PPE_MACHINERY', 'PPE_VEHICLES')))
    given = sum(1 for _, g in checks if g)
    pct = rnd(given / len(checks) * 100, 2) if checks else 100.0
    return pct, [n for n, g in checks if not g]


def data_requests(card, s, ctx, missing):
    """What the report asks the company for (docs/35 section 11)."""
    req = [('DISCLOSURE', m) for m in missing]
    if ctx.get('bureau') is None:
        req.append(('BUREAU_REPORT', 'SIMAH'))
    if not ctx.get('product_mix'):
        req.append(('PRODUCT_MIX', 'PRODUCT_LINES'))
    if ctx.get('country') not in COUNTRIES:
        req.append(('COUNTRY_PROFILE', ctx.get('country') or 'NONE'))
    if not ctx.get('industry'):
        req.append(('INDUSTRY', 'ISIC'))
    else:
        if ctx['industry'] in DIVISIONS_WITH_ACTIVITIES:
            req.append(('INDUSTRY_DETAIL', ctx['industry']))
        cp = COUNTRIES.get(ctx.get('country'))
        if INDUSTRIES[ctx['industry']]['sens']['REAL_ESTATE'] >= 4 and cp and cp.get('regions') and not ctx.get('region'):
            req.append(('MARKET_REGION', ctx['country']))
        for c in INDUSTRIES[ctx['industry']]['disclosures']:
            if c in LINES and not s.known(c) and ('DISCLOSURE', c) not in req:
                req.append(('INDUSTRY_DISCLOSURE', c))
    if s.inconsistent:
        req.extend(('INCONSISTENT', c) for c in s.inconsistent)
    return req


def country_profile(country):
    """The country's risk profile, or the default one for a country without a profile (docs/35 section 13)."""
    return COUNTRIES.get(country) or CR['default']


def country_ceiling(country):
    """The ceiling of a company's grade in its country: the published sovereign rating, or the ceiling of its country
    risk when it has none."""
    c = country_profile(country)
    g = c.get('sovereign_rating') or CR['unrated_ceiling'][str(c['country_risk'])]
    return 'Ca' if g == 'C' else g   # a sovereign in default (C): the scale of a company's grade ends at Ca


def anchor_notch(industry, country):
    """The country and industry risk anchor (docs/35 section 13): the matrix cell of the country risk and the industry
    risk, high cyclicality one notch worse and low one better."""
    d = INDUSTRIES[industry]
    n = CR['anchor'][country_profile(country)['country_risk'] - 1][d['industry_risk'] - 1] + CR['cyclicality_notch'][d['cyclicality']]
    return min(20, max(1, n))


def sector_risk_score(industry, country):
    """The computed SECTOR_RISK sub-factor of the business profile: the anchor notch as a score."""
    if not industry:
        return None
    return float(anchor_notch(industry, country))


def qualitative_score(card, factor, qual, subfactors, industry, country):
    """A qualitative factor: the analyst's grade (its midpoint), or the average of the graded sub-factors when at least
    the minimum are graded; for the business profile the computed sector risk joins the average."""
    subs = CARDS[card]['qualitative'].get(factor, [])
    graded = (subfactors or {}).get(factor) or {}
    vals = None
    if qual and factor in qual and qual[factor]:
        vals = [MID(qual[factor])] * max(1, len(subs))
    elif len(graded) >= M['subfactor_minimum']:
        vals = [MID(g) for g in graded.values()]
    if vals is None:
        return None
    if factor == 'BUSINESS_PROFILE':
        sr = sector_risk_score(industry, country)
        if sr is not None:
            vals = vals + [sr]
    return rnd(sum(vals) / len(vals), 4)


def months_between(a, b):
    return (b[0] - a[0]) * 12 + b[1] - a[1]


def applied_adjustments(card, s, p, Q, m, ctx, opts):
    """The adjustments that apply, each (code, notches, cap, stage), in the methodology's order (docs/35 section 8)."""
    out = []
    def add(code, n=None, cap=None):
        a = ADJ[code]
        out.append((code, a['n'] if n is None else n, a['cap'] if cap is None else cap, a['stage']))
    P = lambda code: ADJ[code]['p']
    if opts['assurance'] == 'MANAGEMENT' and opts['period_type'] == 'ANNUAL': add('UNAUDITED_ANNUAL')
    if opts['opinion'] == 'QUALIFIED': add('AUDIT_QUALIFIED')
    if opts.get('statement_age_months') is not None and opts['statement_age_months'] > P('STALE_STATEMENT'): add('STALE_STATEMENT')
    if not Q['CF']: add('INCOMPLETE_STATEMENT')
    if opts.get('restated_change_pct') is not None and opts['restated_change_pct'] > P('RESTATEMENT'): add('RESTATEMENT')
    if ctx['holding_standalone']: add('HOLDCO_STANDALONE')
    if opts['breach'] == 'OPEN': add('OPEN_BREACH')
    if opts['breach'] == 'WAIVER_REQUESTED': add('BREACH_WAIVER_REQUESTED')
    if opts.get('flow_shortfall'): add('FLOW_SHORTFALL')
    sc = s('SHARE_CAPITAL')
    st, al = m['ACC_LOSS_TO_CAPITAL']
    lost = st == 'COMPUTED' and al >= P('HALF_CAPITAL_LOST')
    cured = Q['QUASI'] >= sc
    if lost and cured: add('HALF_CAPITAL_LOST_CURED')
    rel_exp = Q['RELATED'] + (s('GUARANTEES_GIVEN_RELATED') if s.known('GUARANTEES_GIVEN_RELATED') else s.z('GUARANTEES_GIVEN'))
    rel_on = rel_exp > 0 and (Q['ADJ_TNW'] <= 0 or rel_exp > P('RELATED_PARTY_EXPOSURE') / 100 * Q['ADJ_TNW'])
    if rel_on: add('RELATED_PARTY_EXPOSURE')
    lab = sgl(m['LIQUIDITY_COVERAGE'])
    if lab == 'SGL-4':
        add('LIQUIDITY_SGL4')
        cv = m['LIQUIDITY_COVERAGE']
        if cv == E(WORST) or (cv[0] == 'COMPUTED' and cv[1] < M['liquidity']['severe_below']): add('LIQUIDITY_SEVERE')
    tc = m['REV_TOP_CUSTOMER_SHARE']
    cp = lambda code: ADJ[code].get('card_p', {}).get(card, P(code))
    if tc[0] == 'COMPUTED' and tc[1] > cp('CUSTOMER_CONCENTRATION'):
        gov_top = s.known('REV_GOVERNMENT') and s('REV_GOVERNMENT') >= s('REV_TOP_CUSTOMER')
        bl = m['BACKLOG_COVERAGE']
        if not (gov_top and bl[0] == 'COMPUTED' and bl[1] >= 1):
            add('CUSTOMER_CONCENTRATION')
            if tc[1] > cp('CUSTOMER_CONCENTRATION_HIGH'): add('CUSTOMER_CONCENTRATION_HIGH')
    comp = ctx['completeness']
    if comp < P('INFORMATION_RISK'): add('INFORMATION_RISK')
    if comp < P('INFORMATION_RISK_SEVERE'): add('INFORMATION_RISK_SEVERE')
    drain = s('PARTNER_DRAWINGS') + (max(0.0, s('DUE_FROM_RELATED') - p('DUE_FROM_RELATED')) if p is not None else 0.0)
    if drain > 0 and (Q['FFO'] <= 0 or drain > P('RELATED_PARTY_DRAIN') / 100 * Q['FFO']) and not rel_on: add('RELATED_PARTY_DRAIN')
    fxm = m['FX_EXPOSURE_TO_TNW']
    hedged = s.z('DERIVATIVES_NOTIONAL') >= 0.5 * (Q['FX_OPEN'] or 0)
    if (fxm == E(WORST) or (fxm[0] == 'COMPUTED' and fxm[1] > P('FX_UNHEDGED'))) and not hedged: add('FX_UNHEDGED')
    # the credit bureau (SIMAH) report
    bu = ctx.get('bureau')
    if bu is not None:
        rev_m = Q['REVENUE']
        if bu.get('current_default'): add('BUREAU_CURRENT_DEFAULT')
        if bu.get('worst_dpd_12m', 0) >= 90 and not bu.get('current_default'): add('BUREAU_DPD90_12M')
        elif 60 <= bu.get('worst_dpd_12m', 0) < 90: add('BUREAU_DPD60_89')
        elif 30 <= bu.get('worst_dpd_12m', 0) < 60: add('BUREAU_DPD30_59')
        if bu.get('defaults_24m', 0) > 0 and not bu.get('current_default') and bu.get('worst_dpd_12m', 0) < 90: add('BUREAU_DEFAULT_24M')
        bc, ba = bu.get('bounced_count', 0), bu.get('bounced_amount', 0)
        if bc >= 6 or (rev_m > 0 and ba > 0.02 * rev_m): add('BUREAU_BOUNCED_CHEQUES_SEVERE')
        elif bc >= 3 or (rev_m > 0 and ba > 0.005 * rev_m): add('BUREAU_BOUNCED_CHEQUES')
        ja, tnw = bu.get('judgments_amount', 0), Q['ADJ_TNW']
        if ja > 0 and ((tnw > 0 and ja > 0.10 * tnw)): add('BUREAU_JUDGMENTS_MATERIAL')
        elif ja > 0 and ((tnw > 0 and ja > 0.02 * tnw) or (tnw <= 0 and ja > 1e6)): add('BUREAU_JUDGMENTS')
        if bu.get('restructured'): add('BUREAU_RESTRUCTURED')
        if bu.get('inquiries_6m', 0) > 6: add('BUREAU_INQUIRIES')
        plat = ctx['platform'] or {}
        if bu.get('lenders', 0) >= (plat.get('lenders') or 0) + 2 or (plat.get('limits') and bu.get('limits', 0) > 1.25 * plat['limits']):
            add('BUREAU_LENDERS_NOT_ON_PLATFORM')
        if Q['HIDDEN_DEBT'] > 0: add('BUREAU_HIDDEN_DEBT')
    if opts.get('resilience_notch'): add('RESILIENCE')
    # standalone caps
    if lost and not cured: add('HALF_CAPITAL_LOST')
    if opts['going_concern']: add('GOING_CONCERN')
    if Q['QUASI'] <= 0: add('NEGATIVE_EQUITY')
    rs = m['REVENUE_SIZE']
    for code in ('SIZE_CEILING', 'SIZE_CEILING_MID', 'SIZE_CEILING_SMALL', 'SIZE_CEILING_MICRO'):
        if rs == E(WORST) or (rs[0] == 'COMPUTED' and rs[1] < cp(code)): add(code)
    if lab == 'SGL-4': add('LIQUIDITY_SGL4_CAP')
    for ad in CARDS[card]['extra_adjustments']:
        if ad['r'] == 'SECTOR_CEILING': add('SECTOR_CEILING')
    if ctx.get('industry') and INDUSTRIES[ctx['industry']].get('ceiling'):
        add('INDUSTRY_CEILING', cap=INDUSTRIES[ctx['industry']]['ceiling'])
    if opts['opinion'] in ('ADVERSE', 'DISCLAIMER'): add('AUDIT_ADVERSE')
    add('SOVEREIGN_CEILING', cap=country_ceiling(ctx.get('country')))
    return out


def facility_grade(obligor_notch, s, Q, plat, guarantors):
    """The facility grade (bank ORR / FRR practice, Moody's LGD bands, Fitch recovery ratings): docs/35 section 10."""
    L = M['lgd']
    plat = plat or {}
    if not plat.get('collateral') and not plat.get('limits'):
        return None
    expo = max(plat.get('limits') or 0, plat.get('outstanding') or 0)
    if expo <= 0:
        return None
    sec = min(expo, sum(cv * (1 - L['collateral_haircuts'][k] / 100) for k, cv in plat.get('collateral') or []))
    P = CARDS[next(iter(CARDS))]['params']
    base_ur = P['unsecured_recovery_pct']
    enc = s('ASSETS_PLEDGED')
    if enc is not None and s('TOTAL_ASSETS') > 0:
        ur = max(P['unsecured_recovery_floor_pct'], base_ur * (1 - enc / s('TOTAL_ASSETS')))
    elif s.known('DEBT_SECURED') and Q['DEBT'] > 0:
        ur = max(P['unsecured_recovery_floor_pct'], base_ur * (1 - s('DEBT_SECURED') / Q['DEBT']))
    else:
        ur = base_ur
    lgd = 100 * (1 - (sec + ur / 100 * (expo - sec)) / expo)
    band = next(b for b in L['bands'] if lgd <= b['max_lgd_pct'] + 1e-9)
    up = band['notches']
    g = 0
    if guarantors:
        lnw = sum(x['liquid'] for x in guarantors)
        lev = max((x['given'] / x['net_worth'] * 100 if x['net_worth'] > 0 else 999.0) for x in guarantors)
        for u in L['guarantor_uplift']:
            if lnw / expo >= u['min_coverage'] and lev <= u['max_guarantor_leverage_pct']:
                g = u['notches']
    tot = up + g
    if tot > 0:
        tot = min(tot, L['max_up'] if obligor_notch < 19 else L['max_up_near_default'])
        fn = max(N[L['best_facility_grade']], obligor_notch - tot)
    else:
        fn = min(20, obligor_notch - tot)
    return dict(lgd=rnd(lgd, 4), band=band['code'], recovery=M['fitch']['recovery'][band['code']], grade=GR[fn - 1], notch=fn,
                unsecured_recovery=rnd(ur, 4))


def assess(card, cur, *, prior=None, period_type='ANNUAL', prior_period_type='ANNUAL', fx=1.0, qual=None, subfactors=None,
           documented=(), ev=(), breach=None, breach_at_period_end=False, assurance='AUDITED', opinion='UNQUALIFIED',
           going_concern=False, holding=False, basis=None, platform=None, support=None, parent_notch=None, override=0,
           guarantors=None, bureau=None, industry=None, product_mix=None, market_size=None, statement_age_months=None,
           restated_change_pct=None, flow_shortfall=False, rollover_factor=1.0, resilience_notch=False, proforma=False,
           with_remedies=True, with_scenarios=True, with_plans=False, country='SA', region=None):
    """cur and prior: lines in SAR. Returns the full result (docs/35 sections 3 to 14)."""
    c = CARDS[card]
    s = Stmt(cur, period_type)
    p = Stmt(prior, prior_period_type) if prior is not None else None
    holding_standalone = bool(holding) and (basis or 'STANDALONE') == 'STANDALONE'
    ctx = dict(evidence=set(ev), breach_at_period_end=breach_at_period_end, platform=platform, guarantors=guarantors, bureau=bureau,
               industry=industry, product_mix=product_mix, market_size=market_size, holding_standalone=holding_standalone,
               rollover_factor=rollover_factor, country=country, region=region)
    Q, R = analytical(card, s, p, ctx)
    m = all_metrics(card, s, p, Q, ctx, fx, c['amount_unit'])
    rows = []
    for sm in c['metrics']:
        md = METRICS[sm['m']]
        if md['kind'] == 'QUALITATIVE':
            sc = qualitative_score(card, sm['m'], qual, subfactors, industry, country)
            rows.append(dict(m=sm['m'], f=sm['f'], w=sm['w'], st='ANALYST' if sc is not None else 'NOT_COMPUTABLE', v=None, score=sc, qual=True))
            continue
        st, v = m[sm['m']]
        if st == 'NOT_COMPUTABLE':
            rows.append(dict(m=sm['m'], f=sm['f'], w=sm['w'], st=st, v=None, score=None, qual=False)); continue
        score = S[0] if v == BEST else S[8] if v == WORST else grid_score(v, sm['b'])
        rows.append(dict(m=sm['m'], f=sm['f'], w=sm['w'], st=st, v=None if st == 'EXTREME' else v, score=rnd(score, 4), qual=False))
    # a missing metric's weight goes to the scored metrics of its factor; a factor with none scored leaves its weight out
    for f in {r['f'] for r in rows}:
        rs = [r for r in rows if r['f'] == f]
        have = [r for r in rs if r['score'] is not None]
        miss = sum(r['w'] for r in rs if r['score'] is None)
        tot = sum(r['w'] for r in have)
        for r in rs:
            r['eff'] = (r['w'] + miss * r['w'] / tot) if r['score'] is not None else 0.0
    qw = sum(r['w'] for r in rows if not r['qual'])
    coverage = rnd(sum(r['w'] for r in rows if not r['qual'] and r['score'] is not None) / qw * 100, 2)
    comp, missing = completeness(card, s, Q)
    ctx['completeness'] = comp
    items = {}
    for ir in c['items']:
        st, v = m[ir['r']]
        items[(ir['r'], ir['line'])] = ('NOT_ASSESSED', None) if st == 'NOT_COMPUTABLE' else \
            (('LOW' if v == BEST else 'CRITICAL'), None) if st == 'EXTREME' else (item_level(v, ir['t'], METRICS[ir['r']]['dir']), v)
    res = dict(card=card, Q=Q, reclass=R, metrics=m, rows=rows, coverage=coverage, completeness=comp, missing=missing, items=items,
               requests=data_requests(card, s, ctx, missing), inconsistent=s.inconsistent, liquidity=sgl(m['LIQUIDITY_COVERAGE']))
    if coverage < c['min_coverage']:
        return dict(res, state='INSUFFICIENT_DATA')
    qr = [r for r in rows if not r['qual'] and r['score'] is not None]
    fin = rnd(sum(r['score'] * r['eff'] for r in qr) / sum(r['eff'] for r in qr), 4)
    fin_notch = notch_of(fin)
    res.update(financial=fin, financial_grade=GR[fin_notch - 1])
    quals = [r for r in rows if r['qual']]
    if any(r['score'] is None for r in quals):
        return dict(res, state='INDICATIVE')
    if not proforma:
        for r in quals:
            if fin_notch - notch_of(r['score']) > M['qualitative_bound'] and r['m'] not in documented:
                raise InputError(f"{r['m']} more than {M['qualitative_bound']} notches better than the financial grade without a document")
    scored = [r for r in rows if r['score'] is not None]
    agg = rnd(sum(r['score'] * r['eff'] for r in scored) / sum(r['eff'] for r in scored), 4)
    n0 = notch_of(agg)
    opts = dict(assurance=assurance, opinion=opinion, period_type=period_type, statement_age_months=statement_age_months,
                restated_change_pct=restated_change_pct, breach=breach, flow_shortfall=flow_shortfall, going_concern=going_concern,
                resilience_notch=resilience_notch)
    applied = applied_adjustments(card, s, p, Q, m, ctx, opts)
    raw = sum(n for _, n, _, stg in applied if stg == 'NOTCH')
    notches = max(M['notch_floor'], raw)
    n1 = n0 - notches
    capn = lambda stg: max([N[cp] for _, _, cp, st in applied if st == stg and cp] or [1])
    n2 = max(n1, capn('STANDALONE'))
    n3 = n2
    if support:
        n3 = min(n2, max(n2 - support, parent_notch))
    n4 = n3 - override
    n5 = min(20, max(1, max(n4, capn('ABSOLUTE'))))
    res.update(state='RATED', aggregate=agg, indicated=GR[n0 - 1], applied=applied, notches=notches, notches_raw=raw,
               standalone=GR[min(20, n2) - 1], final=GR[n5 - 1], final_notch=n5, fitch=BY_CODE[GR[n5 - 1]]['fitch'],
               facility=facility_grade(n5, s, Q, platform, guarantors))
    res['triggers'] = triggers(card, res)
    if industry:
        typ = anchor_notch(industry, country)
        res['sector_position'] = 'ABOVE' if n5 < typ - 1 else 'BELOW' if n5 > typ + 1 else 'WITHIN'
    kw = dict(prior=prior, period_type=period_type, prior_period_type=prior_period_type, fx=fx, qual=qual, subfactors=subfactors,
              documented=documented, ev=ev, breach=breach, breach_at_period_end=breach_at_period_end, assurance=assurance, opinion=opinion,
              going_concern=going_concern, holding=holding, basis=basis, platform=platform, support=support, parent_notch=parent_notch,
              override=override, guarantors=guarantors, bureau=bureau, industry=industry, product_mix=product_mix, market_size=market_size,
              statement_age_months=statement_age_months, restated_change_pct=restated_change_pct, flow_shortfall=flow_shortfall,
              country=country, region=region)
    if with_scenarios and not proforma and industry:
        sc = {}
        for name in [x['code'] for x in SCENARIOS]:
            prm = scenario_params(industry, name, product_mix, country, region)
            lines2, extra = stress_lines(card, cur, prm)
            r2 = assess(card, lines2, **dict(kw, rollover_factor=1 - prm['st_lines_withdrawn_pct'] / 100), proforma=True, with_remedies=False, with_scenarios=False)
            sc[name] = dict(final=r2.get('final'), notch=r2.get('final_notch'), liquidity=r2['liquidity'], aggregate=r2.get('aggregate'),
                            lost=None if r2.get('final_notch') is None else r2['final_notch'] - n5, revenue=lines2['REVENUE'],
                            ebitda=r2['Q']['EBITDA'], inventory=lines2['INVENTORY'], extra=extra, params=prm)
        res['scenarios'] = sc
        lost = sc[BASE_SCENARIO]['lost']
        if lost is not None and lost > ADJ['RESILIENCE']['p'] and not resilience_notch:
            r3 = assess(card, cur, **kw, resilience_notch=True, with_remedies=with_remedies, with_scenarios=False, with_plans=with_plans)
            r3['scenarios'] = sc
            r3['resilience'] = 'VULNERABLE'
            if r3['state'] == 'RATED':
                r3['outlook'] = outlook(card, r3, _prior_metrics(card, kw), breach)
            return r3
        res['resilience'] = 'RESILIENT' if lost is not None and lost <= 1 else 'MODERATE' if lost is not None else None
    if with_remedies and not proforma:
        res['remedies'] = remedies(card, cur, res, dict(kw, resilience_notch=resilience_notch))
        if with_plans:
            res['plans'] = plans(card, cur, res, dict(kw, resilience_notch=resilience_notch))
    if not proforma:
        res['outlook'] = outlook(card, res, _prior_metrics(card, kw), breach)
    return res


def _prior_metrics(card, kw):
    """The metrics of the comparison statement, for the trend of the outlook."""
    if kw.get('prior') is None:
        return None
    s = Stmt(kw['prior'], kw.get('prior_period_type', 'ANNUAL'))
    ctx = dict(evidence=set(kw.get('ev') or ()), breach_at_period_end=False, platform=kw.get('platform'), guarantors=kw.get('guarantors'),
               bureau=None, industry=kw.get('industry'), product_mix=kw.get('product_mix'), market_size=kw.get('market_size'),
               holding_standalone=False, rollover_factor=1.0)
    Q, _ = analytical(card, s, None, ctx)
    return all_metrics(card, s, None, Q, ctx, kw.get('fx', 1.0), CARDS[card]['amount_unit'])


def grid_value(score, b):
    """The value of a grid at a score: the inverse of grid_score between the caps."""
    score = min(S[8], max(S[0], score))
    for i in range(8):
        if S[i] <= score <= S[i + 1]:
            return b[i] + (score - S[i]) / (S[i + 1] - S[i]) * (b[i + 1] - b[i])
    raise AssertionError('unreachable')


def triggers(card, res):
    """What would move the scorecard grade one notch, metric by metric with the others unchanged (docs/35 section
    15): the value at which the weighted score crosses into the grade above (UP) or below (DOWN), and the headroom
    of the weighted score to each. A metric whose own score cannot carry the move has no trigger that way."""
    agg, n0 = res['aggregate'], notch_of(res['aggregate'])
    rows = [r for r in res['rows'] if r['score'] is not None]
    W = sum(r['eff'] for r in rows)
    grids = {sm['m']: sm['b'] for sm in CARDS[card]['metrics'] if 'b' in sm}
    out = []
    for r in rows:
        if r['qual'] or r['eff'] <= 0 or r['m'] not in grids or r['st'] != 'COMPUTED':
            continue
        cur = r['score']
        for way, target in (('UP', n0 - 0.5), ('DOWN', n0 + 0.5)):
            if (way == 'UP' and n0 <= 1) or (way == 'DOWN' and n0 >= 20):
                continue
            s2 = cur + (target - agg) * W / r['eff']
            if s2 < S[0] - 1e-9 or s2 > S[8] + 1e-9:
                continue
            out.append(dict(metric=r['m'], way=way, current=r['v'], value=rnd(grid_value(s2, grids[r['m']]), 6),
                            score=rnd(cur, 4), target_score=rnd(s2, 4)))
    return dict(indicated_notch=n0, up_headroom=rnd(agg - (n0 - 0.5), 4) if n0 > 1 else None,
                down_headroom=rnd((n0 + 0.5) - agg, 4) if n0 < 20 else None, metrics=out)


def outlook(card, res, prior_metrics, breach):
    """The outlook over 12 to 18 months from the fixed rules of the methodology (docs/35 section 15)."""
    O = M['outlook']
    hits = []
    if res.get('liquidity') in ('SGL-3', 'SGL-4'): hits.append('NEG_LIQUIDITY')
    sc = res.get('scenarios') or {}
    lost = (sc.get(BASE_SCENARIO) or {}).get('lost')
    if lost is not None and lost >= O['stagnant_loss_negative']: hits.append('NEG_SCENARIO')
    tr = res['triggers']
    if tr['down_headroom'] is not None and tr['down_headroom'] < O['headroom_pct'] / 100: hits.append('NEG_HEADROOM')
    m = res['metrics']
    trend = None
    if prior_metrics is not None:
        d, dp = m['DEBT_TO_EBITDA'], prior_metrics['DEBT_TO_EBITDA']
        e, ep = m['EBITDA_MARGIN'], prior_metrics['EBITDA_MARGIN']
        g = m['REVENUE_GROWTH']
        if all(x[0] == 'COMPUTED' for x in (d, dp, e, ep)):
            if d[1] > dp[1] and e[1] < ep[1]: trend = 'NEG'
            elif d[1] < dp[1] and e[1] > ep[1] and g[0] == 'COMPUTED' and g[1] > 0: trend = 'POS'
    if trend == 'NEG': hits.append('NEG_TREND')
    if breach in ('OPEN', 'WAIVER_REQUESTED'): hits.append('NEG_BREACH')
    if tr['up_headroom'] is not None and tr['up_headroom'] < O['headroom_pct'] / 100: hits.append('POS_HEADROOM')
    if trend == 'POS': hits.append('POS_TREND')
    if res.get('resilience') == 'RESILIENT' and res.get('liquidity') == 'SGL-1' and \
            all((v.get('lost') or 0) <= 1 for v in sc.values()) and sc: hits.append('POS_RESILIENT')
    neg = sum(1 for h in hits if h.startswith('NEG'))
    pos = sum(1 for h in hits if h.startswith('POS'))
    view = 'DEVELOPING' if neg and pos else 'NEGATIVE' if neg else 'POSITIVE' if pos >= 2 else 'STABLE'
    return dict(outlook=view, rules=hits)


def _apply_remedy(rm, state):
    """One remedy on a plan's state (lines, evidence, breach): the new state, the amount moved, and whether its
    evidence bears on the statement."""
    lines, ev, breach, bape = state
    se = rm.get('sets_evidence')
    bears = (se == 'SUBORDINATION' and (lines.get('SHAREHOLDER_LOANS_SUB') or 0) > 0 and 'SUBORDINATION' not in ev) \
        or (se == 'CAPITAL_RESOLUTION' and (lines.get('CAPITAL_CONTRIBUTIONS') or 0) > 0 and 'CAPITAL_RESOLUTION' not in ev) \
        or (se == 'WAIVER_BEFORE_PERIOD_END' and (breach or bape))
    new, moved = apply_steps(lines, rm['steps']) if rm['steps'] else (lines, 0.0)
    if moved > 0 and se in ('SUBORDINATION', 'CAPITAL_RESOLUTION') and se not in ev:
        bears = True
    ev2 = tuple(sorted(set(ev) | ({se} if se else set())))
    if se == 'WAIVER_BEFORE_PERIOD_END':
        breach, bape = None, False
    return (new, ev2, breach, bape), moved, bears


def _gap(lines):
    return (lines.get('TOTAL_ASSETS') or 0) - (lines.get('TOTAL_LIABS') or 0) - (lines.get('TOTAL_EQUITY') or 0)


def plans(card, cur, res, kw):
    """The ready-made plans to strengthen the statements and the two best plans (docs/35 section 12): each step is
    a remedy the findings call for, applied to the pro-forma statement before it and assessed again; the balance
    sheet's gap (assets less liabilities and equity) stays what it was at every step."""
    ST = M['strengthening']
    cand = [x['code'] for x in res.get('remedies', []) if x.get('moved') is not None]
    base_gap = _gap(rebuild_totals(dict(cur), cur))
    start = (dict(cur), tuple(sorted(set(kw.get('ev') or ()))), kw.get('breach'), kw.get('breach_at_period_end', False))

    def run(state):
        lines, ev, breach, bape = state
        kw2 = dict(kw, ev=ev, breach=breach, breach_at_period_end=bape)
        return assess(card, lines, **kw2, proforma=True, with_remedies=False, with_scenarios=False, with_plans=False)

    def step(code, state):
        rm = REMEDIES[code]
        new, moved, bears = _apply_remedy(rm, state)
        if moved <= 0 and not bears:
            return None
        r = run(new)
        if r.get('final_notch') is None:
            return None
        return new, r, moved

    def result(code, steps, state, last):
        g = max([abs(_gap(s[3]) - base_gap) for s in steps] or [0.0])
        return dict(code=code, steps=[dict(remedy=c, final=f, aggregate=a, moved=mv) for c, f, a, _, mv in
                                      [(x[0], x[1], x[2], x[3], x[4]) for x in steps]],
                    final=GR[last['notch'] - 1], final_notch=last['notch'], aggregate=last['agg'],
                    gained=res['final_notch'] - last['notch'], balanced=g <= 1.0)

    out = []
    for pk in ST['packages']:
        state, last, steps = start, dict(notch=res['final_notch'], agg=res['aggregate']), []
        for code in pk['members']:
            if code not in cand:
                continue
            s = step(code, state)
            if s is None:
                continue
            state, r, moved = s
            last = dict(notch=r['final_notch'], agg=r['aggregate'])
            steps.append((code, r['final'], r['aggregate'], state[0], rnd(moved, 2)))
        if steps:
            out.append(result(pk['code'], steps, state, last))
    opt_done = set()
    for op in ST['optimal']:
        pool = [c for c in cand if REMEDIES[c].get('funding') not in op['exclude_funding']]
        state, last, steps = start, dict(notch=res['final_notch'], agg=res['aggregate']), []
        while pool and len(steps) < ST['max_steps']:
            best = None
            for code in pool:
                s = step(code, state)
                if s is None:
                    continue
                key = (s[1]['final_notch'], s[1]['aggregate'], pool.index(code))
                if best is None or key < best[0]:
                    best = (key, code, s)
            if best is None:
                break
            (n, a, _), code, (new, r, moved) = best
            if not (n < last['notch'] or a <= last['agg'] - ST['min_gain_score']):
                break
            state, last = new, dict(notch=n, agg=a)
            steps.append((code, r['final'], a, new[0], rnd(moved, 2)))
            pool.remove(code)
        # a later best plan is kept only when it reaches a better grade than an earlier one (new cash that buys nothing
        # more is not proposed)
        if steps and all(last['notch'] < x['final_notch'] for x in out if x['code'] in opt_done):
            out.append(result(op['code'], steps, state, last))
        opt_done.add(op['code'])
    return out


def remedies(card, cur, res, kw):
    """The remedies the findings call for, each with its pro-forma grade (docs/35 section 12)."""
    order = {l: i for i, l in enumerate(LEVELS)}
    applied = {a[0] for a in res['applied']}
    lvl = {}
    for (r, line), (level, v) in res['items'].items():
        if level in order and (r not in lvl or order[level] > order[lvl[r]]):
            lvl[r] = level
    out = []
    for rm in M['remedies']:
        hit = None
        for t in rm['triggers']:
            if t in lvl and order[lvl[t]] >= order[rm['min_level']]:
                hit = (t, lvl[t]); break
            if t in applied:
                hit = (t, 'ADJUSTMENT'); break
        if not hit:
            continue
        kw2 = dict(kw)
        se = rm.get('sets_evidence')
        if se:
            kw2['ev'] = tuple(sorted(set(kw2.get('ev') or ()) | {se}))
            if se == 'WAIVER_BEFORE_PERIOD_END':
                kw2['breach'], kw2['breach_at_period_end'] = None, False
        if not rm['steps'] and not se:
            out.append(dict(code=rm['code'], trigger=hit, moved=None, final=None, gained=None)); continue
        new, moved = apply_steps(cur, rm['steps']) if rm['steps'] else (cur, 0.0)
        # a remedy is proposed only when it changes something: its steps move an amount, or its evidence bears on a
        # balance the statement holds (or on the breach)
        bears = (se == 'SUBORDINATION' and (cur.get('SHAREHOLDER_LOANS_SUB') or 0) > 0 and 'SUBORDINATION' not in (kw.get('ev') or ())) \
            or (se == 'CAPITAL_RESOLUTION' and (cur.get('CAPITAL_CONTRIBUTIONS') or 0) > 0 and 'CAPITAL_RESOLUTION' not in (kw.get('ev') or ())) \
            or (se == 'WAIVER_BEFORE_PERIOD_END' and (kw.get('breach') or kw.get('breach_at_period_end')))
        if moved <= 0 and not bears:
            continue
        r = assess(card, new, **kw2, proforma=True, with_remedies=False, with_scenarios=False)
        pf = r.get('final_notch')
        out.append(dict(code=rm['code'], trigger=hit, moved=moved, final=None if pf is None else GR[pf - 1], score=r.get('aggregate'),
                        gained=None if pf is None else res['final_notch'] - pf))
    return out


def apply_steps(lines, steps):
    """The statement after a remedy's steps: each step moves ref x pct (read before the remedy) from its decreased lines
    to its increased lines, capped by the smallest balance-sheet LINE it decreases; the totals are rebuilt."""
    base, out = dict(lines), dict(lines)
    moved = 0.0
    for st in steps:
        amt = (base.get(st['ref']) or 0) * st['pct'] / 100
        bs_dec = [x for x in st['dec'] if LINES[x]['kind'] == 'LINE' and LINES[x]['section'].startswith('BS')]
        if bs_dec:
            amt = min([amt] + [max(0.0, out.get(x) or 0) for x in bs_dec])
        if amt <= 0:
            continue
        for x in st['dec']:
            if x in out or LINES[x]['kind'] == 'LINE':
                out[x] = (out.get(x) or 0) - amt
        for x in st['inc']:
            out[x] = (out.get(x) or 0) + amt
        moved += amt
    return rebuild_totals(out, lines), moved


def rebuild_totals(out, original):
    """The balance sheet totals rebuilt from their lines; the income statement totals stay as reported."""
    d = {k: v for k, v in out.items() if LINES[k]['kind'] != 'TOTAL'}
    for t in ('TOTAL_CA', 'TOTAL_ASSETS', 'TOTAL_CL', 'TOTAL_LIABS', 'TOTAL_EQUITY'):
        d[t] = sum(sign * (d.get(cmp) or 0) for cmp, sign in TOTALS[t])
    for t in ('GROSS_PROFIT', 'OPERATING_PROFIT', 'EBITDA', 'NET_PROFIT'):
        if original.get(t) is not None:
            d[t] = original[t]
    return d


def scenario_params(industry, scen, mix, country=None, region=None):
    """The stress of a macro scenario on the company (docs/35 section 14): per driver, the scenario intensity × the
    activity sensitivity ÷ 5 × the country exposure × the region multiplier (real estate and conflict); the product mix
    replaces the activity's demand sensitivity and gives the inventory write-down."""
    sd = next(x for x in SCENARIOS if x['code'] == scen)
    R = M['scenario_rules']
    sens = dict(INDUSTRIES[industry]['sens'])
    cp = country_profile(country)
    rg = next((x for x in cp.get('regions') or [] if x['code'] == region), None) if region else None
    sev = 'STAGNANT_MARKET' if sd['inventory'] == 'STAGNANT' else 'FINANCIAL_CRISIS'
    if mix:
        rw = sum(m['revenue_share_pct'] for m in mix)
        sens['DEMAND'] = sum(PCAT[m['category']]['demand_sensitivity'] * m['revenue_share_pct'] for m in mix) / rw
    x = {}
    for d in DRIVERS:
        v = sd['intensity'][d] * sens[d] / 5 * cp['exposure'][d]
        if rg and d == 'REAL_ESTATE': v *= rg['re_mult']
        if rg and d == 'CONFLICT': v *= rg['conflict_mult']
        x[d] = v
    p = dict(revenue_pct=max(-R['max_revenue_fall_pct'], -sum(x[d] * DRV[d]['rev_pct'] for d in DRIVERS)),
             gross_margin_pp=-sum(x[d] * DRV[d]['gm_pp'] for d in DRIVERS),
             dso_days=sd['base_dso_days'] + sum(x[d] * DRV[d]['dso_days'] for d in DRIVERS),
             st_lines_withdrawn_pct=min(R['st_lines_max_pct'], sd['st_lines_withdrawn_pct'] * cp['exposure']['CREDIT'] * sens['CREDIT'] / R['credit_sensitivity_reference']),
             rate_bp=sd['rate_bp'],
             private_ar_loss_pct=min(100.0, sd['private_ar_loss_pct'] * (1 + R['private_ar_loss_demand_factor'] * x['DEMAND'])),
             property_writedown_pct=min(R['investment_property_fall_max_pct'], R['investment_property_fall_pct'] * x['REAL_ESTATE']))
    if mix:
        iw = sum(m.get('inventory_share_pct', 0) for m in mix) or 1
        p['inventory_writedown_pct'] = sum((PCAT[m['category']]['inventory_value_pct']['NORMAL'] - PCAT[m['category']]['inventory_value_pct'][sev])
                                           * m.get('inventory_share_pct', 0) for m in mix) / iw
        if sev == 'FINANCIAL_CRISIS':
            p['dso_days'] = max(p['dso_days'], sum(PCAT[m['category']]['crisis_extra_dso'] * m['revenue_share_pct'] for m in mix) / rw)
    else:
        cats = INDUSTRIES[industry]['product_categories']
        p['inventory_writedown_pct'] = sum(PCAT[c]['inventory_value_pct']['NORMAL'] - PCAT[c]['inventory_value_pct'][sev] for c in cats) / len(cats)
    return p


def stress_lines(card, d, prm):
    """The statement under a scenario: revenue and gross margin change, the variable part of the operating expenses
    follows revenue, floating debt costs more, receivables stretch and private aged receivables are lost, inventory is
    written down; the cash effect goes to cash and then to short-term loans, the losses to retained earnings."""
    a = Stmt(d)
    o = {k: v for k, v in d.items() if LINES[k]['kind'] != 'TOTAL'}
    rev, cogs, opex = a('REVENUE'), a('COGS'), a('OPEX')
    gm = (rev - cogs) / rev
    rev2 = rev * (1 + prm['revenue_pct'] / 100)
    R = M['scenario_rules']
    gm_eff = prm['gross_margin_pp'] * min(R['gross_margin_scale_max'], max(gm, 0.0) * 100 / R['reference_gross_margin_pct'])
    gp2 = rev2 * (gm + gm_eff / 100)
    fr = CARDS[card]['fixed_cost_rule']
    ga, sd = a('GENERAL_ADMIN'), a('SELLING_DISTRIBUTION')
    if ga is None and sd is None:
        opex_fixed = fr['fallback_opex_fixed_pct'] / 100 * opex
    else:
        opex_fixed = min(opex, (ga or 0) + fr['selling_fixed_pct'] / 100 * (sd or 0) + a.z('RENT_SHORT_TERM'))
    opex2 = opex_fixed + (opex - opex_fixed) * rev2 / rev
    floating = a('DEBT_FLOATING') if a.known('DEBT_FLOATING') else 0.6 * (a('ST_LOANS') + a('BANK_ACCEPTANCES') + a('CURRENT_PORTION_LTD') + a('LT_LOANS'))
    dfin = floating * prm['rate_bp'] / 10000
    stretch = prm['dso_days'] * rev2 / 365 + (a('AR') / rev) * (rev2 - rev)
    if a.known('AR_AGE_181_365') and a.known('AR_AGE_OVER_365'):
        priv180 = max(0.0, a('AR_AGE_181_365') + a('AR_AGE_OVER_365') - a.z('AR_AGE_OVER_365_GOV') - a.z('AR_ECL_ALLOWANCE'))
    else:
        priv180 = 0.10 * max(0.0, a('AR') - a.z('AR_GOVERNMENT'))
    ar_loss = priv180 * prm['private_ar_loss_pct'] / 100
    inv_wd = a('INVENTORY') * prm['inventory_writedown_pct'] / 100
    ip_wd = a.z('INVESTMENT_PROPERTY') * prm['property_writedown_pct'] / 100
    d_ebitda = (gp2 - opex2) - (rev - cogs - opex)
    o['REVENUE'] = rev2; o['COGS'] = rev2 - gp2; o['OPEX'] = opex2
    o['FINANCE_COSTS'] = a('FINANCE_COSTS') + dfin
    o['OTHER_INCOME'] = a('OTHER_INCOME') - ar_loss - inv_wd - ip_wd
    if ip_wd: o['INVESTMENT_PROPERTY'] = a('INVESTMENT_PROPERTY') - ip_wd
    if a('INTEREST_PAID'): o['INTEREST_PAID'] = a('INTEREST_PAID') + dfin
    flow = d_ebitda - dfin - stretch
    if a('OP_CASH_FLOW') or a('CFO_BEFORE_WC'):
        o['OP_CASH_FLOW'] = a('OP_CASH_FLOW') + flow
        if a('CFO_BEFORE_WC'): o['CFO_BEFORE_WC'] = a('CFO_BEFORE_WC') + d_ebitda - dfin
    o['AR'] = a('AR') + stretch - ar_loss
    if 'AR_AGE_91_180' in o:
        if stretch >= 0: o['AR_AGE_91_180'] = o['AR_AGE_91_180'] + stretch
        else: o['AR_AGE_0_90'] = max(0.0, o['AR_AGE_0_90'] + stretch)
    if 'AR_GROSS' in o and 'AR_AGE_0_90' in o:
        o['AR_GROSS'] = max(o['AR_GROSS'], sum(o.get(k, 0) for k in ('AR_AGE_0_90', 'AR_AGE_91_180', 'AR_AGE_181_365', 'AR_AGE_OVER_365')))
    o['INVENTORY'] = a('INVENTORY') - inv_wd
    if 'INV_SLOW_MOVING' in o: o['INV_SLOW_MOVING'] = min(o['INVENTORY'], o['INV_SLOW_MOVING'])
    for k in ('INV_FINISHED', 'INV_RAW', 'INV_WIP', 'INV_IN_TRANSIT'):
        if k in o: o[k] = o[k] * o['INVENTORY'] / a('INVENTORY') if a('INVENTORY') else 0.0
    cash = a('CASH') + flow
    st_add = 0.0
    free = a('CASH') - a.z('CASH_RESTRICTED')
    if free + flow < 0:
        st_add = -(free + flow); cash = a.z('CASH_RESTRICTED')
    o['CASH'] = cash; o['ST_LOANS'] = a('ST_LOANS') + st_add
    o['RETAINED_EARNINGS'] = a('RETAINED_EARNINGS') + d_ebitda - dfin - ar_loss - inv_wd - ip_wd
    for k in ('REV_TOP5', 'REV_TOP_CUSTOMER', 'REV_GOVERNMENT', 'REV_CASH', 'REV_EXPORT'):
        if k in o: o[k] = o[k] * rev2 / rev
    full = rebuild_totals(o, {})
    full['GROSS_PROFIT'] = full['REVENUE'] - full['COGS']
    full['OPERATING_PROFIT'] = full['GROSS_PROFIT'] - full['OPEX']
    full['EBITDA'] = full['OPERATING_PROFIT'] + full.get('DEPR_AMORT', 0)
    full['NET_PROFIT'] = full['OPERATING_PROFIT'] - full.get('FINANCE_COSTS', 0) + full.get('OTHER_INCOME', 0) + full.get('SHARE_OF_ASSOCIATES', 0) - full.get('ZAKAT_TAX', 0)
    return full, dict(ar_loss=ar_loss, inv_wd=inv_wd, ip_wd=ip_wd, gm_pp=gm_eff, dfin=dfin, stretch=stretch, d_ebitda=d_ebitda)


def case_args(c, scale=1.0):
    """The keyword arguments of a stress case of the methodology file, amounts multiplied by scale."""
    sc = lambda d: None if d is None else {k: v * scale for k, v in d.items()}
    inp = dict(c.get('inputs') or {})
    plat = copy.deepcopy(c.get('platform')) if c.get('platform') else None
    guarantors = None
    if plat:
        for k in ('limits', 'outstanding', 'committed_undrawn', 'secured_coverage'):
            if plat.get(k) is not None: plat[k] *= scale
        if plat.get('collateral'):
            plat['collateral'] = [(k, v * scale) for k, v in plat['collateral']]
        if plat.get('guarantors'):
            # the review's cases give a guarantor's liquid net worth and leverage: its net worth is taken as the liquid
            # part, and it guarantees the platform's outstanding
            guarantors = [dict(liquid=g['liquid_nw'] * scale, net_worth=g['liquid_nw'] * scale, given=g['leverage_pct'] / 100 * g['liquid_nw'] * scale,
                               guaranteed=plat['outstanding']) for g in plat.pop('guarantors')]
    mix = [dict(m) for m in c.get('product_mix') or []]
    return dict(prior=sc(c.get('prior')), qual=c['qual'], ev=tuple(inp.get('ev', ())), breach=inp.get('breach'),
                breach_at_period_end=inp.get('breach_at_period_end', False), assurance=inp.get('assurance', 'AUDITED'),
                holding=inp.get('holding', False), platform=plat, guarantors=guarantors, industry=c.get('industry'),
                product_mix=mix or None, country=c.get('country', 'SA'), region=c.get('region')), sc(c['lines'])


if __name__ == '__main__':
    key = sys.argv[1] if len(sys.argv) > 1 else 'G01_EXAMPLE'
    c = next(x for x in M['stress'] + M['scenario_stress'] if x['key'] == key)
    kw, lines = case_args(c, 1e6)
    r = assess(c['card'], lines, **kw)
    print(f"{key}: {r['state']} coverage {r['coverage']} financial {r.get('financial')} aggregate {r.get('aggregate')} "
          f"indicated {r.get('indicated')} final {r.get('final')} ({r.get('fitch')}) liquidity {r['liquidity']} completeness {r['completeness']}")
    for row in r['rows']:
        print(f"  {row['m']:28s} {row['f']:26s} w {row['w']:5} eff {row.get('eff', 0):7.3f} {row['st']:15s} "
              f"{'' if row['v'] is None else rnd(row['v'], 4):>12} score {row['score']}")
    print('  adjustments', [a[0] for a in r.get('applied', [])])
    print('  facility', r.get('facility'))
    for rm in r.get('remedies', []):
        print('  remedy', rm)
    if r.get('scenarios'):
        for k, v in r['scenarios'].items():
            print('  scenario', k, v['final'], v['liquidity'], 'lost', v['lost'])
