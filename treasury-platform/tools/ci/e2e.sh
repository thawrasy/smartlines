#!/usr/bin/env bash
# Browser tests of S0 (ADR 0040), run by tools/ci/app_ci.sh on the database db_ci.sh deployed and with the service
# logins it provisioned. Starts the API (HTTPS on 127.0.0.1, a throwaway certificate for *.bankfas.test) and the
# worker, invites the first operator the way the deployment does (sa, CI only), and runs app/web/e2e in Chromium.
# The browser test invites an operator administrator for the integration tests that follow and writes its link to
# E2E_HANDOFF_FILE.
#
# Environment: SA_PASSWORD, SQL_SERVER, SQLCMD, BANKFAS_SECRETS_DIR (the provisioned secrets, set a),
# E2E_WORK (a private directory), E2E_HANDOFF_FILE (optional), E2E_CHROMIUM (optional, a Chromium binary).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${SA_PASSWORD:?}" "${SQL_SERVER:?}" "${SQLCMD:?}" "${BANKFAS_SECRETS_DIR:?}" "${E2E_WORK:?}"
PORT="${E2E_PORT:-8443}"
W="$E2E_WORK"
mkdir -p -m 700 "$W/mail" "$W/breached" "$W/files"

# A throwaway certificate; the browser is told to ignore its issuer.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=bankfas.test" \
    -addext "subjectAltName=DNS:bankfas.test,DNS:*.bankfas.test" -keyout "$W/key.pem" -out "$W/cert.pem" 2>/dev/null
CERT_PW="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$W/key.pem" -in "$W/cert.pem" -out "$W/cert.pfx" -passout "pass:$CERT_PW"

# The leaked-password list of the test: one range, holding the password the test tries (DQ-S04-1).
HASH="$(printf '%s' 'correct horse battery staple' | sha1sum | awk '{print toupper($1)}')"
printf '%s:2400\r\n' "${HASH:5}" > "$W/breached/${HASH:0:5}.txt"

# Configuration of both processes; the master key is random for this run.
export ASPNETCORE_ENVIRONMENT=Testing DOTNET_ENVIRONMENT=Testing
export Database__Server="$(echo "$SQL_SERVER" | sed 's/^localhost$/localhost,1433/')" Database__TrustServerCertificate=true
for pair in App:app Jobs:jobs Platform:platform Support:support; do
    login="${pair%%:*}"; name="${pair##*:}"
    export "Database__Logins__${login}__User=bankfas_${name}_a"
    export "Database__Logins__${login}__SecretFile=$BANKFAS_SECRETS_DIR/bankfas_${name}_a.secret"
done
export Hosts__Operator=admin.bankfas.test Portal__Domain=bankfas.test Portal__Port="$PORT"
export Keys__Provider=local Keys__Local__Current=local:e2e/1 Keys__Local__Keys__0__Ref=local:e2e/1
Keys__Local__Keys__0__Key="$(openssl rand -base64 32)"; export Keys__Local__Keys__0__Key
export Mail__DropDirectory="$W/mail" Passwords__BreachedList__Directory="$W/breached" Passwords__BreachedList__AllowMissingRanges=true
export Files__Root="$W/files" Scanning__Provider=test
export Web__Root="$ROOT/app/web/dist"
export ASPNETCORE_URLS="https://127.0.0.1:$PORT" Kestrel__Certificates__Default__Path="$W/cert.pfx" Kestrel__Certificates__Default__Password="$CERT_PW"

BIN="$ROOT/app/src"
dotnet "$BIN/BankFas.Api/bin/Release/net10.0/BankFas.Api.dll" > "$W/api.log" 2>&1 &
API=$!
(unset ASPNETCORE_URLS; dotnet "$BIN/BankFas.Worker/bin/Release/net10.0/BankFas.Worker.dll") > "$W/worker.log" 2>&1 &
WORKER=$!
stop() { kill "$API" "$WORKER" 2>/dev/null || true; wait "$API" "$WORKER" 2>/dev/null || true; }
fail() { echo "$1"; echo "-- api"; tail -40 "$W/api.log"; echo "-- worker"; tail -40 "$W/worker.log"; stop; exit 1; }
trap stop EXIT
for _ in $(seq 60); do
    curl -ksf --noproxy "*" -o /dev/null --resolve "admin.bankfas.test:$PORT:127.0.0.1" "https://admin.bankfas.test:$PORT/" && break
    kill -0 "$API" 2>/dev/null || fail "the API stopped"
    sleep 1
done

# The deployment's invitation of the first operator (sa, CI only).
openssl rand 32 > "$W/token.bin"
TOKEN_HEX="$(od -An -tx1 -v "$W/token.bin" | tr -d ' \n')"
TOKEN="$(base64 -w0 < "$W/token.bin" | tr '+/' '-_' | tr -d '=')"
rm -f "$W/token.bin"
SQLCMDPASSWORD="$SA_PASSWORD" "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -Q \
    "SET NOCOUNT ON; EXEC plat.usp_BootstrapOperator @Email = N'e2e-operator@test.invalid', @DisplayName = N'E2E operator', @Token = 0x$TOKEN_HEX;" \
    > "$W/bootstrap.out" 2>&1 || { cat "$W/bootstrap.out"; fail "the operator bootstrap failed: deploy a fresh database"; }

cd "$ROOT/app/web"
E2E_SETUP_LINK="https://admin.bankfas.test:$PORT/setup#token=$TOKEN" E2E_MAIL_DIR="$W/mail" E2E_PORT="$PORT" \
    npx playwright test || fail "the browser tests failed"
echo "browser tests passed"
