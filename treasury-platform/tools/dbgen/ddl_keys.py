#!/usr/bin/env python3
"""ddl_keys.py — يقرأ المفاتيح من DDL المولَّد، وهو المصدر الفعلي لقاعدة البيانات:
- pk_cols(fq): أعمدة المفتاح الأساسي كما تُنشأ في SQL Server (تشمل TenantId في المفاتيح المركّبة)
- unique_count(fq): عدد القيود الفريدة للجدول (CONSTRAINT UQ_ + الفهارس الفريدة المصفّاة وغيرها)
- owner_tables(): الجداول التي يشير عمود TenantId فيها إلى plat.Tenant (ملكية المشترك)
"""
import os, re

HERE = os.path.dirname(os.path.abspath(__file__))
DDL_DIR = os.path.join(HERE, '..', '..', 'db', 'generated', 'tsql')
_cache = None


def _load():
    global _cache
    if _cache is not None:
        return _cache
    t1 = open(os.path.join(DDL_DIR, '001_tables.sql'), encoding='utf-8').read()
    t2 = open(os.path.join(DDL_DIR, '002_foreign_keys.sql'), encoding='utf-8').read()
    t3 = open(os.path.join(DDL_DIR, '003_indexes.sql'), encoding='utf-8').read()
    pk, uq, cols = {}, {}, {}
    for m in re.finditer(r'CREATE TABLE \[(\w+)\]\.\[(\w+)\] \((.*?)\n\);', t1, re.S):
        fq, body = f'{m.group(1)}.{m.group(2)}', m.group(3)
        p = re.search(r'PRIMARY KEY CLUSTERED \(([^)]*)\)', body)
        pk[fq] = [c.strip().strip('[]') for c in p.group(1).split(',')] if p else []
        uq[fq] = len(re.findall(r'CONSTRAINT \[UQ_[^\]]*\] UNIQUE \(', body))
        cols[fq] = []
        for line in body.split('\n'):
            cm = re.match(r'\s*\[(\w+)\] ([A-Z0-9_]+(?:\([^)]*\))?)', line)
            if cm:
                cols[fq].append((cm.group(1), cm.group(2).lower(), 'NOT NULL' in line))
    for m in re.finditer(r'CREATE UNIQUE NONCLUSTERED INDEX \[[^\]]+\] ON \[(\w+)\]\.\[(\w+)\]', t3):
        fq = f'{m.group(1)}.{m.group(2)}'
        uq[fq] = uq.get(fq, 0) + 1
    fks = []
    for m in re.finditer(r'ALTER TABLE \[(\w+)\]\.\[(\w+)\] ADD CONSTRAINT \[[^\]]+\] FOREIGN KEY \(([^)]*)\) REFERENCES \[(\w+)\]\.\[(\w+)\] \(([^)]*)\)([^;]*);', t2):
        strip = lambda x: [c.strip().strip('[]') for c in x.split(',') if c.strip()]
        fks.append({'child': f'{m.group(1)}.{m.group(2)}', 'cols': strip(m.group(3)), 'parent': f'{m.group(4)}.{m.group(5)}', 'pcols': strip(m.group(6)), 'cascade': 'ON DELETE CASCADE' in m.group(7)})
    owners = set()
    for m in re.finditer(r'ALTER TABLE \[(\w+)\]\.\[(\w+)\] ADD CONSTRAINT \[[^\]]+\] FOREIGN KEY \(\[TenantId\]\) REFERENCES \[plat\]\.\[Tenant\]', t2):
        owners.add(f'{m.group(1)}.{m.group(2)}')
    fk_total = t2.count('FOREIGN KEY')
    _cache = {'pk': pk, 'uq': uq, 'cols': cols, 'fks': fks, 'owners': owners, 'fk_total': fk_total,
              'tables': len(pk), 'unique_total': sum(uq.values())}
    return _cache


def pk_cols(fq):
    return _load()['pk'][fq]


def unique_count(fq):
    return _load()['uq'].get(fq, 0)


def columns(fq):
    """(name, sql_type, not_null) for every column of the table, as created by the DDL."""
    return _load()['cols'][fq]


def foreign_keys():
    """Every foreign-key constraint: child, cols, parent, pcols, cascade."""
    return _load()['fks']


def owner_tables():
    return _load()['owners']


def totals():
    d = _load()
    return {k: d[k] for k in ('tables', 'fk_total', 'unique_total')} | {'owners': len(d['owners'])}


if __name__ == '__main__':
    print(totals())
