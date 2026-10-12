#!/usr/bin/env python3
"""check_deployed.py — compares what SQL Server holds after db/deploy.sql with the generated DDL.

The expected counts come from db/generated/tsql (through ddl_keys), not from the model, so the check
catches a deployment that ran only part of the scripts. The password is read from SQLCMDPASSWORD.

Usage: python3 tools/dbgen/check_deployed.py --sqlcmd sqlcmd --server localhost,1433 --database BankFas
Exit code 1 when any count differs.
"""
import argparse, os, re, shlex, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ddl_keys

DDL = os.path.join(HERE, '..', '..', 'db', 'generated', 'tsql')
KEYS = ['tables', 'schemas', 'foreign keys', 'unique constraints', 'check constraints', 'indexes']
QUERY = """SET NOCOUNT ON;
USE [{db}];
SELECT
  (SELECT COUNT(*) FROM sys.tables),
  (SELECT COUNT(DISTINCT s.name) FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id),
  (SELECT COUNT(*) FROM sys.foreign_keys),
  (SELECT COUNT(*) FROM sys.key_constraints WHERE type = 'UQ')
    + (SELECT COUNT(*) FROM sys.indexes WHERE is_unique = 1 AND is_primary_key = 0 AND is_unique_constraint = 0
         AND object_id IN (SELECT object_id FROM sys.tables)),
  (SELECT COUNT(*) FROM sys.check_constraints),
  (SELECT COUNT(*) FROM sys.indexes WHERE type IN (1, 2) AND is_primary_key = 0 AND is_unique_constraint = 0
         AND object_id IN (SELECT object_id FROM sys.tables));"""


def expected():
    t1 = open(os.path.join(DDL, '001_tables.sql'), encoding='utf-8').read()
    t3 = open(os.path.join(DDL, '003_indexes.sql'), encoding='utf-8').read()
    schemas = {m.group(1) for m in re.finditer(r'CREATE TABLE \[(\w+)\]\.\[\w+\]', t1)}
    totals = ddl_keys.totals()
    return {'tables': len(re.findall(r'CREATE TABLE \[', t1)),
            'schemas': len(schemas),
            'foreign keys': totals['fk_total'],
            'unique constraints': totals['unique_total'],
            'check constraints': len(re.findall(r'CHECK \(', t1)),
            'indexes': len(re.findall(r'^CREATE (?:UNIQUE )?(?:CLUSTERED |NONCLUSTERED )?INDEX ', t3, re.M))}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sqlcmd', default='sqlcmd')
    ap.add_argument('--server', default='localhost,1433')
    ap.add_argument('--database', default='BankFas')
    args = ap.parse_args()
    if not os.environ.get('SQLCMDPASSWORD'):
        raise SystemExit('SQLCMDPASSWORD is not set')
    cmd = shlex.split(args.sqlcmd) + ['-S', args.server, '-U', 'sa', '-C', '-I', '-b',
                                     '-h', '-1', '-W', '-s', '|', '-Q', QUERY.format(db=args.database)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'sqlcmd failed:\n{r.stdout}\n{r.stderr}')
    line = next(l for l in r.stdout.splitlines() if l.strip())
    actual = dict(zip(KEYS, (int(x) for x in line.split('|'))))
    want = expected()
    bad = []
    for k in KEYS:
        mark = 'ok ' if want[k] == actual[k] else 'DIFF'
        print(f'{mark} {k:20s} deployed={actual[k]:5d}  generated={want[k]:5d}')
        if want[k] != actual[k]:
            bad.append(k)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
