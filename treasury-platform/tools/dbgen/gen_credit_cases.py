#!/usr/bin/env python3
"""gen_credit_cases.py — the cases that check the T-SQL credit engine (db/static/047) against the Python reference
(tools/dbgen/credit_reference.py), number for number.

Every stress case of tools/dbgen/credit_scorecard.json, and the variants below that reach the rules the stress cases do
not (the credit bureau, the audit opinion, a stale or restated statement, group support, the override, an interim
period, the market size, a holding company), becomes one test of db/tests/credit_engine_cases.sql:
  CE  the core (fin.usp_CreditCore) on the statement: every named quantity, every metric with its state, the factors
      and their effective weights, every item level, the adjustments that apply, the grades, the liquidity label, the
      data completeness and the facility grade, as the reference computes them without scenarios or remedies;
  CV  the evaluation (fin.usp_CreditEvaluate): the final grade with the seven macro scenarios (their stress parameters
      from the drivers, the activity, the country and the region) and the
      resilience overlay, the grade each scenario gives, and every remedy with its pro-forma grade, the balance of the
      pro-forma balance sheet, and the strengthening plans.
The file is generated; CI regenerates it and fails when the committed file differs.

Usage: python3 tools/dbgen/gen_credit_cases.py db/tests/credit_engine_cases.sql
"""
import copy, os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import credit_reference as cr

SCALE = 1e6
# Variants of stress cases: (key, base case, changes to the keyword arguments, what the variant reaches).
VARIANTS = [
    ('V01_BUREAU_CLEAN', 'G01_EXAMPLE', dict(bureau=dict(outstanding=None, limits=None, lenders=2)), 'a clean bureau report that matches the statement'),
    ('V02_BUREAU_DEFAULT', 'G01_EXAMPLE', dict(bureau=dict(outstanding=None, current_default=True, worst_dpd_12m=120, bounced_count=7,
                                                             judgments_amount=40e6, lenders=3)), 'a current default, severe bounced cheques, material judgments'),
    ('V03_BUREAU_WATCH', 'G01_EXAMPLE', dict(bureau=dict(outstanding=1.5, worst_dpd_12m=75, defaults_24m=1, bounced_count=3, judgments_amount=3e6,
                                                           restructured=True, inquiries_6m=8, lenders=6)),
     'late payments, a past default, a restructuring, many inquiries, lenders and debt outside the platform'),
    ('V04_BUREAU_DPD30_OLD', 'G01_EXAMPLE', dict(bureau=dict(outstanding=2.0, worst_dpd_12m=35, months_after_period_end=9, bounced_amount=0.01)),
     'a report taken long after the period end: no hidden debt'),
    ('V05_AUDIT_STALE', 'G01_EXAMPLE', dict(opinion='QUALIFIED', statement_age_months=20, restated_change_pct=15, flow_shortfall=True),
     'a qualified opinion, a stale and restated statement, a shortfall of the bank flows'),
    ('V06_ADVERSE_SUPPORT', 'G01_EXAMPLE', dict(opinion='ADVERSE', support=2, parent_notch=6, override=1, going_concern=True),
     'an adverse opinion with group support and an override'),
    ('V07_SUPPORT_OVERRIDE', 'G01_EXAMPLE', dict(support=2, parent_notch=5, override=-1), 'group support up to the parent, an override up'),
    ('V08_QUARTERLY', 'G01_EXAMPLE', dict(period_type='QUARTERLY', quarter=True), 'a quarterly statement against an annual one'),
    ('V09_MARKET_SIZE', 'G01_EXAMPLE', dict(market_size=900.0), 'the market size of the activity'),
    ('V10_HOLDING', 'G01_EXAMPLE', dict(holding=True), 'a holding company on its standalone statement'),
    ('V11_MANAGEMENT', 'G01_EXAMPLE', dict(assurance='MANAGEMENT'), 'an annual statement prepared by the management'),
    ('V12_NO_TOTALS', 'G01_EXAMPLE', dict(drop=['TOTAL_CA', 'TOTAL_ASSETS', 'TOTAL_EQUITY', 'GROSS_PROFIT', 'OPERATING_PROFIT', 'EBITDA', 'NET_PROFIT']),
     'a statement without its totals: each is the sum of its lines'),
    ('V13_EGYPT', 'S04_BUILDING_CONTRACTOR', dict(country='EG'), 'a contractor in a country of high risk: its anchor, exposures and sovereign ceiling'),
    ('V14_BAHRAIN_CEILING', 'G02_STRONG_LARGE', dict(country='BH', industry='C2101'), 'a strong company capped by its country\'s sovereign rating'),
    ('V15_DUBAI_REGION', 'S02_BUILDING_MATERIALS_TRADER', dict(country='AE', region='DXB', industry='G466301', card='BUILDING_MATERIALS_TRADE'),
     'a finished building materials supplier in a city whose property falls more, on its family card'),
    ('V16_NO_PROFILE', 'S01_FOOD_DISTRIBUTOR', dict(country='TR'), 'a country without a risk profile: the default profile'),
    ('V17_MICRO', 'G01_EXAMPLE', dict(scale=0.04), 'a very small company under the micro-size ceiling'),
    ('V18_JORDAN_TOURISM', 'S03_FASHION_RETAILER', dict(country='JO', region='AMM', industry='N7902', card='HOSPITALITY_TOURISM'),
     'an activity exposed to conflict in a country exposed to it'),
    ('V19_KUWAIT_IMPORTER_FROZEN', 'S01_FOOD_DISTRIBUTOR',
     dict(country='KW', industry='G463002', platform=dict(limits=400, outstanding=260, committed_undrawn=120, largest_lender_share_pct=60,
                                                          expiring_12m_share_pct=50)),
     'a staple food importer in a country the Gulf conflict hits hardest, with committed undrawn limits the banks stop in it'),
    ('V20_LENDER_DECIDED', 'S01_FOOD_DISTRIBUTOR',
     dict(country='KW', industry='G463002', platform=dict(limits=340, outstanding=260, committed_undrawn=60, largest_lender_share_pct=60,
                                                          expiring_12m_share_pct=50, undrawn_decided=20, lender_repayment=30,
                                                          decided_share_pct=55, decided_cost=2.6)),
     'the actual decisions of the lenders on part of the facilities: one stopped its undrawn limit, one reduced its limit below the drawn amount '
     'and repriced; the estimate covers the other facilities only'),
    # review v6 (ADR 0038): the months of an interim, the unaudited interim, the age of the bureau report
    ('V21_INTERIM_YTD_MANAGEMENT', 'G01_EXAMPLE', dict(ytd=9, assurance='MANAGEMENT'),
     'a nine-month year-to-date interim prepared by the management: annualised by 12/9 and one notch for the unaudited statement'),
    ('V22_BUREAU_STALE', 'G01_EXAMPLE', dict(bureau=dict(outstanding=1.5, worst_dpd_12m=75, defaults_24m=1, bounced_count=3, judgments_amount=3e6,
                                                           restructured=True, inquiries_6m=8, lenders=6, age_months=5)),
     'the bureau report of V03 five months old on the assessment date: older than the card allows, it is not read'),
    ('V23_BUREAU_AT_MAX_AGE', 'G01_EXAMPLE', dict(bureau=dict(outstanding=1.5, worst_dpd_12m=75, defaults_24m=1, bounced_count=3, judgments_amount=3e6,
                                                                restructured=True, inquiries_6m=8, lenders=6, age_months=3)),
     'the same report three months old: at the maximum age it is read'),
]


def num(v):
    if v is None:
        return 'NULL'
    if isinstance(v, bool):
        return '1' if v else '0'
    if isinstance(v, int):
        return str(v)
    return 'NULL' if v != v else repr(float(v)).replace('inf', '1e308')


def s(v):
    return 'NULL' if v is None else "'" + str(v).replace("'", "''") + "'"


def cases():
    """Each case: (id, key, title, card, lines, kw)."""
    out = []
    for c in cr.M['stress'] + cr.M['scenario_stress']:
        kw, lines = cr.case_args(c, SCALE)
        out.append((c['key'], c['name_ar'], c['card'], lines, kw))
    base = {k: (card, lines, kw) for k, _, card, lines, kw in out}
    for key, frm, ch, title in VARIANTS:
        card, lines, kw = copy.deepcopy(base[frm])
        ch = copy.deepcopy(ch)
        for k in ch.pop('drop', []):
            lines.pop(k, None)
        if 'scale' in ch:
            f = ch.pop('scale')
            lines = {k: v * f for k, v in lines.items()}
            if kw.get('prior'):
                kw['prior'] = {k: v * f for k, v in kw['prior'].items()}
        if 'card' in ch:
            card = ch.pop('card')
        if ch.pop('quarter', False):
            kw['prior_period_type'] = 'ANNUAL'
            lines = {k: (v / 4 if cr.LINES[k]['section'] in ('IS', 'CF') else v) for k, v in lines.items()}
        if 'ytd' in ch:
            # a year-to-date interim of so many months (its start and end dates give them to the engine)
            mo = ch.pop('ytd')
            kw['period_type'], kw['period_months'], kw['prior_period_type'] = 'QUARTERLY', mo, 'ANNUAL'
            lines = {k: (v * mo / 12 if cr.LINES[k]['section'] in ('IS', 'CF') else v) for k, v in lines.items()}
        if 'bureau' in ch:
            b = ch['bureau']
            q, _ = cr.analytical(card, cr.Stmt(lines, kw.get('period_type', 'ANNUAL'), months=kw.get('period_months')), None,
                                 dict(evidence=set(), breach_at_period_end=False, platform=kw.get('platform'), guarantors=None, bureau=None,
                                      industry=None, product_mix=None, market_size=None, holding_standalone=False, rollover_factor=1.0))
            bank = q['BANK_DEBT']
            b['outstanding'] = bank if b.get('outstanding') is None else bank * b['outstanding']
            b['limits'] = 1.1 * b['outstanding'] if b.get('limits') is None else b['limits']
            if 'bounced_amount' in b:
                b['bounced_amount'] = b['bounced_amount'] * lines['REVENUE']
            for k in ('worst_dpd_12m', 'defaults_24m', 'bounced_count', 'bounced_amount', 'judgments_amount', 'inquiries_6m', 'months_after_period_end'):
                b.setdefault(k, 0)
            b.setdefault('current_default', False); b.setdefault('restructured', False); b.setdefault('lenders', 1)
        if 'market_size' in ch:
            ch['market_size'] = ch['market_size'] * SCALE
        if 'platform' in ch:
            ch['platform'] = {k: v * SCALE if k in ('limits', 'outstanding', 'committed_undrawn', 'undrawn_decided', 'lender_repayment', 'decided_cost') else v
                              for k, v in ch['platform'].items()}
        kw.update(ch)
        out.append((key, title, card, lines, kw))
    return out


def context(card, lines, kw):
    """The #crX row the caller of the core gives for these arguments (fin.usp_ComputeCreditAssessment computes the same
    from the tables)."""
    plat = kw.get('platform') or {}
    bu = kw.get('bureau')
    gu = kw.get('guarantors')
    mix = kw.get('product_mix') or []
    ind = kw.get('industry')
    country = kw.get('country', 'SA')
    # the product measures, as metric_values computes them
    pv = {}
    if mix:
        rw = sum(m['revenue_share_pct'] for m in mix)
        pv['cfq'] = None if rw <= 0 else sum(cr.PCAT[m['category']]['cash_flow_quality'] * m['revenue_share_pct'] for m in mix) / rw
        pv['conc'] = None if rw <= 0 else max(m['revenue_share_pct'] for m in mix) / rw * 100
        iw = sum(m.get('inventory_share_pct', 0) for m in mix)
        cats = [(cr.PCAT[m['category']], m.get('inventory_share_pct', 0)) for m in mix] if iw > 0 else [(cr.PCAT[m['category']], 1) for m in mix]
    elif ind:
        cats = [(cr.PCAT[c], 1) for c in cr.INDUSTRIES[ind]['product_categories']]
    else:
        cats = []
    if cats:
        w = sum(x for _, x in cats)
        pv['crisis'] = sum(c['inventory_value_pct']['FINANCIAL_CRISIS'] * x for c, x in cats) / w
        pv['days'] = sum(c['days_to_sell']['STAGNANT_MARKET'] * x for c, x in cats) / w
    qual, subs = kw.get('qual'), kw.get('subfactors')
    holding = bool(kw.get('holding')) and (kw.get('basis') or 'STANDALONE') == 'STANDALONE'
    ev = set(kw.get('ev') or ())
    return dict(
        Card=card, PeriodType=kw.get('period_type', 'ANNUAL'), PriorPeriodType=kw.get('prior_period_type', 'ANNUAL'),
        HasPrior=kw.get('prior') is not None, Fx=kw.get('fx', 1.0), Assurance=kw.get('assurance', 'AUDITED'), Opinion=kw.get('opinion', 'UNQUALIFIED'),
        GoingConcern=bool(kw.get('going_concern')), HoldingStandalone=holding, Breach=kw.get('breach'),
        BreachAtPeriodEnd=bool(kw.get('breach_at_period_end')), FlowShortfall=bool(kw.get('flow_shortfall')),
        StatementAgeMonths=kw.get('statement_age_months'), RestatedPct=kw.get('restated_change_pct'), Industry=ind,
        MarketSize=kw.get('market_size'), RolloverFactor=kw.get('rollover_factor', 1.0), ResilienceNotch=bool(kw.get('resilience_notch')),
        Proforma=bool(kw.get('proforma')), EvSub='SUBORDINATION' in ev, EvCap='CAPITAL_RESOLUTION' in ev,
        PfLimits=plat.get('limits'), PfOutstanding=plat.get('outstanding'), PfCommittedUndrawn=plat.get('committed_undrawn'),
        PfLargestLenderShare=plat.get('largest_lender_share_pct'), PfExpiring12mShare=plat.get('expiring_12m_share_pct'), PfLenders=plat.get('lenders'),
        BuPresent=bu is not None, BuOutstanding=(bu or {}).get('outstanding'), BuLimits=(bu or {}).get('limits'), BuLenders=(bu or {}).get('lenders'),
        BuDpd12m=(bu or {}).get('worst_dpd_12m'), BuCurrentDefault=bool((bu or {}).get('current_default')), BuDefaults24m=(bu or {}).get('defaults_24m'),
        BuBouncedCount=(bu or {}).get('bounced_count'), BuBouncedAmount=(bu or {}).get('bounced_amount'), BuJudgments=(bu or {}).get('judgments_amount'),
        BuRestructured=bool((bu or {}).get('restructured')), BuInquiries6m=(bu or {}).get('inquiries_6m'),
        BuMonthsAfterPeriodEnd=(bu or {}).get('months_after_period_end'),
        QualBp=cr.qualitative_score(card, 'BUSINESS_PROFILE', qual, subs, ind, country), QualFp=cr.qualitative_score(card, 'FINANCIAL_POLICY', qual, subs, ind, country),
        DocBp='BUSINESS_PROFILE' in (kw.get('documented') or ()), DocFp='FINANCIAL_POLICY' in (kw.get('documented') or ()),
        ProdCashFlowQuality=pv.get('cfq'), ProdConcentration=pv.get('conc'), InvCrisisValue=pv.get('crisis'), InvDaysStagnant=pv.get('days'),
        Support=kw.get('support'), ParentNotch=kw.get('parent_notch'), Override=kw.get('override') or 0,
        GuLiquid=None if not gu else sum(g['liquid'] for g in gu), GuNetWorth=None if not gu else sum(g['net_worth'] for g in gu),
        GuGiven=None if not gu else sum(g['given'] for g in gu), GuGuaranteed=None if not gu else sum(g['guaranteed'] for g in gu),
        GuMaxLeverage=None if not gu else max((g['given'] / g['net_worth'] * 100 if g['net_worth'] > 0 else 999.0) for g in gu),
        Country=country, RegionCode=kw.get('region'),
        PfUndrawnDecided=plat.get('undrawn_decided'), PfLenderRepayment=plat.get('lender_repayment'), PfDecidedShare=plat.get('decided_share_pct'),
        PfDecidedCost=plat.get('decided_cost'), PeriodMonths=kw.get('period_months'), PriorPeriodMonths=kw.get('prior_period_months'),
        BuAgeMonths=(bu or {}).get('age_months'),
    )


X_COLS = ['ScorecardId', 'PeriodType', 'PriorPeriodType', 'HasPrior', 'Fx', 'Assurance', 'Opinion', 'GoingConcern', 'HoldingStandalone', 'Breach',
          'BreachAtPeriodEnd', 'FlowShortfall', 'StatementAgeMonths', 'RestatedPct', 'IndustryId', 'MarketSize', 'RolloverFactor', 'ResilienceNotch',
          'Proforma', 'EvSub', 'EvCap', 'PfLimits', 'PfOutstanding', 'PfCommittedUndrawn', 'PfLargestLenderShare', 'PfExpiring12mShare', 'PfLenders',
          'BuPresent', 'BuOutstanding', 'BuLimits', 'BuLenders', 'BuDpd12m', 'BuCurrentDefault', 'BuDefaults24m', 'BuBouncedCount', 'BuBouncedAmount',
          'BuJudgments', 'BuRestructured', 'BuInquiries6m', 'BuMonthsAfterPeriodEnd', 'QualBp', 'QualFp', 'DocBp', 'DocFp', 'ProdCashFlowQuality',
          'ProdConcentration', 'InvCrisisValue', 'InvDaysStagnant', 'Support', 'ParentNotch', 'Override', 'GuLiquid', 'GuNetWorth', 'GuGiven',
          'GuGuaranteed', 'GuMaxLeverage', 'CountryId', 'RegionCode', 'PfUndrawnDecided', 'PfLenderRepayment', 'PfDecidedShare', 'PfDecidedCost',
          'PeriodMonths', 'PriorPeriodMonths', 'BuAgeMonths']
STR_X = {'PeriodType', 'PriorPeriodType', 'Assurance', 'Opinion', 'Breach', 'RegionCode'}


def x_values(x):
    vals = []
    for c in X_COLS:
        if c == 'ScorecardId':
            vals.append(f"(SELECT ScorecardId FROM fin.Scorecard WHERE Code = {s(x['Card'])} AND Status = 'APPROVED')")
        elif c == 'CountryId':
            vals.append(f"(SELECT CountryId FROM ref.Country WHERE Iso2 = {s(x['Country'])})")
        elif c == 'IndustryId':
            vals.append('NULL' if x['Industry'] is None else f"(SELECT IndustryId FROM ref.Industry WHERE Code = {s(x['Industry'])})")
        elif c in STR_X:
            vals.append(s(x[c]))
        else:
            vals.append(num(x[c]))
    return vals


def expected_core(card, lines, kw):
    """The reference's result for the core: no scenarios, no remedies, no resilience overlay."""
    kw2 = {k: v for k, v in kw.items() if k not in ('resilience_notch',)}
    return cr.assess(card, lines, **kw2, with_remedies=False, with_scenarios=False)


def rows_values(rows):
    return [rows[i:i + 200] for i in range(0, len(rows), 200)]


def insert(table, cols, rows):
    if not rows:
        return ''
    parts = []
    for chunk in rows_values(rows):
        parts.append(f"INSERT {table} ({', '.join(cols)}) VALUES\n    " + ',\n    '.join('(' + ', '.join(r) + ')' for r in chunk) + ';')
    return '\n'.join(parts) + '\n'


def metric_state(st, v):
    if st == 'EXTREME':
        return v, None
    return st, v


def core_case(i, key, title, card, lines, kw):
    x = context(card, lines, kw)
    r = expected_core(card, lines, kw)
    b = [f"/* CE{i}: {key} — {title} */"]
    b.append('DELETE #crX; DELETE #crL; DELETE #crP; DELETE #crColl; DELETE #eQ; DELETE #eM; DELETE #eF; DELETE #eI; DELETE #eA; DELETE #eS;')
    b.append(f"INSERT #crX ({', '.join(X_COLS)})\nVALUES ({', '.join(x_values(x))});")
    b.append(insert('#crL', ['Code', 'Amount'], [[s(k), num(v)] for k, v in sorted(lines.items())]).rstrip())
    if kw.get('prior'):
        b.append(insert('#crP', ['Code', 'Amount'], [[s(k), num(v)] for k, v in sorted(kw['prior'].items())]).rstrip())
    coll = (kw.get('platform') or {}).get('collateral') or []
    if coll:
        b.append(insert('#crColl', ['Kind', 'Cover'], [[s(k), num(v)] for k, v in coll]).rstrip())
    Q = r['Q']
    b.append(insert('#eQ', ['Code', 'Value'], [[s(k), num(v)] for k, v in sorted(Q.items()) if not isinstance(v, (list, dict, tuple, str))]).rstrip())
    mrows = []
    for code, (st, v) in sorted(r['metrics'].items()):
        st2, v2 = metric_state(st, v)
        mrows.append([s(code), s(st2), num(v2)])
    b.append(insert('#eM', ['Code', 'State', 'Value'], mrows).rstrip())
    frows = [[s(row['m']), num(row['score']), num(row.get('eff', 0.0))] for row in r['rows']]
    b.append(insert('#eF', ['Code', 'Score', 'EffectiveWeight'], frows).rstrip())
    irows = [[s(m), s(line), s(level), num(v)] for (m, line), (level, v) in sorted(r['items'].items())]
    b.append(insert('#eI', ['MetricCode', 'LineCode', 'Level', 'Value'], irows).rstrip())
    if r['state'] == 'RATED':
        b.append(insert('#eA', ['RuleCode', 'Notches', 'CapNotch'],
                         [[s(a[0]), num(a[1]), num(cr.N[a[2]] if a[2] else None)] for a in r['applied']]).rstrip())
    fac = r.get('facility') or {}
    b.append(insert('#eS', ['State', 'Coverage', 'Completeness', 'Liquidity', 'FinancialScore', 'WeightedScore', 'FinalNotch', 'Notches', 'FacilityLgd',
                            'FacilityBand', 'FacilityNotch'],
                    [[s(r['state']), num(r['coverage']), num(r['completeness']), s(r['liquidity']), num(r.get('financial')), num(r.get('aggregate')),
                      num(r.get('final_notch')), num(r.get('notches')), num(fac.get('lgd')), s(fac.get('band')), num(fac.get('notch'))]]).rstrip())
    b.append(CHECK_BATCH.format(id=f'CE{i}', key=key))
    return '\n'.join(x for x in b if x) + '\nGO\n'


def eval_case(i, key, title, card, lines, kw):
    """The evaluation: the reference's full result with its scenarios, remedies, plans, triggers and outlook."""
    x = context(card, lines, kw)
    r = cr.assess(card, lines, **kw, with_plans=True)
    b = [f"/* CV{i}: {key} — {title} */"]
    b.append('DELETE #crX; DELETE #crL; DELETE #crP; DELETE #crColl; DELETE #crMix; DELETE #eEv; DELETE #eScen; DELETE #eRem; DELETE #ePlan; DELETE #eTrig;')
    b.append(f"INSERT #crX ({', '.join(X_COLS)})\nVALUES ({', '.join(x_values(x))});")
    b.append(insert('#crL', ['Code', 'Amount'], [[s(k), num(v)] for k, v in sorted(lines.items())]).rstrip())
    if kw.get('prior'):
        b.append(insert('#crP', ['Code', 'Amount'], [[s(k), num(v)] for k, v in sorted(kw['prior'].items())]).rstrip())
    coll = (kw.get('platform') or {}).get('collateral') or []
    if coll:
        b.append(insert('#crColl', ['Kind', 'Cover'], [[s(k), num(v)] for k, v in coll]).rstrip())
    mix = kw.get('product_mix') or []
    if mix:
        b.append('INSERT #crMix (ProductCategoryId, RevenueSharePct, InventorySharePct)\n' + '\nUNION ALL '.join(
            f"SELECT ProductCategoryId, {num(m['revenue_share_pct'])}, {num(m.get('inventory_share_pct', 0))} FROM fin.ProductCategory WHERE Code = {s(m['category'])}"
            for m in mix) + ';')
    o = r.get('outlook') or {}
    b.append(insert('#eEv', ['State', 'FinalNotch', 'Resilience', 'Outlook', 'OutlookRules'],
                    [[s(r['state']), num(r.get('final_notch')), s(r.get('resilience')), s(o.get('outlook')), s(','.join(o.get('rules', [])) or None)]]).rstrip())
    for name, v in sorted((r.get('scenarios') or {}).items()):
        pm = v['params']
        b.append(insert('#eScen', ['Scenario', 'FinalNotch', 'NotchesLost', 'Liquidity', 'RevenuePct', 'DsoDays', 'StLinesWithdrawnPct', 'PrivateArLossPct',
                                   'InventoryWritedownPct', 'UndrawnAvailablePct', 'CountryMult', 'LenderCostBp'],
                        [[s(name), num(v['notch']), num(v['lost']), s(v['liquidity']), num(pm['revenue_pct']), num(pm['dso_days']),
                          num(pm['st_lines_withdrawn_pct']), num(pm['private_ar_loss_pct']), num(pm['inventory_writedown_pct']),
                          num(pm['undrawn_available_pct']), num(pm['country_mult']), num(pm['lender_cost_bp'])]]).rstrip())
    rows = []
    for rm in r.get('remedies', []):
        pf = rm.get('final')
        rows.append([s(rm['code']), s(rm['trigger'][0]), s(rm['trigger'][1]), num(rm.get('moved')), num(cr.N[pf] if pf else None), num(rm.get('gained'))])
    b.append(insert('#eRem', ['Code', 'TriggerCode', 'TriggerLevel', 'Moved', 'FinalNotch', 'NotchesGained'], rows).rstrip())
    rows = [[s(pl['code']), num(pl['final_notch']), num(pl['gained']), s(','.join(st['remedy'] for st in pl['steps'])), num(pl['balanced'])] for pl in r.get('plans', [])]
    b.append(insert('#ePlan', ['Code', 'FinalNotch', 'NotchesGained', 'Steps', 'IsBalanced'], rows).rstrip())
    tr = (r.get('triggers') or {}).get('metrics') or []
    b.append(insert('#eTrig', ['MetricCode', 'Direction', 'TriggerValue', 'TargetScore'],
                    [[s(m['metric']), s(m['way']), num(m['value']), num(m['target_score'])] for m in tr]).rstrip())
    b.append(EVAL_BATCH.format(id=f'CV{i}', key=key))
    return '\n'.join(x for x in b if x) + '\nGO\n'


HEAD = """/* ============================================================================
   BankFas - the credit engine of 047 against the Python reference, number for number (generated by
   tools/dbgen/gen_credit_cases.py from tools/dbgen/credit_scorecard.json; do not edit; docs/35 section 16, ADR 0018)
   CE<n>  the core on the statement of a stress case or a variant: quantities, metrics, factors, item levels,
          adjustments, grades, liquidity, completeness and facility grade equal those of tools/dbgen/credit_reference.py
   CV<n>  the evaluation of the same statement: the grade after the scenarios and the resilience overlay, the two
          scenarios, every remedy with its pro-forma grade, the strengthening plans step by step with the balance of the
          balance sheet, the triggers of the grade and the outlook

   Run against a deployed BankFas database with a sysadmin login:
       sqlcmd -S <server> -U sa -C -I -b -i db/tests/credit_engine_cases.sql
   The cases read the methodology tables only and write temporary tables. Each prints one line: PASS or FAIL.
   ============================================================================ */
USE [BankFas];
GO
SET NOCOUNT ON;
GO
"""

TABLES = """CREATE TABLE #crX (ScorecardId INT, PeriodType VARCHAR(10) COLLATE DATABASE_DEFAULT, PriorPeriodType VARCHAR(10) COLLATE DATABASE_DEFAULT, HasPrior BIT, Fx FLOAT, Assurance VARCHAR(10) COLLATE DATABASE_DEFAULT, Opinion VARCHAR(11) COLLATE DATABASE_DEFAULT,
    GoingConcern BIT, HoldingStandalone BIT, Breach VARCHAR(16) COLLATE DATABASE_DEFAULT, BreachAtPeriodEnd BIT, FlowShortfall BIT, StatementAgeMonths INT, RestatedPct FLOAT,
    IndustryId INT, MarketSize FLOAT, RolloverFactor FLOAT, ResilienceNotch BIT, Proforma BIT, EvSub BIT, EvCap BIT, PfLimits FLOAT, PfOutstanding FLOAT,
    PfCommittedUndrawn FLOAT, PfLargestLenderShare FLOAT, PfExpiring12mShare FLOAT, PfLenders INT, BuPresent BIT, BuOutstanding FLOAT, BuLimits FLOAT,
    BuLenders INT, BuDpd12m INT, BuCurrentDefault BIT, BuDefaults24m INT, BuBouncedCount INT, BuBouncedAmount FLOAT, BuJudgments FLOAT, BuRestructured BIT,
    BuInquiries6m INT, BuMonthsAfterPeriodEnd INT, QualBp FLOAT, QualFp FLOAT, DocBp BIT, DocFp BIT, ProdCashFlowQuality FLOAT, ProdConcentration FLOAT,
    InvCrisisValue FLOAT, InvDaysStagnant FLOAT, Support INT, ParentNotch INT, Override INT, GuLiquid FLOAT, GuNetWorth FLOAT, GuGiven FLOAT,
    GuGuaranteed FLOAT, GuMaxLeverage FLOAT, CountryId INT, RegionCode VARCHAR(10) COLLATE DATABASE_DEFAULT,
    PfUndrawnDecided FLOAT, PfLenderRepayment FLOAT, PfDecidedShare FLOAT, PfDecidedCost FLOAT, PeriodMonths INT, PriorPeriodMonths INT, BuAgeMonths INT);
CREATE TABLE #crL (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT NULL);
CREATE TABLE #crP (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Amount FLOAT NULL);
CREATE TABLE #crColl (Kind VARCHAR(40) COLLATE DATABASE_DEFAULT NOT NULL, Cover FLOAT NOT NULL);
CREATE TABLE #crQ (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Value FLOAT NULL);
CREATE TABLE #crM (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, State VARCHAR(14) COLLATE DATABASE_DEFAULT NOT NULL, Value FLOAT NULL);
CREATE TABLE #crF (MetricId INT, Code VARCHAR(40) COLLATE DATABASE_DEFAULT, Kind VARCHAR(12) COLLATE DATABASE_DEFAULT, FactorCode VARCHAR(30) COLLATE DATABASE_DEFAULT, Weight FLOAT, EffectiveWeight FLOAT,
    Status VARCHAR(14) COLLATE DATABASE_DEFAULT, Value FLOAT, Score FLOAT, SortOrder INT);
CREATE TABLE #crI (MetricCode VARCHAR(40) COLLATE DATABASE_DEFAULT, LineCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Level VARCHAR(12) COLLATE DATABASE_DEFAULT, Value FLOAT, SortOrder INT);
CREATE TABLE #crA (Ord INT PRIMARY KEY, RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Stage VARCHAR(10) COLLATE DATABASE_DEFAULT, Notches INT, CapNotch INT, ParamValue FLOAT);
CREATE TABLE #crR (AdjCode VARCHAR(40) COLLATE DATABASE_DEFAULT, LineCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Bucket VARCHAR(20) COLLATE DATABASE_DEFAULT, Amount FLOAT);
CREATE TABLE #crD (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Given BIT NOT NULL);
CREATE TABLE #crMix (ProductCategoryId INT NOT NULL, RevenueSharePct FLOAT NOT NULL, InventorySharePct FLOAT NOT NULL);
CREATE TABLE #evScen (Scenario VARCHAR(30) COLLATE DATABASE_DEFAULT PRIMARY KEY, State VARCHAR(20) COLLATE DATABASE_DEFAULT, FinalNotch INT, WeightedScore FLOAT,
    Liquidity VARCHAR(6) COLLATE DATABASE_DEFAULT, NotchesLost INT, Revenue FLOAT, Ebitda FLOAT, Inventory FLOAT, ArLoss FLOAT, InventoryWritedown FLOAT,
    ExtraFinanceCost FLOAT, ReceivablesStretch FLOAT, BalanceGap FLOAT, RevenuePct FLOAT, GrossMarginPp FLOAT, DsoDays FLOAT, StLinesWithdrawnPct FLOAT,
    RateBp INT, PrivateArLossPct FLOAT, InventoryWritedownPct FLOAT, UndrawnAvailablePct FLOAT, CountryMult FLOAT, LenderCostBp FLOAT);
CREATE TABLE #evRem (SeqNo INT PRIMARY KEY, RemedyId INT NOT NULL, TriggerCode VARCHAR(40) COLLATE DATABASE_DEFAULT, TriggerLevel VARCHAR(12) COLLATE DATABASE_DEFAULT,
    Moved FLOAT, FinalNotch INT, WeightedScore FLOAT, NotchesGained INT, BalanceGap FLOAT);
CREATE TABLE #evPlan (PlanId INT PRIMARY KEY, StepCount INT, FinalNotch INT, FinalScore FLOAT, NotchesGained INT, IsBalanced BIT);
CREATE TABLE #evPlanStep (PlanId INT, StepNo INT, RemedyId INT, Moved FLOAT, FinalNotch INT, Score FLOAT, PRIMARY KEY (PlanId, StepNo));
CREATE TABLE #evTrig (MetricId INT, MetricCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Direction VARCHAR(4) COLLATE DATABASE_DEFAULT, CurrentValue FLOAT,
    TriggerValue FLOAT, Score FLOAT, TargetScore FLOAT);
CREATE TABLE #evSum (Resilience VARCHAR(10) COLLATE DATABASE_DEFAULT, Outlook VARCHAR(10) COLLATE DATABASE_DEFAULT, OutlookRules VARCHAR(200) COLLATE DATABASE_DEFAULT,
    IndicatedNotch INT, UpHeadroom FLOAT, DownHeadroom FLOAT);
CREATE TABLE #crS (State VARCHAR(20) COLLATE DATABASE_DEFAULT, Coverage FLOAT, FinancialScore FLOAT, FinancialNotch INT, WeightedScore FLOAT, IndicatedNotch INT, NotchesRaw INT,
    Notches INT, CapStandalone INT, CapAbsolute INT, StandaloneNotch INT, SupportedNotch INT, OverriddenNotch INT, FinalNotch INT, Liquidity VARCHAR(6) COLLATE DATABASE_DEFAULT,
    Completeness FLOAT, FacilityLgd FLOAT, FacilityBand VARCHAR(4) COLLATE DATABASE_DEFAULT, FacilityNotch INT, UnsecuredRecovery FLOAT, AdjustedDebt FLOAT, AdjustedTnw FLOAT,
    RealisableNetWorth FLOAT, Ebitda FLOAT, Revenue FLOAT, Inventory FLOAT);
"""

def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, '..', '..', 'db', 'tests', 'credit_engine_cases.sql')
    cs = cases()
    parts = [HEAD, TABLES, CHECK_SQL]
    for i, (key, title, card, lines, kw) in enumerate(cs, 1):
        parts.append(core_case(i, key, title, card, lines, kw))
    for i, (key, title, card, lines, kw) in enumerate(cs, 1):
        parts.append(eval_case(i, key, title, card, lines, kw))
    parts.append(FOOT)
    open(out, 'w', encoding='utf-8', newline='\n').write('\n'.join(parts))
    print(f'{len(cs)} cases -> {out}')


def nd(a, b, tol=None, rel=False):
    """The SQL condition that two values differ, null-safe: one unknown and the other known is a difference (review
    B2). Numbers differ by more than tol (rel: tol times one plus the larger magnitude); text and integers by <>."""
    one = f"(({a}) IS NULL AND ({b}) IS NOT NULL OR ({a}) IS NOT NULL AND ({b}) IS NULL"
    if tol is None:
        return one + f" OR ({a}) <> ({b}))"
    if rel:
        return one + (f" OR ABS(({a}) - ({b})) > {tol} * (1 + CASE WHEN ABS({a}) > ABS({b}) THEN ABS({a}) ELSE ABS({b}) END))")
    return one + f" OR ABS(({a}) - ({b})) > {tol})"


CHECK_SQL = """CREATE TABLE #eQ (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Value FLOAT NULL);
CREATE TABLE #eM (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, State VARCHAR(14) COLLATE DATABASE_DEFAULT, Value FLOAT NULL);
CREATE TABLE #eF (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Score FLOAT NULL, EffectiveWeight FLOAT NULL);
CREATE TABLE #eI (MetricCode VARCHAR(40) COLLATE DATABASE_DEFAULT, LineCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Level VARCHAR(12) COLLATE DATABASE_DEFAULT, Value FLOAT NULL,
    PRIMARY KEY (MetricCode, LineCode));
CREATE TABLE #eA (RuleCode VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, Notches INT NULL, CapNotch INT NULL);
CREATE TABLE #eEv (State VARCHAR(20) COLLATE DATABASE_DEFAULT, FinalNotch INT, Resilience VARCHAR(10) COLLATE DATABASE_DEFAULT,
    Outlook VARCHAR(10) COLLATE DATABASE_DEFAULT, OutlookRules VARCHAR(200) COLLATE DATABASE_DEFAULT);
CREATE TABLE #eScen (Scenario VARCHAR(30) COLLATE DATABASE_DEFAULT PRIMARY KEY, FinalNotch INT, NotchesLost INT, Liquidity VARCHAR(6) COLLATE DATABASE_DEFAULT,
    RevenuePct FLOAT, DsoDays FLOAT, StLinesWithdrawnPct FLOAT, PrivateArLossPct FLOAT, InventoryWritedownPct FLOAT, UndrawnAvailablePct FLOAT,
    CountryMult FLOAT, LenderCostBp FLOAT);
CREATE TABLE #eRem (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, TriggerCode VARCHAR(40) COLLATE DATABASE_DEFAULT, TriggerLevel VARCHAR(12) COLLATE DATABASE_DEFAULT,
    Moved FLOAT, FinalNotch INT, NotchesGained INT);
CREATE TABLE #ePlan (Code VARCHAR(40) COLLATE DATABASE_DEFAULT PRIMARY KEY, FinalNotch INT, NotchesGained INT, Steps VARCHAR(1000) COLLATE DATABASE_DEFAULT, IsBalanced BIT);
CREATE TABLE #eTrig (MetricCode VARCHAR(40) COLLATE DATABASE_DEFAULT, Direction VARCHAR(4) COLLATE DATABASE_DEFAULT, TriggerValue FLOAT, TargetScore FLOAT,
    PRIMARY KEY (MetricCode, Direction));
CREATE TABLE #eS (State VARCHAR(20) COLLATE DATABASE_DEFAULT, Coverage FLOAT, Completeness FLOAT, Liquidity VARCHAR(6) COLLATE DATABASE_DEFAULT, FinancialScore FLOAT, WeightedScore FLOAT, FinalNotch INT,
    Notches INT, FacilityLgd FLOAT, FacilityBand VARCHAR(4) COLLATE DATABASE_DEFAULT, FacilityNotch INT);
GO
"""

EVAL_BATCH = """-- The evaluation's results against the reference's; every comparison is null-safe and every row is matched both ways.
DECLARE @Id VARCHAR(10) = '{id}', @Key VARCHAR(60) = '{key}';
BEGIN
    DECLARE @err NVARCHAR(4000) = NULL;
    BEGIN TRY
        EXEC fin.usp_CreditEvaluate @WithScenarios = 1, @WithRemedies = 1, @WithPlans = 1;
    END TRY
    BEGIN CATCH
        SET @err = CONCAT('error ', ERROR_NUMBER(), ' ', ERROR_PROCEDURE(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
    END CATCH;
    DECLARE @d TABLE (n INT IDENTITY, t NVARCHAR(400) COLLATE DATABASE_DEFAULT);
    IF @err IS NOT NULL
        INSERT @d (t) VALUES (@err);
    ELSE
    BEGIN
        IF (SELECT COUNT(*) FROM #crS) <> 1 OR (SELECT COUNT(*) FROM #evSum) <> 1
            INSERT @d (t) VALUES (CONCAT('summary rows ', (SELECT COUNT(*) FROM #crS), '/', (SELECT COUNT(*) FROM #evSum), ', expected one each'));
        INSERT @d (t)
        SELECT CONCAT('result ', e.State, '/', s.State, ' final ', e.FinalNotch, '/', s.FinalNotch, ' resilience ', e.Resilience, '/', v.Resilience,
                      ' outlook ', e.Outlook, ' ', e.OutlookRules, '/', v.Outlook, ' ', v.OutlookRules)
        FROM #eEv AS e LEFT JOIN #crS AS s ON 1 = 1 LEFT JOIN #evSum AS v ON 1 = 1
        WHERE s.State IS NULL OR """ + '\n           OR '.join([nd('e.State', 's.State'), nd('e.FinalNotch', 's.FinalNotch'), nd('e.Resilience', 'v.Resilience'),
                                                     nd('e.Outlook', 'v.Outlook'), nd('e.OutlookRules', 'v.OutlookRules')]) + """;
        INSERT @d (t)
        SELECT CONCAT('scenario ', COALESCE(e.Scenario, x.Scenario), ' ', e.FinalNotch, ' lost ', e.NotchesLost, ' ', e.Liquidity, ' / ', x.FinalNotch, ' lost ',
                      x.NotchesLost, ' ', x.Liquidity)
        FROM #eScen AS e FULL JOIN #evScen AS x ON x.Scenario = e.Scenario
        WHERE e.Scenario IS NULL OR x.Scenario IS NULL OR """ + '\n           OR '.join(
            [nd('e.FinalNotch', 'x.FinalNotch'), nd('e.NotchesLost', 'x.NotchesLost'), nd('e.Liquidity', 'x.Liquidity')]
            + [nd('e.' + c, 'x.' + c, '1e-6') for c in ('RevenuePct', 'DsoDays', 'StLinesWithdrawnPct', 'PrivateArLossPct', 'InventoryWritedownPct',
                                                      'UndrawnAvailablePct', 'CountryMult', 'LenderCostBp')]) + """;
        INSERT @d (t)
        SELECT CONCAT('remedy ', COALESCE(e.Code, r.Code), ' ', e.TriggerCode, ' ', e.TriggerLevel, ' ', CONVERT(VARCHAR(30), e.Moved, 3), ' ', e.FinalNotch, ' ', e.NotchesGained,
                      ' / ', x.TriggerCode, ' ', x.TriggerLevel, ' ', CONVERT(VARCHAR(30), x.Moved, 3), ' ', x.FinalNotch, ' ', x.NotchesGained)
        FROM #eRem AS e
        FULL JOIN (#evRem AS x JOIN fin.CreditRemedy AS r ON r.CreditRemedyId = x.RemedyId) ON r.Code = e.Code
        WHERE e.Code IS NULL OR r.Code IS NULL OR """ + '\n           OR '.join(
            [nd('e.TriggerCode', 'x.TriggerCode'), nd('e.TriggerLevel', 'x.TriggerLevel'), nd('e.FinalNotch', 'x.FinalNotch'),
             nd('e.NotchesGained', 'x.NotchesGained'), nd('e.Moved', 'x.Moved', '1e-6', rel=True)]) + """;
        INSERT @d (t)
        SELECT CONCAT('plan ', COALESCE(e.Code, p.Code), ' ', e.FinalNotch, ' +', e.NotchesGained, ' ', e.Steps, ' / ', x.FinalNotch, ' +', x.NotchesGained, ' ', st.Steps,
                      ' balanced ', e.IsBalanced, '/', x.IsBalanced)
        FROM #ePlan AS e
        FULL JOIN (#evPlan AS x JOIN fin.StrengtheningPlan AS p ON p.StrengtheningPlanId = x.PlanId) ON p.Code = e.Code
        OUTER APPLY (SELECT STRING_AGG(r.Code, ',') WITHIN GROUP (ORDER BY s.StepNo) AS Steps FROM #evPlanStep AS s
                     JOIN fin.CreditRemedy AS r ON r.CreditRemedyId = s.RemedyId WHERE s.PlanId = x.PlanId) AS st
        WHERE e.Code IS NULL OR p.Code IS NULL OR """ + '\n           OR '.join(
            [nd('e.FinalNotch', 'x.FinalNotch'), nd('e.NotchesGained', 'x.NotchesGained'), nd('e.Steps', 'st.Steps'), nd('e.IsBalanced', 'x.IsBalanced')]) + """;
        INSERT @d (t)
        SELECT CONCAT('trigger ', COALESCE(e.MetricCode, x.MetricCode), ' ', COALESCE(e.Direction, x.Direction), ' ', CONVERT(VARCHAR(30), e.TriggerValue, 3), ' / ',
                      CONVERT(VARCHAR(30), x.TriggerValue, 3))
        FROM #eTrig AS e FULL JOIN #evTrig AS x ON x.MetricCode = e.MetricCode AND x.Direction = e.Direction
        -- a trigger agrees when its value does, or its target score does to a thousandth: the weighted score is rounded to
        -- four decimals on both sides, and a steep grid turns its last digit into a visible difference of value
        WHERE e.MetricCode IS NULL OR x.MetricCode IS NULL
           OR (""" + nd('e.TriggerValue', 'x.TriggerValue', '1e-5', rel=True) + '\n               AND ' + nd('e.TargetScore', 'x.TargetScore', '1e-3') + """);
    END;
    DECLARE @n INT = (SELECT COUNT(*) FROM @d), @first NVARCHAR(4000);
    SELECT @first = STRING_AGG(t, '; ') WITHIN GROUP (ORDER BY n) FROM @d WHERE n <= 6;
    IF @n = 0
        PRINT CONCAT('PASS ', @Id, ': ', @Key, ' - the evaluation equals the reference');
    ELSE
        PRINT CONCAT('FAIL ', @Id, ': ', @Key, ' - ', @n, ' differences: ', @first);
END;
"""

CHECK_BATCH = """-- The core's results against the reference's: every difference is listed, the first ones printed with the FAIL line.
-- Every comparison is null-safe (one side unknown and the other known is a difference) and every row is matched both
-- ways (review B2).
DECLARE @Id VARCHAR(10) = '{id}', @Key VARCHAR(60) = '{key}';
BEGIN
    DECLARE @err NVARCHAR(4000) = NULL;
    BEGIN TRY
        EXEC fin.usp_CreditCore;
    END TRY
    BEGIN CATCH
        SET @err = CONCAT('error ', ERROR_NUMBER(), ' line ', ERROR_LINE(), ': ', ERROR_MESSAGE());
    END CATCH;
    DECLARE @d TABLE (n INT IDENTITY, t NVARCHAR(400) COLLATE DATABASE_DEFAULT);
    IF @err IS NOT NULL
        INSERT @d (t) VALUES (@err);
    ELSE
    BEGIN
        -- two numbers agree when both are unknown, or they differ by less than a millionth of the larger (and of one unit)
        INSERT @d (t)
        SELECT CONCAT('quantity ', COALESCE(e.Code, q.Code), ' ', CONVERT(VARCHAR(30), e.Value, 3), ' <> ', CONVERT(VARCHAR(30), q.Value, 3),
                      CASE WHEN e.Code IS NULL THEN ' not expected' WHEN q.Code IS NULL THEN ' missing' END)
        FROM #eQ AS e FULL JOIN #crQ AS q ON q.Code = e.Code
        WHERE e.Code IS NULL OR q.Code IS NULL OR """ + nd('e.Value', 'q.Value', '1e-6', rel=True) + """;
        INSERT @d (t)
        SELECT CONCAT('metric ', COALESCE(e.Code, m.Code), ' ', ISNULL(e.State, 'not expected'), ' ', CONVERT(VARCHAR(30), e.Value, 3), ' <> ', ISNULL(m.State, 'missing'), ' ',
                      CONVERT(VARCHAR(30), m.Value, 3))
        FROM #eM AS e FULL JOIN #crM AS m ON m.Code = e.Code
        WHERE e.Code IS NULL OR m.Code IS NULL OR """ + nd('e.State', 'm.State') + '\n           OR ' + nd('e.Value', 'm.Value', '1e-6', rel=True) + """;
        INSERT @d (t)
        SELECT CONCAT('factor ', COALESCE(e.Code, f.Code), ' score ', e.Score, ' <> ', f.Score, ' weight ', e.EffectiveWeight, ' <> ', f.EffectiveWeight)
        FROM #eF AS e FULL JOIN #crF AS f ON f.Code = e.Code
        WHERE e.Code IS NULL OR f.Code IS NULL OR """ + nd('e.Score', 'f.Score', '1e-4') + '\n           OR ' + nd('e.EffectiveWeight', 'f.EffectiveWeight', '1e-6') + """;
        INSERT @d (t)
        SELECT CONCAT('item ', COALESCE(e.MetricCode, i.MetricCode), '/', COALESCE(e.LineCode, i.LineCode), ' ', ISNULL(e.Level, 'not expected'), ' ',
                      CONVERT(VARCHAR(30), e.Value, 3), ' <> ', ISNULL(i.Level, 'missing'), ' ', CONVERT(VARCHAR(30), i.Value, 3))
        FROM #eI AS e FULL JOIN #crI AS i ON i.MetricCode = e.MetricCode AND i.LineCode = e.LineCode
        WHERE e.MetricCode IS NULL OR i.MetricCode IS NULL OR """ + nd('e.Level', 'i.Level') + '\n           OR ' + nd('e.Value', 'i.Value', '1e-6', rel=True) + """;
        INSERT @d (t)
        SELECT CONCAT('adjustment ', COALESCE(e.RuleCode, a.RuleCode), CASE WHEN a.RuleCode IS NULL THEN ' expected' WHEN e.RuleCode IS NULL THEN ' not expected' END,
                      ' notches ', e.Notches, '/', a.Notches, ' cap ', e.CapNotch, '/', a.CapNotch)
        FROM #eA AS e FULL JOIN #crA AS a ON a.RuleCode = e.RuleCode
        WHERE e.RuleCode IS NULL OR a.RuleCode IS NULL OR """ + nd('e.Notches', 'a.Notches') + '\n           OR ' + nd('e.CapNotch', 'a.CapNotch') + """;
        IF (SELECT COUNT(*) FROM #crS) <> 1
            INSERT @d (t) VALUES (CONCAT('summary rows ', (SELECT COUNT(*) FROM #crS), ', expected one'));
        INSERT @d (t)
        SELECT CONCAT('summary ', e.State, '/', s.State, ' coverage ', e.Coverage, '/', s.Coverage, ' completeness ', e.Completeness, '/', s.Completeness,
                      ' liquidity ', e.Liquidity, '/', s.Liquidity, ' financial ', e.FinancialScore, '/', s.FinancialScore, ' aggregate ', e.WeightedScore,
                      '/', s.WeightedScore, ' final ', e.FinalNotch, '/', s.FinalNotch, ' notches ', e.Notches, '/', s.Notches, ' facility ',
                      e.FacilityBand, ' ', e.FacilityLgd, ' ', e.FacilityNotch, '/', s.FacilityBand, ' ', s.FacilityLgd, ' ', s.FacilityNotch)
        FROM #eS AS e LEFT JOIN #crS AS s ON 1 = 1
        WHERE s.State IS NULL OR """ + '\n           OR '.join(
            [nd('e.State', 's.State'), nd('e.Coverage', 's.Coverage', '0.01'), nd('e.Completeness', 's.Completeness', '0.01'), nd('e.Liquidity', 's.Liquidity'),
             nd('e.FinancialScore', 's.FinancialScore', '1e-4'), nd('e.WeightedScore', 's.WeightedScore', '1e-4'), nd('e.FinalNotch', 's.FinalNotch'),
             nd('e.Notches', 's.Notches'), nd('e.FacilityBand', 's.FacilityBand'), nd('e.FacilityNotch', 's.FacilityNotch'),
             nd('e.FacilityLgd', 's.FacilityLgd', '1e-4')]) + """;
    END;
    DECLARE @n INT = (SELECT COUNT(*) FROM @d), @first NVARCHAR(4000);
    SELECT @first = STRING_AGG(t, '; ') WITHIN GROUP (ORDER BY n) FROM @d WHERE n <= 6;
    IF @n = 0
        PRINT CONCAT('PASS ', @Id, ': ', @Key, ' - the core equals the reference');
    ELSE
        PRINT CONCAT('FAIL ', @Id, ': ', @Key, ' - ', @n, ' differences: ', @first);
END;
"""

FOOT = ""

if __name__ == '__main__':
    main()
