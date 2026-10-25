#!/usr/bin/env bash
# Application CI (phase 2, ADR 0040): builds the .NET solution and the web front end, runs the unit tests, and runs the
# browser tests (tools/ci/e2e.sh) and the integration tests against the BankFas database that tools/ci/db_ci.sh has
# just deployed. The tests connect with the
# service logins of the deployment (provision_logins.sh, set a, secrets generated into a private temporary
# directory) and stand in for the deployment's bootstrap of the first operator (sa, CI only). The logins are dropped
# at the end. Run it after db_ci.sh, on the same throwaway server.
#
# Environment: SA_PASSWORD (required), SQL_SERVER (default localhost,1433), SQLCMD (default sqlcmd).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${SA_PASSWORD:?set SA_PASSWORD to the sa password}"
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

echo "== A1. build and unit tests (.NET)"
# dotnet reads app/global.json (SDK and test runner) from the directory it runs in
(cd app && dotnet build BankFas.slnx -c Release --nologo -v quiet && dotnet test --project tests/BankFas.Core.Tests -c Release --no-build)

echo "== A2. web front end: type check and build"
(cd app/web && npm ci --no-audit --no-fund --loglevel=error && npm run build --silent && npm test --silent)

echo "== A3. service logins"
SQLCMDPASSWORD="$SA_PASSWORD" SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$SEC" BANKFAS_LOGIN_SET=a \
    BANKFAS_CHANGE_REF=CI-app bash tools/deploy/provision_logins.sh --generate > "$TMP/provision.out" 2>&1 || {
    cat "$TMP/provision.out"
    echo "provisioning the service logins failed"
    exit 1
}
printf '%s' "$SA_PASSWORD" > "$TMP/sa"
chmod 600 "$TMP/sa"
echo "== A4. browser tests (Playwright, Chromium)"
CHROMIUM="${E2E_CHROMIUM:-}"
if [ -z "$CHROMIUM" ] && [ -x /opt/pw-browsers/chromium ]; then CHROMIUM=/opt/pw-browsers/chromium; fi
if [ -z "$CHROMIUM" ]; then
    (cd app/web && npx playwright install --with-deps chromium > "$TMP/pw-install.out" 2>&1)
    # The same Chromium prints the PDFs of the integration tests (PdfRenderer, docs/31 row 52).
    CHROMIUM="$(ls -d "$HOME"/.cache/ms-playwright/chromium-*/chrome-linux*/chrome 2>/dev/null | head -1)"
fi
SA_PASSWORD="$SA_PASSWORD" SQL_SERVER="$SQL_SERVER" SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$SEC" E2E_WORK="$TMP/e2e" \
    E2E_HANDOFF_FILE="$TMP/operator-link" E2E_CHROMIUM="$CHROMIUM" bash tools/ci/e2e.sh

echo "== A5. integration tests against the deployed database"
BANKFAS_IT_OPERATOR_LINK_FILE="$TMP/operator-link" BANKFAS_IT_SERVER="$(echo "$SQL_SERVER" | sed 's/^localhost$/localhost,1433/')" BANKFAS_IT_SECRETS="$SEC" BANKFAS_IT_SA_FILE="$TMP/sa" \
BANKFAS_IT_REQUIRED=1 Pdf__Chromium="$CHROMIUM" bash -c 'cd app && dotnet test --project tests/BankFas.IntegrationTests -c Release --no-build'
echo "application CI passed"
