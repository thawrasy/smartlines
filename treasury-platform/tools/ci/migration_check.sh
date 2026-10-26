#!/usr/bin/env bash
# The incremental schema changes (tools/deploy/migrate.sh, db/static/056_schema_fingerprint.sql; DOC-B11 section 6,
# ADR 0034), on the database CI has just deployed with deploy.sh. Prints one PASS or FAIL line per case, MG1-MG12.
# migrate.sh runs as in production (internal review v6, B7): as bankfas_migrator, inside a deployment window that the
# administrator opens (prepare_database.sh open, after a full backup) and closes. Every change made here is removed at
# the end: the probe tables, users and triggers, and the journal rows after the first repeatable run.
#
# Environment: as tools/ci/db_ci.sh (SQL_SERVER, SQLCMD, SQLCMDPASSWORD of sa, SQLCMD_OPTS=-C and the CI allowances),
# and MIGRATOR_SECRET, the secret file of bankfas_migrator that step 4 made.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# shellcheck source=tools/ci/ci_guard.sh
. "$ROOT/tools/ci/ci_guard.sh"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
: "${MIGRATOR_SECRET:?set MIGRATOR_SECRET to the secret file of bankfas_migrator}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SQL_SERVER SQLCMD BANKFAS_MIGRATIONS="$TMP/migrations" BANKFAS_CHANGE_REF=CI-migration
mkdir "$BANKFAS_MIGRATIONS"
SA_PW="$SQLCMDPASSWORD"
# The real versioned scripts of db/migrations are in the folder too, as deploy.sh journaled them at the baseline; the
# probes of this check are numbered after them, from V9000 on. RJ is the real ones' part of a journal, NR their count.
cp "$ROOT"/db/migrations/V*.sql "$BANKFAS_MIGRATIONS"/ 2>/dev/null || true
REAL=(); for f in "$BANKFAS_MIGRATIONS"/V*.sql; do [ -e "$f" ] && REAL+=("$(basename "$f" | cut -c1-5)"); done
NR=${#REAL[@]}; RJ=""; RB=""
for v in "${REAL[@]}"; do RJ+=",$v"; RB+=",$v:VERSIONED:baseline"; done

val() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1; }
migrate() { SQL_USER=bankfas_migrator SQLCMDPASSWORD="$(cat "$MIGRATOR_SECRET")" bash "$ROOT/tools/deploy/migrate.sh" "$@" > "$TMP/m.out" 2>&1; rc=$?; }
admin() { SQL_USER=sa SQLCMDPASSWORD="$SA_PW" bash "$ROOT/tools/deploy/prepare_database.sh" "$@" > "$TMP/p.out" 2>&1; rc=$?; }
fp() { val "SELECT CONVERT(CHAR(64), Fingerprint, 2) FROM plat.fn_SchemaFingerprint();"; }
journal() { val "SELECT CONCAT(COUNT(*), ':', STRING_AGG(Version, ',') WITHIN GROUP (ORDER BY SchemaMigrationId)) FROM plat.SchemaMigration;"; }
result() { if [ "$1" = "1" ]; then echo "PASS $2"; else echo "FAIL $2 ($3)"; fi; }

# MG1: deploy.sh journaled the new database: its BASELINE and the first run R of the repeatable scripts, with the
# fingerprint the schema has (after the service logins and the tests, which the fingerprint leaves out or undid), and
# the change reference of the run.
base_fp="$(fp)"
j="$(journal)"
jfp="$(val "SELECT CONCAT(MIN(CONVERT(CHAR(64), Fingerprint, 2)), '/', MAX(CONVERT(CHAR(64), Fingerprint, 2)), '/', MIN(ChangeRef)) FROM plat.SchemaMigration;")"
result "$([ "$j" = "$((2 + NR)):BASELINE$RJ,R" ] && [ "$jfp" = "$base_fp/$base_fp/CI" ] && echo 1)" \
    "MG1: deploy.sh journals the new database (BASELINE and R) with the schema's fingerprint and its change" "journal $j, fingerprints $jfp, schema $base_fp"
keep_id="$(val "SELECT MAX(SchemaMigrationId) FROM plat.SchemaMigration;")"

# MG8: the window of an upgrade opens only after a full backup (50153; with a maximum age of 0 hours none is recent
# enough, the backup of step 20 included); sa, a sysadmin, is refused by migrate.sh's
# server gate (50140); without the window the deployment login cannot connect at all.
BANKFAS_BACKUP_MAX_AGE_HOURS=0 admin open; o1=$rc; grep -q '50153' "$TMP/p.out" || o1=x
migrate status; s0=$rc
SQL_USER=sa SQLCMDPASSWORD="$SA_PW" bash "$ROOT/tools/deploy/migrate.sh" apply > "$TMP/sa.out" 2>&1; s1=$?; grep -q '50140' "$TMP/sa.out" || s1=x
val "BACKUP DATABASE [BankFas] TO DISK = N'/var/opt/mssql/data/ci-migration.bak' WITH COPY_ONLY, INIT, FORMAT; SELECT 1;" >/dev/null
admin open; o2=$rc
result "$([ "$o1/$s0/$s1/$o2" = "1/1/1/0" ] && echo 1)" \
    "MG8: the window opens only after a full backup, migrate.sh refuses sa, and outside the window the deployment login cannot connect" \
    "open without backup $o1, status outside $s0, sa $s1, open after backup $o2: $(tr '\n' ' ' < "$TMP/p.out" | cut -c1-300)"

# MG2: with nothing pending, apply changes nothing; status reports no problem and exits 0.
migrate apply; rc1=$rc
migrate status; rc2=$rc; st="$(cat "$TMP/m.out")"
result "$([ "$rc1/$rc2" = "0/0" ] && [ "$(journal)" = "$((2 + NR)):BASELINE$RJ,R" ] && ! grep -q '^problem\|^pending' <<<"$st" && echo 1)" \
    "MG2: apply with nothing pending changes nothing, and status reports no problem" "rc $rc1/$rc2, journal $(journal): $(tr '\n' ' ' <<<"$st" | cut -c1-300)"

# MG3: the repeatable scripts run again on the deployed database, in one transaction, and leave the fingerprint as it
# was: row filters, grants, procedures and triggers can be brought up to date on any version.
migrate apply --repeatable; rc1=$rc
after="$(fp)"
result "$([ "$rc1" = "0" ] && [ "$after" = "$base_fp" ] && [ "$(journal)" = "$((3 + NR)):BASELINE$RJ,R,R" ] && echo 1)" \
    "MG3: the repeatable scripts run again on a deployed database and leave its fingerprint unchanged" "rc $rc1, fingerprint $after, journal $(journal): $(tail -5 "$TMP/m.out" | tr '\n' ' ')"
keep_id="$(val "SELECT MAX(SchemaMigrationId) FROM plat.SchemaMigration;")"

# MG4: a versioned script applies once, with its journal row, and changes the fingerprint; applied again, nothing.
cat > "$BANKFAS_MIGRATIONS/V9001__probe.sql" <<'SQL'
CREATE TABLE plat.MigrationProbe (MigrationProbeId INT NOT NULL CONSTRAINT PK_MigrationProbe PRIMARY KEY);
GO
INSERT plat.MigrationProbe (MigrationProbeId) VALUES (1);
SQL
migrate apply; rc1=$rc; fp1="$(fp)"; j1="$(journal)"
migrate apply; rc2=$rc; j2="$(journal)"
rows="$(val "SELECT COUNT(*) FROM plat.MigrationProbe;")"
jv="$(val "SELECT CONCAT(Kind, '/', ScriptName, '/', ChangeRef, '/', CASE WHEN Fingerprint = (SELECT Fingerprint FROM plat.fn_SchemaFingerprint()) THEN 'current' END) FROM plat.SchemaMigration WHERE Version = 'V9001';")"
result "$([ "$rc1" = "0" ] && [ "$rc2" = "0" ] && [ "$fp1" != "$base_fp" ] && [ "$j1" = "$((5 + NR)):BASELINE$RJ,R,R,V9001,R" ] && [ "$j2" = "$j1" ] && [ "$rows" = "1" ] && [ "$jv" = "VERSIONED/V9001__probe.sql/CI-migration/current" ] && echo 1)" \
    "MG4: a versioned script applies once with its journal row and the new fingerprint, then the repeatable scripts" "rc $rc1/$rc2, journal $j1 then $j2, rows $rows, $jv"

# MG9: the last run of the journal is a versioned script (its repeatable run failed before): the next apply runs the
# repeatable scripts again, though nothing is pending and they did not change (D4).
val "DELETE FROM plat.SchemaMigration WHERE SchemaMigrationId = (SELECT MAX(SchemaMigrationId) FROM plat.SchemaMigration); SELECT 1;" >/dev/null
migrate apply; rc1=$rc
result "$([ "$rc1" = "0" ] && [ "$(journal)" = "$((5 + NR)):BASELINE$RJ,R,R,V9001,R" ] && grep -q 'ran the repeatable scripts' "$TMP/m.out" && echo 1)" \
    "MG9: a repeatable run that failed after a versioned script is taken up again by the next apply" "rc $rc1, journal $(journal)"

# MG5: refused, with nothing changed: an applied script edited or removed, a new script numbered before an applied one,
# two scripts with one version, a file that is not a versioned script, and a script that ends or opens a transaction or
# holds a sqlcmd command (D5, B8).
before="$(journal)"
echo "-- edited" >> "$BANKFAS_MIGRATIONS/V9001__probe.sql"; migrate apply; e1=$rc; grep -q 'changed after it was applied' "$TMP/m.out" || e1=x
sed -i '$d' "$BANKFAS_MIGRATIONS/V9001__probe.sql"
echo "SELECT 1;" > "$BANKFAS_MIGRATIONS/V9000__early.sql"; migrate apply; e2=$rc; grep -q 'sorts before V9001' "$TMP/m.out" || e2=x
rm "$BANKFAS_MIGRATIONS/V9000__early.sql"
echo "SELECT 1;" > "$BANKFAS_MIGRATIONS/fix.sql"; migrate apply; e3=$rc; grep -q 'is named Vnnnn__description.sql' "$TMP/m.out" || e3=x
rm "$BANKFAS_MIGRATIONS/fix.sql"
mv "$BANKFAS_MIGRATIONS/V9001__probe.sql" "$TMP/V9001__probe.sql"; migrate apply; e4=$rc; grep -q 'V9001 is applied but its script is no longer' "$TMP/m.out" || e4=x
mv "$TMP/V9001__probe.sql" "$BANKFAS_MIGRATIONS/"
echo "SELECT 1;" > "$BANKFAS_MIGRATIONS/V9003__one.sql"; echo "SELECT 2;" > "$BANKFAS_MIGRATIONS/V9003__two.sql"
migrate apply; e5=$rc; grep -q 'have the version V9003' "$TMP/m.out" || e5=x
rm "$BANKFAS_MIGRATIONS"/V9003__*.sql
n=0
for body in "COMMIT;" "  rollback transaction" "BEGIN TRAN;" "save transaction s1;" ":r other.sql" "!! ls"; do
    printf 'CREATE TABLE plat.MigrationProbeThree (Id INT NOT NULL);\nGO\n%s\nGO\n' "$body" > "$BANKFAS_MIGRATIONS/V9002__control.sql"
    migrate apply; [ "$rc" = "1" ] && grep -q 'ends or opens a transaction, or is a sqlcmd command' "$TMP/m.out" && n=$((n + 1))
done
rm "$BANKFAS_MIGRATIONS/V9002__control.sql"
left="$(val "SELECT CASE WHEN OBJECT_ID(N'plat.MigrationProbeThree') IS NULL THEN 'none' ELSE 'left' END;")"
result "$([ "$e1/$e2/$e3/$e4/$e5/$n/$left" = "1/1/1/1/1/6/none" ] && [ "$(journal)" = "$before" ] && echo 1)" \
    "MG5: edited, removed, early, duplicate and misnamed scripts, and scripts with transaction or sqlcmd control lines, are refused" \
    "exit codes $e1/$e2/$e3/$e4/$e5, control lines refused $n of 6, probe $left, journal $(journal)"

# MG6: a script that fails part way leaves nothing: its table and its journal row roll back together, and the failure
# is the script's own (divide by zero, 8134).
cat > "$BANKFAS_MIGRATIONS/V9002__fails.sql" <<'SQL'
CREATE TABLE plat.MigrationProbeTwo (MigrationProbeTwoId INT NOT NULL CONSTRAINT PK_MigrationProbeTwo PRIMARY KEY);
GO
SELECT 1 / 0;
SQL
migrate apply; e1=$rc; grep -q 'Msg 8134' "$TMP/m.out" || e1=x
gone="$(val "SELECT CONCAT(CASE WHEN OBJECT_ID(N'plat.MigrationProbeTwo') IS NULL THEN 'no table' END, '/', (SELECT COUNT(*) FROM plat.SchemaMigration WHERE Version = 'V9002'), '/', (SELECT MAX(Version) FROM plat.SchemaMigration WHERE Kind = 'VERSIONED'));")"
rm "$BANKFAS_MIGRATIONS/V9002__fails.sql"
result "$([ "$e1" = "1" ] && [ "$gone" = "no table/0/V9001" ] && echo 1)" \
    "MG6: a versioned script that fails rolls back with its journal row" "exit $e1, $gone: $(grep -m1 'Msg' "$TMP/m.out")"

# MG7: a change made outside the journal stops the next apply, and status names it and exits 1: a table, a member added
# to db_owner, a grant to a user, a database DDL trigger (A10, B6, B21). Each one undone, apply runs again.
n=0 st=0
for probe in "CREATE TABLE plat.DriftProbe (DriftProbeId INT NOT NULL);|DROP TABLE plat.DriftProbe;" \
             "CREATE USER mg_drift WITHOUT LOGIN; ALTER ROLE db_owner ADD MEMBER mg_drift;|ALTER ROLE db_owner DROP MEMBER mg_drift; DROP USER mg_drift;" \
             "CREATE USER mg_drift WITHOUT LOGIN; GRANT SELECT ON plat.Tenant TO mg_drift;|DROP USER mg_drift;" \
             "EXEC (N'CREATE TRIGGER mg_drift ON DATABASE FOR CREATE_TABLE AS RETURN;');|DROP TRIGGER mg_drift ON DATABASE;"; do
    val "${probe%%|*} SELECT 1;" >/dev/null
    migrate apply; e1=$rc; grep -q 'changed outside the journal' "$TMP/m.out" || e1=x
    migrate status; e2=$rc; grep -q '^problem.*outside the journal' "$TMP/m.out" || e2=x
    val "${probe#*|} SELECT 1;" >/dev/null
    migrate status; e3=$rc
    [ "$e1/$e2/$e3" = "1/1/0" ] && n=$((n + 1)) || st="$st ${probe%% *}:$e1/$e2/$e3"
done
result "$([ "$n" = "4" ] && echo 1)" \
    "MG7: a table, a member of db_owner, a grant to a user or a DDL trigger made outside the journal stops apply, and status exits 1" "caught $n of 4:$st"

# MG10: the baseline of a new database journals the versioned scripts present as applied (the database was built from
# the model they lead to, D3); without a baseline apply is refused; baseline runs only from deploy.sh (D17). The
# journal is put back as it was.
val "IF OBJECT_ID(N'tempdb..mg_journal') IS NOT NULL DROP TABLE tempdb..mg_journal; SELECT * INTO tempdb..mg_journal FROM plat.SchemaMigration; DELETE FROM plat.SchemaMigration; SELECT 1;" >/dev/null
migrate apply; b0=$rc; grep -q 'no BASELINE' "$TMP/m.out" || b0=x
migrate baseline; b1=$rc
migrate baseline --after-deploy; b2=$rc
jb="$(val "SELECT CONCAT(STRING_AGG(CONCAT(Version, ':', Kind, ':', LEFT(AppliedBy, 8)), ',') WITHIN GROUP (ORDER BY SchemaMigrationId), '/', MIN(ChangeRef)) FROM plat.SchemaMigration;")"
val "DELETE FROM plat.SchemaMigration; SET IDENTITY_INSERT plat.SchemaMigration ON;
INSERT plat.SchemaMigration (SchemaMigrationId, Version, Kind, ScriptName, Checksum, Fingerprint, AppliedAt, AppliedBy, DurationMs, ChangeRef)
SELECT SchemaMigrationId, Version, Kind, ScriptName, Checksum, Fingerprint, AppliedAt, AppliedBy, DurationMs, ChangeRef FROM tempdb..mg_journal;
SET IDENTITY_INSERT plat.SchemaMigration OFF; DROP TABLE tempdb..mg_journal; SELECT 1;" >/dev/null
result "$([ "$b0/$b1/$b2" = "1/1/0" ] && [ "$jb" = "BASELINE:BASELINE:bankfas_$RB,V9001:VERSIONED:baseline,R:REPEATABLE:bankfas_/CI-migration" ] && echo 1)" \
    "MG10: a baseline journals the versioned scripts present; apply without a baseline and a baseline outside deploy.sh are refused" "exit codes $b0/$b1/$b2, journal $jb"

# MG11: a run without the change reference is refused before it connects (D7).
env -u BANKFAS_CHANGE_REF SQL_USER=bankfas_migrator SQLCMDPASSWORD="$(cat "$MIGRATOR_SECRET")" bash "$ROOT/tools/deploy/migrate.sh" apply > "$TMP/c.out" 2>&1; c1=$?
result "$([ "$c1" = "1" ] && grep -q 'BANKFAS_CHANGE_REF' "$TMP/c.out" && echo 1)" \
    "MG11: apply without BANKFAS_CHANGE_REF is refused" "exit $c1: $(cat "$TMP/c.out")"

# Clean-up: the probe table, and the journal rows after MG3; the database is as deploy.sh left it; the window closes.
val "DROP TABLE IF EXISTS plat.MigrationProbe; DELETE FROM plat.SchemaMigration WHERE SchemaMigrationId > $keep_id; SELECT 1;" >/dev/null
rm -f "$BANKFAS_MIGRATIONS"/V9*.sql
migrate status; s1=$rc
admin close; c2=$rc
# MG12: after the clean-up the schema has its deployed fingerprint, status is clean, and the window closes.
result "$([ "$(fp)" = "$base_fp" ] && [ "$s1/$c2" = "0/0" ] && echo 1)" \
    "MG12: the clean-up brings the database back to its deployed fingerprint, and the window closes" "fingerprint $(fp), status $s1, close $c2"
