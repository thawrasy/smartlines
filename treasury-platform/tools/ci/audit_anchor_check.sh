#!/usr/bin/env bash
# The anchors of the audit hash chains kept outside the database (tools/deploy/audit_anchor.sh, 055; FR-PLT-025,
# DOC-S12 section 5.3, ADR 0033), on the database CI deployed. Prints one PASS or FAIL line per case, AA1-AA7. The
# store is a temporary folder here; in production it is a write-once bucket or WORM volume. The tool runs as the job
# worker does, with a login of tp_jobs only (internal review v6, B7), made here and dropped at the end. What a case
# changes in the platform chain is put back, except AA7, which plays a restore: the platform chain ends a few rows
# earlier, as after a restore of the database to an earlier time.
#
# Environment: as tools/ci/db_ci.sh (SQL_SERVER, SQLCMD, SQLCMDPASSWORD of sa, SQLCMD_OPTS=-C and the CI allowances).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/ci/ci_guard.sh
. "$ROOT/tools/ci/ci_guard.sh"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
TMP="$(mktemp -d)"
JOBS_PW="Aa1$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
cleanup() {
    "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -Q "IF EXISTS (SELECT 1 FROM BankFas.sys.database_principals WHERE name = N'ci_anchor_jobs') EXEC (N'USE BankFas; DROP USER ci_anchor_jobs;'); IF SUSER_ID(N'ci_anchor_jobs') IS NOT NULL DROP LOGIN ci_anchor_jobs;" >/dev/null 2>&1
    chmod -R u+w "$TMP"; rm -rf "$TMP"
}
trap cleanup EXIT
STORE="$TMP/store"
mkdir "$STORE"
SA_PW="$SQLCMDPASSWORD"
export SQL_SERVER SQLCMD

val() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1; }
sa_file() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -i "$1" >/dev/null; }
anchor() { SQL_USER=ci_anchor_jobs SQLCMDPASSWORD="$JOBS_PW" bash "$ROOT/tools/deploy/audit_anchor.sh" "$@" > "$TMP/a.out" 2>&1; rc=$?; [ -z "${AA_DEBUG:-}" ] || { echo "== anchor $*: $rc"; cat "$TMP/a.out"; }; }
result() { if [ "$1" = "1" ]; then echo "PASS $2"; else echo "FAIL $2 ($3)"; fi; }
files() { ls "$STORE" | grep -c '\.tsv$'; }
# a platform audit row changed past the row filter, and (with rehash) every hash of the chain and its head computed
# again, as an administrator of the database could
tamper() {   # SET clause, 1 to rehash
    cat > "$TMP/t.sql" <<SQL
SET NOCOUNT ON;
ALTER SECURITY POLICY rls.TP_aud_AuditLog WITH (STATE = OFF);
UPDATE aud.AuditLog SET $1 WHERE TenantId IS NULL AND ChainSeq = 1;
IF $2 = 1
BEGIN
    DECLARE @seq BIGINT = 1, @prev VARBINARY(32) = NULL, @hash VARBINARY(32), @id BIGINT;
    WHILE 1 = 1
    BEGIN
        SET @id = (SELECT AuditLogId FROM aud.AuditLog WHERE TenantId IS NULL AND ChainSeq = @seq);
        IF @id IS NULL BREAK;
        SELECT @hash = h.RowHash FROM aud.fn_AuditCanonical(@id) AS a CROSS APPLY aud.fn_AuditRowHash(@prev, @seq, a.Canonical) AS h;
        UPDATE aud.AuditLog SET PrevHash = @prev, RowHash = @hash WHERE AuditLogId = @id;
        SELECT @prev = @hash, @seq += 1;
    END;
    UPDATE aud.AuditChainHead SET LastSeq = @seq - 1, LastHash = @prev WHERE ChainKey = 0;
END;
ALTER SECURITY POLICY rls.TP_aud_AuditLog WITH (STATE = ON);
SQL
    sa_file "$TMP/t.sql"
}

# the job worker's login: tp_jobs only
cat > "$TMP/login.sql" <<SQL
SET NOCOUNT ON;
IF SUSER_ID(N'ci_anchor_jobs') IS NULL CREATE LOGIN ci_anchor_jobs WITH PASSWORD = N'$JOBS_PW', CHECK_POLICY = OFF, DEFAULT_DATABASE = BankFas;
GO
USE BankFas;
IF DATABASE_PRINCIPAL_ID(N'ci_anchor_jobs') IS NULL CREATE USER ci_anchor_jobs FOR LOGIN ci_anchor_jobs;
ALTER ROLE tp_jobs ADD MEMBER ci_anchor_jobs;
SQL
"$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -i "$TMP/login.sql" >/dev/null

# AA1: a folder without the store's mark is refused (a store not mounted, D12); take writes each run's anchors to a new
# read-only file of the store, with a name of its own even within one second (no sleep), and one line per chain that
# moved past the store: the run's own audit rows move the platform chain, so the second run anchors it again.
anchor take "$STORE"; r0=$rc; grep -q 'bankfas-anchor-store' "$TMP/a.out" || r0=x
touch "$STORE/.bankfas-anchor-store"
# On a fresh database the platform chain may hold no row yet: the first run then anchors nothing and writes no file,
# and its own audit row starts the chain. So three runs give two or three files, one platform line in each.
anchor take "$STORE"; r1=$rc
anchor take "$STORE"; r2=$rc
anchor take "$STORE"; r3=$rc; r2="$r2$r3"
lines="$(cat "$STORE"/anchors-*.tsv | grep -cE '^0	[0-9]+	[0-9A-F]{64}	')"
writable="$(find "$STORE" -name '*.tsv' -perm -u+w | wc -l)"
result "$([ "$r0/$r1/$r2" = "1/0/00" ] && [ "$(files)" -ge 2 ] && [ "$lines" = "$(files)" ] && [ "$writable" = "0" ] && echo 1)" \
    "AA1: audit_anchor.sh take refuses a folder that is not the store, and writes each run's anchors to a new read-only file" "exit $r0/$r1/$r2, files $(files), platform lines $lines, writable $writable"

# AA2: verify checks every chain against its latest anchor in the store and passes.
anchor verify "$STORE"; r1=$rc
result "$([ "$r1" = "0" ] && grep -q '^chain 0: OK' "$TMP/a.out" && ! grep -qv '^chain [0-9]*: OK' "$TMP/a.out" && echo 1)" \
    "AA2: audit_anchor.sh verify checks each chain against its latest anchor" "exit $r1: $(tr '\n' ' ' < "$TMP/a.out")"

# AA3: an administrator changes the first platform audit row, past the row filter, without computing hashes again. The
# daily check from the anchor reads only the anchor's row and after, so it passes (its known limit); the weekly full
# check fails (exit 1, BROKEN at 1); put back, the full check passes again.
tamper "Action = Action + 'X'" 0
anchor verify "$STORE"; r0=$rc
anchor verify "$STORE" --full; r1=$rc; grep -q '^chain 0: BROKEN (anchor [0-9]*; 1|' "$TMP/a.out" || r1=x
tamper "Action = LEFT(Action, LEN(Action) - 1)" 0
anchor verify "$STORE" --full; r2=$rc
result "$([ "$r0/$r1/$r2" = "0/1/0" ] && echo 1)" \
    "AA3: an old audit row changed without its hash passes the daily check, fails the full check, and passes once put back" "exit $r0/$r1/$r2: $(tr '\n' ' ' < "$TMP/a.out")"

# AA4: the same change with every hash and the head computed again: take checks the chain against the store first and
# refuses to anchor the rewritten chain (ANCHOR_MISMATCH), writing nothing; put back (the hashes come out as before),
# take anchors again (D1).
before="$(files)"
tamper "Action = Action + 'X'" 1
anchor take "$STORE"; r1=$rc; grep -q '^chain 0: ANCHOR_MISMATCH' "$TMP/a.out" || r1=x
mid="$(files)"
tamper "Action = LEFT(Action, LEN(Action) - 1)" 1
anchor take "$STORE"; r2=$rc
result "$([ "$r1/$r2" = "1/0" ] && [ "$mid" = "$before" ] && [ "$(files)" = "$((before + 1))" ] && echo 1)" \
    "AA4: a chain rewritten with every hash again is never anchored as it stands: take refuses and writes nothing" "exit $r1/$r2, files $before/$mid/$(files): $(tr '\n' ' ' < "$TMP/a.out" | cut -c1-300)"

# AA5: what moved is decided by the store, not by the database: a forged anchor row far ahead in aud.AuditChainAnchor
# does not stop the platform chain from being anchored (D2).
val "INSERT aud.AuditChainAnchor (ChainKey, ChainSeq, RowHash, StoreRef) VALUES (0, 999999999, 0x$(printf '0%.0s' $(seq 64)), N'forged'); SELECT 1;" >/dev/null
anchor take "$STORE"; r1=$rc; grep -q 'anchors: 1 written' "$TMP/a.out" || r1=x
val "DELETE FROM aud.AuditChainAnchor WHERE StoreRef = N'forged'; SELECT 1;" >/dev/null
result "$([ "$r1" = "0" ] && echo 1)" \
    "AA5: a forged anchor in the database does not stop a chain from being anchored: the store decides what moved" "exit $r1: $(tr '\n' ' ' < "$TMP/a.out")"

# AA6: a job that stops anchoring is itself an alarm: with a maximum age of 0 hours the platform chain, which moved past
# its latest anchor, is STALE; in an empty store every chain is NOT_ANCHORED (D2).
mkdir "$TMP/empty"; touch "$TMP/empty/.bankfas-anchor-store"
BANKFAS_ANCHOR_MAX_AGE_HOURS=0 anchor verify "$STORE"; r1=$rc; grep -q '^chain 0: STALE' "$TMP/a.out" || r1=x
BANKFAS_ANCHOR_MAX_AGE_HOURS=0 anchor verify "$TMP/empty"; r2=$rc; grep -q '^chain 0: NOT_ANCHORED' "$TMP/a.out" || r2=x
anchor verify "$TMP/empty"; r3=$rc
result "$([ "$r1/$r2/$r3" = "1/1/0" ] && echo 1)" \
    "AA6: a chain that moved past an anchor too old, or that has no anchor, fails the check" "exit $r1/$r2/$r3: $(tr '\n' ' ' < "$TMP/a.out" | cut -c1-300)"

# AA7: a restore of the database to an earlier time: the platform chain ends three rows before the latest anchor, so
# the check fails (ANCHOR_MISSING); "restored" checks every chain in full against the anchors up to its restored head,
# records the restored heads in a restore file with the change reference, and the chains verify again (D13).
anchor take "$STORE"
cut="$(val "SELECT LastSeq - 3 FROM aud.AuditChainHead WHERE ChainKey = 0;")"
cat > "$TMP/r.sql" <<SQL
SET NOCOUNT ON;
ALTER SECURITY POLICY rls.TP_aud_AuditLog WITH (STATE = OFF);
DELETE FROM aud.AuditLog WHERE TenantId IS NULL AND ChainSeq > $cut;
UPDATE aud.AuditChainHead SET LastSeq = $cut, LastHash = (SELECT RowHash FROM aud.AuditLog WHERE TenantId IS NULL AND ChainSeq = $cut) WHERE ChainKey = 0;
ALTER SECURITY POLICY rls.TP_aud_AuditLog WITH (STATE = ON);
SQL
sa_file "$TMP/r.sql"
anchor verify "$STORE"; r1=$rc; grep -q '^chain 0: ANCHOR_MISSING' "$TMP/a.out" || r1=x
anchor restored "$STORE" CI-restore; r2=$rc
restore_file="$(ls "$STORE" | grep -c '^restore-')"
anchor verify "$STORE" --full; r3=$rc
anchor take "$STORE"; r4=$rc
result "$([ "$r1/$r2/$r3/$r4" = "1/0/0/0" ] && [ "$restore_file" = "1" ] && grep -q 'CI-restore' "$STORE"/restore-*.tsv && echo 1)" \
    "AA7: after a restore the anchors past the restored heads fail the check until restored records the new heads" "exit $r1/$r2/$r3/$r4, restore files $restore_file: $(tr '\n' ' ' < "$TMP/a.out" | cut -c1-300)"
