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
    pk, uq = {}, {}
    for m in re.finditer(r'CREATE TABLE \[(\w+)\]\.\[(\w+)\] \((.*?)\n\);', t1, re.S):
        fq, body = f'{m.group(1)}.{m.group(2)}', m.group(3)
        p = re.search(r'PRIMARY KEY CLUSTERED \(([^)]*)\)', body)
        pk[fq] = [c.strip().strip('[]') for c in p.group(1).split(',')] if p else []
        uq[fq] = len(re.findall(r'CONSTRAINT \[UQ_[^\]]*\] UNIQUE \(', body))
    for m in re.finditer(r'CREATE UNIQUE NONCLUSTERED INDEX \[[^\]]+\] ON \[(\w+)\]\.\[(\w+)\]', t3):
        fq = f'{m.group(1)}.{m.group(2)}'
        uq[fq] = uq.get(fq, 0) + 1
    owners = set()
    for m in re.finditer(r'ALTER TABLE \[(\w+)\]\.\[(\w+)\] ADD CONSTRAINT \[[^\]]+\] FOREIGN KEY \(\[TenantId\]\) REFERENCES \[plat\]\.\[Tenant\]', t2):
        owners.add(f'{m.group(1)}.{m.group(2)}')
    fk_total = t2.count('FOREIGN KEY')
    _cache = {'pk': pk, 'uq': uq, 'owners': owners, 'fk_total': fk_total,
              'tables': len(pk), 'unique_total': sum(uq.values())}
    return _cache


def pk_cols(fq):
    return _load()['pk'][fq]


def unique_count(fq):
    return _load()['uq'].get(fq, 0)


def owner_tables():
    return _load()['owners']


def totals():
    d = _load()
    return {k: d[k] for k in ('tables', 'fk_total', 'unique_total')} | {'owners': len(d['owners'])}


if __name__ == '__main__':
    print(totals())
