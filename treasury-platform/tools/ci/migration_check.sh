#!/usr/bin/env bash
# The incremental schema changes (tools/deploy/migrate.sh, db/static/056_schema_fingerprint.sql; DOC-B11 section 6,
# ADR 0034), on the database CI has just deployed with deploy.sh. Prints one PASS or FAIL line per case, MG1-MG7.
# Every change made here is removed at the end: the probe tables, and the journal rows after the first repeatable run.
#
# Environment: as tools/ci/db_ci.sh (SQL_SERVER, SQLCMD, SQLCMDPASSWORD of sa, SQLCMD_OPTS=-C and the CI allowances).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQLCMD="${SQLCMD:-sqlcmd}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export SQL_SERVER SQLCMD SQL_USER=sa BANKFAS_MIGRATIONS="$TMP/migrations"
mkdir "$BANKFAS_MIGRATIONS"

val() { "$SQLCMD" -S "$SQL_SERVER" -U sa -C -I -b -d BankFas -h -1 -W -Q "SET NOCOUNT ON; $1" | tr -d '\r' | sed '/^[[:space:]]*$/d' | tail -1; }
migrate() { bash "$ROOT/tools/deploy/migrate.sh" "$@" > "$TMP/m.out" 2>&1; rc=$?; }
fp() { val "SELECT CONVERT(CHAR(64), Fingerprint, 2) FROM plat.fn_SchemaFingerprint();"; }
journal() { val "SELECT CONCAT(COUNT(*), ':', STRING_AGG(Version, ',') WITHIN GROUP (ORDER BY SchemaMigrationId)) FROM plat.SchemaMigration;"; }
result() { if [ "$1" = "1" ]; then echo "PASS $2"; else echo "FAIL $2 ($3)"; fi; }

# MG1: deploy.sh journaled the new database: its BASELINE and the first run R of the repeatable scripts, with the
# fingerprint the schema has.
base_fp="$(fp)"
j="$(journal)"
jfp="$(val "SELECT CONCAT(MIN(CONVERT(CHAR(64), Fingerprint, 2)), '/', MAX(CONVERT(CHAR(64), Fingerprint, 2))) FROM plat.SchemaMigration;")"
result "$([ "$j" = "2:BASELINE,R" ] && [ "$jfp" = "$base_fp/$base_fp" ] && echo 1)" \
    "MG1: deploy.sh journals the new database (BASELINE and R) with the schema's fingerprint" "journal $j, fingerprints $jfp, schema $base_fp"
keep_id="$(val "SELECT MAX(SchemaMigrationId) FROM plat.SchemaMigration;")"

# MG2: with nothing pending, apply changes nothing; status reports no problem.
migrate apply; rc1=$rc
migrate status; st="$(cat "$TMP/m.out")"
result "$([ "$rc1" = "0" ] && [ "$(journal)" = "2:BASELINE,R" ] && ! grep -q '^problem\|^pending' <<<"$st" && echo 1)" \
    "MG2: apply with nothing pending changes nothing, and status reports no problem" "rc $rc1, journal $(journal)"

# MG3: the repeatable scripts run again on the deployed database, in one transaction, and leave the fingerprint as it
# was: row filters, grants, procedures and triggers can be brought up to date on any version.
migrate apply --repeatable; rc1=$rc
after="$(fp)"
result "$([ "$rc1" = "0" ] && [ "$after" = "$base_fp" ] && [ "$(journal)" = "3:BASELINE,R,R" ] && echo 1)" \
    "MG3: the repeatable scripts run again on a deployed database and leave its fingerprint unchanged" "rc $rc1, fingerprint $after, journal $(journal)"
keep_id="$(val "SELECT MAX(SchemaMigrationId) FROM plat.SchemaMigration;")"

# MG4: a versioned script applies once, with its journal row, and changes the fingerprint; applied again, nothing.
cat > "$BANKFAS_MIGRATIONS/V0001__probe.sql" <<'SQL'
CREATE TABLE plat.MigrationProbe (MigrationProbeId INT NOT NULL CONSTRAINT PK_MigrationProbe PRIMARY KEY);
GO
INSERT plat.MigrationProbe (MigrationProbeId) VALUES (1);
SQL
migrate apply; rc1=$rc; fp1="$(fp)"; j1="$(journal)"
migrate apply; rc2=$rc; j2="$(journal)"
rows="$(val "SELECT COUNT(*) FROM plat.MigrationProbe;")"
jv="$(val "SELECT CONCAT(Kind, '/', ScriptName, '/', CASE WHEN Fingerprint = (SELECT Fingerprint FROM plat.fn_SchemaFingerprint()) THEN 'current' END) FROM plat.SchemaMigration WHERE Version = 'V0001';")"
result "$([ "$rc1" = "0" ] && [ "$rc2" = "0" ] && [ "$fp1" != "$base_fp" ] && [ "$j1" = "5:BASELINE,R,R,V0001,R" ] && [ "$j2" = "$j1" ] && [ "$rows" = "1" ] && [ "$jv" = "VERSIONED/V0001__probe.sql/current" ] && echo 1)" \
    "MG4: a versioned script applies once with its journal row and the new fingerprint, then the repeatable scripts" "rc $rc1/$rc2, journal $j1 then $j2, rows $rows, $jv"

# MG5: refused, with nothing changed: an applied script edited, a new script numbered before an applied one, a file
# that is not a versioned script.
before="$(journal)"
echo "-- edited" >> "$BANKFAS_MIGRATIONS/V0001__probe.sql"; migrate apply; e1=$rc; grep -q 'changed after it was applied' "$TMP/m.out" || e1=x
sed -i '$d' "$BANKFAS_MIGRATIONS/V0001__probe.sql"
echo "SELECT 1;" > "$BANKFAS_MIGRATIONS/V0000__early.sql"; migrate apply; e2=$rc; grep -q 'sorts before V0001' "$TMP/m.out" || e2=x
rm "$BANKFAS_MIGRATIONS/V0000__early.sql"
echo "SELECT 1;" > "$BANKFAS_MIGRATIONS/fix.sql"; migrate apply; e3=$rc; grep -q 'is named Vnnnn__description.sql' "$TMP/m.out" || e3=x
rm "$BANKFAS_MIGRATIONS/fix.sql"
result "$([ "$e1/$e2/$e3" = "1/1/1" ] && [ "$(journal)" = "$before" ] && echo 1)" \
    "MG5: an applied script that was edited, a script numbered before an applied one, and a misnamed file are refused" "exit codes $e1/$e2/$e3, journal $(journal)"

# MG6: a script that fails part way leaves nothing: its table and its journal row roll back together.
cat > "$BANKFAS_MIGRATIONS/V0002__fails.sql" <<'SQL'
CREATE TABLE plat.MigrationProbeTwo (MigrationProbeTwoId INT NOT NULL CONSTRAINT PK_MigrationProbeTwo PRIMARY KEY);
GO
SELECT 1 / 0;
SQL
migrate apply; e1=$rc
gone="$(val "SELECT CONCAT(CASE WHEN OBJECT_ID(N'plat.MigrationProbeTwo') IS NULL THEN 'no table' END, '/', (SELECT COUNT(*) FROM plat.SchemaMigration WHERE Version = 'V0002'));")"
rm "$BANKFAS_MIGRATIONS/V0002__fails.sql"
result "$([ "$e1" != "0" ] && [ "$gone" = "no table/0" ] && echo 1)" \
    "MG6: a versioned script that fails rolls back with its journal row" "exit $e1, $gone"

# MG7: a change made outside the journal stops the next apply, and status names it.
val "CREATE TABLE plat.DriftProbe (DriftProbeId INT NOT NULL); SELECT 1;" >/dev/null
migrate apply; e1=$rc; grep -q 'changed outside the journal' "$TMP/m.out" || e1=x
migrate status; grep -q '^problem.*outside the journal' "$TMP/m.out"; e2=$?
val "DROP TABLE plat.DriftProbe; SELECT 1;" >/dev/null
migrate apply; e3=$rc
result "$([ "$e1/$e2/$e3" = "1/0/0" ] && echo 1)" \
    "MG7: a schema change outside the journal stops apply until it is undone" "exit codes $e1/$e2/$e3"

# Clean-up: the probe table, and the journal rows after MG3; the database is as deploy.sh left it.
val "DROP TABLE IF EXISTS plat.MigrationProbe; DELETE FROM plat.SchemaMigration WHERE SchemaMigrationId > $keep_id; SELECT 1;" >/dev/null
rm -f "$BANKFAS_MIGRATIONS"/*.sql
migrate status
if [ "$(fp)" != "$base_fp" ] || grep -q '^problem' "$TMP/m.out"; then
    echo "FAIL MG7: the clean-up did not bring the database back to its deployed fingerprint"
fi
