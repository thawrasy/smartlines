#!/usr/bin/env bash
# The job JOB-PLT-AUDIT-CHAIN (db/static/055_audit_chain.sql; FR-PLT-025, DOC-S12 section 5.3, ADR 0033): keeps the
# anchors of the audit hash chains outside the database, and checks the chains against them. The store, never the
# database, is the judge (internal review v6, D1, D2).
#
#   audit_anchor.sh take <store>     the daily run. It first checks each chain from its latest anchor in the store
#                                    (as verify does) and refuses to anchor anything if one is not OK: a chain rewritten
#                                    in the database is never anchored again as it now stands. Then it takes the head of
#                                    each chain that moved past its latest store anchor (aud.usp_TakeAuditAnchors, given
#                                    the store's latest anchors) and writes them to a new file of the store,
#                                    anchors-<UTC time>-<random>.tsv, one line per chain: chain key, number, SHA-256 in
#                                    hex, time taken. The file is never written twice (noclobber), is read back and
#                                    compared, and is made read-only. An anchor taken in the database whose file was not
#                                    written is simply taken again the next day, since the store has no newer anchor.
#   audit_anchor.sh verify <store> [--full]
#                                    checks each chain against the store: daily, from its latest anchor (the anchor's
#                                    row and the rows after it, so the cost follows the day's rows); with --full, weekly,
#                                    every row and every anchor of the store, which alone sees an old row changed without
#                                    its hash computed again (ADR 0033, docs/40). It also fails a chain whose first row is
#                                    older than BANKFAS_ANCHOR_MAX_AGE_HOURS (default 26) and has no anchor in the store,
#                                    or that moved past an anchor older than that (NOT_ANCHORED, STALE): a job that stops
#                                    anchoring is itself an alarm.
#   audit_anchor.sh restored <store> <change reference>
#                                    after a restore of the database to an earlier time (DOC-S09): the anchors past the
#                                    restored heads can no longer match. Every chain is checked in full against the
#                                    store's anchors up to its restored head; if all are OK, a file
#                                    restore-<UTC time>-<random>.tsv records the restored heads and the change
#                                    reference, and the anchors past them, taken before it, no longer count. The monthly
#                                    review lists the restore files (DOC-S12 section 5.3).
#   Exit code 1 when a chain is not OK. Each check is also an audit row (AUDIT_CHAIN_VERIFIED, or AUDIT_CHAIN_BROKEN,
#   high severity), from which AL-12 raises the alert (DOC-S12 section 6).
#
# <store> is what nobody with access to the database can rewrite: a write-once (object lock) bucket mounted here, or a
# WORM volume, in another administrative domain than the database server (DOC-S12 section 5.3). The operator mounts
# it and puts in it, once, the file .bankfas-anchor-store; a folder without it (a store not mounted, the bare mount
# point) is refused (D12).
#
# Environment: SQL_SERVER, SQLCMD and SQLCMD_OPTS as for deploy.sh; SQL_USER, default bankfas_jobs_a, the job worker's
# login (tp_jobs, ADR 0009), with SQLCMDPASSWORD from its secret file; BANKFAS_ANCHOR_MAX_AGE_HOURS.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-bankfas_jobs_a}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
MAX_AGE_H="${BANKFAS_ANCHOR_MAX_AGE_HOURS:-26}"
# shellcheck source=tools/deploy/preflight.sh
. "$HERE/preflight.sh"
usage="usage: audit_anchor.sh take <store> | verify <store> [--full] | restored <store> <change reference>"
full=0 change=""
case "${1:-}" in
    take) [ $# -eq 2 ] || bankfas_refuse "$usage" ;;
    verify) { [ $# -eq 2 ] || { [ $# -eq 3 ] && [ "$3" = "--full" ] && full=1; }; } || bankfas_refuse "$usage" ;;
    restored) [ $# -eq 3 ] && [[ "$3" =~ ^[A-Za-z0-9._/-]{3,60}$ ]] || bankfas_refuse "$usage (the reference: 3 to 60 letters, digits, . _ / -)"
              change="$3" full=1 ;;
    *) bankfas_refuse "$usage" ;;
esac
[[ "$MAX_AGE_H" =~ ^[0-9]{1,4}$ ]] || bankfas_refuse "BANKFAS_ANCHOR_MAX_AGE_HOURS is a number of hours"
cmd="$1" store="$2"
[ -d "$store" ] || bankfas_refuse "no folder $store"
[ -f "$store/.bankfas-anchor-store" ] || bankfas_refuse "$store has no .bankfas-anchor-store: is the store mounted? (D12)"
: "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
run() {   # a batch from stdin; its rows, without blank lines
    { sa_guard_sql; cat; } > "$WORK/q.sql"
    "$SQLCMD" -S "$SQL_SERVER" -U "$SQL_USER" -d BankFas -I -b -h -1 -W -s '|' $SQLCMD_OPTS -i "$WORK/q.sql" | tr -d '\r' | sed '/^[[:space:]]*$/d'
}
stamp() { printf '%s-%s' "$(date -u +%Y%m%dT%H%M%SZ)" "$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"; }
epoch() { date -u -d "$1" +%s 2>/dev/null || echo 0; }

# The anchors that count, oldest file first (by the time in its name): every anchor line, but a restore file drops the
# anchors of its chains past the head it records, and its own lines count as anchors.
ls "$store" | grep -E '^(anchors|restore)-[0-9]{8}T[0-9]{6}Z(-[0-9a-f]{8})?\.tsv$' \
    | awk -F- '{ print $2 "\t" $0 }' | sort | cut -f2 > "$WORK/files" || true
: > "$WORK/all"
while read -r f; do
    kind="${f%%-*}"
    awk -F'\t' -v kind="$kind" -v all="$WORK/all" '
        BEGIN { while ((getline l < all) > 0) { split(l, x, "\t"); n++; K[n] = x[1]; S[n] = x[2]; H[n] = x[3]; T[n] = x[4] } }
        NF >= 4 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9A-F]{64}$/ { m++; k[m] = $1; s[m] = $2; h[m] = $3; t[m] = $4; if (kind == "restore") cut[$1] = $2 }
        END { for (i = 1; i <= n; i++) if (!(K[i] in cut) || S[i] + 0 <= cut[K[i]] + 0) print K[i] "\t" S[i] "\t" H[i] "\t" T[i]
              for (i = 1; i <= m; i++) print k[i] "\t" s[i] "\t" h[i] "\t" t[i] }' /dev/null "$store/$f" > "$WORK/all.new"
    mv "$WORK/all.new" "$WORK/all"
done < "$WORK/files"
# the latest anchor of each chain: number, hash, time taken
awk -F'\t' '{ if (!($1 in s) || $2 + 0 > s[$1] + 0) { s[$1] = $2; h[$1] = $3; t[$1] = $4 } }
    END { for (k in s) print k "\t" s[k] "\t" h[k] "\t" t[k] }' "$WORK/all" | sort -n > "$WORK/latest"

# The chains in the database: key, head number, head hash, time of the first row.
run > "$WORK/chains.raw" <<SQL
SET NOCOUNT ON;
EXEC aud.usp_ListAuditChains @JobKey = 'JOB-PLT-AUDIT-CHAIN';
SQL
grep -E '^[0-9]+\|[0-9]+\|[0-9A-F]{64}\|' "$WORK/chains.raw" | tr '|' '\t' > "$WORK/chains" || true
[ "$(wc -l < "$WORK/chains")" = "$(wc -l < "$WORK/chains.raw")" ] || bankfas_refuse "the list of chains could not be read: $(head -3 "$WORK/chains.raw")"

now="$(date -u +%s)" bad=0
: > "$WORK/report"
check() {   # chain key: verify it against the store; prints one line, sets bad
    local key="$1" seq hash taken more="" res status head first a_seq a_hash a_more
    read -r seq hash taken <<< "$(awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $3 "\t" $4 }' "$WORK/latest")"
    read -r head first <<< "$(awk -F'\t' -v k="$key" '$1 == k { print $2 "\t" $4 }' "$WORK/chains")"
    if [ -z "$seq" ]; then
        if [ "$cmd" = "verify" ] && [ -n "$first" ] && [ $(( now - $(epoch "$first") )) -gt $(( MAX_AGE_H * 3600 )) ]; then
            echo "chain $key: NOT_ANCHORED (head ${head:-0}; first row $first, no anchor in the store)"; bad=1
        else
            echo "chain $key: new, not anchored yet (head ${head:-0})"
        fi
        return 0
    fi
    if [ "$full" = "1" ]; then
        more="$(awk -F'\t' -v k="$key" -v s="$seq" -v hd="${head:-0}" -v r="$cmd" '$1 == k && $2 != s && (r != "restored" || $2 + 0 <= hd + 0) {
            printf "%s{\"s\":%s,\"h\":\"%s\"}", (n++ ? "," : "["), $2, $3 } END { if (n) print "]" }' "$WORK/all")"
        if [ "$cmd" = "restored" ] && [ "$seq" -gt "${head:-0}" ]; then   # the latest anchor is past the restored head
            read -r seq hash <<< "$(awk -F'\t' -v k="$key" -v hd="${head:-0}" '$1 == k && $2 + 0 <= hd + 0 && $2 + 0 > m + 0 { m = $2; h = $3 } END { if (m) print m "\t" h }' "$WORK/all")"
        fi
    fi
    local a_seq="${seq:-NULL}" a_hash="NULL" a_more="NULL"
    [ -z "$hash" ] || a_hash="0x$hash"
    [ -z "$more" ] || a_more="N'$more'"
    res="$(run <<SQL
SET NOCOUNT ON;
DECLARE @s VARCHAR(20), @b BIGINT, @n BIGINT;
EXEC aud.usp_VerifyAuditChain @JobKey = 'JOB-PLT-AUDIT-CHAIN', @ChainKey = $key,
     @AnchorSeq = $a_seq, @AnchorHash = $a_hash,
     @FromAnchor = $((1 - full)), @MoreAnchors = $a_more,
     @Status = @s OUTPUT, @BadSeq = @b OUTPUT, @Rows = @n OUTPUT;
SELECT CONCAT(@s, '|', @b, '|', @n);
SQL
)"
    status="${res%%|*}"
    # only verify judges the age: take is what makes the store current again, so it must not refuse for it
    if [ "$status" = "OK" ] && [ "$cmd" = "verify" ] && [ "${head:-0}" -gt "$seq" ] \
       && [ $(( now - $(epoch "$taken") )) -gt $(( MAX_AGE_H * 3600 )) ]; then
        status="STALE"; res="STALE|$seq|${res#*|*|}"
    fi
    echo "chain $key: $status (anchor ${seq:-none}; ${res#*|})"
    [ "$status" = "OK" ] || bad=1
}
cut -f1 "$WORK/latest" "$WORK/chains" | sort -nu > "$WORK/keys"
while read -r key; do check "$key"; done < "$WORK/keys"

if [ "$cmd" = "verify" ]; then exit "$bad"; fi
[ "$bad" = "0" ] || bankfas_refuse "a chain does not match the store: nothing is anchored until it is resolved (ADR 0033)"

write_file() {   # file name, lines: a new read-only file of the store, read back and compared
    local out="$store/$1"
    ( set -o noclobber; cat "$2" > "$out" ) || bankfas_refuse "could not write $out: the anchors are taken again on the next run"
    sync "$out" 2>/dev/null || true
    cmp -s "$2" "$out" || bankfas_refuse "$out does not read back as written"
    chmod 0444 "$out"
    echo "anchors: $(grep -cE '^[0-9]+	' "$out") written to $out"
}

if [ "$cmd" = "restored" ]; then
    { printf '# restored database, change %s, %s; heads:\n' "$change" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      awk -F'\t' -v t="$(date -u +%Y-%m-%dT%H:%M:%S.000)" '{ print $1 "\t" $2 "\t" $3 "\t" t }' "$WORK/chains"; } > "$WORK/restore.tsv"
    write_file "restore-$(stamp).tsv" "$WORK/restore.tsv"
    exit 0
fi

# take: the heads that moved past the store's latest anchors
json="$(awk -F'\t' '{ printf "%s{\"k\":%s,\"s\":%s}", (n++ ? "," : ""), $1, $2 }' "$WORK/latest")"
ref="anchors-$(stamp).tsv"
run > "$WORK/anchors.raw" <<SQL
SET NOCOUNT ON;
EXEC aud.usp_TakeAuditAnchors @JobKey = 'JOB-PLT-AUDIT-CHAIN', @StoreRef = N'$ref', @StoreLatest = N'[$json]';
SQL
grep -E '^[0-9]+\|[0-9]+\|[0-9A-F]{64}\|' "$WORK/anchors.raw" | tr '|' '\t' > "$WORK/anchors.tsv" || true
[ "$(wc -l < "$WORK/anchors.tsv")" = "$(wc -l < "$WORK/anchors.raw")" ] \
    || bankfas_refuse "the anchors could not be read: $(head -3 "$WORK/anchors.raw"); they are taken again on the next run"
if [ ! -s "$WORK/anchors.tsv" ]; then echo "anchors: no chain moved"; exit 0; fi
write_file "$ref" "$WORK/anchors.tsv"
