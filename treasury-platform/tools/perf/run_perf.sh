#!/usr/bin/env bash
# The performance measurement of the database (review v5.0 P0-2; NFR-PERF-01, NFR-PERF-06, NFR-SCL-01, NFR-SCL-02;
# ADR 0036). It drops BankFas and builds it again, so it runs only against a server on this machine or one marked a
# throwaway (as tools/ci/db_ci.sh), and never where real data lives.
#   1. deploys db/deploy.sql to a fresh BankFas through the production path (prepare, deploy as bankfas_migrator);
#   2. writes the synthetic data of tools/perf/perf_seed.sql: 300 tenants by default, three of them at the volume of
#      NFR-SCL-02 on the tables the database's own paths read;
#   3. measures (tools/perf/perf_measure.sql), then the session binding of NFR-PERF-06 one new connection per call
#      (the binding keys are read-only for the life of a connection), four writers of one tenant's audit chain at
#      once followed by the chain's verification, and the repeatable scripts of tools/deploy/migrate.sh on the loaded
#      database (the length of a deployment window);
#   4. writes the raw lines to $PERF_OUT and the report to $PERF_REPORT (tools/perf/perf_report.py).
#
# Environment: SA_PASSWORD (required), SQL_SERVER (default localhost,1433), SQLCMD; the sizes PERF_FULL (3),
# PERF_LIGHT (297), PERF_COMPANIES (200), PERF_YEARS (5), PERF_AUDIT (50000), PERF_SESSIONS (50000),
# PERF_LIGHT_AUDIT (2000), PERF_ITER (50), PERF_BIND (100), PERF_WRITERS (4), PERF_WRITES (500);
# PERF_OUT (default docs/perf/perf-run.txt), PERF_REPORT (default docs/perf/perf-results.md).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
: "${SA_PASSWORD:?set SA_PASSWORD to the sa password}"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
export SQLCMDPASSWORD="$SA_PASSWORD"
ci_host="${SQL_SERVER%%,*}"; ci_host="${ci_host#tcp:}"
case "$ci_host" in
    localhost|127.0.0.1|::1|"(local)"|.) ;;
    *) [ "${BANKFAS_CI_THROWAWAY_SERVER:-}" = "1" ] \
           || { echo "run_perf.sh drops BankFas: it runs only against a server on this machine, not $ci_host"; exit 1; } ;;
esac
export SQLCMD_OPTS=-C BANKFAS_ALLOW_TRUST_CERT=1 BANKFAS_ALLOW_SA=1
FULL="${PERF_FULL:-3}" LIGHT="${PERF_LIGHT:-297}" COMPANIES="${PERF_COMPANIES:-200}" YEARS="${PERF_YEARS:-5}"
AUDIT="${PERF_AUDIT:-50000}" SESSIONS="${PERF_SESSIONS:-50000}" LIGHT_AUDIT="${PERF_LIGHT_AUDIT:-2000}"
ITER="${PERF_ITER:-50}" BIND="${PERF_BIND:-100}" WRITERS="${PERF_WRITERS:-4}" WRITES="${PERF_WRITES:-500}"
OUT="${PERF_OUT:-$ROOT/docs/perf/perf-run.txt}"
REPORT="${PERF_REPORT:-$ROOT/docs/perf/perf-results.md}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
sq() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b "$@"; }
mkdir -p "$(dirname "$OUT")"
: > "$OUT"
log() { echo "$*" | tee -a "$OUT"; }
now_ms() { date +%s%3N; }

log "RUN|started|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "RUN|commit|$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
log "RUN|server|$(sq -h -1 -W -Q "SET NOCOUNT ON; SELECT CONCAT(CAST(SERVERPROPERTY('ProductVersion') AS NVARCHAR(40)), ' ', CAST(SERVERPROPERTY('Edition') AS NVARCHAR(80)));" | tr -d '\r' | tail -1)"
log "RUN|host|$(nproc) cpu, $(free -g | awk '/^Mem:/ {print $2}') GB memory"
log "RUN|sizes|full $FULL, light $LIGHT, companies $COMPANIES, years $YEARS, audit $AUDIT, sessions $SESSIONS, light audit $LIGHT_AUDIT"

# 1. a fresh database through the production path
t0=$(now_ms)
sq -Q "IF DB_ID(N'BankFas') IS NOT NULL BEGIN ALTER DATABASE [BankFas] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [BankFas]; END" >/dev/null
mkdir -m 700 "$TMP/migrator"
export BANKFAS_CHANGE_REF=PERF
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" BANKFAS_SECRETS_DIR="$TMP/migrator" bash tools/deploy/prepare_database.sh prepare --generate >/dev/null
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/prepare_database.sh open >/dev/null
SQL_SERVER="$SQL_SERVER" SQL_USER=bankfas_migrator SQLCMDPASSWORD="$(cat "$TMP/migrator/bankfas_migrator.secret")" SQLCMD="$SQLCMD" \
    bash tools/deploy/deploy.sh >/dev/null
log "RUN|deploy seconds|$(( ($(now_ms) - t0) / 1000 ))"

# 2. the synthetic data
{ printf ':setvar FullTenants %s\n:setvar LightTenants %s\n:setvar Companies %s\n:setvar Years %s\n:setvar AuditRows %s\n:setvar Sessions %s\n:setvar LightAudit %s\n' \
      "$FULL" "$LIGHT" "$COMPANIES" "$YEARS" "$AUDIT" "$SESSIONS" "$LIGHT_AUDIT"
  cat tools/perf/perf_seed.sql; } > "$TMP/seed.sql"
t0=$(now_ms)
sq -h -1 -W -i "$TMP/seed.sql" > "$TMP/seed.out" 2>&1 || { cat "$TMP/seed.out"; echo "the synthetic data failed"; exit 1; }
grep -a '^GEN|' "$TMP/seed.out" | tee -a "$OUT"
log "RUN|seed seconds|$(( ($(now_ms) - t0) / 1000 ))"

# 3a. the database's own paths
{ printf ':setvar Iterations %s\n' "$ITER"; cat tools/perf/perf_measure.sql; } > "$TMP/measure.sql"
sq -h -1 -W -i "$TMP/measure.sql" > "$TMP/measure.out" 2>&1 || { cat "$TMP/measure.out"; echo "the measurement failed"; exit 1; }
grep -aE '^(RESULT|INFO|SIZE|TOP|MISSING)\|' "$TMP/measure.out" | tee -a "$OUT"

# 3b. NFR-PERF-06: the session binding, one new connection per call, timed on the server
t="$(sq -h -1 -W -Q "SET NOCOUNT ON; SELECT TenantId FROM BankFas.plat.Tenant WHERE Code = 'perf-f001';" | tr -d '\r' | grep -E '^[0-9]+$')"
for i in $(seq 1 "$BIND"); do
    sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; DECLARE @t0 DATETIME2(7) = SYSUTCDATETIME();
EXEC sec.usp_SetSessionContext @TenantId = $t, @SessionToken = 0x$(printf 'perf-%s-%s' "$t" "$i" | od -An -tx1 | tr -d ' \n');
SELECT CONCAT('B|', DATEDIFF_BIG(MICROSECOND, @t0, SYSUTCDATETIME()));" | tr -d '\r' | grep -a '^B|' >> "$TMP/bind.out"
done
python3 - "$TMP/bind.out" >> "$OUT" <<'PY'
import sys, statistics
us = sorted(int(l.split('|')[1]) for l in open(sys.argv[1]) if l.startswith('B|'))
q = lambda p: us[min(len(us) - 1, int(round(p * (len(us) - 1))))] / 1000
print(f'RESULT|B1|{len(us)}|{q(0.5):.2f}|{q(0.95):.2f}|{us[-1] / 1000:.2f}')
PY
tail -1 "$OUT"

# 3c. four writers of one tenant's audit chain at once, then the chain verified
cat > "$TMP/writer.sql" <<SQL
SET NOCOUNT ON;
DECLARE @token UNIQUEIDENTIFIER = NEWID(), @i INT = 0, @u BIGINT;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
INSERT sec.SessionBinding (SessionId, BoundTenantId, BoundUserId, BindingToken, BindingKind) VALUES (@@SPID, $t, 0, @token, 'USER');
EXEC sys.sp_set_session_context @key = N'TenantId', @value = $t;
EXEC sys.sp_set_session_context @key = N'BindingToken', @value = @token;
SET @u = (SELECT AppUserId FROM sec.AppUser WHERE TenantId = $t AND Email = N'fa@perf.invalid');   -- visible once bound
UPDATE sec.SessionBinding SET BoundUserId = @u WHERE SessionId = @@SPID;
EXEC sys.sp_set_session_context @key = N'UserId', @value = @u;
WHILE @i < $WRITES
BEGIN
    BEGIN TRANSACTION;
    EXEC aud.usp_WriteEvent @TenantId = $t, @Action = 'PERF_CONCURRENT', @Category = 'SYSTEM', @ActorType = 'USER', @ActorUserId = @u;
    COMMIT;
    SET @i += 1;
END;
DELETE FROM sec.SessionBinding WHERE SessionId = @@SPID;
SQL
t0=$(now_ms)
pids=()
for w in $(seq 1 "$WRITERS"); do sq -d BankFas -i "$TMP/writer.sql" > "$TMP/writer$w.out" 2>&1 & pids+=($!); done
for p in "${pids[@]}"; do wait "$p" || { cat "$TMP"/writer*.out; echo "a concurrent writer failed"; exit 1; }; done
ms=$(( $(now_ms) - t0 ))
log "RESULT|C1|$((WRITERS * WRITES))|$ms|$(( WRITERS * WRITES * 1000 / (ms > 0 ? ms : 1) ))"
log "INFO|C1|chain after the concurrent writers|$(sq -d BankFas -h -1 -W -Q "SET NOCOUNT ON; DECLARE @s VARCHAR(20), @b BIGINT, @n BIGINT;
EXEC aud.usp_VerifyAuditChain @JobKey = 'JOB-PLT-AUDIT-CHAIN', @ChainKey = $t, @Status = @s OUTPUT, @BadSeq = @b OUTPUT, @Rows = @n OUTPUT;
SELECT CONCAT(@n, ' ', @s);" | tr -d '\r' | tail -1)"

# 3d. the repeatable scripts on the loaded database: how long a deployment window holds the schema
t0=$(now_ms)
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/migrate.sh apply --repeatable > "$TMP/migrate.out" 2>&1 \
    || { cat "$TMP/migrate.out"; echo "the repeatable scripts failed on the loaded database"; exit 1; }
log "RESULT|D2|1|$(( $(now_ms) - t0 ))|$(( $(now_ms) - t0 ))|$(( $(now_ms) - t0 ))"
SQL_SERVER="$SQL_SERVER" SQL_USER=sa SQLCMD="$SQLCMD" bash tools/deploy/prepare_database.sh close >/dev/null
unset BANKFAS_CHANGE_REF
log "RUN|finished|$(date -u +%Y-%m-%dT%H:%M:%SZ)"

python3 tools/perf/perf_report.py "$OUT" "$REPORT"
