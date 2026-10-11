#!/usr/bin/env python3
"""erd_build_en.py — renders every English ERD chart and writes the manifest the Word builder reads.

Usage: python3 tools/dbgen/erd_build_en.py <manifest.json>
Sources: db/model/*.model (purpose, flags) and db/generated/tsql (keys, nullability, counts). Every count is
checked against the generated DDL before anything is written; a routing problem stops the build.
Output: docs/diagrams/erd-en/<chart>.png
"""
import glob, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen, ddl_keys, erd_layout as L, erd_plan as P

ROOT = os.path.join(HERE, '..', '..')
OUT = os.path.join(ROOT, 'docs', 'diagrams', 'erd-en')
DATE = '2026-10-11'

SCHEMA_TEXT = {
    'plat': 'Platform: tenants, plans, modules, support access, platform operators',
    'sec': 'Security: users, roles, permissions, sessions, encryption keys, login attempts',
    'org': 'Organisation: companies, departments, shareholding, governance, KYC profiles',
    'aud': 'Audit trail',
    'doc': 'Document store',
    'cfg': 'Configuration and background jobs',
    'pty': 'Parties: the shared person and legal-entity model',
    'ins': 'Financial institutions',
    'acc': 'Bank accounts and signatories',
    'cat': 'Catalogues: products, fees, financing, limits, collateral types, lookups',
    'ref': 'Shared global reference data (read-only)',
    'fac': 'Facilities, limits and utilisation',
    'prc': 'Pricing and tariffs',
    'cmp': 'Comparable terms library',
    'col': 'Collateral and guarantees',
    'obl': 'Obligations, covenants and reporting',
    'fin': 'Financial statements and balances',
    'wfl': 'Workflow engine and requests',
    'ntf': 'Notifications',
    'lc': 'Letters of credit and proforma invoices',
}


def purpose(t):
    return ' '.join((t.comment or '').split()).split(' -- ')[0].strip()


def legend_chart():
    """A small sample that shows every symbol used in the charts (synthetic rows, not model tables)."""
    nodes = [
        {'fq': 'org.Company', 'own': True, 'hidden': 26,
         'rows': [{'name': 'CompanyId', 'type': 'bigint', 'not_null': True, 'key': 'PK'}]},
        {'fq': 'org.CompanyBranch', 'own': True, 'hidden': 4,
         'rows': [{'name': 'BranchId', 'type': 'bigint', 'not_null': True, 'key': 'PK'},
                  {'name': 'CompanyId', 'type': 'bigint', 'not_null': True, 'key': 'FK'}]},
        {'fq': 'ref.Country', 'own': False, 'hidden': 3,
         'rows': [{'name': 'CountryCode', 'type': 'char(2)', 'not_null': True, 'key': 'PK'}]},
        {'fq': 'org.CompanyProfile', 'own': True, 'hidden': 5,
         'rows': [{'name': 'ProfileId', 'type': 'bigint', 'not_null': True, 'key': 'PK'},
                  {'name': 'CountryCode', 'type': 'char(2)', 'not_null': False, 'key': 'FK'}]},
    ]
    edges = [
        {'child': 'org.CompanyBranch', 'parent': 'org.Company', 'ccol': 'CompanyId', 'pcol': 'CompanyId',
         'mandatory': True, 'columns': ['CompanyId']},
        {'child': 'org.CompanyProfile', 'parent': 'ref.Country', 'ccol': 'CountryCode', 'pcol': 'CountryCode',
         'mandatory': False, 'columns': ['CountryCode']},
    ]
    return {'key': 'legend', 'nodes': nodes, 'edges': edges}


def check_counts(tables):
    ddl = ddl_keys.totals()
    owners = ddl_keys.owner_tables()
    model_fk = sum(1 for t in tables.values() for c in t.cols if c.fk and not (c.name == 'TenantId' and c.fk == 'plat.Tenant'))
    if len(tables) != ddl['tables']:
        raise SystemExit(f'table count: model={len(tables)} DDL={ddl["tables"]}')
    if len(owners) + model_fk != ddl['fk_total']:
        raise SystemExit(f'FK count: owners={len(owners)} model={model_fk} DDL={ddl["fk_total"]}')
    return ddl, owners, model_fk


def index_count():
    text = open(os.path.join(ROOT, 'db', 'generated', 'tsql', '003_indexes.sql'), encoding='utf-8').read()
    return len(re.findall(r'^CREATE (?:UNIQUE )?(?:CLUSTERED |NONCLUSTERED )?INDEX ', text, re.M))


MAX_W, MAX_H, MAX_COLS = 1100.0, 640.0, 4     # A3 landscape at 1:1 leaves about 1100 x 640 pt for a chart


def fit_charts(raw, probe):
    """Split any chart that would not fit an A3 landscape page at natural size, then number the parts."""
    from collections import Counter

    def fit(members, allowed=None):
        m = L.render(L.build_chart('probe', members, allowed), probe)
        if m['problems']:
            raise SystemExit(f'routing problem in probe chart: {m["problems"][:2]}')
        if m['w_pt'] <= MAX_W and m['columns'] <= MAX_COLS and (m['h_pt'] <= MAX_H or len(members) == 1 and allowed is None and not refs_of(members[0])):
            return [(members, allowed)]
        if len(members) > 1:
            half = (len(members) + 1) // 2
            return fit(members[:half], allowed) + fit(members[half:], allowed)
        # one table with too many parents: split its parent boxes between two charts, so each parent is drawn once
        refs = refs_of(members[0])
        if allowed is not None:
            refs = [r for r in refs if r in allowed]
        if len(refs) < 2:
            raise SystemExit(f'cannot fit {members[0]}')
        half = (len(refs) + 1) // 2
        self_here = allowed is None or members[0] in allowed     # a self-reference is drawn in exactly one part
        first = set(refs[:half]) | ({members[0]} if self_here else set())
        return fit(members, first) + fit(members, set(refs[half:]))

    def refs_of(fq):
        return sorted({f['parent'] for f in ddl_keys.foreign_keys()
                       if f['child'] == fq and not L.is_owner_fk(f) and not L.is_provenance_fk(f) and f['parent'] != fq})

    fitted = []
    for c in raw:
        for chunk, allowed in fit(c['members']):
            fitted.append({**c, 'members': chunk, 'allowed': allowed})
    if os.path.exists(probe):
        os.remove(probe)
    counts = Counter(c['group'] for c in fitted)
    seen = Counter()
    out = []
    for c in fitted:
        seen[c['group']] += 1
        n = seen[c['group']]
        key = c['group'] if counts[c['group']] == 1 else f"{c['group']}_{n}"
        out.append({**c, 'key': key, 'part': n, 'parts': counts[c['group']]})
    return out


def main(manifest_path):
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs:
        raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    ddl, owners, model_fk = check_counts(tables)
    os.makedirs(OUT, exist_ok=True)

    # every chart is rendered first; any routing problem stops the build
    charts = fit_charts(P.plan(tables), os.path.join(OUT, '_probe.png'))
    fk_by_child = {}
    for f in ddl_keys.foreign_keys():
        fk_by_child.setdefault(f['child'], []).append(f)
    bad = []
    legend = legend_chart()
    legend_metrics = L.render(legend, os.path.join(OUT, 'legend.png'))
    if legend_metrics['problems']:
        bad.append(('legend', legend_metrics['problems']))
    out_charts = []
    prov_done, seen_before = set(), set()
    for c in charts:
        chart = L.build_chart(c['key'], c['members'], c['allowed'])
        m = L.render(chart, os.path.join(OUT, c['key'] + '.png'))
        if m['problems']:
            bad.append((c['key'], m['problems']))
        refs = sorted({n['fq'] for n in chart['nodes'] if not n['own']})
        in_chart = {n['fq'] for n in chart['nodes']}
        relations = []
        for f in fk_by_child_members(c['members'], fk_by_child):
            if L.is_owner_fk(f):
                continue
            drawn_here = any(e['child'] == f['child'] and e['parent'] == f['parent']
                             and e['columns'] == L.non_tenant(f['cols']) for e in chart['edges'])
            if not L.is_provenance_fk(f) and not drawn_here:
                continue                    # drawn in another part of the same table
            if L.is_provenance_fk(f) and f['child'] in prov_done:
                continue                    # traceability links are listed once, with the first chart of the table
            nt_child = L.non_tenant(f['cols'])
            nt_parent = L.non_tenant(f['pcols'])
            required = all(next(nn for n, _, nn in ddl_keys.columns(f['child']) if n == col) for col in nt_child)
            prov = L.is_provenance_fk(f)
            relations.append({
                'child': f['child'], 'columns': ', '.join(nt_child),
                'parent': f['parent'], 'parent_columns': ', '.join(nt_parent),
                'required': required, 'cascade': f['cascade'],
                'kind': 'Traceability' if prov else 'Business',
                'drawn': not prov,
            })
        continued = set(c['members']) & seen_before
        seen_before.update(c['members'])
        prov_done.update(c['members'])
        out_charts.append({
            'key': c['key'], 'module': c['module'], 'title': c['title'], 'subtitle': c['subtitle'],
            'part': c['part'], 'parts': c['parts'], 'png': f'diagrams/erd-en/{c["key"]}.png',
            'w_pt': m['w_pt'], 'h_pt': m['h_pt'], 'columns': m['columns'], 'over_top': m['over_top'],
            'members': [{'fq': fq, 'schema': tables[fq].schema, 'name': tables[fq].name,
                         'continued': fq in continued, 'purpose': purpose(tables[fq]),
                         'pk': ', '.join(ddl_keys.pk_cols(fq)),
                         'uq': ddl_keys.unique_count(fq),
                         'fk': sum(1 for f in fk_by_child.get(fq, []) if not L.is_owner_fk(f)),
                         'drawn_fk': sum(1 for f in fk_by_child.get(fq, []) if not L.is_owner_fk(f) and not L.is_provenance_fk(f))}
                        for fq in c['members']],
            'refs': refs,
            'relations': relations,
        })
    if bad:
        for name, probs in bad:
            print('PROBLEM', name, probs[:3], file=sys.stderr)
        raise SystemExit('routing problems; nothing written')

    # every drawn relation must be listed exactly once in the charts
    drawn_rel = sum(1 for ch in out_charts for r in ch['relations'] if r['drawn'])
    model_drawn = sum(1 for f in ddl_keys.foreign_keys() if not L.is_owner_fk(f) and not L.is_provenance_fk(f))
    if drawn_rel != model_drawn:
        import collections
        seen_keys = collections.Counter((ch['key'], r['child'], r['columns'], r['parent'])
                                        for ch in out_charts for r in ch['relations'] if r['drawn'])
        dups = [k for k, v in seen_keys.items() if v > 1]
        where = collections.Counter((r['child'], r['columns'], r['parent']) for ch in out_charts for r in ch['relations'] if r['drawn'])
        extra = [k for k, v in where.items() if v > 1]
        raise SystemExit(f'drawn relations {drawn_rel} != DDL drawn relations {model_drawn}; repeated={extra[:4]} in={dups[:4]}')
    prov_rel = sum(1 for ch in out_charts for r in ch['relations'] if not r['drawn'])

    unique_module = {}
    for ch in out_charts:
        for m in ch['members']:
            unique_module.setdefault(m['fq'], ch['module'])
    modules = []
    for _, label in P.MODULES:
        cs = [ch for ch in out_charts if ch['module'] == label]
        modules.append({'label': label, 'charts': len(cs),
                        'tables': sum(1 for v in unique_module.values() if v == label)})
    if sum(m['tables'] for m in modules) != ddl['tables']:
        raise SystemExit('module table totals do not match the DDL')

    schemas = {}
    for t in tables.values():
        s = schemas.setdefault(t.schema, {'schema': t.schema, 'tables': 0, 'owned': 0})
        s['tables'] += 1
        s['owned'] += 1 if t.fq in owners else 0
    schema_rows = []
    for s in sorted(schemas):
        schema_rows.append({**schemas[s], 'text': SCHEMA_TEXT[s]})
    if set(SCHEMA_TEXT) != set(schemas):
        raise SystemExit(f'schema descriptions missing or extra: {set(schemas) ^ set(SCHEMA_TEXT)}')
    pairs = {}
    for t in tables.values():
        for c in t.cols:
            if c.fk and c.fk.split('.')[0] != t.schema and not (c.name == 'TenantId' and c.fk == 'plat.Tenant'):
                k = (t.schema, c.fk.split('.')[0])
                pairs[k] = pairs.get(k, 0) + 1
    pair_rows = [{'child': a, 'parent': b, 'count': n} for (a, b), n in sorted(pairs.items())]

    chart_of = {fq: ch['key'] for ch in out_charts for fq in (m['fq'] for m in ch['members'])}
    index = [{'fq': fq, 'schema': tables[fq].schema, 'purpose': purpose(tables[fq]), 'chart': chart_of[fq]}
             for fq in sorted(tables)]

    out = {
        'meta': {
            'date': DATE, 'tables': ddl['tables'], 'schemas': len(schemas), 'indexes': index_count(),
            'fk_total': ddl['fk_total'], 'fk_owner': len(owners), 'fk_model': model_fk,
            'fk_drawn': model_drawn, 'fk_traceability': prov_rel,
            'fk_generated': sum(1 for t in tables.values() for c in t.cols if c.fk and c.auto and not (c.name == 'TenantId' and c.fk == 'plat.Tenant')),
            'unique_total': ddl['unique_total'], 'charts': len(out_charts) + 1, 'max_members': P.MAX_MEMBERS,
            'legend_w_pt': legend_metrics['w_pt'], 'legend_h_pt': legend_metrics['h_pt'],
        },
        'legend': {'png': 'diagrams/erd-en/legend.png', 'w_pt': legend_metrics['w_pt'], 'h_pt': legend_metrics['h_pt']},
        'modules': modules, 'charts': out_charts, 'schemas': schema_rows, 'pairs': pair_rows, 'index': index,
    }
    with open(manifest_path, 'w', encoding='utf-8') as fh:
        json.dump(out, fh, ensure_ascii=False, indent=1)
    widest = max(out_charts, key=lambda ch: ch['w_pt'])
    tallest = max(out_charts, key=lambda ch: ch['h_pt'])
    print(json.dumps({'charts': len(out_charts), 'drawn_relations': model_drawn, 'traceability_listed': prov_rel,
                      'widest': [widest['key'], widest['w_pt']], 'tallest': [tallest['key'], tallest['h_pt']],
                      'over_top_routes': sum(ch['over_top'] for ch in out_charts)}))


def fk_by_child_members(members, fk_by_child):
    for fq in members:
        for f in fk_by_child.get(fq, []):
            yield f


if __name__ == '__main__':
    main(sys.argv[1])
