#!/usr/bin/env python3
"""check_deployed.py — compares what SQL Server holds after db/deploy.sql with the generated DDL and the static
scripts, and runs the read-only checks of DOC-S11 section 8.2.

The expected values come from db/generated/tsql (through ddl_keys) and from the static scripts db/deploy.sql runs,
not from the model, so the check catches a deployment that ran only part of the scripts:
  - the counts of tables, schemas, foreign keys, unique and check constraints and indexes;
  - one security policy per table of 004_rls_tables, none of them disabled;
  - every procedure and trigger that a static script declares WITH EXECUTE AS 'tp_auth_exec' runs so;
  - one trigger per trigger the static scripts create, none of them disabled: CREATE OR ALTER keeps a trigger that
    someone disabled disabled, so a later deployment would not show it (self-review C6);
  - no internal function (schemas rls, sec, plat, cfg, and lc.BeneficiaryIbanChange) readable by tp_readonly (090);
  - the deployment login bankfas_migrator disabled: the check runs after the window closes (self-review E3);
  - the collation Arabic_100_CI_AS_SC.
It reads definitions only, so the monitoring login bankfas_monitor (VIEW DEFINITION, no row) runs it in production
(docs/adr/0013-monitor-login-and-deployment-checks.md).

The connection follows tools/deploy/deploy.sh (DQ-S11-7): SQL_USER (default sa; an empty value selects -E),
SQLCMDPASSWORD, and SQLCMD_OPTS (default none, so the server certificate is verified; CI passes -C, DQ-S05-7). As in
tools/deploy/preflight.sh, -C is refused unless BANKFAS_ALLOW_TRUST_CERT=1, which only CI sets (DQ-S11-6).

Usage: SQL_USER=bankfas_monitor python3 tools/dbgen/check_deployed.py --sqlcmd sqlcmd --server <server> --database BankFas
Exit code 1 when any value differs.
"""
import argparse, os, re, shlex, subprocess, sys, tempfile
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import ddl_keys

DB = os.path.join(HERE, '..', '..', 'db')
DDL = os.path.join(DB, 'generated', 'tsql')
KEYS = ['tables', 'schemas', 'foreign keys', 'unique constraints', 'check constraints', 'indexes',
        'security policies', 'disabled policies', 'modules as tp_auth_exec', 'triggers', 'disabled triggers',
        'functions open to tp_readonly', 'deployment login disabled', 'collation Arabic_100_CI_AS_SC']
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
  (SELECT COUNT(*) FROM sys.triggers WHERE parent_class = 1),
  (SELECT COUNT(*) FROM sys.triggers WHERE is_disabled = 1),
  (SELECT COUNT(*) FROM sys.objects AS o
    WHERE o.type IN ('IF', 'TF', 'FN')
      AND (SCHEMA_NAME(o.schema_id) IN (N'rls', N'sec', N'plat', N'cfg') OR o.object_id = OBJECT_ID(N'lc.BeneficiaryIbanChange'))
      AND NOT EXISTS (SELECT 1 FROM sys.database_permissions AS p
                      WHERE p.major_id = o.object_id AND p.grantee_principal_id = DATABASE_PRINCIPAL_ID(N'tp_readonly')
                        AND p.state = 'D' AND p.permission_name = CASE WHEN o.type = 'FN' THEN 'EXECUTE' ELSE 'SELECT' END)),
  (SELECT COUNT(*) FROM sys.server_principals WHERE name = N'bankfas_migrator' AND is_disabled = 1),
  CASE WHEN CAST(DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS NVARCHAR(128)) = N'Arabic_100_CI_AS_SC' THEN 1 ELSE 0 END;"""


def static_scripts():
    """The static scripts in the order db/deploy.sql runs them."""
    deploy = open(os.path.join(DB, 'deploy.sql'), encoding='utf-8').read()
    return [os.path.join(DB, m) for m in re.findall(r'^:r (static/\S+\.sql)\s*$', deploy, re.M)]


def static_triggers():
    """The table triggers the static scripts create: the names they write out, and the two families 044 builds in a
    loop from a list (the freeze of an approved revision per revisioned table, and the draft-only parts of a template
    version). A new loop of this kind is to be added here, or the count differs."""
    names = set()
    for f in static_scripts():
        text = open(f, encoding='utf-8').read()
        names.update(f'{a}.{b}' for a, b in re.findall(r'CREATE\s+(?:OR\s+ALTER\s+)?TRIGGER\s+\[?(\w+)\]?\.\[?(\w+)\]?', text))
        if "N'_ApprovedFrozen'" in text:
            block = re.search(r'INSERT @t VALUES (.*?);', text, re.S).group(1)
            names.update(f'{a}.TR_{b}_ApprovedFrozen' for a, b in re.findall(r"\(N'(\w+)', N'(\w+)', N'\w+', [01]\)", block))
        if "N'_DraftOnly'" in text:
            block = re.search(r'INSERT @parts VALUES (.*?);', text, re.S).group(1)
            names.update(f'wfl.TR_{t}_DraftOnly' for t in re.findall(r"\(N'(\w+)', [01]\)", block))
        if "N'_KeyStatus'" in text:   # 054: one per table with a foreign key to sec.TenantKey, but the key log
            fks = open(os.path.join(DDL, '002_foreign_keys.sql'), encoding='utf-8').read()
            names.update(f'{a}.TR_{b}_KeyStatus'
                         for a, b in re.findall(r'ALTER TABLE \[(\w+)\]\.\[(\w+)\] ADD CONSTRAINT \[\w+\] FOREIGN KEY .*? REFERENCES \[sec\]\.\[TenantKey\]', fks)
                         if (a, b) != ('sec', 'KeyEvent'))
    return names


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
            'triggers': len(static_triggers()),
            'disabled triggers': 0,
            'functions open to tp_readonly': 0,
            'deployment login disabled': 1,
            'collation Arabic_100_CI_AS_SC': 1}


def allowed_options(text, sqlcmd):
    """SQLCMD_OPTS as tools/deploy/preflight.sh allows it: -l and -t with seconds, -N s|m, -f 65001, and -C only in CI; the
    sqlcmd command is a program, without options (self-review E7)."""
    def refuse(msg):
        raise SystemExit(f'check_deployed: {msg}')
    if re.search(r'\s', sqlcmd.strip()):
        refuse('--sqlcmd is the sqlcmd program, without options: put options in SQLCMD_OPTS')
    opts, i = shlex.split(text), 0
    while i < len(opts):
        o = opts[i]
        if o == '-C':
            if os.environ.get('BANKFAS_ALLOW_TRUST_CERT') != '1':
                refuse('-C trusts any server certificate; only CI may pass it (BANKFAS_ALLOW_TRUST_CERT=1, DOC-S05 section 5.3)')
        elif o in ('-l', '-t'):
            if i + 1 >= len(opts) or not re.fullmatch(r'\d{1,4}', opts[i + 1]):
                refuse(f'{o} takes a number of seconds')
            i += 1
        elif o == '-N':
            if i + 1 >= len(opts) or opts[i + 1] not in ('s', 'm'):
                refuse('-N takes s or m: the connection is encrypted (DOC-S05 section 5.3)')
            i += 1
        elif o == '-f':
            if i + 1 >= len(opts) or opts[i + 1] != '65001':
                refuse('-f takes 65001: the scripts are UTF-8 (DQ-S11-3)')
            i += 1
        elif o not in ('-Ns', '-Nm', '-f65001'):
            refuse(f"SQLCMD_OPTS may hold only -l, -t, -N s|m, -f 65001 and, in CI, -C; '{o}' is not on the list")
        i += 1
    return opts


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
    opts = allowed_options(os.environ.get('SQLCMD_OPTS', ''), args.sqlcmd)
    # The query goes in a file: an older sqlcmd garbles a long -Q argument.
    with tempfile.NamedTemporaryFile('w', suffix='.sql', encoding='utf-8', delete=False) as f:
        f.write(QUERY.format(db=args.database))
    try:
        cmd = [args.sqlcmd] + ['-S', args.server] + auth + ['-I', '-b'] + opts + ['-h', '-1', '-W', '-s', '|', '-i', f.name]
        r = subprocess.run(cmd, capture_output=True, text=True)
    finally:
        os.unlink(f.name)
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
