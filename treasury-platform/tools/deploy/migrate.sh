#!/usr/bin/env bash
# Incremental schema changes for a deployed BankFas (DOC-B11 section 6, ADR 0034). db/deploy.sql builds an empty
# database only (the preflight refuses one that holds tables, 50142); every later release reaches a deployed
# database through this script, as the deployment login, inside the deployment window (prepare_database.sh open ...
# close), the same way deploy.sh does.
#
#   migrate.sh baseline --after-deploy
#                                 after deploy.sh, on the new database (only deploy.sh calls it): journals the
#                                 deployment bundle as BASELINE, the versioned scripts of db/migrations as applied (the
#                                 new database was built from the model they lead to; internal review v6, D3), and the
#                                 repeatable scripts as their first run R.
#   migrate.sh status             the journal, the versioned scripts not yet applied, whether the repeatable scripts
#                                 changed, and whether the schema still has the fingerprint the journal holds; exit
#                                 code 1 when a problem is listed (B21).
#   migrate.sh apply [--repeatable]
#                                 applies each versioned script of db/migrations not yet applied, in order, each in
#                                 one transaction with its journal row; then runs the repeatable scripts again, in one
#                                 transaction, when a versioned script ran, when they changed, when the last run of
#                                 the journal is a versioned script (a run of them that failed before is taken up
#                                 again, D4), or with --repeatable.
#
# Before baseline and apply: the server gate of deploy.sh (db/ops/server_gate.sql: never sa, a sysadmin or a holder of
# a server-wide right, 50140; the release register, 50143; nested triggers on, 50150; D6), and BANKFAS_CHANGE_REF, the
# change of the run, which the journal records. The administrator's prepare_database.sh open checks the rest of the
# window: the server audit running, no session of a service login (the application stopped), and a full backup of the
# database within BANKFAS_BACKUP_MAX_AGE_HOURS (D7, D14).
# Refusals (exit code 1, nothing changed): no BASELINE in the journal; the schema's fingerprint is not the journal's
# (someone changed the schema outside it; checked again inside each script's transaction, D17); a script already
# applied was edited or removed; a new script sorts before one already applied; a file of db/migrations is not named
# Vnnnn__description.sql; a versioned script holds a line that ends or opens a transaction (COMMIT, ROLLBACK, BEGIN
# TRAN, SAVE TRAN) or a sqlcmd command (:r, :setvar, !! and the rest), which would escape the transaction of its
# journal row (D5, B8). A script that fails rolls back with its journal row (XACT_ABORT, and sqlcmd closes the session
# on the first error).
#
# The repeatable scripts are the lines of db/deploy.sql from generated/tsql/004_rls_tables.sql on: row filters,
# grants, procedures, functions, views and triggers, all of which can run again on any version (CI checks that a
# second run leaves the fingerprint unchanged, step 4c). A versioned script changes what they cannot: tables,
# columns, keys, indexes, and data that has to move with them.
#
# Environment: as deploy.sh (SQL_SERVER, SQL_USER default bankfas_migrator, SQLCMDPASSWORD, SQLCMD, SQLCMD_OPTS,
# BANKFAS_VERSIONS), BANKFAS_CHANGE_REF, and BANKFAS_MIGRATIONS, the folder of the versioned scripts, default
# db/migrations.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
DB_DIR="$(cd "$HERE/../../db" && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-bankfas_migrator}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
MIGRATIONS="${BANKFAS_MIGRATIONS:-$DB_DIR/migrations}"
# shellcheck source=tools/deploy/preflight.sh
. "$HERE/preflight.sh"

cmd="${1:-}"
force_repeatable=0
usage="usage: migrate.sh status | apply [--repeatable] (baseline --after-deploy is deploy.sh's)"
case "$cmd" in
    baseline) [ $# -eq 2 ] && [ "$2" = "--after-deploy" ] \
                  || bankfas_refuse "baseline journals a database deploy.sh has just built, and only deploy.sh runs it (D17)" ;;
    status) [ $# -eq 1 ] || bankfas_refuse "$usage" ;;
    apply) [ $# -eq 1 ] || { [ $# -eq 2 ] && [ "$2" = "--repeatable" ] && force_repeatable=1; } || bankfas_refuse "$usage" ;;
    *) bankfas_refuse "$usage" ;;
esac
change_ref=""
if [ "$cmd" != "status" ]; then
    change_ref="${BANKFAS_CHANGE_REF:-}"
    [[ "$change_ref" =~ ^[A-Za-z0-9._/-]{2,60}$ ]] \
        || bankfas_refuse "set BANKFAS_CHANGE_REF to the change of this run (2 to 60 letters, digits, . _ / -): the journal records it (D7)"
fi
if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sq() { "$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -d BankFas -I -b $SQLCMD_OPTS "$@"; }
# One value or a list of lines from a query; the query is read from a file, so its length does not matter.
query() {
    { sa_guard_sql; printf 'SET NOCOUNT ON;\n%s\n' "$1"; } > "$WORK/q.sql"
    sq -h -1 -W -i "$WORK/q.sql" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}
# The files of db/deploy.sql: all of them for the baseline, from 004 on for the repeatable scripts.
deploy_files() { sed -n 's/^:r \([^[:space:]]*\.sql\)[[:space:]]*$/\1/p' "$DB_DIR/deploy.sql"; }
repeatable_files() { deploy_files | sed -n '/^generated\/tsql\/004_rls_tables\.sql$/,$p'; }
bundle_sum() {   # the names and contents of the files given on stdin, relative to db/
    local f
    while read -r f; do printf '%s\n' "$f"; cat "$DB_DIR/$f"; done | sha256sum | cut -c1-64 | tr 'a-f' 'A-F'
}
file_sum() { sha256sum "$1" | cut -c1-64 | tr 'a-f' 'A-F'; }
FP="(SELECT CONVERT(CHAR(64), Fingerprint, 2) FROM plat.fn_SchemaFingerprint())"

# The versioned scripts, by name; anything else in the folder is refused.
versions=()
if [ -d "$MIGRATIONS" ]; then
    for f in "$MIGRATIONS"/*; do
        [ -e "$f" ] || continue
        b="$(basename "$f")"
        case "$b" in
            README.md) ;;
            *) [[ "$b" =~ ^V[0-9]{4}__[A-Za-z0-9_-]+\.sql$ ]] || bankfas_refuse "db/migrations holds $b: a versioned script is named Vnnnn__description.sql"
               versions+=("$b") ;;
        esac
    done
fi
if [ "${#versions[@]}" -gt 0 ]; then
    mapfile -t versions < <(printf '%s\n' "${versions[@]}" | sort)
    dup="$(printf '%s\n' "${versions[@]}" | cut -c1-5 | uniq -d | head -1)"
    [ -z "$dup" ] || bankfas_refuse "two scripts in db/migrations have the version $dup"
fi

journal_rows() { query "SELECT COUNT(*) FROM plat.SchemaMigration;"; }
gate() {   # the server gate (db/ops/server_gate.sql), in a session of its own
    bankfas_gate_sql > "$WORK/gate.sql"
    sq -i "$WORK/gate.sql" > "$WORK/gate.out" 2>&1 || { cat "$WORK/gate.out" >&2; bankfas_refuse "the server gate refused this run"; }
}
[ "$cmd" = "status" ] || gate

if [ "$cmd" = "baseline" ]; then
    [ "$(journal_rows)" = "0" ] || bankfas_refuse "the journal is not empty: this database has its baseline already"
    base_sum="$(deploy_files | bundle_sum)"
    rep_sum="$(repeatable_files | bundle_sum)"
    vrows=""
    for b in "${versions[@]}"; do
        vrows+="       ('${b:0:5}', 'VERSIONED', N'$b', 0x$(file_sum "$MIGRATIONS/$b"), @fp, CONCAT('baseline ', SUSER_SNAME()), '$change_ref'),
"
    done
    { sa_guard_sql; cat <<SQL
SET NOCOUNT ON; SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM plat.SchemaMigration WITH (TABLOCKX)) THROW 50147, 'The journal is not empty', 1;
DECLARE @fp VARBINARY(32) = (SELECT Fingerprint FROM plat.fn_SchemaFingerprint());
INSERT plat.SchemaMigration (Version, Kind, ScriptName, Checksum, Fingerprint, AppliedBy, ChangeRef)
VALUES ('BASELINE', 'BASELINE', N'deploy.sql', 0x$base_sum, @fp, SUSER_SNAME(), '$change_ref'),
$vrows       ('R', 'REPEATABLE', N'deploy.sql from generated/tsql/004_rls_tables.sql', 0x$rep_sum, @fp, SUSER_SNAME(), '$change_ref');
COMMIT;
SELECT CONCAT('baseline journaled, fingerprint ', CONVERT(CHAR(64), @fp, 2));
SQL
    } > "$WORK/baseline.sql"
    sq -h -1 -W -i "$WORK/baseline.sql" | tr -d '\r' | sed '/^[[:space:]]*$/d'
    exit 0
fi

[ "$(query "SELECT COUNT(*) FROM plat.SchemaMigration WHERE Kind = 'BASELINE';")" = "1" ] \
    || bankfas_refuse "no BASELINE in plat.SchemaMigration: deploy.sh journals it (migrate.sh baseline)"
journal_fp="$(query "SELECT TOP (1) CONVERT(CHAR(64), Fingerprint, 2) FROM plat.SchemaMigration ORDER BY SchemaMigrationId DESC;")"
current_fp="$(query "SELECT $FP;")"
last_rep="$(query "SELECT TOP (1) CONVERT(CHAR(64), Checksum, 2) FROM plat.SchemaMigration WHERE Kind = 'REPEATABLE' ORDER BY SchemaMigrationId DESC;")"
last_kind="$(query "SELECT TOP (1) Kind FROM plat.SchemaMigration ORDER BY SchemaMigrationId DESC;")"
rep_sum="$(repeatable_files | bundle_sum)"
declare -A applied=()
while IFS='|' read -r v s; do [ -n "$v" ] && applied["$v"]="$s"; done \
    < <(query "SELECT CONCAT(Version, '|', CONVERT(CHAR(64), Checksum, 2)) FROM plat.SchemaMigration WHERE Kind = 'VERSIONED' ORDER BY Version;")
problems=()
pending=()
last_applied=""
for v in "${!applied[@]}"; do [[ "$v" > "$last_applied" ]] && last_applied="$v"; done
declare -A seen=()
for b in "${versions[@]}"; do
    v="${b:0:5}"; seen["$v"]=1
    if [ -n "${applied[$v]:-}" ]; then
        [ "${applied[$v]}" = "$(file_sum "$MIGRATIONS/$b")" ] || problems+=("$b was changed after it was applied: a correction is a new script")
    elif [[ "$v" < "$last_applied" ]]; then
        problems+=("$b sorts before $last_applied, which is applied already: give it a later number")
    else
        pending+=("$b")
        # a line that would end the journal's transaction, or run a sqlcmd command, is refused before anything runs
        bad_line="$(grep -niE '^[[:space:]]*((commit|rollback)([[:space:]]|;|$)|begin[[:space:]]+(distributed[[:space:]]+)?tran|save[[:space:]]+tran|:[a-z!]|!!)' "$MIGRATIONS/$b" | head -1 || true)"
        [ -z "$bad_line" ] || problems+=("$b line ${bad_line%%:*} ends or opens a transaction, or is a sqlcmd command: a versioned script runs inside the transaction of its journal row")
    fi
done
for v in "${!applied[@]}"; do [ -n "${seen[$v]:-}" ] || problems+=("$v is applied but its script is no longer in db/migrations"); done
[ "$journal_fp" = "$current_fp" ] || problems+=("the schema's fingerprint $current_fp is not the journal's $journal_fp: the schema was changed outside the journal")

if [ "$cmd" = "status" ]; then
    query "SELECT CONCAT(Version, '  ', Kind, '  ', ScriptName, '  ', CONVERT(CHAR(19), AppliedAt, 126), '  ', AppliedBy) FROM plat.SchemaMigration ORDER BY SchemaMigrationId;" | sed 's/^/journal  /'
    for b in "${pending[@]}"; do echo "pending  $b"; done
    if [ "$rep_sum" = "$last_rep" ]; then echo "repeatable scripts unchanged since their last run"; else echo "repeatable scripts changed since their last run"; fi
    echo "fingerprint $current_fp"
    for p in "${problems[@]}"; do echo "problem  $p"; done
    [ "${#problems[@]}" -eq 0 ]
    exit $?
fi

# apply
if [ "${#problems[@]}" -gt 0 ]; then
    for p in "${problems[@]}"; do echo "migrate.sh: $p" >&2; done
    exit 1
fi
for b in "${pending[@]}"; do
    v="${b:0:5}"; s="$(file_sum "$MIGRATIONS/$b")"
    { sa_guard_sql; cat <<SQL
:on error exit
SET NOCOUNT ON; SET XACT_ABORT ON;
DECLARE @start DATETIME2(7) = SYSUTCDATETIME(); EXEC sys.sp_set_session_context @key = N'bankfas.migration.start', @value = @start;
BEGIN TRANSACTION;
IF EXISTS (SELECT 1 FROM plat.SchemaMigration WITH (TABLOCKX) WHERE Version = '$v') THROW 50147, 'This version is applied already', 1;
IF (SELECT Fingerprint FROM plat.fn_SchemaFingerprint())
   <> (SELECT TOP (1) Fingerprint FROM plat.SchemaMigration ORDER BY SchemaMigrationId DESC)
    THROW 50147, 'The schema was changed outside the journal since the check', 1;
GO
:r "$MIGRATIONS/$b"
GO
IF @@TRANCOUNT <> 1 THROW 50147, 'A versioned script ends the transaction it runs in, or opens another', 1;
INSERT plat.SchemaMigration (Version, Kind, ScriptName, Checksum, Fingerprint, AppliedBy, DurationMs, ChangeRef)
SELECT '$v', 'VERSIONED', N'$b', 0x$s, Fingerprint, SUSER_SNAME(),
       DATEDIFF(MILLISECOND, CAST(SESSION_CONTEXT(N'bankfas.migration.start') AS DATETIME2(7)), SYSUTCDATETIME()), '$change_ref'
FROM plat.fn_SchemaFingerprint();
COMMIT;
GO
SQL
    } > "$WORK/apply.sql"
    (cd "$DB_DIR" && sq -i "$WORK/apply.sql")
    echo "applied $b"
done
if [ "${#pending[@]}" -gt 0 ] || [ "$rep_sum" != "$last_rep" ] || [ "$last_kind" = "VERSIONED" ] || [ "$force_repeatable" = "1" ]; then
    { sa_guard_sql
      printf ':on error exit\nSET NOCOUNT ON; SET XACT_ABORT ON;\n'
      printf "DECLARE @start DATETIME2(7) = SYSUTCDATETIME(); EXEC sys.sp_set_session_context @key = N'bankfas.migration.start', @value = @start;\n"
      printf 'BEGIN TRANSACTION;\nGO\n'
      repeatable_files | sed 's/^/:r /'
      cat <<SQL
GO
IF @@TRANCOUNT <> 1 THROW 50147, 'A repeatable script ends the transaction it runs in, or opens another', 1;
INSERT plat.SchemaMigration (Version, Kind, ScriptName, Checksum, Fingerprint, AppliedBy, DurationMs, ChangeRef)
SELECT 'R', 'REPEATABLE', N'deploy.sql from generated/tsql/004_rls_tables.sql', 0x$rep_sum, Fingerprint, SUSER_SNAME(),
       DATEDIFF(MILLISECOND, CAST(SESSION_CONTEXT(N'bankfas.migration.start') AS DATETIME2(7)), SYSUTCDATETIME()), '$change_ref'
FROM plat.fn_SchemaFingerprint();
COMMIT;
GO
SQL
    } > "$WORK/repeatable.sql"
    (cd "$DB_DIR" && sq -i "$WORK/repeatable.sql" > "$WORK/repeatable.out") || { cat "$WORK/repeatable.out"; exit 1; }
    echo "ran the repeatable scripts"
fi
echo "fingerprint $(query "SELECT $FP;")"
