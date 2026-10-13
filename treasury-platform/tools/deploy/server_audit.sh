#!/usr/bin/env bash
# SQL Server Audit of the database server (DOC-S08 section 10, DQ-S08-10; DOC-S12 section 3.5; docs/adr/0012-server-audit.md).
#   apply            creates or corrects the audit, its server specification and, once BankFas is deployed, its database
#                    specification (db/ops/server_audit.sql). Run it before the first deployment, so that the deployment
#                    is recorded, and inside every deployment window after deploy.sh. What already matches is left
#                    running untouched. It declares itself in the audit as an administrative change (audit_declare.sh).
#   check            fails unless the three are in place and the audit is writing (HS-8 in DOC-S10, R-08 in DOC-S11).
#   alerts [SINCE]   the AL-18 alerts in the audit files since SINCE (UTC, YYYY-MM-DDTHH:MM:SS; default 24 hours ago),
#                    from db/ops/server_audit_alerts.sql. Exit code 3 when there is any.
#   windows [SINCE]  the declared deployment windows and administrative changes, for the monthly review.
# BANKFAS_AUDIT_DIR is the folder of the audit files, default /var/opt/mssql/audit (V5, DOC-S10 section 3). It must
# exist, owned by mssql. apply runs with an administrator's own login (SQL_USER, SQLCMDPASSWORD, as for
# prepare_database.sh); check, alerts and windows need only the read permissions in docs/adr/0012-server-audit.md.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OPS="$(cd "$HERE/../../db/ops" && pwd)"
SQL_SERVER="${SQL_SERVER:-localhost,1433}"
SQL_USER="${SQL_USER-sa}"
SQLCMD="${SQLCMD:-sqlcmd}"
SQLCMD_OPTS="${SQLCMD_OPTS-}"
AUDIT_DIR="${BANKFAS_AUDIT_DIR:-/var/opt/mssql/audit}"
AUDIT_DIR="${AUDIT_DIR%/}"
ACTION="${1:-}"

fail() { echo "server_audit: $*" >&2; exit 1; }
# shellcheck source=tools/deploy/audit_declare.sh
. "$HERE/audit_declare.sh"
[[ "$AUDIT_DIR" =~ ^/[A-Za-z0-9/_.-]+$ ]] || fail "BANKFAS_AUDIT_DIR must be an absolute path of [A-Za-z0-9/_.-]"
if [ -n "$SQL_USER" ]; then
    : "${SQLCMDPASSWORD:?set SQLCMDPASSWORD for the login $SQL_USER}"
    AUTH=(-U "$SQL_USER")
else
    AUTH=(-E)
fi
WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
sq() { "$SQLCMD" -S "$SQL_SERVER" "${AUTH[@]}" -I -b $SQLCMD_OPTS "$@"; }
fill() {   # template, mode or report, since: the $(...) values, filled here as in prepare_database.sh
    local sql
    sql="$(cat "$1")"
    sql="${sql//\$(BANKFAS_AUDIT_DIR)/$AUDIT_DIR}"
    sql="${sql//\$(BANKFAS_AUDIT_MODE)/$2}"
    sql="${sql//\$(BANKFAS_ALERTS_REPORT)/$2}"
    sql="${sql//\$(BANKFAS_ALERTS_SINCE)/${3:-}}"
    printf '%s\n' "$sql"
}
since() {
    local s="${1:-$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%S)}"
    [[ "$s" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] || fail "SINCE must be YYYY-MM-DDTHH:MM:SS (UTC)"
    printf '%s' "$s"
}

case "$ACTION" in
apply)
    # The end of the change is declared even when the run fails, so the window never outlives the run.
    { declare_sql 1103 "server_audit apply started"; fill "$OPS/server_audit.sql" APPLY; } > "$WORK/run.sql"
    declare_sql 1104 "server_audit apply finished" > "$WORK/end.sql"
    rc=0
    sq -i "$WORK/run.sql" || rc=$?
    sq -i "$WORK/end.sql" >/dev/null || true
    exit "$rc"
    ;;
check)
    fill "$OPS/server_audit.sql" CHECK > "$WORK/run.sql"
    sq -i "$WORK/run.sql"
    ;;
alerts)
    s="$(since "${2:-}")"
    fill "$OPS/server_audit_alerts.sql" ALERTS "$s" > "$WORK/run.sql"
    if ! sq -h -1 -W -s '|' -i "$WORK/run.sql" > "$WORK/alerts.out"; then
        cat "$WORK/alerts.out" >&2
        exit 1
    fi
    n=$(grep -c . "$WORK/alerts.out" || true)
    echo "rule|event_time|action|class|principal|database|object|statement"
    cat "$WORK/alerts.out"
    echo "AL-18 alerts since $s: $n"
    [ "$n" -eq 0 ] || exit 3
    ;;
windows)
    s="$(since "${2:-}")"
    echo "kind|opened|ends|closing|opened_by|declaration"
    fill "$OPS/server_audit_alerts.sql" WINDOWS "$s" > "$WORK/run.sql"
    sq -h -1 -W -s '|' -i "$WORK/run.sql"
    ;;
*)
    fail "usage: server_audit.sh apply | check | alerts [SINCE] | windows [SINCE]"
    ;;
esac
