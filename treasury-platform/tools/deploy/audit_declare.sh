# Declarations of deployment windows and administrative changes in SQL Server Audit (docs/adr/0012-server-audit.md).
# Sourced by prepare_database.sh, provision_logins.sh and server_audit.sh. The alerts of db/ops/server_audit_alerts.sql
# do not fire for changes inside a declared window, and the monthly review matches every declaration with the
# deployment log (DOC-S11 section 10).
#   BANKFAS_CHANGE_REF  the change in the deployment log, 1 to 64 characters of [A-Za-z0-9._/-] (default unrecorded,
#                       which the review then has to explain)
# declare_sql EVENT TEXT prints a batch that writes user-defined audit event EVENT: 1101 deployment window opened,
# 1102 deployment window closed, 1103 administrative change started, 1104 administrative change finished. While no
# audit records user-defined events the batch writes nothing and does not fail.
CHANGE_REF="${BANKFAS_CHANGE_REF:-unrecorded}"
if ! [[ "$CHANGE_REF" =~ ^[A-Za-z0-9._/-]{1,64}$ ]]; then
    echo "BANKFAS_CHANGE_REF must be 1 to 64 characters of [A-Za-z0-9._/-]" >&2
    exit 1
fi
declare_sql() {
    printf "EXEC sys.sp_audit_write @user_defined_event_id = %s, @succeeded = 1, @user_defined_information = N'BankFas %s; change %s';\nGO\n" \
        "$1" "$2" "$CHANGE_REF"
}
