#!/usr/bin/env bash
# Deploys db/deploy.sql to SQL Server from Linux. The :r paths in deploy.sql are relative to the current
# directory, so this script changes to db/ first. tools/ci/db_ci.sh calls this script, so CI tests the same path.
#
# Environment:
#   SQL_SERVER      server, default localhost,1433
#   SQL_USER        SQL login, default sa. An empty value selects Windows authentication (-E), which needs a Kerberos ticket
#   SQLCMDPASSWORD  password of SQL_USER (sqlcmd reads it)
#   SQLCMD          sqlcmd command, default sqlcmd
#   SQLCMD_OPTS     extra options, default -C (trust the server certificate). Drop it once the server has a trusted
#                   certificate (open decision O-08)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$(cd "$HERE/../../db" && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-sa}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS--C}"

if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi

cd "$DB_DIR"
"$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS -i deploy.sql
echo "deployment finished"
