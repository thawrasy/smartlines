#!/usr/bin/env python3
"""credit_doc.py — the generated tables of docs/35-credit-assessment-methodology.md (version 2).

Every table between the `<!-- gen:NAME -->` markers of docs/35 is written from tools/dbgen/credit_scorecard.json (and,
for the worked example and the stress cases, computed by tools/dbgen/credit_reference.py), so the document and the
seed of the database never disagree. tools/dbgen/gen_credit_seed.py --doc writes them; --doc-check (CI step 2) fails
when the document differs.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SECTION = {'BS_ASSET': 'أصول', 'BS_LIABILITY': 'خصوم', 'BS_EQUITY': 'حقوق ملكية', 'IS': 'قائمة الدخل', 'CF': 'التدفقات النقدية', 'MEMO': 'إفصاح'}
KIND = {'LINE': 'بند', 'TOTAL': 'إجمالي', 'OF_WHICH': 'منه', 'DETAIL': 'تفصيل', 'MEMO': 'إفصاح'}
UNIT = {'AMOUNT': 'مليون', 'PERCENT': '%', 'RATIO': 'مرة', 'DAYS': 'يوم', 'MONTHS': 'شهر', 'YEARS': 'سنة', 'GRADE': 'درجة'}
DIR = {'LOWER_BETTER': 'الأدنى أفضل', 'HIGHER_BETTER': 'الأعلى أفضل', 'NONE': '—'}
STAGE = {'NOTCH': '1. تنزيل', 'STANDALONE': '2. سقف منفرد', 'ABSOLUTE': '4. سقف مطلق'}
FUNDING = None
LEVEL = {'LOW': 'منخفضة', 'MODERATE': 'معتدلة', 'ELEVATED': 'مرتفعة نسبيًا', 'HIGH': 'مرتفعة', 'CRITICAL': 'حرجة', 'NOT_ASSESSED': 'لم يُقيَّم'}
CYC = {'LOW': 'منخفضة', 'MEDIUM': 'متوسطة', 'HIGH': 'مرتفعة'}
# The worked example of section 16: the statement of test CA2 (db/tests/credit_assessment_tests.sql) in SAR millions.
EXAMPLE = ('CASH=45;AR=160;INVENTORY=130;DUE_FROM_RELATED=20;OTHER_CA=25;TOTAL_CA=380;PPE=520;INTANGIBLES=30;OTHER_NCA=70;TOTAL_ASSETS=1000;'
           'ST_LOANS=120;CURRENT_PORTION_LTD=60;AP=110;DUE_TO_RELATED=10;OTHER_CL=50;TOTAL_CL=350;LT_LOANS=180;LEASE_LIABS=20;'
           'SHAREHOLDER_LOANS_SUB=0;EOSB=18;OTHER_NCL=12;TOTAL_LIABS=580;SHARE_CAPITAL=250;RETAINED_EARNINGS=140;OTHER_EQUITY=30;'
           'MINORITY_INTEREST=0;TOTAL_EQUITY=420;REVENUE=900;COGS=650;GROSS_PROFIT=250;OPEX=160;DEPR_AMORT=40;EBITDA=130;'
           'OPERATING_PROFIT=90;FINANCE_COSTS=22;OTHER_INCOME=4;ZAKAT_TAX=8;NET_PROFIT=64;OP_CASH_FLOW=95;CAPEX=60;'
           'PRINCIPAL_REPAID=55;INTEREST_PAID=21;DIVIDENDS=30;LC_OUTSTANDING=90;LG_PERFORMANCE=100;LG_FINANCIAL=20;GUARANTEES_GIVEN=0')
EXAMPLE_PRIOR = 'TOTAL_ASSETS=940;REVENUE=850;GROSS_PROFIT=245;CURRENT_PORTION_LTD=55;OP_CASH_FLOW=85'


def cell(x):
    return '—' if x is None or x == '' else str(x).replace('|', '\\|').replace('\n', ' ')


def num(v):
    if v is None:
        return '—'
    if isinstance(v, bool):
        return 'نعم' if v else 'لا'
    if isinstance(v, (int,)) or float(v).is_integer():
        return f'{int(v):,}'
    return f'{v:,.4f}'.rstrip('0').rstrip('.')


def table(head, rows):
    out = ['| ' + ' | '.join(head) + ' |', '|' + '---|' * len(head)]
    out += ['| ' + ' | '.join(cell(c) for c in r) + ' |' for r in rows]
    return '\n'.join(out)


def lines_from(spec, scale=1e6):
    d = {}
    for kv in [x for x in spec.split(';') if '=' in x]:
        k, v = kv.split('=')
        d[k] = float(v) * scale
    return d


def doc_tables(M):
    import credit_reference as cr
    T = {}
    texts = {(t['domain'], t['code']): t for t in M['texts']}
    metric = {m['code']: m for m in M['metrics']}
    lines = {x['code']: x for x in M['lines']}
    gen = next(c for c in M['scorecards'] if c['code'] == 'GENERAL_CORPORATE')
    # 1. the scale
    T['grades'] = table(['الدرجة', 'الرتبة', 'الفئة', 'المجال على الخط', 'المخاطر', 'درجة استثمار', 'مقابلها عند فيتش', 'المعنى'],
                        [[g['code'], g['notch'], g['category'],
                          ('x < 1.5' if g['code'] == 'Aaa' else f"x ≥ {g['from']}" if g['code'] == 'Ca' else '—' if g['code'] == 'C' else f"{g['from']} ≤ x < {g['to']}"),
                          M['band_text'][g['band']][0], 'نعم' if g['ig'] else 'لا', g['fitch'], M['category_text'][g['category']][0]] for g in M['grades']])
    # 2. the standard lines, by section, with the metrics that test each
    tested = {}
    for c in M['scorecards']:
        for ir in c['items']:
            tested.setdefault(ir['line'], [])
            if ir['r'] not in tested[ir['line']]:
                tested[ir['line']].append(ir['r'])
    for sec in ('BS_ASSET', 'BS_LIABILITY', 'BS_EQUITY', 'IS', 'CF', 'MEMO'):
        rows = []
        for x in M['lines']:
            if x['section'] != sec:
                continue
            rows.append([f"`{x['code']}`", x['ar'], KIND[x['kind']], f"`{x['parent']}`" if x['parent'] else '—', x['formula'] or '—',
                         ', '.join(f"`{m}`" for m in tested.get(x['code'], [])) or '—'])
        T[f'lines_{sec}'] = table(['الرمز', 'البند', 'النوع', 'يفصّل', 'الصيغة', 'تختبره قواعد'], rows)
    # 3. the themes and the metric dictionary
    themes = M['themes']
    T['themes'] = table(['المحور', 'المقاييس'], [[v[0], ', '.join(f"`{m['code']}`" for m in M['metrics'] if m.get('theme') == k)] for k, v in themes.items()])
    T['metrics'] = table(['الرمز', 'المقياس', 'الوحدة', 'الاتجاه', 'المحور', 'التعريف'],
                         [[f"`{m['code']}`", m['ar'], UNIT[m['unit']], DIR[m['dir']], themes.get(m.get('theme'), ['—'])[0], m['def']] for m in M['metrics']])
    rem_by_trigger = {}
    for r in M['remedies']:
        for t in r['triggers']:
            rem_by_trigger.setdefault(t, []).append(r['code'])
    T['effects'] = table(['المقياس', 'أثره على النقد', 'أثره على الملاءة', 'الحلول التي يستدعيها'],
                         [[f"`{m['code']}` {m['ar']}", (m.get('cash') or ['—'])[0], (m.get('solvency') or ['—'])[0],
                           ', '.join(f"`{x}`" for x in rem_by_trigger.get(m['code'], [])) or '—'] for m in M['metrics'] if m['kind'] == 'QUANTITATIVE'])
    # 4. the scorecards, their sub-factors, their item rules, their parameters
    FACT = ['SCALE', 'BUSINESS_PROFILE', 'PROFITABILITY_EFFICIENCY', 'LEVERAGE_COVERAGE', 'CAPITAL_SOLVENCY', 'LIQUIDITY_FUNDING', 'BALANCE_SHEET_QUALITY',
            'FINANCIAL_POLICY']
    acts = M['industries']['activities']
    T['families'] = table(['البطاقة', 'العائلة', 'أساسها', 'المقاييس'] + [M['factor_names'][f][0] for f in FACT] + ['الأنشطة'],
                          [[f"`{c['code']}`", c['ar'], c.get('base') or '—', len(c['metrics'])]
                           + [num(sum(sm['w'] for sm in c['metrics'] if sm['f'] == f)) for f in FACT]
                           + [sum(1 for a in acts if a['card'] == c['code'])] for c in M['scorecards']])
    T['families_why'] = table(['البطاقة', 'لماذا تختلف أوزانها'], [[f"`{c['code']}` {c['ar']}", c.get('why_ar') or c.get('sector')] for c in M['scorecards']])
    for c in M['scorecards']:
        rows = []
        for sm in c['metrics']:
            md = metric[sm['m']]
            grid = ['تقدير'] * 9 if md['kind'] == 'QUALITATIVE' else [num(v) for v in sm['b']]
            rows.append([M['factor_names'][sm['f']][0], f"`{sm['m']}` {md['ar']}", num(sm['w'])] + grid)
        T[f"card_{c['code']}"] = table(['العامل', 'المقياس', 'الوزن %', 'أفضل حد (0.5)', 'Aaa\\|Aa', 'Aa\\|A', 'A\\|Baa', 'Baa\\|Ba', 'Ba\\|B', 'B\\|Caa', 'Caa\\|Ca',
                                        'أسوأ حد (20.5)'], rows)
        if c.get('base'):
            continue
        T[f"items_{c['code']}"] = table(['البند', 'المقياس', 'منخفضة \\| معتدلة', 'معتدلة \\| مرتفعة نسبيًا', 'مرتفعة نسبيًا \\| مرتفعة', 'مرتفعة \\| حرجة', 'يُذكر قوةً'],
                                        [[f"`{ir['line']}`", f"`{ir['r']}` {metric[ir['r']]['ar']}"] + [num(v) for v in ir['t']] + ['نعم' if ir['strength'] else 'لا']
                                         for ir in c['items']])
    rows = []
    for c in M['scorecards']:
        for f, subs in c['qualitative'].items():
            if c.get('base') and f == 'FINANCIAL_POLICY':
                continue
            for s in subs:
                g = s.get('guide_ar') or {}
                rows.append([c['code'], M['factor_names'][f][0], f"`{s['code']}` {s['ar']}"] + [g.get(k, '—') for k in ('Aa', 'A', 'Baa', 'Ba', 'B')])
    T['subfactors'] = table(['البطاقة', 'العامل', 'العامل الفرعي', 'Aa', 'A', 'Baa', 'Ba', 'B'], rows)
    cards = [c for c in M['scorecards'] if not c.get('base')]
    keys = sorted({k for c in cards for k in c['params']})
    T['params'] = table(['المعامل'] + [c['code'] for c in cards], [[f"`{k}`"] + [num(c['params'].get(k)) for c in cards] for k in keys])
    keys = list(gen['realisable_haircuts'])
    T['haircuts'] = table(['البند'] + [c['code'] for c in cards], [[f"`{k}`"] + [num(c['realisable_haircuts'].get(k)) for c in cards] for k in keys])
    keys = list(gen['fixed_cost_rule'])
    T['fixed_costs'] = table(['القاعدة'] + [c['code'] for c in cards], [[f"`{k}`"] + [num(c['fixed_cost_rule'].get(k)) for c in cards] for k in keys])
    # 5. the reconciliation of the analytical statement
    T['reclass'] = table(['الرمز', 'التعديل', 'سببه'], [[f"`{t['code']}`", t['ar'], t['text'][0]] for t in M['texts'] if t['domain'] == 'RECLASS'])
    # 6. the adjustments
    rows = []
    for a in M['adjustments'] + [x for c in M['scorecards'] for x in c['extra_adjustments']]:
        if a['r'] == 'NOTCH_FLOOR':
            continue
        eff = f"تنزيل {-a['n']}" if a['stage'] == 'NOTCH' and a['n'] < 0 else ('مراقبة بلا تنزيل' if a['stage'] == 'NOTCH' else f"لا تتجاوز {a['cap'] or 'سقف النشاط'}")
        on = [c['code'] for c in M['scorecards'] if a in c['extra_adjustments']] or ['كلها']
        rows.append([f"`{a['r']}` {a['ar']}", STAGE[a['stage']], eff, num(a.get('p')), ', '.join(on), a['t'][0]])
    T['adjustments'] = table(['القاعدة', 'المرحلة', 'الأثر', 'المعامل', 'البطاقات', 'النص'], rows)
    # 7. liquidity, facility grade, Fitch
    L, LG = M['liquidity'], M['lgd']
    T['liquidity'] = table(['التسمية', 'تغطية مصادر السنة لاستخداماتها', 'المعنى'],
                           [['SGL-1', f"≥ {L['sgl'][0]}", texts[('LIQUIDITY', 'SGL-1')]['text'][0]],
                            ['SGL-2', f"{L['sgl'][1]} إلى أقل من {L['sgl'][0]}", texts[('LIQUIDITY', 'SGL-2')]['text'][0]],
                            ['SGL-3', f"{L['sgl'][2]} إلى أقل من {L['sgl'][1]}", texts[('LIQUIDITY', 'SGL-3')]['text'][0]],
                            ['SGL-4', f"أقل من {L['sgl'][2]} (وأقل من {L['severe_below']} شديدة)", texts[('LIQUIDITY', 'SGL-4')]['text'][0]]])
    T['lgd_bands'] = table(['النطاق', 'الخسارة عند التعثر حتى %', 'درجات فوق درجة الملتزم', 'تصنيف الاسترداد عند فيتش'],
                           [[b['code'], num(b['max_lgd_pct']), num(b['notches']), M['fitch']['recovery'][b['code']]] for b in LG['bands']])
    T['collateral'] = table(['نوع الضمان', 'الخصم %'], [[f"`{k}`", num(v)] for k, v in LG['collateral_haircuts'].items()])
    T['guarantors'] = table(['تغطية الأصول السائلة للكفلاء للتعرض (مرة)', 'أقصى رفع للكفيل %', 'درجات إضافية'],
                            [[num(u['min_coverage']), num(u['max_guarantor_leverage_pct']), num(u['notches'])] for u in LG['guarantor_uplift']])
    # 8. completeness and the data the report requests
    rows = [[f"`{c['code']}`", texts[('DISCLOSURE', c['code'])]['ar'], c['expected_when'], c['given_when'], texts[('DISCLOSURE', c['code'])]['text'][0]] for c in M['completeness']]
    T['disclosures'] = table(['الرمز', 'الإفصاح', 'يُطلب حين', 'يُعد مقدَّمًا حين', 'نص الطلب في التقرير'], rows)
    T['requests'] = table(['الرمز', 'الطلب', 'نصه'], [[f"`{t['code']}`", t['ar'], t['text'][0]] for t in M['texts'] if t['domain'] == 'REQUEST'])
    # 9. the activities and the product categories
    pcat = {p['code']: p for p in M['product_categories']}
    SH = {'DEMAND': 'طلب', 'GOV_SPENDING': 'حكومة', 'REAL_ESTATE': 'عقار', 'CONFLICT': 'نزاع', 'OIL': 'نفط', 'CREDIT': 'ائتمان', 'IMPORT_FX': 'استيراد'}
    sens = lambda d: ' '.join(f"{SH[k]} {d['sens'][k]}" for k in SH)
    anc = lambda d: cr.GR[cr.anchor_notch(d['code'], 'SA') - 1]
    T['industries'] = table(['الرمز', 'الفرع', 'البطاقة', 'مخاطر النشاط (1–6)', 'الدورية', 'المرتكز في السعودية', 'سقف', 'الحساسية للمحركات (0–5)', 'أنشطته'],
                            [[f"`{d['code']}`", d['ar'], d['card'], d['industry_risk'], CYC[d['cyclicality']], anc(d), d.get('ceiling') or '—', sens(d),
                              sum(1 for a in acts if a['division'] == d['code'])] for d in M['industries']['divisions']])
    T['activities'] = table(['الرمز', 'النشاط', 'البطاقة', 'مخاطر النشاط', 'الدورية', 'المرتكز في السعودية', 'سقف', 'الحساسية للمحركات (0–5)', 'لماذا'],
                            [[f"`{d['code']}`", d['ar'], d['card'], d['industry_risk'], CYC[d['cyclicality']], anc(d), d.get('ceiling') or '—', sens(d),
                              d.get('note_ar')] for d in acts])
    CRk = M['country_risk']
    T['anchor'] = table(['مخاطر البلد \\ مخاطر النشاط', '1', '2', '3', '4', '5', '6'],
                        [[str(i)] + [cr.GR[v - 1] for v in row] for i, row in enumerate(CRk['anchor'], 1)])
    T['countries'] = table(['البلد', 'مخاطر البلد (1–6)', 'التصنيف السيادي (تاريخه)', 'سقف الشركات', 'التعرض: ' + ' / '.join(SH.values()), 'المدن والمناطق', 'ملاحظة'],
                           [[f"{c['ar']} `{c['iso2']}`", c['country_risk'], f"{c['sovereign_rating']} ({c['rating_as_of']})" if c.get('sovereign_rating') else 'غير مصنّف',
                             c.get('sovereign_rating') or CRk['unrated_ceiling'][str(c['country_risk'])], ' / '.join(num(c['exposure'][k]) for k in SH),
                             len(c.get('regions') or []), c.get('note_ar')] for c in CRk['countries']]
                           + [['افتراضي (بلد بلا ملف)', CRk['default']['country_risk'], '—', CRk['unrated_ceiling'][str(CRk['default']['country_risk'])],
                               ' / '.join(num(CRk['default']['exposure'][k]) for k in SH), 0, 'يُطلب ملف البلد']])
    TIER = {'PRIME': 'رئيسية', 'MAJOR': 'كبرى', 'SECONDARY': 'ثانوية', 'PERIPHERAL': 'طرفية'}
    T['regions'] = table(['البلد', 'الرمز', 'المدينة أو المنطقة', 'الفئة', 'مضاعف العقار', 'مضاعف النزاع'],
                         [[c['iso2'], f"`{r['code']}`", r['ar'], TIER[r['tier']], num(r['re_mult']), num(r['conflict_mult'])]
                          for c in CRk['countries'] for r in c.get('regions') or []])
    T['drivers'] = table(['المحرك', 'ما يقيسه', 'فقد الإيرادات عند الشدة الكاملة %', 'هامش مجمل الربح (نقطة)', 'أيام تحصيل إضافية'],
                         [[f"`{d['code']}` {d['ar']}", d['about_ar'], num(d['rev_pct']), num(d['gm_pp']), num(d['dso_days'])] for d in M['shock_drivers']])
    T['macro_scenarios'] = table(['السيناريو', 'وصفه', 'الشدة: ' + ' / '.join(SH.values()), 'المخزون', 'سحب الخطوط %', 'رفع الفائدة (نقطة أساس)',
                                  'خسارة الذمم الخاصة %', 'أيام تحصيل أساسية'],
                                 [[f"`{x['code']}` {x['ar']}" + (' (أساس الصمود)' if x['resilience_base'] else ''), x['desc_ar'],
                                   ' / '.join(num(x['intensity'][k]) for k in SH), 'ركود' if x['inventory'] == 'STAGNANT' else 'أزمة',
                                   num(x['st_lines_withdrawn_pct']), num(x['rate_bp']), num(x['private_ar_loss_pct']), num(x['base_dso_days'])]
                                  for x in M['macro_scenarios']])
    T['products'] = table(['الفئة', 'الاسم', 'جودة التدفقات (1 الأفضل)', 'حساسية الطلب (0–5)', 'قيمة بيع المخزون: عادي / ركود / أزمة %',
                           'أيام البيع: عادي / ركود / أزمة', 'أيام تحصيل إضافية في الأزمة'],
                          [[f"`{p['code']}`", p['ar'], p['cash_flow_quality'], p['demand_sensitivity'],
                            f"{num(p['inventory_value_pct']['NORMAL'])} / {num(p['inventory_value_pct']['STAGNANT_MARKET'])} / {num(p['inventory_value_pct']['FINANCIAL_CRISIS'])}",
                            f"{p['days_to_sell']['NORMAL']} / {p['days_to_sell']['STAGNANT_MARKET']} / {p['days_to_sell']['FINANCIAL_CRISIS']}", p['crisis_extra_dso']]
                           for p in M['product_categories']])
    # 10. the remedies and the strengthening plans
    fund = {t['code']: t['ar'] for t in M['texts'] if t['domain'] == 'FUNDING'}
    rows = []
    for r in M['remedies']:
        steps = '؛ '.join(f"{num(s['pct'])}% من `{s['ref']}`: " + ' و'.join(f"−`{x}`" for x in s['dec']) + ('، ' if s['dec'] and s['inc'] else '')
                          + ' و'.join(f"+`{x}`" for x in s['inc']) for s in r['steps']) or ('دليل: ' + r['sets_evidence'] if r.get('sets_evidence') else 'لا خطوات (نصيحة)')
        rows.append([f"`{r['code']}` {r['ar']}", 'إجراء فعلي' if r['kind'] == 'REAL_ACTION' else 'عرض يتبع الجوهر', fund[r['funding']],
                     ', '.join(f"`{t}`" for t in r['triggers']), LEVEL[r['min_level']], steps, r['text'][0]])
    T['remedies'] = table(['الحل', 'نوعه', 'ما يحتاجه', 'تستدعيه', 'من مستوى', 'خطواته في القائمة التقديرية', 'مضمونه'], rows)
    ST = M['strengthening']
    rows = [[f"`{p['code']}` {p['ar']}", 'حزمة', ' ← '.join(f"`{m}`" for m in p['members']), p['text'][0]] for p in ST['packages']]
    rows += [[f"`{p['code']}` {p['ar']}", 'الأمثل', 'يختارها النظام خطوة خطوة' + (f"؛ يستبعد: {', '.join(fund[f] for f in p['exclude_funding'])}" if p['exclude_funding'] else ''),
              p['text'][0]] for p in ST['optimal']]
    T['plans'] = table(['الخطة', 'نوعها', 'حلولها بالترتيب', 'مضمونها'], rows)
    O = M['outlook']
    T['outlook'] = table(['القاعدة', 'الاتجاه', 'متى تتحقق'], [[f"`{r['code']}`", 'سلبية' if r['direction'] == 'NEGATIVE' else 'إيجابية', r['ar']] for r in O['rules']])
    # 11. the stress cases of the review
    import credit_stress as cs
    base, scen = cs.run_base(), cs.run_scenarios()
    rows = []
    for x in base:
        exp = x['expected'][0] if x['expected'][0] == x['expected'][1] else f"{x['expected'][0]} إلى {x['expected'][1]}"
        fac = f" (التسهيلات {x['facility']})" if x.get('expected_facility') else ''
        rows.append([f"`{x['key']}`", x['name'], x['card'], exp, f"{x['final']}{fac}", '' if x['aggregate'] is None else f"{x['aggregate']:.2f}", ', '.join(x['applied']),
                     'نعم' if x['ok'] else 'لا'])
    T['stress'] = table(['#', 'الحالة', 'البطاقة', 'توقع المراجع', 'النتيجة', 'المجموع', 'التعديلات', 'ضمن المدى'], rows)
    rows = []
    for x in scen:
        got = dict(x['results'])
        cells = [f"{got[k]} ({x['expected'][k][0]}–{x['expected'][k][1]})" if k in got else '—' for k in ['NORMAL'] + [y['code'] for y in M['macro_scenarios']]]
        acc = '؛ '.join(f"{k}: {g}" for k, g in (x['accepted'] or {}).items())
        acc = f"{acc} — {x['accepted_reason'][0]}" if acc and x.get('accepted_reason') else acc or '—'
        rows.append([f"`{x['key']}`", x['name'], f"`{x['industry']}` {x['country']}"] + cells + [x['resilience'] or '—', 'نعم' if x['ok'] else 'لا', acc])
    T['scenario_stress'] = table(['#', 'الحالة', 'النشاط والبلد', 'عادي'] + [x['ar'] for x in M['macro_scenarios']] + ['الصمود', 'ضمن المدى',
                                 'خارج المدى بقبول المراجع وسببه'], rows)
    # 12. the worked example (test CA2)
    cur = lines_from(EXAMPLE)
    prior = dict(cur); prior.update(lines_from(EXAMPLE_PRIOR))
    r = cr.assess('GENERAL_CORPORATE', cur, prior=prior, qual={'BUSINESS_PROFILE': 'Ba1', 'FINANCIAL_POLICY': 'Baa3'}, statement_age_months=4)
    tot = sum(x['eff'] for x in r['rows'] if x['score'] is not None)
    rows = []
    for x in r['rows']:
        md = metric[x['m']]
        val = 'تقدير المحلل' if x['qual'] else ('لا يُحسب' if x['st'] == 'NOT_COMPUTABLE' else ('طرف الخط' if x['v'] is None else num(round(x['v'], 2))))
        rows.append([md['ar'], val, '—' if x['score'] is None else f"{x['score']:.4f}", '—' if x['score'] is None else cr.GR[cr.notch_of(x['score']) - 1],
                     num(x['w']), f"{x['eff']:.2f}", '—' if x['score'] is None else f"{x['score'] * x['eff'] / tot:.4f}"])
    rows.append(['**المجموع الموزون**', '', f"**{r['aggregate']:.4f}**", f"**{r['indicated']}**", '100', '100', ''])
    T['example'] = table(['المقياس', 'القيمة', 'الدرجة على الخط', 'الدرجة', 'الوزن %', 'الوزن الفعلي %', 'المساهمة'], rows)
    o = r['outlook']
    applied = [a[0] for a in r['applied'] if a[0] != 'SOVEREIGN_CEILING']
    T['example_result'] = (f"المجموع المالي (المقاييس الكمية وحدها) {r['financial']:.4f} أي {r['financial_grade']}؛ والمجموع الموزون مع العاملين النوعيين "
                           f"{r['aggregate']:.4f} أي **{r['indicated']}**؛ والتعديلات التي تنطبق: {', '.join(f'`{a}`' for a in applied) or 'لا شيء'}، "
                           f"فالدرجة المنفردة {r['standalone']} والنهائية **{r['final']}** (فيتش {r['fitch']})؛ والسيولة {r['liquidity']}، واكتمال الإفصاح "
                           f"{r['completeness']:.2f}%، والنظرة {texts[('OUTLOOK_VIEW', o['outlook'])]['ar']} ({', '.join(f'`{x}`' for x in o['rules'])}).")
    T['example_remedies'] = table(['الحل', 'النتيجة التي يستدعيها', 'الدرجة التقديرية', 'درجات يكسبها'],
                                  [[f"`{x['code']}` {next(m for m in M['remedies'] if m['code'] == x['code'])['ar']}", f"`{x['trigger'][0]}` ({LEVEL.get(x['trigger'][1], 'تعديل')})",
                                    x.get('final') or 'نصيحة بلا حساب', '—' if x.get('gained') is None else x['gained']] for x in r['remedies']])
    tr = r['triggers']
    T['example_triggers'] = table(['المقياس', 'الاتجاه', 'القيمة الآن', 'القيمة التي تنقل الدرجة'],
                                  [[metric[m['metric']]['ar'], 'رفع' if m['way'] == 'UP' else 'خفض', num(round(m['current'], 2)), num(round(m['value'], 2))]
                                   for m in tr['metrics'][:12]])
    return T


if __name__ == '__main__':
    import credit_methodology
    M = credit_methodology.load()
    for k, v in doc_tables(M).items():
        print(k, len(v.splitlines()))
