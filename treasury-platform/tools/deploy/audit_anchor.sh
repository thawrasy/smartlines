#!/usr/bin/env bash
# The job JOB-PLT-AUDIT-CHAIN (db/static/055_audit_chain.sql; FR-PLT-025, DOC-S12 section 5.3, ADR 0033): keeps the
# anchors of the audit hash chains outside the database, and checks the chains against them.
#
#   audit_anchor.sh take <store>     takes the head of each chain that moved (aud.usp_TakeAuditAnchors) and writes them
#                                    to a new file in <store>, anchors-<UTC time>.tsv, one line per chain:
#                                    chain key, number, SHA-256 in hex, time taken. A file is never written twice
#                                    (noclobber) and is made read-only.
#   audit_anchor.sh verify <store> [--full]
#                                    checks each chain of the files against its latest anchor
#                                    (aud.usp_VerifyAuditChain): daily, from the anchor (the anchor's row and the rows
#                                    after it, so the cost follows the day's rows); with --full, weekly, every row,
#                                    which alone sees an old row changed without its hash computed again (ADR 0033,
#                                    docs/40). Exit code 1 when a chain is not OK; each result is
#                                    also an audit row (AUDIT_CHAIN_VERIFIED, or AUDIT_CHAIN_BROKEN, high severity),
#                                    from which AL-12 raises the alert (DOC-S12 section 6).
#
# <store> is what nobody with access to the database can rewrite: a write-once (object lock) bucket mounted here, or a
# WORM volume, in another administrative domain than the database server (DOC-S12 section 5.3). The operator mounts
# it; the script only needs the folder.
#
# Environment: SQL_SERVER, SQLCMD and SQLCMD_OPTS as for deploy.sh; SQL_USER, default bankfas_jobs_a, the job worker's
# login (tp_jobs, ADR 0009), with SQLCMDPASSWORD from its secret file.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-bankfas_jobs_a}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
# shellcheck source=tools/deploy/preflight.sh
. "$HERE/preflight.sh"
full=0
if [ $# -eq 3 ] && [ "$1" = "verify" ] && [ "$3" = "--full" ]; then full=1; set -- "$1" "$2"; fi
[ $# -eq 2 ] && { [ "$1" = "take" ] || [ "$1" = "verify" ]; } || bankfas_refuse "usage: audit_anchor.sh take <store> | verify <store> [--full]"
cmd="$1" store="$2"
[ -d "$store" ] || bankfas_refuse "no folder $store"
: "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
run() {   # a batch from stdin; its rows, without blank lines
    { sa_guard_sql; cat; } > "$WORK/q.sql"
    "$SQLCMD" -S "$SQL_SERVER" -U "$SQL_USER" -d BankFas -I -b -h -1 -W -s '|' $SQLCMD_OPTS -i "$WORK/q.sql" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}

if [ "$cmd" = "take" ]; then
    out="$store/anchors-$(date -u +%Y%m%dT%H%M%SZ).tsv"
    run > "$WORK/anchors" <<SQL
SET NOCOUNT ON;
EXEC aud.usp_TakeAuditAnchors @JobKey = 'JOB-PLT-AUDIT-CHAIN', @StoreRef = N'$(basename "$out")';
SQL
    grep -E '^[0-9]+\|[0-9]+\|[0-9A-F]{64}\|' "$WORK/anchors" | tr '|' '\t' > "$WORK/anchors.tsv" || true
    set -o noclobber
    cat "$WORK/anchors.tsv" > "$out"
    chmod 0444 "$out"
    echo "anchors: $(wc -l < "$out") written to $out"
    exit 0
fi

# verify: the latest anchor of each chain, over every file of the store
cat "$store"/anchors-*.tsv 2>/dev/null | awk -F'\t' 'NF >= 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9A-F]{64}$/ {
    if (!($1 in seq) || $2 + 0 > seq[$1] + 0) { seq[$1] = $2; hash[$1] = $3 } }
    END { for (k in seq) print k "\t" seq[k] "\t" hash[k] }' | sort -n > "$WORK/latest"
[ -s "$WORK/latest" ] || bankfas_refuse "no anchor in $store: take one first"
bad=0
while IFS=$'\t' read -r key seq hash; do
    res="$(run <<SQL
SET NOCOUNT ON;
DECLARE @s VARCHAR(20), @b BIGINT, @n BIGINT;
EXEC aud.usp_VerifyAuditChain @JobKey = 'JOB-PLT-AUDIT-CHAIN', @ChainKey = $key, @AnchorSeq = $seq, @AnchorHash = 0x$hash,
     @FromAnchor = $((1 - full)), @Status = @s OUTPUT, @BadSeq = @b OUTPUT, @Rows = @n OUTPUT;
SELECT CONCAT(@s, '|', @b, '|', @n);
SQL
)"
    status="${res%%|*}"
    echo "chain $key: $status (anchor $seq; ${res#*|})"
    [ "$status" = "OK" ] || bad=1
done < "$WORK/latest"
exit "$bad"
