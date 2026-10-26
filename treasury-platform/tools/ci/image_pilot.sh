#!/usr/bin/env bash
# The pilot run of the release images (docs/53): the browser tests of tools/ci/e2e.sh against the API and the worker
# started from their images (app/deploy/Dockerfile) the way the host runs them (tools/host/compose.yml): read-only
# root, no capabilities, user 10001, master keys in owner-only files. Run it after db_ci.sh on a throwaway server,
# like app_ci.sh; the service logins it provisions are dropped at the end.
#
# Environment: SA_PASSWORD (required), API_IMAGE and WORKER_IMAGE (required), SQL_SERVER (default localhost,1433),
# SQLCMD (default sqlcmd). The web front end must be installed (npm ci in app/web) for Playwright.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${SA_PASSWORD:?set SA_PASSWORD to the sa password}" "${API_IMAGE:?}" "${WORKER_IMAGE:?}"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
export SQLCMD_OPTS=-C BANKFAS_ALLOW_TRUST_CERT=1 BANKFAS_ALLOW_SA=1
# shellcheck source=tools/ci/ci_guard.sh
. "$ROOT/tools/ci/ci_guard.sh"
TMP="$(mktemp -d)"
SEC="$TMP/secrets"
mkdir -m 700 "$SEC"
cleanup() {
    printf '%s\n' "SET NOCOUNT ON; USE [BankFas];
DECLARE @n SYSNAME, @sql NVARCHAR(300);
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.database_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S'
    AND name NOT LIKE N'bankfas[_]migrator%' AND name NOT LIKE N'bankfas[_]monitor%';
OPEN c; FETCH NEXT FROM c INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP USER ' + QUOTENAME(@n); EXEC sys.sp_executesql @sql; FETCH NEXT FROM c INTO @n; END;
CLOSE c; DEALLOCATE c;
DECLARE l CURSOR LOCAL FAST_FORWARD FOR SELECT name FROM sys.server_principals WHERE name LIKE N'bankfas[_]%[_][ab]' AND type = 'S'
    AND name NOT LIKE N'bankfas[_]migrator%' AND name NOT LIKE N'bankfas[_]monitor%';
OPEN l; FETCH NEXT FROM l INTO @n;
WHILE @@FETCH_STATUS = 0 BEGIN SET @sql = N'DROP LOGIN ' + QUOTENAME(@n); EXEC sys.sp_executesql @sql; FETCH NEXT FROM l INTO @n; END;
CLOSE l; DEALLOCATE l;" > "$TMP/drop.sql"
    SQLCMDPASSWORD="$SA_PASSWORD" "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -i "$TMP/drop.sql" >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

echo "== P1. the images run as the host runs them"
for image in "$API_IMAGE" "$WORKER_IMAGE"; do
    [ "$(docker image inspect --format '{{.Config.User}}' "$image")" = "bankfas" ] || { echo "$image does not run as the bankfas user"; exit 1; }
done
docker run --rm --read-only --tmpfs /tmp --cap-drop ALL -e HOME=/tmp --entrypoint /opt/chromium/headless_shell "$API_IMAGE" --version

echo "== P2. service logins"
SQLCMDPASSWORD="$SA_PASSWORD" SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$SEC" BANKFAS_LOGIN_SET=a \
    BANKFAS_CHANGE_REF=CI-pilot bash tools/deploy/provision_logins.sh --generate > "$TMP/provision.out" 2>&1 || {
    cat "$TMP/provision.out"; echo "provisioning the service logins failed"; exit 1; }

echo "== P3. browser tests against the containers"
SA_PASSWORD="$SA_PASSWORD" SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$SEC" E2E_WORK="$TMP/e2e" \
    E2E_API_IMAGE="$API_IMAGE" E2E_WORKER_IMAGE="$WORKER_IMAGE" E2E_CHROMIUM="${E2E_CHROMIUM:-}" bash tools/ci/e2e.sh
echo "image pilot passed"
