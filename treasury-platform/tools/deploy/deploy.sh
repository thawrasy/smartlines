#!/usr/bin/env bash
# Deploys db/deploy.sql to SQL Server from Linux. The :r paths in deploy.sql are relative to the current
# directory, so this script changes to db/ first. tools/ci/db_ci.sh calls this script, so CI tests the same path.
# Before anything runs, db/ops/deploy_preflight.sql checks (DQ-S11-6, docs/adr/0014-deployment-preflight.md) that
# the login is neither sa nor a sysadmin (50140), that the SQL Server build and the Ubuntu release are those of
# versions.json (gate G4, 50143), and that BankFas exists in its collation (50141) and is empty (50142).
#
# Environment:
#   SQL_SERVER      server, default localhost,1433
#   SQL_USER        SQL login, default bankfas_migrator (ADR 0010). An empty value selects Windows authentication (-E),
#                   which needs a Kerberos ticket
#   SQLCMDPASSWORD  password of SQL_USER (sqlcmd reads it)
#   SQLCMD          sqlcmd command, default sqlcmd
#   SQLCMD_OPTS     extra sqlcmd options, default none. The server certificate is verified (DOC-S05 section 5.3,
#                   DQ-S05-7); only CI, whose throwaway container has a self-signed certificate, passes -C. The same
#                   variable and default hold for every script in tools/deploy and for tools/dbgen/check_deployed.py
#   BANKFAS_VERSIONS the release register, default versions.json at the root of treasury-platform
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$(cd "$HERE/../../db" && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-bankfas_migrator}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
VERSIONS="${BANKFAS_VERSIONS:-$HERE/../../versions.json}"
# shellcheck source=tools/deploy/preflight.sh
. "$HERE/preflight.sh"

if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi

# The release register: the SQL Server build and the Ubuntu release of the database host.
read -r expect_version expect_os < <(python3 -c 'import json, sys
h = json.load(open(sys.argv[1], encoding="utf-8"))["database_host"]
print(h["sqlserver"]["product_version"], h["os_release"])' "$VERSIONS")
[[ "$expect_version" =~ ^[0-9]+(\.[0-9]+){3}$ && "$expect_os" =~ ^[0-9]+\.[0-9]+$ ]] \
    || { echo "deploy: $VERSIONS must give database_host.sqlserver.product_version and database_host.os_release" >&2; exit 1; }
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
sql="$(cat "$DB_DIR/ops/deploy_preflight.sql")"
sql="${sql//\$(BANKFAS_EXPECT_VERSION)/$expect_version}"
sql="${sql//\$(BANKFAS_EXPECT_OS)/$expect_os}"
printf '%s\n' "$sql" > "$WORK/preflight.sql"
"$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i "$WORK/preflight.sql"

cd "$DB_DIR"
"$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i deploy.sql
echo "deployment finished"
