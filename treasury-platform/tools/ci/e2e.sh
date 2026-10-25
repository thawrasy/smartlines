#!/usr/bin/env bash
# Browser tests of S0 (ADR 0040), run by tools/ci/app_ci.sh on the database db_ci.sh deployed and with the service
# logins it provisioned. Starts the API (HTTPS on 127.0.0.1, a throwaway certificate for *.bankfas.test) and the
# worker, invites the first operator the way the deployment does (sa, CI only), and runs app/web/e2e in Chromium.
# The browser test invites an operator administrator for the integration tests that follow and writes its link to
# E2E_HANDOFF_FILE.
#
# Environment: SA_PASSWORD, SQL_SERVER, SQLCMD, BANKFAS_SECRETS_DIR (the provisioned secrets, set a),
# E2E_WORK (a private directory), E2E_HANDOFF_FILE (optional), E2E_CHROMIUM (optional, a Chromium binary).
# With E2E_API_IMAGE and E2E_WORKER_IMAGE (tools/ci/image_pilot.sh) the API and the worker run from those images
# instead, as the host runs them (tools/host/compose.yml: read-only, no capabilities, an unprivileged user), with
# the master keys in owner-only files (Keys:Provider file).
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
if [ -n "${E2E_API_IMAGE:-}" ]; then
    # The containers' user (10001) owns what they read and write; the secrets are copied for it.
    mkdir -p -m 700 "$W/keys" "$W/secrets" "$W/dataprotection"
    openssl rand -base64 32 > "$W/keys/e2e.key"
    cp "$BANKFAS_SECRETS_DIR"/*.secret "$W/secrets/"
    chown -R 10001:10001 "$W"
    chmod 400 "$W/keys/e2e.key" "$W/secrets/"*.secret
    BANKFAS_SECRETS_DIR="$W/secrets"
    export Keys__Provider=file Keys__File__Directory="$W/keys" Keys__File__Current=file:e2e DataProtection__KeysDirectory="$W/dataprotection"
else
    export Keys__Provider=local Keys__Local__Current=local:e2e/1 Keys__Local__Keys__0__Ref=local:e2e/1
    Keys__Local__Keys__0__Key="$(openssl rand -base64 32)"; export Keys__Local__Keys__0__Key
fi
export Mail__DropDirectory="$W/mail" Passwords__BreachedList__Directory="$W/breached" Passwords__BreachedList__AllowMissingRanges=true
export Files__Root="$W/files" Scanning__Provider=test
export Web__Root="$ROOT/app/web/dist"
export ASPNETCORE_URLS="https://127.0.0.1:$PORT" Kestrel__Certificates__Default__Path="$W/cert.pfx" Kestrel__Certificates__Default__Password="$CERT_PW"

BIN="$ROOT/app/src"
if [ -n "${E2E_API_IMAGE:-}" ]; then
    for pair in App:app Jobs:jobs Platform:platform Support:support; do
        login="${pair%%:*}"; name="${pair##*:}"
        export "Database__Logins__${login}__SecretFile=$BANKFAS_SECRETS_DIR/bankfas_${name}_a.secret"
    done
    unset Web__Root                                    # the image carries the portal's files
    env | grep -E '^(ASPNETCORE_ENVIRONMENT|DOTNET_ENVIRONMENT|Database__|Hosts__|Portal__|Keys__|DataProtection__|Mail__|Passwords__|Files__|Scanning__|Kestrel__)' > "$W/app.env"
    # Each process gets only its own logins, as on the host (docs/54): the API app, platform and support, the worker jobs.
    grep -v '^Database__Logins__Jobs__' "$W/app.env" > "$W/api.env"
    grep -vE '^(Database__Logins__(App|Platform|Support)__|Kestrel__|DataProtection__)' "$W/app.env" > "$W/worker.env"
    RUN=(docker run --rm --network host --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true -e HOME=/tmp -v "$W:$W")
    "${RUN[@]}" --env-file "$W/api.env" --name bankfas-pilot-api --shm-size 256m -e ASPNETCORE_URLS="$ASPNETCORE_URLS" "$E2E_API_IMAGE" > "$W/api.log" 2>&1 &
    API=$!
    "${RUN[@]}" --env-file "$W/worker.env" --name bankfas-pilot-worker "$E2E_WORKER_IMAGE" > "$W/worker.log" 2>&1 &
    WORKER=$!
    stop() { docker stop -t 10 bankfas-pilot-api bankfas-pilot-worker > /dev/null 2>&1 || true; wait "$API" "$WORKER" 2>/dev/null || true; }
else
    dotnet "$BIN/BankFas.Api/bin/Release/net10.0/BankFas.Api.dll" > "$W/api.log" 2>&1 &
    API=$!
    (unset ASPNETCORE_URLS; dotnet "$BIN/BankFas.Worker/bin/Release/net10.0/BankFas.Worker.dll") > "$W/worker.log" 2>&1 &
    WORKER=$!
    stop() { kill "$API" "$WORKER" 2>/dev/null || true; wait "$API" "$WORKER" 2>/dev/null || true; }
fi
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
    npx playwright test || {
        # The page as the failing step saw it (headings, notices, form errors), since CI keeps no artifacts.
        find test-results -name error-context.md -exec sh -c 'echo "-- page at the failure"; head -200 "$1"' _ {} \;
        fail "the browser tests failed"
    }
if [ -n "${E2E_API_IMAGE:-}" ]; then
    # Both containers are still up after the run, and the worker has worked (its log, without the request lines).
    for c in bankfas-pilot-api bankfas-pilot-worker; do
        [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || fail "the container $c stopped"
    done
    echo "-- worker log (last lines)"; tail -15 "$W/worker.log"
    grep -qiE "unhandled|crit|fail:" "$W/worker.log" && fail "the worker logged a failure"
    ls "$W/dataprotection"/key-*.xml > /dev/null 2>&1 || fail "the data protection keys were not kept"
    grep -q masterKeyWrapped "$W/dataprotection"/key-*.xml || fail "a data protection key is stored unwrapped"
fi
echo "browser tests passed"
