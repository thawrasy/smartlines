#!/usr/bin/env python3
"""gen_credit_seed.py — writes db/seed/104_credit_scorecard.sql, and the tables of docs/35, from
tools/dbgen/credit_scorecard.json (the credit assessment methodology, version 2: docs/35, ADR 0017 and ADR 0018).

Usage: python3 tools/dbgen/gen_credit_seed.py [out.sql] [--doc | --doc-check]
  out.sql      where to write the seed (default db/seed/104_credit_scorecard.sql); CI writes it to a temporary file
               and compares, so the committed seed cannot drift from the methodology file
  --doc        also rewrites the generated tables of docs/35-credit-assessment-methodology.md between their markers
               <!-- gen:NAME --> and <!-- /gen:NAME -->
  --doc-check  changes nothing in docs/35 and exits 1 if its generated tables differ from the methodology file (CI)
The seed inserts only. The scale, the standard lines, the metrics, the activities, the product categories and the
remedies are written when missing; a scorecard is written as DRAFT with its rows and then approved, and an approved
scorecard is never changed (046 refuses it), so a change to the methodology is a new version.
"""
import json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
sys.path.insert(0, HERE)
import credit_methodology
M = credit_methodology.load(os.path.join(HERE, 'credit_scorecard.json'))
args = [a for a in sys.argv[1:] if not a.startswith('--')]
OUT = args[0] if args else os.path.join(ROOT, 'db', 'seed', '104_credit_scorecard.sql')
DOC = os.path.join(ROOT, 'docs', '35-credit-assessment-methodology.md')
EFFECTIVE = '2026-10-19'
METRIC = {m['code']: m for m in M['metrics']}
LINES = {x['code']: x for x in M['lines']}
GRADE_CODES = {g['code'] for g in M['grades']}


def q(s):
    return 'NULL' if s is None else "N'" + str(s).replace("'", "''") + "'"


def a(s):
    return 'NULL' if s is None else "'" + str(s) + "'"


def n(x):
    if x is None:
        return 'NULL'
    if isinstance(x, bool):
        return '1' if x else '0'
    return repr(x) if isinstance(x, int) else ('%.6f' % x).rstrip('0').rstrip('.')


def vals(rows):
    return ',\n'.join('    ' + r for r in rows)


def guide(g):
    """A sub-factor's grading guide as one text: each category with its description."""
    return ' | '.join(f'{k}: {v}' for k, v in g.items())


def check():
    """The methodology is consistent before anything is written."""
    for c in M['scorecards']:
        w = sum(sm['w'] for sm in c['metrics'])
        assert abs(w - 100) < 1e-9, f"{c['code']}: weights add up to {w}"
        for sm in c['metrics']:
            md = METRIC[sm['m']]
            if md['kind'] == 'QUALITATIVE':
                assert 'b' not in sm or sm['b'] is None, f"{c['code']} {sm['m']}: a qualitative metric has no grid"
                continue
            b = sm['b']
            assert len(b) == 9, f"{c['code']} {sm['m']}: nine boundaries"
            asc = all(b[i] < b[i + 1] for i in range(8))
            desc = all(b[i] > b[i + 1] for i in range(8))
            assert (asc and md['dir'] == 'LOWER_BETTER') or (desc and md['dir'] == 'HIGHER_BETTER'), \
                f"{c['code']} {sm['m']}: the grid does not run from best to worst in the metric's direction"
        for ir in c['items']:
            md, t = METRIC[ir['r']], ir['t']
            assert md['kind'] == 'QUANTITATIVE', ir
            assert ir['line'] in LINES, f"{c['code']} item {ir['r']}: unknown line {ir['line']}"
            asc = all(t[i] < t[i + 1] for i in range(3))
            desc = all(t[i] > t[i + 1] for i in range(3))
            assert (asc and md['dir'] == 'LOWER_BETTER') or (desc and md['dir'] == 'HIGHER_BETTER'), \
                f"{c['code']} item {ir['r']}: thresholds out of order"
        assert sum(1 for h in c['realisable_haircuts'].values() if not 0 <= h <= 100) == 0
    for m in M['metrics']:
        if m['kind'] == 'QUANTITATIVE' and m['pattern'] != 'VALUE':
            assert m['num'], m['code']
    for r in M['remedies']:
        for st in r['steps']:
            for x in [st['ref']] + st['dec'] + st['inc']:
                assert x in LINES, (r['code'], x)
            assert len(st['dec']) <= 3 and len(st['inc']) <= 3, r['code']
    kinds = {k['code'] for k in M['funding_kinds']}
    for r in M['remedies']:
        assert r['funding'] in kinds, (r['code'], r['funding'])
    ST = M['strengthening']
    for p in ST['packages']:
        assert p['members'] and len(set(p['members'])) == len(p['members']), p['code']
        for r in p['members']:
            assert r in {x['code'] for x in M['remedies']}, (p['code'], r)
    for p in ST['optimal']:
        assert not p['members'] and all(f in kinds for f in p['exclude_funding']), p['code']
    drivers = {d['code'] for d in M['shock_drivers']}
    cards = {c['code'] for c in M['scorecards']}
    pcats = {p['code'] for p in M['product_categories']}
    allind = M['industries']['divisions'] + M['industries']['activities']
    codes = [d['code'] for d in allind]
    assert len(codes) == len(set(codes)), 'an activity code repeats'
    divs = {d['code'] for d in M['industries']['divisions']}
    for d in allind:
        assert re.fullmatch(r'[A-Z][0-9]{2,8}', d['code']) and len(d['code']) <= 10, d['code']
        assert d['card'] in cards, (d['code'], d['card'])
        assert 1 <= d['industry_risk'] <= 6 and d['cyclicality'] in ('LOW', 'MEDIUM', 'HIGH'), d['code']
        assert set(d['sens']) == drivers and all(0 <= v <= 5 for v in d['sens'].values()), d['code']
        assert all(c in pcats for c in d['product_categories']), d['code']
        assert d.get('ceiling') is None or d['ceiling'] in GRADE_CODES, d['code']
    for x in M['industries']['activities']:
        assert x['division'] in divs and x['code'].startswith(x['division']), x['code']
    CRk = M['country_risk']
    assert len(CRk['anchor']) == 6 and all(len(r) == 6 and all(1 <= v <= 21 for v in r) for r in CRk['anchor'])
    for c in CRk['countries'] + [CRk['default']]:
        assert 1 <= c['country_risk'] <= 6 and set(c['exposure']) == drivers, c.get('iso2')
        assert c.get('sovereign_rating') is None or c['sovereign_rating'] in GRADE_CODES, c['iso2']
        for r in c.get('regions') or []:
            assert re.fullmatch(r'[A-Z0-9_]{1,10}', r['code']) and r['tier'] in ('PRIME', 'MAJOR', 'SECONDARY', 'PERIPHERAL'), (c['iso2'], r['code'])
    assert all(v in GRADE_CODES for v in CRk['unrated_ceiling'].values())
    for sc in M['macro_scenarios']:
        assert set(sc['intensity']) == drivers and all(0 <= v <= 1 for v in sc['intensity'].values()), sc['code']
    assert sum(1 for sc in M['macro_scenarios'] if sc['resilience_base']) == 1
    for g in M['grades']:
        assert g['category'] in M['category_text']


HEADER = f"""/* ============================================================================
   BankFas - 104: the credit assessment methodology of the platform, version 2.1 (docs/35-credit-assessment-methodology.md,
   ADR 0017, ADR 0018 and ADR 0019; owner requests of 2026-10-18 and 2026-10-19). GENERATED by tools/dbgen/gen_credit_seed.py
   from tools/dbgen/credit_scorecard.json: do not edit by hand.
     fin.RatingGrade          the {len(M['grades'])} grades of the Moody's long-term scale, their Fitch equivalents and their range on the continuum
     fin.StandardLine         the {len(M['lines'])} standard statement lines and the components of their totals
     fin.CreditMetric         the {len(M['metrics'])} metrics: definitions, patterns, units, directions, themes and texts
     ref.Industry             the {len(M['industries']['sections'])} sections, {len(M['industries']['divisions'])} divisions and {len(M['industries']['activities'])} activities, with their profiles
                              and their sensitivities to the {len(M['shock_drivers'])} drivers of stress
     fin.MacroScenario        the {len(M['macro_scenarios'])} macro scenarios and the intensity of each driver
     fin.CountryRiskProfile   the {len(M['country_risk']['countries'])} Arab countries and a default: country risk, sovereign rating, ceiling, exposures,
                              their {sum(len(c.get('regions') or []) for c in M['country_risk']['countries'])} regions, and the country and industry risk anchor
     fin.ProductCategory      the {len(M['product_categories'])} product categories
     fin.CreditRemedy         the {len(M['remedies'])} remedies, their triggers and steps
     fin.CreditText           the {len(M['texts'])} texts of the report
     fin.StrengtheningPlan    the {len(M['strengthening']['packages'])} ready-made plans to strengthen the statements and the {len(M['strengthening']['optimal'])} best plans
     fin.Scorecard            {len(M['scorecards'])} sector family scorecards, approved on {EFFECTIVE}, with their metrics, item rules, adjustments,
                              parameters and qualitative sub-factors
   The thresholds are this system's calibration by expert judgment on the Moody's 21-grade scale, not the grids of an
   agency; the company's treasury department validates them before a grade is used in a credit decision (docs/35).
   The sovereign ratings are published facts the platform operator verifies and keeps current.
   Insert only, so a second run changes nothing.
   ============================================================================ */
SET NOCOUNT ON;
SET ANSI_NULLS ON; SET QUOTED_IDENTIFIER ON; SET ANSI_PADDING ON; SET ANSI_WARNINGS ON; SET ARITHABORT ON; SET CONCAT_NULL_YIELDS_NULL ON; SET NUMERIC_ROUNDABORT OFF;
GO"""


def merge(table, cols, rows, key, using=None):
    """An insert-only MERGE of VALUES rows into a table, matched on key."""
    src = using or f"(VALUES\n{vals(rows)}\n) AS s ({', '.join(cols)})"
    on = ' AND '.join(f'd.{k} = s.{k}' for k in key)
    return (f"MERGE {table} AS d\nUSING {src}\n   ON {on}\nWHEN NOT MATCHED THEN\n    INSERT ({', '.join(cols)})\n"
            f"    VALUES ({', '.join('s.' + c for c in cols)});\nGO")


def seed():
    L = [HEADER]
    rows = []
    for g in M['grades']:
        ar, en = M['category_text'][g['category']]
        rows.append(f"({a(g['code'])}, {g['notch']}, {a(g['category'])}, {n(g['from'])}, {n(g['to'])}, {a(g['band'])}, {n(g['ig'])}, {a(g['fitch'])}, {q(ar)}, {q(en)})")
    L.append(merge('fin.RatingGrade', ['Code', 'NotchNo', 'Category', 'ScoreFrom', 'ScoreTo', 'RiskBand', 'IsInvestmentGrade', 'FitchEquivalent',
                                       'DescriptionAr', 'DescriptionEn'], rows, ['Code']))
    rows = []
    for i, x in enumerate(M['lines'], 1):
        rows.append(f"({a(x['code'])}, {a(x['section'])}, {a(x['kind'])}, {a(x['parent'])}, {q(x['ar'])}, {q(x['en'])}, {n(bool(x['req']))}, {a(x['formula'])}, {i * 10})")
    L.append(merge('fin.StandardLine', ['Code', 'Section', 'LineKind', 'ParentCode', 'NameAr', 'NameEn', 'IsRequired', 'TotalFormula', 'SortOrder'],
                   rows, ['Code']))
    rows = []
    for x in M['lines']:
        if x['kind'] != 'TOTAL':
            continue
        toks = x['formula'].replace('+', ' + ').replace('-', ' - ').split()
        sign = 1
        for t in toks:
            if t == '+': sign = 1
            elif t == '-': sign = -1
            else: rows.append(f"({a(x['code'])}, {a(t)}, {sign})")
    L.append(merge('fin.StandardLineTotal', ['TotalCode', 'ComponentCode', 'Sign'], rows, ['TotalCode', 'ComponentCode']))
    rows = []
    for m in M['metrics']:
        quant = m['kind'] == 'QUANTITATIVE'
        pat = m.get('pattern') if quant else None
        ratio = pat == 'RATIO'
        cash, solv = m.get('cash') or [None, None], m.get('solvency') or [None, None]
        rows.append(f"({a(m['code'])}, {q(m['ar'])}, {q(m['en'])}, {a(m['kind'])}, {a(m['unit'])}, {a(m['dir'])},\n"
                    f"     {q(m['def'])},\n     {q(m['s'][0])}, {q(m['s'][1])}, {q(m['w'][0])}, {q(m['w'][1])},\n"
                    f"     {a(pat)}, {a(m.get('num') if quant else None)}, {a(m.get('den') if quant else None)}, {n(m.get('scale') if ratio else None)}, "
                    f"{a(m.get('nz') if ratio else None)}, {a(m.get('dz') if ratio else None)}, {a(m.get('dn') if ratio else None)}, "
                    f"{a(m.get('nn') if pat in ('RATIO', 'AMOUNT') else None)}, {a(m['theme'])},\n"
                    f"     {q(cash[0])}, {q(cash[1])}, {q(solv[0])}, {q(solv[1])})")
    L.append(merge('fin.CreditMetric', ['Code', 'NameAr', 'NameEn', 'Kind', 'Unit', 'Direction', 'DefinitionAr', 'StrengthTextAr', 'StrengthTextEn',
                                        'WeaknessTextAr', 'WeaknessTextEn', 'Pattern', 'NumQty', 'DenQty', 'Scale', 'IfNumZero', 'IfDenZero',
                                        'IfDenNeg', 'IfNumNeg', 'ThemeCode', 'CashEffectAr', 'CashEffectEn', 'SolvencyEffectAr', 'SolvencyEffectEn'],
                   rows, ['Code']))
    # the Saudi classification of economic activities: sections, then divisions under them
    rows = [f"({a(s['code'])}, {a(s['code'])}, {q(s['ar'])}, {q(s['en'])})" for s in M['industries']['sections']]
    L.append(merge('ref.Industry', ['Code', 'SectionCode', 'NameAr', 'NameEn'], rows, ['Code']))
    rows = [f"({a(d['code'])}, {a(d['section'])}, {a(d['section'])}, {q(d['ar'])}, {q(d['en'])})" for d in M['industries']['divisions']]
    rows += [f"({a(d['code'])}, {a(d['section'])}, {a(d['division'])}, {q(d['ar'])}, {q(d['en'])})" for d in M['industries']['activities']]
    L.append(f"""-- the divisions under their sections, then the activities under their divisions
MERGE ref.Industry AS d
USING (SELECT v.Code, v.SectionCode, p.IndustryId AS ParentId, v.NameAr, v.NameEn
       FROM (VALUES
{vals(rows[:len(M['industries']['divisions'])])}
            ) AS v (Code, SectionCode, ParentCode, NameAr, NameEn)
       JOIN ref.Industry AS p ON p.Code = v.ParentCode) AS s
   ON d.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (Code, SectionCode, ParentId, NameAr, NameEn)
    VALUES (s.Code, s.SectionCode, s.ParentId, s.NameAr, s.NameEn);
GO
MERGE ref.Industry AS d
USING (SELECT v.Code, v.SectionCode, p.IndustryId AS ParentId, v.NameAr, v.NameEn
       FROM (VALUES
{vals(rows[len(M['industries']['divisions']):])}
            ) AS v (Code, SectionCode, ParentCode, NameAr, NameEn)
       JOIN ref.Industry AS p ON p.Code = v.ParentCode) AS s
   ON d.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (Code, SectionCode, ParentId, NameAr, NameEn)
    VALUES (s.Code, s.SectionCode, s.ParentId, s.NameAr, s.NameEn);
GO""")
    allind = M['industries']['divisions'] + M['industries']['activities']
    rows = [f"({a(d['code'])}, {a(d['card'])}, {d['industry_risk']}, {a(d['cyclicality'])}, {a(d.get('ceiling'))}, {a(','.join(d['disclosures']))}, "
            f"{a(','.join(d['product_categories']))},\n     {q(d.get('note_ar'))},\n     {q(d.get('note_en'))})" for d in allind]
    L.append(f"""MERGE fin.IndustryProfile AS d
USING (SELECT i.IndustryId, v.DefaultScorecardCode, v.IndustryRisk, v.Cyclicality, gc.RatingGradeId AS CeilingGradeId, v.ExtraDisclosures,
              v.ProductCategories, v.NoteAr, v.NoteEn
       FROM (VALUES
{vals(rows)}
            ) AS v (Code, DefaultScorecardCode, IndustryRisk, Cyclicality, Ceiling, ExtraDisclosures, ProductCategories, NoteAr, NoteEn)
       JOIN ref.Industry AS i ON i.Code = v.Code
       LEFT JOIN fin.RatingGrade AS gc ON gc.Code = v.Ceiling) AS s
   ON d.IndustryId = s.IndustryId
WHEN NOT MATCHED THEN
    INSERT (IndustryId, DefaultScorecardCode, IndustryRisk, Cyclicality, CeilingGradeId, ExtraDisclosures, ProductCategories, NoteAr, NoteEn)
    VALUES (s.IndustryId, s.DefaultScorecardCode, s.IndustryRisk, s.Cyclicality, s.CeilingGradeId, s.ExtraDisclosures, s.ProductCategories, s.NoteAr, s.NoteEn);
GO""")
    # the drivers of stress, the macro scenarios and their intensities, the sensitivities of the activities
    rows = [f"({a(d['code'])}, {q(d['ar'])}, {q(d['en'])}, {n(d['rev_pct'])}, {n(d['gm_pp'])}, {n(d['dso_days'])}, {i * 10})" for i, d in enumerate(M['shock_drivers'], 1)]
    L.append(merge('fin.ShockDriver', ['Code', 'NameAr', 'NameEn', 'RevenuePct', 'GrossMarginPp', 'DsoDays', 'SortOrder'], rows, ['Code']))
    rows = [f"({a(x['code'])}, {q(x['ar'])}, {q(x['en'])},\n     {q(x['desc_ar'])},\n     {q(x['desc_en'])}, {a(x['inventory'])}, {n(x['st_lines_withdrawn_pct'])}, "
            f"{int(x['rate_bp'])}, {n(x['private_ar_loss_pct'])}, {n(x['base_dso_days'])}, {n(bool(x['resilience_base']))}, {i * 10})" for i, x in enumerate(M['macro_scenarios'], 1)]
    L.append(merge('fin.MacroScenario', ['Code', 'NameAr', 'NameEn', 'DescriptionAr', 'DescriptionEn', 'InventorySeverity', 'StLinesWithdrawnPct', 'RateBp',
                                         'PrivateArLossPct', 'BaseDsoDays', 'IsResilienceBase', 'SortOrder'], rows, ['Code']))
    rows = [f"({a(x['code'])}, {a(d)}, {n(float(v))})" for x in M['macro_scenarios'] for d, v in x['intensity'].items()]
    L.append(f"""MERGE fin.MacroScenarioIntensity AS d
USING (SELECT ms.MacroScenarioId, sd.ShockDriverId, v.Intensity
       FROM (VALUES
{vals(rows)}
            ) AS v (ScenarioCode, DriverCode, Intensity)
       JOIN fin.MacroScenario AS ms ON ms.Code = v.ScenarioCode
       JOIN fin.ShockDriver AS sd ON sd.Code = v.DriverCode) AS s
   ON d.MacroScenarioId = s.MacroScenarioId AND d.ShockDriverId = s.ShockDriverId
WHEN NOT MATCHED THEN
    INSERT (MacroScenarioId, ShockDriverId, Intensity) VALUES (s.MacroScenarioId, s.ShockDriverId, s.Intensity);
GO""")
    rows = [f"({a(x['code'])}, {a(d)}, {int(v)})" for x in allind for d, v in x['sens'].items()]
    L.append(f"""MERGE fin.IndustrySensitivity AS d
USING (SELECT i.IndustryId, sd.ShockDriverId, v.Sensitivity
       FROM (VALUES
{vals(rows)}
            ) AS v (IndustryCode, DriverCode, Sensitivity)
       JOIN ref.Industry AS i ON i.Code = v.IndustryCode
       JOIN fin.ShockDriver AS sd ON sd.Code = v.DriverCode) AS s
   ON d.IndustryId = s.IndustryId AND d.ShockDriverId = s.ShockDriverId
WHEN NOT MATCHED THEN
    INSERT (IndustryId, ShockDriverId, Sensitivity) VALUES (s.IndustryId, s.ShockDriverId, s.Sensitivity);
GO""")
    # the countries: risk, sovereign rating and ceiling, exposures; their regions; the anchor matrix
    CRk = M['country_risk']
    EXP = ('DEMAND', 'GOV_SPENDING', 'REAL_ESTATE', 'CONFLICT', 'OIL', 'CREDIT', 'IMPORT_FX')
    def prof(c, iso):
        ceiling = c.get('sovereign_rating') or CRk['unrated_ceiling'][str(c['country_risk'])]
        ceiling = 'Ca' if ceiling == 'C' else ceiling   # the scale of a company's grade ends at Ca
        return (f"({a(iso)}, {n(iso is None)}, {c['country_risk']}, {a(c.get('sovereign_rating'))}, {a(c.get('rating_as_of'))}, {a(ceiling)}, "
                + ', '.join(n(float(c['exposure'][k])) for k in EXP) + f",\n     {q(c.get('note_ar'))},\n     {q(c.get('note_en'))})")
    rows = [prof(c, c['iso2']) for c in CRk['countries']] + [prof(CRk['default'], None)]
    L.append(f"""MERGE fin.CountryRiskProfile AS d
USING (SELECT co.CountryId, v.IsDefault, v.CountryRisk, sr.RatingGradeId AS SovereignRatingGradeId, v.RatingAsOf, ce.RatingGradeId AS CeilingGradeId,
              v.ExpDemand, v.ExpGovSpending, v.ExpRealEstate, v.ExpConflict, v.ExpOil, v.ExpCredit, v.ExpImportFx, v.NoteAr, v.NoteEn
       FROM (VALUES
{vals(rows)}
            ) AS v (Iso2, IsDefault, CountryRisk, Sovereign, RatingAsOf, Ceiling, ExpDemand, ExpGovSpending, ExpRealEstate, ExpConflict, ExpOil,
                    ExpCredit, ExpImportFx, NoteAr, NoteEn)
       LEFT JOIN ref.Country AS co ON co.Iso2 = v.Iso2
       LEFT JOIN fin.RatingGrade AS sr ON sr.Code = v.Sovereign
       JOIN fin.RatingGrade AS ce ON ce.Code = v.Ceiling
       WHERE v.Iso2 IS NULL OR co.CountryId IS NOT NULL) AS s
   ON (d.CountryId = s.CountryId) OR (d.IsDefault = 1 AND s.IsDefault = 1)
WHEN NOT MATCHED THEN
    INSERT (CountryId, IsDefault, CountryRisk, SovereignRatingGradeId, RatingAsOf, CeilingGradeId, ExpDemand, ExpGovSpending, ExpRealEstate, ExpConflict,
            ExpOil, ExpCredit, ExpImportFx, NoteAr, NoteEn)
    VALUES (s.CountryId, s.IsDefault, s.CountryRisk, s.SovereignRatingGradeId, s.RatingAsOf, s.CeilingGradeId, s.ExpDemand, s.ExpGovSpending, s.ExpRealEstate,
            s.ExpConflict, s.ExpOil, s.ExpCredit, s.ExpImportFx, s.NoteAr, s.NoteEn);
GO""")
    rows = [f"({a(c['iso2'])}, {a(r['code'])}, {q(r['ar'])}, {q(r['en'])}, {a(r['tier'])}, {n(float(r['re_mult']))}, {n(float(r['conflict_mult']))})"
            for c in CRk['countries'] for r in c.get('regions') or []]
    L.append(f"""MERGE fin.CountryRegion AS d
USING (SELECT co.CountryId, v.Code, v.NameAr, v.NameEn, v.Tier, v.RealEstateMult, v.ConflictMult
       FROM (VALUES
{vals(rows)}
            ) AS v (Iso2, Code, NameAr, NameEn, Tier, RealEstateMult, ConflictMult)
       JOIN ref.Country AS co ON co.Iso2 = v.Iso2) AS s
   ON d.CountryId = s.CountryId AND d.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (CountryId, Code, NameAr, NameEn, Tier, RealEstateMult, ConflictMult)
    VALUES (s.CountryId, s.Code, s.NameAr, s.NameEn, s.Tier, s.RealEstateMult, s.ConflictMult);
GO""")
    rows = [f"({i}, {j}, {v})" for i, r in enumerate(CRk['anchor'], 1) for j, v in enumerate(r, 1)]
    L.append(merge('fin.RiskAnchor', ['CountryRisk', 'IndustryRisk', 'AnchorNotch'], rows, ['CountryRisk', 'IndustryRisk']))
    rows = []
    for c in M['product_categories']:
        rows.append(f"({a(c['code'])}, {q(c['ar'])}, {q(c['en'])}, {c['cash_flow_quality']}, {c['demand_sensitivity']}, "
                    f"{n(c['inventory_value_pct']['NORMAL'])}, {n(c['inventory_value_pct']['STAGNANT_MARKET'])}, "
                    f"{n(c['inventory_value_pct']['FINANCIAL_CRISIS'])}, {c['days_to_sell']['NORMAL']}, {c['days_to_sell']['STAGNANT_MARKET']}, "
                    f"{c['days_to_sell']['FINANCIAL_CRISIS']}, {c['crisis_extra_dso']})")
    L.append(merge('fin.ProductCategory', ['Code', 'NameAr', 'NameEn', 'CashFlowQuality', 'DemandSensitivity', 'InvValueNormalPct',
                                           'InvValueStagnantPct', 'InvValueCrisisPct', 'DaysToSellNormal', 'DaysToSellStagnant', 'DaysToSellCrisis',
                                           'CrisisExtraDso'], rows, ['Code']))
    rows = []
    for i, r in enumerate(M['remedies'], 1):
        ev = r.get('evidence') or [None, None]
        rows.append(f"({a(r['code'])}, {a(r['kind'])}, {a(r['min_level'])}, {q(r['ar'])}, {q(r['en'])},\n     {q(r['text'][0])},\n     {q(r['text'][1])},\n"
                    f"     {q(ev[0])}, {q(ev[1])}, {a(r['funding'])}, {a(r.get('sets_evidence'))}, {i * 10})")
    L.append(merge('fin.CreditRemedy', ['Code', 'Kind', 'MinLevel', 'NameAr', 'NameEn', 'TextAr', 'TextEn', 'EvidenceAr', 'EvidenceEn', 'Funding',
                                        'SetsEvidence', 'SortOrder'], rows, ['Code']))
    rows = [f"({a(r['code'])}, {a(t)}, {i})" for r in M['remedies'] for i, t in enumerate(r['triggers'], 1)]
    L.append(f"""MERGE fin.CreditRemedyTrigger AS d
USING (SELECT r.CreditRemedyId AS RemedyId, v.TriggerCode, v.SortOrder
       FROM (VALUES
{vals(rows)}
            ) AS v (Code, TriggerCode, SortOrder)
       JOIN fin.CreditRemedy AS r ON r.Code = v.Code) AS s
   ON d.RemedyId = s.RemedyId AND d.TriggerCode = s.TriggerCode
WHEN NOT MATCHED THEN
    INSERT (RemedyId, TriggerCode, SortOrder) VALUES (s.RemedyId, s.TriggerCode, s.SortOrder);
GO""")
    rows = []
    for r in M['remedies']:
        for i, st in enumerate(r['steps'], 1):
            dec, inc = st['dec'] + [None] * 3, st['inc'] + [None] * 3
            rows.append(f"({a(r['code'])}, {i}, {a(st['ref'])}, {n(float(st['pct']))}, {a(dec[0])}, {a(dec[1])}, {a(dec[2])}, {a(inc[0])}, {a(inc[1])}, {a(inc[2])})")
    L.append(f"""MERGE fin.CreditRemedyStep AS d
USING (SELECT r.CreditRemedyId AS RemedyId, v.StepNo, v.RefLine, v.Pct, v.Dec1, v.Dec2, v.Dec3, v.Inc1, v.Inc2, v.Inc3
       FROM (VALUES
{vals(rows)}
            ) AS v (Code, StepNo, RefLine, Pct, Dec1, Dec2, Dec3, Inc1, Inc2, Inc3)
       JOIN fin.CreditRemedy AS r ON r.Code = v.Code) AS s
   ON d.RemedyId = s.RemedyId AND d.StepNo = s.StepNo
WHEN NOT MATCHED THEN
    INSERT (RemedyId, StepNo, RefLine, Pct, Dec1, Dec2, Dec3, Inc1, Inc2, Inc3)
    VALUES (s.RemedyId, s.StepNo, s.RefLine, s.Pct, s.Dec1, s.Dec2, s.Dec3, s.Inc1, s.Inc2, s.Inc3);
GO""")
    # the strengthening plans: the packages with their remedies in order, and the two best plans
    ST = M['strengthening']
    plans_ = [('PACKAGE', p) for p in ST['packages']] + [('OPTIMAL', p) for p in ST['optimal']]
    rows = [f"({a(p['code'])}, {a(k)}, {q(p['ar'])}, {q(p['en'])},\n     {q(p['text'][0])},\n     {q(p['text'][1])}, "
            f"{a(','.join(p['exclude_funding']) or None)}, {i * 10})" for i, (k, p) in enumerate(plans_, 1)]
    L.append(merge('fin.StrengtheningPlan', ['Code', 'Kind', 'NameAr', 'NameEn', 'TextAr', 'TextEn', 'ExcludeFunding', 'SortOrder'], rows, ['Code']))
    rows = [f"({a(p['code'])}, {a(r)}, {i})" for p in ST['packages'] for i, r in enumerate(p['members'], 1)]
    L.append(f"""MERGE fin.StrengtheningPlanMember AS d
USING (SELECT p.StrengtheningPlanId AS PlanId, r.CreditRemedyId AS RemedyId, v.SortOrder
       FROM (VALUES
{vals(rows)}
            ) AS v (PlanCode, RemedyCode, SortOrder)
       JOIN fin.StrengtheningPlan AS p ON p.Code = v.PlanCode
       JOIN fin.CreditRemedy AS r ON r.Code = v.RemedyCode) AS s
   ON d.PlanId = s.PlanId AND d.RemedyId = s.RemedyId
WHEN NOT MATCHED THEN
    INSERT (PlanId, RemedyId, SortOrder) VALUES (s.PlanId, s.RemedyId, s.SortOrder);
GO""")
    rows = [f"({a(x['domain'])}, {a(x['code'])}, {q(x['ar'])}, {q(x['en'])},\n     {q(x['text'][0])},\n     {q(x['text'][1])})" for x in M['texts']]
    L.append(merge('fin.CreditText', ['Domain', 'Code', 'NameAr', 'NameEn', 'TextAr', 'TextEn'], rows, ['Domain', 'Code']))
    dis_ar, dis_en = M['disclaimer']
    LQ, LG = M['liquidity'], M['lgd']
    for c in M['scorecards']:
        code, ver = a(c['code']), c['version']
        draft = f"JOIN fin.Scorecard AS sc ON sc.Code = {code} AND sc.VersionNo = {ver} AND sc.Status = 'DRAFT'"
        L.append(f"""-- {c['code']} version {ver}: {c['en']}
IF NOT EXISTS (SELECT 1 FROM fin.Scorecard WHERE Code = {code} AND VersionNo = {ver})
    INSERT fin.Scorecard (Code, VersionNo, NameAr, NameEn, SectorNoteAr, CurrencyId, AmountUnit, MinCoveragePct, QualitativeBoundNotches,
                          SupportMaxAgeMonths, Status, DisclaimerAr, DisclaimerEn)
    SELECT {code}, {ver}, {q(c['ar'])}, {q(c['en'])},
           {q(c['sector'])},
           cu.CurrencyId, {c['amount_unit']}, {n(c['min_coverage'])}, {M['qualitative_bound']}, {M['support_max_age_months']}, 'DRAFT',
           {q(dis_ar)},
           {q(dis_en)}
    FROM ref.Currency AS cu WHERE cu.Code = {a(c['currency'])};""")
        rows = []
        for i, sm in enumerate(c['metrics'], 1):
            b = sm.get('b') or [None] * 9
            rows.append(f"({a(sm['m'])}, {a(sm['f'])}, {n(float(sm['w']))}, " + ", ".join(n(x) for x in b) + f", {i})")
        L.append(f"""MERGE fin.ScorecardMetric AS d
USING (SELECT sc.ScorecardId, m.CreditMetricId, v.FactorCode, v.Weight, v.B0, v.B1, v.B2, v.B3, v.B4, v.B5, v.B6, v.B7, v.B8, v.SortOrder
       FROM (VALUES
{vals(rows)}
            ) AS v (MetricCode, FactorCode, Weight, B0, B1, B2, B3, B4, B5, B6, B7, B8, SortOrder)
       {draft}
       JOIN fin.CreditMetric AS m ON m.Code = v.MetricCode) AS s
   ON d.ScorecardId = s.ScorecardId AND d.MetricId = s.CreditMetricId
WHEN NOT MATCHED THEN
    INSERT (ScorecardId, MetricId, FactorCode, Weight, B0, B1, B2, B3, B4, B5, B6, B7, B8, SortOrder)
    VALUES (s.ScorecardId, s.CreditMetricId, s.FactorCode, s.Weight, s.B0, s.B1, s.B2, s.B3, s.B4, s.B5, s.B6, s.B7, s.B8, s.SortOrder);""")
        rows = []
        for i, ir in enumerate(c['items'], 1):
            rows.append(f"({a(ir['r'])}, {a(ir['line'])}, " + ", ".join(n(float(x)) for x in ir['t']) + f", {n(bool(ir['strength']))}, {i})")
        L.append(f"""MERGE fin.ScorecardItemRule AS d
USING (SELECT sc.ScorecardId, m.CreditMetricId, v.LineCode, v.T1, v.T2, v.T3, v.T4, v.ReportStrength, v.SortOrder
       FROM (VALUES
{vals(rows)}
            ) AS v (MetricCode, LineCode, T1, T2, T3, T4, ReportStrength, SortOrder)
       {draft}
       JOIN fin.CreditMetric AS m ON m.Code = v.MetricCode) AS s
   ON d.ScorecardId = s.ScorecardId AND d.MetricId = s.CreditMetricId AND d.LineCode = s.LineCode
WHEN NOT MATCHED THEN
    INSERT (ScorecardId, MetricId, LineCode, T1, T2, T3, T4, ReportStrength, SortOrder)
    VALUES (s.ScorecardId, s.CreditMetricId, s.LineCode, s.T1, s.T2, s.T3, s.T4, s.ReportStrength, s.SortOrder);""")
        rows = []
        for ad in [x for x in M['adjustments'] if x['r'] != 'NOTCH_FLOOR'] + c['extra_adjustments']:
            p = ad.get('card_p', {}).get(c['code'], ad.get('p'))
            rows.append(f"({a(ad['r'])}, {a(ad['stage'])}, {ad['n']}, {a(ad['cap'])}, {n(p)}, {a(ad['show'])}, {q(ad['ar'])},\n"
                        f"     {q(ad['t'][0])},\n     {q(ad['t'][1])})")
        L.append(f"""MERGE fin.ScorecardAdjustment AS d
USING (SELECT sc.ScorecardId, v.RuleCode, v.Stage, v.Notches, g.RatingGradeId AS CapGradeId, v.ParamValue, v.ShowWhen, v.NameAr, v.TextAr, v.TextEn
       FROM (VALUES
{vals(rows)}
            ) AS v (RuleCode, Stage, Notches, CapGrade, ParamValue, ShowWhen, NameAr, TextAr, TextEn)
       {draft}
       LEFT JOIN fin.RatingGrade AS g ON g.Code = v.CapGrade) AS s
   ON d.ScorecardId = s.ScorecardId AND d.RuleCode = s.RuleCode
WHEN NOT MATCHED THEN
    INSERT (ScorecardId, RuleCode, Stage, Notches, CapGradeId, ParamValue, ShowWhen, IsActive, NameAr, TextAr, TextEn)
    VALUES (s.ScorecardId, s.RuleCode, s.Stage, s.Notches, s.CapGradeId, s.ParamValue, s.ShowWhen, 1, s.NameAr, s.TextAr, s.TextEn);""")
        prm = [('CARD', k, v, None) for k, v in sorted(c['params'].items())]
        prm += [('CARD', 'NOTCH_FLOOR', M['notch_floor'], None), ('CARD', 'SUBFACTOR_MINIMUM', M['subfactor_minimum'], None),
                ('CARD', 'HIDDEN_DEBT_PCT', M['bureau']['hidden_debt_pct'], None), ('CARD', 'BUREAU_MAX_AGE_MONTHS', M['bureau']['max_age_months'], None),
                ('CARD', 'LGD_MAX_UP', LG['max_up'], None), ('CARD', 'LGD_MAX_UP_NEAR_DEFAULT', LG['max_up_near_default'], None),
                ('CARD', 'LGD_BEST_FACILITY_NOTCH', next(g['notch'] for g in M['grades'] if g['code'] == LG['best_facility_grade']), None),
                ('SGL', 'SGL1', LQ['sgl'][0], None), ('SGL', 'SGL2', LQ['sgl'][1], None), ('SGL', 'SGL3', LQ['sgl'][2], None),
                ('SGL', 'SEVERE', LQ['severe_below'], None),
                ('CARD', 'PLAN_MAX_STEPS', ST['max_steps'], None), ('CARD', 'PLAN_MIN_GAIN', ST['min_gain_score'], None),
                ('CARD', 'OUTLOOK_HEADROOM_PCT', M['outlook']['headroom_pct'], None),
                ('CARD', 'OUTLOOK_STAGNANT_LOSS', M['outlook']['stagnant_loss_negative'], None),
                ('SCENARIO', 'MAX_REVENUE_FALL_PCT', M['scenario_rules']['max_revenue_fall_pct'], None),
                ('SCENARIO', 'ST_LINES_MAX_PCT', M['scenario_rules']['st_lines_max_pct'], None),
                ('SCENARIO', 'PRIVATE_AR_LOSS_DEMAND_FACTOR', M['scenario_rules']['private_ar_loss_demand_factor'], None),
                ('SCENARIO', 'CREDIT_SENSITIVITY_REFERENCE', M['scenario_rules']['credit_sensitivity_reference'], None),
                ('SCENARIO', 'REFERENCE_GROSS_MARGIN_PCT', M['scenario_rules']['reference_gross_margin_pct'], None),
                ('SCENARIO', 'GROSS_MARGIN_SCALE_MAX', M['scenario_rules']['gross_margin_scale_max'], None),
                ('SCENARIO', 'INVESTMENT_PROPERTY_FALL_PCT', M['scenario_rules']['investment_property_fall_pct'], None),
                ('SCENARIO', 'INVESTMENT_PROPERTY_FALL_MAX_PCT', M['scenario_rules']['investment_property_fall_max_pct'], None)]
        prm += [('REALISABLE_HAIRCUT', k, v, None) for k, v in sorted(c['realisable_haircuts'].items())]
        prm += [('COLLATERAL_HAIRCUT', k, v, None) for k, v in sorted(LG['collateral_haircuts'].items())]
        prm += [('LGD_BAND', b['code'], b['max_lgd_pct'], b['notches']) for b in LG['bands']]
        prm += [('FIXED_COST', k, v, None) for k, v in sorted(c['fixed_cost_rule'].items())]
        for i, u in enumerate(LG['guarantor_uplift'], 1):
            prm += [('CARD', f'GUARANTOR{i}_COVERAGE', u['min_coverage'], u['notches']), ('CARD', f'GUARANTOR{i}_LEVERAGE', u['max_guarantor_leverage_pct'], None)]
        rows = [f"({a(g)}, {a(k)}, {n(float(v))}, {n(None if v2 is None else float(v2))})" for g, k, v, v2 in prm]
        L.append(f"""MERGE fin.ScorecardParameter AS d
USING (SELECT sc.ScorecardId, v.GroupCode, v.ParamKey, v.Value, v.Value2
       FROM (VALUES
{vals(rows)}
            ) AS v (GroupCode, ParamKey, Value, Value2)
       {draft}) AS s
   ON d.ScorecardId = s.ScorecardId AND d.GroupCode = s.GroupCode AND d.ParamKey = s.ParamKey
WHEN NOT MATCHED THEN
    INSERT (ScorecardId, GroupCode, ParamKey, Value, Value2) VALUES (s.ScorecardId, s.GroupCode, s.ParamKey, s.Value, s.Value2);""")
        rows = []
        for f, subs in c['qualitative'].items():
            for i, sb in enumerate(subs, 1):
                rows.append(f"({a(f)}, {a(sb['code'])}, {q(sb['ar'])}, {q(sb['en'])},\n     {q(guide(sb['guide_ar']))}, {i})")
        L.append(f"""MERGE fin.ScorecardSubfactor AS d
USING (SELECT sc.ScorecardId, m.CreditMetricId AS MetricId, v.Code, v.NameAr, v.NameEn, v.GuideAr, v.SortOrder
       FROM (VALUES
{vals(rows)}
            ) AS v (MetricCode, Code, NameAr, NameEn, GuideAr, SortOrder)
       {draft}
       JOIN fin.CreditMetric AS m ON m.Code = v.MetricCode) AS s
   ON d.ScorecardId = s.ScorecardId AND d.MetricId = s.MetricId AND d.Code = s.Code
WHEN NOT MATCHED THEN
    INSERT (ScorecardId, MetricId, Code, NameAr, NameEn, GuideAr, SortOrder) VALUES (s.ScorecardId, s.MetricId, s.Code, s.NameAr, s.NameEn, s.GuideAr, s.SortOrder);
UPDATE fin.Scorecard SET Status = 'APPROVED', EffectiveFrom = '{EFFECTIVE}'
WHERE Code = {code} AND VersionNo = {ver} AND Status = 'DRAFT';
GO""")
    return "\n".join(L) + "\n"


def render_doc(s):
    import credit_doc
    for name, body in credit_doc.doc_tables(M).items():
        pat = re.compile(r'(<!-- gen:%s -->\n).*?(<!-- /gen:%s -->)' % (re.escape(name), re.escape(name)), re.S)
        if not pat.search(s):
            raise SystemExit(f'docs/35 has no markers for {name}')
        s = pat.sub(lambda m: m.group(1) + body + '\n' + m.group(2), s)
    return s


if __name__ == '__main__':
    sys.path.insert(0, HERE)
    check()
    open(OUT, 'w', encoding='utf-8').write(seed())
    print(f"wrote {OUT}: {len(M['grades'])} grades, {len(M['lines'])} lines, {len(M['metrics'])} metrics, {len(M['scorecards'])} scorecards")
    if '--doc' in sys.argv or '--doc-check' in sys.argv:
        current = open(DOC, encoding='utf-8').read()
        if '--doc' in sys.argv:
            open(DOC, 'w', encoding='utf-8').write(render_doc(current))
            print(f'updated the generated tables of {DOC}')
        elif render_doc(current) != current:
            print('docs/35 is stale: run tools/dbgen/gen_credit_seed.py --doc and commit the result')
            sys.exit(1)
