#!/usr/bin/env bash
# The anchors of the audit hash chains kept outside the database (tools/deploy/audit_anchor.sh, 055; FR-PLT-025,
# DOC-S12 section 5.3, ADR 0033), on the database CI deployed. Prints one PASS or FAIL line per case, AA1-AA3. The
# store is a temporary folder here; in production it is a write-once bucket or WORM volume. The one audit row changed
# in AA3 is put back as it was.
#
# Environment: as tools/ci/db_ci.sh (SQL_SERVER, SQLCMD, SQLCMDPASSWORD of sa, SQLCMD_OPTS=-C and the CI allowances).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
TMP="$(mktemp -d)"
trap 'chmod -R u+w "$TMP"; rm -rf "$TMP"' EXIT
STORE="$TMP/store"
mkdir "$STORE"
export SQL_SERVER SQLCMD SQL_USER=sa

val() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1; }
anchor() { bash "$ROOT/tools/deploy/audit_anchor.sh" "$@" > "$TMP/a.out" 2>&1; rc=$?; }
result() { if [ "$1" = "1" ]; then echo "PASS $2"; else echo "FAIL $2 ($3)"; fi; }

# AA1: take writes a new read-only file per run, with one line per chain that moved; the run's own audit row moves the
# platform chain, so the second run anchors it again.
anchor take "$STORE"; r1=$rc
sleep 1
anchor take "$STORE"; r2=$rc
files="$(ls "$STORE" | wc -l)"
lines="$(cat "$STORE"/anchors-*.tsv | grep -cE '^0	[0-9]+	[0-9A-F]{64}	')"
writable="$(find "$STORE" -type f -perm -u+w | wc -l)"
result "$([ "$r1/$r2" = "0/0" ] && [ "$files" = "2" ] && [ "$lines" -ge 1 ] && [ "$writable" = "0" ] && echo 1)" \
    "AA1: audit_anchor.sh take writes each run's anchors to a new read-only file of the store" "exit $r1/$r2, files $files, platform lines $lines, writable $writable"

# AA2: verify checks every chain of the store against its latest anchor and passes.
anchor verify "$STORE"; r1=$rc
result "$([ "$r1" = "0" ] && grep -q '^chain 0: OK' "$TMP/a.out" && echo 1)" \
    "AA2: audit_anchor.sh verify checks each chain against its latest anchor" "exit $r1: $(tr '\n' ' ' < "$TMP/a.out")"

# AA3: an administrator changes the first platform audit row, past the row filter, without computing hashes again. The
# daily check from the anchor reads only the anchor's row and after, so it passes (its known limit); the weekly full
# check fails (exit 1, BROKEN at 1); put back, the full check passes again.
# A new anchor first: on a fresh database the platform chain is short, and row 1 must lie before the latest anchor.
sleep 1
anchor take "$STORE"
cat > "$TMP/tamper.sql" <<'SQL'
SET NOCOUNT ON;
ALTER SECURITY POLICY rls.TP_aud_AuditLog WITH (STATE = OFF);
UPDATE aud.AuditLog SET Action = Action + 'X' WHERE TenantId IS NULL AND ChainSeq = 1;
ALTER SECURITY POLICY rls.TP_aud_AuditLog WITH (STATE = ON);
SQL
"$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -i "$TMP/tamper.sql" >/dev/null
anchor verify "$STORE"; r0=$rc
anchor verify "$STORE" --full; r1=$rc; grep -q '^chain 0: BROKEN (anchor [0-9]*; 1|' "$TMP/a.out" || r1=x
sed "s/SET Action = Action + 'X'/SET Action = LEFT(Action, LEN(Action) - 1)/" "$TMP/tamper.sql" > "$TMP/restore.sql"
"$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -i "$TMP/restore.sql" >/dev/null
anchor verify "$STORE" --full; r2=$rc
result "$([ "$r0/$r1/$r2" = "0/1/0" ] && echo 1)" \
    "AA3: an old audit row changed without its hash passes the daily check, fails the full check, and passes once put back" "exit $r0/$r1/$r2: $(tr '\n' ' ' < "$TMP/a.out")"
