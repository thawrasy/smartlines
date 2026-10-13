#!/usr/bin/env bash
# The deployment preflight (db/ops/deploy_preflight.sql, tools/deploy/preflight.sh; ADR 0014, DQ-S11-6): deploy.sh
# refuses a database that already holds tables and changes nothing; it refuses sa and any sysadmin, in CI too; every
# tool refuses -C before connecting unless CI allows it; the administrator scripts refuse sa unless CI allows it; and
# deploy.sh refuses a server whose build or Ubuntu release differs from versions.json. Prints PASS or FAIL lines like
# the .sql tests. The logins it creates are dropped at the end.
#
# Environment: SQLCMDPASSWORD (sa), SQL_SERVER (default localhost,1433), SQLCMD (default sqlcmd), SQLCMD_OPTS (-C in
#              CI), MIGRATOR_SECRET (the secret file of bankfas_migrator from step 4), MONITOR_SECRETS (the folder of
#              bankfas_monitor.secret)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
SA_PW="${SQLCMDPASSWORD:?set SQLCMDPASSWORD to the sa password}"
MIGRATOR_PW="$(cat "${MIGRATOR_SECRET:?set MIGRATOR_SECRET to the secret file of bankfas_migrator}")"
MONITOR_DIR="${MONITOR_SECRETS:?set MONITOR_SECRETS to the folder of bankfas_monitor.secret}"
export SQL_SERVER SQLCMD BANKFAS_CHANGE_REF=CI-preflight
TMP="$(mktemp -d)"
mkdir -m 700 "$TMP/secrets"
trap 'rm -rf "$TMP"' EXIT
ADMIN_PW="Pf-$(head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-30)9a"

sa_run() { printf '%s\n' "$1" > "$TMP/sa.sql"; SQLCMDPASSWORD="$SA_PW" "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -h -1 -W -i "$TMP/sa.sql"; }
window() { SQLCMDPASSWORD="$SA_PW" SQL_USER=sa bash "$ROOT/tools/deploy/prepare_database.sh" "$1" >/dev/null; }
deploy_as() {   # login, secret: deploy.sh's output and exit code in $TMP/deploy.out, $rc
    rc=0
    SQL_USER="$1" SQLCMDPASSWORD="$2" bash "$ROOT/tools/deploy/deploy.sh" > "$TMP/deploy.out" 2>&1 || rc=$?
}
state() { sa_run "SET NOCOUNT ON; SELECT CONCAT((SELECT COUNT(*) FROM BankFas.sys.objects), '/', (SELECT COUNT(*) FROM BankFas.sys.schemas), '/',
                  (SELECT is_disabled FROM sys.server_principals WHERE name = N'bankfas_migrator'));"; }
# Service logins left by an earlier run would hide what PF4 must show; they are dropped at the start and the end.
cleanup_sql="SET NOCOUNT ON;
IF SUSER_ID(N'ci_preflight_admin') IS NOT NULL DROP LOGIN [ci_preflight_admin];
USE [BankFas];
DECLARE @n SYSNAME, @sql NVARCHAR(300);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.database_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S';
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP USER ' + QUOTENAME(@n); EXEC sys.sp_executesql @sql; FETCH NEXT FROM c INTO @n; END;
CLOSE c; DEALLOCATE c;
DECLARE l CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.server_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S';
OPEN l; FETCH NEXT FROM l INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP LOGIN ' + QUOTENAME(@n); EXEC master.sys.sp_executesql @sql; FETCH NEXT FROM l INTO @n; END;
CLOSE l; DEALLOCATE l;"
sa_run "$cleanup_sql" >/dev/null

# PF1: deploy.sh on a database that already holds tables stops before db/deploy.sql and changes nothing.
before="$(state)"
window open
deploy_as bankfas_migrator "$MIGRATOR_PW"
window close
after="$(state)"
if [ "$rc" -ne 0 ] && grep -q "Msg 50142" "$TMP/deploy.out" && ! grep -q "deployment finished" "$TMP/deploy.out" \
   && [ "$before" = "$after" ]; then
    echo "PASS PF1: deploy.sh refuses a database that already holds tables (50142) and changes nothing ($after objects/schemas/disabled)"
else
    echo "FAIL PF1: exit $rc, objects before $before after $after"; cat "$TMP/deploy.out"; echo
fi

# PF2: deploy.sh refuses sa and any sysadmin, in CI too (50140): the deployment runs as bankfas_migrator only.
deploy_as sa "$SA_PW"; rc_sa=$rc; grep -q "Msg 50140" "$TMP/deploy.out" && sa_refused=1 || sa_refused=0
sa_run "CREATE LOGIN [ci_preflight_admin] WITH PASSWORD = N'$ADMIN_PW', CHECK_POLICY = OFF; ALTER SERVER ROLE [sysadmin] ADD MEMBER [ci_preflight_admin];" >/dev/null
deploy_as ci_preflight_admin "$ADMIN_PW"; rc_admin=$rc; grep -q "Msg 50140" "$TMP/deploy.out" && admin_refused=1 || admin_refused=0
sa_run "DROP LOGIN [ci_preflight_admin];" >/dev/null
if [ "$rc_sa" -ne 0 ] && [ "$sa_refused" -eq 1 ] && [ "$rc_admin" -ne 0 ] && [ "$admin_refused" -eq 1 ]; then
    echo "PASS PF2: deploy.sh refuses sa and a sysadmin login (50140), even where CI allows sa elsewhere"
else
    echo "FAIL PF2: sa exit $rc_sa refused $sa_refused, sysadmin exit $rc_admin refused $admin_refused"; cat "$TMP/deploy.out"; echo
fi

# PF3: without the CI allowance, -C stops every tool before it connects (the server name does not even resolve).
refused=0
no_trust() { env -u BANKFAS_ALLOW_TRUST_CERT SQL_SERVER=no-such-server.invalid,1433 SQLCMD_OPTS=-C SQLCMDPASSWORD=x "$@" > "$TMP/c.out" 2>&1 && return 1
             grep -q -- "-C trusts any server certificate" "$TMP/c.out"; }
no_trust SQL_USER=bankfas_migrator bash "$ROOT/tools/deploy/deploy.sh" && refused=$((refused + 1))
no_trust SQL_USER=sa bash "$ROOT/tools/deploy/prepare_database.sh" open && refused=$((refused + 1))
no_trust SQL_USER=sa BANKFAS_SECRETS_DIR="$TMP/secrets" bash "$ROOT/tools/deploy/provision_logins.sh" --generate && refused=$((refused + 1))
no_trust SQL_USER=sa BANKFAS_SECRETS_DIR="$TMP/secrets" bash "$ROOT/tools/deploy/provision_monitor.sh" --generate && refused=$((refused + 1))
no_trust SQL_USER=bankfas_monitor bash "$ROOT/tools/deploy/server_audit.sh" check && refused=$((refused + 1))
no_trust SQL_USER=bankfas_monitor python3 "$ROOT/tools/dbgen/check_deployed.py" --sqlcmd "$SQLCMD" --server no-such-server.invalid,1433 \
    && refused=$((refused + 1))
if [ "$refused" -eq 6 ]; then
    echo "PASS PF3: without the CI allowance, -C stops deploy.sh, prepare_database.sh, provision_logins.sh, provision_monitor.sh, server_audit.sh and check_deployed.py before they connect"
else
    echo "FAIL PF3: $refused of 6 tools refused -C"
fi

# PF4: without the CI allowance, the administrator scripts refuse sa (50144) and change nothing; the monitoring login is
# refused nothing it is allowed.
codes=""
no_sa() { if env -u BANKFAS_ALLOW_SA SQLCMDPASSWORD="$SA_PW" SQL_USER=sa "$@" > "$TMP/s.out" 2>&1; then codes="$codes ok"
          else codes="$codes $(grep -o 'Msg 501[0-9][0-9]' "$TMP/s.out" | head -n 1 | cut -c5-)"; fi; }
before="$(state)"
no_sa bash "$ROOT/tools/deploy/prepare_database.sh" open
no_sa env BANKFAS_SECRETS_DIR="$TMP/secrets" bash "$ROOT/tools/deploy/provision_logins.sh" --generate
no_sa env BANKFAS_SECRETS_DIR="$MONITOR_DIR" bash "$ROOT/tools/deploy/provision_monitor.sh"
no_sa bash "$ROOT/tools/deploy/server_audit.sh" apply
after="$(state)"
logins="$(sa_run "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.server_principals WHERE name LIKE N'bankfas[_]%[_][ab]';")"
if [ "$codes" = " 50144 50144 50144 50144" ] && [ "$before" = "$after" ] && [ "$logins" = "0" ]; then
    echo "PASS PF4: without the CI allowance, prepare_database.sh, provision_logins.sh, provision_monitor.sh and server_audit.sh apply refuse sa (50144) and change nothing"
else
    echo "FAIL PF4: errors [$codes] (expected [ 50144 50144 50144 50144]), state before $before after $after, service logins $logins"
fi

# PF5: deploy.sh refuses a server whose SQL Server build or Ubuntu release is not the one of the release register (G4).
python3 - "$ROOT/versions.json" "$TMP" <<'PY'
import json, sys
v = json.load(open(sys.argv[1], encoding='utf-8'))
build = json.loads(json.dumps(v)); build['database_host']['sqlserver']['product_version'] = '17.0.9999.1'
os_rel = json.loads(json.dumps(v)); os_rel['database_host']['os_release'] = '22.04'
json.dump(build, open(sys.argv[2] + '/build.json', 'w')); json.dump(os_rel, open(sys.argv[2] + '/os.json', 'w'))
PY
window open
export BANKFAS_VERSIONS="$TMP/build.json"
deploy_as bankfas_migrator "$MIGRATOR_PW"; rc_build=$rc; build_out="$(cat "$TMP/deploy.out")"
export BANKFAS_VERSIONS="$TMP/os.json"
deploy_as bankfas_migrator "$MIGRATOR_PW"; rc_os=$rc; grep -q "Msg 50143" "$TMP/deploy.out" && os_refused=1 || os_refused=0
unset BANKFAS_VERSIONS
deploy_as bankfas_migrator "$MIGRATOR_PW"; grep -q "Msg 50142" "$TMP/deploy.out" && register_passes=1 || register_passes=0
window close
if [ "$rc_build" -ne 0 ] && [[ "$build_out" == *"Msg 50143"*"17.0.9999.1"* ]] && [ "$rc_os" -ne 0 ] && [ "$os_refused" -eq 1 ] \
   && [ "$register_passes" -eq 1 ] && ! grep -q "deployment finished" <<< "$build_out"; then
    echo "PASS PF5: deploy.sh refuses a server whose SQL Server build or Ubuntu release differs from versions.json (50143); with the register it reaches the next check"
else
    echo "FAIL PF5: build exit $rc_build [$build_out], release exit $rc_os refused $os_refused, register passes $register_passes"; cat "$TMP/deploy.out"; echo
fi

sa_run "$cleanup_sql" >/dev/null
