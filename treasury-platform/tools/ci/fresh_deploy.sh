#!/usr/bin/env bash
# A fresh BankFas deployed the way production does (step 4 of tools/ci/db_ci.sh, DOC-S11, ADR 0010, ADR 0012): the
# server audit first, the empty database and the deployment login, the window opened, deploy.sh as bankfas_migrator,
# the database audit specification, the window closed. CI only (sa on a throwaway server): the image job of the
# workflow runs it before tools/ci/image_pilot.sh, whose browser test needs a database with no operator yet.
#
# Environment: SA_PASSWORD (required), SQL_SERVER (default localhost,1433), SQLCMD (default sqlcmd).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${SA_PASSWORD:?set SA_PASSWORD to the sa password}"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
export SQLCMD_OPTS=-C BANKFAS_ALLOW_TRUST_CERT=1 BANKFAS_ALLOW_SA=1 SQLCMDPASSWORD="$SA_PASSWORD"
# shellcheck source=tools/ci/ci_guard.sh
. "$ROOT/tools/ci/ci_guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sq() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b "$@"; }
for _ in $(seq 60); do sq -Q "SELECT 1" >/dev/null 2>&1 && break; sleep 2; done
sq -Q "$(ci_guard_drop_sql)
IF DB_ID(N'BankFas') IS NOT NULL BEGIN ALTER DATABASE [BankFas] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [BankFas]; END" >/dev/null
sq -Q "EXEC master.sys.xp_create_subdir N'/var/opt/mssql/audit';" >/dev/null
export BANKFAS_CHANGE_REF=CI-fresh
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/server_audit.sh apply
mkdir -m 700 "$TMP/migrator"
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$TMP/migrator" bash tools/deploy/prepare_database.sh prepare --generate
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/prepare_database.sh open
SQL_SERVER="$SQL_SERVER" SQL_USER=bankfas_migrator SQLCMDPASSWORD="$(cat "$TMP/migrator/bankfas_migrator.secret")" SQLCMD="$SQLCMD" \
    bash tools/deploy/deploy.sh
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/server_audit.sh apply
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/prepare_database.sh close
echo "fresh BankFas deployed as bankfas_migrator"
