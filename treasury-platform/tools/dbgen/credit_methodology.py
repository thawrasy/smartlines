#!/usr/bin/env python3
"""credit_methodology.py — reads tools/dbgen/credit_scorecard.json for every tool that uses it (the seed, the
reference, the documentation and the engine cases), and expands it:

- a scorecard with a `base` takes the item rules, parameters, realisable haircuts, fixed cost rule, qualitative
  guides, extra adjustments, currency, unit and minimum coverage of its base card, unless it gives its own (the
  qualitative guides factor by factor); it always gives its own metrics and version (ADR 0019);
- a division without its own sensitivities takes the median of the activities whose code starts with its own.

CREDIT_METHODOLOGY in the environment points to another file (the tests of the reference use it).
"""
import copy, json, os, statistics

HERE = os.path.dirname(os.path.abspath(__file__))
INHERITED = ('params', 'realisable_haircuts', 'fixed_cost_rule', 'qualitative', 'items', 'extra_adjustments',
             'currency', 'amount_unit', 'min_coverage')
DRIVERS = ('DEMAND', 'GOV_SPENDING', 'REAL_ESTATE', 'CONFLICT', 'OIL', 'CREDIT', 'IMPORT_FX')


def expand(M):
    M = copy.deepcopy(M)
    cards = {c['code']: c for c in M['scorecards']}
    for c in M['scorecards']:
        b = c.get('base')
        if not b:
            continue
        base = cards[b]
        if base.get('base'):
            raise ValueError(f'{c["code"]}: its base {b} has a base itself')
        for k in INHERITED:
            if k not in c:
                c[k] = copy.deepcopy(base[k])
            elif k == 'qualitative':
                # a card gives its own sector sub-factors for a factor; the factors it does not give come from its base
                c[k] = {f: copy.deepcopy(c[k].get(f, base[k][f])) for f in base[k]}
    ind = M['industries']
    acts = ind.get('activities', [])
    for d in ind['divisions']:
        mine = [a for a in acts if a['division'].startswith(d['code'])]
        if 'sens' not in d:
            if not mine:
                raise ValueError(f'division {d["code"]} has neither sensitivities nor activities')
            d['sens'] = {k: int(statistics.median_low([a['sens'][k] for a in mine])) for k in DRIVERS}
        if 'industry_risk' not in d:
            d['industry_risk'] = int(statistics.median_low([a['industry_risk'] for a in mine]))
    return M


def load(path=None):
    path = path or os.environ.get('CREDIT_METHODOLOGY') or os.path.join(HERE, 'credit_scorecard.json')
    return expand(json.load(open(path, encoding='utf-8')))
