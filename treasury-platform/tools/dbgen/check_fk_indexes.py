#!/usr/bin/env python3
"""check_fk_indexes.py — every foreign key must be indexed, unless the model marks its column noidx.

A foreign key counts as indexed when some index or key of the child table starts with the foreign-key
columns in order (TenantId first for tenant-scoped tables, as the generator creates them). A foreign key
with no index and no noidx flag fails the check; the generator creates an index for every other one.

Usage: python3 tools/dbgen/check_fk_indexes.py   (exit code 1 when a foreign key is not covered)
Sources: db/model/*.model (noidx flags) and db/generated/tsql (indexes and keys actually created).
"""
import glob, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import dbgen, ddl_keys
import erd_layout as L

ROOT = os.path.join(HERE, '..', '..')
DDL = os.path.join(ROOT, 'db', 'generated', 'tsql')


def cols_of(text):
    return [c.strip().strip('[]') for c in text.split(',') if c.strip()]


def index_prefixes(fq, idx_text, tab_text):
    schema, name = fq.split('.')
    out = [cols_of(m.group(1)) for m in re.finditer(
        r'CREATE (?:UNIQUE )?(?:CLUSTERED |NONCLUSTERED )?INDEX \[[^\]]+\] ON \[%s\]\.\[%s\] \(([^)]*)\)' % (schema, name), idx_text)]
    body = tab_text[tab_text.find(f'CREATE TABLE [{schema}].[{name}]'):]
    body = body[:body.find('\n);')]
    out += [cols_of(m.group(1)) for m in re.finditer(
        r'(?:PRIMARY KEY|CONSTRAINT \[UQ_[^\]]*\] UNIQUE) (?:CLUSTERED )?\(([^)]*)\)', body)]
    return out


def main():
    tables, errs, _ = dbgen.load(sorted(glob.glob(os.path.join(ROOT, 'db', 'model', '*.model'))), False)
    if errs:
        raise SystemExit('model errors: ' + '; '.join(errs[:3]))
    idx_text = open(os.path.join(DDL, '003_indexes.sql'), encoding='utf-8').read()
    tab_text = open(os.path.join(DDL, '001_tables.sql'), encoding='utf-8').read()
    covered = flagged = 0
    gaps = []
    cache = {}
    for f in ddl_keys.foreign_keys():
        if L.is_owner_fk(f):
            continue
        child = f['child']
        if child not in cache:
            cache[child] = index_prefixes(child, idx_text, tab_text)
        nt = [c for c in f['cols'] if c != 'TenantId']
        need = (['TenantId'] + nt) if tables[child].tenant_scoped else nt
        if any(p[:len(need)] == need for p in cache[child]):
            covered += 1
        elif any(getattr(c, 'noidx', False) for c in tables[child].cols if c.name in f['cols']):
            flagged += 1
        else:
            gaps.append(f"{child} ({', '.join(f['cols'])}) -> {f['parent']}")
    print(f'foreign keys indexed: {covered}; deliberately noidx: {flagged}; without index: {len(gaps)}')
    for g in gaps:
        print('  GAP', g)
    return 1 if gaps else 0


if __name__ == '__main__':
    sys.exit(main())
