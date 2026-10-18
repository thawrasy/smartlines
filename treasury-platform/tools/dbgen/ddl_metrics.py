#!/usr/bin/env python3
"""ddl_metrics.py — prints the numbers the design documents quote, read from the model and the generated DDL, so that
a document is corrected from one place instead of by hand (self-review D1).

Usage: python3 tools/dbgen/ddl_metrics.py [--json]
"""
import glob, json, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, '..', '..')
G = os.path.join(ROOT, 'db', 'generated', 'tsql')
sys.path.insert(0, HERE)
import ddl_keys  # noqa: E402

read = lambda p: open(p, encoding='utf-8').read()


def model_tables():
    """(schema.table, flags) for every table of the model."""
    out = []
    for f in sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))):
        for line in read(f).splitlines():
            m = re.match(r'^table\s+(\w+\.\w+)\s*([^#]*)', line)
            if m:
                out.append((m.group(1), m.group(2).split()))
    return out


def model_columns():
    import subprocess
    out = subprocess.run([sys.executable, os.path.join(HERE, 'dbgen.py'), 'check'] + sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))),
                         capture_output=True, text=True).stdout
    m = re.search(r'columns:\s*(\d+)', out)
    return int(m.group(1)) if m else -1


def metrics():
    t1, t2, t3, t4 = (read(os.path.join(G, n)) for n in ('001_tables.sql', '002_foreign_keys.sql', '003_indexes.sql', '004_rls_tables.sql'))
    t6, t7 = read(os.path.join(G, '006_sensitive_columns.sql')), read(os.path.join(G, '007_table_grants.sql'))
    blocks = re.findall(r'CREATE TABLE \[(\w+)\]\.\[(\w+)\] \((.*?)\n\);', t1, re.S)
    cols = sum(len(re.findall(r'^\s{4}\[\w+\] ', b, re.M)) for _, _, b in blocks)
    fks = re.findall(r'FOREIGN KEY \(([^)]*)\) REFERENCES \[(\w+)\]\.\[(\w+)\] \(([^)]*)\)', t2)
    to_tenant = sum(1 for c, s, t, r in fks if (s, t) == ('plat', 'Tenant'))
    composite = sum(1 for c, s, t, r in fks if (s, t) != ('plat', 'Tenant') and c.startswith('[TenantId]'))
    idx_lines = re.findall(r'^CREATE (?:UNIQUE )?(?:CLUSTERED |NONCLUSTERED )?INDEX .*$', t3, re.M)
    flags = model_tables()
    totals = ddl_keys.totals()
    return {
        'tables': len(blocks),
        'schemas': len({s for s, _, _ in blocks}),
        'columns in the DDL (with the added key, tenant, audit and version columns)': cols,
        'columns in the model (dbgen check)': model_columns(),
        'foreign keys': totals['fk_total'],
        'foreign keys to plat.Tenant': to_tenant,
        'foreign keys composite on TenantId': composite,
        'foreign keys other': totals['fk_total'] - to_tenant - composite,
        'unique constraints and unique indexes': totals['unique_total'],
        'check constraints': len(re.findall(r'CHECK \(', t1)),
        'indexes (nonclustered)': len(idx_lines),
        'indexes filtered': sum(1 for l in idx_lines if ' WHERE ' in l),
        'indexes with INCLUDE': sum(1 for l in idx_lines if ' INCLUDE ' in l),
        'tables with PublicId': len(re.findall(r'^\s{4}\[PublicId\] ', t1, re.M)),
        'tables with RowVersion': len(re.findall(r'^\s{4}\[RowVersion\] ', t1, re.M)),
        'tables under row-level security': len(re.findall(r'^INSERT #rls_tables ', t4, re.M)),
        'restricted columns (denied to tp_readonly)': len(re.findall(r'^DENY SELECT ON ', t6, re.M)),
        'tables noapp': sum(1 for _, f in flags if 'noapp' in f),
        'tables with INT key': sum(1 for _, f in flags if 'int' in f),
        'tables deletable by tp_app': sum(1 for _, f in flags if 'deletable' in f),
        'tables global': sum(1 for _, f in flags if 'global' in f),
        'tables mixed (global and tenant rows)': sum(1 for _, f in flags if 'mixed' in f),
        'tables revisioned': sum(1 for _, f in flags if 'rev' in f),
        'tables source-stamped': sum(1 for _, f in flags if 'src' in f),
        'cascading foreign keys': len(re.findall(r'ON DELETE CASCADE', t2)),
        'table grants in 007': len(re.findall(r'^(?:GRANT|DENY) ', t7, re.M)),
    }


if __name__ == '__main__':
    m = metrics()
    if '--json' in sys.argv:
        print(json.dumps(m, ensure_ascii=False, indent=1))
    else:
        for k, v in m.items():
            print(f'{k:80s} {v:6d}')
