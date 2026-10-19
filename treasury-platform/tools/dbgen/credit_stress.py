#!/usr/bin/env python3
"""credit_stress.py — the stress cases of the independent credit review (docs/35 section 16), run through the
methodology of tools/dbgen/credit_scorecard.json with credit_reference.py, beside the grade range the reviewer
expects for each (a separate AI agent in the role of a senior credit analyst, not a human review). The base cases
check the obligor grade (and the facility grade where given) and that the remedies the reviewer expects are
proposed; the scenario cases check the grade in normal conditions, in a stagnant market and in a financial crisis.
It prints one row per case and exits 1 if a case falls outside its range or an expected remedy is missing; a scenario
result the reviewer accepted outside its range (accepted_outside, with its reason) must stay exactly as accepted.

Usage: python3 tools/dbgen/credit_stress.py [--markdown]
The cases are written in SAR millions and computed in SAR.
"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import credit_reference as cr


def in_range(grade, rng):
    return grade is not None and cr.N[rng[0]] <= cr.N[grade] <= cr.N[rng[1]]


def run_base():
    out = []
    for c in cr.M['stress']:
        kw, lines = cr.case_args(c, 1e6)
        r = cr.assess(c['card'], lines, **kw)
        ok = in_range(r.get('final'), c['expected'])
        fac = (r.get('facility') or {}).get('grade')
        if c.get('expected_facility'):
            ok = ok and in_range(fac, c['expected_facility'])
        proposed = {x['code'] for x in r.get('remedies', [])}
        miss = [x for x in c.get('remedies_expected', []) if x not in proposed]
        out.append(dict(key=c['key'], name=c['name_ar'], card=c['card'], expected=c['expected'], final=r.get('final', r['state']),
                        aggregate=r.get('aggregate'), facility=fac, expected_facility=c.get('expected_facility'),
                        applied=[a[0] for a in r.get('applied', []) if a[0] != 'SOVEREIGN_CEILING'], missing_remedies=miss,
                        ok=ok and not miss))
    return out


def run_scenarios():
    out = []
    for c in cr.M['scenario_stress']:
        kw, lines = cr.case_args(c, 1e6)
        r = cr.assess(c['card'], lines, **kw, with_remedies=False)
        e = c['expected']
        res = [('NORMAL', r.get('final')), ('STAGNANT_MARKET', r['scenarios']['STAGNANT_MARKET']['final']),
               ('FINANCIAL_CRISIS', r['scenarios']['FINANCIAL_CRISIS']['final'])]
        acc = c.get('accepted_outside') or {}
        ok = all(in_range(g, e[k]) or acc.get(k) == g for k, g in res)
        out.append(dict(key=c['key'], name=c['name_ar'], card=c['card'], industry=c['industry'], results=res, expected=e,
                        resilience=r.get('resilience'), ok=ok))
    return out


def main():
    base, scen = run_base(), run_scenarios()
    bad = sum(1 for x in base + scen if not x['ok'])
    if '--markdown' in sys.argv:
        print('| # | الحالة | البطاقة | توقع المراجع | النتيجة | المجموع | التعديلات | ضمن المدى |')
        print('|---|---|---|---|---|---|---|---|')
        for x in base:
            exp = x['expected'][0] if x['expected'][0] == x['expected'][1] else f"{x['expected'][0]} إلى {x['expected'][1]}"
            agg = '' if x['aggregate'] is None else f"{x['aggregate']:.2f}"
            fac = f" (التسهيلات {x['facility']})" if x.get('expected_facility') else ''
            print(f"| {x['key']} | {x['name']} | {x['card']} | {exp} | {x['final']}{fac} | {agg} | {', '.join(x['applied'])} | {'نعم' if x['ok'] else 'لا'} |")
        print()
        print('| # | الحالة | النشاط | عادي | ركود السوق | أزمة مالية | الصمود | ضمن المدى |')
        print('|---|---|---|---|---|---|---|---|')
        for x in scen:
            cells = [f"{g} ({x['expected'][k][0]}–{x['expected'][k][1]})" for k, g in x['results']]
            print(f"| {x['key']} | {x['name']} | {x['industry']} | " + ' | '.join(cells) + f" | {x['resilience'] or ''} | {'نعم' if x['ok'] else 'لا'} |")
    else:
        for x in base:
            print(f"{x['key']:34s} {x['final']:5s} expected {x['expected'][0]}-{x['expected'][1]}"
                  + (f" facility {x['facility']} expected {x['expected_facility'][0]}-{x['expected_facility'][1]}" if x.get('expected_facility') else '')
                  + ('' if not x['missing_remedies'] else f" missing remedies {x['missing_remedies']}") + ('' if x['ok'] else '  OUT'))
        for x in scen:
            print(f"{x['key']:34s} " + ' '.join(f"{k} {g}" for k, g in x['results']) + ('' if x['ok'] else '  OUT'))
        total = len(base) + len(scen)
        print(f'{total - bad} of {total} cases within the reviewer\'s range')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
