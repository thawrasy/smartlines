#!/usr/bin/env python3
"""check_deployed.py — compares what SQL Server holds after db/deploy.sql with the generated DDL and the static
scripts, and runs the read-only checks of DOC-S11 section 8.2.

The expected values come from db/generated/tsql (through ddl_keys) and from the static scripts db/deploy.sql runs,
not from the model, so the check catches a deployment that ran only part of the scripts:
  - the counts of tables, schemas, foreign keys, unique and check constraints and indexes;
  - one security policy per table of 004_rls_tables, none of them disabled;
  - every procedure and trigger that a static script declares WITH EXECUTE AS 'tp_auth_exec' runs so;
  - the collation Arabic_100_CI_AS_SC.
It reads definitions only, so the monitoring login bankfas_monitor (VIEW DEFINITION, no row) runs it in production
(docs/adr/0013-monitor-login-and-deployment-checks.md).

The connection follows tools/deploy/deploy.sh (DQ-S11-7): SQL_USER (default sa; an empty value selects -E),
SQLCMDPASSWORD, and SQLCMD_OPTS (default none, so the server certificate is verified; CI passes -C, DQ-S05-7).

Usage: SQL_USER=bankfas_monitor python3 tools/dbgen/check_deployed.py --sqlcmd sqlcmd --server <server> --database BankFas
Exit code 1 when any value differs.
"""
import argparse, os, re, shlex, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ddl_keys

DB = os.path.join(HERE, '..', '..', 'db')
DDL = os.path.join(DB, 'generated', 'tsql')
KEYS = ['tables', 'schemas', 'foreign keys', 'unique constraints', 'check constraints', 'indexes',
        'security policies', 'disabled policies', 'modules as tp_auth_exec', 'collation Arabic_100_CI_AS_SC']
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
         AND object_id IN (SELECT object_id FROM sys.tables)),
  (SELECT COUNT(*) FROM sys.security_policies),
  (SELECT COUNT(*) FROM sys.security_policies WHERE is_enabled = 0),
  (SELECT COUNT(*) FROM sys.sql_modules WHERE USER_NAME(execute_as_principal_id) = N'tp_auth_exec'),
  CASE WHEN CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS NVARCHAR(128)) = N'Arabic_100_CI_AS_SC' THEN 1 ELSE 0 END;"""


def static_scripts():
    """The static scripts in the order db/deploy.sql runs them."""
    deploy = open(os.path.join(DB, 'deploy.sql'), encoding='utf-8').read()
    return [os.path.join(DB, m) for m in re.findall(r'^:r (static/\S+\.sql)\s*$', deploy, re.M)]


def expected():
    t1 = open(os.path.join(DDL, '001_tables.sql'), encoding='utf-8').read()
    t3 = open(os.path.join(DDL, '003_indexes.sql'), encoding='utf-8').read()
    t4 = open(os.path.join(DDL, '004_rls_tables.sql'), encoding='utf-8').read()
    schemas = {m.group(1) for m in re.finditer(r'CREATE TABLE \[(\w+)\]\.\[\w+\]', t1)}
    totals = ddl_keys.totals()
    as_auth = sum(len(re.findall(r"^\s*WITH\s+EXECUTE AS N?'tp_auth_exec'", open(f, encoding='utf-8').read(), re.M))
                  for f in static_scripts())
    return {'tables': len(re.findall(r'CREATE TABLE \[', t1)),
            'schemas': len(schemas),
            'foreign keys': totals['fk_total'],
            'unique constraints': totals['unique_total'],
            'check constraints': len(re.findall(r'CHECK \(', t1)),
            'indexes': len(re.findall(r'^CREATE (?:UNIQUE )?(?:CLUSTERED |NONCLUSTERED )?INDEX ', t3, re.M)),
            'security policies': len(re.findall(r'^INSERT #rls_tables ', t4, re.M)),
            'disabled policies': 0,
            'modules as tp_auth_exec': as_auth,
            'collation Arabic_100_CI_AS_SC': 1}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--sqlcmd', default='sqlcmd')
    ap.add_argument('--server', default='localhost,1433')
    ap.add_argument('--database', default='BankFas')
    args = ap.parse_args()
    user = os.environ.get('SQL_USER', 'sa')
    if user:
        if not os.environ.get('SQLCMDPASSWORD'):
            raise SystemExit(f'set SQLCMDPASSWORD for the login {user}')
        auth = ['-U', user]
    else:
        auth = ['-E']
    cmd = (shlex.split(args.sqlcmd) + ['-S', args.server] + auth + ['-I', '-b']
           + shlex.split(os.environ.get('SQLCMD_OPTS', ''))
           + ['-h', '-1', '-W', '-s', '|', '-Q', QUERY.format(db=args.database)])
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(f'sqlcmd failed:\n{r.stdout}\n{r.stderr}')
    line = next(l.strip() for l in r.stdout.splitlines() if re.fullmatch(r'\d+(\|\d+){%d}' % (len(KEYS) - 1), l.strip()))
    actual = dict(zip(KEYS, (int(x) for x in line.split('|'))))
    want = expected()
    bad = []
    for k in KEYS:
        mark = 'ok ' if want[k] == actual[k] else 'DIFF'
        print(f'{mark} {k:30s} deployed={actual[k]:5d}  expected={want[k]:5d}')
        if want[k] != actual[k]:
            bad.append(k)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
